package com.noop.ingest

import java.io.ByteArrayOutputStream
import java.time.Instant
import kotlin.math.roundToLong

/**
 * Export a recorded GPS workout route to a standard interchange file (GPX 1.1 or FIT), the sibling of
 * [ActivityFileImporter]. Pure JVM — no Android/Room/UI types — so it unit-tests off-device and stays the
 * byte-for-byte twin of the Swift `RouteExporter` in `Packages/StrandImport`.
 *
 * FIDELITY NOTE: the stored route ([com.noop.analytics.RouteMath] polyline) is lat/lon ONLY — no per-point
 * timestamp, elevation, speed, or HR is persisted (see the workout's `routePolyline`). So an export carries
 * the lat/lon track plus per-point timestamps INTERPOLATED evenly across the workout window
 * [startTs, endTs] (total duration is exact; instantaneous pace is not), and workout-level metadata
 * (sport, distance, calories, avg/max HR). That's the honest maximum from what's stored, and it's what
 * Strava / Garmin Connect need to read the track back as a timed activity.
 */
object RouteExport {

    /** One route point — lat/lon only, matching the stored polyline. */
    data class Point(val lat: Double, val lon: Double)

    enum class Format(val ext: String, val label: String) {
        GPX("gpx", "GPX"),
        FIT("fit", "FIT"),
    }

    /** Seconds between the Unix epoch and the FIT epoch (1989-12-31T00:00:00Z). */
    private const val FIT_EPOCH = 631_065_600L

    /** Semicircles per degree — the FIT position unit: `semicircles = degrees × 2^31 / 180`. */
    private const val SEMI_PER_DEG = 2_147_483_648.0 / 180.0

    // ── Public API ──────────────────────────────────────────────────────────────────────────────────

    fun render(
        format: Format,
        points: List<Point>,
        startTs: Long,
        endTs: Long,
        sport: String?,
        distanceM: Double? = null,
        energyKcal: Double? = null,
        avgHr: Int? = null,
        maxHr: Int? = null,
    ): ByteArray = when (format) {
        Format.GPX -> buildGpx(points, startTs, endTs, sport, distanceM).toByteArray(Charsets.UTF_8)
        Format.FIT -> buildFit(points, startTs, endTs, sport, distanceM, energyKcal, avgHr, maxHr)
    }

