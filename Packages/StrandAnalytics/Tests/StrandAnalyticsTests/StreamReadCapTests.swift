import Foundation
import XCTest
@testable import StrandAnalytics

/// Per-stream read caps (#1538) — twin of the Kotlin `StreamReadCapTest`, same cases and same numbers.
final class StreamReadCapTests: XCTestCase {

    /// THE invariant. A cap must exceed what a full window can legitimately hold, or a complete read is
    /// indistinguishable from a truncated one — and the truncated one silently loses its newest rows.
    func testCapExceedsAFullWindowForEveryStream() {
        let fullHR = Double(StreamReadCap.windowSeconds) * StreamReadCap.hrRowsPerSecond
        let fullRR = Double(StreamReadCap.windowSeconds) * StreamReadCap.rrRowsPerSecond
        XCTAssertGreaterThan(Double(StreamReadCap.hr), fullHR)
        XCTAssertGreaterThan(Double(StreamReadCap.rr), fullRR)
    }

    /// The test above is derived from the same constants as the caps, so on its own it only asserts that
    /// headroom exceeds 1. This one is anchored OUTSIDE the type, to a number the field produced: R-R
    /// came back at 200,000 ten times in one capture, so that value is known-insufficient rather than
    /// theorised. A cap at or below it would reintroduce the bug no matter how the arithmetic reads.
    func testCapsClearTheValueThatTruncatedInTheField() {
        let knownInsufficient = 200_000
        XCTAssertGreaterThan(StreamReadCap.rr, knownInsufficient)
        XCTAssertGreaterThan(StreamReadCap.hr, knownInsufficient,
                             "HR sat 3% under this and was lucky, not safe")
    }

    /// The window is not restated here — the engine reads `dayStart - lookbackSeconds`, so these are the
    /// same number by construction. Pinned so that splitting them again is a visible change.
    func testWindowIsItsTwoHalves() {
        XCTAssertEqual(StreamReadCap.windowSeconds,
                       StreamReadCap.lookbackSeconds + StreamReadCap.forwardSeconds)
        XCTAssertEqual(StreamReadCap.lookbackSeconds, 30 * 3_600)
        XCTAssertEqual(StreamReadCap.forwardSeconds, 86_400)
    }

    /// The regression itself, in the numbers that caused it. The old shared cap of 200,000 was ABOVE a
    /// full HR window and BELOW a full R-R one — which is exactly why HR never truncated, R-R always did,
    /// and one number looked adequate from the HR side.
    func testTheOldSharedCapWasBelowAFullRRWindow() {
        let oldSharedCap = 200_000.0
        let fullHR = Double(StreamReadCap.windowSeconds) * StreamReadCap.hrRowsPerSecond
        let fullRR = Double(StreamReadCap.windowSeconds) * StreamReadCap.rrRowsPerSecond
        XCTAssertGreaterThan(oldSharedCap, fullHR, "the old cap fitted HR, which is why it looked fine")
        XCTAssertLessThan(oldSharedCap, fullRR, "and did not fit R-R, which is why nights were clipped")
        XCTAssertGreaterThan(Double(StreamReadCap.rr), fullRR, "the new cap does fit it")
    }

    /// R-R must be capped higher than HR: it is one row per BEAT, not one per second.
    func testRRIsCappedHigherThanHR() {
        XCTAssertGreaterThan(StreamReadCap.rr, StreamReadCap.hr)
    }

    /// The window is 54 hours — `dayStart - 30h` running through the night. Pinned because both caps are
    /// derived from it, so a silent change here would resize them both.
    func testWindowIsFiftyFourHours() {
        XCTAssertEqual(StreamReadCap.windowSeconds, 54 * 3_600)
        XCTAssertEqual(StreamReadCap.hr, 291_600)
        XCTAssertEqual(StreamReadCap.rr, 583_200)
        XCTAssertEqual(StreamReadCap.gravity, 291_600)
    }

    /// Gravity is the third stream on the 54-hour window, and the field capture put it at 192,698 rows -
    /// 96% of the old shared cap. Unlike HR and R-R it is a PLAIN read with no truncation counter, so a
    /// clip there reports nothing at all; sleep staging simply gets a night missing its tail.
    func testGravityClearsWhatTheFieldMeasured() {
        let measuredInField = 192_698
        XCTAssertGreaterThan(StreamReadCap.gravity, measuredInField)
        XCTAssertGreaterThan(StreamReadCap.gravity, 200_000, "the old shared cap it sat 96% of")
    }

}
