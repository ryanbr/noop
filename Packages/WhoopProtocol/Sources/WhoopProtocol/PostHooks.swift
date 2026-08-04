import Foundation

// Local LE readers mirroring interpreter._read (nil when out of range).
private func u8(_ f: [UInt8], _ off: Int) -> Int? { off + 1 <= f.count ? Int(f[off]) : nil }
private func u16(_ f: [UInt8], _ off: Int) -> Int? {
    off + 2 <= f.count ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}
private func u32(_ f: [UInt8], _ off: Int) -> UInt32? {
    guard off + 4 <= f.count else { return nil }
    return UInt32(f[off]) | (UInt32(f[off + 1]) << 8) | (UInt32(f[off + 2]) << 16) | (UInt32(f[off + 3]) << 24)
}
/// signed 24-bit little-endian (mirrors interpreter._read "s24"); nil when out of range.
private func s24(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 3 <= f.count else { return nil }
    let v = Int(f[off]) | (Int(f[off + 1]) << 8) | (Int(f[off + 2]) << 16)
    return (v & 0x800000) != 0 ? v - 0x1000000 : v
}
/// IEEE-754 float32 LE -> Double (exact, NO rounding). nil when out of range.
private func f32(_ f: [UInt8], _ off: Int) -> Double? {
    guard let bits = u32(f, off) else { return nil }
    return Double(Float(bitPattern: bits))
}
/// Read an unsigned integer dtype (u8/u16/u32) as Int; nil when out of range.
private func readHistInt(_ f: [UInt8], _ off: Int, _ dtype: String) -> Int? {
    switch dtype {
    case "u8": return u8(f, off)
    case "u16": return u16(f, off)
    case "u32": return u32(f, off).map { Int($0) }
    default: return nil
    }
}

/// Read `count` signed i16 LE starting at off, clamping count to the available bytes
/// (mirrors interpreter._i16_block).
private func i16Block(_ frame: [UInt8], _ off: Int, _ count: Int) -> [Int] {
    var n = count
    if off + n * 2 > frame.count {
        n = max(0, (frame.count - off) / 2)
    }
    guard n > 0 else { return [] }
    var out: [Int] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let p = off + i * 2
        let raw = UInt16(frame[p]) | (UInt16(frame[p + 1]) << 8)
        out.append(Int(Int16(bitPattern: raw)))
    }
    return out
}

/// Error-free transformation of a * b into (product, error).
/// Uses Knuth / Dekker splitting so that a * b = product + error exactly.
private func twoProduct(_ a: Double, _ b: Double) -> (Double, Double) {
    let p = a * b
    let split = 134217729.0  // 2^27 + 1 (Dekker/Knuth constant)
    let ca = split * a;  let ah = ca - (ca - a);  let al = a - ah
    let cb = split * b;  let bh = cb - (cb - b);  let bl = b - bh
    let err = ((ah * bh - p) + ah * bl + al * bh) + al * bl
    return (p, err)
}

/// Round to 1 decimal place, matching Python's round(x, 1) exactly.
///
/// Python's round(x, 1) uses an internal error-correction step: after computing
/// z = rint(x * 10), it checks whether the true value of x * 10 (via an error-free
/// transformation) is above or below the half-integer z + 0.5, and adjusts if so.
/// This matches Python's behaviour for cases where x * 10 lands on an exact half-integer
/// in double arithmetic even though x is not mathematically at the midpoint.
private func round1(_ x: Double) -> Double {
    let y = x * 10.0
    let fl = y.rounded(.down)
    let frac = y - fl
    // Fast path: not at an exact half-integer → standard round-to-nearest-even is correct.
    guard abs(frac - 0.5) < 1e-14 else {
        return y.rounded(.toNearestOrEven) / 10.0
    }
    // y is exactly at a half-integer in double arithmetic.
    // Use the error-free transformation to determine whether the TRUE product x*10
    // is above or below the half-integer (i.e. whether x is above or below the midpoint).
    let (_, err) = twoProduct(x, 10.0)
    if err > 0 {
        return y.rounded(.up) / 10.0    // true product above half-int → ceiling
    } else if err < 0 {
        return fl / 10.0                // true product below half-int → floor
    } else {
        // Exactly at the mathematical half-integer: banker's rounding on fl.
        let z = Int(fl)
        return (z % 2 == 0 ? fl : fl + 1.0) / 10.0
    }
}

/// Format a rounded-to-1dp mean the way Python's str() renders a float.
/// Python str(round(x, 1)) always keeps one decimal: "62.9", "3637.8", "5.0".
func formatMean(_ x: Double) -> String {
    String(format: "%.1f", x)
}

