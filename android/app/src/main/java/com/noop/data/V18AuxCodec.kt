package com.noop.data

/**
 * One wire slot in the 5/MG v18 auxiliary-field record. [index] is the slot's bit position in the
 * persisted presence bitmap, so it is a STORAGE CONTRACT: never reorder, renumber, or reuse a value.
 * Appending a new entry at the end is the only safe evolution (an old reader ignores a bit it has no
 * entry for; a new reader sees the bit absent on old rows).
 *
 * Every slot is carried as an UNSIGNED integer of [width] bytes, little-endian, exactly as it sits on the
 * wire — including [UNKNOWN_F32_113], which is banked as its raw 32-bit pattern rather than a decoded
 * float. One uniform integer path is what makes the Kotlin and Swift codecs verifiably byte-identical,
 * and banking the bit pattern means a future reader can re-interpret those 4 bytes as something other
 * than a float if the census says so.
 *
 * Every slot value is an unsigned integer up to 32 bits wide, so the DECODED domain has to be at least
 * 33 bits or this side disagrees with Swift on a u32 with bit 31 set (which `unknown_f32_113` routinely
 * has). Kotlin's `Int` is 32-bit and Swift's `Int` is 64-bit, so every slot value here is a `Long` —
 * `V18AuxRow` fields, [V18AuxRow.slotValues] and the codec's internals alike. `DeepCaptureChannelsTest`
 * asserts the SAME decimal literals the Swift suite does, so the parity is proved rather than assumed.
 *
 * Names are the DECODER's own names, verbatim ([decoderKey]) — no exceptions. Several slots are frankly
 * unpinned bytes: `cardiac_flags`/`cardiac_status` are outside-report names for bytes near the HR fields
 * that do not decode consistently across firmwares, and `optical_amp_a`/`_b` are optical channel
 * amplitudes, not a named physiological quantity. Nothing here is renamed to imply a meaning it has not
 * earned — but nothing is renamed AWAY from the decoder either, because [decoderKey] is a string lookup
 * into the parsed map and a slot whose key does not exist banks silence, not an error. See
 * `DeepCaptureChannelsTest.everySlotDecoderKeyExistsInARealV18Decode`, the tripwire for exactly that.
 *
 * `@36`/`@37` and `@106`/`@107` are each TWO one-byte slots rather than one u16, because the decoder reads
 * them as two u8 channels: #861 showed `@36` is a flag byte with `@37` a duplicate HR beside it, and that
 * `@106`/`@107` cannot be a u16 at all (the high byte steps without a low-byte carry).
 *
 * Mirror of the Swift `V18AuxSlot`.
 */
enum class V18AuxSlot(val index: Int, val width: Int, val decoderKey: String) {
    RECORD_INDEX(0, 4, "record_index"),                 // @11  per-record counter, +1 per record
    RR_COUNT(1, 1, "rr_count"),                         // @23  the strap's OWN R-R count (stream caps at 4)
    CARDIAC_FLAGS(2, 1, "cardiac_flags"),               // @33  raw byte near the HR fields; not pinned

    /**
     * `@36`/`@37` were banked as ONE u16 (`hr_fixed_8_8`, "higher-precision HR, bpm = value/256"). #861
     * retired that: over 18,650 real v18 records bit 4 of `@36` is NEVER set (a genuine 8.8 fraction sets
     * it ~50% of the time), 95.02% of values land in 0x80-0x8F, and the "corr 0.989 with heart_rate@22"
     * was circular — the u16 is literally the duplicate HR at `@37` plus the `@36` flag byte over 256.
     * They are two independent bytes, so they are two slots. Both are still carried RAW: bit 7 of `@36`
     * reads as a validity bit and `@37` tracks HR only while it is set, but storage asserts neither.
     */
    HR_QUALITY_FLAGS(3, 1, "hr_quality_flags"),         // @36  flag byte (bit7 = valid); NOT a fixed HR
    HEART_RATE_ALT(4, 1, "heart_rate_alt"),             // @37  duplicate of heart_rate@22; raw, ungated
    RR_PACKED(5, 2, "rr_packed"),                       // @38  raw u16 near the R-R fields; not pinned
    CARDIAC_STATUS(6, 1, "cardiac_status"),             // @40  raw status-like byte near the HR fields
    STEP_CADENCE(7, 1, "step_cadence"),                 // @59  cadence-like byte (never 0)
    STATUS_WORD(8, 2, "status_word"),                   // @75  packed status word; NOT a deep-sleep marker
    STATUS_WORD_1(9, 2, "status_word_1"),               // @77  near-static sibling of @75
    STATUS_WORD_2(10, 2, "status_word_2"),              // @79  sibling of @75
    AUX_BYTE_82(11, 1, "aux_byte_82"),                  // @82  RAW byte; spo2_candidate_82 is a gated view

