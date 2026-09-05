package com.noop.analytics

import com.noop.data.MetricSeriesRow
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import kotlin.math.roundToLong

/**
 * Sleep-onset-to-sleep-onset step materialisation. Kept outside [IntelligenceEngine]'s already-large
 * scoring method so the JVM method stays below its 64 KiB bytecode limit and the feature has one boundary.
 * The cache retains summaries only; raw step pages are released immediately after each segment.
 */
internal object PhysiologicalStepCycleEngine {
    data class Result(
        val cycleStepsByWakeDay: Map<String, Int>,
        val cycleStrainByWakeDay: Map<String, Double>,
        val cycleCaloriesByWakeDay: Map<String, Double>,
        val cycleWorkoutCountByWakeDay: Map<String, Int>,
        val boundaryOnsetByWakeDay: Map<String, Long>,
        val firstCycleWakeDay: String?,
        val recoveredOwnerMarkerRows: List<MetricSeriesRow>,
    )

    private data class CachedCycleSteps(
        val key: String,
        val count: SleepAwareStepCounter.Count,
        val pages: Int,
        val samples: Int,
        val evaluated: Boolean,
    )

    /** Process-local and serialized by IntelligenceEngine's analyze gate. */
    private val cache = HashMap<String, CachedCycleSteps>()

