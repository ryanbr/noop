package com.noop.protocol

import org.json.JSONObject
import org.junit.Assert.assertEquals
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
