import XCTest
import StrandAnalytics
import WhoopStore
import WhoopProtocol
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

// MARK: - #2242: the fold makes analyzeDay's MET-vs-HR energy decision over its own window

/// 2026-09-17, first hardware day of the MET-calories toggle: `AnalyticsEngine.analyzeDay` logged the ring's
/// MET number (1220 kcal) and the export held 743 — Keytel over the wake-to-wake HR window, which this
/// fold recomputed unconditionally and `applying()` wrote over the day's `activeKcalEst`. These pin the
/// three outcomes: a covered MET cycle carries the MET total, a thin one is WITHHELD (no HR substitute),
/// and no MET reader (toggle off) is the byte-identical Keytel path.
extension DayCycleRecoveryTests {

    private struct CycleFixture {
        let store: WhoopStore
        let night: DayCycleIntelligenceIntegration.Night
        let onset: Int
        let now: Int
        let day: String
        static let owner = "oura-ring"
    }

    /// One 8-h main sleep 22:00 → 06:00 UTC, `now` 12 h after wake, 1 Hz HR across the whole cycle so the
    /// Keytel path has something to say when it is allowed to.
    private func cycleFixture() async throws -> CycleFixture {
        let store = try await WhoopStore.inMemory()
        let onset = 1_755_208_800 - 2 * 3_600            // 2026-08-14 22:00 UTC
        let wake = onset + 8 * 3_600
        let now = wake + 12 * 3_600
        let day = AnalyticsEngine.dayString(wake, offsetSec: 0)
        try await store.upsertDevice(id: CycleFixture.owner, mac: nil, name: "Oura")
        let hr = stride(from: onset, to: now, by: 1).map { HRSample(ts: $0, bpm: $0 < wake ? 52 : 74) }
        try await store.insert(Streams(hr: hr), deviceId: CycleFixture.owner)
        let sleep = CachedSleepSession(startTs: onset, endTs: wake, efficiency: 0.9, restingHr: 50,
                                       avgHrv: nil, stagesJSON: nil, deviceId: CycleFixture.owner)
        let daily = DailyMetric(
            day: day, totalSleepMin: 460, efficiency: 0.9, deepMin: 80, remMin: 90, lightMin: 290,
            disturbances: 3, restingHr: 50, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil,
            steps: nil, activeKcalEst: nil, skinTempC: nil, sleepHrOnly: nil)
        let night = DayCycleIntelligenceIntegration.Night(daily: daily, sleeps: [sleep], workouts: [],
                                                          owner: CycleFixture.owner)
        return CycleFixture(store: store, night: night, onset: onset, now: now, day: day)
    }