    suspend fun compute(
        scoredNights: List<DayResult>,
        editedRows: List<SleepSession>,
        resolvedScoreOwnerByDay: Map<String, String>,
        candidatePriorities: List<Pair<String, Int>>,
        stepWitnessByDay: Map<String, String>,
        repo: WhoopRepository,
        tzOffsetSeconds: Long,
        habitualMidsleepSec: Long?,
        windowStart: Long,
        nowSeconds: Long,
        stepTicksPerStep: Double,
        stepsTraceSink: ((String) -> Unit)?,
        dayCycleMode: DayCycleMode,
        profile: UserProfile,
        maxHROverride: Double?,
        effortMethod: StrainScorer.Method,
    ): Result {
        if (dayCycleMode == DayCycleMode.MIDNIGHT) {
            return Result(emptyMap(), emptyMap(), emptyMap(), emptyMap(), emptyMap(), null, emptyList())
        }
        val editedRowsByDay = editedRows.groupBy {
            AnalyticsEngine.dayString(it.endTs, tzOffsetSeconds)
        }
        val boundaries = ArrayList<PhysiologicalSteps.CycleBoundary>()
        val dayBySleepId = LinkedHashMap<String, String>()
        val ownerBySleepId = LinkedHashMap<String, String>()
        val sleepContext = ArrayList<DetectedSleep>()
        val recovered = ArrayList<DayCycleIntelligenceIntegration.PersistedBoundary>()

        for (res in scoredNights) {
            val dayEdits = editedRowsByDay[res.daily.day].orEmpty()
            val editsByDetectedStart = dayEdits.associateBy { it.startTs }
            val detectedStarts = res.sleepSessions.mapTo(HashSet()) { it.start }
            val blocks = buildList {
                for (session in res.sleepSessions) {
                    val edit = editsByDetectedStart[session.start]
                    sleepContext += SleepAwareStepCounter.withBounds(
                        session,
                        start = edit?.effectiveStartTs ?: session.start,
                        end = edit?.endTs ?: session.end,
                    )
                    add(
                        PhysiologicalSteps.SleepBlock(
                            onset = session.start,
                            end = edit?.endTs ?: session.end,
                            id = session.start.toString(),
                            editedOnset = edit?.effectiveStartTs,
                        ),
                    )
                }
                for (edit in dayEdits) {
                    if (edit.startTs !in detectedStarts) {
                        add(
                            PhysiologicalSteps.SleepBlock(
                                onset = edit.startTs,
                                end = edit.endTs,
                                id = "manual:${edit.startTs}",
                                editedOnset = edit.startTsAdjusted,
                                kind = PhysiologicalSteps.SleepKind.NAP,
                            ),
                        )
                        sleepContext += DetectedSleep(
                            start = edit.effectiveStartTs,
                            end = edit.endTs,
                            efficiency = 0.0,
                            stages = emptyList(),
                            restingHR = null,
                            avgHRV = null,
                        )
                    }
                }
            }
            val classified = PhysiologicalSteps.classifyForCycle(
                blocks, tzOffsetSeconds, habitualMidsleepSec,
            )
            PhysiologicalSteps.mainSleepOnset(
                classified, tzOffsetSeconds, habitualMidsleepSec,
            )?.let { onset ->
                val winner = classified.firstOrNull {
                    it.kind == PhysiologicalSteps.SleepKind.MAIN_SLEEP && it.effectiveOnset == onset
                } ?: return@let
                boundaries += PhysiologicalSteps.CycleBoundary(winner.id, onset)
                dayBySleepId[winner.id] = res.daily.day
                resolvedScoreOwnerByDay[res.daily.day]?.let { ownerBySleepId[winner.id] = it }
            }
        }

        if (candidatePriorities.isNotEmpty()) {
            val markerFromDay = AnalyticsEngine.dayString(windowStart, tzOffsetSeconds)
            val markerToDay = AnalyticsEngine.dayString(nowSeconds, tzOffsetSeconds)
            val sessionsByOwner = LinkedHashMap<String, List<SleepSession>>()
            val markersByOwner = LinkedHashMap<String, Map<String, Long>>()
            for (owner in candidatePriorities.map { it.first }.distinct()) {
                val ownerComputedId = repo.computedDeviceId(owner)
                sessionsByOwner[owner] = repo.sleepSessionsForDevice(
                    ownerComputedId, windowStart, nowSeconds, limit = 4_000,
                )
                markersByOwner[owner] = repo.metricSeries(
                    ownerComputedId,
                    DayCycleIntelligenceIntegration.ONSET_KEY,
                    markerFromDay,
                    markerToDay,
                ).mapNotNull { row ->
                    val onset = row.value.toLong()
                    if (row.value == onset.toDouble()) row.day to onset else null
                }.toMap()
            }
            for (item in DayCycleIntelligenceIntegration.persistedBoundaries(
                candidates = candidatePriorities,
                sessionsByOwner = sessionsByOwner,
                markerOnsetByOwnerAndDay = markersByOwner,
                currentBoundaryWakeDays = dayBySleepId.values.toHashSet(),
                tzOffsetSeconds = tzOffsetSeconds,
                habitualMidsleepSec = habitualMidsleepSec,
            )) {
                recovered += item
                boundaries += item.boundary
                dayBySleepId[item.boundary.sleepId] = item.wakeDay
                ownerBySleepId[item.boundary.sleepId] = item.owner
                sleepContext += item.sleepContext
            }
        }

        // Resolve the open tail through the shared day-cycle policy. Step storage proves strap coverage,
        // not wakefulness: a missed sleep detection has the same endpoints. Until a dedicated, validated
        // awake signal exists, unknown therefore takes the safe midnight fallback.
        boundaries.maxByOrNull { it.onset }?.let { latest ->
            val wakeDay = dayBySleepId[latest.sleepId]
            val owner = ownerBySleepId[latest.sleepId]
            if (wakeDay != null && owner != null) {
                val active = DayCycleResolver.activeWindow(
                    mode = dayCycleMode,
                    latestSleep = DayCycleWindow(
                        id = latest.sleepId,
                        startInclusive = latest.onset,
                        endExclusive = nowSeconds,
                        displayDay = wakeDay,
                        source = DayCycleWindow.Source.DETECTED_SLEEP,
                    ),
                    now = nowSeconds,
                    tzOffsetSeconds = tzOffsetSeconds,
                )
                if (active.source == DayCycleWindow.Source.SYNTHETIC_MIDNIGHT) {
                    val synthetic = PhysiologicalSteps.CycleBoundary(active.id, active.startInclusive)
                    boundaries += synthetic
                    dayBySleepId[synthetic.sleepId] = active.displayDay
                    ownerBySleepId[synthetic.sleepId] = owner
                }
            }
        }

        val stepsByWakeDay = HashMap<String, Int>()
        val strainByWakeDay = HashMap<String, Double>()
        val caloriesByWakeDay = HashMap<String, Double>()
        val workoutCountByWakeDay = HashMap<String, Int>()
        val windows = PhysiologicalSteps.cycleWindows(boundaries, nowSeconds)
        val allDetectedSleep = sleepContext.distinctBy { it.start to it.end }
        cache.keys.retainAll(windows.mapTo(HashSet()) { it.sleepId })
        for (window in windows) {
            val wakeDay = dayBySleepId[window.sleepId] ?: continue
            val fallbackOwner = ownerBySleepId[window.sleepId] ?: continue
            // DAO ranges are inclusive. Keep adjacent physiological cycles disjoint.
            val cycleHr = repo.hrSamplesUnion(
                fallbackOwner, window.onset, window.endExclusive - 1L, 200_000,
            )
            val restingHr = scoredNights.firstOrNull { it.daily.day == wakeDay }?.daily?.restingHr?.toDouble()
                ?: StrainScorer.defaultRestingHR
            val effectiveMaxHr = maxHROverride
                ?: profile.age.takeIf { it > 0 }?.let { StrainScorer.tanakaHRmax(it.toDouble()) }
            StrainScorer.strain(cycleHr, effectiveMaxHr, restingHr, effortMethod, profile.sex)
                ?.let { strainByWakeDay[wakeDay] = it }
            if (cycleHr.isNotEmpty()) {
                caloriesByWakeDay[wakeDay] = Calories.estimateDayCalories(
                    cycleHr, profile, effectiveMaxHr, restingHr,
                )
            }
            // Count the persisted all-source workout union, not only analyzer-detected bouts. Repository
            // reads are inclusive, while ownership is [onset, nextOnset).
            val workoutEndInclusive = window.endExclusive - 1L
            val cycleWorkouts = (
                repo.workoutsUnion(fallbackOwner, window.onset, workoutEndInclusive, 100_000) +
                    repo.detectedWorkoutsUnion(fallbackOwner, window.onset, workoutEndInclusive, 100_000) +
                    listOf("apple-health", "health-connect", "lifting", "activity-file").flatMap { source ->
                        repo.workouts(source, window.onset, workoutEndInclusive, 100_000)
                    }
                ).distinctBy { Triple(it.startTs, it.endTs, it.sport) }
            val freshDetectedKeys = scoredNights.asSequence().flatMap { it.workouts.asSequence() }
                .filter { it.start >= window.onset && it.start < window.endExclusive }
                .filter { detected ->
                    cycleWorkouts.none { persisted ->
                        detected.start < persisted.endTs && persisted.startTs < detected.end
                    }
                }
                .map { it.start to it.end }
                .toList()
            workoutCountByWakeDay[wakeDay] = (
                cycleWorkouts.map { it.startTs to it.endTs } + freshDetectedKeys
                ).distinct().size
            val priorities = LinkedHashMap<String, Int>()
            for ((owner, priority) in candidatePriorities) priorities[owner] = priority
            priorities.putIfAbsent(fallbackOwner, priorities.values.minOrNull() ?: 0)
            val coverage = priorities.mapNotNull { (owner, priority) ->
                val span = repo.stepTimestampCoverage(owner, window.onset, window.endExclusive)
                val first = span.firstTs
                val last = span.lastTs
                if (first == null || last == null) null else PhysiologicalSteps.OwnerCoverage(
                    owner, first, (last + 1L).coerceAtMost(window.endExclusive), priority,
                )
            }
            val segments = PhysiologicalSteps.ownerSegmentsFromCoverage(window, coverage, fallbackOwner)
            if (segments.isEmpty()) continue
            val active = window.endExclusive == nowSeconds
            val ownerIdentity = segments.mapIndexed { index, segment ->
                val identityEnd = if (active && index == segments.lastIndex) 0L else segment.endExclusive
                "${segment.owner}:${segment.onset}-$identityEnd"
            }.joinToString(",")
            val stepRevision = segments.joinToString("|") { segment ->
                "${segment.owner}=" + repo.stepDataRevisionSignature(
                    segment.owner, segment.onset, segment.endExclusive,
                )
            }
            val contextSignature = SleepAwareStepCounter.contextSignature(
                allDetectedSleep, window.onset, window.endExclusive,
            )
            val firstDay = AnalyticsEngine.dayString(window.onset, tzOffsetSeconds)
            val lastDay = AnalyticsEngine.dayString(
                (window.endExclusive - 1L).coerceAtLeast(window.onset), tzOffsetSeconds,
            )
            val witnesses = stepWitnessByDay.entries.asSequence()
                .filter { it.key >= firstDay && it.key <= lastDay }
                .map { it.key to it.value }
                .toList()
            val key = DayCycleIntelligenceIntegration.cacheKey(
                owner = ownerIdentity,
                sleepId = window.sleepId,
                onset = window.onset,
                end = if (active) 0L else window.endExclusive,
                stepRevision = stepRevision,
                sleepContextSignature = contextSignature,
                contributingDayKeys = witnesses,
            )
            var cached = cache[window.sleepId]
            if (DayCycleIntelligenceIntegration.shouldRecount(cached?.key, key)) {
                var pages = 0
                var samples = 0
                var evaluated = false
                var combinedCount = SleepAwareStepCounter.Count.EMPTY
                for ((segmentIndex, segment) in segments.withIndex()) {
                    val hasClasses = repo.hasStepActivityClasses(
                        segment.owner, segment.onset, segment.endExclusive,
                    )
                    val accumulator = SleepAwareStepCounter.Accumulator(allDetectedSleep, hasClasses)
                    var segmentSamples = 0
                    if (PhysiologicalSteps.shouldReadCounterPredecessor(segmentIndex)) {
                        repo.stepSampleBefore(segment.owner, segment.onset)?.let {
                            accumulator.acceptPage(listOf(it))
                            samples++
                            segmentSamples++
                        }
                    }
                    var cursor = segment.onset - 1L
                    while (cursor < segment.endExclusive) {
                        val page = repo.stepSamplesPage(
                            segment.owner,
                            cursor,
                            segment.endExclusive,
                            IntelligenceEngine.PHYSIOLOGICAL_STEP_PAGE_SIZE,
                        )
                        if (page.isEmpty()) break
                        accumulator.acceptPage(page)
                        pages++
                        samples += page.size
                        segmentSamples += page.size
                        val next = page.last().ts
                        if (next <= cursor) break
                        cursor = next
                        if (page.size < IntelligenceEngine.PHYSIOLOGICAL_STEP_PAGE_SIZE) break
                    }
                    if (segmentSamples >= 2) evaluated = true
                    combinedCount += accumulator.finish()
                }
                cached = CachedCycleSteps(key, combinedCount, pages, samples, evaluated)
                cache[window.sleepId] = cached
            }
            val result = cached ?: continue
            if (result.evaluated) {
                val scaled = (result.count.totalTicks.toDouble() / maxOf(stepTicksPerStep, 0.5))
                    .roundToLong().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                stepsByWakeDay[wakeDay] = scaled
                stepsTraceSink?.invoke(
                    "stepsCycle wakeDay=$wakeDay status=${if (active) "active" else "closed"} " +
                        "onsetTs=${window.onset} endTs=${window.endExclusive} owner=$ownerIdentity " +
                        "pages=${result.pages} samples=${result.samples} " +
                        "totalTicks=${result.count.totalTicks} " +
                        "outside=${result.count.acceptedOutsideSleepTicks} " +
                        "awakeGap=${result.count.acceptedAwakeGapTicks} " +
                        "sleepBout=${result.count.acceptedSleepBoutTicks} " +
                        "rejectedIsolatedSleep=${result.count.rejectedIsolatedSleepTicks} " +
                        "rejectedClass=${result.count.rejectedActivityClassTicks} " +
                        "rejectedImplausible=${result.count.rejectedImplausibleTicks} " +
                        "gravitySamples=${result.count.gravitySamplesAvailable} " +
                        "auxSamples=${result.count.auxSamplesAvailable} " +
                        "ticksPerStep=$stepTicksPerStep " +
                        "scaledSteps=$scaled",
                )
            }
        }

        return Result(
            cycleStepsByWakeDay = stepsByWakeDay,
            cycleStrainByWakeDay = strainByWakeDay,
            cycleCaloriesByWakeDay = caloriesByWakeDay,
            cycleWorkoutCountByWakeDay = workoutCountByWakeDay,
            boundaryOnsetByWakeDay = boundaries.mapNotNull { boundary ->
                dayBySleepId[boundary.sleepId]?.let { it to boundary.onset }
            }.toMap(),
            firstCycleWakeDay = dayBySleepId.values.minOrNull(),
            recoveredOwnerMarkerRows = DayCycleIntelligenceIntegration.recoveredMarkerRows(
                recovered,
                repo::computedDeviceId,
            ),
        )
    }
}
