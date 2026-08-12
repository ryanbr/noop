import Foundation

/// Which Whoop hardware generation a connection / capture belongs to.
///
/// This package is platform-pure: it never imports CoreBluetooth. The app layer is responsible
/// for turning the UUID *strings* exposed here into `CBUUID` values. Keeping CBUUID out of this
/// module lets the protocol code run on any platform (and in CLI tools / tests) unchanged.
public enum DeviceFamily: String, Sendable, CaseIterable {
    /// Whoop 4.0 — 0x07 CRC8 header check.
    case whoop4
    /// Whoop 5.0 / MG — CRC16-Modbus header check, "puffin" packet types.
    case whoop5
}

/// Which checksum guards the frame header for a given device family.
public enum HeaderCRCKind: String, Sendable, CaseIterable {
    /// CRC8 (poly 0x07) over the two declared-length bytes — Whoop 4.0.
    case crc8
    /// CRC16-Modbus (poly 0xA001, init 0xFFFF, reflected) over the header prefix — Whoop 5.0.
    case crc16Modbus
}

/// WHOOP custom GATT service families visible in advertisements.
///
/// Only `.whoop4` and `.maverickGooseFD4B` are connectable in NOOP today. The other services are
/// protocol facts from reverse engineering and are diagnostic-only until their connection framing is
/// mapped and hardware-tested. `.puffin1150` is intentionally qualified because NOOP already uses
/// "puffin" for the fd4b/Maverick-Goose packet framing.
public enum WhoopGattServiceFamily: String, Sendable, CaseIterable {
    case whoop4
    case maverickGooseFD4B
    case puffin1150
    case monument
    case symphony

    public var displayName: String {
        switch self {
        case .whoop4: return "WHOOP 4.0"
        case .maverickGooseFD4B: return "WHOOP 5.0 / MG fd4b (Maverick/Goose)"
        case .puffin1150: return "WHOOP PUFFIN service 1150"
        case .monument: return "WHOOP MONUMENT"
        case .symphony: return "WHOOP SYMPHONY"
        }
    }

    public var serviceUUIDString: String {
        switch self {
        case .whoop4: return "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .maverickGooseFD4B: return "fd4b0001-cce1-4033-93ce-002d5875f58a"
        case .puffin1150: return "11500001-6215-11ee-8c99-0242ac120002"
        case .monument: return "8a580001-2fe8-4796-9267-b87a2b0c8234"
        case .symphony: return "59830001-5955-419b-bb8d-c8262926af23"
        }
    }

    public var characteristicUUIDStrings: [String] {
        switch self {
        case .whoop4: return DeviceFamily.whoop4.characteristicUUIDStrings
        case .maverickGooseFD4B: return DeviceFamily.whoop5.characteristicUUIDStrings
        case .puffin1150:
            return Self.unsupportedCharacteristicUUIDStrings(
                prefix: "1150", suffix: "6215-11ee-8c99-0242ac120002")
        case .monument:
            return Self.unsupportedCharacteristicUUIDStrings(
                prefix: "8a58", suffix: "2fe8-4796-9267-b87a2b0c8234")
        case .symphony:
            return Self.unsupportedCharacteristicUUIDStrings(
                prefix: "5983", suffix: "5955-419b-bb8d-c8262926af23")
        }
    }

    public var connectableDeviceFamily: DeviceFamily? {
        switch self {
        case .whoop4: return .whoop4
        case .maverickGooseFD4B: return .whoop5
        case .puffin1150, .monument, .symphony: return nil
        }
    }

    public var isConnectable: Bool { connectableDeviceFamily != nil }

    public var diagnosticUnsupportedMessage: String {
        "\(displayName) detected but unsupported; NOOP will not connect or send commands."
    }

    public static var unsupportedFamilies: [WhoopGattServiceFamily] {
        allCases.filter { !$0.isConnectable }
    }

    public static var unsupportedServiceUUIDStrings: [String] {
        unsupportedFamilies.map(\.serviceUUIDString)
    }

    public static func forServiceUUIDString(_ uuid: String?) -> WhoopGattServiceFamily? {
        guard let normalized = uuid?.lowercased() else { return nil }
        return allCases.first { $0.serviceUUIDString == normalized }
    }

    public static func firstUnsupported(in serviceUUIDStrings: [String]) -> WhoopGattServiceFamily? {
        serviceUUIDStrings.compactMap { forServiceUUIDString($0) }.first { !$0.isConnectable }
    }

    private static func unsupportedCharacteristicUUIDStrings(prefix: String, suffix: String) -> [String] {
        ["0002", "0003", "0004", "0005", "0007"].map { "\(prefix)\($0)-\(suffix)" }
    }
}

