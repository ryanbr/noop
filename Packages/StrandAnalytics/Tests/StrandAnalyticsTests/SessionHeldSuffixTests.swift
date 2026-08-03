import XCTest
@testable import StrandAnalytics

/// #1020 — the ` after <n>s` suffix on a `connect down` trace line. Twin of the Kotlin
/// `ConnectionDownReasonTest`'s duration cases; the same inputs, because a log pasted into an issue must
/// read the same whichever platform wrote it.
///
/// The reason this exists: a report of thousands of reconnects arrived with a log whose every drop read
/// `connect down (uptime ends)`. Nothing in that line said whether the sessions lasted seconds or
/// minutes, which is the first split between a bond watchdog firing and a radio-side drop, so the issue
/// needed a round trip before anyone could start on it.
final class SessionHeldSuffixTests: XCTestCase {

    /// The ordinary case, to a tenth: enough to separate a watchdog from a stall, no false precision.
    func testAHeldSessionReportsItsLengthToATenth() {
        XCTAssertEqual(ConnectionTrace.sessionHeldSuffix(millis: 6_800), " after 6.8s")
        XCTAssertEqual(ConnectionTrace.sessionHeldSuffix(millis: 120_000), " after 120.0s")
        XCTAssertEqual(ConnectionTrace.sessionHeldSuffix(millis: 432), " after 0.4s")
    }

    /// An unknown start yields NO suffix rather than `after 0.0s` — "dropped instantly" and "we do not
    /// know when it came up" are different diagnoses and must not render alike.
    func testAnUnknownStartAddsNothing() {
        XCTAssertEqual(ConnectionTrace.sessionHeldSuffix(millis: -1), "")
    }

    /// A genuine instant drop is still reported: zero is a measurement, unlike the negative sentinel.
    func testAnInstantDropIsStillReported() {
        XCTAssertEqual(ConnectionTrace.sessionHeldSuffix(millis: 0), " after 0.0s")
    }
}
