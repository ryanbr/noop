package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.ScoreInputProvenanceRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository

/** Persistence-only helpers kept out of the already large scoring orchestrator. */
internal object IntelligencePersistence {
    data class ComputedWindow(
        val deviceId: String,
        val from: String,
        val to: String,
        val dailies: List<DailyMetric>,
        val metricRows: List<MetricSeriesRow>,
        val provenance: List<ScoreInputProvenanceRow>,
        val markerSourceIds: List<String>,
    )

    suspend fun prepareComputedWindow(
        repo: WhoopRepository,
        importedDeviceId: String,
        computedId: String,
        from: String,
        to: String,
        dailies: List<DailyMetric>,
        metricRows: List<MetricSeriesRow>,
        cycle: PhysiologicalStepCycleEngine.Result,
        candidatePriorities: List<Pair<String, Int>>,
        ownerByDay: Map<String, String>,
    ): ComputedWindow {
        val provenance = scoreProvenance(computedId, dailies, metricRows, ownerByDay)
        return ComputedWindow(
            deviceId = computedId,
            from = from,
            to = to,
            dailies = dailies,
            metricRows = (metricRows + cycle.recoveredOwnerMarkerRows)
                .distinctBy { Triple(it.deviceId, it.day, it.key) },
            provenance = provenance,
            markerSourceIds = DayCycleIntelligenceIntegration.markerRewriteSourceIds(
                repo.computedSourceIds(importedDeviceId),
                candidatePriorities.map { (owner, _) -> repo.computedDeviceId(owner) },
            ),
        )
    }

    fun scoreProvenance(
        computedId: String,
        dailies: List<DailyMetric>,
        metricRows: List<MetricSeriesRow>,
        ownerByDay: Map<String, String>,
    ): List<ScoreInputProvenanceRow> {
        val byCell = LinkedHashMap<Pair<String, String>, ScoreInputProvenanceRow>()
        for (daily in dailies) {
            val source = ownerByDay[daily.day] ?: continue
            if (daily.recovery != null) {
                byCell[daily.day to "recovery"] = ScoreInputProvenanceRow(
                    computedId, daily.day, "recovery", source,
                )
            }
            if (daily.strain != null) {
                byCell[daily.day to "strain"] = ScoreInputProvenanceRow(
                    computedId, daily.day, "strain", source,
                )
            }
        }
        for (point in metricRows) {
            val source = ownerByDay[point.day] ?: continue
            byCell[point.day to point.key] = ScoreInputProvenanceRow(
                computedId, point.day, point.key, source,
            )
        }
        return byCell.values.toList()
    }

    suspend fun persistDetectedSleepDetails(
        repo: WhoopRepository,
        computedId: String,
        kept: List<SleepSession>,
        scoredNights: List<DayResult>,
    ) {
        // Only kept (not edited/dismissed) sessions receive their per-epoch motion and band-state arrays.
        // Missing streams remain absent rather than being materialised as synthetic zero arrays.
        if (kept.isNotEmpty()) repo.upsertSleepSessions(kept)
        val keptStarts = kept.map { it.startTs }.toHashSet()
        val motionByStart = HashMap<Long, List<Double>>()
        val sleepStateByStart = HashMap<Long, List<Int>>()
        for (result in scoredNights) {
            for ((start, motion) in result.sessionMotionByStart) {
                if (start in keptStarts) motionByStart[start] = motion
            }
            for ((start, states) in result.sessionSleepStateByStart) {
                if (start in keptStarts) sleepStateByStart[start] = states
            }
        }
        for ((start, motion) in motionByStart) repo.persistSessionMotion(computedId, start, motion)
        for ((start, states) in sleepStateByStart) repo.persistSessionSleepState(computedId, start, states)
    }
}

/** Keep the oversized scoring orchestrator at a single, auditable transactional call site. */
internal suspend fun WhoopRepository.replaceComputedScoreWindow(
    window: IntelligencePersistence.ComputedWindow,
) = replaceComputedScoreWindow(
    deviceId = window.deviceId,
    from = window.from,
    to = window.to,
    dailyMetrics = window.dailies,
    metricPoints = window.metricRows,
    provenance = window.provenance,
    replaceMetricKeys = listOf(DayCycleIntelligenceIntegration.ONSET_KEY),
    replaceMetricSourceIds = window.markerSourceIds,
)
