package com.noop.data

/** The existing metric-series schema stores one manual reading per local date. No migration required. */
class WeightHistoryStore(
    private val upsert: suspend (List<MetricSeriesRow>) -> Unit,
    private val query: suspend (String, String, String, String) -> List<MetricSeriesRow>,
    private val delete: suspend (String, String, String) -> Unit,
    private val queryDaily: suspend (String, String, String) -> List<AppleDaily> = { _, _, _ -> emptyList() },
) {
    constructor(repo: WhoopRepository) : this(
        { repo.upsertMetricSeries(it) },
        { source, key, from, to -> repo.metricSeries(source, key, from, to) },
        { source, day, key -> repo.deleteMetricSeriesPoint(source, day, key) },
        { source, from, to -> repo.appleDaily(source, from, to) },
    )

    suspend fun save(day: String, kilograms: Double) {
        require(WeightHistory.validDay(day) && WeightHistory.validKilograms(kilograms))
        upsert(listOf(MetricSeriesRow(WeightHistory.MANUAL_SOURCE, day, WeightHistory.KEY, kilograms)))
    }

    suspend fun delete(day: String) {
        require(WeightHistory.validDay(day))
        delete(WeightHistory.MANUAL_SOURCE, day, WeightHistory.KEY)
    }

    suspend fun history(through: String): List<WeightEntry> {
        val entries = WeightHistory.sources.flatMap { source ->
            // Older imports only populated appleDaily. Series rows follow so a valid same-source
            // series value wins; resolve discards invalid rows before applying source precedence.
            val daily = if (source == WeightHistory.MANUAL_SOURCE) emptyList() else
                queryDaily(source, "0001-01-01", through).mapNotNull { row ->
                    row.weightKg?.let { WeightEntry(row.day, it, source) }
                }
            daily + query(source, WeightHistory.KEY, "0001-01-01", through)
                .map { WeightEntry(it.day, it.value, source) }
        }
        return WeightHistory.resolve(entries, through)
    }
}
