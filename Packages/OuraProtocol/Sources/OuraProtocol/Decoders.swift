import Foundation

// Decoders: pure per-tag byte->value decoders (OURA_PROTOCOL.md s6). Each returns nil on a
// malformed/short record (honest-data invariant): NEVER a guessed value. Body offsets in the spec are
// relative to the start of the RECORD (offset 6 = first body byte); the parsed OuraRecord already
// stripped the 6-byte header, so here `body[0]` == spec offset 6.
//
// FOOTGUN WATCH (per the brief + OURA_PROTOCOL.md s6 risks):
//   - 0x7B SpO2 is BIG-endian (the lone exception to the LE default).
//   - 0x6E reads IBIs in REVERSE byte order.
//   - 0x80 / 0x60 are bit-packed across byte boundaries.
//   - live-HR IBI uses a 12-bit LE-ish nibble at subBody[5..6]: ((b6 & 0x0F) << 8) | b5.
//
// Platform-pure value types. All facts cited tersely per OURA_PROTOCOL.md s6.

public enum OuraDecoders {

    // MARK: - Little-endian helpers (body offset == spec offset - 6)

    @inline(__always) static func u16le(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }
    @inline(__always) static func u16be(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 8) | Int(b[i + 1])
    }
    @inline(__always) static func i16le(_ b: [UInt8], _ i: Int) -> Int {
        Int(Int16(bitPattern: UInt16(b[i]) | (UInt16(b[i + 1]) << 8)))
    }
    @inline(__always) static func u24le(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16)
    }
    @inline(__always) static func u32le(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    // MARK: - GetProductInfo reply (serial / hardware pages; s4.1 / s7.3)

    /// Decode a GetProductInfo reply body (the serial page `18 03 08 00 10` or the hardware page
    /// `18 03 18 00 10`, both answered under outer op 0x19). On-device capture 2026-07-24 (Gen3): the body is
    /// `byte0 = 0x00 status/OK, then a NUL-terminated ASCII string, NUL-padded` — e.g. serial "2H3B2405003655"
    /// or hardware id "BLB_03". Returns the trimmed ASCII string, or nil for an empty/non-printable body.
    public static func productInfoString(_ body: [UInt8]) -> String? {
        guard body.count > 1 else { return nil }
        let ascii = body.dropFirst().prefix(while: { $0 != 0x00 })
        guard !ascii.isEmpty, ascii.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
        return String(bytes: ascii, encoding: .ascii)
    }

    // MARK: - Live-HR realtime push (0x2F sub-op 0x28; s5.6)

    /// Decode a live-HR push body (the bytes AFTER `2f 0f 28`). Per OURA_PROTOCOL.md s5.6 the wire
    /// frame is `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f`. The spec lists the IBI at
    /// frame bytes 8-9; once the transport strips the 3-byte `2f 0f 28` prefix those indices shift down
    /// by 3, so within this subBody the IBI sits at subBody[5..6] as a 12-bit value:
    /// ((b6 & 0x0F) << 8) | b5; bpm = round(60000 / ibi). Returns nil on a short body or a
    /// zero/implausible IBI.
    ///
    /// `ringTimestamp` is supplied by the caller (the push is not a TLV record; the driver stamps it
    /// with the live ring time). Example subBody[5..6] = `01 04` -> ibi 1025 ms -> ~59 bpm.
    public static func decodeLiveHRPush(_ body: [UInt8], ringTimestamp: UInt32) -> OuraHR? {
        guard body.count >= 7 else { return nil }
        let ibi = ((Int(body[6]) & 0x0F) << 8) | Int(body[5])
        guard ibi > 0 else { return nil }
        let bpm = Int((60000.0 / Double(ibi)).rounded())
        guard bpm > 0 && bpm < 300 else { return nil }   // reject implausible derived BPM, never guess
        return OuraHR(ringTimestamp: ringTimestamp, bpm: bpm, ibiMs: ibi)
    }

    // MARK: - IBI + amplitude, byte-scatter packed (0x60; s6.1)

    /// Decode the 0x60 ibi_and_amplitude_event: a fixed 14-byte packet holding 6 IBIs (ms) + PPG
    /// amplitudes. Each 11-bit IBI is gathered from SCATTERED bytes, NOT a linear bitstream — per the
    /// ring's native `parse_api_ibi_and_amplitude_event`: `ibi[k] = (b[6+k]&1) | (b[k]<<3) | <2 hi bits
    /// from the b[12]/b[13] nibbles>`. Amplitude = `(b[6+k] >> 1) << shift`, exponent = low nibble of
    /// b[13] (shift = (n==7) ? 0 : n+1). Returns nil on a short body.
    ///
    /// NOTE (#511, decode fix): the previous layout read the body as a linear MSB-first bitstream, which
    /// only ever recovered the FIRST IBI correctly and scrambled the other five — a real overnight
    /// capture decoded to an 82% beat-to-beat >200ms "jump" rate (not a heartbeat train). This
    /// byte-scatter layout, cross-checked against the same capture, yields a coherent ~60 bpm train
    /// (10% jump rate) that tracks the night's sleep stages and its day/night dip. Validated against
    /// the `open_oura` decompiled `parse_api_ibi_and_amplitude_event`.
    /// - Parameter channel: which tag's record this is. 0x60 and 0x44 share this layout byte for byte,
    ///   so they share the decoder — but they are different tags on the wire, and the caller states
    ///   which one it routed here so the beat carries its true origin (#1071 follow-up). Defaults to
    ///   0x60's channel, which is what every existing call site means.
    public static func decodeIBIAmplitude(_ rec: OuraRecord,
                                          channel: OuraIBIChannel = .ibiAmplitude) -> [OuraIBI]? {
        let b = rec.payload
        guard b.count >= 14 else { return nil }   // fixed 14-byte packet (body bytes 6..19)
        let b12 = Int(b[12]), b13 = Int(b[13])
        let n = b13 & 0x0F
        let shift = (n == 7) ? 0 : (n + 1)
        let ibi = [
            (Int(b[6])  & 1) | (Int(b[0]) << 3) | ((b12 >> 5) & 6),
            (Int(b[7])  & 1) | (Int(b[1]) << 3) | ((b12 >> 3) & 6),
            (Int(b[8])  & 1) | (Int(b[2]) << 3) | ((b12 >> 1) & 6),
            (Int(b[9])  & 1) | (Int(b[3]) << 3) | ((b12 & 3) << 1),
            (Int(b[10]) & 1) | (Int(b[4]) << 3) | ((b13 >> 5) & 6),
            (Int(b[11]) & 1) | (Int(b[5]) << 3) | ((b13 >> 3) & 6),
        ]
        var out: [OuraIBI] = []
        for k in 0..<6 {
            guard ibi[k] > 0 else { continue }                 // drop a zero IBI, never invent one
            let amp = (Int(b[6 + k]) >> 1) << shift            // 7-bit mantissa << exponent
            out.append(OuraIBI(ringTimestamp: rec.ringTimestamp, ibiMs: ibi[k], amplitude: amp,
                               channel: channel))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Green IBI + amplitude CANDIDATE decode (0x71; s6.2, upstream #287)

    /// CANDIDATE decode of the 0x71 green_ibi_and_amp_event, ported verbatim from ringverse's
    /// `p_green_ibi_and_amp` (parse.js, firmware @0x503960): 5 densely bit-packed 11-bit IBIs +
    /// amplitudes (7-bit mantissa << shift), first entry amplitude-only (`ibiMs == 0`), timestamps
    /// walking backward from the event time by each IBI in turn (caller's job — entries are returned
    /// in that walk order). `shift` comes from payload[13] bits [2:0] (`s == 7 → 0`, else `s+1`);
    /// bit [3] set means a firmware-layout mismatch → nil (never guess).
    ///
    /// TIER-B (#287): this layout has NO verified NOOP capture yet — the result is for the 0x71
    /// fixture-capture log ONLY (side-by-side with the raw bytes, cross-checked against concurrent
    /// live-HR R-R), never a stored rrInterval. Promote only after a real capture validates it.
    /// Payload indexing: ringverse's `b[i]` spans the whole frame (type/len/rt4/body); our `payload`
    /// starts at spec offset 6, so `b[i] == payload[i-6]`. Strict 14-byte gate (= wire len 18).
    public static func decodeGreenIBIAmpCandidate(payload p: [UInt8], ringTimestamp: UInt32)
        -> (shift: Int, samples: [OuraIBI])? {
        guard p.count == 14 else { return nil }
        let b13 = Int(p[13])
        guard (b13 >> 3) & 1 == 0 else { return nil }   // reserved bit set → firmware mismatch
        let s = b13 & 7
        let shift = (s == 7) ? 0 : s + 1
        let b12 = Int(p[12])
        // Each 11-bit IBI: 1 low bit (an amplitude byte's LSB) | 8 mid bits (a full byte << 3)
        // | 2 bits [2:1] from the pack bytes. Ordering per the firmware's scrambled layout.
        let ds = [
            (Int(p[10]) & 1) | (Int(p[4]) << 3) | ((b13 >> 5) & 6),
            (Int(p[9]) & 1) | (Int(p[3]) << 3) | ((b12 & 3) << 1),
            (Int(p[8]) & 1) | (Int(p[2]) << 3) | ((b12 >> 1) & 6),
            (Int(p[7]) & 1) | (Int(p[1]) << 3) | ((b12 >> 3) & 6),
            (Int(p[6]) & 1) | (Int(p[0]) << 3) | ((b12 >> 5) & 6),
        ]
        let amps = (6...10).map { (Int(p[$0]) >> 1) << shift }
        var samples = [OuraIBI(ringTimestamp: ringTimestamp, ibiMs: 0, amplitude: amps[0])]
        for i in 0..<5 {
            samples.append(OuraIBI(ringTimestamp: ringTimestamp, ibiMs: ds[i], amplitude: amps[i]))
        }
        return (shift, samples)
    }

    // MARK: - Green IBI quality, 2 bytes/sample (0x80; s6.4)

    /// Decode the 0x80 green_ibi_quality_event: per 2-byte sample `ibi_ms = (b1 & 7) | (b0 << 3)`
    /// (an 11-bit value, high byte first — NOT a little-endian u16), `quality = (b1 >> 3) & 3`. Accept a
    /// sample only when `quality == 1` (the ring's "good beat" flag) and the IBI is physiological
    /// (300..2000 ms). Up to 7 samples per 14-byte record. Per the native `parse_api_green_ibi_quality
    /// _event`. Returns nil on a short body.
    ///
    /// NOTE (#511, decode fix): the previous layout read a little-endian u16 and masked bits 0-10, placing
    /// the high byte in the LOW bits — a bit-order error that scrambled the interval (real-capture
    /// within-record jitter 583ms). This high-byte-first layout with the `quality == 1` gate yields a
    /// clean beat train (45ms jitter) and keeps MORE good beats. Validated against `open_oura`.
    public static func decodeGreenIBIQuality(_ rec: OuraRecord) -> [OuraIBI]? {
        let b = rec.payload
        guard b.count >= 2 else { return nil }
        let maxSamples = 7                            // s6.4: 7 samples per 14-byte record
        var out: [OuraIBI] = []
        var i = 0
        var sampleCount = 0
        while i + 1 < b.count && sampleCount < maxSamples {
            let ibi = (Int(b[i + 1]) & 0x07) | (Int(b[i]) << 3)   // high byte first
            let quality = (Int(b[i + 1]) >> 3) & 0x03
            if quality == 1 && ibi >= 300 && ibi <= 2000 {
                out.append(OuraIBI(ringTimestamp: rec.ringTimestamp, ibiMs: ibi,
                                   channel: .greenQuality))
            }
            i += 2
            sampleCount += 1
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - SpO2 IBI + amplitude, REVERSE byte order (0x6E; s6.3)

    /// Decode the 0x6E spo2_ibi_and_amplitude_event: byte6 bits [7:6]=flag+shift, [3:0]=mode;
    /// 5 IBIs as 8-bit counts x8 read bytes 11->7 (REVERSE). Per OURA_PROTOCOL.md s6.3. Returns nil on
    /// a short body. (The reverse read is the footgun: we walk index 11 down to 7.)
    ///
    /// SCOPE NOTE (honest, not accidental): the 0x6E record also carries a 7-amplitude PPG channel
    /// (s6.3: "7 amplitudes: first byte<<3, rest byte<<shift"). NOOP v1 deliberately decodes the R-R
    /// (IBI) channel ONLY and drops the amplitude channel, exactly as the 0x47 motion decoder is held
    /// out of v1 scope. This partial decode is an explicit scope choice, not a missed field.
    public static func decodeSpO2IBI(_ rec: OuraRecord) -> [OuraIBI]? {
        let b = rec.payload
        // body[0] is spec offset 6; the 5 IBI bytes are spec offsets 7..11 => body[1..5], read reversed.
        guard b.count >= 6 else { return nil }
        var out: [OuraIBI] = []
        var idx = 5
        while idx >= 1 {
            let ibi = Int(b[idx]) * 8                  // 8-bit count x8 -> ms
            if ibi > 0 {
                out.append(OuraIBI(ringTimestamp: rec.ringTimestamp, ibiMs: ibi, channel: .spo2Ibi))
            }
            idx -= 1
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - HRV / RMSSD (0x5D; s6.9)

    /// Decode the 0x5D hrv_event: a run of `(u8 avg HR bpm, u8 avg RMSSD ms)` pairs, ONE per 5-min bucket
    /// (per open_oura `decode_hrv` / OURA_PROTOCOL.md s6.9). The previous layout read a 4-byte
    /// `(u16 time, int8, int8)` stride — a mis-framing: it garbled the first (hr,rmssd) byte-pair into a
    /// bogus `time_ms`, sign-flipped the RMSSD byte, and only its `b1` accidentally landed on a real HR
    /// byte. Both bytes are UNSIGNED (no scaling). Returns nil on an empty or ODD-length body (a partial
    /// pair is never emitted). Validated against a real overnight: the hr byte tracks sleeping HR (~52 bpm,
    /// matching the #511 IBI-derived median).
    public static func decodeHRV(_ rec: OuraRecord) -> [OuraHRV]? {
        let b = rec.payload
        guard b.count >= 2, b.count % 2 == 0 else { return nil }   // N complete (hr, rmssd) pairs
        var out: [OuraHRV] = []
        var i = 0
        var index = 0
        while i + 2 <= b.count {
            out.append(OuraHRV(ringTimestamp: rec.ringTimestamp, index: index,
                               hrBpm: Int(b[i]), rmssdMs: Int(b[i + 1])))
            i += 2
            index += 1
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - SpO2 per-sample (0x6F; s6.5)

    /// Decode the 0x6F spo2_event: byte6 bits [7:4]=SpO2 base/status field, [3:0]=status flag; then one
    /// uint8 SpO2 value per second from byte7 onward (optional 0xFF terminator). Per OURA_PROTOCOL.md
    /// s6.5. Returns nil on a short body.
    ///
    /// UNIT TAG: these samples carry the default `unit: "raw"`, which is a legacy CHANNEL label, not a
    /// claim about the quantity — 0x6F is a firmware-computed PERCENTAGE (s6.5, corroborated by
    /// open_oura), unlike 0x77 which really is a raw DC channel and tags itself `"dc_raw"`. The string
    /// is deliberately left alone: it is a persisted column (`Database.swift` spo2 `unit`), no consumer
    /// branches on it (only the CLI dump and one log line read it), and rewriting it would split stored
    /// history across two spellings of the same channel for a cosmetic gain. Kotlin matches exactly.
    ///
    /// s6.5 also records an OPEN ISSUE: ~47% of decoded 0x6F samples exceed 100%, which no ground truth
    /// yet explains, so no offset is applied here — a guessed calibration would be worse than the gap.
    /// These land in the RAW channel (`SpO2Sample.red`), never in `spo2Pct`, so an impossible value is
    /// not surfaced as a Blood Oxygen reading.
    public static func decodeSpO2PerSample(_ rec: OuraRecord) -> [OuraSpO2]? {
        let b = rec.payload
        guard b.count >= 2 else { return nil }
        // byte6 high nibble [7:4] is a base/status field, NOT an offset to add to each sample. Real Gen 3
        // captures (#968, pipiche38) show samples[] are DIRECT SpO2 percentages (~95-96), so adding the
        // scaled base produced impossible ~223% readings. The samples themselves are the percentage.
        var out: [OuraSpO2] = []
        var i = 1
        while i < b.count {
            let raw = Int(b[i])
            if raw == 0xFF { break }                  // terminator
            // The samples are one PER SECOND, so each carries its position in the record: `ringTimestamp`
            // stays the record's anchor and the consumer spreads them over their own seconds. Without the
            // position the offset is unrecoverable downstream and 12 of every 13 samples collide away on
            // the `(deviceId, ts)` primary key (#1070).
            out.append(OuraSpO2(ringTimestamp: rec.ringTimestamp, value: raw, index: out.count))
            i += 1
        }
        return out.isEmpty ? nil : stampSampleCount(out)
    }

    /// Fill in `count` (the number of samples the record yielded) on every sample of one record. The
    /// total is only known once the body has been walked, so the decoders stamp `index` inline and the
    /// count in one pass at the end.
    private static func stampSampleCount(_ samples: [OuraSpO2]) -> [OuraSpO2] {
        let n = samples.count
        return samples.map {
            OuraSpO2(ringTimestamp: $0.ringTimestamp, value: $0.value, unit: $0.unit, index: $0.index, count: n)
        }
    }

    // MARK: - SpO2 stable, BIG-endian (0x7B; s6.6)

    /// Decode the 0x7B spo2_stable_event: a SINGLE uint16 BIG-endian at bytes 6-7. This is the lone
    /// exception to the LE default. Per OURA_PROTOCOL.md s6.6. Returns nil on a short body.
    public static func decodeSpO2Stable(_ rec: OuraRecord) -> OuraSpO2? {
        let b = rec.payload
        guard b.count >= 2 else { return nil }
        let value = u16be(b, 0)                       // BIG-endian footgun
        return OuraSpO2(ringTimestamp: rec.ringTimestamp, value: value)
    }

    // MARK: - SpO2 DC, sign-magnitude deltas (0x77; s6.7)

    /// Decode the 0x77 spo2_dc_event: byte6 bit[7]=HDR low bit, bit[6]=hasBase, bits[5:4]=scale shift.
    /// If hasBase: bytes 7-9 = 24-bit LE base. Remaining bytes are sign-magnitude int8 deltas:
    /// v=(int8)raw; mag=|v|<<scale; out = v<0 ? -mag : mag, accumulated. Per OURA_PROTOCOL.md s6.7.
    public static func decodeSpO2DC(_ rec: OuraRecord) -> [OuraSpO2]? {
        let b = rec.payload
        guard b.count >= 1 else { return nil }
        let header = Int(b[0])
        let hasBase = (header & 0x40) != 0
        let scale = (header >> 4) & 0x03
        var i = 1
        var acc = 0
        if hasBase {
            guard b.count >= 4 else { return nil }
            acc = u24le(b, 1)
            i = 4
        }
        var out: [OuraSpO2] = []
        if hasBase {
            out.append(OuraSpO2(ringTimestamp: rec.ringTimestamp, value: acc, unit: "dc_raw", index: 0))
        }
        while i < b.count {
            let v = Int(Int8(bitPattern: b[i]))
            let mag = abs(v) << scale
            acc += (v < 0) ? -mag : mag
            // Same per-sample position as 0x6F (see #1070): this record is multi-sample too, and its
            // samples reach the same `(deviceId, ts)`-keyed table, so they collide the same way.
            out.append(OuraSpO2(ringTimestamp: rec.ringTimestamp, value: acc, unit: "dc_raw", index: out.count))
            i += 1
        }
        return out.isEmpty ? nil : stampSampleCount(out)
    }

    // MARK: - Temperature (0x46 / 0x69 / 0x75; s6.8)

    /// Decode the 0x46 temp_event: up to 7 samples, each int16 LE / 100 = C. Even body length.
    /// Per OURA_PROTOCOL.md s6.8. Returns nil on a short/odd body.
    ///
    /// ROBUSTNESS (s6.8): the record holds at most 7 samples. We cap the read at 7; sample bytes beyond
    /// the 7th are a misframe (a longer record is not a real temp_event) and are ignored.
    public static func decodeTemp(_ rec: OuraRecord) -> [OuraTemp]? {
        let b = rec.payload
        guard b.count >= 2, b.count % 2 == 0 else { return nil }
        let maxSamples = 7                            // s6.8: up to 7 samples per temp_event
        var out: [OuraTemp] = []
        var i = 0
        while i + 1 < b.count && out.count < maxSamples {
            let c = Double(i16le(b, i)) / 100.0
            out.append(OuraTemp(ringTimestamp: rec.ringTimestamp, celsius: c))
            i += 2
        }
        return out.isEmpty ? nil : out
    }

    /// Decode the 0x69 temp_period: a single int16 LE / 100 = C. Per OURA_PROTOCOL.md s6.8.
    public static func decodeTempPeriod(_ rec: OuraRecord) -> OuraTemp? {
        let b = rec.payload
        guard b.count >= 2 else { return nil }
        return OuraTemp(ringTimestamp: rec.ringTimestamp, celsius: Double(i16le(b, 0)) / 100.0)
    }

    /// Decode the 0x75 sleep_temp_event: uint16 LE / 100 = C, 30-second spacing. Per OURA_PROTOCOL.md
    /// s6.8. Returns nil on a short/odd body.
    public static func decodeSleepTemp(_ rec: OuraRecord) -> [OuraTemp]? {
        let b = rec.payload
        guard b.count >= 2, b.count % 2 == 0 else { return nil }
        var out: [OuraTemp] = []
        var i = 0
        while i + 1 < b.count {
            let c = Double(u16le(b, i)) / 100.0       // unsigned for sleep temp
            out.append(OuraTemp(ringTimestamp: rec.ringTimestamp, celsius: c))
            i += 2
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Battery (0x0D outer response; s6.10)

    /// Decode the 0x0D battery response BODY (the 8 bytes after `0d <len>`). percent at body[0];
    /// voltage estimate as uint16 LE at body[4..6] (fallback only). charging_progress at body[1],
    /// recommended_flag at body[2]. Per OURA_PROTOCOL.md s6.10. Returns nil on a short body.
    ///
    /// CONFLICT (s6.10): open_oura-r3 reads percent at body[0], open_ring reads voltage at [4]. NOOP
    /// rule: percent from body[0]; voltage from [4..6] is a fixture-validated fallback estimate only.
    public static func decodeBattery(_ body: [UInt8]) -> OuraBattery? {
        guard body.count >= 3 else { return nil }
        let percent = Int(body[0])
        guard percent <= 100 else { return nil }       // a >100 "percent" is a misread, not a guess
        let chargingProgress = Int(body[1])
        let voltage: Int? = body.count >= 6 ? u16le(body, 4) : nil
        // charging_progress > 0 indicates an active charge cycle (per s6.10 field name).
        return OuraBattery(percent: percent, voltageMv: voltage, charging: chargingProgress > 0)
    }

    // MARK: - Time sync (0x42; s6.11)

    /// Decode the 0x42 time-sync ind: bytes 6-13 = int64 LE epoch ms; byte14 = int8 tz offset in
    /// 30-min units (x1800 = seconds). Per OURA_PROTOCOL.md s6.11. Returns nil on a short body.
    public static func decodeTimeSync(_ rec: OuraRecord) -> OuraTimeSync? {
        let b = rec.payload
        // body[0..8] = epoch ms (8 bytes), body[8] = tz offset.
        guard b.count >= 9 else { return nil }
        var epoch: UInt64 = 0
        for k in 0..<8 { epoch |= UInt64(b[k]) << (8 * k) }
        let tz = Int(Int8(bitPattern: b[8])) * 1800
        return OuraTimeSync(ringTimestamp: rec.ringTimestamp,
                            epochMs: Int64(bitPattern: epoch), tzOffsetSeconds: tz)
    }

    // MARK: - RTC beacon (0x85; s6.15)

    /// Decode the 0x85 rtc_beacon_ind: unix_s u32 LE, reserved 4 B, trailer u16 LE in {0x01F6,0x01F8}.
    /// Per OURA_PROTOCOL.md s6.15. Returns nil on a short body.
    public static func decodeRtcBeacon(_ rec: OuraRecord) -> OuraRtcBeacon? {
        let b = rec.payload
        guard b.count >= 4 else { return nil }
        return OuraRtcBeacon(ringTimestamp: rec.ringTimestamp, unixSeconds: u32le(b, 0))
    }

    // MARK: - State / wear (0x45 / 0x53; s6.15)

    /// Decode the 0x45 state_change_ind / 0x53 wear_event: byte6 = STATE_* enum; optional trailing
    /// UTF-8 string when payload > 5. Per OURA_PROTOCOL.md s6.15. Returns nil on an empty body.
    public static func decodeState(_ rec: OuraRecord) -> OuraState? {
        let b = rec.payload
        guard let code = b.first else { return nil }
        var text: String? = nil
        if b.count > 5 {
            text = String(bytes: b[1...], encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0000}"))
        }
        return OuraState(ringTimestamp: rec.ringTimestamp, stateCode: Int(code), text: text)
    }

    // MARK: - Feature-status read reply (0x2F sub-op 0x21; s5.6 / s7.1)

    /// Decode a feature-status read reply's SUB-BODY (the bytes AFTER the `0x21` sub-op) into
    /// `feature, mode, status, state, subscription`, the ring's own feature report [open_oura-feat]. The
    /// observed daytime-HR reply is `2f 06 21 02 01 11 02 00` → sub-body `02 01 11 02 00`. Returns nil on a
    /// short body (< 5) so a truncated reply never fabricates a status. READ-ONLY diagnostic.
    public static func decodeFeatureStatus(_ subBody: [UInt8]) -> OuraFeatureStatus? {
        guard subBody.count >= 5 else { return nil }
        return OuraFeatureStatus(feature: Int(subBody[0]), mode: Int(subBody[1]),
                                 status: Int(subBody[2]), state: Int(subBody[3]),
                                 subscription: Int(subBody[4]))
    }

    // MARK: - Debug text (0x43; s6.15)

    /// Decode the 0x43 debug_event: ASCII state strings. Per OURA_PROTOCOL.md s6.15. Returns nil when
    /// the body is empty or not decodable text.
    public static func decodeDebugText(_ rec: OuraRecord) -> String? {
        guard !rec.payload.isEmpty else { return nil }
        return String(bytes: rec.payload, encoding: .utf8)
    }

    // MARK: - Sleep phase, 2-bit codes (0x4E / 0x5A; s6.12)

    /// Decode the 0x4E/0x5A sleep_phase_details: byte6 = header; phase codes are 2-bit, 4 per byte
    /// (bits [7:6][5:4][3:2][1:0]); codes 0=deep, 1=light, 2=rem, 3=awake per open_oura's VALIDATED
    /// `decode_sleep_phases` mapping (see OuraSleepStage). Returns nil on a short body. The header
    /// byte is skipped; phase bytes follow.
    public static func decodeSleepPhase(_ rec: OuraRecord) -> [OuraSleepPhase]? {
        let b = rec.payload
        // body[0] is the header (spec offset 6); phase codes begin at body[1].
        guard b.count >= 2 else { return nil }
        var out: [OuraSleepPhase] = []
        var index = 0
        for k in 1..<b.count {
            let byte = b[k]
            // MSB-first within the byte: [7:6] is the first code.
            for shift in stride(from: 6, through: 0, by: -2) {
                let code = Int((byte >> UInt8(shift)) & 0x03)
                if let stage = OuraSleepStage(rawValue: code) {
                    out.append(OuraSleepPhase(ringTimestamp: rec.ringTimestamp, index: index, stage: stage))
                    index += 1
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Motion period, 2-bit MOTION_STATE codes (0x6B; s6.13)

    /// Decode the 0x6B motion_period: 12-bit period header, byte6 bits[5:4]=leading-symbol count, then
    /// 2-bit MOTION_STATE codes, 4 per byte (MSB-first). 0=NO_MOTION,1=RESTLESS,2=TOSSING,3=ACTIVE.
    /// Per OURA_PROTOCOL.md s6.13. Returns nil on a short body. The first two bytes carry the period
    /// header; codes follow from byte index 2.
    public static func decodeMotionPeriod(_ rec: OuraRecord) -> [OuraMotion]? {
        let b = rec.payload
        guard b.count >= 3 else { return nil }
        var out: [OuraMotion] = []
        var index = 0
        for k in 2..<b.count {
            let byte = b[k]
            for shift in stride(from: 6, through: 0, by: -2) {
                let code = Int((byte >> UInt8(shift)) & 0x03)
                if let state = OuraMotionState(rawValue: code) {
                    out.append(OuraMotion(ringTimestamp: rec.ringTimestamp, index: index, state: state))
                    index += 1
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Motion events, averaged accel vector (0x47; s6.13)

    /// Decode a 0x47 `motion_events` record: a compact per-window motion summary. Layout is a
    /// byte-for-byte port of open_oura's `decode_motion` / native `parse_api_motion_events`
    /// (clean-room fact citation; OURA_PROTOCOL.md s6.13):
    ///   byte0 >> 5      = orientation (0…7)
    ///   byte0 & 0x1f    = motion_seconds (0…31)
    ///   byte1/2/3       = avg X/Y/Z, signed int8 × 8
    ///   byte4 (opt)     = low_intensity: bit 0x40 set ⇒ INVALID (whole record → nil); else `& 0x3f`
    ///   byte5 (opt)     = high_intensity: bit 0x40 set ⇒ INVALID (whole record → nil); else `& 0x3f`
    /// Needs ≥ 4 bytes (orientation/motion_seconds + the 3 axes); low/high intensity are optional. The
    /// avg vector is the SAME averaged-accel shape as a WHOOP 4.0 gravity sample. NOTE (validated
    /// on-device #804): 0x47 is MOVEMENT-GATED — the ring emits it only while moving, so there is no
    /// still/1 g sample; `motion_seconds` / intensity are the activity signal, not a gravity magnitude.
    public static func decodeMotionEvents(_ rec: OuraRecord) -> OuraMotionEvent? {
        let b = rec.payload
        guard b.count >= 4 else { return nil }
        var low: Int? = nil
        if b.count >= 5 {
            guard b[4] & 0x40 == 0 else { return nil }
            low = Int(b[4] & 0x3f)
        }
        var high: Int? = nil
        if b.count >= 6 {
            guard b[5] & 0x40 == 0 else { return nil }
            high = Int(b[5] & 0x3f)
        }
        return OuraMotionEvent(
            ringTimestamp: rec.ringTimestamp,
            orientation: Int(b[0] >> 5),
            motionSeconds: Int(b[0] & 0x1f),
            avgX: Int(Int8(bitPattern: b[1])) * 8,
            avgY: Int(Int8(bitPattern: b[2])) * 8,
            avgZ: Int(Int8(bitPattern: b[3])) * 8,
            lowIntensity: low,
            highIntensity: high)
    }

    // MARK: - Activity info (0x50; s6.13) - Tier B, third-party formula

    /// Decode the 0x50 activity_info record: byte0 = a `state` code (activity-category; meaning
    /// unconfirmed), every following byte = one MET sample. Formula (OURA_PROTOCOL.md s6.13, [oura-rs],
    /// clean-room fact citation): `met = byte * 0.1` for byte < 0x80, else `met = 12.8 + (byte - 128) * 0.2`
    /// (a two-slope encoding: 0.1-MET resolution up to 12.7, coarser 0.2 steps above). THIRD-PARTY and NOT
    /// ground-truth-validated against the Oura app, so this stays Tier B end to end: OuraDriver gates it
    /// behind `allowTierB`, and OuraStreamMapping never folds it into a durable stream. Values are
    /// normalised to 2 decimal places so a decoded MET compares exactly against its fixture (0.1 is not
    /// exactly representable in binary floating point). Returns nil on an empty body - a record with no
    /// state byte decodes to nothing, never a guess.
    public static func decodeActivityInfo(_ rec: OuraRecord) -> OuraActivityInfo? {
        let b = rec.payload
        guard let state = b.first else { return nil }
        let met: [Double] = b.dropFirst().map { byte in
            let raw = byte < 0x80 ? Double(byte) * 0.1 : 12.8 + (Double(byte) - 128.0) * 0.2
            return (raw * 100).rounded() / 100
        }
        return OuraActivityInfo(ringTimestamp: rec.ringTimestamp, state: Int(state), met: met)
    }
}
