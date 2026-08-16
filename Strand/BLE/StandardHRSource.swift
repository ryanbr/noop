import Foundation
import Combine
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// An ISOLATED standard-Bluetooth Heart-Rate source for generic HR straps
/// (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) that expose the standard
/// BLE Heart Rate Service (0x180D) with the Heart Rate Measurement characteristic (0x2A37).
///
/// WHOOP-FIRST ISOLATION: this class runs its OWN `CBCentralManager` and never imports, calls, or
/// shares state with `BLEManager`. The WHOOP path cannot regress because of anything here — the two
/// CoreBluetooth flows are fully independent. The only shared surfaces are `LiveState` (so the
/// existing Live UI shows the strap's HR) and the `persist` closure (wired by the app to
/// `StreamStore.insert`). The pure HR→Streams mapping lives in `WhoopStore.StandardHRMapping` so it
/// can be unit-tested away from CoreBluetooth.
@MainActor
public final class StandardHRSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// A generic HR strap seen during a scan.
    public struct DiscoveredStrap: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
    }

    /// Straps discovered during the current scan, keyed by peripheral identifier, ordered by proximity —
    /// strongest signal (closest) FIRST — so the strap the user is standing next to surfaces at the top of
    /// a crowded gym list. Maintained by `upsertByProximity`.
    @Published public private(set) var discovered: [DiscoveredStrap] = []

    /// Upsert a freshly-seen strap into the discovered list (same peripheral id updates in place with the
    /// newest RSSI) and keep it ordered by proximity — strongest RSSI first. Pure so the dedup + ordering
    /// contract is unit-testable without CoreBluetooth. Live RSSI is noisy, so a busy list can reorder as
    /// signals fluctuate; that's the accepted cost of "closest first" and matches every BLE scanner UI.
    nonisolated static func upsertByProximity(_ list: [DiscoveredStrap], _ strap: DiscoveredStrap) -> [DiscoveredStrap] {
        var out = list
        if let idx = out.firstIndex(where: { $0.id == strap.id }) {
            out[idx] = strap
        } else {
            out.append(strap)
        }
        // Stable descending by RSSI: a higher (less negative) dBm is closer. `sorted` is a stable sort in
        // Swift, so straps at equal RSSI keep their existing relative order (no needless churn).
        return out.sorted { $0.rssi > $1.rssi }
    }
    /// True while a scan is running (UI affordance).
    @Published public private(set) var scanning: Bool = false
    /// The connected strap's standard Battery Service (0x180F) level, 0–100, once read. nil until then
    /// or for a strap that doesn't expose the battery service. Surfaced on the device card the same way
    /// the WHOOP strap battery is. Cleared on disconnect/stop so a stale value can't outlive the link.
    @Published public private(set) var batteryPct: Int? = nil

    // MARK: - Standard BLE UUIDs

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")
    /// Standard Battery Service + Battery Level characteristic (a generic strap usually exposes these).
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    // Standard fitness-sensor services + measurement characteristics — discovered and subscribed
    // ADDITIVELY alongside HR if the connected device exposes them (a footpod / bike speed-cadence sensor
    // / power meter). A device without these simply yields no such characteristic; the HR path is wholly
    // unaffected. Speed/cadence/power surface on `LiveState.sensor*`, NEVER on `heartRate`.
    private static let rscService = CBUUID(string: "1814")           // Running Speed and Cadence
    private static let rscMeasurement = CBUUID(string: "2A53")
    private static let cscService = CBUUID(string: "1816")           // Cycling Speed and Cadence
    private static let cscMeasurement = CBUUID(string: "2A5B")
    private static let cpsService = CBUUID(string: "1818")           // Cycling Power
    private static let cpsMeasurement = CBUUID(string: "2A63")
    /// The three fitness-sensor measurement characteristics we read, mapped to their UUID16 short form.
    private static let fitnessSensorChars: [(CBUUID, String)] = [
        (rscMeasurement, "2A53"), (cscMeasurement, "2A5B"), (cpsMeasurement, "2A63"),
    ]
    private static func fitnessSensorUUID16(for uuid: CBUUID) -> String? {
        fitnessSensorChars.first(where: { $0.0 == uuid })?.1
    }

    /// Derives instantaneous speed/cadence from successive CSC/CPS cumulative counters. Per-source so a
    /// reconnect / new session starts fresh (reset on stop/disconnect). Pure value type in WhoopProtocol.
    private var rateComputer = FitnessRateComputer()
    /// Logs the first fitness-sensor sample of a connection only; reset on stop/disconnect.
    private var loggedFirstSensor = false

    // MARK: - Dependencies (injected — no BLEManager reference)

    private let live: LiveState
    private let persist: (Streams) -> Void
    private let deviceId: String
    /// Optional hook fired with the strap's battery percent (0–100) whenever it's read off 0x2A19.
    /// Wired (via `SourceCoordinator`) into `LiveState.setBattery` so a generic strap surfaces its
    /// charge the same place the WHOOP strap does. Default no-op keeps the discovery-only scanner and
    /// existing call sites silent / compiling unchanged.
    private let onBattery: (Int) -> Void
    /// Diagnostic sink for the connect lifecycle. Wired (via `SourceCoordinator`) to the SAME strap-log
    /// sink `BLEManager` uses, so the generic-HR path is no longer invisible in a bug report (issue #421).
    /// Every line is prefixed `"HR-strap: "` so it's distinguishable from WHOOP lines in the shared log.
    /// Default no-op keeps existing call sites compiling and the discovery-only scanner silent.
    private let log: (String) -> Void

    /// Logs the FIRST HR sample of a connection only (never every notification); reset on stop/disconnect.
    private var loggedFirstHR = false

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// A peripheral asked to connect before `centralManagerDidUpdateState` reported `.poweredOn`.
    private var pendingConnectID: UUID?
    /// Peripherals retained by identifier so a chosen one survives until connection.
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Sample buffer

    /// Buffered (hr, rr, ts) readings, flushed to `persist` in batches to keep the write path off
    /// the per-notification hot loop.
    private var buffer: [(hr: Int, rr: [Int], ts: Int)] = []
    private var lastFlush: Date = .init()
    /// Flush thresholds — whichever trips first.
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30

    // MARK: - Init

    /// - Parameters:
    ///   - live: the shared `LiveState` the Live UI observes.
    ///   - deviceId: the datastore device id these samples are attributed to.
    ///   - persist: wired by the app to `store.insert(_, deviceId:)`. Called on the main actor.
    ///   - log: connect-lifecycle diagnostics sink, wired at the composition root to the same strap log
    ///     `BLEManager` writes to (issue #421). Defaults to a no-op so the discovery-only scanner and
    ///     existing call sites stay silent / compile unchanged.
    public init(live: LiveState,
                deviceId: String,
                persist: @escaping (Streams) -> Void,
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in }) {
        self.live = live
        self.deviceId = deviceId
        self.persist = persist
        self.log = log
        self.onBattery = onBattery
        super.init()
        // Dedicated queue-less central → callbacks arrive on the main queue, matching @MainActor.
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    /// Begin scanning for generic HR straps advertising the 0x180D service.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        log("HR-strap: scanning for standard heart-rate straps (0x180D)…")
        guard central.state == .poweredOn else {
            log("HR-strap: Bluetooth not powered on (state=\(central.state.rawValue)) — scan deferred until ready")
            return   // deferred until poweredOn
        }
        central.scanForPeripherals(withServices: [Self.heartRateService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Stop an in-progress scan.
    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    /// Connect to the chosen discovered strap and start streaming its HR.
    public func connect(_ id: UUID) {
        stopScan()
        // Reach the peripheral directly: use the freshly-discovered handle if we have it, else ask
        // CoreBluetooth for the cached peripheral by identifier (a strap we've connected before). This is
        // what lets the active-strap switch CONNECT without depending on a fresh scan — the switchToStrap
        // path only ever scanned before, so a Polar etc. was discovered but never connected (#421).
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            // Never seen by this Mac/iPhone yet → remember it and scan; didDiscover connects it on sight.
            pendingConnectID = id
            log("HR-strap: strap \(id) not cached yet — scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("HR-strap: Bluetooth not powered on — connect to \(id) deferred until ready")
            return
        }
        log("HR-strap: connecting to \(id)")
        central.connect(p, options: nil)
    }

    /// Tear down: cancel the peripheral connection and stop scanning. Idempotent.
    public func stop() {
        stopScan()
        pendingConnectID = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        loggedFirstHR = false         // a later reconnect should log its first sample again
        loggedFirstSensor = false
        batteryPct = nil              // a stale charge must not outlive the link
        flush()                       // persist anything still buffered
        live.clearSensorMetrics()     // a stale speed/cadence/power panel must not outlive the link
        rateComputer.reset()          // next CSC/CPS packet is a first packet again (no carry-over)
        live.connected = false
    }

    // MARK: - Buffer / persistence

    private func enqueue(hr: Int, rr: [Int]) {
        buffer.append((hr: hr, rr: rr, ts: Int(Date().timeIntervalSince1970)))
        if buffer.count >= flushCount || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    private func flush() {
        guard !buffer.isEmpty else { lastFlush = Date(); return }
        for sample in buffer {
            persist(StandardHRMapping.samples(fromHR: sample.hr, rr: sample.rr, at: sample.ts))
        }
        buffer.removeAll()
        lastFlush = Date()
    }

    // MARK: - Fitness-sensor ingest (additive — never touches HR / scoring)

    /// Decode one RSC/CSC/CPS measurement and fold it onto `LiveState`'s additive sensor channel. RSC
    /// carries speed + cadence directly; CSC/CPS carry cumulative counters that the rate computer turns
    /// into instantaneous speed/cadence; CPS carries power directly. A field we can't derive yet (a first
    /// CSC/CPS packet) is left as-is rather than zeroed, so the panel shows the last good value, not a
    /// fabricated 0. Nothing here writes `live.heartRate`, `live.rr`, the sample buffer, or any scorer.
    private func ingestFitnessSensor(uuid16: String, bytes: [UInt8]) {
        guard let reading = FitnessSensorDecode.decode(uuid16: uuid16, bytes) else { return }
        if !loggedFirstSensor {
            loggedFirstSensor = true
            log("HR-strap: receiving \(reading.kind.displayName) data — first reading")
        }
        // RSC: direct instantaneous speed + cadence.
        if let kmh = reading.speedKmh { live.sensorSpeedKmh = kmh }
        if let spm = reading.runningCadenceSpm { live.sensorCadence = Double(spm) }
        // CPS: direct instantaneous power.
        if let w = reading.instantaneousPowerWatts { live.sensorPowerWatts = w }
        // CSC / CPS: derive instantaneous speed/cadence from successive cumulative counters.
        let rates = rateComputer.update(reading)
        if let kmh = rates.speedKmh { live.sensorSpeedKmh = kmh }
        if let rpm = rates.crankRpm { live.sensorCadence = rpm }
    }

    // CB delegate callbacks live in the @preconcurrency extensions below. The queue-less central
    // delivers them on the main thread, so MainActor isolation is sound; @preconcurrency lets this
    // @MainActor type satisfy the nonisolated CoreBluetooth requirements (same pattern as BLEManager).
}

// MARK: - CBCentralManagerDelegate

extension StandardHRSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Replay any intent that arrived before the radio was ready.
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: [Self.heartRateService],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            // Radio off / unauthorized / resetting → the link is not live.
            live.connected = false
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil   // not seen before this scan
        seenPeripherals[id] = peripheral
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "Heart Rate Strap"
        if firstSight { log("HR-strap: found \(name) (\(id)) rssi \(RSSI.intValue)") }
        let strap = DiscoveredStrap(id: id, name: name, rssi: RSSI.intValue)
        discovered = Self.upsertByProximity(discovered, strap)
        // If we were scanning specifically to reach this strap (a not-yet-cached active strap), connect now
        // that it's been seen — the switchToStrap path (#421).
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("HR-strap: connected — discovering services")
        peripheral.delegate = self
        // Discover the HR service (unchanged) AND, additively, the standard Battery Service + the three
        // fitness-sensor services (RSC/CSC/CPS) so a generic strap's charge AND a connected footpod / bike
        // speed-cadence sensor / power meter can be surfaced. A device without any of these simply yields
        // no such characteristic — the HR path is wholly unaffected.
        peripheral.discoverServices([Self.heartRateService, Self.batteryService,
                                     Self.rscService, Self.cscService, Self.cpsService])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("HR-strap: WARNING failed to connect — \(error?.localizedDescription ?? "unknown error")")
        live.connected = false
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            log("HR-strap: disconnected — \(error.localizedDescription)")
        } else {
            log("HR-strap: disconnected (clean)")
        }
        loggedFirstHR = false   // a reconnect should log its first sample again
        loggedFirstSensor = false
        batteryPct = nil        // a stale charge must not outlive the link
        flush()
        live.clearSensorMetrics()
        rateComputer.reset()
        live.connected = false
        if self.peripheral?.identifier == peripheral.identifier {
            self.peripheral = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension StandardHRSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("HR-strap: WARNING service discovery failed — \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("HR-strap: services discovered but the list was empty")
            return
        }
        log("HR-strap: services discovered")
        if services.contains(where: { $0.uuid == Self.heartRateService }) {
            log("HR-strap: 0x180D heart-rate service FOUND")
        } else {
            log("HR-strap: 0x180D heart-rate service NOT FOUND — this strap may not expose standard HR")
        }
        for svc in services where svc.uuid == Self.heartRateService {
            peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: svc)
        }
        // Additively read the battery level off 0x180F if the strap exposes it (low-risk, separate svc).
        for svc in services where svc.uuid == Self.batteryService {
            log("HR-strap: 0x180F battery service found — reading level")
            peripheral.discoverCharacteristics([Self.batteryLevel], for: svc)
        }
        // Additively discover the fitness-sensor measurement characteristics (RSC/CSC/CPS). Separate
        // services from HR — a device without them never reaches the sensor branch below.
        for svc in services where svc.uuid == Self.rscService {
            log("HR-strap: 0x1814 running speed/cadence service found")
            peripheral.discoverCharacteristics([Self.rscMeasurement], for: svc)
        }
        for svc in services where svc.uuid == Self.cscService {
            log("HR-strap: 0x1816 cycling speed/cadence service found")
            peripheral.discoverCharacteristics([Self.cscMeasurement], for: svc)
        }
        for svc in services where svc.uuid == Self.cpsService {
            log("HR-strap: 0x1818 cycling power service found")
            peripheral.discoverCharacteristics([Self.cpsMeasurement], for: svc)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("HR-strap: WARNING characteristic discovery failed — \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            log("HR-strap: characteristics discovered but the list was empty")
            return
        }
        // Battery Level (0x2A19): read it once and, if it supports notifications, subscribe so the card
        // updates as the strap drains. Kept entirely separate from the HR enablement below.
        for ch in chars where ch.uuid == Self.batteryLevel {
            peripheral.readValue(for: ch)
            if ch.properties.contains(.notify) { peripheral.setNotifyValue(true, for: ch) }
        }
        if chars.contains(where: { $0.uuid == Self.heartRateMeasurement }) {
            log("HR-strap: 0x2A37 measurement characteristic found — enabling notifications on 0x2A37")
        } else if service.uuid == Self.heartRateService {
            log("HR-strap: 0x2A37 measurement characteristic NOT FOUND — cannot read HR from this strap")
        }
        for ch in chars where ch.uuid == Self.heartRateMeasurement {
            peripheral.setNotifyValue(true, for: ch)
        }
        // Additively subscribe to any fitness-sensor measurement characteristic (RSC/CSC/CPS) this device
        // exposes. Notify-only, entirely separate from the HR enablement above.
        for ch in chars where Self.fitnessSensorUUID16(for: ch.uuid) != nil {
            log("HR-strap: fitness-sensor characteristic \(ch.uuid) found — enabling notifications")
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.heartRateMeasurement else { return }
        if let error = error {
            log("HR-strap: WARNING enabling notifications FAILED — \(error.localizedDescription) — strap will send no HR data")
        } else {
            log("HR-strap: notifications enabled (isNotifying=\(characteristic.isNotifying))")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        // Battery Level (0x2A19): a single u8 percent. Surface it and notify the wired hook.
        if characteristic.uuid == Self.batteryLevel {
            if let pct = StandardBattery.parse([UInt8](value)) {
                log("HR-strap: battery \(pct)%")
                batteryPct = pct
                onBattery(pct)
            }
            return
        }
        // Fitness-sensor measurement (RSC/CSC/CPS) — surface speed/cadence/power ADDITIVELY on LiveState's
        // sensor channel, never on `heartRate`. Cumulative CSC/CPS counters feed the rate computer.
        if let uuid16 = Self.fitnessSensorUUID16(for: characteristic.uuid) {
            ingestFitnessSensor(uuid16: uuid16, bytes: [UInt8](value))
            return
        }
        guard characteristic.uuid == Self.heartRateMeasurement else { return }
        guard let parsed = StandardHeartRate.parse([UInt8](value)) else { return }
        // Log the FIRST sample of a connection only — proof that data is flowing — never every sample.
        if !loggedFirstHR {
            loggedFirstHR = true
            log("HR-strap: receiving data — first sample \(parsed.hr) bpm (rr beats: \(parsed.rr.count))")
        }
        live.heartRate = parsed.hr
        live.setRRIntervals(parsed.rr)
        live.connected = true
        enqueue(hr: parsed.hr, rr: parsed.rr)
    }
}
