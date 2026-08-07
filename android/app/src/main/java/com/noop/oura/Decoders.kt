package com.noop.oura

// Decoders: pure per-tag byte->value decoders (OURA_PROTOCOL.md s6). Kotlin twin of Decoders.swift.
// Each returns null on a malformed/short record (honest-data invariant): NEVER a guessed value. Body
// offsets in the spec are relative to the start of the RECORD (offset 6 = first body byte); the parsed
// OuraRecord already stripped the 6-byte header, so here `body[0]` == spec offset 6.
//
// FOOTGUN WATCH (per the brief + OURA_PROTOCOL.md s6 risks):
//   - 0x7B SpO2 is BIG-endian (the lone exception to the LE default).
//   - 0x6E reads IBIs in REVERSE byte order.
//   - 0x80 / 0x60 are bit-packed across byte boundaries.
//   - live-HR IBI uses a 12-bit LE-ish nibble at subBody[5..6]: ((b6 & 0x0F) << 8) | b5.
//
// DIVERGENCE FROM SWIFT: payload bytes are unsigned-byte Ints (0..255) in an IntArray (see Framing.kt
// note), so a signed int16/int8 read goes through an explicit sign-extension helper rather than
// Swift's Int16(bitPattern:)/Int8(bitPattern:). The numeric results are identical.
//
// Platform-pure value types. All facts cited tersely per OURA_PROTOCOL.md s6.

object OuraDecoders {

    /**
     * Decode a GetProductInfo reply body (serial page `18 03 08 00 10` or hardware page `18 03 18 00 10`,
     * both under outer op 0x19). On-device capture 2026-07-24 (Gen3): the body is `byte0 = 0x00 status, then
     * a NUL-terminated ASCII string, NUL-padded` — e.g. serial "2H3B2405003655" or hardware id "BLB_03".
     * Returns the trimmed ASCII string, or null for an empty/non-printable body. Twin of Swift's
     * `OuraDecoders.productInfoString`.
     */
    fun productInfoString(body: IntArray): String? {
        if (body.size <= 1) return null
        val ascii = body.drop(1).takeWhile { it != 0x00 }
        if (ascii.isEmpty() || ascii.any { it < 0x20 || it > 0x7e }) return null
        return ascii.map { it.toChar() }.joinToString("")
    }

    // MARK: - Little-endian helpers (body offset == spec offset - 6)

    private fun u16le(b: IntArray, i: Int): Int = b[i] or (b[i + 1] shl 8)

    private fun u16be(b: IntArray, i: Int): Int = (b[i] shl 8) or b[i + 1]

    /** Signed 16-bit LE: sign-extend the assembled u16. Mirrors Swift Int16(bitPattern:). */
    private fun i16le(b: IntArray, i: Int): Int = (b[i] or (b[i + 1] shl 8)).toShort().toInt()

    private fun u24le(b: IntArray, i: Int): Int = b[i] or (b[i + 1] shl 8) or (b[i + 2] shl 16)

    private fun u32le(b: IntArray, i: Int): Long =
        (b[i].toLong() and 0xFFL) or ((b[i + 1].toLong() and 0xFFL) shl 8) or
            ((b[i + 2].toLong() and 0xFFL) shl 16) or ((b[i + 3].toLong() and 0xFFL) shl 24)

    /** Signed 8-bit: sign-extend an unsigned byte. Mirrors Swift Int8(bitPattern:). */
    private fun i8(v: Int): Int = v.toByte().toInt()

    // MARK: - Live-HR realtime push (0x2F sub-op 0x28; s5.6)

    /**
     * Decode a live-HR push body (the bytes AFTER `2f 0f 28`). Per OURA_PROTOCOL.md s5.6 the wire
     * frame is `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f`. The spec lists the IBI at
     * frame bytes 8-9; once the transport strips the 3-byte `2f 0f 28` prefix those indices shift down
     * by 3, so within this subBody the IBI sits at subBody[5..6] as a 12-bit value:
     * ((b6 & 0x0F) << 8) | b5; bpm = round(60000 / ibi). Returns null on a short body or a
     * zero/implausible IBI.
     *
     * `ringTimestamp` is supplied by the caller (the push is not a TLV record; the driver stamps it
     * with the live ring time). Example subBody[5..6] = `01 04` -> ibi 1025 ms -> ~59 bpm.
     */
    fun decodeLiveHRPush(body: IntArray, ringTimestamp: Long): OuraHR? {
        if (body.size < 7) return null
        val ibi = ((body[6] and 0x0F) shl 8) or body[5]
        if (ibi <= 0) return null
        val bpm = Math.round(60000.0 / ibi.toDouble()).toInt()
        if (bpm <= 0 || bpm >= 300) return null   // reject implausible derived BPM, never guess
        return OuraHR(ringTimestamp = ringTimestamp, bpm = bpm, ibiMs = ibi)
    }

