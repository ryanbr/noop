import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// Detects a marginal Bluetooth radio that can't sustain the WHOOP 4 R10/R11 raw realtime stream
/// (#80). On a flaky radio (2016 Mac / OpenCore) the link dies the *instant* NOOP arms that
/// high-bandwidth burst, then the auto-rescan reconnects, re-arms, and dies again — an endless loop.
///
/// The tell is a CONNECTION TIMEOUT that lands shortly after we armed realtime: arm → die → rescan →
/// arm → die. We don't trip on a single drop (links die for benign reasons), but on >= `tripThreshold`
/// CONSECUTIVE arm-then-quick-timeout cycles. Once tripped, the caller skips arming R10/R11 on the next
/// connect and relies on the independent low-bandwidth 0x2A37 standard HR profile, which NOOP already
/// subscribes — live HR survives on a radio that otherwise couldn't, and even if 0x2A37 stays silent the
/// arm/die loop stops. Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam.
struct MarginalRadioDetector {
    /// How many consecutive arm-then-quick-timeout cycles before we fall back to standard-HR-only.
    /// 2 (not 1): one drop is noise; two in a row right after arming is the radio buckling under the burst.
    let tripThreshold: Int
    /// A timeout only counts as "right after arming" if it lands within this window. A drop minutes into a
    /// healthy session is unrelated to the arm burst and must NOT be blamed on it (that would mis-trip a
    /// good radio whose link merely flaps later).
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveArmTimeouts = 0
    /// True once we've tripped: the next connect should skip the R10/R11 arm and run standard-HR-only.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 20) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// A connection ended. `wasArmed` = we had armed R10/R11 this connection; `secondsSinceArm` = how long
    /// after arming the link ended (nil if we never armed); `timedOut` = the drop looks like a connection
    /// timeout (vs. an intentional disconnect, a bond reset, etc.). Returns true if THIS event tripped the
    /// fallback (a freshly-crossed threshold), so the caller can log/surface it exactly once.
    mutating func connectionEnded(wasArmed: Bool, secondsSinceArm: TimeInterval?, timedOut: Bool) -> Bool {
        // Only a timeout that lands within the window after we actually armed the burst is evidence the
        // radio choked on the arm. Anything else (clean session that later flapped, non-timeout error,
        // never armed) breaks the streak — a single healthy spell should clear prior suspicion.
        let armCausedTimeout = wasArmed && timedOut
            && (secondsSinceArm.map { $0 <= quickTimeoutWindow } ?? false)
        guard armCausedTimeout else {
            consecutiveArmTimeouts = 0
            return false
        }
        consecutiveArmTimeouts += 1
        if !tripped && consecutiveArmTimeouts >= tripThreshold {
            tripped = true
            return true        // freshly tripped — caller logs/surfaces once
        }
        return false
    }

    /// Clear all suspicion: a clean session is flowing, or the user explicitly re-requested the full
    /// stream (Live re-open / manual Start HR). Lets a transient radio hiccup recover instead of
    /// permanently pinning the user to standard-HR mode.
    mutating func reset() {
        consecutiveArmTimeouts = 0
        tripped = false
    }
}

/// Decides when a completed sync that handed over only the strap's console/diagnostic output (no sensor
/// records) is sustained enough to warn that the strap's clock has lost sync and it isn't banking to flash
/// (#77 / #91 / #120). A SINGLE empty cycle is common on a perfectly healthy strap — the strap can hand
/// back a console-only window, especially under heavy live-HR polling — so warning on one cycle
/// false-alarms users whose clock is fine (#126). We require CONSECUTIVE empty cycles; any cycle that banks
/// real sensor records clears the streak. Pure value type → unit-testable without a CoreBluetooth seam.
struct EmptySyncTracker {
    /// Consecutive console-only completed syncs before the clock-lost banner shows. 3 (not 1): a genuinely
    /// un-banking strap is console-only on EVERY cycle, so 3 is reached within minutes, while a transient
    /// empty cycle amid healthy ones never accumulates.
    let threshold: Int
    private(set) var consecutiveEmptySyncs = 0

    init(threshold: Int = 3) { self.threshold = threshold }

    /// Record a COMPLETED (HISTORY_COMPLETE) offload. `bankedSensorRecords` = the strap handed over real
    /// sensor records this cycle (decoded, or undecodable-but-archived — either way the clock is banking).
    /// `consoleOnly` = it handed over only diagnostic frames and no sensor records. Returns true only once
    /// emptiness is SUSTAINED (≥ threshold consecutive console-only cycles) — the caller shows the
    /// "clock has lost sync" banner only then. Any banking cycle, or a caught-up cycle with nothing to
    /// offload, clears the streak.
    mutating func recordCompletedSync(bankedSensorRecords: Bool, consoleOnly: Bool) -> Bool {
        guard consoleOnly, !bankedSensorRecords else {
            consecutiveEmptySyncs = 0
            return false
        }
        consecutiveEmptySyncs += 1
        return consecutiveEmptySyncs >= threshold
    }
}

