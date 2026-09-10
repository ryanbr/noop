import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Charge breakdown wiring (pure, testable)
//
// The fold-and-score wiring behind the "What shaped it" sheet, lifted out of the two views that had
// byte-identical private copies of it (TodayView.chargeBreakdown / CoupledView.chargeBreakdown). They
// differed only in which row they display and where their sleep-performance number comes from, both of
// which are inputs, so one function serves both.
//
// Extracted so it can be TESTED. Living inside a `View` struct as a private method meant the only way to
// exercise it was to render the view, so the iOS side of this path had no test at all while the Android
// twin did. Kotlin twin: `TodayScoring.recoveryChargeDrivers`.
//
// Pure: no SwiftUI state, no I/O, no store access. Nothing here invents a number. The drivers come from
// `RecoveryScorer.chargeDrivers` and the tier is SURFACED from `ScoreConfidence.charge` against the same
// folded HRV baseline the drivers scored with, so the header and the rows agree by construction.
enum ChargeBreakdownWiring {

    /// The ordered Charge driver rows for `row` plus its confidence tier, folded from the visible `days`
    /// history, or nil when the night cannot honestly score (missing HRV or resting HR, or an HRV
    /// baseline that is not yet usable) so the sheet hides rather than showing fabricated rows.
    ///
    /// `sleepPerfPercent` is the Rest composite on a 0-100 scale, divided by 100 here to match
    /// `AnalyticsEngine`'s `sleepPerf` form, so the Sleep row scores against the headline's own input.
    ///
    /// The resting-HR and respiration baselines are passed only when usable. `RecoveryScorer` and
    /// `chargeDrivers` both apply that gate themselves since #1990, so these are belt-and-braces rather
    /// than load-bearing; they are kept because they say the intent at the call site, which is where a
    /// reader looks first.
    static func breakdown(days: [DailyMetric],
                          row: DailyMetric,
                          sleepPerfPercent: Double?) -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        guard let hrv = row.avgHrv, let rhr = row.restingHr else { return nil }
        // PERF: one pass per series. The two private copies this replaces each re-folded the full history
        // per body evaluation of the open sheet; the guard above still runs before any fold.
        let hrvBase = Baselines.foldHistory(days.map(\.avgHrv), cfg: Baselines.hrvCfg)
        guard hrvBase.usable else { return nil }
        let rhrBase = Baselines.foldHistory(days.map { $0.restingHr.map(Double.init) },
                                            cfg: Baselines.restingHRCfg)
        let respBase = Baselines.foldHistory(days.map(\.respRateBpm), cfg: Baselines.respCfg)
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
            hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil,
            respBaseline: respBase.usable ? respBase : nil,
            sleepPerf: sleepPerfPercent.map { $0 / 100.0 },
            skinTempDev: row.skinTempDevC)
        return (drivers, ScoreConfidence.charge(recovery: row.recovery, hrvBaseline: hrvBase))
    }
}
