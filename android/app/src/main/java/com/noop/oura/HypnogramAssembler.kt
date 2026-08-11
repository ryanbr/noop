package com.noop.oura

// HypnogramAssembler: reconstruct the TIME AXIS of the ring's sleep-phase hypnogram. Byte-identical
// Kotlin twin of Swift's HypnogramAssembler.swift.
//
// THE PROBLEM (observed on-device 2026-07-12, Gen3): the ring's SleepNet finalizes a night's staging
// AFTER wake and writes the whole hypnogram to its event log in ONE BURST — e.g. 23 records x 52
// codes, all sharing essentially the same envelope ring-time (the WRITE moment). The envelope
// timestamp therefore marks WHEN THE ANALYSIS WAS SAVED, not when the sleep happened; anchoring each
// record at its envelope collapses an entire night onto a few seconds.
//
// THE RECONSTRUCTION: the burst's codes are one contiguous sequence at 30 s/code, ENDING at the
// anchored burst end. Laying N codes backward from that end recovers the real window. The 30 s epoch
// is triple-confirmed: open_oura's sleepnet.md ("DEEP/LIGHT/REM/WAKE classification at 30-second
// intervals"), the observed window math (1,196 codes over a ~10 h night), and the 0x49 summary's
// window minutes over those same codes. The burst end itself is the matching 0x49 window's TRUE
// sleep end when available (the write moment trails it by 10–43 min observed) — that pairing lives
// in the live source; this assembler only groups and lays out.
//
// Platform-pure, no android.bluetooth, no clock (the caller resolves the anchored end time).

/** One sleep-phase record as fed to the assembler: its envelope ring-time + decoded codes in order. */
data class OuraHypnogramRecord(val ringTimestamp: Long, val phases: List<OuraSleepPhase>)

/** One reconstructed code with its laid-out unix-seconds timestamp (interval START). */
data class OuraHypnogramCode(val phase: OuraSleepPhase, val ts: Long)

/** One completed burst of consecutive sleep-phase records (usually a whole night's hypnogram). */
data class OuraHypnogramBurst(val records: List<OuraHypnogramRecord>) {
    /** Total 2-bit codes across the burst. */
    val totalCodes: Int get() = records.sumOf { it.phases.size }

    /**
     * The burst's LAST envelope ring-time — the write/finalization moment the reconstruction anchors
     * its END to (absent a 0x49 refinement), and the resume-cursor note for the whole burst.
     */
    val lastRingTimestamp: Long get() = records.lastOrNull()?.ringTimestamp ?: 0

    /**
     * True when any record's envelope ring-time is LOWER than its predecessor's within this burst —
     * the one signal that the arrival order (which the layout trusts as the sequence ground truth)
     * might not be chronological. Surfaced so the caller can LOG it rather than fail silently;
     * re-sorting is deliberately not done (envelope ring-times of a burst are near-identical write
     * moments, so a sort on them could scramble the true code sequence).
     */
    val hasNonMonotonicRingTimes: Boolean
        get() = records.zipWithNext().any { (a, b) -> b.ringTimestamp < a.ringTimestamp }

    /**
     * Lay the burst's codes out backward from [endUnixSeconds] at [secondsPerCode]. Code j of N gets
     * `ts = end - (N - j) * secondsPerCode` — i.e. each ts marks the START of that code's interval
     * and the final code's interval ends exactly at the burst end. Order: records in arrival order,
     * codes by their in-record index (the sequence is the ground truth; the spacing is the documented
     * 30 s SleepNet epoch). Arrival order is deliberately NOT re-sorted by envelope ring-time — see
     * [hasNonMonotonicRingTimes] for the surfaced escape hatch.
     *
     * When [sleepStartUnixSeconds] is given (the ring's 0x49 window ONSET), codes that fall BEFORE it are
     * dropped — clipping the SleepNet burst's pre-window epochs to the ring's own sleep window, symmetric
     * with anchoring the end to the 0x49 sleep-end. A clamp that would drop EVERY code is IGNORED (the full
     * unclamped lay is returned) so a mis-paired window can never empty the night. null = no clip.
     */
    fun codesWithTimes(
        endUnixSeconds: Long,
        sleepStartUnixSeconds: Long? = null,
        secondsPerCode: Long = 30,
    ): List<OuraHypnogramCode> {
        val n = totalCodes
        val out = ArrayList<OuraHypnogramCode>(n)
        var j = 0
        for (record in records) {
            for (phase in record.phases) {
                out.add(OuraHypnogramCode(phase, endUnixSeconds - (n - j) * secondsPerCode))
                j += 1
            }
        }
        // #1246: drop UNWRITTEN epochs (whole-record 0xFF erased pages) from the reconstructed hypnogram —
        // they are a GAP, not AWAKE. Done AFTER the lay so n/j (and thus every WRITTEN code's ts) are
        // computed over the full sequence: an unwritten run anywhere — head, middle, or tail — leaves the
        // real codes around it correctly timed. An all-unwritten burst yields [] (an honest no-stage night),
        // which the caller drops rather than persisting a blank session. Byte-parity twin of Swift.
        val written = out.filter { !it.phase.unwritten }
        if (sleepStartUnixSeconds == null) return written
        val clipped = written.filter { it.ts >= sleepStartUnixSeconds }
        return if (clipped.isEmpty()) written else clipped
    }
}

/**
 * Accumulate consecutive sleep-phase records into bursts. Records whose envelope ring-times sit
 * within [burstGapTicks] of the previous record belong to the same burst (a finalization write-out);
 * a larger gap (a different night / a separate analysis pass) closes the burst and starts a new one.
 */
class OuraHypnogramAssembler(
    /**
     * Max envelope ring-time gap (ticks, 100 ms each) between records of ONE burst. Observed bursts
     * share rts within a few seconds; 600 ticks = 60 s is generous while still splitting nights
     * (separate finalizations are hours apart).
     */
    val burstGapTicks: Long = 600,
) {
    private var current = ArrayList<OuraHypnogramRecord>()

    /**
     * Feed one record. Returns the PREVIOUS burst when this record's ring-time gap closes it (the fed
     * record then starts the next burst); null while the current burst is still growing. Records with
     * no codes are ignored (nothing to place).
     */
    fun feed(ringTimestamp: Long, phases: List<OuraSleepPhase>): OuraHypnogramBurst? {
        if (phases.isEmpty()) return null
        val record = OuraHypnogramRecord(ringTimestamp, phases)
        val last = current.lastOrNull()
        if (last != null) {
            val gap = if (ringTimestamp >= last.ringTimestamp) {
                ringTimestamp - last.ringTimestamp
            } else {
                last.ringTimestamp - ringTimestamp
            }
            if (gap > burstGapTicks) {
                val done = OuraHypnogramBurst(current)
                current = arrayListOf(record)
                return done
            }
        }
        current.add(record)
        return null
    }

    /** Close and return the in-progress burst (call at drain end / teardown), or null if none. */
    fun flush(): OuraHypnogramBurst? {
        if (current.isEmpty()) return null
        val done = OuraHypnogramBurst(current)
        current = ArrayList()
        return done
    }

    /** Discard any partial state (fresh session). */
    fun reset() {
        current = ArrayList()
    }

    /** Number of records currently accumulating (observability only). */
    val pendingRecordCount: Int get() = current.size
}
