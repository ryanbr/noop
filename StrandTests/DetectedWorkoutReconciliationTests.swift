import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// #1735/#2187: the analytics detector may enrich workouts the user already logged, but the opt-in
/// confirmation card is the only path that creates a new visible automatic workout. A scoring pass must
/// therefore preserve legacy `sport="detected"` history verbatim, avoid inserting a fresh generic row,
/// and keep the useful overlap backfill for real manual/imported sessions.
@MainActor
final class DetectedWorkoutReconciliationTests: XCTestCase {
    private let deviceId = "my-whoop"

    private func withPreferences(_ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
            "profile.heightCm", "profile.hrMaxOverride", "profile.stepTicksPerStep",
            "noop.analyzeWatermark", "analyzeRecent.stepsMotionCache.v1",
            "noop.hrvBaselineEpoch", "noop.recoveryBaselineEpoch", UnitPrefs.hrvWindowKey,
            RescoreBackgroundScheduler.owedKey, RescoreBackgroundScheduler.owedTokenKey,
            RescoreBackgroundScheduler.lastPassSecondsKey, DayCycleMode.storageKey,
            PuffinExperiment.experimentalSleepV2Key, PuffinExperiment.motionAwareWakeKey,
            PuffinExperiment.autoDetectWorkoutsKey,
            WorkoutSource.dismissedDefaultsKey,
            "testcentre.active.workouts", "testcentre.active.master",
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(DayCycleMode.midnight.rawValue, forKey: DayCycleMode.storageKey)
        defaults.set(true, forKey: PuffinExperiment.experimentalSleepV2Key)
        defaults.set(false, forKey: PuffinExperiment.motionAwareWakeKey)
        defaults.set(false, forKey: PuffinExperiment.autoDetectWorkoutsKey)
        TestCentre.activate(.workouts)
        try await body()
    }

    private func activeBlock(start: Int, seconds: Int) -> (hr: [HRSample], gravity: [GravitySample]) {
        let hr = (0..<seconds).map { HRSample(ts: start + $0, bpm: 150) }
        let gravity = (0..<seconds).map { second in
            GravitySample(ts: start + second, x: second.isMultiple(of: 2) ? -0.6 : 0.6, y: 0, z: 1)
        }
        return (hr, gravity)
    }

    func testCandidateSelectionHonorsBothLegacyDismissalStores() {
        let older = DetectedWorkout(startSec: 1_000, endSec: 1_900,
                                    avgBpm: 130, peakBpm: 155, durationMin: 15)
        let newer = DetectedWorkout(startSec: 3_000, endSec: 3_900,
                                    avgBpm: 140, peakBpm: 165, durationMin: 15)

        XCTAssertEqual(
            Repository.selectAutoDetectCandidate(
                [older, newer],
                autoDismissedTokens: ["3000:3900"],
                detectedDismissedTokens: []),
            older,
            "an exact dismissal from the confirmation-card store must still suppress its candidate")

        XCTAssertEqual(
            Repository.selectAutoDetectCandidate(
                [older, newer],
                autoDismissedTokens: [],
                detectedDismissedTokens: ["2990:3910"]),
            older,
            "an overlapping legacy engine dismissal must suppress a boundary-shifted candidate")

        XCTAssertNil(
            Repository.selectAutoDetectCandidate(
                [older, newer],
                autoDismissedTokens: ["3000:3900"],
                detectedDismissedTokens: ["990:1910"]),
            "a candidate dismissed through either historical contract must never reappear")
    }

