import Foundation

// MARK: - FIT parser (Garmin/ANT FIT binary)
//
// The FIT file format (Flexible and Interoperable Data Transfer), as documented publicly by Garmin in
// the FIT SDK. Structure:
//
//   ┌ File header (12 or 14 bytes) ────────────────────────────────────────────────┐
//   │ u8  headerSize (12 or 14)                                                      │
//   │ u8  protocolVersion                                                            │
//   │ u16 profileVersion (little-endian)                                             │
//   │ u32 dataSize (little-endian) — bytes of records that follow the header         │
//   │ 4×u8 ".FIT" signature                                                          │
//   │ [u16 headerCRC] — present only when headerSize == 14                           │
//   └───────────────────────────────────────────────────────────────────────────────┘
//   Then `dataSize` bytes of RECORDS, each led by a 1-byte record header:
//     • Normal header:  bit7=0. bit6=1 → DEFINITION message, 0 → DATA message.
//                       bit5 → has developer fields (definition). bits0-3 → local message type.
//     • Compressed-timestamp header: bit7=1. bits5-6 → local message type, bits0-4 → time offset.
//   A DEFINITION record describes a local message type: reserved(u8), architecture(u8: 0=LE,1=BE),
//     globalMessageNumber(u16), numFields(u8), then numFields × (fieldDefNum u8, size u8, baseType u8).
//     If the header's dev-fields bit is set: numDevFields(u8) then that many × 3 bytes (we skip them).
//   A DATA record carries the fields for its local type, in definition order, each `size` bytes.
//   Trailing 2-byte file CRC after the data section.
//
// We decode the messages that matter for a workout summary + HR/route:
//   • record (20)   — the per-sample stream: timestamp(253), position_lat(0)/long(1) in semicircles,
//                     heart_rate(3), altitude(2), distance(5).
//   • lap (19)      — per-lap summary: total_distance(9), total_calories(11), total_ascent(21),
//                     avg/max_heart_rate(15/16).
//   • session (18)  — whole-activity summary: sport(5), start_time(2), total_distance(9),
//                     total_calories(11), total_ascent(22), avg/max_heart_rate(16/17),
//                     total_elapsed_time(7).
//
// DEFERRED (flagged in the lane risks): developer-defined fields (skipped, not decoded),
// compressed-timestamp accumulation across records (the offset is honoured within the 32 s window but
// we don't accumulate a rolling base across many records — rare in modern files), and the long-tail of
// message types (device_info, event, hrv, monitoring, etc.). Those are skipped gracefully, never fatal.
//
// Conceptually adapted from the public FIT spec and the structure of roznet/FitFileParser,
// FitnessKit/FitDataProtocol (MIT) and muktihari/fit (BSD); NOOP's own clean implementation — no
// upstream code vendored.
//
// SECURITY: every read is bounds-checked against the buffer. Field/record counts are capped. A
// declared dataSize larger than the buffer is clamped. Semicircle→degree and FIT-epoch→Date conversions
// are range-checked. A malformed file yields `activity == nil`, never a crash.

enum FitParser {

    // FIT timestamps are seconds since the FIT epoch 1989-12-31T00:00:00Z (631065600 unix seconds).
    static let fitEpochOffset: Double = 631_065_600
    // Semicircles → degrees: value * (180 / 2^31).
    static let semicircleToDegrees = 180.0 / 2_147_483_648.0

    // Caps (DoS): a long activity is tens of thousands of records; these are generous ceilings that
    // still bound work against a crafted file claiming millions of records or absurd field counts.
    static let maxRecords = 2_000_000
    static let maxFieldsPerDef = 255    // a u8 count can't exceed this anyway; keep explicit.

