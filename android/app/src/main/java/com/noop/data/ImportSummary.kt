package com.noop.data

/**
 * Result of importing an external data source (WHOOP export, Apple Health export, or
 * Health Connect) into the local Room store. Returned by every importer so the UI can
 * show one consistent "imported N days / M workouts" toast.
 */
data class ImportSummary(
    /** Human label of the source: "WHOOP", "Apple Health", "Health Connect". */
    val source: String,
    /** Rows actually upserted, keyed by table name (e.g. "dailyMetric" -> 1200). */
    val counts: Map<String, Int>,
    /** Earliest day touched, "YYYY-MM-DD" (null if nothing imported). */
    val firstDay: String? = null,
    /** Latest day touched, "YYYY-MM-DD". */
    val lastDay: String? = null,
    /** One-line human summary for a Toast / status line. */
    val message: String,
    /**
     * #1617: per-metric-column counts from the parsed daily rows, in the cross-platform label order —
     * see `com.noop.ingest.importColumnCoverage`. Empty for importers that do not produce daily
     * physiological rows, in which case the trace emits no coverage line at all rather than a row of
     * zeroes that would read as "everything is missing".
     */
    val columnCoverage: List<Pair<String, Int>> = emptyList(),
    /**
     * Rows the coverage above was counted over. Carried explicitly rather than inferred from the largest
     * count: if every column were sparse, the largest count would UNDER-report the row total and the line
     * would quietly overstate coverage.
     */
    val columnCoverageRows: Int = 0,
) {
    val totalRows: Int get() = counts.values.sum()

    companion object {
        /** A failed/empty import carrying a reason. */
        fun failure(source: String, reason: String) =
            ImportSummary(source = source, counts = emptyMap(), message = reason)
    }
}
