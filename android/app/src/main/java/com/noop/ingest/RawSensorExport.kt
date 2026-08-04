package com.noop.ingest

import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast
import androidx.core.content.FileProvider
import com.noop.BuildConfig
import com.noop.data.WhoopRepository
import java.io.File
import java.util.Locale

/**
 * EXPERIMENTAL diagnostic: dump the decoded per-sample sensor streams NOOP already stores to ONE
 * combined long-format CSV (last 24 h) and share it. Lets power users / external devs prototype
 * sleep / activity / VBT algorithms on real data without a BLE stream (#308/#276/#322).
 *
 * Long format = one row per sample, with a `stream` discriminator and ONLY that stream's columns
 * filled (the rest blank). Streams: hr / rr / gravity / steps / ppghr / spo2 / skintemp / resp /
 * event. All rows are merged then sorted by ts ascending. Plain text only — never any BLE hex.
 *
 * The `hr` stream reads the RAW `hrSample` table (NOT WhoopDao.hrSamples, which COALESCE-unions in
 * the v26 PPG-derived HR); PPG HR is its own `ppghr` stream so a measured sensor HR is never
 * confused with a derived estimate. Columns and semantics MATCH the Swift exporter byte-for-byte:
 *   unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter,ppg_bpm,ppg_conf,
 *   spo2_red,spo2_ir,skintemp_raw,resp_raw,event_kind,event_payload
 *
 * On-device only — the file is written to cache/logs (the existing FileProvider path) and shared via
 * the same ACTION_SEND mechanism as the strap-log export; nothing leaves the phone unless shared.
 */
object RawSensorExport {

    /** 18 columns, in the contract order shared with the Swift exporter (band_sleep_state added, #175). */
    private const val HEADER =
        "unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter,ppg_bpm,ppg_conf," +
            "spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload"

    private val UTC_FMT: java.time.format.DateTimeFormatter =
        java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .withZone(java.time.ZoneOffset.UTC)

    private fun iso(epochSeconds: Long): String =
        UTC_FMT.format(java.time.Instant.ofEpochSecond(epochSeconds))

    // Locale-proof Double (always '.'); reuse the exporter's csvField for the one free-text column.
    private fun n(v: Double): String = WhoopCsvExporter.num(v)
    private fun n(v: Int): String = v.toString()

    /**
     * Read each stream for [deviceId] over [from, to] (inclusive, unix seconds), merge by ts ascending,
     * and STREAM the combined long-format CSV body straight through [out] (CSV header row first). A high
     * per-stream [limit] caps a runaway 24 h window without truncating a normal day. Returns a per-stream
     * count map.
     *
     * Memory: we hold one short CSV-line String per sample, sort by ts, and write each through [out]'s
     * buffer. The previous version built a multi-MB StringBuilder of the whole file AND then a second
     * full copy via `header + csv` before writing — on a busy 24 h window that doubling tipped the export
     * into an OutOfMemoryError (#406). Keeping only the raw query rows + one line each, and never
     * materialising the whole file as a String, holds peak allocation roughly to the data itself.
     */
    internal suspend fun writeCsv(
        out: java.io.Writer,
        repo: WhoopRepository,
        deviceId: String,
        from: Long,
        to: Long,
        limit: Int = 200_000,
    ): Map<String, Int> {
        // index: 0 hr_bpm,1 rr_ms,2 grav_x,3 grav_y,4 grav_z,5 step_counter,6 ppg_bpm,7 ppg_conf,
        //        8 spo2_red,9 spo2_ir,10 skintemp_raw,11 resp_raw,12 band_sleep_state,13 event_kind,14 event_payload
        val rows = ArrayList<LineRow>()
        val counts = LinkedHashMap<String, Int>()

        val hr = repo.rawHrSamples(deviceId, from, to, limit)
        counts["hr"] = hr.size
        for (s in hr) rows += LineRow(s.ts, line("hr", s.ts, 0 to n(s.bpm)))

        val rr = repo.rrIntervals(deviceId, from, to, limit)
        counts["rr"] = rr.size
        for (s in rr) rows += LineRow(s.ts, line("rr", s.ts, 1 to n(s.rrMs)))

        val grav = repo.gravitySamples(deviceId, from, to, limit)
        counts["gravity"] = grav.size
        for (s in grav) rows += LineRow(s.ts, line("gravity", s.ts, 2 to n(s.x), 3 to n(s.y), 4 to n(s.z)))

        val steps = repo.stepSamples(deviceId, from, to, limit)
        counts["steps"] = steps.size
        for (s in steps) rows += LineRow(s.ts, line("steps", s.ts, 5 to n(s.counter)))

        val ppg = repo.ppgHrSamples(deviceId, from, to, limit)
        counts["ppghr"] = ppg.size
        for (s in ppg) rows += LineRow(s.ts, line("ppghr", s.ts, 6 to n(s.bpm), 7 to n(s.conf)))

        val spo2 = repo.spo2Samples(deviceId, from, to, limit)
        counts["spo2"] = spo2.size
        for (s in spo2) rows += LineRow(s.ts, line("spo2", s.ts, 8 to n(s.red), 9 to n(s.ir)))

        val skin = repo.skinTempSamples(deviceId, from, to, limit)
        counts["skintemp"] = skin.size
        for (s in skin) rows += LineRow(s.ts, line("skintemp", s.ts, 10 to n(s.raw)))

        val resp = repo.respSamples(deviceId, from, to, limit)
        counts["resp"] = resp.size
        for (s in resp) rows += LineRow(s.ts, line("resp", s.ts, 11 to n(s.raw)))

        // Band sleep_state (#175): the strap's OWN @81 high-nibble state (0 wake/1 still/2 asleep/3 up),
        // carried verbatim. Column 12, before the event columns (matches the Swift exporter order).
        val sleepState = repo.sleepStateSamples(deviceId, from, to, limit)
        counts["band_sleep_state"] = sleepState.size
        for (s in sleepState) rows += LineRow(s.ts, line("band_sleep_state", s.ts, 12 to n(s.state)))

        val events = repo.events(deviceId, from, to, limit)
        counts["event"] = events.size
        for (s in events) rows += LineRow(
            s.ts,
            line("event", s.ts, 13 to WhoopCsvExporter.csvField(s.kind), 14 to WhoopCsvExporter.csvField(s.payloadJSON)),
        )

        // Stable sort by ts asc (a stream's intra-ts order is its query's secondary key).
        rows.sortBy { it.ts }
        out.write(HEADER); out.write("\n")
        for (r in rows) { out.write(r.line); out.write("\n") }
        return counts
    }

