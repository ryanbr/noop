package com.noop.protocol

/**
 * Decoded stream rows — the durable, compact local record produced from parsed frames.
 *
 * Ported from the Swift reference (Streams.swift). `ts` is wall-clock unix seconds throughout.
 * These are pure data carriers with no Android/Room dependency; the data layer maps them onto
 * Room entities (HrSample, RrInterval, EventRow, BatterySample) as needed.
 */

/** A heart-rate sample at wall-clock unix seconds [ts]. */
data class HrSample(val ts: Int, val bpm: Int)

/**
 * WHICH sensor channel produced an R-R interval (#1071).
 *
 * A WHOOP strap has ONE beat source, so its rows carry no channel (null) and nothing here changes for
 * them. An Oura ring has more than one: the green-quality tag (0x80) and the SpO2 tag (0x6E) both
 * decode to R-R and both were stored, so the table held roughly TWO complete copies of every night —
 * not duplicate rows to de-duplicate, but the SAME heartbeats measured twice. Labelling the channel is
 * what lets scoring read one copy while both stay on disk as each other's cross-check.
 *
 * [code] is the DURABLE, cross-platform storage value for `rrInterval.srcChannel` and must stay in
 * lockstep with Swift `RRSourceChannel` — it is written to SQLite and crosses the `.noopbak` boundary,
 * so it is a wire format, not an implementation detail. Never renumber a case; only append.
 */
enum class RrSourceChannel(val code: Int) {
    /**
     * Oura 0x80 `green_ibi_quality_event` — the green-LED beat train, gated on the ring's own
     * `quality == 1` flag and a 300-2000 ms physiological window, running the whole night.
     */
    GREEN_QUALITY(1),

    /**
     * Oura 0x6E `spo2_ibi_and_amplitude_event` — the SpO2/red-channel beat train, on an 8 ms
     * quantisation grid with no quality gate, and present ONLY while SpO2 measurement is running.
     */
    SPO2_IBI(2),

    /** Oura 0x60 `ibi_and_amplitude_event` — the bit-packed IBI+amplitude family. */
    IBI_AMPLITUDE(3),

    /**
     * Oura 0x44 `ibi_event` — the SAME bit-packed layout family as 0x60, decoded by the same routine,
     * but a DIFFERENT tag on the wire.
     *
     * Split out (#1071 follow-up) because both tags used to stamp [IBI_AMPLITUDE], which made them
     * indistinguishable once stored: a capture showing that channel over-covering its own wall-clock
     * could not say whether one tag repeats beats or two tags report the same beats to each other. That
     * is the question the channel choice for scoring rests on, and no stored night could answer it.
     * Labelling only — both are read exactly as before.
     */
    IBI_BARE(4),
    ;

    companion object {
        /** The channel with this durable storage [code], or null for an unknown/absent one. */
        fun fromCode(code: Int?): RrSourceChannel? = entries.firstOrNull { it.code == code }
    }
}

/**
 * A single beat-to-beat R-R interval (ms) at wall-clock unix seconds [ts].
 *
 * [srcChannel] is the sensor channel that measured this beat, or null when the source does not
 * distinguish one (every WHOOP row, and every row written before the column existed). See
 * [RrSourceChannel].
 */
data class RrInterval(val ts: Int, val rrMs: Int, val srcChannel: RrSourceChannel? = null)

/**
 * A raw-ADC SpO2 sample at wall-clock unix seconds [ts]. Mirrors the Room `Spo2Sample` (red/ir)
 * and the Swift `SpO2Sample(red:ir:unit:)` shape so [StreamPersistence.toBatch] is a 1:1 widen.
 * Historically only the type-47 historical-offload path produced these; the live carrier now also
 * carries them so a single-value optical source (the Oura ring exposes ONE combined SpO2 reading,
 * not separate red/ir channels) can flow live. Such a source puts its raw value in [red] and
 * leaves [ir] at 0 (an unread channel, never a fabricated second reading).
 *
 * [unit] preserves the decoder's own scale tag (e.g. "raw_adc"/"raw"/"dc_raw") so a downstream
 * reader never assumes a percentage. This mirrors the unit fidelity the Swift `SpO2Sample` carries,
 * so the unit is not silently dropped on the Kotlin side at the carrier level. (The Room `Spo2Sample`
 * entity has no unit column yet; the carrier-level tag documents the convention until a migration
 * adds one.)
 */
data class Spo2Sample(val ts: Int, val red: Int, val ir: Int, val unit: String = "raw_adc")

