import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #1118: RMSSD is withheld on a night whose own R-R banks more beat-time than the wall clock it spans.
///
/// Each over-count case asserts TWICE: that the gated call returns nil, AND that the very same beats do
/// produce an RMSSD through `sessionHrvWindows`. Without that second assertion the test would pass just as
/// well against a window that had no usable beats at all, proving nothing about the gate.
/// Byte-parity twin of Kotlin `HrvOverCountGateTest`.
final class HrvOverCountGateTests: XCTestCase {

    private func windowsYieldRMSSD(_ start: Int, _ end: Int, _ rr: [RRInterval]) -> Bool {
        !SleepStager.sessionHrvWindows(start: start, end: end, rr: rr, stages: []).compactMap { $0.rmssd }.isEmpty
    }

    /// Two near-equal beats per second: ~1.8x coverage that a same-second collapse would fix.
    func testSameSecondOverCountIsWithheld() {
        let start = 1_000, end = 1_600
        var rr: [RRInterval] = []
        for i in 0..<600 {
            rr.append(RRInterval(ts: start + i, rrMs: 900))
            rr.append(RRInterval(ts: start + i, rrMs: 905))
        }
        XCTAssertTrue(windowsYieldRMSSD(start, end, rr), "precondition: these beats DO yield an RMSSD")
        XCTAssertNil(SleepStager.sessionAvgHRV(start: start, end: end, rr: rr),
                     "an over-counted night must report no HRV")
    }

    /// Two beats per second far enough apart that a same-second collapse cannot reach them.
    func testCrossSecondOverCountIsWithheld() {
        let start = 1_000, end = 1_600
        var rr: [RRInterval] = []
        for i in 0..<600 {
            rr.append(RRInterval(ts: start + i, rrMs: 880))
            rr.append(RRInterval(ts: start + i, rrMs: 960))
        }
        XCTAssertTrue(windowsYieldRMSSD(start, end, rr), "precondition: these beats DO yield an RMSSD")
        XCTAssertNil(SleepStager.sessionAvgHRV(start: start, end: end, rr: rr),
                     "an over-counted night must report no HRV")
    }

    /// The gate must not touch an ordinary night: one beat per second, coverage ~1.0.
    func testAPlausibleNightStillReportsItsHRV() {
        let start = 1_000, end = 1_600
        let rr = (0..<600).map { RRInterval(ts: start + $0, rrMs: $0 % 2 == 0 ? 980 : 1_020) }
        let hrv = SleepStager.sessionAvgHRV(start: start, end: end, rr: rr)
        XCTAssertNotNil(hrv, "a plausible night must keep its HRV")
        XCTAssertGreaterThan(hrv ?? 0, 0, "and it must be a real reading, not zero")
    }

    /// A sparse night is underCovered, which is honest data and stays trusted.
    func testAnUnderCoveredNightIsNotGated() {
        let start = 1_000, end = 1_600
        let rr = (0..<300).map { RRInterval(ts: start + $0 * 2, rrMs: $0 % 2 == 0 ? 980 : 1_020) }
        XCTAssertNotNil(SleepStager.sessionAvgHRV(start: start, end: end, rr: rr),
                        "sparse is not the same as over-counted")
    }

    /// The verdict mapping itself, so the seam above and the rule stay pinned separately.
    func testOnlyTheTwoOverCountVerdictsRefuse() {
        XCTAssertFalse(HRVAnalyzer.successiveDiffIsTrustworthy(.sameSecondOverCount))
        XCTAssertFalse(HRVAnalyzer.successiveDiffIsTrustworthy(.crossSecondOverCount))
        XCTAssertTrue(HRVAnalyzer.successiveDiffIsTrustworthy(.plausible))
        XCTAssertTrue(HRVAnalyzer.successiveDiffIsTrustworthy(.underCovered))
        XCTAssertTrue(HRVAnalyzer.successiveDiffIsTrustworthy(.unmeasurable))
    }

    /// It refuses exactly what the SDNN gate refuses: same rule, stated twice on purpose, never drifting.
    func testItRefusesTheSameVerdictsAsTheSdnnGate() {
        let all: [HRVAnalyzer.RrCoverageVerdict] =
            [.plausible, .underCovered, .sameSecondOverCount, .crossSecondOverCount, .unmeasurable]
        for v in all {
            XCTAssertEqual(HRVAnalyzer.beatSpreadIsTrustworthy(v),
                           HRVAnalyzer.successiveDiffIsTrustworthy(v),
                           "verdict \(v) must be judged alike by both gates")
        }
    }
}
