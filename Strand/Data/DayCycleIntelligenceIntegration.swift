import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

@MainActor enum DayCycleIntelligenceIntegration {
    static let onsetKey = "day_cycle_onset_ts"
    static let pageSize = 10_000

    struct Night { let daily: DailyMetric; let sleeps: [CachedSleepSession]; let workouts: [ExerciseSession]; let owner: String }
    struct SourcedMarker: Sendable { let deviceId: String; let point: MetricPoint }
    struct BoundaryRecoveryReader {
        let sleepSessions: (String, Int, Int) async throws -> [CachedSleepSession]
        let markers: (String, String, String) async throws -> [MetricPoint]
    }
    enum MarkerUpdate {
        case preserve
        case replace(points: [SourcedMarker], sourceIds: [String])
    }
    struct Result {
        let stepsByWakeDay: [String: Int]
        let strainByWakeDay: [String: Double]
        let caloriesByWakeDay: [String: Double]
        let workoutCountByWakeDay: [String: Int]
        let onsetByWakeDay: [String: Int]
        let firstWakeDay: String?
        let markerUpdate: MarkerUpdate
    }
    struct PersistedBoundary {
        let boundary: PhysiologicalSteps.CycleBoundary
        let wakeDay: String
        let owner: String
        let sleepContext: SleepSession
    }
    fileprivate struct CachedCycle {
        let key: String; let count: SleepAwareStepCounter.Count
        let pages: Int; let samples: Int; let evaluated: Bool
    }
    final class Cache {
        fileprivate var cycles: [String: CachedCycle] = [:]
    }
    private static func computedId(_ owner: String) -> String { owner + "-noop" }

    static func recover(candidates: [(owner: String, priority: Int)], reader: BoundaryRecoveryReader,
                                claimedDays: Set<String>, windowStart: Int, now: Int,
                                offsetSec: Int, habitualMidsleepSec: Int?) async throws -> [PersistedBoundary] {
        var claimed = claimedDays, output: [PersistedBoundary] = []
        let fromDay = AnalyticsEngine.dayString(windowStart, offsetSec: offsetSec)
        let toDay = AnalyticsEngine.dayString(now, offsetSec: offsetSec)
        for candidate in candidates.sorted(by: {
            $0.priority == $1.priority ? $0.owner < $1.owner : $0.priority < $1.priority
        }) {
            let source = computedId(candidate.owner)
            let sessions = try await reader.sleepSessions(source, windowStart, now)
            let points = try await reader.markers(source, fromDay, toDay)
            let markers = Dictionary(points.compactMap { point -> (String, Int)? in
                let value = Int(point.value)
                return point.value == Double(value) ? (point.day, value) : nil
            }, uniquingKeysWith: { first, _ in first })
            let grouped = Dictionary(grouping: sessions) {
                AnalyticsEngine.dayString($0.endTs, offsetSec: offsetSec)
            }
            for day in grouped.keys.sorted() where !claimed.contains(day) {
                guard let marker = markers[day] else { continue }
                let rows = grouped[day] ?? []
                let blocks = rows.map { PhysiologicalSteps.SleepBlock(
                    onset: $0.startTs, end: $0.endTs, id: String($0.startTs),
                    editedOnset: $0.startTsAdjusted) }
                guard let winner = PhysiologicalSteps.classifyForCycle(
                    blocks, offsetSec: offsetSec, habitualMidsleepSec: habitualMidsleepSec)
                    .first(where: { $0.kind == .mainSleep && $0.effectiveOnset == marker }),
                      let row = rows.first(where: {
                          String($0.startTs) == winner.id && $0.effectiveStartTs == marker
                      }) else { continue }
                let context = SleepSession(start: row.effectiveStartTs, end: row.endTs,
                    efficiency: row.efficiency ?? 0, stages: AnalyticsEngine.decodeStages(row.stagesJSON),
                    restingHR: row.restingHr, avgHRV: row.avgHrv)
                output.append(PersistedBoundary(boundary: .init(
                    sleepId: "persisted:\(candidate.owner):\(row.startTs)", onset: marker),
                    wakeDay: day, owner: candidate.owner, sleepContext: context))
                claimed.insert(day)
            }
        }
        return output
    }

