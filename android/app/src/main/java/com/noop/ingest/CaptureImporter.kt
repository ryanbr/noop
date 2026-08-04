package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.ble.PuffinExperiment
import com.noop.ble.RawHistoryArchive
import com.noop.ble.WhoopBleClient
import com.noop.data.ImportSummary
import com.noop.data.InsertCounts
import com.noop.data.StreamBatch
import com.noop.data.WhoopRepository
import com.noop.protocol.DeviceFamily
import com.noop.protocol.extractHistoricalStreams
import com.noop.protocol.rejectedHistoricalRecords
import org.json.JSONException
import org.json.JSONObject
import java.io.Reader
import java.io.StringReader
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit

/**
 * Imports a `capture.json` produced by Tools/linux-capture/whoop_sync.py `export` into the local
 * Room store by running its raw strap frames through the SAME on-device historical decoder the live
 * BLE offload uses (extractHistoricalStreams -> WhoopRepository.insert). No new decode logic; this is
 * pure file -> frames -> decode -> store plumbing, so externally-captured history (e.g. a Linux BLE
 * offload) lands in the app exactly as if synced over Bluetooth.
 *
 * capture.json shape (one object per stored frame):
 *   [{"hex":"aa50...","char":"61080003-...","ts_ms":1718...,"hr":75}, ...]
 * `char` is the strap's notify-characteristic UUID; its family marker ("6108"->WHOOP4, "fd4b"->WHOOP5)
 * selects the decoder. ts_ms/hr are informational; decode uses each record's embedded unix.
 *
 * UNTRUSTED INPUT. A `capture.json` is a user-supplied file, not a live BLE stream, so the parse path
 * treats it defensively: a hard cap on bytes scanned ([MAX_CHARS]) and on frames kept ([MAX_FRAMES]),
 * a per-frame hex-length ceiling ([MAX_FRAME_BYTES]), strict hex validation, and the same offload
 * filter the live path uses — so a malformed or oversized file is bounded and rejected, never able to
 * exhaust memory or push junk frames into the decoder. It NEVER touches the live BLE analyze path.
 *
 * parse/decode/summarize are pure so they are JVM unit-testable (CaptureImporterTest); only
 * importCapture touches the SAF Uri / Room / reject archive.
 */
/** A multi-day capture is tens of MB; 256 M chars is a generous ceiling against a runaway file.
 *  File-level so the [JsonArrayScanner] (a separate top-level class below) shares the same cap. */
private const val MAX_CHARS = 256L shl 20

object CaptureImporter {
    const val SOURCE_LABEL = "Raw capture"

    /** Historical data attaches to the seeded primary WHOOP device so the dashboard shows it. */
    const val DEFAULT_DEVICE_ID = "my-whoop"

    /** Hard cap on frames kept from one file (~a year of dense offload is well under this). */
    private const val MAX_FRAMES = 5_000_000

    /** A real strap frame is well under this; a longer hex string is junk and is skipped. */
    private const val MAX_FRAME_BYTES = 512

    // ---- pure: char -> family ----

    /** Map a stored notify-characteristic UUID to its device family. Null = unrecognised. */
    internal fun familyForChar(char: String?): DeviceFamily? {
        val c = char?.lowercase() ?: return null
        return when {
            c.contains("fd4b") -> DeviceFamily.WHOOP5
            c.contains("6108") -> DeviceFamily.WHOOP4
            else -> null
        }
    }

