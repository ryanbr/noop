package com.noop.protocol

import com.noop.data.BatteryRow
import com.noop.data.EcgWaveformRow
import com.noop.data.EventEntry
import com.noop.data.GravityRow
import com.noop.data.HrRow
import com.noop.data.PpgHrRow
import com.noop.data.PpgWaveformRow
import com.noop.data.RespRow
import com.noop.data.RrRow
import com.noop.data.SkinTempRow
import com.noop.data.SleepStateRow
import com.noop.data.Spo2Row
import com.noop.data.StepRow
import com.noop.data.StreamBatch
import com.noop.data.V18AuxRow
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * GOLDEN DECODER ORACLE (lane-4 A8) , the Kotlin half of a shared Swift<->Kotlin drift guard.
 *
 * `src/test/resources/decoder_oracle.json` is a fixture of REAL captured WHOOP type-47 HISTORICAL_DATA
 * frames plus their expected decode. The IDENTICAL file is committed at
 * `Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/decoder_oracle.json`, and the Swift
 * `DecoderOracleTests` runs the same assertions through `parseFrame`. Because the two decoders are
 * independent reimplementations of the same byte layout, decoding the same fixture and asserting the
 * same output is what catches a one-sided edit (a moved offset / changed scaling on one platform only).
 *
 * The fixture was seeded from existing in-repo test vectors (Whoop4HistoricalV25Test,
 * Whoop5HistoricalDecodeTest and their Swift twins), so every expected value is already independently
 * grounded , this test only proves the two decoders agree on it.
 *
 * The oracle pins THREE layers, each with a twin test in `DecoderOracleTests.swift` (#647, #775):
 *  1. `frames`         , decoded VALUES. A per-platform fixture-hex test cannot catch a 32-vs-64-bit or
 *                        signedness divergence: the wire bytes are identical on both platforms and each
 *                        suite asserts its own answer. Comparing the decoded NUMBERS against one shared
 *                        expectation is what catches it (PR #848: a u32 with bit 31 set read
 *                        -1062772323 here and 3232194973 in Swift).
 *  2. `stream_batches` , the ASSEMBLED shape. Frame decode agreeing does not imply assembly agrees ,
 *                        PR #848 also shipped a [StreamBatch.isEmpty] that omitted a stream Swift's
 *                        `Streams.isEmpty` included, and `insert` early-returns on empty, so that batch
 *                        banked nothing on Android alone.
 *  3. `coverage`       , the self-defence manifest, so the oracle cannot silently stop covering
 *                        something. Deleting an `expect` key, a frame or a batch fails a test.
 */
class DecoderOracleTest {

    private fun hexToBytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    private fun loadOracle(): JSONObject {
        val stream = javaClass.classLoader!!.getResourceAsStream("decoder_oracle.json")
        assertNotNull("decoder_oracle.json missing from test classpath", stream)
        return JSONObject(stream!!.bufferedReader().use { it.readText() })
    }

    @Test
    fun oracleFramesDecodeToExpectedOutput() {
        val oracle = loadOracle()
        val tolerance = oracle.getDouble("tolerance")
        val frames = oracle.getJSONArray("frames")
        assertTrue("no oracle frames loaded", frames.length() > 0)

        for (i in 0 until frames.length()) {
            val frame = frames.getJSONObject(i)
            val name = frame.getString("name")
            val family = if (frame.getString("family") == "whoop5") DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4
            val parsed = decodeHistorical(hexToBytes(frame.getString("hex")), family)
            assertNotNull("$name: decodeHistorical returned null", parsed)
            parsed!!

            val expect = frame.getJSONObject("expect")
            for (key in expect.keys()) {
                when (key) {
                    "gravity_mag" -> {
                        val wantMag = expect.getDouble(key)
                        val gx = parsed["gravity_x"] as? Double
                        val gy = (parsed["gravity_y"] as? Double) ?: 0.0
                        val gz = (parsed["gravity_z"] as? Double) ?: 0.0
                        assertNotNull("$name: gravity did not decode", gx)
                        val mag = sqrt(gx!! * gx + gy * gy + gz * gz)
                        assertTrue("$name: |gravity| $mag != ~$wantMag", abs(mag - wantMag) <= 0.1)
                    }
                    else -> {
                        val want = expect.get(key)
                        when (want) {
                            is org.json.JSONArray -> {
                                @Suppress("UNCHECKED_CAST")
                                val got = (parsed[key] as? List<Int>) ?: emptyList()
                                val wantList = (0 until want.length()).map { want.getInt(it) }
                                assertEquals("$name.$key", wantList, got)
                            }
                            // Numeric compare keyed off the DECODED type, not org.json's parse type (it
                            // can hand back Int / Long / Double / BigDecimal / BigInteger for one JSON
                            // number). Integral decoded fields compare exactly; float fields within tolerance.
                            is Number -> when (val got = parsed[key]) {
                                is Int, is Long ->
                                    assertEquals("$name.$key", want.toLong(), (got as Number).toLong())
                                is Double, is Float -> {
                                    val w = want.toDouble()
                                    val g = (got as Number).toDouble()
                                    assertTrue("$name.$key: $g != ~$w", abs(g - w) <= tolerance)
                                }
                                null -> throw AssertionError("$name.$key missing in decoded output")
                                else -> assertEquals("$name.$key", want.toString(), got.toString())
                            }
                            else -> throw AssertionError("$name.$key: unhandled expect type ${want::class}")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Layer 2: stream assembly

    /**
     * Per-stream row counts + the emptiness verdict for each pinned batch. Frame decode agreeing does
     * not imply assembly agrees: [extractHistoricalStreams] gates each stream separately (bpm 0 writes
     * no HR row, skin temp has a thermal gate, v25 carries gravity but no HR), and the emptiness verdict
     * is what `insert` early-returns on. Every stream is pinned INCLUDING the zeros, so a stream that
     * materialises on one platform only is a failure rather than an unasserted extra.
     */
    @Test
    fun oracleStreamBatchesAssembleToExpectedShape() {
        val oracle = loadOracle()
        val batches = oracle.getJSONArray("stream_batches")
        assertTrue("no oracle stream batches loaded", batches.length() > 0)
        val framesByName = HashMap<String, JSONObject>()
        val frames = oracle.getJSONArray("frames")
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            framesByName[f.getString("name")] = f
        }

        for (i in 0 until batches.length()) {
            val spec = batches.getJSONObject(i)
            val name = spec.getString("name")
            val family =
                if (spec.getString("family") == "whoop5") DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4
            val names = spec.getJSONArray("frames")
            val raw = (0 until names.length()).map {
                val fname = names.getString(it)
                val f = framesByName[fname] ?: throw AssertionError("$name: unknown fixture frame '$fname'")
                hexToBytes(f.getString("hex"))
            }
            val wallClockRef = spec.getInt("wall_clock_ref")
            val batch = extractHistoricalStreams(
                rawFrames = raw,
                deviceClockRef = spec.getInt("device_clock_ref"),
                wallClockRef = wallClockRef,
                family = family,
                // Optional #547 future-bound override. Absent → reproduce the production default
                // verbatim, so the batches that don't set it behave exactly as before. A batch whose
                // records are post-2038 MUST set it, or the live clock rejects them for an unrelated
                // reason and the batch asserts nothing. Swift passes the same value.
                wallNow = if (spec.has("wall_now")) spec.getLong("wall_now")
                          else maxOf(wallClockRef.toLong(), System.currentTimeMillis() / 1000L),
                sessionOldestUnix = if (spec.has("session_oldest_unix")) spec.getLong("session_oldest_unix") else null,
                sessionNewestUnix = if (spec.has("session_newest_unix")) spec.getLong("session_newest_unix") else null,
            )

            val expect = spec.getJSONObject("expect")
            val counts = expect.getJSONObject("counts")
            val got = streamCounts(batch)
            for (stream in counts.keys()) {
                val have = got[stream] ?: throw AssertionError("$name: unknown stream '$stream'")
                assertEquals("$name.$stream row count", counts.getInt(stream), have)
            }
            assertEquals("$name: emptiness verdict", expect.getBoolean("is_empty"), batch.isEmpty)
            assertEquals(
                "$name: #547 dropped-record count",
                expect.getInt("dropped_implausible"),
                batch.droppedImplausibleTs,
            )
            // The verdict must also AGREE with the counts, so a platform whose isEmpty forgets a stream
            // is caught even on a batch that wasn't written to target that stream.
            assertEquals(
                "$name: isEmpty disagrees with the per-stream counts",
                got.values.all { it == 0 },
                batch.isEmpty,
            )
        }
    }

    /** Row count per stream, keyed by the oracle's (and Swift `Streams.CodingKeys`') wire names. */
    private fun streamCounts(b: StreamBatch): Map<String, Int> = mapOf(
        "hr" to b.hr.size, "rr" to b.rr.size, "spo2" to b.spo2.size, "skin_temp" to b.skinTemp.size,
        "resp" to b.resp.size, "gravity" to b.gravity.size, "steps" to b.steps.size,
        "sleep_state" to b.sleepState.size, "ppg_hr" to b.ppgHr.size,
        "ppg_waveform" to b.ppgWaveform.size, "ecg_waveform" to b.ecgWaveform.size,
        "v18_aux" to b.v18Aux.size,
        "events" to b.events.size, "battery" to b.battery.size,
    )

    /**
     * EVERY stream on its own makes the batch non-empty. This is the exhaustive form of the #848 bug:
     * [StreamBatch.isEmpty] omitted one stream, and because `insert` early-returns on an empty batch, a
     * batch carrying ONLY that stream banked nothing on Android. A batch fixture can only catch that for
     * the streams it happens to populate; constructing a one-stream batch per stream catches it for all
     * of them. The cases are keyed by the oracle's stream names and cross-checked against the manifest,
     * so a stream added to [StreamBatch] without a case here fails `declaredStreams…` below.
     */
    @Test
    fun emptinessVerdictCoversEveryStream() {
        val oracle = loadOracle()
        val oneOf = mapOf(
            "hr" to StreamBatch(hr = listOf(HrRow(1L, 60))),
            "rr" to StreamBatch(rr = listOf(RrRow(1L, 900))),
            "spo2" to StreamBatch(spo2 = listOf(Spo2Row(1L, 1, 1))),
            "skin_temp" to StreamBatch(skinTemp = listOf(SkinTempRow(1L, 3000))),
            "resp" to StreamBatch(resp = listOf(RespRow(1L, 3000))),
            "gravity" to StreamBatch(gravity = listOf(GravityRow(1L, 0.0, 0.0, 1.0))),
            "steps" to StreamBatch(steps = listOf(StepRow(1L, 1))),
            "sleep_state" to StreamBatch(sleepState = listOf(SleepStateRow(1L, 2))),
            "ppg_hr" to StreamBatch(ppgHr = listOf(PpgHrRow(1L, 60, 0.5))),
            "ppg_waveform" to StreamBatch(ppgWaveform = listOf(PpgWaveformRow(1L, listOf(1, 2)))),
            // A FULL-LENGTH record, not a short one: EcgWaveformRow carries the inner record and the
            // insert path asserts R16_INNER_LENGTH, so a one-byte stand-in would pass here and fail
            // where it matters.
            "ecg_waveform" to StreamBatch(
                ecgWaveform = listOf(
                    EcgWaveformRow(1L, 1L, ByteArray(com.noop.protocol.Whoop5Ecg.R16_INNER_LENGTH)),
                ),
            ),
            // Carries a real slot value rather than a bare ts: V18AuxRow.isEmpty is "every slot is null",
            // so an all-null row would still make the LIST non-empty and pass this check while saying
            // nothing about a row that carries data.
            "v18_aux" to StreamBatch(v18Aux = listOf(V18AuxRow(1L, recordIndex = 1L))),
            "events" to StreamBatch(events = listOf(EventEntry(1L, "BOOT", "{}"))),
            "battery" to StreamBatch(battery = listOf(BatteryRow(1L, 50.0, 3900))),
        )
        assertEquals(
            "one-stream cases and the oracle's stream manifest disagree",
            stringSet(oracle.getJSONObject("coverage").getJSONArray("streams")),
            oneOf.keys.toSortedSet(),
        )
        assertTrue("a StreamBatch with no rows must be empty", StreamBatch().isEmpty)
        for ((stream, batch) in oneOf) {
            assertFalse(
                "StreamBatch carrying only '$stream' must NOT be empty , isEmpty gates the insert, " +
                    "so a stream missing from the verdict is silent data loss",
                batch.isEmpty,
            )
            assertEquals(
                "'$stream' case must populate exactly one row in exactly one stream",
                1,
                streamCounts(batch).values.sum(),
            )
        }
    }

    // MARK: - Layer 3: the oracle defends itself

    /**
     * The manifest and the fixtures must agree EXACTLY, in both directions. Without this, deleting an
     * `expect` key, a whole frame or a whole batch passes both suites and coverage silently shrinks.
     * Precedent: PR #848 needed a test that every storage slot's decoder key exists in a real decode,
     * because a rename had broken an extractor and nothing failed.
     */
    @Test
    fun oracleCoverageManifestMatchesFixtures() {
        val oracle = loadOracle()
        val cov = oracle.getJSONObject("coverage")
        val frames = oracle.getJSONArray("frames")
        val batches = oracle.getJSONArray("stream_batches")

        val frameNames = (0 until frames.length()).map { frames.getJSONObject(it).getString("name") }
        assertEquals(
            "coverage.frames must list every fixture frame, in order",
            (0 until cov.getJSONArray("frames").length()).map { cov.getJSONArray("frames").getString(it) },
            frameNames,
        )
        assertEquals(
            "coverage.batches must list every stream batch",
            stringSet(cov.getJSONArray("batches")),
            (0 until batches.length()).map { batches.getJSONObject(it).getString("name") }.toSortedSet(),
        )

        // Field -> how many frames assert it. Counting (not just naming) is what makes EVERY individual
        // assertion load-bearing: dropping `heart_rate` from one frame leaves the key set unchanged.
        val asserted = sortedMapOf<String, Int>()
        for (i in 0 until frames.length()) {
            for (key in frames.getJSONObject(i).getJSONObject("expect").keys()) {
                asserted[key] = (asserted[key] ?: 0) + 1
            }
        }
        val fieldsObj = cov.getJSONObject("fields")
        val fields = fieldsObj.keys().asSequence().associateWithTo(sortedMapOf()) { fieldsObj.getInt(it) }
        assertEquals(
            "coverage.fields must name every 'expect' key and how many frames assert it",
            fields,
            asserted,
        )
        val derived = stringSet(cov.getJSONArray("derived_fields"))
        assertTrue("coverage.derived_fields must be a subset of coverage.fields", fields.keys.containsAll(derived))

        // Every pinned batch pins EVERY stream, zeros included , otherwise "absent on one platform" and
        // "not asserted" are indistinguishable.
        val streams = stringSet(cov.getJSONArray("streams"))
        for (i in 0 until batches.length()) {
            val spec = batches.getJSONObject(i)
            val name = spec.getString("name")
            val expect = spec.getJSONObject("expect")
            val counts = expect.getJSONObject("counts")
            assertEquals(
                "$name: counts must pin every stream in coverage.streams",
                streams,
                counts.keys().asSequence().toSortedSet(),
            )
            assertEquals(
                "$name: pinned is_empty contradicts the pinned counts",
                counts.keys().asSequence().all { counts.getInt(it) == 0 },
                expect.getBoolean("is_empty"),
            )
        }

        // Every non-derived pinned field must appear in at least one REAL decode. A field that no
        // decoder emits any more would otherwise sit in the manifest looking covered.
        val seen = HashSet<String>()
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            val family =
                if (f.getString("family") == "whoop5") DeviceFamily.WHOOP5 else DeviceFamily.WHOOP4
            decodeHistorical(hexToBytes(f.getString("hex")), family)?.let { seen.addAll(it.keys) }
        }
        for (field in fields.keys - derived) {
            assertTrue(
                "coverage.fields lists '$field' but no fixture decode emits that key",
                seen.contains(field),
            )
        }
    }

    /**
     * The oracle's stream manifest must equal the list-typed fields [StreamBatch] actually declares.
     * This is the direction the manifest alone cannot cover: a NEW stream added to [StreamBatch] (and to
     * the emptiness verdict) but never given oracle counts would otherwise be invisible to every check
     * above. Diagnostics that are lists but deliberately excluded from the verdict are listed in
     * `coverage.non_stream_lists`. The Swift twin reflects `Streams` the same way.
     */
    @Test
    fun declaredStreamsMatchOracleManifest() {
        val cov = loadOracle().getJSONObject("coverage")
        val declared = StreamBatch::class.java.declaredFields
            .filter { List::class.java.isAssignableFrom(it.type) }
            .map { snakeCased(it.name) }
            .toSortedSet()
        val expected = (stringSet(cov.getJSONArray("streams")) +
            stringSet(cov.getJSONArray("non_stream_lists"))).toSortedSet()
        assertEquals(
            "StreamBatch declares list fields the oracle does not account for (or vice versa) , " +
                "add the new stream to coverage.streams and to every batch's counts",
            expected,
            declared,
        )
    }

    private fun stringSet(a: org.json.JSONArray): java.util.SortedSet<String> =
        (0 until a.length()).map { a.getString(it) }.toSortedSet()

    /** `sleepState` -> `sleep_state`. Digits never take a separator, so `spo2` stays `spo2`. */
    private fun snakeCased(s: String): String =
        s.map { if (it.isUpperCase()) "_${it.lowercaseChar()}" else "$it" }.joinToString("")

    /**
     * The Android and Swift copies of the oracle MUST be byte-identical, so neither platform can edit
     * its fixture without the other. We can read the Android copy off the test classpath; the Swift
     * copy lives in the source tree, located relative to the module dir via the `user.dir` the JVM
     * test runner is launched from. Skips gracefully (passes) if the Swift tree isn't present.
     */
    @Test
    fun oracleCopiesAreIdentical() {
        val androidBytes = javaClass.classLoader!!
            .getResourceAsStream("decoder_oracle.json")!!
            .use { it.readBytes() }

        // Gradle runs unit tests with the module dir (android/app) or repo root as user.dir; try both.
        val userDir = java.io.File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(
            java.io.File(userDir, "Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/decoder_oracle.json"),
            java.io.File(userDir, "../../Packages/WhoopProtocol/Tests/WhoopProtocolTests/Resources/decoder_oracle.json"),
        )
        val swiftFile = candidates.firstOrNull { it.exists() }
        org.junit.Assume.assumeTrue(
            "swift oracle copy not found from user.dir=$userDir , skipping cross-copy identity check",
            swiftFile != null,
        )
        val swiftBytes = swiftFile!!.readBytes()
        assertTrue(
            "decoder_oracle.json copies differ , keep the Android and Swift copies in lockstep",
            androidBytes.contentEquals(swiftBytes),
        )
    }
}
