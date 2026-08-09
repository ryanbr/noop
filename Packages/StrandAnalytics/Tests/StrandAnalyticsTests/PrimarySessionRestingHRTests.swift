import XCTest
@testable import StrandAnalytics

/// #1169 — the primary-session mean resting-HR definition. The oracle for the Android
/// `PrimarySessionRestingHRTest`; keep the two in lockstep (same fixtures, same numbers).
final class PrimarySessionRestingHRTests: XCTestCase {
    private typealias P = PrimarySessionRestingHR
    private typealias S = PrimarySessionRestingHR.Session

    /// A shorter, lower-HR nap must NOT replace the longer main night — the half the shipped `.min()`
    /// across sessions gets wrong. Longest session wins, order-independent.
    func testNapDoesNotReplaceTheLongerMainNight() {
        let mainNight = S(durationSec: 8 * 3600, bpm: Array(repeating: 64, count: 480))  // 8h @ 64
        let nap = S(durationSec: 40 * 60, bpm: Array(repeating: 50, count: 40))           // 40m @ 50 (lower)
        XCTAssertEqual(P.meanHR(sessions: [nap, mainNight]), 64.0)
        XCTAssertEqual(P.meanHR(sessions: [mainNight, nap]), 64.0)
    }

    /// The SAMPLE mean is unweighted, so irregular cadence weights by COUNT, not wall-time. Asserted
    /// explicitly so a future time-weighted variant is a deliberate, visible change (issue's caveat).
    func testSampleMeanIsUnweightedByCadence() {
        let bpm = Array(repeating: 60, count: 90) + Array(repeating: 40, count: 10)
        // (90*60 + 10*40) / 100 = 58.0
        XCTAssertEqual(P.meanHR(sessions: [S(durationSec: 8 * 3600, bpm: bpm)]), 58.0)
    }

    /// Spikes, dropouts and 0s outside 30…220 are excluded; the mean is over the valid samples only.
    func testInvalidSamplesAreExcluded() {
        let bpm = Array(repeating: 60, count: 40) + [0, 300, -5, 250]
        XCTAssertEqual(P.meanHR(sessions: [S(durationSec: 8 * 3600, bpm: bpm)]), 60.0)
    }

    /// Below the coverage floor → nil rather than a noisy value; an all-invalid session is nil too.
    func testInsufficientCoverageReturnsNil() {
        XCTAssertNil(P.meanHR(sessions: [S(durationSec: 3600, bpm: Array(repeating: 60, count: 5))]))
        XCTAssertNil(P.meanHR(sessions: [S(durationSec: 3600, bpm: Array(repeating: 0, count: 100))]))
    }

    /// A constant-HR session returns exactly that value.
    func testConstantHRExact() {
        XCTAssertEqual(P.meanHR(sessions: [S(durationSec: 3600, bpm: Array(repeating: 58, count: 100))]), 58.0)
    }

    /// No sessions → nil.
    func testNoSessionsReturnsNil() {
        XCTAssertNil(P.meanHR(sessions: []))
    }

    /// Equal-duration sessions resolve to the FIRST (the documented tie rule). Locked so the selection
    /// can't silently diverge from the Kotlin twin under a tie — the two stdlibs must agree here.
    func testEqualDurationTieSelectsFirst() {
        let a = S(durationSec: 6 * 3600, bpm: Array(repeating: 60, count: 100))
        let b = S(durationSec: 6 * 3600, bpm: Array(repeating: 50, count: 100))
        XCTAssertEqual(P.meanHR(sessions: [a, b]), 60.0)  // first (a) wins the tie
        XCTAssertEqual(P.meanHR(sessions: [b, a]), 50.0)  // order flips → first (b) wins
    }

    /// The coverage threshold is a parameter, so the validation phase can tune it.
    func testCoverageThresholdIsParameterised() {
        let bpm = Array(repeating: 62, count: 12)
        XCTAssertNil(P.meanHR(sessions: [S(durationSec: 3600, bpm: bpm)], minValidSamples: 20))
        XCTAssertEqual(P.meanHR(sessions: [S(durationSec: 3600, bpm: bpm)], minValidSamples: 10), 62.0)
    }
}
