import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// An ISOLATED standard-Bluetooth source for FTMS gym equipment — a treadmill, indoor bike, rower, or
/// cross-trainer that exposes the Fitness Machine Service (0x1826) with one of the machine-data
/// characteristics (Treadmill 0x2ACD, Indoor Bike 0x2AD2, Rower 0x2AD1, Cross Trainer 0x2ACE).
///
/// WHOOP-FIRST ISOLATION (identical to `StandardHRSource`): this class runs its OWN `CBCentralManager`
/// and never imports, calls, or shares state with `BLEManager`. The WHOOP path cannot regress because of
/// anything here — the two CoreBluetooth flows are fully independent. The only shared surfaces are
/// `LiveState` (so the existing Live UI shows the machine's HR and the live-workout recorder captures it
/// through the SAME path) and the injected closures (`log`, `onBattery`). The pure FTMS field decode
/// lives in `WhoopProtocol.FTMSDecode` so it's unit-tested away from CoreBluetooth.
///
/// RECORDING: this source does NOT invent a scoring loop. It feeds live HR into `LiveState.heartRate`
/// exactly like `StandardHRSource`, so a machine session is recorded by the EXISTING manual live-workout
/// flow (`AppModel.startWorkout` / `endWorkout` → `StrainScorer` → Effort). The machine-specific metrics
/// (speed, cadence, power, distance, energy) are surfaced live via `latest` for the in-exercise UI and
/// logged; they are not run through any new scorer.
@MainActor
public final class FTMSSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// An FTMS machine seen during a scan.
    public struct DiscoveredMachine: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    /// Machines discovered during the current scan.
    @Published public private(set) var discovered: [DiscoveredMachine] = []
    /// True while a scan is running (UI affordance).
    @Published public private(set) var scanning: Bool = false
    /// The most recently decoded machine-data reading, for the live in-exercise readout. nil until the
    /// first notification; cleared on stop/disconnect so a stale panel can't outlive the link.
    @Published public private(set) var latest: FTMSReading?
    /// The connected machine's battery level (0x180F), 0–100, if it exposes one. nil otherwise.
    @Published public private(set) var batteryPct: Int?

    // MARK: - Standard BLE UUIDs

    private static let fitnessMachineService = CBUUID(string: "1826")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    /// The four machine-data characteristics we read, mapped to their FTMS kind. We subscribe to
    /// whichever one the machine exposes.
    private static let machineCharKinds: [(CBUUID, FTMSMachineKind)] = [
        (CBUUID(string: "2ACD"), .treadmill),
        (CBUUID(string: "2AD2"), .indoorBike),
        (CBUUID(string: "2AD1"), .rower),
        (CBUUID(string: "2ACE"), .crossTrainer),
    ]
    private static let machineChars: [CBUUID] = machineCharKinds.map { $0.0 }
    /// The FTMS machine kind for a characteristic UUID (CBUUID compare), or nil if it isn't one of ours.
    private static func machineKind(for uuid: CBUUID) -> FTMSMachineKind? {
        machineCharKinds.first(where: { $0.0 == uuid })?.1
    }

    // MARK: - Dependencies (injected — no BLEManager reference)

    private let live: LiveState
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// Whether to push the machine's HR into the shared `LiveState` (true for the active machine; false
    /// for the throwaway discovery-only scanner the wizard uses).
    private let feedsLive: Bool

    private var loggedFirstReading = false

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingConnectID: UUID?
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Init

    /// - Parameters:
    ///   - live: the shared `LiveState` the Live UI + live-workout recorder observe.
    ///   - log: connect-lifecycle diagnostics, wired to the same strap log `BLEManager` writes to.
    ///   - onBattery: fired with the machine's battery percent (0–100) when read off 0x2A19.
    ///   - feedsLive: when false (the wizard's discovery-only scanner) the source never writes `LiveState`.
    public init(live: LiveState,
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                feedsLive: Bool = true) {
        self.live = live
        self.log = log
        self.onBattery = onBattery
        self.feedsLive = feedsLive
        super.init()
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    /// Begin scanning for FTMS machines advertising the 0x1826 service.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        log("FTMS: scanning for gym equipment (0x1826)…")
        guard central.state == .poweredOn else {
            log("FTMS: Bluetooth not powered on (state=\(central.state.rawValue)) — scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: [Self.fitnessMachineService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Stop an in-progress scan.
    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    /// Connect to the chosen machine and start streaming its machine data.
    public func connect(_ id: UUID) {
        stopScan()
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            pendingConnectID = id
            log("FTMS: machine \(id) not cached yet — scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("FTMS: Bluetooth not powered on — connect to \(id) deferred until ready")
            return
        }
        log("FTMS: connecting to \(id)")
        central.connect(p, options: nil)
    }

    /// Tear down: cancel the connection and stop scanning. Idempotent.
    public func stop() {
        stopScan()
        pendingConnectID = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        loggedFirstReading = false
        latest = nil
        batteryPct = nil
        if feedsLive { live.connected = false }
    }

    // MARK: - Reading handling

    /// Fold a decoded reading into the live state + published snapshot. HR (when present) rides the SAME
    /// `LiveState.heartRate` channel the WHOOP / standard-HR sources use, so the existing live-workout
    /// recorder scores it — no new scoring loop.
    private func ingest(_ reading: FTMSReading) {
        latest = reading
        guard feedsLive else { return }
        if let hr = reading.heartRate, hr >= 30, hr <= 220 {
            live.heartRate = hr
        }
        live.connected = true
    }
}

// MARK: - CBCentralManagerDelegate

extension FTMSSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: [Self.fitnessMachineService],
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
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "Gym Equipment"
        if firstSight { log("FTMS: found \(LiveState.logSafeDeviceName(name)) (\(id)) rssi \(RSSI.intValue)") }
        let machine = DiscoveredMachine(id: id, name: name, rssi: RSSI.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = machine
        } else {
            discovered.append(machine)
        }
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("FTMS: connected — discovering services")
        peripheral.delegate = self
        peripheral.discoverServices([Self.fitnessMachineService, Self.batteryService])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("FTMS: WARNING failed to connect — \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.connected = false }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            log("FTMS: disconnected — \(error.localizedDescription)")
        } else {
            log("FTMS: disconnected (clean)")
        }
        loggedFirstReading = false
        latest = nil
        batteryPct = nil
        if feedsLive { live.connected = false }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
    }
}