    /** ts + the fully-formatted CSV line for one sample (kept small so a whole day fits in memory). */
    private class LineRow(val ts: Long, val line: String)

    /** Build one CSV line: `unix_s,iso_utc,stream` + the 15 value cells (only [set] indices filled). */
    private fun line(stream: String, ts: Long, vararg set: Pair<Int, String>): String {
        val sb = StringBuilder(96)
        sb.append(ts).append(',').append(iso(ts)).append(',').append(stream)
        for (i in 0 until 15) {
            sb.append(',')
            for ((idx, v) in set) if (idx == i) { sb.append(v); break }
        }
        return sb.toString()
    }

    /**
     * Build the last-24 h CSV for the strap source and fire a share sheet (text/csv). Runs the DB read
     * off the main thread; toasts a per-stream summary so the user sees what was captured (and that the
     * deeper 5/MG streams are empty until they've been unlocked). On-device only.
     *
     * [deviceId] is REQUIRED, deliberately. It used to default to the canonical "my-whoop", and the one
     * caller took the default — so after a strap re-add this exported the legacy id's streams rather than
     * the strap the user is actually wearing, silently, in the CSV people attach to bug reports. That is
     * the #172/#175 defect exactly: a defaulted strap id that no caller overrides. Removing the default
     * makes the compiler ask, which is stronger than remembering. (Ported from tanarchytan/noop e4f508f.)
     */
    suspend fun export(context: Context, repo: WhoopRepository, deviceId: String) {
        runCatching {
            val now = System.currentTimeMillis() / 1000
            val dir = File(context.cacheDir, "logs").apply { mkdirs() }
            val file = File(dir, "noop-raw-sensors.csv")
            // Stream straight to disk through an 8 KB buffer — never hold the whole CSV as a String (#406).
            val counts = file.bufferedWriter().use { w ->
                w.append("# NOOP raw sensor export · last 24h · long-format CSV\n")
                w.append("# App: ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER}) · Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}\n")
                w.append("# One row per decoded sample; only the row's `stream` columns are filled. Times are UTC.\n")
                writeCsv(w, repo, deviceId, now - 86_400, now)
            }

            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "NOOP raw sensor export")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Export raw sensor data"))

            val total = counts.values.sum()
            val summary = if (total == 0) {
                "No samples in the last 24h - wear the strap and let it sync, then export again."
            } else {
                // Compact "hr 3204 · rr 812 · …" line, only non-empty streams.
                counts.filterValues { it > 0 }.entries.joinToString(" · ") { "${it.key} ${it.value}" }
            }
            Toast.makeText(context, summary, Toast.LENGTH_LONG).show()
        }.onFailure {
            Toast.makeText(context, "Couldn't export sensor data: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}
