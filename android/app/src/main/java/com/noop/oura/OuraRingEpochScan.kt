package com.noop.oura

/**
 * Group Oura sidecar rows by the ring epoch each one implies, so a session filed under the wrong
 * anchor is visible without needing a trusted anchor to compare against.
 *
 * Kotlin twin of `WhoopStore.OuraRingEpochScan` (#2252), so both platforms read a bundle the same way.
 *
 * The ticks x10 defect (#2239) filed whole sessions in the past, and the rows it wrote carry no
 * ring-time in the store, so nothing there can say which they were. The decoded sidecars do carry both
 * axes and are written on every live-feeding connection, so the evidence is already on the device.
 *
 * Every row implies `epoch = utc - ringTs / 10`: the UTC at which the ring's tick counter read zero.
 * Rows anchored correctly against one boot all imply the SAME epoch; a session whose anchor was adopted
 * as seconds x10 implies one `0.9 * anchorTicks` seconds earlier, 41.7 days for the ring in #2239. The
 * shift is CONSTANT across that session because it comes from the anchor, not from each record.
 *
 * This DESCRIBES, it does not classify. A ring that genuinely restarted also starts a new epoch, and
 * telling a restart from a mis-anchored session is a judgement the caller makes with the registration
 * date in hand.
 */
object OuraRingEpochScan {

    /** One run of rows agreeing on where the ring's clock started. */
    data class Cluster(
        /** Implied UTC of ring tick 0, the median of the run so one outlying row cannot move it. */
        val epochUnix: Long,
        val rows: Int,
        val firstStoredUtc: Long,
        val lastStoredUtc: Long,
    )

    /**
     * Six hours, the default gap that separates one epoch from the next.
     *
     * Not tight, deliberately. The ring runs at 9.94 to 10.25 ticks per second rather than exactly 10,
     * so dividing by 10 accumulates error WITHIN a correctly anchored session: a 2.5% rate error is
     * about eight hours of implied-epoch drift across a fortnight of banked history. A tighter tolerance
     * would split one honest boot and report the ring's own tick rate as corruption. The defect this
     * surfaces moves the epoch by DAYS.
     */
    const val DEFAULT_TOLERANCE_SECONDS = 21_600L

    /**
     * One report line when the rows disagree about where the ring's clock started, or null when they do
     * not. Null is the healthy answer and the common one, so an absent line keeps a healthy report
     * byte-unchanged by this existing.
     *
     * States the gap in days rather than naming a cause: `0.9 * anchorTicks` for the #2239 ring was 41.7
     * days, so a gap near that is the ticks x10 signature, while a few days is more likely a genuine
     * restart. Both look identical from here, and the reader has the registration date.
     *
     * The Swift twin is `OuraRingEpochScan.summaryLine`.
     */
    fun summaryLine(clusters: List<Cluster>): String? {
        if (clusters.size <= 1) return null
        val newest = clusters.first()
        val sb = StringBuilder(
            "ouraRingEpoch clusters=${clusters.size} newest=${isoDay(newest.epochUnix)} rows=${newest.rows}"
        )
        for (older in clusters.drop(1)) {
            val gapDays = (newest.epochUnix - older.epochUnix).toDouble() / 86_400
            sb.append(" | epoch=${isoDay(older.epochUnix)} rows=${older.rows}")
            sb.append(" gapDays=${String.format(java.util.Locale.ROOT, "%.1f", gapDays)}")
            sb.append(" stored=${isoDay(older.firstStoredUtc)}..${isoDay(older.lastStoredUtc)}")
        }
        return sb.toString()
    }

    /**
     * UTC calendar day for a unix second, as the report prints dates elsewhere.
     *
     * The Swift twin is `OuraRingEpochScan.isoDay`.
     */
    internal fun isoDay(unix: Long): String {
        val f = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        f.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return f.format(java.util.Date(unix * 1000L))
    }

    /**
     * Cluster [rows] by implied ring epoch, newest epoch first.
     *
     * Rows may arrive in any order and may mix sidecars. A row whose `ringTs` is 0 is dropped: an
     * unanchored record has no time axis to imply an epoch from, and including it would invent one.
     *
     * The Swift twin is `OuraRingEpochScan.cluster`.
     */
    fun cluster(
        rows: List<Pair<Long, Long>>,               // (ringTs, storedUtc)
        toleranceSeconds: Long = DEFAULT_TOLERANCE_SECONDS,
    ): List<Cluster> {
        val points = rows
            .filter { it.first > 0 }
            .map { (it.second - it.first / 10) to it.second }
            .sortedBy { it.first }
        if (points.isEmpty()) return emptyList()

        // Runs are collected first and turned into clusters after, rather than closed by a local helper:
        // a nested function is a DECLARATION the parity ledger sees on each side and cannot pair, so the
        // twin would owe two one-sided entries for a private detail neither platform exposes.
        val runs = ArrayList<List<Pair<Long, Long>>>()
        var run = mutableListOf(points[0])
        for (point in points.drop(1)) {
            // Against the PREVIOUS row, not the run's first: a long session drifts steadily, and measuring
            // from the start would eventually exceed any tolerance and split one boot in two.
            if (point.first - run[run.size - 1].first <= toleranceSeconds) {
                run.add(point)
            } else {
                runs.add(run)
                run = mutableListOf(point)
            }
        }
        runs.add(run)

        val clusters = runs.map { r ->
            val epochs = r.map { it.first }.sorted()
            val utcs = r.map { it.second }
            Cluster(
                epochUnix = epochs[epochs.size / 2],
                rows = r.size,
                firstStoredUtc = utcs.min(),
                lastStoredUtc = utcs.max(),
            )
        }
        // Tie-broken to match Swift, whose `sorted(by:)` is NOT stable where this is: two clusters sharing
        // a median epoch must come back in the same order on both platforms, or `summaryLine` names a
        // different one "newest".
        return clusters.sortedWith(
            compareByDescending<Cluster> { it.epochUnix }
                .thenByDescending { it.rows }
                .thenByDescending { it.firstStoredUtc }
        )
    }
}
