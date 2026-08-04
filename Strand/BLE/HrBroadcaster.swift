import Foundation
import Combine
import CoreBluetooth

/// Re-broadcasts NOOP's LIVE heart rate back OUT as a standard Bluetooth Heart Rate peripheral, so a
/// gym treadmill, Zwift, Peloton, a bike computer, or any fitness app can read the WHOOP HR that NOOP
/// is already receiving off the strap. It runs a `CBPeripheralManager` that advertises the standard
/// Heart Rate Service (0x180D) and notifies the Heart Rate Measurement characteristic (0x2A37) with the
/// SIG-spec flags + bpm encoding whenever NOOP has a fresh live HR sample.
///
/// OFFLINE, OPT-IN, ADDITIVE
/// -------------------------
/// This is LOCAL Bluetooth only — nothing leaves the device to any cloud or server. It just re-shares
/// the strap's HR to nearby gym kit over a standard BLE profile, which fits NOOP's offline ethos. It is
/// OFF by default and only ever runs when the user flips the "Broadcast heart rate" toggle in Data
/// Sources (persisted at ``defaultsKey``).
///
/// WHOOP-FIRST ISOLATION: this class runs its OWN `CBPeripheralManager` and never imports, calls, or
/// shares state with `BLEManager` / `StandardHRSource` / `SourceCoordinator`. It is a pure consumer of
/// whatever live HR the app already has — the input arrives via ``update(heartRate:)`` (or, when wired
/// to `LiveState`, by observing `$heartRate`). It writes nothing back into the WHOOP path, so the strap
/// connection, scoring, and history offload cannot regress because of anything here. The pure 0x2A37
/// measurement *encoder* lives in ``measurement(bpm:)`` so it can be unit-tested away from CoreBluetooth.
@MainActor
public final class HrBroadcaster: NSObject, ObservableObject {

    /// Shared with the Data Sources toggle via `@AppStorage(HrBroadcaster.defaultsKey)`. Deliberately a
    /// DISTINCT key from `PuffinExperiment.broadcastHrKey` — that one makes the WHOOP *strap* advertise
    /// its own HR via a firmware device-config; THIS one makes the NOOP *app* act as the HR peripheral.
    /// Default OFF (a bare `UserDefaults.bool` read is false when unset).
    public static let defaultsKey = "noopHrPeripheral"

    /// True once the user opted in (read where no instance is handy, e.g. app launch wiring).
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    // MARK: - Standard BLE UUIDs

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")

    // MARK: - Published state (for the toggle's status line)

    /// True while the peripheral is advertising 0x180D (the radio is on and `start()` was called).
    @Published public private(set) var advertising = false
    /// Count of centrals (gym kit / apps) currently subscribed to 0x2A37 notifications. Honest "who's
    /// listening" signal for the UI; 0 means we're advertising but nothing has connected yet.
    @Published public private(set) var subscriberCount = 0
    /// A human-readable reason the broadcast can't run (Bluetooth off / unauthorized), or nil when fine.
    /// Surfaced under the toggle so a silent no-op is never a mystery. No em-dashes, US-neutral.
    @Published public private(set) var statusNote: String? = nil

    // MARK: - CoreBluetooth state (OWN peripheral manager, separate from every WHOOP/central flow)

    private var manager: CBPeripheralManager?
    private var hrCharacteristic: CBMutableCharacteristic?
    /// Set true by `start()`; the actual advertise call happens once the radio reports `.poweredOn`.
    private var wantAdvertising = false
    /// The most recent live HR pushed in, re-sent to any central that subscribes mid-session so a newly
    /// connected machine shows a value immediately rather than waiting for the next sample. nil until the
    /// first sample of a session; cleared on stop so a stale bpm can't outlive the broadcast.
    private var lastBpm: Int?

    /// `private(set)` rather than `private` so `HrBroadcasterEncodeTests` can assert that ``bind(to:)``
    /// leaves exactly one subscription however many times it is called — the leak it fixes is invisible
    /// from the outside, so the count is the only thing a test can pin.
    private(set) var cancellables = Set<AnyCancellable>()

