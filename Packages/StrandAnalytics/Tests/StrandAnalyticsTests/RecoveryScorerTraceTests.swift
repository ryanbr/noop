import XCTest
@testable import StrandAnalytics

/// The Recovery (Charge) test mode's pure term-breakdown trace. Pins the lines a fixture night produces
/// AND proves the emitter never changes the score `recovery(...)` returns (Test Centre Group G). Twin of
/// the Android RecoveryScorerTraceTest. No em-dashes.
final class RecoveryScorerTraceTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and Gaussian sigma.
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    func testTraceScoreIsByteIdenticalToRecovery() {
        // Full set of terms present: the trace's returned score must equal recovery(...) exactly.
        let hrvB = baseline(mean: 50, sigma: 6)
        let rhrB = baseline(mean: 55, sigma: 3)
        let respB = baseline(mean: 16, sigma: 2)
        let plain = RecoveryScorer.recovery(
            hrv: 62, rhr: 51, resp: 15,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: respB,
            sleepPerf: 0.9, skinTempDev: 0.3)
        let (traced, lines) = RecoveryScorer.recoveryTrace(
            hrv: 62, rhr: 51, resp: 15,
            hrvBaseline: hrvB, rhrBaseline: rhrB, respBaseline: respB,
            sleepPerf: 0.9, skinTempDev: 0.3)
        XCTAssertEqual(traced, plain)
        // All five terms present, none nil.
        XCTAssertTrue(lines.contains { $0.contains("charge term hrv ") })
        XCTAssertTrue(lines.contains { $0.contains("charge term rhr ") })
        XCTAssertTrue(lines.contains { $0.contains("charge term resp ") })
        XCTAssertTrue(lines.contains { $0.contains("charge term sleepPerf ") })
        XCTAssertTrue(lines.contains { $0.contains("charge term skinTempDev ") })
        XCTAssertTrue(lines.contains { $0.contains("nilTerm dropped=[]") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("charge score=") && $0.contains("band=") })
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testTraceNamesTheNilTermThatForcedRenorm() {
        // No RHR baseline, no resp, no skin temp → those three terms drop and the trace must name them.
        let hrvB = baseline(mean: 50, sigma: 6)
        let plain = RecoveryScorer.recovery(
            hrv: 55, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: 0.85, skinTempDev: nil)
        let (traced, lines) = RecoveryScorer.recoveryTrace(
            hrv: 55, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: 0.85, skinTempDev: nil)
        XCTAssertEqual(traced, plain)
        let nilLine = lines.first { $0.contains("nilTerm dropped=") }
        XCTAssertNotNil(nilLine)
        XCTAssertTrue(nilLine!.contains("rhr"))
        XCTAssertTrue(nilLine!.contains("resp"))
        XCTAssertTrue(nilLine!.contains("skinTempDev"))
        XCTAssertFalse(nilLine!.contains("hrv,"))      // hrv + sleepPerf survived
    }

    func testColdStartTraceReportsTheGateAndNilScore() {
        let coldHRV = BaselineState(baseline: 50, spread: 5, nValid: 2,
                                    nightsSinceUpdate: 0, status: .calibrating)
        let (traced, lines) = RecoveryScorer.recoveryTrace(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: coldHRV, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: 0.9, skinTempDev: nil)
        XCTAssertNil(traced)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("nilScore reason=hrvBaselineNotUsable"))
        XCTAssertTrue(lines[0].contains("hrvStatus=calibrating"))
        XCTAssertTrue(lines[0].contains("hrvNValid=2"))
    }

    func testBaselineLinesCarryStatusAndNValid() {
        let hrvB = baseline(mean: 50, sigma: 6, nValid: 9)
        let (_, lines) = RecoveryScorer.recoveryTrace(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: RecoveryScorer.sleepPerfCenter, skinTempDev: nil)
        let base = lines.first { $0.hasPrefix("charge baseline hrv ") }
        XCTAssertNotNil(base)
        XCTAssertTrue(base!.contains("nValid=9"))
        XCTAssertTrue(base!.contains("status=provisional"))
    }

    /// #1437 follow-up: a term just below baseline rounds to zero but must keep its SIGN. Swift's
    /// `.rounded()` yields -0.0 here and interpolates as "-0.0"; the Kotlin twin negated a Long (which
    /// has no negative zero) and printed "0.0", so the two traces disagreed on the one line whose whole
    /// purpose is being byte-identical across platforms. Twin:
    /// `traceKeepsNegativeZeroOnNearBaselineTerm`.
    func testTraceKeepsNegativeZeroOnNearBaselineTerm() {
        let hrvB = baseline(mean: 50, sigma: 6)
        let (_, lines) = RecoveryScorer.recoveryTrace(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: nil, skinTempDev: 0.001)
        XCTAssertEqual(
            lines.first { $0.hasPrefix("charge term skinTempDev ") },
            "charge term skinTempDev z=-0.0 w=0.05 (dev=0.0C penalty=-|dev|/1.0)"
        )
    }

    /// The second trap in the same helper: an exact -0.0 cannot be routed by a sign COMPARISON, because
    /// `-0.0 < 0.0` is false. It is reachable — a skin-temp deviation of exactly 0.0 (skin temp sitting
    /// on the personal baseline) gives z = -|dev| = -0.0. Swift's `.rounded()` carries the sign for
    /// free; this pins that the Kotlin twin does too. Twin: `traceKeepsExactNegativeZeroTerm`.
    func testTraceKeepsExactNegativeZeroTerm() {
        let hrvB = baseline(mean: 50, sigma: 6)
        let (_, lines) = RecoveryScorer.recoveryTrace(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: nil, skinTempDev: 0.0)
        XCTAssertEqual(
            lines.first { $0.hasPrefix("charge term skinTempDev ") },
            "charge term skinTempDev z=-0.0 w=0.05 (dev=0.0C penalty=-|dev|/1.0)"
        )
    }

    func testTraceRoundsHalfTiesAwayFromZeroWithoutChangingScore() {
        let hrvB = baseline(mean: 50, sigma: 6)
        let plain = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: nil, skinTempDev: 0.125)
        let (traced, lines) = RecoveryScorer.recoveryTrace(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: nil, skinTempDev: 0.125)

        XCTAssertEqual(traced, plain)
        XCTAssertEqual(
            lines.first { $0.hasPrefix("charge term skinTempDev ") },
            "charge term skinTempDev z=-0.13 w=0.05 (dev=0.13C penalty=-|dev|/1.0)"
        )
    }

    func testTracePreservesNonTieRounding() {
        let hrvB = baseline(mean: 50, sigma: 6)
        let plain = RecoveryScorer.recovery(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: nil, skinTempDev: 0.124)
        let (traced, lines) = RecoveryScorer.recoveryTrace(
            hrv: 50, rhr: 55, resp: nil,
            hrvBaseline: hrvB, rhrBaseline: nil, respBaseline: nil,
            sleepPerf: nil, skinTempDev: 0.124)

        XCTAssertEqual(traced, plain)
        XCTAssertEqual(
            lines.first { $0.hasPrefix("charge term skinTempDev ") },
            "charge term skinTempDev z=-0.12 w=0.05 (dev=0.12C penalty=-|dev|/1.0)"
        )
    }

    /// #47: the two-decimal trace-rounding contract itself, pinned as RAW BITS rather than as text.
    /// Text would hide what this pins: Swift and Kotlin print the same Double differently ("1e+20" vs
    /// "1.0E20"), and -0.0 vs 0.0 is a one-bit difference. This side is the oracle — the Kotlin twin
    /// carries these same bit patterns as literals, so a change here without a change there fails over
    /// there. Twin: `traceRound2MatchesTheSwiftContract`.
    func testTraceRound2MatchesTheSwiftContract() {
        let cases: [(String, Double, String)] = [
            ("-0.004", -0.004, "8000000000000000"), // -0.0: sign survives rounding to zero
            ("0.004", 0.004, "0"),
            ("1e20", 1e20, "4415af1d78b58c40"), // large finite value, not a signed-64 ceiling
            ("-1e20", -1e20, "c415af1d78b58c40"),
            ("0.0", 0.0, "0"),
            ("-0.0", -0.0, "8000000000000000"),
            ("0.125", 0.125, "3fc0a3d70a3d70a4"), // positive half-tie -> away from zero (0.13)
            ("-0.125", -0.125, "bfc0a3d70a3d70a4"), // negative half-tie -> -0.13
            ("1.2349", 1.2349, "3ff3ae147ae147ae"), // ordinary non-ties
            ("-1.2349", -1.2349, "bff3ae147ae147ae"),
            // Just below the half-tie: a floor(m + 0.5) implementation would round this UP.
            ("0.0049999999999999994", 0.0049999999999999994, "0"),
            ("-0.0049999999999999994", -0.0049999999999999994, "8000000000000000"),
            ("1e306", 1e306, "7f76c8e5ca239029"), // largest magnitudes whose *100 is still finite
            ("-1e306", -1e306, "ff76c8e5ca239029"),
            // Finite input whose intermediate x * 100 overflows: both platforms yield an infinity.
            ("1e307", 1e307, "7ff0000000000000"),
            ("-1e307", -1e307, "fff0000000000000"),
        ]
        for (label, input, bits) in cases {
            XCTAssertEqual(String(RecoveryScorer.traceRound2(input).bitPattern, radix: 16), bits,
                           "traceRound2(\(label))")
        }
    }

    /// #47: the exact differential fixture. Every line of one full-term night, pinned verbatim, so a
    /// rounding change on either platform shows up as a text diff rather than as two field logs that
    /// quietly disagree. The skin-temp deviation is 0.004, the issue's near-zero negative: it must
    /// render `z=-0.0` and `dev=0.0C`. Twin: `traceFixtureIsByteIdenticalAcrossPlatforms`.
    func testTraceFixtureIsByteIdenticalAcrossPlatforms() {
        let (_, lines) = RecoveryScorer.recoveryTrace(
            hrv: 62, rhr: 51, resp: 15,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2),
            sleepPerf: 0.9, skinTempDev: 0.004)
        XCTAssertEqual(lines, [
            "charge baseline hrv mean=50.0 spread=4.79 nValid=14 status=trusted",
            "charge baseline rhr mean=55.0 spread=2.39 nValid=14 status=trusted",
            "charge baseline resp mean=16.0 spread=1.6 nValid=14 status=trusted",
            "charge term hrv z=2.0 w=0.55 (higher HRV is better)",
            "charge term rhr z=1.33 w=0.2 (lower RHR is better)",
            "charge term resp z=0.5 w=0.05 (lower resp is better)",
            "charge term sleepPerf z=0.42 w=0.15 (rest=0.9 center=0.85)",
            "charge term skinTempDev z=-0.0 w=0.05 (dev=0.0C penalty=-|dev|/1.0)",
            "charge nilTerm dropped=[] (each dropped term renormalizes the remaining weights)",
            "charge renorm totalWeight=1.0 compositeZ=1.45 (z = sum(z*w)/sum(w))",
            "charge score=93.38 band=green (logistic k=1.6 z0=-0.2)",
        ])
    }
}
