import XCTest
@testable import StrandAnalytics

/// #1988: an UNUSABLE resting-HR baseline must be treated as absent, everywhere.
///
/// `Baselines.foldHistory` returns the config's SYNTHETIC midpoint (about 75 bpm for resting HR) when the
/// history is empty or entirely out of physiological range. That is nobody's resting HR, so scoring
/// against it moved Charge, and a driver bar, on a baseline the user never had.
///
/// The gate lives in two places on purpose, and both are pinned here: `RecoveryScorer.recovery`'s
/// `BaselineState` overload (every headline caller passes through it) and `chargeDrivers` (which builds
/// the ROW from the baseline directly, not only through the scorer). Gating one without the other would
/// let the breakdown disagree with the headline, which is exactly what `chargeDrivers`' own contract
/// promises never happens. Kotlin twin: `RecoveryRhrBaselineUsableTest`.
final class RecoveryRhrBaselineUsableTests: XCTestCase {

    private func state(_ mean: Double, _ sigma: Double,
                       _ status: BaselineStatus, nValid: Int) -> BaselineState {
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: status == .stale ? 20 : 0, status: status)
    }

    private var hrvBase: BaselineState { state(55, 12, .trusted, nValid: 20) }
    private var usableRhr: BaselineState { state(52, 3, .provisional, nValid: 5) }
    /// What an empty or all-implausible history folds to: the config midpoint, never banked.
    private var syntheticRhr: BaselineState { state(75, 6, .calibrating, nValid: 0) }
    private var staleRhr: BaselineState { state(52, 3, .stale, nValid: 20) }

    private func score(_ rhrBaseline: BaselineState?) -> Double? {
        RecoveryScorer.recovery(hrv: 55, rhr: 62, resp: nil,
                                hrvBaseline: hrvBase, rhrBaseline: rhrBaseline,
                                respBaseline: nil, sleepPerf: 0.85)
    }

    private func rows(_ rhrBaseline: BaselineState?) -> [ChargeDriver] {
        RecoveryScorer.chargeDrivers(hrv: 55, rhr: 62, resp: nil,
                                     hrvBaseline: hrvBase, rhrBaseline: rhrBaseline,
                                     respBaseline: nil, sleepPerf: 0.85)
    }

    func testASyntheticRhrBaselineScoresLikeAnAbsentOne() {
        XCTAssertEqual(score(syntheticRhr)!, score(nil)!, accuracy: 1e-12)
    }

    func testAStaleRhrBaselineScoresLikeAnAbsentOne() {
        // `usable` is provisional-or-trusted, so a real personal baseline that has gone stale is dropped
        // too. That is the same reading of "usable" the rest of the codebase uses.
        XCTAssertEqual(score(staleRhr)!, score(nil)!, accuracy: 1e-12)
    }

    func testAUsableRhrBaselineStillContributes() {
        // The control: the gate is not a blanket off. A resting HR well above a usable baseline must pull
        // the score away from the HRV-only number.
        XCTAssertNotEqual(score(usableRhr)!, score(nil)!, accuracy: 1e-9)
    }

    func testASyntheticRhrBaselineProducesNoRhrDriverRow() {
        let labels = rows(syntheticRhr).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"),
                      "the HRV row must still be present: \(labels)")
        XCTAssertFalse(labels.contains("Resting heart rate"),
                       "no usable resting-HR baseline, so no RHR row: \(labels)")
    }

    func testAUsableRhrBaselineProducesItsRow() {
        XCTAssertTrue(rows(usableRhr).map(\.label).contains("Resting heart rate"))
    }

    /// THE invariant this change exists to keep. `chargeDrivers` documents that its rows are scored
    /// "against the identical inputs as the headline number", so the two gates must agree: passing an
    /// unusable baseline has to be indistinguishable from passing none, row for row.
    func testTheDriverRowsAndTheHeadlineApplyTheSameGate() {
        XCTAssertEqual(rows(syntheticRhr), rows(nil))
        XCTAssertEqual(rows(staleRhr), rows(nil))
    }

    /// The trace is the THIRD place that reads this baseline directly, for its own
    /// `charge baseline rhr` line, its rhrZ and the saturation guard. Its own contract is that the score
    /// it reports is the dashboard's "verbatim, so the trace cannot diverge from it", so an unusable
    /// baseline has to drop the rhr TERM there too. Without the gate the trace would name a term the
    /// score never used, which is the one thing a trace must never do.
    func testTheTraceDropsTheRhrTermForAnUnusableBaseline() {
        let (traced, lines) = RecoveryScorer.recoveryTrace(
            hrv: 55, rhr: 62, resp: nil,
            hrvBaseline: hrvBase, rhrBaseline: syntheticRhr, respBaseline: nil, sleepPerf: 0.85)
        XCTAssertEqual(traced!, score(syntheticRhr)!, accuracy: 1e-12)
        XCTAssertFalse(lines.contains { $0.contains("charge term rhr ") },
                       "the trace must not name an rhr term the score did not use: \(lines)")
        XCTAssertTrue(lines.contains { $0.contains("nilTerm dropped=") && $0.contains("rhr") },
                      "rhr must be reported as a dropped term: \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("charge baseline rhr ") },
                       "no baseline line for a baseline that was not used: \(lines)")
    }

    /// Control: a usable baseline still produces the trace's rhr term and its baseline line.
    func testTheTraceKeepsTheRhrTermForAUsableBaseline() {
        let (_, lines) = RecoveryScorer.recoveryTrace(
            hrv: 55, rhr: 62, resp: nil,
            hrvBaseline: hrvBase, rhrBaseline: usableRhr, respBaseline: nil, sleepPerf: 0.85)
        XCTAssertTrue(lines.contains { $0.contains("charge term rhr ") })
        XCTAssertTrue(lines.contains { $0.contains("charge baseline rhr ") })
    }
}
