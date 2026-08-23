import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// #1545: the two always-on bout diagnostics — HR coverage, and the line naming what an Effort was scored
/// against.
///
/// Diagnosing #1545 meant reversing the arithmetic out of a displayed score to work out which HRmax had set
/// the zone boundaries. These two make that visible from a strap log alone, and split the three causes a
/// low Effort can have: the 50% floor doing its job, a wrong HRmax, or the sensor not being there.
///
/// Neither changes a score. That is exactly why they need pinning: a silently-wrong diagnostic is worse
/// than none, because the next report will be argued from it.
///
/// Byte-parity twin of Kotlin `BoutCalibrationDiagnosticTest`.
final class BoutCalibrationDiagnosticTests: XCTestCase {

    // MARK: coverage

    /// The reason coverage is bucketed rather than sample-counted.
    ///
    /// A WHOOP 5/MG sends live HR about every 30 s. Counted against a 1 Hz expectation a perfectly captured
    /// hour would report ~3% — a number that reads as "the sensor was off" for the most common healthy
    /// case, and would send every 5/MG user chasing a hardware fault that isn't there.
    func testAThirtySecondCadenceIsFullCoverageNotThreePercent() {
        let ts = stride(from: 0, to: 3600, by: 30).map { $0 }
        XCTAssertEqual(WorkoutDetector.hrCoveragePct(sampleTs: ts, start: 0, end: 3600) ?? -1,
                       100.0, accuracy: 1e-9)
    }

    /// And a real dropout still reads as the gap it is — the diagnostic has to keep the signal it exists
    /// for, not just avoid the false alarm above.
    func testARealDropoutReadsAsTheGap() {
        let ts = stride(from: 0, to: 1800, by: 30).map { $0 }          // first half only
        XCTAssertEqual(WorkoutDetector.hrCoveragePct(sampleTs: ts, start: 0, end: 3600) ?? -1,
                       50.0, accuracy: 1e-9)
    }

    /// Samples outside the bout must not inflate it. The detector back-dates a bout's start over the
    /// warm-up, so the surrounding day's samples are genuinely present in memory beside these.
    func testSamplesOutsideTheWindowAreIgnored() {
        let ts = Array(0 ..< 600) + Array(7200 ..< 10800)
        // 600 s in window = 10 of the hour's 60 buckets. The hour of samples AFTER the bout contributes
        // nothing — if it did, a bout followed by a long walk would report as fully covered.
        XCTAssertEqual(WorkoutDetector.hrCoveragePct(sampleTs: ts, start: 0, end: 3600) ?? -1,
                       10.0 / 60.0 * 100.0, accuracy: 1e-9)
    }

    /// A partial trailing bucket still counts as a whole one — 90 s is two buckets, not 1.5 — so coverage
    /// can never exceed 100 and a short bout can't read as over-covered.
    func testAPartialTrailingBucketCountsAsAWholeBucket() {
        let ts = Array(0 ..< 90)
        XCTAssertEqual(WorkoutDetector.hrCoveragePct(sampleTs: ts, start: 0, end: 90) ?? -1,
                       100.0, accuracy: 1e-9)
        // One sample in each of two buckets is still full coverage; one bucket empty is half.
        XCTAssertEqual(WorkoutDetector.hrCoveragePct(sampleTs: [0], start: 0, end: 90) ?? -1,
                       50.0, accuracy: 1e-9)
    }

    /// Degenerate windows report nothing rather than a fabricated 0 or 100.
    func testDegenerateWindowsAreNil() {
        XCTAssertNil(WorkoutDetector.hrCoveragePct(sampleTs: [1, 2], start: 100, end: 100))
        XCTAssertNil(WorkoutDetector.hrCoveragePct(sampleTs: [1, 2], start: 100, end: 50))
        XCTAssertNil(WorkoutDetector.hrCoveragePct(sampleTs: [1, 2], start: 0, end: 60, bucketSeconds: 0))
    }

    // MARK: the line

    /// The exact bytes. This string is compared between two users' logs — and between an iOS log and an
    /// Android one — so its shape is the contract, not an implementation detail.
    func testTheLineIsExactlyThis() {
        XCTAssertEqual(
            WorkoutDetector.boutCalibrationLine(day: "2026-08-24", durMin: 45, hrmax: 187.0,
                                                hrmaxSource: "caller", avgHRRPct: 52.4,
                                                hrCoveragePct: 43.2, strain: 8.14),
            "effort bout day=2026-08-24 durMin=45 hrmax=187 src=caller avgHRR=52 cover=43 effort=8.1")
    }

    /// Missing values say so. A bout with no HRmax is a different diagnosis from one with a low HRmax, and
    /// printing 0 for both would merge the two.
    func testMissingValuesRenderAsNilNotZero() {
        XCTAssertEqual(
            WorkoutDetector.boutCalibrationLine(day: "2026-08-24", durMin: 12, hrmax: nil,
                                                hrmaxSource: "estimated", avgHRRPct: nil,
                                                hrCoveragePct: nil, strain: nil),
            "effort bout day=2026-08-24 durMin=12 hrmax=nil src=estimated avgHRR=nil cover=nil effort=nil")
    }

