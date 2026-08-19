import CoreBluetooth
import WhoopProtocol

/// Which strap the user is pairing. The user pick remains the preferred scan target so we look for
/// exactly one device family instead of guessing — a WHOOP 4.0 scan finds a WHOOP 4 fast — but a scan
/// that finds nothing rotates to the other family (`fallbackScanModel`) in case the persisted
/// preference went stale after an update or restore.
public enum WhoopModel: String, CaseIterable, Identifiable, Hashable {
    case whoop4   = "WHOOP 4.0"
    case whoop5mg = "WHOOP 5.0 / MG"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// The OTHER WHOOP family to try when a service-filtered scan for this model finds nothing. A
    /// stale/missing persisted preference (after an update or a state restore) can point the scan at
    /// the wrong service, so it runs forever with the strap sitting right there; rotating to the other
    /// family — and persisting whichever one actually advertises — recovers reconnect automatically.
    var fallbackScanModel: WhoopModel {
        switch self {
        case .whoop4:   return .whoop5mg
        case .whoop5mg: return .whoop4
        }
    }

    /// The protocol-layer device family this model maps to — drives framing (CRC8 vs CRC16),
    /// characteristic UUIDs, and the CLIENT_HELLO handshake.
    public var deviceFamily: DeviceFamily {
        switch self {
        case .whoop4:   return .whoop4
        case .whoop5mg: return .whoop5
        }
    }

    /// The model the user last chose, read from the same key the pickers write
    /// (`@AppStorage("selectedWhoopModel")`). Used as the default for scans the user
    /// didn't directly trigger — BLE state restoration, power-on reconnect — so those
    /// look for the right strap after a relaunch instead of falling back to WHOOP 4.0.
    public static var persisted: WhoopModel {
        UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:)) ?? .whoop4
    }

    /// The BLE service to scan for, and to discover after connecting, for this model.
    /// These mirror `BLEManager.customService` / `BLEManager.whoop5Service` (kept inline
    /// here so the enum stays nonisolated — `BLEManager` is `@MainActor`). CBUUID compares
    /// by value, so these match the manager's constants in every `switch`/scan filter.
    public var scanService: CBUUID {
        switch self {
        case .whoop4:   return CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        case .whoop5mg: return CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
        }
    }

    /// The UUIDs that may appear in a strap's ADVERTISEMENT, which is not the same set as `scanService`.
    ///
    /// A 128-bit UUID often does not fit the 31-byte advertising payload, so a peripheral may advertise
    /// the 16-bit SIG member form instead and CoreBluetooth surfaces that as its Bluetooth-base expansion
    /// (`0000FD4B-…`) — which does NOT equal the vendor UUID `fd4b0001-…`. A scan filtered only on the
    /// vendor UUID would then never see the strap, and it would read to the owner as "NOOP cannot find my
    /// 5.0" rather than as a discovery bug.
    ///
    /// Advertisement-only, deliberately: after connecting, the strap exposes the real 128-bit service in
    /// GATT, so `retrieveConnectedPeripherals` and `discoverServices` must keep using `scanService` alone.
    /// Widening those would be wrong, not merely redundant.
    ///
    /// UNCONFIRMED against hardware. The 16-bit `0xFD4B` possibility is a fact re-derived from
    /// OpenStrap/edge#255 (Dart; no code taken), which ships the same widening while its own test plan
    /// still asks for the nRF Connect capture that would settle it. NOOP straps do pair today, so the
    /// vendor UUID demonstrably works at least often — this only removes a way for discovery to fail
    /// silently, and the discovery log records which form actually matched so the first 5/MG capture
    /// answers the question for both projects.
    public var advertisedScanServices: [CBUUID] {
        switch self {
        case .whoop4:   return [scanService]
        case .whoop5mg: return [scanService, CBUUID(string: "FD4B")]
        }
    }
}
