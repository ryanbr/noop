package com.noop.ui

import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.Toast
import androidx.core.content.FileProvider
import com.noop.BuildConfig
import com.noop.ble.PuffinExperiment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Shares the strap connection log as a plain-text file so users can attach it to a bug report.
 *
 * Android's `Log.d` output isn't reachable without adb, which is why people on issues #17/#18
 * couldn't share what was happening on their strap. [com.noop.ble.WhoopBleClient] now keeps an
 * in-memory ring buffer (`exportLogText()`); this writes it to a cache file and fires a share sheet.
 */
object LogExport {

    /**
     * A short `yyMMdd-HHmm` wall-clock stamp for export filenames (#510 — maddognik's protocol RE), so
     * a reporter who shares several strap logs / raw captures in a row gets sortable, non-colliding
     * files (e.g. `noop-strap-log-260617-1042.txt`). Locale-independent (US/POSIX) so the stamp is
     * stable on every device. Matches the Swift `FileExport.timestamp()`.
     */
    fun timestamp(): String =
        java.text.SimpleDateFormat("yyMMdd-HHmm", java.util.Locale.US)
            .format(System.currentTimeMillis())

    /**
     * A full `YYYYMMDD-HHMMSS` wall-clock stamp for the SCHEDULED daily auto-export (#510, maddognik), so
     * a day-after-day run drops sortable, second-precise, non-colliding files:
     * `noop-straplog-20260617-070000.txt` (and the raw `.bin` alongside). Distinct from [timestamp]
     * (minute-precision, for interactive shares) because the scheduler can fire twice in the same minute
     * across a reschedule and we never want one auto-export to clobber another. Locale-independent so the
     * stamp is identical on every device. Injectable epoch purely for the unit test.
     */
    fun exportStamp(nowMs: Long = System.currentTimeMillis()): String =
        java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(nowMs)

    /** The scheduled-export filenames, kept together so the formatter + extensions live in one place. */
    fun strapLogFilename(nowMs: Long = System.currentTimeMillis()) = "noop-straplog-${exportStamp(nowMs)}.txt"
    fun rawCaptureFilename(nowMs: Long = System.currentTimeMillis()) = "noop-straplog-${exportStamp(nowMs)}.bin"

    /**
     * Profile-tagged, self-describing bundle filename: `noop-<profile>-<platform>-v<version>-<yyMMdd-HHmm>.zip`
     * (spec section 5.1). Twin of the Swift `FileExport.bundleName`. Self-describing so a maintainer knows
     * the profile, platform and version before opening the zip. Uses the same minute-precision [timestamp]
     * the interactive shares use. Injectable epoch purely for the unit test.
     */
    fun bundleName(profile: String, platform: String, version: String, nowMs: Long = System.currentTimeMillis()): String {
        val stamp = java.text.SimpleDateFormat("yyMMdd-HHmm", java.util.Locale.US).format(nowMs)
        return "noop-$profile-$platform-v$version-$stamp.zip"
    }