    static func compute(nights: [Night], editedRows: [CachedSleepSession], store: WhoopStore,
                        candidates: [(owner: String, priority: Int)], physiologyOwners: [String],
                        workouts: [WorkoutRow], windowStart: Int,
                        now: Int, offsetSec: Int, habitualMidsleepSec: Int?, ticksPerStep: Double,
                        mode: DayCycleMode, cache: Cache,
                        profile: UserProfile, maxHROverride: Double?, effortMethod: StrainScorer.Method,
                        recoveryReader: BoundaryRecoveryReader? = nil,
                        trace: ((String) -> Void)? = nil) async -> Result {
        guard mode == .sleepOnset else {
            return Result(stepsByWakeDay: [:], strainByWakeDay: [:], caloriesByWakeDay: [:],
                          workoutCountByWakeDay: [:], onsetByWakeDay: [:], firstWakeDay: nil,
                          markerUpdate: .replace(points: [], sourceIds: Array(Set(
                            candidates.map { computedId($0.owner) })).sorted()))
        }
        let editsByDay = Dictionary(grouping: editedRows) {
            AnalyticsEngine.dayString($0.endTs, offsetSec: offsetSec)
        }
        var boundaries: [PhysiologicalSteps.CycleBoundary] = []
        var wakeDayById: [String: String] = [:], ownerById: [String: String] = [:]
        var sleepContexts: [SleepSession] = []
        for night in nights {
            let dayEdits = editsByDay[night.daily.day] ?? []
            let edits = Dictionary(dayEdits.map { ($0.startTs, $0) }, uniquingKeysWith: { first, _ in first })
            let detectedStarts = Set(night.sleeps.map(\.startTs))
            var blocks: [PhysiologicalSteps.SleepBlock] = []
            for row in night.sleeps {
                let edit = edits[row.startTs]
                let start = edit?.effectiveStartTs ?? row.effectiveStartTs
                let end = edit?.endTs ?? row.endTs
                blocks.append(.init(onset: row.startTs, end: end, id: String(row.startTs), editedOnset: start))
                sleepContexts.append(SleepSession(start: start, end: end,
                    efficiency: row.efficiency ?? 0, stages: AnalyticsEngine.decodeStages(row.stagesJSON),
                    restingHR: row.restingHr, avgHRV: row.avgHrv))
            }
            for edit in dayEdits where !detectedStarts.contains(edit.startTs) {
                blocks.append(.init(onset: edit.startTs, end: edit.endTs,
                    id: "manual:\(edit.startTs)", editedOnset: edit.startTsAdjusted, kind: .nap))
                sleepContexts.append(SleepSession(start: edit.effectiveStartTs, end: edit.endTs,
                    efficiency: 0, stages: [], restingHR: nil, avgHRV: nil))
            }
            let classified = PhysiologicalSteps.classifyForCycle(
                blocks, offsetSec: offsetSec, habitualMidsleepSec: habitualMidsleepSec)
            guard let winner = classified.filter({ $0.kind == .mainSleep })
                .min(by: { $0.effectiveOnset < $1.effectiveOnset }), winner.effectiveOnset <= now else { continue }
            boundaries.append(.init(sleepId: winner.id, onset: winner.effectiveOnset))
            wakeDayById[winner.id] = night.daily.day; ownerById[winner.id] = night.owner
        }

        let recovered: [PersistedBoundary]
        do {
            let productionReader = BoundaryRecoveryReader(
                sleepSessions: { source, from, to in
                    try await store.sleepSessions(deviceId: source, from: from, to: to, limit: 4_000)
                },
                markers: { source, fromDay, toDay in
                    try await store.metricSeries(
                        deviceId: source, key: onsetKey, from: fromDay, to: toDay)
                })
            recovered = try await recover(candidates: candidates,
                reader: recoveryReader ?? productionReader,
                claimedDays: Set(wakeDayById.values), windowStart: windowStart, now: now,
                offsetSec: offsetSec, habitualMidsleepSec: habitualMidsleepSec)
        } catch {
            // Fail closed: an unread namespace is unknown, not empty. Returning no replacement source IDs
            // prevents the persistence transaction from deleting valid markers after a transient read error.
            trace?("stepsCycle status=error error=boundaryRecoveryRead")
            return Result(stepsByWakeDay: [:], strainByWakeDay: [:], caloriesByWakeDay: [:],
                          workoutCountByWakeDay: [:], onsetByWakeDay: [:], firstWakeDay: nil,
                          markerUpdate: .preserve)
        }
        for item in recovered {
            boundaries.append(item.boundary); wakeDayById[item.boundary.sleepId] = item.wakeDay
            ownerById[item.boundary.sleepId] = item.owner; sleepContexts.append(item.sleepContext)
        }
        if let latest = boundaries.max(by: { $0.onset < $1.onset }),
           let day = wakeDayById[latest.sleepId], let owner = ownerById[latest.sleepId] {
            let active = DayCycleResolver.activeWindow(mode: mode,
                latestSleep: DayCycleWindow(id: latest.sleepId, startInclusive: latest.onset,
                    endExclusive: now, displayDay: day, source: .detectedSleep), now: now,
                offsetSec: offsetSec)
            if active.source == .syntheticMidnight {
                boundaries.append(.init(sleepId: active.id, onset: active.startInclusive))
                wakeDayById[active.id] = active.displayDay; ownerById[active.id] = owner
            }
        }

        let windows = PhysiologicalSteps.cycleWindows(boundaries, now: now)
        cache.cycles = cache.cycles.filter { entry in windows.contains(where: { $0.sleepId == entry.key }) }
        let priorities = Dictionary(candidates.map { ($0.owner, $0.priority) }, uniquingKeysWith: min)
        let witnesses = Dictionary(uniqueKeysWithValues: nights.map { night in
            let sleeps = night.sleeps.sorted { $0.startTs < $1.startTs }.map {
                "\($0.startTs)-\($0.endTs):\($0.stagesJSON ?? "")"
            }.joined(separator: "|")
            return (night.daily.day, "\(night.owner):\(night.daily.steps.map(String.init) ?? "nil")|\(sleeps)")
        })
        var steps: [String: Int] = [:], onsets: [String: Int] = [:]
        var strains: [String: Double] = [:], calories: [String: Double] = [:]
        var workoutCounts: [String: Int] = [:]
        windowLoop: for window in windows {
            guard let day = wakeDayById[window.sleepId], let fallback = ownerById[window.sleepId] else { continue }
            do {
            onsets[day] = window.onset
            // Store ranges are inclusive. Read the active-first WHOOP + canonical union without borrowing
            // step coverage: an HR-only device may legitimately have no step rows.
            let hrEndInclusive = window.endExclusive - 1
            let owners = ([fallback] + physiologyOwners).reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            var hrByTimestamp: [Int: HRSample] = [:]
            if hrEndInclusive >= window.onset {
                for owner in owners {
                    let rows = (try? await store.hrSamples(
                        deviceId: owner, from: window.onset, to: hrEndInclusive, limit: 200_000)) ?? []
                    for row in rows where hrByTimestamp[row.ts] == nil { hrByTimestamp[row.ts] = row }
                }
            }
            let cycleHR = hrByTimestamp.values.sorted { $0.ts < $1.ts }
            let restingHR = nights.first(where: { $0.daily.day == day })?.daily.restingHr.map(Double.init)
                ?? StrainScorer.defaultRestingHR
            let effectiveMaxHR = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
            if let strain = StrainScorer.strain(cycleHR, maxHR: effectiveMaxHR,
                                                restingHR: restingHR, method: effortMethod,
                                                sex: profile.sex) { strains[day] = strain }
            if !cycleHR.isEmpty {
                calories[day] = Calories.estimateDayCalories(
                    cycleHR, profile: profile, hrmax: effectiveMaxHR, restingHR: restingHR)
            }
            let persistedWorkoutKeys = workouts
                .filter { $0.startTs >= window.onset && $0.startTs < window.endExclusive }
                .map { "\($0.startTs):\($0.endTs)" }
            let freshDetectedKeys = nights.flatMap(\.workouts)
                .filter { $0.start >= window.onset && $0.start < window.endExclusive }
                .filter { detected in
                    !workouts.contains { persisted in
                        detected.start < persisted.endTs && persisted.startTs < detected.end
                    }
                }
                .map { "\($0.start):\($0.end)" }
            workoutCounts[day] = Set(persistedWorkoutKeys + freshDetectedKeys).count
            var ranked = priorities; ranked[fallback] = ranked[fallback] ?? ranked.values.min() ?? 0
            var coverage: [PhysiologicalSteps.OwnerCoverage] = []
            for (owner, priority) in ranked {
                let span = try await store.stepTimestampCoverage(
                    deviceId: owner, from: window.onset, to: window.endExclusive)
                if let first = span.first, let last = span.last {
                    coverage.append(.init(owner: owner, onset: first,
                        endExclusive: min(last + 1, window.endExclusive), priority: priority))
                }
            }
            let segments = PhysiologicalSteps.ownerSegmentsFromCoverage(
                window, coverage: coverage, fallbackOwner: fallback)
            guard !segments.isEmpty else { continue }
            let active = window.endExclusive == now
            let identity = segments.enumerated().map { index, segment in
                "\(segment.owner):\(segment.onset)-\(active && index == segments.count - 1 ? 0 : segment.endExclusive)"
            }.joined(separator: ",")
            var revisions: [String] = []
            for segment in segments {
                let revision = await store.stepDataRevisionSignature(
                    deviceId: segment.owner, from: segment.onset, to: segment.endExclusive)
                revisions.append("\(segment.owner)=\(revision)")
            }
            let contextSignature = sleepContexts.filter { $0.end > window.onset && $0.start < window.endExclusive }
                .sorted { $0.start < $1.start }.map { sleep in
                    "\(sleep.start)-\(sleep.end):" + sleep.stages.sorted { $0.start < $1.start }
                        .map { "\($0.start)-\($0.end)=\($0.stage)" }.joined(separator: ":")
                }.joined(separator: "|")
            let firstDay = AnalyticsEngine.dayString(window.onset, offsetSec: offsetSec)
            let lastDay = AnalyticsEngine.dayString(max(window.onset, window.endExclusive - 1), offsetSec: offsetSec)
            let dayWitness = witnesses.keys.filter { $0 >= firstDay && $0 <= lastDay }.sorted()
                .map { "\($0)=\(witnesses[$0] ?? "")" }.joined(separator: "|")
            let key = "\(identity)|\(window.sleepId)|\(window.onset)|\(active ? 0 : window.endExclusive)"
                + "|stepRevision=\(revisions.joined(separator: "|"))|sleepContext=\(contextSignature)"
                + "|days=\(dayWitness)"
            var cached = cache.cycles[window.sleepId]
            if cached?.key != key {
                var count = SleepAwareStepCounter.Count.empty, pages = 0, samples = 0, evaluated = false
                for (index, segment) in segments.enumerated() {
                    let hasClasses = try await store.hasStepActivityClasses(
                        deviceId: segment.owner, from: segment.onset, to: segment.endExclusive)
                    let accumulator = SleepAwareStepCounter.Accumulator(
                        sleepSessions: sleepContexts, hasActivityClasses: hasClasses)
                    var segmentSamples = 0
                    if index == 0, let predecessor = try await store.stepSampleBefore(
                        deviceId: segment.owner, before: segment.onset) {
                        accumulator.acceptPage([predecessor]); samples += 1; segmentSamples += 1
                    }
                    var cursor = segment.onset - 1
                    while cursor < segment.endExclusive {
                        let page = try await store.stepSamplesPage(deviceId: segment.owner,
                            afterExclusive: cursor, endExclusive: segment.endExclusive, limit: pageSize)
                        guard !page.isEmpty else { break }
                        accumulator.acceptPage(page); pages += 1; samples += page.count; segmentSamples += page.count
                        guard let last = page.last, last.ts >= cursor else { break }
                        cursor = last.ts
                        if page.count < pageSize { break }
                    }
                    let motion = try? await store.stepDiagnosticMotionCounts(
                        deviceId: segment.owner, from: segment.onset, to: segment.endExclusive)
                    accumulator.observeMotion(gravityCount: motion?.gravity ?? 0, auxCount: motion?.aux ?? 0)
                    if segmentSamples >= 2 { evaluated = true }
                    count = count.adding(accumulator.finish())
                }
                cached = CachedCycle(key: key, count: count, pages: pages, samples: samples, evaluated: evaluated)
                cache.cycles[window.sleepId] = cached
            }
            guard let result = cached, result.evaluated else { continue }
            let scaled = Int((Double(result.count.totalTicks) / max(ticksPerStep, 0.5)).rounded())
            steps[day] = scaled
            let status = active ? "active" : "closed"
            trace?("stepsCycle wakeDay=\(day) status=\(status) onsetTs=\(window.onset) "
                + "endTs=\(window.endExclusive) owner=\(identity) pages=\(result.pages) samples=\(result.samples) "
                + "totalTicks=\(result.count.totalTicks) outside=\(result.count.acceptedOutsideSleepTicks) "
                + "awakeGap=\(result.count.acceptedAwakeGapTicks) sleepBout=\(result.count.acceptedSleepBoutTicks) "
                + "rejectedIsolatedSleep=\(result.count.rejectedIsolatedSleepTicks) "
                + "rejectedClass=\(result.count.rejectedActivityClassTicks) "
                + "rejectedImplausible=\(result.count.rejectedImplausibleTicks) "
                + "gravitySamples=\(result.count.gravitySamplesAvailable) auxSamples=\(result.count.auxSamplesAvailable) "
                + "ticksPerStep=\(ticksPerStep) scaledSteps=\(scaled)")
            } catch {
                trace?("stepsCycle wakeDay=\(day) status=error error=databaseRead")
                continue windowLoop
            }
        }
        let recoveredMarkers = recovered.map { SourcedMarker(deviceId: computedId($0.owner),
            point: MetricPoint(day: $0.wakeDay, key: onsetKey, value: Double($0.boundary.onset))) }
        return Result(stepsByWakeDay: steps, strainByWakeDay: strains, caloriesByWakeDay: calories,
            workoutCountByWakeDay: workoutCounts, onsetByWakeDay: onsets,
            firstWakeDay: wakeDayById.values.min(), markerUpdate: .replace(
                points: recoveredMarkers,
                sourceIds: Array(Set(candidates.map { computedId($0.owner) })).sorted()))
    }

