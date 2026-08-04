package com.noop.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Frame round-trip + decode tests against concrete byte vectors.
 *
 * All vectors were generated independently (Python: zlib CRC-32, table CRC-8, CRC16-Modbus) from
 * the same envelope spec the Kotlin code implements, so a passing test confirms cross-checked
 * agreement rather than the code merely agreeing with itself.
 */
class FramingTest {

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private fun bytes(vararg ints: Int): ByteArray = ByteArray(ints.size) { ints[it].toByte() }

    // MARK: - buildCommand round-trips

    @Test
    fun buildCommand_getBatteryLevel_exactBytes() {
        // GET_BATTERY_LEVEL(26), payload [0], seq 0.
        val frame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        assertEquals("aa0800a823001a001725ee23", hex(frame))
    }

    @Test
    fun buildCommand_toggleRealtimeHr_exactBytes() {
        // TOGGLE_REALTIME_HR(3), payload [1], seq 7.
        val frame = Framing.buildCommand(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1), seq = 7)
        assertEquals("aa0800a8230703011caaa6ca", hex(frame))
    }

    @Test
    fun buildCommand_oneShotBuzzSequence_exactBytes() {
        // #921 one-shot buzz (WhoopBleClient.buzzStrapOnce, twin of Swift buzzStrapOnce): the
        // on-device-confirmed WHOOP 4.0 sequence is RUN_HAPTICS_PATTERN(79) [patternId=2, loops=3,
        // 0, 0, 0] immediately followed by RUN_ALARM(68) [0x01], on consecutive seq bytes. Golden
        // hexes generated independently (Python: zlib CRC-32, table CRC-8) so a drift in either
        // frame, payload, or command number fails here. On a 5/MG the pattern write is remapped to
        // the maverick 0x13 frame pinned in puffinCommandFrame_hapticsMatchesMaverickGolden, and
        // RUN_ALARM is deliberately NOT sent (the Android 5/MG allow-list excludes it).
        val haptics = Framing.buildCommand(
            CommandNumber.RUN_HAPTICS_PATTERN, byteArrayOf(2, 3, 0, 0, 0), seq = 1,
        )
        assertEquals("aa0c00fc23014f02030000005ff5d722", hex(haptics))
        val runAlarm = Framing.buildCommand(CommandNumber.RUN_ALARM, byteArrayOf(0x01), seq = 2)
        assertEquals("aa0800a82302440135b15573", hex(runAlarm))
        // The payload bytes themselves, pinned once more without the envelope: patternId=2, 3 loops.
        assertArrayEquals(byteArrayOf(2, 3, 0, 0, 0), haptics.copyOfRange(7, 12))
        assertEquals(CommandNumber.RUN_ALARM.rawValue, runAlarm[6].toInt() and 0xFF)
    }

    @Test
    fun buildCommand_envelopeShapeIsCorrect() {
        val frame = Framing.buildCommand(CommandNumber.GET_CLOCK, byteArrayOf(0), seq = 0)
        assertEquals(0xAA.toByte(), frame[0])                 // SOF
        val length = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
        assertEquals(frame.size, length + 4)                  // total = length + 4
        assertEquals(PacketType.COMMAND.rawValue, frame[4].toInt() and 0xFF)   // type 35
        assertEquals(0, frame[5].toInt() and 0xFF)            // seq
        assertEquals(CommandNumber.GET_CLOCK.rawValue, frame[6].toInt() and 0xFF) // cmd
    }

    @Test
    fun buildCommand_parsesBackAsValidCommandResponseSibling() {
        // Building a COMMAND frame and re-validating its CRCs proves the envelope is self-consistent:
        // crc8(length) and crc32(inner) both verify when parsed by a generic Whoop4 validation.
        val frame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        // Manually re-check CRC8 over the two length bytes.
        val wantCrc8 = Crc.crc8(byteArrayOf(frame[1], frame[2]))
        assertEquals(wantCrc8, frame[3].toInt() and 0xFF)
        // Manually re-check CRC32 over the inner record frame[4 until length].
        val length = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
        val inner = frame.copyOfRange(4, length)
        val wantCrc32 = Crc.crc32(inner)
        val gotCrc32 = (frame[length].toLong() and 0xFFL) or
            ((frame[length + 1].toLong() and 0xFFL) shl 8) or
            ((frame[length + 2].toLong() and 0xFFL) shl 16) or
            ((frame[length + 3].toLong() and 0xFFL) shl 24)
        assertEquals(wantCrc32, gotCrc32)
    }

    // MARK: - puffinCommandFrame (EXPERIMENTAL WHOOP 5.0/MG)

    @Test
    fun puffinCommandFrame_roundTripsThroughWhoop5Parse() {
        // EXPERIMENTAL: a puffin TOGGLE_REALTIME_HR(3) probe, payload [1], seq 7. The CRC16 header +
        // CRC32 payload must both verify when parsed as a WHOOP5 frame (parseWhoop5 reports crcOk).
        val frame = Framing.puffinCommandFrame(
            cmd = CommandNumber.TOGGLE_REALTIME_HR.rawValue,
            seq = 7,
            payload = byteArrayOf(1),
        )
        val r = Framing.parseFrame(frame, DeviceFamily.WHOOP5)
        assertTrue(r.ok)
        assertEquals(true, r.crcOk)
        // Inner record starts at offset 8: [type=35][seq=7][cmd=3][payload=1].
        assertEquals(PacketType.COMMAND.rawValue, frame[8].toInt() and 0xFF)
        assertEquals(7, frame[9].toInt() and 0xFF)
        assertEquals(CommandNumber.TOGGLE_REALTIME_HR.rawValue, frame[10].toInt() and 0xFF)
        assertEquals(1, frame[11].toInt() and 0xFF)
    }

    @Test
    fun puffinCommandFrame_envelopeShapeAndCrcsAreSelfConsistent() {
        val frame = Framing.puffinCommandFrame(
            cmd = CommandNumber.TOGGLE_REALTIME_HR.rawValue,
            seq = 1,
            payload = byteArrayOf(1),
        )
        // SOF 0xAA, format byte 0x01.
        assertEquals(0xAA.toByte(), frame[0])
        assertEquals(0x01.toByte(), frame[1])
        // declaredLength = inner(3+1=4) + 4 = 8; total frame = declaredLength + 8.
        val declLen = (frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)
        assertEquals(8, declLen)
        assertEquals(declLen + 8, frame.size)
        // CRC16-Modbus over frame[0..6) is stored LE at frame[6..8).
        val wantHeader = Crc.crc16Modbus(frame.copyOfRange(0, 6))
        val gotHeader = (frame[6].toInt() and 0xFF) or ((frame[7].toInt() and 0xFF) shl 8)
        assertEquals(wantHeader, gotHeader)
        // CRC32 over the inner record frame[8 until total-4) is stored LE in the last 4 bytes.
        val payloadEnd = frame.size - 4
        val inner = frame.copyOfRange(8, payloadEnd)
        val wantCrc32 = Crc.crc32(inner)
        val gotCrc32 = (frame[payloadEnd].toLong() and 0xFFL) or
            ((frame[payloadEnd + 1].toLong() and 0xFFL) shl 8) or
            ((frame[payloadEnd + 2].toLong() and 0xFFL) shl 16) or
            ((frame[payloadEnd + 3].toLong() and 0xFFL) shl 24)
        assertEquals(wantCrc32, gotCrc32)
    }

    @Test
    fun puffinCommandFrame_hapticsMatchesMaverickGolden() {
        // WHOOP 5/MG buzz (#48): haptic inner is 15 bytes ([35, seq, 0x13] + 12-byte payload), which
        // pad4 must extend to 16 before length/CRC — like the strap's maverick framing. Golden frame
        // from the working app's buildMaverickFrame (notify preset, effects 47,152) at seq=1; exact
        // equality proves the opcode (0x13), payload, AND pad4 are all correct, byte-for-byte.
        val payload = byteArrayOf(0x01, 47, 152.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0) // 0x01+effects(8)+loopCtl(2)+overall
        assertEquals(12, payload.size)
        val frame = Framing.puffinCommandFrame(cmd = 0x13, seq = 1, payload = payload)
        assertEquals("aa0114000001e1e1230113012f980000000000000000000098cb83a5", hex(frame))
        assertEquals(28, frame.size) // 8 header + 16 padded inner + 4 crc32
        assertTrue(Framing.parseFrame(frame, DeviceFamily.WHOOP5).ok)
        // pad4 is a NO-OP for already-4-aligned commands: HR toggle inner ([35,seq,3,1]) stays 16 bytes.
        assertEquals(16, Framing.puffinCommandFrame(cmd = CommandNumber.TOGGLE_REALTIME_HR.rawValue, seq = 7, payload = byteArrayOf(1)).size)
    }

    @Test
    fun puffinCommandFrame_alarmFramesMatchSwiftParityGoldens() {
        // Cross-platform parity pins: the macOS port (DeviceFamilyFramingTests) asserts these SAME
        // three full-frame hexes, so both platforms are locked to identical alarm bytes. The
        // SET_ALARM_TIME inner is 23 bytes → pad4 → 24 (declLen 28); the rev-2 bodies pad 5 → 8.
        // (RUN_ALARM rev2 [0x02, alarmId] is built inline — the Kotlin client no longer ships a
        // helper for it, but the Mac test-buzz path still sends it, so the bytes stay pinned here.)
        val alarm = Framing.puffinCommandFrame(cmd = 66, seq = 1, payload = AlarmPayload.build(1_700_000_000_123L))
        assertEquals("aa011c000001e381230142040100f15365be0f2f980000000000000000071e00392f2ac9", hex(alarm))
        assertEquals("aa010c000001e74123014502ff000000267ffc4f",
            hex(Framing.puffinCommandFrame(cmd = 69, seq = 1, payload = AlarmPayload.disableRev2())))
        assertEquals("aa010c000001e741230144020100000017cd19e2",
            hex(Framing.puffinCommandFrame(cmd = 68, seq = 1, payload = byteArrayOf(0x02, 0x01))))
    }

    // MARK: - parseFrame decode vectors

    @Test
    fun parse_realtimeData_heartRateAndRr() {
        // type40 seq0, ts=1700000000, hr=62, rr=[850,870].
        val frame = bytes(
            0xaa, 0x12, 0x00, 0x7d, 0x28, 0x00, 0x00, 0xf1, 0x53, 0x65, 0x00, 0x00,
            0x3e, 0x02, 0x52, 0x03, 0x66, 0x03, 0x73, 0x8f, 0x40, 0xae,
        )
        val r = Framing.parseFrame(frame)
        assertTrue(r.ok)
        assertEquals(true, r.crcOk)
        assertEquals("REALTIME_DATA", r.typeName)
        assertEquals(1700000000, r.parsed["timestamp"])
        assertEquals(62, r.parsed["heart_rate"])
        assertEquals(listOf(850, 870), r.parsed["rr_intervals"])
    }

    @Test
    fun parse_eventBatteryLevel_socMvCharging() {
        // EVENT BATTERY_LEVEL(3): ev_ts=1700000050, soc_raw=875(->87.5), mv=4012, charge=1.
        val frame = bytes(
            0xaa, 0x1b, 0x00, 0xc0, 0x30, 0x00, 0x03, 0x00, 0x32, 0xf1, 0x53, 0x65,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x6b, 0x03, 0x00, 0x00, 0xac, 0x0f, 0x00,
            0x00, 0x00, 0x01, 0xb8, 0xe1, 0x9c, 0x12,
        )
        val r = Framing.parseFrame(frame)
        assertTrue(r.ok)
        assertEquals(true, r.crcOk)
        assertEquals("EVENT", r.typeName)
        assertEquals("BATTERY_LEVEL(3)", r.parsed["event"])
        assertEquals(1700000050, r.parsed["event_timestamp"])
        assertEquals(87.5, r.parsed["battery_pct"] as Double, 1e-9)
        assertEquals(4012, r.parsed["battery_mV"])
        assertEquals(1, r.parsed["battery_charging"])
    }

    @Test
    fun parse_eventBatteryLevel_notCharging() {
        // Same synthetic BATTERY_LEVEL vector with the charge byte @26 = 0 (and the CRC32 trailer
        // recomputed over the same type..payload region). Pins the decoder's bit in BOTH states so
        // a charging consumer can trust 0 as "not charging", not "field missing".
        val frame = bytes(
            0xaa, 0x1b, 0x00, 0xc0, 0x30, 0x00, 0x03, 0x00, 0x32, 0xf1, 0x53, 0x65,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x6b, 0x03, 0x00, 0x00, 0xac, 0x0f, 0x00,
            0x00, 0x00, 0x00, 0x2e, 0xd1, 0x9b, 0x65,
        )
        val r = Framing.parseFrame(frame)
        assertTrue(r.ok)
        assertEquals(true, r.crcOk)
        assertEquals("BATTERY_LEVEL(3)", r.parsed["event"])
        assertEquals(0, r.parsed["battery_charging"])
    }

    @Test
    fun parse_metadata_historyEnd() {
        // METADATA HISTORY_END(2): unix=1699999999, trim=123456.
        val frame = bytes(
            0xaa, 0x15, 0x00, 0x16, 0x31, 0x00, 0x02, 0xff, 0xf0, 0x53, 0x65, 0x05,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0xe2, 0x01, 0x00, 0x5a, 0x85, 0x0d, 0x5e,
        )
        val r = Framing.parseFrame(frame)
        assertTrue(r.ok)
        assertEquals(true, r.crcOk)
        assertEquals("METADATA", r.typeName)
        assertEquals("HISTORY_END(2)", r.parsed["meta_type"])
        assertEquals(1699999999, r.parsed["unix"])
        assertEquals(123456, r.parsed["trim_cursor"])
    }

    @Test
    fun parse_commandResponse_getBatteryLevel() {
        // COMMAND_RESPONSE GET_BATTERY_LEVEL(26): soc=912 -> 91.2%.
        // GENERATED, not captured — see this class's header. Its [seq][result] prefix is 00 00 on a
        // reply that succeeded, which reads as a counterexample to the #791 result-byte mapping, and it
        // was cited as one in #900 by someone who had not read that header. Zero bytes in a generated
        // vector are whatever the generator emitted. Nothing below asserts the result byte. (#900)
        val frame = bytes(
            0xaa, 0x0b, 0x00, 0x97, 0x24, 0x00, 0x1a, 0x00, 0x00, 0x90, 0x03, 0x72,
            0x96, 0x86, 0x64,
        )
        val r = Framing.parseFrame(frame)
        assertTrue(r.ok)
        assertEquals(true, r.crcOk)
        assertEquals("COMMAND_RESPONSE", r.typeName)
        assertEquals("GET_BATTERY_LEVEL(26)", r.parsed["resp_cmd"])
        assertEquals(91.2, r.parsed["battery_pct"] as Double, 1e-9)
    }

    /** Build a CRC-valid WHOOP4 COMMAND_RESPONSE (type 0x24) frame for a given resp_cmd + payload,
     *  computing crc8(length) and crc32(inner) exactly as the strap would, so the decode vector
     *  cross-checks the decoder instead of agreeing with a hand-typed checksum. */
    private fun whoop4CommandResponse(cmd: Int, payload: ByteArray): ByteArray {
        val inner = byteArrayOf(0x24, 0x00, cmd.toByte()) + payload   // type, seq, resp_cmd, payload
        val length = 4 + inner.size                                    // crc32 sits at offset = length
        val out = ByteArray(length + 4)
        out[0] = 0xAA.toByte()
        out[1] = (length and 0xFF).toByte()
        out[2] = ((length ushr 8) and 0xFF).toByte()
        out[3] = Crc.crc8(byteArrayOf(out[1], out[2])).toByte()
        inner.copyInto(out, 4)
        val crc32 = Crc.crc32(inner)
        for (i in 0..3) out[length + i] = ((crc32 ushr (8 * i)) and 0xFFL).toByte()
        return out
    }

    @Test
    fun parse_commandResponse_reportVersionInfo_fwHarvard() {
        // COMMAND_RESPONSE REPORT_VERSION_INFO(7): fw_harvard = four LE u32 at payload[3,7,11,15].
        // payload[0..2] are status bytes (ignored); the four versions spell 41.16.6.0.
        val payload = ByteArray(19)
        fun le32(at: Int, v: Int) { for (i in 0..3) payload[at + i] = ((v ushr (8 * i)) and 0xFF).toByte() }
        le32(3, 41); le32(7, 16); le32(11, 6); le32(15, 0)
        val r = Framing.parseFrame(whoop4CommandResponse(CommandNumber.REPORT_VERSION_INFO.rawValue, payload))
        assertTrue(r.ok)
        assertEquals(true, r.crcOk)
        assertEquals("COMMAND_RESPONSE", r.typeName)
        assertEquals("41.16.6.0", r.parsed["fw_harvard"])
    }

    @Test
    fun parse_corruptedCrc_reportsCrcFalse() {
        // Flip a payload byte so the CRC32 no longer matches; the frame is still well-formed (ok),
        // but crcOk must be false so downstream code rejects it.
        val frame = bytes(
            0xaa, 0x12, 0x00, 0x7d, 0x28, 0x00, 0x00, 0xf1, 0x53, 0x65, 0x00, 0x00,
            0x3e, 0x02, 0x52, 0x03, 0x66, 0x03, 0x73, 0x8f, 0x40, 0xae,
        )
        frame[12] = (frame[12] + 1).toByte() // mutate heart_rate byte
        val r = Framing.parseFrame(frame)
        assertTrue(r.ok)
        assertEquals(false, r.crcOk)
    }

    @Test
    fun parse_fragmentIsInvalid() {
        val r = Framing.parseFrame(bytes(0xaa, 0x12, 0x00))
        assertEquals(false, r.ok)
        assertEquals("INVALID/FRAGMENT", r.typeName)
        assertNull(r.crcOk)
    }

    // MARK: - Reassembler

    @Test
    fun reassembler_splitFrameAcrossFragments() {
        val frame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        val r = Reassembler()
        // Split mid-frame.
        val cut = frame.size / 2
        assertTrue(r.feed(frame.copyOfRange(0, cut)).isEmpty())
        val done = r.feed(frame.copyOfRange(cut, frame.size))
        assertEquals(1, done.size)
        assertArrayEquals(frame, done[0])
    }

    @Test
    fun reassembler_twoFramesInOneFragment() {
        val a = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        val b = Framing.buildCommand(CommandNumber.GET_CLOCK, byteArrayOf(0), seq = 1)
        val r = Reassembler()
        val out = r.feed(a + b)
        assertEquals(2, out.size)
        assertArrayEquals(a, out[0])
        assertArrayEquals(b, out[1])
    }

    @Test
    fun reassembler_dropsLeadingGarbageBeforeSof() {
        val frame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        val r = Reassembler()
        val out = r.feed(byteArrayOf(0x00, 0x11, 0x22) + frame)
        assertEquals(1, out.size)
        assertArrayEquals(frame, out[0])
    }

    @Test
    fun reassembler_garbageLengthDoesNotStall_resyncsToNextFrame() {
        // A misaligned/corrupt SOF with an impossibly large declared length (0xFFFF -> 65539 bytes)
        // must NOT wedge the stream waiting for bytes that can never arrive over BLE. The reassembler
        // should drop the bad SOF and recover the real frame that follows. (This is the live-HR-freeze
        // failure mode: without the guard, every later frame — including HR — is silently dropped.)
        val good = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        val garbage = byteArrayOf(0xAA.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0x00)
        val r = Reassembler()
        val out = r.feed(garbage + good)
        assertEquals(1, out.size)
        assertArrayEquals(good, out[0])
    }

    @Test
    fun reassembler_reassemblesWhenFedOneByteAtATime() {
        // Two back-to-back frames, fed a single byte per fragment. This is the worst case for the old
        // removeAt(0) drain (O(n^2)) and exercises the offset/compact window hard: head advances byte by
        // byte, compact() slides the tail every feed(). Output must still be the two exact frames, in order.
        val first = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        val second = Framing.buildCommand(CommandNumber.GET_CLOCK, byteArrayOf(0), seq = 1)
        val r = Reassembler()
        val out = ArrayList<ByteArray>()
        for (b in first + second) out += r.feed(byteArrayOf(b))
        assertEquals(2, out.size)
        assertArrayEquals(first, out[0])
        assertArrayEquals(second, out[1])
    }

    @Test
    fun reassembler_resetDropsPartialFrame() {
        // reset() (called on every reconnect) must discard a buffered half-frame, so the stale bytes
        // can't corrupt the first frame of the next session.
        val frame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq = 0)
        val r = Reassembler()
        val cut = frame.size / 2
        assertTrue(r.feed(frame.copyOfRange(0, cut)).isEmpty())
        r.reset()
        val out = r.feed(frame)
        assertEquals(1, out.size)
        assertArrayEquals(frame, out[0])
    }

    // MARK: - enum fromRaw

    @Test
    fun enums_fromRawRoundTrip() {
        assertEquals(PacketType.REALTIME_DATA, PacketType.fromRaw(40))
        assertEquals(EventNumber.BATTERY_LEVEL, EventNumber.fromRaw(3))
        assertEquals(MetadataType.HISTORY_END, MetadataType.fromRaw(2))
        assertEquals(CommandNumber.RUN_HAPTICS_PATTERN, CommandNumber.fromRaw(79))
        // #769: STOP_HAPTICS is cmd 122, the documented WHOOP 4.0 clear the Breathe teardown fires.
        assertEquals(CommandNumber.STOP_HAPTICS, CommandNumber.fromRaw(122))
        assertEquals(122, CommandNumber.STOP_HAPTICS.rawValue)
        assertNull(PacketType.fromRaw(999))
        assertNotNull(CommandNumber.fromRaw(26))
    }

    // MARK: - extractStreams

    @Test
    fun extractStreams_hrAndRrFromRealtime() {
        val frame = bytes(
            0xaa, 0x12, 0x00, 0x7d, 0x28, 0x00, 0x00, 0xf1, 0x53, 0x65, 0x00, 0x00,
            0x3e, 0x02, 0x52, 0x03, 0x66, 0x03, 0x73, 0x8f, 0x40, 0xae,
        )
        val parsed = Framing.parseFrame(frame)
        // deviceClockRef == wallClockRef so ts passes through unchanged.
        val streams = extractStreams(listOf(parsed), deviceClockRef = 1700000000, wallClockRef = 1700000000)
        assertEquals(1, streams.hr.size)
        assertEquals(HrSample(ts = 1700000000, bpm = 62), streams.hr[0])
        assertEquals(2, streams.rr.size)
        assertEquals(RrInterval(ts = 1700000000, rrMs = 850), streams.rr[0])
        assertEquals(RrInterval(ts = 1700000000, rrMs = 870), streams.rr[1])
    }

    // MARK: - WHOOP 5.0/MG REALTIME_DATA (+4) + family-aware reassembly

    private fun fromHex(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    /** A real type-40 REALTIME_DATA frame from a worn WHOOP 5 (same vector as the Swift
     *  Whoop5RealtimeTests): hr=98, rr=[603,587] ms, ts=1780916382. HR matched the 0x2A37 profile. */
    private val whoop5RealtimeHex =
        "aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc"

    @Test
    fun whoop5_realtimeData_decodesHrRrAtPlus4() {
        val f = Framing.parseFrame(fromHex(whoop5RealtimeHex), DeviceFamily.WHOOP5)
        assertTrue(f.ok)
        assertEquals("REALTIME_DATA", f.typeName)
        assertEquals(true, f.crcOk)
        assertEquals(98, f.parsed["heart_rate"])          // 4.0 @12 → 5.0 @16
        assertEquals(1780916382, f.parsed["timestamp"])   // 4.0 @6  → 5.0 @10
        @Suppress("UNCHECKED_CAST")
        assertEquals(listOf(603, 587), f.parsed["rr_intervals"] as List<Int>)
    }

    @Test
    fun whoop5_reassembler_isFamilyAware() {
        // The WHOOP4 length rule decodes a bogus ~6 KB length for a 5/MG frame and never emits; the
        // family-aware reassembler frames it correctly (declLen @[2..4], total + 8).
        val frame = fromHex(whoop5RealtimeHex)
        val out = Reassembler(DeviceFamily.WHOOP5).feed(frame)
        assertEquals(1, out.size)
        assertArrayEquals(frame, out[0])
        assertTrue(Reassembler(DeviceFamily.WHOOP4).feed(frame).isEmpty())
    }

    // MARK: - WHOOP 5/MG command + decode vectors (real-hardware captures, #78 fork)

    @Test
    fun puffinCommandFrame_historicalCommandsMatchGooseBytes() {
        // CRC-pinned against frames a real WHOOP 5 acked (Goose-compatible). Our [0x00] default
        // payload pads identically to an empty payload (pad4), so both forms produce these bytes.
        val getRange = Framing.puffinCommandFrame(
            cmd = CommandNumber.GET_DATA_RANGE.rawValue, seq = 1, payload = byteArrayOf(),
        )
        val sendHistorical = Framing.puffinCommandFrame(
            cmd = CommandNumber.SEND_HISTORICAL_DATA.rawValue, seq = 2, payload = byteArrayOf(),
        )
        assertEquals("aa0108000001e67123012200dbf3b335", hex(getRange))
        assertEquals("aa0108000001e6712302160075bedf8c", hex(sendHistorical))
    }

    @Test
    fun whoop5_commandResponse_decodesAtPuffinOffsets() {
        // Synthetic puffin COMMAND_RESPONSE round-trip: GET_DATA_RANGE, resp_seq=7, result=SUCCESS.
        val frame = Framing.puffinCommandFrame(
            cmd = CommandNumber.GET_DATA_RANGE.rawValue,
            seq = 0,
            payload = byteArrayOf(7, 1),
            type = PacketType.COMMAND_RESPONSE.rawValue,
        )
        val parsed = Framing.parseFrame(frame, DeviceFamily.WHOOP5)
        assertEquals("COMMAND_RESPONSE", parsed.typeName)
        assertEquals("GET_DATA_RANGE(34)", parsed.parsed["resp_cmd"])
        assertEquals(7, parsed.parsed["resp_seq"])
        assertEquals("SUCCESS(1)", parsed.parsed["result"])
    }

    @Test
    fun whoop5_event_decodesAtPlus4AndPreservesPayload() {
        // Real 5/MG capture: event 29 with a 16-byte payload. The shared catalogue names it
        // STRAP_CONDITION_REPORT — event NAMES are family-independent (#791) — but its PAYLOAD has no
        // on-device 5.0 ground truth, so it stays raw hex for protocol research rather than being decoded
        // on faith. The payload assertion below is what pins that distinction.
        val frame = fromHex("aa011c00010023d130c61d00e61ab7698a390c000e0000000000e8020b000100d2803585")
        val parsed = Framing.parseFrame(frame, DeviceFamily.WHOOP5)
        assertEquals("EVENT", parsed.typeName)
        assertEquals(true, parsed.crcOk)
        assertEquals("STRAP_CONDITION_REPORT(29)", parsed.parsed["event"])
        assertEquals(1773607654, parsed.parsed["event_timestamp"])
        assertEquals("8a390c000e0000000000e8020b000100", parsed.parsed["event_payload_hex"])
    }

    @Test
    fun whoop5_consoleLogs_extractsText() {
        // Real 5/MG capture: the strap narrating its own history transfer. NUL-trimmed.
        val frame = fromHex(
            "aa014400010030b1329f02005319b769a93e340001486973746f726963616c20446174610a20" +
                "35352c20323538313935393a20424c453a2068697374207472616e7366657220730039d91fe2",
        )
        val parsed = Framing.parseFrame(frame, DeviceFamily.WHOOP5)
        assertEquals("CONSOLE_LOGS", parsed.typeName)
        assertEquals(true, parsed.crcOk)
        assertEquals("Historical Data\n 55, 2581959: BLE: hist transfer s", parsed.parsed["console"])
        // Record header (Swift parity: decodeWhoop5ConsoleLogs): per-chunk counter + batch time.
        assertEquals(671, parsed.parsed["record_index"])
        assertEquals(1773607251, parsed.parsed["unix"])
        assertEquals(16041, parsed.parsed["subsec"])
    }

    @Test
    fun whoop5_consoleLogs_consecutiveChunksCarryContiguousIndices() {
        // Two consecutive real chunks of one console stream — a single log line split mid-word
        // ("…response a" | "ck, start burst") across frames. record_index is the reassembly key.
        val a = Framing.parseFrame(
            fromHex(
                "aa014400010030b132ad020052b4526a337334000131392c203134363535323131393a20424c453a2068" +
                    "697374207472616e7366657220737461727420726573706f6e7365206100324a7906",
            ),
            DeviceFamily.WHOOP5,
        )
        val b = Framing.parseFrame(
            fromHex(
                "aa014400010030b132ae020052b4526a3373340001636b2c2073746172742062757273740a2031392c20" +
                    "3134363535343633303a20424c453a20486973746f727920627572737400e67d611f",
            ),
            DeviceFamily.WHOOP5,
        )
        assertEquals(true, a.crcOk)
        assertEquals(true, b.crcOk)
        assertEquals(685, a.parsed["record_index"])
        assertEquals(686, b.parsed["record_index"])
        assertEquals("19, 146552119: BLE: hist transfer start response a", a.parsed["console"])
        assertEquals("ck, start burst\n 19, 146554630: BLE: History burst", b.parsed["console"])
    }

    // MARK: - CONSOLE_LOGS text-region hardening edges (synthetic frames, Swift parity)

    /** A synthetic CONSOLE_LOGS frame carrying [text] at @21. The CRC32 trailer is left zero: field
     *  decode is CRC-independent (the flag is only reported, never gated on), so these pin the trim/cap
     *  edges without a real capture. Twin of the Swift `consoleFrame` helper. */
    private fun consoleFrame(text: ByteArray): ByteArray {
        val f = ByteArray(21 + text.size + 4)          // envelope + record header + text + CRC32
        f[0] = 0xAA.toByte()
        f[1] = 0x01.toByte()
        f[8] = 0x32.toByte()                            // CONSOLE_LOGS (type 50)
        text.copyInto(f, 21)
        val declaredLength = f.size - 8                 // payload + 4-byte CRC32 (u16 LE @2)
        f[2] = (declaredLength and 0xFF).toByte()
        f[3] = ((declaredLength shr 8) and 0xFF).toByte()
        return f
    }

    /** The 2 KB cap (a garbled/malicious peer must not pin arbitrary bytes as a String). A real chunk
     *  is ~51 bytes and can never reach this from the strap, so it needs a synthetic oversize frame. */
    @Test
    fun whoop5_consoleLogs_oversizedTextCappedAt2048() {
        val f = consoleFrame(ByteArray(2100) { 'A'.code.toByte() })
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertEquals(2048, (p.parsed["console"] as String).length)
    }

    /** An all-NUL (padding-only) text region trims to empty -> no `console` key, not an empty string. */
    @Test
    fun whoop5_consoleLogs_allNulRegionYieldsNoConsole() {
        val f = consoleFrame(ByteArray(6))
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertNull(p.parsed["console"])
    }

    /** Only TRAILING NULs are trimmed; the text before them is kept verbatim. */
    @Test
    fun whoop5_consoleLogs_trailingNulsTrimmed() {
        val f = consoleFrame("AB".toByteArray() + byteArrayOf(0, 0, 0))
        val p = Framing.parseFrame(f, DeviceFamily.WHOOP5)
        assertEquals("AB", p.parsed["console"])
    }
}