    /**
     * Lenient hex -> bytes. Returns null on odd length, a non-hex char, or a frame longer than
     * [MAX_FRAME_BYTES] (an over-long hex string in an untrusted file is junk, not a real frame).
     */
    internal fun hexToBytes(hex: String): ByteArray? {
        val s = hex.trim()
        if (s.isEmpty() || s.length % 2 != 0 || s.length / 2 > MAX_FRAME_BYTES) return null
        val out = ByteArray(s.length / 2)
        var i = 0
        while (i < s.length) {
            val hi = Character.digit(s[i], 16)
            val lo = Character.digit(s[i + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i / 2] = ((hi shl 4) or lo).toByte()
            i += 2
        }
        return out
    }

    // ---- pure: parse capture.json ----

    /** Frames grouped by family, with bookkeeping counts. */
    data class Parsed(
        val byFamily: Map<DeviceFamily, List<ByteArray>>,
        val totalFrames: Int,
        val skipped: Int, // unknown-char or unparsable-hex rows
        val truncated: Boolean = false, // hit MAX_FRAMES; later frames were dropped
    )

    /** Parse capture.json text into per-family frame lists. Throws org.json.JSONException on non-array input. */
    fun parse(jsonText: String): Parsed = parse(StringReader(jsonText))

    /**
     * Streaming parse: pull one top-level JSON value at a time off [reader] so a multi-day capture
     * (tens of MB, hundreds of thousands of frames) never materialises as a giant String + JSONArray.
     * Peak memory is the per-family ByteArray lists plus one element substring — not the whole file.
     * Throws org.json.JSONException on non-array / malformed input, exactly like the old DOM parse.
     *
     * Bounded against an untrusted file: the scanner caps total bytes read ([MAX_CHARS]) and the
     * accepted-frame count ([MAX_FRAMES]); past the frame cap it stops keeping frames and flags the
     * result `truncated` (rather than throwing) so a partial import still lands.
     */
    fun parse(reader: Reader): Parsed {
        val groups = LinkedHashMap<DeviceFamily, MutableList<ByteArray>>()
        var total = 0
        var skipped = 0
        var kept = 0
        var truncated = false
        JsonArrayScanner(reader).forEachElement { elem ->
            if (kept >= MAX_FRAMES) { truncated = true; return@forEachElement }
            val obj = elem.asJsonObjectOrNull()
            if (obj == null) { skipped++; return@forEachElement }
            total++
            val family = familyForChar(if (obj.has("char")) obj.optString("char") else null)
            val frame = if (obj.has("hex")) hexToBytes(obj.optString("hex")) else null
            if (family == null || frame == null) { skipped++; return@forEachElement }
            groups.getOrPut(family) { ArrayList() }.add(frame)
            kept++
        }
        return Parsed(groups, total, skipped, truncated)
    }

    /** A top-level array element is a frame only if it is a JSON object; everything else is skipped
     *  (matches the old `JSONArray.optJSONObject(i) == null` behaviour). A malformed object throws. */
    private fun String.asJsonObjectOrNull(): JSONObject? =
        if (trimStart().startsWith("{")) JSONObject(this) else null

    // ---- pure: decode ----

    /** Decoded streams plus the frames that failed to decode (to be reject-archived), per family. */
    data class Decoded(
        val batches: Map<DeviceFamily, StreamBatch>,
        val rejects: Map<DeviceFamily, List<ByteArray>>,
        val offloadFrames: Int,
    )

    /**
     * Filter each family's frames to offload frames (drops realtime/control), then decode in a single
     * pass per family via extractHistoricalStreams with clockRef 0/0 — historical records carry an
     * embedded unix, exactly as RawHistoryArchive.replayIfNeeded decodes archived frames.
     *
     * [ppgHrSubLagInterp] threads the opt-in "HR-from-PPG sub-lag interpolation" flag (Test Centre →
     * Experimental algorithms) into the v26 PPG-HR estimator, so an imported capture re-derives v26 HR
     * with the same variant the live offload / archive replay use. Kept a pure param (not a prefs read
     * inside this pure decode) so it stays JVM unit-testable; the importCapture caller supplies it.
     * Default false = byte-identical to today.
     */
    fun decode(parsed: Parsed, ppgHrSubLagInterp: Boolean = false): Decoded {
        val batches = LinkedHashMap<DeviceFamily, StreamBatch>()
        val rejects = LinkedHashMap<DeviceFamily, List<ByteArray>>()
        var offload = 0
        for ((family, frames) in parsed.byFamily) {
            val offloadFrames = frames.filter { WhoopBleClient.isOffloadFrame(it, family) }
            if (offloadFrames.isEmpty()) continue
            offload += offloadFrames.size
            val batch = extractHistoricalStreams(
                offloadFrames, 0, 0, family,
                ppgHrSubLagInterp = ppgHrSubLagInterp,
            )
            if (!batch.isEmpty) batches[family] = batch
            val rej = rejectedHistoricalRecords(offloadFrames, family)
            if (rej.isNotEmpty()) rejects[family] = rej
        }
        return Decoded(batches, rejects, offload)
    }

    // ---- pure: summarize ----

    private val DAY: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC)