/// CoreBluetooth engine for the WHOOP 4.0: scan-by-service → connect → discover →
/// BOND (one confirmed write) → subscribe → reassemble char-05 frames → FrameRouter.
/// Cannot run in the simulator; verified manually on-device (Task C6).
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") // WHOOP 5.0 / MG
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    // WHOOP 5.0 / MG ("puffin") characteristics under the fd4b service. EXPERIMENTAL — see the
    // whoop5 connect path in didDiscoverCharacteristics. fd4b0002 takes the static CLIENT_HELLO.
    static let whoop5CmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let whoop5NotifyChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    static let restoreID = "com.openwhoop.ble.central"

    // MARK: Published state
    public let state: LiveState
    private let router: FrameRouter
    private var collector: Collector?

    // MARK: Upload / server sync — REMOVED for Strand (standalone, fully on-device).

    // MARK: Backfill
    private var backfiller: Backfiller?
    /// True while a historical offload session is in progress (frames route to Backfiller).
    private var backfilling = false
    /// Wall time of the most recent offload frame OR HISTORY_COMPLETE — drives the #174 deep-packet
    /// cooldown. A type-0x2F frame arriving just after a backfill ends (backfilling already flipped
    /// false) is a TRAILING historical frame, not the live R22 stream; it must not be miscounted as a
    /// "live deep packet". nil until the first offload frame this process.
    private var lastOffloadFrameAt: Date?
    /// Window after the last offload frame/HISTORY_COMPLETE during which a type-0x2F frame is treated
    /// as trailing-historical, not live. ~10 s comfortably covers the post-completion drain lull.
    static let deepPacketLiveCooldownSeconds: TimeInterval = 10
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
    /// Fires if the strap goes silent mid-offload; re-armed on every frame during backfill.
    private var backfillTimeout: DispatchWorkItem?
    /// Periodic opportunistic upload while connected. Without it, upload only fires at connect +
    /// backfill-exit, so during a long live session decoded rows pile up locally and the server
    /// (dashboard) lags. Started on bond, cancelled on disconnect.
    private var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect. Plain SEND_HISTORICAL_DATA returns the type-47 store (no
    /// high-freq-sync), so each periodic tick just routes through requestSync(.periodic) → beginBackfill
    /// (SEND_HISTORICAL_DATA + watchdog), subject to the BackfillPolicy floor.
    private var backfillTimer: DispatchSourceTimer?
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
    /// Keep-alive: re-arm realtime, poll battery, and bounce a stalled link so streaming
    /// never silently dies. Started on bond, cancelled on disconnect.
    private var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    private var keepAliveTick = 0
    /// If a persisted/missing strap-family preference points at the wrong service, a service-filtered
    /// BLE scan can run forever even though the strap is nearby (the common "won't reconnect after an
    /// update" report). Rotate between WHOOP families after a short miss and persist whichever family
    /// actually advertises. (PR#195)
    private var scanFallbackWorkItem: DispatchWorkItem?
    static let scanFallbackDelaySeconds: TimeInterval = 8
    /// Last time ANY notification arrived — drives the liveness watchdog.
    private var lastDataAt = Date()
    /// True while a Live/Health screen is on-screen and wants the realtime stream. One of the two
    /// inputs to `wantsRealtime`. Driven by `startRealtime()` / `stopRealtime()`.
    private var screenWantsRealtime = false
    /// True while the "Continuous HRV capture" preference wants the realtime stream held open even with
    /// no Live screen visible, so the strap banks dense beat-to-beat R-R 24/7 (better overnight
    /// HRV/recovery/sleep). The second input to `wantsRealtime`. Default off; set by
    /// `setKeepRealtimeForData(_:)`. Mirrors the Android `keepStreamForData`.
    private var keepRealtimeForData = false
    /// Derived want: the (heavy) realtime stream should be armed while EITHER a screen wants it OR the
    /// continuous-capture preference wants it. Keep-alive re-arms it; the post-bond branch arms it on
    /// connect. Recomputed only inside `reconcileRealtime()`.
    private var wantsRealtime = false
    /// What we last told the strap (armed = TOGGLE_REALTIME_HR 1). Lets `reconcileRealtime()` send the
    /// toggle only on the false↔true edge instead of on every input change. Cleared on disconnect — the
    /// strap forgets the toggle across a connection, and the post-bond branch re-arms from `wantsRealtime`.
    private var realtimeArmed = false
    /// #80 marginal-radio fallback: tracks consecutive arm-then-quick-timeout cycles. When it trips,
    /// `standardHRFallback` goes true and the next connect skips arming R10/R11 (relies on 0x2A37).
    private var marginalRadio = MarginalRadioDetector()
    /// #126 false-alarm guard: tracks CONSECUTIVE console-only completed syncs so the "clock has lost
    /// sync" banner only fires on sustained emptiness, not a single transient empty cycle on a healthy strap.
    private var emptySyncTracker = EmptySyncTracker()
    /// When true, SKIP arming the R10/R11 raw realtime stream on connect — the radio couldn't sustain
    /// it (see MarginalRadioDetector). Live HR then comes only from the already-subscribed low-bandwidth
    /// 0x2A37 standard-HR profile. Per-session: set by the detector, cleared on a clean reconnect (a
    /// connection that actually carried data) or when the user re-opens Live / taps Start HR.
    private var standardHRFallback = false
    /// Wall time we last armed the R10/R11 realtime burst this connection, to measure how soon a drop
    /// follows the arm (the marginal-radio tell). nil until armed; cleared on disconnect.
    private var realtimeArmedAt: Date?
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    private var backfillStarted = false
    /// Runs the connect handshake EXACTLY ONCE per connection. `didWriteValueFor` re-fires on every
    /// `.withResponse` write (the bond write, every SEND_HISTORICAL, every HISTORY_END ack); without
    /// this guard those re-entries re-blasted hello/SET_CLOCK at the strap mid-offload and stopped it
    /// from streaming type-47 — THE iOS "won't serve" root cause. Reset on disconnect.
    private var connectHandshakeDone = false
    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    private var rawCaptureInFlight = false
    /// Ordered queue of frames awaiting drain through the serial Backfiller task.
    private var backfillFrameQueue: [[UInt8]] = []
    /// True while the drain task is running (prevents a second drain task from launching).
    private var backfillDraining = false
    /// Keep each main-actor drain slice small enough that SwiftUI can process input/paint between slices.
    private static let backfillDrainBatchSize = 12

    /// Records WHOOP 5/MG puffin frames to a JSON file for protocol mapping. Passive (read-only on the
    /// strap) and gated by the Settings → Experimental "Record puffin frames" toggle; a no-op for
    /// WHOOP 4.0 and when the toggle is off. Lazy so it shares `state` after init. (Cherry-picked from
    /// @j0b-dev's PR #20.)
    private lazy var puffinRecorder = PuffinFrameRecorder(state: state)

    /// Force the puffin capture buffer to disk so the Settings export/reveal targets a current file.
    public func flushPuffinCaptures() { puffinRecorder.flush() }

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Multi-WHOOP: when non-nil, the scan/discover path connects ONLY to the peripheral whose
    /// `identifier == preferredPeripheralUUID` and ignores every other discovered WHOOP. When nil
    /// (the only state a single-WHOOP user is ever in) the discover path is byte-for-byte unchanged —
    /// it connects to the FIRST WHOOP discovered. Set by the app via `setPreferredPeripheral(_:)` to
    /// the active device's persisted `peripheralId`. Purely additive; nothing reads it on the nil path.
    private var preferredPeripheralUUID: UUID?
    /// Multi-WHOOP Add-a-WHOOP wizard: while true, `didDiscover` POPULATES `discoveredWhoops` instead
    /// of auto-connecting — an explicit, separate "present the nearby straps" mode the wizard turns on
    /// (`scanForWhoops()`) then off (`stopWhoopScan()`). Default false leaves the auto-connect path
    /// untouched. Must never overlap the normal connect flow (the wizard owns the central while true).
    private var isPresentingScan = false
    /// The CBPeripheral.identifier.uuidString of the WHOOP we most recently CONNECTED to (`didConnect`).
    /// Published so the app/AppModel can persist it onto the active registry device
    /// (`registry.setPeripheralId`) — letting "my-whoop" adopt its strap's id on first connect and a
    /// specific WHOOP confirm its identity. BLEManager stays decoupled: it never writes the registry.
    @Published public private(set) var connectedPeripheralUUID: String?
    /// Multi-WHOOP Add-a-WHOOP wizard surface: straps seen while `isPresentingScan` is true, WITHOUT
    /// auto-connecting. Cleared at the start of each `scanForWhoops()`. Empty/unused on the default path.
    @Published public private(set) var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] = []
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private var cmdNotifyCharacteristic: CBCharacteristic?
    private var eventNotifyCharacteristic: CBCharacteristic?
    private var dataNotifyCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    /// EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/4/5/7), remembered at discovery so we
    /// can re-subscribe them AFTER bonding — the strap refuses them ("Authentication is insufficient")
    /// until the link is encrypted (issue #17).
    private var whoop5NotifyCharacteristics: [CBCharacteristic] = []
    private var reassembler = Reassembler()
    private var seq: UInt8 = 0
    private var didBond = false
    /// WHOOP 5/MG only: realtime HR has been armed (puffin TOGGLE_REALTIME_HR sent) once for this
    /// connection, so the post-bond callback re-firing on later `.withResponse` writes doesn't re-send it.
    private var whoop5RealtimeArmed = false
    /// Once-per-connection guard for the 5/MG offload kick (connectHandshakeDone + requestSync +
    /// startBackfillTimer). Stops the HISTORY_END acks re-entering didWriteValueFor from re-triggering
    /// the offload mid-stream (the 5/MG twin of the WHOOP4 connectHandshakeDone ack-storm guard).
    private var whoop5SessionStarted = false
    /// Backfill ACKs can arrive hundreds or thousands of times in one offload. Keep the strap log
    /// readable and avoid forcing SwiftUI to auto-scroll on every ACK row.
    private var historicalAckLogCounter = 0
    private var clockRequested = false
    private var intentionalDisconnect = false
    /// The strap family the user chose to pair. Drives which service we scan for
    /// and which service we discover after connecting. Hydrated from the persisted
    /// pick so restoration/reconnect after a relaunch target the right strap.
    private var selectedModel: WhoopModel = .persisted
    private var lastStandardHRLogAt: Date?

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    /// Seeded from the init argument, then refined once in bootstrapStore() to the device registry's
    /// active id (still "my-whoop" today) before any store writes use it — see bootstrapStore().
    private(set) var deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?

    /// The strap's OWN clock extrapolated to right now (its RTC at the last GET_CLOCK + elapsed since).
    /// Used to judge live-gesture freshness in the strap's clock domain rather than wall time — so a
    /// real-time gesture is "now" and a replayed historical one is "old" REGARDLESS of how stale the
    /// strap RTC is (fix #72's straps). Falls back to wall-now when GET_CLOCK hasn't landed.
    private var strapClockNow: Int {
        let wallNow = Int(Date().timeIntervalSince1970)
        guard let ref = clockRef else { return wallNow }
        return ref.device + (wallNow - ref.wall)
    }

    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // WhoopStore.init is now async, so it can't run here.
        // bootstrapStore() is called once the CBCentralManager reaches poweredOn
        // (see centralManagerDidUpdateState), which guarantees the store is ready
        // before any BLE data arrives.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (foundation for M3 state restoration).
        #if os(iOS)
        // iOS background state preservation/restoration: the restore identifier is what makes
        // CoreBluetooth relaunch the app into the background and deliver willRestoreState after
        // a suspend-then-jettison. Without it, willRestoreState is never called.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil else { return }
        // Surface store-open failures instead of swallowing them with `try?` (#222): a silent failure
        // here left `backfiller` nil forever and the only visible symptom was the downstream
        // "store not ready" tick, with no clue why. On iOS a background reconnect that opens the
        // data-protected store while the device is locked throws SQLITE_IOERR/CANTOPEN — logging the
        // code proves it; the periodic tick (see beginBackfill) re-attempts so it self-heals on unlock.
        let path: String
        do {
            path = try StorePaths.defaultDatabasePath()
        } catch {
            log("Backfill: bootstrap FAILED resolving DB path — \(error)")
            return
        }
        let store: WhoopStore
        do {
            store = try await WhoopStore(path: path)
        } catch {
            let ns = error as NSError
            log("Backfill: bootstrap FAILED opening store — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return
        }
        // Route deviceId through the device registry: use the active device's id (migration v15 seeds
        // a single 'my-whoop' row as active, so this is still "my-whoop" today — zero behaviour change).
        // Guarded + best-effort: if the registry is empty/unreadable, deviceId stays as it was, so no
        // crash and no behaviour change. registryQueue is nonisolated/Sendable (GRDB-serialized).
        if let activeId = try? DeviceRegistryStore(dbQueue: store.registryQueue).activeDeviceId(),
           !activeId.isEmpty {
            self.deviceId = activeId
        }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        // The store can finish bootstrapping AFTER connect(model:) already ran (both wait on
        // poweredOn), so apply the family/clock configuration here too — whichever runs last wins.
        configureCollectorFamily()
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture,
                                log: { [weak self] s in self?.log(s) },
                                rejectedSink: { [weak self] frames, trim, family in
                                    self?.archiveRejectedFrames(frames, trim: trim, family: family) ?? true
                                },
                                onChunk: { [weak self] decoded, console in
                                    if decoded { self?.state.decodedChunksThisSession += 1 }
                                    if console { self?.state.consoleChunksThisSession += 1 }
                                })
        // Strand: no server uploader/sync — all data stays on-device.

        // Retro-decode: when the decoder gains a historical layout (e.g. WHOOP 4.0 v25), re-run every
        // archived undecodable frame through it and insert whatever now decodes — the only path by
        // which already-acked banked history backfills after an update. Run ONCE per app version (no
        // manual decoder-version constant to forget to bump); idempotent if it re-runs (rows dedupe
        // by ts) and the archive is small, so the once-per-update cost is negligible. (#152)
        // Note: the archive carries no deviceId, so replayed rows attribute to the current strap.
        let replayKey = "rejectArchiveReplayedAppVersion"
        if UserDefaults.standard.string(forKey: replayKey) != AppChangelog.currentVersion {
            do {
                let rows = try await rejectedHistoryArchive.replay(into: store, deviceId: deviceId)
                if rows > 0 { log("Backfill: retro-decoded \(rows) record(s) from the reject archive after an update.") }
                // Advance the gate ONLY on success — a failed insert must retry next launch, because
                // the archive holds the only surviving copy of these records. (#152)
                UserDefaults.standard.set(AppChangelog.currentVersion, forKey: replayKey)
            } catch {
                log("Backfill: reject-archive retro-decode deferred (store insert failed) — will retry next launch.")
            }
        }
    }

    /// Designated initializer for testing and preview use: accepts a pre-built Collector.
    init(state: LiveState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        self.collector = collector
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (mirrors the production initializer
        // so a restored manager matches by identifier; only exercised by tests/previews).
        #if os(iOS)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    // MARK: Public API
    public func connect(model: WhoopModel = .persisted) {
        intentionalDisconnect = false
        selectedModel = model
        // Frame the inbound stream for the chosen family (WHOOP 4.0 CRC8 vs WHOOP 5.0 CRC16/puffin)
        // and tell the router which decoder to use. Fresh per connection so no stale bytes carry over.
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        // Live 5/MG persistence: point the Collector's decode at the selected family and install the
        // identity clock ref for a 5/MG (its live timestamps are already real unix). WHOOP 4.0 keeps
        // the GET_CLOCK correlation flow untouched. Re-applied after bootstrapStore builds the
        // collector so whichever runs last wins.
        configureCollectorFamily()
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            return
        }
        if let p = peripheral, p.state == .connected {
            state.connected = true
            p.delegate = self
            log("Already connected to \(model.displayName) — refreshing services and notifications")
            discoverPrimaryServices(on: p)
            enableLiveNotifications(reason: "manual refresh")
            return
        }
        if let p = central.retrieveConnectedPeripherals(withServices: [model.scanService]).first {
            log("Found existing \(model.displayName) connection \(p.identifier) — attaching")
            preparePeripheral(p)
            if p.state == .connected {
                state.connected = true
                discoverPrimaryServices(on: p)
                enableLiveNotifications(reason: "attached connection")
            } else {
                central.connect(p, options: nil)
            }
            return
        }
        startScan(for: model, allowFallback: true)
    }

    public func disconnect() {
        intentionalDisconnect = true
        cancelScanFallback()
        // A user-initiated teardown is a clean slate: clear any #80 marginal-radio fallback so the next
        // (manual) reconnect attempts the full R10/R11 stream again rather than inheriting old suspicion.
        marginalRadio.reset()
        standardHRFallback = false
        state.standardHRMode = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
    }

    /// Switch which strap we'll connect to next: drop the current strap and clear the **sticky** bond
    /// state so a newly-picked model bonds fresh. `bonded` deliberately survives a disconnect (it means
    /// "this strap is paired"), but that left a user with BOTH a WHOOP 4 and a 5/MG unable to switch —
    /// `bonded` stayed true from the first strap, which hid the strap picker and kept the scan pointed at
    /// the old family's service. Call this when the user changes the strap selection.
    public func prepareForModelSwitch() {
        disconnect()
        state.connected = false
        state.bonded = false
        state.encryptedBond = false
    }

    // MARK: Multi-WHOOP (additive — inert on the single-WHOOP path)

    /// Pin connections to ONE specific strap by its CBPeripheral.identifier.uuidString. The app sets
    /// this to the active device's persisted `peripheralId` when it has one; pass nil to clear it
    /// (back to "connect to the first WHOOP discovered" — the single-WHOOP default). An unparseable
    /// string clears the pin rather than wedging the scan. Only `didDiscover` reads it; setting it
    /// does NOT start/stop/redirect an in-flight connection on its own.
    public func setPreferredPeripheral(_ uuidString: String?) {
        guard let uuidString, let uuid = UUID(uuidString: uuidString) else {
            preferredPeripheralUUID = nil
            return
        }
        preferredPeripheralUUID = uuid
    }

    /// Add-a-WHOOP wizard: scan the selected family's WHOOP service and surface every nearby strap in
    /// `discoveredWhoops` WITHOUT auto-connecting. Turns on the `isPresentingScan` flag that diverts
    /// `didDiscover` to collect-not-connect, and uses duplicate-allowing scanning so RSSI refreshes.
    /// The wizard MUST call `stopWhoopScan()` before any normal connect resumes — this mode owns the
    /// central while active. No-op-to-the-connect-path: it never touches `peripheral`/bond state.
    public func scanForWhoops() {
        guard central.state == .poweredOn else {
            log("Add-a-WHOOP scan: Bluetooth not powered on (state=\(central.state.rawValue))")
            return
        }
        cancelScanFallback()            // no family-rotation timer should fire during a present-scan
        isPresentingScan = true
        discoveredWhoops = []           // fresh list each time the wizard opens the scan
        central.stopScan()
        // Allow duplicates so the wizard's RSSI/signal readout updates as straps move.
        central.scanForPeripherals(
            withServices: [selectedModel.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("Add-a-WHOOP scan: presenting nearby \(selectedModel.displayName) straps")
    }

    /// End the Add-a-WHOOP present-scan: stop scanning and clear `isPresentingScan` so `didDiscover`
    /// returns to its normal auto-connect behaviour. Safe to call when not presenting (idempotent).
    public func stopWhoopScan() {
        guard isPresentingScan else { return }
        isPresentingScan = false
        central.stopScan()
        log("Add-a-WHOOP scan: stopped")
    }

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        // #314 parity: CoreBluetooth already covers both Android defects here — this `p.state == .connected`
        // guard makes a write a no-op once the radio powers off (no DeadObjectException to crash on), and
        // centralManagerDidUpdateState publishes state.connected = false on .poweredOff, so the iOS/macOS UI
        // can't show a stale-connected link. The Android fix re-creates both behaviours; no Swift change needed.
        guard state.connected, let p = peripheral, p.state == .connected, let ch = cmdCharacteristic else {
            let reason = state.connected ? "command characteristic unavailable" : "not connected"
            log("send(\(command.label)) ignored — \(reason)")
            return
        }
        // WHOOP 5.0/MG uses puffin (CRC16) command framing, not the WHOOP4 frame. The realtime-HR toggle
        // is hardware-confirmed (issue #17 — a 5/MG owner saw live HR over a public build), which proves
        // the strap does act on puffin-framed commands. We now also send haptics (buzz) and the
        // firmware-alarm family on that same proven transport. Everything else stays dropped.
        // WHOOP 4.0 is unaffected.
        if selectedModel.deviceFamily == .whoop5 {
            // Allowlist: live (toggle HR, buzz), the firmware-alarm family (set/get/run/disable —
            // same command numbers as WHOOP4 over puffin framing; the 5/MG REVISION_4/REVISION_2
            // bodies are built at the call sites and pad4 covers their 20-/2-byte bodies), the two
            // historical-offload commands, and the clock pair. SEND_HISTORICAL_DATA triggers the
            // offload; HISTORICAL_DATA_RESULT acks each HISTORY_END to walk the trim cursor.
            // SET_CLOCK/GET_CLOCK are MANDATORY before history: an un-clocked WHOOP 5 doesn't save
            // sensor data to flash at all ("RTC timestamp … is invalid; not saving data to flash"),
            // so offloads complete with zero body frames — hardware-validated, same 8-byte WHOOP4
            // payload over puffin framing. (#78 fork)
            guard command == .toggleRealtimeHR || command == .runHapticsPattern
                || command == .setAlarmTime || command == .getAlarmTime
                || command == .runAlarm || command == .disableAlarm
                || command == .sendHistoricalData || command == .historicalDataResult
                || command == .setClock || command == .getClock
                // SET_CONFIG (the R22 deep-stream unlock) is allowed ONLY while the deep-data
                // experiment is opted in — it writes a persistent feature flag to the strap, so it
                // must never fire on a default install. It's still reversible (just changes which
                // data the strap emits) and is what the official app sends. Driven only by
                // enableWhoop5DeepData(). (#174)
                || (command == .setConfig && PuffinExperiment.deepDataEnabled)
                // SET_DEVICE_CONFIG (the Broadcast-HR flag) is allowed ONLY while that opt-in is on —
                // it writes one persistent device-config value so the strap advertises standard HR.
                // Reversible; driven only by setBroadcastHr(_:). (#181)
                || (command == .setDeviceConfig && PuffinExperiment.broadcastHrEnabled) else {
                log("send(\(command.label)) skipped — no WHOOP 5/MG framing for this command yet")
                return
            }
            // WHOOP 5/MG haptics differ from WHOOP 4.0 on BOTH the opcode AND the payload (#48, decoded
            // from the working "maverick" app's binary). Opcode: 0x13, not RUN_HAPTICS_PATTERN=79 (a real-MG
            // capture showed the strap rejecting 79 with COMMAND_RESPONSE result=0x03). Payload: the maverick
            // haptic body [0x01, effects(8), loopControl(u16 LE), overallLoop] — here the "notify" preset
            // (effects 47,152), NOT the 4.0 [patternId, loops, …]. puffinCommandFrame pads the inner to a
            // 4-byte boundary, which this 12-byte payload needs. WHOOP 4.0 is untouched (79 + its own frame).
            let isHaptics = command == .runHapticsPattern
            let puffinCmd: UInt8 = isHaptics ? 0x13 : command.rawValue
            let puffinPayload: [UInt8] = isHaptics ? [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0] : payload
            seq = seq &+ 1
            let frame = puffinCommandFrame(cmd: puffinCmd, seq: seq, payload: puffinPayload)
            p.writeValue(Data(frame), for: ch, type: writeType)
            let cmdNote = isHaptics ? " cmd=0x13" : ""
            if command == .historicalDataResult {
                historicalAckLogCounter += 1
                if historicalAckLogCounter == 1 || historicalAckLogCounter.isMultiple(of: 25) {
                    log("→ \(command.label) ack #\(historicalAckLogCounter) payload=\(hex(puffinPayload)) (puffin)")
                }
                return
            }
            log("→ \(command.label) payload=\(hex(puffinPayload)) (puffin\(cmdNote))")
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        log("→ \(command.label) payload=\(hex(payload))")
    }

    /// Point the Collector's live decode at the selected family. For a 5/MG, also install an identity
    /// clock ref: live puffin REALTIME_DATA timestamps are already real-unix seconds, so device==wall
    /// makes toWall a no-op (the same idiom the Backfiller uses for 5/MG history). For a WHOOP 4.0 the
    /// collector takes the manager's GET_CLOCK correlation (nil until it lands — the normal 4.0 flow);
    /// this also evicts a stale identity ref a prior 5/MG session installed when the user switches
    /// straps, which would otherwise mis-stamp WHOOP4 device-epoch frames as wall-clock. Idempotent;
    /// called from connect() AND after the async store bootstrap builds the collector, so the
    /// configuration lands regardless of which finishes first.
    private func configureCollectorFamily() {
        collector?.family = selectedModel.deviceFamily
        if selectedModel.deviceFamily == .whoop5 {
            let now = Int(Date().timeIntervalSince1970)
            collector?.clockRef = ClockRef(device: now, wall: now)
        } else {
            collector?.clockRef = clockRef   // the WHOOP4 correlation, nil until GET_CLOCK lands
        }
    }

    /// Refresh the battery reading on demand. Source is FAMILY-SPECIFIC (#77): on a WHOOP 4.0 the
    /// standard 0x2A19 characteristic is a STUB that reports a constant 100 — the real charge only
    /// comes from the proprietary GET_BATTERY_LEVEL command (COMMAND_RESPONSE, u16/10). Reading both
    /// flashed 100% before the true value corrected it (and a stub notification could revert a real
    /// 94% back to 100%). So WHOOP 4 uses ONLY the command; WHOOP 5/MG uses ONLY 0x2A19.
    public func refreshBattery() {
        guard state.connected, let p = peripheral, p.state == .connected else {
            log("refreshBattery ignored — not connected")
            return
        }

        if selectedModel.deviceFamily == .whoop4 {
            send(.getBatteryLevel, payload: [0x00])
            return
        }

        if let batteryCharacteristic {
            if batteryCharacteristic.properties.contains(.read) {
                p.readValue(for: batteryCharacteristic)
                log("Reading standard Battery Level")
            } else {
                log("Battery Level read unavailable; waiting for notifications")
            }
        } else {
            log("Battery Level characteristic unavailable")
        }
    }

    /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
    /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
    ///
    /// High-freq-sync ack form (matches re/sync_openwhoop.py, which pulled 762 type-47 records):
    /// HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where end_data is the verbatim
    /// 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at [10:14] + next u32 at [14:18]).
    /// The `trim` argument (= end_data first u32) is already persisted as the strap_trim cursor by
    /// the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
        // Progress signal for the "Syncing strap history…" UI (#77). Same main-queue delegate path as
        // the other state mutations (e.g. lastSyncedAt in exitBackfilling). NOT historicalAckLogCounter
        // — that's a puffin-write log throttle that never increments on WHOOP 4.
        state.syncChunksThisSession += 1
    }

    // MARK: Backfill helpers

    /// Start a historical-offload session: tell the store machine to begin, flip the routing
    /// flag, kick the strap with sendHistoricalData, and arm the idle timeout.
    @discardableResult
    private func beginBackfill() -> Bool {
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return false
        }
        guard let backfiller else {
            // Store not built yet (bootstrapStore failed or hasn't run). Do NOT force live HR — the
            // type-47 backfill is the metric source. RE-ATTEMPT the bootstrap here so a transient
            // first-open failure self-heals: on iOS the data-protected store is unreadable while the
            // phone is locked, so a background-reconnect bootstrap can fail and, with no retry, stay
            // dead forever (#222). Each periodic tick now retries; the first one that runs after the
            // device is unlocked rebuilds the store and backfill proceeds. bootstrapStore() guards on
            // `collector == nil`, so this is a no-op once the store is up.
            log("Backfill: store not ready — re-attempting bootstrap, will retry next tick")
            Task { @MainActor in await self.bootstrapStore() }
            return false
        }
        // Capture the family at begin() (not init): selectedModel is reliably set by connect() before any
        // backfill starts, whereas bootstrapStore() can build the Backfiller before the family is known.
        backfiller.begin(family: selectedModel.deviceFamily)
        backfilling = true
        state.backfilling = true
        state.syncChunksThisSession = 0
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        historicalAckLogCounter = 0
        // Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
        // [0x00] (empty → 0 frames on a clean stable link with ~2k records pending); the Mac ground-truth
        // offload (re/sync_openwhoop.py, re/diagnose_biometrics.py) uses [0x00] too. Plain offload — the
        // strap streams HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE.
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
        return true
    }

    /// Feed a frame to the Backfiller preserving exact arrival order. Frames are appended
    /// synchronously (delegate order) and drained sequentially in small slices, so START /
    /// data / END chunk assembly is never reordered while the UI still gets time to paint.
    private func routeBackfillFrame(_ frame: [UInt8]) {
        backfillFrameQueue.append(frame)
        guard !backfillDraining else { return }
        backfillDraining = true
        Task { @MainActor in await drainBackfillFrames() }
    }

    private func drainBackfillFrames() async {
        while !backfillFrameQueue.isEmpty {
            let count = min(Self.backfillDrainBatchSize, backfillFrameQueue.count)
            let batch = Array(backfillFrameQueue.prefix(count))
            backfillFrameQueue.removeFirst(count)

            for f in batch {
                await backfiller?.ingest(f)
                afterBackfillIngest()
                if !backfilling {
                    backfillFrameQueue.removeAll(keepingCapacity: true)
                    break
                }
            }

            if !backfillFrameQueue.isEmpty {
                await Task.yield()
            }
        }
        backfillDraining = false
    }

    /// Called after every Backfiller.ingest completes. If the Backfiller has consumed all
    /// historical data (isBackfilling drops to false), exit the backfill session cleanly.
    private func afterBackfillIngest() {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        exitBackfilling(reason: "HISTORY_COMPLETE")
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49 / puffin METADATA=56, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
        // (the puffin envelope is 4 bytes longer). Reading frame[4] for a puffin frame misclassifies
        // EVERY offload frame as live-flood and routes nothing to the Backfiller.
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex else { return false }
        switch frame[typeIndex] {
        case 47, 48, 49, 50, 56: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Re-arm the idle watchdog. Called on every offload frame during backfill so the timer resets
    /// as long as the strap keeps sending HISTORY; if the strap goes silent the timer fires and we
    /// exit the session (the durable strap_trim cursor means the next session resumes where we left
    /// off). Timeout is generous (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE
    /// airtime, so genuine offload frames can arrive in bursts with multi-second lulls between chunks
    /// — a short watchdog cut sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60
    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.backfillIdleTimeoutSeconds), execute: item)
    }

    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only (the
    /// manual "Start HR" button in LiveView). Between backfills the Collector sees only the live
    /// type-43 flood, which extractStreams ignores — the data comes from the next periodic offload.
    private func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        state.backfilling = false
        // #174: a backfill just ended. Start (or extend) the deep-packet cooldown from this instant so
        // any type-0x2F records the strap flushes in the seconds after the session aren't miscounted as
        // the live R22 stream — they're the offload's tail.
        lastOffloadFrameAt = Date()
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        log("Backfill: session ended — reason=\(reason)")
        // Success-side summary (#150 forensics): we logged failures (decoded-to-0) but never successes,
        // so a strap log couldn't tell a banking strap from a broken one. Emit the per-session persistence
        // tally whenever anything actually landed — the win-rate signal a log previously lacked.
        if let bf = backfiller,
           let summary = Backfiller.sessionSummaryLine(rows: bf.sessionRowsPersisted, motion: bf.sessionMotionRows, nights: bf.sessionNights) {
            log(summary)
        }
        // Honest sync outcome for a cloud-free user (mirrors Android exitBackfilling, ed6a31d):
        // HISTORY_COMPLETE stamps lastSyncedAt + clears any error; the idle-watchdog timeout surfaces
        // a non-silent error. A disconnect mid-sync bypasses this path (didDisconnectPeripheral resets
        // the flags directly) — that's not a sync failure, and the next connect re-offloads.
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            // #77 / #91: a sync that COMPLETED but discarded records must not read as a clean
            // "History synced" — the wording distinguishes bytes saved on this Mac from bytes the
            // full archive could not preserve, so "saved" is never claimed falsely.
            let archived = state.rejectedFramesThisSession
            let unarchived = state.rejectedFramesUnarchived
            // Classify this completed offload (pure, unit-tested in EmptyBankingClassifierTests).
            let banking = BLEManager.classifyCompletedOffload(
                decodedChunks: state.decodedChunksThisSession,
                archivedFrames: archived,
                unarchivedFrames: unarchived,
                consoleChunks: state.consoleChunksThisSession,
                rowsPersisted: backfiller?.sessionRowsPersisted ?? 0)
            let bankedSensorRecords = banking.bankedSensorRecords
            let bankedNothing = banking.bankedNothing
            let sustainedEmpty = emptySyncTracker.recordCompletedSync(
                bankedSensorRecords: bankedSensorRecords, consoleOnly: bankedNothing)
            if unarchived > 0 {
                state.lastSyncError = "Synced, but \(archived + unarchived) record(s) couldn't be decoded (unrecognised strap firmware layout), and the on-device archive is full — the \(unarchived) newest weren't preserved. Please share a strap log so the layout can be mapped."
            } else if archived > 0 {
                state.lastSyncError = "Synced, but \(archived) record(s) couldn't be decoded (unrecognised strap firmware layout). The raw bytes were saved on this Mac — please share a strap log so the layout can be mapped."
            } else if bankedNothing {
                // #77 / #214 family: the offload COMPLETED but the strap handed over no sensor records
                // at all — either console/diagnostic output across many chunks, OR a near-empty
                // metadata-only completion (zero rows persisted) — i.e. it isn't banking history to
                // flash (its RTC has lost sync). Only escalate to the actionable banner once emptiness
                // is SUSTAINED (#126): a single empty cycle on an otherwise-banking strap stays silent.
                let detail = state.consoleChunksThisSession >= 3
                    ? "console-only across \(state.consoleChunksThisSession) chunks"
                    : "metadata-only, 0 sensor rows persisted"
                log("Backfill: completed but the strap banked no sensor history (\(detail)); consecutive empty syncs = \(emptySyncTracker.consecutiveEmptySyncs).")
                state.lastSyncError = sustainedEmpty
                    ? "Synced, but your strap had no stored history to hand over — only its diagnostic output. This usually means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then reconnect, and it should start banking again."
                    : nil
            } else {
                state.lastSyncError = nil
            }
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
        } else if reason == "timeout" {
            state.lastSyncError = "Sync interrupted — the strap went quiet. It will retry on the next sync."
        }
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
    }

    /// On-device archive for HISTORICAL_DATA record frames that failed decode (#77 / #91).
    private let rejectedHistoryArchive = RawHistoryArchive()

    /// Durably archive undecodable record frames (append-only JSONL, fsynced) BEFORE the Backfiller
    /// acks the trim — the user's only remaining copy of an unmapped firmware's records once the
    /// strap frees them, and the corpus a later layout mapping re-ingests. Updates the session
    /// counters that drive the honest sync status. Returns false ONLY on a genuine write failure,
    /// which makes the Backfiller hold the cursor/ack so the strap re-sends the chunk (no data loss
    /// either way). Frames carry sensor payloads, not identifiers — no serials/MACs are archived.
    private func archiveRejectedFrames(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Bool {
        switch rejectedHistoryArchive.archive(frames, trim: trim, family: family) {
        case .written(let count):
            state.rejectedFramesThisSession += count
            return true
        case .capReached(let count):
            // Cap reached: succeed WITHOUT writing (wedging the offload over a full archive would be
            // worse; ample sample bytes exist by now), counted separately so the sync status never
            // claims "saved" for bytes that were not.
            state.rejectedFramesUnarchived += count
            log("Backfill: rejected-frame archive is FULL — \(count) frame(s) NOT preserved (acking anyway so the offload can finish)")
            return true
        case .failed:
            log("Backfill: rejected-frame archive FAILED — holding ack so the strap re-sends")
            return false
        }
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                sendSetClockBothForms()
            }
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + bonded and NOT already mid-backfill. Extracted so the gate is unit-testable
    /// without a CoreBluetooth seam. Note this intentionally does NOT consult `backfillStarted`
    /// (that flag guards the once-per-connect INITIAL kick); the periodic re-trigger is separate.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// Pure classification of a COMPLETED (HISTORY_COMPLETE) offload, extracted from exitBackfilling so
    /// it's unit-testable without a CoreBluetooth seam (EmptyBankingClassifierTests).
    /// - `bankedSensorRecords`: the strap handed over real sensor records — decoded, or
    ///   undecodable-but-archived (either way its clock is banking to flash).
    /// - `bankedNothing` (#77/#120/#214): the offload completed but banked NO sensor records at all,
    ///   in EITHER shape — console-only across ≥3 diagnostic chunks, OR a near-empty metadata-only
    ///   completion (zero rows persisted) with fewer than 3 console frames. The #214 broadening is the
    ///   `rowsPersisted == 0` arm: before it, a metadata-only completion slipped through silently. The
    ///   sustained-streak gate (EmptySyncTracker) still decides whether the banner fires.
    nonisolated static func classifyCompletedOffload(decodedChunks: Int, archivedFrames: Int,
                                                     unarchivedFrames: Int, consoleChunks: Int,
                                                     rowsPersisted: Int)
        -> (bankedSensorRecords: Bool, bankedNothing: Bool) {
        let bankedSensorRecords = decodedChunks > 0 || archivedFrames > 0 || unarchivedFrames > 0
        let bankedNothing = !bankedSensorRecords && (consoleChunks >= 3 || rowsPersisted == 0)
        return (bankedSensorRecords, bankedNothing)
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    // MARK: - Keep-alive (always-ping + liveness watchdog)

    /// Enable live HR and remember we want it re-armed by keep-alive.
    /// Some WHOOP firmware acknowledges TOGGLE_REALTIME_HR but only emits usable live samples once
    /// the R10/R11 realtime stream is also on. Keep that stream scoped to the Live tab and stop it
    /// on disappear so it does not permanently compete with historical offload.
    public func startRealtime() {
        screenWantsRealtime = true
        state.liveFeedActive = true   // drives the menu-bar Start/Stop label off the real intent
        // The user explicitly (re-)asked for the full stream by opening Live / tapping Start HR — give the
        // heavy R10/R11 burst another chance even if a prior marginal-radio fallback had tripped. If the
        // radio still can't take it, the detector will simply trip again. (#80) This is screen-only intent;
        // the continuous-capture path does NOT reset the fallback (it's a passive background want).
        marginalRadio.reset()
        standardHRFallback = false
        state.standardHRMode = nil
        enableLiveNotifications(reason: "start realtime")
        send(.sendR10R11Realtime, payload: [0x01])   // the heavy burst rides alongside the toggle on Live
        reconcileRealtime()                          // arms TOGGLE_REALTIME_HR(1) on the off→on edge
        realtimeArmedAt = Date()       // start the arm→drop stopwatch for the marginal-radio detector
    }
    /// Stop the Live-tab realtime streams. The lightweight 0x2A37 HR keeps recording if firmware emits it.
    /// The TOGGLE only actually disarms if the continuous-capture preference no longer wants it either —
    /// the reconciler sends it on the on→off edge of the combined want, so a Live screen closing while
    /// continuous capture is on keeps the dense stream flowing.
    public func stopRealtime() {
        screenWantsRealtime = false
        state.liveFeedActive = false   // flip the menu-bar toggle back to "Start live feed"
        // Always stop the heavy R10/R11 burst when the Live screen leaves — it's the battery-hungry part
        // and is only ever wanted while a live screen is up. The lightweight TOGGLE/0x2A37 R-R stream is
        // what continuous capture keeps; the reconciler decides whether to disarm that.
        send(.sendR10R11Realtime, payload: [0x00])
        reconcileRealtime()
    }

    /// The "Continuous HRV capture" preference flipped: hold the realtime stream open with no Live screen
    /// visible (true) or release it (false), then reconcile. Driven from the app model. Mirrors the
    /// Android `setKeepStreamForData`.
    public func setKeepRealtimeForData(_ keep: Bool) {
        keepRealtimeForData = keep
        reconcileRealtime()
    }

    /// Single reconciler for the realtime-HR TOGGLE. The stream should be armed while EITHER a screen
    /// wants it (`screenWantsRealtime`) OR the continuous-capture preference wants it
    /// (`keepRealtimeForData`). We arm (TOGGLE_REALTIME_HR 1) / disarm (TOGGLE_REALTIME_HR 0) ONLY on the
    /// false↔true edge of that derived want — so a Live screen closing while the preference still wants
    /// it does NOT disarm, and turning the preference off with no screen open DOES disarm. The toggle only
    /// reaches the strap once it's a WHOOP4 (custom channels open immediately) or a bonded 5/MG (puffin
    /// framing); otherwise the want is remembered and the post-bond branch arms it. Mirrors the Android
    /// `reconcileRealtime`.
    private func reconcileRealtime() {
        let want = screenWantsRealtime || keepRealtimeForData
        wantsRealtime = want   // keep-alive + post-bond arm-on-connect read this derived value
        guard want != realtimeArmed else { return }                      // no edge — nothing to send
        guard selectedModel.deviceFamily == .whoop4 || state.bonded else { return }   // can't reach the strap yet
        realtimeArmed = want
        send(.toggleRealtimeHR, payload: [want ? 0x01 : 0x00])
    }

    /// EXPERIMENTAL R22 telemetry (#174): give the user (and us) live proof of what the strap is doing.
    /// (1) Every `COMMAND_RESPONSE` (type 0x24) to a `SET_CONFIG` (0x78) is the strap ACKing one
    ///     `enable_r22_*` flag — hardware-confirmed in sebastianwoo's capture. 15 ACKs = full acceptance.
    /// (2) A type-0x2F record arriving OUTSIDE a history offload is the R22 deep biometric stream
    ///     actually flowing in realtime — the prize. (During an offload, type-0x2F is just banked
    ///     history, already handled by the Backfiller, so we only count the live ones.)
    /// Frame layout (5/MG puffin envelope): packet_type @ byte 8, the responded-to cmd @ byte 10.
    ///
    /// #174 cooldown: when an offload ENDS, the strap can keep flushing a few trailing type-0x2F
    /// records AFTER `backfilling` has already flipped false. Those are tail-end HISTORY, not live —
    /// counting them as "live deep packets" was a false positive. So we stamp `lastOffloadFrameAt` on
    /// every offload frame (and at HISTORY_COMPLETE) and refuse to count a non-offload 0x2F as live
    /// within `deepPacketLiveCooldownSeconds` of it. The flag-ACK counting (1) is unchanged.
    private func noteWhoop5R22Telemetry(_ frame: [UInt8], duringOffload: Bool) {
        guard frame.count > 10 else { return }
        if frame[8] == 0x24, frame[10] == WhoopCommand.setConfig.rawValue {
            state.r22FlagsAccepted += 1
            let total = Whoop5Config.enableR22Sequence.count
            if state.r22FlagsAccepted == total {
                log("Deep-data: strap ACCEPTED all \(total)/\(total) R22 flags ✓ — keep it on; watching for deep packets.")
            }
        }
        if frame[8] == 0x2F {
            if duringOffload {
                // Trailing-history reference point: a 0x2F arriving during the offload is banked
                // history (handled by the Backfiller). Remember when it landed so the cooldown below
                // can discount the few that dribble in just after the session ends.
                lastOffloadFrameAt = Date()
                return
            }
            // Cooldown guard: a 0x2F within deepPacketLiveCooldownSeconds of the last offload
            // frame/HISTORY_COMPLETE is a trailing historical record, not the live R22 stream.
            if let last = lastOffloadFrameAt,
               Date().timeIntervalSince(last) < BLEManager.deepPacketLiveCooldownSeconds {
                return
            }
            state.deepPacketsThisSession += 1
            if state.deepPacketsThisSession == 1 {
                log("Deep-data: 🎯 FIRST live deep (R22, type-0x2F) packet received — this is it. Please keep wearing it and share your strap log on #174.")
            } else if state.deepPacketsThisSession.isMultiple(of: 50) {
                log("Deep-data: \(state.deepPacketsThisSession) live deep (type-0x2F) packets this session.")
            }
        }
    }

    /// EXPERIMENTAL (#174): write the official app's `enable_r22_*` SET_CONFIG sequence to a bonded
    /// WHOOP 5/MG, to switch on the deep biometric (type-0x2F "R22") streams the strap withholds from a
    /// fresh third-party connection. The exact 15-flag sequence + values are documented by judes.club
    /// and Asherlc/dofek and built byte-for-byte by `Whoop5Config` (golden-frame unit-tested).
    ///
    /// Safety: only ever runs when the deep-data experiment is explicitly opted in AND the strap is a
    /// bonded, worn 5/MG. The R22 stream is on-wrist gated, so an off-wrist strap is refused with a hint.
    /// Each flag is one `.setConfig` write WITH RESPONSE, spaced ~80 ms (the official app pauses between
    /// writes). Reversible — it only changes which data the strap emits. After it runs, the user should
    /// wear + sync and share their strap log so we can confirm the deeper records start flowing.
    public func enableWhoop5DeepData() {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Deep-data: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard PuffinExperiment.deepDataEnabled else {
            log("Deep-data: the deep-data experiment is off — enable it in Settings → Experimental first."); return
        }
        guard state.connected, state.encryptedBond else {
            // The R22 SET_CONFIG writes go over the encrypted command channel, so the live-HR-only
            // shortcut (`bonded` true, `encryptedBond` false on a 5/MG still owned by the official app,
            // #69/#266) can't carry them. Require the genuine bond, or the writes silently fail (#269).
            log("Deep-data: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to NOOP first — ignored."); return
        }
        guard state.worn else {
            log("Deep-data: the R22 stream is on-wrist only — put the strap ON, then try again."); return
        }
        state.r22FlagsAccepted = 0   // fresh attempt — count this send's ACKs from zero
        let frames = Whoop5Config.enableR22Sequence
        log("Deep-data: sending the \(frames.count)-flag enable_r22 sequence (experimental, reversible)…")
        for (i, flag) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * i)) { [weak self] in
                guard let self else { return }
                self.send(.setConfig,
                          payload: [0x01] + Whoop5Config.payloadBody(name: flag.name, value: flag.value),
                          writeType: .withResponse)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * frames.count + 200)) { [weak self] in
            self?.log("Deep-data: sequence sent. Keep the strap on, let it sync, then share your strap log — we're looking for new deep records (type-0x2F) to start arriving. (#174)")
        }
    }

    /// EXPERIMENTAL (#181): make a bonded WHOOP 5/MG advertise its heart rate as a standard BLE HR
    /// sensor (0x180D + the live HR in its manufacturer data) by writing the device-config flag
    /// `whoop_live_hr_in_adv_ind_pkt` = "1" (on) / "0" (off) via SET_DEVICE_CONFIG (0x77). With it on, a
    /// Garmin (Edge/watch), Zwift or gym HR client can pair to the WHOOP directly during a workout.
    /// Validated on real hardware (paired on a Garmin Edge 840). Opt-in, reversible; unlike R22 it is NOT
    /// on-wrist gated. Re-applied on each 5/MG connection. iOS/Android only (macOS can't bond a 5/MG).
    public func setBroadcastHr(_ on: Bool) {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Broadcast HR: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard state.connected, state.bonded else {
            log("Broadcast HR: connect and bond a 5/MG strap first — ignored."); return
        }
        let value: UInt8 = on ? 0x31 : 0x30   // ASCII '1' / '0'
        send(.setDeviceConfig,
             payload: [0x01] + Whoop5Config.deviceConfigBody(name: "whoop_live_hr_in_adv_ind_pkt", value: value),
             writeType: .withResponse)
        log("Broadcast HR: wrote whoop_live_hr_in_adv_ind_pkt=\(on ? "1" : "0")")
    }

    /// Read the strap's current BLE advertising name (WHOOP 4.0 / Harvard). The reply lands as a
    /// GET_ADVERTISING_NAME COMMAND_RESPONSE and FrameRouter publishes it to `LiveState.advertisingName`.
    /// Also sent automatically in the connect handshake; this is the manual refresh the Settings card
    /// fires after a rename. No-op on a 5/MG (the Harvard name command isn't part of its framing).
    public func requestAdvertisingName() {
        guard selectedModel.deviceFamily == .whoop4 else {
            log("Strap name: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected else { log("Strap name: not connected — ignored."); return }
        send(.getAdvertisingNameHarvard, payload: [0x00])
    }

    /// Rename the strap's BLE advertising name (WHOOP 4.0 / Harvard) via SET_ADVERTISING_NAME (cmd 77).
    /// Writes `[0x00,0x00] + UTF-8 name + [0x00]` (see `WhoopCommand.advertisingNamePayload`) over the
    /// confirmed command channel; the strap reboots to apply, so the new name appears on the next connect
    /// (the connect handshake re-reads it). The result ack is surfaced via `LiveState.renameStatus`.
    /// WHOOP 4.0 only — a 5/MG uses puffin framing and a different device-config path. Reversible.
    public func renameStrap(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedModel.deviceFamily == .whoop4 else {
            state.renameStatus = "Renaming is WHOOP 4.0 only."
            log("Strap rename: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected, state.bonded else {
            state.renameStatus = "Connect and pair your strap first."
            log("Strap rename: connect + bond first — ignored."); return
        }
        guard !name.isEmpty else {
            state.renameStatus = "Enter a name first."; return
        }
        state.renameStatus = "Renaming…"
        send(.setAdvertisingNameHarvard,
             payload: WhoopCommand.advertisingNamePayload(name),
             writeType: .withResponse)
        log("Strap rename: wrote advertising name=\(name.debugDescription)")
        // Re-read shortly after so the card reflects the change if the strap applies it without dropping
        // the link; if it reboots instead, the connect handshake re-reads the name on reconnect anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.requestAdvertisingName()
        }
    }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        enableLiveNotifications(reason: "keepalive")
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled.
        // Bounce the connection — the auto-rescan on disconnect re-bonds and resumes streaming.
        if Date().timeIntervalSince(lastDataAt) > 120 {
            log("No data for >120s — bouncing link to resume streaming")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        // The command pings below are WHOOP4-framed; a 5/MG link drops them at the send() guard, so
        // skip them for 5/MG (it keeps the experimental strap log clean — re-subscribe + the 120s
        // bounce above are what keep a 5/MG link healthy).
        guard selectedModel.deviceFamily == .whoop4 else { return }
        // Never re-arm the heavy R10/R11 burst once the marginal-radio fallback has tripped (#80) — that
        // would just re-trigger the drop the keep-alive is meant to prevent. 0x2A37 keeps the HR flowing.
        if wantsRealtime && !standardHRFallback {
            realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the re-arm
            send(.sendR10R11Realtime, payload: [0x01])
            send(.toggleRealtimeHR, payload: [0x01])
        }   // re-arm so it can't lapse
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }  // ~every 60s
    }

    private func startBackfillTimer() {
        backfillTimer?.cancel()
        let interval = BLEManager.backfillIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.triggerPeriodicBackfill() }
        t.resume()
        backfillTimer = t
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last,
                                       emptyStreak: emptySyncTracker.consecutiveEmptySyncs) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        if beginBackfill() {
            UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        }
    }

    /// Periodic-timer callback: routes through the rate-limited requestSync entry point.
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }

    // MARK: Helpers
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func preparePeripheral(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        resetCharacteristics()
    }

    private func discoverPrimaryServices(on p: CBPeripheral) {
        p.discoverServices([
            selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
        ])
    }

    private func resetCharacteristics() {
        cmdCharacteristic = nil
        cmdNotifyCharacteristic = nil
        eventNotifyCharacteristic = nil
        dataNotifyCharacteristic = nil
        heartRateCharacteristic = nil
        batteryCharacteristic = nil
        whoop5NotifyCharacteristics.removeAll()
    }

    /// Start a service-filtered scan for `model`, re-framing the inbound stream for its family (so a
    /// fallback rotation decodes the strap it actually finds, not the family we started from). When
    /// `allowFallback` is true, schedule a one-shot rotation to the other WHOOP family after
    /// `scanFallbackDelaySeconds` of no discovery — recovers reconnect when the persisted preference is
    /// stale after an update/restore. Discovery/connect cancels the pending rotation. (PR#195)
    private func startScan(for model: WhoopModel, allowFallback: Bool) {
        cancelScanFallback()
        selectedModel = model
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        configureCollectorFamily()
        central.stopScan()
        log("Scanning for \(model.displayName)…")
        central.scanForPeripherals(
            withServices: [model.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        guard allowFallback else { return }
        let fallback = model.fallbackScanModel
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.central.isScanning, !self.state.connected else { return }
            self.log("No \(model.displayName) found yet — trying \(fallback.displayName)")
            self.startScan(for: fallback, allowFallback: true)
        }
        scanFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BLEManager.scanFallbackDelaySeconds,
            execute: work
        )
    }

    private func cancelScanFallback() {
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
    }

    private func enableLiveNotifications(reason: String) {
        guard let p = peripheral, p.state == .connected else { return }
        let chars = [
            cmdNotifyCharacteristic,
            eventNotifyCharacteristic,
            dataNotifyCharacteristic,
            heartRateCharacteristic,
            batteryCharacteristic,
        ].compactMap { $0 }
        for c in chars where !c.isNotifying {
            requestNotify(c, on: p, reason: reason)
        }
    }

    private func requestNotify(_ c: CBCharacteristic, on p: CBPeripheral, reason: String) {
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            log("Notify unavailable \(c.uuid) (\(reason))")
            return
        }
        if c.isNotifying {
            log("Notify already active \(c.uuid) (\(reason))")
            return
        }
        p.setNotifyValue(true, for: c)
        log("Notify requested \(c.uuid) (\(reason))")
    }

    // MARK: Alarm API (M6 — additive; does NOT touch connect/offload/sync flows)

    /// Arm the strap's firmware alarm for `date` (UTC).
    ///
    /// WHOOP 4.0 sequence: SET_CLOCK first to ensure the strap RTC is UTC-correct, then the
    /// rev-1 SET_ALARM_TIME. WHOOP 5/MG sends the REVISION_4 body alone — the strap maintains
    /// its RTC (set during the connect handshake / history sync) and the official app's alarm
    /// path doesn't re-set it (wire observation; mirrors Android WhoopBleClient.armStrapAlarm).
    /// Either way the strap will buzz at `date` even if the app is backgrounded or force-quit
    /// (event STRAP_DRIVEN_ALARM_EXECUTED=57). This is the only alarm path: the strap fires at
    /// the fixed time — NOOP has no light-sleep early-wake layer.
    ///
    /// EXPERIMENTAL / UNCONFIRMED on 5/MG (same posture as the Android client): the byte-identical
    /// Android rev-4 frame has been ACKed by a real 5/MG when arming, but a strap-driven wake fire
    /// has NOT been captured on our side (no STRAP_DRIVEN_ALARM_EXECUTED event observed yet) — do
    /// not present the 5/MG alarm as guaranteed until one is.
    func armStrapAlarm(at date: Date) {
        // Log the wake time in the user's LOCAL zone. `Date` prints in UTC by default, so an alarm
        // for (say) 07:00 in New York logged as "11:00:00 +0000" reads like a timezone bug — but it
        // isn't: SET_ALARM_TIME carries the absolute instant of the chosen local time, and the strap
        // fires at that instant regardless of how its UTC RTC is labelled.
        let localFmt = DateFormatter()
        localFmt.dateFormat = "EEE HH:mm zzz"
        if selectedModel.deviceFamily == .whoop5 {
            // The 5/MG firmware alarm is unconfirmed (arming ACKs, but the wake actually FIRING is not
            // verified), so only arm it when the user has opted into Experimental — matching the Android
            // client, which refuses to arm it otherwise. Without this a normal 5/MG user is silently
            // armed onto an alarm that may never fire.
            guard PuffinExperiment.isEnabled else {
                log("Alarm: 5/MG firmware alarm needs the Experimental toggle (unconfirmed) — not armed")
                return
            }
            // 5/MG SET_ALARM_TIME is REVISION_4: [04][id][u32 sec][u16 subsec][12-byte 47/152
            // pattern, overallLoop 7, 30 s]. No SET_CLOCK preamble (see doc comment above).
            let wakeMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
            send(.setAlarmTime, payload: AlarmPayload.setAlarmRev4(wakeEpochMs: wakeMs))
            log("Alarm: armed 5/MG rev4 for \(localFmt.string(from: date)) — your local wake time")
            return
        }
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        sendSetClockBothForms()
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        log("Alarm: armed for \(localFmt.string(from: date)) — your local wake time (sent as UTC epoch \(epochSec))")
    }

    /// Disarm the currently-armed firmware alarm.
    func disableStrapAlarm() {
        if selectedModel.deviceFamily == .whoop5 {
            // 5/MG DISABLE_ALARM is REVISION_2 [0x02, 0xFF]; the rev-1 [0x01] form below is WHOOP4.
            send(.disableAlarm, payload: AlarmPayload.disableRev2())
            log("Alarm: disarmed (5/MG rev2)")
            return
        }
        send(.disableAlarm, payload: [0x01])
        log("Alarm: disarmed")
    }

    /// Request the currently-armed alarm time from the strap (response arrives on cmd-notify char).
    /// Parsing the reply is optional/bonus — the raw bytes will appear in the BLE log.
    func getStrapAlarm() {
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// Fire an immediate alarm buzz on the strap for testing.
    ///
    /// Uses RUN_HAPTICS_PATTERN (cmd 79) with patternId=2, 3 loops — the same pattern the official
    /// WHOOP app uses for alarms (verified: patternId=2, observed for interoperability), plus RUN_ALARM
    /// (cmd 68) as a belt-and-suspenders. patternId=2 gives the characteristic graduated alarm buzz.
    ///
    /// Alternative waveform form (12-byte):
    ///   [wfe1=47, wfe2=152, 0,0,0,0,0,0, loop u16=0, overall_loop=7, dur=30]
    /// — note for future refinement; the preset id=2 form is simpler and confirmed to buzz on-device.
    ///
    /// Haptic firing cannot be verified in the simulator (no strap motor). Test on-device only.
    func testAlarmBuzz() {
        send(.runHapticsPattern, payload: [2, 3, 0, 0, 0])  // patternId=2, 3 loops (5/MG: send() remaps to the maverick notify buzz)
        if selectedModel.deviceFamily == .whoop5 {
            send(.runAlarm, payload: AlarmPayload.runAlarmRev2())   // REVISION_2 [0x02, alarmId]
            log("Alarm: test buzz fired (5/MG maverick buzz + runAlarm rev2)")
            return
        }
        send(.runAlarm, payload: [0x01])
        log("Alarm: test buzz fired (patternId=2, runAlarm)")
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else {
            log("HR notify parse failed: \(hex(data))")
            return
        }
        let now = Date()
        if lastStandardHRLogAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            lastStandardHRLogAt = now
            let plausibility = (30...220).contains(m.hr) ? "" : " ignored"
            log("HR notify: \(m.hr) bpm\(plausibility), rr=\(m.rr.count)")
        }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present. setRRIntervals also
        // feeds the Live console's rolling rrRecent buffer.
        if !m.rr.isEmpty { state.setRRIntervals(m.rr) }
        // HR: the standard 0x2A37 profile is the RELIABLE source (BLE-standard, ~1Hz). Let it
        // drive the value whenever it's physiologically plausible; reject 0/garbage (off-wrist).
        // AppModel medians these into a stable display value. live perf: only publish on a real
        // change so a steady resting HR doesn't re-render the whole Live console every second.
        if m.hr >= 30 && m.hr <= 220, state.heartRate != m.hr { state.heartRate = m.hr }
        // Record it continuously — independent of the realtime stream or the open screen.
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        guard central.state == .poweredOn else { return }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                central.connect(p, options: nil)
            } else {
                discoverPrimaryServices(on: p)
            }
        } else {
            connect()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        // Multi-WHOOP present-scan (Add-a-WHOOP wizard): collect the strap, do NOT auto-connect, and
        // return before touching the connect flow. Only reachable when the wizard explicitly turned on
        // `isPresentingScan` via scanForWhoops(); on the default path (false) this branch is skipped
        // entirely and the auto-connect code below runs exactly as before.
        if isPresentingScan {
            let uuid = peripheral.identifier.uuidString
            if let i = discoveredWhoops.firstIndex(where: { $0.uuid == uuid }) {
                discoveredWhoops[i] = (uuid: uuid, name: name, rssi: RSSI.intValue)   // refresh RSSI
            } else {
                discoveredWhoops.append((uuid: uuid, name: name, rssi: RSSI.intValue))
            }
            return
        }
        // Multi-WHOOP preferred-peripheral filter: when the app has pinned a specific strap, ignore any
        // OTHER discovered WHOOP and keep scanning. When `preferredPeripheralUUID == nil` (the single-
        // WHOOP default) this guard is skipped and the original "connect to the first discovered" path
        // below is byte-for-byte unchanged.
        if let preferred = preferredPeripheralUUID, peripheral.identifier != preferred {
            log("Discovered \(name) (\(peripheral.identifier)) — not the preferred strap; ignoring")
            return
        }
        cancelScanFallback()
        // Persist the family that actually advertised so the next scan starts on the right service —
        // this is what makes a one-time rotation stick after a stale-preference reconnect. (PR#195)
        UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedWhoopModel")
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        central.stopScan()
        preparePeripheral(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelScanFallback()
        restoredPeripheral = nil
        preparePeripheral(peripheral)
        // Multi-WHOOP: publish the strap's stable BLE identity so the app can persist it onto the active
        // registry device (it observes this and calls registry.setPeripheralId). Additive observation
        // only — BLEManager stays decoupled from the store and the connect flow below is unchanged.
        connectedPeripheralUUID = peripheral.identifier.uuidString
        state.connected = true
        state.encryptedBond = false   // re-proved per connection at the genuine-bond site (#69)
        state.reconnectGuide = nil    // a connect succeeded — the stale-bond guide (if shown) is resolved
        lastDataAt = Date()
        log("Connected — discovering services")
        discoverPrimaryServices(on: peripheral)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        // #80 marginal-radio detection: judge this drop BEFORE the state resets below clobber the
        // arm timestamp. A drop that is unintentional, error-bearing, and lands shortly after we armed
        // the R10/R11 burst is the marginal-radio tell. Feed the detector; if it trips, the NEXT connect
        // skips the heavy arm (the flag is intentionally NOT reset on disconnect so it survives rescan).
        let timedOut = !intentionalDisconnect && error != nil
        let sinceArm = realtimeArmedAt.map { Date().timeIntervalSince($0) }
        if marginalRadio.connectionEnded(wasArmed: realtimeArmedAt != nil,
                                         secondsSinceArm: sinceArm,
                                         timedOut: timedOut) {
            standardHRFallback = true
            log("Marginal radio (#80): \(marginalRadio.consecutiveArmTimeouts) arm-then-timeout cycles — next connect uses standard-HR mode (0x2A37 only)")
        }
        state.connected = false
        state.encryptedBond = false   // cleared with didBond; next session must re-prove the bond (#69)
        state.charging = nil          // a stale charging flag must not outlive the link
        state.clearBiometrics()       // and a stale HR / R-R must not outlive the link either
        state.liveFeedActive = false  // a drop while Live is open must not leave a stale "Stop live feed"
        didBond = false
        whoop5RealtimeArmed = false
        // The strap forgets the realtime-HR toggle across a disconnect; the post-bond branch re-arms it
        // from `wantsRealtime`. Clear only the "what we last sent" flag — `screenWantsRealtime` /
        // `keepRealtimeForData` (and thus `wantsRealtime`) are intent and must survive a reconnect so the
        // stream comes back automatically.
        realtimeArmed = false
        whoop5SessionStarted = false
        clockRequested = false
        connectHandshakeDone = false
        realtimeArmedAt = nil   // cleared after the marginal-radio detector above read it (#80)
        // Reset backfill state so the next connect starts a fresh offload (incl. the syncing pill —
        // a dropped link mid-offload must not leave "Syncing strap history…" stuck on, #77).
        backfillStarted = false
        backfilling = false
        state.backfilling = false
        state.syncChunksThisSession = 0
        // A mid-sync disconnect bypasses exitBackfilling, so clear the reject counters here too —
        // otherwise a stale non-zero count survives until the next beginBackfill. (#77/#91)
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        lastOffloadFrameAt = nil   // #174: don't carry a stale cooldown reference into the next session
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillDraining = false
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        resetCharacteristics()
        puffinRecorder.flush()   // persist any buffered puffin capture frames before reconnect
        Task { @MainActor in await collector?.flushStandardHR() }   // persist any buffered 0x2A37 HR
        if !intentionalDisconnect {
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); rescanning in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.intentionalDisconnect else { return }
                self.connect()
            }
        } else {
            log("Disconnected (intentional)")
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "")")
        // The strap wiped its bond (a firmware update, or the official WHOOP app re-bonding it). macOS keeps
        // re-presenting the now-stale pairing key, so every reconnect loops on this same error with no
        // recovery and no user guidance. Surface an actionable re-pair guide instead of failing silently —
        // NOOP itself works fine on the new firmware once the stale bond is cleared. (5/MG firmware reset, 2026-06)
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            state.reconnectGuide = """
            Your strap's Bluetooth pairing was reset — usually by a WHOOP firmware update, or the official WHOOP app reconnecting. NOOP works fine on the new firmware; you just need to re-pair:

            1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
            2. Open System Settings → Bluetooth and Forget “WHOOP MG” if it's listed.
            3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
            4. Come back here and reconnect.
            """
        }
    }

    /// State restoration entry point (M3 background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        resetCharacteristics()
        // Re-derive the inbound-decode family from the persisted model. connect()/startScan() set the
        // reassembler + router family, but NEITHER runs on the restore path — so without this a restored
        // WHOOP 5/MG would decode its puffin notify frames with the default .whoop4 framing (different
        // length offset + constant), producing corrupt/empty data for the whole unattended session until
        // the user manually taps connect.
        selectedModel = .persisted
        reassembler = Reassembler(family: selectedModel.deviceFamily)
        router.family = selectedModel.deviceFamily
        configureCollectorFamily()
        // Collection only runs post-bond, so a restored link was already bonded;
        // seed those flags now. `didWriteValueFor` won't re-fire on its own.
        state.bonded = true
        state.encryptedBond = true   // a restored link was genuinely encrypted-bonded before (#69)
        didBond = true
        // clockRef is nil in the fresh process after restore, so we must re-request it.
        // Reset the flag so the post-restore didWriteValueFor issues exactly one getClock.
        clockRequested = false
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
            discoverPrimaryServices(on: p)
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        log("Services discovered: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        for s in services {
            switch s.uuid {
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.whoop5Service:
                // EXPERIMENTAL WHOOP 5.0/MG path: discover the puffin command + notify characteristics
                // so we can send CLIENT_HELLO and receive frames. Live HR/battery still arrive over the
                // standard 0x2A37/0x2A19 profiles (discovered alongside this); this custom path is
                // unverified on MG hardware.
                log("WHOOP 5/MG detected — discovering puffin characteristics (experimental).")
                peripheral.discoverCharacteristics(
                    [BLEManager.whoop5CmdWriteChar] + BLEManager.whoop5NotifyChars, for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                cmdCharacteristic = c
                // THE BONDING TRICK: one confirmed write triggers just-works bonding.
                // GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
            case BLEManager.whoop5CmdWriteChar:
                // EXPERIMENTAL WHOOP 5.0/MG: a 5/MG strap starts a session with the static CLIENT_HELLO
                // frame, not the WHOOP4 confirmed-write bond. We write it UNacknowledged (it is a
                // complete framed command), so the WHOOP4 didWriteValueFor bond+handshake path never
                // fires for a 5/MG strap. Live HR/battery come from the standard profiles; this just
                // opens the puffin session. Unverified on real MG hardware.
                cmdCharacteristic = c
                if let hello = selectedModel.deviceFamily.clientHello {
                    // CONTRIBUTOR FIX (issue #17 — diagnosed from the logs, unverified on hardware here):
                    // write CLIENT_HELLO with .withResponse so CoreBluetooth runs just-works bonding when
                    // the link needs authenticating, AND so didWriteValueFor fires. That callback is where
                    // we mark the link established and (re)subscribe the puffin notify chars — the strap
                    // rejects them with "Authentication is insufficient" until the connection is encrypted,
                    // and the old .withoutResponse write never triggered bonding, so it hung forever at
                    // "Finishing the secure pairing handshake…".
                    log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (to trigger bonding, experimental).")
                    state.pairingHint = nil   // fresh attempt; clear any stale pairing-mode guidance
                    peripheral.writeValue(Data(hello), for: c, type: .withResponse)
                }
                // The realtime-HR stream is armed POST-bond (in didWriteValueFor / startRealtime) with
                // puffin framing — not here. Writing it pre-bond on an unauthenticated link did nothing.
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                switch c.uuid {
                case BLEManager.cmdNotifyChar: cmdNotifyCharacteristic = c
                case BLEManager.eventNotifyChar: eventNotifyCharacteristic = c
                case BLEManager.dataNotifyChar: dataNotifyCharacteristic = c
                case BLEManager.heartRateChar: heartRateCharacteristic = c
                case BLEManager.batteryChar:
                    batteryCharacteristic = c
                    if c.properties.contains(.read) {
                        peripheral.readValue(for: c)
                    }
                default: break
                }
                requestNotify(c, on: peripheral, reason: "discovery")
            default:
                // WHOOP 5.0/MG puffin notify characteristics (fd4b0003/0004/0005/0007). Retain them but DO
                // NOT subscribe yet — on an unauthenticated link the strap rejects them with "Authentication
                // is insufficient", which (per a 5/MG owner's verified flow, issue #17) also wedges the bond.
                // didWriteValueFor subscribes them once the CLIENT_HELLO .withResponse write confirms.
                if BLEManager.whoop5NotifyChars.contains(c.uuid) {
                    whoop5NotifyCharacteristics.append(c)
                }
            }
        }
    }

    /// Confirmed-write completion = bonding succeeded (no error).
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Confirmed write failed: \(error.localizedDescription)")
            // WHOOP 5/MG first connect: CoreBluetooth won't start a fresh just-works bond against a strap
            // still bonded to the official WHOOP app, so the CLIENT_HELLO .withResponse write fails with
            // "Encryption/Authentication is insufficient" and the link never authenticates. Surface
            // actionable pairing-mode guidance instead of failing silently (issue #17).
            if selectedModel.deviceFamily == .whoop5, !didBond {
                let d = error.localizedDescription.lowercased()
                if d.contains("encryption") || d.contains("authentication") {
                    state.pairingHint = "Close the official WHOOP app (or turn its phone's Bluetooth off), put the strap in pairing mode (on a 5.0/MG, tap the band repeatedly until the LEDs flash blue), then reconnect."
                    log("WHOOP 5/MG: bond refused — the strap is likely still paired to the WHOOP app. Put it in pairing mode (blue LEDs) with the WHOOP app closed, then reconnect.")
                }
            }
            return
        }

        // EXPERIMENTAL WHOOP 5.0/MG (issue #17): the CLIENT_HELLO is now a .withResponse write, so this
        // fires once the strap acks it — after just-works bonding if the link needed authenticating.
        // Treat that as the link being established: mark bonded (which clears the "Finishing the secure
        // pairing handshake…" status) and re-subscribe the puffin notify chars + standard HR/battery,
        // which the strap refused before the link was encrypted. Do NOT run the WHOOP4 command handshake
        // below — a 5/MG strap rejects WHOOP4-framed commands (the send() guard drops them anyway).
        if selectedModel.deviceFamily == .whoop5 {
            if !didBond {
                didBond = true
                state.bonded = true
                state.encryptedBond = true   // genuine encrypted bond (not the live-HR shortcut) — #69
                state.pairingHint = nil
                log("WHOOP 5/MG: CLIENT_HELLO acked — link established; subscribing notify chars (experimental).")
            }
            for c in whoop5NotifyCharacteristics where !c.isNotifying {
                requestNotify(c, on: peripheral, reason: "post-bond puffin")
            }
            enableLiveNotifications(reason: "post-bond 5/MG")   // standard HR/battery that failed pre-bond
            // Arm realtime HR with puffin framing — the verified step that makes a bonded 5/MG strap start
            // streaming (issue #17). Once per connection; keep-alive skips 5/MG, so this is the trigger.
            // (Opening Live later also arms it via startRealtime(), now that send() routes the 5/MG toggle.)
            if wantsRealtime && !whoop5RealtimeArmed {
                whoop5RealtimeArmed = true
                realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the arm
                log("WHOOP 5/MG: arming realtime HR (puffin TOGGLE_REALTIME_HR)")
                send(.toggleRealtimeHR, payload: [0x01])
            }
            startKeepAlive()                                    // re-subscribe + liveness watchdog
            // Kick the historical offload ONCE per connection — this is the 5/MG edition of the WHOOP4
            // connect-handshake (lines below). didWriteValueFor re-enters this `.whoop5` branch on EVERY
            // .withResponse ack during the offload (each HISTORY_END ack), so the trigger work MUST fire
            // once or it would re-issue SEND_HISTORICAL_DATA mid-stream and storm the strap. The notify
            // re-subscribe + realtime-arm above are idempotent and intentionally run on every re-entry;
            // only this block is gated. `whoop5SessionStarted` resets on disconnect.
            if !whoop5SessionStarted {
                whoop5SessionStarted = true
                connectHandshakeDone = true     // unblocks beginBackfill()'s guard
                log("WHOOP 5/MG: connect handshake done — backfill unblocked")
                // Re-apply the Broadcast-HR device-config flag if the user opted in (#181).
                if PuffinExperiment.broadcastHrEnabled { setBroadcastHr(true) }
                // Clock the strap BEFORE history: an un-clocked WHOOP 5 discards sensor data ("RTC
                // timestamp … is invalid; not saving data to flash") and history offloads "succeed"
                // with metadata only. Same 8-byte payload as the WHOOP4 handshake, puffin-framed;
                // GET_CLOCK's reply rides the puffin notify chars and never touches the WHOOP4
                // clockRef correlation path. The 1.5s deferral below keeps clock-before-history.
                // Hardware-validated ordering (#78 fork).
                send(.setClock, payload: BLEManager.setClockPayload())
                send(.getClock, payload: [])
                log("WHOOP 5/MG: clock synced (set/get) — strap can persist history now")
                log("WHOOP 5/MG: scheduling first historical offload (connect)")
                // Deferred ~1.5s so the puffin notify subscriptions settle before SEND_HISTORICAL_DATA,
                // mirroring the WHOOP4 kick. requestSync → beginBackfill is itself gated on
                // connectHandshakeDone, so a racing foreground/restore trigger can't fire it early.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
                startBackfillTimer()            // re-offload the type-47 store every backfillIntervalSeconds
            }
            return
        }

        if !didBond {
            didBond = true
            state.bonded = true
            state.encryptedBond = true   // WHOOP 4 confirmed-write bond is always genuine — #69
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor re-fires on EVERY
        // .withResponse write — the bond write, every SEND_HISTORICAL, every HISTORY_END ack. Without
        // this guard those re-entries re-sent hello/SET_CLOCK at the strap *during* the offload and
        // stopped it from streaming type-47. This was THE iOS-side root cause: the Mac prototype pulls
        // type-47 fine because it runs the sequence once on a stable connection; the app stormed it.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        backfillStarted = true

        // WHOOP-faithful connect lifecycle: hello → set RTC,
        // then offload. Hello is NOT strictly required to serve — verified on this strap via the Mac
        // ground-truth test: plain SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync
        // (PHASE A = 50 records; PHASE B high-freq = 0). We still exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        sendSetClockBothForms()
        if clockRef == nil && !clockRequested {
            clockRequested = true
            // GET_CLOCK's payload length is firmware-specific, exactly like SET_CLOCK's: newer
            // firmware answers the EMPTY form and ignores [0x00], while fw 41.17.x answers [0x00] and
            // ignores the empty form (#120). Send both — the strap answers whichever its firmware
            // accepts, and the `clockRef == nil` correlation guard makes a second reply a no-op.
            // Without the [0x00] form, correlation never establishes on 41.17.x, so a lost RTC (the
            // 1971 clock behind #120) stays invisible and ClockPolicy can never re-fix it. Both
            // GET_CLOCKs ride behind both SET_CLOCKs above, so the reply reflects the corrected clock.
            // (Offload doesn't depend on this — Backfiller falls back to an identity clockRef — but a
            // real correlation drives realtime decode and the drift re-set.)
            send(.getClock, payload: [])
            send(.getClock, payload: [0x00])
        }
        send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
        send(.getDataRange)                          // refresh the strap's stored range for the watchdog
        // Plain offload (no high-freq-sync), rate-limited (first connect always runs; reconnect-flaps are
        // throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/GET_DATA_RANGE round-trip first and
        // SEND_HISTORICAL runs on a settled link, like the paced Mac prototype. beginBackfill is itself
        // gated on connectHandshakeDone so a racing foreground/restore trigger can't fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
        startKeepAlive()       // always-ping: re-arm realtime, poll battery, watchdog the link
        enableLiveNotifications(reason: "post-bond")   // includes 0x2A37 standard HR — the fallback path
        if wantsRealtime {
            if standardHRFallback {
                // #80: this radio repeatedly dropped the link the instant we armed the R10/R11 burst.
                // Skip the heavy stream entirely; live HR rides the already-subscribed low-bandwidth
                // 0x2A37 standard profile (subscribed by enableLiveNotifications above). SAFE either way:
                // if 0x2A37 emits the user gets live HR on a radio that otherwise died; if it doesn't, at
                // least the arm→die loop stops.
                log("Realtime HR: standard-HR mode (low bandwidth) — skipping R10/R11 arm (#80)")
                state.standardHRMode = "Standard HR mode (low bandwidth) — your Bluetooth radio couldn't sustain the full stream; live heart rate via the standard profile."
            } else {
                log("Realtime HR: arming after bond")
                realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the arm
                send(.sendR10R11Realtime, payload: [0x01])
                send(.toggleRealtimeHR, payload: [0x01])
                realtimeArmedAt = Date()   // start the arm→drop stopwatch for the marginal-radio detector
            }
        }
    }

    /// SET_CLOCK(10) payload — the 8-byte form `[seconds u32 LE][subseconds u32 LE]`, subseconds in
    /// 1/32768 s (0 is fine). The payload LENGTH is firmware-specific and LOAD-BEARING: newer WHOOP 4
    /// firmware latches this form, but fw 41.17.x ignores it outright — no COMMAND_RESPONSE, RTC
    /// unchanged — and latches only the legacy 9-byte form below. A strap that misses the set keeps an
    /// invalid RTC and stops banking sensor data to flash entirely, which surfaces as endless
    /// console-only syncs and no sleep/recovery (#120). Send WHOOP 4 through sendSetClockBothForms()
    /// so either firmware latches.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// SET_CLOCK(10) payload — the legacy 9-byte form `[seconds u32 LE][5 zero]` required by WHOOP 4
    /// fw 41.17.x, which ignores the 8-byte form. On a strap whose RTC was stuck in the past, days of
    /// 8-byte sends drew no response; the 9-byte form was ack'd (COMMAND_RESPONSE cmd 10), the clock
    /// latched and ticked, and the strap resumed banking history to flash (#120). On newer firmware
    /// this form is ack'd but NOT latched, so sending it after the 8-byte form is a no-op there — both
    /// forms carry the same seconds, so whichever one latches sets the same time.
    static func setClockPayloadLegacy(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0, 0]
    }

    /// Send SET_CLOCK in every payload form the WHOOP 4 firmware family is known to accept (8-byte for
    /// newer firmware, 9-byte for 41.17.x — each a no-op on the other). Both carry the same `now`, so
    /// double-latching is harmless. WHOOP 5/MG keeps its single hardware-validated 8-byte send (its
    /// connect path calls setClockPayload() directly; the 9-byte form is unverified on that family), so
    /// the legacy form is gated to WHOOP 4. (#120)
    func sendSetClockBothForms() {
        let now = UInt32(Date().timeIntervalSince1970)
        send(.setClock, payload: BLEManager.setClockPayload(now: now))
        if selectedModel.deviceFamily == .whoop4 {
            send(.setClock, payload: BLEManager.setClockPayloadLegacy(now: now))
        }
    }

    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var newest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { newest = max(newest ?? 0, w) }
            i += 4
        }
        return newest
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log("Notify update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            parseStandardHR(bytes)
            // EXPERIMENTAL WHOOP 5.0/MG: there is no confirmed-write bond for a 5/MG strap, so once
            // live HR actually streams over the standard profile we treat the link as established —
            // otherwise the UI sits on "Connecting…" forever even though data is flowing (issue #8).
            if selectedModel.deviceFamily == .whoop5, !state.bonded {
                state.bonded = true
                log("WHOOP 5/MG: live HR streaming — marking the link established (experimental).")
            }
        case BLEManager.batteryChar:
            // 0x2A19 = percent — 5/MG ONLY. The WHOOP 4.0's 0x2A19 is a stub constant 100 (real value =
            // GET_BATTERY_LEVEL response, u16/10) and it's subscribed, so an unsolicited stub
            // notification was reverting the true reading back to 100% (#77).
            if selectedModel.deviceFamily != .whoop4, let pct = bytes.first {
                state.setBattery(Double(pct))
            }
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar:
            // Reassemble (no-op for already-complete frames) then route each complete frame.
            for frame in reassembler.feed(bytes) {
                if backfilling, BLEManager.isOffloadFrame(frame, family: .whoop4) {
                    // Historical replay is bulk sync traffic, not live UI traffic. Feed it only to
                    // the Backfiller; parsing every record through FrameRouter updates SwiftUI for
                    // no user-visible benefit and can make the app feel hung during long offloads.
                    armBackfillTimeout()
                    routeBackfillFrame(frame)
                    // …but a REAL-TIME physical gesture (double-tap / wrist) must still fire even mid-
                    // offload (#69). Gated on ts≈now so replayed historical EVENTs (old ts) are ignored.
                    router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                    continue
                }
                router.handle(frame: frame)                       // live/UI path
                if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue,
                   let newest = BLEManager.dataRangeNewestUnix(from: frame) {
                    strapNewestTs = newest                        // feeds the liveness watchdog
                }
                // Clock correlation runs in both live and backfill modes. Once established it
                // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
                if clockRef == nil {
                    let parsed = parseFrame(frame)
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref                  // unblocks buffered persistence
                        backfiller?.clockRef = ref                 // unblocks historical chunk decode
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            sendSetClockBothForms()
                        }
                    }
                }
                if !backfilling {
                    // Live path (unchanged): synchronous ingest preserves delegate arrival order.
                    collector?.ingest(frame)
                }
            }
        default:
            // EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/0004/0005/0007): reassemble with
            // the family-aware reassembler and route through the family-aware FrameRouter so the UI
            // reflects arriving frames. The historical offload uses the WHOOP4 backfill machinery
            // (family-aware), and live puffin frames are now persisted too — see below. (Clock: the
            // Collector runs an identity ref for 5/MG via configureCollectorFamily, since live puffin
            // timestamps are already real-unix seconds.) Live HR/battery still also come from the
            // standard 0x2A37 / 0x2A19 profiles handled above.
            if BLEManager.whoop5NotifyChars.contains(characteristic.uuid) {
                for frame in reassembler.feed(bytes) {
                    let isOffload = backfilling && BLEManager.isOffloadFrame(frame, family: .whoop5)
                    noteWhoop5R22Telemetry(frame, duringOffload: isOffload)   // #174 deep-data telemetry
                    if isOffload {
                        // Same policy as WHOOP4: historical offload frames are bulk sync traffic.
                        // Keep them out of the live UI parser during backfill and let Backfiller
                        // preserve/order/process them in the sliced drain.
                        armBackfillTimeout()
                        routeBackfillFrame(frame)
                        // A real-time double-tap / wrist gesture still fires during a 5/MG offload (which
                        // runs for minutes, #69); the ts≈now gate rejects replayed historical EVENTs.
                        router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                        continue
                    }
                    router.handle(frame: frame)
                    // NOTE: we deliberately do NOT ingest live 5/MG REALTIME_DATA into the Collector
                    // here. For a 5/MG the standard 0x2A37 Heart-Rate profile is already the RELIABLE,
                    // continuously-persisted live source (see didUpdateValueFor 0x2A37 → ingestStandardHR);
                    // decoding HR a second time off the puffin stream stored a duplicate row per heartbeat
                    // at a slightly different second (strap-unix vs Mac-receive), inflating the sample
                    // store. 0x2A37 stays the single authoritative live HR/RR source for 5/MG.
                    // Capture for protocol mapping (no-op unless the Settings toggle is on). PR #20.
                    puffinRecorder.capture(frame: frame, char: characteristic.uuid)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notify \(characteristic.isNotifying ? "active" : "off") \(characteristic.uuid)")
        }
    }
}
