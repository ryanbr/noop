import XCTest
@testable import StrandAnalytics
import WhoopStore

/// RD2 — the readiness HRV/RHR baselines are folded through the shared Winsorized-EWMA spine
/// (`Baselines.foldHistory`) instead of a naive mean + sample SD, in the WINDOW-FOLD mode
/// (`rejectHardOutliers: false`). Chosen over the full incremental spine after replaying real HRV
/// history: hard-outlier rejection is right for RecoveryScorer's incremental nightly fold but WRONG
/// for a re-folded trailing window, where a recent sustained shift lands past the young grace period
/// and would be rejected as a run of "outliers". Winsorization (kept) still damps single freak nights.
final class RD2SpineTests: XCTestCase {

    // MARK: - The spine capability itself: reject on (incremental) vs off (window-fold)

    func testWindowFoldAdaptsToSustainedShiftThatIncrementalRejects() {
        // 20 settled nights at 140 ms, then 10 recent nights at 85 ms (a real sustained shift). The
        // incremental fold (reject on) discards the recent block as >5σ outliers and stays anchored
        // high; the window fold (reject off) follows the shift down. This is the exact readiness
        // failure mode (device swap / supplement onset) the mode switch fixes.
        let vals: [Double?] = Array(repeating: 140.0, count: 20) + Array(repeating: 85.0, count: 10)
        let rejectOn = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg, rejectHardOutliers: true)
        let rejectOff = Baselines.foldHistory(vals, cfg: Baselines.hrvCfg, rejectHardOutliers: false)
        XCTAssertGreaterThan(rejectOn.baseline, 130, "hard-reject keeps the stale high baseline")
        XCTAssertLessThan(rejectOff.baseline, rejectOn.baseline - 10,
                          "window-fold adapts meaningfully toward the recent sustained level")
    }

    func testSingleFreakNightIsDampedNotRejectedInWindowFold() {
        // One freak sensor night in an otherwise stable baseline. With reject OFF the freak is not
        // discarded — but Winsorization still CLAMPS it, so it barely moves the center. (Contrast the
        // sustained block above, which the same mode follows: single spike damped, sustained shift
        // adapted — the whole point of Winsor-without-reject.)
        let stable: [Double?] = Array(repeating: 90.0, count: 29)
        let withFreak: [Double?] = stable + [180.0]
        let base0 = Baselines.foldHistory(stable, cfg: Baselines.hrvCfg, rejectHardOutliers: false)
        let base1 = Baselines.foldHistory(withFreak, cfg: Baselines.hrvCfg, rejectHardOutliers: false)
        XCTAssertLessThan(abs(base1.baseline - base0.baseline), 8,
                          "a single 2× freak night must be Winsor-damped, not swing the baseline")
    }

    // MARK: - Readiness end-to-end (ln-space HRV, reject off)

    private func d(_ i: Int, hrv: Double?, rhr: Int?) -> DailyMetric {
        DailyMetric(day: String(format: "2024-03-%02d", i), totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: 10, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    func testReadinessAdaptsToRecentSustainedHRVShift() {
        // 12 old nights at 130 ms, then 18 recent nights settled at 85 ms (a sustained shift), today at
        // the new normal 85. It must NOT read BAD — the window fold adapts. Under the incremental
        // (reject-on) mode this exact case reads BAD (the recent block is rejected, baseline stuck at
        // 130), which is the readiness regression RD2 exists to prevent.
        var days: [DailyMetric] = []
        for i in 1...12 { days.append(d(i, hrv: 130, rhr: 52)) }
        for i in 13...30 { days.append(d(i, hrv: 85, rhr: 52)) }
        days.append(d(31, hrv: 85, rhr: 52))   // today: the new normal
        let hrv = ReadinessEngine.evaluate(days: days).signals.first { $0.key == "hrv" }
        XCTAssertNotNil(hrv)
        XCTAssertNotEqual(hrv?.flag, .bad,
                          "today at the recent sustained normal must not read BAD (the reject-mode failure)")
    }

    func testGenuineLowStillFlagsAfterSpineAdoption() {
        // Regression: the spine must not blunt a real drop. Stable ~95 ms baseline, today a clear 68 ms.
        var days: [DailyMetric] = []
        for i in 1...30 { days.append(d(i, hrv: i % 2 == 0 ? 97 : 93, rhr: 52)) }
        days.append(d(31, hrv: 68, rhr: 52))
        let hrv = ReadinessEngine.evaluate(days: days).signals.first { $0.key == "hrv" }
        XCTAssertEqual(hrv?.flag, .bad, "a genuine ~28% HRV drop must still read BAD")
    }
}
