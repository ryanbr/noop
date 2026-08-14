import Foundation
import Combine
import CoreBluetooth
import Security
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen 3/4/5), driven by the clean-room
/// `OuraProtocol.OuraDriver`.
///
/// This is a real transport (it replaced an earlier honest dead-end probe): it decodes the ring's OWN
/// raw signals + open event tags (HR / IBI / HRV / SpO2 / temp / sleep-phase / battery), persists them
/// under the ring's `deviceId`, and lets NOOP compute its own Charge/Rest from those streams exactly like
/// a WHOOP day. It NEVER reads or surfaces Oura's encrypted readiness/sleep scores (honest-data
/// invariant), and when a signal can't be read it stays at "-", never a fabricated value (Huami precedent).
///
/// WHOOP-FIRST ISOLATION (identical to `StandardHRSource` / `HuamiHRSource`): this class runs its OWN
/// `CBCentralManager` and never imports, calls, or shares state with `BLEManager` / `WhoopBleClient`. The
/// WHOOP path cannot regress. The only shared surfaces are `LiveState` and the injected closures
/// (`persist`, `log`, `onBattery`). All BLE specifics live here; all protocol specifics live in the pure,
/// headless-testable `OuraDriver` (no CoreBluetooth in that package).
///
/// Honest about the handshake, step by step:
///   1. Scan for the Oura GATT service and filter discoveries by `OuraRingGen.recognise`.
///   2. Connect, discover the write/notify characteristics, enable notifications on ...0003.
///   3. Run the application auth challenge through `OuraDriver` (GetAuthNonce -> compute proof ->
///      Authenticate). The 16-byte install key is injected via `authKey`; when it is nil (or auth fails
///      because the ring is in factory reset / wrong key) we surface an HONEST `needsPairing` message and
///      stream NO data rather than faking one.
///   3a. ADOPT (factory-reset ring + explicit consent only): when the ring is in factory reset (auth status
///      `inFactoryReset` / no key) AND `adoptIntent == true`, the transport PROVISIONS a fresh 16-byte key:
///      it writes the dangerous `0x24` install, awaits the `0x25` OK ack, persists the key to `OuraKeyStore`,
///      then re-runs auth with the new key (s3.2). Without `adoptIntent` the dangerous opcode is NEVER sent;
///      we announce needs-pairing instead. A failed install is honest (Failed), never a fake success.
///   4. On auth success, run the gen-appropriate live-HR enable triplet; HR/IBI then streams as 0x2F
///      sub-op 0x28 pushes which the driver decodes.
///   5. Once streaming, also run a `GetEvents` HISTORY FETCH (s5) from the last-persisted cursor, and
///      periodically thereafter. Skin temp and SpO2 are SLEEP-ONLY on this hardware (neither ever arrives
///      as a live push, only as banked history), so the fetch is the only way last night's readings ever
///      reach the app. Fetched records are stamped with their real ring-time-anchored UTC (s5.5, from the
///      ring's own 0x42 time-sync event), NOT the wall-clock arrival time, so "last night" data is never
///      mis-timestamped as "now".
///   6. Decoded events map onto `Streams` via `OuraStreamMapping` and persist in batches; live HR also
///      feeds `LiveState`. Temp/SpO2/HRV/sleep-phase persist ONLY (no live surface - they are last-night
///      values, not a live readout). Battery is requested once streaming starts (`GetBattery`, 0x0C ->
///      0x0D) and feeds `onBattery`/`batteryPct`.
@MainActor
public final class OuraLiveSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// An Oura ring seen during a scan.
    public struct DiscoveredRing: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        /// Best-effort generation guess from the advertised name (confirmed by the model the user picks).
        public let detectedGen: OuraRingGen?
    }

    /// The coarse adopt outcome the wizard observes while it is in its "Taking over your ring" state, so it
    /// can drive Adopting -> success (on `.streaming`/connected) and Adopting -> an honest Failed (on
    /// `.failed`). It is ONLY meaningful for an adopt-intent connection; a read-only connect stays `.idle`
    /// until it streams (or surfaces `needsPairing`). PARITY: the Android twin exposes the same coarse
    /// adopt outcome the Compose wizard observes to leave its Adopting step.
    public enum AdoptPhase: Equatable, Sendable {
        case idle            // no adopt in flight (the default; a read-only connect never leaves this until streaming)
        case installingKey   // the dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running)
        case streaming       // auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete
        case failed          // an honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success
    }

    @Published public private(set) var discovered: [DiscoveredRing] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var batteryPct: Int? = nil
    /// Set to an HONEST explanation string when the ring needs a pairing/key handshake NOOP can't complete
    /// (no install key, or the ring is in factory reset, or the key was rejected). nil otherwise. The UI
    /// surfaces this instead of a fake reading. Cleared on stop/disconnect.
    @Published public private(set) var needsPairing: String? = nil
    /// The live adopt outcome (see `AdoptPhase`). The wizard observes this to leave its Adopting step. Reset
    /// to `.idle` on every connect/stop/disconnect so a stale outcome never drives a transition.
    @Published public private(set) var adoptPhase: AdoptPhase = .idle

    // MARK: - BLE UUIDs (from the platform-pure OuraGatt facts)

    /// The Oura base service (gen3/4/5). `OuraGatt` keeps the raw strings so the package stays
    /// CoreBluetooth-free; the app turns them into `CBUUID` here.
    private static let service = CBUUID(string: OuraGatt.serviceUUID)
    private static let writeChar = CBUUID(string: OuraGatt.writeCharacteristicUUID)
    private static let notifyChar = CBUUID(string: OuraGatt.notifyCharacteristicUUID)

    /// iOS state-restoration identifier for the PERSISTENT Oura central (#1213). DISTINCT from the WHOOP
    /// central's `BLEManager.restoreID` — each restoring `CBCentralManager` needs its own unique id.
    private static let restoreID = "com.openwhoop.ble.oura"

    /// The `0x25` SetAuthKey-response outer opcode (`25 01 <status>`, status `0x00` = OK). Per
    /// OURA_PROTOCOL.md s3.2. This is the install-ack the adopt key-install awaits.
    private static let setAuthKeyRespOp: UInt8 = 0x25

    /// Outer-frame ops a GetProductInfo (`0x18`) reply can arrive under. The request op is `0x18`; by the
    /// request→response +1 convention seen elsewhere (GetBattery `0x0C` request → `0x0D` reply) the reply may
    /// be `0x19`. We capture both so the fixture lands whatever the firmware uses (#771/#772 capture). Neither
    /// is an event tag (tags are ≥ 0x41), so peeking them never disturbs the TLV decode.
    private static let productInfoResponseOps: Set<UInt8> = [0x18, 0x19]

    /// A GetProductInfo string is a usable ring SERIAL only when it is plain alphanumeric and a sane length —
    /// so a misframed/garbage reply can never mint a bogus `oura-<serial>` identity (#771 honest-data guard).
    /// The captured Gen3 serial "2H3B2405003655" (14 chars) passes; the hardware id "BLB_03" (underscore) does
    /// not — but it is already routed to the generation path before this is reached.
    private static func isPlausibleSerial(_ s: String) -> Bool {
        (8...24).contains(s.count) && s.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Local-time formatter for logging a decoded date/time next to a raw ring-tick cursor value, so a
    /// number like "1178203" reads as an actual date instead of an opaque tick count. Logging only.
    private static let cursorDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Decode a ring-tick cursor value to a human-readable local date/time via the driver's current
    /// session anchor (s5.5), or "no anchor yet" when none has arrived yet this session (honest: never
    /// guesses a time). Investigation/logging only.
    private func describeCursor(_ cursor: UInt32) -> String {
        guard let driver, let seconds = driver.unixSeconds(forRingTimestamp: cursor) else {
            return "no anchor yet"
        }
        return Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // MARK: - Dependencies (injected - no BLEManager / WhoopBleClient reference)

    private let live: LiveState
    private let deviceId: String
    private let persist: (Streams) -> Void
    /// Upsert the ring-PROVIDED reconstructed hypnogram as a `CachedSleepSession` (banked under the ring's
    /// own `deviceId`, the imported/measured side, so `SleepMerge`'s imported-over-computed rule makes
    /// Oura's own SleepNet staging win over NOOP's sparse-motion computed night — "richer record wins").
    /// Wired at the composition root to `store.upsertSleepSessions([_], deviceId:)`; default no-op so the
    /// discovery-only scanner and tests take the byte-identical inert path.
    private let persistSleepSession: (CachedSleepSession) -> Void
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// Fired with the ring's TRUE model label ("Oura Ring 3/4/5") once the GetProductInfo hardware id resolves
    /// a generation on connect, so the app can correct a registry row mis-stamped from the advertised name
    /// (#772). Default no-op (the discovery-only scanner and unit paths don't correct anything).
    private let onModel: (String) -> Void
    /// Fired with the ring's STABLE serial (e.g. "2H3B2405003655") once the GetProductInfo serial page is read
    /// on connect, so the app can re-point this device onto its `oura-<serial>` id — the identity that survives
    /// a re-pair, unlike the CoreBluetooth UUID (#771). Default no-op. Only plausible serials are surfaced.
    private let onSerial: (String) -> Void
    /// The ring generation (carried on `PairedDevice.model`, recovered via `OuraRingGen.from(model:)`).
    /// Selects the MTU clamp, which characteristics to discover, and the live-HR command set.
    private let ringGen: OuraRingGen
    /// Supplies the 16-byte application install key (from the Keychain) for this ring, or nil. A nil key
    /// drives the honest `needsPairing` path: the driver answers `.needsKeyInstall` and we never fake data.
    private let authKey: () -> Data?
    /// When false (the wizard's discovery-only scanner) this source never writes `LiveState` or persists.
    private let feedsLive: Bool
    /// EXPLICIT, USER-GRANTED adopt consent for THIS connection. Default FALSE. The dangerous installKey
    /// opcode (`0x24`) may be sent ONLY when this is true: it is what gates the post-factory-reset key
    /// provisioning (s3.2). It is set true by the adopt flow AFTER the wizard's irreversible-consent gate
    /// (the consent tick AND the "Take over this ring?" confirm), and it gates the driver's `allowKeyInstall`
    /// so a read-only / Advanced-key connection can NEVER install a key. Set once at construction (the
    /// coordinator builds a fresh source per connection, so a new value just means a new source).
    private let adoptIntent: Bool

    // MARK: - Protocol state machine (pure - holds NO BLE handle)

    /// The transport-agnostic driver. Re-created on each connect so a fresh session re-runs auth (the
    /// app key is session-scoped). nil until a connection begins.
    private var driver: OuraDriver?
    /// Reassembles notification fragments into complete TLV inner records across feeds.
    private let reassembler = OuraReassembler()
    /// Accumulates the ring's burst-written sleep-phase records so a night's hypnogram can be laid out
    /// backward at the 30 s SleepNet epoch from the anchored burst end (the envelope time marks the
    /// analysis WRITE moment, not the sleep). Flushed at drain end and teardown; reset per connection.
    private let hypnogramAssembler = OuraHypnogramAssembler()
    /// Closed bursts that could not anchor yet (no 0x42 this session so far) — held and reconstructed
    /// the moment the anchor lands, mirroring the pendingAnchorEvents hold-until-anchor discipline.
    /// NEVER persisted at wall-clock (the burst end IS the night's time axis); if the session ends
    /// unanchored they are dropped honestly — the resume cursor did not advance, so the ring re-serves
    /// the same records next drain. Reset per connection.
    private var pendingUnanchoredBursts: [OuraHypnogramBurst] = []

    /// Live wear/charge indicator: a LIVE-HR push (.hr) means the ring is on a finger; the ring's own "chg.
    /// detected"/"stopped" STATE strings bracket a charging period. Fed ONLY from the live push and STATE
    /// (never a banked .ibi, which can be a past-night re-serve) and only while `feedsLive`. Mirrored to
    /// `live.ouraWearState` for the On-wrist / Off-wrist UI.
    private let wearTracker = OuraWearTracker()
    private var loggedWearState: OuraWearState?
    /// When the last LIVE-HR beat arrived. If the stream goes quiet for `wornPulseTimeout` while we are
    /// still re-engaging it, the ring came off the finger (there is no "removed" event) -> NOT WORN.
    private var lastLivePulseAt: Date?
    /// Grace before a silent live-HR stream means "removed": the ring auto-reverts DHR ~20 s and we
    /// re-engage every `reengageInterval` (15 s), so a worn ring resumes beats well within this; exceeding
    /// it means no finger. Checked on the re-engage tick, so worst-case detection is this + one interval.
    private let wornPulseTimeout: TimeInterval = 40

    /// Logs the FIRST live HR sample of a connection only (never every push); reset on stop/disconnect.
    private var loggedFirstHR = false
    /// The ring's optical HR needs a beat or two to settle after (re)subscribe, so the very first live-HR
    /// sample of a session is often an artifact (observed on-device). Drop exactly one, then stream
    /// normally. Reset on stop/disconnect alongside `loggedFirstHR`.
    private var droppedFirstLiveHR = false
    /// Logs the FIRST skin-temp sample DECODED THIS SESSION only (never every record); reset on
    /// stop/disconnect. These are last-night values from the history fetch, not live pushes, but we still
    /// only want one log line, not one per sample. Twin of `loggedFirstHR`.
    private var loggedFirstTemp = false
    /// Logs the FIRST SpO2 sample decoded this session only. Twin of `loggedFirstTemp`.
    private var loggedFirstSpo2 = false
    /// Logs the FIRST ring-time -> UTC anchor of this session only (s5.5); reset on stop/disconnect.
    private var loggedAnchor = false
    /// Tier-B (UNVERIFIED) kinds ("activity" / "real_steps" / "sleep_summary" / "spo2_smoothed") already
    /// logged this session, so a repeated tag logs once per KIND, not once per record. INVESTIGATION
    /// ONLY (see the `allowTierB: true` comment at driver construction) - the log is how we collect raw
    /// captures to validate these layouts; nothing here ever persists or scores. Reset on stop/disconnect.
    private var loggedTierBKinds: Set<String> = []
    /// Feature ids whose status we have already logged this session (SpO2 0x04 / real_steps 0x0b), so the
    /// read-only feature-status diagnostic prints once per feature, not on every reconnect.
    private var loggedFeatureStatuses: Set<Int> = []
    /// Product-info replies already logged this session, keyed by op+body so the #771/#772 serial/hardware
    /// capture prints each DISTINCT reply once — get_serial and get_hardware both answer under op 0x19, so a
    /// per-op guard would swallow the second (observed on-device: only the serial reached the log). Distinct
    /// bodies each log once; identical re-serves are suppressed. Reset on stop/disconnect.
    private var loggedProductInfo: Set<String> = []

    /// 0x71 green_ibi_amp fixture capture (upstream #287/#333): EVERY occurrence is logged with its
    /// anchored time + envelope rt + length + full raw bytes (a verified decoder needs several real
    /// payloads, and the anchored time aligns each with concurrent live-HR R-R). Capped per session so a
    /// night-long green-IBI wall can't flood the log; the count + observed lengths are summarized at
    /// drain end regardless. Reset on stop/disconnect/connect.
    private var greenIbiAmpCount = 0
    private var greenIbiAmpLengths: Set<Int> = []
    private static let greenIbiAmpLogCap = 50

    /// The recent 0x49 sleep_summary_1 windows (ringverse: start/end offsets in MINUTES BEFORE the event
    /// time), stashed so the hypnogram burst each one belongs to can anchor its END at the TRUE sleep end
    /// (`event − end_offset`) instead of the SleepNet WRITE moment. Validated 2026-07-13: the write
    /// trailed the real sleep end by 43 min, shifting the whole reconstructed night +43 min; the 0x49
    /// window matched the wearer's report within minutes (23:32→08:08 vs 23:34→08:03). The 0x49 arrives
    /// in the same finalization burst right BEFORE the phase records, so stash-then-match by ring-time
    /// proximity pairs them. A single drain can carry SEVERAL windows (e.g. an overnight AND a daytime
    /// nap), so this is a COLLECTION, not a single slot: keeping only the latest let a nap's 0x49 clobber
    /// the overnight's before the overnight burst finalized, and the overnight then fell back to its
    /// +4 h write time (2026-07-17 capture). Each burst matches its OWN window by ring-time proximity.
    /// Bounded (oldest dropped past the cap); reset per session.
    private var recentSleepWindows049: [(ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)] = []
    private static let recentSleepWindows049Cap = 16

    /// #1284 residual 3 (duplicate-generation diagnostic): the [start, end] window of each sleep session
    /// banked THIS connection. The session PK is (deviceId, startTs) and the burst end moves with the 0x49
    /// drain, so an early partial drain can bank a short session that a later full burst then nests inside,
    /// minting a second row that the #899 heal only cleans up afterward. Comparing each new persist against
    /// this list surfaces the GENERATION in the strap log. Diagnostic only; nothing is skipped. Bounded;
    /// reset per session with the 0x49 windows. Twin of Kotlin's recentPersistedSessionWindows.
    private var recentPersistedSessionWindows: [(start: Int, end: Int)] = []
    private static let recentPersistedSessionsCap = 16

    // MARK: - Activity (0x50 MET) estimate accumulation — INVESTIGATION ONLY
    // Aggregate the decoded 0x50 MET stream into an honest, clearly-labeled per-day estimate
    // (OuraActivityEstimator) logged at drain-end, for eyeballing against WHOOP active minutes / Apple
    // exercise minutes. Tier-B: never persisted, never scored, never a step count. Reset per connection.
    /// MET samples bucketed by LOCAL calendar day (key `yyyy-MM-dd`, so a bucket matches the WHOOP / Apple
    /// daily figure being compared), accumulated across the history drain.
    private var activityMETByDay: [String: [Double]] = [:]
    /// Cadence self-check state: the previous 0x50 record's UTC and sample count, plus the per-sample
    /// seconds observed between consecutive records — `(curr.utc - prev.utc) / prev.sampleCount`. The
    /// median pins the ring's MET epoch directly from the stream, validating `activityEpochSeconds`.
    private var lastActivityUtc: Int?
    private var lastActivitySampleCount = 0
    private var activityCadenceObs: [Double] = []
    /// Assumed per-sample epoch for the estimate log (the ONE calibration knob; the cadence self-check
    /// above measures the real value). 60 s = Oura's common 1-minute MET resolution.
    private let activityEpochSeconds: Double = 60
    /// Append-only JSONL research corpus for the raw 0x50 MET series (Tier-B, never scored/persisted to
    /// SQLite). Created only on a live/persisting source (nil for the discovery-only scanner). Deduped by
    /// ring-time so re-served records don't duplicate; logs its file path once when the first record lands.
    private let activityDump: OuraActivityDump?
    /// Append-only JSONL sidecar for the 0x47 motion vectors (Tier-A), for offline LSB→g calibration (#804).
    private let motionDump: OuraMotionDump?
    /// Append-only JSONL research corpus for 0x7E/0x7F real_steps_features (Tier-B, third-party
    /// [oura-rs] unpack formula, never scored/persisted to SQLite). See OuraRealStepsDump.
    private let realStepsDump: OuraRealStepsDump?
    /// Append-only JSONL capture of the RAW, undecoded history-drain notification bytes (`oura-raw-<id>.jsonl`).
    /// Complement to the decoded sidecars above: those show what NOOP interpreted, this shows exactly what the
    /// ring sent, so after a full connect a hole in a decoded file can be pinned as a decode drop vs ring-side.
    /// No dedup (a re-serve is still evidence the ring re-sent it); the offline reframer collapses duplicates.
    private let rawDump: OuraRawDump?
    /// Cached local-day formatter (the 0x50 stream is high-volume; avoid building one per record).
    private static let activityDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f   // local time zone by default
    }()

    // MARK: - Sleep-phase arrival visibility — INVESTIGATION ONLY
    // Log every 0x4B/0x4E/0x5A hypnogram record (anchored time + code count + stage histogram) so a
    // capture shows inline when/whether the ring transmits the night's phase timeline, and observe the
    // per-CODE cadence (record gap ÷ previous record's code count) to pin the ring's phase epoch — the
    // same technique that pinned the 60 s activity MET epoch. Reset per connection.
    private var lastPhaseUtc: Int?
    private var lastPhaseCodeCount = 0
    private var phaseCadenceObs: [Double] = []

    /// History-fetched events decoded BEFORE a ring-time -> UTC anchor exists this session, held here
    /// (with their own ring timestamp) until the anchor lands (`drainPendingAnchorEvents`), so they get
    /// their real historical time instead of a premature wall-clock guess. The ring's 0x42 time-sync can
    /// arrive anywhere in a history-fetch stream, not necessarily first, so records that land before it
    /// are parked here and re-stamped the moment an anchor lands. Drained with an honest wall-clock
    /// fallback at teardown if no anchor ever arrived this session (never silently dropped). Reset on
    /// stop/disconnect.
    private var pendingAnchorEvents: [(event: OuraEvent, ringTimestamp: UInt32)] = []
    /// True once the live-HR stream has been requested, so the disconnect handler can tell "we never got
    /// authenticated/streaming" (-> honest note) from "the link just dropped".
    private var reachedStreaming = false
    /// The freshly-generated 16-byte key written to the ring during an adopt key install. Held in memory
    /// ONLY between writing the `0x24` install and receiving the `0x25` ack: it is persisted to the keystore
    /// ONLY on an OK ack (so a failed/absent ack never leaves a key the next session would wrongly trust).
    /// Cleared on stop/disconnect/failure.
    private var pendingInstallKey: Data?

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    /// A peripheral asked to connect before `centralManagerDidUpdateState` reported `.poweredOn`.
    private var pendingConnectID: UUID?
    /// Peripherals retained by identifier so a chosen one survives until connection (exact
    /// StandardHRSource seenPeripherals/pendingConnectID/retrievePeripherals pattern).
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Auto-reconnect (#912)

    /// The paired ring we should keep re-reaching. Set by `connect(_:)`, cleared by `stop()`. While it is
    /// non-nil an INVOLUNTARY drop (or a failed connect) re-issues a connect on a capped backoff, so the
    /// ring comes back on its own once it's in range again, exactly like the WHOOP strap's auto-reconnect
    /// (BLEManager). WHOOP has this loop; the non-WHOOP sources never did, so a dropped Oura ring stayed
    /// down until a manual reconnect. This never touches the WHOOP path or the shared central queue.
    private var reconnectID: UUID?
    /// True while a teardown was USER/COORDINATOR-initiated (`stop()`), so the disconnect handler suppresses
    /// the auto-reconnect (mirrors BLEManager's `intentionalDisconnect`). Cleared on every `connect(_:)`.
    private var intentionalDisconnect = false
    /// Consecutive involuntary reconnect attempts, driving the capped-exponential backoff (3, 6, 12, 24,
    /// 48, 60s). Reset to 0 on a successful connect and on an explicit `connect(_:)`. Matches BLEManager
    /// (#414) and the Android `ReconnectBackoff` so a ring genuinely out of range doesn't hammer BLE.
    private var failedReconnectAttempts = 0

    /// After this many consecutive failures, stop scheduling timed retries and hand the reconnect to
    /// CoreBluetooth as a STANDING connect (see `issueStandingConnect`). Three keeps the quick 3s/6s
    /// retries that fix a transient blip while the app is awake, then gets out of the way.
    nonisolated static let standingConnectAfterAttempts = 3

    /// Floor between two standing connects, used ONLY for a near-instant failure (see
    /// `standingConnectFastFailureS`). Long enough that a genuine hot loop is broken, short enough that a
    /// foreground user is not left waiting.
    nonisolated static let standingConnectRetryFloor: TimeInterval = 30

    /// A standing connect that stayed outstanding at least this long before failing was not a hot loop —
    /// the ring was reachable enough to try, then refused. Re-issue such a failure **immediately**, so that
    /// something is ALWAYS outstanding with CoreBluetooth.
    ///
    /// WHY THIS EXISTS, and why the timer path had to go (measured 2026-08-12, overnight, build `91812d93`,
    /// the first hardware run of this whole fix). It engaged correctly at 01:27:52 after three consecutive
    /// failures — and CoreBluetooth rejected the standing connect 7 s later with the same
    /// `Failed to encrypt the connection` this ring produces on **every** reconnect. The old
    /// `.standingConnectAfter` branch then nil'd `standingConnectAt` and armed a
    /// `DispatchQueue.main.asyncAfter(23 s)`. The app suspended before it fired, so it went into the night
    /// holding **nothing** outstanding — the exact defect this fix exists to remove, reintroduced by its
    /// own backoff. The re-issue finally ran at **07:06:07, 5 h 38 m late**, on resume.
    ///
    /// The floor's purpose was only ever to avoid hammering while the app is AWAKE. A suspended app has no
    /// loop to break — no callbacks are being delivered — so paying the floor on a dispatch timer trades
    /// the one thing that survives suspension for protection against a problem that cannot occur there.
    /// Re-issuing immediately instead is self-limiting: the rate is set by how long CoreBluetooth itself
    /// takes to fail (7–11 s on this hardware), not by us.
    nonisolated static let standingConnectFastFailureS: TimeInterval = 2

    /// When the current standing connect was issued, or nil when none is outstanding.
    private var standingConnectAt: Date?

    /// What to do after an involuntary drop or a failed connect. Split out as a PURE function so the policy
    /// is unit-testable with no CoreBluetooth, no radio and no ring — `OuraLiveSource` itself owns a
    /// `CBCentralManager` and cannot be built in a test.
    enum ReconnectStep: Equatable, Sendable {
        /// Retry through the ordinary `connect(_:)` path after `delay`. The app is awake (it just received
        /// the callback), so a short timer genuinely fixes a transient blip.
        case timedRetry(delay: TimeInterval)
        /// Hand off to CoreBluetooth now: leave a standing connect outstanding, which survives suspension.
        case standingConnect
        /// A standing connect failed fast; re-issue one after `delay` rather than looping on the callback.
        case standingConnectAfter(delay: TimeInterval)
    }

    /// - Parameters:
    ///   - attempt: the 1-based consecutive failure count (`failedReconnectAttempts` after incrementing).
    ///   - secondsSinceStandingConnect: age of the outstanding standing connect, or nil when none is.
    nonisolated static func reconnectStep(attempt: Int,
                                         secondsSinceStandingConnect: TimeInterval?) -> ReconnectStep {
        guard attempt >= standingConnectAfterAttempts else {
            return .timedRetry(delay: min(60.0, 3.0 * pow(2.0, Double(max(0, attempt - 1)))))
        }
        // No standing connect outstanding reads as "long ago", so the first time we get here we hand off
        // immediately rather than sitting out a floor we never started.
        let since = secondsSinceStandingConnect ?? .greatestFiniteMagnitude
        // Anything but a near-instant failure re-issues NOW, so a suspension can never catch us holding
        // nothing. Only a genuinely instant failure (which proves the app is awake and looping) is worth
        // a timer, and a timer is safe precisely because the app is awake.
        guard since < standingConnectFastFailureS else { return .standingConnect }
        return .standingConnectAfter(delay: standingConnectRetryFloor - since)
    }

    /// Hand the reconnect to CoreBluetooth: `central.connect(_:options:)` has **no timeout**, so it stays
    /// outstanding indefinitely and iOS wakes the app when the ring advertises again — including while the
    /// app is SUSPENDED, which is the whole point.
    ///
    /// WHY THIS EXISTS (measured 2026-08-10 11:16, build `9bd45fef`). The link dropped at 11:16:38, two
    /// connects failed fast on `Failed to encrypt the connection`, and attempt 3 was scheduled for ~11:17:06.
    /// It actually ran at **11:29:27 — 12m33s late**, when the phone was next picked up, with zero log lines
    /// in between: `DispatchQueue.main.asyncAfter` does not run in a suspended app, the deadline just passes
    /// and the block fires on resume. The ring was down for **12m51s of a 27m window (47%)** and the wearer
    /// noticed. The damage is not the late timer — it is that after `didFailToConnect` the old code held
    /// **nothing** outstanding, so there was no way to notice the ring at all.
    ///
    /// This is a DIFFERENT hole from the state restoration in #1213/#1215: that one is the app being
    /// TERMINATED and relaunched; this one is the app merely being SUSPENDED, which overnight is far more
    /// common. Neither fixes the other.
    ///
    /// No new outbound command: `central.connect` is the same call `connect(_:)` already makes.
    private func issueStandingConnect(_ id: UUID) {
        guard !intentionalDisconnect, reconnectID == id else { return }
        guard let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            // No peripheral object to hand CoreBluetooth (never seen on this device). Fall back to the
            // ordinary connect path, which scans for it — that is the only way to acquire one.
            log("Oura: ring \(id) not cached - scanning instead of leaving a standing connect")
            connect(id)
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            // `centralManagerDidUpdateState` replays this on poweredOn.
            pendingConnectID = id
            log("Oura: standing reconnect deferred - Bluetooth not powered on (state=\(central.state.rawValue))")
            return
        }
        standingConnectAt = Date()
        log("Oura: leaving a STANDING connect outstanding for \(id) - CoreBluetooth will reconnect "
            + "whenever the ring is reachable, including while the app is suspended")
        central.connect(p, options: nil)
    }

    /// Re-reach the paired ring after an involuntary drop or a failed connect, unless the teardown was
    /// intentional or there is no known ring.
    ///
    /// Two regimes, deliberately: the first few attempts use a short timed backoff (the app is awake — it
    /// just received the callback — so a 3s/6s retry fixes a transient blip fast), and after that it hands
    /// off to a STANDING CoreBluetooth connect that survives suspension. The timed block is guarded again on
    /// wake: a `stop()` that lands in the meantime cancels it (it re-checks `intentionalDisconnect` and that
    /// the target is unchanged), so a deliberate teardown never races a stale reconnect.
    private func scheduleReconnect() {
        guard !intentionalDisconnect, let id = reconnectID else { return }
        failedReconnectAttempts += 1

        switch Self.reconnectStep(attempt: failedReconnectAttempts,
                                  secondsSinceStandingConnect: standingConnectAt.map {
                                      Date().timeIntervalSince($0)
                                  }) {
        case .standingConnect:
            issueStandingConnect(id)

        case .standingConnectAfter(let wait):
            // A standing connect failed NEAR-INSTANTLY, which only happens with the app awake and is the one
            // shape that can hot-loop. Break it with a timer — safe here precisely because the app is awake.
            // Any slower failure takes `.standingConnect` above and re-issues immediately, so this is the
            // only path that can ever leave nothing outstanding, and it cannot be reached from suspension.
            log("Oura: standing connect failed instantly - re-issuing in \(Int(wait))s "
                + "(attempt \(failedReconnectAttempts))")
            standingConnectAt = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, !self.intentionalDisconnect, self.reconnectID == id else { return }
                self.issueStandingConnect(id)
            }

        case .timedRetry(let delay):
            log("Oura: reconnecting in \(Int(delay))s (attempt \(failedReconnectAttempts))")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.intentionalDisconnect, self.reconnectID == id else { return }
                self.connect(id)
            }
        }
    }

    // MARK: - History fetch (GetEvents, s5) - the ONLY path skin temp / SpO2 / HRV / sleep-phase ever
    // arrive by. Neither temp nor SpO2 is ever pushed live on this hardware; both are banked overnight and
    // retrievable only by asking the ring for its history.

    /// The GetEvents resume cursor — a CLIENT-managed event-envelope ring-time (open_oura
    /// `nextEventToSync`), loaded from `OuraHistoryCursorStore` on connect and COMMITTED only when a
    /// drain completes (from `maxStoredRingTime`). 0 = fetch everything the ring has banked.
    ///
    /// #91: the `0x11` response carries NO cursor — only `bytes_left` (a remaining-byte count). NOOP
    /// previously persisted that byte-count as a "cursor" and compared it across sessions as a clock,
    /// minting a phantom "ring-time regression" → reset-to-0 → full re-dump on every connect.
    private var historyCursor: UInt32 = 0
    /// The pure, unit-tested drain + resume-cursor decision core (#291): the stall/deadline guards, the
    /// stored-ring-time high-water mark, the reboot flag, the cursor-commit and loaded-cursor-sanitize
    /// decisions, and the plausibility ceiling. OuraLiveSource keeps only the I/O — anchor resolution,
    /// persistence, logging, and the `historyCursorAdvanced` emit — and delegates every decision here so
    /// they can't silently regress in a refactor again (they did once: #91 → #291). See OuraHistoryDrainTests.
    private var drain = OuraHistoryDrain()
    /// The cursor we resumed FROM at the start of the current fetch — passed into `drain.noteStoredRingTime`
    /// so a real stored sample OLDER than it flags a genuine ring reboot (clock reset / seek ignored).
    private var resumeCursorAtFetchStart: UInt32 = 0
    /// Wall-clock start of the current drain; `drain`'s deadline guard force-stops one running too long.
    private var drainStartedAt: Date?
    /// The cursor the LAST GetEvents request was issued at — the `start` of open_oura's progress test
    /// (`next > start`). Continuation requests must advance past it or the drain stops.
    private var lastRequestCursor: UInt32 = 0
    /// True between a `0x11` summary that wants more data and the batch-quiet continuation request. The
    /// ring emits the summary EARLY (observed before its batch finished streaming), so the next request
    /// waits for the stream to go quiet — open_oura's `transact()` collects until a 1.5 s silence for the
    /// same reason. Re-requesting mid-stream at a stale cursor restarts the ring's serve (the re-serve loop).
    private var pendingContinuation = false
    /// Debounce for the batch-quiet window: restarted on every history record while a continuation is
    /// pending; fires = the ring finished streaming the batch and the next request can go out.
    private var batchQuietTimer: Timer?
    private let batchQuietInterval: TimeInterval = 1.5
    /// Self-chained drain passes: when a drain ends with KNOWN remaining work — a detected ring reboot
    /// (cursor honestly reset to 0, full pull pending) or a deadline-guard stop with banked progress —
    /// the next pass starts itself a few seconds later instead of waiting for a manual reconnect or the
    /// 15 min periodic timer. Capped per session; a stall/no-progress stop never chains (that is the
    /// ring looping, and re-asking would loop with it).
    private var chainedDrainPasses = 0
    private static let maxChainedDrainPasses = 6
    /// One-shot delay before a self-chained drain pass (see `finishDrain`). Invalidated on teardown.
    private var chainedDrainTimer: Timer?
    /// Periodic re-fetch while connected, so an overnight-connected session (or one left open after a nap)
    /// picks up freshly-banked sleep data without needing a reconnect. Mirrors BLEManager's ~15 min
    /// periodic WHOOP history-offload floor.
    private var historyFetchTimer: Timer?
    private let historyFetchInterval: TimeInterval = 900

    /// Kick a history-fetch pass at the current cursor, but ONLY when the driver is idle-streaming (never
    /// overlaps a fetch already in flight - the driver's own phase is the guard, so this is safe to call
    /// both right after reaching `.streaming` and from the periodic timer).
    private func fetchHistoryIfIdle() {
        guard let driver, driver.phase == .streaming else { return }
        // Arm the per-drain state: where we sought from (reboot detection), the stored-sample high-water
        // mark the cursor will commit from, and the stall/deadline guards.
        resumeCursorAtFetchStart = historyCursor
        drainStartedAt = Date()
        drain.reset()
        lastRequestCursor = historyCursor
        pendingContinuation = false
        stopBatchQuietTimer()
        log("Oura: fetching history from cursor \(historyCursor) (\(describeCursor(historyCursor))) [cursor-fix]")
        advance(.startHistoryFetch(cursor: historyCursor))
    }

    private func startHistoryFetchTimer() {
        stopHistoryFetchTimer()
        let t = Timer.scheduledTimer(withTimeInterval: historyFetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchHistoryIfIdle() }
        }
        historyFetchTimer = t
    }

    private func stopHistoryFetchTimer() {
        historyFetchTimer?.invalidate()
        historyFetchTimer = nil
    }

    /// Handle a `0x11` GetEvents summary (open_oura `EventBatchSummary`): the drain continues while
    /// `bytes_left > 0` and is complete at `bytes_left == 0`. The response's byte-count is NEVER persisted
    /// — persisting it and comparing byte-counts across sessions as clocks was the #91 re-dump loop.
    ///
    /// The durable resume point (open_oura `nextEventToSync`) is the newest STORED history sample's
    /// ring-time (`maxStoredRingTime`), committed here when the drain completes. A genuine ring reboot is
    /// caught by `sawPreResumeData` — a stored sample OLDER than where we sought means the ring's clock
    /// reset (or it ignored the seek), so next connect does a full pull rather than resume from a
    /// now-stale ring-time. Stall/deadline guards are backstops only; they force-stop the drain but keep
    /// whatever forward progress was banked (never reset to 0 — that re-arms the loop).
    private func handleHistorySummary(_ summary: (eventsReceived: UInt8, bytesLeft: UInt32, moreData: Bool)) {
        // Stall + deadline backstops (a healthy drain ends at bytes_left 0, where moreData is false).
        let elapsed = drainStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let continueDrain = drain.onSummary(bytesLeft: summary.bytesLeft, moreData: summary.moreData,
                                            elapsedSeconds: elapsed)
        if summary.moreData, !continueDrain {
            let reason = elapsed > OuraHistoryDrain.maxDrainSeconds
                ? "exceeded \(Int(OuraHistoryDrain.maxDrainSeconds))s deadline"
                : "bytes_left stalled"
            log("Oura: history drain force-stopped - \(reason) at bytes_left \(summary.bytesLeft) (guard)")
        }
        guard continueDrain else {
            // A deadline stop with more data behind it is resumable backlog (progress banked, the ring
            // is healthy — we just chose to breathe); a STALL stop is the ring looping and must not chain.
            let deadlineBacklog = summary.moreData && elapsed > OuraHistoryDrain.maxDrainSeconds
            finishDrain(completed: !summary.moreData, resumeBacklog: deadlineBacklog)
            return
        }
        // More data behind this batch. Do NOT re-request yet: the ring emits the 0x11 summary EARLY
        // (observed arriving before its batch finished streaming), and a mid-stream request at a stale
        // cursor restarts the serve from that cursor (the 5x same-window re-serve, 2026-07-12). Wait for
        // the batch to go quiet, then continue from max-seen-ring-time + 1 (open_oura drain_events).
        pendingContinuation = true
        restartBatchQuietTimer()
    }

    /// The batch went quiet after a more-data summary: issue the next GetEvents at the ADVANCED cursor,
    /// or end the drain when the batch made no progress (open_oura `!progressed → break` — re-sending a
    /// non-advancing cursor is exactly what loops the ring).
    private func continueDrainAfterQuiet() {
        stopBatchQuietTimer()
        guard pendingContinuation else { return }
        pendingContinuation = false
        guard let driver, driver.phase == .fetchingHistory else { return }
        if let next = drain.continuationCursor(lastRequestCursor: lastRequestCursor) {
            lastRequestCursor = next
            log("Oura: history batch done - continuing from cursor \(next) [\(describeCursor(next))]")
            advance(.historyCursorAdvanced(cursor: next, moreData: true))
        } else {
            log("Oura: history batch made no cursor progress - stopping drain (ring would re-serve)")
            finishDrain(completed: false, resumeBacklog: false)
        }
    }

    /// Common drain-end path: close the in-progress hypnogram burst BEFORE committing the cursor (so its
    /// banked ring-time can advance the resume point in the same drain), commit, log the estimates, and
    /// return the driver to `.streaming`. When the drain ends with KNOWN remaining work — a detected ring
    /// reboot (`sawPreResumeData` just reset the cursor to 0; the full pull is pending) or a deadline stop
    /// with backlog (`resumeBacklog`) — the next pass self-schedules a few seconds later, so catching up
    /// never needs a manual reconnect (progress banks between passes).
    private func finishDrain(completed: Bool, resumeBacklog: Bool) {
        pendingContinuation = false
        stopBatchQuietTimer()
        if let burst = hypnogramAssembler.flush() {
            persistHypnogramBurst(burst)
        }
        let rebootFullPullPending = drain.sawPreResumeData
        commitResumeCursor(drainCompleted: completed)
        logActivityEstimateSummary()
        advance(.historyCursorAdvanced(cursor: historyCursor, moreData: false))
        if rebootFullPullPending || resumeBacklog {
            guard chainedDrainPasses < Self.maxChainedDrainPasses else {
                log("Oura: drain pass cap (\(Self.maxChainedDrainPasses)) reached with work remaining - next periodic fetch / reconnect continues from the banked cursor")
                return
            }
            chainedDrainPasses += 1
            let why = rebootFullPullPending
                ? "ring reboot detected - starting the honest full re-pull"
                : "backlog remains after the deadline guard"
            log("Oura: \(why); next drain pass in 5 s (\(chainedDrainPasses)/\(Self.maxChainedDrainPasses))")
            let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.fetchHistoryIfIdle() }
            }
            chainedDrainTimer = t
        } else if completed {
            chainedDrainPasses = 0   // healthy full completion re-arms the cap for future backlogs
        }
    }

    private func restartBatchQuietTimer() {
        batchQuietTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: batchQuietInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.continueDrainAfterQuiet() }
        }
        batchQuietTimer = t
    }

    private func stopBatchQuietTimer() {
        batchQuietTimer?.invalidate()
        batchQuietTimer = nil
    }

    /// Commit the durable resume cursor at drain end. Only a cursor that (a) moved forward, (b) is below
    /// the plausibility ceiling, and (c) resolves to a real time under the CURRENT anchor is persisted;
    /// a reboot (`sawPreResumeData`) resets to 0 so next connect does an honest full pull.
    private func commitResumeCursor(drainCompleted: Bool) {
        let how = drainCompleted ? "caught up (bytes_left 0)" : "stopped early"
        let resolves = drain.maxStoredRingTime > 0
            && (driver?.unixSeconds(forRingTimestamp: drain.maxStoredRingTime) != nil)
        let newCursor = drain.resumeCursorAtDrainEnd(currentCursor: historyCursor, resolvesUnderAnchor: resolves)
        if drain.sawPreResumeData {
            log("Oura: history \(how) but the ring served data older than cursor \(resumeCursorAtFetchStart) - clock reset/seek ignored; next connect does a full pull")
            historyCursor = 0
            OuraHistoryCursorStore.save(0, deviceId: deviceId)
        } else if newCursor != historyCursor {
            historyCursor = newCursor
            OuraHistoryCursorStore.save(newCursor, deviceId: deviceId)
            log("Oura: history \(how) - resume cursor advanced to \(historyCursor) [\(describeCursor(historyCursor))]")
        } else if drain.maxStoredRingTime > historyCursor {
            log("Oura: history \(how) but resume candidate \(drain.maxStoredRingTime) does not resolve under the current anchor - keeping cursor \(historyCursor)")
        } else {
            log("Oura: history \(how) (resume cursor unchanged \(historyCursor) [\(describeCursor(historyCursor))])")
        }
    }

    /// The 0x49 window in `windows` whose envelope ring-time is nearest `rt` and within `tolerance` ticks,
    /// or nil when none is in range. A drain can hold several windows (overnight + nap); each burst must
    /// pair with its OWN, so match by ring-time proximity — keeping a single latest slot mis-anchored the
    /// overnight burst to the nap's window when both finalized in one drain (2026-07-17 capture). Pure +
    /// static so the pairing is unit-testable without a strap. Twin of Kotlin's closestSleepWindow049.
    nonisolated static func closestSleepWindow049(
        in windows: [(ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)],
        toRingTimestamp rt: UInt32,
        within tolerance: UInt32
    ) -> (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)? {
        var best: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)?
        var bestGap = UInt32.max
        for w in windows {
            let gap = w.ringTimestamp >= rt ? w.ringTimestamp - rt : rt - w.ringTimestamp
            if gap <= tolerance, gap < bestGap {
                bestGap = gap
                best = w
            }
        }
        return best
    }

    /// Persist a closed hypnogram burst with its RECONSTRUCTED time axis: codes laid backward at the
    /// 30 s SleepNet epoch from the anchored burst END. The end is the matching 0x49 window's TRUE
    /// sleep end (`event − end_offset` min, ringverse-validated within minutes of the wearer's report)
    /// when one arrived in the same finalization burst; otherwise the last record's envelope time (the
    /// analysis WRITE moment — observed trailing the real sleep end by 10–43 min, so 0x49 wins when
    /// available). Logs the reconstructed window + stage minutes so a capture is self-evident.
    private func persistHypnogramBurst(_ burst: OuraHypnogramBurst) {
        guard let driver, burst.totalCodes > 0 else { return }
        // HOLD-UNTIL-ANCHOR (same discipline as pendingAnchorEvents): the burst end IS the night's whole
        // time axis, so guessing it from wall-clock would persist real stage codes at fabricated times.
        // An unanchored burst is parked and re-tried when the 0x42 anchor lands; if the session ends
        // without one it is DROPPED honestly — safe, because the resume cursor only advances on an
        // anchored persist, so the ring re-serves the same records next drain.
        guard let writeEnd = driver.unixSeconds(forRingTimestamp: burst.lastRingTimestamp) else {
            pendingUnanchoredBursts.append(burst)
            log("Oura: hypnogram burst (\(burst.totalCodes) codes) held - no anchor yet; reconstructs when the 0x42 lands")
            return
        }
        var end = writeEnd
        var sleepStart: Int?    // the 0x49 onset; clips leading pre-window codes (symmetric with `end`)
        // Same-finalization match: the 0x49 and the phase records carry near-identical envelope ring-times
        // (observed seconds apart). 6000 ticks = 10 min is generous while still never pairing a different
        // night's summary. Pick the CLOSEST window, not merely the newest — a drain can hold an overnight
        // AND a nap, and the newer (nap) window would otherwise mis-anchor the overnight burst.
        if let w = Self.closestSleepWindow049(in: recentSleepWindows049, toRingTimestamp: burst.lastRingTimestamp, within: 6_000),
           let eventUtc = driver.unixSeconds(forRingTimestamp: w.ringTimestamp) {
            let sleepEnd = eventUtc - w.endOffMin * 60
            // Sanity: the true end precedes the write and by a plausible margin (< 6 h).
            if sleepEnd <= writeEnd, writeEnd - sleepEnd < 6 * 3600 {
                end = sleepEnd
                let fmt = Self.cursorDateFormatter
                log("Oura: hypnogram burst end refined by 0x49 - SleepNet write \(fmt.string(from: Date(timeIntervalSince1970: TimeInterval(writeEnd)))) → true sleep end \(fmt.string(from: Date(timeIntervalSince1970: TimeInterval(sleepEnd)))) (event-\(w.endOffMin) min)")
            }
            // The 0x49 window ALSO carries the ONSET (startOffMin). The SleepNet burst runs a few epochs
            // before that onset (observed ~7 min / 14 codes), so the reconstruction start would otherwise
            // precede the ring's OWN sleep window. Clamp it symmetrically with the end: keep the onset when
            // it plausibly precedes the (refined) end within a night's span (< 16 h), and clip the
            // pre-onset codes below. A mis-paired 0x49 can never empty the night (the clip only applies
            // when it leaves ≥1 code).
            let onset = eventUtc - w.startOffMin * 60
            if onset < end, end - onset < 16 * 3600 { sleepStart = onset }
        }
        if burst.hasNonMonotonicRingTimes {
            // The layout trusts arrival order as the code sequence; a backwards envelope ring-time inside
            // a burst is the one signal that assumption may not hold. Surface it, never fail silent.
            log("Oura: hypnogram burst has NON-MONOTONIC envelope ring-times (\(burst.records.count) records) - sequence order taken from arrival order")
        }
        // Reconstruct the time axis; `sleepStart` (the 0x49 onset, or nil) clips leading pre-window codes
        // in the PURE assembler (never emptying the night). Testable there; the app just logs the trim.
        let laid = burst.codesWithTimes(endUnixSeconds: end, sleepStartUnixSeconds: sleepStart)
        // #1246: an all-unwritten burst (every hypnogram page erased) reconstructs to nothing. Note the
        // resume cursor so the ring stops re-serving it, but persist no blank/awake session.
        guard !laid.isEmpty else {
            log("Oura: hypnogram burst entirely unwritten (0xFF) - \(burst.totalCodes) code(s), no stageable sleep; skipped")
            noteStoredHistoryRingTime(burst.lastRingTimestamp)
            return
        }
        if laid.count < burst.totalCodes {
            // Fewer laid than decoded = unwritten (#1246, 0xFF pages) and/or pre-0x49-onset epochs trimmed.
            log("Oura: hypnogram trimmed \(burst.totalCodes - laid.count) code(s) - unwritten (0xFF) and/or pre-onset")
        }
        for code in laid {
            enqueue([.sleepPhase(code.phase)], ts: code.ts)
        }
        noteStoredHistoryRingTime(burst.lastRingTimestamp)   // banked → the resume cursor may advance
        var mins = [0.0, 0.0, 0.0, 0.0]
        for code in laid { mins[code.phase.stage.rawValue] += 0.5 }   // 30 s/code = 0.5 min
        let fmt = Self.cursorDateFormatter
        let startStr = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(laid.first!.ts)))
        let endStr = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(end)))
        log(String(format: "Oura: hypnogram reconstructed [%@ → %@, anchored] codes=%d deep/light/rem/awake=%.0f/%.0f/%.0f/%.0f min",
                   startStr, endStr, burst.totalCodes, mins[0], mins[1], mins[2], mins[3]))
        // Bank the SAME anchored codes as a ring-PROVIDED night: a CachedSleepSession with the
        // `[{start,end,stage}]` stage breakdown, upserted under the ring's own deviceId so SleepMerge's
        // imported-over-computed rule surfaces Oura's SleepNet staging as the night's stages (#325 persist).
        // Reuses the anchored+0x49-refined `end` via `laid`, so the session end IS the true sleep end. The
        // confirmation line makes the persist self-evident in the strap log for on-device validation.
        if let session = OuraSleepSessionMapping.session(fromCodes: laid.map { (ts: $0.ts, stage: $0.phase.stage) }) {
            let start = laid.first!.ts
            // #1284 residual 3: log when this persist lands wholly inside — or overlapping — a session already
            // banked this connection (the duplicate GENERATION an early partial drain creates, which the #899
            // heal only cleans up afterward). `sleepStart != nil` = a 0x49 anchor was applied; a persist with
            // NO anchor is the prime suspect for the short nested row. Diagnostic only — nothing is skipped
            // here; the fix is 0x49-window session keying (hardware-gated). Twin of Kotlin's.
            if let prior = recentPersistedSessionWindows.first(where: { start < $0.end && end > $0.start }) {
                let nested = start >= prior.start && end <= prior.end
                let anchor = sleepStart != nil ? "0x49 onset=\(sleepStart!)" : "no 0x49 onset (start derived from burst end)"
                log("Oura: duplicate-gen(#1284) new session [\(start) → \(end)] \(nested ? "NESTED IN" : "OVERLAPS") already-banked [\(prior.start) → \(prior.end)] this connection - \(anchor); PK=(deviceId,startTs) mints a 2nd row")
            }
            recentPersistedSessionWindows.append((start: start, end: end))
            if recentPersistedSessionWindows.count > Self.recentPersistedSessionsCap {
                recentPersistedSessionWindows.removeFirst(recentPersistedSessionWindows.count - Self.recentPersistedSessionsCap)
            }
            persistSleepSession(session)
            let effStr = session.efficiency.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
            // #1284 residual 3: stamp the 0x49 anchor state on EVERY persist, so an unanchored early-drain row
            // (the prime suspect for the short nested duplicate) is self-evident even when it is the FIRST
            // persist, before the duplicate-gen line above can fire.
            // #1284: log the SESSION's STORED window, not the pre-trim burst window. The #1293
            // trailing-run trim shortens the persisted end, so `startStr`/`endStr` (from the burst) read
            // ~tens of minutes wider than the row — every future capture then reads the wrong window out
            // of the log. `session.startTs`/`.endTs` are exactly what `persistSleepSession` banks.
            let persistedStart = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs)))
            let persistedEnd = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs)))
            let anchorTag = sleepStart != nil ? "0x49-onset" : "no-0x49-onset"
            log("Oura: sleep session persisted [\(persistedStart) → \(persistedEnd)] eff=\(effStr) [\(anchorTag)] → \(deviceId) (ring-provided night; wins merge over computed)")
        }
    }

    /// Re-try bursts parked while unanchored (called right after the 0x42 anchor lands, alongside
    /// drainPendingAnchorEvents). A burst that still cannot resolve goes back on the pending list.
    private func drainPendingHypnogramBursts() {
        guard !pendingUnanchoredBursts.isEmpty else { return }
        let held = pendingUnanchoredBursts
        pendingUnanchoredBursts.removeAll()
        for burst in held {
            persistHypnogramBurst(burst)
        }
    }

    /// Teardown for bursts that never anchored this session: DROP them with an honest log instead of
    /// persisting a wall-clock-guessed time axis. Nothing is lost — the resume cursor only advances on
    /// an anchored persist, so the ring re-serves the same records on the next drain.
    private func dropUnanchoredHypnogramBursts() {
        guard !pendingUnanchoredBursts.isEmpty else { return }
        let codes = pendingUnanchoredBursts.reduce(0) { $0 + $1.totalCodes }
        log("Oura: dropping \(pendingUnanchoredBursts.count) unanchored hypnogram burst(s) (\(codes) codes) - no anchor this session; cursor did not advance, so they re-arrive next drain")
        pendingUnanchoredBursts.removeAll()
    }

    /// Record a STORED history sample's ring-time toward the resume cursor (open_oura `nextEventToSync`).
    /// Called only where a sample resolved a REAL anchored time and was enqueued — never for a no-anchor
    /// wall-clock fallback. Also flags a reboot: a real sample older than where we sought this fetch.
    private func noteStoredHistoryRingTime(_ rt: UInt32) {
        // A ring-time above the plausibility ceiling is corrupt; letting it set the resume cursor would
        // seek the next session into nonsense. Bounds the cursor at the source.
        drain.noteStoredRingTime(rt, resumeCursorAtFetchStart: resumeCursorAtFetchStart)
    }

    /// Log the per-day MET-derived activity estimate + the empirical cadence cross-check at drain-end.
    /// INVESTIGATION ONLY (OuraActivityEstimator; weight-free, so no kcal): a clearly-labeled Tier-B
    /// estimate for eyeballing against WHOOP active minutes / Apple exercise minutes. The cadence line
    /// reports the ring's real per-sample spacing so `activityEpochSeconds` can be pinned. Never
    /// persisted, never scored, never a step count.
    private func logActivityEstimateSummary() {
        // 0x71 fixture-capture roll-up (#287): even when the per-record cap truncated the stream, the
        // session total + observed payload lengths are what a decoder verification needs to plan with.
        if greenIbiAmpCount > 0 {
            log("Oura: 0x71 green_ibi_amp capture - \(greenIbiAmpCount) record(s) this session, payload lengths \(greenIbiAmpLengths.sorted()) (fixture material, #287)")
        }
        // Sleep-phase cadence (investigation): pins the ring's per-code phase epoch from the stream,
        // exactly like the activity 60 s pin. Logged whenever any hypnogram records arrived this drain.
        if !phaseCadenceObs.isEmpty {
            let sorted = phaseCadenceObs.sorted()
            log(String(format: "Oura: sleep-phase cadence self-check - median %.1fs/code over %d gaps",
                       sorted[sorted.count / 2], phaseCadenceObs.count))
        }
        guard !activityMETByDay.isEmpty else { return }
        if !activityCadenceObs.isEmpty {
            let sorted = activityCadenceObs.sorted()
            let median = sorted[sorted.count / 2]
            log(String(format: "Oura: activity cadence self-check - median %.1fs/sample over %d gaps (assumed %.0fs)",
                       median, activityCadenceObs.count, activityEpochSeconds))
        }
        for day in activityMETByDay.keys.sorted() {
            let est = OuraActivityEstimator.estimate(metSamples: activityMETByDay[day] ?? [],
                                                     epochSeconds: activityEpochSeconds)
            log(String(format: "Oura: activity estimate day=%@ samples=%d meanMET=%.2f maxMET=%.1f metMin=%.1f activeMin=%.1f [assumed %.0fs/sample, Tier-B est]",
                       day, est.sampleCount, est.meanMET, est.maxMET, est.metMinutes, est.activeMinutes, activityEpochSeconds))
        }
    }

    // MARK: - Sample buffer

    /// Buffered decoded events, flushed to `persist` in batches to keep the write path off the
    /// per-notification hot loop. Each entry carries its own `ts` (unix seconds): live-push events (HR,
    /// IBI, battery) are stamped at wall-clock arrival time; history-fetched events (temp, SpO2, HRV,
    /// sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) when an anchor is available,
    /// so last night's data is never mis-recorded as happening right now.
    private var buffer: [(events: [OuraEvent], ts: Int)] = []
    private var lastFlush: Date = .init()
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30

    // MARK: - Live-HR re-engagement

    /// Daytime-HR auto-reverts after ~20 s (OURA_PROTOCOL.md s5.7), so while a live session is open we
    /// re-send the enable+subscribe every ~15 s. nil when no session is streaming.
    private var reengageTimer: Timer?
    private let reengageInterval: TimeInterval = 15

    // MARK: - Init

    /// - Parameters:
    ///   - live: the shared `LiveState` the Live UI observes.
    ///   - deviceId: the datastore device id these samples are attributed to.
    ///   - ringGen: the ring generation (selects MTU clamp + command set).
    ///   - authKey: supplies the 16-byte install key from the Keychain, or nil to drive `needsPairing`.
    ///   - persist: wired by the app to `store.insert(_, deviceId:)`. Called on the main actor.
    ///   - log: connect-lifecycle diagnostics sink, wired at the composition root to the same strap log
    ///     `BLEManager` writes to (issue #421). Every line is prefixed "Oura: ". Defaults to a no-op.
    ///   - onBattery: fired with the ring's battery percent (0-100). Default no-op.
    ///   - feedsLive: when false (the discovery-only wizard scanner) this source never touches LiveState
    ///     or persists. Default true.
    ///   - adoptIntent: EXPLICIT user-granted adopt consent for this connection. Default FALSE. Only when
    ///     true may the dangerous `0x24` installKey opcode ever be sent (the post-factory-reset provisioning,
    ///     s3.2). The standard live path leaves it false (read-only / Advanced-key), so a key is NEVER
    ///     installed outside the wizard's irreversible-consent adopt flow.
    public init(live: LiveState,
                deviceId: String,
                ringGen: OuraRingGen,
                authKey: @escaping () -> Data?,
                persist: @escaping (Streams) -> Void = { _ in },
                persistSleepSession: @escaping (CachedSleepSession) -> Void = { _ in },
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                onModel: @escaping (String) -> Void = { _ in },
                onSerial: @escaping (String) -> Void = { _ in },
                feedsLive: Bool = true,
                adoptIntent: Bool = false) {
        self.live = live
        self.deviceId = deviceId
        self.ringGen = ringGen
        self.authKey = authKey
        self.persist = persist
        self.persistSleepSession = persistSleepSession
        self.log = log
        self.onBattery = onBattery
        self.onModel = onModel
        self.onSerial = onSerial
        self.feedsLive = feedsLive
        self.adoptIntent = adoptIntent
        // Tier-B MET research corpus: only on a live/persisting source, never the discovery-only scanner.
        self.activityDump = feedsLive && !deviceId.isEmpty ? OuraActivityDump(deviceId: deviceId, log: log) : nil
        // 0x47 motion calibration corpus: same gate as the activity dump (live/persisting source only).
        self.motionDump = feedsLive && !deviceId.isEmpty ? OuraMotionDump(deviceId: deviceId, log: log) : nil
        // RAW undecoded history-drain capture: same live/persisting gate; complements the decoded sidecars.
        self.rawDump = feedsLive && !deviceId.isEmpty ? OuraRawDump(deviceId: deviceId, log: log) : nil
        // 0x7E/0x7F real_steps research corpus: same gate as the other Tier-B dumps.
        self.realStepsDump = feedsLive && !deviceId.isEmpty ? OuraRealStepsDump(deviceId: deviceId, log: log) : nil
        super.init()
        // Dedicated queue-less central -> callbacks arrive on the main queue, matching @MainActor.
        #if os(iOS)
        // iOS state restoration (#1213): only the PERSISTENT live source (feedsLive, real deviceId) carries a
        // restore identifier, so CoreBluetooth relaunches the app into the background and delivers
        // willRestoreState after a suspend-then-jettison — without it an overnight Oura session dies with the
        // process and nothing reconnects until the user re-opens the app. The discovery-only wizard scanner
        // (feedsLive == false, deviceId "scan-preview") must NOT restore, and two centrals may never share one
        // restore identifier, so it is deliberately excluded. Mirrors the WHOOP central in BLEManager.
        if feedsLive && !deviceId.isEmpty {
            self.central = CBCentralManager(delegate: self, queue: nil,
                                            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID])
        } else {
            self.central = CBCentralManager(delegate: self, queue: nil)
        }
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        self.central = CBCentralManager(delegate: self, queue: nil)
        #endif
    }

    // MARK: - Scanning

    /// Scan for Oura rings advertising the Oura GATT service, keeping only ones the ring-gen recogniser
    /// accepts as an Oura ring.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        needsPairing = nil
        log("Oura: scanning for an Oura ring (service \(OuraGatt.serviceUUID))")
        guard central.state == .poweredOn else {
            log("Oura: Bluetooth not powered on (state=\(central.state.rawValue)) - scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: [Self.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    /// Connect to the chosen ring and start the auth -> enable -> stream flow. Mirrors the
    /// StandardHRSource cached-by-identifier-first, else scan-then-connect pattern.
    public func connect(_ id: UUID) {
        stopScan()
        needsPairing = nil
        // Remember the paired ring so an involuntary drop auto-reconnects to it (#912). An explicit connect
        // is never the intentional-teardown case, so clear the suppression flag.
        reconnectID = id
        intentionalDisconnect = false
        standingConnectAt = nil   // an explicit connect supersedes any standing one
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            // Never seen by this Mac/iPhone yet -> remember it and scan; didDiscover connects on sight.
            pendingConnectID = id
            log("Oura: ring \(id) not cached yet - scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Oura: Bluetooth not powered on - connect to \(id) deferred until ready")
            return
        }
        log("Oura: connecting to \(id)")
        central.connect(p, options: nil)
    }

    /// Tear down: cancel the connection, stop scanning, flush, clear all transient state. Idempotent.
    public func stop() {
        // A deliberate teardown (device switch / removal) must NOT auto-reconnect: mark it intentional and
        // drop the reconnect target so any pending backoff bails and no fresh one is scheduled (#912).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        standingConnectAt = nil   // cancelPeripheralConnection below also cancels any standing connect
        stopScan()
        pendingConnectID = nil
        stopReengageTimer()
        stopHistoryFetchTimer()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeCharacteristic = nil
        // Drain BEFORE driver.stop() clears its anchor, so a pending event still gets a real anchored
        // time if one exists rather than always falling back to wall-clock at teardown. Same for a
        // hypnogram burst still accumulating (e.g. the session ended mid-drain).
        if let burst = hypnogramAssembler.flush() {
            persistHypnogramBurst(burst)
        }
        drainPendingAnchorEvents()
        dropUnanchoredHypnogramBursts()   // never wall-clock a night's time axis; they re-arrive next drain
        driver?.stop()
        driver = nil
        reassembler.reset()
        wearTracker.reset(); loggedWearState = nil; lastLivePulseAt = nil
        loggedFirstHR = false
        droppedFirstLiveHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        loggedFeatureStatuses.removeAll()
        loggedProductInfo.removeAll()
        greenIbiAmpCount = 0
        greenIbiAmpLengths.removeAll()
        recentSleepWindows049.removeAll()
        recentPersistedSessionWindows.removeAll()
        activityMETByDay.removeAll()
        activityCadenceObs.removeAll()
        lastActivityUtc = nil
        lastActivitySampleCount = 0
        phaseCadenceObs.removeAll()
        lastPhaseUtc = nil
        lastPhaseCodeCount = 0
        drain.reset()
        resumeCursorAtFetchStart = 0
        drainStartedAt = nil
        lastRequestCursor = 0
        pendingContinuation = false
        stopBatchQuietTimer()
        chainedDrainPasses = 0
        chainedDrainTimer?.invalidate()
        chainedDrainTimer = nil
        reachedStreaming = false
        pendingInstallKey = nil
        adoptPhase = .idle
        batteryPct = nil
        needsPairing = nil
        flush()                       // persist anything still buffered
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
    }

    // MARK: - Driver wiring

    /// Write the bytes for each command the driver returned, logging the label only (never an address).
    private func write(_ commands: [OuraCommand]) {
        guard let peripheral, let writeCharacteristic else { return }
        let mtuPayload = ringGen.maxWritePayload   // gen-appropriate clamp (gen3=200, gen4/5=244)
        for cmd in commands {
            guard cmd.bytes.count <= mtuPayload else {
                log("Oura: skipping \(cmd.label) - \(cmd.bytes.count)B exceeds the \(mtuPayload)B write window")
                continue
            }
            log("Oura: -> \(cmd.label)")
            peripheral.writeValue(Data(cmd.bytes), for: writeCharacteristic, type: .withoutResponse)
        }
    }

    /// Advance the driver with a transition and write whatever it asks for next.
    private func advance(_ transition: OuraTransition) {
        guard let driver else { return }
        let commands = driver.nextStep(after: transition)
        write(commands)
        // Surface the driver's coarse phase honestly into the UI state.
        switch driver.phase {
        case .needsKeyInstall:
            // A factory-reset ring (auth status inFactoryReset) or no key available. The dangerous key
            // install is the ONLY thing that recovers it, and ONLY with explicit adopt consent: provision
            // when `adoptIntent`, otherwise stay honest (never loop the dangerous command).
            if adoptIntent {
                provisionKeyInstall()
            } else {
                announceNeedsPairing(reason: .factoryResetOrNoKey)
            }
        case .authFailed(let status):
            announceNeedsPairing(reason: .authFailed(status))
        case .streaming:
            if !reachedStreaming {
                reachedStreaming = true
                adoptPhase = .streaming   // re-auth after an install (or a normal auth) reached the stream: adoption complete
                pendingInstallKey = nil   // an OK ack already persisted the key; nothing left in flight
                if feedsLive { live.streamingLiveHR = true }   // drive the green menu-bar STREAMING pill (no WHOOP bond)
                log("Oura: live-HR enabled - streaming HR / IBI")
                startReengageTimer()
                startHistoryFetchTimer()
                // §5.3 step 1 / open_oura sync recipe: hand the ring the current UTC BEFORE draining
                // history so it can emit a usable 0x42 time-sync anchor (§5.5). Without this a short
                // resume drain carries NO 0x42 at all — every fetched record stays "[no anchor yet]",
                // the night's hypnogram gets wall-clock-stamped at connect time, and the resume cursor
                // can never commit (observed 2026-07-12: 4 connects re-dumped the same window). Sent
                // ONCE per session, before the first fetch; the ack-fetch loop never re-sends it.
                write([OuraCommands.syncTime(unixSeconds: Int(Date().timeIntervalSince1970))])
                fetchHistoryIfIdle()   // pull last night's banked temp/SpO2/HRV/sleep-phase right away
                write([OuraCommands.getBattery()])   // ask once HR streams; the 0x0D reply routes to onBattery
                // Read-only diagnostic: ask the ring its SpO2 / real-steps feature status once, so a capture
                // confirms (from the ring itself) that these server-flag features are subscription-gated OFF
                // for an offline ring. NEVER an enable/set-mode write - purely the 0x20 read verb.
                write([OuraCommands.spo2ReadStatus(), OuraCommands.realStepsReadStatus()])
                // Read-only capture (#771/#772): the ring's GetProductInfo serial + hardware pages are
                // pre-auth readable. The SERIAL is a STABLE per-ring identity — unlike the CoreBluetooth UUID,
                // which rotates on re-pair and orphans the ring's history (#771) — and the HARDWARE id
                // (e.g. "BLB_03") maps to the generation, confirming it from the ring instead of stray digits
                // in the advertised name (#772). Here we only ASK and LOG the raw replies to capture their
                // byte layout; nothing is decoded, minted into an id, or persisted yet (capture-first, so a
                // real fixture backs the decode before it drives identity/generation). Same read-only class as
                // the SpO2 / real-steps status reads above; never a set/enable write.
                write([OuraCommands.getProductSerial(), OuraCommands.getProductHardware()])
            }
        default:
            break
        }
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /// PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from `advance`
    /// when `driver.phase == .needsKeyInstall` AND `adoptIntent == true`. Steps: (1) generate a fresh
    /// cryptographically-random 16-byte key; (2) ask the driver for the dangerous `24 10 <key>` install
    /// command (the driver's own `allowKeyInstall`/phase gate is the second guard) and write it; (3) hold the
    /// key in memory and mark `.installingKey` (an install IS now running). The key is NOT persisted yet: it
    /// is written to the keystore only once the ring acks OK (`handleKeyInstallAck`), so a failed install
    /// never leaves a key the next session would wrongly trust. On any build/RNG failure we stay honest.
    private func provisionKeyInstall() {
        guard adoptIntent else { return }                 // belt-and-braces: never provision without consent
        guard pendingInstallKey == nil else { return }    // an install is already in flight; don't double-send
        guard let driver else { return }
        guard let key = Self.randomInstallKey() else {
            announceNeedsPairing(reason: .installFailed("could not generate a key"))
            return
        }
        guard let cmd = driver.beginKeyInstall(key: [UInt8](key)) else {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            announceNeedsPairing(reason: .installFailed("the install command could not be prepared"))
            return
        }
        pendingInstallKey = key
        adoptPhase = .installingKey
        log("Oura: installing NOOP's key on the reset ring")
        write([cmd])
    }

    /// Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
    /// On OK: persist the freshly-provisioned key under this `deviceId` (so every future session authenticates
    /// with it), then drive the driver's `keyInstallAcknowledged()` to re-run the auth handshake (GetAuthNonce
    /// then Authenticate) with the NEW key. On a non-OK status (or a missing pending key) announce an honest
    /// failure and do NOT retry the dangerous command.
    private func handleKeyInstallAck(status: UInt8) {
        guard let driver, let key = pendingInstallKey else { return }
        guard status == 0x00 else {
            announceNeedsPairing(reason: .installFailed("the ring did not accept the key (status \(status))"))
            return
        }
        // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
        guard OuraKeyStore.save(key, deviceId: deviceId) else {
            announceNeedsPairing(reason: .installFailed("the installed key could not be stored"))
            return
        }
        log("Oura: key installed and stored - re-running auth with the new key")
        pendingInstallKey = nil
        // Re-auth with the freshly-installed key. The driver returns enable-notify + get-nonce; the nonce
        // response then flows through the normal handleSecure -> advance path to streaming.
        write(driver.keyInstallAcknowledged())
    }

    /// A fresh 16-byte application key for the adopt install, from the system CSPRNG. Per OURA_PROTOCOL.md
    /// s3 the key is exactly 16 bytes; `SecRandomCopyBytes` is the same CSPRNG the rest of the app relies on.
    /// Returns nil if the RNG fails (then the caller stays honest rather than installing a weak key).
    private static func randomInstallKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: OuraKeyStore.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    // MARK: - Buffer / persistence

    private func enqueue(_ events: [OuraEvent], ts: Int) {
        guard !events.isEmpty else { return }
        buffer.append((events: events, ts: ts))
        if buffer.count >= flushCount || Date().timeIntervalSince(lastFlush) >= flushInterval {
            flush()
        }
    }

    private func flush() {
        guard feedsLive, !buffer.isEmpty else { lastFlush = Date(); return }
        for entry in buffer {
            // Pure, unit-tested mapping (events -> Streams) keyed by each entry's own ts (wall-clock for
            // live pushes, ring-time-anchored for history-fetched records). A signal that could not be
            // decoded never reaches here, so a missing stream stays empty, never faked.
            persist(OuraStreamMapping.streams(from: entry.events, at: entry.ts))
        }
        buffer.removeAll()
        lastFlush = Date()
    }

    /// Flush every event parked in `pendingAnchorEvents`, now that `driver.unixSeconds` can resolve them
    /// (called right after the anchor is set) - OR, if called at session teardown with NO anchor ever
    /// having arrived, with an honest wall-clock fallback (a rough stamp beats silently dropping real
    /// decoded samples). Reset the buffer afterward so nothing is drained twice.
    private func drainPendingAnchorEvents() {
        guard !pendingAnchorEvents.isEmpty, let driver else { return }
        let now = Int(Date().timeIntervalSince1970)
        var stamped: [(event: OuraEvent, ts: Int)] = []
        for pending in pendingAnchorEvents {
            if let ts = driver.unixSeconds(forRingTimestamp: pending.ringTimestamp) {
                stamped.append((event: pending.event, ts: ts))
                // A parked IBI can be a LIVE beat that arrived before the anchor (see .ibi in ingest());
                // it must never advance the resume cursor either, or a live push could skip un-drained
                // backlog on a force-stopped drain. Only the history-only siblings drive the cursor.
                if case .ibi = pending.event {} else {
                    noteStoredHistoryRingTime(pending.ringTimestamp)   // parked history sample placed → advance resume cursor
                }
            } else {
                stamped.append((event: pending.event, ts: now))   // honest wall-clock fallback; NEVER advances the cursor
            }
        }
        // Batched by resolved second, exactly like the live path (#1072): a record's parked beats are
        // released as ONE insert so `ord` records their emission order instead of restarting at 0 per beat.
        for batch in OuraStreamMapping.batched(stamped) {
            enqueue(batch.events, ts: batch.ts)
        }
        pendingAnchorEvents.removeAll()
    }

    // MARK: - Live ingest

    /// Fold TLV records decoded from the notify stream — these are HISTORY-LOG records (the live-HR path
    /// is `ingestLiveHRPush`): every envelope ring-time advances the drain's in-session continuation
    /// cursor (open_oura `drain_events` tracks the max timestamp of EVERY batch event), and while a
    /// continuation is pending the batch-quiet window stays open as long as records keep arriving.
    private func ingestHistory(_ events: [OuraEvent]) {
        guard !events.isEmpty else { return }
        for e in events {
            if let rt = e.envelopeRingTimestamp {
                drain.noteSeenRingTime(rt)
            }
        }
        if pendingContinuation { restartBatchQuietTimer() }
        ingest(events)
    }

    /// Fold decoded events into live state (HR / R-R only - skin temp and SpO2 are SLEEP-ONLY on this
    /// hardware, never a live readout) + the persist buffer. Genuinely-live pushes (HR/battery) are stamped
    /// at wall-clock arrival time, since they really are "now". Ring-time-carrying events (IBI, temp, SpO2,
    /// HRV, sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) so last night's banked
    /// data is never mis-recorded as happening right now; when no anchor has arrived yet this session, we
    /// park the event until one does (`pendingAnchorEvents`), rather than immediately guessing wall-clock.
    /// (IBI is special: it arrives both live and banked, so it anchors like history but — unlike the
    /// history-only streams — never advances the resume cursor; see the `.ibi` case.) Out-of-range HR/temp
    /// is dropped, never shown.
    private func ingest(_ events: [OuraEvent]) {
        guard !events.isEmpty, let driver else { return }
        let now = Int(Date().timeIntervalSince1970)
        // Sleep-phase record visibility (investigation): one 0x4B/0x4E/0x5A record's codes arrive as one
        // events array; log it whole (time + count + histogram) and feed the per-code cadence observer.
        let phases = events.compactMap { e -> OuraSleepPhase? in
            if case .sleepPhase(let v) = e { return v } else { return nil }
        }
        if let firstPhase = phases.first {
            let utc = driver.unixSeconds(forRingTimestamp: firstPhase.ringTimestamp)
            let when = utc.map { Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? "no anchor yet"
            var counts = [0, 0, 0, 0]
            for p in phases { counts[p.stage.rawValue] += 1 }
            log("Oura: sleep-phase record [\(when)] codes=\(phases.count) deep/light/rem/awake=\(counts[0])/\(counts[1])/\(counts[2])/\(counts[3])")
            if let utc {
                if let prev = lastPhaseUtc, lastPhaseCodeCount > 0, utc > prev {
                    let perCode = Double(utc - prev) / Double(lastPhaseCodeCount)
                    // Keep only plausible epoch spacings; a gap across sessions/naps is not a cadence.
                    if perCode >= 5, perCode <= 3600 { phaseCadenceObs.append(perCode) }
                }
                lastPhaseUtc = utc
                lastPhaseCodeCount = phases.count
            }
            // TIME-AXIS RECONSTRUCTION: the ring writes a night's whole hypnogram in one burst AFTER
            // wake, every record stamped with the WRITE moment — so the codes are accumulated here and
            // laid out backward (30 s/code from the anchored burst end) when the burst closes, instead
            // of being persisted at the (meaningless for sleep) envelope time. A returned burst means a
            // ring-time gap just closed the previous one.
            if let closed = hypnogramAssembler.feed(ringTimestamp: firstPhase.ringTimestamp, phases: phases) {
                persistHypnogramBurst(closed)
            }
        }
        // #728: materialise `hrSample` from BANKED IBI. A batch with NO live-HR push (`.hr`) is history
        // data — the ring banks overnight IBI (0x60/0x80/0x6E) but no HR, and the nightly pipeline gates on
        // `hrSample` (day-owner probe + `hr.count >= 200`), so an Oura night otherwise never scores. Derive
        // one median HR per IBI-record (`OuraIbiHr`) and enqueue it as `.hr` → the mapping writes
        // `hrSample`, WITHOUT this switch's wear/live-badge side-effects (enqueue buffers for the mapping,
        // it never re-enters ingest). Live batches ([.hr, .ibi]) are excluded, so live HR is never
        // double-counted. Per-record ring-time anchored; an unanchored record is skipped (re-derived when
        // it re-serves after the 0x42 anchor, exactly like the sibling `.ibi` rows).
        let hasLiveHR = events.contains { if case .hr = $0 { return true } else { return false } }
        if !hasLiveHR {
            let bankedIbis: [OuraIBI] = events.compactMap { if case .ibi(let v) = $0 { return v } else { return nil } }
            for hr in OuraIbiHr.perRecordMedianHR(bankedIbis) {
                if let ts = driver.unixSeconds(forRingTimestamp: hr.ringTimestamp) {
                    enqueue([.hr(hr)], ts: ts)
                }
            }
        }
        // #1072 (root cause for #823): a RECORD's beats must reach the store as ONE batch. `StreamStore`'s
        // `ord` counter is batch-local — a beat's position among the beats sharing its second WITHIN one
        // insert is the only place emission order still exists — so enqueuing one beat at a time (what the
        // `.ibi` arm below used to do) restarted the counter on every beat and wrote `ord = 0` on every
        // row: 575,630 of 575,630 rows in a real database. With `ord` tied the read falls through to
        // `(rrMs, seq)`, i.e. a second's beats come back sorted by VALUE, which minimises successive
        // differences by construction and biases RMSSD down (#823). All of one record's beats carry that
        // record's ring time, so grouping the anchored ones by their resolved `ts` hands the store a
        // record at a time and `ord` becomes their real emission order. Unanchored beats still park below
        // and are batched the same way when the 0x42 lands (`drainPendingAnchorEvents`).
        let anchoredBeats: [(event: OuraEvent, ts: Int)] = events.compactMap { e in
            guard case .ibi(let ibi) = e,
                  let ts = driver.unixSeconds(forRingTimestamp: ibi.ringTimestamp) else { return nil }
            return (event: e, ts: ts)
        }
        for batch in OuraStreamMapping.batched(anchoredBeats) {
            enqueue(batch.events, ts: batch.ts)
        }
        for e in events {
            switch e {
            case .hr(let hr):
                guard hr.bpm >= 30, hr.bpm <= 220 else { continue }   // physiological gate
                // Drop the first (settling) live-HR sample of the session — it is frequently an artifact.
                // The value is never shown or persisted; the NEXT sample becomes the first real reading.
                if !droppedFirstLiveHR {
                    droppedFirstLiveHR = true
                    log("Oura: dropping first live HR \(hr.bpm) bpm (settling sample)")
                    continue
                }
                if !loggedFirstHR {
                    loggedFirstHR = true
                    log("Oura: receiving live data - first HR \(hr.bpm) bpm")
                }
                if feedsLive {
                    live.heartRate = hr.bpm
                    live.connected = true
                    // A LIVE HR push (0x2F) exists only while the ring is measuring on a finger, so it is
                    // the sole safe "worn now" signal. A banked IBI (.ibi below) can be a history re-serve
                    // from a past night, so it must NOT flip the badge to worn.
                    lastLivePulseAt = Date()
                    wearTracker.notePulse()
                    publishWearState()
                }
                enqueue([e], ts: now)

            case .ibi(let ibi):
                if feedsLive { live.setRRIntervals([ibi.ibiMs]) }
                // A banked IBI is history data: anchor it to its REAL ring-time, exactly like the sibling
                // banked streams (.hrv/.temp/.spo2/.sleepPhase) below — never the drain-arrival `now`.
                // Stamping it at `now` (52b6e88d) misfiled every overnight beat to the daytime sync moment,
                // so the sleep window ended up with zero R-R -> no restingHr/avgHrv for the night. The
                // anchored beats were ALREADY enqueued above, as one batch per record (#1072); all this arm
                // still owns is the live readout and parking the ones no anchor can place yet.
                //
                // NOTE: unlike the history-only siblings, an IBI never calls noteStoredHistoryRingTime — it
                // is the one stream that arrives both LIVE (ring-time ~now) and banked, indistinguishable
                // at this call site except by ring-time. Letting a live beat advance the resume cursor
                // could leap `maxStoredRingTime` to ~now during a force-stopped drain (300s/stall guard,
                // bytes_left > 0) and permanently skip the un-drained backlog. The resume cursor is still
                // driven correctly by the history-only siblings (hrv/temp/spo2/sleepPhase) that share the
                // same night window; this also matches Kotlin, which notes no stream's ring-time.
                if driver.unixSeconds(forRingTimestamp: ibi.ringTimestamp) == nil {
                    pendingAnchorEvents.append((e, ibi.ringTimestamp))
                }

            case .battery(let bat):
                batteryPct = bat.percent
                onBattery(bat.percent)
                log("Oura: battery \(bat.percent)%")
                enqueue([e], ts: now)

            case .temp(let t):
                guard t.celsius >= 20, t.celsius <= 45 else { continue }   // physiological gate (wrist skin temp)
                if !loggedFirstTemp {
                    loggedFirstTemp = true
                    log("Oura: first skin temp decoded (last night) - \(String(format: "%.2f", t.celsius))C")
                }
                if let ts = driver.unixSeconds(forRingTimestamp: t.ringTimestamp) {
                    enqueue([e], ts: ts)
                    noteStoredHistoryRingTime(t.ringTimestamp)
                } else {
                    pendingAnchorEvents.append((e, t.ringTimestamp))
                }

            case .spo2(let s):
                if !loggedFirstSpo2 {
                    loggedFirstSpo2 = true
                    log("Oura: first SpO2 decoded (last night) - value \(s.value) (\(s.unit))")
                }
                if let ts = driver.unixSeconds(forRingTimestamp: s.ringTimestamp) {
                    enqueue([e], ts: ts)
                    noteStoredHistoryRingTime(s.ringTimestamp)
                } else {
                    pendingAnchorEvents.append((e, s.ringTimestamp))
                }

            case .hrv(let v):
                if let ts = driver.unixSeconds(forRingTimestamp: v.ringTimestamp) {
                    enqueue([e], ts: ts)
                    noteStoredHistoryRingTime(v.ringTimestamp)
                } else {
                    pendingAnchorEvents.append((e, v.ringTimestamp))
                }

            case .sleepPhase:
                // Handled at the record level above (hypnogramAssembler): the envelope time marks the
                // analysis WRITE moment, not the sleep, so per-code enqueue here would mis-place the
                // night. Codes persist when the burst closes (persistHypnogramBurst).
                break

            case .timeSync(let ts):
                // #91: a 0x42 whose epoch is outside the 2020–2035 plausibility window is silently ignored,
                // so history samples stay unanchored (no sleep/daily). Log the rejection with the offending
                // epoch; only announce "acquired" when the sync ACTUALLY anchored (the old unconditional
                // "acquired" line fired even on a rejected sync). `epochMs` holds the raw wire value, which
                // is unix SECONDS despite the name (s6.11).
                if OuraDriver.isPlausibleAnchorEpoch(ts.epochMs) {
                    if !loggedAnchor {
                        loggedAnchor = true
                        log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                    }
                } else {
                    log("Oura: 0x42 time-sync REJECTED - implausible epoch \(ts.epochMs)s (outside the 2020–2035 anchor window); history samples stay unanchored (#91)")
                }
                // The 0x42 time-sync can arrive ANYWHERE in a history-fetch stream, not necessarily first.
                // Anything parked while unanchored gets its real time retroactively the moment an anchor lands.
                drainPendingAnchorEvents()
                drainPendingHypnogramBursts()

            case .rtcBeacon(let r):
                // #91: the 0x85 beacon is the SECONDARY anchor (fills the gap only until a 0x42 arrives). A
                // beacon ignored because a primary anchor already exists is NORMAL and not logged; only an
                // IMPLAUSIBLE-epoch beacon is a real failure (it can never anchor), so log just that.
                if !OuraDriver.isPlausibleAnchorEpoch(Int64(r.unixSeconds)) {
                    log("Oura: 0x85 RTC beacon REJECTED - implausible epoch \(r.unixSeconds)s (outside the 2020–2035 anchor window) (#91)")
                }

            case .tierB(let summary):
                // 0x71 green_ibi_amp FIXTURE CAPTURE (upstream #287/#333): unlike the other Tier-B tags,
                // EVERY occurrence is logged (up to a flood cap) with its anchored time, envelope rt,
                // length, and full raw bytes — a verified decoder needs several real payloads (5 IBI
                // deltas + 6 amplitudes + [2:0] shift per open_oura decode_green_ibi_and_amp), and the
                // anchored time is what aligns each record with concurrent live-HR R-R (the ground truth).
                // Never persisted, never scored (OuraStreamMapping drops .tierB unconditionally).
                if summary.kind == "green_ibi_amp" {
                    greenIbiAmpCount += 1
                    greenIbiAmpLengths.insert(summary.rawPayload.count)
                    if greenIbiAmpCount <= Self.greenIbiAmpLogCap {
                        let utc = driver.unixSeconds(forRingTimestamp: summary.ringTimestamp)
                        let when = utc.map { Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? "no anchor yet"
                        let hex = summary.rawPayload.map { String(format: "%02x", $0) }.joined(separator: " ")
                        var line = "Oura: 0x71 green_ibi_amp #\(greenIbiAmpCount) [\(when)] rt=\(summary.ringTimestamp) len=\(summary.rawPayload.count) raw: \(hex)"
                        // Side-by-side CANDIDATE decode (ringverse p_green_ibi_and_amp @0x503960, Tier-B):
                        // printed for the R-R cross-check only, never stored. nil = gate failed (length /
                        // reserved bit), which is itself capture evidence.
                        if let cand = OuraDecoders.decodeGreenIBIAmpCandidate(payload: summary.rawPayload,
                                                                              ringTimestamp: summary.ringTimestamp) {
                            let ibis = cand.samples.dropFirst().map { String($0.ibiMs) }.joined(separator: ",")
                            let amps = cand.samples.map { String($0.amplitude ?? 0) }.joined(separator: ",")
                            line += " | candidate [ringverse]: shift=\(cand.shift) ibis_ms=[\(ibis)] amps=[\(amps)]"
                        } else {
                            line += " | candidate [ringverse]: GATE FAILED (len != 14 or reserved bit set)"
                        }
                        log(line)
                        if greenIbiAmpCount == Self.greenIbiAmpLogCap {
                            log("Oura: 0x71 log cap (\(Self.greenIbiAmpLogCap)) reached - further records counted, summarized at drain end")
                        }
                    }
                    break
                }
                // 0x49 sleep_summary_1 window candidate (ringverse, VALIDATED against our own samples:
                // 600/10 on the 2026-07-11→12 night = write−600 min → write−10 min = 23:30→09:20, matching
                // the reconstructed hypnogram): both uint16 LE fields are MINUTES BEFORE the event time —
                // start_offset / end_offset of the ring's tracked sleep window. Logged EVERY occurrence
                // (one per night) as an independent cross-check of the burst reconstruction axis. Tier-B:
                // log-only, never persisted. Falls through to the once-per-kind raw line below.
                if summary.tag == 0x49, summary.rawPayload.count >= 4 {
                    let startOff = Int(summary.rawPayload[0]) | (Int(summary.rawPayload[1]) << 8)
                    let endOff = Int(summary.rawPayload[2]) | (Int(summary.rawPayload[3]) << 8)
                    // Stash for the hypnogram burst of the SAME finalization (it follows right after):
                    // its end anchors at the TRUE sleep end (event − end_offset), not the write moment.
                    // Append (don't overwrite): a drain may carry an overnight AND a nap window, and each
                    // burst pairs with its OWN by ring-time proximity. Bounded — oldest dropped past the cap.
                    recentSleepWindows049.append((summary.ringTimestamp, startOff, endOff))
                    if recentSleepWindows049.count > Self.recentSleepWindows049Cap {
                        recentSleepWindows049.removeFirst(recentSleepWindows049.count - Self.recentSleepWindows049Cap)
                    }
                    if let utc = driver.unixSeconds(forRingTimestamp: summary.ringTimestamp) {
                        let startStr = Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(utc - startOff * 60)))
                        let endStr = Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(utc - endOff * 60)))
                        log("Oura: 0x49 sleep window candidate [ringverse] \(startStr) -> \(endStr) (event-\(startOff)/-\(endOff) min)")
                    } else {
                        log("Oura: 0x49 sleep window candidate [ringverse] offsets start-\(startOff)min end-\(endOff)min [no anchor yet]")
                    }
                }
                // Other Tier-B tags (real_steps / activity-summary / sleep-summary / smoothed-SpO2,
                // OURA_PROTOCOL.md s7.3; PR #960): logged ONCE PER KIND with the raw bytes so we can see
                // whether the ring sends these tags at all and collect capture material - e.g. real_steps
                // 0x7E/0x7F is server-flag-gated OFF by default ([open_oura-feat]), so its continued
                // absence here is the ring's doing, not a decode gap.
                if !loggedTierBKinds.contains(summary.kind) {
                    loggedTierBKinds.insert(summary.kind)
                    let hex = summary.rawPayload.map { String(format: "%02x", $0) }.joined(separator: " ")
                    log("Oura: Tier-B \(summary.kind) seen (tag 0x\(String(summary.tag, radix: 16))) - raw: \(hex)")
                }

            case .activityInfo(let info):
                // INVESTIGATION ONLY (0x50 activity/MET, Tier B - a plausible third-party formula, NOT
                // ground-truth-validated; see OuraActivityInfo). Logged with the DECODED state/MET values
                // every time (not once-per-kind): this is the tag under active plausibility evaluation, so
                // every real capture is evidence. Never persisted, never scored, and NEVER converted into
                // steps (MET is not a step count; OuraStreamMapping drops .activityInfo unconditionally).
                // Include the record's anchored timestamp so an individual MET burst can be correlated
                // with what the wearer was doing (walk / swim / …); before the UTC anchor lands it reads
                // "no anchor yet".
                let utc = driver.unixSeconds(forRingTimestamp: info.ringTimestamp)
                let when = utc.map { Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? "no anchor yet"
                log("Oura: activity (Tier-B) [\(when)] state=\(info.state) met=\(info.met)")
                // Append the raw record to the Tier-B research corpus (anchored records only; deduped by
                // ring-time inside the writer). Diagnostic sidecar — never persisted to SQLite, never scored.
                if let utc = utc {
                    activityDump?.record(ringTs: info.ringTimestamp, utc: utc, state: info.state,
                                         secPerSample: Int(activityEpochSeconds), met: info.met)
                }
                // Accumulate the MET series by local day for the drain-end estimate, and observe the
                // per-sample cadence from consecutive record times (both investigation-only, never scored).
                if let utc = utc {
                    let dayKey = Self.activityDayFormatter.string(from: Date(timeIntervalSince1970: Double(utc)))
                    activityMETByDay[dayKey, default: []].append(contentsOf: info.met)
                    if let prev = lastActivityUtc, lastActivitySampleCount > 0 {
                        let perSample = Double(utc - prev) / Double(lastActivitySampleCount)
                        // Reject off-wrist gaps / out-of-order re-dumps; keep only plausible epoch spacings.
                        if perSample >= 5, perSample <= 600 { activityCadenceObs.append(perSample) }
                    }
                    lastActivityUtc = utc
                    lastActivitySampleCount = info.met.count
                }

            case .realStepsFields(let steps):
                // INVESTIGATION ONLY (0x7E/0x7F real_steps_features, Tier B - a cited third-party unpack
                // formula [oura-rs], NOT ground-truth-validated; see OuraRealStepsFields). Logged once per
                // kind (like the other raw Tier-B tags) rather than every occurrence - this stream runs at
                // a much higher rate than 0x50 MET, so the JSONL corpus is the real record; the strap log
                // just confirms the ring sends it at all. Never persisted, never scored, and NEVER
                // converted into steps (OuraStreamMapping drops .realStepsFields unconditionally) - not
                // even from fields[0]/fields[8], which ground truth showed are movement FEATURES, not a
                // count (a 13,349-step day; every field large and non-zero asleep - OURA_PROTOCOL.md §6.13).
                if !loggedTierBKinds.contains("real_steps_fields") {
                    loggedTierBKinds.insert("real_steps_fields")
                    log("Oura: Tier-B real_steps_fields seen (tag 0x\(String(steps.tag, radix: 16))) - first fields: \(steps.fields)")
                }
                if let utc = driver.unixSeconds(forRingTimestamp: steps.ringTimestamp) {
                    realStepsDump?.record(tag: steps.tag, ringTs: steps.ringTimestamp, utc: utc, fields: steps.fields)
                }

            case .sleepPeriodInfo(let info):
                // 0x6A sleep_period_info (Tier B - third-party field NAMES [open_ring] over offsets our
                // own §6.12 already had; see OuraSleepPeriodInfo). Logged with the DECODED values every
                // time, like 0x50 MET rather than once-per-kind: its cadence is a modest ~5 min and the
                // series is what the respiration ledger is reconstructed from, sample by sample.
                //
                // The record's `breath` field is also PERSISTED, as instrumentation: anchored to its own
                // ring-time and enqueued exactly like the sibling banked streams (.hrv/.temp/.spo2), so a
                // night's ~5-min windows land where they were MEASURED and never at the drain-arrival
                // moment. `OuraStreamMapping` maps that ONE field onto a `respSample` row in milli-bpm;
                // everything else in this record stays here in the log. Nothing SCORES the row — not the
                // sleep stager, and not `dailyMetric.respRateBpm` (see `OuraRespScale`). The logging is
                // kept as well as the row: the log line is what the ledger is reconstructed from,
                // including for records no anchor can place, and it carries the fields the store
                // deliberately does not.
                let periodWhen = driver.unixSeconds(forRingTimestamp: info.ringTimestamp)
                    .map { Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
                    ?? "no anchor yet"
                log("Oura: sleep_period (Tier-B) [\(periodWhen)] hr=\(info.averageHrBpm) "
                    + "trend=\(info.hrTrend) breath=\(info.breathsPerMin) "
                    + "breathV=\(info.breathVariability) motion=\(info.motionCount) state=\(info.sleepState)")
                if let ts = driver.unixSeconds(forRingTimestamp: info.ringTimestamp) {
                    enqueue([e], ts: ts)
                    noteStoredHistoryRingTime(info.ringTimestamp)
                } else {
                    pendingAnchorEvents.append((e, info.ringTimestamp))
                }

            case .state(let s):
                // The ring's own lifecycle strings (0x45/0x53). Charger transitions drive the wear badge;
                // never a durable Streams row. Only the LIVE stream updates the indicator (a history
                // re-serve is out of order and would flap it).
                if feedsLive {
                    wearTracker.note(state: s)
                    publishWearState()
                }

            case .motionEvent(let m):
                // 0x47 averaged accel vector (Tier-A). Persisted as an OURA_MOTION event (same event-table
                // path as OURA_HRV / OURA_SLEEP_PHASE — see OuraStreamMapping), AND appended to the raw
                // calibration sidecar. Instrumentation only: never scored, never fed to the sleep stager
                // (0x47 is movement-gated, a shape mismatch for the gravity-stillness stager, #804). Anchor
                // per record (its own ring-time) so each window lands on a distinct (deviceId, ts, kind) row.
                if let ts = driver.unixSeconds(forRingTimestamp: m.ringTimestamp) {
                    motionDump?.record(ringTs: m.ringTimestamp, utc: ts, orientation: m.orientation,
                                       motionSeconds: m.motionSeconds, x: m.avgX, y: m.avgY, z: m.avgZ,
                                       lowIntensity: m.lowIntensity, highIntensity: m.highIntensity)
                    enqueue([e], ts: ts)
                    noteStoredHistoryRingTime(m.ringTimestamp)
                } else {
                    pendingAnchorEvents.append((e, m.ringTimestamp))
                }

            default:
                break   // state / debugText / etc: not a durable Streams row (see OuraStreamMapping)
            }
        }
    }

    /// Mirror the tracker's current wear/charge state to the observable, and log each TRANSITION once (a
    /// charger on/off or first pulse is worth a strap-log line; steady state is not).
    private func publishWearState() {
        let s = wearTracker.current
        if feedsLive { live.ouraWearState = s }
        if s != loggedWearState {
            loggedWearState = s
            switch s {
            case .worn:     log("Oura: ring WORN - live HR streaming")
            case .charging: log("Oura: ring NOT WORN - on charger (HR/IBI paused until removed)")
            case .off:      log("Oura: ring NOT WORN - no live HR (removed / off charger)")
            case .unknown:  break
            }
        }
    }

    /// Log a feature-status read reply once per feature (read-only diagnostic). Confirms, from the ring
    /// itself, whether a server-flag feature (SpO2 0x04 / real_steps 0x0b) is subscribed/emitting — NOOP
    /// cannot enable these offline (server ClientConfiguration gate), so a `subscription == 0` here is the
    /// honest "not a bug, it's a gate" reading. Never scored, never stored.
    private func logFeatureStatus(_ st: OuraFeatureStatus) {
        guard loggedFeatureStatuses.insert(st.feature).inserted else { return }
        let name: String
        switch UInt8(truncatingIfNeeded: st.feature) {
        case OuraCommands.featureSpO2:      name = "SpO2 (0x04)"
        case OuraCommands.featureRealSteps: name = "real_steps (0x0b)"
        case OuraCommands.featureDaytimeHR: name = "daytime-HR (0x02)"
        default:                            name = "0x\(String(st.feature, radix: 16))"
        }
        // A gated/unavailable feature reports ALL-ZERO (mode/status/state); the streaming daytime-HR, by
        // contrast, reads mode=1 status=0x11 state=2. Flag the all-zero case as the honest "cloud never
        // enabled it" — NOT `subscription==0` alone, since daytime-HR is subscription=0 yet active.
        let off = st.mode == 0 && st.status == 0 && st.state == 0
        let gate = off ? " - INACTIVE (server-gated off; the cloud never enabled it, not emitted offline)" : ""
        // Name the enum fields so the log reads plainly (OURA_PROTOCOL.md s7.1 [ring4-ble]) — e.g. a gated
        // feature prints `mode=0 (off) … subscription=0 (off)`, the active daytime-HR `mode=1 (automatic)`.
        log("Oura: feature status \(name) mode=\(st.mode) (\(Self.featureModeName(st.mode))) status=\(st.status) state=\(st.state) subscription=\(st.subscription) (\(Self.subscriptionName(st.subscription)))\(gate)")
    }

    /// The ring's feature-MODE enum (`2f 03 22` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble].
    private static func featureModeName(_ m: Int) -> String {
        switch m {
        case 0: return "off"; case 1: return "automatic"; case 2: return "requested"; case 3: return "connected_live"
        default: return "?"
        }
    }
    /// The ring's SUBSCRIPTION enum (`2f 03 26` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble].
    private static func subscriptionName(_ s: Int) -> String {
        switch s {
        case 0: return "off"; case 1: return "state"; case 2: return "latest"; case 4: return "feature_data"
        default: return "?"
        }
    }

    // MARK: - Re-engagement timer (daytime-HR auto-reverts ~20s)

    private func startReengageTimer() {
        stopReengageTimer()
        let t = Timer.scheduledTimer(withTimeInterval: reengageInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reengageLiveHR() }
        }
        reengageTimer = t
    }

    private func stopReengageTimer() {
        reengageTimer?.invalidate()
        reengageTimer = nil
    }

    /// Re-send the live-HR enable+subscribe so the ~20 s auto-revert never silently stops the stream.
    /// Skipped while a history drain is in flight: the Oura app never runs live mode during a sync, and
    /// interleaving enable writes with the batch stream is off-model noise (live HR resumes on the next
    /// 15 s tick after the drain returns to `.streaming`).
    private func reengageLiveHR() {
        guard let driver, reachedStreaming, driver.phase != .fetchingHistory else { return }
        write(driver.reengageLiveHRCommands())
        // Live-HR watchdog: if the stream has gone silent past the grace window while we were WORN, the
        // ring came off the finger (no "removed" event exists) -> NOT WORN. Only meaningful once we have
        // seen at least one live beat this session.
        if feedsLive, let last = lastLivePulseAt, Date().timeIntervalSince(last) > wornPulseTimeout {
            wearTracker.noteLivePulseTimeout()
            publishWearState()
        }
    }

    // MARK: - Honest needs-pairing fallback (Huami precedent)

    private enum NeedsPairingReason {
        case factoryResetOrNoKey
        case authFailed(OuraAuthStatus)
        case installFailed(String)
    }

    /// Record + log the honest "this ring needs a pairing handshake NOOP can't complete" outcome (once),
    /// and drop the link so no half-authenticated session lingers. We never fabricate a reading. Also marks
    /// `adoptPhase = .failed` so an in-flight adopt's Adopting step lands on a REACHABLE honest Failed state
    /// (file-import + Advanced-key fallbacks), and clears any in-flight install key WITHOUT persisting it (a
    /// failed install must never leave a wrongly-trusted key). RECOVERY-HONEST: a factory-reset ring is NOT
    /// bricked; re-pairing it in the Oura app brings it back. We never claim a key was installed here.
    private func announceNeedsPairing(reason: NeedsPairingReason) {
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = nil
        adoptPhase = .failed
        // This is an honest dead-end (no key / auth rejected / install failed), NOT a transient drop, so the
        // ensuing disconnect must NOT auto-reconnect (that would loop the same auth failure and drain the
        // ring). Suppress it the same way a deliberate teardown does (#912): a later user reconnect re-arms.
        // Run this UNCONDITIONALLY, before the first-announce guard, so a SECOND announce in the same session
        // (needsPairing already set) still cancels the lingering peripheral and re-suppresses the reconnect,
        // mirroring the Android twin (OuraLiveSource.kt announceNeedsPairing).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        standingConnectAt = nil   // the cancel below also drops any standing connect
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        guard needsPairing == nil else { return }
        let detail: String
        switch reason {
        case .factoryResetOrNoKey:
            detail = "NOOP needs the ring's install key to read it live, and that pairing handshake isn't set up yet."
        case .authFailed(let status):
            detail = "The ring rejected the pairing handshake (status \(status.rawValue))."
        case .installFailed(let why):
            detail = "NOOP couldn't take over this ring (\(why))."
        }
        let recovery = " The ring isn't bricked: re-pair it in the Oura app to recover it."
        let msg = detail + " Live data isn't available - export from the Oura app and import the file instead." + recovery
        needsPairing = msg
        log("Oura: \(msg)")
        stopReengageTimer()
        stopHistoryFetchTimer()
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
    }

    // CB delegate callbacks live in the @preconcurrency extensions below. The queue-less central delivers
    // them on the main thread, so MainActor isolation is sound; @preconcurrency lets this @MainActor type
    // satisfy the nonisolated CoreBluetooth requirements (same pattern as StandardHRSource / BLEManager).
}

