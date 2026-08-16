import Foundation

// MARK: - Polar Measurement Data (PMD) decode — clean-room, pure, no CoreBluetooth
//
// Polar's PMD service is proprietary but PUBLICLY DOCUMENTED (Polar's official BLE SDK). This is NOOP's
// own clean parser of the documented byte layout — no Polar code, no firmware, nothing fabricated.
//
// PMD data notifications (on the PMD Data characteristic FB005C82-…) share a 10-byte header:
//
//   byte  0      measurement type   (0x00 ECG, 0x01 PPG, 0x02 ACC, 0x03 PPI, 0x05 GYRO, 0x06 MAG, …)
//   bytes 1…8    timestamp          (uint64 LE, nanoseconds since 2000-01-01 UTC — the PMD epoch, NOT
//                                    Unix; of the LAST sample in the frame)
//   byte  9      frame type         (bit 7 = compressed/delta flag; bits 0…6 = data-format id)
//   bytes 10…    sample data        (format depends on measurement type + frame type)
//
// This package decodes the **PPI** stream (measurement 0x03), which is the one NOOP actually needs: it
// yields heart rate AND the peak-to-peak (inter-beat) interval per beat — the same signal WHOOP R-R gives
// — so NOOP can compute HRV from a Polar H10 / OH1 / Verity Sense without running peak detection on raw
// ECG. The header parser is exposed too, so a future live source can route other measurement types.
//
// PPI is never compressed: each sample is a fixed 6-byte record (documented `PpiData` layout):
//
//   byte 0      heart rate          (uint8, bpm; 0 when the sensor has no valid beat — kept, never faked)
//   bytes 1…2   ppi                 (uint16 LE, ms — the peak-to-peak / inter-beat interval)
//   bytes 3…4   error estimate      (uint16 LE, ms)
//   byte 5      flags               (bit0 blocker, bit1 skinContact, bit2 skinContactSupported)

/// A PMD measurement type (the subset NOOP recognises). An unrecognised type decodes to `nil` rather than
/// a wrong guess, matching the conservative stance of the other clean-room decoders.
public enum PolarPmdMeasurement: UInt8, Sendable, Equatable, CaseIterable {
    case ecg = 0x00
    case ppg = 0x01
    case acc = 0x02
    case ppi = 0x03
    case gyro = 0x05
    case magnetometer = 0x06

    /// Short lower-case token for diagnostics / the debug strap log (e.g. "ecg", "ppi"). Engineer-facing,
    /// not localised.
    public var label: String {
        switch self {
        case .ecg:          return "ecg"
        case .ppg:          return "ppg"
        case .acc:          return "acc"
        case .ppi:          return "ppi"
        case .gyro:         return "gyro"
        case .magnetometer: return "mag"
        }
    }
}

/// The parsed 10-byte PMD data-frame header, common to every measurement type.
public struct PolarPmdFrameHeader: Equatable, Sendable {
    /// The measurement stream this frame belongs to.
    public let measurement: PolarPmdMeasurement
    /// Frame timestamp in nanoseconds since **2000-01-01 UTC** — the PMD epoch, NOT the Unix epoch (a raw
    /// read is ~30 years behind wall clock). Applies to the LAST sample in the frame. Use `unixTimestampNs`
    /// for wall clock. Only load-bearing for the fixed-rate streams (ECG/ACC/PPG) when those land — for PPI,
    /// samples are event-based and callers timestamp on arrival.
    public let timestampNs: UInt64
    /// The data-format id (frame type bits 0…6).
    public let frameType: UInt8
    /// True when the compressed/delta bit (0x80) is set on the frame-type byte.
    public let isCompressed: Bool

    /// Nanoseconds between the Unix epoch (1970-01-01) and the PMD epoch (2000-01-01): 946 684 800 s. Add
    /// to a PMD `timestampNs` to re-base it onto the Unix epoch.
    public static let pmdEpochUnixOffsetNs: UInt64 = 946_684_800_000_000_000

    /// `timestampNs` re-based to the Unix epoch (ns since 1970-01-01 UTC), for wall-clock use.
    public var unixTimestampNs: UInt64 { timestampNs &+ Self.pmdEpochUnixOffsetNs }

    public init(measurement: PolarPmdMeasurement, timestampNs: UInt64, frameType: UInt8, isCompressed: Bool) {
        self.measurement = measurement
        self.timestampNs = timestampNs
        self.frameType = frameType
        self.isCompressed = isCompressed
    }
}