public struct WhoopGattScanDecision: Equatable, Sendable {
    public var shouldConnect: Bool
    public var unsupportedFamily: WhoopGattServiceFamily?

    public init(shouldConnect: Bool, unsupportedFamily: WhoopGattServiceFamily? = nil) {
        self.shouldConnect = shouldConnect
        self.unsupportedFamily = unsupportedFamily
    }
}

/// Decide whether an advertisement found by the broadened diagnostic scan should enter GATT.
///
/// Empty service lists preserve the pre-diagnostic behaviour because some platform callbacks omit the
/// advertised service UUIDs even though the service-filtered scan matched. When services are present,
/// only the selected connectable service may connect; unsupported families are reported for logging.
public func whoopGattScanDecision(
    selectedServiceUUIDString: String,
    advertisedServiceUUIDStrings: [String]
) -> WhoopGattScanDecision {
    let advertised = Set(advertisedServiceUUIDStrings.map { $0.lowercased() })
    if advertised.isEmpty || advertised.contains(selectedServiceUUIDString.lowercased()) {
        return WhoopGattScanDecision(shouldConnect: true)
    }
    return WhoopGattScanDecision(
        shouldConnect: false,
        unsupportedFamily: WhoopGattServiceFamily.firstUnsupported(in: Array(advertised))
    )
}

public extension DeviceFamily {
    /// Resolve a device-registry `model` label to the strap family that wrote its rows (#171).
    ///
    /// The registry holds several historical spellings for the same hardware: the Add-Device wizard
    /// stores bare "4.0" / "5.0 MG", other paths match the full picker labels ("WHOOP 4.0" /
    /// "WHOOP 5.0 / MG"), and the legacy seeded "my-whoop" row stores just "WHOOP". Matching any
    /// single spelling silently misses the others (#171), so this is the ONE place allowed to
    /// interpret registry model labels.
    ///
    /// "WHOOP" predates the wizard and was written identically for 4.0 and 5/MG installs, so it
    /// carries no family information; it keeps the prior `.whoop5` fallback, as do nil/unknown
    /// labels (non-WHOOP imports whose skin temp is already °C) — only a positively-identified 4.0
    /// changes scale (#938). Mirrors the Kotlin `DeviceFamily.forRegistryModel`.
    static func forRegistryModel(_ model: String?) -> DeviceFamily {
        switch model {
        case "4.0", "WHOOP 4.0": return .whoop4
        default: return .whoop5
        }
    }

    /// Brand-aware family resolution (#1086). Returns `nil` for a positively non-WHOOP brand (e.g.
    /// "Oura", "Apple") — `DeviceFamily` has only `.whoop4`/`.whoop5`, so it cannot represent "not a
    /// WHOOP", and letting such a device fall through to `.whoop5` is exactly the #171 mistake (a family
    /// question answered by a fall-through rather than by evidence). The row already carries the answer:
    /// `PairedDevice.brand` is set from `DeviceBrandCatalog`.
    ///
    /// A nil/empty brand or the legacy "WHOOP" label (written identically for 4.0 and 5/MG) carries no
    /// non-WHOOP signal, so it defers to `forRegistryModel`. Callers that need a concrete family for a
    /// non-WHOOP device (e.g. the skin-temp raw→°C scale, where a non-WHOOP reading shares the non-4.0
    /// branch) coalesce the nil to `.whoop5`, matching the prior behaviour exactly. Mirrors the Kotlin
    /// `DeviceFamily.forRegistryDevice`.
    static func forRegistryDevice(model: String?, brand: String?) -> DeviceFamily? {
        if let brand, !brand.isEmpty, brand.caseInsensitiveCompare("WHOOP") != .orderedSame {
            return nil
        }
        return forRegistryModel(model)
    }

    /// Is this registry row positively a 5.0/MG-family WHOOP? For callers asking a YES/NO *identity*
    /// question rather than needing a concrete family to compute with.
    ///
    /// The distinction matters because the two kinds of caller must treat `forRegistryDevice`'s `nil`
    /// oppositely, and only one of them may coalesce it:
    ///
    ///   - **Needs a concrete family** (the skin-temp raw→°C scale): a non-WHOOP reading genuinely shares
    ///     the non-4.0 branch, so `?? .whoop5` picks the right arithmetic and preserves prior behaviour.
    ///   - **Asks "is it a 5/MG?"** (this): `?? .whoop5` answers **yes** for an Oura ring, which is the
    ///     #171 fall-through mistake wearing #1086's clothes — the brand said "not a WHOOP" and the
    ///     coalesce threw that evidence away.
    ///
    /// Exists so the second kind cannot be written as `forRegistryDevice(…) ?? .whoop5 == .whoop5`, which
    /// reads plausible and is wrong. Mirrors the Kotlin `DeviceFamily.isWhoop5Registry`.
    static func isWhoop5Registry(model: String?, brand: String?) -> Bool {
        forRegistryDevice(model: model, brand: brand) == .whoop5
    }

