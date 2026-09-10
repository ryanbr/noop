package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository

/** Narrow adapter between the generic day-cycle domain and the legacy scoring orchestrator. */
internal object DayCycleIntelligenceIntegration {
    const val ONSET_KEY = "day_cycle_onset_ts"

    internal data class PersistedBoundary(
        val boundary: PhysiologicalSteps.CycleBoundary,
        val wakeDay: String,
        val owner: String,
        val sleepContext: DetectedSleep,
    )

    fun integratedStepValue(calendarSteps: Int?, established: Boolean, cycleSteps: Int?): Int? =
        if (established) cycleSteps else calendarSteps

    fun markerRewriteSourceIds(
        currentComputedSources: List<String>,
        candidateComputedSources: List<String>,
    ): List<String> = (currentComputedSources + candidateComputedSources).distinct()

    fun persistedBoundaries(
        candidates: List<Pair<String, Int>>,
        sessionsByOwner: Map<String, List<SleepSession>>,
        markerOnsetByOwnerAndDay: Map<String, Map<String, Long>>,
        currentBoundaryWakeDays: Set<String>,
        tzOffsetSeconds: Long,
        habitualMidsleepSec: Long?,
    ): List<PersistedBoundary> {
        val claimedDays = currentBoundaryWakeDays.toMutableSet()
        val recovered = ArrayList<PersistedBoundary>()
        for ((owner, _) in candidates.sortedWith(compareBy<Pair<String, Int>> { it.second }.thenBy { it.first })) {
            val sessionsByWakeDay = sessionsByOwner[owner].orEmpty()
                .filter { it.endTs > it.effectiveStartTs }
                .groupBy { AnalyticsEngine.dayString(it.endTs, tzOffsetSeconds) }
            for ((wakeDay, sessions) in sessionsByWakeDay.toSortedMap()) {
                if (wakeDay in claimedDays) continue
                val markerOnset = markerOnsetByOwnerAndDay[owner]?.get(wakeDay) ?: continue
                val blocks = sessions.map { session ->
                    PhysiologicalSteps.SleepBlock(
                        session.startTs, session.endTs, session.startTs.toString(), session.startTsAdjusted,
                    )
                }
                val winner = PhysiologicalSteps.classifyForCycle(
                    blocks, tzOffsetSeconds, habitualMidsleepSec,
                ).firstOrNull {
                    it.kind == PhysiologicalSteps.SleepKind.MAIN_SLEEP && it.effectiveOnset == markerOnset
                } ?: continue
                val persisted = sessions.firstOrNull {
                    it.startTs.toString() == winner.id && it.effectiveStartTs == markerOnset
                } ?: continue
                recovered += PersistedBoundary(
                    PhysiologicalSteps.CycleBoundary("persisted:$owner:${persisted.startTs}", markerOnset),
                    wakeDay,
                    owner,
                    DetectedSleep(
                        persisted.effectiveStartTs, persisted.endTs, persisted.efficiency ?: 0.0,
                        AnalyticsEngine.decodeStages(persisted.stagesJSON), persisted.restingHr, persisted.avgHrv,
                    ),
                )
                claimedDays += wakeDay
            }
        }
        return recovered
    }

    fun recoveredMarkerRows(
        recovered: List<PersistedBoundary>,
        computedDeviceId: (String) -> String,
    ): List<MetricSeriesRow> = recovered.map {
        MetricSeriesRow(computedDeviceId(it.owner), it.wakeDay, ONSET_KEY, it.boundary.onset.toDouble())
    }

    fun cacheKey(
        owner: String,
        sleepId: String,
        onset: Long,
        end: Long,
        stepRevision: String,
        sleepContextSignature: String,
        contributingDayKeys: List<Pair<String, String>>,
    ): String = buildString {
        append(owner).append('|').append(sleepId).append('|').append(onset).append('|').append(end)
            .append("|stepRevision=").append(stepRevision)
            .append("|sleepContext=").append(sleepContextSignature)
        for ((day, witness) in contributingDayKeys.sortedBy { it.first }) append('|').append(day).append('=').append(witness)
    }

    fun shouldRecount(cachedKey: String?, currentKey: String): Boolean = cachedKey != currentKey

    private fun dayWitness(owner: String, result: DayResult): String = buildString {
        append(owner).append(':').append(result.daily.steps ?: "nil")
        for (sleep in result.sleepSessions.sortedBy { it.start }) {
            append('|').append(sleep.start).append('-').append(sleep.end).append(':').append(sleep.stages.hashCode())
        }
    }

    suspend fun compute(
        scoredNights: List<DayResult>,
        editedRows: List<SleepSession>,
        resolvedOwners: Map<String, String>,
        candidatePriorities: List<Pair<String, Int>>,
        repo: WhoopRepository,
        tzOffsetSeconds: Long,
        habitualMidsleepSec: Long?,
        windowStart: Long,
        nowSeconds: Long,
        stepTicksPerStep: Double,
        traceSink: ((String) -> Unit)?,
        mode: DayCycleMode,
        profile: UserProfile,
        maxHROverride: Double?,
        effortMethod: StrainScorer.Method,
    ): PhysiologicalStepCycleEngine.Result {
        val witnesses = scoredNights.associate { result ->
            result.daily.day to dayWitness(resolvedOwners[result.daily.day].orEmpty(), result)
        }
        return PhysiologicalStepCycleEngine.compute(
            scoredNights, editedRows, resolvedOwners, candidatePriorities, witnesses, repo,
            tzOffsetSeconds, habitualMidsleepSec, windowStart, nowSeconds, stepTicksPerStep, traceSink, mode,
            profile, maxHROverride, effortMethod,
        )
    }

    fun apply(
        daily: DailyMetric,
        result: PhysiologicalStepCycleEngine.Result,
        computedId: String,
        metricRows: MutableList<MetricSeriesRow>,
    ): DailyMetric {
        val established = result.firstCycleWakeDay?.let { daily.day >= it } == true
        result.boundaryOnsetByWakeDay[daily.day]?.let { onset ->
            metricRows += MetricSeriesRow(computedId, daily.day, ONSET_KEY, onset.toDouble())
        }
        return daily.copy(
            steps = integratedStepValue(daily.steps, established, result.cycleStepsByWakeDay[daily.day]),
            strain = if (established) result.cycleStrainByWakeDay[daily.day] else daily.strain,
            activeKcalEst = if (established) result.cycleCaloriesByWakeDay[daily.day] else daily.activeKcalEst,
            exerciseCount = if (established) result.cycleWorkoutCountByWakeDay[daily.day] else daily.exerciseCount,
        )
    }
}
