package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Connection & Sync line formatters + readout parsers (Test Centre). Pure JVM - no Robolectric, no
 * Mockito/MockK, no BLE - so fixtures pin the exact line shapes the Kotlin and Swift emitters share.
 * Twin of the Swift ConnectionTraceTests / ConnectionReadoutTests.
 */
class ConnectionTraceTest {

    @Test fun clockDriftLineHealthy() {
        val newest = 1_782_475_200L            // 2026-06-26 12:00:00 UTC
        val oldest = newest - 2 * 86_400L
        val wall = newest + 600L               // wall 10 min ahead of the newest record
        val line = ConnectionTrace.clockDriftLine(oldestUnix = oldest, newestUnix = newest, wallNowUnix = wall)
        assertTrue(line, line.startsWith("clockDrift newest=2026-06-26 12:00:00 "))
        assertTrue(line, line.contains("newestVsWall=-600s"))
        assertTrue(line, line.contains("spanDays=2"))
        assertTrue(line, line.endsWith("clockOk"))
        assertFalse(line, line.contains("FUTURE"))
    }

    @Test fun clockDriftLineFutureDated() {
        val wall = 1_782_475_200L
        val newest = wall + 3 * 86_400L        // strap thinks it banked 3 days into the future
        val line = ConnectionTrace.clockDriftLine(oldestUnix = null, newestUnix = newest, wallNowUnix = wall)
        assertTrue(line, line.contains("newestVsWall=+${3 * 86_400}s"))
        assertTrue(line, line.contains("FUTURE-DATED"))
        assertFalse(line, line.contains("oldest="))   // half range reply: no lower bound
    }

    @Test fun clockDriftLineWithinToleranceIsOk() {
        val wall = 1_782_475_200L
        val newest = wall + 60L                // 1 min ahead, inside the 120s default tolerance
        val line = ConnectionTrace.clockDriftLine(oldestUnix = null, newestUnix = newest, wallNowUnix = wall)
        assertTrue(line, line.endsWith("clockOk"))
    }

    @Test fun firmwareLine() {
        assertEquals("firmware layout=v25 decodable", ConnectionTrace.firmwareLine(25, true))
        assertEquals("firmware layout=v30 UNMAPPED (no motion/HR decoded)", ConnectionTrace.firmwareLine(30, false))
    }

    @Test fun noCursorLine() {
        assertEquals(
            "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)",
            ConnectionTrace.noCursorLine(),
        )
    }

    // #990: the -363 d drift that used to print "clockOk". Beyond the 48 h behind-tolerance the line
    // must carry a clock warning naming the day count. Twin of the Swift vector.
    @Test fun clockDriftLineFarBehindIsWarning() {
        val wall = 1_782_475_200L
        val line = ConnectionTrace.clockDriftLine(
            oldestUnix = null, newestUnix = wall - 363L * 86_400L, wallNowUnix = wall,
        )
        assertTrue(line, line.contains("CLOCK-WARNING"))
        assertTrue(line, line.contains("363d behind wall"))
        assertFalse(line, line.contains("clockOk"))
    }

    @Test fun clockDriftLineBehindWithinToleranceStaysOk() {
        val wall = 1_782_475_200L
        val line = ConnectionTrace.clockDriftLine(
            oldestUnix = null, newestUnix = wall - 47L * 3_600L, wallNowUnix = wall,
        )
        assertTrue(line, line.endsWith("clockOk"))
    }

    // #987: an epoch-era newest (never-set RTC, ~1970/71) is the named RTC-EPOCH fault, never clockOk.
    @Test fun clockDriftLineEpochEraReadsRtcEpoch() {
        val line = ConnectionTrace.clockDriftLine(
            oldestUnix = null, newestUnix = 40_000_000L, wallNowUnix = 1_782_475_200L,  // 1971-04
        )
        assertTrue(line, line.contains("RTC-EPOCH"))
        assertFalse(line, line.contains("clockOk"))
    }
}

