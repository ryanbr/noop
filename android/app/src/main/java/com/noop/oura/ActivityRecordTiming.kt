package com.noop.oura

/**
 * Place a 0x50 activity_info record's MET samples on the clock. Twin of Swift
 * `OuraActivityRecordTiming` (OuraProtocol/ActivityRecordTiming.swift).
 *
 * A 0x50 record carries N MET samples and ONE ring timestamp, and that timestamp is the END of the
 * record's LAST sample — not the start of its first. Fitted against Oura's own per-minute export,
 * every record length N matched best at exactly −N epochs: reading forward from the timestamp gives
 * 23 % exact minute matches (r 0.57), reading back from it gives 85 % (r 0.90). So sample i starts at
 * `endUtc − (N − i) × epoch`, and the record's samples span `endUtc − N × epoch until endUtc`.
 *
 * This lived inline in both BLE callbacks, which no test can reach: the arithmetic is one expression,
 * but it is the expression that decides which DAY a minute lands on, so a record straddling local
 * midnight splits correctly only if both platforms agree to the second. Hoisted here so the rule is
 * stated once per platform and pinned by the shared fixture
 * `oura_met_record_timing_oracle.json`.
 *
 * Pure value arithmetic — no Android, no database. Facts per OURA_PROTOCOL.md s6.13.
 */
object OuraActivityRecordTiming {

    /**
     * Start time (UTC seconds) of sample [index] in a record of [sampleCount] samples whose timestamp
     * is [endUtc]. [index] is zero-based in record order, so the LAST sample (`sampleCount - 1`)
     * starts one epoch before [endUtc] and the first starts [sampleCount] epochs before it.
     *
     * No clamping and no validation: a caller passing a non-positive [epochSeconds] or an out-of-range
     * [index] gets the arithmetic it asked for. The guard belongs at the call site, which knows whether
     * the record was anchored at all — see [sampleStarts], which rejects the degenerate shapes.
     *
     * Byte-parity twin of Swift `OuraActivityRecordTiming.sampleStart`.
     */
    fun sampleStart(endUtc: Long, sampleCount: Int, index: Int, epochSeconds: Int): Long =
        endUtc - (sampleCount - index).toLong() * epochSeconds

    /**
     * Start times for every sample in the record, in record order (ascending, one [epochSeconds] apart).
     *
     * Empty when the record carries no samples or [epochSeconds] is not positive — both mean "there is
     * nothing to place on the clock", and returning empty keeps the decision here instead of leaving
     * each call site to remember it. The first element is `endUtc - sampleCount * epochSeconds`; the
     * last is `endUtc - epochSeconds`. [endUtc] itself is never a sample start: it is the exclusive end
     * of the record's span.
     *
     * Byte-parity twin of Swift `OuraActivityRecordTiming.sampleStarts`.
     */
    fun sampleStarts(endUtc: Long, sampleCount: Int, epochSeconds: Int): List<Long> {
        if (sampleCount <= 0 || epochSeconds <= 0) return emptyList()
        return (0 until sampleCount).map { sampleStart(endUtc, sampleCount, it, epochSeconds) }
    }

}