    /**
     * `@106`/`@107` were banked as one u16 optical baseline. #861 showed a u16 is structurally impossible
     * there: across 18,599 consecutive-second pairs the HIGH byte moved while the LOW byte stayed frozen
     * in 3,514 of them, with ZERO low-byte wrap events in the corpus. Two correlated but independent u8
     * channels, so two slots — and `0`, not `128`, is the off-wrist reading on both.
     */
    OPTICAL_BASELINE_A(12, 1, "optical_baseline_a"),    // @106 optical/ADC baseline; 0 = off-wrist
    OPTICAL_BASELINE_B(13, 1, "optical_baseline_b"),    // @107 the other baseline channel

    /**
     * `@108`/`@109` are a pair, and 128 is a RECORD-level marker rather than a per-channel invalid
     * sentinel: in the #845 census `optical_amp_a == 128` and `optical_amp_b == 128` co-occur 757/757 and
     * never independently, so one channel reading 128 while the other does not has never been observed.
     * Banked raw either way — nothing here decides what the marker means.
     */
    OPTICAL_AMP_A(14, 1, "optical_amp_a"),              // @108 paired amplitude-like channel
    OPTICAL_AMP_B(15, 1, "optical_amp_b"),              // @109 the other half of the @108/@109 pair
    UNKNOWN_F32_113(16, 4, "unknown_f32_113"),          // @113 carried as its raw u32 bit pattern
}

/**
 * Every remaining 5/MG v18 per-second field the decoder produces and the extractor used to DROP.
 *
 * Carried VERBATIM under the decoder's own names — no scaling, no renaming, no physiological claim —
 * precisely so a later census decides what these are rather than this change pre-judging it.
 *
 * Fields that already have a durable home are deliberately NOT duplicated here: `heart_rate`,
 * `rr_intervals`, `gravity_*`, `skin_temp_raw`, `step_motion_counter`, `activity_class`, `sleep_state`
 * and `unix` all have their own columns. `motion_wear_quality@63` is the same byte as `activity_class`
 * under a second name and the same 0-2 gate. `spo2_candidate_82` is a gated 70-100 view of [auxByte82]
 * and is recoverable from the raw byte.
 *
 * INSTRUMENTATION ONLY: nothing reads this stream. Every slot is nullable, so an absent field stays
 * absent and never becomes a fabricated 0.
 *
 * Every field is a `Long`, NOT an `Int`. Slots are UNSIGNED and up to 32 bits wide, and Kotlin's `Int` is
 * 32-bit while Swift's is 64-bit — an `Int` here would decode `unknown_f32_113` = 0xC0A7619D to
 * -1_062_772_323 where Swift reads 3_232_194_973, from byte-identical blobs. The wire bytes are the same
 * either way, so this is a decoded-domain fix, not a format change. Mirror of the Swift `V18AuxSample`.
 */
