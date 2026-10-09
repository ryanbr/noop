package com.noop.push

import java.time.Instant
import java.time.ZoneId
import kotlin.math.sqrt

/** The small sleep-session shape needed to reproduce the Sleep screen's consistency series for export. */
internal data class SleepConsistencySession(
    val startTs: Long,
    val endTs: Long,
    val startTsAdjusted: Long?,
) {
    val effectiveStartTs: Long get() = startTsAdjusted ?: startTs
}

/** Source-local twin of SleepModelLogic.consistencySeries, keyed by each session's local wake day. */
internal object SleepConsistencyPushProjection {
    fun byWakeDay(sessions: List<SleepConsistencySession>, zoneId: ZoneId): Map<String, Double> {
        val ordered = sessions.sortedBy { it.startTs }
        if (ordered.size < 3) return emptyMap()

        val bedtimeMinutes = ordered.map { session ->
            val bedtime = Instant.ofEpochSecond(session.effectiveStartTs).atZone(zoneId)
            var minutes = (bedtime.hour * 60 + bedtime.minute).toDouble()
            if (minutes < 12 * 60) minutes += 24 * 60 // keep evening and after-midnight times continuous
            minutes
        }
        val scores = linkedMapOf<String, Double>()
        for (index in ordered.indices) {
            val first = maxOf(0, index - 13)
            val window = bedtimeMinutes.subList(first, index + 1)
            if (window.size < 3) continue
            val mean = window.average()
            val variance = window.sumOf { (it - mean) * (it - mean) } / window.size
            val score = (100.0 * (1.0 - sqrt(variance) / 120.0)).coerceIn(0.0, 100.0)
            val wakeDay = Instant.ofEpochSecond(ordered[index].endTs).atZone(zoneId).toLocalDate().toString()
            // SleepModel orders by startTs; if a day has multiple sessions, its latest session supplies
            // the one daily point, matching the unique dailyMetric day key.
            scores[wakeDay] = score
        }
        return scores
    }
}