class ConnectionReadoutTest {

    @Test fun uptimeLabelFromConnectMarker() {
        val tail = listOf("[connection] connect up gen=1 latencyMs=420 uptimeStart=1000")
        assertEquals("3m 12s", ConnectionReadout.uptimeLabel(tail, nowUnix = 1000 + 192))
    }

    @Test fun uptimeLabelDownAfterDisconnect() {
        val tail = listOf(
            "[connection] connect up gen=1 latencyMs=420 uptimeStart=1000",
            "[connection] connect down (uptime ends)",
        )
        assertEquals("not connected", ConnectionReadout.uptimeLabel(tail, nowUnix = 5000))
    }

    /**
     * #1020: the emitter appends a session duration, so the line the parser actually receives is no
     * longer the bare one above. Pinned because the two are edited independently - the suffix was added
     * on the strength of this match being a `contains`, and nothing was asserting that.
     */
    @Test fun uptimeLabelDownWithASessionDuration() {
        val tail = listOf(
            "[connection] connect up gen=1 latencyMs=420 uptimeStart=1000",
            "[connection] connect down (uptime ends after 6.8s)",
        )
        assertEquals("not connected", ConnectionReadout.uptimeLabel(tail, nowUnix = 5000))
    }

    @Test fun uptimeLabelEmptyTail() {
        assertEquals("not connected", ConnectionReadout.uptimeLabel(emptyList(), nowUnix = 5000))
    }

    @Test fun reconnectCountTakesHighest() {
        val tail = listOf(
            "[connection] reconnect n=1 reason=connectionTimeout",
            "[connection] reconnect n=2 reason=connectionTimeout",
            "[connection] reconnect n=3 failedConnect reason=peerRemovedPairing",
        )
        assertEquals(3, ConnectionReadout.reconnectCount(tail))
    }

    @Test fun reconnectCountZeroWhenNone() {
        assertEquals(0, ConnectionReadout.reconnectCount(listOf("[connection] connect up gen=1 uptimeStart=1")))
    }

    @Test fun lastOffloadResult() {
        val tail = listOf(
            "[connection] offload progress trim=100 chunkRows=5 sessionRows=5 sessionMotion=2 nights=1",
            "[connection] offload result=complete rows=42 nights=2",
        )
        assertEquals("complete rows=42 nights=2", ConnectionReadout.lastOffloadResult(tail))
    }

    @Test fun lastOffloadResultStalled() {
        // #1466: a stall is now specifically rows=0 — an idle timeout that banked rows is reported as a
        // productive end instead (below), so this fixture tracks what the producer actually emits.
        val tail = listOf("[connection] offload result=stalled (idle timeout, rows=0)")
        assertEquals("stalled (idle timeout, rows=0)", ConnectionReadout.lastOffloadResult(tail))
    }

    @Test fun lastOffloadResultIdleTimeoutAfterRows() {
        val tail = listOf("[connection] offload result=idle-timeout after rows=17205")
        assertEquals("idle-timeout after rows=17205", ConnectionReadout.lastOffloadResult(tail))
    }

    @Test fun lastOffloadResultNullWhenNone() {
        assertNull(ConnectionReadout.lastOffloadResult(listOf("[connection] connect up gen=1 uptimeStart=1")))
    }

    // #990 per-session / all-time drained rows - twins of the Swift vectors.

    @Test fun sessionRowsFromProgressLine() {
        val tail = listOf("[connection] offload progress trim=100 chunkRows=5 sessionRows=57 sessionMotion=2 nights=1")
        assertEquals(57, ConnectionReadout.sessionRows(tail))
    }

    @Test fun sessionRowsResultLineWins() {
        val tail = listOf(
            "[connection] offload progress trim=100 chunkRows=5 sessionRows=5 sessionMotion=2 nights=1",
            "[connection] offload result=complete rows=42 nights=2",
        )
        assertEquals(42, ConnectionReadout.sessionRows(tail))
    }

