import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// StressModel carry (#543). The Today "Stress" metric derives against a 30-day RHR/HRV baseline. Today's
/// own daily row is often vitals-less until the overnight is analyzed (especially right after an app update
/// relaunches and re-runs the analyze pass), and every OTHER Today vital carries last night's value — Stress
/// used to be the one card that didn't, so it dropped to "Calibrating" while the rest showed numbers. These
/// pin the carry: score the newest day that actually has RHR/HRV. Twin of the Android StressModelTest.
final class StressModelCarryTests: XCTestCase {

    private func day(_ d: String, rhr: Int?, hrv: Double?, sleepMin: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    // 31 days that all carry RHR + HRV: a full 30-day baseline plus one more scorable day.
    private var baseline: [DailyMetric] {
        (1...30).map { day(String(format: "2026-06-%02d", $0), rhr: 55, hrv: 60) }
            + [day("2026-07-01", rhr: 55, hrv: 60)]
    }

    func testVitalsLessTodayCarriesInsteadOfCalibrating() {
        // Control: today HAS vitals → builds (unchanged).
        XCTAssertNotNil(StressModel(days: baseline + [day("2026-07-02", rhr: 58, hrv: 45)], stored: []))
        // The fix: today has NO RHR/HRV yet (the post-update window) but a prior day does → carries, not nil.
        XCTAssertNotNil(StressModel(days: baseline + [day("2026-07-02", rhr: nil, hrv: nil)], stored: []),
                        "a vitals-less today must carry the last day with RHR/HRV, not calibrate")
    }

    func testNoVitalsAnywhereStillCalibrates() {
        // Genuine cold start: no day has RHR/HRV and nothing stored → honestly calibrating (nil).
        let days = (1...5).map { day("2026-07-0\($0)", rhr: nil, hrv: nil) }
        XCTAssertNil(StressModel(days: days, stored: []))
    }

    func testFirstNightWithoutBaselineStillShowsTodaysTimeline() {
        let daily = StressModel(days: [day("2026-07-01", rhr: 55, hrv: 60, sleepMin: 420)], stored: [])
        XCTAssertNil(daily, "one night cannot establish the daily stress baseline")
        let hr = (0..<DaytimeStress.minHourHRSamples).map { HRSample(ts: 7 * 3_600 + $0, bpm: 65) }
        let daytime = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(daytime.scored.isEmpty)
        XCTAssertEqual(StressDaytimeState.resolve(daytime: daytime, hasDailyModel: daily != nil,
                                                 hasAdvancedReadouts: false), .timeline)
    }

    func testIntradayLoadingAndEmptyStatesRespectIndependentReadouts() {
        for hasDaily in [false, true] {
            for hasAdvanced in [false, true] {
                XCTAssertEqual(StressDaytimeState.resolve(daytime: nil, hasDailyModel: hasDaily,
                                                         hasAdvancedReadouts: hasAdvanced), .loading)
                XCTAssertEqual(StressDaytimeState.resolve(daytime: .empty, hasDailyModel: hasDaily,
                                                         hasAdvancedReadouts: hasAdvanced),
                               hasDaily || hasAdvanced ? .hidden : .empty)
            }
        }
    }

    func testStoredStressOnLatestVitalsLessDayIsUsedNotSkipped() {
        // An imported latest day carries a STORED stress value but no RHR/HRV (e.g. a Xiaomi / Garmin /
        // WHOOP export). The original gate honoured it; the carry must NOT skip it back to an older vitals
        // day. The stored 2.5 must win over any derived carry.
        let days = baseline + [day("2026-07-02", rhr: nil, hrv: nil)]
        let model = StressModel(days: days, stored: [(day: "2026-07-02", value: 2.5)])
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.score ?? -1, 2.5, accuracy: 0.001,
                       "the latest day's stored stress must win over a carry")
    }
}
