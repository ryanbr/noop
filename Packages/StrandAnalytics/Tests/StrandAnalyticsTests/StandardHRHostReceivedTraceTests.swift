import XCTest
@testable import StrandAnalytics

/// What a strap log keeps about the standard-HR transport when no Test Centre mode is on.
///
/// The per-sample line was 52.8% of one gym session's log (3,009 of 5,704 lines on 22 Sep 2026), which is what
/// decides how much history the on-disk log (#2386) can hold. These tests pin what survives that: every refusal
/// at the moment it happens, and one summary a window carrying the counts, the span and the widest gap.
final class StandardHRHostReceivedTraceTests: XCTestCase {

    private typealias Trace = LivePersistTrace.StandardHRHostReceivedTrace

    /// A routine sample: one HR row, two R-R rows, nothing refused.
    private func routine(at second: Int, pendingHR: Int = 1, pendingRR: Int = 2) -> Trace.Sample {
        Trace.Sample(hostUnixSeconds: second, acceptedHRRows: 1, acceptedRRRows: 2,
                     rejectedHRRows: 0, rejectedRRRows: 0,
                     pendingHRRows: pendingHR, pendingRRRows: pendingRR)
    }

    /// THE ONE THAT MATTERS: a streaming strap writes one line a minute, not one a second, and that line
    /// carries what the sixty said.
    func testAQuietMinuteBecomesOneLineThatCarriesTheMinute() {
        var trace = Trace()
        var lines: [String] = []
        for second in 0...60 { lines += trace.record(routine(at: 1_790_000_000 + second), detailed: false) }
        XCTAssertEqual(lines, [
            "standard-hr transport host-received summary windowSec=59 samples=60 gapMaxSec=1"
            + " acceptedHRRows=60 acceptedRRRows=120 rejectedHRRows=0 rejectedRRRows=0"
            + " pendingHRRows=1 pendingRRRows=2",
        ])
    }

    /// The reason the per-sample line was added: a refusal is written the moment it happens, mode or no mode,
    /// and is still counted in the window.
    func testARefusedSampleIsWrittenAtOnceAndCounted() {
        var trace = Trace()
        var lines: [String] = []
        for second in 0..<30 { lines += trace.record(routine(at: second), detailed: false) }
        lines += trace.record(Trace.Sample(hostUnixSeconds: 30, acceptedHRRows: 0, acceptedRRRows: 1,
                                           rejectedHRRows: 1, rejectedRRRows: 2,
                                           pendingHRRows: 3, pendingRRRows: 4), detailed: false)
        XCTAssertEqual(lines, [
            "standard-hr transport host-received hostUnixSec=30 acceptedHRRows=0 acceptedRRRows=1"
            + " rejectedHRRows=1 rejectedRRRows=2 pendingHRRows=3 pendingRRRows=4",
        ])
        XCTAssertEqual(trace.close(), [
            "standard-hr transport host-received summary windowSec=30 samples=31 gapMaxSec=1"
            + " acceptedHRRows=30 acceptedRRRows=61 rejectedHRRows=1 rejectedRRRows=2"
            + " pendingHRRows=3 pendingRRRows=4",
        ])
    }

    /// A gap is the stall a reader used to have to find by eye through sixty timestamps.
    func testTheWidestGapIsReported() {
        var trace = Trace()
        for second in [0, 1, 2, 14, 15] { _ = trace.record(routine(at: second), detailed: false) }
        XCTAssertEqual(trace.close(), [
            "standard-hr transport host-received summary windowSec=15 samples=5 gapMaxSec=12"
            + " acceptedHRRows=5 acceptedRRRows=10 rejectedHRRows=0 rejectedRRRows=0"
            + " pendingHRRows=1 pendingRRRows=2",
        ])
    }

    /// With a Test Centre mode on, the per-sample readout is back in full — and the window still lands, so the
    /// two modes describe the same stream.
    func testDetailWritesEverySampleAndStillSummarises() {
        var trace = Trace()
        var lines: [String] = []
        for second in 0...60 { lines += trace.record(routine(at: second), detailed: true) }
        XCTAssertEqual(lines.filter { $0.contains("hostUnixSec=") }.count, 61)
        XCTAssertEqual(lines.filter { $0.contains("summary") }.count, 1)
    }

    /// Closing is what a disconnect, a background flush or a termination does: the last, partial window is the
    /// part a report is usually taken for.
    func testClosingWritesThePartialWindowOnceAndThenNothing() {
        var trace = Trace()
        for second in 0..<5 { _ = trace.record(routine(at: second), detailed: false) }
        XCTAssertEqual(trace.close().count, 1)
        XCTAssertEqual(trace.close(), [])
    }

