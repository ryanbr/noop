import Foundation

public struct DecodedField: Codable, Equatable {
    public let off: Int
    public let len: Int
    public let name: String
    public let cat: String
    public let value: ParsedValue?
    public let raw: String
    public let note: String?
}

public struct ParsedFrame: Codable, Equatable {
    public let ok: Bool
    public let typeName: String
    public let seq: Int?
    public let cmdName: String?
    public let crcOK: Bool?
    public let lenBytes: Int
    public let rawHex: String
    public let fields: [DecodedField]
    public let parsed: [String: ParsedValue]
}

// MARK: - low-level readers (LE), nil when out of range (mirrors interpreter._read)

@inline(__always) private func readU8(_ f: [UInt8], _ off: Int) -> Int? {
    off + 1 <= f.count ? Int(f[off]) : nil
}
@inline(__always) private func readU16(_ f: [UInt8], _ off: Int) -> Int? {
    off + 2 <= f.count ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}
@inline(__always) private func readU32(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 4 <= f.count else { return nil }
    return Int(f[off]) | (Int(f[off + 1]) << 8) | (Int(f[off + 2]) << 16) | (Int(f[off + 3]) << 24)
}
@inline(__always) private func readI16(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 2 <= f.count else { return nil }
    let raw = UInt16(f[off]) | (UInt16(f[off + 1]) << 8)
    return Int(Int16(bitPattern: raw))
}

@inline(__always) private func readI32(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 4 <= f.count else { return nil }
    let raw = UInt32(f[off]) | (UInt32(f[off + 1]) << 8) | (UInt32(f[off + 2]) << 16) | (UInt32(f[off + 3]) << 24)
    return Int(Int32(bitPattern: raw))
}

@inline(__always) private func readF32(_ f: [UInt8], _ off: Int) -> Double? {
    guard off + 4 <= f.count else { return nil }
    let bits = UInt32(f[off]) | (UInt32(f[off + 1]) << 8) | (UInt32(f[off + 2]) << 16) | (UInt32(f[off + 3]) << 24)
    return Double(Float(bitPattern: bits))   // float32 -> Double is exact, no rounding
}

/// Read a schema dtype at off; returns the integer value or nil if out of range.
private func readDType(_ f: [UInt8], _ off: Int, _ dtype: String) -> Int? {
    switch dtype {
    case "u8": return readU8(f, off)
    case "u16": return readU16(f, off)
    case "u32": return readU32(f, off)
    case "i16": return readI16(f, off)
    default: return nil
    }
}

