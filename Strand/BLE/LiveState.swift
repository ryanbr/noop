import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol
import OuraProtocol

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    // NOTE: do NOT auto-clear `pairingHint` when `bonded` flips true. On a 5/MG, `bonded` is also set by
    // the live-HR shortcut (BLEManager — HR over the unbonded standard profile), so clearing the hint
    // there hides the still-accurate "free the strap" guidance from users who are streaming HR but never
    // got the real encrypted bond (issue #69). The genuine bond path clears the hint itself (the
    // CLIENT_HELLO ack), and a fresh connect attempt resets it.
    @Published public var bonded: Bool = false
    /// True ONLY when the link reached a GENUINE encrypted bond — the WHOOP 5/MG CLIENT_HELLO ack, the
    /// WHOOP 4 confirmed-write bond, or a restored already-bonded link. Deliberately NOT set by the
    /// live-HR shortcut that flips `bonded` true when HR streams over the *unbonded* standard profile on
    /// a 5/MG (issue #69) — so `bonded` can be true while `encryptedBond` is false ("Live HR, not fully
    /// paired"). WHOOP 4 always reaches a genuine bond, so the two track together there. Reset on
    /// connect/disconnect. Drives the Live pill's two-state distinction; the encrypted channel (buzz,
    /// alarm, double-tap, history offload) only works when this is true.
    @Published public var encryptedBond: Bool = false
    /// #34: bumped by BLEManager once a WHOOP 4.0 connection has BOTH run its connect handshake (hello +
    /// SET_CLOCK, exactly once — `connectHandshakeDone`) AND had the cmd-notify characteristic confirm
    /// subscribed (`didUpdateNotificationStateFor` for it fired with `isNotifying == true`) — whichever of
    /// the two lands second. `bonded` alone fires the instant the confirmed-write bond ack lands, which is
    /// BEFORE either of those — arming the firmware alarm off `bonded` sent SET_ALARM_TIME/GET_ALARM_TIME
    /// while the cmd-notify channel wasn't confirmed active yet, so the strap's GET_ALARM_TIME readback
    /// was silently dropped (evidenced in a v8.6.2 strap log, issue #34). A monotonic counter (not a Bool)
    /// so a re-arm-eligible sink can `.dropFirst()` the initial published value and fire on every bump,
    /// exactly once per settled connection. Reset to a fresh (un-bumped) state is implicit: BLEManager's
    /// per-connection guards (`connectHandshakeDone`, the cmd-notify-confirmed flag) reset on disconnect,
    /// so the next connection can bump this again.
    @Published public var connectSettled: Int = 0
    /// True ONLY when a non-WHOOP live source (currently the Oura ring) is actively streaming live HR.
    /// This is the green "STREAMING" signal for sources that have no WHOOP-style encrypted bond: it is
    /// DELIBERATELY separate from `bonded`, which carries WHOOP encrypted-bond + buzz semantics (it gates
    /// haptics in AppModel / BreathingView) and must not be set by the Oura path. The menu-bar pill reads
    /// this to show STREAMING for a live ring while leaving the WHOOP bonded logic untouched. The owning
    /// source sets it true in its streaming branch and false at every teardown (stop / needs-pairing /
    /// radio-off / connect-fail / disconnect). Twin of the Android LiveState.streamingLiveHR.
    @Published public var streamingLiveHR: Bool = false
    @Published public var heartRate: Int? = nil
    /// Whether the heavy R10/R11 realtime burst is currently armed (the "live feed"). Tracks the
    /// realtime INTENT (startRealtime/stopRealtime), NOT `heartRate` — the lightweight 0x2A37 profile
    /// keeps setting heartRate while bonded, so a heartRate-driven toggle could never read "off". The
    /// menu-bar Start/Stop-live-feed button reads this.
    @Published public var liveFeedActive: Bool = false
    /// Latest R-R packet exactly as it arrived from the strap. Keep this as the "fresh packet"
    /// surface for stress/breathing logic that reacts to the most recent arrival (and the standard
    /// 0x2A37 profile, which is the reliable R-R source). Drive it ONLY via `setRRIntervals(_:)`.
    @Published public var rr: [Int] = []
    /// Rolling UI buffer of recent R-R intervals (capped, oldest dropped first). Standard BLE HR
    /// notifications usually carry only one or two intervals per packet, so the Live console needs a
    /// separate short history to render an actually-moving R-R strip / rolling RMSSD. Appended (never
    /// replaced) by `setRRIntervals(_:)`; emptied by `clearBiometrics()`.
    @Published public private(set) var rrRecent: [Int] = []
    @Published public var batteryPct: Double? = nil
    /// Strap battery pack VOLTAGE (mV), decoded from the ~8-min BATTERY_LEVEL event (mv@21/@25) and the
    /// GET_EXTENDED_BATTERY_INFO response (#592). Shown on the Devices card as a "x.xx V" readout beside the
    /// percent; nil until the first battery event lands. Twin of the Android LiveState.batteryMv.
    @Published public var batteryMv: Int? = nil
    /// Charging flag from the strap's BATTERY_LEVEL events — wire observation: u8 bit0 in the
    /// event payload (4.0 @26 / 5.0 @30), pushed ~every 8 min on captured links. nil until the
    /// first event of a session; cleared on disconnect so a stale flag can't outlive the link.
    /// Flag ONLY — the battery % keeps its family-specific source (#77).
    @Published public var charging: Bool? = nil

    /// The Oura ring's current wear/charge state (nil for non-Oura straps or before any evidence this
    /// session). Driven by OuraLiveSource from the live-HR push + the ring's STATE charger strings: a live
    /// beat only comes from a finger (`.worn`); "chg. detected"/"stopped" bracket `.charging`; a silent
    /// live-HR stream drops to `.off` (removed). Lets the Live view show On wrist / Off wrist.
    @Published public var ouraWearState: OuraWearState? = nil

    // MARK: - Battery runtime estimate (#713)

    /// Rolling buffer of `(unix-seconds, SoC%)` battery readings banked from the live link, the twin of
    /// `rrRecent` for the battery series. `setBattery` appends each reading (with a small dedupe so a
    /// repeated identical % at a near-identical time doesn't pad the buffer), and `batteryEstimate` fits
    /// the recent discharge slope over it. Capped + bounded so it can't grow without limit; cleared on
    /// disconnect so a stale estimate can't outlive the link.
    @Published public private(set) var batterySamples: [(ts: Int, soc: Double)] = []
    /// Cap on the SoC buffer. Battery events arrive only every ~8 minutes, so a few hundred readings
    /// already spans a couple of days, plenty to fit a discharge slope against.
    static let maxBatterySamples = 400

    // MARK: - Sleep & Rest test-mode live readout (Group E)

    /// Rolling buffer of recent live HR samples, banked ONLY while the Sleep test mode is active so the
    /// Test Centre readout can show live HR density (samples/min) the detector sees. Appended via
    /// `recordSleepLiveSample` from the central live-HR ingest; empty (no work, no allocation) when the
    /// mode is off. Capped + bounded; cleared on disconnect with the rest of the live biometrics.
    @Published public private(set) var recentHrSamples: [HRSample] = []
    /// Rolling buffer of recent live gravity samples, banked ONLY while the Sleep test mode is active so
    /// the readout can show live gravity coverage. The twin of `recentHrSamples`.
    @Published public private(set) var recentGravitySamples: [GravitySample] = []
    /// Cap on each live-readout buffer. ~30 min of 1 Hz live HR is plenty to read a density/coverage
    /// snapshot; bounded so an active test mode can never grow it without limit.
    static let maxSleepReadoutSamples = 2000

    /// Bank one live HR sample for the Sleep readout. Side-effect-only; the caller already gated on
    /// `TestCentre.active(.sleep)`, so this does NO work when the mode is off (it is simply not called).
    public func recordSleepLiveHr(ts: Int, bpm: Int) {
        recentHrSamples.append(HRSample(ts: ts, bpm: bpm))
        if recentHrSamples.count > Self.maxSleepReadoutSamples {
            recentHrSamples.removeFirst(recentHrSamples.count - Self.maxSleepReadoutSamples)
        }
    }

    /// Bank live gravity samples for the Sleep readout. Caller-gated on `TestCentre.active(.sleep)`.
    public func recordSleepLiveGravity(_ samples: [GravitySample]) {
        guard !samples.isEmpty else { return }
        recentGravitySamples.append(contentsOf: samples)
        if recentGravitySamples.count > Self.maxSleepReadoutSamples {
            recentGravitySamples.removeFirst(recentGravitySamples.count - Self.maxSleepReadoutSamples)
        }
    }

    /// The strap's typical full-charge life in hours, chosen by generation, used as the cold-start
    /// fallback before enough of the user's own discharge is banked. The today lane / coordinator sets
    /// this from the connected `WhoopModel` (WHOOP 4.0 vs 5.0/MG); it defaults to the WHOOP 4.0 figure so
    /// an estimate is sensible before the strap generation is known.
    @Published public var batteryRatedHours: Double = BatteryEstimator.ratedLifeHoursWhoop4

    /// "~X days left" runtime estimate for the connected strap, computed from the banked SoC samples and
    /// `batteryRatedHours`. nil until there's at least one reading. The Today badge reads this.
    public var batteryEstimate: BatteryEstimator.Estimate? {
        BatteryEstimator.estimate(samples: batterySamples, ratedHours: batteryRatedHours)
    }

    /// The discharge-run / fitted-slope / gate trace for the banked SoC series (#713, Test Centre Battery
    /// mode). Pure: delegates to BatteryEstimator.estimateTrace, which returns the SAME Estimate as
    /// batteryEstimate plus the trace lines, so reading this never changes any displayed number.
    public var batteryEstimateTraceLines: [String] {
        BatteryEstimator.estimateTrace(samples: batterySamples, ratedHours: batteryRatedHours).trace
    }

    /// Emit the discharge-run / slope / gate trace once, tagged .battery, when the Battery test mode is on.
    /// The readout / Today lane calls this on each refresh; it is a no-op (zero cost) when the mode is off.
    public func emitBatteryTrace() {
        guard TestCentre.active(.battery) else { return }
        for line in batteryEstimateTraceLines { append(log: line, domain: .battery) }
    }

    /// Resolve one of the Battery mode's liveReadout ids ("currentSoc" / "estimateDaysLeft" /
    /// "slopeSource") to a short display string the Test Centre Battery panel binds to. Returns "--" when
    /// there is no estimate yet or the id is unknown. Reads the SAME values the Today badge shows, so the
    /// readout never diverges from the headline number.
    public func batteryReadout(_ id: String) -> String {
        guard let e = batteryEstimate else { return "--" }
        switch id {
        case "currentSoc":       return "\(Int(e.currentSoc.rounded()))%"
        case "estimateDaysLeft": return BatteryEstimator.label(hours: e.remainingHours)
        case "slopeSource":      return e.source.rawValue
        default:                 return "--"
        }
    }

    // MARK: - Strap clock-drift snapshot (universal export self-diagnostic, RTC cluster #531/#767/#804/#812)

    /// The strap's last-decoded banked-record window + firmware layout, banked from the GET_DATA_RANGE reply
    /// and the offload's hist_version. It is what the export assembler turns into the UNIVERSAL clock-drift
    /// line that rides EVERY Test Centre export (UniversalTrace.clockDriftLine), so a clock-broken strap
    /// self-diagnoses on a Sleep / Battery / any-mode report, not only when the Connection mode is on. Set
    /// unconditionally (it is observability, not gated) and cleared on disconnect so a stale window can't
    /// outlive the link. nil until the strap first reports its range this session.
    public struct StrapRange: Equatable, Sendable {
        public var newestUnix: Int
        public var oldestUnix: Int?
        public var firmwareLayout: Int?
        public init(newestUnix: Int, oldestUnix: Int? = nil, firmwareLayout: Int? = nil) {
            self.newestUnix = newestUnix; self.oldestUnix = oldestUnix; self.firmwareLayout = firmwareLayout
        }
    }
    @Published public private(set) var strapRange: StrapRange?

    /// Bank the strap's reported banked-record window (from GET_DATA_RANGE). Additive observability: the
    /// universal clock-drift export line reads this. `oldest` keeps the previously-known value when this
    /// reply carries only the upper bound, so a half/short range reply never clears a good lower bound.
    public func setStrapRange(newestUnix: Int, oldestUnix: Int?) {
        let firmware = strapRange?.firmwareLayout
        let oldest = oldestUnix ?? strapRange?.oldestUnix
        strapRange = StrapRange(newestUnix: newestUnix, oldestUnix: oldest, firmwareLayout: firmware)
        // #34: persist the strap's newest banked record so the debug export can flag a reset/stale clock.
        UserDefaults.standard.set(newestUnix, forKey: "strap.newestRecordTs")
    }

    /// Bank the historical record-layout version (hist_version: 18/24/25/26) the strap emits, so the
    /// universal clock-drift line is firmware-aware even before a fresh range reply lands. Keeps the
    /// already-known window; a nil range (firmware seen before any range) stores a firmware-only snapshot.
    public func setStrapFirmwareLayout(_ version: Int) {
        if let r = strapRange {
            strapRange = StrapRange(newestUnix: r.newestUnix, oldestUnix: r.oldestUnix, firmwareLayout: version)
        } else {
            strapRange = StrapRange(newestUnix: 0, oldestUnix: nil, firmwareLayout: version)
        }
    }

    /// Drop the strap-range snapshot (called on disconnect with the other live clears) so a stale clock-drift
    /// window can't outlive the link.
    public func clearStrapRange() { strapRange = nil }

    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil
    /// #987: unix of the most recent strap frame FrameRouter routed. Deliberately NOT @Published - the
    /// raw flood arrives per-notification and a published write per frame would re-render every observer
    /// at frame rate (the exact churn the lastFrameType change-guard exists to avoid). The Test Centre
    /// Connection readout reads it on its own render cadence, which is plenty for a freshness label.
    /// Cleared with the other live readouts in clearBiometrics so it can't outlive the link.
    public private(set) var lastFrameAtUnix: Int?

    /// Stamp the last-frame instant (#987). One plain Int write per routed frame; called by FrameRouter
    /// after the CRC guard so bad bytes never count as liveness.
    public func noteFrameRouted(now: Int = Int(Date().timeIntervalSince1970)) { lastFrameAtUnix = now }
    /// The strap's BLE advertising name, read back from firmware via GET_ADVERTISING_NAME_HARVARD
    /// (cmd 76 — sent in the connect handshake, parsed by FrameRouter). nil until the first reply.
    /// WHOOP 4.0 only; the rename control in Settings shows this as the strap's current name.
    @Published public var advertisingName: String? = nil
    /// The connected strap's firmware version, read during the connect handshake: WHOOP 4.0 via
    /// REPORT_VERSION_INFO (`fw_harvard`), WHOOP 5/MG via GET_HELLO (`fw_version`). FrameRouter
    /// publishes it; the Devices card shows it next to battery. nil until the reply lands, and
    /// cleared on disconnect so a stale version can't outlive the link. Twin of the Android
    /// LiveState.strapFirmware.
    @Published public var strapFirmware: String? = nil
    /// True while a user-initiated reboot (#166) is in flight — from sending REBOOT_STRAP until the strap
    /// reconnects (or the settle timeout gives up). Combined with `!connected` it drives the Devices
    /// card's transient "Reconnecting…" pill so the restart reads as intentional. Twin of the Android
    /// LiveState.rebootInProgress.
    @Published public var rebootInProgress: Bool = false
    /// Transient, human-readable result of the most recent strap-rename attempt — the
    /// SET_ADVERTISING_NAME_HARVARD ack, or a local validation message from BLEManager.renameStrap.
    /// Surfaced under the rename field; overwritten by the next attempt.
    @Published public var renameStatus: String? = nil
    /// #592: the read-only extended-battery probe result (raw hex + payload triage + capture diff), or a
    /// `" waiting"` sentinel while a probe is in flight; nil otherwise. Drives the Devices result dialog so
    /// a capture is readable/copyable without a full log export. BLEManager writes it; cleared on disconnect
    /// and on dialog dismiss. Twin of the Android StateFlow LiveState/WhoopBleClient.extendedBatteryProbe.
    @Published public var extendedBatteryProbe: String? = nil

    /// #690: the body-location probe result (or the waiting sentinel), shown + copied in the Devices dialog.
    /// Cleared on disconnect and on dialog dismiss. Twin of the Android WhoopBleClient.bodyLocationProbe flow.
    @Published public var bodyLocationProbe: String? = nil

    /// #761: the READ-ONLY feature-flag enumeration report — the flag NAMES the strap's own firmware lists
    /// (`START_FF_KEY_EXCHANGE`/`SEND_NEXT_FF`), or the waiting sentinel while the walk runs. Nothing is
    /// written to the strap to produce it. Cleared on disconnect and on dialog dismiss. Twin of the Android
    /// WhoopBleClient.featureFlagProbe flow.
    @Published public var featureFlagProbe: String? = nil

    /// The WHOOP MG ECG ("Labrador") probe result (or the waiting sentinel), shown + copied in the Devices
    /// dialog. Cleared on disconnect and on dialog dismiss. Instrumentation only — the text it carries is
    /// explicitly not a medical measurement.
    @Published public var ecgProbe: String? = nil

    /// The 5-generation hardware variant resolved from the strap's Device Information Service
    /// (`Whoop5Variant.label`: "MG" / "5.0" / "—"), nil before any DIS string has landed. Published so an
    /// MG-only capability can gate on POSITIVELY identified hardware instead of guessing from a model
    /// string; `.unknown` is not MG, so a feature stays off until the strap attests. Diagnostic + gating
    /// only — it never changes how a frame is parsed (see the note on `Whoop5Variant`).
    @Published public var whoop5Variant: String? = nil

    /// #103: the READ-ONLY device-config read report — what `GET_DEVICE_CONFIG_VALUE`(121) and
    /// `GET_FF_VALUE`(128) answer when asked for a key's VALUE (the #761 follow-up), or the waiting
    /// sentinel while the walk runs. Nothing is written to the strap to produce it. Cleared on disconnect
    /// and on dialog dismiss. Twin of the Android WhoopBleClient.deviceConfigProbe flow.
    @Published public var deviceConfigProbe: String? = nil

    /// #174: the R22 DISABLE report — the per-key result of writing `'0'` to the sixteen feature flags and
    /// reading every one of them back with `GET_FF_VALUE`(128), or the waiting sentinel while the run walks.
    /// Unlike the two probes above this one DOES write, which is exactly why it reports the value the strap
    /// stores rather than the write's own ack. Cleared on disconnect and on dialog dismiss. Twin of the
    /// Android WhoopBleClient.r22DisableReport flow.
    @Published public var r22DisableReport: String? = nil

    /// Wrist-wear state from WRIST_ON/WRIST_OFF events. Defaults true so wear-gated features work
    /// before the first event arrives; flipped by FrameRouter on a real event.
    @Published public var worn: Bool = true

    /// #580 — true when a connected WHOOP 5/MG streams live HR fine but its firmware hands over no history
    /// offload (consecutive empty backfills). Lets the home state read "connected, history sync is
    /// experimental on 5.0" instead of a WHOOP-4-style "not recording"/sync-error. Reset on connect/disconnect.
    @Published public var historySyncExperimental: Bool = false

    // MARK: - Standard fitness-sensor live metrics (RSC / CSC / CPS — additive, never HR)
    //
    // Live instantaneous speed / cadence / power from a connected standard fitness sensor (a footpod, a
    // bike speed/cadence sensor, a power meter) read ALONGSIDE the HR profile by `StandardHRSource`. These
    // are a PURE ADDITIVE surface for the in-exercise readout: they never touch `heartRate`, `rr`, or any
    // scoring input — a workout is still recorded by the existing HR-driven live-workout flow. nil when no
    // such sensor is connected / before its first packet; cleared on disconnect so a stale panel can't
    // outlive the link. Honest: speed/cadence from CSC/CPS are DERIVED from successive packets, so they
    // appear only once two have arrived.

    /// Instantaneous speed in km/h from a connected RSC/CSC/CPS sensor (RSC direct; CSC/CPS derived).
    @Published public var sensorSpeedKmh: Double? = nil
    /// Instantaneous cadence — running steps/min (RSC) or crank rpm (CSC/CPS) — from a connected sensor.
    @Published public var sensorCadence: Double? = nil
    /// Instantaneous power in watts from a connected cycling-power (CPS) sensor.
    @Published public var sensorPowerWatts: Int? = nil

    /// Clear the standard fitness-sensor live metrics (called on disconnect / source teardown), the twin
    /// of `clearBiometrics()` for the additive sensor surface. Leaves HR + R-R untouched.
    public func clearSensorMetrics() {
        sensorSpeedKmh = nil
        sensorCadence = nil
        sensorPowerWatts = nil
    }

    /// True when ANY standard fitness-sensor metric is currently present — drives whether the additive
    /// in-workout sensor readout shows at all (it stays hidden until a real sensor feeds a value, so a
    /// workout with only HR looks exactly as it does today).
    public var hasSensorMetrics: Bool {
        sensorSpeedKmh != nil || sensorCadence != nil || sensorPowerWatts != nil
    }

    /// Pure, honest display strings for the additive in-workout sensor readout. Each returns nil when the
    /// sensor hasn't sent that field (the UI then hides the tile rather than showing a fabricated value).
    /// Units are the sensor's native ones, no unit-conversion guessing: speed km/h (the decode/derivation
    /// unit), cadence per-minute (steps/min for a footpod, crank rpm for a bike sensor — both "/min", and
    /// LiveState doesn't carry the kind, so the neutral honest label is used), power watts. Mirrors the
    /// JVM-tested Kotlin `StandardHrSource.formatSensor*` so the two platforms read identically. `static`
    /// so they're trivially unit-testable away from the @MainActor instance.
    static func formatSpeedKmh(_ kmh: Double?) -> String? {
        guard let kmh, kmh.isFinite, kmh >= 0 else { return nil }
        return String(format: "%.1f", kmh)
    }
    static func formatCadence(_ perMin: Double?) -> String? {
        guard let perMin, perMin.isFinite, perMin >= 0 else { return nil }
        return String(Int(perMin.rounded()))
    }
    static func formatPowerWatts(_ watts: Int?) -> String? {
        guard let watts, watts >= 0 else { return nil }
        return String(watts)
    }
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    // MARK: - Connection status (single source of truth, #266)

    /// Short connection-status label shared by the sidebar footer (RootView) and the Settings strap
    /// card, so the two can't disagree the way they did in #266 (sidebar "Connecting…" vs Settings
    /// "Connected" for the same connected-but-unbonded 5/MG link). Once the link is up and HR is
    /// flowing — even over the unbonded standard profile — this reads "Connected", never "Connecting…".
    public var connectionStatusLabel: String {
        if connected && bonded { return "Bonded · streaming" }
        if connected { return "Connected" }
        if bonded { return "Bonded · idle" }
        return "Disconnected"
    }
    /// True when the link is up (HR flowing) → status reads green. Drives the sidebar + Settings tone.
    public var connectionStatusIsActive: Bool { connected }
    /// True when previously paired but not currently connected → amber.
    public var connectionStatusIsIdle: Bool { !connected && bonded }

    /// Fired (live only) when the strap reports a DOUBLE_TAP gesture. Wired by AppModel to the
    /// user's chosen action. Debounced in AppModel.
    public var onDoubleTap: (() -> Void)?
    /// Fired (live only) when wrist-wear changes (true = put on, false = taken off).
    public var onWristChange: ((Bool) -> Void)?
    /// Fired (live only) when the strap reports it executed its firmware alarm
    /// (STRAP_DRIVEN_ALARM_EXECUTED). Wired by AppModel to re-arm the next day's alarm.
    public var onSmartAlarmFired: (() -> Void)?

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Set when an offload ended abnormally (the idle watchdog fired — the strap went quiet mid-sync),
    /// so a stalled history download isn't silent. Cleared by the next successful HISTORY_COMPLETE.
    /// Process-local on purpose (mirrors Android, ed6a31d): the next connect / 15-min tick re-offloads
    /// anyway, so persisting a stale error across launches would outlive its relevance.
    @Published public var lastSyncError: String? = nil

    /// True while a historical offload session is running, so screens can say "Syncing strap
    /// history…" instead of presenting half-loaded data as final (#77).
    @Published public var backfilling = false
    /// Chunks acked during the current offload session — an honest progress signal (total pending is
    /// unknowable from the protocol, so a count, never a percent).
    @Published public var syncChunksThisSession: Int = 0

    /// Undecodable HISTORICAL_DATA record frames seen this offload session whose raw bytes WERE
    /// preserved to the on-device archive (#77 / #91). Drives the honest "saved on this Mac" sync
    /// status. Reset at session start.
    @Published public var rejectedFramesThisSession: Int = 0
    /// Undecodable record frames the archive could NOT preserve this session (the ~5 MB cap was
    /// reached). Kept separate so the sync status never claims "saved" for bytes that were not.
    @Published public var rejectedFramesUnarchived: Int = 0
    /// Per-session chunk tallies that separate an EMPTY completed sync (the strap handed over only
    /// console/diagnostic frames — it isn't banking to flash, #77 family) from a clean one. Reset at
    /// session start. `decodedChunks == 0` with `consoleChunks` high ⇒ the strap's clock has lost sync.
    @Published public var decodedChunksThisSession: Int = 0
    @Published public var consoleChunksThisSession: Int = 0

    /// EXPERIMENTAL R22 telemetry (#174). How many of the 15 `enable_r22_*` SET_CONFIG flags the strap
    /// has ACKed since the last "Send enable sequence" tap — 15 means the strap accepted the whole
    /// sequence (hardware-confirmed: it returns a COMMAND_RESPONSE per flag). Reset on each new attempt.
    @Published public var r22FlagsAccepted: Int = 0
    /// Count of type-0x2F records seen this session OUTSIDE our own history offload. #494 showed these are
    /// historical-offload data (e.g. another BLE client pulling the strap's backlog over the shared notify
    /// channel), NOT a separate live R22 stream — type-0x2F is only ever the historical offload. Kept as a
    /// diagnostic counter, not a "deep stream unlocked" signal. Reset per session.
    @Published public var deepPacketsThisSession: Int = 0

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    /// Number of WHOOP 5/MG ("puffin") frames captured this session (when frame capture is enabled in
    /// Settings → Experimental). Drives the capture status line + export button.
    @Published public var puffinCaptureCount: Int = 0
    /// On-disk location of the current puffin capture file, once anything has been flushed. The
    /// Settings "Export" / "Reveal" actions target this URL.
    @Published public var puffinCaptureURL: URL?

    /// Set when a WHOOP 5/MG strap refuses the encrypted bond on first connect ("Encryption/Authentication
    /// is insufficient") — CoreBluetooth won't start a fresh just-works bond against a strap still bonded to
    /// the official WHOOP app. Surfaced as actionable pairing-mode guidance; cleared once the link bonds.
    @Published public var pairingHint: String? = nil

    /// Set when a connect attempt fails because the strap wiped its bond ("Peer removed pairing
    /// information") — a firmware update, or the official WHOOP app re-bonding it. macOS keeps re-presenting
    /// the now-stale pairing key, so reconnects loop on the same error with no recovery. Carries an
    /// actionable forget-and-re-pair guide; cleared on the next successful connect. (5/MG firmware reset, 2026-06)
    @Published public var reconnectGuide: String? = nil

    /// Set when NOOP detects a marginal Bluetooth radio that can't sustain the WHOOP 4 R10/R11 raw realtime
    /// stream (#80 — a 2016 Mac / OpenCore drops the link the instant that high-bandwidth burst is armed).
    /// After repeated arm-then-timeout cycles NOOP stops arming the heavy stream and falls back to the
    /// low-bandwidth 0x2A37 standard Heart Rate profile, so live HR can still flow on a radio that otherwise
    /// looped forever. Informational note for the Live screen; cleared on a clean reconnect or Live re-open.
    @Published public var standardHRMode: String? = nil

    public init() {}

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        bankBatterySample(pct)
        onBatteryUpdate?(pct)
    }

    /// Append a SoC reading to the rolling `batterySamples` buffer for the runtime estimate (#713). The
    /// strap emits battery events every ~8 minutes, so we skip a reading that's the SAME % as the last one
    /// within ten minutes (a duplicate event, not new discharge information) to keep the slope fit clean;
    /// any change in %, or enough elapsed time, banks a fresh point. The oldest readings fall off once the
    /// buffer is full. `now` is injectable so the estimate is unit-testable without a live clock.
    func bankBatterySample(_ pct: Double, now: Int = Int(Date().timeIntervalSince1970)) {
        if let last = batterySamples.last, last.soc == pct, now - last.ts < 600 { return }
        batterySamples.append((ts: now, soc: pct))
        if batterySamples.count > Self.maxBatterySamples {
            batterySamples.removeFirst(batterySamples.count - Self.maxBatterySamples)
        }
        // Battery test mode: one tagged (t, soc) line per banked reading, gated zero-cost when off (the
        // gate is one UserDefaults bool read, and the string below is only built when the mode is on).
        // Rides the redacting sink; the banked SoC series is the readout + trace source (#713, Test Centre).
        if TestCentre.active(.battery) {
            append(log: "bank soc=\(String(format: "%.1f", pct)) t=\(now)s", domain: .battery)
            // Also emit the discharge-run / slope / gate ANALYSIS trace, once per banked reading. The strap
            // banks at most one SoC point every ~8 minutes (the dedup above), so this is a natural throttle,
            // never a tight loop. emitBatteryTrace re-checks the same gate and is pure (it reads batteryEstimate,
            // changing no displayed number), so the headline "~X left" badge is unaffected. (#713, Test Centre.)
            emitBatteryTrace()
        }
    }

    /// Seed the SoC buffer from the persisted battery table on connect/bootstrap (#7). `batterySamples` is
    /// otherwise fed ONLY by live BLE events (`bankBatterySample`), so after a reconnect the "~X days left"
    /// estimate restarted from an empty buffer and ignored the long discharge history already on disk.
    /// Android seeds from its persisted battery table over a 14-day window; iOS/macOS did not, so the two
    /// platforms diverged. The BLEManager bootstrap path does one async read of the persisted series and
    /// passes it here. De-dupes against any points already banked from live events this session (by ts) so a
    /// seed that races a couple of live readings can't double-count them, then re-sorts and caps the buffer.
    /// Only banks the historical points that aren't already present, so calling it twice is idempotent.
    public func seedBatterySamples(_ seed: [(ts: Int, soc: Double)]) {
        guard !seed.isEmpty else { return }
        let existing = Set(batterySamples.map { $0.ts })
        let fresh = seed.filter { !existing.contains($0.ts) }
        guard !fresh.isEmpty else { return }
        batterySamples.append(contentsOf: fresh)
        batterySamples.sort { $0.ts < $1.ts }
        if batterySamples.count > Self.maxBatterySamples {
            batterySamples.removeFirst(batterySamples.count - Self.maxBatterySamples)
        }
    }

    /// Drop the banked SoC buffer (called on disconnect) so a stale runtime estimate can't outlive the
    /// link, the twin of the `charging = nil` clear on the same path.
    public func clearBatterySamples() {
        batterySamples.removeAll()
    }

    /// Single funnel for R-R intervals from EITHER source (the standard 0x2A37 profile in BLEManager,
    /// the REALTIME_DATA frame in FrameRouter). Updates the fresh-packet `rr` AND appends the valid
    /// intervals onto the bounded `rrRecent` rolling buffer so the Live console can show a moving
    /// strip. Non-positive sentinels (a strap "no interval this beat" placeholder) are dropped from the
    /// rolling buffer. `recentLimit` caps the buffer; the oldest intervals fall off first.
    public func setRRIntervals(_ intervals: [Int], recentLimit: Int = 60) {
        rr = intervals
        let valid = intervals.filter { $0 > 0 }
        guard !valid.isEmpty else { return }
        rrRecent.append(contentsOf: valid)
        if rrRecent.count > recentLimit {
            rrRecent.removeFirst(rrRecent.count - recentLimit)
        }
    }

    /// Blank all live biometric readouts (HR + R-R + the rolling buffer) so a stale heart rate or
    /// R-R strip can't outlive the link. Called on CoreBluetooth disconnect (BLEManager), the twin of
    /// the `charging = nil` / `encryptedBond = false` clears on the same path.
    public func clearBiometrics() {
        heartRate = nil
        rr.removeAll()
        rrRecent.removeAll()
        clearBatterySamples()   // a stale runtime estimate must not outlive the link either (#713)
        recentHrSamples.removeAll()       // Sleep readout buffers must not outlive the link (Group E)
        recentGravitySamples.removeAll()
        clearStrapRange()                 // a stale clock-drift window must not outlive the link either
        lastFrameAtUnix = nil             // #987: a stale "last frame" freshness must not outlive it either
        ouraWearState = nil               // a stale worn/charging badge must not outlive the link either
        // Perf: flush the durable log tail on disconnect (mirroring is batched in `append`), so a completed
        // session's tail is always persisted for a later scheduled export despite the per-line throttle.
        Self.persistTail(log)
        logsSincePersist = 0
    }

    /// Cap on the in-app strap-log ring buffer. Raised from the old ~1h (200 lines) to retain a rolling
    /// ~24h of activity (#510 — maddognik's protocol RE wants a full day to correlate against): a busy
    /// live session emits a few lines a minute, so 5,000 lines comfortably spans a day. Each line is a
    /// short redacted string (~100 bytes), so the worst-case buffer is well under ~1 MB — bounded, never
    /// unbounded. Drives the Live log card AND the shareable `exportableLogText()`.
    static let maxLogLines = 5_000

    /// Perf: the durable UserDefaults tail (`persistTail`) only feeds a scheduled export that fires hours
    /// later, so it needn't be current to the last line. Mirroring the whole tail on EVERY append was a
    /// hot-path cost that grew as more diagnostics (offload/backfill/#700/#714/#720) funnel through this one
    /// sink. Persist in batches of `persistEveryNLines` instead, and always flush on disconnect
    /// (`clearBiometrics`) so a finished session stays durable; a few unmirrored lines on an abrupt kill is
    /// harmless for a debug tail. iOS-only — Android's `logBuffer` is an O(1) `ArrayDeque` with no per-line
    /// persist, already correct.
    private static let persistEveryNLines = 32
    private var logsSincePersist = 0
    /// Amortize the ring trim: let the buffer overrun by this slack, then trim back to the cap in one batch
    /// — turning an O(n) `Array.removeFirst` on every line at steady state into one per `trimSlack` lines.
    /// Still hard-bounded (never exceeds `maxLogLines + trimSlack`).
    private static let trimSlack = 256

    public func append(log line: String, domain: TestDomain? = nil) {
        // Tag inert when nil (today's behaviour, byte-identical). When tagged, prefix a compact,
        // parseable marker the export filters on. Redaction is STILL the only scrub point
        // (redactPii below); tagging happens BEFORE redaction so the scrub covers the whole line.
        let tagged = domain.map { "[\($0.id)] " + line } ?? line
        log.append(Self.redactPii(tagged))
        // Batched trim: overrun by `trimSlack`, then trim back to the cap in one shot (amortized O(1)/line).
        if log.count > Self.maxLogLines + Self.trimSlack { log.removeFirst(log.count - Self.maxLogLines) }
        // Batched durable-tail mirror: persist every `persistEveryNLines` lines, not on every line;
        // `clearBiometrics()` flushes on disconnect so a completed session is always fully mirrored.
        logsSincePersist += 1
        if logsSincePersist >= Self.persistEveryNLines {
            logsSincePersist = 0
            Self.persistTail(log)
        }
        // #990: fold the Backfiller's per-session "session persisted N rows" summary into the persisted
        // ALL-TIME drained-rows tally, right here at the single log sink (no new BLE seam). The summary
        // is emitted unconditionally whenever rows landed (#150), so the cumulative counter accrues on
        // every session, not only while the Connection test mode is on. The contains() pre-check keeps
        // the common per-line cost to one substring scan.
        if line.contains("session persisted"), let rows = ConnectionReadout.drainedRowsFromSummary(line) {
            TestCentre.noteDrainedRows(rows)
        }
    }

    /// The in-app log lines tagged for one test domain (for the Test Centre live readout). Read-only,
    /// no side effects; the prefix is the same one `append(log:domain:)` writes, and redaction never
    /// strips it (the tag is prepended before the scrub, which only touches identifiers). (Group E)
    public func taggedTail(domain: TestDomain) -> [String] {
        let prefix = "[\(domain.id)] "
        return log.filter { $0.hasPrefix(prefix) }
    }

    // MARK: - Durable log tail (#510, scheduled debug export)

    /// The in-memory `log` lives only for the life of the process, so a scheduled debug auto-export that
    /// fires hours after the last live session (the Apple analogue of Android's `StrapLogBuffer`) would
    /// otherwise find nothing to write. We mirror the rolling log to a single UserDefaults key so the
    /// scheduled export can read the last day's lines even with no live BLE session open. Small and
    /// bounded: capped to the tail (`tailLimit`, well under `maxLogLines`) of short redacted strings, so
    /// the persisted blob stays a few hundred KB at most. On-device only; nothing is sent anywhere.
    private static let tailKey = "strapLog.tail"
    /// How many recent lines the durable tail retains — a sensible day's worth for a scheduled export,
    /// smaller than the live `maxLogLines` ring so the persisted copy stays modest.
    static let tailLimit = 2_000

    /// Mirror the most recent `tailLimit` lines to UserDefaults (called from `append`). Synchronous and
    /// cheap (a single small array write); UserDefaults coalesces the disk flush. `nonisolated` (touches
    /// only UserDefaults, no actor state) so the background/static export path can read the twin getter.
    nonisolated private static func persistTail(_ lines: [String]) {
        let tail = lines.count > tailLimit ? Array(lines.suffix(tailLimit)) : lines
        UserDefaults.standard.set(tail, forKey: tailKey)
    }

    /// The persisted log tail, newest-last — what a scheduled export reads when no live session is open.
    /// Empty if nothing has ever been logged on this device. `nonisolated` so a background task with no
    /// main-actor instance can read it.
    nonisolated public static func persistedLogTail() -> [String] {
        (UserDefaults.standard.array(forKey: tailKey) as? [String]) ?? []
    }

    /// A shareable strap-log body sourced from the DURABLE tail, for a background / scheduled export that
    /// runs with no live `LiveState` instance. Mirrors `exportableLogText()`'s header so a scheduled drop
    /// reads the same as a manual share; falls back to the live `log` is not available here by design
    /// (this is a `static` so a background task needs no main-actor instance).
    nonisolated public static func scheduledExportText(extraHeaderLines: [String] = []) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let osName = "iOS"
        #else
        let osName = "macOS"
        #endif
        var header = "NOOP strap log (scheduled export) — \(osName)\nApp: \(v)\n\(osName): "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        if !extraHeaderLines.isEmpty { header += extraHeaderLines.joined(separator: "\n") + "\n" }
        header += String(repeating: "-", count: 40) + "\n"
        return header + persistedLogTail().joined(separator: "\n")
    }

    /// Scrub personal identifiers from a strap-log line so it's safe to share publicly (#445): BLE MAC
    /// addresses are masked to their first + last byte, the WHOOP's SERIAL — carried in its device
    /// name ("WHOOP 4C1594026") and tied to the owner's account — is removed, and the CoreBluetooth
    /// peripheral identifier (a per-install random UUID iOS/macOS print in "Discovered …(<uuid>)" lines)
    /// is masked. Applied at the single log sink (BLEManager + the generic-HR diagnostics both feed it).
    /// MACs require colons, so hex command payloads are untouched; the dotted model names ("WHOOP
    /// 4.0"/"5.0") don't match the serial pattern. The UUID rule deliberately KEEPS standard-BLE-base
    /// UUIDs (…-0000-1000-8000-00805f9b34fb, e.g. the 0x2A37 HR characteristic) and the WHOOP vendor
    /// service base (…-8d6d-82b8-614a-1c8cb0f8dcc6) — those are public, identical on every strap, and
    /// are exactly the GATT diagnostics a shared log needs to be useful (#421). Thanks @ujix (#447) for
    /// catching the peripheral-UUID leak; this is a targeted form so we don't redact the service UUIDs.
    nonisolated static func redactPii(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: "([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})",
            with: "$1:••:••:••:••:$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "WHOOP (\\d[0-9A-Za-z]{5,})", with: "WHOOP <serial>", options: .regularExpression)
        // Mask a CoreBluetooth peripheral UUID, but NOT a standard-BLE / WHOOP-vendor service UUID.
        out = out.replacingOccurrences(
            of: "(?![0-9A-Fa-f]{8}-(?:0000-1000-8000-00805f9b34fb|8d6d-82b8-614a-1c8cb0f8dcc6))[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<device>", options: [.regularExpression, .caseInsensitive])
        return out
    }

    /// The full, shareable strap log for a bug report (issue #17): a header carrying the app version,
    /// OS, and — on iOS — the environment diagnostics that actually cause issues, followed by the live
    /// session log. Shared so BOTH the Live screen's log card AND a macOS Settings shortcut (#507 — a 4.0
    /// owner couldn't find the log on Mac) build the SAME text. Call on the main thread (button taps).
    func exportableLogText(extraHeaderLines: [String] = []) -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let osName = "iOS"
        #else
        let osName = "macOS"
        #endif
        var header = "NOOP strap log - \(osName)\nApp: \(v)\n\(osName): "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
        #if os(iOS)
        let diagLines = IOSDiagnostics.capture().summaryLines()
        if !diagLines.isEmpty { header += diagLines.joined(separator: "\n") + "\n" }
        #endif
        if !extraHeaderLines.isEmpty { header += extraHeaderLines.joined(separator: "\n") + "\n" }
        header += String(repeating: "-", count: 40) + "\n"
        return header + log.joined(separator: "\n")
    }
}
