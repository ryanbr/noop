package com.noop.analytics

/*
 * Spo2ReTrace.kt - the Connection-mode SpO2 reverse-engineering dump (PR #945, reimplemented). Kotlin
 * twin of the Swift Spo2ReTrace; the emitted line is byte-identical on both platforms.
 *
 * WHOOP 4.0 has the Blood O2 sensor and the historical decode already maps the raw red/IR PPG channels
 * (spo2_red@68 / spo2_ir@70 on the v24 layout), but NOOP nulls spo2Pct for WHOOP on purpose: computing a
 * calibrated % from the raw ADC needs the dense dual-wavelength waveform plus WHOOP's proprietary
 * calibration curve, and guessing it would manufacture a plausible-but-wrong health number - the exact
 * trap that withdrew the #194 PPG->HR attempt. The ONLY honest path to a reliable value is to find out
 * whether the strap already BANKS a computed SpO2 in a record field we have not mapped.
 *
 * So this dumps a handful of FULL historical records (hex) alongside their mapped SpO2 channels, log-only
 * and gated behind the Test Centre Connection mode, so an offline pass can correlate a byte (or the
 * red/IR pair) against the SpO2 % the WHOOP app shows for the same nights. Records dump whether or not
 * they carry SpO2 channels, so "the strap banks nothing" is provable too - in which case the honest
 * outcome is a capability label, never a fabricated number. NO user-facing SpO2 value comes from this.
 *
 * Pure formatter: no IO, no state, no em-dashes, no PII (a record is sensor payload; the serial never
 * rides in it).
 */
object Spo2ReTrace {

    /** Max records dumped per offload session, across all layout versions. A handful is enough for an
     *  offline correlation pass and keeps the strap log bounded; the Backfiller counter spans chunks and
     *  resets per session. */
    const val MAX_SAMPLES = 12

    /**
     * Max records dumped per DISTINCT layout version, so the budget cannot be spent entirely on the
     * layout we already understand.
     *
     * The dump used to take the first [MAX_SAMPLES] decodable records in arrival order. On a strap that
     * emits a dominant layout plus a rarer one, that spends the whole budget inside the first chunk on
     * the dominant layout - and the rare one is precisely the one still unmapped. The log would then
     * announce "historical records use layout vN" while carrying no bytes of vN at all: proof a thing
     * exists, with no material to work on it. Stratifying guarantees every layout the strap emits gets
     * samples, including one at 1% of traffic, and stops re-dumping a layout already at parity.
     */
    const val MAX_PER_VERSION = 3

    /**
     * Max records this dump may EXAMINE per session, separate from how many it may dump.
     *
     * The dump budget alone stopped bounding the work the moment [MAX_PER_VERSION] arrived. The loop's
     * outer guard counts DUMPS, so on a strap emitting one layout the per-version cap is reached at 3,
     * the dump count sticks below [MAX_SAMPLES] forever, and every later chunk re-decodes every frame to
     * rediscover a version already at cap. That is a full second decode of the whole offload, on top of
     * the one the extractor already did, for a dump that can never fire again.
     *
     * Bounding examinations instead keeps the stratified search working - several chunks' worth of
     * frames is plenty to turn up a layout at a few percent of traffic - while making the cost fixed
     * rather than proportional to offload length. The pre-stratification code examined barely more
     * frames than it dumped; this is the ceiling that restores that property.
     */
    const val MAX_EXAMINED = 512

    /**
     * One record's RE line: the mapped SpO2 channels + timestamp + layout version, then the FULL frame
     * hex (no prefix cap - a v24 record is ~84 B and the unmapped tail is exactly where a banked SpO2
     * would sit). Absent channels render "null" so a channel-less record still proves what it lacks.
     * Takes already-extracted numbers (ConnectionTrace's primitive style, matching the Swift signature);
     * the caller reads them off its decoded record map.
     *
     * [unix] is a LONG here where the other fields are Int: it is an unsigned u32 off the wire, and the
     * Swift twin's `Int` is 64-bit, so narrowing it on this side would render a NEGATIVE unix in the dump
     * past 2038-01-19 and break the byte-identical-line promise above. See `histU32` in HistoricalStreams.
     */
    fun recordLine(frame: ByteArray, version: Int?, unix: Long?, red: Int?, ir: Int?, skinRaw: Int?): String {
        val hex = frame.joinToString("") { String.format("%02x", it.toInt() and 0xFF) }
        fun f(v: Any?): String = v?.toString() ?: "null"
        return "spo2re v=${f(version)} unix=${f(unix)} red=${f(red)} ir=${f(ir)} " +
            "skinRaw=${f(skinRaw)} len=${frame.size} raw=$hex"
    }
}
