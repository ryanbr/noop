package com.noop.analytics

/**
 * One line summarising every day a scoring pass skipped for want of HR samples, replacing one line per
 * skipped day.
 *
 * A pass walks a fixed recent window, so a day whose raw HR never arrived is re-read, re-skipped and
 * re-logged on every pass, forever. The strap banks days rather than weeks of raw HR while an import can
 * supply a much longer spine of daily rows, so the steady state for an importing user is a permanent
 * block of un-scoreable days. In one field capture that was 1262 lines - 21 days re-skipped across 63
 * passes in two hours, about a fifth of everything the log had to say.
 *
 * That matters because the strap log is a fixed-size rolling buffer: noise does not merely annoy, it
 * evicts the older lines an investigation needs. Collapsing per pass keeps every fact - which days, and
 * each day's own HR count - while removing the repetition, so days are grouped by their sample count and
 * listed rather than summarised into a range that could hide a gap.
 *
 * Returns null when nothing was skipped, so a healthy pass stays silent. Swift twin:
 * `StrandAnalytics.skippedSleepDaysLine`.
 */
internal fun skippedSleepDaysLine(skipped: List<Pair<String, Int>>, minHrSamples: Int): String? {
    if (skipped.isEmpty()) return null
    val groups = skipped.groupBy { it.second }.toSortedMap().map { (count, entries) ->
        val days = entries.map { it.first }.sorted()
        "hrSamples=$count on ${days.size} day(s): ${days.joinToString(", ")}"
    }
    return "sleep SKIPPED ${skipped.size} day(s) — need ≥$minHrSamples hrSamples: " +
        groups.joinToString("; ")
}

/**
 * Accumulates the skipped days for one pass.
 *
 * A class rather than a `mutableListOf<Pair<String, Int>>()` built inline, for the same reason
 * [DayTraceRecorders] is one: `analyzeRecentOnCpu` sits against the JVM's 64 KB per-method ceiling that
 * #1524 guards, and the generic construction plus the null-check branch cost enough there to break it.
 * Holding both inside the collector leaves the hot method with three plain calls.
 */
internal class SleepSkipCollector {
    private val skipped = mutableListOf<Pair<String, Int>>()

    fun add(day: String, hrSamples: Int) {
        skipped += day to hrSamples
    }

    /** Drop the previous pass's days. Called at the top of every pass, under `analyzeGate`. */
    fun reset() {
        skipped.clear()
    }

    /** The one summary line for this pass, or null when nothing was skipped. */
    fun line(minHrSamples: Int): String? = skippedSleepDaysLine(skipped, minHrSamples)

    /**
     * Emit this pass's summary to [diag], if there is one.
     *
     * The null check lives here rather than at the call site deliberately: the caller is
     * `analyzeRecentOnCpu`, which passes the JVM ceiling test with single-digit bytes to spare, so a local
     * plus a branch there costs margin that this method has in abundance.
     */
    fun emit(minHrSamples: Int, diag: (String) -> Unit) {
        val text = line(minHrSamples)
        if (text != null) diag(text)
    }
}
