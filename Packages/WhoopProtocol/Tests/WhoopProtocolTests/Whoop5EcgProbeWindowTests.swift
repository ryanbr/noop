import XCTest
@testable import WhoopProtocol

/// #891 — the two rules that decide whether a run can OBSERVE a completed reading at all.
///
/// Both defects they pin were invisible to every existing test, because the probe's own report looked
/// correct: the packet count was honest, the verdict wording was honest, and the run simply never
/// reached the frame that carries the answer. @meta1971's field timing (terminal frame at 38 to 39 s
/// across five MG sessions, variability unset for 2 to 9 s after it) is the evidence behind the numbers.
///
/// The Kotlin twin pins the same cases in `Whoop5EcgProbeWindowTest`.
final class Whoop5EcgProbeWindowTests: XCTestCase {

    func testCaptureWindowOutlastsTheMeasuredTerminalFrame() {
        // The whole defect in one assertion: 30 s cannot reach a frame that lands at 38 to 39 s.
        XCTAssertGreaterThan(Whoop5EcgProbe.Window.capture, 39)
        XCTAssertEqual(Whoop5EcgProbe.Window.capture, 60)
        // A run waiting on a COMMAND_RESPONSE is not waiting on a reading, so it keeps the short window.
        XCTAssertEqual(Whoop5EcgProbe.Window.selectOrStop, 30)
        // Long enough to outlast the measured 2-to-9 s unset variability window after the terminal frame.
        XCTAssertGreaterThan(Whoop5EcgProbe.Window.terminalGrace, 9)
        XCTAssertEqual(Whoop5EcgProbe.Window.terminalGrace, 10)
    }

    func testOrdinaryFramesFillTheCapAndThenStop() {
        XCTAssertTrue(Whoop5EcgProbe.retainsCandidate(linesKept: 0, terminalLinesKept: 0,
                                                      isTerminal: false))
        XCTAssertTrue(Whoop5EcgProbe.retainsCandidate(linesKept: 11, terminalLinesKept: 0,
                                                      isTerminal: false))
        XCTAssertFalse(Whoop5EcgProbe.retainsCandidate(linesKept: 12, terminalLinesKept: 0,
                                                       isTerminal: false))
        XCTAssertFalse(Whoop5EcgProbe.retainsCandidate(linesKept: 99, terminalLinesKept: 0,
                                                       isTerminal: false))
    }

    func testTerminalFramesAreKeptPastTheCapButStayBounded() {
        // THE #891 CASE. R17 arrives about once a second, so at the terminal frame the ordinary cap has
        // long since filled with seconds 1 to 12 — the twelve frames that carry no result.
        XCTAssertTrue(Whoop5EcgProbe.retainsCandidate(linesKept: 12, terminalLinesKept: 0,
                                                      isTerminal: true))
        XCTAssertTrue(Whoop5EcgProbe.retainsCandidate(linesKept: 40, terminalLinesKept: 3,
                                                      isTerminal: true))
        // Bounded: the reserve is four slots, not an exemption.
        XCTAssertFalse(Whoop5EcgProbe.retainsCandidate(linesKept: 40, terminalLinesKept: 4,
                                                       isTerminal: true))
        XCTAssertEqual(Whoop5EcgProbe.maxCandidateLines + Whoop5EcgProbe.maxTerminalCandidateLines, 16)
    }

    func testTheGraceExtensionHappensOncePerRun() {
        XCTAssertEqual(Whoop5EcgProbe.terminalGraceSeconds(isTerminal: true, alreadyExtended: false), 10)
        // A terminal STREAM must not be able to postpone the verdict indefinitely.
        XCTAssertNil(Whoop5EcgProbe.terminalGraceSeconds(isTerminal: true, alreadyExtended: true))
        // An ordinary frame leaves the run's deadline alone.
        XCTAssertNil(Whoop5EcgProbe.terminalGraceSeconds(isTerminal: false, alreadyExtended: false))
        XCTAssertNil(Whoop5EcgProbe.terminalGraceSeconds(isTerminal: false, alreadyExtended: true))
    }
}
