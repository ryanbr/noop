import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// EXPERIMENTAL, ISOLATED live-BLE source for the Huami family — Amazfit / Zepp (incl. the Helio
/// ring/band) and Xiaomi Mi Band.
///
/// "EXPERIMENTAL, HELP US TEST": this is a best-effort, clean-room driver built from PUBLICLY DOCUMENTED
/// protocol FACTS (open projects document the Huami GATT layout; we reuse only the facts and wrote our own
/// code — no GPL/AGPL code copied). It is shipped behind the experimental add-device tier because it can't
/// be hardware-verified here. It NEVER fabricates data: if it can't read a real HR it stays at "—".
///
/// WHOOP-FIRST ISOLATION (identical to `StandardHRSource`): this class runs its OWN `CBCentralManager`
/// and never imports, calls, or shares state with `BLEManager`. The WHOOP path cannot regress. The only
/// shared surfaces are `LiveState` and the injected closures (`persist`, `log`, `onBattery`).
///
/// HR strategy, honest about each step:
///   1. Prefer the STANDARD SIG Heart Rate Service (0x180D / 0x2A37) when the device exposes it — newer
///      Amazfit/Zepp bands do, and that path is identical to `StandardHRSource`. (Decoded via
///      `StandardHeartRate`.)
///   2. Else fall back to the documented Huami custom HR-measurement characteristic
///      (`00002a37-0000-3512-2118-0009af100700` on the Huami service `0000fee0-…`). Many bands expose live
///      HR here with NO auth handshake. (Decoded via `HuamiHeartRate`.)
///   3. If NEITHER is readable (the band needs the Huami auth pairing we don't implement), surface an
///      HONEST message via `needsPairing` and stay disconnected from data — we never fake a reading.
@MainActor
public final class HuamiHRSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// A Huami-family device seen during a scan.
    public struct DiscoveredDevice: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    @Published public private(set) var discovered: [DiscoveredDevice] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var batteryPct: Int? = nil
    /// Set to an HONEST explanation string when the band turned out to need the Huami auth pairing we
    /// can't do (no standard HR service AND no readable Huami HR characteristic). nil otherwise. The UI
    /// surfaces this instead of a fake reading. Cleared on stop/disconnect.
    @Published public private(set) var needsPairing: String? = nil

    // MARK: - BLE UUIDs

    /// Standard SIG Heart Rate Service / Measurement — preferred when present (newer bands).
    private static let stdHeartRateService = CBUUID(string: "180D")
    private static let stdHeartRateMeasurement = CBUUID(string: "2A37")
    /// Documented Huami custom HR service + measurement characteristic (128-bit). FACTS only.
    private static let huamiService = CBUUID(string: "0000FEE0-0000-1000-8000-00805F9B34FB")
    private static let huamiHeartRateMeasurement = CBUUID(string: "00002A37-0000-3512-2118-0009AF100700")
    /// Standard Battery Service.
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    // MARK: - Dependencies (injected — no BLEManager reference)

    private let live: LiveState
    private let persist: (Streams) -> Void
    private let deviceId: String
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// When false (the wizard's discovery-only scanner) this source never writes `LiveState`.
    private let feedsLive: Bool

    private var loggedFirstHR = false
    /// True once we've enabled notifications on EITHER HR characteristic, so the disconnect handler can
    /// tell "we never found an HR source" (→ honest needs-pairing note) from "the link just dropped".
    private var enabledAnyHR = false

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingConnectID: UUID?
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Sample buffer

    private var buffer: [(hr: Int, ts: Int)] = []
    private var lastFlush: Date = .init()
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30

    // MARK: - Init

    public init(live: LiveState,
                deviceId: String,
                persist: @escaping (Streams) -> Void = { _ in },
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                feedsLive: Bool = true) {
        self.live = live
        self.deviceId = deviceId
        self.persist = persist
        self.log = log
        self.onBattery = onBattery
        self.feedsLive = feedsLive
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    /// Scan for Huami-family devices. We can't filter by a single service (some advertise the standard
    /// 0x180D, some the Huami 0xFEE0, some neither in the advert), so we scan broadly and keep only the
    /// ones whose advertised name `ExperimentalBrand` recognises as Amazfit/Zepp/Mi Band.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        needsPairing = nil
        log("Huami: scanning for Amazfit / Zepp / Mi Band devices…")
        guard central.state == .poweredOn else {
            log("Huami: Bluetooth not powered on (state=\(central.state.rawValue)) — scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    public func connect(_ id: UUID) {
        stopScan()
        needsPairing = nil
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            pendingConnectID = id
            log("Huami: device \(id) not cached yet — scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Huami: Bluetooth not powered on — connect to \(id) deferred until ready")
            return
        }
        log("Huami: connecting to \(id)")
        central.connect(p, options: nil)
    }

    public func stop() {
        stopScan()
        pendingConnectID = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        loggedFirstHR = false
        enabledAnyHR = false
        batteryPct = nil
        flush()
        if feedsLive { live.connected = false }
    }

    // MARK: - Buffer / persistence

    private func enqueue(hr: Int) {
        buffer.append((hr: hr, ts: Int(Date().timeIntervalSince1970)))
        if buffer.count >= flushCount || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { lastFlush = Date(); return }
        for sample in buffer {
            // HR-only mapping (no R-R on the Huami custom char): reuse the same HR→Streams mapping the
            // generic strap path uses so persisted rows are identical in shape and source-tagged by id.
            persist(StandardHRMapping.samples(fromHR: sample.hr, rr: [], at: sample.ts))
        }
        buffer.removeAll()
        lastFlush = Date()
    }

    /// Fold a decoded HR (from either characteristic) into live state + the buffer. Range-gated to the
    /// same physiological window the standard path uses; an out-of-range value is dropped (never shown).
    private func ingest(hr: Int) {
        guard hr >= 30, hr <= 220 else { return }
        if !loggedFirstHR {
            loggedFirstHR = true
            log("Huami: receiving data — first sample \(hr) bpm")
        }
        if feedsLive {
            live.heartRate = hr
            live.connected = true
        }
        enqueue(hr: hr)
    }
}