    /**
     * Pure zip builder (twin of Swift `FileExport.zipData`): write `entries` (in-zip name to bytes) into a
     * single zip and return its bytes, or null if there are no entries. No file IO or UI so it is JVM
     * unit-testable. EVERY entry must already be redacted by the caller (spec section 5.3).
     */
    fun zipEntries(entries: List<Pair<String, ByteArray>>): ByteArray? {
        if (entries.isEmpty()) return null
        val bos = java.io.ByteArrayOutputStream()
        java.util.zip.ZipOutputStream(bos).use { zos ->
            for ((name, data) in entries) {
                zos.putNextEntry(java.util.zip.ZipEntry(name))
                zos.write(data)
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    /**
     * Zip `entries` into one `.zip` under cache/logs (the FileProvider path) and fire the share chooser,
     * returning the staged file or null. Twin of Swift `FileExport.exportBundle`. EVERY entry must already
     * be redacted by the caller; the 20 MB cap is the assembler's job before this is called.
     *
     * The zip build + write (`zipEntries` + `writeBytes`) runs on [Dispatchers.IO] (#646/#651) so a
     * multi-MB bundle doesn't stall the caller's dispatcher; only the chooser intent fires back on
     * whatever dispatcher the caller resumed on (Main, for every UI call site today).
     */
    suspend fun exportBundle(context: Context, entries: List<Pair<String, ByteArray>>, suggestedName: String): File? =
        runCatching {
            val file = withContext(Dispatchers.IO) {
                zipEntries(entries)?.let { bytes ->
                    val dir = File(context.cacheDir, "logs").apply { mkdirs() }
                    File(dir, suggestedName).also { it.writeBytes(bytes) }
                }
            } ?: return null
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "application/zip"
                putExtra(Intent.EXTRA_STREAM, fileUri(context, file))
                putExtra(Intent.EXTRA_SUBJECT, suggestedName)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share report bundle"))
            file
        }.onFailure {
            Toast.makeText(context, "Couldn't export the bundle: ${it.message}", Toast.LENGTH_LONG).show()
        }.getOrNull()

    /**
     * Mirror the latest strap-log tail into the durable [StrapLogBuffer] (#510). Called from the same UI
     * actions that ship a log interactively, AND on demand by [DebugExportScheduler] before a scheduled
     * write, so the 24h rolling buffer that the background worker reads is kept current even though the
     * worker can't reach the live BLE client. REPLACE semantics: `logText` is the client's authoritative
     * recent window, so we overwrite rather than append (no overlap duplication).
     */
    fun mirrorToRollingBuffer(logText: String) {
        StrapLogBuffer.replaceWith(logText)
    }

    /**
     * The SCHEDULED daily debug export (#510): write the rolling-buffer strap log — plus the raw 5/MG
     * capture alongside as a `.bin`, if one exists — into the app-private export dir under a timestamped
     * name, returning the files written (log first). Unlike the interactive share paths this fires no
     * chooser: it runs from a [androidx.work.Worker] with no UI, leaving a dated pair on disk the user can
     * pick up later from Settings or a file manager. Reuses [StrapLogBuffer.snapshot] for the body so the
     * scheduled file matches what an interactive share would have shown.
     *
     * [logText] is the live tail if the scheduler could reach the BLE client; when it can't, it passes the
     * empty string and we fall back to the rolling buffer alone. Best-effort: returns an empty list on
     * failure rather than throwing into the worker.
     */
    suspend fun writeScheduledExport(context: Context, logText: String, nowMs: Long = System.currentTimeMillis()): List<File> =
        runCatching {
            if (logText.isNotBlank()) StrapLogBuffer.replaceWith(logText, nowMs)
            val body = StrapLogBuffer.snapshot(nowMs)

            val dir = exportDir(context)
            val out = arrayListOf<File>()

            val dynamic = com.noop.testcentre.AndroidDiagnostics.dynamicLines(context)
            val header = buildString {
                appendLine("NOOP strap log (scheduled debug export)")
                appendLine("App:     ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER})")
                for (line in com.noop.testcentre.AndroidDiagnostics.summaryLines(context)) appendLine(line)
                for (line in dynamic) appendLine(line)
                appendLine("─".repeat(40))
            }
            val text = body.ifBlank { "(rolling strap-log buffer is empty; connect to your strap so lines accrue)" }
            val logFile = File(dir, strapLogFilename(nowMs))
            logFile.writeText(header + "\n" + text)
            out.add(logFile)

            // The raw 5/MG capture (JSONL of every backfilled frame) copied alongside as a matching `.bin`
            // so the scheduled drop is a self-contained pair, mirroring the interactive shareRawAndLog. Only
            // present when a 5/MG owner has the opt-in capture on and a history sync has run.
            val main = File(context.filesDir, com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE)
            val prev = File(context.filesDir, "${com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE}.1")
            if (main.exists() || prev.exists()) {
                val rawFile = File(dir, rawCaptureFilename(nowMs))
                rawFile.outputStream().bufferedWriter().use { w ->
                    for (f in listOf(prev, main)) if (f.exists()) f.bufferedReader().use { r -> r.copyTo(w) }
                }
                out.add(rawFile)
            }

            // Retention (#642): scheduled exports accumulate silently with no UI in the loop (unlike an
            // interactive share, nobody is looking when this runs), so prune every write — mirrors
            // BackupSync.backupNow calling prune() right after it writes.
            pruneScheduledExports(context, DebugExportSettings.from(context).keepCount)

            out.toList()
        }.getOrDefault(emptyList())

    /** App-private export dir for the scheduled drops — under the same cache/logs tree the FileProvider
     *  already grants, so a future "open last export" share works without a manifest change. */
    private fun exportDir(context: Context): File =
        File(context.cacheDir, "logs").apply { mkdirs() }

    /** Filename prefix common to BOTH scheduled-export files (the `.txt` log and the `.bin` raw capture),
     *  distinct from the interactive-share prefixes (`noop-strap-log-`, `noop-raw-capture-`) so retention
     *  and the manual clear action only ever touch scheduled drops, never an interactive share sitting in
     *  the same cache/logs dir. */
    private const val SCHEDULED_PREFIX = "noop-straplog-"

    /**
     * The `yyyyMMdd-HHmmss` stamp embedded in one scheduled-export filename (log `.txt` or raw `.bin`),
     * or null if [filename] isn't one of ours. Pure — no file IO — so retention math is unit-testable.
     */
    fun scheduledExportStamp(filename: String): String? {
        if (!filename.startsWith(SCHEDULED_PREFIX)) return null
        val rest = filename.removePrefix(SCHEDULED_PREFIX)
        return when {
            rest.endsWith(".txt") -> rest.removeSuffix(".txt")
            rest.endsWith(".bin") -> rest.removeSuffix(".bin")
            else -> null
        }
    }

    /**
     * Scheduled-export STAMPS (not filenames) to prune to keep only the [keep] newest generations — a
     * day's log+raw pair shares a stamp and counts once. Mirrors [BackupSync.snapshotsToPrune]. The
     * fixed-width, zero-padded `yyyyMMdd-HHmmss` stamp sorts correctly as a plain string (no date
     * parsing needed). Empty when already within budget.
     */
    fun scheduledExportStampsToPrune(names: List<String>, keep: Int): Set<String> {
        val stamps = names.mapNotNull(::scheduledExportStamp).distinct().sortedDescending()
        return if (stamps.size <= keep) emptySet() else stamps.drop(keep).toSet()
    }

    /** Best-effort retention (#642): delete scheduled-export files beyond [keep] generations, oldest
     *  first. Called after every scheduled write. Listing/delete failures are ignored — a transient
     *  hiccup here must never fail the export itself. */
    private fun pruneScheduledExports(context: Context, keep: Int) {
        val files = exportDir(context).listFiles()?.toList() ?: return
        val toPrune = scheduledExportStampsToPrune(files.map { it.name }, keep)
        if (toPrune.isEmpty()) return
        for (f in files) {
            val stamp = scheduledExportStamp(f.name)
            if (stamp != null && stamp in toPrune) runCatching { f.delete() }
        }
    }

    /**
     * Manual "Clear scheduled exports" action (#642): delete every scheduled-export file right now,
     * regardless of the retention setting, so a user who wants the folder empty can make it so without
     * waiting for the next daily prune. Never touches interactive-share files (distinct filename
     * prefixes) or anything else under cache/logs. Returns the number of files removed; self-toasts like
     * the other actions in this object.
     */
    fun clearScheduledExports(context: Context): Int {
        val files = exportDir(context).listFiles()?.filter { scheduledExportStamp(it.name) != null }
            ?: emptyList()
        var removed = 0
        for (f in files) if (runCatching { f.delete() }.getOrDefault(false)) removed++
        val message = if (removed > 0) "Cleared $removed scheduled export file(s)." else "No scheduled exports to clear."
        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
        return removed
    }

    /**
     * Build the shareable strap-log file (header + body + last crash) under cache/logs and return it,
     * so both the single-share and the "raw + log" matched-pair export write the SAME content.
     */
    private suspend fun writeStrapLogFile(context: Context, logText: String): File {
        // Mirror every interactively-shared tail into the durable rolling buffer (#510) so the scheduled
        // background export has a current source even when the live BLE client is gone.
        mirrorToRollingBuffer(logText)
        val dynamic = com.noop.testcentre.AndroidDiagnostics.dynamicLines(context)
        val header = buildString {
            appendLine("NOOP strap log")
            appendLine("App:     ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER})")
            for (line in com.noop.testcentre.AndroidDiagnostics.summaryLines(context)) appendLine(line)
            for (line in dynamic) appendLine(line)
            appendLine("─".repeat(40))
        }
        val body = logText.ifBlank { "(strap log is empty; connect to your strap, reproduce the issue, then share again)" }

        // Append the last captured crash (if any) so a device-specific crash like the Insights
        // tab (#224/#267) arrives with its real stack trace instead of being unreachable.
        val crash = com.noop.CrashCapture.lastCrash(context)
        val crashSection = if (crash != null) "\n\n${"─".repeat(40)}\nLast crash:\n$crash" else ""

        val dir = File(context.cacheDir, "logs").apply { mkdirs() }
        val file = File(dir, "noop-strap-log-${timestamp()}.txt")
        file.writeText(header + "\n" + body + crashSection)
        return file
    }

    /**
     * Build the shareable 5/MG raw-capture file (header + the rotated + live JSONL captures) under
     * cache/logs and return it, or null if no capture has been recorded yet. Shared by the single
     * share and the "raw + log" matched-pair export so both emit the SAME content.
     */
    private fun writeCaptureFile(context: Context): File? {
        val main = File(context.filesDir, com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE)
        val prev = File(context.filesDir, "${com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE}.1")
        if (!main.exists() && !prev.exists()) return null
        val header = buildString {
            appendLine("# NOOP 5/MG raw backfill capture (JSONL; one frame per line)")
            appendLine("# App: ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER}) · Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}")
            appendLine("# NOTE: contains raw biometric frames (heart rate, R-R, skin temp, motion) and the strap's console text. Share only if you're comfortable with that.")
        }
        val dir = File(context.cacheDir, "logs").apply { mkdirs() }
        val out = File(dir, "noop-raw-capture-${timestamp()}.jsonl")
        out.outputStream().bufferedWriter().use { w ->
            w.write(header)
            // Oldest first: previous generation (if rotated), then the live file.
            for (f in listOf(prev, main)) if (f.exists()) f.bufferedReader().use { r -> r.copyTo(w) }
        }
        return out
    }

    /**
     * Share the opt-in "detailed capture" rolling strap-log file (#1121) — the adb-like long-run log the
     * Test Centre toggle writes. Concatenates the rolled generation + the live file (oldest first) into one
     * shareable `.txt`. Lines are ALREADY PII-scrubbed by `WhoopBleClient.log()`, so no extra redaction here.
     */
    suspend fun shareCaptureLog(context: Context) {
        runCatching {
            val out = withContext(Dispatchers.IO) { writeCaptureLogFile(context) }
            if (out == null) {
                Toast.makeText(
                    context,
                    "No detailed capture yet — turn on \"Detailed capture to file\" in Test Centre first.",
                    Toast.LENGTH_LONG,
                ).show()
                return
            }
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, fileUri(context, out))
                putExtra(Intent.EXTRA_SUBJECT, "NOOP detailed capture log")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share captured log"))
        }.onFailure {
            Toast.makeText(context, "Couldn't share the capture: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }

    /** Concatenate the rolling capture file's rolled + live generations (oldest first) into a shareable
     *  copy under cache/logs. Null when nothing has been captured yet. */
    private fun writeCaptureLogFile(context: Context): File? {
        val main = File(context.filesDir, com.noop.ble.WhoopBleClient.CAPTURE_LOG_FILE)
        val prev = File(context.filesDir, "${com.noop.ble.WhoopBleClient.CAPTURE_LOG_FILE}.1")
        if (!main.exists() && !prev.exists()) return null
        val header = buildString {
            appendLine("# NOOP detailed capture — rolling strap log (PII-scrubbed at source)")
            appendLine("# App: ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER}) · Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}")
        }
        val dir = File(context.cacheDir, "logs").apply { mkdirs() }
        val out = File(dir, "noop-capture-${timestamp()}.txt")
        out.outputStream().bufferedWriter().use { w ->
            w.write(header)
            for (f in listOf(prev, main)) if (f.exists()) f.bufferedReader().use { r -> r.copyTo(w) }
        }
        return out
    }

    private fun fileUri(context: Context, file: File) =
        FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)

    suspend fun shareStrapLog(context: Context, logText: String) {
        runCatching {
            // writeStrapLogFile does blocking file IO (#646/#651) — keep it off whatever dispatcher the
            // caller is on (Main, for every UI call site today).
            val file = withContext(Dispatchers.IO) { writeStrapLogFile(context, logText) }
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, fileUri(context, file))
                putExtra(Intent.EXTRA_SUBJECT, "NOOP strap log")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share strap log"))
        }.onFailure {
            Toast.makeText(context, "Couldn't share the log: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }

    /**
     * Empty-state message when there's no raw capture to include (#32). Accurate per device + toggle:
     * a 4.0 can never produce one (5/MG-only feature); a 5/MG needs the toggle on + a history sync;
     * if the toggle is already on, don't tell them to enable it again. `sharingLog` adds the log tail.
     */
    private fun noCaptureMsg(context: Context, whoop5Connected: Boolean, sharingLog: Boolean): String {
        val tail = if (sharingLog) " Sharing the strap log." else ""
        return when {
            !whoop5Connected ->
                "Raw capture records WHOOP 5/MG history syncs and doesn't apply to WHOOP 4.0 (already fully decoded).$tail"
            !PuffinExperiment.from(context).isCaptureEnabled ->
                "No raw capture yet. Turn on \"Record 5/MG raw capture\" above, then let a history sync run.$tail"
            else ->
                "Raw capture is on. Let a 5/MG history sync run, then try again.$tail"
        }
    }

    /**
     * Shares the opt-in 5/MG raw backfill capture (JSONL of every frame from history syncs) for the
     * puffin biometric decode effort (#78). Copies filesDir → cache (the FileProvider path already
     * covers cache/logs) and prepends a header with an informed-consent line: the file holds raw
     * biometric frames and the strap's own console text.
     */
    suspend fun shareWhoop5Capture(context: Context, whoop5Connected: Boolean) {
        runCatching {
            // writeCaptureFile does blocking file IO (#646/#651) — keep it off whatever dispatcher the
            // caller is on (Main, for every UI call site today).
            val out = withContext(Dispatchers.IO) { writeCaptureFile(context) }
            if (out == null) {
                Toast.makeText(context, noCaptureMsg(context, whoop5Connected, sharingLog = false), Toast.LENGTH_LONG).show()
                return
            }
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, fileUri(context, out))
                putExtra(Intent.EXTRA_SUBJECT, "NOOP 5/MG protocol capture")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(send, "Share 5/MG capture"))
        }.onFailure {
            Toast.makeText(context, "Couldn't share the capture: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }

    /**
     * One-tap matched-pair export (#510): share BOTH the raw 5/MG capture AND the strap log together. Now
     * a 2-entry case of [exportBundle] so the pair rides in one `.zip` (mobile GitHub can attach a zip,
     * not loose .txt files). If there's no capture yet, falls back to just the log so the tap isn't a dead
     * end. Reuses the same file-builders the single-share paths use; both entries are already redacted by
     * their writers.
     *
     * Building the files AND reading them back into memory (`readBytes`) is blocking file IO (#646/#651):
     * it runs on [Dispatchers.IO], off the caller's dispatcher (Main, from the Settings/Test Centre share
     * buttons), so a large raw capture doesn't stall the UI. Only the "no capture" toast and the
     * [exportBundle] call (which does its own IO hop for the zip) run back on the caller's dispatcher.
     */
    suspend fun shareRawAndLog(context: Context, logText: String, whoop5Connected: Boolean) {
        runCatching {
            val (entries, hasCapture) = withContext(Dispatchers.IO) {
                val logFile = writeStrapLogFile(context, logText)
                val capture = writeCaptureFile(context)
                val entries = arrayListOf("report.txt" to logFile.readBytes())
                if (capture != null) entries.add(0, "raw-capture.jsonl" to capture.readBytes())
                entries to (capture != null)
            }
            if (!hasCapture) {
                Toast.makeText(context, noCaptureMsg(context, whoop5Connected, sharingLog = true), Toast.LENGTH_LONG).show()
            }
            val name = "noop-export-${timestamp()}.zip"
            exportBundle(context, entries, name)
        }.onFailure {
            Toast.makeText(context, "Couldn't export the pair: ${it.message}", Toast.LENGTH_LONG).show()
        }
    }
}
