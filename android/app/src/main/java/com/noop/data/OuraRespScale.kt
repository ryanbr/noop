package com.noop.data

/**
 * The ONE place the Oura ring's respiration rows are scaled, displayed and — deliberately — kept out
 * of scoring. Twin of Swift `WhoopStore.OuraRespScale`.
 *
 * `respSample` was built for a WHOOP 4.0's raw respiration ADC WAVEFORM (`resp_rate_raw@47`, 1 Hz,
 * unit `raw_adc`): a signal the stager runs a peak detector over. The ring sends no waveform at all;
 * its `0x6A sleep_period_info` record carries an already-computed RATE, one value per ~296 s window
 * (OURA_PROTOCOL.md s6.12). Two different physical quantities now share one table, so the row's OWNER
 * is what tells them apart — the same discipline `skinTempCelsius(raw, family)` already applies to
 * `skinTempSample`, which cannot be reused here because `DeviceFamily` has no Oura case by design
 * (#1086: a ring resolves to null, never to a coalesced whoop5).
 *
 * Everything that reads a respiration row therefore goes through one of the two entry points below —
 * [displayValue] to show it, [forScoring] to (not) score it — so a future reader is one grep away from
 * learning that the ring's rows are a rate, not a waveform.
 */
object OuraRespScale {

    /**
     * The unit tag a ring-sourced respiration row is stored at. `respSample` persists no unit column
     * (only `deviceId, ts, raw`) on either platform, so this documents the scale; the durable
     * discriminator is the deviceId, via [isRingRateStream]. Swift carries the same string on its
     * in-memory `RespSample.unit`; the Kotlin row shape ([RespRow]) has no unit field, which is an
     * in-memory asymmetry only — nothing about the STORED bytes differs.
     */
    const val UNIT_TAG = "milli_bpm"

    /**
     * MILLI-breaths-per-minute — the scale a ring respiration row is stored at.
     *
     * The wire field is a `u8` divided by 8, so every decodable value is an exact multiple of 0.125
     * bpm and `* 1000` is LOSSLESS (`raw == wireByte * 125`, integral for all 256 byte values). That
     * is why the scale is milli and not the codebase's usual centi: centi would land on `x.5` for half
     * the wire alphabet and need a rounding rule both platforms then have to agree about forever.
     * Sub-bpm resolution is not cosmetic here — the whole open question about this channel is a
     * residual of about -0.30 bpm, which rounding to whole bpm would erase.
     */
    const val MILLI_BPM_PER_BPM = 1000.0

    /**
     * Decoded breaths/min -> the durable `respSample.raw` integer. Exact for every wire value; the
     * rounding is a floating-point safety net, never a lossy step. PARITY: the Swift twin returns the
     * IDENTICAL integer (both round half-up, and the input is never negative).
     */
    fun milliBpm(breathsPerMin: Double): Int = Math.round(breathsPerMin * MILLI_BPM_PER_BPM).toInt()

    /** Durable `raw` -> breaths/min. */
    fun breathsPerMin(raw: Int): Double = raw / MILLI_BPM_PER_BPM

    /**
     * True when this device's `respSample` rows are the ring's per-window RATE (milli-bpm) rather than
     * a WHOOP raw ADC waveform.
     */
    fun isRingRateStream(deviceId: String): Boolean = DeviceBrandCatalog.isOura(deviceId)

    /**
     * The number to PLOT for one stored row: breaths/min for a ring, the raw ADC count verbatim for a
     * WHOOP. Without this the day chart's respiration track would plot a ring's 14.375 bpm as "14375"
     * beside a WHOOP's ADC counts and call both "Respiration".
     */
    fun displayValue(raw: Int, deviceId: String): Double =
        if (isRingRateStream(deviceId)) breathsPerMin(raw) else raw.toDouble()

    /**
     * The respiration rows a SCORING read is allowed to see: a ring's are REMOVED.
     *
     * This is a SHAPE refusal, not a trust one — it would hold even for a value nobody doubts, which
     * this one increasingly is not (the ring computes it; see `OuraSleepPeriodInfo`). `SleepStager`
     * buckets `respSample` into epochs and runs `respRateAndRRV` — a peak detector that assumes a
     * ~1 Hz raw WAVEFORM — over a rolling 5-minute window, and its RRV output steers the V1 recipe's
     * depth call. A ring row is a per-window RATE: neither a waveform nor 1 Hz, so what it would
     * contribute is noise wearing the shape of a signal. Feeding a rate to a peak detector is wrong
     * however good the rate is.
     *
     * Today the ring's ~296 s cadence puts fewer than the required 8 samples in any 5-minute window,
     * so the estimate would come back NaN anyway and staging is bit-identical either way (pinned by
     * `OuraRespScoringExclusionTest`). That is luck, not a guarantee: a later change to the record
     * cadence, or a decoder that expanded one record into per-second rows, would quietly switch the
     * path on. Refuse it by provenance instead, where the reason stays legible.
     *
     * There is NO second door. These rows are instrumentation: stored, plotted ([displayValue]) and
     * nothing else. In particular nothing derives `dailyMetric.respRateBpm` from them — that is the
     * SCORED slot (the recovery resp term, the illness signal), and CLAUDE.md's #194 rule reserves it:
     * a channel that already sits at its vendor ceiling gets instrumented beside the incumbent, not made
     * the default and not wired to a downstream gate. If a future change wants to score them, it needs
     * its own evidence and its own review — not a quiet extra caller of this file.
     */
    fun forScoring(rows: List<RespSample>, deviceId: String): List<RespSample> =
        if (isRingRateStream(deviceId)) emptyList() else rows
}