/// One decoded PPI (peak-to-peak interval) sample.
public struct PolarPpiSample: Equatable, Sendable {
    /// Heart rate in bpm as the sensor reported it. `0` means "no valid beat right now" — surfaced as-is
    /// (honest-data invariant: never substituted with a fabricated value).
    public let heartRate: Int
    /// The peak-to-peak / inter-beat interval in milliseconds — NOOP's HRV input (≈ an R-R interval).
    public let ppiMs: Int
    /// The sensor's own error estimate for this interval, in milliseconds.
    public let errorEstimateMs: Int
    /// Blocker bit (flags bit0): the sensor flagged this interval as unreliable (movement / poor contact).
    /// A consumer should drop such intervals from HRV rather than trust them. This bit's meaning is
    /// unambiguous across sources.
    public let blocker: Bool
    /// Raw flags bit1. Named per the Polar SDK's `skinContactStatus` (set = contact). NOTE: NOOP's
    /// `DEVICE_SUPPORT_ROADMAP.md` §PMD phrases bit1 as "poor/no skin contact" (the opposite polarity), so
    /// the real-world meaning is UNCONFIRMED on hardware — do not gate anything on it until verified.
    public let skinContact: Bool
    /// Raw flags bit2. Named per the Polar SDK's `skinContactSupported` (set = supported); the roadmap
    /// phrases it as "contact unsupported" (opposite). Same on-hardware confirmation caveat as `skinContact`.
    public let skinContactSupported: Bool

    public init(heartRate: Int, ppiMs: Int, errorEstimateMs: Int,
                blocker: Bool, skinContact: Bool, skinContactSupported: Bool) {
        self.heartRate = heartRate
        self.ppiMs = ppiMs
        self.errorEstimateMs = errorEstimateMs
        self.blocker = blocker
        self.skinContact = skinContact
        self.skinContactSupported = skinContactSupported
    }
}

public enum PolarPmdDecoder {

    /// The fixed PMD data-frame header length (type + 8-byte timestamp + frame-type byte).
    public static let headerLength = 10
    /// The byte length of one PPI sample record.
    static let ppiSampleLength = 6

    /// Parse the 10-byte PMD data-frame header. Returns `nil` if the frame is shorter than the header or
    /// carries a measurement type NOOP doesn't recognise (no wrong guess).
    public static func header(_ data: [UInt8]) -> PolarPmdFrameHeader? {
        // The measurement type is the low 6 bits of byte 0 (top 2 are reserved) — mask before matching so a
        // frame with reserved bits set still resolves (DEVICE_SUPPORT_ROADMAP.md §PMD: "mask 0x3F").
        guard data.count >= headerLength,
              let measurement = PolarPmdMeasurement(rawValue: data[0] & 0x3F) else { return nil }
        let timestamp = uint64LE(data, at: 1)
        let frameByte = data[9]
        return PolarPmdFrameHeader(
            measurement: measurement,
            timestampNs: timestamp,
            frameType: frameByte & 0x7F,
            isCompressed: (frameByte & 0x80) != 0)
    }

    /// Decode a PPI (measurement 0x03) data frame into its samples. Returns `nil` when the frame isn't a
    /// valid PPI frame (too short, unknown type, or not `.ppi`); returns an empty array for a well-formed
    /// PPI header carrying no complete sample. A trailing partial record (fewer than 6 bytes) is ignored.
    public static func decodePPI(_ data: [UInt8]) -> [PolarPpiSample]? {
        guard let header = header(data), header.measurement == .ppi else { return nil }
        var samples: [PolarPpiSample] = []
        var i = headerLength
        while i + ppiSampleLength <= data.count {
            let flags = data[i + 5]
            samples.append(PolarPpiSample(
                heartRate: Int(data[i]),
                ppiMs: Int(uint16LE(data, at: i + 1)),
                errorEstimateMs: Int(uint16LE(data, at: i + 3)),
                blocker: (flags & 0x01) != 0,
                skinContact: (flags & 0x02) != 0,
                skinContactSupported: (flags & 0x04) != 0))
            i += ppiSampleLength
        }
        return samples
    }

    // MARK: - Little-endian readers (bounds are pre-checked by callers)

    private static func uint16LE(_ data: [UInt8], at i: Int) -> UInt16 {
        UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func uint64LE(_ data: [UInt8], at i: Int) -> UInt64 {
        var v: UInt64 = 0
        for b in 0..<8 { v |= UInt64(data[i + b]) << (8 * b) }
        return v
    }
}
