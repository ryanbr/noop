import XCTest
import StrandAnalytics
@testable import Strand

/// Pins the "HR tracked but no sleep" diagnostic (#1244). When a day clears the >=200-HR gate yet the
/// stager detects NO in-bed session, the summary line only says `totalSleepMin=nil` with no clue why —
/// every other night trace (`rhr`/`rrsample`/`hrv diag`) emits only once a session exists. The engine now
/// ships one counts-only reason line naming the raw inputs the stager was handed, so the next capture
/// separates the causes (no motion vs coverage gap vs window). `sleepDetectNoNightLogLine` is the pure
/// formatter the loop calls; tested directly (no store). Mirrors the Android `sleepDetectNoNightLogLine`
/// so the two platforms log a byte-identical line.
@MainActor
final class IntelligenceSleepDetectNoNightTests: XCTestCase {

    private typealias IE = IntelligenceEngine

    func testNoMotionNight_theLeadingHypothesis() {
        // The #1244 shape: plenty of HR, but grav=0 (no motion offloaded) so the in-bed detector can't
        // gate the night → nothing stages. `window=54h` is the past-day span (30 h back → next midnight).
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-08-11", hrCount: 41230, rrCount: 0, respCount: 880,
            gravCount: 0, stepCount: 12, providedCount: 0, windowHours: 54, skinCount: 0)
        XCTAssertEqual(line,
            "sleep-detect day=2026-08-11 NO-NIGHT hr=41230 rr=0 resp=880 "
            // reason=no-motion with provided=0: no gravity AND the HR-only spine (#1801) yielded
            // nothing either. The bare reason is only correct because nothing was provided; see
            // `testNoMotionButSessionsWereProvided` for the case where it is not.
            + "grav=0 skin=0 steps=12 provided=0 window=54h reason=no-motion")
    }

    /// The case a 5/MG overnight capture actually hits, and the one no fixture covered.
    ///
    /// Since #1801 a no-gravity day still runs the HR-only spine. On that capture it kept four sessions,
    /// the longest 311 minutes, and handed them over — and this line still said `no-motion`, which reads
    /// as "nothing could stage a night" while the log above showed something had. With sessions provided
    /// and the night still empty, the question is what dropped them, not what the strap can do.
    ///
    /// The fixture asserts on PROVIDED sessions, not on their source: with no gravity they may be the
    /// HR-only spine's output or a stored hypnogram, and the line cannot tell. Claiming otherwise would
    /// be the same over-claim this split removes.
    func testNoMotionButSessionsWereProvided() {
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-09-21", hrCount: 106144, rrCount: 73959, respCount: 0,
            gravCount: 0, stepCount: 0, providedCount: 3, windowHours: 30, skinCount: 0)
        // EXACT match on the parsed token, not `contains`. `no-motion` is a PREFIX of
        // `no-motion-provided-unused`, so a contains check matches both and cannot catch a regression to
        // the bare value. The first version of this assertion used `contains("reason=no-motion ")` with a
        // trailing space, which is false for BOTH values whenever nothing is at its read cap, so it could
        // never fail at all.
        XCTAssertEqual(Self.reasonToken(of: line), "no-motion-provided-unused", line)
    }

    /// No gravity AND nothing provided keeps the plain reason: HR alone yielded nothing either.
    func testNoMotionAndNothingProvidedKeepsThePlainReason() {
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-09-21", hrCount: 106144, rrCount: 73959, respCount: 0,
            gravCount: 0, stepCount: 0, providedCount: 0, windowHours: 30, skinCount: 0)
        XCTAssertEqual(Self.reasonToken(of: line), "no-motion", line)
    }

    /// Motion present still outranks everything: the inputs were there and staging produced nothing.
    func testMotionPresentStaysStagedNoneEvenWithProvidedSessions() {
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-09-21", hrCount: 5000, rrCount: 900, respCount: 300,
            gravCount: 4, stepCount: 0, providedCount: 3, windowHours: 48, skinCount: 0)
        XCTAssertEqual(Self.reasonToken(of: line), "staged-none", line)
    }

    func testTodayWindowIs48h() {
        // Today's read caps at dayStart+18h (vs a past day's next-midnight), so the whole span is 48 h.
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-08-12", hrCount: 5000, rrCount: 900, respCount: 300,
            gravCount: 4, stepCount: 0, providedCount: 0, windowHours: 48, skinCount: 0)
        XCTAssertTrue(line.contains("window=48h"), line)
        // The other branch: motion WAS present and staging still produced nothing, which is the case
        // worth investigating rather than a capability limit.
        XCTAssertTrue(line.contains("reason=staged-none"), line)
    }

    func testLineCarriesNoEmDash() {
        // House style: never an em-dash in shared text.
        let line = IE.sleepDetectNoNightLogLine(
            day: "2026-08-11", hrCount: 1, rrCount: 1, respCount: 1,
            gravCount: 1, stepCount: 1, providedCount: 1, windowHours: 54, skinCount: 1)
        XCTAssertFalse(line.contains("—"))
    }

    /// The signal this line was missing. Gravity is a PLAIN read with no truncation counter, so a night
    /// clipped of its newest motion staged badly and said nothing about why — and `grav=192698` reads as
    /// healthy until you know it is 96% of a cap. A read that comes back AT the limit is truncated, which
    /// is what `full.count >= limit` means everywhere else here.
    func testAStreamAtItsReadCapIsNamed() {
        let line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day: "2026-09-06", hrCount: 1000, rrCount: 1000, respCount: 0,
            gravCount: StreamReadCap.gravity, stepCount: 0, providedCount: 0, windowHours: 54, skinCount: 0)
        XCTAssertTrue(line.contains("atCap=grav"), line)
    }

    /// HR and R-R at their caps produce NO marker, and that is deliberate rather than an oversight.
    ///
    /// Both arrive through `SlidingStreamWindow.rows`, which returns a SLICE of a read spanning more than
    /// this night, so a truncated spliced window still hands back a count under the cap — the marker would
    /// miss the very case it claims to catch. Their exact truncation count is printed once per pass by
    /// `WindowedStreamPlan.logLine` instead. Pinned so the omission is not "fixed" back in.
    func testHrAndRrAtTheirCapsCarryNoMarker() {
        let line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day: "2026-09-06", hrCount: StreamReadCap.hr, rrCount: StreamReadCap.rr, respCount: 0,
            gravCount: 10, stepCount: 0, providedCount: 0, windowHours: 54, skinCount: 0)
        XCTAssertFalse(line.contains("atCap"), line)
    }

    /// A healthy night says nothing extra — the marker only appears when something actually clipped.
    func testANightUnderTheCapsCarriesNoMarker() {
        let line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day: "2026-09-06", hrCount: 192_698, rrCount: 136_285, respCount: 0,
            gravCount: 192_698, stepCount: 0, providedCount: 0, windowHours: 54, skinCount: 0)
        XCTAssertFalse(line.contains("atCap"), line)
    }

    /// The field capture that motivated the caps: 192,698 gravity rows was 96% of the OLD 200,000 limit
    /// and silent. Under the caps this ships with, the same night is comfortably clear.
    func testTheMeasuredFieldNightIsClearOfTheCaps() {
        XCTAssertLessThan(192_698, StreamReadCap.gravity)
    }

    /// The count that could not be measured. Skin temp only appears in a Test Centre "Night" line, which
    /// fires when a session EXISTS — so on the nights being triaged, the ones with no sleep at all, its
    /// volume was invisible.
    func testTheLineReportsTheSkinSampleCount() {
        let line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day: "2026-09-06", hrCount: 1000, rrCount: 900, respCount: 0, gravCount: 0,
            stepCount: 0, providedCount: 0, windowHours: 54, skinCount: 4242)
        XCTAssertTrue(line.contains("skin=4242"), line)
    }

    /// Skin is the stream whose density was never measured, and it was the one `atCap` did not cover
    /// when the marker was first written — so a clipped skin read printed a bare count and no warning.
    func testSkinAtItsReadCapIsNamed() {
        let line = IntelligenceEngine.sleepDetectNoNightLogLine(
            day: "2026-09-06", hrCount: 10, rrCount: 10, respCount: 0, gravCount: 10,
            stepCount: 0, providedCount: 0, windowHours: 54, skinCount: StreamReadCap.skin)
        XCTAssertTrue(line.contains("atCap=skin"), line)
    }

    /// The `reason=` value alone, stopping at the space before any `atCap=` marker.
    ///
    /// Comparing the whole line with `contains` cannot separate `no-motion` from
    /// `no-motion-provided-unused`, since the first is a prefix of the second.
    private static func reasonToken(of line: String) -> String {
        guard let r = line.range(of: "reason=") else { return "" }
        return String(line[r.upperBound...].prefix { $0 != " " })
    }
}