    static func applying(_ result: Result, to daily: DailyMetric) -> DailyMetric {
        let established = result.firstWakeDay.map { daily.day >= $0 } ?? false
        let steps = established ? result.stepsByWakeDay[daily.day] : daily.steps
        let strain = established ? result.strainByWakeDay[daily.day] : daily.strain
        let calories = established ? result.caloriesByWakeDay[daily.day] : daily.activeKcalEst
        let workouts = established ? result.workoutCountByWakeDay[daily.day] : daily.exerciseCount
        return DailyMetric(day: daily.day, totalSleepMin: daily.totalSleepMin, efficiency: daily.efficiency,
            deepMin: daily.deepMin, remMin: daily.remMin, lightMin: daily.lightMin,
            disturbances: daily.disturbances, restingHr: daily.restingHr, avgHrv: daily.avgHrv,
            recovery: daily.recovery, strain: strain, exerciseCount: workouts,
            spo2Pct: daily.spo2Pct, skinTempDevC: daily.skinTempDevC, respRateBpm: daily.respRateBpm,
            steps: steps, activeKcalEst: calories, spo2Red: daily.spo2Red,
            spo2Ir: daily.spo2Ir, avgSdnn: daily.avgSdnn,
            skinTempC: daily.skinTempC, sleepHrOnly: daily.sleepHrOnly)
    }
}
