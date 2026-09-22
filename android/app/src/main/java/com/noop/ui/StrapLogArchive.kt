package com.noop.ui

import java.io.File
import java.io.FileOutputStream
import java.time.Instant

/**
 * The strap log on disk: every line of every app run, kept across restarts within a fixed size.
 *
 * WHY THIS EXISTS. [com.noop.ble.WhoopBleClient]'s log buffer lives in memory and dies with the process. It used to
 * be mirrored to SharedPreferences — the newest 2,000 lines, rewritten every 32 lines — and each launch rolled that
 * mirror into a ring of the last three runs, 1,000 lines each (#1263). A restart's cause survived only when
 * restarts were rare and the cause was recent. Three things were lost every time: the lines logged since the last
 * mirror (up to 31 — the seconds before the process is killed, the ones that explain it); everything but a run's
 * last 1,000 lines; and every run before the last three. On 21 Sep 2026 iOS killed NOOP for background CPU four
 * times in 28 minutes of one session, and the log saved afterwards began half an hour after the moment it was
 * saved for; Android keeps the same ring, so it loses the same way.
 *
 * Now each line is appended to its run's file as it is logged — one small write, which the kernel keeps even when
 * the process is killed a moment later. A run is split into segments of [SEGMENT_BYTES]; once all the segments
 * pass [BUDGET_BYTES], the oldest are deleted. So the log holds the newest ~2 MB — about 20,000 lines, some three
 * hours with a strap streaming heart rate — however often the app restarts, and a whole run rather than the last
 * 5,000 lines the buffer keeps. Exports render it exactly as the ring did: earlier runs oldest first, each under
 * its "previous app session" header, then the current run after [CURRENT_RUN_MARKER], so every tool that reads a
 * strap log reads it unchanged.
 *
 * Before the first unlock after a boot a phone can refuse the files — just when a restart after a reboot is logged —
 * so lines that cannot be written wait in memory, the newest within the budget, and go to disk the moment a file
 * opens.
 *
 * An export reads no file while a run is written: the open segment's lines are kept in memory and everything
 * before them is rendered once, again only when pruning deletes a file — the Test Centre readouts ask for the
 * lines on every new one (#1468).
 *
 * Twin of the Swift `StrapLogArchive` (Strand/BLE/StrapLogArchive.swift): same file names, sizes and rendering.
 * Thread-safe: the client logs from the GATT binder thread and the main looper.
 */