    /// The header-CRC algorithm this family uses. This is the single switch that the family-aware
    /// `verifyFrame`/`parseFrame` overloads branch on; the payload CRC32 is identical for both.
    var headerCRCKind: HeaderCRCKind {
        switch self {
        case .whoop4: return .crc8
        case .whoop5: return .crc16Modbus
        }
    }

    /// Primary GATT service UUID *string* for this family (lowercase, as advertised).
    /// The app layer wraps this in `CBUUID(string:)`.
    var serviceUUIDString: String {
        switch self {
        case .whoop4: return "61080001-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0001-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Characteristic UUID *strings* this family uses, in stable ascending order.
    ///
    /// Whoop 4.0 exposes 0002…0005 under the 6108 service. Whoop 5.0 adds an extra 0007
    /// characteristic under the fd4b service. These are plain strings (no CBUUID) on purpose.
    var characteristicUUIDStrings: [String] {
        switch self {
        case .whoop4:
            return [
                "61080002-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080003-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080004-8d6d-82b8-614a-1c8cb0f8dcc6",
                "61080005-8d6d-82b8-614a-1c8cb0f8dcc6",
            ]
        case .whoop5:
            return [
                "fd4b0002-cce1-4033-93ce-002d5875f58a",
                "fd4b0003-cce1-4033-93ce-002d5875f58a",
                "fd4b0004-cce1-4033-93ce-002d5875f58a",
                "fd4b0005-cce1-4033-93ce-002d5875f58a",
                "fd4b0007-cce1-4033-93ce-002d5875f58a",
            ]
        }
    }

    /// The command/write characteristic UUID *string* for this family (the …0002 endpoint that
    /// CLIENT_HELLO and command frames are written to).
    var commandCharacteristicUUIDString: String {
        switch self {
        case .whoop4: return "61080002-8d6d-82b8-614a-1c8cb0f8dcc6"
        case .whoop5: return "fd4b0002-cce1-4033-93ce-002d5875f58a"
        }
    }

    /// Static CLIENT_HELLO frame this family writes immediately after GATT discovery to start a
    /// session. `nil` for families that do not use a fixed hello.
    ///
    /// The Whoop 5.0 hello is a fully-formed type-35 (COMMAND) frame with CRC16-Modbus header and
    /// CRC32 payload trailer. Transcribed verbatim from the Goose reverse-engineering
    /// (`GooseHello.clientHelloFrameHex` = "aa0108000001e67123019101363e5c8d").
    var clientHello: [UInt8]? {
        switch self {
        case .whoop4:
            return nil
        case .whoop5:
            return DeviceFamily.whoop5ClientHello
        }
    }

    /// Whoop 5.0 CLIENT_HELLO bytes (16 bytes). Exposed as a named constant for test/debug use.
    static let whoop5ClientHello: [UInt8] = [
        0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71,
        0x23, 0x01, 0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
    ]
}

// MARK: - Puffin packet type names

/// Whoop 5.0 introduces "puffin" packet types that mirror existing 4.0 types but on the new
/// transport. These map onto the canonical base type names so they decode like their 4.0
/// counterparts instead of falling through to an "unknown"/"typeN" label.
public enum PuffinPacketType {
    /// Puffin command response — behaves like COMMAND_RESPONSE (type 36).
    public static let puffinCommandResponse: Int = 38
    /// Puffin metadata — behaves like METADATA (type 49).
    public static let puffinMetadata: Int = 56
}

/// Canonical type name for a packet type byte, aliasing the Whoop 5.0 "puffin" types onto the
/// base names they share decoding semantics with:
/// - 38 (PUFFIN_COMMAND_RESPONSE) → "COMMAND_RESPONSE"
/// - 56 (PUFFIN_METADATA)         → "METADATA"
///
/// For every other type this defers to the schema's own `typeName`, so existing behaviour is
/// unchanged. This guarantees the puffin types never decode as "unknown" even if the schema's
/// PacketType enum lacks them.
public func canonicalTypeName(_ t: Int, schema: Schema) -> String {
    switch t {
    case PuffinPacketType.puffinCommandResponse: return "COMMAND_RESPONSE"
    case PuffinPacketType.puffinMetadata: return "METADATA"
    default: return schema.typeName(t)
    }
}
