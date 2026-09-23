package com.noop.ble

/**
 * The host-received line, summarised: what a strap log carries about this transport when no Test Centre mode is on.
 *
 * WHY. [standardHrHostReceivedLine] is written for EVERY standard-HR sample, which a streaming strap produces once
 * a second. In one 75-minute gym session on 22 Sep 2026 that was 3,009 of the log's 5,704 lines — 52.8% of
 * everything the log had to say about that session — and a 5/MG export in the #2386 review had the same shape,
 * half its transport lines crowding out the rest. Since #2386 the log is kept on disk within 2 MB, so this ratio
 * now decides how much history a bug report carries: about three hours of a streaming strap, where a summarised
 * stream carries a day.
 *
 * What the line exists for is kept. A sample the host REFUSED — an HR outside 30..220, an R-R outside 250..3000 ms
 * — is still written the moment it happens: that is the rare event, and it costs nothing while nothing is wrong.
 * The routine ones are counted and rendered once a window as a line that says how many arrived, over how long, the
 * widest gap between two of them (a stall a reader used to have to find by eye), what was accepted and refused,
 * and what is still pending. Full per-sample detail comes back while the Test Centre's HRV or Connection mode is
 * on, which is what those modes are for: gate the per-sample readout behind the domain, leave the rare-event
 * evidence always on (`AGENTS.md`).
 *
 * Twin of Swift `LivePersistTrace.StandardHRHostReceivedTrace` (Packages/StrandAnalytics), line for line: same
 * window, same rules, same rendered text. Not thread-safe by itself; [StandardHrSource] records under its buffer
 * lock, as it already builds the per-sample line there.
 */
class StandardHrHostReceivedTrace {

    /** One host-received observation: the same fields the per-sample line renders. */
    data class Sample(
        val hostUnixSeconds: Int,
        val acceptedHrRows: Int,
        val acceptedRrRows: Int,
        val rejectedHrRows: Int,
        val rejectedRrRows: Int,
        val pendingHrRows: Int,
        val pendingRrRows: Int,
    )

    private var firstSecond: Int? = null
    private var lastSecond = 0
    private var samples = 0
    private var acceptedHr = 0
    private var acceptedRr = 0
    private var rejectedHr = 0
    private var rejectedRr = 0
    private var pendingHr = 0
    private var pendingRr = 0
    private var widestGap = 0

    /**
     * The lines to write for this sample, in the order they should appear: a finished window's summary first,
     * because it describes the samples before this one.
     *
     * Twin of Swift `StandardHRHostReceivedTrace.record`.
     */
    fun record(sample: Sample, detailed: Boolean): List<String> {
        val lines = ArrayList<String>(2)
        val first = firstSecond
        if (first != null &&
            // 60 s: a window long enough to turn a streaming hour into 60 lines, short enough that a stall
            // still shows in one of them. The Swift twin uses the same literal.
            (sample.hostUnixSeconds - first >= 60 || sample.hostUnixSeconds < first)
        ) {
            // A clock that went backwards ends the window too: a span is only honest within one clock.
            summaryLine()?.let { lines.add(it) }
            val previousLast = lastSecond
            val forwards = sample.hostUnixSeconds >= previousLast
            reset()
            // #2405: the gap that CROSSED this boundary is the one worth reporting, and it used to be the
            // one gap that could not be. A stall of a minute or more forces this roll on the next sample,
            // so it fell between two windows and appeared in neither, leaving gapMaxSec able to describe
            // only stalls shorter than the window — the opposite of what it is read for.
            //
            // Seeded into the NEW window rather than added to the summary just emitted: that summary
            // describes the samples BEFORE the gap, and this window is the one the gap opens. Not seeded
            // across a backwards clock (no honest span) nor across close(), where a disconnect or a
            // termination already accounts for the silence. Twin of the Swift `record`.
            if (forwards) widestGap = sample.hostUnixSeconds - previousLast
        }
        if (firstSecond == null) {
            firstSecond = sample.hostUnixSeconds
        } else {
            widestGap = maxOf(widestGap, sample.hostUnixSeconds - lastSecond)
        }
        lastSecond = sample.hostUnixSeconds
        samples += 1
        acceptedHr += sample.acceptedHrRows
        acceptedRr += sample.acceptedRrRows
        rejectedHr += sample.rejectedHrRows
        rejectedRr += sample.rejectedRrRows
        pendingHr = sample.pendingHrRows
        pendingRr = sample.pendingRrRows
        if (detailed || sample.rejectedHrRows > 0 || sample.rejectedRrRows > 0) {
            lines.add(
                standardHrHostReceivedLine(
                    hostUnixSeconds = sample.hostUnixSeconds,
                    acceptedHrRows = sample.acceptedHrRows, acceptedRrRows = sample.acceptedRrRows,
                    rejectedHrRows = sample.rejectedHrRows, rejectedRrRows = sample.rejectedRrRows,
                    pendingHrRows = sample.pendingHrRows, pendingRrRows = sample.pendingRrRows,
                )
            )
        }
        return lines
    }

    /**
     * The window so far, for a disconnect, a background flush or a termination: the last minute of a session is
     * exactly the part a report is taken for, and it must not leave with the process.
     *
     * Twin of Swift `StandardHRHostReceivedTrace.close`.
     */
    fun close(): List<String> {
        val summary = summaryLine() ?: return emptyList()
        reset()
        return listOf(summary)
    }

    /** Twin of Swift `StandardHRHostReceivedTrace.summaryLine`. */
    private fun summaryLine(): String? {
        val first = firstSecond
        if (first == null || samples == 0) return null
        return "standard-hr transport host-received summary" +
            " windowSec=${lastSecond - first} samples=$samples gapMaxSec=$widestGap" +
            " acceptedHRRows=$acceptedHr acceptedRRRows=$acceptedRr" +
            " rejectedHRRows=$rejectedHr rejectedRRRows=$rejectedRr" +
            " pendingHRRows=$pendingHr pendingRRRows=$pendingRr"
    }

    /** Twin of Swift `StandardHRHostReceivedTrace.reset`. */
    private fun reset() {
        firstSecond = null
        lastSecond = 0
        samples = 0
        acceptedHr = 0
        acceptedRr = 0
        rejectedHr = 0
        rejectedRr = 0
        pendingHr = 0
        pendingRr = 0
        widestGap = 0
    }
}