data class V18AuxRow(
    val ts: Long,
    val recordIndex: Long? = null,
    val rrCount: Long? = null,
    val cardiacFlags: Long? = null,
    /**
     * The `@36` flag byte, raw. Bit 7 reads as an HR/R-R validity bit and bit 4 is never set (#861);
     * storage carries all 8 bits and interprets none of them.
     */
    val hrQualityFlags: Long? = null,
    /**
     * The `@37` duplicate heart rate, raw and UNGATED — it equals `heart_rate@22` in 99.6% of records but
     * only tracks HR while [hrQualityFlags] bit 7 is set, so it is banked as the byte it is rather than
     * as a bpm. Reading it as one is a consumer's decision, made against the flag byte beside it.
     */
    val heartRateAlt: Long? = null,
    val rrPacked: Long? = null,
    val cardiacStatus: Long? = null,
    val stepCadence: Long? = null,
    val statusWord: Long? = null,
    val statusWord1: Long? = null,
    val statusWord2: Long? = null,
    val auxByte82: Long? = null,
    /**
     * The two `@106`/`@107` optical/ADC baseline channels, raw. Independent bytes, NOT a u16 — see
     * [V18AuxSlot.OPTICAL_BASELINE_A]. `0` on both is the off-wrist reading; `128` is unremarkable here.
     */
    val opticalBaselineA: Long? = null,
    val opticalBaselineB: Long? = null,
    val opticalAmpA: Long? = null,
    val opticalAmpB: Long? = null,
    /** The raw 32-bit pattern of `unknown_f32_113`, NOT a decoded float. See [unknownF32At113]. */
    val unknownF32Bits: Long? = null,
) {
    /**
     * The slot values in wire order — position == [V18AuxSlot.index]. The storage codec's only view of
     * this row, so the field order lives in exactly one place on each platform.
     */
    val slotValues: List<Long?>
        get() = listOf(
            recordIndex, rrCount, cardiacFlags, hrQualityFlags, heartRateAlt, rrPacked, cardiacStatus,
            stepCadence, statusWord, statusWord1, statusWord2, auxByte82, opticalBaselineA,
            opticalBaselineB, opticalAmpA, opticalAmpB, unknownF32Bits,
        )

    /**
     * `unknown_f32_113` re-read as the float the decoder saw. The BITS are what is stored; this is a
     * convenience view, and the only place those four bytes are interpreted as a number at all.
     * [Long.toInt] keeps the low 32 bits, which IS the stored pattern.
     */
    val unknownF32At113: Double?
        get() = unknownF32Bits?.let { Float.fromBits(it.toInt()).toDouble() }

    /** True when the record carried none of the slots — such a row is never banked. */
    val isEmpty: Boolean get() = slotValues.all { it == null }

    companion object {
        /**
         * Rebuild from the codec's slot list. [values] is indexed by [V18AuxSlot.index]; a short list
         * (a blob written by an older build) leaves the missing tail null rather than throwing.
         */
        fun fromSlotValues(ts: Long, values: List<Long?>): V18AuxRow {
            fun v(s: V18AuxSlot): Long? = values.getOrNull(s.index)
            return V18AuxRow(
                ts = ts,
                recordIndex = v(V18AuxSlot.RECORD_INDEX),
                rrCount = v(V18AuxSlot.RR_COUNT),
                cardiacFlags = v(V18AuxSlot.CARDIAC_FLAGS),
                hrQualityFlags = v(V18AuxSlot.HR_QUALITY_FLAGS),
                heartRateAlt = v(V18AuxSlot.HEART_RATE_ALT),
                rrPacked = v(V18AuxSlot.RR_PACKED),
                cardiacStatus = v(V18AuxSlot.CARDIAC_STATUS),
                stepCadence = v(V18AuxSlot.STEP_CADENCE),
                statusWord = v(V18AuxSlot.STATUS_WORD),
                statusWord1 = v(V18AuxSlot.STATUS_WORD_1),
                statusWord2 = v(V18AuxSlot.STATUS_WORD_2),
                auxByte82 = v(V18AuxSlot.AUX_BYTE_82),
                opticalBaselineA = v(V18AuxSlot.OPTICAL_BASELINE_A),
                opticalBaselineB = v(V18AuxSlot.OPTICAL_BASELINE_B),
                opticalAmpA = v(V18AuxSlot.OPTICAL_AMP_A),
                opticalAmpB = v(V18AuxSlot.OPTICAL_AMP_B),
                unknownF32Bits = v(V18AuxSlot.UNKNOWN_F32_113),
            )
        }
    }
}

/**
 * Storage codec for the 5/MG v18 auxiliary-field stream (`v18AuxSample.fields`).
 *
 * WHY A BLOB AND NOT COLUMNS. There are seventeen slots and they arrive once per strap-second. Seventeen
 * nullable columns on a hot per-second table costs a header byte per column per row even when the value
 * is NULL, makes every future slot a migration, and spends schema surface on bytes whose meaning nobody
 * has pinned yet. One compact blob costs a 5-byte header plus only the bytes actually present, and a new
 * slot appends a bitmap bit instead of a column. The tradeoff is that SQL cannot filter on a slot — the
 * right trade here, because nothing queries these yet and a census reads whole rows anyway.
 *
 * WIRE FORMAT (little-endian throughout, no padding, no alignment):
 *
 *     byte  0      format version ([FORMAT_VERSION])
 *     bytes 1..4   u32 presence bitmap; bit [V18AuxSlot.index] set == that slot follows
 *     bytes 5..    each PRESENT slot's value, in ascending slot order, [V18AuxSlot.width] bytes each
 *
 * Absence is a first-class state: a clear bit means "the strap did not report this field", never 0.
 *
 * Byte-identical to the Swift `V18AuxCodec` (`Packages/WhoopStore/Sources/WhoopStore/V18Aux.swift`).
 * Both sides derive slot order and widths from their `V18AuxSlot`, so neither can drift without the
 * other failing its own test.
 */
