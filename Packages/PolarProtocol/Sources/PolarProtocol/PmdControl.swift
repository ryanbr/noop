import Foundation

// MARK: - Polar Measurement Data (PMD) CONTROL POINT — clean-room command builder + response parse
//
// Companion to `PmdDecoder` (the DATA side). The PMD Control Point characteristic
// (FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8, write + indicate) is how a client STARTS / STOPS a
// measurement stream and reads its supported settings, BEFORE the data notifications arrive on the
// Data characteristic (FB005C82-…). Byte layout per docs/DEVICE_SUPPORT_ROADMAP.md §PMD — sourced
// from the official `polarofficial/polar-ble-sdk` (cross-verified). This is NOOP's own byte builder,
// not Polar code.
//
// SCOPE: the pure command/response layer only. The CoreBluetooth / android.bluetooth wiring — discover
// the PMD service, write these bytes to the control point, subscribe to the data characteristic, and
// feed the notifications to `PmdDecoder` — is the hardware-gated `PolarPMDSource` still to build. Keeping
// the byte work here (pure, unit-tested, no BLE) mirrors `PmdDecoder`: the source becomes a thin wrapper.
//
// HARDWARE-GATED: the control-point RESPONSE layout (the `0xF0` indicate reply) is per the SDK but not
// yet confirmed against a real device in this repo — no consumer should treat a parsed `Response` as
// authoritative until an H10 / Verity Sense settles it, exactly as the roadmap flags the PPI flag polarity.

public enum PolarPmdControl {

    /// Control-point opcodes — the FIRST byte of a control-point WRITE (§PMD).
    public enum Opcode: UInt8, Sendable, Equatable {
        case getMeasurementSettings = 0x01
        case requestMeasurementStart = 0x02
        case stopMeasurement = 0x03
    }

    /// A measurement SETTING type inside a start request (`[type, count, u16 LE × count]` blocks, §PMD).
    /// `sampleRate`/`resolution`/`range` are the three NOOP would ever set; the SDK defines more, added
    /// only if a future stream needs them.
    public enum SettingType: UInt8, Sendable, Equatable {
        case sampleRate = 0x00
        case resolution = 0x01
        case range = 0x02
    }

    /// One setting block: a type plus its u16 values (little-endian on the wire).
    public struct Setting: Equatable, Sendable {
        public let type: SettingType
        public let values: [UInt16]
        public init(_ type: SettingType, _ values: [UInt16]) {
            self.type = type
            self.values = values
        }
    }

    /// GET_MEASUREMENT_SETTINGS — ask the sensor which settings a measurement supports: `[0x01, measType]`.
    /// The reply (an indicate on the control point) carries the supported setting blocks; parsing those
    /// param blocks is deferred until `PolarPMDSource` needs to negotiate a rate.
    public static func getSettings(_ measurement: PolarPmdMeasurement) -> [UInt8] {
        [Opcode.getMeasurementSettings.rawValue, measurement.rawValue]
    }

    /// REQUEST_MEASUREMENT_START — begin a stream: `[0x02, (recording << 7) | measType, settingBlocks…]`.
    /// `recording == false` (online streaming — what NOOP uses) leaves bit 7 clear, so the second byte is
    /// just the measurement type. Each setting serialises as `[type, count, lo, hi, …]` with u16 LE values.
    public static func start(_ measurement: PolarPmdMeasurement,
                             recording: Bool = false,
                             settings: [Setting] = []) -> [UInt8] {
        var out: [UInt8] = [
            Opcode.requestMeasurementStart.rawValue,
            (recording ? 0x80 : 0x00) | (measurement.rawValue & 0x7F),
        ]
        for s in settings {
            out.append(s.type.rawValue)
            out.append(UInt8(truncatingIfNeeded: s.values.count))
            for v in s.values {
                out.append(UInt8(v & 0x00FF))
                out.append(UInt8(v >> 8))
            }
        }
        return out
    }

    /// STOP_MEASUREMENT — end a stream: `[0x03, measType]`.
    public static func stop(_ measurement: PolarPmdMeasurement) -> [UInt8] {
        [Opcode.stopMeasurement.rawValue, measurement.rawValue]
    }

    /// The control-point indicate reply, prefixed by `responseMarker`: `[0xF0, reqOpcode, measType,
    /// status, …]`. `status == 0` is success; the rest (a "more" flag + GET_SETTINGS param blocks) is
    /// not parsed here. `measurement` is nil when the reply names a type NOOP doesn't recognise.
    public struct Response: Equatable, Sendable {
        public let requestOpcode: UInt8
        public let measurement: PolarPmdMeasurement?
        public let status: UInt8
        public var isSuccess: Bool { status == 0x00 }
        public init(requestOpcode: UInt8, measurement: PolarPmdMeasurement?, status: UInt8) {
            self.requestOpcode = requestOpcode
            self.measurement = measurement
            self.status = status
        }
    }

    /// The byte the PMD control point prefixes every indicate reply with (§PMD, SDK response frame).
    public static let responseMarker: UInt8 = 0xF0

    /// Parse a control-point indicate reply `[0xF0, reqOpcode, measType, status, …]`, or nil when the
    /// frame is too short or isn't a control-point response. Conservative, matching `PmdDecoder`'s stance.
    public static func parseResponse(_ data: [UInt8]) -> Response? {
        guard data.count >= 4, data[0] == responseMarker else { return nil }
        return Response(requestOpcode: data[1],
                        measurement: PolarPmdMeasurement(rawValue: data[2] & 0x3F),
                        status: data[3])
    }
}
