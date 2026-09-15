package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Framing tests: outer command/response frames, the 0x2F secure-session sub-frame, and the TLV
 * inner-record parse — open_oura's ONE-packet-per-notification model (lenient `len`, no buffering,
 * no multi-record loop, no byte-drop resync). Kotlin twin of the Swift FramingTests.swift.
 *
 * PARITY NOTE: every fixture hex string here is byte-for-byte identical to the Swift FramingTests
 * fixtures, so the same wire bytes parse + reassemble to the same records across both ports.
 */
class FramingTest {
    private fun bytes(s: String) = OuraTestHex.bytes(s)
    private fun hex(b: IntArray) = OuraTestHex.hex(b)

    // MARK: - Outer frame

    @Test
    fun testParseOuterFrame() {
        // 0d 06 <6 body bytes> (a battery response shape).
        val f = OuraFraming.parseOuterFrame(bytes("0d06570000003c0f"))
        assertEquals(0x0D, f?.op)
        assertArrayEquals(bytes("570000003c0f"), f?.body)
        assertEquals(8, f?.totalLength)
    }

    @Test
    fun testParseOuterFrameShortReturnsNil() {
        // Declares 6 body bytes but only 2 present -> null (wait for more).
        assertNull(OuraFraming.parseOuterFrame(bytes("0d065700")))
    }

    @Test
    fun testMultipleOuterFramesInOneValue() {
        // 25 01 00  (SetAuthKey resp)  then  1d 01 00 (SetNotification resp).
        val frames = OuraFraming.parseOuterFrames(bytes("2501001d0100"))
        assertEquals(2, frames.size)
        assertEquals(0x25, frames[0].op)
        assertArrayEquals(intArrayOf(0x00), frames[0].body)
        assertEquals(0x1D, frames[1].op)
        assertArrayEquals(intArrayOf(0x00), frames[1].body)
    }

    // MARK: - GetBattery response (0x0D, s6.10)

    @Test
    fun testBatteryResponseOpIsRecognisedAsAnOuterFrame() {
        // 0d 06 <percent=57=87> <charging=00> <flag=00> <3 unknown> - the live path routes this op to the
        // battery decoder, never to the TLV record decoder (op 0x0D is below the event-tag range).
        val frames = OuraFraming.parseOuterFrames(bytes("0d06570000003c0f"))
        assertEquals(1, frames.size)
        assertEquals(OuraFraming.batteryResponseOp, frames[0].op)
        val battery = OuraDecoders.decodeBattery(frames[0].body)
        assertEquals(0x57, battery?.percent)   // 87%
    }

    // MARK: - GetEvents response (0x11, s5.2 — open_oura EventBatchSummary, #91 twin)

    @Test
    fun testParseGetEventsResponseMoreDataFollows() {
        // 11 08 <events=ff> <progress=00> <bytes_left:4LE=0x00145d39> <pad:2> (a real on-device body).
        val outer = OuraFraming.parseOuterFrame(bytes("1108ff00395d14000300"))
        assertEquals(OuraFraming.getEventsResponseOp, outer?.op)
        val summary = OuraFraming.parseGetEventsResponse(outer!!.body)
        assertEquals(0xFF, summary?.eventsReceived)
        assertEquals(0x0014_5D39L, summary?.bytesLeft)
        assertEquals(true, summary?.moreData)
    }

    @Test
    fun testParseGetEventsResponseBytesLeftZeroIsDone() {
        // bytes_left == 0 -> drain complete, even with a nonzero events count in body[0] (#91: body[0]
        // is a batch COUNT, not a status; bytes 2-5 are bytes_left, never a cursor).
        val outer = OuraFraming.parseOuterFrame(bytes("11081000000000000300"))
        val summary = OuraFraming.parseGetEventsResponse(outer!!.body)
        assertEquals(0x10, summary?.eventsReceived)
        assertEquals(0L, summary?.bytesLeft)
        assertEquals(false, summary?.moreData)
    }

    @Test
    fun testParseGetEventsResponseShortBodyReturnsNil() {
        assertNull(OuraFraming.parseGetEventsResponse(bytes("ff0012")))
    }

    // MARK: - SyncTime response (0x13, s5.4 [ringverse]) + anchor tick disambiguation

