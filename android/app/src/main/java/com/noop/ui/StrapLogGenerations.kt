package com.noop.ui

import java.time.Instant
import java.time.temporal.ChronoUnit

/**
 * Pure, JVM-testable logic for the strap-log "generation ring" (#1263 item 2 — Android parity for the
 * iOS `LiveState` generations in `Strand/BLE/LiveState.swift`, issues #1259 / #1264).
 *
 * WHY THIS EXISTS. Android's live strap log ([com.noop.ble.WhoopBleClient.logBuffer]) lives ONLY for the
 * life of the process, and an export renders exactly that — so an export taken after the app process has
 * restarted begins at the restart, and the lines that would explain the restart are gone. To fix that,
 * [com.noop.ble.WhoopBleClient] now mirrors a DURABLE tail to SharedPreferences and, at the first log line
 * of each process (and at export time), ROLLS the surviving tail into a small ring of previous generations.
 * Exports render the generations oldest-first ahead of the current session, keeping `report.txt` in
 * chronological order so the log-parsing tools read it unchanged — they just get the session a restart
 * used to erase.
 *
 * This object is the PURE part: it operates only on `List<String>` / `List<List<String>>`, holds no
 * Android types and does no I/O, so it unit-tests directly (like [StrapLogBuffer]). The SharedPreferences
 * read/write is the thin, untested wrapper in [com.noop.ble.WhoopBleClient] — the same split iOS has
 * between its pure ring logic and UserDefaults.
 */
object StrapLogGenerations {

    /** How many previous processes to keep. Three covers the observed failure shape (a wake-time restart,
     *  occasionally two) without turning a debug tail into a database. Mirrors iOS `maxLogGenerations`. */
    const val MAX_GENERATIONS = 3

    /** Per-generation line cap — smaller than the durable live tail because what explains a stop is the END
     *  of the previous session. 3 × 1,000 short redacted lines ≈ 300 KB, bounded. Mirrors iOS
     *  `generationTailLimit`. */
    const val GENERATION_TAIL_LIMIT = 1_000

    /**
     * Roll the surviving durable [previousTail] into the generation ring: prepend a self-describing header,
     * clip the tail to [GENERATION_TAIL_LIMIT] keeping the NEWEST lines (what explains a stop is the end of
     * the previous session, not its start), append it to [existing], and drop the oldest beyond
     * [MAX_GENERATIONS].
     *
     * A NO-OP (returns [existing] unchanged) when [previousTail] is empty, so a launch that logged nothing —
     * or a roll that already ran this process — never pushes an empty generation and never evicts a real one.
     *
     * [nowMs] stamps the header as when the roll happened (i.e. THIS launch), NOT when those lines were
     * written — the lines carry their own clock. Said plainly in the text so nobody reads it as the session's
     * end. Pure: the caller owns reading [existing] and persisting the result.
     */
    fun roll(previousTail: List<String>, existing: List<List<String>>, nowMs: Long): List<List<String>> {
        if (previousTail.isEmpty()) return existing
        val iso = Instant.ofEpochMilli(nowMs).truncatedTo(ChronoUnit.SECONDS).toString()
        val clipped = if (previousTail.size > GENERATION_TAIL_LIMIT) {
            previousTail.subList(previousTail.size - GENERATION_TAIL_LIMIT, previousTail.size)
        } else previousTail
        // Say the KEPT count, and say so when the head was dropped — byte-identical wording to iOS,
        // because the same log tools parse both platforms' report.txt. The header used to report only
        // the pre-clip total, so a generation that had lost its first 1,000 lines still announced
        // "2000 line(s)" and read as a complete session; the missing head then measures as silence.
        val count = if (clipped.size == previousTail.size) {
            "${previousTail.size} line(s)"
        } else "${clipped.size} of ${previousTail.size} line(s), head clipped"
        val header = "===== previous app session, $count, rolled at $iso (this launch) ====="
        val gens = existing.toMutableList()
        gens.add(listOf(header) + clipped)
        while (gens.size > MAX_GENERATIONS) gens.removeAt(0)
        return gens
    }

    /** The marker separating banked previous sessions from this process's live tail. ONE definition:
     *  `WhoopBleClient.exportLogLines` emits the same marker when it builds the line form without going
     *  through [previousSessionsText], and two copies of this literal could drift apart silently — the
     *  export would still render, just with a boundary the log parsers no longer agree on. */
    const val CURRENT_SESSION_MARKER = "===== current app session ====="

    /**
     * The previous processes' lines, oldest-first, ready to sit AHEAD of the current session in an export.
     * Each generation is its own newline-joined block (its first line is its own separator header), and a
     * "===== current app session =====" marker follows so the reader can see where the live tail begins.
     * Empty string when there are no generations, so a caller can concatenate unconditionally. Mirrors iOS
     * `previousSessionsText()`.
     */
    fun previousSessionsText(generations: List<List<String>>): String {
        if (generations.isEmpty()) return ""
        return previousSessionsLines(generations).joinToString("\n") + "\n"
    }

    /**
     * The same block as [previousSessionsText], as LINES — for callers that immediately split it again
     * (`WhoopBleClient.exportLogLines`, feeding readouts that filter by domain tag).
     *
     * [previousSessionsText] is DERIVED from this, rather than the two being written separately, so they
     * cannot drift. An earlier revision built the line form with `flatten()` and that was already wrong:
     * `joinToString` renders an EMPTY generation as a blank line, while `flatten()` drops it, so a corrupt
     * or legacy empty block would have shifted every line after it in one form but not the other. Empty
     * generations are not supposed to be stored — `roll` never pushes one — but `persistedLogGenerations`
     * decodes an empty block to `emptyList()`, so the case is representable and must be rendered the same
     * way by both forms.
     */
    fun previousSessionsLines(generations: List<List<String>>): List<String> {
        if (generations.isEmpty()) return emptyList()
        val out = ArrayList<String>()
        for (generation in generations) {
            if (generation.isEmpty()) out.add("") else out.addAll(generation)
        }
        out.add(CURRENT_SESSION_MARKER)
        return out
    }
}
