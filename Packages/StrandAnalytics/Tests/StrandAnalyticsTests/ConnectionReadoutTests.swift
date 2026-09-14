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
        // #1823: no clock was READ on this path - it is the 5/MG fallback, where the only evidence is
        // how the strap dated its records. The wording must not claim a clock reading.
        XCTAssertEqual(
            ConnectionReadout.clockLatchedLabel(deviceClockUnix: nil, strapNewestUnix: 40_000_000),
            "no (records dated 1970/71)")
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

    /// #1818: the remedy must track the battery. A charged strap told to "charge to 100%" is the bug
    /// the field report hit - the user had already done it, twice.
    func testRtcWarningRemedyTracksBattery() {
        let flat = ConnectionReadout.rtcWarning(deviceClockUnix: 40_000_000, strapNewestUnix: nil,
                                                batteryPct: 40)
        XCTAssertEqual(flat?.contains("Charge the strap to 100%"), true,
                       "a low strap keeps the charge advice - a flat battery really does reset the RTC")

        let charged = ConnectionReadout.rtcWarning(deviceClockUnix: 40_000_000, strapNewestUnix: nil,
                                                   batteryPct: 100)
        XCTAssertEqual(charged?.contains("Charge the strap to 100%"), false,
                       "an already-charged strap must not be sent round the loop it just ran")
        XCTAssertEqual(charged?.contains("already charged"), true)
        XCTAssertEqual(charged?.contains("strap log"), true, "it must name the next actionable step")
        // The charged copy must stay true for EVERY strap. "NOOP re-sends the clock on every connect"
        // holds on WHOOP4 but not on a 5/MG, where the write is gated behind didBond and an unbondable
        // strap (#1635) is never clocked at all - the strap most likely to be showing this warning.
        XCTAssertEqual(charged?.contains("every connect"), false,
                       "no model-specific mechanism claim in copy shown to every model")

        // Pin the VALUE, not just the symbol: feeding the constant back into the function under test
        // can never catch a wrong threshold, and nothing else would catch it drifting away from the
        // Kotlin twin - the two platforms would each keep passing while giving different advice.
        XCTAssertEqual(ConnectionReadout.rtcAlreadyChargedPct, 95)

        // Boundary, from both sides, with literals: inclusive at 95, charge advice at 94.
        let atThreshold = ConnectionReadout.rtcWarning(deviceClockUnix: 40_000_000,
                                                       strapNewestUnix: nil, batteryPct: 95)
        XCTAssertEqual(atThreshold?.contains("already charged"), true)
        let justBelow = ConnectionReadout.rtcWarning(deviceClockUnix: 40_000_000,
                                                     strapNewestUnix: nil, batteryPct: 94)
        XCTAssertEqual(justBelow?.contains("Charge the strap to 100%"), true)

        // Battery not read yet: we only withdraw advice on evidence, so the default stands.
        let unknown = ConnectionReadout.rtcWarning(deviceClockUnix: 40_000_000, strapNewestUnix: nil)
        XCTAssertEqual(unknown?.contains("Charge the strap to 100%"), true)

        // A sane clock stays silent no matter how full the battery is.
        XCTAssertNil(ConnectionReadout.rtcWarning(deviceClockUnix: 1_782_475_600,
                                                  strapNewestUnix: 1_782_475_000, batteryPct: 100))
    }

    /// #1809: the epitaph exists so a strap log can STATE that nothing arrived, rather than a reporter
    /// inferring it from the fact that every logged line happened to be outgoing.
    func testLinkEpitaph() {
        let silent = ConnectionReadout.linkEpitaph(upMillis: 4_123, inboundFrames: 0, inboundBytes: 0,
                                                   cmdChannelFrames: 0, realtimeArmed: false,
                                                   ended: "CBError.connectionTimeout(6)")
        XCTAssertEqual(silent,
                       "Link epitaph: up 4123ms, inbound 0 frames / 0 bytes (cmd-channel 0), "
                       + "realtime armed=no, ended=CBError.connectionTimeout(6)"
                       + " - the strap sent NOTHING on this link")

        // A link that carried traffic must NOT claim silence.
        let alive = ConnectionReadout.linkEpitaph(upMillis: 61_000, inboundFrames: 812,
                                                  inboundBytes: 40_990, cmdChannelFrames: 9,
                                                  realtimeArmed: true, ended: "intentional")
        XCTAssertEqual(alive,
                       "Link epitaph: up 61000ms, inbound 812 frames / 40990 bytes (cmd-channel 9), "
                       + "realtime armed=yes, ended=intentional")
        XCTAssertFalse(alive.contains("NOTHING"))

        // Negatives are clamped rather than printed: a monotonic-clock hiccup must not emit "up -3ms".
        XCTAssertTrue(ConnectionReadout.linkEpitaph(upMillis: -3, inboundFrames: -1, inboundBytes: -9,
                                                    cmdChannelFrames: -2, realtimeArmed: false,
                                                    ended: "x")
                        .hasPrefix("Link epitaph: up 0ms, inbound 0 frames / 0 bytes (cmd-channel 0)"))
    }

    func testLastFrameLabel() {
        XCTAssertEqual(ConnectionReadout.lastFrameLabel(lastFrameUnix: 990, nowUnix: 1_002), "12s ago")
        XCTAssertEqual(ConnectionReadout.lastFrameLabel(lastFrameUnix: nil, nowUnix: 1_002), "no frames yet")
    }
}