    /// Diagnostic sink for the broadcast lifecycle, wired (when the composition root chooses to) to the
    /// SAME exportable strap log the WHOOP path uses, so a tester whose gym kit can't see NOOP has a
    /// record of whether we advertised, who subscribed, and why the radio refused. Every line is prefixed
    /// "HR-out: " so it's distinguishable from the WHOOP and HR-strap lines. Privacy-safe: statuses and a
    /// subscriber COUNT only, never a central's address or any health value. Default no-op keeps the
    /// existing call sites + tests silent / compiling unchanged. Mirrors the Android `HrBroadcaster(log:)`.
    private let log: (String) -> Void

    /// - Parameter log: optional broadcast-lifecycle diagnostics sink, wired at the composition root to the
    ///   same strap log the rest of the app writes to. Defaults to a no-op so existing call sites compile.
    public init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
        super.init()
    }

    // MARK: - Lifecycle

    /// Begin acting as a standard HR peripheral: bring up the `CBPeripheralManager`, publish the 0x180D
    /// service, and advertise it. Idempotent. The manager is created lazily on first `start()` so a user
    /// who never opts in never triggers the system Bluetooth-permission prompt.
    public func start() {
        wantAdvertising = true
        statusNote = nil
        if manager == nil {
            // Queue-less manager → delegate callbacks arrive on the main queue, matching @MainActor.
            manager = CBPeripheralManager(delegate: self, queue: nil)
        } else if manager?.state == .poweredOn {
            beginAdvertising()
        }
    }

    /// Stop advertising and tear the peripheral down. Idempotent. A stale HR is cleared so a later
    /// restart never re-emits an old value.
    public func stop() {
        wantAdvertising = false
        lastBpm = nil
        subscriberCount = 0
        advertising = false
        if let manager, manager.state == .poweredOn {
            if manager.isAdvertising { manager.stopAdvertising() }
            manager.removeAllServices()
        }
        // Drop the manager so a future opt-out fully releases the radio; a later start() rebuilds it.
        manager = nil
        hrCharacteristic = nil
    }

    /// Bind to a `LiveState` so every live HR change is broadcast automatically. Optional convenience the
    /// app's composition root can call; the broadcaster works equally well by polling
    /// ``update(heartRate:)`` directly. Observing `$heartRate` keeps this a pure CONSUMER of the existing
    /// live value — it never drives or mutates the WHOOP/central path.
    ///
    /// **Idempotent.** The previous subscription is cancelled before the new one is stored, so calling this
    /// twice leaves exactly one sink. That is not hypothetical tidiness: the only call site is
    /// `DataSourcesView.onAppear`, and `onAppear` fires on EVERY appearance — every tab switch back to Data
    /// Sources, every push-and-pop — while the broadcaster itself is a `@StateObject` that outlives all of
    /// them. Without this reset the sinks accumulated one per visit, and each one called
    /// ``update(heartRate:)`` for the same sample, so a user who had visited the screen N times sent N
    /// duplicate 0x2A37 notifications per heartbeat to every subscribed central.
    public func bind(to live: LiveState) {
        cancellables.removeAll()
        live.$heartRate
            .removeDuplicates()
            .sink { [weak self] hr in self?.update(heartRate: hr) }
            .store(in: &cancellables)
    }

    /// Feed a live HR sample (bpm) to broadcast. nil (no current reading) sends nothing — we never invent
    /// a value. A non-physiological bpm is dropped so untrusted/garbage input can't be re-broadcast.
    public func update(heartRate bpm: Int?) {
        guard wantAdvertising, let bpm, (20...255).contains(bpm) else { return }
        lastBpm = bpm
        notify(bpm: bpm)
    }

    // MARK: - Notify

    /// Send a 0x2A37 Heart Rate Measurement notification to every subscribed central.
    private func notify(bpm: Int) {
        guard let manager, let hrCharacteristic, manager.state == .poweredOn else { return }
        let value = Data(Self.measurement(bpm: bpm))
        // updateValue returns false when the transmit queue is full; CoreBluetooth then calls
        // peripheralManagerIsReady(toUpdateSubscribers:) and the NEXT live sample sends fine. We
        // deliberately don't buffer dropped samples — HR is a live, lossy signal, and the freshest
        // value is what gym kit wants. No retry storm, no growth.
        _ = manager.updateValue(value, for: hrCharacteristic, onSubscribedCentrals: nil)
    }

    // MARK: - Pure encoder (unit-tested away from CoreBluetooth)

    /// Encode one Bluetooth SIG Heart Rate Measurement (0x2A37) payload for a given bpm.
    ///
    /// Layout (matches `StandardHeartRate.parse`, the inverse): a flags byte followed by the HR value.
    ///   - flags bit0 = 0 → the HR value is a single u8 byte (emitted for any bpm < 256);
    ///   - flags bit0 = 1 → the HR value is u16 little-endian (only needed for an out-of-range bpm >= 256).
    /// We never set bit3 (Energy Expended) or bit4 (R-R) — NOOP broadcasts a plain instantaneous HR. The
    /// bpm is clamped to a non-negative 16-bit range so a stray value can never overflow the encoding.
    public static func measurement(bpm: Int) -> [UInt8] {
        let clamped = max(0, min(bpm, 0xFFFF))
        if clamped < 256 {
            return [0x00, UInt8(clamped)]                 // flags=0 (u8 HR), value
        } else {
            return [0x01, UInt8(clamped & 0xFF), UInt8((clamped >> 8) & 0xFF)]   // flags=1 (u16 LE)
        }
    }

    // MARK: - Internal advertise helper

    private func beginAdvertising() {
        guard let manager, manager.state == .poweredOn, wantAdvertising else { return }

        // (Re)publish the HR service with a single notify-only 0x2A37 characteristic.
        if hrCharacteristic == nil {
            let characteristic = CBMutableCharacteristic(
                type: Self.heartRateMeasurement,
                properties: [.notify],
                value: nil,
                permissions: [.readable])
            let service = CBMutableService(type: Self.heartRateService, primary: true)
            service.characteristics = [characteristic]
            manager.removeAllServices()
            manager.add(service)
            hrCharacteristic = characteristic
            log("HR-out: GATT peripheral up, 0x180D / 0x2A37 published")
        }
        if !manager.isAdvertising {
            manager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Self.heartRateService],
                CBAdvertisementDataLocalNameKey: "NOOP HR",
            ])
            log("HR-out: advertising 0x180D heart-rate service")
        }
        advertising = true
        statusNote = nil
    }
}