    static func parse(data: Data) -> ActivityFileImportResult {
        // Work on a contiguous byte array for cheap random access (the picker handed us a local copy).
        let bytes = [UInt8](BOM.stripUTF8(data))
        guard bytes.count >= 12 else {
            return ActivityFileImportResult(activity: nil, kind: .fit, skipped: 0)
        }

        let headerSize = Int(bytes[0])
        // Signature ".FIT" at offset 8 confirms the format.
        guard headerSize >= 12, headerSize <= bytes.count,
              bytes[8] == UInt8(ascii: "."), bytes[9] == UInt8(ascii: "F"),
              bytes[10] == UInt8(ascii: "I"), bytes[11] == UInt8(ascii: "T") else {
            return ActivityFileImportResult(activity: nil, kind: .fit, skipped: 0)
        }

        let declaredDataSize = Int(readU32LE(bytes, 4))
        // Clamp the data window to what's actually in the buffer (minus a possible 2-byte trailing CRC).
        let dataStart = headerSize
        let maxAvailable = bytes.count - dataStart
        let dataSize = min(declaredDataSize, max(0, maxAvailable))
        let dataEnd = dataStart + dataSize
        guard dataEnd <= bytes.count, dataStart < dataEnd else {
            return ActivityFileImportResult(activity: nil, kind: .fit, skipped: 0)
        }

        var decoder = FitDecoder(bytes: bytes, end: dataEnd)
        decoder.run(from: dataStart)

        return decoder.buildResult()
    }

    // MARK: - Little-endian readers (bounds are the caller's responsibility; these assume validity)