    /// The rounding tie this formatter exists to remove. C `printf` rounds .5 to even and Java rounds it
    /// up, so `%.0f` on 52.5 would print 52 on iOS and 53 on Android — the two logs the line is meant to be
    /// compared across. Both platforms must produce the Java answer here.
    func testAHalfRoundsUpOnBothPlatforms() {
        XCTAssertEqual(WorkoutDetector.round0(52.5), "53")
        XCTAssertEqual(WorkoutDetector.round0(53.5), "54")   // printf: 52 then 54 — it ties to even
        XCTAssertEqual(WorkoutDetector.round0(0.5), "1")
        XCTAssertEqual(WorkoutDetector.round1(8.25), "8.3")
        XCTAssertEqual(WorkoutDetector.round1(0.0), "0.0")
        XCTAssertEqual(WorkoutDetector.round1(21.0), "21.0")
    }

    /// The NEGATIVE tie, which breaks the other way: Swift's `.rounded()` is half-away-from-zero and
    /// Java's `Math.round` is half-up, so they disagree on -4.5 (-5 vs -4). Rounding the magnitude and
    /// re-applying the sign makes them agree — and these values are non-negative in production precisely
    /// so that nobody notices when they stop agreeing, which is why it is pinned rather than assumed.
    func testNegativesRoundSymmetricallyAndKeepTheirSign() {
        XCTAssertEqual(WorkoutDetector.round1(-0.45), "-0.5")
        XCTAssertEqual(WorkoutDetector.round1(-8.25), "-8.3")
        XCTAssertEqual(WorkoutDetector.round0(-52.5), "-53")
    }

    /// The minus sign must survive. Integer `/` and `%` truncate toward zero, so a naive
    /// `"\(t / 10).\(abs(t % 10))"` renders -0.4 as `0.4` — a diagnostic silently reporting the
    /// opposite of the truth, which is worse than reporting nothing.
    func testASmallNegativeDoesNotLoseItsSign() {
        XCTAssertEqual(WorkoutDetector.round1(-0.4), "-0.4")
        XCTAssertNotEqual(WorkoutDetector.round1(-0.4), "0.4")
    }

    /// A non-finite value must not print `inf`/`nan` into a log people read as evidence.
    func testNonFiniteValuesAreNil() {
        XCTAssertEqual(WorkoutDetector.round0(Double.nan), "nil")
        XCTAssertEqual(WorkoutDetector.round1(Double.infinity), "nil")
        XCTAssertEqual(WorkoutDetector.round1(-Double.infinity), "nil")
    }

    /// And an absurd FINITE value must not take the process with it. `Int(1e300)` traps in Swift while
    /// Kotlin's `Math.round` saturates to `Long.MAX_VALUE` — a crash on one platform and a nonsense
    /// number on the other, from a line whose only job is explaining a bug. Both print `nil` instead.
    ///
    /// Not reachable through today's detector (it gates `maxHR > restingHR` before computing %HRR), but
    /// these formatters are public API and a near-zero HR reserve is the obvious way in.
    func testAnAbsurdFiniteValueIsNilRatherThanACrash() {
        XCTAssertEqual(WorkoutDetector.round0(1e300), "nil")
        XCTAssertEqual(WorkoutDetector.round1(-1e300), "nil")
        XCTAssertEqual(WorkoutDetector.round0(Double(Int.max)), "nil")
        // The bound is well clear of anything physiological — real values still print.
        XCTAssertEqual(WorkoutDetector.round0(220.0), "220")
    }

    // MARK: end to end

    /// The field has to actually arrive on a detected bout — a diagnostic that is always `nil` in
    /// production would pass every unit test above and tell a reporter nothing.
    func testDetectedBoutsCarryCoverage() {
        let hr = (0 ..< 3600).map { HRSample(ts: $0, bpm: $0 < 600 || $0 > 3000 ? 60 : 150) }
        let grav = (0 ..< 3600).map { GravitySample(ts: $0, x: $0 % 2 == 0 ? 0.9 : 0.5, y: 0.1, z: 0.1) }
        let bouts = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 60, maxHR: 190, age: 30)

        XCTAssertFalse(bouts.isEmpty, "fixture must produce a bout for this test to mean anything")
        for b in bouts {
            XCTAssertNotNil(b.hrCoveragePct, "a detected bout must report its coverage")
            // 1 Hz HR runs across the whole fixture, so every bucket of any detected window is populated
            // — the assertion holds wherever the detector back-dates the start to.
            XCTAssertEqual(b.hrCoveragePct ?? -1, 100.0, accuracy: 1e-9)
        }
    }
}