// MARK: - CBPeripheralManagerDelegate

extension HrBroadcaster: @preconcurrency CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if wantAdvertising { beginAdvertising() }
        case .poweredOff:
            advertising = false
            subscriberCount = 0
            statusNote = "Bluetooth is off. Turn it on to broadcast your heart rate."
            log("HR-out: Bluetooth is off, cannot broadcast")
        case .unauthorized:
            advertising = false
            statusNote = "NOOP needs Bluetooth permission to broadcast your heart rate."
            log("HR-out: Bluetooth permission not granted, cannot broadcast")
        case .unsupported:
            advertising = false
            statusNote = "This device can't broadcast Bluetooth heart rate."
            log("HR-out: peripheral mode unsupported on this device")
        default:
            advertising = false
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.heartRateMeasurement else { return }
        subscriberCount += 1
        log("HR-out: a central subscribed (now \(subscriberCount))")
        // Send the latest reading immediately so a freshly connected machine shows a value at once.
        if let bpm = lastBpm { notify(bpm: bpm) }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.heartRateMeasurement else { return }
        subscriberCount = max(0, subscriberCount - 1)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // The transmit queue drained after a full-queue updateValue. Re-send the freshest reading so a
        // value lands promptly rather than waiting for the next live sample.
        if let bpm = lastBpm { notify(bpm: bpm) }
    }
}
