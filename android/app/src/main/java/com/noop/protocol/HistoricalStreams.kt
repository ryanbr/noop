package com.noop.protocol

import com.noop.data.BatteryRow
import com.noop.data.DynAccelDiag
import com.noop.data.EventEntry
import com.noop.data.GravityRow
import com.noop.data.HrRow
import com.noop.data.PpgHrRow
import com.noop.data.PpgWaveformRow
import com.noop.data.RespRow
import com.noop.data.RrRow
import com.noop.data.SkinTempRow
import com.noop.data.SleepStateRow
import com.noop.data.V18AuxRow
import com.noop.data.V18AuxSlot
import com.noop.data.Spo2Row
import com.noop.data.StepRow
import com.noop.data.StreamBatch
import com.noop.data.StreamPersistence

/**
 * #891: packet types an offload legitimately carries that [extractHistoricalStreams] has no rows for, so
 * reaching the `else` branch is expected rather than a finding. Both decode to zero rows BY DESIGN —
 * CONSOLE_LOGS is strap-side debug text, METADATA is envelope bookkeeping — and counting them on every sync
 * would bury the one signal [com.noop.data.StreamBatch.unhandledPacketTypes] exists to surface. Nothing else
 * is excluded, including named-but-unhandled types like `HISTORICAL_IMU_DATA_STREAM(52)`: those are exactly
 * the interesting ones. Keep in lockstep with Swift's `expectedUnhandledHistoricalTypes`.
 */
val EXPECTED_UNHANDLED_HISTORICAL_TYPES: Set<String> = setOf("METADATA", "CONSOLE_LOGS")

/*
 * Historical (offload) decode for the WHOOP 4.0 — the type-47 HISTORICAL_DATA path.
 *
 * Faithful port of three macOS Swift pieces:
 *   - the `postHooks["historical_data"]` decoder (Packages/WhoopProtocol/.../PostHooks.swift),
 *     which decodes a type-47 record's biometric block using the per-version field table baked
 *     into whoop_protocol.json (V24/V12 = full DSP block; V5/V7/V9 = generic HR/RR only),
 *   - `classifyHistoricalMeta` (Packages/WhoopProtocol/.../HistoricalMeta.swift), the METADATA
 *     classifier the offload state machine uses, and
 *   - `extractHistoricalStreams` (Packages/WhoopProtocol/.../HistoricalStreams.swift), which turns
 *     a batch of parsed offload frames into datastore rows.
 *
 * WHY this lives here and not in [Framing.parseFrame]: the live [Framing] decoder deliberately
 * does NOT decode type-47 (it only handles REALTIME_DATA / EVENT / COMMAND_RESPONSE / METADATA),
 * exactly like the Swift live path. Historical records are decoded only during a backfill, so the
 * type-47 decoder is kept on the offload path to mirror the Swift split precisely.
 *
 * The frame envelope is identical to Framing.kt's: [0]=0xAA, [1..2]=len u16 LE, [3]=crc8(len),
 * [4]=packet type (47 here), [5]=record VERSION (NOT a sequence byte for type-47 — the schema
 * note says "Version = seq byte (frame[5])"), [6..]=record. Field offsets in the version table
 * are FRAME-ABSOLUTE (= openwhoop data offset + 7). All multi-byte values are little-endian.
 */

// MARK: - plausible-timestamp bounds (#547)

/**
 * Lowest unix-second a real WHOOP record can carry (2023-11). A bad strap clock/flash (pikapik, #547)
 * emits records whose `unix` decodes to scattered garbage — far-past (year 2024/2019/…), a year-2027
 * spike (1_827_642_881), and even a FUTURE date. Those land in the DB verbatim and pollute the
 * day-windowed analytics (one ~12 h block re-attributed to every day; a future row surfacing as
 * "last night · 12 Jul"). Reuses the same 1.7 B floor already used to validate GET_DATA_RANGE words
 * (WhoopBleClient.dataRangeNewestUnix). Below this → drop the record.
 */
const val MIN_PLAUSIBLE_UNIX: Long = 1_700_000_000L

/**
 * How far past the offload wall-clock a record may be stamped (#547). A historical record can NEVER
 * post-date its own capture, so anything more than one day ahead of "now" is a bad-clock artefact —
 * drop it. One day of slack absorbs benign timezone/RTC skew without admitting a future-dated row.
 */
const val FUTURE_MARGIN: Long = 86_400L

/**
 * SESSION-RELATIVE slack (#547): how far OUTSIDE the strap's own GET_DATA_RANGE oldest/newest markers a
 * record may still be stamped before it's treated as wandering-clock pollution. The strap reports its
 * banked history span [oldest, newest] for THIS sync; a real record cannot predate the oldest banked marker
 * nor post-date the newest by more than benign skew, so a record dated MONTHS off the strap's OWN window is
 * a bad-clock artefact even when it clears the absolute 2023-11 floor (e.g. a 2024-12-25 record against a
 * 2026 strap window). 7 days absorbs marker jitter / a still-banking newest edge / DST while still catching
 * the months-off garbage. Kept in lockstep with Swift `HistoricalStreams.swift` SESSION_RANGE_MARGIN.
 */
const val SESSION_RANGE_MARGIN: Long = 7L * 86_400L

/**
 * #520: the stillness cut for the `dynamic_acceleration` diagnostic. Borrowed from
 * `SleepStager.gravityStillThresholdG` (0.01 g) as a REFERENCE point, not because the two measure the same
 * thing — the stager thresholds a per-sample DELTA between consecutive gravity vectors, while this field is
 * an ABSOLUTE gravity-removed magnitude at one instant. Both approach 0 when the wrist is still, so the same
 * cut is a sensible starting point, but a matching still-fraction would not prove the two are equivalent.
 * Duplicated as a literal rather than imported — this is the wire layer and must not depend on the analytics
 * layer. If the stager's constant moves, move this one with it. Twin of Swift `dynAccelStillThresholdG`.
 */
const val DYN_ACCEL_STILL_THRESHOLD_G: Double = 0.01

// MARK: - little-endian readers (null when out of range; mirror PostHooks.swift u8/u16/u32/f32)

private fun ByteArray.histU8(off: Int): Int? = if (off + 1 <= size) this[off].toInt() and 0xFF else null

private fun ByteArray.histU16(off: Int): Int? =
    if (off + 2 <= size) (this[off].toInt() and 0xFF) or ((this[off + 1].toInt() and 0xFF) shl 8) else null

/** Signed little-endian i16 (two's complement) -> Int. null when out of range. Mirrors Swift `readI16`. */
private fun ByteArray.histI16(off: Int): Int? {
    if (off + 2 > size) return null
    val u = (this[off].toInt() and 0xFF) or ((this[off + 1].toInt() and 0xFF) shl 8)
    return if (u >= 0x8000) u - 0x10000 else u
}

private fun ByteArray.histU32(off: Int): Long? {
    if (off + 4 > size) return null
    return (this[off].toLong() and 0xFFL) or
        ((this[off + 1].toLong() and 0xFFL) shl 8) or
        ((this[off + 2].toLong() and 0xFFL) shl 16) or
        ((this[off + 3].toLong() and 0xFFL) shl 24)
}

/**
 * Re-widen a 32-bit value that was narrowed to `Int` back into the UNSIGNED 0..4294967295 domain.
 *
 * Kotlin's `Int` is 32-bit and Swift's is 64-bit, so any u32 with bit 31 set (`record_index` late in a
 * strap's life, `unknown_f32_113` whenever the float is negative) reads NEGATIVE on this side and
 * POSITIVE on Swift's from byte-identical input. Anywhere such a value crosses into a stored or compared
 * number rather than staying as raw bytes, it goes through here first so the two platforms agree.
 */
private fun Int?.asU32(): Long? = this?.toLong()?.and(0xFFFF_FFFFL)

/**
 * IEEE-754 float32 LE -> Double (exact, NO rounding). null when out of range.
 * Port of PostHooks.swift `f32`: read the 4 bytes as a u32 bit-pattern, reinterpret as Float,
 * then widen to Double. Kotlin's `Float.fromBits(Int)` is the exact analog of
 * `Float(bitPattern:)`; widening Float -> Double is value-preserving.
 */
