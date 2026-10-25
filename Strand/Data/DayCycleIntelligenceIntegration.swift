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
    /// A cycle's Effort and calories, with the key of the inputs they were computed from.
    fileprivate struct CachedLoad {
        let key: String; let strain: Double?; let calories: Double?
    }
    final class Cache {
        fileprivate var cycles: [String: CachedCycle] = [:]
        fileprivate var loads: [String: CachedLoad] = [:]
    }
    private static func computedId(_ owner: String) -> String { owner + "-noop" }

    /// The cycle owner's own per-minute MET rows in `[from, to]` (#2242) — `nil` while the Experimental
    /// MET-calories toggle is off, which is the byte-identical HR path. Injected rather than read from
    /// `store` directly so the fold's MET decision can be pinned in a test without a live ring.
    typealias MetReader = (_ owner: String, _ from: Int, _ to: Int) async -> [Calories.MetSample]
    /// `(count, maxTs)` of the cycle owner's MET rows in `[from, to]`, the witness the load cache keys a
    /// MET-scored cycle on (#2242); `nil` return = unread, which never serves a cached load.
    typealias MetFingerprint = (_ owner: String, _ from: Int, _ to: Int) async -> (count: Int, maxTs: Int)?

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
                        metReader: MetReader? = nil,
                        metFingerprint: MetFingerprint? = nil,
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
        cache.loads = cache.loads.filter { entry in windows.contains(where: { $0.sleepId == entry.key }) }
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
            let restingHR = nights.first(where: { $0.daily.day == day })?.daily.restingHr.map(Double.init)
                ?? StrainScorer.defaultRestingHR
            let effectiveMaxHR = maxHROverride ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
            // Every pass re-read each cycle's full day of 1 Hz heart rate from every owner and re-scored it,
            // for all 21 cycles, although only the open one gains samples between syncs. On a replayed
            // phone database this was the costliest step of a pass in which every night was otherwise
            // reused (6–12 s of a 16 s pass). The index-only count and newest timestamp per owner witness
            // the heart rate the same way the day cache does, so a closed cycle is scored once.
            var hrWitness: [String] = []
            if hrEndInclusive >= window.onset {
                for owner in owners {
                    let fp = try? await store.hrFingerprint(deviceId: owner, from: window.onset, to: hrEndInclusive)
                    hrWitness.append("\(owner)=\(fp.map { "\($0.count):\($0.maxTs)" } ?? "unread")")
                }
            }
            // #2242: with the MET-calories toggle on, an ended cycle's calories come from the owner's MET
            // series, which the HR witness cannot see. Without this, a drain that banks MET minutes inside an
            // ended window leaves the key unchanged and the cache serves calories from the thinner stream.
            // `met=off` names the toggle state, so flipping it over unchanged data never serves the figure
            // cached under the other setting.
            let metWitness: String
            if metReader == nil {
                metWitness = "met=off"
            } else if hrEndInclusive < window.onset {
                metWitness = "met=empty"
            } else {
                let fp = await metFingerprint?(fallback, window.onset, hrEndInclusive)
                metWitness = "met=\(fallback)=\(fp.map { "\($0.count):\($0.maxTs)" } ?? "unread")"
            }
            let loadKey = "\(window.onset)-\(window.endExclusive)|\(hrWitness.joined(separator: ","))|\(metWitness)"
                + "|rhr=\(restingHR)|max=\(effectiveMaxHR.map { "\($0)" } ?? "nil")|\(effortMethod)|\(profile.cacheKey)"
            let load: CachedLoad
            if let hit = cache.loads[window.sleepId], hit.key == loadKey, !hrWitness.contains(where: { $0.hasSuffix("=unread") }),
               !metWitness.hasSuffix("=unread") {
                load = hit
            } else {
                var hrByTimestamp: [Int: HRSample] = [:]
                if hrEndInclusive >= window.onset {
                    for owner in owners {
                        let rows = (try? await store.hrSamples(
                            deviceId: owner, from: window.onset, to: hrEndInclusive, limit: 200_000)) ?? []
                        for row in rows where hrByTimestamp[row.ts] == nil { hrByTimestamp[row.ts] = row }
                    }
                }
                let cycleHR = hrByTimestamp.values.sorted { $0.ts < $1.ts }
                load = CachedLoad(
                    key: loadKey,
                    strain: StrainScorer.strain(cycleHR, maxHR: effectiveMaxHR, restingHR: restingHR,
                                                method: effortMethod, sex: profile.sex),
                    calories: await cycleCalories(
                        cycleHR, onset: window.onset, endExclusive: window.endExclusive, day: day, owner: fallback, hrEndInclusive: hrEndInclusive,
                        now: now, profile: profile, effectiveMaxHR: effectiveMaxHR, restingHR: restingHR,
                        metReader: metReader, trace: trace))
                cache.loads[window.sleepId] = load
            }
            if let strain = load.strain { strains[day] = strain }
            if let kcal = load.calories { calories[day] = kcal }
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

    /// The cycle's energy, by the SAME decision `AnalyticsEngine.analyzeDay` takes for the calendar day (#2242),
    /// over the wake-to-wake window `[onset, min(endExclusive, now))` instead. A device that measures its own
    /// minute-by-minute intensity decides it by that stream. This fold used to recompute Keytel over the
    /// cycle's HR unconditionally and `applying()` wrote that over the day's `activeKcalEst`, so on any phone
    /// with a day-cycle history the MET number never reached the row (2026-09-17: the log said 1220 kcal, the
    /// export held 743 — the HR figure). Below the coverage floor the cycle is WITHHELD — `nil`, and the HR
    /// figure is not substituted — exactly as on the day path. No reader (toggle off) or no rows = Keytel.
    private static func cycleCalories(_ cycleHR: [HRSample], onset: Int, endExclusive: Int, day: String,
                                      owner: String, hrEndInclusive: Int, now: Int, profile: UserProfile,
                                      effectiveMaxHR: Double?, restingHR: Double, metReader: MetReader?,
                                      trace: ((String) -> Void)?) async -> Double? {
        let cycleMet = hrEndInclusive >= onset ? await metReader?(owner, onset, hrEndInclusive) ?? [] : []
        if !cycleMet.isEmpty {
            let met = Calories.estimateDayEnergyFromMET(cycleMet, profile: profile,
                                                        dayStart: onset, dayEnd: min(endExclusive, now))
            let covered = met.coverageFraction >= Calories.metMinCoverageFraction
            trace?("stepsCycle calories day=\(day) path=met coverage=\(Int((met.coverageFraction * 100).rounded()))% "
                   + "active=\(Int(met.activeKcal.rounded())) total=\(Int(met.totalKcal.rounded())) "
                   + (covered ? "" : "withheld"))
            return covered ? met.totalKcal : nil
        }
        return cycleHR.isEmpty ? nil : Calories.estimateDayCalories(
            cycleHR, profile: profile, hrmax: effectiveMaxHR, restingHR: restingHR)
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
