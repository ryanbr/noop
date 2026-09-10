import XCTest
@testable import StrandAnalytics

/// The per-day probe readout. Mirrored by the Kotlin `StoreProbeTallyTest`, which pins the SAME literals:
/// the line is read off one shared strap log, so a one-sided change to the format would make two platforms'
/// logs incomparable exactly when they are being compared.
final class StoreProbeTallyTests: XCTestCase {

    /// A warm two-strap pass: the scoring loop's 21 owner probes plus the steps loop's 60, and one gravity
    /// witness per steps day. This is the shape the line exists to make readable.
    func testRendersCallsAndMillisInOrder() {
        let line = StoreProbeTally.logLine([
            (name: "ownerHr", calls: 81, seconds: 1.24),
            (name: "gravityFp", calls: 60, seconds: 1.89),
        ])
        XCTAssertEqual(line, "analyzeRecent storeProbes total=3130ms ownerHr=81/1240ms gravityFp=60/1890ms")
    }

    /// A default SINGLE-strap install skips the owner probe entirely (#970), so zero calls must render as
    /// zero rather than being omitted: "not measured" and "measured, and it was free" are different
    /// findings, and only one of them means the batching idea is pointless for that user.
    func testZeroCallsStillRender() {
        let line = StoreProbeTally.logLine([
            (name: "ownerHr", calls: 0, seconds: 0),
            (name: "gravityFp", calls: 60, seconds: 1.89),
        ])
        XCTAssertEqual(line, "analyzeRecent storeProbes total=1890ms ownerHr=0/0ms gravityFp=60/1890ms")
    }

    func testNoProbesSaysSoRatherThanRenderingAnEmptyTail() {
        XCTAssertEqual(StoreProbeTally.logLine([]), "analyzeRecent storeProbes total=0ms (no probes)")
    }

    /// The renderer clamps, and that is a contract about the RENDERER rather than a claim about the probes:
    /// both sides now count monotonic nanoseconds, so neither can hand it a negative. It is pinned anyway
    /// because a negative or non-finite seconds value is the one input where Swift's round-half-away-from-
    /// zero and Kotlin's round-half-up disagree, at exactly -0.5 ms, and the two platforms render into one
    /// shared strap log. A probe cannot take less than no time, so nothing true is lost by flooring it.
    func testNegativeAndNonFiniteSecondsClampToZeroOnBothSides() {
        let line = StoreProbeTally.logLine([
            (name: "ownerHr", calls: 3, seconds: -0.0005),
            (name: "gravityFp", calls: 1, seconds: .nan),
        ])
        XCTAssertEqual(line, "analyzeRecent storeProbes total=0ms ownerHr=3/0ms gravityFp=1/0ms")
    }

    /// The three-probe line as the engine actually renders it, pinned against the Kotlin twin's literal in
    /// `StoreProbeTallyTest.dayOwnerAndOwnerHrAreCountedSeparately`. The shape matters as much as the
    /// numbers: the LOOKUP and the PROBE are separate columns because collapsing them is what hid the
    /// lookup, and `gravityFp` renders even at zero so a pass that never reached the steps loop says so.
    func testThreeProbeLineMatchesTheKotlinTwin() {
        let line = StoreProbeTally.logLine([
            (name: "dayOwner", calls: 81, seconds: 1.62),
            (name: "ownerHr", calls: 132, seconds: 0.132),
            (name: "gravityFp", calls: 0, seconds: 0),
        ])
        XCTAssertEqual(line,
                       "analyzeRecent storeProbes total=1752ms dayOwner=81/1620ms ownerHr=132/132ms gravityFp=0/0ms")
    }
}