// MARK: - CBCentralManagerDelegate

extension OuraLiveSource: @preconcurrency CBCentralManagerDelegate {
    /// iOS relaunched us into the background after a suspend-then-jettison and handed back the Oura central's
    /// peripheral (#1213). Re-adopt it so an overnight session resumes without the user opening the app. Only
    /// the persistent live source carries the restore identifier, so only it is ever restored here. Mirrors
    /// `BLEManager.willRestoreState`; never called on macOS (no restore identifier is set there).
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Oura restore: no peripherals in restore state")
            return
        }
        let id = p.identifier
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        reconnectID = id                 // an involuntary drop re-targets this ring (#912)
        intentionalDisconnect = false
        if p.state == .connected {
            // The link survived; CoreBluetooth does NOT re-fire didConnect for an already-connected restored
            // peripheral, so re-run the session bring-up (fresh driver + service discovery) directly.
            log("Oura restore: peripheral \(id) still connected — resuming session")
            centralManager(central, didConnect: p)
        } else if central.state == .poweredOn {
            log("Oura restore: peripheral \(id) disconnected — reconnecting")
            central.connect(p, options: nil)
        } else {
            // Radio not ready yet; centralManagerDidUpdateState replays pendingConnectID on poweredOn.
            pendingConnectID = id
            log("Oura restore: peripheral \(id) disconnected, central not poweredOn — deferring to poweredOn")
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Replay any intent that arrived before the radio was ready.
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: [Self.service],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            // Radio off / unauthorized / resetting -> the link is not live.
            if feedsLive { live.connected = false; live.streamingLiveHR = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // The scan already filters on the Oura service, but re-check the name through the gen recogniser
        // so a coincidental service match without an Oura-shaped name is dropped (best-effort).
        let detectedGen = OuraRingGen.recognise(advertisedName: name)
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Oura: found \(name.isEmpty ? "Oura ring" : name) (\(id)) rssi \(RSSI.intValue)") }
        let ring = DiscoveredRing(id: id,
                                  name: name.isEmpty ? "Oura" : name,
                                  rssi: RSSI.intValue,
                                  detectedGen: detectedGen)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = ring
        } else {
            discovered.append(ring)
        }
        // If we were scanning specifically to reach this ring (a not-yet-cached active ring), connect now.
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Oura: connected - discovering services")
        failedReconnectAttempts = 0   // a real connection clears the reconnect backoff (#912)
        standingConnectAt = nil       // whatever was outstanding has landed
        peripheral.delegate = self
        // Fresh driver per connection so a new session re-runs auth (the app key is session-scoped). The
        // driver's `allowKeyInstall` is gated on this connection's adopt consent ONLY: with no consent the
        // dangerous `0x24` installKey can never be sequenced, so a read-only / Advanced-key connect stays
        // honest (it announces needs-pairing instead of provisioning). Per OURA_PROTOCOL.md s3.2.
        // allowTierB: true - INVESTIGATION ONLY (activity/real_steps/sleep-summary/smoothed-SpO2 tags,
        // OURA_PROTOCOL.md s7.3 Tier B, UNVERIFIED layouts; PR #960). This lets `ingest` LOG what the
        // ring actually sends (raw bytes per kind, decoded MET for 0x50) so the layouts can be validated
        // against real captures. It can never leak a value into scoring: OuraStreamMapping drops
        // .tierB/.activityInfo unconditionally - the Tier-discipline gate that matters lives there, not here.
        driver = OuraDriver(ringGen: ringGen,
                            authKey: authKey().map { [UInt8]($0) },
                            allowTierB: true,
                            allowKeyInstall: adoptIntent)
        reachedStreaming = false
        loggedFirstHR = false
        droppedFirstLiveHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        loggedFeatureStatuses.removeAll()
        loggedProductInfo.removeAll()
        greenIbiAmpCount = 0
        greenIbiAmpLengths.removeAll()
        recentSleepWindows049.removeAll()
        recentPersistedSessionWindows.removeAll()
        pendingAnchorEvents.removeAll()   // a fresh session must never replay a stale-anchor guess
        hypnogramAssembler.reset()        // ditto for a half-accumulated burst from a dead session
        pendingUnanchoredBursts.removeAll()
        pendingInstallKey = nil
        adoptPhase = .idle
        reassembler.reset()
        wearTracker.reset(); loggedWearState = nil; lastLivePulseAt = nil
        // Per-drain cursor state starts clean each session (fetchHistoryIfIdle re-arms it per drain).
        drain.reset()
        resumeCursorAtFetchStart = 0
        drainStartedAt = nil
        lastRequestCursor = 0
        pendingContinuation = false
        stopBatchQuietTimer()
        chainedDrainPasses = 0
        chainedDrainTimer?.invalidate()
        chainedDrainTimer = nil
        // Resume the GetEvents cursor from where the LAST connection to this ring left off (s5.1/5.3), so
        // a routine reconnect doesn't re-fetch the ring's entire banked history every time. A persisted
        // value above the plausibility ceiling is garbage banked by a pre-fix build (a bytes_left count or
        // a misframe-era ring-time) - seeking to it would starve the fetch; reset to a full pull instead.
        let loadedCursor = OuraHistoryCursorStore.read(deviceId: deviceId)
        historyCursor = OuraHistoryDrain.sanitizeLoadedCursor(loadedCursor)
        if historyCursor != loadedCursor {
            log("Oura: persisted resume cursor \(loadedCursor) exceeds the plausibility ceiling (pre-fix garbage) - full pull")
            OuraHistoryCursorStore.save(0, deviceId: deviceId)
        }
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Oura: WARNING failed to connect - \(error?.localizedDescription ?? "unknown error")")
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
        // The ring wiped its bond (re-paired in the Oura app, or a firmware reset). CoreBluetooth surfaces
        // this as a stable CBError, and re-issuing connect just loops the same stale-pairing failure and
        // drains the ring, so DON'T auto-reconnect: route to the honest needs-pairing path instead, exactly
        // like BLEManager returns early on this error without rescheduling (#912/#414).
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            announceNeedsPairing(reason: .factoryResetOrNoKey)
            return
        }
        // A failed connect to the paired ring (e.g. out of range at launch) retries on the backoff so the
        // ring comes back on its own, mirroring BLEManager's failed-connect reschedule (#912/#414).
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            log("Oura: disconnected - \(error.localizedDescription)")
        } else {
            log("Oura: disconnected (clean)")
        }
        stopReengageTimer()
        stopHistoryFetchTimer()
        stopBatchQuietTimer()
        pendingContinuation = false
        chainedDrainPasses = 0
        chainedDrainTimer?.invalidate()
        chainedDrainTimer = nil
        // Drain BEFORE driver.stop() clears its anchor (same reasoning as stop()); a hypnogram burst
        // still accumulating flushes first for the same reason.
        if let burst = hypnogramAssembler.flush() {
            persistHypnogramBurst(burst)
        }
        drainPendingAnchorEvents()
        dropUnanchoredHypnogramBursts()   // never wall-clock a night's time axis; they re-arrive next drain
        driver?.stop()
        driver = nil
        reassembler.reset()
        wearTracker.reset(); loggedWearState = nil; lastLivePulseAt = nil
        writeCharacteristic = nil
        loggedFirstHR = false
        droppedFirstLiveHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        loggedFeatureStatuses.removeAll()
        loggedProductInfo.removeAll()
        greenIbiAmpCount = 0
        greenIbiAmpLengths.removeAll()
        recentSleepWindows049.removeAll()
        recentPersistedSessionWindows.removeAll()
        activityMETByDay.removeAll()
        activityCadenceObs.removeAll()
        lastActivityUtc = nil
        lastActivitySampleCount = 0
        phaseCadenceObs.removeAll()
        lastPhaseUtc = nil
        lastPhaseCodeCount = 0
        reachedStreaming = false
        pendingInstallKey = nil
        // A disconnect MID-install is an honest failure (no ack came); a disconnect after streaming leaves
        // the completed `.streaming` outcome intact so the wizard's success transition isn't undone.
        if adoptPhase == .installingKey { adoptPhase = .failed }
        batteryPct = nil
        flush()
        if feedsLive { live.connected = false; live.streamingLiveHR = false }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
        // Auto-reconnect on an INVOLUNTARY drop (#912): the paired ring went out of range or the link timed
        // out. Re-issue a connect on the backoff so it comes back on its own, exactly like the WHOOP strap.
        // A deliberate `stop()` set `intentionalDisconnect`/cleared `reconnectID`, so this is a no-op there.
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension OuraLiveSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Oura: WARNING service discovery failed - \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("Oura: services discovered but the list was empty")
            return
        }
        guard let svc = services.first(where: { $0.uuid == Self.service }) else {
            log("Oura: Oura service NOT FOUND - this ring may not expose the expected GATT layout")
            return
        }
        log("Oura: Oura service found - discovering characteristics")
        // Discover the write + notify chars (gen5 also advertises ...0004/5/6, which v1 discovers but
        // never writes to). RingGen drives which to discover.
        let charUUIDs = OuraGatt.characteristicUUIDs(for: ringGen).map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(charUUIDs, for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Oura: WARNING characteristic discovery failed - \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            log("Oura: characteristics discovered but the list was empty")
            return
        }
        if let wc = chars.first(where: { $0.uuid == Self.writeChar }) {
            writeCharacteristic = wc
            log("Oura: write characteristic found")
        } else {
            log("Oura: write characteristic NOT FOUND - cannot drive the ring")
        }
        if let nc = chars.first(where: { $0.uuid == Self.notifyChar }) {
            log("Oura: notify characteristic found - enabling notifications")
            peripheral.setNotifyValue(true, for: nc)
        } else {
            log("Oura: notify characteristic NOT FOUND - cannot read the ring")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.notifyChar else { return }
        if let error = error {
            log("Oura: WARNING enabling notifications FAILED - \(error.localizedDescription) - ring will send no data")
            return
        }
        log("Oura: notifications enabled (isNotifying=\(characteristic.isNotifying)) - beginning auth")
        // Notifications are live: tell the driver we're ready. It returns the auth-nonce request (or, with
        // no key, drives the honest needs-pairing path).
        advance(.ready)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value, characteristic.uuid == Self.notifyChar else { return }
        let bytes = [UInt8](value)
        // The notify char carries TWO framings on the same channel (OURA_PROTOCOL.md s2):
        //   - 0x2F secure-session sub-frames (auth nonce/status, enable ACKs, live-HR pushes)
        //   - inner TLV event records (IBI / HRV / SpO2 / temp / sleep-phase / battery)
        // Split the notification into outer frames; route 0x2F ones through the driver's secure handler,
        // and feed the remainder to the reassembler as TLV records.
        guard let driver else { return }
        let frames = OuraFraming.parseOuterFrames(bytes)
        // The `0x25` SetAuthKey-response is an OUTER frame (NOT a 0x2F secure sub-frame): `25 01 <status>`,
        // status `0x00` = OK (OURA_PROTOCOL.md s3.2). It only ever arrives during an adopt install we
        // initiated, so handle it ONLY while a key install is pending; otherwise it is ignored (never fed to
        // the TLV decoder, where its op byte would be misread as a record type). Per OURA_PROTOCOL.md s3.2.
        if pendingInstallKey != nil,
           let ackFrame = frames.first(where: { $0.op == Self.setAuthKeyRespOp }) {
            handleKeyInstallAck(status: ackFrame.body.first ?? 0xFF)
            return
        }
        // The `0x11` GetEvents summary drives the history-fetch cursor loop (s5.2/5.3) - detected here as a
        // side-channel PEEK, intentionally NOT stripped from `frames` below: its op (0x11) is well below the
        // event-tag range (tags are >= 0x41), so it round-trips safely through the TLV decoder as an
        // "unknown tag" no-op with correct byte accounting (both framings share the same op/len/body wire
        // shape, so the byte count consumed is identical either way).
        if let summaryFrame = frames.first(where: { $0.op == OuraFraming.getEventsResponseOp }) {
            let hex = summaryFrame.body.map { String(format: "%02x", $0) }.joined(separator: " ")
            log("Oura: GetEvents summary raw body (\(summaryFrame.body.count)B) - \(hex)")
            if let summary = OuraFraming.parseGetEventsResponse(summaryFrame.body) {
                handleHistorySummary(summary)
            }
        }
        // The `0x13` SyncTime response is ALSO an outer frame (ringverse BLE.md), peeked the same
        // non-destructive way: it carries the ring's CURRENT clock counter, which paired with the host
        // wall-clock right now is a DETERMINISTIC anchor — the 0x42 record is only logged when the ring
        // actually adjusts its clock, so an already-synced ring can serve a whole drain with no anchor
        // (observed 2026-07-13: a full night parked unanchored, cursor unable to advance).
        if let syncFrame = frames.first(where: { $0.op == OuraFraming.syncTimeResponseOp }),
           let resp = OuraFraming.parseSyncTimeResponse(syncFrame.body) {
            handleSyncTimeResponse(resp)
        }
        // The `0x0D` GetBattery response is ALSO an outer frame (never a TLV record, s6.10), detected the
        // same non-destructive way as the 0x11 summary: its op is below the event-tag range (>= 0x41), so
        // it round-trips safely through the TLV decoder as an "unknown tag" no-op if left unfiltered. Routed
        // through the existing `.battery` ingest path (batteryPct/onBattery/log side effects).
        if let batteryFrame = frames.first(where: { $0.op == OuraFraming.batteryResponseOp }),
           let battery = OuraDecoders.decodeBattery(batteryFrame.body) {
            ingest([.battery(battery)])
        }
        // #771/#772 capture: log the GetProductInfo reply (serial + hardware pages) raw, once per op per
        // session. Peek only — like the 0x11 summary / 0x0D battery above, a product-info op is below the
        // event-tag range (≥ 0x41) so it round-trips through the TLV decoder as a harmless unknown-tag no-op;
        // nothing here decodes it into a stable id (#771) or a generation (#772) yet — that waits on this
        // fixture. Rendered as hex AND ASCII, since the serial / hardware id are strings (e.g. "BLB_03").
        for frame in frames where Self.productInfoResponseOps.contains(frame.op) {
            let hex = frame.body.map { String(format: "%02x", $0) }.joined(separator: " ")
            guard loggedProductInfo.insert("\(frame.op):\(hex)").inserted else { continue }
            let ascii = String(bytes: frame.body.map { (0x20...0x7e).contains($0) ? $0 : 0x2e }, encoding: .ascii) ?? ""
            log("Oura: product-info reply op=0x\(String(format: "%02x", frame.op)) (\(frame.body.count)B) raw: \(hex) | ascii: \(ascii)")
            // The two GetProductInfo pages both arrive under op 0x19; tell them apart by content:
            //  • hardware page ("BLB_03") → resolves a generation → correct the model (#772).
            //  • serial page ("2H3B2405003655", no "_NN" gen marker) → the ring's STABLE identity → surface it
            //    so the app can re-point this device onto its `oura-<serial>` id (#771).
            if let str = OuraDecoders.productInfoString(frame.body) {
                if let gen = OuraRingGen.from(hardwareId: str) {
                    if gen != ringGen {
                        log("Oura: generation from hardware id \(str) is \(gen.displayName) (was \(ringGen.displayName)) - correcting model")
                        onModel(gen.displayName)
                    }
                } else if Self.isPlausibleSerial(str) {
                    onSerial(str)
                }
            }
        }
        if frames.contains(where: { $0.op == OuraFraming.secureSessionOp }) {
            for frame in frames where frame.op == OuraFraming.secureSessionOp {
                guard let secure = OuraFraming.parseSecureFrame(frame) else { continue }
                handleSecure(driver.handleSecureFrame(secure))
            }
            // Any non-secure outer frames in the same notification are TLV records; fall through to decode.
            // The 0x25 ack (if any) is consumed above, so it never reaches here.
            let tlvBytes = frames.filter { $0.op != OuraFraming.secureSessionOp && $0.op != Self.setAuthKeyRespOp }
                                 .flatMap { [$0.op, UInt8($0.body.count)] + $0.body }
            if !tlvBytes.isEmpty {
                rawDump?.record(bytes: tlvBytes)
                ingestHistory(driver.ingest(notification: tlvBytes, reassembler: reassembler))
            }
            return
        }
        // No secure frame in this notification: treat the whole value as TLV record bytes.
        rawDump?.record(bytes: bytes)
        ingestHistory(driver.ingest(notification: bytes, reassembler: reassembler))
    }

    /// Anchor from the 0x13 SyncTime response (ringverse BLE.md `13 05 <device_ts:4LE> <status:1>`):
    /// the ring's clock counter at the moment it processed our SyncTime, paired with the host wall-clock
    /// at receipt. The tick unit is disambiguated against the persisted resume cursor
    /// (OuraDriver.syncTimeAnchorCandidate — raw ticks vs seconds×10, exactly one must be plausible);
    /// no unambiguous reading → log the raw value for investigation and adopt NOTHING (an honest missing
    /// anchor beats a guessed one). On success everything parked while unanchored resolves immediately.
    private func handleSyncTimeResponse(_ resp: (deviceTimestamp: UInt32, status: UInt8)) {
        guard let driver else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let raw = String(format: "0x%08x", resp.deviceTimestamp)
        if let rt = OuraDriver.syncTimeAnchorCandidate(responseValue: resp.deviceTimestamp,
                                                       historyCursor: historyCursor),
           driver.adoptSyncTimeAnchor(ringTimestamp: rt, unixSeconds: now) {
            let unit = rt == resp.deviceTimestamp ? "ticks" : "seconds x10"
            if !loggedAnchor {
                loggedAnchor = true
                log("Oura: UTC anchor from SyncTime response (0x13) - device rt \(rt) [\(unit), raw \(raw), status \(resp.status)] = now; no 0x42 needed this session")
            }
            drainPendingAnchorEvents()
            drainPendingHypnogramBursts()
        } else {
            log("Oura: SyncTime response (0x13) raw \(raw) status \(resp.status) - no unambiguous tick reading vs cursor \(historyCursor); anchor NOT adopted (investigation)")
        }
    }

    /// Act on what the driver resolved a 0x2F secure sub-frame to.
    private func handleSecure(_ routing: OuraDriver.SecureRouting) {
        switch routing {
        case .nonce(let nonce):
            log("Oura: auth nonce received - submitting proof")
            advance(.nonceReceived(nonce))
        case .authStatus(let status):
            if status.isSuccess {
                log("Oura: auth OK - enabling live HR")
            } else {
                log("Oura: WARNING auth status \(status.rawValue)")
            }
            advance(.authCompleted(status))
        case .enableAck:
            advance(.enableAckReceived)
        case .featureStatus(let st):
            logFeatureStatus(st)   // read-only diagnostic; never advances the state machine
        case .liveHRPush(let body):
            guard let driver else { return }
            ingest(driver.ingestLiveHRPush(body: body))
        case .unhandled:
            break
        }
    }
}