    // MARK: - IBI + amplitude, byte-scatter packed (0x60; s6.1)

    /**
     * Decode the 0x60 ibi_and_amplitude_event: a fixed 14-byte packet holding 6 IBIs (ms) + PPG
     * amplitudes. Each 11-bit IBI is gathered from SCATTERED bytes, NOT a linear bitstream — per the
     * ring's native `parse_api_ibi_and_amplitude_event`: `ibi[k] = (b[6+k]&1) | (b[k]<<3) | <2 hi bits
     * from the b[12]/b[13] nibbles>`. Amplitude = `(b[6+k] shr 1) shl shift`, exponent = low nibble of
     * b[13] (shift = (n==7) ? 0 : n+1). Returns null on a short body.
     *
     * NOTE (#511, decode fix): the previous layout read the body as a linear MSB-first bitstream, which only
     * ever recovered the FIRST IBI correctly and scrambled the other five — a real overnight capture
     * decoded to an 82% beat-to-beat >200ms "jump" rate (not a heartbeat train). This byte-scatter
     * layout yields a coherent ~60 bpm train (10% jump rate). Validated against open_oura. Byte-identical
     * twin of Swift's decodeIBIAmplitude.
     *
     * @param channel which tag's record this is. 0x60 and 0x44 share this layout byte for byte, so they
     *   share the decoder — but they are different tags on the wire, and the caller states which one it
     *   routed here so the beat carries its true origin (#1071 follow-up). Defaults to 0x60's channel,
     *   which is what every existing call site means.
     */
    fun decodeIBIAmplitude(
        rec: OuraRecord,
        channel: OuraIbiChannel = OuraIbiChannel.IBI_AMPLITUDE,
    ): List<OuraIBI>? {
        val b = rec.payload
        if (b.size < 14) return null   // fixed 14-byte packet (body bytes 6..19)
        val b12 = b[12] and 0xFF
        val b13 = b[13] and 0xFF
        val n = b13 and 0x0F
        val shift = if (n == 7) 0 else (n + 1)
        val ibi = intArrayOf(
            (b[6] and 1) or ((b[0] and 0xFF) shl 3) or ((b12 shr 5) and 6),
            (b[7] and 1) or ((b[1] and 0xFF) shl 3) or ((b12 shr 3) and 6),
            (b[8] and 1) or ((b[2] and 0xFF) shl 3) or ((b12 shr 1) and 6),
            (b[9] and 1) or ((b[3] and 0xFF) shl 3) or ((b12 and 3) shl 1),
            (b[10] and 1) or ((b[4] and 0xFF) shl 3) or ((b13 shr 5) and 6),
            (b[11] and 1) or ((b[5] and 0xFF) shl 3) or ((b13 shr 3) and 6),
        )
        val out = ArrayList<OuraIBI>()
        for (k in 0 until 6) {
            if (ibi[k] <= 0) continue                      // drop a zero IBI, never invent one
            val amp = ((b[6 + k] and 0xFF) shr 1) shl shift   // 7-bit mantissa << exponent
            out.add(
                OuraIBI(
                    ringTimestamp = rec.ringTimestamp, ibiMs = ibi[k], amplitude = amp,
                    channel = channel,
                ),
            )
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Green IBI + amplitude CANDIDATE decode (0x71; s6.2, upstream #287)

    /** Result of [decodeGreenIBIAmpCandidate]: the amplitude exponent + the six walk-order entries. */
    data class GreenIBIAmpCandidate(val shift: Int, val samples: List<OuraIBI>)

    /**
     * CANDIDATE decode of the 0x71 green_ibi_and_amp_event, ported verbatim from ringverse's
     * `p_green_ibi_and_amp` (parse.js, firmware @0x503960): 5 densely bit-packed 11-bit IBIs +
     * amplitudes (7-bit mantissa << shift), first entry amplitude-only (`ibiMs == 0`), timestamps
     * walking backward from the event time by each IBI in turn (caller's job — entries are returned
     * in that walk order). `shift` comes from payload[13] bits [2:0] (`s == 7 → 0`, else `s+1`);
     * bit [3] set means a firmware-layout mismatch → null (never guess).
     *
     * TIER-B (#287): this layout has NO verified NOOP capture yet — the result is for the 0x71
     * fixture-capture log ONLY (side-by-side with the raw bytes, cross-checked against concurrent
     * live-HR R-R), never a stored rrInterval. Payload indexing: ringverse's `b[i]` spans the whole
     * frame (type/len/rt4/body); our `payload` starts at spec offset 6, so `b[i] == payload[i-6]`.
     * Strict 14-byte gate (= wire len 18). Byte-identical twin of Swift's decodeGreenIBIAmpCandidate.
     */
    fun decodeGreenIBIAmpCandidate(payload: IntArray, ringTimestamp: Long): GreenIBIAmpCandidate? {
        if (payload.size != 14) return null
        val b13 = payload[13] and 0xFF
        if ((b13 shr 3) and 1 == 1) return null   // reserved bit set → firmware mismatch
        val s = b13 and 7
        val shift = if (s == 7) 0 else s + 1
        val b12 = payload[12] and 0xFF
        // Each 11-bit IBI: 1 low bit (an amplitude byte's LSB) | 8 mid bits (a full byte << 3)
        // | 2 bits [2:1] from the pack bytes. Ordering per the firmware's scrambled layout.
        val ds = intArrayOf(
            (payload[10] and 1) or ((payload[4] and 0xFF) shl 3) or ((b13 shr 5) and 6),
            (payload[9] and 1) or ((payload[3] and 0xFF) shl 3) or ((b12 and 3) shl 1),
            (payload[8] and 1) or ((payload[2] and 0xFF) shl 3) or ((b12 shr 1) and 6),
            (payload[7] and 1) or ((payload[1] and 0xFF) shl 3) or ((b12 shr 3) and 6),
            (payload[6] and 1) or ((payload[0] and 0xFF) shl 3) or ((b12 shr 5) and 6),
        )
        val amps = IntArray(5) { ((payload[6 + it] and 0xFF) shr 1) shl shift }
        val samples = ArrayList<OuraIBI>(6)
        samples.add(OuraIBI(ringTimestamp = ringTimestamp, ibiMs = 0, amplitude = amps[0]))
        for (i in 0 until 5) {
            samples.add(OuraIBI(ringTimestamp = ringTimestamp, ibiMs = ds[i], amplitude = amps[i]))
        }
        return GreenIBIAmpCandidate(shift = shift, samples = samples)
    }

    // MARK: - Green IBI quality, 2 bytes/sample (0x80; s6.4)

    /**
     * Decode the 0x80 green_ibi_quality_event: per 2-byte sample `ibi_ms = (b1 & 7) | (b0 << 3)` (an
     * 11-bit value, high byte first — NOT a little-endian u16), `quality = (b1 >> 3) & 3`. Accept a
     * sample only when `quality == 1` (the ring's "good beat" flag) and the IBI is physiological
     * (300..2000 ms). Up to 7 samples per 14-byte record. Per the native `parse_api_green_ibi_quality
     * _event`. Returns null on a short body.
     *
     * NOTE (#511, decode fix): the previous layout read a little-endian u16 and masked bits 0-10, placing the
     * high byte in the LOW bits — a bit-order error that scrambled the interval (real-capture within-
     * record jitter 583ms). This high-byte-first layout with the `quality == 1` gate yields a clean beat
     * train (45ms jitter). Validated against open_oura. Byte-identical twin of Swift's decodeGreenIBIQuality.
     */
    fun decodeGreenIBIQuality(rec: OuraRecord): List<OuraIBI>? {
        val b = rec.payload
        if (b.size < 2) return null
        val maxSamples = 7                              // s6.4: 7 samples per 14-byte record
        val out = ArrayList<OuraIBI>()
        var i = 0
        var sampleCount = 0
        while (i + 1 < b.size && sampleCount < maxSamples) {
            val ibi = (b[i + 1] and 0x07) or ((b[i] and 0xFF) shl 3)   // high byte first
            val quality = (b[i + 1] shr 3) and 0x03
            if (quality == 1 && ibi in 300..2000) {
                out.add(
                    OuraIBI(
                        ringTimestamp = rec.ringTimestamp, ibiMs = ibi,
                        channel = OuraIbiChannel.GREEN_QUALITY,
                    ),
                )
            }
            i += 2
            sampleCount += 1
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - SpO2 IBI + amplitude, REVERSE byte order (0x6E; s6.3)

    /**
     * Decode the 0x6E spo2_ibi_and_amplitude_event: byte6 bits [7:6]=flag+shift, [3:0]=mode;
     * 5 IBIs as 8-bit counts x8 read bytes 11->7 (REVERSE). Per OURA_PROTOCOL.md s6.3. Returns null on
     * a short body. (The reverse read is the footgun: we walk index 11 down to 7.)
     *
     * SCOPE NOTE (honest, not accidental): the 0x6E record also carries a 7-amplitude PPG channel
     * (s6.3: "7 amplitudes: first byte<<3, rest byte<<shift"). NOOP v1 deliberately decodes the R-R
     * (IBI) channel ONLY and drops the amplitude channel, exactly as the 0x47 motion decoder is held
     * out of v1 scope. This partial decode is an explicit scope choice, not a missed field.
     */
    fun decodeSpO2IBI(rec: OuraRecord): List<OuraIBI>? {
        val b = rec.payload
        // body[0] is spec offset 6; the 5 IBI bytes are spec offsets 7..11 => body[1..5], read reversed.
        if (b.size < 6) return null
        val out = ArrayList<OuraIBI>()
        var idx = 5
        while (idx >= 1) {
            val ibi = b[idx] * 8                          // 8-bit count x8 -> ms
            if (ibi > 0) {
                out.add(
                    OuraIBI(
                        ringTimestamp = rec.ringTimestamp, ibiMs = ibi,
                        channel = OuraIbiChannel.SPO2_IBI,
                    ),
                )
            }
            idx -= 1
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - HRV / RMSSD (0x5D; s6.9)

    /**
     * Decode the 0x5D hrv_event: a run of (u8 avg HR bpm, u8 avg RMSSD ms) pairs, ONE per 5-min bucket
     * (per open_oura decode_hrv / OURA_PROTOCOL.md s6.9). The previous layout read a 4-byte
     * (u16 time, int8, int8) stride — a mis-framing that garbled the first (hr,rmssd) byte-pair into a
     * bogus time_ms, sign-flipped the RMSSD byte, and only its b1 accidentally landed on a real HR byte.
     * Both bytes are UNSIGNED (no scaling). Returns null on an empty or ODD-length body (no partial pair).
     * Validated overnight: the hr byte tracks sleeping HR (~52 bpm, matching the #511 IBI-derived median).
     * Twin of Swift decodeHRV.
     *
     * PADDING (#1128): a record that closes early pads its tail with a `00 00` pair, and that is NOT a
     * reading — a stored `hr_bpm: 0` is a value the ring never asserted, indistinguishable downstream from
     * a measurement. Observed on a real overnight: 2 of 22 records were partial, both padded, and both
     * zero pairs persisted into the 5-min series beside 110 genuine buckets running 45-64 bpm. They are
     * skipped here, at decode, so an absent bucket stays absent instead of becoming a zero one.
     *
     * The test is BOTH bytes zero — the exact padding signature — not `hrBpm == 0` alone. A lone zero HR
     * beside a non-zero RMSSD has never been observed, and if it ever occurs it is a DIFFERENT fault (a
     * real record with a bad byte) that should stay visible rather than be silently swallowed by a padding
     * rule. Narrower is the honest choice while one night is all the evidence there is.
     *
     * `index` advances for EVERY pair, including a skipped one, because it is not a label: the consumer
     * derives the bucket's wall-clock from it (`OuraStreamMapping`, `bucketTs = ts - index * 300`).
     * Renumbering the survivors would slide every later bucket 5 minutes. That is invisible for TAIL
     * padding — the only shape observed — which is exactly why it is pinned by test instead of by luck.
     */
    fun decodeHRV(rec: OuraRecord): List<OuraHRV>? {
        val b = rec.payload
        if (b.size < 2 || b.size % 2 != 0) return null   // N complete (hr, rmssd) pairs
        val out = ArrayList<OuraHRV>()
        var i = 0
        var index = 0
        while (i + 2 <= b.size) {
            val hr = b[i]
            val rmssd = b[i + 1]
            if (!(hr == 0 && rmssd == 0)) {
                out.add(OuraHRV(ringTimestamp = rec.ringTimestamp, index = index, hrBpm = hr, rmssdMs = rmssd))
            }
            i += 2
            index += 1
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - SpO2 per-sample (0x6F; s6.5)

    /**
     * Decode the 0x6F spo2_event: byte6 bits [7:4]=SpO2 base/status field, [3:0]=status flag; then one
     * uint8 SpO2 value per second from byte7 onward (optional 0xFF terminator). Per OURA_PROTOCOL.md
     * s6.5. Returns null on a short body.
     *
     * UNIT TAG: these samples carry the default `unit = "raw"`, which is a legacy CHANNEL label, not a
     * claim about the quantity — 0x6F is a firmware-computed PERCENTAGE (s6.5, corroborated by
     * open_oura), unlike 0x77 which really is a raw DC channel and tags itself `"dc_raw"`. The string is
     * deliberately left alone: it is a persisted column, no consumer branches on it, and rewriting it
     * would split stored history across two spellings of the same channel for a cosmetic gain. Swift
     * `OuraDecoders.decodeSpO2PerSample` matches exactly.
     *
     * s6.5 also records an OPEN ISSUE: ~47% of decoded 0x6F samples exceed 100%, which no ground truth
     * yet explains, so no offset is applied here — a guessed calibration would be worse than the gap.
     * These land in the RAW channel (`Spo2Sample.red`), never in a percentage field, so an impossible
     * value is not surfaced as a Blood Oxygen reading.
     */
    fun decodeSpO2PerSample(rec: OuraRecord): List<OuraSpO2>? {
        val b = rec.payload
        if (b.size < 2) return null
        // byte6 high nibble [7:4] is a base/status field, NOT an offset to add to each sample. Real Gen 3
        // captures (#968, pipiche38) show samples[] are DIRECT SpO2 percentages (~95-96), so adding the
        // scaled base produced impossible ~223% readings. The samples themselves are the percentage.
        val out = ArrayList<OuraSpO2>()
        var i = 1
        while (i < b.size) {
            val raw = b[i]
            if (raw == 0xFF) break                       // terminator
            // The samples are one PER SECOND, so each carries its position in the record: ringTimestamp
            // stays the record's anchor and the consumer spreads them over their own seconds. Without the
            // position the offset is unrecoverable downstream and 12 of every 13 samples collide away on
            // the (deviceId, ts) primary key (#1070). Swift twin matches exactly.
            out.add(OuraSpO2(ringTimestamp = rec.ringTimestamp, value = raw, index = out.size))
            i += 1
        }
        return if (out.isEmpty()) null else stampSampleCount(out)
    }

    /**
     * Fill in `count` (the number of samples the record yielded) on every sample of one record. The
     * total is only known once the body has been walked, so the decoders stamp `index` inline and the
     * count in one pass at the end. Twin of Swift `stampSampleCount`.
     */
    private fun stampSampleCount(samples: List<OuraSpO2>): List<OuraSpO2> {
        val n = samples.size
        return samples.map { it.copy(count = n) }
    }

    // MARK: - SpO2 stable, BIG-endian (0x7B; s6.6)

    /**
     * Decode the 0x7B spo2_stable_event: a SINGLE uint16 BIG-endian at bytes 6-7. This is the lone
     * exception to the LE default. Per OURA_PROTOCOL.md s6.6. Returns null on a short body.
     */
    fun decodeSpO2Stable(rec: OuraRecord): OuraSpO2? {
        val b = rec.payload
        if (b.size < 2) return null
        val value = u16be(b, 0)                          // BIG-endian footgun
        return OuraSpO2(ringTimestamp = rec.ringTimestamp, value = value)
    }

    // MARK: - SpO2 DC, sign-magnitude deltas (0x77; s6.7)

    /**
     * Decode the 0x77 spo2_dc_event: byte6 bit[7]=HDR low bit, bit[6]=hasBase, bits[5:4]=scale shift.
     * If hasBase: bytes 7-9 = 24-bit LE base. Remaining bytes are sign-magnitude int8 deltas:
     * v=(int8)raw; mag=|v|<<scale; out = v<0 ? -mag : mag, accumulated. Per OURA_PROTOCOL.md s6.7.
     */
    fun decodeSpO2DC(rec: OuraRecord): List<OuraSpO2>? {
        val b = rec.payload
        if (b.isEmpty()) return null
        val header = b[0]
        val hasBase = (header and 0x40) != 0
        val scale = (header shr 4) and 0x03
        var i = 1
        var acc = 0
        if (hasBase) {
            if (b.size < 4) return null
            acc = u24le(b, 1)
            i = 4
        }
        val out = ArrayList<OuraSpO2>()
        if (hasBase) {
            out.add(OuraSpO2(ringTimestamp = rec.ringTimestamp, value = acc, unit = "dc_raw", index = 0))
        }
        while (i < b.size) {
            val v = i8(b[i])
            val mag = Math.abs(v) shl scale
            acc += if (v < 0) -mag else mag
            // Same per-sample position as 0x6F (see #1070): this record is multi-sample too, and its
            // samples reach the same (deviceId, ts)-keyed table, so they collide the same way.
            out.add(OuraSpO2(ringTimestamp = rec.ringTimestamp, value = acc, unit = "dc_raw", index = out.size))
            i += 1
        }
        return if (out.isEmpty()) null else stampSampleCount(out)
    }

    // MARK: - Temperature (0x46 / 0x69 / 0x75; s6.8)

    /**
     * Decode the 0x46 temp_event: up to 7 samples, each int16 LE / 100 = C. Even body length.
     * Per OURA_PROTOCOL.md s6.8. Returns null on a short/odd body.
     *
     * ROBUSTNESS (s6.8): the record holds at most 7 samples. We cap the read at 7; sample bytes beyond
     * the 7th are a misframe (a longer record is not a real temp_event) and are ignored.
     */
    fun decodeTemp(rec: OuraRecord): List<OuraTemp>? {
        val b = rec.payload
        if (b.size < 2 || b.size % 2 != 0) return null
        val maxSamples = 7                              // s6.8: up to 7 samples per temp_event
        val out = ArrayList<OuraTemp>()
        var i = 0
        while (i + 1 < b.size && out.size < maxSamples) {
            val c = i16le(b, i).toDouble() / 100.0
            out.add(OuraTemp(ringTimestamp = rec.ringTimestamp, celsius = c))
            i += 2
        }
        return if (out.isEmpty()) null else out
    }

    /** Decode the 0x69 temp_period: a single int16 LE / 100 = C. Per OURA_PROTOCOL.md s6.8. */
    fun decodeTempPeriod(rec: OuraRecord): OuraTemp? {
        val b = rec.payload
        if (b.size < 2) return null
        return OuraTemp(ringTimestamp = rec.ringTimestamp, celsius = i16le(b, 0).toDouble() / 100.0)
    }

    /**
     * Decode the 0x75 sleep_temp_event: uint16 LE / 100 = C, 30-second spacing. Per OURA_PROTOCOL.md
     * s6.8. Returns null on a short/odd body.
     */
    fun decodeSleepTemp(rec: OuraRecord): List<OuraTemp>? {
        val b = rec.payload
        if (b.size < 2 || b.size % 2 != 0) return null
        val out = ArrayList<OuraTemp>()
        var i = 0
        while (i + 1 < b.size) {
            val c = u16le(b, i).toDouble() / 100.0        // unsigned for sleep temp
            out.add(OuraTemp(ringTimestamp = rec.ringTimestamp, celsius = c))
            i += 2
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Battery (0x0D outer response; s6.10)

    /**
     * Decode the 0x0D battery response BODY (the 8 bytes after `0d <len>`). percent at body[0];
     * voltage estimate as uint16 LE at body[4..6] (fallback only). charging_progress at body[1],
     * recommended_flag at body[2]. Per OURA_PROTOCOL.md s6.10. Returns null on a short body.
     *
     * CONFLICT (s6.10): open_oura-r3 reads percent at body[0], open_ring reads voltage at [4]. NOOP
     * rule: percent from body[0]; voltage from [4..6] is a fixture-validated fallback estimate only.
     */
    fun decodeBattery(body: IntArray): OuraBattery? {
        if (body.size < 3) return null
        val percent = body[0]
        if (percent > 100) return null                   // a >100 "percent" is a misread, not a guess
        val chargingProgress = body[1]
        val voltage: Int? = if (body.size >= 6) u16le(body, 4) else null
        // charging_progress > 0 indicates an active charge cycle (per s6.10 field name).
        return OuraBattery(percent = percent, voltageMv = voltage, charging = chargingProgress > 0)
    }

    // MARK: - Time sync (0x42; s6.11)

    /**
     * Decode the 0x42 time-sync ind: bytes 6-13 = int64 LE epoch ms; byte14 = int8 tz offset in
     * 30-min units (x1800 = seconds). Per OURA_PROTOCOL.md s6.11. Returns null on a short body.
     */
    fun decodeTimeSync(rec: OuraRecord): OuraTimeSync? {
        val b = rec.payload
        // body[0..8] = epoch ms (8 bytes), body[8] = tz offset.
        if (b.size < 9) return null
        var epoch = 0L
        for (k in 0 until 8) epoch = epoch or ((b[k].toLong() and 0xFFL) shl (8 * k))
        val tz = i8(b[8]) * 1800
        return OuraTimeSync(ringTimestamp = rec.ringTimestamp, epochMs = epoch, tzOffsetSeconds = tz)
    }

    // MARK: - RTC beacon (0x85; s6.15)

    /**
     * Decode the 0x85 rtc_beacon_ind: unix_s u32 LE, reserved 4 B, trailer u16 LE in {0x01F6,0x01F8}.
     * Per OURA_PROTOCOL.md s6.15. Returns null on a short body.
     */
    fun decodeRtcBeacon(rec: OuraRecord): OuraRtcBeacon? {
        val b = rec.payload
        if (b.size < 4) return null
        return OuraRtcBeacon(ringTimestamp = rec.ringTimestamp, unixSeconds = u32le(b, 0))
    }

    // MARK: - State / wear (0x45 / 0x53; s6.15)

    /**
     * Decode the 0x45 state_change_ind / 0x53 wear_event: byte6 = STATE_* enum; optional trailing
     * UTF-8 string when payload > 5. Per OURA_PROTOCOL.md s6.15. Returns null on an empty body.
     */
    fun decodeState(rec: OuraRecord): OuraState? {
        val b = rec.payload
        if (b.isEmpty()) return null
        val code = b[0]
        var text: String? = null
        if (b.size > 5) {
            val tailBytes = ByteArray(b.size - 1) { b[it + 1].toByte() }
            // Swift trims the NUL character set; match that exactly (trim only U+0000, not whitespace).
            text = String(tailBytes, Charsets.UTF_8).trim('\u0000')
        }
        return OuraState(ringTimestamp = rec.ringTimestamp, stateCode = code, text = text)
    }

    // Feature-status read reply (0x2F sub-op 0x21; s5.6 / s7.1)

    /**
     * Decode a feature-status read reply's SUB-BODY (the bytes AFTER the `0x21` sub-op) into
     * feature/mode/status/state/subscription, the ring's own feature report [open_oura-feat]. The observed
     * daytime-HR reply is `2f 06 21 02 01 11 02 00` → sub-body `02 01 11 02 00`. Returns null on a short body
     * (< 5) so a truncated reply never fabricates a status. READ-ONLY diagnostic. Kotlin twin of Swift.
     */
    fun decodeFeatureStatus(subBody: IntArray): OuraFeatureStatus? {
        if (subBody.size < 5) return null
        return OuraFeatureStatus(subBody[0], subBody[1], subBody[2], subBody[3], subBody[4])
    }

    // MARK: - Debug text (0x43; s6.15)

    /**
     * Decode the 0x43 debug_event: ASCII state strings. Per OURA_PROTOCOL.md s6.15. Returns null when
     * the body is empty.
     */
    fun decodeDebugText(rec: OuraRecord): String? {
        if (rec.payload.isEmpty()) return null
        val raw = ByteArray(rec.payload.size) { rec.payload[it].toByte() }
        return String(raw, Charsets.UTF_8)
    }

    // MARK: - Sleep phase, 2-bit codes (0x4E / 0x5A; s6.12)

    /**
     * Decode the 0x4E/0x5A sleep_phase_details: byte6 = header; phase codes are 2-bit, 4 per byte
     * (bits [7:6][5:4][3:2][1:0]); codes 0=awake,1=light,2=deep,3=REM. Per OURA_PROTOCOL.md s6.12.
     * Returns null on a short body. The header byte is skipped; phase bytes follow.
     */
    fun decodeSleepPhase(rec: OuraRecord): List<OuraSleepPhase>? {
        val b = rec.payload
        // body[0] is the header (spec offset 6); phase codes begin at body[1].
        if (b.size < 2) return null
        val out = ArrayList<OuraSleepPhase>()
        var index = 0
        for (k in 1 until b.size) {
            val byte = b[k]
            // MSB-first within the byte: [7:6] is the first code.
            var shift = 6
            while (shift >= 0) {
                val code = (byte shr shift) and 0x03
                val stage = OuraSleepStage.fromRaw(code)
                if (stage != null) {
                    out.add(OuraSleepPhase(ringTimestamp = rec.ringTimestamp, index = index, stage = stage))
                    index += 1
                }
                shift -= 2
            }
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Motion period, 2-bit MOTION_STATE codes (0x6B; s6.13)

    /**
     * Decode the 0x6B motion_period: 12-bit period header, byte6 bits[5:4]=leading-symbol count, then
     * 2-bit MOTION_STATE codes, 4 per byte (MSB-first). 0=NO_MOTION,1=RESTLESS,2=TOSSING,3=ACTIVE.
     * Per OURA_PROTOCOL.md s6.13. Returns null on a short body. The first two bytes carry the period
     * header; codes follow from byte index 2.
     */
    fun decodeMotionPeriod(rec: OuraRecord): List<OuraMotion>? {
        val b = rec.payload
        if (b.size < 3) return null
        val out = ArrayList<OuraMotion>()
        var index = 0
        for (k in 2 until b.size) {
            val byte = b[k]
            var shift = 6
            while (shift >= 0) {
                val code = (byte shr shift) and 0x03
                val state = OuraMotionState.fromRaw(code)
                if (state != null) {
                    out.add(OuraMotion(ringTimestamp = rec.ringTimestamp, index = index, state = state))
                    index += 1
                }
                shift -= 2
            }
        }
        return if (out.isEmpty()) null else out
    }

    // MARK: - Motion events, averaged accel vector (0x47; s6.13)

    /**
     * Decode a 0x47 motion_events record: a compact per-window motion summary. Byte-for-byte port of
     * open_oura's decode_motion / parse_api_motion_events (clean-room fact citation; OURA_PROTOCOL.md
     * s6.13):
     *   byte0 >> 5   = orientation (0..7)
     *   byte0 & 0x1f = motion_seconds (0..31)
     *   byte1/2/3    = avg X/Y/Z, signed int8 × 8
     *   byte4 (opt)  = low_intensity: bit 0x40 set ⇒ INVALID (record → null); else & 0x3f
     *   byte5 (opt)  = high_intensity: bit 0x40 set ⇒ INVALID (record → null); else & 0x3f
     * Needs ≥ 4 bytes; low/high optional. 0x47 is MOVEMENT-GATED (validated #804): emitted only while
     * moving, so there is no still/1 g sample — motion_seconds / intensity are the activity signal, not a
     * gravity magnitude. Byte-identical twin of Swift.
     */
    fun decodeMotionEvents(rec: OuraRecord): OuraMotionEvent? {
        val b = rec.payload
        if (b.size < 4) return null
        var low: Int? = null
        if (b.size >= 5) {
            if (b[4] and 0x40 != 0) return null
            low = b[4] and 0x3f
        }
        var high: Int? = null
        if (b.size >= 6) {
            if (b[5] and 0x40 != 0) return null
            high = b[5] and 0x3f
        }
        return OuraMotionEvent(
            ringTimestamp = rec.ringTimestamp,
            orientation = b[0] shr 5,
            motionSeconds = b[0] and 0x1f,
            avgX = i8(b[1]) * 8,
            avgY = i8(b[2]) * 8,
            avgZ = i8(b[3]) * 8,
            lowIntensity = low,
            highIntensity = high,
        )
    }

    // MARK: - Activity info (0x50; s6.13) - Tier B, third-party formula

    /**
     * Decode the 0x50 activity_info record: byte0 = a `state` code (activity-category; meaning
     * unconfirmed), every following byte = one MET sample. Formula (OURA_PROTOCOL.md s6.13, [oura-rs],
     * clean-room fact citation): `met = byte * 0.1` for byte < 0x80, else `met = 12.8 + (byte - 128) * 0.2`
     * (a two-slope encoding: 0.1-MET resolution up to 12.7, coarser 0.2 steps above). THIRD-PARTY and NOT
     * ground-truth-validated against the Oura app, so this stays Tier B end to end: OuraDriver gates it
     * behind `allowTierB`, and OuraStreamMapping never folds it into a durable stream. Values are
     * normalised to 2 decimal places so a decoded MET compares exactly against its fixture (0.1 is not
     * exactly representable in binary floating point; same normalisation as the Swift twin, so both
     * platforms decode identical doubles). Returns null on an empty body - a record with no state byte
     * decodes to nothing, never a guess.
     */
    fun decodeActivityInfo(rec: OuraRecord): OuraActivityInfo? {
        val b = rec.payload
        if (b.isEmpty()) return null
        val met = ArrayList<Double>(b.size - 1)
        for (k in 1 until b.size) {
            val raw = if (b[k] < 0x80) b[k] * 0.1 else 12.8 + (b[k] - 128) * 0.2
            met.add(Math.round(raw * 100.0) / 100.0)
        }
        return OuraActivityInfo(ringTimestamp = rec.ringTimestamp, state = b[0], met = met)
    }
}
