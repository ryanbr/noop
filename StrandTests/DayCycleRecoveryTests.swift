import XCTest
import StrandAnalytics
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
}
