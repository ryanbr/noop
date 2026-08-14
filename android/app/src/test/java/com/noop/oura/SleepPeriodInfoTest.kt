package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 0x6A `sleep_period_info` (OURA_PROTOCOL.md s6.12) — the tag that carries the ring's own average HR
 * and a CANDIDATE breath rate, and that NOOP used to drop as unknown. Kotlin twin of the Swift
 * SleepPeriodInfoTests.swift.
 *
 * PARITY NOTE: every fixture hex string below is byte-for-byte identical to the Swift fixtures, so the
 * SAME raw record bytes must decode to the SAME values on both platforms. They are REAL captured
 * records from a Gen 3 overnight (`Night 08-06_08_07`, `oura-raw.jsonl`), full `type len rt(4 LE)
 * body(10)` bytes, not synthetic bodies — the point of the tag is what the ring actually sends.
 */
class SleepPeriodInfoTest {
    private val eps = 1e-9

    private fun record(hex: String): OuraRecord {
        val rec = OuraFraming.parseRecord(OuraTestHex.bytes(hex))
            ?: throw AssertionError("record failed to parse: $hex")
        assertEquals(OuraEventTag.SLEEP_PERIOD_INFO.raw, rec.type)
        assertEquals("0x6A bodies are a fixed 10 bytes in every record we hold", 10, rec.payload.size)
        return rec
    }

    // MARK: - The layout, on real records

    /**
     * A typical mid-sleep record. Pins all nine fields at once, which is what catches an off-by-one in
     * the offsets: with the fields adjacent and differently scaled, a one-byte slip cannot leave all
     * nine right.
     */
    @Test
    fun testTypicalRecordDecodesEveryField() {
        val info = OuraDecoders.decodeSleepPeriodInfo(record("6a0e9dcca60068f13a1f831f0001d257"))!!
        assertEquals(52.0, info.averageHrBpm, eps)          // wire 0x68 = 104, x 0.5
        assertEquals(-0.9375, info.hrTrend, eps)            // wire 0xf1 = -15 SIGNED, x 0.0625
        assertEquals(3.625, info.mzci, eps)                 // wire 0x3a = 58, x 0.0625
        assertEquals(1.9375, info.dzci, eps)                // wire 0x1f = 31, x 0.0625
        assertEquals(16.375, info.breathsPerMin, eps)       // wire 0x83 = 131, / 8
        assertEquals(3.875, info.breathVariability, eps)    // wire 0x1f = 31, / 8
        assertEquals(0, info.motionCount)
        assertEquals(1, info.sleepState)
        assertEquals(0.343048, info.cv, 1e-6)               // 0x57d2 LE / 65536
    }

    /**
     * `average_hr` is `u8 * 0.5`, not a bare bpm byte: an ODD wire byte decodes to a half-bpm. About
     * half of all real records carry one (0.506 / 0.530 / 0.507 / 0.467 across four nights), so the
     * half-steps are the channel's real resolution and rounding them away would be a decode loss.
     */
    @Test
    fun testAverageHrHasHalfBpmResolution() {
        val info = OuraDecoders.decodeSleepPeriodInfo(record("6a0eb6cda60067e92e14862200013f58"))!!
        assertEquals(51.5, info.averageHrBpm, eps)          // wire 0x67 = 103 — ODD
        assertEquals(16.75, info.breathsPerMin, eps)
    }

    /**
     * `hr_trend` is the body's ONE signed field. Read as unsigned this record's -4.625 becomes +11.375,
     * which is a plausible-looking number — hence a test rather than a comment.
     */
    @Test
    fun testHrTrendIsSigned() {
        val info = OuraDecoders.decodeSleepPeriodInfo(record("6a0e99efa60062b638176f1f01004055"))!!
        assertEquals(-4.625, info.hrTrend, eps)             // wire 0xb6 = -74 SIGNED, x 0.0625
        assertEquals(49.0, info.averageHrBpm, eps)
        assertEquals(1, info.motionCount)
        assertEquals(0, info.sleepState)
    }