private fun ByteArray.histF32(off: Int): Double? {
    val bits = histU32(off) ?: return null
    return Float.fromBits(bits.toInt()).toDouble()
}

/**
 * One decoded type-47 field-layout VERSION. Frame-absolute offsets, lifted verbatim from the
 * `HISTORICAL_DATA.versions` table in whoop_protocol.json. `rrFirstOff` is where the (up to 4)
 * u16 R-R intervals begin. A null DSP-block offset means that field is absent for the version.
 */
private data class HistVersion(
    val unixOff: Int,
    val hrOff: Int,
    val rrCountOff: Int,
    val rrFirstOff: Int,
    // Full DSP biometric block (V24 / V12 only); null on the generic V5/V7/V9 records.
    val spo2RedOff: Int? = null,
    val spo2IrOff: Int? = null,
    val skinTempRawOff: Int? = null,
    val respRateRawOff: Int? = null,
    val gravityXOff: Int? = null,
    val gravityYOff: Int? = null,
    val gravityZOff: Int? = null,
)

/**
 * V24 layout (this WHOOP 4.0; verified on 762 device records per the schema note). V12 shares the
 * exact same DSP layout ("ref":"24"). Offsets are FRAME-ABSOLUTE, copied from whoop_protocol.json.
 */
private val HIST_V24 = HistVersion(
    unixOff = 11,
    hrOff = 21,
    rrCountOff = 22,
    rrFirstOff = 23,
    spo2RedOff = 68,
    spo2IrOff = 70,
    skinTempRawOff = 72,
    respRateRawOff = 80,
    gravityXOff = 40,
    gravityYOff = 44,
    gravityZOff = 48,
)

/** Generic HR/RR-only record (V5; V7/V9 share it via "ref":"5"). No DSP sensor block. */
private val HIST_V5 = HistVersion(
    unixOff = 11,
    hrOff = 21,
    rrCountOff = 22,
    rrFirstOff = 23,
)

/** Resolve a record version (frame[5]) to its field layout, or null if the layout is unmapped. */
private fun histVersionLayout(version: Int): HistVersion? = when (version) {
    24, 12 -> HIST_V24
    5, 7, 9 -> HIST_V5
    else -> null
}

/**
 * Decode a single type-47 HISTORICAL_DATA frame into the same flat parsed-map keys the Swift
 * `postHooks["historical_data"]` produces. Returns null when the frame is not a valid type-47
 * record (wrong SOF/too short/failed CRC/unmapped version) — callers skip those, matching the
 * Swift `if !r.ok || r.crcOK == false { continue }` + unmapped-layout guard.
 *
 * Keys emitted (only when present in the frame): `hist_version`, `unix`, `heart_rate`, `rr_count`,
 * `rr_intervals` (List<Int>), `spo2_red`, `spo2_ir`, `skin_temp_raw`, `resp_rate_raw`, `gravity_x`,
 * `gravity_y`, `gravity_z`. These match the keys [extractHistoricalStreams] reads.
 */
fun decodeHistorical(frame: ByteArray, family: DeviceFamily = DeviceFamily.WHOOP4): Map<String, Any?>? {
    if (frame.size < 8 || frame[0] != 0xAA.toByte()) return null

    // Integrity gate: validate the envelope + CRC32 via the shared Framing parser. We reuse its
    // crcOk so a garbled/forged offload frame can never inject rows. parseFrame leaves type-47's
    // `parsed` empty (the live decoder skips type-47), so we decode the record ourselves below.
    val checked = Framing.parseFrame(frame, family)
    if (!checked.ok || checked.crcOk == false) return null

    // WHOOP 5.0/MG has the longer puffin envelope (record @8), so its v18 layout is decoded separately
    // at its own absolute offsets (port of Swift decodeWhoop5Historical). WHOOP 4 below is unchanged.
    if (family == DeviceFamily.WHOOP5) return decodeWhoop5Historical(frame)
    if (family != DeviceFamily.WHOOP4) return null
    if (frame[4].toInt() and 0xFF != PacketType.HISTORICAL_DATA.rawValue) return null

    val version = frame[5].toInt() and 0xFF

    // WHOOP 4.0 **v25** historical layout (issue #30). RE'd from 45 real records on v1.92+ full dumps
    // (faklei / FrankdeJong / tchoucker15): an 84-byte record with `unix` @11 (u32 LE) and the DSP
    // gravity vector @73/75/77 as 3×i16 LE / 16384 — |gravity| ≈ 1 g on 45/45 records. Bytes 23-72 are
    // the optical PPG waveform; per-second HR is NOT stored in v25 (PPG-derived), so this yields motion
    // + timestamp — exactly what the sleep stager gates on. Additive + version-gated; v18/v24/v26
    // untouched. Mirrors Swift PostHooks "historical_data" v25 case.
    if (version == 25 && frame.size >= 79) {
        val out = LinkedHashMap<String, Any?>()
        out["hist_version"] = version
        frame.histU32(11)?.let { out["unix"] = it.toInt() }
        fun grav(off: Int): Double? {
            val u = frame.histU16(off) ?: return null
            return (if (u >= 32768) u - 65536 else u).toDouble() / 16384.0   // i16 LE, ±2 g full-scale
        }
        val gx = grav(73); val gy = grav(75); val gz = grav(77)
        if (gx != null && gy != null && gz != null) {
            val mag = Math.sqrt(gx * gx + gy * gy + gz * gz)
            if (mag in 0.5..1.5) {   // a real DSP orientation vector is ~1 g; reject garbage
                out["gravity_x"] = gx; out["gravity_y"] = gy; out["gravity_z"] = gz
            }
        }
        out["rr_intervals"] = ArrayList<Int>()
        return out
    }

    // Unmapped firmware version: instead of dropping the whole record (→ no HR/R-R/gravity → no sleep,
    // and on Android this previously meant ZERO data for a strap on newer firmware — the macOS
    // issue-#30 fix that never reached Android; the likely cause of #77 on some WHOOP 4 straps), fall
    // back to the canonical v24 DSP layout. Firmware versions overwhelmingly share it (V12 == V24). We
    // accept the fallback ONLY if it decodes to physically-real data (validated at the end) so a wrong
    // layout can never store garbage. Mapped versions are unaffected. Mirrors Swift PostHooks
    // "historical_data" (PostHooks.swift). (#30 / #77)
    val mapped = histVersionLayout(version)
    val usingFallback = mapped == null
    val layout = mapped ?: HIST_V24

    val out = LinkedHashMap<String, Any?>()
    out["hist_version"] = version

    // unix is the record's REAL unix seconds (no clock offset needed for type-47).
    frame.histU32(layout.unixOff)?.let { out["unix"] = it.toInt() }
    frame.histU8(layout.hrOff)?.let { out["heart_rate"] = it }
    val rrn = frame.histU8(layout.rrCountOff) ?: 0
    out["rr_count"] = rrn

    // Up to 4 R-R intervals (u16, ms). Drop 0 ms placeholders, matching PostHooks (`v != 0`).
    val rrVals = ArrayList<Int>()
    for (i in 0 until minOf(rrn, 4)) {
        val v = frame.histU16(layout.rrFirstOff + i * 2)
        if (v != null && v != 0) rrVals.add(v)
    }
    out["rr_intervals"] = rrVals

    // Full DSP block (V24/V12 only). Each read is guarded; absent fields are simply not emitted.
    layout.spo2RedOff?.let { off -> frame.histU16(off)?.let { out["spo2_red"] = it } }
    layout.spo2IrOff?.let { off -> frame.histU16(off)?.let { out["spo2_ir"] = it } }
    layout.skinTempRawOff?.let { off -> frame.histU16(off)?.let { out["skin_temp_raw"] = it } }
    layout.respRateRawOff?.let { off -> frame.histU16(off)?.let { out["resp_rate_raw"] = it } }
    layout.gravityXOff?.let { off -> frame.histF32(off)?.let { out["gravity_x"] = it } }
    layout.gravityYOff?.let { off -> frame.histF32(off)?.let { out["gravity_y"] = it } }
    layout.gravityZOff?.let { off -> frame.histF32(off)?.let { out["gravity_z"] = it } }

    // Validate the v24-layout guess for an unmapped version: gravity is the DSP-separated orientation
    // vector, so |gravity| ≈ 1 g on a real record regardless of motion, and HR is physiological. If the
    // guess doesn't fit this firmware the decoded values are random — drop the record rather than store
    // garbage (same outcome as before the fallback). Mapped versions skip this entirely. (#30 / #77)
    if (usingFallback) {
        val gx = (out["gravity_x"] as? Double) ?: Double.NaN
        val gy = (out["gravity_y"] as? Double) ?: Double.NaN
        val gz = (out["gravity_z"] as? Double) ?: Double.NaN
        val mag = Math.sqrt(gx * gx + gy * gy + gz * gz)
        val hr = (out["heart_rate"] as? Int) ?: 0
        if (!(mag in 0.8..1.2 && hr in 25..230)) return null
    }

    return out
}

