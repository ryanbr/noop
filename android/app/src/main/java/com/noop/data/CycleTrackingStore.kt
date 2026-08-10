package com.noop.data

import java.time.LocalDate

/**
 * Local-only menstrual cycle tracker storage. A period start is one value-1 [MetricSeriesRow] under
 * the dedicated `noop-cycle` source. This is the value-for-value twin of Swift
 * `CycleTrackingStore`: same source, key, day format, ordering, idempotent upsert and physical delete.
 * Imports and strap analysis use different source ids, so they cannot overwrite user-entered history.
 */
class CycleTrackingStore(
    private val upsertRows: suspend (List<MetricSeriesRow>) -> Unit,
    private val queryRows: suspend (String, String, String, String) -> List<MetricSeriesRow>,
    private val deletePoint: suspend (String, String, String) -> Unit,
    private val deleteSeries: suspend (String, String) -> Unit,
) {
    constructor(repo: WhoopRepository) : this(
        { rows -> repo.upsertMetricSeries(rows) },
        { deviceId, key, from, to -> repo.metricSeries(deviceId, key, from, to) },
        { deviceId, day, key -> repo.deleteMetricSeriesPoint(deviceId, day, key) },
        { deviceId, key -> repo.deleteMetricSeries(deviceId, key) },
    )

    /** Log or idempotently re-log cycle day 1. */
    suspend fun logStart(day: String = todayKey()) {
        upsertRows(listOf(MetricSeriesRow(SOURCE_ID, day, PERIOD_START_KEY, LOGGED_VALUE)))
    }

    /** Logged starts in the inclusive range, oldest first. */
    suspend fun starts(from: String = DAY_MIN, to: String = DAY_MAX): List<String> =
        queryRows(SOURCE_ID, PERIOD_START_KEY, from, to)
            .filter { it.value >= LOGGED_VALUE }
            .sortedBy { it.day }
            .map { it.day }

    /** Physically remove one start row; deleting an absent row is an idempotent no-op. */
    suspend fun deleteStart(day: String) {
        deletePoint(SOURCE_ID, day, PERIOD_START_KEY)
    }

    /** Remove all logged starts after explicit confirmation in the UI. */
    suspend fun deleteAll() {
        deleteSeries(SOURCE_ID, PERIOD_START_KEY)
    }

    companion object {
        const val SOURCE_ID = "noop-cycle"
        const val PERIOD_START_KEY = "period_start"
        const val LOGGED_VALUE = 1.0
        private const val DAY_MIN = "0000-01-01"
        private const val DAY_MAX = "9999-12-31"

        fun todayKey(today: LocalDate = LocalDate.now()): String = today.toString()
    }
}