/**
 * A skin-temperature sample at wall-clock unix seconds [ts]. Mirrors the Room `SkinTempSample` and
 * the Swift `SkinTempSample(raw:unit:)` shape.
 *
 * UNIT CONVENTION: [raw] is a device-native register value whose °C scale is FAMILY-SPECIFIC (#938) —
 * the 5/MG v18 @73 field is CENTI-degrees C (°C = raw / 100), but the WHOOP 4.0 v24 @72 field is a RAW
 * ADC on a different scale. The analytics reader (AnalyticsEngine / wornNightlySkinTempC, both platforms)
 * converts via [skinTempCelsius], which branches on [DeviceFamily]; running the 4.0 raw through /100 read
 * every worn night ~8 °C, below the 28 °C worn gate (issue #938). The live Oura path stores celsius * 100
 * (the 5/MG centidegree convention), so its raw decodes identically on Android and macOS. [unit] carries a
 * scale tag ("raw_adc") so the scale is never silently assumed. (The Room entity has no unit column yet;
 * this carrier-level tag plus this comment document the convention until a migration adds one.)
 */
data class SkinTempSample(val ts: Int, val raw: Int, val unit: String = "raw_adc")

/**
 * WHOOP 4.0 (v24) skin-temp mapping constants (#938). The single provisional slope + anchor live in ONE
 * place so the two-point-calibration TODO has an obvious home. Kept in lockstep with the Swift
 * `Whoop4SkinTemp`.
 */
object Whoop4SkinTemp {
    /** Worn resting raw register value the GLOBAL anchor pins (first reporter's steady worn baseline, ~826).
     *  Used as the fallback anchor when a device has too few in-band samples to learn its own (#938). */
    const val ANCHOR_RAW: Double = 826.0

    /** Physiological nocturnal wrist skin temperature the anchor raw maps to (°C). */
    const val ANCHOR_CELSIUS: Double = 33.0

    /** PROVISIONAL °C-per-raw-unit slope. TODO(#938): replace with the two-point anchor slope. */
    const val PROVISIONAL_SLOPE_C_PER_RAW: Double = 0.05

    // ── Per-device worn anchor (#938, second capture) ───────────────────────────────────────────────
    // The @72 skin-temp field is a raw ADC whose register OFFSET is per-device: two real 4.0 straps show
    // the IDENTICAL no-contact floor (~509) and 11-bit saturation ceiling (2047), but DIFFERENT worn
    // bands — the first strap ~760–865 (anchored ANCHOR_RAW=826), a second ~1100–1600 (nightly mean raw
    // ~1290). Under the single global anchor the second strap maps to 47–72 °C, so 100% of its samples
    // fail the 28–42 °C worn gate: kept=0, no nightly mean, no baseline, no skin-temp/illness signal. The
    // floor and ceiling agree across devices; only the worn offset differs → the anchor must be learned
    // per device from that device's own worn band. Safe because downstream use is deviation-from-own-
    // baseline (skinTempDevC) and the skin baseline is re-folded from the same scan window's nightly means
    // on every run, so a constant per-run offset cancels in the deviation.

    /** Lower raw bound of the plausible WORN band. Clear of the no-contact floor (~509–520 observed on
     *  two devices); banking stops at removal, so floor-and-below values are doff transients, never worn
     *  skin — excluding them keeps the learned anchor (a median of worn raws) from being dragged down. (#938) */
    const val WORN_MIN_RAW: Int = 550

    /** Upper raw bound of the plausible WORN band. Clear of the 11-bit register saturation (2047 observed
     *  pegged during device charging/fault) — a pegged raw is not a worn reading, so it must not enter the
     *  anchor median or the nightly mean. (#938) */
    const val WORN_MAX_RAW: Int = 2040

    /** Minimum in-band samples before a per-device anchor is trusted. Below this, callers fall back to the
     *  global reporter anchor ([ANCHOR_RAW]=826) so sparse-data behavior is byte-identical to today — a
     *  handful of stray worn raws must not define a device's whole ADC offset. (#938) */
    const val MIN_ANCHOR_SAMPLES: Int = 100

    /** Per-device worn anchor: median of the in-band raws across the caller's scan window, or null
     *  when fewer than [MIN_ANCHOR_SAMPLES] in-band samples exist (caller falls back to [ANCHOR_RAW]).
     *  Median (not mean) so doff/don transients and tails can't drag the anchor. (#938) */
    fun deviceAnchorRaw(raws: List<Int>): Double? {
        val inBand = raws.filter { it in WORN_MIN_RAW..WORN_MAX_RAW }.sorted()
        if (inBand.size < MIN_ANCHOR_SAMPLES) return null
        val n = inBand.size
        return if (n % 2 == 1) inBand[n / 2].toDouble()
        else (inBand[n / 2 - 1] + inBand[n / 2]) / 2.0
    }
}