    func testLegacyRowsAreRemovedFromTheirArchivedComputedOwner() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let archivedComputedId = "whoop-archived-noop"
            let relabelled = WorkoutRow(
                startTs: 1_000, endTs: 1_900, sport: "detected", source: archivedComputedId,
                durationS: 900, energyKcal: 50, avgHr: 130, maxHr: 150, strain: 5,
                distanceM: nil, zonesJSON: nil, notes: "legacy", steps: nil)
            let dismissed = WorkoutRow(
                startTs: 3_000, endTs: 3_900, sport: "detected", source: archivedComputedId,
                durationS: 900, energyKcal: 60, avgHr: 135, maxHr: 155, strain: 6,
                distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
            _ = try await store.upsertWorkouts([relabelled, dismissed], deviceId: archivedComputedId)

            let repo = Repository(deviceId: deviceId)
            repo.setStoreForTesting(store)
            await repo.relabelDetected(relabelled, sport: "Cycling")
            await repo.dismissDetected(dismissed)

            let archivedRows = try await store.workouts(
                deviceId: archivedComputedId, from: 0, to: 10_000, limit: 100)
            XCTAssertTrue(archivedRows.isEmpty,
                          "explicit actions must delete the row from its archived owning namespace")
            let activeRows = try await store.workouts(
                deviceId: deviceId, from: 0, to: 10_000, limit: 100)
            let manual = try XCTUnwrap(activeRows.first)
            XCTAssertEqual(manual.sport, "Cycling")
            XCTAssertEqual(manual.source, "manual")
            XCTAssertEqual(manual.notes, relabelled.notes)
            XCTAssertEqual(
                Set(UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? []),
                Set(["1000:1900", "3000:3900"]),
                "relabel and dismiss must retain suppression markers for their original spans")
        }
    }

    func testMovedManualEditPersistsReplacementAndRetiresOriginalKey() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let original = WorkoutRow(
                startTs: 1_000, endTs: 1_900, sport: "Running", source: "manual",
                durationS: 900, energyKcal: 50, avgHr: 130, maxHr: 150, strain: 5,
                distanceM: nil, zonesJSON: nil, notes: "original", steps: nil)
            let moved = WorkoutRow(
                startTs: 1_060, endTs: 1_960, sport: "Cycling", source: "manual",
                durationS: 900, energyKcal: 50, avgHr: 130, maxHr: 150, strain: 5,
                distanceM: nil, zonesJSON: nil, notes: "edited", steps: nil)
            _ = try await store.upsertWorkouts([original], deviceId: deviceId)

            let repo = Repository(deviceId: deviceId)
            repo.setStoreForTesting(store)
            await repo.saveManualWorkout(moved, replacing: original)

            let rows = try await store.workouts(deviceId: deviceId, from: 0, to: 10_000, limit: 100)
            XCTAssertEqual(rows, [moved],
                           "a successful moved edit must leave only the replacement natural key")
        }
    }

    func testMergePersistsReplacementBeforeRetiringOriginals() async throws {
        let store = try await WhoopStore.inMemory()
        let first = WorkoutRow(
            startTs: 1_000, endTs: 1_900, sport: "Running", source: "manual",
            durationS: 900, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: "first", steps: nil)
        let second = WorkoutRow(
            startTs: 1_800, endTs: 2_700, sport: "Running", source: "manual",
            durationS: 900, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: "second", steps: nil)
        let merged = WorkoutRow(
            startTs: 900, endTs: 2_700, sport: "Running", source: "manual",
            durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: "merged", steps: nil)
        _ = try await store.upsertWorkouts([first, second], deviceId: deviceId)

        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        await repo.mergeWorkouts([first, second], into: merged)

        let rows = try await store.workouts(deviceId: deviceId, from: 0, to: 10_000, limit: 100)
        XCTAssertEqual(rows, [merged], "a successful merge must leave only the durable replacement")
    }

    func testOptInCandidatePublishesTwelveMinutesAndOnlyLogsTenFifteenMinuteShadows() async throws {
        try await withPreferences {
            UserDefaults.standard.set(true, forKey: PuffinExperiment.autoDetectWorkoutsKey)
            let store = try await WhoopStore.inMemory()
            let start = Int(Date().timeIntervalSince1970) - 2 * 3_600
            let hr = (0...(13 * 60)).map { HRSample(ts: start + $0, bpm: 120) }
            _ = try await store.insert(Streams(hr: hr), deviceId: deviceId)

            let repo = Repository(deviceId: deviceId)
            repo.setStoreForTesting(store)
            var diagnostics: [String] = []
            repo.workoutsLog = { diagnostics.append($0) }

            let candidate = await repo.autoDetectCandidate(daysBack: 1)

            XCTAssertEqual(candidate?.startSec, start)
            XCTAssertEqual(candidate?.durationMin, 13,
                           "the visible card must keep the published 12-minute policy")
            XCTAssertTrue(diagnostics.contains { $0.contains("minSustainedMin=12.0") })
            XCTAssertTrue(diagnostics.contains {
                $0.contains("workout shadow policy=10min candidates=1")
            }, "10-minute evaluation must remain a local diagnostic: \(diagnostics)")
            XCTAssertTrue(diagnostics.contains {
                $0.contains("workout shadow policy=15min candidates=0")
            }, "15-minute evaluation must remain a local diagnostic: \(diagnostics)")

            let importedRows = try await store.workouts(
                deviceId: deviceId, from: start - 1, to: start + 86_400, limit: 100)
            let computedRows = try await store.workouts(
                deviceId: deviceId + "-noop", from: start - 1, to: start + 86_400, limit: 100)
            XCTAssertTrue(importedRows.isEmpty)
            XCTAssertTrue(computedRows.isEmpty,
                          "published and shadow detection must stay read-only until Save")
        }
    }

    func testScoringPreservesLegacyDetectionsCreatesNoNewRowsAndBackfillsRealOverlap() async throws {
        try await withPreferences {
            let store = try await WhoopStore.inMemory()
            let now = Int(Date().timeIntervalSince1970)
            let offset = TimeZone.current.secondsFromGMT()
            let dayStart = IntelligenceEngine.midnightLocal(now, offsetSec: offset) - 86_400
            let firstStart = dayStart + 10 * 3_600
            let secondStart = dayStart + 14 * 3_600
            let duration = 20 * 60

            let rest = (0..<10 * 60).map { HRSample(ts: dayStart + 8 * 3_600 + $0, bpm: 60) }
            let first = activeBlock(start: firstStart, seconds: duration)
            let second = activeBlock(start: secondStart, seconds: duration)
            _ = try await store.insert(
                Streams(hr: rest + first.hr + second.hr, gravity: first.gravity + second.gravity),
                deviceId: deviceId)

            let legacy = WorkoutRow(
                startTs: dayStart + 18 * 3_600, endTs: dayStart + 19 * 3_600,
                sport: "detected", source: deviceId + "-noop", durationS: 3_600,
                energyKcal: 321, avgHr: 133, maxHr: 172, strain: 11.5,
                distanceM: nil, zonesJSON: nil, notes: "legacy", steps: nil)
            _ = try await store.upsertWorkouts([legacy], deviceId: deviceId + "-noop")

            let manual = WorkoutRow(
                startTs: secondStart + 30, endTs: secondStart + duration - 30,
                sport: "Cycling", source: "manual", durationS: Double(duration - 60),
                energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                distanceM: 8_000, zonesJSON: nil, notes: "kept", steps: nil)
            _ = try await store.upsertWorkouts([manual], deviceId: deviceId)

            let repo = Repository(deviceId: deviceId)
            repo.setStoreForTesting(store)
            let engine = IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: deviceId)
            var diagnostics: [String] = []
            engine.diagnosticSink = { line, _ in diagnostics.append(line) }

            await engine.analyzeRecent(maxDays: 2, force: true)

            let detected = try await store.workouts(
                deviceId: deviceId + "-noop", from: dayStart, to: dayStart + 86_399, limit: 100)
            XCTAssertEqual(detected, [legacy],
                           "a rescore must preserve old detected history and must not insert a fresh row")

            let real = try await store.workouts(
                deviceId: deviceId, from: dayStart, to: dayStart + 86_399, limit: 100)
            let enriched = try XCTUnwrap(real.first { $0.startTs == manual.startTs && $0.sport == manual.sport })
            XCTAssertEqual(enriched.source, manual.source)
            XCTAssertEqual(enriched.distanceM, manual.distanceM)
            XCTAssertEqual(enriched.notes, manual.notes)
            XCTAssertNotNil(enriched.avgHr, "the detector must still enrich a real overlapping workout")
            XCTAssertNotNil(enriched.maxHr)
            XCTAssertNotNil(enriched.strain)

            XCTAssertTrue(diagnostics.contains { $0.contains("detectedBout verdict=analyticsOnly") },
                          "the unpersisted analytics bout should remain locally diagnosable: \(diagnostics)")
            XCTAssertTrue(diagnostics.contains { $0.contains("detectedBout verdict=droppedOverlapBackfilled") },
                          "the retained overlap enrichment should remain locally diagnosable: \(diagnostics)")
        }
    }
}
