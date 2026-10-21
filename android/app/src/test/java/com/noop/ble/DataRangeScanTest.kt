package com.noop.ble

import com.noop.protocol.DataRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [WhoopBleClient.dataRangeNewestUnix] offset/future-date correctness (#451/#928/#1012).
 *
 * Regression fixtures are David's REAL WHOOP 4.0 GET_DATA_RANGE frames captured 2026-07-11: the newest
 * banked record is 2026-07-11 16:00 (unix 1_783_785_625) and it sits at BYTE OFFSET 8 — off the old
 * 4-byte-aligned-from-7 grid, so the old scan returned null and a stale FUTURE word stayed latched in
 * strapNewestTs, which #228 then used to skip the periodic offload → auto-sync stalled ~25 min.
 */
class DataRangeScanTest {

    private fun hex(s: String) = ByteArray(s.length / 2) {
        ((Character.digit(s[it * 2], 16) shl 4) + Character.digit(s[it * 2 + 1], 16)).toByte()
    }

    /** Little-endian u32 [value] written at [offset] into a [size]-byte frame (rest zero). */
    private fun frameWithU32(size: Int, offset: Int, value: Long): ByteArray {
        val b = ByteArray(size)
        for (k in 0..3) b[offset + k] = ((value shr (8 * k)) and 0xFF).toByte()
        return b
    }

    private val WALL_NOW = 1_783_786_000L    // 2026-07-11 ~16:06, just after the captured newest
    private val REAL_NEWEST = 1_783_785_625L // 2026-07-11 16:00:25 (frame a)

    @Test
    fun `reads the real WHOOP4 newest at byte offset 8 (old scan-from-7 missed it, returned null)`() {
        // Three real captured frames → their true newest (offset-8 u32), all 2026-07-11 ~16:00, a few
        // seconds apart. Each is well behind WALL_NOW, so none is treated as future.
        val expected = mapOf(
            "aa100057305d22009968526a083900001d2e2263" to 1_783_785_625L, // 16:00:25
            "aa10005730612200a268526ab0290000e87d155d" to 1_783_785_634L, // 16:00:34
            "aa100057307c2200e768526a78760000c997138d" to 1_783_785_703L, // 16:01:43
        )
        for ((h, ts) in expected) {
            assertEquals(
                "newest for $h should be its offset-8 value, not null",
                ts,
                WhoopBleClient.dataRangeNewestUnix(hex(h), WALL_NOW),
            )
        }
    }

    @Test
    fun `a lone future-dated straddle never becomes the frontier`() {
        // Real "today" word plus a fabricated far-future word: the true frontier is today, not the future.
        val future = WALL_NOW + 400L * 86_400L
        val frame = frameWithU32(16, 4, REAL_NEWEST)
        for (k in 0..3) frame[10 + k] = ((future shr (8 * k)) and 0xFF).toByte()
        assertEquals(REAL_NEWEST, WhoopBleClient.dataRangeNewestUnix(frame, WALL_NOW))
    }

    @Test
    fun `all-future frame (genuinely wrong RTC) still returns future so the guard fires`() {
        // The strap's ONLY plausible-unix word is future → return it so isFutureDatedNewest detects the
        // real bad-clock case and the periodic/auto-continue guards correctly refuse the range (#928).
        val future = WALL_NOW + 400L * 86_400L
        assertEquals(future, WhoopBleClient.dataRangeNewestUnix(frameWithU32(12, 4, future), WALL_NOW))
    }

    @Test
    fun `a value just inside the 48h skew is treated as present, not future`() {
        val within = WALL_NOW + 40L * 3600L   // 40h ahead, under the 48h AUTO_CONTINUE_FUTURE_SKEW
        assertEquals(within, WhoopBleClient.dataRangeNewestUnix(frameWithU32(12, 4, within), WALL_NOW))
    }

    // oldestUnix — aligned-from-7 (asymmetric with dataRangeNewestUnix by design)

    /**
     * The whole reason [WhoopBleClient.dataRangeOldestUnix] scans the aligned grid, not every offset: the
     * real WHOOP 4.0 frame carries a spurious plausible straddle at byte offset 6 (1_754_857_506, ~11 months
     * BEFORE the true newest at offset 8). An any-offset MIN would return it → a bogus deep backlog. The
     * aligned grid skips it, so this frame (no distinct oldest word) → null. Guards a future "consistency" refactor.
     */
    @Test
    fun `oldest aligned scan skips the spurious offset-6 straddle`() {
        assertEquals(null, WhoopBleClient.dataRangeOldestUnix(hex("aa100057305d22009968526a083900001d2e2263")))
    }

    @Test
    fun `oldest reads a grid-aligned word`() {
        assertEquals(1_750_000_000L, WhoopBleClient.dataRangeOldestUnix(frameWithU32(12, 7, 1_750_000_000L)))
    }

    @Test
    fun `oldest keeps the minimum across grid words`() {
        val frame = frameWithU32(16, 7, 1_800_000_000L)                 // grid offset 7
        for (k in 0..3) frame[11 + k] = ((1_750_000_000L shr (8 * k)) and 0xFF).toByte() // grid offset 11
        assertEquals(1_750_000_000L, WhoopBleClient.dataRangeOldestUnix(frame))
    }

    // #689/#815 pagesBehind (ring backlog): byte-parity twin of the Swift DataRangeTests cases.

    private fun pagesFrame(cmdOff: Int, w: Long, u: Long, t: Long, size: Int = 40): ByteArray {
        val b = ByteArray(size)
        fun put(off: Int, v: Long) { for (k in 0..3) b[off + k] = ((v shr (8 * k)) and 0xFF).toByte() }
        put(cmdOff + 12, w); put(cmdOff + 16, u); put(cmdOff + 24, t)
        return b
    }

    @Test fun `pagesBehind normal no wrap`() =
        assertEquals(300L, DataRange.pagesBehind(pagesFrame(6, 500, 200, 1024), 6))

    @Test fun `pagesBehind wraparound`() =    // synthetic — no real capture has crossed the wrap yet
        assertEquals(300L, DataRange.pagesBehind(pagesFrame(6, 100, 800, 1000), 6))

    @Test fun `pagesBehind too short is null`() =
        assertNull(DataRange.pagesBehind(ByteArray(20), 6))

    @Test fun `pagesBehind implausible is null`() {
        assertNull(DataRange.pagesBehind(pagesFrame(6, 1, 1, 0), 6))                // capacity 0
        assertNull(DataRange.pagesBehind(pagesFrame(6, 1, 1, 1_783_785_625L), 6))  // T is a timestamp
        assertNull(DataRange.pagesBehind(pagesFrame(6, 5, 2000, 1000), 6))         // U >= T
    }

    /**
     * Real captures (#791 WHOOP4, #815 WHOOP 5.0/MG) — confirms the offset fix against hardware, not just
     * synthetic math. All four are the non-wrapped case (W > U); ring capacity T is 131072 in every one.
     */
    @Test fun `pagesBehind real captures`() {
        val cases = listOf(
            // WHOOP4, cmdOff 6 (Galaxy S24 Ultra capture, #791)
            Triple(
                "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000" +
                    "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04",
                6, 83L,
            ),
            // WHOOP 5.0/MG, cmdOff 10 (#815)
            Triple(
                "aa014c00010032d124cc22040101c0890100b4890100b6890100b4890100110000000000020012000000" +
                    "e2ff1d00785ac169707d0000edeb626a5c0f0000edeb626a5c0f0000feeb626a5c0f00000000a7c3ec16",
                10, 2L,
            ),
            Triple(
                "aa014c00010032d1241e22050101008a0100dd890100e5890100dd890100110000000000020" +
                    "05d00000088ff1d00da5dc169b87e000002ee626a0000000002ee626a000000005dee626a140e000000009f8dfab4",
                10, 8L,
            ),
            Triple(
                "aa014c00010032d124982207010180b901005ab7010048b901005ab7010010000000000002" +
                    "00da1b00000ee31d00b0e1ff69d7430000a3ab266a3d4a0000a3ab266a3d4a00007cc7266a5c4f00000000623977f5",
                10, 494L,
            ),
        )
        for ((h, cmdOff, expected) in cases) {
            assertEquals(
                "pagesBehind for $h at cmdOff $cmdOff should be $expected",
                expected,
                DataRange.pagesBehind(hex(h), cmdOff),
            )
        }
    }

    // #689 PENDING ack: GET_DATA_RANGE answers twice and only the second carries the ring pointers.
    // Byte-parity twin of the Swift DataRangeTests cases. Both frames are real, captured on a WHOOP MG
    // (WS50_r00, fw 50.39.1.0) on 2026-08-28; the pair below is one request's two replies.

    /** The PENDING(2) ack: 20 bytes, result byte at cmdOff+2 is 0x02, no ring pointers in it at all. */
    @Test fun `isPendingResponse true for the PENDING ack`() =
        assertTrue(DataRange.isPendingResponse(hex("aa010c000100271124e8220402000000c391bc3d"), 10))

    /** The SUCCESS(1) answer to that same request. Must NOT be skipped. */
    @Test fun `isPendingResponse false for the SUCCESS answer`() =
        assertFalse(
            DataRange.isPendingResponse(
                hex(
                    "aa014c00010032d124e92204010100bf0000b4be0000c1be0000b4be00000c00000000" +
                        "0002008f00",
                ),
                10,
            ),
        )

    /**
     * The reason this pair matters: the ack decodes to null, so before the guard it logged as a decode
     * failure once per sync while the real answer decoded fine two lines later.
     */
    @Test fun `the PENDING ack is exactly the frame pagesBehind cannot decode`() {
        val pending = hex("aa010c000100271124e8220402000000c391bc3d")
        assertNull(DataRange.pagesBehind(pending, 10))
        assertTrue(DataRange.isPendingResponse(pending, 10))
    }

    /** A frame too short to hold a result byte is not a PENDING ack; the caller keeps its own handling. */
    @Test fun `isPendingResponse false when too short for a result byte`() =
        assertFalse(DataRange.isPendingResponse(ByteArray(11), 10))

    /** A negative cmdOff is rejected rather than indexing backwards. */
    @Test fun `isPendingResponse false for a negative cmdOff`() =
        assertFalse(DataRange.isPendingResponse(ByteArray(40), -1))

    /** wearable5.0 golden vectors: the 5/MG newest-page clock at `cmdOff + 60`, and the 0xFFFFFFFF sentinel
     *  read as no clock. Twin of the Swift `testWhoop5PageClockNewestIsFieldExact`. */
    @Test fun `whoop5 page clock newest is field exact`() {
        val normal = hex("aa014c00010032d12405220401010000000000000000780000006400000000000000000002000000000000000000000000000000000000000000000000000000000000000000fb3bb16a00000000000010266950")
        val sentinel = hex("aa014c00010032d1240522040101000000000000000005000000feff010000000000000002000000000000000000000000000000000000000000000000000000000000000000ffffffff0000000000009904b681")
        assertEquals(1_790_000_123L, DataRange.pageClockNewestUnix(normal, 10))
        assertEquals(20L, DataRange.pagesBehind(normal, 10))
        assertNull(DataRange.pageClockNewestUnix(sentinel, 10))
        assertEquals(7L, DataRange.pagesBehind(sentinel, 10))
        assertNull(DataRange.pageClockNewestUnix(normal.copyOf(60), 10))
    }
}