/**
 * WHOOP 5.0/MG type-47 "v18" historical decode. The puffin envelope is longer, so the record starts at
 * byte 8 (type@8, version@9) and fields sit at their WHOOP5-ABSOLUTE offsets — NOT the WHOOP4 V24 layout
 * shifted by +4 (that decodes to garbage on v18). Offsets verified against real worn/off-wrist frames
 * (the data is the arbiter): unix@15, hr@22, rr@24+, gravity@45/49/53, and per-second fields each gated
 * to a physical range so a wrong offset on unmapped firmware stores nothing; further fields (aux thermal
 * @69/71, status words @75/77/79, the @81 band-flag nibbles, aux byte @82) are read off the same real
 * frames. Mirrors Swift `decodeWhoop5Historical`, and emits the same keys [extractHistoricalStreams] reads.
 * v26 (PPG) and other
 * versions aren't stored, so they return null here (skipped), matching the Swift raw-region treatment.
 */
private fun decodeWhoop5Historical(frame: ByteArray): Map<String, Any?>? {
    if (frame.histU8(8) != PacketType.HISTORICAL_DATA.rawValue) return null
    val version = frame.histU8(9) ?: return null
    if (version != 18) return null

    val out = LinkedHashMap<String, Any?>()
    out["hist_version"] = version
    // @11 a per-record counter: +1 every record, independent of unix (advances across gaps); seen on
    // two straps. @11 is only the low byte — read the full u32 LE.
    frame.histU32(11)?.let { out["record_index"] = it.toInt() }
    frame.histU32(15)?.let { out["unix"] = it.toInt() }
    frame.histU8(22)?.let { out["heart_rate"] = it }
    val rrn = frame.histU8(23) ?: 0
    out["rr_count"] = rrn
    val rrVals = ArrayList<Int>()
    for (i in 0 until minOf(rrn, 4)) {
        val v = frame.histU16(24 + i * 2)
        if (v != null && v != 0) rrVals.add(v)
    }
    out["rr_intervals"] = rrVals
    // Bytes adjacent to the HR/R-R fields: @36 is a FLAG byte and @37 a duplicate heart rate — not the
    // two halves of one fixed-point HR; the others are carried raw (meaning not pinned).
    frame.histU8(33)?.let { out["cardiac_flags"] = it }
    // @36 was read as the low half of a u16 `hr_fixed_8_8` with bpm = value/256. Over 18,650 real v18
    // records that model is false. Bit 4 is NEVER set (0/18,650 — a genuine 8.8 fraction sets it ~50% of
    // the time, and it is the ONLY bit never set); 95.02% of values land in 0x80–0x8F where uniform would
    // be 6.25%, over just 40 distinct values, sd 26.5 vs 73.9 for a uniform byte. The "corr 0.989 with
    // hr@22" that justified the old name was circular — the u16 is literally hr@22 (carried at @37) plus
    // this flag byte over 256, so the residual is a flat +0.504 ± 0.189. Bit 7 reads as a VALIDITY bit:
    // with it clear (n=748) rr_count == 0 in 70.32% of records vs 19.82% with it set, and the @108/@109
    // sentinel fires in 69.65% vs 1.32%. The remaining bits are unpinned, so the byte ships raw.
    frame.histU8(36)?.let { out["hr_quality_flags"] = it }   // bit7 = valid, bit4 never set
    // @37 duplicates heart_rate@22 — equal in 99.575% of records (18,523/18,602), differing only by
    // -6…+2, and it only tracks HR while @36 bit7 is set (99.74% exact vs 94.12% when clear).
    frame.histU8(37)?.let { out["heart_rate_alt"] = it }
    frame.histU16(38)?.let { out["rr_packed"] = it }
    frame.histU8(40)?.let { out["cardiac_status"] = it }
    frame.histF32(45)?.let { out["gravity_x"] = it }
    frame.histF32(49)?.let { out["gravity_y"] = it }
    frame.histF32(53)?.let { out["gravity_z"] = it }

    // Per-second fields beyond HR/gravity, each gated to a physically-real range (cross-validated
    // worn vs off-wrist). Optical/perfusion @69/71 still doesn't decode consistently and is left raw.
    frame.histF32(41)?.let { if (it.isFinite() && it in 0.0..8.0) out["dynamic_acceleration"] = it }
    frame.histU16(57)?.let { out["step_motion_counter"] = it }
    // @59 a per-step cadence-like byte (never 0; lower when moving faster). Raw — no unit asserted.
    frame.histU8(59)?.let { out["step_cadence"] = it }
    frame.histU8(63)?.let { if (it in 0..2) out["motion_wear_quality"] = it }
    // @63 also reads as a small validated ACTIVITY-CLASS enum (community finding, #316): 0=still, 1=walk,
    // 2=run, 0xFF=invalid. A lightweight, no-cloud per-record activity readout that rides alongside the
    // step counter. Only the four known codes are surfaced — anything else (incl. 0xFF) stores nothing so
    // an unmapped firmware can't inject garbage.
    frame.histU8(63)?.let { if (it == 0 || it == 1 || it == 2) out["activity_class"] = it }
    // Auxiliary thermal readings adjacent to the main skin-temperature register, read off a digital
    // skin-temperature sensor. Carried raw; °C = raw/10. Signed i16, gated to a plausible thermal range
    // so a wrong offset on an unmapped layout stores nothing rather than garbage.
    frame.histI16(69)?.let { if ((it / 10.0) in 0.0..60.0) out["temp_aux_1_raw"] = it }
    frame.histI16(71)?.let { if ((it / 10.0) in 0.0..60.0) out["temp_aux_2_raw"] = it }
    // skin temp: raw u16 (the store keeps it raw, /100 at display). Gate on a plausible thermal range:
    // °C = raw/100 — gives physiological worn temperatures (median ~34 °C across two straps), whereas a
    // /128 reading lands at a non-physiological ~27 °C. The gate is only a garbage filter; the absolute
    // scale lives in the consumer.
    frame.histU16(73)?.let { if ((it / 100.0) in 5.0..45.0) out["skin_temp_raw"] = it }
    // @75 a 16-bit status word; NOT a deep-sleep marker (low nibble 0 across observed records, equal
    // awake/asleep — the "80=deep" reading is a misread).
    frame.histU16(75)?.let { out["status_word"] = it }
    // @77 / @79 two further 16-bit status words adjacent to @75; carried raw, meaning not pinned.
    frame.histU16(77)?.let { out["status_word_1"] = it }
    frame.histU16(79)?.let { out["status_word_2"] = it }
    // @81 packs several band flags into one byte. High nibble (bits 4-5) tracks a scored night:
    // 0 wake / 1 still / 2 asleep / 3 up. bits 2-3 a wake-quality field; bits 0-1 an on-wrist flag.
    // Deep/REM/light are computed off-band, not here.
    frame.histU8(81)?.let {
        out["sleep_state"] = (it shr 4) and 3
        out["wake_quality"] = (it shr 2) and 3
        out["onwrist"] = it and 3
        // The WHOLE byte, unmasked. The three fields above are the nibbles this project has interpreted;
        // this key is the strap's own byte VERBATIM so all 8 bits survive to storage — including b6-7,
        // which read 0 across every capture held here and therefore have no interpretation at all yet. A
        // per-nibble store would make those bits permanently unrecoverable, because the strap trims its
        // banked history the moment an offload is acked. Instrumentation only: nothing scores this.
        out["sleep_state_byte"] = it
    }
    // @82 a single raw byte adjacent to the flag byte; nonzero only while sleep_state = asleep.
    // #103 SpO2 candidate: a decompile-sourced decode (gen5.rs `spo2_pct`, reimplemented here as a
    // protocol fact with attribution, like the other RE work) reads @82 (= inner 74) as a strap-computed
    // SpO2 % scalar, tri-mode: 70–100 = a real %, bit-7 values (0x80/0xA0…) = saturation sentinels,
    // other sub-70 nonzero = diagnostic codes, populated only during sleep. Evidence is SPLIT: an
    // 8-night independent validation with real spread (corr +0.99, ~0.4 %/night) meets the cross-night
    // bar, but the two capture nights checked on the original #103 device moved OPPOSITE to the app
    // value — unresolved. So this ships as an INSTRUMENTATION CANDIDATE only: the in-band value is
    // decoded and surfaced raw for multi-device correlation against the app's own nightly SpO2. It must
    // never back a shipped SpO2 metric, never write spo2Pct/spo2_red/spo2_ir, and never feed a
    // downstream gate (recovery/illness) until the cross-device contradiction is resolved. Mirror of
    // Swift Interpreter (@82 block).
    frame.histU8(82)?.let {
        out["aux_byte_82"] = it
        if (it in 70..100) out["spo2_candidate_82"] = it
    }
    // ── The @82–119 "optical/tail" span, reverse-engineered over 18,602 real v18 records (a third strap's
    // overnight R22 stream) + cross-checked on two fixture devices: it is ~85% ZERO PADDING (83–103,
    // 110–112, 117–119 constant 0x00; @104 a constant 0x01 marker). Only the byte pairs @106/@107 and
    // @108/@109 plus the @113 float carry data, and none is physiologically ground-truth-named (no
    // SpO2/respiratory reference), so each is carried RAW. Mirror of Swift decodeWhoop5Historical.
    //
    // @106/@107 were read as ONE u16 LE. They cannot be: across 18,599 consecutive-second pairs the HIGH
    // byte changed while the LOW byte stayed frozen in 3,514 of them (18.89%), and the corpus holds ZERO
    // low-byte wrap events — a real u16 cannot step its high byte without a carry. The apparent u16 deltas
    // are exactly 256·Δ@107 + Δ@106 (they cluster at 0, ±1, ±255, ±256, ±257, ±513). These are two
    // correlated but independent u8 channels (corr +0.73; they move in OPPOSITE directions in 5.8% of the
    // pairs where both move), structurally parallel to the @108/@109 pair. 0 — not 128 — is the off-wrist
    // marker: both bytes read 0 in exactly the 8 records that also carry HR == 0, while 128 occurs
    // unremarkably while worn (@106 in 10 records, @107 in 103). Magnitudes are device-specific (102–255 /
    // 119–247 on the R22 strap vs 20–66 / 34–81 on another), so no scale is asserted.
    frame.histU8(106)?.let { out["optical_baseline_a"] = it }
    frame.histU8(107)?.let { out["optical_baseline_b"] = it }
    // @108/@109 a tightly-coupled PAIR (equal ~24% of records, within ±2 ~80%). 128 is a RECORD-level
    // sentinel, not a per-channel one: amp_a == 128 in 757 records and amp_b == 128 in 757 — the SAME 757,
    // never one without the other. They do NOT rise with HR; that reading (~34 at HR 40–49 → ~58 at 80–89)
    // was an averaging artifact of counting the 128 sentinel as a number, and with sentinels excluded the
    // trend is flat-to-declining (32.45 → 29.52). The real monotone trend is with MOTION: ~32.7 while
    // still (dyn_acc < 0.02 g) → 37.4 at 0.05–0.2 g. Amplitude/quality-like; carried raw, NOT named
    // SpO2/perfusion without on-device ground truth.
    //
    // The sentinel itself is a usable per-second SIGNAL-QUALITY flag: it fires on 4.02% of worn seconds
    // and predicts the band's own beat-detection failure (rr_count == 0) at 79.44% vs 19.40% — a 4.09×
    // lift that SURVIVES holding motion constant (4.11× within dyn_acc < 0.009 g), where shuffled and
    // circular-shift nulls all sit at ~1.0×. It is the same quality condition @36 bit7 reports.
    frame.histU8(108)?.let { out["optical_amp_a"] = it }
    frame.histU8(109)?.let { out["optical_amp_b"] = it }
    // @113 a float32 (observed range ~ -5.3..0, 0 = unset); purpose unknown, carried raw. EMPIRICAL.
    frame.histF32(113)?.let { if (it.isFinite()) out["unknown_f32_113"] = it }
    // PROVENANCE / lossless-tail note (A10): this decoder maps only the fields above; bytes past @113
    // up to the CRC32 trailer are NOT consumed here and are NOT a per-field loss. The Backfiller hands
    // the VERBATIM frame (header..tail..CRC) to [RawHistoryArchive] for any record it can't turn into
    // rows, and to the raw-capture batch when that research toggle is on, so the untouched trailing
    // bytes survive on disk for a future re-decode. The `frame` ByteArray itself is never truncated by
    // this function, so a caller that retains it keeps the full record. VERIFIED fields (physiologically
    // cross-checked vs the strap's live 2A37 HR / |gravity|~1g): unix, heart_rate, rr, gravity, skin_temp.
    // EMPIRICAL / not-pinned: status words, aux bytes, unknown_f32_113.
    return out
}