    /// A span is only honest within one clock: a host clock that jumps backwards ends the window instead of
    /// rendering a negative one.
    func testAClockGoingBackwardsEndsTheWindow() {
        var trace = Trace()
        _ = trace.record(routine(at: 1_000), detailed: false)
        let lines = trace.record(routine(at: 900), detailed: false)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("standard-hr transport host-received summary windowSec=0 samples=1"), lines[0])
        XCTAssertEqual(trace.close().first?.contains("samples=1"), true)
    }

    /// The size of the thing: an hour of a streaming strap.
    func testAnHourOfStreamingIsSixtyLines() {
        var trace = Trace()
        var lines = 0
        for second in 0..<3_600 { lines += trace.record(routine(at: second), detailed: false).count }
        lines += trace.close().count
        XCTAssertEqual(lines, 60, "3,600 per-sample lines an hour become one a minute")
    }

    /// The exact pair of lines the Kotlin `ORACLE_QUIET` claims this trace renders.
    ///
    /// #2405: that oracle is Swift's output pasted into a Kotlin test, and nothing on this side asserted
    /// it, so the two could drift without a failure anywhere. The second line is the one that moved when
    /// the boundary gap started being carried: a window that opens one second after the last sample of
    /// the previous one reports exactly that.
    func testTheQuietMinutePairMatchesTheKotlinOracle() {
        var trace = Trace()
        var lines: [String] = []
        for second in 0...60 { lines += trace.record(routine(at: second), detailed: false) }
        lines += trace.close()
        XCTAssertEqual(lines, [
            "standard-hr transport host-received summary windowSec=59 samples=60 gapMaxSec=1"
            + " acceptedHRRows=60 acceptedRRRows=120 rejectedHRRows=0 rejectedRRRows=0"
            + " pendingHRRows=1 pendingRRRows=2",
            "standard-hr transport host-received summary windowSec=0 samples=1 gapMaxSec=1"
            + " acceptedHRRows=1 acceptedRRRows=2 rejectedHRRows=0 rejectedRRRows=0"
            + " pendingHRRows=1 pendingRRRows=2",
        ])
    }

    /// #2405: the stall that crosses a window boundary is the one a reader is looking for.
    ///
    /// A gap of a minute or more forces the roll on the very next sample, so before this it fell between
    /// two windows and was counted in neither: `gapMaxSec` could only ever describe stalls SHORTER than
    /// the window. Here the stream goes quiet for two minutes mid-session.
    func testAStallLongerThanTheWindowIsReportedByTheWindowItOpens() {
        var trace = Trace()
        var lines: [String] = []
        for t in 0..<30 { lines += trace.record(routine(at: 1_000 + t), detailed: false) }
        // Two minutes of silence, then the stream comes back.
        lines += trace.record(routine(at: 1_000 + 29 + 120), detailed: false)
        lines += trace.close()

        XCTAssertEqual(lines.count, 2, "the rolled window, then the closing one: \(lines)")
        XCTAssertTrue(lines[0].contains("windowSec=29 samples=30 gapMaxSec=1"), lines[0])
        XCTAssertTrue(lines[1].contains("samples=1 gapMaxSec=120"),
                      "the stall belongs to the window it opens: \(lines[1])")
    }

    /// A clock that steps backwards across the boundary has no honest span, so none is claimed.
    func testABackwardsClockAcrossTheBoundarySeedsNoGap() {
        var trace = Trace()
        var lines: [String] = []
        for t in 0..<5 { lines += trace.record(routine(at: 1_000 + t), detailed: false) }
        lines += trace.record(routine(at: 900), detailed: false)   // before this window began
        lines += trace.close()

        XCTAssertTrue(lines.last?.contains("gapMaxSec=0") == true, "got: \(lines)")
    }

    /// `close()` is a disconnect, a background flush or a termination, each of which accounts for the
    /// silence on its own. A stall measured across one would be reported twice.
    func testAGapAcrossACloseIsNotSeeded() {
        var trace = Trace()
        _ = trace.record(routine(at: 1_000), detailed: false)
        _ = trace.close()
        var lines = trace.record(routine(at: 1_000 + 600), detailed: false)
        lines += trace.close()

        XCTAssertTrue(lines.last?.contains("gapMaxSec=0") == true, "got: \(lines)")
    }
}