// MARK: - CBPeripheralDelegate

extension FTMSSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("FTMS: WARNING service discovery failed — \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("FTMS: services discovered but the list was empty")
            return
        }
        for svc in services where svc.uuid == Self.fitnessMachineService {
            log("FTMS: 0x1826 fitness machine service FOUND — discovering machine-data characteristics")
            peripheral.discoverCharacteristics(Self.machineChars, for: svc)
        }
        for svc in services where svc.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: svc)
        }
        if !services.contains(where: { $0.uuid == Self.fitnessMachineService }) {
            log("FTMS: 0x1826 service NOT FOUND — this device isn't a fitness machine")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("FTMS: WARNING characteristic discovery failed — \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        // Subscribe to whichever machine-data characteristic this machine exposes (notify-only).
        for ch in chars {
            guard let kind = Self.machineKind(for: ch.uuid) else { continue }
            log("FTMS: \(kind.displayName) data characteristic found — enabling notifications")
            peripheral.setNotifyValue(true, for: ch)
        }
        // Battery (0x2A19): read once, subscribe if it notifies.
        for ch in chars where ch.uuid == Self.batteryLevel {
            peripheral.readValue(for: ch)
            if ch.properties.contains(.notify) { peripheral.setNotifyValue(true, for: ch) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        // Battery Level.
        if characteristic.uuid == Self.batteryLevel {
            if let pct = StandardBattery.parse([UInt8](value)) {
                log("FTMS: battery \(pct)%")
                batteryPct = pct
                onBattery(pct)
            }
            return
        }
        // Machine data — map the characteristic UUID to its FTMS kind (CBUUID compare, not string
        // formatting, so we don't depend on whether the OS reports the 16-bit or 128-bit form).
        guard let kind = Self.machineKind(for: characteristic.uuid),
              let reading = FTMSDecode.decode(uuid16: kind.characteristicUUID16, [UInt8](value)) else { return }
        if !loggedFirstReading {
            loggedFirstReading = true
            log("FTMS: receiving \(reading.kind.displayName) data — first reading\(reading.heartRate.map { " HR \($0) bpm" } ?? "")")
        }
        ingest(reading)
    }
}