    static func readU16LE(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    static func readU32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    static func readU16BE(_ b: [UInt8], _ i: Int) -> UInt16 {
        (UInt16(b[i]) << 8) | UInt16(b[i + 1])
    }
    static func readU32BE(_ b: [UInt8], _ i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
}

// MARK: - Decoder

private struct FitDecoder {
    let bytes: [UInt8]
    let end: Int

    /// A field's layout within a definition.
    struct FieldDef { let num: Int; let size: Int; let baseType: UInt8 }
    /// A local message type's definition: which global message + its fields + byte order.
    struct Definition { let globalNum: Int; let fields: [FieldDef]; let bigEndian: Bool; let totalSize: Int }

    // Local-type → active definition (FIT reuses 0–15 local IDs, redefining as it goes).
    private var defs: [Int: Definition] = [:]

    // Accumulated activity data.
    private var samples: [ActivityFileImporter.TrackSample] = []
    private var hrSampleCount = 0
    private var gpsPointCount = 0

    private var sessionSport: String?
    private var sessionStart: Date?
    private var sessionElapsed: Double?
    private var sessionDistance: Double?
    private var sessionCalories: Double?
    private var sessionSteps: Int?
    private var sessionAscent: Double?
    private var sessionAvgHr: Int?
    private var sessionMaxHr: Int?

    private var lapDistanceSum = 0.0
    private var lapCalorieSum = 0.0
    private var lapStepSum = 0
    private var lapAscentSum = 0.0
    private var lapMaxHr: Int?

    private var skipped = 0
    private var recordCount = 0

    init(bytes: [UInt8], end: Int) {
        self.bytes = bytes
        self.end = end
    }

    mutating func run(from start: Int) {
        var i = start
        while i < end {
            if recordCount >= FitParser.maxRecords { break }
            recordCount += 1

            let header = bytes[i]
            i += 1

            if header & 0x80 != 0 {
                // Compressed-timestamp header → always a DATA message; local type in bits 5-6.
                let localType = Int((header >> 5) & 0x03)
                guard let def = defs[localType] else { skipped += 1; i = skipBytesUnknown(i); break }
                guard i + def.totalSize <= end else { break }
                consumeData(def, at: i)
                i += def.totalSize
            } else if header & 0x40 != 0 {
                // DEFINITION message.
                let localType = Int(header & 0x0F)
                let hasDevFields = (header & 0x20) != 0
                guard let (def, next) = readDefinition(at: i, hasDevFields: hasDevFields) else { break }
                defs[localType] = def
                i = next
            } else {
                // DATA message.
                let localType = Int(header & 0x0F)
                guard let def = defs[localType] else {
                    // No definition for this local type → we can't know its length. Bail safely.
                    skipped += 1
                    break
                }
                guard i + def.totalSize <= end else { break }
                consumeData(def, at: i)
                i += def.totalSize
            }
        }
    }

    /// When we hit an undecodable compressed record with no known def, we can't advance safely.
    private func skipBytesUnknown(_ i: Int) -> Int { end }

    // MARK: - Definition parsing

    private func readDefinition(at start: Int, hasDevFields: Bool) -> (Definition, Int)? {
        // reserved(1) + architecture(1) + globalNum(2) + numFields(1) = 5 bytes minimum.
        guard start + 5 <= end else { return nil }
        var i = start
        i += 1 // reserved
        let architecture = bytes[i]; i += 1
        let bigEndian = architecture == 1
        let globalNum: Int = bigEndian ? Int(FitParser.readU16BE(bytes, i)) : Int(FitParser.readU16LE(bytes, i))
        i += 2
        let numFields = Int(bytes[i]); i += 1
        guard numFields <= FitParser.maxFieldsPerDef else { return nil }
        guard i + numFields * 3 <= end else { return nil }

        var fields: [FieldDef] = []
        fields.reserveCapacity(numFields)
        var total = 0
        for _ in 0..<numFields {
            let num = Int(bytes[i]); let size = Int(bytes[i + 1]); let baseType = bytes[i + 2]
            i += 3
            // Guard a zero/huge field size that would desync the record stream.
            guard size > 0, size <= 255 else { return nil }
            fields.append(FieldDef(num: num, size: size, baseType: baseType))
            total += size
        }

        if hasDevFields {
            // numDevFields(1) then that many × 3 descriptor bytes — we don't decode dev fields, but we
            // MUST account for their bytes in both the definition and the data record length.
            guard i < end else { return nil }
            let numDev = Int(bytes[i]); i += 1
            guard i + numDev * 3 <= end else { return nil }
            for _ in 0..<numDev {
                let size = Int(bytes[i + 1])
                i += 3
                guard size > 0, size <= 255 else { return nil }
                total += size
            }
        }

        return (Definition(globalNum: globalNum, fields: fields, bigEndian: bigEndian, totalSize: total), i)
    }

    // MARK: - Data parsing

    private mutating func consumeData(_ def: Definition, at start: Int) {
        switch def.globalNum {
        // file_id (0) is read by some parsers to gate on activity-vs-course; we don't gate (a course /
        // workout file can still carry a useful track), matching the Kotlin decoder — so it's skipped.
        case 20: consumeRecord(def, at: start)
        case 19: consumeLap(def, at: start)
        case 18: consumeSession(def, at: start)
        default: break   // file_id, device_info, event, hrv, etc. — skipped gracefully (deferred)
        }
    }

    private mutating func consumeRecord(_ def: Definition, at start: Int) {
        var offset = start
        var lat: Double?
        var lon: Double?
        var ele: Double?
        var hr: Int?
        var time: Date?

        for f in def.fields {
            switch f.num {
            case 253: // timestamp (u32 seconds since FIT epoch)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian) {
                    time = fitDate(v)
                }
            case 0:   // position_lat (sint32 semicircles)
                if let v = intField(at: offset, size: f.size, bigEndian: def.bigEndian) {
                    lat = semicircles(v)
                }
            case 1:   // position_long (sint32 semicircles)
                if let v = intField(at: offset, size: f.size, bigEndian: def.bigEndian) {
                    lon = semicircles(v)
                }
            case 2:   // altitude (u16, scale 5, offset 500 → metres = v/5 - 500)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFF {
                    ele = Double(v) / 5.0 - 500.0
                }
            case 3:   // heart_rate (u8 bpm)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian) {
                    hr = ActivityFileImporter.validHr(Double(v))
                }
            default:
                break
            }
            offset += f.size
        }

