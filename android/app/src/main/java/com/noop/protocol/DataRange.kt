package com.noop.protocol

/**
 * GET_DATA_RANGE frame parsing. Byte-identical twin of Swift `WhoopProtocol.DataRange` — the newest-record
 * read gates automatic sync (`isFutureDatedNewest` -> BackfillPolicy), so its value must match across
 * platforms. Extracted from WhoopBleClient (#286 follow-up) so both a Kotlin JVM test and a WhoopProtocol
 * `swift test` pin the parity.
 */
object DataRange {
    /**
     * The newest plausible unix time banked by the strap, from a GET_DATA_RANGE frame. Scans EVERY byte
     * offset (the newest-record u32 isn't on a fixed grid — it sits at byte offset 8 on WHOOP 4, off the
     * old aligned-from-7 scan), keeps the newest word in a plausible unix window (2023-11..2030-03),
     * preferring the newest that is NOT implausibly future (> wallNowUnix + futureSkewSeconds) so a garbage
     * future word can't latch and stall auto-sync (#451/#928/#1012). Falls back to the newest-any word so a
     * genuinely future-dated RTC is still surfaced downstream. null only for a too-short frame or no
     * plausible word. Mirrors Swift `DataRange.newestUnix`.
     */
    fun newestUnix(frame: ByteArray, wallNowUnix: Long, futureSkewSeconds: Long): Long? {
        if (frame.size < 4) return null
        val futureCutoff = wallNowUnix + futureSkewSeconds
        var newestNotFuture: Long? = null
        var newestAny: Long? = null
        var i = 0
        while (i + 4 <= frame.size) {
            val w = (frame[i].toLong() and 0xFFL) or
                ((frame[i + 1].toLong() and 0xFFL) shl 8) or
                ((frame[i + 2].toLong() and 0xFFL) shl 16) or
                ((frame[i + 3].toLong() and 0xFFL) shl 24)
            if (w in 1_700_000_000L..1_900_000_000L) {
                newestAny = maxOf(newestAny ?: 0L, w)
                if (w <= futureCutoff) newestNotFuture = maxOf(newestNotFuture ?: 0L, w)
            }
            i += 1
        }
        return newestNotFuture ?: newestAny
    }

    /**
     * The OLDEST plausible unix time banked by the strap (start of stored history), from a GET_DATA_RANGE
     * frame — the low end of the banked span (oldest…newest = the backlog DEPTH a deep oldest-first drain
     * must cover before recent nights land, #364).
     *
     * Unlike [newestUnix], scans ONLY the 4-byte grid aligned from offset 7, NOT every offset — and that
     * asymmetry is DELIBERATE. The minimum is fragile in a way the maximum is not: an any-offset scan of a
     * real WHOOP 4.0 frame surfaces a spurious straddle word (offset 6 -> 1_754_857_506, ~11 months *before*
     * the true newest at offset 8) that would hijack the min and report a bogus deep backlog. The max is
     * immune — the real newest dominates it — which is why [newestUnix] can scan every offset. The aligned
     * grid skips that straddle, so real frames with no distinct oldest word return null here. Do NOT "make
     * this consistent with newestUnix" by scanning every offset without anchoring — see DataRangeScanTest.
     * Mirrors Swift `DataRange.oldestUnix`.
     */
    fun oldestUnix(frame: ByteArray): Long? {
        if (frame.size <= 7) return null
        var oldest: Long? = null
        var i = 7
        while (i + 4 <= frame.size) {
            val w = (frame[i].toLong() and 0xFFL) or
                ((frame[i + 1].toLong() and 0xFFL) shl 8) or
                ((frame[i + 2].toLong() and 0xFFL) shl 16) or
                ((frame[i + 3].toLong() and 0xFFL) shl 24)
            if (w in 1_700_000_000L..1_900_000_000L) oldest = minOf(oldest ?: Long.MAX_VALUE, w)
            i += 4
        }
        return oldest
    }

