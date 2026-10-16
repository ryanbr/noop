import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class DayCycleRecoveryTests: XCTestCase {
    private enum ReadFailure: Error { case injected }

    func testApplyingCycleStepsPreservesUnrelatedDailyColumns() {
        let daily = DailyMetric(
            day: "2026-09-04", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
            steps: 10, activeKcalEst: nil, skinTempC: 34.2, sleepHrOnly: true)
        let result = DayCycleIntelligenceIntegration.Result(
            stepsByWakeDay: [daily.day: 42], strainByWakeDay: [daily.day: 61],
            caloriesByWakeDay: [daily.day: 1_840], workoutCountByWakeDay: [daily.day: 2],
            onsetByWakeDay: [:], firstWakeDay: daily.day,
            markerUpdate: .preserve)

        let updated = DayCycleIntelligenceIntegration.applying(result, to: daily)

        XCTAssertEqual(updated.steps, 42)
        XCTAssertEqual(updated.strain, 61)
        XCTAssertEqual(updated.activeKcalEst, 1_840)
        XCTAssertEqual(updated.exerciseCount, 2)
        XCTAssertEqual(updated.skinTempC, 34.2)
        XCTAssertEqual(updated.sleepHrOnly, true)
    }

    func testBoundaryRecoveryPropagatesSessionReadFailure() async {
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in throw ReadFailure.injected },
            markers: { _, _, _ in XCTFail("marker read must not follow a failed session read"); return [] })

        do {
            _ = try await DayCycleIntelligenceIntegration.recover(
                candidates: [(owner: "strap", priority: 0)], reader: reader,
                claimedDays: [], windowStart: 1_700_000_000, now: 1_700_086_400,
                offsetSec: 0, habitualMidsleepSec: nil)
            XCTFail("expected recovery to fail closed")
        } catch ReadFailure.injected {
            // Expected: callers can distinguish an unread namespace from an authoritative empty one.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBoundaryRecoveryPropagatesMarkerReadFailure() async {
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in [] },
            markers: { _, _, _ in throw ReadFailure.injected })

        do {
            _ = try await DayCycleIntelligenceIntegration.recover(
                candidates: [(owner: "strap", priority: 0)], reader: reader,
                claimedDays: [], windowStart: 1_700_000_000, now: 1_700_086_400,
                offsetSec: 0, habitualMidsleepSec: nil)
            XCTFail("expected recovery to fail closed")
        } catch ReadFailure.injected {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testComputePreservesMarkersWhenRecoveryCannotBeRead() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in throw ReadFailure.injected },
            markers: { _, _, _ in XCTFail("marker read must not follow a failed session read"); return [] })

        let result = await DayCycleIntelligenceIntegration.compute(
            nights: [], editedRows: [], store: store,
            candidates: [(owner: "strap", priority: 0)],
            physiologyOwners: ["strap"], workouts: [],
            windowStart: 1_700_000_000, now: 1_700_086_400, offsetSec: 0,
            habitualMidsleepSec: nil, ticksPerStep: 1, mode: .sleepOnset,
            cache: DayCycleIntelligenceIntegration.Cache(), profile: UserProfile(),
            maxHROverride: nil, effortMethod: .edwards, recoveryReader: reader)

        guard case .preserve = result.markerUpdate else {
            return XCTFail("an unread marker namespace must never become an authoritative replacement")
        }
        XCTAssertTrue(result.stepsByWakeDay.isEmpty)
        XCTAssertTrue(result.onsetByWakeDay.isEmpty)
    }

    func testPass2SkinTempDeviationBeforeRecoveryScoring() throws {
        let daily = recoveryDailyFixture()
        let baselines = AnalyticsEngine.ProfileBaselines(
            hrv: recoveryBaseline(50, spread: 6), skinTemp: recoveryBaseline(34.5, spread: 0.4))
        let withoutSkin = expectedRecovery(daily, baselines: baselines, skinDev: nil)

        for (nightly, deviation) in [(34.804, 0.3), (34.196, -0.3)] {
            let result = IntelligenceEngine.recomputeRecoveryDaily(
                daily, nightlySkinTempC: nightly, baselines: baselines)
            let expected = try XCTUnwrap(expectedRecovery(daily, baselines: baselines, skinDev: deviation))
            XCTAssertNotEqual(expected, withoutSkin)
            XCTAssertEqual(result.recovery, expected)
            XCTAssertEqual(result.skinTempDevC, deviation)
            XCTAssertEqual(result.skinTempC, nightly)
            // Undo only the three intended substitutions; every other daily field must survive.
            XCTAssertEqual(result.with(recovery: daily.recovery, skinTempDevC: daily.skinTempDevC,
                                       skinTempC: daily.skinTempC), daily)
        }
    }

    func testPass2MissingOrUnusableSkinBaselineClearsStaleDeviation() {
        let daily = recoveryDailyFixture().with(recovery: 99, skinTempDevC: 9, skinTempC: 36)
        let usable = recoveryBaseline(34.5, spread: 0.4)
        let cases: [(Double?, BaselineState?)] = [
            (nil, usable), (34.8, nil),
            (34.8, recoveryBaseline(34.5, spread: 0.4, status: .calibrating)),
            (34.8, recoveryBaseline(34.5, spread: 0.4, status: .stale))
        ]
        for (nightly, skinBaseline) in cases {
            let baselines = AnalyticsEngine.ProfileBaselines(
                hrv: recoveryBaseline(50, spread: 6), skinTemp: skinBaseline)
            let result = IntelligenceEngine.recomputeRecoveryDaily(
                daily, nightlySkinTempC: nightly, baselines: baselines)
            XCTAssertNil(result.skinTempDevC)
            XCTAssertEqual(result.skinTempC, nightly)
            XCTAssertEqual(result.recovery, expectedRecovery(daily, baselines: baselines, skinDev: nil))
        }
    }

    func testPass2SkinTemperatureDoesNotBypassHrvColdStart() {
        let hrvBaselines: [BaselineState?] = [nil, recoveryBaseline(50, spread: 6, status: .calibrating)]
        for hrv in hrvBaselines {
            let result = IntelligenceEngine.recomputeRecoveryDaily(
                recoveryDailyFixture(), nightlySkinTempC: 34.8,
                baselines: AnalyticsEngine.ProfileBaselines(
                    hrv: hrv, skinTemp: recoveryBaseline(34.5, spread: 0.4)))
            XCTAssertNil(result.recovery)
            XCTAssertEqual(result.skinTempDevC, 0.3)
        }
    }

    func testCycleLoadPreservesOwnerPriorityBoundariesAndCachedResults() async throws {
        let store = try await WhoopStore.inMemory()
        let onset = 1_788_904_800
        let now = onset + 85_000
        let daily = recoveryDailyFixture()
        let sleep = CachedSleepSession(startTs: onset, endTs: onset + 28_800,
                                      efficiency: 0.9, restingHr: 58, avgHrv: 48, stagesJSON: nil)
        let samples = (0..<80_000).map { HRSample(ts: onset + $0, bpm: 70 + $0 % 80) }
        _ = try await store.insert(Streams(hr: samples), deviceId: "strap")
        let duplicates = stride(from: 0, through: 80_000, by: 2).map { HRSample(ts: onset + $0, bpm: 190) }
        _ = try await store.insert(Streams(hr: duplicates + [HRSample(ts: onset - 1, bpm: 200),
                                                           HRSample(ts: now, bpm: 200)]), deviceId: "canonical")
        // Bit patterns recorded from this fixture before moving the existing work off the main actor.
        let expected: [String: (strain: UInt64, calories: UInt64)] = [
            "male-edwards": (4_634_812_706_201_377_178, 4_663_630_262_385_791_330),
            "male-banister": (4_635_039_997_245_071_032, 4_663_630_262_385_791_330),
            "female-edwards": (4_634_812_706_201_377_178, 4_662_157_254_104_897_468),
            "female-banister": (4_635_082_218_491_577_631, 4_662_157_254_104_897_468)
        ]
        for sex in ["male", "female"] {
            for method in [StrainScorer.Method.edwards, .banister] {
                let cache = DayCycleIntelligenceIntegration.Cache()
                let profile = UserProfile(weightKg: 75, heightCm: 180, age: 35, sex: sex)
                func compute() async -> DayCycleIntelligenceIntegration.Result {
                    await DayCycleIntelligenceIntegration.compute(
                        nights: [.init(daily: daily, sleeps: [sleep], workouts: [], owner: "strap")],
                        editedRows: [], store: store, candidates: [("strap", 0)],
                        physiologyOwners: ["canonical", "strap"], workouts: [], windowStart: onset,
                        now: now, offsetSec: 0, habitualMidsleepSec: nil, ticksPerStep: 1,
                        mode: .sleepOnset, cache: cache, profile: profile, maxHROverride: 190,
                        effortMethod: method)
                }
                let result = await compute()
                let strain = try XCTUnwrap(result.strainByWakeDay[daily.day])
                let calories = try XCTUnwrap(result.caloriesByWakeDay[daily.day])
                let oracle = try XCTUnwrap(expected["\(sex)-\(method)"])
                XCTAssertEqual(strain.bitPattern, oracle.strain)
                XCTAssertEqual(calories.bitPattern, oracle.calories)
                XCTAssertEqual(result.onsetByWakeDay[daily.day], onset)
                let cached = await compute()
                XCTAssertEqual(cached.strainByWakeDay, result.strainByWakeDay)
                XCTAssertEqual(cached.caloriesByWakeDay, result.caloriesByWakeDay)
                if sex == "female", method == .banister {
                    _ = try await store.insert(Streams(hr: [HRSample(ts: onset + 80_001, bpm: 180)]),
                                               deviceId: "canonical")
                    let updated = await compute()
                    XCTAssertGreaterThan(try XCTUnwrap(updated.caloriesByWakeDay[daily.day]), calories)
                }
            }
        }
    }

    private func recoveryBaseline(_ mean: Double, spread: Double,
                                  status: BaselineStatus = .trusted) -> BaselineState {
        BaselineState(baseline: mean, spread: spread,
                      nValid: status == .calibrating ? 3 : 14, nightsSinceUpdate: status == .stale ? 15 : 0,
                      status: status)
    }

    private func recoveryDailyFixture() -> DailyMetric {
        DailyMetric(day: "2026-09-09", totalSleepMin: 420, efficiency: 0.85,
                    deepMin: 80, remMin: 90, lightMin: 250, disturbances: 2,
                    restingHr: 58, avgHrv: 48, recovery: 99, strain: 61, exerciseCount: 2,
                    spo2Pct: 97, skinTempDevC: nil, respRateBpm: 15, steps: 42, activeKcalEst: 1_840,
                    spo2Red: 100, spo2Ir: 200, avgSdnn: 44, skinTempC: nil, sleepHrOnly: true)
    }

    private func expectedRecovery(_ daily: DailyMetric, baselines: AnalyticsEngine.ProfileBaselines,
                                  skinDev: Double?) -> Double? {
        RecoveryScorer.recovery(
            hrv: 48, rhr: 58, resp: 15, hrvBaseline: baselines.hrv!, rhrBaseline: nil,
            respBaseline: nil,
            sleepPerf: AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency,
            skinTempDev: skinDev)
    }
}