private func hexString(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// Field builder: accumulates annotated fields and a flat parsed dict. Port of Python FB.
///
/// `collectFields` (D#742): the annotated `fields` array, and each field's per-field `raw` hex
/// string, exist for the inspector surfaces (whoop-decode, the fields-asserting tests), not for
/// the live BLE stream. When false, `add` writes only the flat `parsed` dict and skips both the
/// `DecodedField` append and the `hexString` call, so the 1Hz+ live path and a 5/MG offload burst
/// stop allocating metadata nothing reads. `value:`/`note:` are @autoclosure for the same reason
/// (the gated zero-cost idiom): a formatted envelope value (crc hex strings etc.) is never built
/// unless a path that keeps it runs. The `parsed` output is byte-identical on both paths.
final class FieldBuilder {
    let frame: [UInt8]
    let collectFields: Bool
    var fields: [DecodedField] = []
    var parsed: [String: ParsedValue] = [:]

    init(_ frame: [UInt8], collectFields: Bool = true) {
        self.frame = frame
        self.collectFields = collectFields
    }

    @discardableResult
    func add(_ off: Int, _ length: Int, _ name: String, _ cat: String,
             value: @autoclosure () -> ParsedValue? = nil,
             note: @autoclosure () -> String? = nil) -> FieldBuilder {
        let keepInParsed = cat != "frame" && cat != "unknown"
        if collectFields {
            let end = min(off + length, frame.count)
            let raw = off <= frame.count ? hexString(frame[max(0, off)..<max(off, end)]) : ""
            let v = value()
            fields.append(DecodedField(off: off, len: length, name: name, cat: cat,
                                       value: v, raw: raw, note: note()))
            if let v = v, keepInParsed {
                parsed[name] = v
            }
        } else if keepInParsed, let v = value() {
            parsed[name] = v
        }
        return self
    }

    func region(_ start: Int, _ end: Int, _ name: String, _ cat: String, note: String? = nil) {
        if start < end && end <= frame.count {
            add(start, end - start, name, cat, value: .string("[\(end - start) bytes]"), note: note)
        }
    }
}

/// Parse one complete WHOOP 4.0 frame.
///
/// `collectFields` (D#742) defaults to FALSE, the decode-only fast path: the flat `parsed` dict
/// (and every other property except `fields`) is byte-identical, but the annotated `fields` array
/// with its per-field `raw` hex stays empty. The live ingest path (FrameRouter / Collector /
/// Backfiller / extractStreams) reads only `parsed`, so on a 1Hz+ stream or an offload burst the
/// per-field metadata was pure allocation waste. Pass `true` on inspector/diagnostic surfaces
/// (whoop-decode, field-asserting tests) that actually read `fields`.
public func parseFrame(_ frame: [UInt8], collectFields: Bool = false) -> ParsedFrame {
    // D#969: only build the whole-frame hex when a consumer will read it. The live ingest fast path
    // (collectFields:false) never reads `rawHex` — only inspector/diagnostic surfaces (whoop-decode,
    // PuffinCapture, field-asserting tests) do — so on a 1Hz stream or an offload burst this skips a
    // per-byte `String(format:)` allocation pass whose result was discarded.
    let rawHex = collectFields ? frame.map { String(format: "%02x", $0) }.joined() : ""
    if frame.count < 8 || frame[0] != 0xAA {
        return ParsedFrame(ok: false, typeName: "INVALID/FRAGMENT", seq: nil, cmdName: nil,
                           crcOK: nil, lenBytes: frame.count, rawHex: rawHex,
                           fields: [], parsed: [:])
    }

    let schema = loadSchema()
    let check = verifyFrame(frame)
    let length = check.length
    let crcOK = check.crc32OK

    let t = Int(frame[4])
    let typeName = schema.typeName(t)
    let seq = Int(frame[5])

    let fb = FieldBuilder(frame, collectFields: collectFields)
    // envelope
    fb.add(0, 1, "SOF", "frame", value: .string("0xAA"))
    fb.add(1, 2, "length", "frame", value: length.map { .int($0) })
    fb.add(3, 1, "crc8", "frame", value: .string(String(format: "0x%02X", frame[3])))
    fb.add(4, 1, "packet_type", "frame", value: .string(typeName))
    fb.add(5, 1, "seq", "frame", value: .int(Int(frame[5])))

    let spec = schema.packet(forType: t)
    if spec == nil {
        fb.add(6, 1, "cmd", "cmd", value: frame.count > 6 ? .int(Int(frame[6])) : nil)
        if let length = length { fb.region(7, length, "payload", "unknown") }
    } else {
        // static fields from schema
        for fld in spec!.fields {
            guard let dtype = fld.dtype else { continue }
            guard let val = readDType(frame, fld.off, dtype) else { continue }
            let value: ParsedValue
            if let enumKey = fld.`enum` {
                value = .string(schema.enumName(enumKey, val))
            } else {
                value = .int(val)
            }
            fb.add(fld.off, fld.len, fld.name, fld.cat, value: value, note: fld.note)
        }
        // per-type post-hook for irregular fields (populated in PostHooks.swift by B7)
        if let postName = spec!.post, let hook = postHooks[postName] {
            hook(fb, frame, length, schema)
        }
    }

    // crc32 trailer field
    if let length = length, length + 4 <= frame.count {
        let crcVal = UInt32(frame[length]) | (UInt32(frame[length + 1]) << 8)
            | (UInt32(frame[length + 2]) << 16) | (UInt32(frame[length + 3]) << 24)
        fb.add(length, 4, "crc32", "frame", value: .string(String(format: "0x%08X", crcVal)),
               note: check.crc32OK == true ? "OK" : "MISMATCH")
    }

    let cmdByte = frame.count > 6 ? Int(frame[6]) : 0
    let cmdName = (t == 35 || t == 36) ? schema.enumName("CommandNumber", cmdByte) : nil

    return ParsedFrame(ok: true, typeName: typeName, seq: seq, cmdName: cmdName,
                       crcOK: crcOK, lenBytes: frame.count, rawHex: rawHex,
                       fields: fb.fields, parsed: fb.parsed)
}

/// #47: the packet type NAME only — NO CRC verify, NO FieldBuilder — for hot-path pre-filters that just
/// need a frame's TYPE (e.g. "is this an EVENT?") before deciding whether to pay a full `parseFrame`. On a
/// multi-minute offload of thousands of type-47 records that only ever act on rare EVENT frames, this skips
/// the redundant decode for the ~99% that aren't. Mirrors `parseFrame`'s family split EXACTLY — the inner
/// type byte is at [4] on WHOOP4 and [8] on 5/MG, with the same lookup each uses (`schema.typeName` /
/// `canonicalTypeName`). Returns nil for a frame too short / wrong SOF — which `parseFrame` would also mark
/// INVALID (never "EVENT") — so a pre-filter guarded on `== "EVENT"` is byte-identical to the full-parse
/// guard.
public func frameTypeName(_ frame: [UInt8], family: DeviceFamily) -> String? {
    guard frame.first == 0xAA else { return nil }
    let schema = loadSchema()
    switch family {
    case .whoop4:
        guard frame.count >= 8 else { return nil }        // parseFrame's `count < 8` INVALID guard
        return schema.typeName(Int(frame[4]))
    case .whoop5:
        guard frame.count >= 12 else { return nil }       // parseFrameWhoop5's `count < 12` INVALID guard
        return canonicalTypeName(Int(frame[8]), schema: schema)
    }
}

/// Family-aware frame parsing.
///
/// `whoop4` behaves EXACTLY like the no-family `parseFrame(_:)` above (back-compat). `whoop5`
/// parses the Whoop 5.0 envelope (see `verifyFrame(_:family:)` for the layout): the SOF/length/
/// header-CRC live in the first 8 bytes, the inner `[type][seq][cmd][data…]` starts at offset 8,
/// and the 4-byte CRC32 trailer closes the frame. "Puffin" types 38/56 are aliased onto their base
/// names (COMMAND_RESPONSE / METADATA) via `canonicalTypeName`.
///
/// `collectFields` follows `parseFrame(_:collectFields:)` exactly (D#742): default FALSE is the
/// decode-only fast path with an identical `parsed` dict and an empty `fields` array.
public func parseFrame(_ frame: [UInt8], family: DeviceFamily, collectFields: Bool = false) -> ParsedFrame {
    switch family {
    case .whoop4:
        return parseFrame(frame, collectFields: collectFields)
    case .whoop5:
        return parseFrameWhoop5(frame, collectFields: collectFields)
    }
}

private func parseFrameWhoop5(_ frame: [UInt8], collectFields: Bool) -> ParsedFrame {
    // D#969: gated identically to parseFrame — build the hex only when a consumer reads it.
    let rawHex = collectFields ? frame.map { String(format: "%02x", $0) }.joined() : ""
    // Minimum whoop5 frame: 8 header bytes + 1 inner (type) + 4 CRC32 trailer.
    if frame.count < 12 || frame[0] != 0xAA {
        return ParsedFrame(ok: false, typeName: "INVALID/FRAGMENT", seq: nil, cmdName: nil,
                           crcOK: nil, lenBytes: frame.count, rawHex: rawHex,
                           fields: [], parsed: [:])
    }

    let schema = loadSchema()
    let check = verifyFrame(frame, family: .whoop5)
    let declaredLength = check.length            // payload + 4 (CRC32)
    let crcOK = check.crc32OK

    // Inner record starts at offset 8: [type][seq][cmd][data…].
    let innerStart = 8
    let t = Int(frame[innerStart])
    let typeName = canonicalTypeName(t, schema: schema)
    let seq = frame.count > innerStart + 1 ? Int(frame[innerStart + 1]) : nil

    let fb = FieldBuilder(frame, collectFields: collectFields)
    // envelope
    fb.add(0, 1, "SOF", "frame", value: .string("0xAA"))
    fb.add(1, 1, "format", "frame", value: .int(Int(frame[1])))
    fb.add(2, 2, "length", "frame", value: declaredLength.map { .int($0) })
    fb.add(4, 2, "header", "frame", value: .string(hexFrameSlice(frame, 4, 6)))
    let hdrCRC = UInt16(frame[6]) | (UInt16(frame[7]) << 8)
    fb.add(6, 2, "crc16", "frame", value: .string(String(format: "0x%04X", hdrCRC)),
           note: check.crc8OK == true ? "OK" : "MISMATCH")
    fb.add(innerStart, 1, "packet_type", "frame", value: .string(typeName))
    if let seq = seq { fb.add(innerStart + 1, 1, "seq", "frame", value: .int(seq)) }

    // WHOOP 5.0 field offsets are the WHOOP 4.0 layout shifted by +4: the inner record starts at
    // byte 8 here vs byte 4 on 4.0, so every field sits at its 4.0 offset + `delta`. Verified on real
    // hardware for REALTIME_DATA (type 40) — HR, R-R and the unix timestamp land exactly at +4 (HR
    // matched the standard 2A37 profile to ~0.4 bpm). We reuse the 4.0 schema with that shift.
    let cmdByte = frame.count > innerStart + 2 ? Int(frame[innerStart + 2]) : 0
    let delta = innerStart - 4                       // = 4
    let payloadEnd = declaredLength.map { ($0 + 8) - 4 }   // start of CRC32 trailer
    let spec = schema.packet(forType: t)
    if spec == nil {
        fb.add(innerStart + 2, 1, "cmd", "cmd",
               value: frame.count > innerStart + 2 ? .int(cmdByte) : nil)
        if let payloadEnd = payloadEnd, innerStart + 3 < payloadEnd, payloadEnd <= frame.count {
            fb.region(innerStart + 3, payloadEnd, "payload", "unknown")
        }
    } else {
        // Static schema fields at the 4.0 offset + delta.
        for fld in spec!.fields {
            guard let dtype = fld.dtype, let val = readDType(frame, fld.off + delta, dtype) else { continue }
            let value: ParsedValue = fld.`enum`.map { .string(schema.enumName($0, val)) } ?? .int(val)
            fb.add(fld.off + delta, fld.len, fld.name, fld.cat, value: value, note: fld.note)
        }
        if spec!.post == "realtime_data" {
            // Verified variable-length extension: REALTIME_DATA R-R intervals (rr_count @13+delta,
            // intervals @14+delta…), the same shape as 4.0 shifted by +4.
            let rrn = readDType(frame, 13 + delta, "u8") ?? 0
            var rrs: [Int] = []
            for i in 0..<rrn {
                let off = 14 + delta + i * 2
                if let v = readDType(frame, off, "u16"), v > 0 {
                    fb.add(off, 2, "rr[\(i)]", "rr", value: .int(v), note: "ms")
                    rrs.append(v)
                }
            }
            fb.parsed["rr_intervals"] = .intArray(rrs)
        } else if spec!.post == "historical_data" {
            decodeWhoop5Historical(frame, fb: fb, payloadEnd: payloadEnd)
        } else if spec!.post == "metadata" {
            decodeWhoop5Metadata(frame, fb: fb)
        } else if spec!.post == "command_response" {
            decodeWhoop5CommandResponse(frame, fb: fb, schema: schema, payloadEnd: payloadEnd)
        } else if spec!.post == "event" {
            decodeWhoop5Event(frame, fb: fb, schema: schema)
        } else if spec!.post == "console_logs" {
            decodeWhoop5ConsoleLogs(frame, fb: fb, payloadEnd: payloadEnd)
        } else if let payloadEnd = payloadEnd, innerStart + 3 < payloadEnd, payloadEnd <= frame.count {
            // Other types: static fields decoded above; the remaining variable body is kept raw —
            // its 4.0 post-hook awaits per-type 5.0 hardware verification before we apply it at +4.
            fb.region(innerStart + 3, payloadEnd, "payload", "unknown")
        }
    }

    // crc32 trailer field
    if let payloadEnd = payloadEnd, payloadEnd + 4 <= frame.count {
        let crcVal = UInt32(frame[payloadEnd]) | (UInt32(frame[payloadEnd + 1]) << 8)
            | (UInt32(frame[payloadEnd + 2]) << 16) | (UInt32(frame[payloadEnd + 3]) << 24)
        fb.add(payloadEnd, 4, "crc32", "frame",
               value: .string(String(format: "0x%08X", crcVal)),
               note: check.crc32OK == true ? "OK" : "MISMATCH")
    }

    let cmdName = (t == 35 || t == 36 || t == PuffinPacketType.puffinCommandResponse)
        ? schema.enumName("CommandNumber", cmdByte) : nil

    return ParsedFrame(ok: true, typeName: typeName, seq: seq, cmdName: cmdName,
                       crcOK: crcOK, lenBytes: frame.count, rawHex: rawHex,
                       fields: fb.fields, parsed: fb.parsed)
}

/// The WHOOP 5/MG type-47 `hist_version` values `decodeWhoop5Historical` has a REAL field map for.
/// Every other version falls through to the "unmapped layout" branch, which decodes nothing and only
/// describes the payload as an opaque region.
///
/// This is the single source of truth for "does NOOP understand this layout": the dispatch `switch` in
/// `decodeWhoop5Historical` reads nothing else, and `rejectedHistoricalRecords` uses it to decide which
/// records must be archived raw. Keeping one set means the two can never disagree — the failure mode
/// this replaced was a record from an unmapped layout that happened to decode a plausible `unix` and
/// `gravity_x`/`heart_rate` slipping past the archive filter, so its bytes were kept nowhere at all.
/// `Whoop5HistoricalLayoutMapTests` pins the set against the decoder's actual behaviour.
public let mappedWhoop5HistoricalVersions: Set<Int> = [18, 20, 21, 26]

/// True when `frame` is a WHOOP 5/MG type-47 record whose layout version has NO field map — the
/// records that reach the unmapped branch of `decodeWhoop5Historical` and are therefore never
/// re-derivable from anything NOOP stores. Non-type-47 and too-short frames are false.
public func isUnmappedWhoop5HistoricalRecord(_ frame: [UInt8]) -> Bool {
    guard frame.count > 9, Int(frame[8]) == 47 else { return false }
    return !mappedWhoop5HistoricalVersions.contains(Int(frame[9]))
}

/// Decode a WHOOP 5.0 HISTORICAL_DATA (type 47) DSP biometric record.
///
/// The layout version is carried in the byte at frame[9] — the inner record's seq slot, which the
/// historical packet reuses for its layout version exactly as WHOOP 4.0 does (version at frame[5],
/// +4 here). Real WHOOP 5 hardware on the latest firmware emits **version 18**, captured 2026-06-08
/// and unlocked via the HISTORICAL_DATA_RESULT chunk-ack handshake (see docs §5).
///
/// v18 is NOT the repo's 4.0 v24 layout shifted by +4 — that firmware revision is not what this
/// device emits, and a naive +4 decodes to garbage (HR 0, gravity overflow). Every offset below is
/// read directly off real frames at its absolute 5.0 position and cross-checked physiologically:
///   • unix monotonic at +1 s,  • rr_count matches the number of valid R-R intervals (100%),
///   • 60000/mean(R-R) ≈ heart_rate (88%, the rest being HR-averaging cases),  • |gravity| ≈ 1 g
///     (100% of 500 records).
/// PPG / SpO₂ / skin-temp live further in the 124-byte record but lack on-device ground truth, so
/// they are left as a raw region rather than guessed (project rule: real captures, never invented
/// offsets).
private func decodeWhoop5Historical(_ frame: [UInt8], fb: FieldBuilder, payloadEnd: Int?) {
    let version = frame.count > 9 ? Int(frame[9]) : -1
    fb.parsed["hist_version"] = .int(version)
    fb.add(9, 1, "hist_version", "meta", value: .int(version))
    // One dispatch, one list: every `case` here must appear in `mappedWhoop5HistoricalVersions` and
    // vice versa, because that set is what decides whether a record gets archived raw. A `switch`
    // rather than the old if-chain so the mapped versions are readable in one place.
    switch version {
    case 26:
        decodeWhoop5HistoricalV26(frame, fb: fb)
        return
    case 20, 21:
        decodeWhoop5HistoricalV2021(frame, fb: fb, version: version, payloadEnd: payloadEnd)
        return
    case 18:
        break   // falls through to the v18 field decode below
    default:
        // Unknown historical layout — describe it faithfully without inventing offsets. The bytes are
        // NOT lost: `rejectedHistoricalRecords` archives every record that lands here (#77 / #91).
        if let payloadEnd = payloadEnd, 11 < payloadEnd, payloadEnd <= frame.count {
            fb.region(11, payloadEnd, "HISTORICAL_DATA v\(version) (unmapped layout)", "unknown")
        }
        return
    }
    if let idx = readDType(frame, 11, "u32") {
        // A per-record counter: +1 every record and independent of unix (it advances across gaps);
        // observed identical on two straps. @11 is only the low byte — read the full u32 LE.
        fb.add(11, 4, "record_index", "meta", value: .int(idx), note: "per-record counter")
    }
    if let unix = readDType(frame, 15, "u32") {
        fb.add(15, 4, "unix", "time", value: .int(unix), note: "real unix seconds")
    }
    if let hr = readDType(frame, 22, "u8") {
        fb.add(22, 1, "heart_rate", "hr", value: .int(hr), note: "bpm")
    }
    let rrn = readDType(frame, 23, "u8") ?? 0
    fb.add(23, 1, "rr_count", "rr", value: .int(rrn))
    var rrs: [Int] = []
    for i in 0..<min(rrn, 4) {
        let off = 24 + i * 2
        if let v = readDType(frame, off, "u16"), v > 0 {
            fb.add(off, 2, "rr[\(i)]", "rr", value: .int(v), note: "ms")
            rrs.append(v)
        }
    }
    fb.parsed["rr_intervals"] = .intArray(rrs)
    // Bytes adjacent to the HR/R-R fields, read off real frames: @36 is a FLAG byte and @37 a duplicate
    // heart rate — not the two halves of one fixed-point HR (see below); the others are raw.
    if let v = readDType(frame, 33, "u8") {
        fb.add(33, 1, "cardiac_flags", "cardiac", value: .int(v), note: "raw byte near the HR fields")
    }
    // @36 was read as the low half of a u16 `hr_fixed_8_8` with bpm = value/256. Over 18,650 real v18
    // records that model is false. Bit 4 is NEVER set (0/18,650 — a genuine 8.8 fraction sets it ~50% of
    // the time, and it is the ONLY bit never set); 95.02% of values land in 0x80–0x8F where uniform would
    // be 6.25%, over just 40 distinct values, sd 26.5 vs 73.9 for a uniform byte. The "corr 0.989 with
    // hr@22" that justified the old name was circular — the u16 is literally hr@22 (carried at @37) plus
    // this flag byte over 256, so the residual is a flat +0.504 ± 0.189. Bit 7 reads as a VALIDITY bit:
    // with it clear (n=748) rr_count == 0 in 70.32% of records vs 19.82% with it set, and the @108/@109
    // sentinel fires in 69.65% vs 1.32%. The remaining bits are unpinned, so the byte ships raw.
    if let v = readDType(frame, 36, "u8") {
        fb.add(36, 1, "hr_quality_flags", "hr", value: .int(v),
               note: "flag byte (raw); bit7 = HR/R-R valid, bit4 never set; NOT a fixed-point HR")
    }
    // @37 duplicates heart_rate@22 — equal in 99.575% of records (18,523/18,602), differing only by
    // -6…+2, and it only tracks HR while @36 bit7 is set (99.74% exact vs 94.12% when clear).
    if let v = readDType(frame, 37, "u8") {
        fb.add(37, 1, "heart_rate_alt", "hr", value: .int(v),
               note: "bpm; duplicate of heart_rate@22 (99.6% exact); trust only when hr_quality_flags bit7 is set")
    }
    if let v = readDType(frame, 38, "u16") {
        fb.add(38, 2, "rr_packed", "rr", value: .int(v), note: "raw u16 near the R-R fields; meaning not pinned")
    }
    if let v = readDType(frame, 40, "u8") {
        fb.add(40, 1, "cardiac_status", "cardiac", value: .int(v), note: "raw status-like byte near the HR fields")
    }
    for (name, off) in [("gravity_x", 45), ("gravity_y", 49), ("gravity_z", 53)] {
        if let d = readF32(frame, off) {
            fb.add(off, 4, name, "accel", value: .double(d), note: "g")
        }
    }
    // Per-second fields beyond HR/gravity, each gated to a physically-real range and cross-validated
    // against real v18 frames (worn vs off-wrist), so a wrong offset on an unmapped layout stores
    // nothing rather than garbage (the data is the arbiter).
    if let d = readF32(frame, 41), d.isFinite, (0...8).contains(d) {
        fb.add(41, 4, "dynamic_acceleration", "accel", value: .double(d), note: "g, gravity-removed magnitude")
    }
    if let raw = readDType(frame, 57, "u16") {
        // Cumulative motion/step counter — monotonic across a stream (validated downstream), no midnight
        // reset. Single-frame value is unbounded so it carries no physical gate here.
        fb.add(57, 2, "step_motion_counter", "activity", value: .int(raw), note: "cumulative motion counter")
    }
    if let cad = readDType(frame, 59, "u8") {
        // A per-step cadence-like byte between the step counter and @63: never 0, and lower when moving
        // faster (still > walk > run in the data). Raw — no unit asserted.
        fb.add(59, 1, "step_cadence", "activity", value: .int(cad), note: "cadence-like byte (raw)")
    }
    if let wear = readDType(frame, 63, "u8"), (0...2).contains(wear) {
        fb.add(63, 1, "motion_wear_quality", "quality", value: .int(wear), note: "0=still/good, 1, 2=poor contact")
    }
    // @63 also reads as a small validated ACTIVITY-CLASS enum (community finding, #316): 0=still, 1=walk,
    // 2=run, 0xFF=invalid. A lightweight, no-cloud per-record activity readout that rides alongside the
    // step counter. Only the four known codes are surfaced — anything else (incl. 0xFF) stores nothing so
    // an unmapped firmware can't inject garbage.
    if let cls = readDType(frame, 63, "u8"), cls == 0 || cls == 1 || cls == 2 {
        fb.add(63, 1, "activity_class", "activity", value: .int(cls), note: "0=still, 1=walk, 2=run (0xFF=invalid)")
    }
    // Two auxiliary thermal channels just before skin_temp. Each is a signed i16 whose value/10 reads as
    // °C, tracks skin_temp@73 closely (corr ~0.92 and ~0.97 across the captured corpus) and follows the
    // same diurnal curve. Gated to a plausible thermal range so a wrong offset stores nothing.
    if let v = readI16(frame, 69), (0...60).contains(Double(v) / 10.0) {
        fb.add(69, 2, "temp_aux_1_raw", "temp", value: .int(v),
               note: "secondary temperature channel; °C = value/10; tracks skin_temp (corr ~0.92) with the same diurnal curve")
    }
    if let v = readI16(frame, 71), (0...60).contains(Double(v) / 10.0) {
        fb.add(71, 2, "temp_aux_2_raw", "temp", value: .int(v),
               note: "secondary temperature channel; °C = value/10; tracks skin_temp (corr ~0.97) with the same diurnal curve")
    }
    if let raw = readDType(frame, 73, "u16") {
        // Skin temperature from a digital skin-temperature sensor. Emitted as the RAW u16 register
        // (`skin_temp_raw`, consumed by the decode-features store) to stay scale-agnostic; °C = raw/100
        // is the divisor that yields physiological worn skin temps (median ~34 °C across two straps;
        // 30.6 °C worn / 22.5 °C ambient off-wrist on the test fixtures). The alternative /128 reads a
        // non-physiological ~27 °C worn (≈23.9 °C on this fixture) and is rejected. The on-wrist warming
        // curve after donning is a thermal signature nothing else in the record has. Gate on a plausible
        // thermal range so a wrong offset on an unmapped firmware stores nothing rather than garbage.
        let celsius = Double(raw) / 100.0
        if (5...45).contains(celsius) {
            fb.add(73, 2, "skin_temp_raw", "temp", value: .int(raw),
                   note: "raw register; °C = raw/100 (≈30.6 worn / ~22.5 ambient; on-wrist warming curve)")
        }
    }
    if let raw = readDType(frame, 75, "u16") {
        // A 16-bit status word. NOT a deep-sleep marker: across ~258k records its low nibble is 0 and it
        // occurs as often awake as asleep (the community "80 = deep" reading is a misread).
        fb.add(75, 2, "status_word", "status", value: .int(raw), note: "packed status word; not deep-sleep")
    }
    if let v = readDType(frame, 77, "u16") {
        fb.add(77, 2, "status_word_1", "status", value: .int(v),
               note: "raw; near-static sibling of status_word@75 (low nibble = 1)")
    }
    if let v = readDType(frame, 79, "u16") {
        fb.add(79, 2, "status_word_2", "status", value: .int(v),
               note: "raw; sibling of @75 (low nibble = 2)")
    }
    if let sb = readDType(frame, 81, "u8") {
        // High nibble (bits 4-5) tracks a scored night: 0 wake / 1 still / 2 asleep / 3 up; low nibble =
        // sub-flags. Deep/REM/light are computed off-band, not present here.
        let state = (sb >> 4) & 3
        fb.add(81, 1, "sleep_state", "sleep", value: .int(state),
               note: "0 wake/1 still/2 asleep/3 up (band state; not deep/REM/light)")
        fb.add(81, 1, "onwrist", "sleep", value: .int(sb & 3),
               note: "on-wrist/validity flag (b0-1)")
        fb.add(81, 1, "wake_quality", "sleep", value: .int((sb >> 2) & 3),
               note: "quality code (b2-3); observed nonzero only in wake")
        // The WHOLE byte, unmasked. The three fields above are the nibbles this project has interpreted;
        // this key is the strap's own byte VERBATIM so all 8 bits survive to storage — including b6-7,
        // which read 0 across every capture held here and therefore have no interpretation at all yet.
        // A per-nibble store would make those bits permanently unrecoverable, because the strap trims its
        // banked history the moment an offload is acked. Instrumentation only: nothing scores this.
        fb.add(81, 1, "sleep_state_byte", "sleep", value: .int(sb),
               note: "the RAW @81 flag byte, all 8 bits (b0-1 onwrist, b2-3 wake_quality, b4-5 sleep_state, b6-7 reserved)")
    }
    if let v = readDType(frame, 82, "u8") {
        fb.add(82, 1, "aux_byte_82", "status", value: .int(v),
               note: "raw; nonzero only while sleep_state = asleep; tri-mode, see spo2_candidate_82")
        // #103 SpO2 candidate: a decompile-sourced decode (gen5.rs `spo2_pct`, reimplemented here as a
        // protocol fact with attribution, like the other RE work) reads @82 (= inner 74) as a
        // strap-computed SpO2 % scalar, tri-mode: 70–100 = a real %, bit-7 values (0x80/0xA0…) =
        // saturation sentinels, other sub-70 nonzero = diagnostic codes, populated only during sleep.
        // Evidence is SPLIT: an 8-night independent validation with real spread (corr +0.99, ~0.4 %/night,
        // tracks a 92 % desat AND a 98 % high; offset-specific — only @82 tracks in a 74–92 scan) meets
        // the cross-night bar, but the two capture nights checked on the original #103 device moved
        // OPPOSITE to the app value (95.50→92.83 app vs 93.62→93.80 gated mean) — device/firmware
        // variance or an extraction error on one side, unresolved. So this ships as an INSTRUMENTATION
        // CANDIDATE only: the in-band value is decoded and surfaced raw for multi-device correlation
        // against the app's own nightly SpO2. It must never back a shipped SpO2 metric, never write
        // `spo2Pct`/`spo2_red`/`spo2_ir` (the testHistoricalV18OpticalFieldsAreNotNamedPhysiologically
        // guard), and never
        // feed a downstream gate (recovery/illness) until the cross-device contradiction is resolved.
        if (70...100).contains(v) {
            fb.add(82, 1, "spo2_candidate_82", "spo2", value: .int(v),
                   note: "in-band (70–100) @82 reading; candidate strap-computed SpO2 % (#103) — instrumentation only, cross-device evidence still split, not a shipped metric")
        }
    }
    // ── The @82–119 "optical/perfusion + tail" span, characterised over 18,602 real v18 records from a
    // third strap (overnight R22 live stream) + cross-checked on the two fixture devices above. The span
    // is ~85% ZERO PADDING: bytes 83–103, 110–112 and 117–119 are constant 0x00 on every record, and @104
    // is a constant 0x01 marker (5/5 fixtures, both devices). Only two byte PAIRS carry data — @106/@107
    // and @108/@109 — plus the @113 float, and none is physiologically ground-truth-named (no
    // SpO2/respiratory reference exists), so each is carried RAW with its observed behaviour, never
    // mapped to a named metric. This documents the region honestly instead of leaving 38 opaque bytes.
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
    for (name, off) in [("optical_baseline_a", 106), ("optical_baseline_b", 107)] {
        if let v = readDType(frame, off, "u8") {
            fb.add(off, 1, name, "optical", value: .int(v),
                   note: "u8 optical/ADC baseline channel; wanders overnight, 0 = off-wrist; raw, not pinned")
        }
    }
    // @108/@109 are a tightly-coupled PAIR (equal in 23.5% of records, within ±2 in ~80%). 128 is a
    // RECORD-level sentinel, not a per-channel one: amp_a == 128 in 757 records and amp_b == 128 in 757 —
    // the SAME 757, never one without the other. They do NOT rise with heart rate; that reading (mean ~34
    // at HR 40–49 → ~58 at 80–89) was an averaging artifact of counting the 128 sentinel as a number, and
    // with sentinels excluded the trend is flat-to-declining (32.45 → 29.52). The real monotone trend is
    // with MOTION: ~32.7 while still (dyn_acc < 0.02 g) → 37.4 at 0.05–0.2 g. Amplitude- or
    // signal-quality-like; carried raw, NOT named SpO2/perfusion without on-device ground truth.
    //
    // The sentinel itself is a usable per-second SIGNAL-QUALITY flag: it fires on 4.02% of worn seconds
    // and predicts the band's own beat-detection failure (rr_count == 0) at 79.44% vs 19.40% — a 4.09×
    // lift that SURVIVES holding motion constant (4.11× within dyn_acc < 0.009 g), where shuffled and
    // circular-shift nulls all sit at ~1.0×. It is the same quality condition @36 bit7 reports.
    if let a = readDType(frame, 108, "u8") {
        fb.add(108, 1, "optical_amp_a", "optical", value: .int(a),
               note: "paired optical channel A (≈ optical_amp_b@109); tracks motion, not HR; 128 = record-level signal-quality sentinel; raw")
    }
    if let b = readDType(frame, 109, "u8") {
        fb.add(109, 1, "optical_amp_b", "optical", value: .int(b),
               note: "paired optical channel B (see optical_amp_a@108); 128 = record-level sentinel, always together with @108; raw")
    }
    if let d = readF32(frame, 113), d.isFinite {
        // A float32 at @113 (observed range ~ -5.3…0, 0 = unset); purpose unknown, carried raw.
        fb.add(113, 4, "unknown_f32_113", "aux", value: .double(d), note: "float32, purpose unknown")
    }
    // The bytes NOT annotated above are the constant zero padding (83–103, 105, 110–112, 117–119) and the
    // @104 = 0x01 marker; keep one honest raw region over the whole span so nothing is silently dropped.
    // PROVENANCE / lossless-tail note (A10): the fields above split into VERIFIED (physiologically
    // cross-checked vs the live 2A37 HR / |gravity|~1g: unix, heart_rate, rr, gravity, skin_temp) and
    // EMPIRICAL / not-pinned (status words, aux bytes, unknown_f32_113). This decoder never truncates
    // `frame`; the unmapped trailing bytes are preserved verbatim upstream (RawHistoryArchive for
    // undecodable records, the raw-capture batch when that toggle is on), so a future re-decode is
    // lossless. Kept in lockstep with the Android decodeWhoop5Historical provenance note.
    if let payloadEnd = payloadEnd, 82 < payloadEnd, payloadEnd <= frame.count {
        fb.region(82, payloadEnd, "optical/tail (mostly zero padding; see @106/@107/@108/@109/@113)", "unknown")
    }
}

/// Decode a WHOOP 5.0 type-47 **version-26** record — the high-rate optical PPG buffer.
///
/// Unlike the v18 per-second summary, v26 is a 24 Hz waveform: **24 little-endian i16 samples at bytes
/// [27:75]**, one record per second (`unix` u32 LE @15, the same slot v18 uses). It was verified to be
/// an OPTICAL PPG trace — not IMU/motion — using the heart rate as *internal* ground truth (no external
/// reference): the concatenated waveform's autocorrelation peaks at the HR (lag 14 = 102.9 bpm vs a
/// measured 101.7 bpm), trough-detection gives a 563 ms inter-beat interval (≈106 bpm), the pulse stays
/// HR-locked even when the wrist is still, and its amplitude is not motion-driven. (Reproduce with
/// `Tools/linux-capture/analyze_v26_waveform.py`; see docs §5.)
///
/// The samples are raw AC-coupled ADC counts — PPG has no absolute unit — so they are exposed verbatim
/// as `ppg_waveform` with NO invented scale. The bytes before [27] (header + a block index) and the
/// footer after [75] are not mapped; SpO₂/skin-temp have no internal proxy and are left untouched.
private func decodeWhoop5HistoricalV26(_ frame: [UInt8], fb: FieldBuilder) {
    // @21 is a small per-burst counter (`burst_index`), NOT the optical channel (PR#553). An earlier read
    // labelled it `ppg_channel` and gated it 1…26 because our two original fixtures happened to read 1 and
    // 2 — but a later capture read 65, far outside any 26-channel sweep, so @21 is not a stable channel id.
    // Re-surfaced as the neutral `burst_index` (gated bi > 0, the observed always-set sentinel) with NO
    // channel/LED semantics claimed; the physical optical-channel mapping is unproven and left unasserted.
    if let bi = readDType(frame, 21, "u8"), bi > 0 {
        fb.add(21, 1, "burst_index", "ppg", value: .int(bi),
               note: "per-burst counter (raw); NOT a channel id")
    }
    // record_index@11 (PR#563): the same monotonic lifetime per-record counter the v18/v20/v21 records
    // carry at @11 — +1 per record, independent of unix (advances across gaps). The only @11+ v26 field
    // proven by behaviour; everything else below stays raw/neutral.
    if let idx = readDType(frame, 11, "u32") {
        fb.add(11, 4, "record_index", "meta", value: .int(idx), note: "monotonic lifetime record index")
    }
    if let unix = readDType(frame, 15, "u32") {
        fb.add(15, 4, "unix", "time", value: .int(unix), note: "real unix seconds")
    }
    var samples: [Int] = []
    for off in stride(from: 27, to: 75, by: 2) {
        guard let v = readI16(frame, off) else { break }
        samples.append(v)
    }
    if !samples.isEmpty {
        fb.add(27, samples.count * 2, "ppg_waveform", "ppg", value: .intArray(samples),
               note: "optical PPG @24 Hz, LE-i16 ADC counts")
        fb.parsed["ppg_sample_count"] = .int(samples.count)
    }
    // PR#563: the remaining per-record v26 bytes, surfaced as RAW NEUTRAL fields — read off the real
    // fixtures but with NO invented semantics (deliberately not named segment_id / signal_quality / etc.).
    // Each is gated only to "present in range"; meaning is unpinned. The header @19/@23/@25 frame the
    // waveform block; @75/@79/@81/@82 trail it. (`@27…@75` is the proven waveform handled above.)
    for (name, off) in [("raw_u8_19", 19), ("raw_u8_23", 23), ("raw_u8_25", 25),
                        ("raw_u8_75", 75), ("raw_u8_79", 79), ("raw_u8_81", 81), ("raw_u8_82", 82)] {
        if let v = readDType(frame, off, "u8") {
            fb.add(off, 1, name, "raw", value: .int(v), note: "raw byte @\(off); meaning not pinned")
        }
    }
}

/// Decode WHOOP 5.0 type-47 **version-20 / version-21** records — the bulk multi-channel sensor stream
/// the strap serves alongside the v18 per-second summary. These are large records (v20 = 2140 B, v21 =
/// 1244 B) that earlier builds could not decode (issue #344): the offload "completed" but stored nothing.
///
/// Both versions reuse the v18 record header — layout version @9, a marker byte @10 (0x81 on v20, 0x80 on
/// v21), the monotonic u32 record index @11 (the same lifetime counter as v18), and the u32 unix second
/// @15. Their bodies are blocks of fixed-length sample channels, established from captured frames:
///   • v21 (1244 B): a (100, 100, 3) descriptor near @22, then SIX 100-sample i16 channels in two blocks —
///     accelerometer at @28 / @228 / @428 and gyroscope at @640 / @840 / @1040 (200 B apart; countB @630 =
///     100). This is 6-axis IMU, not optical: the accel channels sphere-fit to a ~1 g gravity shell on a
///     stationary strap (validated by Whoop5RawImu over 1423 real buffers, #423/#493).
///   • v20 (2140 B): five repeated 422-byte optical-measurement blocks. Each has a 21-byte header,
///     two 200-byte channel slots, and one reserved byte. Header byte 0 is the shared sample count; an
///     active block holds two 25-sample i32 channels (~25 Hz). The two channels share one measurement
///     header and must not be interpreted as two wavelengths. See `Whoop5RawOptical` for the lossless
///     structural model and the 25-vs-50 sample-count evidence.
///
/// v21 channels are named accel_/gyro_ per the gravity-shell evidence above. The v20 record is optical,
/// but its measurement wavelengths and channel geometry remain OPEN, so those channels stay neutrally
/// named. This layer exposes raw i16 (v21) or sign-extended i32 (v20) arrays; `Whoop5RawImu.decode`
/// applies the v21 physical scales.
private func decodeWhoop5HistoricalV2021(_ frame: [UInt8], fb: FieldBuilder, version: Int, payloadEnd: Int?) {
    if frame.count > 10 {
        fb.add(10, 1, "layout_marker", "meta", value: .int(Int(frame[10])))
    }
    if let idx = readU32(frame, 11) {
        fb.add(11, 4, "record_index", "meta", value: .int(idx), note: "monotonic lifetime record index")
    }
    if let unix = readU32(frame, 15) {
        fb.add(15, 4, "unix", "time", value: .int(unix), note: "real unix seconds")
    }
    if version == 21 {
        // TWO blocks of three 100-sample i16 channels: accelerometer (@28/@228/@428) then gyroscope
        // (@640/@840/@1040), matching the (100,100,3) header @22 and countB @630. NOT optical: on a
        // stationary strap the three accel channels sphere-fit to a ~1 g gravity shell (median |a| =
        // 1.006 g, 100/100 samples in-shell on the real fixture) — a gravity vector, which PPG cannot
        // produce. Validated as 6-axis IMU by Whoop5RawImu over 1423 real buffers (#423/#493). Emitted as
        // raw i16 arrays (this field layer applies no scale); the physical scales — 1/4096 g/LSB (accel),
        // 2000/32768 (°/s)/LSB (gyro) — are applied by Whoop5RawImu.decode.
        let channels: [(name: String, start: Int)] = [
            ("accel_x", 28), ("accel_y", 228), ("accel_z", 428),
            ("gyro_x", 640), ("gyro_y", 840), ("gyro_z", 1040),
        ]
        for (name, start) in channels {
            var samples: [Int] = []
            for i in 0..<100 {
                guard let v = readI16(frame, start + i * 2) else { break }
                samples.append(v)
            }
            if samples.count == 100 {
                fb.add(start, 200, name, "imu", value: .intArray(samples),
                       note: "raw i16 samples (scale via Whoop5RawImu: 1/4096 g accel, 2000/32768 dps gyro)")
            }
        }
        fb.parsed["sensor_channel_samples"] = .int(100)
        return
    }
    // version == 20: five repeated optical-measurement blocks. Each block carries one shared header and
    // two channel slots. This matters semantically: the two channels within a block are a detector/readout
    // pair for one measurement configuration, not evidence for two different LED wavelengths.
    //
    // EVIDENCE (why 25, not 50): across all 29,203 captured 2140-B buffers, exactly blocks 0/3/4 are active
    // (channel slots @47/247/1313/1513/1735/1935) and, in every active channel, sample slots 25..49 are
    // exactly 0.0 — only samples 0..24 carry data. Earlier builds read 50 and emitted arrays that were half
    // zeros. The block-header byte itself reads 0x19 = 25 on every active block, consistent with a live
    // per-block sample count. Each sample is a 4-byte LE container holding a 20-bit signed value (its upper
    // 12 bits are only ever 0x000/0xFFF — pure sign extension — across all captures), so reading it as i32
    // recovers the correct signed magnitude with no masking.
    //
    // Wavelength identity remains open. The six active channels in the current corpus are three pairs
    // (blocks 0/3/4), not six independent colors. In particular, block 4's two channels cannot be named
    // IR and red without independent evidence because they share the same block-level configuration.
    guard let optical = Whoop5RawOptical.decode(frame) else { return }
    fb.parsed["sensor_block_count"] = .int(optical.blocks.count)
    var present = 0
    for block in optical.blocks {
        let start = Whoop5RawOptical.blockStart + block.index * Whoop5RawOptical.blockLength
        fb.add(start, Whoop5RawOptical.headerLength, "block_b\(block.index)_header", "optical_config",
               value: .intArray(block.rawHeader.map(Int.init)),
               note: "raw: sample count + shared metadata + two 7-byte channel descriptors")
        fb.parsed["block_b\(block.index)_sample_count"] = .int(block.sampleCount)
        guard block.sampleCount > 0 else { continue }
        for (channelIndex, channel) in block.channels.enumerated() {
            let sampleStart = start + Whoop5RawOptical.headerLength
                + channelIndex * Whoop5RawOptical.channelSlotLength
            fb.add(sampleStart, block.sampleCount * 4,
                   "channel_b\(block.index)_\(channelIndex)", "sensor",
                   value: .intArray(channel.samples.map(Int.init)),
                   note: "raw signed i32 samples; paired under one block config; no wavelength or absolute unit asserted")
            present += 1
        }
    }
    fb.parsed["sensor_channel_samples"] = .int(optical.blocks.map(\.sampleCount).max() ?? 0)
    fb.parsed["sensor_channels_present"] = .int(present)
}

/// Decode WHOOP 5.0 METADATA (type 49) chunk fields so the historical-offload state machine can act
/// on them. `meta_type` is already added by the static-schema walk (4.0 @6 → 5.0 @10); a HISTORY_END
/// additionally carries the chunk's `unix` and `trim_cursor`, which `classifyHistoricalMeta` needs to
/// drive the `HISTORICAL_DATA_RESULT` ack. Offsets are the 4.0 metadata post-hook positions + 4,
/// verified on real WHOOP 5 HISTORY_END frames (trim decodes consistently across a whole capture).
/// `end_data` to echo back in the ack is `frame[21..29]` (trim u32 + next u32).
private func decodeWhoop5Metadata(_ frame: [UInt8], fb: FieldBuilder) {
    if let unix = readDType(frame, 11, "u32") { fb.add(11, 4, "unix", "time", value: .int(unix)) }
    if let ss = readDType(frame, 15, "u16") { fb.add(15, 2, "subsec", "time", value: .int(ss)) }
    if let trim = readDType(frame, 21, "u32") {
        fb.add(21, 4, "trim_cursor", "meta", value: .int(trim), note: "ack with this to advance")
    }
}

/// Build the WHOOP 5.0 historical-offload ack (`HISTORICAL_DATA_RESULT`, cmd 23) for one HISTORY_END
/// chunk. `endData` is the chunk's verbatim 8-byte trim block (`frame[21..29]`); the payload is
/// `[0x01] + endData`, framed as a puffin COMMAND. This is the WHOOP 5 image of `ackHistoricalChunk`
/// in `BLEManager`, and the byte-for-byte twin of the Python `build_history_ack` proven on hardware.
public func whoop5HistoricalAckFrame(endData: [UInt8], seq: UInt8) -> [UInt8] {
    puffinCommandFrame(cmd: 23, seq: seq, payload: [0x01] + endData)
}

/// Decode a WHOOP 5.0 COMMAND_RESPONSE (type 36) — battery %, history data-range, firmware version.
///
/// The response command is at frame[10] (the 4.0 frame[6] + 4) and its payload at frame[11]. WHOOP 5
/// reuses the 4.0 command NUMBERS, but the response PAYLOADS differ from 4.0 — so each field below is
/// mapped from a real WHOOP 5 capture (firmware 50.38.1.0), not ported on faith. Commands that return
/// a short stub on this firmware (REPORT_VERSION_INFO / GET_EXTENDED_BATTERY_INFO) or aren't served
/// (GET_CLOCK — unneeded, since realtime + historical carry real unix) are intentionally left undecoded.
private func decodeWhoop5CommandResponse(_ frame: [UInt8], fb: FieldBuilder, schema: Schema, payloadEnd: Int?) {
    guard let payloadEnd = payloadEnd, 11 < payloadEnd, payloadEnd <= frame.count else { return }
    let respCmd = Int(frame[10])
    let name = schema.enumName("CommandNumber", respCmd)   // e.g. "GET_BATTERY_LEVEL(26)"
    let pay = Array(frame[11..<payloadEnd])
    fb.region(11, payloadEnd, "response payload", "cmd")
    // Origin-seq echo + result code, the 4.0 offsets shifted by the usual +4 (#894). The Kotlin twin has
    // always published both here; this decoder published neither. Bounded by `pay` so a short reply
    // decodes nothing rather than reading the CRC32 trailer as a result.
    if pay.count >= 1 { fb.add(11, 1, "resp_seq", "cmd", value: .int(Int(pay[0]))) }
    if pay.count >= 2 {
        fb.add(12, 1, "result", "cmd", value: .string(schema.enumName("CommandResult", Int(pay[1]))))
    }
    if name.hasPrefix("GET_BATTERY_LEVEL"), pay.count >= 3 {
        // Direct percent at pay[2] (47% confirmed against the app) — the 4.0 deci-percent ÷10 is gone.
        fb.add(11 + 2, 1, "battery_pct", "battery", value: .double(Double(pay[2])), note: "%")
    } else if name.hasPrefix("GET_DATA_RANGE"), pay.count >= 7 {
        // The long response carries record cursors + real-unix timestamps as 4-byte-aligned u32s from
        // pay[3]; the history window is their min/max. (A short ack response also exists — no
        // timestamps — so this no-ops on it.)
        var oldest = UInt32.max, newest: UInt32 = 0
        var o = 3
        while o + 4 <= pay.count {
            let v = UInt32(pay[o]) | (UInt32(pay[o + 1]) << 8) | (UInt32(pay[o + 2]) << 16) | (UInt32(pay[o + 3]) << 24)
            if v >= 1_600_000_000 && v <= 1_800_000_000 { oldest = min(oldest, v); newest = max(newest, v) }
            o += 4
        }
        if newest > 0 {
            fb.parsed["history_oldest"] = .int(Int(oldest))
            fb.parsed["history_newest"] = .int(Int(newest))
        }
    } else if respCmd == 145, pay.count >= 26 {
        // GET_HELLO info block. We surface the two user-facing fields the app shows — the device NAME
        // (the model-style label the strap calls itself) and the firmware VERSION — and deliberately never
        // read the session token (also in this response). Both offsets are anchored to a real
        // 50.38.1.0 capture: the name is printable ASCII at pay[16]; the version is 4 bytes at pay[93],
        // after the (fixed-width on this firmware) name+token region. Re-verify the version offset
        // across firmwares; the guards (printable name / pay[93]==50 "5.0" generation) fail closed.
        var nameBytes: [UInt8] = []
        var i = 16
        while i < pay.count, pay[i] != 0, (32...126).contains(pay[i]), nameBytes.count < 24 {
            nameBytes.append(pay[i]); i += 1
        }
        if nameBytes.count >= 6 {
            fb.parsed["device_name"] = .string(String(decoding: nameBytes, as: UTF8.self))
        }
        if pay.count >= 97, pay[93] == 50 {
            fb.parsed["fw_version"] = .string("\(pay[93]).\(pay[94]).\(pay[95]).\(pay[96])")
        } else {
            // The guards fail closed by design, which left a strap reporting no firmware with no way to
            // say WHY - a different generation byte and a MOVED offset look identical from a log. Carry
            // the evidence instead; see `firmwareGateDiagnostic`.
            fb.parsed["fw_gate"] = .string(firmwareGateDiagnostic(payload: pay, nameEndIndex: i))
        }
    }
}

/// Decode a WHOOP 5.0 EVENT (type 48) per-event payload.
///
/// `event` (u8 @10, EventNumber) and `event_timestamp` (u32 @12, real unix) are already set by the
/// static +4 walk. This hook adds the BATTERY_LEVEL payload, which follows the same +4 rule as the
/// rest of the 5.0 layout: 4.0's soc@17 / mv@21 / charge@26 become soc@21 / mv@25 / charge@30. Unlike
/// the 5.0 COMMAND_RESPONSE (which switched to a DIRECT percent), the EVENT battery keeps 4.0's
/// deci-percent (÷10) — confirmed by a clean monotonic discharge across a real capture (49.9 → 47.7 %).
/// The same range guards as the 4.0 `event` post-hook fail closed.
///
/// Event NAMES come only from the shared `EventNumber` schema, so an unnamed number the firmware emits
/// (e.g. 123) stays the raw `0x7B(123)` set by the static walk and gets no payload here — never a name
/// borrowed from another enum (`CommandNumber` 123 is `SELECT_WRIST`) or invented. Other events'
/// payloads (EXTENDED_BATTERY_INFORMATION, STRAP_CONDITION_REPORT) lack on-device 5.0 ground truth and
/// are intentionally left raw rather than ported from 4.0 on faith.
private func decodeWhoop5Event(_ frame: [UInt8], fb: FieldBuilder, schema: Schema) {
    guard let evVal = readDType(frame, 10, "u8") else { return }
    guard schema.enums["EventNumber"]?[String(evVal)] == "BATTERY_LEVEL" else { return }
    if let raw = readDType(frame, 21, "u16"), raw <= 1100 {
        fb.add(21, 2, "battery_pct", "battery", value: .double(Double(raw) / 10), note: "%")
    }
    if let mv = readDType(frame, 25, "u16"), (3000...4300).contains(mv) {
        fb.add(25, 2, "battery_mV", "battery", value: .int(mv), note: "mV")
    }
    if let ch = readDType(frame, 30, "u8"), ch <= 1 {
        fb.add(30, 1, "battery_charging", "battery", value: .int(ch & 1))
    }
}

/// Decode a WHOOP 5.0 CONSOLE_LOGS (type 50) frame — the strap firmware's own plaintext diagnostics
/// channel. The console is one continuous text stream chunked into fixed-size pieces, so a log line
/// routinely splits mid-sentence across frames; consumers reassemble by `record_index` order before
/// reading. Lines look like `19, 146552119: BLE: History burst success. Trim: …` (boot-count,
/// firmware tick ms, tag, message) and narrate the history sync and the sensor pipeline
/// ("SENSORS: AFE configuration changed", "SIGPROC: generated a valid SPO2 during sleep") — primary
/// raw material for the deep-data work (#103).
///
/// Record header, verified across 3 257 real frames from two nights (all one shape: 76-byte frame,
/// chunk_len 52, channel 1): `record_index` u16@9 (monotonic per-chunk counter — the frame's u8 seq
/// slot is its low byte), `unix` u32@12 + `subsec` u16@16 (batch write time), chunk_len u16@18,
/// channel u8@20, text bytes @21 up to the CRC32 trailer with NUL padding. The Kotlin twin is
/// `Framing.decodeConsoleLogsWhoop5` (text key "console"), same offsets.
private func decodeWhoop5ConsoleLogs(_ frame: [UInt8], fb: FieldBuilder, payloadEnd: Int?) {
    if let idx = readDType(frame, 9, "u16") {
        fb.add(9, 2, "record_index", "meta", value: .int(idx), note: "per-chunk counter")
    }
    if let unix = readDType(frame, 12, "u32") { fb.add(12, 4, "unix", "time", value: .int(unix)) }
    if let ss = readDType(frame, 16, "u16") { fb.add(16, 2, "subsec", "time", value: .int(ss)) }
    guard let payloadEnd = payloadEnd, 21 < payloadEnd, payloadEnd <= frame.count else { return }
    var textBytes = Array(frame[21..<payloadEnd])
    while textBytes.last == 0 { textBytes.removeLast() }
    guard !textBytes.isEmpty else { return }
    let txt = String(decoding: textBytes, as: UTF8.self)
    fb.region(21, payloadEnd, "console log text", "text", note: String(txt.prefix(80)))
    // Same 2 KB cap as the 4.0 console post-hook: a garbled/malicious peer must not pin arbitrary
    // bytes as a String on the parse path. A real chunk is 51 bytes.
    fb.parsed["log"] = .string(String(txt.prefix(2048)))
}

@inline(__always)
private func hexFrameSlice(_ f: [UInt8], _ start: Int, _ end: Int) -> String {
    guard start >= 0, end <= f.count, start < end else { return "" }
    return f[start..<end].map { String(format: "%02x", $0) }.joined()
}

// Post-hook registry (populated in PostHooks.swift by Task B7).
// name -> (FieldBuilder, frame, length, schema) -> Void
typealias PostHook = (FieldBuilder, [UInt8], Int?, Schema) -> Void
var postHooks: [String: PostHook] = [:]