    private func computeCycle(_ f: CycleFixture,
                              cache: DayCycleIntelligenceIntegration.Cache = DayCycleIntelligenceIntegration.Cache(),
                              metFingerprint: DayCycleIntelligenceIntegration.MetFingerprint? = nil,
                              metReader: DayCycleIntelligenceIntegration.MetReader?) async
        -> DayCycleIntelligenceIntegration.Result {
        await DayCycleIntelligenceIntegration.compute(
            nights: [f.night], editedRows: [], store: f.store,
            candidates: [(owner: CycleFixture.owner, priority: 0)],
            physiologyOwners: [CycleFixture.owner], workouts: [],
            windowStart: f.onset - 86_400, now: f.now, offsetSec: 0,
            habitualMidsleepSec: nil, ticksPerStep: 1, mode: .sleepOnset,
            cache: cache, profile: UserProfile(),
            maxHROverride: nil, effortMethod: .edwards,
            recoveryReader: DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
                sleepSessions: { _, _, _ in [] }, markers: { _, _, _ in [] }),
            metReader: metReader, metFingerprint: metFingerprint)
    }

    func testCycleEnergyIsTheMetTotalWhenTheCycleIsCovered() async throws {
        let f = try await cycleFixture()
        // Every minute of the cycle at 1.1 MET, one 30-min 4.0 bout after wake.
        let wake = f.onset + 8 * 3_600
        let met = stride(from: f.onset, to: f.now, by: 60).map {
            Calories.MetSample(ts: $0, met: ($0 >= wake + 3_600 && $0 < wake + 5_400) ? 4.0 : 1.1)
        }
        var asked: [(String, Int, Int)] = []
        let result = await computeCycle(f) { owner, from, to in asked.append((owner, from, to)); return met }

        let expected = Calories.estimateDayEnergyFromMET(met, profile: UserProfile(),
                                                         dayStart: f.onset, dayEnd: f.now)
        XCTAssertEqual(expected.coverageFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.caloriesByWakeDay[f.day], expected.totalKcal, "the MET total, not Keytel over the cycle HR")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, CycleFixture.owner)
        XCTAssertEqual(asked.first?.1, f.onset)
        XCTAssertEqual(asked.first?.2, f.now - 1, "the cycle window, inclusive end like every store read")
        // And the fold carries it onto the row (the write that used to bring Keytel back).
        let applied = DayCycleIntelligenceIntegration.applying(result, to: f.night.daily)
        XCTAssertEqual(applied.activeKcalEst, expected.totalKcal)
    }

    func testThinMetCoverageWithholdsTheCycleAndDoesNotSubstituteKeytel() async throws {
        let f = try await cycleFixture()
        // 10 % of the cycle covered — below the floor — with plenty of HR alongside.
        let met = stride(from: f.onset, to: f.onset + 2 * 3_600, by: 60).map { Calories.MetSample(ts: $0, met: 3.0) }
        let result = await computeCycle(f) { _, _, _ in met }
        XCTAssertNil(result.caloriesByWakeDay[f.day], "withheld: no entry, no HR figure in its place")
        let applied = DayCycleIntelligenceIntegration.applying(result, to: f.night.daily)
        XCTAssertNil(applied.activeKcalEst)
        // The rest of the fold is untouched by the decision.
        XCTAssertNotNil(result.strainByWakeDay[f.day])
    }

    func testNoMetReaderIsTheKeytelPath() async throws {
        let f = try await cycleFixture()
        let result = await computeCycle(f, metReader: nil)
        let keytel = try XCTUnwrap(result.caloriesByWakeDay[f.day])
        XCTAssertGreaterThan(keytel, 0)
        // An empty MET read is the same as no reader: the HR path, byte for byte.
        let empty = await computeCycle(f) { _, _, _ in [] }
        XCTAssertEqual(empty.caloriesByWakeDay[f.day], keytel)
    }

    /// #2242 × the cycle load cache: MET banked inside an already-scored cycle moves the cache key. The first
    /// pass sees 10 % coverage and withholds; a later drain fills the cycle, and the next pass must score it
    /// from MET instead of serving the withheld load cached under the heart-rate-only witness.
    func testMetBankedAfterAPassIsNotServedFromTheCache() async throws {
        let f = try await cycleFixture()
        let all = stride(from: f.onset, to: f.now, by: 60).map { Calories.MetSample(ts: $0, met: 1.2) }
        var banked = all.filter { $0.ts < f.onset + 2 * 3_600 }
        let cache = DayCycleIntelligenceIntegration.Cache()
        let fingerprint: DayCycleIntelligenceIntegration.MetFingerprint = { _, _, _ in
            (banked.count, banked.last?.ts ?? 0)
        }
        let first = await computeCycle(f, cache: cache, metFingerprint: fingerprint) { _, _, _ in banked }
        XCTAssertNil(first.caloriesByWakeDay[f.day])

        banked = all
        let second = await computeCycle(f, cache: cache, metFingerprint: fingerprint) { _, _, _ in banked }
        let expected = Calories.estimateDayEnergyFromMET(all, profile: UserProfile(), dayStart: f.onset, dayEnd: f.now)
        XCTAssertEqual(second.caloriesByWakeDay[f.day], expected.totalKcal)
    }

    /// Flipping the toggle over unchanged data never serves the figure cached under the other setting.
    func testAToggleFlipOverUnchangedDataRescoresTheCycle() async throws {
        let f = try await cycleFixture()
        let met = stride(from: f.onset, to: f.now, by: 60).map { Calories.MetSample(ts: $0, met: 2.0) }
        let cache = DayCycleIntelligenceIntegration.Cache()
        let fingerprint: DayCycleIntelligenceIntegration.MetFingerprint = { _, _, _ in (met.count, met.last?.ts ?? 0) }
        let on = await computeCycle(f, cache: cache, metFingerprint: fingerprint) { _, _, _ in met }
        let off = await computeCycle(f, cache: cache, metReader: nil)
        let onKcal = try XCTUnwrap(on.caloriesByWakeDay[f.day])
        let offKcal = try XCTUnwrap(off.caloriesByWakeDay[f.day])
        XCTAssertNotEqual(onKcal, offKcal, "the two paths must differ for this test to mean anything")
        let onAgain = await computeCycle(f, cache: cache, metFingerprint: fingerprint) { _, _, _ in met }
        XCTAssertEqual(onAgain.caloriesByWakeDay[f.day], onKcal)
        let offAgain = await computeCycle(f, cache: cache, metReader: nil)
        XCTAssertEqual(offAgain.caloriesByWakeDay[f.day], offKcal)
    }
}