private let utcRangeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
    return f
}()

func registerPostHooks() {
    postHooks["realtime_data"] = { fb, frame, _, _ in
        let rrn = u8(frame, 13) ?? 0
        var rrs: [Int] = []
        for i in 0..<rrn {
            // Drop 0 ms intervals here too, matching the historical path (Streams.extractStreams);
            // a 0 ms R-R is a placeholder, not a beat-to-beat interval.
            if let v = u16(frame, 14 + i * 2), v > 0 {
                fb.add(14 + i * 2, 2, "rr[\(i)]", "rr", value: .int(v), note: "ms")
                rrs.append(v)
            }
        }
        fb.parsed["rr_intervals"] = .intArray(rrs)
    }

    postHooks["event"] = { fb, frame, length, schema in
        let evVal = frame.count > 6 ? Int(frame[6]) : nil
        let evName = evVal.flatMap { schema.enums["EventNumber"]?[String($0)] }
        guard let length = length else { return }
        if evName == "BATTERY_LEVEL" {
            // Fixed layout, empirically verified against captured frames (matches the WHOOP
            // Payload-slice offsets 1/5/10 after our SOF/len/crc8 prefix +
            // u32 event_timestamp@8). Emitted ~every 8 min → a DENSE battery series.
            //   soc% = u16@17/10 · mV = u16@21 · charging = u8@26 bit0
            fb.region(7, length, "BATTERY_LEVEL payload", "battery", note: "soc@17(/10) mv@21 charge@26")
            if let raw = u16(frame, 17), raw <= 1100 {
                fb.parsed["battery_pct"] = .double(Double(raw) / 10)
            }
            if let mv = u16(frame, 21), (3000...4300).contains(mv) {
                fb.parsed["battery_mV"] = .int(mv)
            }
            if let ch = u8(frame, 26), ch <= 1 {
                fb.parsed["battery_charging"] = .int(ch & 1)
            }
        } else if evName == "EXTENDED_BATTERY_INFORMATION" {
            // Not decoded by the WHOOP app; keep the heuristic mV scan only.
            let payEnd = min(length, frame.count)
            guard 7 < payEnd else { return }
            let pay = Array(frame[7..<payEnd])
            fb.region(7, length, "EXTENDED_BATTERY_INFORMATION payload", "battery", note: "mV (heuristic scan)")
            if pay.count >= 2 {
                for o in 0..<(pay.count - 1) {
                    let v = Int(pay[o]) | (Int(pay[o + 1]) << 8)
                    if 3000 <= v && v <= 4300 {
                        fb.parsed["battery_mV?"] = .int(v)
                        break
                    }
                }
            }
        }
    }

    postHooks["command_response"] = { fb, frame, length, schema in
        guard let length = length else { return }
        let payEnd = min(length, frame.count)
        guard 7 <= payEnd else { return }
        let pay = Array(frame[7..<payEnd])
        fb.region(7, length, "response payload", "cmd")
        // The origin-seq echo and the result code (#894). Kotlin has published both on this family since
        // #791 and on 5/MG since the port; Swift published neither, so an Apple strap log could not say
        // whether a command the app sent succeeded — and every probe that needed the answer re-derived
        // this byte privately (FeatureFlagProbe.resultLabel, DeviceConfigReadProbe, BodyLocationProbe).
        //
        // Read from `pay`, not the raw frame, so a response too short to carry them decodes nothing
        // rather than reporting CRC32 bytes as a result code. Same offsets and the same
        // `"NAME(raw)"` rendering as the Kotlin twin, so the two platforms' logs are comparable.
        if pay.count >= 1 { fb.add(7, 1, "resp_seq", "cmd", value: .int(Int(pay[0]))) }
        if pay.count >= 2 {
            fb.add(8, 1, "result", "cmd", value: .string(schema.enumName("CommandResult", Int(pay[1]))))
        }
        let cmd = frame.count > 6 ? Int(frame[6]) : nil
        let name = cmd.flatMap { schema.enums["CommandNumber"]?[String($0)] }
        switch name {
        case "GET_BATTERY_LEVEL" where pay.count >= 4:
            let v = Int(pay[2]) | (Int(pay[3]) << 8)
            fb.parsed["battery_pct"] = .double(Double(v) / 10)
        case "GET_CLOCK" where pay.count >= 6:
            let v = UInt32(pay[2]) | (UInt32(pay[3]) << 8) | (UInt32(pay[4]) << 16) | (UInt32(pay[5]) << 24)
            fb.parsed["clock"] = .int(Int(v))
        case "GET_EXTENDED_BATTERY_INFO" where pay.count >= 9:
            let v = Int(pay[7]) | (Int(pay[8]) << 8)
            fb.parsed["battery_mV"] = .int(v)
        case "REPORT_VERSION_INFO" where pay.count >= 31:
            // "<BBBLLLLLLLL" = 3 + 8*4 = 35 bytes; pad short payloads to 35.
            var buf: [UInt8]
            if pay.count >= 35 {
                buf = Array(pay[0..<35])
            } else {
                buf = Array(pay[0..<31])
                buf.append(contentsOf: [UInt8](repeating: 0, count: 4))
            }
            // struct '<BBBLLLLLLLL': B[0], B[1], B[2], then 8 LE u32 at bytes 3, 7, 11, 15, 19, 23, 27, 31
            func le32(_ at: Int) -> UInt32 {
                UInt32(buf[at]) | (UInt32(buf[at + 1]) << 8) | (UInt32(buf[at + 2]) << 16) | (UInt32(buf[at + 3]) << 24)
            }
            // u[3..6] = fw_harvard (a.b.c.d), u[7..10] = fw_boylston
            let h0 = le32(3), h1 = le32(7), h2 = le32(11), h3 = le32(15)
            let b0 = le32(19), b1 = le32(23), b2 = le32(27), b3 = le32(31)
            fb.parsed["fw_harvard"] = .string("\(h0).\(h1).\(h2).\(h3)")
            fb.parsed["fw_boylston"] = .string("\(b0).\(b1).\(b2).\(b3)")
        case "GET_DATA_RANGE":
            // Set membership instead of an O(n) linear scan inside a byte-by-byte sliding window
            // over the whole payload (was O(n^2)).
            var seen = Set<UInt32>()
            var o = 3
            while o < pay.count - 3 {
                let v = UInt32(pay[o]) | (UInt32(pay[o + 1]) << 8)
                    | (UInt32(pay[o + 2]) << 16) | (UInt32(pay[o + 3]) << 24)
                if v >= 1_600_000_000 && v <= 1_800_000_000 {
                    seen.insert(v)
                }
                o += 1
            }
            if let lo = seen.min(), let hi = seen.max() {
                fb.parsed["history_oldest"] = .string(
                    utcRangeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(lo))))
                fb.parsed["history_newest"] = .string(
                    utcRangeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(hi))))
            }
        default:
            break
        }
    }

    postHooks["raw_data"] = { fb, frame, length, schema in
        guard let length = length else { return }
        let spec = schema.packet(forType: Int(frame[4]))
        let dataLen = length - 7
        guard let variant = spec?.variants[String(dataLen)] else {
            fb.region(21, length, "sensor payload (short/alt subtype)", "unknown")
            return
        }
        if variant.kind == "imu" {
            guard let hrOff = variant.hrOff,
                  let rrCountOff = variant.rrCountOff,
                  let rrFirstOff = variant.rrFirstOff,
                  let samples = variant.samples,
                  let tailFrom = variant.tailFrom else { return }
            let hr = u8(frame, hrOff)
            let rrn = u8(frame, rrCountOff) ?? 0
            fb.add(hrOff, 1, "heart_rate", "hr", value: hr.map { .int($0) }, note: "bpm")
            fb.add(rrCountOff, 1, "rr_count", "rr", value: .int(rrn))
            var rrVals: [Int] = []
            for i in 0..<min(rrn, 4) {
                let off = rrFirstOff + i * 2
                fb.add(off, 2, "rr[\(i)]", "rr", value: u16(frame, off).map { .int($0) }, note: "ms")
                if let v = u16(frame, off) { rrVals.append(v) }
            }
            fb.parsed["heart_rate"] = hr.map { .int($0) }
            fb.parsed["rr_intervals"] = .intArray(rrVals)
            for axis in variant.axes {
                let vals = i16Block(frame, axis.off, samples)
                let mean: Double? = vals.isEmpty ? nil
                    : round1(Double(vals.reduce(0, +)) / Double(vals.count))
                let text: ParsedValue? = mean.map { .string("mean=\(formatMean($0)) (\(vals.count)xi16)") }
                fb.add(axis.off, samples * 2, axis.name, axis.cat, value: text, note: variant.note)
                if let mean = mean {
                    // Python's round() returns a float, but Python's JSON encoder writes
                    // integral floats (e.g. 3644.0) without a decimal suffix in some JSON
                    // serialisers, and Swift's JSONDecoder decodes bare integers as Int.
                    // Golden.json uses json.dumps which writes 3644.0 as "3644.0", and
                    // ParsedValue decodes that as .int(3644) because Int.self is tried first
                    // and 3644.0 is representable as Int. Mirror that: store integral means
                    // as .int so the ParsedValue round-trip is consistent.
                    if mean == mean.rounded() && !mean.isNaN {
                        fb.parsed["\(axis.name)_mean"] = .int(Int(mean))
                    } else {
                        fb.parsed["\(axis.name)_mean"] = .double(mean)
                    }
                }
            }
            fb.region(tailFrom, length, "tail (optical? - not parsed by app)", "unknown")
        } else if variant.kind == "optical" {
            guard let ppgOff = variant.ppgOff,
                  let ppgStride = variant.ppgStride,
                  let ppgSamples = variant.ppgSamples,
                  let configFrom = variant.configFrom else { return }
            fb.region(configFrom, ppgOff, "optical config header (UNKNOWN)", "unknown", note: variant.note)
            var vals: [Int] = []
            for i in 0..<ppgSamples {
                guard let v = s24(frame, ppgOff + i * ppgStride) else { break }
                vals.append(v)
            }
            if !vals.isEmpty {
                let mean = round1(Double(vals.reduce(0, +)) / Double(vals.count))
                fb.add(ppgOff, vals.count * ppgStride, "ppg_green_ac", "ppg",
                       value: .string("mean=\(formatMean(mean)) (\(vals.count)xs24)"), note: variant.note)
                fb.parsed["ppg_sample_count"] = .int(vals.count)
                // Same integral-mean rule used for IMU axis means above.
                if mean == mean.rounded() && !mean.isNaN {
                    fb.parsed["ppg_mean"] = .int(Int(mean))
                } else {
                    fb.parsed["ppg_mean"] = .double(mean)
                }
            }
        }
    }

    postHooks["historical_data"] = { fb, frame, length, schema in
        guard let length = length else { return }
        let spec = schema.packet(forType: Int(frame[4]))
        let version = Int(frame[5])
        fb.parsed["hist_version"] = .int(version)

        // WHOOP 4.0 **v25** historical layout (issue #30). Reverse-engineered from 45 real records on
        // v1.92+ full dumps (faklei / FrankdeJong / tchoucker15): an 84-byte record with `unix` @11
        // (u32 LE) and the DSP gravity vector at @73/75/77 as 3×i16 LE / 16384 — |gravity| ≈ 1 g on
        // 45/45 records (resting 0.94–0.99 g). Bytes 23–72 are the optical PPG waveform; per-second HR
        // is NOT stored in v25 (it's PPG-derived), so this yields **motion + timestamp** — exactly what
        // the sleep stager gates on (it returns no stages without gravity). Additive + version-gated,
        // so v18/v24/v26 straps are untouched.
        if version == 25, frame.count >= 79 {
            if let unix = u32(frame, 11) {
                fb.add(11, 4, "unix", "time", value: .int(Int(unix)), note: "real unix seconds")
                fb.parsed["unix"] = .int(Int(unix))
            }
            func grav(_ off: Int) -> Double? {
                guard let u = u16(frame, off) else { return nil }
                return Double(u >= 32768 ? u - 65536 : u) / 16384.0   // i16 LE, ±2 g full-scale
            }
            if let gx = grav(73), let gy = grav(75), let gz = grav(77) {
                let mag = (gx * gx + gy * gy + gz * gz).squareRoot()
                if (0.5...1.5).contains(mag) {   // a real DSP orientation vector is ~1 g; reject garbage
                    fb.add(73, 2, "gravity_x", "accel", value: .double(gx), note: "g")
                    fb.add(75, 2, "gravity_y", "accel", value: .double(gy), note: "g")
                    fb.add(77, 2, "gravity_z", "accel", value: .double(gz), note: "g")
                    fb.parsed["gravity_x"] = .double(gx)
                    fb.parsed["gravity_y"] = .double(gy)
                    fb.parsed["gravity_z"] = .double(gz)
                }
            }
            fb.parsed["rr_intervals"] = .intArray([])
            fb.region(23, 73, "PPG waveform (optical)", "ppg")
            return
        }

        let mapped = spec.flatMap { schema.resolveVersion($0.versions, version) }
        // Unmapped firmware version: instead of dropping the whole record (→ no HR/R-R/GRAVITY → sleep
        // can never compute from the strap, issue #30), fall back to the canonical v24 DSP layout —
        // firmware versions overwhelmingly share it (the schema notes V12 == V24). We then accept it
        // ONLY if it decodes to something physically real (validated after the field decode below): a
        // wrong layout yields random f32 gravity whose magnitude is nowhere near 1 g, so it's rejected
        // and the record is left raw. Mapped versions are unaffected.
        let usingFallback = (mapped == nil)
        guard let entry = mapped ?? spec.flatMap({ schema.resolveVersion($0.versions, 24) }) else {
            fb.region(7, length, "HISTORICAL_DATA v\(version) (unmapped layout)", "unknown")
            return
        }
        for fld in entry.fields {
            guard let dtype = fld.dtype else { continue }
            let value: ParsedValue
            switch dtype {
            case "u8", "u16", "u32":
                guard let v = readHistInt(frame, fld.off, dtype) else { continue }
                if let enumKey = fld.`enum` {
                    value = .string(schema.enumName(enumKey, v))
                } else {
                    value = .int(v)
                }
            case "f32":
                guard let d = f32(frame, fld.off) else { continue }
                value = .double(d)  // NO rounding — float32->Double is exact.
            default:
                continue
            }
            fb.add(fld.off, fld.len, fld.name, fld.cat, value: value, note: fld.note)
        }
        var rrVals: [Int] = []
        if let rrFirst = entry.rrFirstOff {
            let rrn = fb.parsed["rr_count"]?.intValue ?? 0
            for i in 0..<min(rrn, 4) {
                let o = rrFirst + i * 2
                if let v = u16(frame, o), v != 0 {
                    fb.add(o, 2, "rr[\(i)]", "rr", value: .int(v), note: "ms")
                    rrVals.append(v)
                }
            }
        }
        fb.parsed["rr_intervals"] = .intArray(rrVals)

        // Validate the v24-layout guess for an unmapped version: gravity is the DSP-separated
        // orientation vector, so |gravity| ≈ 1 g on a real record regardless of motion. If the magnitude
        // isn't ~1 g (or HR is implausible), the layout doesn't fit this firmware — drop the decoded
        // biometrics so nothing garbage is stored, and leave the record raw (the Backfiller then logs the
        // unmapped version, issue #30). Mapped versions skip this entirely.
        if usingFallback {
            let gx = fb.parsed["gravity_x"]?.doubleValue ?? Double.nan
            let gy = fb.parsed["gravity_y"]?.doubleValue ?? Double.nan
            let gz = fb.parsed["gravity_z"]?.doubleValue ?? Double.nan
            let mag = (gx * gx + gy * gy + gz * gz).squareRoot()
            let hr = fb.parsed["heart_rate"]?.intValue ?? 0
            if !((0.8...1.2).contains(mag) && (25...230).contains(hr)) {
                for k in ["heart_rate", "rr_count", "rr_intervals",
                          "gravity_x", "gravity_y", "gravity_z", "unix", "subseconds"] {
                    fb.parsed.removeValue(forKey: k)
                }
                fb.region(7, length, "HISTORICAL_DATA v\(version) (unmapped; v24 layout rejected)", "unknown")
            }
        }
    }

    postHooks["metadata"] = { fb, frame, length, _ in
        guard let length = length else { return }
        let payEnd = min(length, frame.count)
        guard 7 < payEnd else { return }
        let pay = Array(frame[7..<payEnd])
        if pay.count >= 14 {
            // struct '<LHLL': u32, u16, u32, u32
            let unix = UInt32(pay[0]) | (UInt32(pay[1]) << 8) | (UInt32(pay[2]) << 16) | (UInt32(pay[3]) << 24)
            let ss = Int(pay[4]) | (Int(pay[5]) << 8)
            let unk0 = UInt32(pay[6]) | (UInt32(pay[7]) << 8) | (UInt32(pay[8]) << 16) | (UInt32(pay[9]) << 24)
            let trim = UInt32(pay[10]) | (UInt32(pay[11]) << 8) | (UInt32(pay[12]) << 16) | (UInt32(pay[13]) << 24)
            fb.add(7, 4, "unix", "time", value: .int(Int(unix)))
            fb.add(11, 2, "subsec", "time", value: .int(ss))
            fb.add(13, 4, "unk0", "meta", value: .int(Int(unk0)))
            fb.add(17, 4, "trim_cursor", "meta", value: .int(Int(trim)), note: "ack with this to advance")
        }
    }

    postHooks["console_logs"] = { fb, frame, length, _ in
        guard let length = length else { return }
        var txt = ""
        let lo = 11
        let hi = length - 1
        if lo < hi && hi <= frame.count {
            txt = String(decoding: Array(frame[lo..<hi]), as: UTF8.self)
        }
        let head = String(txt.prefix(80))
        fb.region(7, length, "console log text", "text", note: head)
        // Cap the stored value: a garbled/malicious peer could otherwise pin up to ~64 KB of
        // arbitrary bytes per frame as a String on the parse path. A log line is never this long.
        fb.parsed["log"] = .string(String(txt.prefix(2048)))
    }
}