    /** Build the user-facing ImportSummary from decode output + the rows actually inserted. */
    fun summarize(decoded: Decoded, inserted: InsertCounts, parsed: Parsed): ImportSummary {
        val counts = linkedMapOf(
            "hr" to inserted.hr, "rr" to inserted.rr, "gravity" to inserted.gravity,
            "spo2" to inserted.spo2, "skinTemp" to inserted.skinTemp, "resp" to inserted.resp,
            "steps" to inserted.steps, "events" to inserted.events, "battery" to inserted.battery,
        ).filterValues { it > 0 }

        val allTs = decoded.batches.values.flatMap { b -> b.hr.map { it.ts } + b.gravity.map { it.ts } }
        val first = allTs.minOrNull()?.let { DAY.format(Instant.ofEpochSecond(it)) }
        val last = allTs.maxOrNull()?.let { DAY.format(Instant.ofEpochSecond(it)) }
        val rejectCount = decoded.rejects.values.sumOf { it.size }
        val total = counts.values.sum()

        val message = buildString {
            append("Imported $total rows from ${decoded.offloadFrames} historical frames")
            if (first != null && last != null) append(" ($first → $last)")
            append(".")
            if (parsed.skipped > 0) append(" Skipped ${parsed.skipped} unrecognised frame(s).")
            if (rejectCount > 0) append(" Archived $rejectCount undecodable frame(s) for a future decoder.")
            if (parsed.truncated) append(" File was very large - imported the first ${MAX_FRAMES} frames only.")
        }
        return ImportSummary(SOURCE_LABEL, counts, first, last, message)
    }

    private fun InsertCounts.plus(o: InsertCounts) = InsertCounts(
        hr = hr + o.hr, rr = rr + o.rr, events = events + o.events, battery = battery + o.battery,
        spo2 = spo2 + o.spo2, skinTemp = skinTemp + o.skinTemp, steps = steps + o.steps,
        resp = resp + o.resp, gravity = gravity + o.gravity,
    )

    // ---- pure: import-rescore window ----
    //
    // Kept in this self-contained importer (not AppViewModel) so the Data Sources screen can wire the
    // whole feature with ONE call into this object plus its own analyze trigger: it passes the import's
    // firstDay through analyzeWindowDays() to size the post-import rescore. Nothing here imports the UI.

    /** Default analyze look-back (days) — the recent window the loop scores each pass. */
    const val ANALYZE_DEFAULT_MAX_DAYS = 21

    /** Upper bound on the import-rescore look-back, in days (~2 years). */
    const val ANALYZE_MAX_DAYS = 730

    /**
     * How many days back from [today] an import-triggered analyze pass must cover so a freshly imported
     * capture is actually scored. The recompute loop normally only looks at the recent [minDays] window;
     * an OLD historical import (the whole point of the raw-capture importer) needs the window widened to
     * reach its first imported day ([sinceDay], "yyyy-MM-dd"), plus a small buffer, clamped to [maxDays].
     * A null/unparseable/future [sinceDay] falls back to [minDays] (never negative or zero).
     */
    fun analyzeWindowDays(
        sinceDay: String?,
        today: LocalDate,
        minDays: Int = ANALYZE_DEFAULT_MAX_DAYS,
        maxDays: Int = ANALYZE_MAX_DAYS,
    ): Int {
        val since = sinceDay?.let {
            try { LocalDate.parse(it) } catch (_: DateTimeParseException) { null }
        } ?: return minDays
        val span = ChronoUnit.DAYS.between(since, today) // > 0 when sinceDay is in the past
        if (span <= 0) return minDays
        return (span + 2).coerceIn(minDays.toLong(), maxDays.toLong()).toInt()
    }

    // ---- IO: the entry the UI calls ----

    /**
     * Read the SAF [uri] capture.json, decode it, insert decoded streams under [deviceId], and
     * reject-archive undecodable frames. Idempotent: re-importing dedupes via Room natural keys.
     *
     * The file is parsed by STREAMING one frame object at a time off the SAF input stream (see
     * [parse]); a multi-day capture is never loaded whole into a String + JSONArray, which used to
     * OOM (a 74 MB capture needs ~150 MB just for the UTF-16 String, before the DOM on top). The
     * stream is bounded (size + frame-count caps) since the file is untrusted user input.
     */
    suspend fun importCapture(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        archive: RawHistoryArchive,
        deviceId: String = DEFAULT_DEVICE_ID,
    ): ImportSummary {
        val parsed = try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                input.bufferedReader(Charsets.UTF_8).use { parse(it) }
            } ?: return ImportSummary.failure(SOURCE_LABEL, "Could not open the file.")
        } catch (e: JSONException) {
            return ImportSummary.failure(
                SOURCE_LABEL, "Not a valid capture.json (expected a JSON array of frames).",
            )
        } catch (e: SecurityException) {
            return ImportSummary.failure(SOURCE_LABEL, "No permission to read that file.")
        } catch (e: Exception) {
            return ImportSummary.failure(SOURCE_LABEL, "Could not read the file: ${e.message ?: "unknown error"}")
        }

        // Test Centre → Experimental algorithms: re-derive v26 PPG-HR with the opt-in sub-lag interpolation
        // variant when the user has it on, matching the live offload / archive replay. Default OFF.
        val decoded = decode(parsed, ppgHrSubLagInterp = PuffinExperiment.from(context).ppgHrSubLagInterp)

        // Reject-archive undecodable offload frames FIRST — before the empty-batch early return — so a
        // capture the current decoder can't map yet (e.g. a future record layout) is still preserved
        // for a later release, exactly as the live offload archives undecodable history before acking.
        for ((family, rej) in decoded.rejects) {
            runCatching { archive.append(rej, trim = 0, family = family) }
        }

        if (decoded.batches.isEmpty()) {
            val archived = decoded.rejects.values.sumOf { it.size }
            return if (archived == 0) {
                ImportSummary.failure(SOURCE_LABEL, "No historical WHOOP frames found in this file.")
            } else {
                ImportSummary.failure(
                    SOURCE_LABEL,
                    "No frames could be decoded yet; archived $archived undecodable frame(s) for a future decoder.",
                )
            }
        }

        var totals = InsertCounts()
        for ((_, batch) in decoded.batches) {
            totals = totals.plus(repo.insert(batch, deviceId))
        }
        return summarize(decoded, totals, parsed)
    }
}

