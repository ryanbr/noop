import XCTest
@testable import StrandAnalytics
import WhoopProtocol

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

    /// #1169 instrumentation: `AnalyticsEngine.primarySessionRestingHR` windows HR to each session and
    /// selects the LONGEST — a nap and out-of-window samples must not pollute the primary-night mean.
    func testPrimarySessionRestingHRWindowsAndSelectsLongest() {
        let night = SleepSession(start: 0, end: 30_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        let nap = SleepSession(start: 40_000, end: 45_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        var hr = (0..<100).map { HRSample(ts: $0 * 30, bpm: 60) }        // inside the night
        hr += (0..<50).map { HRSample(ts: 40_000 + $0 * 30, bpm: 45) }   // inside the nap
        hr += (0..<50).map { HRSample(ts: 31_000 + $0 * 10, bpm: 100) }  // between the two — excluded
        XCTAssertEqual(AnalyticsEngine.primarySessionRestingHR(sessions: [nap, night], hr: hr), 60.0)
    }

    /// Half-open `[start, end)`: a sample exactly at `end` is excluded (kept identical to the Kotlin twin).
    func testPrimarySessionRestingHRExcludesEndBoundarySample() {
        let s = SleepSession(start: 0, end: 3000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        var hr = (0..<40).map { HRSample(ts: $0 * 60, bpm: 58) }         // 0…2340, inside
        hr.append(HRSample(ts: 3000, bpm: 200))                          // exactly at end → excluded
        XCTAssertEqual(AnalyticsEngine.primarySessionRestingHR(sessions: [s], hr: hr), 58.0)
    }

    // MARK: - #1169 coverage inputs (shadow metadata beside the mean)

    /// Coverage reports the LONGEST session's VALID-sample count (invalids excluded) and its duration —
    /// the raw inputs the later holdout weights by. Nap + out-of-range samples must not count.
    func testCoverageReportsValidCountAndDurationOfLongestSession() {
        let night = S(durationSec: 8 * 3600, bpm: Array(repeating: 64, count: 480) + [0, 300])
        let nap = S(durationSec: 40 * 60, bpm: Array(repeating: 50, count: 40))
        let cov = P.coverage(sessions: [nap, night])
        XCTAssertEqual(cov?.validSamples, 480)
        XCTAssertEqual(cov?.durationSec, 8 * 3600)
    }

    /// Coverage is nil in LOCKSTEP with `meanHR`: below the gate, both return nil (so the mean and its
    /// coverage are always emitted together or not at all).
    func testCoverageIsNilInLockstepWithMean() {
        let thin = [S(durationSec: 3600, bpm: Array(repeating: 60, count: 5))]
        XCTAssertNil(P.meanHR(sessions: thin))
        XCTAssertNil(P.coverage(sessions: thin))
        XCTAssertNil(P.coverage(sessions: []))
    }

    /// The AnalyticsEngine wrapper windows HR to the longest session, same as the mean wrapper.
    func testPrimarySessionRestingHRCoverageWindowsToLongest() {
        let night = SleepSession(start: 0, end: 30_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        let nap = SleepSession(start: 40_000, end: 45_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        var hr = (0..<100).map { HRSample(ts: $0 * 30, bpm: 60) }
        hr += (0..<50).map { HRSample(ts: 40_000 + $0 * 30, bpm: 45) }
        let cov = AnalyticsEngine.primarySessionRestingHRCoverage(sessions: [nap, night], hr: hr)
        XCTAssertEqual(cov?.validSamples, 100)
        XCTAssertEqual(cov?.durationSec, 30_000)
    }

    /// The combined wrapper windows the HR ONCE but must return byte-identical (mean, coverage) to calling the
    /// two separate wrappers — the only caller (IntelligenceEngine) needs both, so this locks the dedup.
    func testWithCoverageMatchesSeparateCalls() {
        let night = SleepSession(start: 0, end: 30_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        let nap = SleepSession(start: 40_000, end: 45_000, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
        var hr = (0..<100).map { HRSample(ts: $0 * 30, bpm: 60) }
        hr += (0..<50).map { HRSample(ts: 40_000 + $0 * 30, bpm: 45) }
        let sessions = [nap, night]
        let combined = AnalyticsEngine.primarySessionRestingHRWithCoverage(sessions: sessions, hr: hr)
        XCTAssertEqual(combined.mean, AnalyticsEngine.primarySessionRestingHR(sessions: sessions, hr: hr))
        let sep = AnalyticsEngine.primarySessionRestingHRCoverage(sessions: sessions, hr: hr)
        XCTAssertEqual(combined.coverage?.validSamples, sep?.validSamples)
        XCTAssertEqual(combined.coverage?.durationSec, sep?.durationSec)
    }
}