/// #2117: the R-R transport line, which separates "banked nothing" from "banked beats the policy refused".
final class UniversalTraceRRTransportTests: XCTestCase {

    /// A device the WHOOP 5 unit policy does not govern says nothing at all, so a WHOOP 4 export is
    /// byte-unchanged by this line existing.
    func testANonStrictDeviceEmitsNothing() {
        XCTAssertNil(UniversalTrace.rrTransportLine(strictWhoop5: false, firstRecordedUnix: 1_750_000_000,
                                                    firstScorableUnix: nil))
    }

    /// The state that blanks every night at once: beats on disk, none the policy will score. This is the
    /// one worth recognising at a glance, because it looks identical to "no data" from the analyzer's side.
    func testBeatsOnDiskButNoneScorableIsNamed() {
        let line = UniversalTrace.rrTransportLine(strictWhoop5: true, firstRecordedUnix: 1_750_000_000,
                                                  firstScorableUnix: nil)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("scorable=none"))
        XCTAssertTrue(line!.contains("unscorableHistory=yes"))
    }

    /// A strap that has never banked a beat is a DIFFERENT report from one whose beats were refused, and
    /// the line must not blur them: no "unscorableHistory" claim when there is no history to be unscorable.
    func testNoHistoryAtAllIsNotReportedAsUnscorable() {
        let line = UniversalTrace.rrTransportLine(strictWhoop5: true, firstRecordedUnix: nil,
                                                  firstScorableUnix: nil)
        XCTAssertEqual(line, "rrTransport recorded=none scorable=none")
        XCTAssertFalse(line!.contains("unscorableHistory"))
    }

    /// Partly scorable: the gap is what says how much history was refused, and it is the number that
    /// distinguishes "upgraded last week" from "lost a year".
    func testAPartlyScorableHistoryReportsTheGapInDays() {
        let line = UniversalTrace.rrTransportLine(strictWhoop5: true, firstRecordedUnix: 1_750_000_000,
                                                  firstScorableUnix: 1_750_000_000 + 30 * 86_400)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("unscorableHistory=yes"))
        XCTAssertTrue(line!.contains("gapDays=30"))
    }

    /// The WHOLE line, byte for byte, with the identical literal pinned on the Kotlin side.
    ///
    /// The other cases here assert fragments, which would let the two platforms drift on anything a
    /// `contains` does not look at: field order, spacing, or the shared date format. A report is diffed
    /// across platforms, so the line has to be the same line, not merely the same facts.
    func testTheWholeLineIsPinnedByteForByte() {
        XCTAssertEqual(
            UniversalTrace.rrTransportLine(strictWhoop5: true, firstRecordedUnix: 1_750_000_000,
                                           firstScorableUnix: 1_752_592_000),
            "rrTransport recorded=2025-06-15 15:06:40 scorable=2025-07-15 15:06:40 unscorableHistory=yes gapDays=30"
        )
    }

    /// Fully scorable from the first beat: nothing was refused, and the line must say so plainly rather
    /// than leaving a reader to infer it from a missing field.
    func testAFullyScorableHistorySaysSo() {
        let line = UniversalTrace.rrTransportLine(strictWhoop5: true, firstRecordedUnix: 1_750_000_000,
                                                  firstScorableUnix: 1_750_000_000)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("unscorableHistory=no"))
        XCTAssertTrue(line!.contains("gapDays=0"))
    }
}