/**
 * Minimal streaming reader over a JSON array of objects. Pulls one top-level element at a time so a
 * huge capture.json is processed incrementally instead of buffered whole. It is a SPLITTER, not a full
 * JSON parser: it slices each top-level value into a substring (respecting strings, escapes and nested
 * braces/brackets) and hands that to org.json's [JSONObject] for the actual field parsing — so the
 * field semantics stay identical to the old DOM path, only the array iteration is streamed.
 *
 * Throws [JSONException] on non-array or truncated input, matching the old `JSONArray(text)` contract,
 * and on a file whose byte count exceeds the cap (untrusted-input guard).
 */
private class JsonArrayScanner(reader: Reader) {
    private val r: Reader = reader.buffered()
    private var pushed = NO_CHAR
    private var consumed = 0L

    private fun read(): Int {
        if (pushed != NO_CHAR) { val c = pushed; pushed = NO_CHAR; return c }
        val c = r.read()
        if (c >= 0 && ++consumed > MAX_CHARS) throw JSONException("capture.json exceeds size limit")
        return c
    }

    private fun pushback(c: Int) { pushed = c }

    private fun skipWhitespace(): Int {
        while (true) {
            val c = read()
            if (c == -1 || !Character.isWhitespace(c)) return c
        }
    }

    /** Invoke [onElement] with each top-level array element as a raw JSON substring. */
    fun forEachElement(onElement: (String) -> Unit) {
        if (skipWhitespace() != '['.code) throw JSONException("Expected a JSON array of frames")
        while (true) {
            val c = skipSeparators()
            when (c) {
                ']'.code -> return
                -1 -> throw JSONException("Unterminated JSON array")
                else -> onElement(readValue(c))
            }
        }
    }

    /** Skip whitespace and element-separating commas; return the next significant char (or -1/']'). */
    private fun skipSeparators(): Int {
        while (true) {
            val c = skipWhitespace()
            if (c != ','.code) return c
        }
    }

    /** Read one complete JSON value whose first char is [first]; return it verbatim. */
    private fun readValue(first: Int): String {
        val sb = StringBuilder()
        sb.append(first.toChar())
        when (first.toChar()) {
            '{', '[' -> {
                var depth = 1
                var inString = false
                var escape = false
                while (depth > 0) {
                    val c = read()
                    if (c == -1) throw JSONException("Unterminated JSON value")
                    val ch = c.toChar()
                    sb.append(ch)
                    when {
                        escape -> escape = false
                        inString -> when (ch) { '\\' -> escape = true; '"' -> inString = false }
                        ch == '"' -> inString = true
                        ch == '{' || ch == '[' -> depth++
                        ch == '}' || ch == ']' -> depth--
                    }
                }
            }
            '"' -> {
                var escape = false
                while (true) {
                    val c = read()
                    if (c == -1) throw JSONException("Unterminated JSON string")
                    val ch = c.toChar()
                    sb.append(ch)
                    when {
                        escape -> escape = false
                        ch == '\\' -> escape = true
                        ch == '"' -> return sb.toString()
                    }
                }
            }
            else -> { // bare scalar: number / true / false / null — ends at ws, comma or ']'
                while (true) {
                    val c = read()
                    if (c == -1) break
                    val ch = c.toChar()
                    if (Character.isWhitespace(c) || ch == ',' || ch == ']') { pushback(c); break }
                    sb.append(ch)
                }
            }
        }
        return sb.toString()
    }

    companion object {
        private const val NO_CHAR = -2
    }
}