/**
 * Convert a raw `skin_temp_raw` register value to °C, DEVICE-FAMILY-AWARE (#938).
 *
 * The two families bank skin temp on DIFFERENT scales, and applying one family's scale to the other is a
 * real decode bug: the historical `skin_temp_raw` field is a RAW ADC on the WHOOP 4.0 (v24 @72, "degC
 * computed server-side" per the schema) but a CENTIDEGREE register on the 5/MG (v18 @73). A single
 * family-blind `raw/100` sent every 4.0 night ~8 °C low, below the 28 °C worn gate, so skin temp and the
 * illness signal vanished (issue #938, reporter dpguglielmi's 4.0 capture).
 *
 * - [DeviceFamily.WHOOP5]: `raw / 100`. PROVEN on real 5/MG captures (Whoop5HistoricalTests: worn 3057 =
 *   30.6 °C, off-wrist 2247 = 22.5 °C). Unchanged.
 *
 * - [DeviceFamily.WHOOP4]: a single-anchor affine map. The 4.0 firmware (41.17.6.0) banks byte-72 at 1 Hz
 *   ON-WRIST ONLY, so there is ONE solid anchor and NO clean off-wrist room anchor from the strap. The
 *   reporter's doff/don capture gives a steady worn resting value of raw ~826 (worn steady ~830–865; a
 *   no-contact floor ~510–520 at removal, then banking stops). Under `/100` that reads ~8.3 °C — impossible
 *   for a wrist streaming a resting HR (~52 bpm). We anchor the worn value at a defensible nocturnal wrist
 *   skin temperature (33.0 °C ↔ the worn anchor raw) and carry a PROVISIONAL slope until a second
 *   calibration point exists. Because downstream use is a deviation from the user's OWN nightly baseline
 *   (skinTempDevC), the offset is what must be right to clear the absolute 28–42 °C worn gate + 20–42 °C
 *   baseline clamp; a slope error only rescales the deviation and stays directionally correct. All 4.0
 *   values APPROXIMATE.
 *
 *   PER-DEVICE ANCHOR (#938 second capture): [anchorRaw] is the raw that maps to 33.0 °C. It defaults to the
 *   global [Whoop4SkinTemp.ANCHOR_RAW] (826, first reporter's strap) so every existing caller is byte-
 *   identical, but the register OFFSET is per-device — a second real 4.0 strap shows the SAME floor (~509)
 *   and saturation (2047) yet a worn band of ~1100–1600 (nightly mean raw ~1290), which the global 826
 *   anchor maps to 47–72 °C (all samples fail the worn gate). The analytics caller therefore learns
 *   [anchorRaw] from the device's OWN worn median ([Whoop4SkinTemp.deviceAnchorRaw]) so the worn band lands
 *   in range; the constant offset cancels in the deviation-from-own-baseline the app consumes.
 *
 *   TODO(#938): replace the provisional slope with the exact two-point anchor once a second worn point at a
 *   markedly different ambient pins the ADC→°C transfer (including whether it is linear). Until then this is
 *   a defensible worn-range mapping, NOT a claimed-accurate absolute thermometer. Kept in lockstep with the
 *   Swift `skinTempCelsius(raw:family:anchorRaw:)`.
 */
fun skinTempCelsius(
    raw: Int,
    family: DeviceFamily,
    anchorRaw: Double = Whoop4SkinTemp.ANCHOR_RAW,
): Double = when (family) {
    DeviceFamily.WHOOP5 -> raw / 100.0
    DeviceFamily.WHOOP4 ->
        Whoop4SkinTemp.ANCHOR_CELSIUS +
            (raw - anchorRaw) * Whoop4SkinTemp.PROVISIONAL_SLOPE_C_PER_RAW
}

/**
 * A device event. [ts] is real RTC unix seconds (already wall-clock, never offset). [kind] is the
 * event label (e.g. "BATTERY_LEVEL(3)", "WRIST_OFF(10)"); [payload] carries any extra decoded
 * fields with `event`/`event_timestamp` removed.
 */
data class WhoopEvent(val ts: Int, val kind: String, val payload: Map<String, Any?>)

/**
 * #324 diagnostic record: a strap RTC-STATE event (RTC_LOST / BOOT / SET_RTC) that the #547 plausibility
 * gate dropped for an implausible own-timestamp. [rawTs] is the event's OWN dated value (unix seconds) - on
 * a future-dated strap this is the bad epoch the RTC jumped to, the single most useful signal for #324.
 * Mirrors the Swift `DroppedRtcEvent`.
 */
data class DroppedRtcEvent(val kind: String, val rawTs: Long) {
    companion object {
        /**
         * The RTC-state event kinds worth capturing when dropped. Kinds are formatted "NAME(n)" (e.g.
         * "RTC_LOST(13)"), matched by prefix - "BOOT" covers both BOOT and BOOT_REPORT.
         */
        fun isRtcStateKind(kind: String): Boolean =
            kind.startsWith("RTC_LOST") || kind.startsWith("SET_RTC") || kind.startsWith("BOOT")
    }
}