    @Test
    fun testParseSyncTimeResponse() {
        // ringverse example body: 4b ed a9 00 00 -> device_ts 0x00A9ED4B, status 0.
        val resp = OuraFraming.parseSyncTimeResponse(bytes("4beda90000"))
        assertEquals(0x00A9_ED4BL, resp?.deviceTimestamp)
        assertEquals(0, resp?.status)
        // Short body -> null, never a guessed timestamp.
        assertNull(OuraFraming.parseSyncTimeResponse(bytes("4beda900")))
    }

    /**
     * Parity oracle for [OuraDriver.syncTimeAnchorCandidate] (2026-09-02/03 captures). Expected values are the VERBATIM
     * stdout of the shipped Swift twin compiled standalone (`swiftc -O twin.swift main.swift`), one
     * `responseValue / lowerBoundTicks / result` row per line — not values read off the Kotlin. The
     * spread covers the shipped unit cases, the 2026-09-02/03 capture values behind this fix, both halves
     * of the cursor↔anchor deadlock, the exact window edges, the ambiguity band around the 9× boundary,
     * and the UInt32 ceiling. Guards the Kotlin direction only; the Swift test in FramingTests.swift is
     * what stops Swift drifting.
     */
    @Test
    fun testSyncTimeAnchorCandidateMatchesTheSwiftOracle() {
        // responseValue, lowerBoundTicks, expected (null = no unambiguous reading)
        val oracle: List<Triple<Long, Long, Long?>> = listOf(
            Triple(4_810_000L, 4_413_933L, 4_810_000L),
            Triple(481_000L, 4_413_933L, 4_810_000L),
            Triple(100_000L, 4_413_933L, null),
            Triple(50_000_000L, 4_413_933L, null),
            Triple(4_810_000L, 0L, null),
            Triple(150_000L, 140_000L, null),
            Triple(35_157_631L, 28_073_725L, 35_157_631L),
            Triple(35_159_272L, 28_073_725L, 35_159_272L),
            Triple(35_168_206L, 28_073_725L, 35_168_206L),
            Triple(34_724_816L, 0L, null),
            Triple(34_749_048L, 0L, null),
            Triple(34_776_653L, 0L, null),
            Triple(34_724_816L, 22_628_816L, 34_724_816L),
            Triple(34_749_048L, 22_628_816L, 34_749_048L),
            Triple(34_776_653L, 22_628_816L, 34_776_653L),
            Triple(28_073_725L, 28_073_725L, 28_073_725L),
            Triple(66_953_725L, 28_073_725L, 66_953_725L),
            Triple(66_953_726L, 28_073_725L, null),
            Triple(28_073_724L, 28_073_725L, null),
            Triple(500_000L, 400_000L, null),
            Triple(4_320_000L, 4_320_000L, null),
            Triple(4_320_001L, 4_320_001L, 4_320_001L),
            Triple(4_294_967_295L, 4_294_000_000L, 4_294_967_295L),
            Triple(500_000_000L, 100_000_000L, null),
        )
        for ((value, lowerBound, expected) in oracle) {
            assertEquals(
                "syncTimeAnchorCandidate($value, $lowerBound)",
                expected,
                OuraDriver.syncTimeAnchorCandidate(value, lowerBound),
            )
        }
    }

    /**
     * Stated as the behaviour rather than the table: the 2026-09-03 capture's 0x13 reply
     * (0x0218767f = 35_157_631) against the frozen resume cursor 28_073_725, which trails it by 8.20
     * days. Under the old 7-day window neither reading fit, so no anchor was adopted; with no anchor the
     * drain-end commit could not advance the cursor, so the cursor stayed stale and the gap only grew —
     * a permanent loop, one full re-serve of the same window per launch.
     */
    @Test
    fun testSyncTimeAnchorCandidateAcceptsAStaleCursor() {
        val staleCursor = 28_073_725L
        assertEquals(35_157_631L, OuraDriver.syncTimeAnchorCandidate(0x0218767fL, staleCursor))
        // The old 7-day window is what excluded it: 28_073_725 + 6_048_000 = 34_121_725 < 35_157_631.
        assertTrue(
            "the window must cover the observed 8.2-day staleness",
            OuraDriver.SYNC_TIME_ANCHOR_WINDOW_TICKS > 35_157_631L - staleCursor,
        )
    }

