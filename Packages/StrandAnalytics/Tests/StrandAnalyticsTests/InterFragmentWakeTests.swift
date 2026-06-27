import XCTest
@testable import StrandAnalytics

/// (#777) Out-of-bed time BETWEEN bridged main-night fragments must count as awake (WASO), not vanish.
/// Mirror of the Android `InterFragmentWakeTest` — same numbers, same expectations.
final class InterFragmentWakeTests: XCTestCase {

    func testEmptyOrSingleSpanHasNoGap() {
        XCTAssertEqual(SleepStageTotals.interFragmentWakeSeconds([]), 0)
        XCTAssertEqual(SleepStageTotals.interFragmentWakeSeconds([(start: 0, end: 100)]), 0)
    }

    func testSumsPositiveGapsBetweenOrderedSpans() {
        // [0,100] then [400,500] then [700,900] → gaps 300 + 200 = 500.
        let spans = [(start: 0, end: 100), (start: 400, end: 500), (start: 700, end: 900)]
        XCTAssertEqual(SleepStageTotals.interFragmentWakeSeconds(spans), 500)
    }

    func testIgnoresContiguousAndOverlappingSpans() {
        XCTAssertEqual(SleepStageTotals.interFragmentWakeSeconds([(start: 0, end: 100), (start: 100, end: 200)]), 0)
        XCTAssertEqual(SleepStageTotals.interFragmentWakeSeconds([(start: 0, end: 200), (start: 150, end: 300)]), 0)
    }

    func testOrdersByStartBeforeMeasuring() {
        XCTAssertEqual(SleepStageTotals.interFragmentWakeSeconds([(start: 400, end: 500), (start: 0, end: 100)]), 300)
    }

    func testExtraAwakeRaisesAwakeAndLowersEfficiency() {
        // One fragment: 8 awake + 392 asleep (light 120, deep 152, rem 120) → eff = 392/400 = 0.98.
        let stages = #"{"awake":8,"light":120,"deep":152,"rem":120}"#
        let base = try! XCTUnwrap(SleepStageTotals.dailyAggregate([stages]))
        XCTAssertEqual(base.efficiency, 0.98, accuracy: 1e-9)
        // Add a 20-min (1200s) out-of-bed gap as awake: asleep unchanged (392), in-bed = 420, eff = 392/420.
        let withGap = try! XCTUnwrap(SleepStageTotals.dailyAggregate([stages], extraAwakeSec: 1200.0))
        XCTAssertEqual(withGap.totalSleepMin, 392.0, accuracy: 1e-9)
        XCTAssertEqual(withGap.efficiency, 392.0 / 420.0, accuracy: 1e-9)
    }

    func testBridgedBiphasicNightCountsTheOutOfBedGapAsAwake() throws {
        // Two fragments of ONE night split by a 20-min walk. A: onset 0, in-bed 200min; B: onset 200+20min.
        let aStart = 1_700_000_000
        let aStages = #"{"awake":10,"light":60,"deep":80,"rem":50}"#  // in-bed 200, asleep 190
        let bStart = aStart + (200 + 20) * 60                          // 20-min out-of-bed gap
        let bStages = #"{"awake":10,"light":60,"deep":70,"rem":60}"#  // in-bed 200, asleep 190
        let r = try XCTUnwrap(SleepStageTotals.dailyAggregateHonoringEdits(
            detected: [(startTs: aStart, stagesJSON: aStages), (startTs: bStart, stagesJSON: bStages)],
            edited: [:],
            onsetByStart: [aStart: aStart, bStart: bStart], offsetSec: 0))
        // Asleep = 190 + 190 = 380. In-bed = 200 + 200 + 20 (gap) = 420. eff = 380/420.
        XCTAssertEqual(r.sleep.totalSleepMin, 380.0, accuracy: 1e-9)
        XCTAssertEqual(r.sleep.efficiency, 380.0 / 420.0, accuracy: 1e-9)
    }
}