/**
 * WHOOP 5.0/MG type-47 **layout v26** PPG-waveform decode (#156). Mirror of Swift
 * `decodeWhoop5HistoricalV26`. v26 is NOT a per-second biometric summary like v18 — it is a 24 Hz
 * optical PPG buffer: **24 little-endian i16 samples at frame bytes [27:75]**, one record per second,
 * with the record's own unix u32 LE @15 (the v18 slot). WHOOP stores no per-second HR in v26 (HR is
 * PPG-derived on-device), so the win here is the waveform itself, which [PpgHr] turns into HR.
 *
 * Returns the record's wall-second [unix] and the 24 raw ADC [samples], or null when the frame is not
 * a v26 HISTORICAL_DATA record or the waveform region is truncated. The bytes before [27] (header +
 * the raw per-burst counter @21 — `burst_index`, NOT a channel id; PR#553) and the footer after [75]
 * are intentionally not mapped here: the Android offload path needs only [unix] + the waveform for HR.
 */
private data class V26Record(val unix: Int, val samples: List<Int>)

private fun decodeWhoop5HistoricalV26(frame: ByteArray): V26Record? {
    if (frame.histU8(8) != PacketType.HISTORICAL_DATA.rawValue) return null
    if (frame.histU8(9) != 26) return null
    val unix = frame.histU32(15)?.toInt() ?: return null
    val samples = ArrayList<Int>(24)
    var off = 27
    while (off < 75) {
        val v = frame.histI16(off) ?: break
        samples.add(v)
        off += 2
    }
    if (samples.isEmpty()) return null
    return V26Record(unix = unix, samples = samples)
}