    /** GPX 1.1 track. Each `trkpt` carries lat/lon + an interpolated `time`; no `ele`/HR (none stored). */
    fun buildGpx(
        points: List<Point>,
        startTs: Long,
        endTs: Long,
        sport: String?,
        distanceM: Double? = null,
    ): String {
        val canon = canonicalSport(sport)
        val times = interpolatedTimes(points.size, startTs, endTs)
        val sb = StringBuilder(256 + points.size * 96)
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<gpx version=\"1.1\" creator=\"NOOP\" ")
        sb.append("xmlns=\"http://www.topografix.com/GPX/1/1\">\n")
        sb.append("  <metadata>\n    <time>").append(iso(startTs)).append("</time>\n  </metadata>\n")
        sb.append("  <trk>\n")
        sb.append("    <name>").append(xmlEscape(displaySport(canon))).append("</name>\n")
        sb.append("    <type>").append(xmlEscape(canon)).append("</type>\n")
        sb.append("    <trkseg>\n")
        for (i in points.indices) {
            val p = points[i]
            sb.append("      <trkpt lat=\"").append(coord(p.lat)).append("\" lon=\"").append(coord(p.lon))
                .append("\"><time>").append(iso(times[i])).append("</time></trkpt>\n")
        }
        sb.append("    </trkseg>\n  </trk>\n</gpx>\n")
        return sb.toString()
    }

    /** A minimal but well-formed FIT activity file: file_id, one record per point, lap, session,
     *  activity, and the trailing CRC-16. Decodes back through [ActivityFileImporter]/FIT and imports into
     *  Strava / Garmin Connect. */
    fun buildFit(
        points: List<Point>,
        startTs: Long,
        endTs: Long,
        sport: String?,
        distanceM: Double? = null,
        energyKcal: Double? = null,
        avgHr: Int? = null,
        maxHr: Int? = null,
    ): ByteArray {
        val canon = canonicalSport(sport)
        val times = interpolatedTimes(points.size, startTs, endTs)
        val body = ByteArrayOutputStream(64 + points.size * 14)

        // ── file_id (global 0): type=activity, manufacturer=development, time_created ──
        body.defn(0, 0, listOf(F(0, 1, 0x00), F(1, 2, 0x84), F(4, 4, 0x86)))
        body.write(0)                 // local type 0 data header
        body.u8(4)                    // type = activity
        body.u16(255)                 // manufacturer = development
        body.u32(fitTime(startTs))

        // ── record (global 20): timestamp + position ──
        body.defn(1, 20, listOf(F(253, 4, 0x86), F(0, 4, 0x85), F(1, 4, 0x85)))
        for (i in points.indices) {
            body.write(1)             // local type 1 data header
            body.u32(fitTime(times[i]))
            body.s32(semicircles(points[i].lat))
            body.s32(semicircles(points[i].lon))
        }

        val elapsedMs = ((endTs - startTs).coerceAtLeast(0)) * 1000L
        val distCenti = distanceM?.let { (it * 100.0).roundToLong().coerceAtLeast(0) }

        // ── lap (global 19) ── (external tools expect at least one; our decoder folds it under session).
        // Distance uses the FIT 0xFFFFFFFF "invalid" value when absent — the decoder special-cases it.
        body.defn(2, 19, listOf(F(253, 4, 0x86), F(2, 4, 0x86), F(7, 4, 0x86), F(9, 4, 0x86)))
        body.write(2)
        body.u32(fitTime(endTs)); body.u32(fitTime(startTs)); body.u32(elapsedMs)
        body.u32(distCenti ?: 0xFFFFFFFFL)

        // ── session (global 18): the authoritative summary the importer reads. ONLY the fields we
        // actually have are emitted — an absent HR must be truly absent, since the importer's validHr
        // accepts 1..300 and would misread a 0xFF sentinel as a real HR of 255. ──
        val sf = ArrayList<F>(8)
        val sd = ByteArrayOutputStream(28)
        sf.add(F(253, 4, 0x86)); sd.u32(fitTime(endTs))
        sf.add(F(2, 4, 0x86)); sd.u32(fitTime(startTs))
        sf.add(F(7, 4, 0x86)); sd.u32(elapsedMs)
        sf.add(F(5, 1, 0x00)); sd.u8(fitSport(canon))
        if (distCenti != null) { sf.add(F(9, 4, 0x86)); sd.u32(distCenti) }
        energyKcal?.let { sf.add(F(11, 2, 0x84)); sd.u16(it.roundToLong().coerceIn(0, 0xFFFEL).toInt()) }
        avgHr?.let { sf.add(F(16, 1, 0x02)); sd.u8(it.coerceIn(0, 254)) }
        maxHr?.let { sf.add(F(17, 1, 0x02)); sd.u8(it.coerceIn(0, 254)) }
        body.defn(3, 18, sf)
        body.write(3)
        body.write(sd.toByteArray())

        // ── activity (global 34): one session ──
        body.defn(4, 34, listOf(F(253, 4, 0x86), F(1, 2, 0x84), F(2, 1, 0x00)))
        body.write(4)
        body.u32(fitTime(endTs)); body.u16(1); body.u8(0)

        val bodyBytes = body.toByteArray()

        // ── 12-byte header + body + CRC-16 over header+body ──
        val out = ByteArrayOutputStream(14 + bodyBytes.size + 2)
        out.u8(12)                    // header size
        out.u8(0x20)                  // protocol version 2.0
        out.u16(2140)                 // profile version 21.40
        out.u32(bodyBytes.size.toLong())
        out.write(byteArrayOf('.'.code.toByte(), 'F'.code.toByte(), 'I'.code.toByte(), 'T'.code.toByte()))
        out.write(bodyBytes)
        val crc = fitCrc(out.toByteArray())
        out.u16(crc)
        return out.toByteArray()
    }

    // ── Timing / units ────────────────────────────────────────────────────────────────────────────────

    /** Per-point Unix seconds, spread evenly across [startTs, endTs] (start for a single point). */
    internal fun interpolatedTimes(n: Int, startTs: Long, endTs: Long): LongArray {
        if (n <= 0) return LongArray(0)
        if (n == 1) return longArrayOf(startTs)
        val span = (endTs - startTs).coerceAtLeast(0).toDouble()
        return LongArray(n) { i -> startTs + (span * i / (n - 1)).roundToLong() }
    }

    private fun fitTime(unix: Long): Long = (unix - FIT_EPOCH).coerceIn(0, 0xFFFFFFFFL)

    private fun semicircles(deg: Double): Int =
        (deg * SEMI_PER_DEG).roundToLong().coerceIn(Int.MIN_VALUE.toLong(), Int.MAX_VALUE.toLong()).toInt()

    /** ISO-8601 UTC to whole seconds, e.g. `2026-08-11T04:47:38Z`. */
    private fun iso(unix: Long): String = Instant.ofEpochSecond(unix).toString()

    /** Fixed 6-dp coordinate — well beyond the polyline's ~1 m (precision-5) resolution. */
    private fun coord(v: Double): String = String.format(java.util.Locale.US, "%.6f", v)

    // ── Sport mapping ───────────────────────────────────────────────────────────────────────────────

    /** Collapse a free-form sport string to one canonical key (the GPS-relevant families). */
    internal fun canonicalSport(sport: String?): String {
        val s = (sport ?: "").lowercase(java.util.Locale.US).trim()
        return when (s) {
            "", "other" -> "other"
            "run", "running", "jog", "jogging", "treadmill" -> "run"
            "cycle", "cycling", "bike", "biking", "ride", "spinning" -> "cycle"
            "walk", "walking", "rucking" -> "walk"
            "hike", "hiking" -> "hike"
            "swim", "swimming" -> "swim"
            else -> s
        }
    }

    private fun displaySport(canon: String): String =
        canon.replaceFirstChar { if (it.isLowerCase()) it.titlecase(java.util.Locale.US) else it.toString() }

    /** FIT `sport` enum (session field 5). Round-trips through the importer's `sportName`. */
    private fun fitSport(canon: String): Int = when (canon) {
        "run" -> 1
        "cycle" -> 2
        "swim" -> 5
        "walk" -> 11
        "hike" -> 15
        else -> 0
    }

    // ── XML / byte helpers ────────────────────────────────────────────────────────────────────────────

    private fun xmlEscape(s: String): String {
        val sb = StringBuilder(s.length + 8)
        for (c in s) when (c) {
            '&' -> sb.append("&amp;")
            '<' -> sb.append("&lt;")
            '>' -> sb.append("&gt;")
            '"' -> sb.append("&quot;")
            '\'' -> sb.append("&apos;")
            else -> sb.append(c)
        }
        return sb.toString()
    }

    /** A FIT field definition (field number, byte size, base-type byte). */
    private data class F(val num: Int, val size: Int, val baseType: Int)

    /** Emit a FIT definition message for [localType]/[globalNum] with [fields] (little-endian). */
    private fun ByteArrayOutputStream.defn(localType: Int, globalNum: Int, fields: List<F>) {
        u8(0x40 or (localType and 0x0F)) // definition record header
        u8(0)                            // reserved
        u8(0)                            // architecture: 0 = little-endian
        u16(globalNum)
        u8(fields.size)
        for (f in fields) { u8(f.num); u8(f.size); u8(f.baseType) }
    }

    private fun ByteArrayOutputStream.u8(v: Int) = write(v and 0xFF)
    private fun ByteArrayOutputStream.u16(v: Int) { write(v and 0xFF); write((v ushr 8) and 0xFF) }
    private fun ByteArrayOutputStream.u32(v: Long) {
        write((v and 0xFF).toInt()); write(((v ushr 8) and 0xFF).toInt())
        write(((v ushr 16) and 0xFF).toInt()); write(((v ushr 24) and 0xFF).toInt())
    }
    private fun ByteArrayOutputStream.s32(v: Int) = u32(v.toLong() and 0xFFFFFFFFL)

    /** The standard FIT CRC-16 (nibble-table variant), computed over [data]. */
    internal fun fitCrc(data: ByteArray): Int {
        val table = intArrayOf(
            0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
            0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
        )
        var crc = 0
        for (b in data) {
            var tmp = table[crc and 0xF]
            crc = (crc ushr 4) and 0x0FFF
            crc = crc xor tmp xor table[b.toInt() and 0xF]
            tmp = table[crc and 0xF]
            crc = (crc ushr 4) and 0x0FFF
            crc = crc xor tmp xor table[(b.toInt() ushr 4) and 0xF]
        }
        return crc and 0xFFFF
    }
}