    /**
     * The other half of the deadlock: on a fresh pair / post-reboot reset the cursor is 0, so it
     * can never be the reference. The drain's maxSeenRingTime can — it counts EVERY history record's
     * envelope time and needs no anchor to read — so the caller retries the parked reply against it.
     */
    @Test
    fun testSyncTimeAnchorCandidateResolvesAgainstSeenRingTimeWhenCursorIsZero() {
        val reply = 0x0211dbd0L                 // 34_724_816 — the 2026-09-02 capture, cursor 0
        assertNull(OuraDriver.syncTimeAnchorCandidate(reply, 0L))
        // First batch of a full pull lands the ring's OLDEST banked record (~14 days back).
        assertEquals(reply, OuraDriver.syncTimeAnchorCandidate(reply, 34_724_816L - 12_096_000L))
    }

    @Test
    fun testAdoptSyncTimeAnchorResolvesHistoryTimes() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        val now = 1_784_000_000L                     // inside the 2020-2035 plausibility window
        assertNull("no anchor yet", d.unixSeconds(forRingTimestamp = 4_800_000L))
        assertTrue(d.adoptSyncTimeAnchor(ringTimestamp = 4_810_000L, unixSeconds = now))
        // A record 10_000 ticks (1000 s) before the anchor resolves to now - 1000.
        assertEquals(now - 1000L, d.unixSeconds(forRingTimestamp = 4_800_000L))
        // An implausible host epoch is refused (never anchors to a garbage clock).
        assertFalse(d.adoptSyncTimeAnchor(ringTimestamp = 4_810_000L, unixSeconds = 100L))
    }

    // MARK: - Secure-session sub-frame (0x2F)

    @Test
    fun testSecureFrameNonceResponse() {
        // Wire: 2f 10 2c <nonce:15>. Outer: op 0x2F, len 0x10 (16), body = 2c + 15 nonce bytes.
        val wire = bytes("2f102c0102030405060708090a0b0c0d0e0f")
        val outer = OuraFraming.parseOuterFrame(wire)!!
        assertEquals(0x2F, outer.op)
        val secure = OuraFraming.parseSecureFrame(outer)!!
        assertEquals(0x2C, secure.subop)
        assertArrayEquals(bytes("0102030405060708090a0b0c0d0e0f"), secure.subBody)
        // And the auth layer pulls the 15-byte nonce straight out.
        assertArrayEquals(bytes("0102030405060708090a0b0c0d0e0f"), OuraAuth.nonce(secure))
    }

    @Test
    fun testSecureFrameAuthStatus() {
        // 2f 02 2e 00 -> success.
        val wire = bytes("2f022e00")
        val outer = OuraFraming.parseOuterFrame(wire)!!
        val secure = OuraFraming.parseSecureFrame(outer)!!
        assertEquals(0x2E, secure.subop)
        assertEquals(OuraAuthStatus.SUCCESS, OuraAuth.authStatus(secure))
    }

    @Test
    fun testNonSecureFrameReturnsNilSecure() {
        val outer = OuraOuterFrame(op = 0x0D, body = intArrayOf(0x01))
        assertNull(OuraFraming.parseSecureFrame(outer))
    }

    // MARK: - TLV record parsing

    @Test
    fun testParseTLVRecord() {
        // 7b 06 <rt:4 LE 02000100> 03 ca  -> type 0x7B, rt 0x00010002, payload 03 ca.
        val rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))
        assertEquals(0x7B, rec?.type)
        assertEquals(0x0001_0002L, rec?.ringTimestamp)
        assertEquals(0x0002, rec?.counter)
        assertEquals(0x0001, rec?.session)
        assertArrayEquals(bytes("03ca"), rec?.payload)
        assertEquals(8, rec?.totalLength)
    }

    @Test
    fun testTLVLenBelowFourIsRejected() {
        // len must be >= 4 to cover the 4 timestamp bytes; len=3 -> null (honest, no guess).
        assertNull(OuraFraming.parseRecord(intArrayOf(0x7B, 0x03, 0x00, 0x01, 0x02)))
    }

    // MARK: - Lenient TLV parse + one-packet-per-notification reassembler (open_oura Packet::parse,
    // twin of Swift dae3d7a4 — the phantom-storm fix)

    @Test
    fun testParseRecordTooBigLenUsesWhatArrived() {
        // len 0x10 (16) declared but only 4 payload bytes present: the lenient parse uses what
        // arrived instead of waiting for (and swallowing) the next notification.
        val rec = OuraFraming.parseRecord(bytes("7b100200010003ca0102"))
        assertEquals(0x7B, rec?.type)
        assertArrayEquals(bytes("03ca0102"), rec?.payload)
    }

    @Test
    fun testParseRecordTrailingBytesBeyondLenAreIgnored() {
        // len 0x06 but extra trailing bytes follow (BLE padding / an unpacked second frame): the
        // payload stops at the declared end; the tail is never minted into a phantom record.
        val rec = OuraFraming.parseRecord(bytes("7b060200010003ca" + "4e0602000100006c"))
        assertEquals(0x7B, rec?.type)
        assertArrayEquals(bytes("03ca"), rec?.payload)
    }

    @Test
    fun testFeedWalksANotificationThatTilesExactlyIntoSeveralPackets() {
        // Two complete packets whose declared lengths land exactly on each other and on the value's
        // last byte are BOTH returned (the ring packs like this when serving the official app,
        // 2026-09-15). Expected literals = the Swift standalone twin's output over the same bytes.
        val r = OuraReassembler()
        val recs = r.feed(bytes("7b060200010003ca" + "4e0602000100006c"))
        assertEquals(listOf(0x7B, 0x4E), recs.map { it.type })
        assertEquals(listOf(65538L, 65538L), recs.map { it.ringTimestamp })
        assertEquals(listOf("03ca", "006c"), recs.map { hex(it.payload) })
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testFeedFallsBackToOneLenientPacketWhenTheTailDoesNotTile() {
        // Three trailing bytes that do not form a packet: the tiling fails, so the value is read as
        // ONE lenient packet (the pre-packed behaviour) — the tail is neither walked nor buffered.
        val r = OuraReassembler()
        val recs = r.feed(bytes("7b060200010003ca" + "4e0602"))
        assertEquals(1, recs.size)
        assertEquals(0x7B, recs[0].type)
        assertEquals("03ca", hex(recs[0].payload))
    }

    @Test
    fun testFeedKeepsALonePacketWhoseLenDisagreesWithTheNotification() {
        // A 20-byte value whose `len` says 10: the lenient single read clamps the payload and the
        // remaining bytes (`d5 55 ...`) do not tile, so nothing is minted from them.
        val r = OuraReassembler()
        val recs = r.feed(bytes("5a0a1dbdb40200fffffff7d7d555555555543fff"))
        assertEquals(1, recs.size)
        assertEquals(45399325L, recs[0].ringTimestamp)
        assertEquals("00fffffff7d7", hex(recs[0].payload))
    }

    @Test
    fun testFeedOnRealPackedNotificationsFromTheRing() {
        // Two notifications captured verbatim from a Gen 3 ring on 2026-09-15 07:39:25 while it served
        // the official app's history request. Expected = the Swift twin's stdout, pasted verbatim.
        val r = OuraReassembler()
        val a = r.feed(bytes(
            "5a1209e7b30206f00000005555555555555555405a120ae7b302070000014555555555555545f0ff5a120be7b30208" +
            "fffffffffffffffffffff7f555580b0ce7b302185f1033563c645a120de7b302095555555555555555555555557f4f" +
            "0f0ee7b302772514020d0100008000004c120fe7b30201001f00d9007f0047013b3405146e1118e7b3028a7c7b797b" +
            "7a7a947c919051616e1127e7b30204797a7d797b80d0dfe7a7bdca60122ee7b3027a7c797a8180bbb96572889d1761"))
        assertEquals(listOf(
            "5a rt=45344521 payload=06f0000000555555555555555540",
            "5a rt=45344522 payload=070000014555555555555545f0ff",
            "5a rt=45344523 payload=08fffffffffffffffffffff7f555",
            "58 rt=45344524 payload=185f1033563c64",
            "5a rt=45344525 payload=095555555555555555555555557f",
            "4f rt=45344526 payload=772514020d010000800000",
            "4c rt=45344527 payload=01001f00d9007f0047013b340514",
            "6e rt=45344536 payload=8a7c7b797b7a7a947c91905161",
            "6e rt=45344551 payload=04797a7d797b80d0dfe7a7bdca",
            "60 rt=45344558 payload=7a7c797a8180bbb96572889d1761",
        ), a.map { "%02x rt=%d payload=%s".format(it.type, it.ringTimestamp, hex(it.payload)) })
        val b = r.feed(bytes(
            "751231e7b3028d0d8d0d8d0d8d0d8d0d870d870d461232e7b302870dfc0c4c0b640d7a0d8d0d7d0d690633e7b302ed0d" +
            "6f123ce7b3024d66666666666666676767676768771243e7b302beff03fef6fe0100020d0e06ff016e1152e7b30280" +
            "80807c7c7e2f5e795c879a00771260e7b3023afc020805040a09fcf5fcfdfd036e1161e7b3020a807d7b7e7d76e1d0" +
            "e5dfd4b0601267e7b3027d7b7e7d777996b4cdb38d92886161107ae7b3021a1800288a0000ac3f0000cb"))
        assertEquals(listOf(
            "75 rt=45344561 payload=8d0d8d0d8d0d8d0d8d0d870d870d",
            "46 rt=45344562 payload=870dfc0c4c0b640d7a0d8d0d7d0d",
            "69 rt=45344563 payload=ed0d",
            "6f rt=45344572 payload=4d66666666666666676767676768",
            "77 rt=45344579 payload=beff03fef6fe0100020d0e06ff01",
            "6e rt=45344594 payload=8080807c7c7e2f5e795c879a00",
            "77 rt=45344608 payload=3afc020805040a09fcf5fcfdfd03",
            "6e rt=45344609 payload=0a807d7b7e7d76e1d0e5dfd4b0",
            "60 rt=45344615 payload=7d7b7e7d777996b4cdb38d928861",
            "61 rt=45344634 payload=1a1800288a0000ac3f0000cb",
        ), b.map { "%02x rt=%d payload=%s".format(it.type, it.ringTimestamp, hex(it.payload)) })
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testFeedOnAnOrdinarySinglePacketNotificationIsUnchanged() {
        // A 20-byte one-packet value from a NOOP drain (2026-09-15 04:20): one record, whole payload.
        val r = OuraReassembler()
        val recs = r.feed(bytes("5a121dbdb40200fffffff7d7d555555555543fff"))
        assertEquals(1, recs.size)
        assertEquals(45399325L, recs[0].ringTimestamp)
        assertEquals("00fffffff7d7d555555555543fff", hex(recs[0].payload))
    }

    @Test
    fun testFeedNeverBuffersAcrossNotifications() {
        // A truncated notification is dropped whole (nothing buffered), and the next notification is
        // parsed on its own — no cross-notification reassembly, so a garbled value can never corrupt
        // the following one (the phantom-storm failure mode).
        val full = bytes("7b060200010003ca")
        val r = OuraReassembler()
        assertTrue(r.feed(full.copyOfRange(0, 5)).isEmpty())
        assertEquals(0, r.bufferedByteCount)
        val recs = r.feed(full)
        assertEquals(1, recs.size)
        assertEquals(0x7B, recs[0].type)
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testFeedDropsUnusableNotificationWholeNoResync() {
        // A noise value (len < 4 / too short) yields nothing — never walked byte-by-byte for a
        // resync, never a type-0 garbage record.
        val r = OuraReassembler()
        assertTrue(r.feed(intArrayOf(0x00, 0x01, 0x02, 0x03, 0x01, 0x02)).isEmpty())
        assertTrue(r.feed(intArrayOf(0x00, 0x01) + bytes("4e0602000100006c")).isEmpty())
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testResetIsANoOpWithNoBufferedState() {
        val r = OuraReassembler()
        assertTrue(r.feed(intArrayOf(0x7B, 0x06, 0x02)).isEmpty())   // below floor, nothing retained
        assertEquals(0, r.bufferedByteCount)
        r.reset()
        assertEquals(0, r.bufferedByteCount)
    }
}