/**
 * The HISTORICAL_DATA (type-47) record frames in [rawFrames] that genuinely FAIL to decode — a CRC
 * failure, or an unmapped firmware layout whose v24 plausibility gate (see [decodeHistorical]) also
 * rejects it. These are exactly the record frames [extractHistoricalStreams] silently drops: their
 * biometric payload would otherwise be lost forever once the strap trims the acked history.
 *
 * EXCLUDED (decode to zero rows BY DESIGN, never "lost" data — must NOT be counted):
 *   - CONSOLE_LOGS (type-50) frames — the strap's own diagnostics text channel. On WHOOP 4.0 the
 *     inner type byte is frame[4]; type-50 (0x32) is not type-47 so the family-aware type guard below
 *     already skips it. On WHOOP 5/MG the inner type byte is at frame[8].
 *   - WHOOP 5/MG v26 (raw PPG) records — deliberately unstored (see [decodeWhoop5Historical]), known
 *     and skipped by design, not lost.
 *   - Non-record frames (METADATA, EVENT, etc.) — not type-47, so never returned.
 *
 * The Backfiller archives these raw bytes BEFORE acking the trim, so a user on an unmapped firmware
 * keeps their only copy (for a later release that maps the layout, and as the corpus that mapping
 * needs) instead of permanently losing it while the UI reports a healthy sync (#77 / #91).
 *
 * Pure function (no I/O) so it is unit-testable against captured frames.
 */
fun rejectedHistoricalRecords(
    rawFrames: List<ByteArray>,
    family: DeviceFamily = DeviceFamily.WHOOP4,
): List<ByteArray> {
    // Inner packet-type byte: WHOOP 5/MG's longer puffin envelope puts it at frame[8]; WHOOP 4 at frame[4].
    val typeIndex = if (family == DeviceFamily.WHOOP5) 8 else 4
    return rawFrames.filter { frame ->
        val t = frame.histU8(typeIndex) ?: return@filter false
        if (t != PacketType.HISTORICAL_DATA.rawValue) return@filter false // type-50 console / metadata / etc.
        // WHOOP 5/MG v26 = raw PPG block, deliberately not stored — known-skipped, not lost data.
        if (family == DeviceFamily.WHOOP5 && frame.histU8(9) == 26) return@filter false
        // A type-47 record that [decodeHistorical] cannot turn into usable biometrics — CRC failure or
        // an unmapped layout the v24-fallback plausibility gate rejected. This is precisely what
        // [extractHistoricalStreams] drops (`decodeHistorical(...) ?: continue`), so the rejected set
        // matches the silently-lost set exactly.
        decodeHistorical(frame, family) == null
    }
}

// MARK: - METADATA classification (port of HistoricalMeta.swift)

/** Classification of a METADATA frame (type 49) for the historical-offload state machine. */
sealed class HistoricalMeta {
    object Start : HistoricalMeta()

    /** HISTORY_END: [unix] = record unix seconds, [trim] = the trim cursor to ack/advance. */
    data class End(val unix: Long, val trim: Long) : HistoricalMeta()

    object Complete : HistoricalMeta()
    object Other : HistoricalMeta()
}

/**
 * Classify a parsed METADATA frame into the four cases the offload state machine needs.
 * Direct port of Swift `classifyHistoricalMeta`.
 *
 * Field mapping (whoop_protocol.json + Framing.decodeMetadata): `meta_type` is the
 * "NAME(rawValue)" enum label (e.g. "HISTORY_END(2)"); for HISTORY_END the metadata decoder
 * additionally stores `unix` and `trim_cursor`. We match by prefix so a raw-value change can't
 * break the classifier.
 *
 * Integrity gate (kept from Swift): only act on a checksum-valid frame — without it a garbled or
 * forged BLE peer could forge HISTORY_END / HISTORY_COMPLETE and advance/ack the trim cursor for
 * data we never durably stored.
 */
fun classifyHistoricalMeta(p: ParsedFrame): HistoricalMeta {
    if (!p.ok || p.crcOk == false) return HistoricalMeta.Other
    if (p.typeName != "METADATA") return HistoricalMeta.Other
    val metaName = p.parsed["meta_type"] as? String ?: return HistoricalMeta.Other
    return when {
        metaName.startsWith("HISTORY_START") -> HistoricalMeta.Start
        metaName.startsWith("HISTORY_COMPLETE") -> HistoricalMeta.Complete
        metaName.startsWith("HISTORY_END") -> {
            val unix = p.parsed.intOrNull("unix")
            val trim = p.parsed.intOrNull("trim_cursor")
            if (unix == null || trim == null) HistoricalMeta.Other
            // u32-on-the-wire; the Int values were already truncated to 32 bits on decode. Carry as
            // Long (unsigned-safe) so a value past 2^31 doesn't surface as negative downstream.
            else HistoricalMeta.End(unix = unix.toLong() and 0xFFFFFFFFL, trim = trim.toLong() and 0xFFFFFFFFL)
        }
        else -> HistoricalMeta.Other
    }
}

// MARK: - Historical extraction (port of HistoricalStreams.swift extractHistoricalStreams)

/**
 * Turn a batch of parsed offload frames into a [StreamBatch] of datastore rows. Direct port of
 * Swift `extractHistoricalStreams`.
 *
 * HR/R-R/SpO2/skinTemp/resp/gravity come from type-47 HISTORICAL_DATA records, each of which
 * carries its OWN real unix timestamp — so NO wall-clock offset is applied to them (the
 * [deviceClockRef]/[wallClockRef] args exist only for the REALTIME_RAW_DATA fallback below and to
 * mirror the Swift signature). EVENT timestamps are real RTC unix seconds (already wall-clock).
 * CRC-failed / non-ok frames are skipped.
 *
 * [rawFrames] are the verbatim BLE frames for this chunk; [decodeHistorical] re-validates + decodes
 * each. We take the frames (not pre-parsed records) because the live [Framing.parseFrame] doesn't
 * populate type-47 fields — the type-47 record is decoded here by [decodeHistorical].
 */
