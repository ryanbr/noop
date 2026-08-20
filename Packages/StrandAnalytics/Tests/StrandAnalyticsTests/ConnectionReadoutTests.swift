import XCTest
@testable import StrandAnalytics

/// The Connection & Sync line formatters + readout parsers (Test Centre). Pure - no clock, no BLE - so
/// fixtures pin the exact line shapes the Swift and Kotlin emitters share. Twin of the Android
/// ConnectionReadoutTest.
final class ConnectionTraceTests: XCTestCase {

    // A strap whose newest record sits before wall-now reads clockOk, with the [oldest, newest] span.
    func testClockDriftLineHealthy() {
        // 2026-06-26 12:00:00 UTC newest, oldest two days earlier, wall just after newest.
        let newest = 1_782_475_200            // 2026-06-26 12:00:00 UTC
        let oldest = newest - 2 * 86_400
        let wall = newest + 600               // wall 10 min ahead of the newest record
        let line = ConnectionTrace.clockDriftLine(oldestUnix: oldest, newestUnix: newest, wallNowUnix: wall)
        XCTAssertTrue(line.hasPrefix("clockDrift newest=2026-06-26 12:00:00 "), line)
        XCTAssertTrue(line.contains("newestVsWall=-600s"), line)
        XCTAssertTrue(line.contains("spanDays=2"), line)
        XCTAssertTrue(line.hasSuffix("clockOk"), line)
        XCTAssertFalse(line.contains("FUTURE"), line)
    }

    // A strap whose newest record is dated AHEAD of wall-now beyond the tolerance is FUTURE-DATED.
    func testClockDriftLineFutureDated() {
        let wall = 1_782_475_200
        let newest = wall + 3 * 86_400        // strap thinks it banked 3 days into the future
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: newest, wallNowUnix: wall)
        XCTAssertTrue(line.contains("newestVsWall=+\(3 * 86_400)s"), line)
        XCTAssertTrue(line.contains("FUTURE-DATED"), line)
        XCTAssertFalse(line.contains("oldest="), line)   // half range reply: no lower bound
    }

    // A small skew inside the tolerance window must NOT trip the future flag.
    func testClockDriftLineWithinToleranceIsOk() {
        let wall = 1_782_475_200
        let newest = wall + 60                // 1 min ahead, inside the 120s default tolerance
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: newest, wallNowUnix: wall)
        XCTAssertTrue(line.hasSuffix("clockOk"), line)
    }

    func testFirmwareLine() {
        XCTAssertEqual(ConnectionTrace.firmwareLine(version: 25, decodable: true), "firmware layout=v25 decodable")
        XCTAssertEqual(ConnectionTrace.firmwareLine(version: 30, decodable: false),
                       "firmware layout=v30 UNMAPPED (no motion/HR decoded)")
    }

    func testNoCursorLine() {
        XCTAssertEqual(ConnectionTrace.noCursorLine(),
                       "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)")
    }

    // #990: the -363 d drift that used to print "clockOk". Beyond the 48 h behind-tolerance the line
    // must carry a clock warning naming the day count, mirroring the universal line's shared verdict.
    func testClockDriftLineFarBehindIsWarning() {
        let wall = 1_782_475_200
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: wall - 363 * 86_400,
                                                  wallNowUnix: wall)
        XCTAssertTrue(line.contains("CLOCK-WARNING"), line)
        XCTAssertTrue(line.contains("363d behind wall"), line)
        XCTAssertFalse(line.contains("clockOk"), line)
    }

    func testClockDriftLineBehindWithinToleranceStaysOk() {
        let wall = 1_782_475_200
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: wall - 47 * 3_600,
                                                  wallNowUnix: wall)
        XCTAssertTrue(line.hasSuffix("clockOk"), line)
    }

    // #987: an epoch-era newest (never-set RTC, ~1970/71) is the named RTC-EPOCH fault, not a generic
    // behind warning and never clockOk.
    func testClockDriftLineEpochEraReadsRtcEpoch() {
        let line = ConnectionTrace.clockDriftLine(oldestUnix: nil, newestUnix: 40_000_000,  // 1971-04
                                                  wallNowUnix: 1_782_475_200)
        XCTAssertTrue(line.contains("RTC-EPOCH"), line)
        XCTAssertFalse(line.contains("clockOk"), line)
    }
}