        let point = ActivityFileImporter.validCoordinate(lat: lat, lon: lon)
        if point == nil && time == nil && hr == nil {
            skipped += 1
            return
        }
        if samples.count >= ActivityFileImporter.maxPoints { return }
        if point != nil { gpsPointCount += 1 }
        if hr != nil { hrSampleCount += 1 }
        samples.append(.init(time: time, point: point, elevationM: ele, hr: hr))
    }

    /// lap (19): fold per-lap summary totals.
    private mutating func consumeLap(_ def: Definition, at start: Int) {
        var offset = start
        for f in def.fields {
            switch f.num {
            case 9:  // total_distance (u32, scale 100 → metres)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFFFFFF {
                    lapDistanceSum += Double(v) / 100.0
                }
            case 11: // total_calories (u16 kcal)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFF {
                    lapCalorieSum += Double(v)
                }
            case 10: // total_cycles; converted to steps only for foot activities in buildResult().
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian),
                   let steps = Self.validSteps(v, size: f.size) {
                    lapStepSum += steps
                }
            case 21: // total_ascent (u16 metres)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFF {
                    lapAscentSum += Double(v)
                }
            case 16: // max_heart_rate (u8 bpm)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian),
                   let hr = ActivityFileImporter.validHr(Double(v)) {
                    lapMaxHr = max(lapMaxHr ?? 0, hr)
                }
            default:
                break
            }
            offset += f.size
        }
    }

    /// session (18): the authoritative whole-activity summary; takes precedence over lap sums.
    private mutating func consumeSession(_ def: Definition, at start: Int) {
        var offset = start
        for f in def.fields {
            switch f.num {
            case 2:  // start_time (u32 FIT seconds)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian) { sessionStart = fitDate(v) }
            case 5:  // sport (enum)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian) { sessionSport = Self.sportName(v) }
            case 7:  // total_elapsed_time (u32, scale 1000 → seconds)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFFFFFF {
                    sessionElapsed = Double(v) / 1000.0
                }
            case 9:  // total_distance (u32, scale 100 → metres)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFFFFFF {
                    sessionDistance = Double(v) / 100.0
                }
            case 11: // total_calories (u16 kcal)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFF {
                    sessionCalories = Double(v)
                }
            case 10: // total_cycles; converted to steps only for foot activities in buildResult().
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian) {
                    sessionSteps = Self.validSteps(v, size: f.size)
                }
            case 22: // total_ascent (u16 metres)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian), v != 0xFFFF {
                    sessionAscent = Double(v)
                }
            case 16: // avg_heart_rate (u8 bpm)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian) {
                    sessionAvgHr = ActivityFileImporter.validHr(Double(v))
                }
            case 17: // max_heart_rate (u8 bpm)
                if let v = uintField(at: offset, size: f.size, bigEndian: def.bigEndian) {
                    sessionMaxHr = ActivityFileImporter.validHr(Double(v))
                }
            default:
                break
            }
            offset += f.size
        }
    }

    // MARK: - Field readers (bounds-checked)

    /// Read an unsigned little/big-endian integer of `size` bytes at `offset`. Returns nil out of
    /// bounds or for an unsupported size. The all-0xFF "invalid" sentinel is left to the caller.
    private func uintField(at offset: Int, size: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset + size <= end, size >= 1, size <= 8 else { return nil }
        var v: UInt64 = 0
        if bigEndian {
            for k in 0..<size { v = (v << 8) | UInt64(bytes[offset + k]) }
        } else {
            for k in 0..<size { v |= UInt64(bytes[offset + k]) << (8 * k) }
        }
        return v
    }

    /// Read a signed integer of `size` bytes (sign-extended). Returns nil out of bounds. The all-0xFF /
    /// 0x7FFFFFFF "invalid" sentinels are rejected for the typed lat/long callers via the range check
    /// in `semicircles`/`validCoordinate`.
    private func intField(at offset: Int, size: Int, bigEndian: Bool) -> Int64? {
        guard let u = uintField(at: offset, size: size, bigEndian: bigEndian) else { return nil }
        let bits = size * 8
        if bits >= 64 { return Int64(bitPattern: u) }
        let signBit: UInt64 = 1 << (bits - 1)
        if u & signBit != 0 {
            // Negative: sign-extend.
            let mask: UInt64 = (1 << bits) - 1
            return Int64(bitPattern: u | ~mask)
        }
        return Int64(u)
    }

    private func semicircles(_ v: Int64) -> Double? {
        // The FIT "invalid" sentinel for sint32 is 0x7FFFFFFF; reject it.
        if v == 0x7FFF_FFFF { return nil }
        let deg = Double(v) * FitParser.semicircleToDegrees
        return deg.isFinite ? deg : nil
    }

    private func fitDate(_ v: UInt64) -> Date? {
        // 0xFFFFFFFF is the invalid timestamp sentinel.
        if v == 0xFFFF_FFFF { return nil }
        let unix = Double(v) + FitParser.fitEpochOffset
        // Sanity window: 1990-01-01 .. 2100-01-01. Anything outside is garbage.
        guard unix > FitParser.fitEpochOffset, unix < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: unix)
    }

    /// Map the FIT `sport` enum to a readable label (the common subset). Unknown → nil (neutral).
    static func sportName(_ v: UInt64) -> String? {
        switch v {
        case 0: return "Generic"
        case 1: return "Running"
        case 2: return "Cycling"
        case 5: return "Swimming"
        case 11: return "Walking"
        case 13: return "Strength Training"
        case 14: return "Cardio"
        case 15: return "Hiking"
        case 17: return "Hiking"
        case 4: return "Fitness Equipment"
        case 10: return "Training"
        default: return nil
        }
    }

    static func validSteps(_ v: UInt64, size: Int) -> Int? {
        let invalid = size >= 8 ? UInt64.max : ((UInt64(1) << UInt64(size * 8)) - 1)
        guard v != invalid, v > 0, v <= 1_000_000 else { return nil }
        return Int(v)
    }

    static func isFootSport(_ sport: String?) -> Bool {
        switch sport?.lowercased() {
        case "running", "walking", "hiking": return true
        default: return false
        }
    }

    // MARK: - Build

    func buildResult() -> ActivityFileImportResult {
        guard !samples.isEmpty || sessionStart != nil else {
            return ActivityFileImportResult(activity: nil, kind: .fit, skipped: skipped)
        }

        let route = samples.compactMap { sample -> RoutePoint? in
            guard let point = sample.point else { return nil }
            return RoutePoint(lat: point.lat, lon: point.lon, time: sample.time)
        }
        let times = samples.compactMap { $0.time }

        // Prefer the session summary; fall back to lap sums, then the sampled track.
        let distance = sessionDistance
            ?? (lapDistanceSum > 0 ? lapDistanceSum : (route.count >= 2 ? ActivityFileImporter.routeDistanceM(route) : nil))
        let calories = sessionCalories ?? (lapCalorieSum > 0 ? lapCalorieSum : nil)
        // FIT field 10 is total_cycles — for foot sports that's STRIDES (one stride = two steps), so
        // double it to the real step count. The "converted to steps" note above was never applied, so a
        // walk logged as 1150 strides read as 1150 steps instead of 2300 (#568).
        let steps = Self.isFootSport(sessionSport)
            ? (sessionSteps ?? (lapStepSum > 0 ? lapStepSum : nil)).map { $0 * 2 }
            : nil
        let ascent = sessionAscent
            ?? (lapAscentSum > 0 ? lapAscentSum : ActivityFileImporter.ascentM(from: samples))

        let sampledHrs = samples.compactMap { $0.hr }
        let avgHr = sessionAvgHr
            ?? (sampledHrs.isEmpty ? nil : Int((Double(sampledHrs.reduce(0, +)) / Double(sampledHrs.count)).rounded()))
        let maxHr = sessionMaxHr ?? lapMaxHr ?? sampledHrs.max()

        // Time window: the session start + elapsed when present, else the sampled span.
        let start = times.min() ?? sessionStart ?? Date(timeIntervalSince1970: 0)
        let computedEnd = times.max() ?? start
        let end: Date
        if let s = sessionStart, let el = sessionElapsed, el > 0 {
            end = max(s.addingTimeInterval(el), computedEnd)
        } else {
            end = computedEnd
        }

        let activity = ActivityFile(
            kind: .fit,
            start: min(start, sessionStart ?? start),
            end: max(end, start),
            sport: sessionSport,
            distanceM: distance,
            energyKcal: calories,
            steps: steps,
            avgHr: avgHr,
            maxHr: maxHr,
            ascentM: ascent,
            gpsPointCount: gpsPointCount,
            hrSampleCount: hrSampleCount,
            route: ActivityFileImporter.cappedRoute(route),
            // #137: the real per-record HR series, via the SHARED extractor so FIT persists a
            // byte-identical HR stream to the GPX/TCX paths (and the Kotlin twin).
            hrSamples: ActivityFileImporter.hrSamples(from: samples)
        )
        return ActivityFileImportResult(activity: activity, kind: .fit, skipped: skipped)
    }
}