class StrapLogArchive(
    private val directory: File,
    private val budgetBytes: Long = BUDGET_BYTES,
    private val segmentBytes: Long = SEGMENT_BYTES,
    nowMs: Long = System.currentTimeMillis(),
) {
    /** When this run began, unix milliseconds: the name its files sort by, and when the run before it ended. */
    val runStart: Long = nowMs

    private val lock = Any()
    private var out: FileOutputStream? = null
    private var segment = 0
    /** Bytes written to the open segment. */
    private var segmentSize = 0L
    /** The open segment's lines, all on disk, so an export reads nothing that is being written. */
    private val openLines = ArrayList<String>()
    /** Lines not on disk yet, all newer than [openLines]: storage refused them or no file would open. Written the
     *  moment one opens; meanwhile in this run's export, the newest within the budget. */
    private val unwritten = ArrayDeque<String>()
    private var unwrittenBytes = 0L
    /** Lines until the next attempt to open a file while none is open: every 64 lines, not on every line. */
    private var openAttemptIn = 0
    /** Everything before the open segment: the earlier runs as rendered lines (ending in the marker), and this
     *  run's closed segments. Null until an export needs it, and again when pruning deletes a file. */
    private var previousLines: List<String>? = null
    private val closedLines = ArrayList<String>()

    /** Log one line: onto disk now, or — if storage cannot be written — into memory until it can, the newest lines
     *  within the budget. Either way it is in this run's export. */
    fun append(line: String) = synchronized(lock) {
        unwritten.addLast(line)
        unwrittenBytes += line.toByteArray(Charsets.UTF_8).size + 1
        writeUnwritten()
        if (unwrittenBytes > budgetBytes) {
            while (unwrittenBytes > budgetBytes) {
                unwrittenBytes -= unwritten.removeFirst().toByteArray(Charsets.UTF_8).size + 1
            }
            // Nothing of this run on disk yet: its first file then starts at segment 1, which reads as a clipped head.
            if (segment == 0 && openLines.isEmpty()) segment = 1
        }
    }

    /** Write what waits, oldest first; a refusal leaves the rest waiting and the next attempt 64 lines away. */
    private fun writeUnwritten() {
        if (out == null) {
            if (openAttemptIn > 0) { openAttemptIn -= 1; return }
            openSegment()
            if (out == null) { openAttemptIn = 63; return }
        }
        while (unwritten.isNotEmpty()) {
            val bytes = (unwritten.first() + "\n").toByteArray(Charsets.UTF_8)
            if (openLines.isNotEmpty() && segmentSize + bytes.size > segmentBytes) {
                closeSegment()
                openSegment()
                if (out == null) { openAttemptIn = 63; return }
            }
            if (runCatching { out!!.write(bytes) }.isFailure) {
                runCatching { out?.close() }
                out = null
                openAttemptIn = 63
                return
            }
            segmentSize += bytes.size
            unwrittenBytes -= bytes.size
            openLines.add(unwritten.removeFirst())
        }
    }

    /** The whole log as an export shows it: earlier runs, the marker, then this run. */
    fun exportText(): String = exportLines().joinToString("\n").let { text ->
        // The ring's text form ended its previous-sessions block in a newline after the marker even when this
        // run was empty, which the line form cannot carry.
        if (text.endsWith(CURRENT_RUN_MARKER)) text + "\n" else text
    }

    /** The same log as lines, for readouts that filter it without building one string. */
    fun exportLines(): List<String> = synchronized(lock) {
        ensureRendered()
        val previous = previousLines.orEmpty()
        ArrayList<String>(previous.size + closedLines.size + openLines.size + unwritten.size).apply {
            addAll(previous); addAll(closedLines); addAll(openLines); addAll(unwritten)
        }
    }

    /** Keep the ring's lines when the log first moves to disk: written once, before every run, as they were. */
    fun importLegacy(lines: List<String>) {
        if (lines.isEmpty()) return
        synchronized(lock) {
            val file = File(directory, LEGACY_FILE_NAME)
            if (file.exists()) return
            runCatching { file.writeText(lines.joinToString("\n") + "\n") }
            previousLines = null
        }
    }

    // ── Files ───────────────────────────────────────────────────────────────────────────────────────────

    /** One file: a segment of a run, or the carried-over ring ([run] null). */
    private data class LogFile(val file: File, val run: Long?, val index: Int)

    /** Every file, oldest first: the carried-over ring, then each run's segments in order. */
    private fun files(): List<LogFile> =
        (directory.listFiles() ?: emptyArray()).mapNotNull { f ->
            if (f.name == LEGACY_FILE_NAME) return@mapNotNull LogFile(f, null, 0)
            val parts = f.name.removeSuffix(".log").split("-")
            val run = parts.getOrNull(0)?.toLongOrNull()
            val index = parts.getOrNull(1)?.toIntOrNull()
            if (!f.name.endsWith(".log") || parts.size != 2 || run == null || index == null) null
            else LogFile(f, run, index)
        }.sortedWith(compareBy({ it.run ?: -1L }, { it.index }))

    private fun openSegment() {
        runCatching {
            directory.mkdirs()
            out = FileOutputStream(File(directory, fileName(runStart, segment)), true)
        }
        prune()
    }

    private fun closeSegment() {
        runCatching { out?.close() }
        out = null
        if (previousLines != null) closedLines.addAll(openLines)
        segment += 1
        segmentSize = 0
        openLines.clear()
    }

    /** Delete the oldest files until everything fits the budget — never the segment being written. */
    private fun prune() {
        val open = fileName(runStart, segment)
        val all = files().toMutableList()
        var total = all.sumOf { it.file.length() }
        while (total > budgetBytes) {
            val oldest = all.firstOrNull { it.file.name != open } ?: break
            total -= oldest.file.length()
            oldest.file.delete()
            all.remove(oldest)
            previousLines = null
        }
    }

    // ── Rendering ───────────────────────────────────────────────────────────────────────────────────────

    private fun ensureRendered() {
        if (previousLines != null) return
        val open = fileName(runStart, segment)
        val legacy = ArrayList<String>()
        val runs = ArrayList<Run>()
        closedLines.clear()
        for (f in files()) {
            if (f.file.name == open) continue
            val lines = linesOf(f.file)
            when {
                f.run == null -> legacy.addAll(lines)
                f.run == runStart -> closedLines.addAll(lines)
                runs.lastOrNull()?.start == f.run -> runs.last().lines.addAll(lines)
                else -> runs.add(Run(f.run, ArrayList(lines), f.index > 0))
            }
        }
        previousLines = render(legacy, runs, runStart)
    }

    /** One earlier run: when it began, its lines, and whether its first segments were pruned. */
    data class Run(val start: Long, val lines: MutableList<String>, val clipped: Boolean)

    companion object {
        /** How much of the log is kept, all runs together. */
        const val BUDGET_BYTES: Long = 2L * 1024 * 1024
        /** The size at which a run's file is closed and the next begun — what the oldest runs are deleted by. */
        const val SEGMENT_BYTES: Long = 256L * 1024
        /** Separates the earlier runs from the current one in an export, as the ring's exports did. */
        const val CURRENT_RUN_MARKER = "===== current app session ====="
        /** Lines carried over from the SharedPreferences ring the first time this runs: rendered first. */
        const val LEGACY_FILE_NAME = "legacy.log"

        fun fileName(run: Long, segment: Int): String = String.format(java.util.Locale.US, "%013d-%04d.log", run, segment)

        /** The ring's lines as its export printed them: each stored run already carries its own header; a tail
         *  the ring had not rolled yet gets the header its roll would have written, now. */
        fun legacyRingLines(generations: List<List<String>>, tail: List<String>, nowMs: Long): List<String> {
            val lines = generations.flatten().toMutableList()
            if (tail.isNotEmpty()) {
                lines.add(header(tail.size, clipped = false, rolledAt = nowMs))
                lines.addAll(tail)
            }
            return lines
        }

        /** One earlier run's header. Byte-identical to the ring's, which the log tools parse; the time is UTC,
         *  to the second. */
        fun header(lines: Int, clipped: Boolean, rolledAt: Long): String {
            val rolled = Instant.ofEpochSecond(rolledAt / 1000).toString()
            val count = "$lines line(s)" + if (clipped) ", head clipped" else ""
            return "===== previous app session, $count, rolled at $rolled (this launch) ====="
        }

        /** The earlier runs as an export prints them, ending in the current-run marker; empty when there are
         *  none. A run's "rolled at" is when the run after it began — the moment the ring used to roll it. */
        fun render(legacy: List<String>, runs: List<Run>, currentStart: Long): List<String> {
            if (legacy.isEmpty() && runs.isEmpty()) return emptyList()
            val out = ArrayList<String>(legacy)
            runs.forEachIndexed { i, run ->
                val next = runs.getOrNull(i + 1)?.start ?: currentStart
                out.add(header(run.lines.size, run.clipped, next))
                out.addAll(run.lines)
            }
            out.add(CURRENT_RUN_MARKER)
            return out
        }

        private fun linesOf(file: File): List<String> {
            val text = runCatching { file.readText() }.getOrDefault("")
            if (text.isEmpty()) return emptyList()
            val lines = text.split("\n")
            return if (lines.last().isEmpty()) lines.dropLast(1) else lines
        }
    }
}