// MARK: - CBCentralManagerDelegate

extension HuamiHRSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            if feedsLive { live.connected = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // Keep only recognised Amazfit / Zepp / Mi Band devices — a broad scan sees everything nearby.
        guard let brand = ExperimentalBrand.recognise(name: name),
              brand == .amazfit || brand == .miBand else { return }
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Huami: found \(LiveState.logSafeDeviceName(name)) (\(id)) rssi \(RSSI.intValue)") }
        let dev = DiscoveredDevice(id: id, name: name.isEmpty ? brand.displayBrand : name, rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = dev
        } else {
            discovered.append(dev)
        }
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Huami: connected — discovering services")
        peripheral.delegate = self
        peripheral.discoverServices([Self.stdHeartRateService, Self.huamiService, Self.batteryService])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Huami: WARNING failed to connect — \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.connected = false }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Huami: disconnected\(error.map { " — \($0.localizedDescription)" } ?? " (clean)")")
        loggedFirstHR = false
        enabledAnyHR = false
        batteryPct = nil
        flush()
        if feedsLive { live.connected = false }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
    }
}

// MARK: - CBPeripheralDelegate

extension HuamiHRSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Huami: WARNING service discovery failed — \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        let hasStd = services.contains { $0.uuid == Self.stdHeartRateService }
        let hasHuami = services.contains { $0.uuid == Self.huamiService }
        // Prefer the standard SIG HR service; fall back to the Huami custom one.
        if hasStd {
            log("Huami: standard 0x180D heart-rate service FOUND — using it (preferred)")
            for svc in services where svc.uuid == Self.stdHeartRateService {
                peripheral.discoverCharacteristics([Self.stdHeartRateMeasurement], for: svc)
            }
        } else if hasHuami {
            log("Huami: no standard 0x180D — trying the documented Huami custom HR characteristic")
            for svc in services where svc.uuid == Self.huamiService {
                peripheral.discoverCharacteristics([Self.huamiHeartRateMeasurement], for: svc)
            }
        } else {
            // Neither HR service exposed → this band needs the Huami auth pairing we don't implement.
            announceNeedsPairing()
        }
        for svc in services where svc.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: svc)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Huami: WARNING characteristic discovery failed — \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for ch in chars where ch.uuid == Self.batteryLevel {
            peripheral.readValue(for: ch)
            if ch.properties.contains(.notify) { peripheral.setNotifyValue(true, for: ch) }
        }
        // Subscribe to whichever HR characteristic this band exposed.
        var subscribed = false
        for ch in chars where ch.uuid == Self.stdHeartRateMeasurement || ch.uuid == Self.huamiHeartRateMeasurement {
            // It must actually support notify/indicate for live HR — an auth-gated band sometimes lists
            // the characteristic but won't notify without pairing. We try; the disconnect/failure path
            // surfaces the honest message if nothing ever arrives.
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: ch)
                subscribed = true
                enabledAnyHR = true
                log("Huami: enabling notifications on \(ch.uuid == Self.stdHeartRateMeasurement ? "standard" : "Huami") HR characteristic")
            }
        }
        // The HR service was found but its characteristic isn't notifiable (auth-gated) → be honest.
        if !subscribed,
           service.uuid == Self.stdHeartRateService || service.uuid == Self.huamiService {
            announceNeedsPairing()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.stdHeartRateMeasurement ||
              characteristic.uuid == Self.huamiHeartRateMeasurement else { return }
        if let error = error {
            // The band refused the subscription — almost always the Huami auth gate. Be honest.
            log("Huami: WARNING enabling notifications FAILED — \(error.localizedDescription)")
            announceNeedsPairing()
        } else {
            log("Huami: notifications enabled (isNotifying=\(characteristic.isNotifying))")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == Self.batteryLevel {
            if let pct = StandardBattery.parse([UInt8](value)) {
                log("Huami: battery \(pct)%")
                batteryPct = pct
                onBattery(pct)
            }
            return
        }
        let bytes = [UInt8](value)
        let hr: Int?
        if characteristic.uuid == Self.stdHeartRateMeasurement {
            hr = StandardHeartRate.parse(bytes)?.hr     // standard 0x2A37 layout
        } else if characteristic.uuid == Self.huamiHeartRateMeasurement {
            hr = HuamiHeartRate.parse(bytes)            // Huami custom layout
        } else {
            return
        }
        guard let hr else { return }   // no usable reading → stay at "—", never fabricate
        ingest(hr: hr)
    }

    /// Record + log the honest "this band needs pairing we can't do yet" outcome (once).
    private func announceNeedsPairing() {
        guard needsPairing == nil else { return }
        let msg = "This band needs a pairing handshake NOOP can't do yet. Live data isn't available - try " +
                  "exporting from the Zepp app and importing the file instead."
        needsPairing = msg
        log("Huami: \(msg)")
    }
}