/**
 * A battery reading. [ts] is event RTC for BATTERY_LEVEL events, else the wall-clock reference.
 * [charging] is a real Boolean only when the frame reported it (BATTERY_LEVEL events); `null`
 * otherwise (command responses).
 */
data class BatterySample(
    val ts: Int,
    val soc: Double?,
    val mv: Int?,
    val charging: Boolean? = null,
)

/** The bundle of decoded series extracted from a batch of parsed frames. */
data class Streams(
    val hr: MutableList<HrSample> = mutableListOf(),
    val rr: MutableList<RrInterval> = mutableListOf(),
    val events: MutableList<WhoopEvent> = mutableListOf(),
    val battery: MutableList<BatterySample> = mutableListOf(),
    // spo2/skinTemp default empty so every existing WHOOP-path constructor/extractStreams call site is
    // unchanged; only a source that decodes these biometric signals live (the Oura ring) populates them.
    val spo2: MutableList<Spo2Sample> = mutableListOf(),
    val skinTemp: MutableList<SkinTempSample> = mutableListOf(),
) {
    companion object {
        val EMPTY: Streams get() = Streams()
    }
}

/**
 * Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
 * Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of `_to_wall`.
 */
private fun toWall(deviceTs: Int?, deviceClockRef: Int, wallClockRef: Int): Int? {
    if (deviceTs == null) return null
    return wallClockRef + (deviceTs - deviceClockRef)
}

/**
 * Turn parsed frames into datastore rows. Port of `interpreter.extract_streams`.
 *
 * HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also carries an
 * HR byte but streams alongside type-40 during raw collection, so routing both would double-count
 * HR for the same instants. CRC-failed and non-ok frames are skipped.
 */
fun extractStreams(parsed: List<ParsedFrame>, deviceClockRef: Int, wallClockRef: Int): Streams {
    val out = Streams()
    for (r in parsed) {
        if (!r.ok || r.crcOk == false) continue
        val p = r.parsed
        when (r.typeName) {
            "REALTIME_DATA" -> {
                val ts = toWall(p.intOrNull("timestamp"), deviceClockRef, wallClockRef)
                if (ts != null) {
                    p.intOrNull("heart_rate")?.let { bpm -> out.hr.add(HrSample(ts, bpm)) }
                    // Drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
                    p.intArrayOrNull("rr_intervals")?.let { rrs ->
                        for (rr in rrs) out.rr.add(RrInterval(ts, rr))
                    }
                }
            }

            "EVENT" -> {
                // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
                val ts = p.intOrNull("event_timestamp") ?: continue
                val kind = p.stringOrNull("event") ?: ""
                // BATTERY_LEVEL events (~every 8 min) carry SoC/mV/charging → the DENSE series.
                if (kind.startsWith("BATTERY_LEVEL")) appendBattery(out, ts, p)
                val payload = p.toMutableMap()
                payload.remove("event")
                payload.remove("event_timestamp")
                out.events.add(WhoopEvent(ts, kind, payload))
            }

            "COMMAND_RESPONSE" -> {
                // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
                appendBattery(out, wallClockRef, p)
            }

            else -> Unit
        }
    }
    return out
}

/**
 * Append a [BatterySample] from a parsed frame's `battery_pct`/`battery_mV`/`battery_charging`
 * fields (no-op when neither soc nor mv is present). `charging` is a real Boolean only when the
 * frame reported it (BATTERY_LEVEL events); command responses leave it null.
 */
internal fun appendBattery(out: Streams, ts: Int, p: Map<String, Any?>) {
    val soc = p.doubleOrNull("battery_pct")
    val mv = p.intOrNull("battery_mV")
    if (soc == null && mv == null) return
    val charging = p.intOrNull("battery_charging")?.let { it != 0 }
    out.battery.add(BatterySample(ts = ts, soc = soc, mv = mv, charging = charging))
}

// MARK: - Heterogeneous parsed-map accessors (mirror Swift's ParsedValue.intValue/etc.)

internal fun Map<String, Any?>.intOrNull(key: String): Int? = when (val v = this[key]) {
    is Int -> v
    is Long -> v.toInt()
    else -> null
}

internal fun Map<String, Any?>.doubleOrNull(key: String): Double? = when (val v = this[key]) {
    is Double -> v
    is Int -> v.toDouble()
    is Long -> v.toDouble()
    else -> null
}

internal fun Map<String, Any?>.stringOrNull(key: String): String? = this[key] as? String

@Suppress("UNCHECKED_CAST")
internal fun Map<String, Any?>.intArrayOrNull(key: String): List<Int>? = this[key] as? List<Int>