object V18AuxCodec {
    /**
     * Bumped only for an INCOMPATIBLE layout change. A reader that meets a version it does not know
     * returns an empty row rather than mis-parsing bytes as a slot they are not.
     *
     * v2: the bitmap widened from u16 to u32 and the `@36`/`@37` and `@106`/`@107` pairs each became two
     * u8 slots instead of one u16 (#861 retired the u16 readings). The body bytes are unchanged — the
     * same bytes in the same order — but the HEADER grew by two and every slot past [V18AuxSlot.CARDIAC_FLAGS]
     * shifted its bit position, so a v1 blob and a v2 blob are not interchangeable. A v1 row therefore
     * reads back as "nothing known about this second" rather than being mis-sliced, which is the only safe
     * answer; the format has never shipped, so the only v1 rows that can exist are on a locally built branch.
     */
    const val FORMAT_VERSION = 2

    /**
     * version byte + u32 bitmap. Widened at v2: 17 slots do not fit in a u16, and a bitmap that silently
     * dropped bit 16 would bank the `@113` float on no platform at all.
     */
    const val HEADER_BYTES = 5

    private val SLOTS = V18AuxSlot.entries.sortedBy { it.index }

    /**
     * Pack a row's slots. Returns an EMPTY array when nothing is present, so a caller can skip the row
     * entirely rather than banking an all-absent record.
     */
    fun pack(row: V18AuxRow): ByteArray {
        val values = row.slotValues
        var bitmap = 0
        val body = ArrayList<Byte>(32)
        for (slot in SLOTS) {
            val v = values.getOrNull(slot.index) ?: continue
            bitmap = bitmap or (1 shl slot.index)
            // Truncate to the slot's declared width. Every value here came off the wire at that width,
            // so this is a no-op in practice and a guard against a caller inventing an out-of-range one.
            for (b in 0 until slot.width) body.add(((v ushr (8 * b)) and 0xFF).toByte())
            // (`v` is a Long: the shift is a Long shift, so a 4-byte slot with bit 31 set emits the same
            // bytes Swift's 64-bit Int path does instead of relying on Int wraparound.)
        }
        if (bitmap == 0) return ByteArray(0)
        val out = ByteArray(HEADER_BYTES + body.size)
        out[0] = FORMAT_VERSION.toByte()
        for (b in 0 until 4) out[1 + b] = ((bitmap ushr (8 * b)) and 0xFF).toByte()
        for (i in body.indices) out[HEADER_BYTES + i] = body[i]
        return out
    }

    /**
     * Inverse of [pack]. A malformed, truncated, or unknown-version blob yields an all-null row rather
     * than throwing: a read path over durable rows must never crash on one bad blob. Trailing bytes past
     * the last known slot are ignored, so a row written by a LATER build with more slots still decodes
     * the slots this build knows.
     */
    fun unpack(data: ByteArray, ts: Long): V18AuxRow {
        if (data.size < HEADER_BYTES || (data[0].toInt() and 0xFF) != FORMAT_VERSION) {
            return V18AuxRow(ts = ts)
        }
        var bitmap = 0
        for (b in 0 until 4) bitmap = bitmap or ((data[1 + b].toInt() and 0xFF) shl (8 * b))
        // Long, not Int: a 4-byte slot with bit 31 set (which `unknown_f32_113` routinely has) would
        // decode NEGATIVE in a 32-bit Int while Swift's 64-bit Int reads it positive, from the very same
        // bytes. Widening here is what makes the two platforms agree on the NUMBER, not just the blob.
        val values = arrayOfNulls<Long>(SLOTS.size)
        var i = HEADER_BYTES
        for (slot in SLOTS) {
            if (bitmap and (1 shl slot.index) == 0) continue
            if (i + slot.width > data.size) return V18AuxRow.fromSlotValues(ts, values.toList())
            var u = 0L
            for (b in 0 until slot.width) u = u or ((data[i + b].toLong() and 0xFF) shl (8 * b))
            values[slot.index] = u
            i += slot.width
        }
        return V18AuxRow.fromSlotValues(ts, values.toList())
    }
}