    @Test fun sessionRowsEmptyResultIsZeroNotStale() {
        // An "empty" result carries no rows= field: it honestly means 0, never an older running total.
        val tail = listOf(
            "[connection] offload progress trim=100 chunkRows=9 sessionRows=9 sessionMotion=2 nights=1",
            "[connection] offload result=empty (console only, no sensor records)",
        )
        assertEquals(0, ConnectionReadout.sessionRows(tail))
    }

    @Test fun sessionRowsNullWhenNoOffload() {
        assertNull(ConnectionReadout.sessionRows(listOf("[connection] connect up gen=1 uptimeStart=1")))
    }

    @Test fun drainedRowsFromSummary() {
        assertEquals(
            5_397,
            ConnectionReadout.drainedRowsFromSummary(
                "Backfill: session persisted 5397 rows (5211 with motion, 5211 skin-temp) across 2 night(s).",
            ),
        )
        assertNull(ConnectionReadout.drainedRowsFromSummary("Backfill: session ended - reason=timeout"))
        assertNull(ConnectionReadout.drainedRowsFromSummary("session persisted garbage rows"))
    }

    // #987 clock latch + last frame - twins of the Swift vectors.

    @Test fun clockCorrelatedDeviceParsesNewest() {
        val lines = listOf(
            "12:00:01  Clock correlated: device=100 wall=1782475200",
            "12:05:09  Clock correlated: device=1782475600 wall=1782475601",
        )
        assertEquals(1_782_475_600L, ConnectionReadout.clockCorrelatedDevice(lines))
        assertNull(ConnectionReadout.clockCorrelatedDevice(listOf("connect up")))
    }

    @Test fun clockLatchedLabel() {
        assertEquals("yes", ConnectionReadout.clockLatchedLabel(1_782_475_600L))
        assertEquals("no (RTC reads 1970/71)", ConnectionReadout.clockLatchedLabel(40_000_000L))
        assertEquals("no (waiting for the strap clock)", ConnectionReadout.clockLatchedLabel(null))
    }

    // #261: a WHOOP 5/MG never populates deviceClockUnix (its GET_CLOCK reply rides the puffin channel,
    // never the WHOOP4 correlation path) — the data-range fallback is what keeps the row from reading
    // "waiting" forever on a strap that's actually fine.
    @Test fun clockLatchedLabelFallsBackToStrapNewestForFiveMG() {
        assertEquals("yes", ConnectionReadout.clockLatchedLabel(null, 1_782_475_600L))
        // #1823: no clock was READ on this path - the wording must not claim one.
        assertEquals("no (records dated 1970/71)", ConnectionReadout.clockLatchedLabel(null, 40_000_000L))
        assertEquals("no (waiting for the strap clock)", ConnectionReadout.clockLatchedLabel(null, null))
        // deviceClockUnix wins when BOTH signals are present (the WHOOP4 correlation is the more direct one).
        assertEquals("yes", ConnectionReadout.clockLatchedLabel(1_782_475_600L, 40_000_000L))
    }

    @Test fun rtcWarningFiresOnEpochEraClockOrNewest() {
        assertTrue(ConnectionReadout.rtcWarning(40_000_000L, null) != null)
        assertTrue(ConnectionReadout.rtcWarning(null, 30_000_000L) != null)
        assertNull(ConnectionReadout.rtcWarning(1_782_475_600L, 1_782_475_000L))
        // No signal seen yet must not fabricate a fault.
        assertNull(ConnectionReadout.rtcWarning(null, null))
    }

