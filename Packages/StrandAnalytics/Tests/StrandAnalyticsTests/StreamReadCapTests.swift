import Foundation
import XCTest
@testable import StrandAnalytics

/// Per-stream read caps (#1538) — twin of the Kotlin `StreamReadCapTest`, same cases and same numbers.
final class StreamReadCapTests: XCTestCase {

    /// THE invariant. A cap must exceed what a full window can legitimately hold, or a complete read is
    /// indistinguishable from a truncated one — and the truncated one silently loses its newest rows.
    /// If the window span or a stream's rate ever changes, this fails instead of a night being clipped.
    func testCapExceedsAFullWindowForEveryStream() {
        let fullHR = Double(StreamReadCap.windowSeconds) * StreamReadCap.hrRowsPerSecond
        let fullRR = Double(StreamReadCap.windowSeconds) * StreamReadCap.rrRowsPerSecond
        XCTAssertGreaterThan(Double(StreamReadCap.hr), fullHR)
        XCTAssertGreaterThan(Double(StreamReadCap.rr), fullRR)
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
    }
}