    /**
     * #689/#815: the ring-buffer page backlog ("pages behind") the strap reports in a GET_DATA_RANGE
     * response — DIAGNOSTIC ONLY (feeds a future sync-progress UI, never gates sync or backfill itself).
     * Confirmed against real captures on both WHOOP 4.0 (#791) and 5.0/MG (#815): the write/read pointers
     * and ring capacity below all landed exactly where this predicts, across four independent frames.
     * Mirrors Swift `DataRange.pagesBehind`.
     *
     * Reads three u32s from the command-response INNER payload (byte 0 a subtype), `V(i) = @ (i*4 + 3)`:
     * write pointer W=V(2), read pointer U=V(3), ring capacity T=V(5) — at frame offsets cmdOff + 12/16/24
     * (inner payload starts at cmdOff + 1). u32 LITTLE-endian to match the frame's other words. Backlog
     * with wraparound (unverified — no real capture has crossed it yet, but harmless since this only ever
     * feeds a diagnostic): W<U ? W+(T-U) : W-U. T has been 131072 in every real capture so far (both
     * families) but is still read from the frame each time rather than hardcoded, in case a firmware
     * revision differs. Returns null for a too-short frame or implausible values (capacity 0 or over a
     * sane ceiling, a pointer at/beyond capacity, or a backlog past capacity).
     */
    fun pagesBehind(frame: ByteArray, cmdOff: Int): Long? {
        if (cmdOff < 0) return null
        val payloadOffset = cmdOff + 1
        val wOff = payloadOffset + 11; val uOff = payloadOffset + 15; val tOff = payloadOffset + 23
        if (tOff + 4 > frame.size) return null
        fun u32(o: Int): Long =
            (frame[o].toLong() and 0xFFL) or
                ((frame[o + 1].toLong() and 0xFFL) shl 8) or
                ((frame[o + 2].toLong() and 0xFFL) shl 16) or
                ((frame[o + 3].toLong() and 0xFFL) shl 24)
        val w = u32(wOff); val u = u32(uOff); val t = u32(tOff)
        if (t <= 0L || t > 0x00FFFFFFL || w >= t || u >= t) return null
        val behind = if (w < u) w + (t - u) else w - u
        if (behind < 0L || behind > t) return null
        return behind
    }

    /**
     * The BLE seam's decision on a GET_DATA_RANGE COMMAND_RESPONSE: is this a reply to [opcode], and may
     * it move state? A reply is accepted only on the verifier's FULL verdict.
     *
     * This one reply does not merely report a timestamp: [newestUnix]/[oldestUnix] become the window every
     * drained record of the same sync is checked against (#547). A damaged reply that narrows the window
     * makes the real records fall through it — the section persists nothing and is acked anyway, which is
     * the permanent loss the integrity gate exists to stop. So the gate belongs to this decision, not to
     * the seam that happens to host it.
     *
     * [verdictOk] is the FULL verdict of the single parse the caller already holds, taken lazily so a frame
     * that is not this reply costs one byte compare and no parse. The opcode is passed in rather than
     * restated here: the command table lives with the caller. Mirrors Swift `DataRange.acceptsReply`.
     */
    fun acceptsReply(frame: ByteArray, cmdOff: Int, opcode: Int, verdictOk: () -> Boolean): Boolean {
        if (cmdOff < 0 || cmdOff >= frame.size) return false
        if ((frame[cmdOff].toInt() and 0xFF) != opcode) return false
        return verdictOk()
    }

    /**
     * True when a GET_DATA_RANGE COMMAND_RESPONSE is the `PENDING(2)` acknowledgement rather than the
     * answer. The strap replies twice: a short PENDING ack, then the payload with `SUCCESS(1)`. Framing's
     * own result-code table already states it — "2=PENDING precedes SUCCESS on GET_DATA_RANGE
     * (hardware-confirmed, #78 fork)" — but [pagesBehind] had no way to tell the two apart, so the ack
     * (which carries no ring pointers by construction) decoded to null and logged as a decode FAILURE once
     * per sync.
     *
     * The result byte sits at `cmdOff + 2`, after the echoed opcode and the origin sequence. A frame too
     * short to hold one is not a PENDING ack, so it stays false and the caller keeps its existing
     * too-short handling. Twin of the Swift `DataRange.isPendingResponse`.
     */
    fun isPendingResponse(frame: ByteArray, cmdOff: Int): Boolean {
        if (cmdOff < 0 || cmdOff + 2 >= frame.size) return false
        return (frame[cmdOff + 2].toInt() and 0xFF) == 2
    }
}