    /** #1818: the remedy must track the battery. A charged strap told to "charge to 100%" is the bug
     *  the field report hit - the user had already done it, twice. Twin of the Swift test. */
    @Test fun rtcWarningRemedyTracksBattery() {
        val flat = ConnectionReadout.rtcWarning(40_000_000L, null, batteryPct = 40.0)
        assertTrue(flat!!.contains("Charge the strap to 100%"))

        val charged = ConnectionReadout.rtcWarning(40_000_000L, null, batteryPct = 100.0)!!
        assertFalse(charged.contains("Charge the strap to 100%"))
        assertTrue(charged.contains("already charged"))
        assertTrue(charged.contains("strap log"))
        // The charged copy must stay true for EVERY strap. "NOOP re-sends the clock on every connect"
        // holds on WHOOP4 but not on a 5/MG, where the write is gated behind didBond and an unbondable
        // strap (#1635) is never clocked at all - the strap most likely to be showing this warning.
        assertFalse(charged.contains("every connect"))

        // Pin the VALUE, not just the symbol: feeding the constant back into the function under test
        // can never catch a wrong threshold, and nothing else would catch it drifting away from the
        // Swift twin - the two platforms would each keep passing while giving different advice.
        assertEquals(95.0, ConnectionReadout.RTC_ALREADY_CHARGED_PCT, 0.0)

        // Boundary, from both sides, with literals: inclusive at 95, charge advice at 94.
        val atThreshold = ConnectionReadout.rtcWarning(40_000_000L, null, batteryPct = 95.0)!!
        assertTrue(atThreshold.contains("already charged"))
        val justBelow = ConnectionReadout.rtcWarning(40_000_000L, null, batteryPct = 94.0)!!
        assertTrue(justBelow.contains("Charge the strap to 100%"))

        // Battery not read yet: we only withdraw advice on evidence, so the default stands.
        assertTrue(ConnectionReadout.rtcWarning(40_000_000L, null)!!.contains("Charge the strap to 100%"))

        // A sane clock stays silent no matter how full the battery is.
        assertNull(ConnectionReadout.rtcWarning(1_782_475_600L, 1_782_475_000L, batteryPct = 100.0))
    }

    /** #1809: the epitaph exists so a strap log can STATE that nothing arrived, rather than a reporter
     *  inferring it from the fact that every logged line happened to be outgoing. Twin of the Swift test -
     *  the two strings must match byte for byte or one platform's report reads differently. */
    @Test fun linkEpitaph() {
        val silent = ConnectionReadout.linkEpitaph(
            upMillis = 4_123L, inboundFrames = 0, inboundBytes = 0, cmdChannelFrames = 0,
            realtimeArmed = false, ended = "CBError.connectionTimeout(6)",
        )
        assertEquals(
            "Link epitaph: up 4123ms, inbound 0 frames / 0 bytes (cmd-channel 0), " +
                "realtime armed=no, ended=CBError.connectionTimeout(6)" +
                " - the strap sent NOTHING on this link",
            silent,
        )

        // A link that carried traffic must NOT claim silence.
        val alive = ConnectionReadout.linkEpitaph(
            upMillis = 61_000L, inboundFrames = 812, inboundBytes = 40_990, cmdChannelFrames = 9,
            realtimeArmed = true, ended = "intentional",
        )
        assertEquals(
            "Link epitaph: up 61000ms, inbound 812 frames / 40990 bytes (cmd-channel 9), " +
                "realtime armed=yes, ended=intentional",
            alive,
        )
        assertFalse(alive.contains("NOTHING"))

        // Negatives are clamped rather than printed: a clock hiccup must not emit "up -3ms".
        assertTrue(
            ConnectionReadout.linkEpitaph(-3L, -1, -9, -2, false, "x")
                .startsWith("Link epitaph: up 0ms, inbound 0 frames / 0 bytes (cmd-channel 0)"),
        )
    }

    @Test fun lastFrameLabel() {
        assertEquals("12s ago", ConnectionReadout.lastFrameLabel(990L, nowUnix = 1_002L))
        assertEquals("no frames yet", ConnectionReadout.lastFrameLabel(null, nowUnix = 1_002L))
    }
}
