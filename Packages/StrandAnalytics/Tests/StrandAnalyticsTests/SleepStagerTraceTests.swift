import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepStagerTraceTests: XCTestCase {

    // MARK: - E1: pure formatter

    func testRunLineKept() {
        let line = SleepStager.GateTrace.runLine(
            index: 0, startTs: 1_749_513_600, endTs: 1_749_513_600 + 5400,
            verdict: .kept, gate: "minSleepMin", detail: "spanMin=90 minSleepMin=60")
        XCTAssertEqual(line, "gate run=0 spanS=5400 KEPT gate=minSleepMin spanMin=90 minSleepMin=60")
    }

    func testRunLineDropped() {
        let line = SleepStager.GateTrace.runLine(
            index: 2, startTs: 0, endTs: 1800,
            verdict: .dropped, gate: "minSleepMin", detail: "spanMin=30 minSleepMin=60")
        XCTAssertEqual(line, "gate run=2 spanS=1800 DROPPED gate=minSleepMin spanMin=30 minSleepMin=60")
    }

    func testFlipLine() {
        let line = SleepStager.GateTrace.flipLine(
            epoch: 14, from: "wake", to: "sleep", threshold: "hrMult=1.05 bpm=49 baseline=52")
        XCTAssertEqual(line, "epoch=14 flip wake->sleep threshold=hrMult=1.05 bpm=49 baseline=52")
    }

    func testNoEmDash() {
        let line = SleepStager.GateTrace.runLine(
            index: 0, startTs: 0, endTs: 60, verdict: .kept, gate: "x", detail: "y")
        XCTAssertFalse(line.contains("\u{2014}"))
    }

    // MARK: - fixtures for the live-ladder tests (E2/E3)

    /// Build a still gravity stream at 1 Hz.
    fileprivate func still(_ start: Int, _ durS: Int) -> [GravitySample] {
        (0..<durS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }
    fileprivate func hr(_ start: Int, _ durS: Int, _ bpm: Int) -> [HRSample] {
        (0..<durS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    // MARK: - E2: per-run verdicts emitted from the live ladder

    func testGateTraceDropsShortRun() {
        // A 30-minute still low-HR run at 02:00 UTC: below minSleepMin (60), so it is DROPPED
        // by the minSleepMin gate. Assert the trace carries the expected DROPPED line and that
        // detection still returns zero sessions (the trace did not alter the result).
        let start = 1_749_513_600 + 2 * 3600
        let dur = 30 * 60
        var lines: [String] = []
        let sessions = SleepStager.detectSleep(
            hr: hr(start, dur, 50), gravity: still(start, dur),
            traceSink: { lines.append($0) })
        XCTAssertEqual(sessions.count, 0)
        XCTAssertTrue(lines.contains { $0.contains("DROPPED gate=minSleepMin") },
                      "expected a minSleepMin drop line, got: \(lines)")
    }

    /// The one-line detection summary must be emitted and reflect the pass: a single 30-min run is seen
    /// and dropped by minSleepMin, so `kept=0` and `droppedMinSleep=1`. This is the glanceable line that
    /// makes the "slept 8h, app shows 1h" fragmentation readable in an export without hand-summing.
    func testDetectionSummaryLineEmitted() {
        let start = 1_749_513_600 + 2 * 3600
        let dur = 30 * 60
        var lines: [String] = []
        let sessions = SleepStager.detectSleep(
            hr: hr(start, dur, 50), gravity: still(start, dur),
            traceSink: { lines.append($0) })
        XCTAssertEqual(sessions.count, 0)
        guard let summary = lines.first(where: { $0.hasPrefix("sleep-detect summary:") }) else {
            return XCTFail("expected a sleep-detect summary line, got: \(lines)")
        }
        // Guaranteed-true facts (no exact span/count pins — those depend on run-boundary mechanics):
        // nothing survived, so kept=0 and survivingSpanMin=0; a run WAS seen and dropped by minSleepMin.
        XCTAssertTrue(summary.contains("kept=0"), summary)
        XCTAssertTrue(summary.contains("survivingSpanMin=0"), summary)
        XCTAssertFalse(summary.contains("droppedMinSleep=0"), "expected >=1 drop: \(summary)")
        XCTAssertFalse(summary.contains("detectedSpanMin=0"), "expected a detected run: \(summary)")
    }

    func testGateTraceKeepsRealNight() {
        // A 90-minute still low-HR overnight run clears every gate -> one KEPT line.
        let start = 1_749_513_600 + 2 * 3600
        let dur = 90 * 60
        var lines: [String] = []
        let sessions = SleepStager.detectSleep(
            hr: hr(start, dur, 50), gravity: still(start, dur),
            traceSink: { lines.append($0) })
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(lines.contains { $0.contains("KEPT gate=accepted") })
    }

    func testTracedAndUntracedReturnIdenticalSessions() {
        // The trace is side-effect-only: a traced call and an untraced call must return the
        // identical [SleepSession]. This is the byte-identical-output guard for the mode.
        let start = 1_749_513_600 + 2 * 3600
        let dur = 90 * 60
        let untraced = SleepStager.detectSleep(hr: hr(start, dur, 50), gravity: still(start, dur))
        let traced = SleepStager.detectSleep(hr: hr(start, dur, 50), gravity: still(start, dur),
                                             traceSink: { _ in })
        XCTAssertEqual(untraced, traced)
    }

    // MARK: - E3: sparse-gravity bridge trace

    func testSparseBridgeTraceEmittedOnlyWhenSparse() {
        // A dense overnight night is NOT sparse, so no sparse-bridge line appears.
        let start = 1_749_513_600 + 2 * 3600
        let dur = 90 * 60
        var lines: [String] = []
        _ = SleepStager.detectSleep(hr: hr(start, dur, 50), gravity: still(start, dur),
                                    traceSink: { lines.append($0) })
        XCTAssertFalse(lines.contains { $0.contains("gate=sparseBridge") })
    }
}