final class ConnectionReadoutTests: XCTestCase {

    func testUptimeLabelFromConnectMarker() {
        let tail = ["[connection] connect up gen=1 latencyMs=420 uptimeStart=1000"]
        // 3 min 12 s after the connect.
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: tail, nowUnix: 1000 + 192), "3m 12s")
    }

    func testUptimeLabelDownAfterDisconnect() {
        let tail = [
            "[connection] connect up gen=1 latencyMs=420 uptimeStart=1000",
            "[connection] connect down (uptime ends)",
        ]
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: tail, nowUnix: 5000), "not connected")
    }

    /// #1020: the emitter appends a session duration, so the line the parser actually receives is no
    /// longer the bare one above. Pinned because the two are edited independently — the suffix was added
    /// on the strength of this match being a `contains`, and nothing was asserting that.
    func testUptimeLabelDownWithASessionDuration() {
        let tail = [
            "[connection] connect up gen=1 latencyMs=420 uptimeStart=1000",
            "[connection] connect down (uptime ends after 6.8s)",
        ]
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: tail, nowUnix: 5000), "not connected")
    }

    func testUptimeLabelEmptyTail() {
        XCTAssertEqual(ConnectionReadout.uptimeLabel(taggedTail: [], nowUnix: 5000), "not connected")
    }

    func testReconnectCountTakesHighest() {
        let tail = [
            "[connection] reconnect n=1 reason=connectionTimeout",
            "[connection] reconnect n=2 reason=connectionTimeout",
            "[connection] reconnect n=3 failedConnect reason=peerRemovedPairing",
        ]
        XCTAssertEqual(ConnectionReadout.reconnectCount(taggedTail: tail), 3)
    }

    func testReconnectCountZeroWhenNone() {
        XCTAssertEqual(ConnectionReadout.reconnectCount(taggedTail: ["[connection] connect up gen=1 uptimeStart=1"]), 0)
    }

    func testLastOffloadResult() {
        let tail = [
            "[connection] offload progress trim=100 chunkRows=5 sessionRows=5 sessionMotion=2 nights=1",
            "[connection] offload result=complete rows=42 nights=2",
        ]
        XCTAssertEqual(ConnectionReadout.lastOffloadResult(taggedTail: tail), "complete rows=42 nights=2")
    }

    func testLastOffloadResultStalled() {
        // #1466: a stall is now specifically rows=0 — an idle timeout that banked rows is reported as a
        // productive end instead (below), so this fixture tracks what the producer actually emits.
        let tail = ["[connection] offload result=stalled (idle timeout, rows=0)"]
        XCTAssertEqual(ConnectionReadout.lastOffloadResult(taggedTail: tail), "stalled (idle timeout, rows=0)")
    }

    func testLastOffloadResultIdleTimeoutAfterRows() {
        let tail = ["[connection] offload result=idle-timeout after rows=17205"]
        XCTAssertEqual(ConnectionReadout.lastOffloadResult(taggedTail: tail), "idle-timeout after rows=17205")
    }

    func testLastOffloadResultNilWhenNone() {
        XCTAssertNil(ConnectionReadout.lastOffloadResult(taggedTail: ["[connection] connect up gen=1 uptimeStart=1"]))
    }

    // MARK: - #990 per-session / all-time drained rows

    func testSessionRowsFromProgressLine() {
        let tail = ["[connection] offload progress trim=100 chunkRows=5 sessionRows=57 sessionMotion=2 nights=1"]
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: tail), 57)
    }

    func testSessionRowsResultLineWins() {
        let tail = [
            "[connection] offload progress trim=100 chunkRows=5 sessionRows=5 sessionMotion=2 nights=1",
            "[connection] offload result=complete rows=42 nights=2",
        ]
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: tail), 42)
    }

    func testSessionRowsEmptyResultIsZeroNotStale() {
        // An "empty" result carries no rows= field: it honestly means 0, never an older running total.
        let tail = [
            "[connection] offload progress trim=100 chunkRows=9 sessionRows=9 sessionMotion=2 nights=1",
            "[connection] offload result=empty (console only, no sensor records)",
        ]
        XCTAssertEqual(ConnectionReadout.sessionRows(taggedTail: tail), 0)
    }

    func testSessionRowsNilWhenNoOffload() {
        XCTAssertNil(ConnectionReadout.sessionRows(taggedTail: ["[connection] connect up gen=1 uptimeStart=1"]))
    }

    func testDrainedRowsFromSummary() {
        XCTAssertEqual(ConnectionReadout.drainedRowsFromSummary(
            "Backfill: session persisted 5397 rows (5211 with motion, 5211 skin-temp) across 2 night(s)."), 5_397)
        XCTAssertNil(ConnectionReadout.drainedRowsFromSummary("Backfill: session ended - reason=timeout"))
        XCTAssertNil(ConnectionReadout.drainedRowsFromSummary("session persisted garbage rows"))
    }

    // MARK: - #987 clock latch + last frame

    func testClockCorrelatedDeviceParsesNewest() {
        let lines = [
            "12:00:01  Clock correlated: device=100 wall=1782475200",
            "12:05:09  Clock correlated: device=1782475600 wall=1782475601",
        ]
        XCTAssertEqual(ConnectionReadout.clockCorrelatedDevice(logLines: lines), 1_782_475_600)
        XCTAssertNil(ConnectionReadout.clockCorrelatedDevice(logLines: ["connect up"]))
    }

    func testClockLatchedLabel() {
        XCTAssertEqual(ConnectionReadout.clockLatchedLabel(deviceClockUnix: 1_782_475_600), "yes")
        XCTAssertEqual(ConnectionReadout.clockLatchedLabel(deviceClockUnix: 40_000_000), "no (RTC reads 1970/71)")
        XCTAssertEqual(ConnectionReadout.clockLatchedLabel(deviceClockUnix: nil), "no (waiting for the strap clock)")
    }

    // #261: a WHOOP 5/MG never populates deviceClockUnix (its GET_CLOCK reply rides the puffin channel,
    // never the WHOOP4 correlation path) — the data-range fallback is what keeps the row from reading
    // "waiting" forever on a strap that's actually fine.
    func testClockLatchedLabelFallsBackToStrapNewestForFiveMG() {
        XCTAssertEqual(
            ConnectionReadout.clockLatchedLabel(deviceClockUnix: nil, strapNewestUnix: 1_782_475_600),
            "yes")
        XCTAssertEqual(
            ConnectionReadout.clockLatchedLabel(deviceClockUnix: nil, strapNewestUnix: 40_000_000),
            "no (RTC reads 1970/71)")
        XCTAssertEqual(
            ConnectionReadout.clockLatchedLabel(deviceClockUnix: nil, strapNewestUnix: nil),
            "no (waiting for the strap clock)")
        // deviceClockUnix wins when BOTH signals are present (the WHOOP4 correlation is the more direct one).
        XCTAssertEqual(
            ConnectionReadout.clockLatchedLabel(deviceClockUnix: 1_782_475_600, strapNewestUnix: 40_000_000),
            "yes")
    }

    func testRtcWarningFiresOnEpochEraClockOrNewest() {
        XCTAssertNotNil(ConnectionReadout.rtcWarning(deviceClockUnix: 40_000_000, strapNewestUnix: nil))
        XCTAssertNotNil(ConnectionReadout.rtcWarning(deviceClockUnix: nil, strapNewestUnix: 30_000_000))
        XCTAssertNil(ConnectionReadout.rtcWarning(deviceClockUnix: 1_782_475_600, strapNewestUnix: 1_782_475_000))
        XCTAssertNil(ConnectionReadout.rtcWarning(deviceClockUnix: nil, strapNewestUnix: nil),
                     "no signal seen yet must not fabricate a fault")
    }

    func testLastFrameLabel() {
        XCTAssertEqual(ConnectionReadout.lastFrameLabel(lastFrameUnix: 990, nowUnix: 1_002), "12s ago")
        XCTAssertEqual(ConnectionReadout.lastFrameLabel(lastFrameUnix: nil, nowUnix: 1_002), "no frames yet")
    }
}