// MARK: - Oura install-key Keychain accessor

/// Keychain Services wrapper for the per-ring 16-byte Oura application install key. Mirrors the
/// `AIKeyStore` generic-password pattern (`Strand/AI/AICoach.swift`) so the key never lands in
/// UserDefaults, a plist, or on disk in the clear. The key is scoped per `deviceId` (the `account`), so
/// each registered ring has its own item. The install key is written here from exactly two places: the
/// adopt key-install handshake (on an OK `0x25` ack, `OuraLiveSource.handleKeyInstallAck`) and the wizard's
/// Advanced "I already have my ring's key" path. This accessor only stores/reads/clears it.
public enum OuraKeyStore {
    private static let service = "com.noop.oura.installkey"
    /// The fixed key length per OURA_PROTOCOL.md s3 (16-byte application auth key).
    public static let keyLength = 16

    private static func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
    }

    /// Store (or replace) the 16-byte install key for `deviceId`. A wrong-length key is rejected (no
    /// partial key is ever stored, so a later read can't return a malformed key).
    @discardableResult
    public static func save(_ key: Data, deviceId: String) -> Bool {
        guard key.count == keyLength else { return false }
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        var attrs = baseQuery(deviceId: deviceId)
        attrs[kSecValueData as String] = key
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Read the stored 16-byte install key for `deviceId`, or nil if none is set (or the stored item is
    /// the wrong length, which is treated as absent so the honest needs-pairing path runs).
    public static func read(deviceId: String) -> Data? {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == keyLength else { return nil }
        return data
    }

    /// Remove the stored install key for `deviceId`.
    public static func clear(deviceId: String) {
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
    }
}

// MARK: - Oura GetEvents cursor persistence

/// Persists the Oura `GetEvents` cursor (OURA_PROTOCOL.md s5.1/5.3) per ring, so a later connection
/// resumes from where the last session left off instead of re-fetching the ring's entire banked history
/// on every single connect. Unlike `OuraKeyStore` this is NOT sensitive - it's an opaque ring-clock tick
/// counter, not a credential - so plain `UserDefaults` is the right (and simplest) store.
enum OuraHistoryCursorStore {
    private static func key(deviceId: String) -> String { "com.noop.oura.historyCursor.\(deviceId)" }

    /// The persisted cursor for `deviceId`, or 0 (fetch everything) if none is stored yet.
    static func read(deviceId: String) -> UInt32 {
        let raw = UserDefaults.standard.object(forKey: key(deviceId: deviceId)) as? Int ?? 0
        return UInt32(clamping: raw)
    }

    /// Store the advanced cursor for `deviceId`.
    static func save(_ cursor: UInt32, deviceId: String) {
        UserDefaults.standard.set(Int(cursor), forKey: key(deviceId: deviceId))
    }
}