fun extractHistoricalStreams(
    rawFrames: List<ByteArray>,
    deviceClockRef: Int,
    wallClockRef: Int,
    family: DeviceFamily = DeviceFamily.WHOOP4,
    // #547 ingest gate "now": the true wall clock used ONLY to reject future-dated records. NOT
    // wallClockRef — that arg is the (device,wall) correlation and is 0 on the RawHistoryArchive replay
    // path (which would otherwise reject everything). Take the LATER of the supplied correlation wall and
    // the real clock so a test that passes a recent wallClockRef still has a sane upper bound, and the
    // replay path's wallClockRef=0 falls back to the real clock. Mirrors the Swift wallNow seam.
    wallNow: Long = maxOf(wallClockRef.toLong(), System.currentTimeMillis() / 1000L),
    // SESSION-RELATIVE bounds (#547): the strap's own GET_DATA_RANGE oldest/newest markers for THIS sync.
    // null on the replay/import/no-range paths — the gate then falls back to the absolute-only floor
    // (unchanged). Kept in lockstep with the Swift extractHistoricalStreams session args.
    sessionOldestUnix: Long? = null,
    sessionNewestUnix: Long? = null,
    // Opt-in "HR-from-PPG sub-lag interpolation" (Test Centre → Experimental algorithms, default false):
    // threaded straight into the v26 PPG-HR estimator below. The pure protocol package can't read prefs, so
    // the app-layer caller (Backfiller / archive replay / capture import) reads PuffinExperiment.ppgHrSubLagInterp
    // and passes it. Default false = byte-identical to today. Mirrors the Swift extractHistoricalStreams arg.
    ppgHrSubLagInterp: Boolean = false,
): StreamBatch {
    // Count of records dropped by the #547 plausibility gate this batch, surfaced on the returned
    // StreamBatch so the Backfiller can log "bad strap clock" once per session via its existing seam.
    var droppedImplausible = 0
    // #891: packet types that reach the `else` branch and are dropped. See StreamBatch.unhandledPacketTypes.
    val unhandledTypes = mutableMapOf<String, Int>()
    // #324: oldest/newest own-timestamp among the dropped records (the poisoned-range epoch span), and the
    // dropped RTC-state events (RTC_LOST / BOOT / SET_RTC) — the ground truth that the clock reset. Declared
    // before correctedWall so the local function can capture them (Kotlin: no forward reference to locals).
    var droppedOldest: Long? = null
    var droppedNewest: Long? = null
    val droppedRtcEvents = ArrayList<DroppedRtcEvent>()
    // #520 diagnostic: running summary of dynamic_acceleration@41 over this batch. Counted, never
    // stored — the field has been decoded all along with nothing consuming it, so there is no evidence
    // on whether it beats the gravity-delta stillness the stager derives today. Twin of Swift.
    val dynAccel = DynAccelDiag()

    // The plausible-timestamp window for this batch (#547): the absolute floor [MIN_PLAUSIBLE_UNIX,
    // wallNow + FUTURE_MARGIN] PLUS, when the strap's GET_DATA_RANGE markers are known AND well-formed
    // (both above the floor, oldest <= newest), the strap's OWN banked window padded by SESSION_RANGE_MARGIN.
    // A record dated months outside the strap's own window is wandering-clock pollution even if it clears the
    // absolute floor (e.g. 2024-12-25 against a 2026 strap). A legitimately-OLD record WITHIN [oldest, newest]
    // (real banked history) is always kept. Malformed/half markers fall back to absolute-only — never reject
    // real data on a wrong-epoch marker. Mirrors Swift `isPlausibleHistoricalUnix(_:wallNow:sessionOldest:sessionNewest:)`.
    fun plausible(ts: Long): Boolean {
        if (ts < MIN_PLAUSIBLE_UNIX || ts > wallNow + FUTURE_MARGIN) return false
        val oldest = sessionOldestUnix
        val newest = sessionNewestUnix
        if (oldest == null || newest == null || oldest < MIN_PLAUSIBLE_UNIX || newest < oldest) return true
        return ts >= oldest - SESSION_RANGE_MARGIN && ts <= newest + SESSION_RANGE_MARGIN
    }

    fun wall(deviceTs: Int?): Int? = if (deviceTs == null) null else wallClockRef + (deviceTs - deviceClockRef)

    // FIX #72: type-47 `unix` and EVENT `event_timestamp` are the strap RTC's own real-unix seconds.
    // When the strap RTC is grossly stale (it sat unused for months, so its clock is months behind) those
    // land far in the past — live HR works but all offloaded history is misdated. Correct them by the
    // (wall - device) clock offset, but ONLY when grossly stale, and SNAPPED to a 5-min grid so the SAME
    // record re-syncs to the SAME corrected ts (offloaded rows dedupe by (deviceId, ts); an un-snapped,
    // slightly-different offset on re-sync would duplicate every row). A normal/identity clockRef has
    // offset ~0 (< threshold) → rawTs unchanged (current behavior).
    val staleThreshold = 86_400          // 1 day
    val snapGranularity = 300            // 5 min
    val clockOffset = wallClockRef - deviceClockRef
    // #547: now NULLABLE. After resolving the final candidate ts (BOTH the raw pass-through branch AND the
    // corrected branch, including the anti-future fallback that keeps rawTs), reject the record entirely
    // when its timestamp is implausible — older than 2023-11 or more than a day ahead of now. pikapik's
    // bad-clock WHOOP 4.0 emits records whose `unix` decodes to scattered garbage (2024 / 2027-spike /
    // far-past / a future date); the constant-skew corrector returns those rawTs UNVALIDATED on a healthy-
    // looking clock (offset 0 on backfill), so they entered the DB verbatim and polluted every day-window.
    // Returning null here makes every call site skip the record. Counts each drop for the once-per-session
    // bad-clock log. Mirrors the Swift correctedWall returning nil.
    fun correctedWall(rawTs: Long): Long? {
        val candidate: Long = run {
            if (kotlin.math.abs(clockOffset) <= staleThreshold) return@run rawTs
            val snapped = (if (clockOffset >= 0) clockOffset + snapGranularity / 2
                           else clockOffset - snapGranularity / 2) / snapGranularity * snapGranularity
            val corrected = rawTs + snapped.toLong()
            // A fully-drained strap whose RTC reset to ~epoch (year ~1971) reports a near-zero
            // deviceClockRef while its frames still carry the true-unix rawTs; clockOffset is then
            // ~decades and this "correction" hurls every historical sample into the future (field: year
            // 2081), silently breaking sleep & recovery because the night never lands on the right day.
            // A record can't post-date its own capture, so when corrected overshoots wall time the offset
            // was bogus — keep the raw ts. Genuine stale (strap behind real time) has corrected <= wall,
            // so this is a no-op there. (PR #471, @cataboysbusiness-debug)
            if (corrected > wallClockRef + snapGranularity) rawTs else corrected
        }
        if (!plausible(candidate)) {
            droppedImplausible++
            // #324: track the epoch SPAN of the dropped (bad-clock) records — the strap's OWN dated value,
            // so the Backfiller can log whether the whole poisoned range is future-dated or mixed.
            droppedOldest = minOf(droppedOldest ?: candidate, candidate)
            droppedNewest = maxOf(droppedNewest ?: candidate, candidate)
            return null
        }
        return candidate
    }

    val hr = ArrayList<HrRow>()
    val rr = ArrayList<RrRow>()
    val spo2 = ArrayList<Spo2Row>()
    val skinTemp = ArrayList<SkinTempRow>()
    val steps = ArrayList<StepRow>()
    val sleepState = ArrayList<SleepStateRow>()
    val resp = ArrayList<RespRow>()
    val gravity = ArrayList<GravityRow>()
    val events = ArrayList<EventEntry>()
    val battery = ArrayList<BatteryRow>()
    // v26 PPG samples accumulate across the chunk, then get turned into HR after the loop (#156).
    val ppgSamples = ArrayList<PpgHr.Sample>()
    // The RAW v26 waveform kept PER RECORD (one row per strap-second) for durable storage (#156
    // follow-up) — the same (ts, samples) the estimator above consumes, but grouped per second so it
    // persists as its own `ppgWaveformSample` stream rather than being flattened into the HR buffer.
    val ppgWaveform = ArrayList<PpgWaveformRow>()
    // Every remaining v18 per-second field the decoder produces and this funnel used to discard.
    val v18Aux = ArrayList<V18AuxRow>()

    for (frame in rawFrames) {
        // Packet type byte: WHOOP 5/MG's longer puffin envelope puts it at frame[8]; WHOOP 4 at frame[4].
        val t = if (family == DeviceFamily.WHOOP5) (frame.histU8(8) ?: -1)
                else if (frame.size > 4) frame[4].toInt() and 0xFF else -1
        when (t) {
            PacketType.HISTORICAL_DATA.rawValue -> {
                // WHOOP 5/MG layout v26 = the 24 Hz optical PPG buffer. It carries no per-second HR
                // (HR is PPG-derived on-device), so [decodeHistorical] returns null for it; instead we
                // accumulate its waveform samples here and derive HR after the loop via [PpgHr] (#156).
                // One v26 record == one strap second == 24 samples, appended in wire (time) order so the
                // concatenated stream is contiguous at 24 Hz. The whole-second `ts` is the record's unix
                // (sub-second resolution isn't needed — [PpgHr] indexes by sample position, not ts, and
                // the emitted HR is per-second). The unix gets the same grossly-stale-RTC correction
                // (FIX #72) as every other stream.
                if (family == DeviceFamily.WHOOP5) {
                    decodeWhoop5HistoricalV26(frame)?.let { rec ->
                        // #547: skip a v26 PPG buffer whose unix is implausible (correctedWall → null) so a
                        // bad-clock strap can't seed the derived-HR estimator with garbage-timestamped samples.
                        val baseTs = correctedWall(rec.unix.toLong() and 0xFFFFFFFFL)
                        if (baseTs != null) {
                            for (v in rec.samples) ppgSamples.add(PpgHr.Sample(ts = baseTs, value = v))
                            // Persist the raw waveform itself too (#156 follow-up), keyed on the record's
                            // corrected wall-second. Guard on non-empty so a truncated frame that decoded
                            // zero samples never banks an empty row (mirrors the Swift `!samples.isEmpty`).
                            if (rec.samples.isNotEmpty()) ppgWaveform.add(PpgWaveformRow(baseTs, rec.samples))
                        }
                    }
                }
                // type-47 carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
                // (FIX #72); a normal strap is unchanged (offset < threshold).
                val p = decodeHistorical(frame, family) ?: continue
                // #547: correctedWall is now nullable — it returns null for an implausible (far-past /
                // future-dated) record, so the `?: continue` below skips a bad-clock record entirely
                // instead of letting its garbage `unix` enter the DB and pollute the day-windowed analytics.
                val ts = (p.intOrNull("unix")?.toLong())?.let { correctedWall(it) } ?: continue

                // skip startup hr=0 (matches Swift `bpm != 0`).
                p.intOrNull("heart_rate")?.let { bpm -> if (bpm != 0) hr.add(HrRow(ts, bpm)) }

                @Suppress("UNCHECKED_CAST")
                (p["rr_intervals"] as? List<Int>)?.forEach { rrMs -> rr.add(RrRow(ts, rrMs)) }

                p.intOrNull("spo2_red")?.let { red ->
                    spo2.add(Spo2Row(ts, red = red, ir = p.intOrNull("spo2_ir") ?: 0))
                }
                // The two AUXILIARY thermal channels (`temp_aux_1_raw@69` / `temp_aux_2_raw@71`, i16,
                // °C = value/10) ride the primary skin-temp row for the same second. Both were decoded
                // and dropped here until now. They are carried ONLY when the primary channel decoded,
                // because that is the row's key — a record whose @73 failed the decoder's 5-45 °C gate
                // banks no skinTemp row at all, and inventing one to hold an aux value would put a
                // fabricated primary reading in the store. null for a WHOOP 4.0.
                p.intOrNull("skin_temp_raw")?.let { raw ->
                    skinTemp.add(
                        SkinTempRow(
                            ts,
                            raw,
                            aux1Raw = p.intOrNull("temp_aux_1_raw"),
                            aux2Raw = p.intOrNull("temp_aux_2_raw"),
                        ),
                    )
                }
                // step_motion_counter@57 is the WHOOP5 CUMULATIVE u16 counter (decoded but, until now,
                // dropped). Stored raw; AnalyticsEngine derives the daily step total from counter deltas.
                // APPROXIMATE — @57 semantics unverified vs the official app (see decodeWhoop5Historical). (#78)
                // activity_class@63 (0=still/1=walk/2=run) rides on the same record — null when invalid/absent.
                p.intOrNull("step_motion_counter")?.let { c ->
                    steps.add(StepRow(ts, c, activityClass = p.intOrNull("activity_class")))
                }
                // Band sleep_state (#175): the strap's OWN @81 high-nibble state (0 wake/1 still/2 asleep/3
                // up), decoded but DROPPED here until now, so the whole band-state chain (persist → the H7
                // re-onset confirm guard → Deep Timeline track) had no source. Carried VERBATIM including 0
                // (a real wake reading, not "absent"): only 5/MG v18 records emit the key, so a WHOOP 4.0
                // simply adds nothing.
                // `rawByte` carries the WHOLE @81 byte beside the high-nibble `state` this row already
                // stored, so the bits the mask throws away survive: b0-1 `onwrist` and b2-3
                // `wake_quality` are both decoded and were discarded right here, and b6-7 have no
                // interpretation at all yet. `state` is unchanged, so #175 / the H7 guard / the Deep
                // Timeline track are bit-identical.
                p.intOrNull("sleep_state")?.let { st ->
                    sleepState.add(SleepStateRow(ts, st, rawByte = p.intOrNull("sleep_state_byte")))
                }
                p.intOrNull("resp_rate_raw")?.let { raw -> resp.add(RespRow(ts, raw)) }
                // `dynAccel` is the strap's OWN gravity-removed motion magnitude
                // (`dynamic_acceleration@41`) for this same second, riding the gravity row it belongs
                // beside. It was decoded and dropped here until now, so every second of it was lost once
                // the offload was acked. null for a WHOOP 4.0 or a record whose f32 failed the [0, 8] g gate.
                p.doubleOrNull("gravity_x")?.let { gx ->
                    gravity.add(
                        GravityRow(
                            ts,
                            x = gx,
                            y = p.doubleOrNull("gravity_y") ?: 0.0,
                            z = p.doubleOrNull("gravity_z") ?: 0.0,
                            dynAccel = p.doubleOrNull("dynamic_acceleration"),
                        ),
                    )
                }
                // #520: fold the gravity-removed motion magnitude into the diagnostic summary. The
                // threshold is the stager's own cut, borrowed as a reference point (the stager thresholds a
                // per-sample delta, this is an absolute magnitude — related, not the same measurement);
                // passed as a literal because the protocol layer must not depend on analytics.
                p.doubleOrNull("dynamic_acceleration")?.let { dynAccel.add(it, DYN_ACCEL_STILL_THRESHOLD_G) }
                // Everything ELSE the v18 decoder produced for this second. Each of these was computed
                // and then dropped one line later; the strap trims its banked history the moment the
                // offload is acked, so an unbanked field is unrecoverable and can never be censused.
                // Carried verbatim under the decoder's own names, no scaling and no interpretation.
                //
                // Gated on `hist_version == 18` — the exact layout these offsets were read off. Every
                // other layout adds NOTHING: a WHOOP 4.0 v24/v25 record and a 5/MG v20/v21/v26 record are
                // untouched. The gate is explicit rather than implied by which keys happen to be present,
                // because `rr_count` IS shared with the 4.0 schema and a presence-based test would start
                // banking a near-empty row for every WHOOP 4.0 second.
                //
                // Every lookup below is BY DECODER KEY, and every one is nullable. That makes a decoder
                // rename silent: the key stops existing, the slot banks nothing, and neither the compiler
                // nor a runtime check says a word (absence is a legal state here). Each key comes from
                // `V18AuxSlot.decoderKey` and is written down nowhere else on this side, so
                // `DeepCaptureChannelsTest.everySlotDecoderKeyExistsInARealV18Decode` — which asserts every
                // one still decodes off a real v18 frame — is checking the same string this code reads
                // with, not a copy of it. Swift twin: `extractHistoricalStreams`.
                // Every slot is carried as a Long in the UNSIGNED domain, matching Swift's 64-bit Int.
                // The 1- and 2-byte slots are already non-negative, but the two 4-byte ones are not: the
                // decoder narrows `record_index` to an Int (`histU32(11)!!.toInt()`) and `toRawBits`
                // yields an Int, so a u32 with bit 31 set arrives NEGATIVE here while Swift reads it
                // positive. `asU32` puts both back in the 0..4294967295 domain, so the two platforms
                // agree on the NUMBER and not merely on the blob bytes.
                if (p.intOrNull("hist_version") == 18) {
                    // Read through [V18AuxSlot.decoderKey] rather than repeating the key strings here.
                    // They used to be two independent literals per slot — the enum's and this extractor's
                    // — and `everySlotIsPopulatedFromARealV18Frame` exists precisely because those two can
                    // drift apart while each looks right on its own. With one source there is nothing to
                    // drift: a slot pointed at a retired key now fails BOTH tripwires, not only the second.
                    fun slot(s: V18AuxSlot): Long? = p.intOrNull(s.decoderKey)?.toLong()
                    val aux = V18AuxRow(
                        ts = ts,
                        // Needs asU32(), so it cannot use slot() — but the KEY still comes from the enum.
                        recordIndex = p.intOrNull(V18AuxSlot.RECORD_INDEX.decoderKey).asU32(),
                        rrCount = slot(V18AuxSlot.RR_COUNT),
                        cardiacFlags = slot(V18AuxSlot.CARDIAC_FLAGS),
                        hrQualityFlags = slot(V18AuxSlot.HR_QUALITY_FLAGS),
                        heartRateAlt = slot(V18AuxSlot.HEART_RATE_ALT),
                        rrPacked = slot(V18AuxSlot.RR_PACKED),
                        cardiacStatus = slot(V18AuxSlot.CARDIAC_STATUS),
                        stepCadence = slot(V18AuxSlot.STEP_CADENCE),
                        statusWord = slot(V18AuxSlot.STATUS_WORD),
                        statusWord1 = slot(V18AuxSlot.STATUS_WORD_1),
                        statusWord2 = slot(V18AuxSlot.STATUS_WORD_2),
                        auxByte82 = slot(V18AuxSlot.AUX_BYTE_82),
                        opticalBaselineA = slot(V18AuxSlot.OPTICAL_BASELINE_A),
                        opticalBaselineB = slot(V18AuxSlot.OPTICAL_BASELINE_B),
                        opticalAmpA = slot(V18AuxSlot.OPTICAL_AMP_A),
                        opticalAmpB = slot(V18AuxSlot.OPTICAL_AMP_B),
                        // Banked as the float's raw 32-bit pattern, not a decoded value — the decoder
                        // gates this field to finite floats, which round-trip Double->Float exactly.
                        // Reads doubleOrNull, so it cannot use slot() either; same rule for the key.
                        unknownF32Bits = p.doubleOrNull(V18AuxSlot.UNKNOWN_F32_113.decoderKey)
                            ?.let { f -> f.toFloat().toRawBits() }.asU32(),
                    )
                    // A record that decoded none of the slots banks no row at all — absence stays absence.
                    if (!aux.isEmpty) v18Aux.add(aux)
                }
            }

            PacketType.REALTIME_RAW_DATA.rawValue -> {
                // Fallback (rare during a plain type-47 offload): HR/RR off the type-43 header. Its
                // timestamp is a device-epoch value, so it DOES get the wall-clock offset. The live
                // Framing decoder doesn't decode type-43 biometrics, so re-parse via parseFrame and
                // read whatever timestamp/HR/RR it surfaced (typically none on this firmware).
                val parsed = Framing.parseFrame(frame, family)
                if (!parsed.ok || parsed.crcOk == false) continue
                val ts = wall(parsed.parsed.intOrNull("timestamp")) ?: continue
                // #547: gate the wall()-corrected REALTIME_RAW_DATA ts on the same plausibility window — a
                // bad device clock here would otherwise inject a far-past / future-dated HR/RR row.
                if (!plausible(ts.toLong())) { droppedImplausible++; continue }
                parsed.parsed.intOrNull("heart_rate")?.let { bpm -> hr.add(HrRow(ts.toLong(), bpm)) }
                @Suppress("UNCHECKED_CAST")
                (parsed.parsed["rr_intervals"] as? List<Int>)?.forEach { rrMs ->
                    rr.add(RrRow(ts.toLong(), rrMs))
                }
            }

            PacketType.EVENT.rawValue -> {
                // EVENT carries the strap RTC's real-unix seconds. Correct for a grossly-stale RTC
                // (FIX #72); a normal strap is unchanged. Port of the Swift `case "EVENT"` branch:
                // persist the event (with battery extracted for BATTERY_LEVEL) so offloaded
                // wrist/charge/battery events aren't lost. During a backfill the live path is
                // suppressed, so the offload extractor MUST handle these.
                val parsed = Framing.parseFrame(frame, family)
                if (!parsed.ok || parsed.crcOk == false) continue
                val rawTs = parsed.parsed.intOrNull("event_timestamp")?.toLong() ?: continue
                val kind = (parsed.parsed["event"] as? String) ?: ""
                // #547: correctedWall now nullable — an EVENT with an implausible event_timestamp is
                // skipped so a bad-clock wrist/charge/battery event can't enter the DB.
                val ts = correctedWall(rawTs)
                if (ts == null) {
                    // #324: the #547 gate just dropped this event for an implausible ts. If it's an RTC-STATE
                    // event (RTC_LOST / BOOT / SET_RTC), that IS the ground truth that the clock reset —
                    // capture (kind, rawTs) for the strap log before discarding.
                    if (DroppedRtcEvent.isRtcStateKind(kind)) droppedRtcEvents.add(DroppedRtcEvent(kind, rawTs))
                    continue
                }
                if (kind.startsWith("BATTERY_LEVEL")) appendHistBattery(battery, ts, parsed.parsed)
                val payload = LinkedHashMap(parsed.parsed)
                payload.remove("event")
                payload.remove("event_timestamp")
                events.add(EventEntry(ts, kind, StreamPersistence.encodePayload(payload)))
            }

            PacketType.COMMAND_RESPONSE.rawValue -> {
                // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef (Swift parity).
                val parsed = Framing.parseFrame(frame, family)
                if (!parsed.ok || parsed.crcOk == false) continue
                appendHistBattery(battery, wallClockRef.toLong(), parsed.parsed)
            }

            // #891: no branch handles this type, so the record is dropped — count it first, or an offload
            // carrying a type nobody has mapped reports as a clean sync. See StreamBatch.unhandledPacketTypes
            // for why METADATA/CONSOLE_LOGS are excluded. Mirrors Swift's `default:`.
            else -> {
                // Family-aware exactly as Swift's `frameTypeName` is: a WHOOP 4.0 frame renders through the
                // plain enum (`schema.typeName` on Apple), a 5/MG frame through the puffin aliasing
                // (`canonicalTypeName`). Always aliasing here would have rendered a 4.0 type-56 as METADATA
                // and then EXCLUDED it, while Apple counted it as PUFFIN_METADATA — the census silently
                // disagreeing across platforms about an anomalous frame, which is the one case it exists for.
                val name = if (family == DeviceFamily.WHOOP5) Framing.typeName(t)
                           else PacketType.fromRaw(t)?.name ?: "type$t"
                if (name !in EXPECTED_UNHANDLED_HISTORICAL_TYPES) {
                    // Swift skips CRC-failed frames BEFORE its switch; this loop dispatches on the raw type
                    // byte, so the check has to happen here or a corrupt frame would be reported as an
                    // unknown firmware feature on Android and not on Apple. A CRC failure is a different
                    // finding with its own archive (rejectedHistoricalRecords).
                    val parsed = Framing.parseFrame(frame, family)
                    if (parsed.ok && parsed.crcOk != false) {
                        unhandledTypes[name] = (unhandledTypes[name] ?: 0) + 1
                    }
                }
            }
        }
    }

    // Derive HR from the accumulated v26 PPG waveform (8 s / 24 Hz autocorrelation, conf>=0.3). Empty
    // unless the strap sent v26 records; falls back gracefully (no rows) on noise (#156).
    val ppgHr = PpgHr.estimate(ppgSamples, subLagInterp = ppgHrSubLagInterp)
        .map { PpgHrRow(ts = it.ts, bpm = it.bpm, conf = it.conf) }

    return StreamBatch(
        hr = hr, rr = rr, events = events, battery = battery,
        spo2 = spo2, skinTemp = skinTemp, resp = resp, gravity = gravity, steps = steps,
        sleepState = sleepState,
        ppgHr = ppgHr,
        ppgWaveform = ppgWaveform,
        v18Aux = v18Aux,
        unhandledPacketTypes = unhandledTypes,   // #891 diag census (not persisted)
        droppedImplausibleTs = droppedImplausible,
        droppedImplausibleOldestTs = droppedOldest,   // #324 poisoned-range epoch span (diag only)
        droppedImplausibleNewestTs = droppedNewest,
        droppedRtcEvents = droppedRtcEvents,
        dynAccel = dynAccel,
    )
}

/**
 * Append a [BatteryRow] from a parsed frame's `battery_pct`/`battery_mV`/`battery_charging` fields
 * (no-op when neither soc nor mv is present). Mirrors the live-path `appendBattery` in Streams.kt
 * (kept local here to avoid widening that internal helper's surface).
 */
private fun appendHistBattery(out: MutableList<BatteryRow>, ts: Long, p: Map<String, Any?>) {
    val soc = p.doubleOrNull("battery_pct")
    val mv = p.intOrNull("battery_mV")
    if (soc == null && mv == null) return
    val charging = p.intOrNull("battery_charging")?.let { it != 0 }
    out.add(BatteryRow(ts = ts, soc = soc, mv = mv, charging = charging))
}