    /**
     * A restless record: motion present, HR up, trend strongly positive. Confirms the fields move
     * together the way a real summary should rather than being a fixed pattern.
     */
    @Test
    fun testRestlessRecord() {
        val info = OuraDecoders.decodeSleepPeriodInfo(record("6a0e0929a7008c7f54346f261b007340"))!!
        assertEquals(70.0, info.averageHrBpm, eps)
        assertEquals(7.9375, info.hrTrend, eps)             // wire 0x7f = +127, the positive extreme
        assertEquals(27, info.motionCount)
        assertEquals(13.875, info.breathsPerMin, eps)
    }

    // MARK: - The honest-data boundaries

    /**
     * The source's own parser THROWS when `motion_count >= 121` or `sleep_state > 2`, so a body that
     * breaks either is not this layout. Return null rather than a number assembled from bytes that mean
     * something else — and note this costs nothing on real data: all 3,493 records across four
     * consecutive overnights satisfy both.
     */
    @Test
    fun testDeclaredInvariantsRejectABody() {
        val badMotion = OuraRecord(
            type = 0x6A, ringTimestamp = 1L,
            payload = intArrayOf(104, 0, 58, 31, 131, 31, 121, 1, 0xd2, 0x57),
        )
        assertNull("motion_count == 121 is out of range", OuraDecoders.decodeSleepPeriodInfo(badMotion))
        val badState = OuraRecord(
            type = 0x6A, ringTimestamp = 1L,
            payload = intArrayOf(104, 0, 58, 31, 131, 31, 0, 3, 0xd2, 0x57),
        )
        assertNull("sleep_state == 3 is out of range", OuraDecoders.decodeSleepPeriodInfo(badState))
        // …and the boundary values that ARE legal still decode, so the guard is not off by one.
        val edge = OuraRecord(
            type = 0x6A, ringTimestamp = 1L,
            payload = intArrayOf(104, 0, 58, 31, 131, 31, 120, 2, 0xff, 0xff),
        )
        val ok = OuraDecoders.decodeSleepPeriodInfo(edge)!!
        assertEquals(120, ok.motionCount)
        assertEquals(2, ok.sleepState)
        assertEquals(0.999985, ok.cv, 1e-6)
    }

    @Test
    fun testShortBodyDecodesToNull() {
        val short = OuraRecord(
            type = 0x6A, ringTimestamp = 1L,
            payload = intArrayOf(104, 0, 58, 31, 131, 31, 0, 1, 0xd2),
        )
        assertNull("9 bytes cannot hold the u16 cv tail", OuraDecoders.decodeSleepPeriodInfo(short))
    }

    // MARK: - Tier discipline

    /**
     * 0x6A is Tier B: the field NAMES rest on one decompiled-binary source, and nothing has shown
     * `breath` tracks a real respiratory rate (#194). So the driver must drop it by default and only
     * emit it when a caller explicitly asks for Tier B.
     */
    @Test
    fun testTagIsTierBAndGatedInTheDriver() {
        assertEquals(TrustTier.TIER_B, OuraEventTag.SLEEP_PERIOD_INFO.tier)
        val rec = record("6a0e9dcca60068f13a1f831f0001d257")

        val gated = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        assertTrue("Tier-B 0x6A must not be emitted by default", gated.ingest(rec).isEmpty())

        val allowed = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null, allowTierB = true)
        val events = allowed.ingest(rec)
        assertEquals(1, events.size)
        val e = events[0] as OuraEvent.SleepPeriodInfo
        assertEquals(16.375, e.value.breathsPerMin, eps)
        assertTrue("a consumer asserting a Tier-A-only sink must see this as Tier B", e.isTierB)
        assertEquals(rec.ringTimestamp, e.envelopeRingTimestamp)
    }
}
