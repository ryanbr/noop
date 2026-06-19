package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.Manifest
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import com.noop.data.HrRow
import com.noop.data.RrRow
import com.noop.data.StreamBatch
import com.noop.data.StreamPersistence
import com.noop.data.WhoopRepository
import com.noop.protocol.AlarmPayload
import com.noop.protocol.BackfillCaptureJsonl
import com.noop.protocol.BackfillCaptureRecord
import com.noop.protocol.BackfillCaptureSummary
import com.noop.protocol.CommandNumber
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Framing
import com.noop.protocol.HapticClock
import com.noop.protocol.Reassembler
import com.noop.protocol.Streams
import com.noop.protocol.Whoop5Config
import com.noop.protocol.extractStreams
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.SedentaryDetector
import com.noop.analytics.StressOnsetDetector
import com.noop.analytics.UserProfile
import com.noop.analytics.WorkoutDetector
import com.noop.ingest.HealthConnectWriter
import com.noop.ui.BiofeedbackPrefs
import com.noop.ui.InactivityPrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.StressNudgeCenter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Immutable snapshot of the live connection + biometric state.
 *
 * Direct port of Strand's `LiveState` (Strand/BLE/LiveState.swift), reduced to the fields the
 * Android UI consumes. Where the Swift app used an `@Published` ObservableObject with closures
 * (`onDoubleTap`, `onWristChange`), the Android port surfaces the most-recent physical input through
 * [lastEvent] and exposes wrist-wear through [worn]; the ViewModel reacts to changes in this flow.
 *
 *  - [connected]   GATT connection is up (CBPeripheral didConnect)
 *  - [bonded]      one confirmed write to the command char has been ACKed (the WHOOP "bond")
 *  - [heartRate]   most-recent plausible BPM (30..220) from the standard 0x2A37 profile OR the
 *                  custom REALTIME_DATA frame
 *  - [rr]          most-recent R-R intervals (ms); the standard profile is the reliable source
 *  - [batteryPct]  battery percent — 5/MG: 0x2A19 whole %; WHOOP 4: GET_BATTERY_LEVEL response u16/10
 *                  (the 4.0's 0x2A19 is a stub constant 100 and is ignored, #77)
 *  - [worn]        wrist-wear from WRIST_ON/WRIST_OFF events; defaults true (Swift parity) so
 *                  wear-gated features work before the first event lands
 *  - [lastEvent]   the most-recent strap EVENT string ("WRIST_ON(9)", "DOUBLE_TAP(14)", …)
 */
data class LiveState(
    val connected: Boolean = false,
    val bonded: Boolean = false,
    /** True ONLY when the link reached a GENUINE encrypted bond — the 5/MG CLIENT_HELLO ack, the WHOOP4
     *  confirmed-write bond, or a strap-reported BLE_BONDED event. NOT set by the live-HR shortcut that
     *  flips [bonded] true when HR streams over the unbonded standard profile on a 5/MG (#69) — so
     *  [bonded] can be true while this is false ("Live HR, not fully paired"). WHOOP 4 always reaches a
     *  genuine bond, so the two track together there. Port of macOS LiveState.encryptedBond. */
    val encryptedBond: Boolean = false,
    val heartRate: Int? = null,
    val rr: List<Int> = emptyList(),
    /** Rolling UI buffer of recent R-R intervals (capped, oldest dropped first). The standard BLE HR
     *  notification usually carries only one or two intervals per packet, so the Live console needs a
     *  short history to render a moving R-R strip / rolling RMSSD. Appended (never replaced) via
     *  [withRRIntervals]; emptied by [clearedBiometrics]. Twin of macOS LiveState.rrRecent (PR#191). */
    val rrRecent: List<Int> = emptyList(),
    val batteryPct: Double? = null,
    /** Charging flag from BATTERY_LEVEL events — wire observation: u8 bit0 (4.0 @26 / 5.0 @30,
     *  ~every 8 min on captured links). Flag only; battery % keeps its family source (#77).
     *  Cleared on disconnect so a stale flag can't outlive the link. Twin of macOS
     *  LiveState.charging. */
    val charging: Boolean? = null,
    /** Wrist-wear from WRIST_ON/WRIST_OFF events. Defaults TRUE to match the macOS LiveState (Swift
     *  parity) — assume worn until the strap says otherwise. (Was false, which made the UI show
     *  "Worn: Off" forever when no WRIST_ON event arrived — issue #18.) */
    val worn: Boolean = true,
    val lastEvent: String? = null,
    /** The strap's current BLE advertising name (the WHOOP 4.0 device name from the OS), captured on
     *  connect. Drives the "Rename strap" card in Settings → Strap. Null until connected. */
    val advertisingName: String? = null,
    /** Status of the last strap-rename attempt (sent / validation reason), surfaced in Settings → Strap.
     *  Replaced by the next attempt. Twin of macOS LiveState.renameStatus. */
    val renameStatus: String? = null,
    /** True while actively scanning for the strap (so the UI can show "Searching…"). */
    val scanning: Boolean = false,
    /** Human-readable reason for the current state (why it can't connect, what to try). */
    val statusNote: String? = null,
    /** A WHOOP 5/MG strap was found. It connects and its battery reads, but live data needs an
     *  MG secure handshake that isn't supported yet — so the UI explains that honestly instead of
     *  showing the generic "charge it and put it on" checklist. */
    val whoop5Detected: Boolean = false,
    /** True while a historical offload session is running, so screens can say "Syncing strap
     *  history…" instead of presenting half-loaded data as final (#77). */
    val backfilling: Boolean = false,
    /** Chunks acked during the current offload session — an honest progress signal (total pending is
     *  unknowable from the protocol, so no percent). Republished every ~10 chunks: the foreground
     *  service re-posts its notification on EVERY LiveState emission, so per-chunk would spam it. */
    val syncChunksThisSession: Int = 0,
    /** Wall-clock (unix seconds) of the last offload that ran to HISTORY_COMPLETE, or null if none
     *  this process. For a cloud-free app this is the honest "is sync actually working?" answer — the
     *  UI renders it as a relative "Last synced N ago". (PR #85) */
    val lastSyncAt: Long? = null,
    /** Set when an offload ended abnormally (strap went quiet mid-sync / idle-watchdog fired), so a
     *  stalled history download isn't silent. Cleared on the next successful HISTORY_COMPLETE. (PR #85) */
    val lastSyncError: String? = null,
    /** Set when a connect attempt fails because the strap wiped its Bluetooth bond — a firmware reset,
     *  or the official WHOOP app re-bonding it. The OS still holds a now-stale bond, so retrying the
     *  direct connect just re-fails. Carries an actionable forget+re-pair guide; cleared on the next
     *  successful connect. Parity with macOS LiveState.reconnectGuide (5/MG firmware reset, 2026-06). */
    val reconnectGuide: String? = null,
    /** EXPERIMENTAL R22 telemetry (#174): how many of the 15 enable_r22 SET_CONFIG flags the strap has
     *  ACKed since the last "Send enable sequence" tap. 15 = the strap accepted the whole sequence (it
     *  returns a COMMAND_RESPONSE per flag — hardware-confirmed). Reset per attempt + per session.
     *  Twin of macOS LiveState.r22FlagsAccepted. */
    val r22FlagsAccepted: Int = 0,
    /** Count of type-0x2F records seen this session OUTSIDE our own history offload. #494 showed these are
     *  historical-offload data (e.g. another BLE client pulling the strap's backlog over the shared notify
     *  channel), NOT a separate live R22 stream — type-0x2F is only ever the historical offload. Kept as a
     *  diagnostic counter, not a "deep stream unlocked" signal. Twin of macOS LiveState.deepPacketsThisSession. (#174) */
    val deepPacketsThisSession: Int = 0,
) {
    /** Set the fresh-packet [rr] AND append the valid intervals onto the bounded [rrRecent] rolling
     *  buffer (oldest fall off first). Non-positive sentinels are dropped from the rolling buffer.
     *  Twin of macOS LiveState.setRRIntervals (PR#191). */
    fun withRRIntervals(intervals: List<Int>, recentLimit: Int = 60): LiveState {
        val valid = intervals.filter { it > 0 }
        if (valid.isEmpty()) return copy(rr = intervals)
        val merged = rrRecent + valid
        val capped = if (merged.size > recentLimit) merged.takeLast(recentLimit) else merged
        return copy(rr = intervals, rrRecent = capped)
    }

    /** Blank all live biometric readouts (HR + R-R + the rolling buffer) so a stale heart rate or R-R
     *  strip can't outlive the link. Applied on disconnect alongside the charging/bond clears. Twin of
     *  macOS LiveState.clearBiometrics (PR#191). */
    fun clearedBiometrics(): LiveState = copy(heartRate = null, rr = emptyList(), rrRecent = emptyList())
}

/**
 * Android CoreBluetooth-equivalent engine for the WHOOP 4.0.
 *
 * Direct port of [Strand/BLE/BLEManager.swift] (the CoreBluetooth engine) folded together with
 * [Strand/BLE/FrameRouter.swift] (the pure decode→state router). Hardware-verified protocol
 * behaviour from the Swift app is preserved exactly; only the framework calls change
 * (CoreBluetooth → android.bluetooth).
 *
 * Lifecycle, mirroring the verified Swift flow:
 *   1. [connect]  — scan by the WHOOP4 custom-service UUID (BLEManager.connect → scanForPeripherals).
 *   2. onScanResult — stop scan, `connectGatt` (centralManager didDiscover → central.connect).
 *   3. onConnectionStateChange(CONNECTED) — `discoverServices` (didConnect → discoverServices).
 *   4. onServicesDiscovered — for the custom service: capture the cmd-write char and fire THE BOND
 *      (one confirmed write of GET_BATTERY_LEVEL); subscribe to the three custom notify chars + the
 *      standard HR and battery chars (didDiscoverCharacteristicsFor).
 *   5. onCharacteristicWrite — the confirmed-write ACK == bonding succeeded; run the connect
 *      handshake EXACTLY ONCE (didWriteValueFor + connectHandshakeDone guard).
 *   6. onCharacteristicChanged — route inbound bytes (didUpdateValueFor):
 *        • HR char (0x2A37)      → parse standard HR + R-R
 *        • battery char (0x2A19) → first byte = percent
 *        • custom notify chars   → Reassembler.feed → Framing.parseFrame → update LiveState
 *
 * Android 12+ (API 31) runtime-permission notes:
 *   - The caller MUST hold BLUETOOTH_SCAN and BLUETOOTH_CONNECT at runtime before [connect].
 *   - On API <= 30, BLUETOOTH + BLUETOOTH_ADMIN are install-time, but a coarse/fine LOCATION
 *     runtime permission is required for BLE *scanning* to return results.
 *   - Declaring `android:usesPermissionFlags="neverForLocation"` on BLUETOOTH_SCAN lets you skip
 *     the location grant on API 31+ (we filter by service UUID, never deriving location).
 *   - Every android.bluetooth call below is annotated @SuppressLint("MissingPermission"); the
 *     ViewModel/Activity owns the permission request and must not call into here until granted.
 */
/**
 * Thin injectable indirection over the raw [BluetoothGatt] operations the client calls.
 *
 * Production wires [RealGattOps] (a straight delegate to a live `BluetoothGatt`). Unit tests inject a
 * stub whose methods throw `android.os.DeadObjectException` to exercise the crash-safety teardown
 * (#314) WITHOUT pulling in Robolectric or a full GATT mock. The interface is deliberately minimal —
 * only the GATT calls that can throw a `DeadObjectException` once the OS Bluetooth binder dies (the
 * radio was turned off mid-link) are routed through it; everything else stays on the concrete handle.
 *
 * The boolean returns mirror `BluetoothGatt`'s own contract (true == the op was accepted by the
 * stack). A THROW is distinct from a `false` return: `false` is a transient BUSY (retry), a throw is
 * a dead binder (tear down). See [WhoopBleClient.safeGatt].
 */
interface GattOps {
    fun writeCharacteristicCompat(
        ch: BluetoothGattCharacteristic,
        value: ByteArray,
        writeType: Int,
    ): Boolean

    fun writeDescriptorCompat(
        descriptor: BluetoothGattDescriptor,
        value: ByteArray,
    ): Boolean

    fun readCharacteristicCompat(ch: BluetoothGattCharacteristic): Boolean
    fun setCharacteristicNotificationCompat(ch: BluetoothGattCharacteristic, enable: Boolean): Boolean
    fun requestMtuCompat(mtu: Int): Boolean
    fun readRemoteRssiCompat(): Boolean
    fun discoverServicesCompat(): Boolean
}

/**
 * Production [GattOps]: a straight delegate to a live [BluetoothGatt]. The TIRAMISU+/legacy branch
 * for the value-bearing write/descriptor calls lives here (one place) so the client call sites read
 * uniformly. Permission is owned by the caller (the client is @SuppressLint("MissingPermission")).
 */
@SuppressLint("MissingPermission")
class RealGattOps(private val gatt: BluetoothGatt) : GattOps {
    override fun writeCharacteristicCompat(
        ch: BluetoothGattCharacteristic,
        value: ByteArray,
        writeType: Int,
    ): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(ch, value, writeType) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                ch.writeType = writeType
                ch.value = value
                gatt.writeCharacteristic(ch)
            }
        }

    override fun writeDescriptorCompat(
        descriptor: BluetoothGattDescriptor,
        value: ByteArray,
    ): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeDescriptor(descriptor, value) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                descriptor.value = value
                gatt.writeDescriptor(descriptor)
            }
        }

    override fun readCharacteristicCompat(ch: BluetoothGattCharacteristic): Boolean =
        gatt.readCharacteristic(ch)

    override fun setCharacteristicNotificationCompat(
        ch: BluetoothGattCharacteristic,
        enable: Boolean,
    ): Boolean = gatt.setCharacteristicNotification(ch, enable)

    override fun requestMtuCompat(mtu: Int): Boolean = gatt.requestMtu(mtu)
    override fun readRemoteRssiCompat(): Boolean = gatt.readRemoteRssi()
    override fun discoverServicesCompat(): Boolean = gatt.discoverServices()
}

class WhoopBleClient(
    private val context: Context,
    /**
     * Local store the decoded live + historical streams are persisted into. Defaults to the
     * process-wide Room-backed repository so the existing `WhoopBleClient(context)` call site keeps
     * working unchanged. The Swift `BLEManager` wires a `WhoopStore`-backed `Collector`/`Backfiller`
     * the same way (BLEManager.bootstrapStore).
     */
    private val repository: WhoopRepository = WhoopRepository.from(context),
    /**
     * Stable device id; all rows are stamped with this. Resolved at startup from
     * [DeviceRegistry.activeDeviceId] (see NoopApplication), falling back to [DEFAULT_DEVICE_ID]
     * ("my-whoop") — which matches the Swift default and the rest of the Android app, so behaviour
     * is unchanged today while the registry takes over as the single source of the active id.
     *
     * MUTABLE (multi-WHOOP, MW-3): [setActiveDeviceId] re-points it so a WHOOP→WHOOP switch attributes
     * new samples to the newly-active WHOOP immediately, without waiting for a relaunch. The single-WHOOP
     * path NEVER reassigns it (the coordinator only calls [setActiveDeviceId] for a non-legacy WHOOP), so
     * with one WHOOP it stays "my-whoop" throughout — byte-for-byte today's behaviour. The live persist
     * sites + the analyze pass read this field directly; the [Backfiller] captured its own copy at
     * construction, so [setActiveDeviceId] re-points that too (see there).
     */
    private var deviceId: String = DEFAULT_DEVICE_ID,
    /** Durable trim-cursor store for the offload safe-trim watermark (see [Backfiller]). */
    private val cursorStore: TrimCursorStore = PrefsTrimCursorStore(context),
    /**
     * Opt-in switch for the EXPERIMENTAL WHOOP 5.0/MG ("puffin") protocol probes (default OFF).
     * Read fresh from SharedPreferences each connect so a Settings toggle takes effect on the next
     * scan. Port of the macOS `PuffinExperiment` gate. NEVER consulted for WHOOP 4.0.
     */
    private val puffinExperiment: PuffinExperiment = PuffinExperiment.from(context),
    /**
     * Builds the [GattOps] indirection from a live [BluetoothGatt]. Production uses [RealGattOps];
     * unit tests inject a factory that returns a stub whose calls throw `DeadObjectException` to
     * exercise the crash-safety teardown (#314) without Robolectric. Default keeps every existing
     * call site unchanged.
     */
    private val gattOpsFactory: (BluetoothGatt) -> GattOps = ::RealGattOps,
) {

    companion object {
        private const val TAG = "WhoopBleClient"
        /**
         * Cap on the in-app strap-log ring buffer (for the "Share strap log" diagnostics export).
         * Raised from the old ~1h (2,000 lines) to retain a rolling ~24h of activity (#510 —
         * maddognik's protocol RE wants a full day to correlate against): a busy live session emits a
         * few lines a minute, so 5,000 short lines comfortably spans a day while staying well under
         * ~1 MB — bounded, never unbounded. Matches the Swift `LiveState.maxLogLines`.
         */
        private const val LOG_BUFFER_MAX = 5000

        /**
         * Fallback device id when the registry has no active device yet (fresh install before the v8
         * migration seeds it, or an all-archived registry). Matches the Swift default and the legacy
         * hardcoded id, so behaviour is unchanged today — the registry resolves to exactly this string.
         */
        const val DEFAULT_DEVICE_ID = "my-whoop"


        // MARK: GATT UUIDs (authoritative, from BLEManager.swift / FINDINGS.md).
        //
        // WHOOP 4.0 custom service + its four characteristics. The shared contract also lists a
        // WHOOP5 service UUID; we scan for both so a v5 strap is discoverable, but the verified
        // characteristic/bond flow is the v4 layout (the only hardware-verified path).
        val WHOOP4_SERVICE: UUID = UUID.fromString("61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        private val CMD_WRITE_CHAR: UUID = UUID.fromString("61080002-8d6d-82b8-614a-1c8cb0f8dcc6")   // CMD → strap
        private val CMD_NOTIFY_CHAR: UUID = UUID.fromString("61080003-8d6d-82b8-614a-1c8cb0f8dcc6")  // responses
        private val EVENT_NOTIFY_CHAR: UUID = UUID.fromString("61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
        private val DATA_NOTIFY_CHAR: UUID = UUID.fromString("61080005-8d6d-82b8-614a-1c8cb0f8dcc6")  // data (fragmented)

        val WHOOP5_SERVICE: UUID = UUID.fromString("fd4b0001-cce1-4033-93ce-002d5875f58a")
        // WHOOP 5.0/MG command-write char — takes the static CLIENT_HELLO (EXPERIMENTAL).
        val WHOOP5_CMD_WRITE_CHAR: UUID = UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a")
        // WHOOP 5.0/MG ("puffin") notify chars — realtime HR rides these as REALTIME_DATA frames, NOT
        // the standard 0x2A37 profile. They require an encrypted/bonded link, so they're subscribed
        // only AFTER the CLIENT_HELLO confirmed-write bonds (mirrors macOS whoop5NotifyChars). (#17)
        private val WHOOP5_NOTIFY_CHARS: List<UUID> = listOf(
            UUID.fromString("fd4b0003-cce1-4033-93ce-002d5875f58a"),
            UUID.fromString("fd4b0004-cce1-4033-93ce-002d5875f58a"),
            UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a"),
            UUID.fromString("fd4b0007-cce1-4033-93ce-002d5875f58a"),
        )

        // Standard BLE profiles. HR + R-R works UNBONDED; battery is a plain %.
        private val HEART_RATE_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        private val HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        private val BATTERY_SERVICE: UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_CHAR: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")

        // Client Characteristic Configuration Descriptor — written to enable notifications
        // (CoreBluetooth does this implicitly via setNotifyValue; Android requires the explicit write).
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Auto-rescan delay after an unintentional disconnect (BLEManager: "rescanning in 3s"). */
        private const val RECONNECT_DELAY_MS = 3_000L
        /** Give up a scan after this long with no strap found, and tell the user why. */
        private const val SCAN_TIMEOUT_MS = 20_000L
        /** Rotate to the other WHOOP family after this long with no discovery, in case the persisted
         *  preference went stale after an update/restore. Mirrors macOS scanFallbackDelaySeconds. (PR#195) */
        private const val SCAN_FALLBACK_DELAY_MS = 8_000L

        // MARK: Live-persistence cadence (port of Swift CollectorPolicy.default).
        /** Flush the live buffer after this many frames OR [FLUSH_MAX_INTERVAL_MS], whichever first. */
        private const val FLUSH_MAX_FRAMES = 64
        private const val FLUSH_MAX_INTERVAL_MS = 30_000L

        // MARK: Historical-offload timers (ported from BLEManager.swift, same constants).
        /** Periodic re-offload of the type-47 store while connected+bonded. 900s = 15 min (matches WHOOP). */
        private const val BACKFILL_INTERVAL_MS = 900_000L
        /** How far back the inactivity check reads gravity on each offload completion (4 h comfortably
         *  spans the threshold + re-nudge cadence and a separating Active break for bout continuity). */
        private const val INACTIVITY_LOOKBACK_S = 4 * 3600L
        /**
         * Idle watchdog: if no genuine offload frame arrives for this long mid-session, end the
         * session (the durable strap_trim cursor means the next session resumes where we left off).
         * Generous (60s, not 20s) because the type-43 raw flood eats BLE airtime between chunks.
         */
        private const val BACKFILL_IDLE_TIMEOUT_MS = 60_000L
        /** Deferral before the first connect-time offload, so SET_CLOCK/GET_DATA_RANGE round-trip first. */
        private const val INITIAL_BACKFILL_DELAY_MS = 1_500L
        /** 5/MG fail-open gate: how long to wait for a GET_DATA_RANGE SUCCESS before requesting
         *  history anyway (real hardware sometimes swallows the first range query, #78 fork). */
        private const val DATA_RANGE_GATE_MS = 2_000L
        /** 5/MG zero-frame retry: pause before re-requesting history when a session timed out having
         *  produced nothing (the first request after connect can go entirely unanswered). */
        private const val WHOOP5_HISTORY_RETRY_DELAY_MS = 700L
        /** Debounce between a committed backfill chunk and the on-device scoring pass it schedules. */
        private const val POST_BACKFILL_ANALYZE_DELAY_MS = 1_500L
        /** #174: window after the last offload frame/HISTORY_COMPLETE during which a type-0x2F frame is
         *  treated as trailing-historical, not live. Mirrors macOS deepPacketLiveCooldownSeconds (10s). */
        private const val DEEP_PACKET_LIVE_COOLDOWN_MS = 10_000L

        /** ATT MTU to request on connect. The default 23 caps every notification at 20 payload bytes,
         *  so the historical offload fragments across many notifications (slow, more reassembly). 247
         *  is what the official app requests (and the common BLE max), letting a full type-47 record
         *  ride one packet. Benefits both families' offload. (PR #85, iHateSubscriptions) */
        private const val GATT_MTU = 247
        /** Proceed to service discovery even if onMtuChanged never fires (some stacks ignore
         *  requestMtu); keeps connect from stalling behind the MTU exchange. */
        private const val MTU_FALLBACK_MS = 1_500L

        /** 5/MG raw-capture file (app filesDir; shared via Settings → "Share 5/MG capture"). */
        const val WHOOP5_CAPTURE_FILE = "whoop5-backfill-capture.jsonl"
        /** Rotation threshold (~10 MB) and absolute per-file line cap (a full overnight offload is
         *  ~28k frames; 40k leaves headroom — his fork's 20k truncated real sessions, #78 fork). */
        private const val WHOOP5_CAPTURE_MAX_BYTES = 10L * 1024 * 1024
        private const val WHOOP5_CAPTURE_MAX_LINES = 40_000

        /** Live-gesture freshness window (seconds). A DOUBLE_TAP / WRIST_* event only updates live state
         *  if its event_timestamp is within this of wall-now, so a *replayed historical* gesture during a
         *  backfill offload is ignored. Port of Swift FrameRouter.liveGestureWindowSeconds (#69). */
        private const val LIVE_GESTURE_WINDOW_SECONDS = 45L

        // MARK: Live-stream keep-alive (port of BLEManager.keepAlive*). The WHOOP firmware lets the
        // realtime HR stream lapse if it isn't re-armed, so a stuck-on-stale HR that only a manual
        // disconnect/reconnect fixes is really a missing keep-alive. We re-arm + poll battery every
        // 30s, and bounce a truly silent link after 120s (the auto version of disconnect+reconnect).
        private const val KEEPALIVE_INTERVAL_MS = 30_000L
        /** No inbound data for this long ⇒ the link/stream stalled; bounce it to resume streaming. */
        private const val KEEPALIVE_STALL_MS = 120_000L
        /** Stream gone quiet this long (but not yet stall) ⇒ re-subscribe in case a CCCD silently dropped. */
        private const val KEEPALIVE_QUIET_MS = 45_000L

        /** A CCCD write can transiently return BUSY if the stack slot hasn't freed yet; retry the same
         *  subscribe a few times (short backoff) before giving up, rather than dropping the stream. */
        private const val CCCD_RETRY_DELAY_MS = 60L
        private const val MAX_CCCD_RETRIES = 8

        /** A command write can transiently return BUSY on a stricter stack (notably Android 13+, and
         *  worst on Android 16) when the previous write hasn't physically completed. Retry the SAME
         *  frame a few times (short backoff) instead of dropping it — a dropped TOGGLE_REALTIME_HR /
         *  SET_CLOCK / offload-ack silently breaks live HR, the clock, or the backfill (issue #77). */
        // Base backoff; the per-frame delay ESCALATES (× attempt) so a sustained-BUSY stack — a Pixel 7
        // on Android 16 logged ~56 busy retries + a few hard drops in 10 min (#77) — gets progressively
        // more time to clear instead of burning the whole budget in ~70ms.
        private const val WRITE_RETRY_DELAY_MS = 12L
        private const val MAX_WRITE_RETRIES = 12
        /** Pacing gap before freeing the slot after a WITHOUT-response write. A bare post fires the next
         *  write on the same looper tick — before Android's GATT has accepted the previous one, which it
         *  then rejects. A small gap lets the stack settle and largely eliminates the rejections (#77). */
        private const val WITHOUT_RESPONSE_PACE_MS = 8L
        /** Delay before reading link RSSI after connect — past the bond/MTU/discovery handshake so the
         *  read can't occupy the single GATT op slot the critical setup commands need. Diagnostic only.
         *  (PR #241, ryanbr.) */
        private const val RSSI_READ_DELAY_MS = 3000L

        /**
         * True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
         * METADATA=49, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
         * REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
         * this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
         * offload progress. Port of Swift `BLEManager.isOffloadFrame`.
         */
        fun isOffloadFrame(frame: ByteArray, family: DeviceFamily): Boolean {
            // WHOOP 5/MG's inner record starts at byte 8 (+4 envelope), and its HISTORY_END/COMPLETE
            // is PUFFIN_METADATA=56, NOT 49. Reading frame[4] with {47,48,49,50} (the old WHOOP4-only
            // form) drops every 5/MG offload-closing frame as live-flood, so the strap never trims and
            // offload never completes. Matches the hardware-proven Swift isOffloadFrame
            // (BLEManager.swift:500, "case 47,48,49,50,56"). (#78)
            val typeIndex = if (family == DeviceFamily.WHOOP5) 8 else 4
            if (frame.size <= typeIndex) return false
            return when (frame[typeIndex].toInt() and 0xFF) {
                47, 48, 49, 50, 56 -> true // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS / PUFFIN_METADATA
                // HISTORICAL_IMU_DATA_STREAM — a genuine 5/MG history BODY type (observed in bulk in
                // real ACK-enabled hardware captures, #78 fork). 5/MG-only; never seen from a WHOOP 4.
                52 -> family == DeviceFamily.WHOOP5
                else -> false // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
            }
        }

        /**
         * The gate every offload kick passes through: a sync may start ONLY when the link is up
         * ([connected]), the command channel is usable ([bonded]), and no offload is already running
         * ([backfilling]). Extracted as a pure predicate so the auto-kick, the 900s periodic timer,
         * and the manual "Sync now" button (#93) can't drift apart, and so the no-op behaviour is
         * unit-testable without a live GATT stack. Mirrors the `requestSync` guard in BLEManager.swift.
         */
        fun canRequestSync(connected: Boolean, bonded: Boolean, backfilling: Boolean): Boolean =
            connected && bonded && !backfilling

        /**
         * #314: should a Throwable that escaped a raw GATT call trigger a full link teardown?
         *
         * Once the OS Bluetooth radio is turned off mid-link the binder dies, and `BluetoothGatt`'s
         * write/read/descriptor/mtu/discover calls throw `android.os.DeadObjectException` (an unchecked
         * `RuntimeException`); we also see `IllegalStateException` (adapter off) and `SecurityException`
         * (permission revoked). ALL of these mean the link is unusable, so the honest answer is always
         * `true` — there is no recoverable GATT throw. Kept as a pure, instance-free predicate so the
         * catch policy in [safeGatt] is unit-testable without a live GATT stack (the actual call sites
         * need a real binder, which the unit harness has no way to fake). The named types are documented
         * here because they are the ones observed in #314 and the prompt's required catch set.
         */
        fun shouldTeardownOnGattThrow(t: Throwable): Boolean = when (t) {
            is android.os.DeadObjectException,   // binder died — the #314 crash
            is IllegalStateException,            // adapter/stack in a bad state
            is SecurityException,                // BLUETOOTH_CONNECT revoked mid-link
            -> true
            // Any other RuntimeException out of a GATT call is equally unrecoverable: there is no path
            // where continuing to drive a throwing GATT is correct, so tear down rather than crash.
            else -> true
        }

        /**
         * The LiveState the teardown path publishes after the link drops (#314). Pure model of the
         * `connected = false` + biometrics-cleared transition so a test can assert the UI flips to
         * disconnected without a live instance. Mirrors what `handleDisconnect` applies via
         * `LiveState.clearedBiometrics().copy(...)`.
         */
        fun disconnectedLiveState(previous: LiveState): LiveState =
            previous.clearedBiometrics().copy(
                connected = false, bonded = false, encryptedBond = false,
                backfilling = false, syncChunksThisSession = 0, charging = null,
            )

        /**
         * Pure classification of a COMPLETED (HISTORY_COMPLETE) offload, extracted from exitBackfilling
         * so it's unit-testable without a live GATT stack. Mirrors Swift
         * `BLEManager.classifyCompletedOffload`.
         *  - first  = bankedSensorRecords: the strap handed over real sensor records (decoded this pass
         *    OR rows persisted) — its clock is banking to flash.
         *  - second = bankedNothing (#77/#120/#214): the offload completed but banked NO sensor records,
         *    in EITHER shape — console-only across ≥3 diagnostic chunks, OR a near-empty metadata-only
         *    completion (zero rows persisted) with fewer than 3 console frames. The #214 broadening is
         *    the `rowsPersisted == 0` arm; before it a metadata-only completion slipped through silently.
         *    The sustained-streak gate (EmptySyncTracker) still decides whether the banner fires.
         */
        fun classifyCompletedOffload(
            decodedChunks: Int,
            consoleChunks: Int,
            rowsPersisted: Int,
        ): Pair<Boolean, Boolean> {
            val bankedSensorRecords = decodedChunks > 0 || rowsPersisted > 0
            val bankedNothing = !bankedSensorRecords && (consoleChunks >= 3 || rowsPersisted == 0)
            return Pair(bankedSensorRecords, bankedNothing)
        }

        /**
         * Newest plausible-unix marker in a GET_DATA_RANGE response = the strap's newest stored
         * record. Mirrors Swift `BLEManager.dataRangeNewestUnix`: scan u32 LE words in the response
         * body (starts at frame[7], after [type,seq,cmd]), keep those in the unix range, return max.
         */
        fun dataRangeNewestUnix(frame: ByteArray): Long? {
            if (frame.size <= 7) return null
            var newest: Long? = null
            var i = 7
            while (i + 4 <= frame.size) {
                val w = (frame[i].toLong() and 0xFFL) or
                    ((frame[i + 1].toLong() and 0xFFL) shl 8) or
                    ((frame[i + 2].toLong() and 0xFFL) shl 16) or
                    ((frame[i + 3].toLong() and 0xFFL) shl 24)
                if (w in 1_700_000_000L..1_900_000_000L) newest = maxOf(newest ?: 0L, w)
                i += 4
            }
            return newest
        }

        /** OLDEST plausible record timestamp in a GET_DATA_RANGE frame — the start of the strap's stored
         *  history. Same scan as [dataRangeNewestUnix] but keeps the minimum, so one connect can report the
         *  full banked SPAN (oldest…newest) = the backlog DEPTH a deep oldest-first drain must cover before
         *  recent nights land (#364). Mirrors Swift `BLEManager.dataRangeOldestUnix`. */
        fun dataRangeOldestUnix(frame: ByteArray): Long? {
            if (frame.size <= 7) return null
            var oldest: Long? = null
            var i = 7
            while (i + 4 <= frame.size) {
                val w = (frame[i].toLong() and 0xFFL) or
                    ((frame[i + 1].toLong() and 0xFFL) shl 8) or
                    ((frame[i + 2].toLong() and 0xFFL) shl 16) or
                    ((frame[i + 3].toLong() and 0xFFL) shl 24)
                if (w in 1_700_000_000L..1_900_000_000L) oldest = minOf(oldest ?: Long.MAX_VALUE, w)
                i += 4
            }
            return oldest
        }

        /** #364 auto-continue cap: consecutive immediate re-kicks per connection before falling back to
         *  the 900s periodic timer. 6 × ~60s ≈ 6 min of back-to-back draining without letting a
         *  misbehaving strap monopolise Bluetooth. Mirrors Swift BackfillContinuation.defaultMaxAutoContinues. */
        const val MAX_AUTO_CONTINUES = 6

        /** #364 "more backlog remains" margin (seconds): how far ahead the strap must be of our persisted
         *  data frontier before we treat it as behind, not clock noise. Matches the Swift
         *  BackfillContinuation.defaultBehindGapSeconds (and StuckStrapDetector's behindGapSeconds). */
        const val AUTO_CONTINUE_BEHIND_GAP_SECONDS = 300L

        /**
         * Decides whether a backfill session that ended on the 60s IDLE cap (NOT a true HISTORY_COMPLETE)
         * should immediately re-kick another offload instead of tearing down to wait the 900s periodic
         * floor (#364). The strap offloads OLDEST-first at ~60s/session with no auto-continue, so on a
         * deep backlog each connection drains only the oldest pass then waits — "last night" can take many
         * connections even while the strap stays connected. Auto-continuing drains it in back-to-back
         * passes. Pure predicate so it's unit-testable without a live GATT stack; mirrors Swift
         * `BackfillContinuation.shouldAutoContinue` byte-for-behaviour.
         *
         * ALL four guards must hold:
         *  1. [stillConnected] — connected + bonded; a dropped link uses the normal reconnect path.
         *  2. backlog remains — the strap's newest banked record ([strapNewestTs], GET_DATA_RANGE) is
         *     AHEAD of our persisted data frontier ([ourFrontierTs] = max persisted HR ts) by more than
         *     [behindGapSeconds]. Comparing the frontier (not the trim u32, which climbs on empty ENDs even
         *     when stuck) separates "more to fetch" from "caught up / off-wrist". null on either side ⇒
         *     unknown ⇒ don't auto-continue.
         *  3. [lastTrimAdvanced] — the just-ended session actually moved the strap's trim cursor. A frozen
         *     cursor (console-only / refusing to trim) would spin forever; stop and let the floor retry.
         *  4. [consecutiveCount] < [maxAutoContinues] — hard per-connection cap.
         */
        fun shouldAutoContinue(
            stillConnected: Boolean,
            strapNewestTs: Long?,
            ourFrontierTs: Long?,
            lastTrimAdvanced: Boolean,
            consecutiveCount: Int,
            rowsPersistedThisSession: Int = 0,
            maxAutoContinues: Int = MAX_AUTO_CONTINUES,
            behindGapSeconds: Long = AUTO_CONTINUE_BEHIND_GAP_SECONDS,
        ): Boolean {
            if (!stillConnected) return false                          // 1
            if (consecutiveCount >= maxAutoContinues) return false      // 4 (cap)
            if (!lastTrimAdvanced) return false                        // 3 (don't spin on a frozen cursor)
            // 2a: strap reports newer data than we hold — reliable WHEN its clock epoch is sane.
            val newest = strapNewestTs
            val frontier = ourFrontierTs
            if (newest != null && frontier != null && (newest - frontier) > behindGapSeconds) return true
            // 2b (#451): GET_DATA_RANGE's "newest" can read a STALE / wrong-epoch value — a strap that was
            // fully discharged (or carries a previous owner's history) banks records across multiple clock
            // epochs and can latch an OLD one (e.g. 2024 when the real newest is 2026). That false "already
            // past it" would stop the drain after ONE session and make the user tap the strap to re-trigger
            // (#364 / #451). But guard #3 proved the trim advanced, so if this session also PERSISTED REAL
            // SENSOR ROWS the strap is still handing over real backlog — keep going. Empty / console-only
            // ENDs persist 0 rows, so a stuck or caught-up strap won't spin; the cap bounds it regardless.
            return rowsPersistedThisSession > 0
        }
    }

    // MARK: Published state — the single source of truth the UI observes.
    private val _state = MutableStateFlow(LiveState())
    val state: StateFlow<LiveState> = _state.asStateFlow()

    // MARK: Multi-WHOOP (additive — inert on the single-WHOOP path; MW-2/MW-3 parity with iOS BLEManager).

    /**
     * Pin connections to ONE specific strap by its [BluetoothDevice.address] (the Android analogue of the
     * iOS CBPeripheral identifier). When non-null, [onScanResult]'s normal connect path connects ONLY to
     * the device whose `address == preferredAddress` and ignores every other discovered WHOOP. When null
     * (the only state a single-WHOOP user is ever in) the discover path is byte-for-byte unchanged — it
     * connects to the FIRST WHOOP discovered. The app sets this to the active device's persisted
     * `peripheralId`; setting it does NOT start/stop/redirect an in-flight connection on its own. Mirrors
     * macOS `BLEManager.preferredPeripheralUUID`.
     */
    @Volatile
    var preferredAddress: String? = null

    /** True when [dev] is the strap we're pinned to — or when no pin is set (single-WHOOP default, any
     *  WHOOP acceptable). The involuntary-reconnect fast paths consult this so they can never re-attach to a
     *  non-pinned strap, mirroring macOS/iOS BLEManager.isPreferredPeripheral (multi-WHOOP parity). */
    private fun isPreferred(dev: BluetoothDevice): Boolean {
        val p = preferredAddress ?: return true
        return dev.address.equals(p, ignoreCase = true)
    }

    /** A WHOOP strap surfaced by the Add-a-device wizard's present-scan ([scanForWhoops]) WITHOUT
     *  auto-connecting. [address] is the BLE MAC; [name] the advertised name (may be null); [rssi] the
     *  signal. Twin of the iOS `discoveredWhoops` tuple (uuid/name/rssi). */
    data class DiscoveredWhoop(val address: String, val name: String?, val rssi: Int)

    private val _discoveredWhoops = MutableStateFlow<List<DiscoveredWhoop>>(emptyList())
    /** WHOOP straps seen while [scanningForList] is true (the Add-a-device wizard's present-scan), WITHOUT
     *  auto-connecting. Cleared at the start of each [scanForWhoops]. Empty/unused on the default path. */
    val discoveredWhoops: StateFlow<List<DiscoveredWhoop>> = _discoveredWhoops.asStateFlow()

    private val _connectedPeripheralAddress = MutableStateFlow<String?>(null)
    /** The BLE address of the strap currently connected, or null when disconnected. Twin of macOS
     *  BLEManager.connectedPeripheralUUID — drives SourceCoordinator's first-connect identity adoption. */
    val connectedPeripheralAddress: StateFlow<String?> = _connectedPeripheralAddress.asStateFlow()

    /** Add-a-WHOOP wizard present-scan flag: while true, [onScanResult] ACCUMULATES every discovered strap
     *  into [discoveredWhoops] instead of auto-connecting. Turned on by [scanForWhoops], off by
     *  [stopWhoopScan]. Default false leaves the auto-connect path untouched. Written on the main looper
     *  (scan lifecycle) and read in the GATT/scan callback — @Volatile for cross-thread visibility. */
    @Volatile
    private var scanningForList = false

    /**
     * Multi-source seam (Phase 1B): publish a live HR/R-R reading that came from a NON-WHOOP source
     * (the isolated [StandardHrSource], driven by [SourceCoordinator]) into the SAME [state] flow the
     * UI already observes, so a generic HR strap's live HR shows in the existing Live UI.
     *
     * This is a tiny ADDITIVE call site, not a change to any WHOOP logic: it is invoked ONLY while the
     * coordinator has paused WHOOP's own BLE (a non-WHOOP strap is the active device), so it can never
     * race the WHOOP scan/connect/parse/persist path. The WHOOP-active path never calls it. HR is range
     * gated exactly like [parseStandardHr]; R-R rides [LiveState.withRRIntervals] (rolling buffer + fresh
     * packet), matching how the WHOOP standard-HR notification surfaces live data. Mirrors the Swift
     * StandardHRSource writing into the shared LiveState. Persistence is owned by the source's own
     * `persist` closure — this method touches only the live readout.
     */
    fun publishExternalLiveHr(hr: Int, rr: List<Int>) {
        if (rr.isNotEmpty()) _state.value = _state.value.withRRIntervals(rr)
        if (hr in 30..220) {
            _state.value = _state.value.copy(heartRate = hr, connected = true)
        }
    }

    // MARK: Android Bluetooth handles.
    private val bluetoothManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    /** Injectable indirection over [gatt]'s raw GATT calls (see [GattOps]). Rebuilt whenever [gatt] is
     *  (re)assigned in [connectToDevice], cleared in the teardown path alongside `gatt = null`. */
    private var gattOps: GattOps? = null
    private var cmdCharacteristic: BluetoothGattCharacteristic? = null

    /** Frame reassembler for the fragmented custom notify chars (port of Reassembler). Reassigned per
     *  connection with the detected family — WHOOP5/MG frames use a different length encoding. */
    private var reassembler = Reassembler()

    /** Rolling command sequence byte; `seq = seq &+ 1` before each send (Swift `seq: UInt8`). */
    private var seq: Int = 0

    /** True once the confirmed-write bond ACK lands (Swift `didBond`). */
    private var didBond = false

    /** Runs the connect handshake EXACTLY ONCE per connection (Swift `connectHandshakeDone`). */
    private var connectHandshakeDone = false

    /** True when the user asked to disconnect; suppresses the auto-rescan (Swift `intentionalDisconnect`).
     *  Written on the main looper (connect/disconnect/keep-alive bounce) and read on the GATT binder
     *  thread (handleDisconnect), so it must be @Volatile for cross-thread visibility. */
    @Volatile
    private var intentionalDisconnect = false
    /// The strap family the user chose to pair, remembered so an auto-reconnect after a
    /// dropout re-scans for the same model instead of falling back to WHOOP 4.0.
    private var selectedModel = WhoopModel.WHOOP4
    /// The last device we connected to, kept so an auto-reconnect after a dropout can connect
    /// DIRECTLY to it (autoConnect=true) instead of scanning. A bonded strap the OS still holds (or
    /// that simply isn't advertising) won't appear in a scan — so the old scan-only reconnect looped
    /// "No WHOOP strap found" until the user forced pairing mode (#61). Mirrors macOS, which already
    /// reconnects via retrieveConnectedPeripherals + central.connect before scanning.
    private var lastDevice: BluetoothDevice? = null

    /** Address of the strap we last connected to — for persisting it + auto-reconnecting on launch (#67). */
    val lastDeviceAddress: String? get() = lastDevice?.address
    /// The family actually discovered on the connected peripheral. Drives family-aware frame
    /// parsing and gates the WHOOP4-only bond/handshake. Set in onServicesDiscovered.
    private var connectedFamily = DeviceFamily.WHOOP4

    /** True while a scan is active, so we never start a second scan (Android scanner is stateful). */
    private var scanning = false

    /** All BLE work hops onto the main looper, matching CBCentralManager(queue: .main). */
    private val handler = Handler(Looper.getMainLooper())

    /**
     * Mirror the strap log to logcat (`Log.d`). Default OFF — a normal user has no reason to write the
     * connection log to the system log, and shouldn't have to. The in-app ring buffer below always
     * records regardless, so the "Share strap log" export still works for everyone (issues #17/#18);
     * this gate only controls the adb-visible `Log.d`, which is the tool developers use to watch a
     * connection live (`adb logcat -s WhoopBleClient`). Driven by Settings → Strap → "Debug logging"
     * (persisted as [com.noop.ui.NoopPrefs.KEY_DEBUG_LOGGING]); the value is pushed down from the
     * composition root so this low-level client never depends on the UI/prefs layer. @Volatile because
     * [log] runs on both the GATT binder thread and the main looper.
     */
    @Volatile
    var debugLogcat: Boolean = false

    /** In-memory ring buffer of the strap log so it can be exported from the UI for bug reports.
     *  `log()` always writes here (under [logBuffer]'s monitor); logcat mirroring is opt-in via
     *  [debugLogcat]. Android's `Log.d` isn't reachable by a normal user, which is why the in-app
     *  buffer + "Share strap log" exist (issues #17/#18). */
    private val logBuffer = ArrayDeque<String>()
    private val logTimeFmt = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US)
    // PII scrubbers for the shareable strap log (#445) live at file scope as [redactStrapLogPii]
    // so they're unit-testable without constructing this Android-only client (#421).

    /** Fired if a scan finds nothing in [SCAN_TIMEOUT_MS]; stops scanning and explains why. */
    private val scanTimeoutRunnable = Runnable {
        if (scanning && !_state.value.connected) {
            stopScan()
            log("No WHOOP strap found within ${SCAN_TIMEOUT_MS / 1000}s")
            _state.value = _state.value.copy(
                scanning = false,
                statusNote = "No strap found. Check it's charged and on your wrist, and that the " +
                    "official WHOOP app isn't connected to it (a strap will only pair with one app " +
                    "at a time). Then tap Connect again.",
            )
        }
    }

    /** Fired after [SCAN_FALLBACK_DELAY_MS] of a service-filtered scan with no discovery: rotate to the
     *  other WHOOP family in case the persisted preference is stale (after an update/restore). Cancelled
     *  on discovery/connect. Mirrors macOS BLEManager scanFallbackWorkItem. (PR#195) */
    private val scanFallbackRunnable = Runnable {
        if (scanning && !_state.value.connected) {
            val fallback = selectedModel.fallbackScanModel
            log("No ${selectedModel.displayName} found yet — trying ${fallback.displayName}")
            stopScan()   // clears the scanning flag + the LE scan; startScan re-arms both
            startScan(fallback, allowFallback = true)
        }
    }

    // ====================================================================================
    // MARK: Persistence + historical offload (NEW — ports BLEManager.swift Collector/Backfiller)
    // ====================================================================================

    /**
     * Background scope for all DB writes (insert is a suspend Room call). SupervisorJob so one
     * failed insert never cancels the others; IO dispatcher keeps DB work off the main looper.
     * Cancelled in [shutdown].
     */
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Durable archive for undecodable history record frames (#77/#91). Written BEFORE the strap is
     * acked, so an unrecognised firmware layout can't cost the user their only copy: the ack frees
     * the strap's records, and this archive is the only remaining copy until the layout is mapped.
     */
    private val rawHistoryArchive = RawHistoryArchive(context)

    init {
        // Retro-decode (#151): when the decoder gains a historical layout (WHOOP 4.0 v25), re-run every
        // archived undecodable frame through it and insert whatever now decodes — the only path by
        // which already-acked, strap-freed history backfills after an update. Runs once per APP version
        // (no manual decoder constant to forget to bump, #152); idempotent if it re-runs (offloaded rows
        // dedupe by ts), and the gate holds on a failed insert so the records retry next launch. Mirrors
        // the Swift BLEManager gate. (This client is a process singleton, so init runs once per process.)
        ioScope.launch {
            val rows = rawHistoryArchive.replayIfNeeded(
                repository, deviceId, com.noop.ui.AppChangelog.CURRENT_VERSION,
            )
            if (rows > 0) {
                log("Backfill: retro-decoded $rows record(s) from the reject archive after an update.")
            }
        }
    }

    /** The offload state machine. Ack callback writes HISTORICAL_DATA_RESULT (with response). */
    private val backfiller = Backfiller(
        repository = repository,
        deviceId = deviceId,
        cursorStore = cursorStore,
        ackTrim = { trim, endData -> ackHistoricalChunk(trim, endData) },
        onChunkCommitted = { batch -> onBackfillChunkCommitted(batch) },
        onConsoleChunk = { consoleChunksThisSession += 1 },
        // #77/#91: archive undecodable frames before the ack. append() returns ok=true (written, or
        // archive-full → still safe to ack) and THROWS only on a genuine write failure → return false
        // so finishChunk holds the cursor/ack and the strap re-sends. The throw is mapped to the
        // boolean contract HERE so nothing can escape into the offload drain loop.
        rejectedSink = { frames, trim ->
            try {
                val r = rawHistoryArchive.append(frames, trim, connectedFamily)
                if (r.written) log("Backfill: ${frames.size} undecodable frame(s) archived before ack")
                else log("Backfill: ${frames.size} undecodable frame(s) NOT archived (archive full) — acking anyway")
                r.ok
            } catch (t: Throwable) {
                log("Backfill: reject-archive write FAILED (${t.message}) — holding ack so the strap re-sends")
                false
            }
        },
        log = { s -> log(s) },
    )

    /**
     * Fresh history just landed durably (a backfill chunk committed + acked) — schedule one debounced
     * on-device scoring pass so recovery/strain/sleep appear right away instead of waiting for the
     * UI's 15-min analysis tick (which also doesn't run at all with the app UI closed and only the
     * foreground service alive). Mirrors the AppViewModel loop's profile + writeback behaviour. (#78 fork)
     */
    private fun onBackfillChunkCommitted(batch: StreamBatch) {
        decodedChunksThisSession += 1   // invoked once per non-empty decoded chunk (#77 family tally)
        if (!analyzeAfterBackfillScheduled.compareAndSet(false, true)) return
        ioScope.launch {
            try {
                delay(POST_BACKFILL_ANALYZE_DELAY_MS) // let trailing chunks of the same session land
                val profileStore = ProfileStore.from(context)
                val profile = UserProfile(
                    weightKg = profileStore.weightKg,
                    heightCm = profileStore.heightCm,
                    age = profileStore.age.toDouble(),
                    sex = profileStore.sex,
                    stepTicksPerStep = profileStore.stepTicksPerStep,
                )
                runCatching {
                    IntelligenceEngine.analyzeRecent(
                        repo = repository,
                        profile = profile,
                        importedDeviceId = deviceId,
                        maxHROverride = profileStore.hrMaxOverride.takeIf { it > 0 }?.toDouble(),
                        // Steps-estimate calibration: honor the user's manual override and persist the fit
                        // after a backfill too, so the Settings/Steps screen reflects the latest data.
                        manualStepCoefficient = profileStore.stepsManualOverride,
                        persistStepsCalibration = { cal ->
                            profileStore.stepsCalibrationCoefficient = cal.coefficient
                            profileStore.stepsCalibrationSampleDays = cal.sampleDays
                            profileStore.stepsCalibrationConfidence = cal.confidence
                            profileStore.stepsCalibrationManual = cal.manual
                        },
                    )
                }.onSuccess {
                    log("Backfill: post-sync scoring pass done")
                    // #277 diagnostic: surface the day-key the dashboard treats as "today" against the
                    // newest banked row, so a UTC-bucket vs local-day split (rows persist but Today
                    // freezes) shows up plainly in the shared strap log. Best-effort — a diagnostic read
                    // must never break scoring.
                    runCatching {
                        val merged = repository.daysMerged(deviceId)
                        val newest = merged.maxByOrNull { it.day }?.day ?: "—"
                        val todayKey = com.noop.ui.logicalDayKeyNow()
                        val present = if (merged.any { it.day == todayKey }) "present" else "MISSING"
                        log("Backfill: ${merged.size} day(s) banked; newest=$newest, dashboard-today=$todayKey ($present)")
                    }
                }.onFailure {
                    // The scoring pass now hops to Dispatchers.Default; shutdown() cancels it, which is
                    // not a scoring failure — rethrow so the cancellation isn't swallowed/mis-logged. (#125)
                    if (it is kotlin.coroutines.cancellation.CancellationException) throw it
                    log("Backfill: post-sync scoring failed: ${it.message}")
                }
                // Keep the opt-in Health Connect writeback fresh in background-only operation too.
                if (NoopPrefs.hcWriteback(context)) {
                    runCatching { HealthConnectWriter.write(context, repository) }
                }
            } finally {
                analyzeAfterBackfillScheduled.set(false)
            }
        }
    }

    /** True while a historical offload is in progress (offload frames route to the Backfiller). */
    @Volatile
    private var backfilling = false
    /** Chunks acked this offload session — feeds LiveState.syncChunksThisSession (throttled). Only
     *  touched on the serial backfill drain coroutine + the begin/exit lifecycle. */
    private var ackedChunksThisSession = 0
    /** #77 family: per-session chunk tallies to tell an EMPTY completed sync (strap handed over only
     *  console/diagnostic output — not banking to flash) from a clean one. Reset at session start. */
    private var decodedChunksThisSession = 0
    private var consoleChunksThisSession = 0
    /** #126 false-alarm guard: CONSECUTIVE console-only completed syncs, so the "clock has lost sync"
     *  banner only fires on sustained emptiness, not a single transient empty cycle on a healthy strap. */
    private val emptySyncTracker = EmptySyncTracker()
    /** Genuine offload frames seen this session — zero at timeout means the strap never answered
     *  the history request at all (5/MG retry trigger, #78 fork). Main-looper only. */
    private var offloadFramesThisSession = 0
    /** #174 deep-packet cooldown: wall time (ms) of the most recent offload frame OR HISTORY_COMPLETE.
     *  A type-0x2F arriving just after a backfill ends (backfilling already flipped false) is a TRAILING
     *  historical frame, not the live R22 stream, so it must not be counted as a "live deep packet".
     *  0 = no offload reference yet this session. Mirrors macOS BLEManager.lastOffloadFrameAt. */
    private var lastOffloadFrameAtMs = 0L
    /** One-shot per session: SEND_HISTORICAL_DATA already fired (gate + fail-open can both call). */
    private var historicalKickSent = false
    /** 5/MG zero-frame retries used this CONNECTION (max 2 — then the 900s periodic timer owns it). */
    private var whoop5HistoryAttempts = 0
    /** One-shot debounce: a post-backfill scoring pass is already scheduled/running. */
    private val analyzeAfterBackfillScheduled = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Guards the once-per-connect initial offload kick (Swift `backfillStarted`). */
    private var backfillStarted = false

    /** #364 auto-continue: consecutive immediate re-kicks after a 60s idle-cap OR HISTORY_COMPLETE exit on
     *  THIS connection. Bounded by [MAX_AUTO_CONTINUES] so a pathological strap can't pin the radio. Reset
     *  to 0 once [shouldAutoContinue] proves we're caught up (its else path, under the cap) and on
     *  disconnect — NOT unconditionally on every HISTORY_COMPLETE, so a strap that slices one offload into
     *  many completions can't reset the cap each slice (#25). Main-looper only. Mirrors Swift
     *  `consecutiveAutoContinues`. */
    private var consecutiveAutoContinues = 0

    /** #364 spin-detector: the trim cursor as of the END of the PREVIOUS backfill session this
     *  connection. [exitBackfilling] compares Backfiller.lastAckedTrim against this to decide whether the
     *  just-ended session advanced the strap's trim (progress) or froze (stop re-kicking). null until the
     *  first session ends; reset on disconnect. Mirrors Swift `lastSessionEndTrim`. */
    private var lastSessionEndTrim: Long? = null

    /** Newest unix the strap reports having (from GET_DATA_RANGE); refreshed each connect. */
    @Volatile
    private var strapNewestTs: Long? = null

    // --- Live-persistence buffer (port of Swift Collector: custom realtime/event/battery frames) ---

    /**
     * Live-persistence buffers, guarded by [collectorLock] (a plain monitor, NOT a coroutine Mutex,
     * because frames are appended synchronously from the single-threaded GATT callback thread and
     * only the suspend DB insert hops to [ioScope]). [batchStartedAtMs] tracks the flush interval.
     */
    private val collectorLock = Any()

    /** Buffered complete custom-channel frames awaiting a batched decode+insert. */
    private val liveBuffer = ArrayList<ByteArray>()
    private var batchStartedAtMs = System.currentTimeMillis()

    /** Standard 0x2A37 HR/RR buffer — the reliable, always-on stream (port of Collector.stdHR/stdRR). */
    private val stdHr = ArrayList<HrRow>()
    private val stdRr = ArrayList<RrRow>()

    // --- Offload frame drain (preserves START/data/END arrival order; port of routeBackfillFrame) ---

    /** Ordered queue of offload frames awaiting the serial Backfiller drain. */
    private val backfillFrameQueue = ConcurrentLinkedQueue<ByteArray>()

    @Volatile
    private var backfillDraining = false

    /** Periodic re-offload + idle-watchdog tokens (handler-posted; cancelled on disconnect). */
    private val periodicBackfillRunnable = Runnable { triggerPeriodicBackfill() }
    private val backfillTimeoutRunnable = Runnable { onBackfillTimeout() }

    /** Live-stream keep-alive (port of BLEManager.keepAliveTimer): re-arms realtime, polls battery,
     *  and bounces a stalled link. Handler-posted on every connect handshake; cancelled in reset(). */
    private val keepAliveRunnable = Runnable { keepAliveFire() }
    private var keepAliveTick = 0
    /** True while a Live/Health screen is on-screen and wants the realtime HR stream (ref-counted in
     *  [com.noop.ui.AppViewModel]). One of the two inputs to [wantsRealtime]. */
    @Volatile private var screenWantsRealtime = false
    /** True while the "Continuous HRV capture" preference wants the realtime stream held open even with
     *  no Live screen visible, so the strap banks dense beat-to-beat R-R 24/7 (better overnight
     *  HRV/recovery/sleep). The second input to [wantsRealtime]. Default off; set by
     *  [setKeepStreamForData]. Mirrors the Swift `keepRealtimeForData`. */
    @Volatile private var keepStreamForData = false
    /** Derived want: the realtime stream should be armed while EITHER a screen wants it OR the
     *  continuous-capture preference wants it. The keep-alive re-arms it so it can't lapse, and the
     *  post-bond branch arms it on connect. Recomputed only inside [reconcileRealtime]. */
    @Volatile private var wantsRealtime = false
    /** What we last told the strap (armed = TOGGLE_REALTIME_HR 1). Lets [reconcileRealtime] send the
     *  toggle only on the false↔true edge instead of on every input change. */
    @Volatile private var realtimeArmed = false
    /** Wall-clock of the last inbound notification — drives the keep-alive liveness watchdog. */
    @Volatile private var lastDataAtMs = 0L
    /** True once we've re-subscribed during the CURRENT quiet episode, so the keep-alive re-subscribes
     *  at most once between data arrivals instead of flooding descriptor writes every 30s tick (#77).
     *  Reset to false in [onInbound] when fresh data lands. */
    @Volatile private var resubscribedSinceData = false

    /**
     * Pending outbound writes. Android's GATT stack allows ONE in-flight write at a time:
     * a second writeCharacteristic before onCharacteristicWrite silently fails. The Swift app
     * leaned on CoreBluetooth's internal queue; here we serialise writes ourselves. Each queued
     * item is the fully-framed byte array + its write type (with/without response).
     */
    private data class PendingWrite(val frame: ByteArray, val withResponse: Boolean)
    private val writeQueue = ConcurrentLinkedQueue<PendingWrite>()
    private var writeInFlight = false
    /** A frame being retried after a transient BUSY rejection. Held here rather than re-added to the
     *  queue so it keeps its place AHEAD of later commands — command order matters (e.g. SET_CLOCK
     *  before GET_CLOCK). Only ever touched on the main looper inside [drainWriteQueue]. */
    private var pendingRetry: PendingWrite? = null
    private var writeRetries = 0

    /** The BUSY-retry kick for [drainWriteQueue], held as a NAMED runnable (not an inline lambda) so the
     *  teardown path can cancel a still-pending retry — otherwise a queued retry fires after the link is
     *  dead and re-enters the now-dead write, re-throwing `DeadObjectException` (#314). */
    private val drainWriteRetryRunnable = Runnable { drainWriteQueue() }

    /** Descriptor-write queue: enabling notifications is also a one-at-a-time GATT operation. */
    private val cccdQueue = ConcurrentLinkedQueue<BluetoothGattCharacteristic>()
    private var cccdInFlight = false
    /** Bounded retries for a transiently-BUSY CCCD write, so a single rejected subscribe doesn't
     *  permanently kill a stream (HR/battery/events). Reset per connection in [reset]. */
    private var cccdRetries = 0
    /** The BUSY-retry kick for [drainCccdQueue], a NAMED runnable so teardown can cancel a pending
     *  subscribe-retry that would otherwise re-enter a dead descriptor write (#314). It re-drains using
     *  the CURRENT [gatt]; if the link is already torn down ([gatt] is null) the drain is a no-op. */
    private val drainCccdRetryRunnable = Runnable { gatt?.let { drainCccdQueue(it) } }
    /** Set once startSession() has fired the first command, so it runs exactly once per connection. */
    private var sessionStarted = false

    // ====================================================================================
    // MARK: Public API  (port of BLEManager.connect / disconnect / send + buzz helper)
    // ====================================================================================

    /**
     * Begin scanning for the WHOOP custom service, then connect to the first match.
     * Port of `BLEManager.connect()` → `central.scanForPeripherals(withServices:[customService])`.
     */
    @SuppressLint("MissingPermission")
    fun connect(model: WhoopModel = WhoopModel.WHOOP4) {
        intentionalDisconnect = false
        selectedModel = model
        val adp = adapter
        // No Bluetooth LE hardware at all (most often an emulator / virtual device).
        if (adp == null || !context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            log("No Bluetooth LE on this device")
            _state.value = _state.value.copy(
                scanning = false,
                statusNote = "This device has no Bluetooth LE. NOOP has to run on a real phone with " +
                    "Bluetooth, near your strap. It can't connect from an emulator or virtual device.")
            return
        }
        if (!adp.isEnabled) {
            log("Bluetooth is off")
            _state.value = _state.value.copy(
                scanning = false, statusNote = "Bluetooth is off. Turn it on, then tap Connect.")
            return
        }
        val sc = scanner
        if (sc == null) {
            log("No BLE scanner available")
            _state.value = _state.value.copy(statusNote = "Bluetooth isn't ready yet. Try again in a moment.")
            return
        }
        if (scanning) {
            log("Scan already in progress — ignoring")
            return
        }
        // 5/MG fast path: a strap the OS already bonded connects DIRECTLY — no scan, no advertisement
        // needed. Real hardware showed scan-reconnects against an OS-bonded 5/MG failing their first
        // protected GATT operation (status=133), while the direct path reached a working puffin
        // session. Falls open to the normal scan when no bonded WHOOP is found; a stale bond falls
        // back to a scan via handleDisconnect. Never used for WHOOP 4. (#78 fork)
        if (model == WhoopModel.WHOOP5_MG) {
            val bonded = bondedWhoopDevice()
            if (bonded != null) {
                log("Connecting directly to OS-bonded ${bonded.name ?: "WHOOP"}")
                _state.value = _state.value.copy(
                    scanning = false, whoop5Detected = false,
                    statusNote = "Connecting to your bonded ${model.displayName}…",
                )
                connectToDevice(bonded)
                bondedDirectAttempt = true   // after connectToDevice: reset() must not clear it
                return
            }
        }
        startScan(model, allowFallback = true)
    }

    /**
     * Start a service-filtered scan for [model], re-framing for its family so a fallback rotation
     * decodes the strap it actually finds. When [allowFallback] is true, schedule a one-shot rotation
     * to the other WHOOP family after [SCAN_FALLBACK_DELAY_MS] of no discovery — recovers reconnect
     * when the persisted preference is stale after an update/restore. Discovery/connect cancels both
     * the fallback and the not-found timeout. Port of macOS BLEManager.startScan(for:allowFallback:).
     */
    @SuppressLint("MissingPermission")
    private fun startScan(model: WhoopModel, allowFallback: Boolean) {
        handler.removeCallbacks(scanFallbackRunnable)
        // Defensive: the normal auto-connect scan is NEVER a present-scan. Clearing the flag here means a
        // leaked wizard present-scan (e.g. the wizard was dismissed without stopWhoopScan) can't divert
        // this connect's onScanResult into accumulate-not-connect. No-op on the (default) single-WHOOP path.
        scanningForList = false
        selectedModel = model
        val sc = scanner ?: run {
            log("No BLE scanner available")
            _state.value = _state.value.copy(scanning = false, statusNote = "Bluetooth isn't ready yet. Try again in a moment.")
            return
        }
        // Filter to the strap we're targeting — a single service, so a WHOOP 4.0
        // scan never lingers on a WHOOP 5/MG wrist (or the reverse).
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(model.service)).build(),
        )
        // LOW_LATENCY for a snappy first connect, mirroring the desktop app's eager scan.
        // We do NOT allow duplicates (CBCentralManagerScanOptionAllowDuplicatesKey: false).
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        log("Scanning for ${model.displayName}…")
        scanning = true
        _state.value = _state.value.copy(scanning = true, whoop5Detected = false, statusNote = "Searching for your ${model.displayName}…")
        try {
            sc.startScan(filters, settings, scanCallback)
        } catch (se: SecurityException) {
            // Android 12+: BLUETOOTH_SCAN/CONNECT not granted. This is the #1 reason connect fails.
            scanning = false
            log("Scan blocked (permission): ${se.message}")
            _state.value = _state.value.copy(
                scanning = false,
                statusNote = "NOOP needs the Nearby devices / Bluetooth permission. Allow it in " +
                    "Settings → Apps → NOOP → Permissions, then tap Connect.")
            return
        } catch (t: Throwable) {
            scanning = false
            log("Scan failed to start: ${t.message}")
            _state.value = _state.value.copy(scanning = false, statusNote = "Couldn't start scanning: ${t.message}")
            return
        }
        // Stop and explain if nothing turns up in time.
        handler.removeCallbacks(scanTimeoutRunnable)
        handler.postDelayed(scanTimeoutRunnable, SCAN_TIMEOUT_MS)
        // Before the hard timeout, try the other family once in case the family preference is stale.
        if (allowFallback) {
            handler.postDelayed(scanFallbackRunnable, SCAN_FALLBACK_DELAY_MS)
        }
    }

    /**
     * Intentionally tear down the link and stop scanning.
     * Port of `BLEManager.disconnect()` (sets intentionalDisconnect, cancels the connection).
     */
    @SuppressLint("MissingPermission")
    fun disconnect() {
        intentionalDisconnect = true
        handler.removeCallbacks(scanTimeoutRunnable)
        stopScan()
        _state.value = _state.value.copy(scanning = false, statusNote = null)
        // disconnect() can throw on a dead binder (radio off, #314). If it does, the OS won't deliver
        // onConnectionStateChange(DISCONNECTED), so tear down directly instead of crashing.
        try {
            gatt?.disconnect()   // onConnectionStateChange(DISCONNECTED) does the teardown + close.
        } catch (t: Throwable) {
            log("gatt.disconnect() threw ${t.javaClass.simpleName}; tearing down directly")
            teardownAfterGattFailure()
        }
    }

    /**
     * The OS Bluetooth radio was turned OFF (or is turning off). #314: turning Bluetooth off does NOT
     * deliver onConnectionStateChange(DISCONNECTED) for our GATT, so the orphaned link lingered —
     * gatt/cmdCharacteristic stayed non-null, state.connected stayed true, and the UI kept showing live
     * HR/buzz/sync that wasn't real (and the next write crashed on a dead binder). Called from
     * [WhoopConnectionService]'s ACTION_STATE_CHANGED receiver. Runs the FULL teardown synchronously on
     * the main looper so the UI flips to disconnected immediately. Idempotent — a no-op if already down.
     *
     * NOTE: the auto-reconnect that [teardownAfterGattFailure] suppresses (it sets intentionalDisconnect)
     * is exactly what we want here too: the [connect] adapter.isEnabled gate would reject a reconnect
     * while the radio is off anyway, and [onBluetoothRadioOn] re-arms the connect when it comes back.
     */
    fun onBluetoothRadioOff() {
        handler.post {
            if (gatt == null && !_state.value.connected) {
                log("Bluetooth radio off — already disconnected")
                return@post
            }
            log("Bluetooth radio turned off — tearing down the orphaned link (#314)")
            teardownAfterGattFailure()
            // teardownAfterGattFailure → handleDisconnect already publishes connected=false; make the
            // "off" reason explicit for the UI so it reads "Bluetooth is off" rather than "Reconnecting…".
            _state.value = _state.value.copy(
                connected = false, scanning = false,
                statusNote = "Bluetooth is off. Turn it on to reconnect.",
            )
        }
    }

    /**
     * The OS Bluetooth radio came back ON. Resume the connection the user last had: reconnect directly
     * to the remembered strap if we have one, else re-scan for the selected family. The connect path's
     * own adapter.isEnabled gate is now satisfied. Called from the ACTION_STATE_CHANGED receiver.
     */
    fun onBluetoothRadioOn() {
        handler.post {
            if (gatt != null || _state.value.connected) return@post   // already (re)connected
            val dev = lastDevice
            // Multi-WHOOP: only fast-path reconnect to [lastDevice] when it's still the pinned strap; an
            // un-pinned (or differently-pinned) last device falls through to the pin-aware rescan, mirroring
            // macOS re-asserting the pin on every reconnect. Single-WHOOP: preferredAddress null → always
            // preferred → unchanged.
            if (dev != null && isPreferred(dev)) {
                log("Bluetooth radio back on — reconnecting directly to the last strap")
                intentionalDisconnect = false
                connectToDevice(dev, autoConnect = true)
            } else {
                log("Bluetooth radio back on — rescanning for your ${selectedModel.displayName}")
                connect(selectedModel)
            }
        }
    }

    /**
     * Switch which strap we'll connect to next: drop the current strap and clear the **sticky** bond
     * state so a newly-picked model bonds fresh. Without this, `bonded` stayed true from the first strap,
     * which hid the strap picker and kept the scan pointed at the old family's service — so a user with
     * both a WHOOP 4 and a 5/MG couldn't switch between them. Mirrors macOS BLEManager.prepareForModelSwitch.
     */
    fun prepareForModelSwitch() {
        disconnect()
        lastDevice = null   // don't auto-reconnect to the old strap; the next connect scans for the new model
        _state.value = _state.value.copy(connected = false, bonded = false, encryptedBond = false,
                                         r22FlagsAccepted = 0, deepPacketsThisSession = 0)   // #174 reset per session
    }

    /**
     * Re-point which device id live WHOOP samples store under, when the active WHOOP changes (a
     * WHOOP↔WHOOP switch via the registry). Only the [SourceCoordinator] calls this, and only when a
     * DIFFERENT registered WHOOP becomes active — the single-WHOOP path leaves the seeded "my-whoop" id in
     * place (NoopApplication set it at construction; this is never called), so that path is byte-for-byte
     * unchanged. Sets this client's [deviceId] AND re-points the in-flight [Backfiller] so the very next
     * live flush / standard-HR persist / historical finishChunk attributes new samples to the new id —
     * without waiting for a relaunch. The live persist sites + analyze read [deviceId] directly; the
     * Backfiller captured its own copy at construction, so both are updated here. Port of macOS
     * `BLEManager.setActiveDeviceId`. Empty id is ignored.
     */
    fun setActiveDeviceId(id: String) {
        if (id.isEmpty()) return
        deviceId = id
        backfiller.deviceId = id
    }

    /**
     * Add-a-device wizard present-scan (MW-4): scan the given WHOOP family's service and surface every
     * nearby strap in [discoveredWhoops] WITHOUT auto-connecting. Turns on [scanningForList] so
     * [onScanResult] accumulates rather than connecting, and clears the list for a fresh presentation. It
     * does NOT disturb an existing connection (it never touches [gatt]/bond state) — but it does take over
     * the single LE scanner, so the wizard MUST call [stopWhoopScan] before any normal connect resumes.
     * Respects the runtime BLUETOOTH_SCAN/CONNECT grant exactly like [startScan]. Port of macOS
     * `BLEManager.scanForWhoops`.
     */
    @SuppressLint("MissingPermission")
    fun scanForWhoops(model: WhoopModel) {
        val adp = adapter
        if (adp == null || !adp.isEnabled) {
            log("Add-a-WHOOP scan: Bluetooth not ready")
            return
        }
        val sc = scanner
        if (sc == null) {
            log("Add-a-WHOOP scan: no BLE scanner available")
            return
        }
        // Cancel the auto-connect scan's not-found/fallback timers — neither should fire during a
        // present-scan — and stop whatever LE scan is running before re-arming our own.
        handler.removeCallbacks(scanTimeoutRunnable)
        handler.removeCallbacks(scanFallbackRunnable)
        stopScan()
        selectedModel = model
        scanningForList = true
        _discoveredWhoops.value = emptyList()   // fresh list each time the wizard opens the scan
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(ParcelUuid(model.service)).build(),
        )
        // LOW_LATENCY for a snappy wizard; the in-callback accumulation refreshes RSSI as straps move.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanning = true
        try {
            sc.startScan(filters, settings, scanCallback)
            log("Add-a-WHOOP scan: presenting nearby ${model.displayName} straps")
        } catch (se: SecurityException) {
            scanning = false
            scanningForList = false
            log("Add-a-WHOOP scan blocked (permission): ${se.message}")
        } catch (t: Throwable) {
            scanning = false
            scanningForList = false
            log("Add-a-WHOOP scan failed to start: ${t.message}")
        }
    }

    /**
     * End the Add-a-device present-scan: stop scanning and clear [scanningForList] so [onScanResult]
     * returns to its normal auto-connect behaviour. Idempotent — safe to call when not presenting. Port of
     * macOS `BLEManager.stopWhoopScan`.
     */
    @SuppressLint("MissingPermission")
    fun stopWhoopScan() {
        if (!scanningForList) return
        scanningForList = false
        stopScan()
        log("Add-a-WHOOP scan: stopped")
    }

    /**
     * Reconnect DIRECTLY to a previously-bonded strap by its address — no scan — for auto-reconnect on
     * app launch (#67). No-op if already connecting/connected, the address can't be resolved, or the
     * runtime Bluetooth permission isn't granted yet (the user will connect manually / next launch).
     * Uses connectGatt(autoConnect=true) so the OS connects as soon as the strap is reachable.
     */
    @SuppressLint("MissingPermission")
    fun reconnectToAddress(address: String, model: WhoopModel) {
        if (gatt != null || _state.value.connected) return
        val adp = adapter ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val device = runCatching { adp.getRemoteDevice(address) }.getOrNull() ?: return
        selectedModel = model
        intentionalDisconnect = false
        log("Auto-reconnecting to your saved ${model.displayName}…")
        connectToDevice(device, autoConnect = true)
    }

    /**
     * Send a command to the strap.
     * Port of `BLEManager.send(_:payload:writeType:)` — builds the framed COMMAND packet via
     * [Framing.buildCommand] and writes it to the command characteristic (61080002).
     *
     * Default write type is WITHOUT response (matching the Swift default), so existing call sites
     * (toggleRealtimeHR, getBatteryLevel, runHapticsPattern) are link-cheap. The bond write and any
     * acked command use WITH response.
     */
    fun send(cmd: CommandNumber, payload: ByteArray = byteArrayOf(0), withResponse: Boolean = false) {
        val ch = cmdCharacteristic
        if (gatt == null || ch == null) {
            log("send(${cmd.name}) ignored — not connected")
            return
        }
        // WHOOP 5.0/MG uses puffin (CRC16) command framing, not the WHOOP4 frame. The realtime-HR toggle
        // is hardware-confirmed (issue #17 — a 5/MG owner saw live HR on v1.13), which proves the strap
        // acts on puffin-framed commands. We now also send haptics (buzz) on that same proven transport —
        // experimental: the strap may or may not honor that specific command, but it's no longer a blind
        // guess. Everything else stays dropped (offload commands need the held work). WHOOP 4.0 unaffected.
        if (connectedFamily == DeviceFamily.WHOOP5) {
            // 5/MG allow-list: live HR, buzz, and the historical-offload pair (trigger + ack). The
            // offload commands ride the SAME proven puffin COMMAND frame as the Swift path
            // (whoop5HistoricalAckFrame = puffinCommandFrame(23, [0x01]+endData)). (#78)
            if (cmd != CommandNumber.TOGGLE_REALTIME_HR && cmd != CommandNumber.RUN_HAPTICS_PATTERN &&
                cmd != CommandNumber.SEND_HISTORICAL_DATA && cmd != CommandNumber.HISTORICAL_DATA_RESULT &&
                cmd != CommandNumber.SET_CLOCK && cmd != CommandNumber.GET_CLOCK &&
                cmd != CommandNumber.GET_DATA_RANGE &&
                cmd != CommandNumber.SET_ALARM_TIME && cmd != CommandNumber.DISABLE_ALARM &&
                // SET_CONFIG (the R22 deep-stream unlock) is allowed ONLY while the deep-data experiment
                // is opted in — it writes a persistent feature flag to the strap, so it must never fire
                // on a default install. Reversible; driven only by enableWhoop5DeepData(). (#174)
                !(cmd == CommandNumber.SET_CONFIG && puffinExperiment.isDeepDataEnabled) &&
                // SET_DEVICE_CONFIG (the Broadcast-HR flag) is allowed ONLY while that opt-in is on.
                // Reversible; driven only by setBroadcastHr(). (#181)
                !(cmd == CommandNumber.SET_DEVICE_CONFIG && puffinExperiment.broadcastHr)) {
                log("send(${cmd.name}) skipped — no WHOOP 5/MG framing for this command yet")
                return
            }
            // WHOOP 5/MG haptics differ from WHOOP 4.0 on BOTH the opcode AND the payload (#48, decoded
            // from the working "maverick" app's binary). Opcode: 0x13, not RUN_HAPTICS_PATTERN=79 (a real-MG
            // capture showed the strap rejecting 79 with COMMAND_RESPONSE result=0x03). Payload: the maverick
            // haptic body [0x01, effects(8), loopControl(u16 LE), overallLoop] — here the "notify" preset
            // (effects 47,152), NOT the 4.0 [patternId, loops, …]. puffinCommandFrame pads the inner to a
            // 4-byte boundary, which this 12-byte payload needs. WHOOP 4.0 is untouched (79 + its own frame).
            val isHaptics = cmd == CommandNumber.RUN_HAPTICS_PATTERN
            val puffinCmd = if (isHaptics) 0x13 else cmd.rawValue
            val puffinPayload = if (isHaptics)
                byteArrayOf(0x01, 47, 152.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0) else payload
            seq = (seq + 1) and 0xFF
            val frame = Framing.puffinCommandFrame(cmd = puffinCmd, seq = seq, payload = puffinPayload)
            enqueueWrite(PendingWrite(frame, withResponse))
            val cmdNote = if (isHaptics) " cmd=0x13" else ""
            log("→ ${cmd.name} payload=${puffinPayload.toHex()} (puffin$cmdNote)")
            return
        }
        seq = (seq + 1) and 0xFF
        val frame = Framing.buildCommand(cmd, payload, seq)
        enqueueWrite(PendingWrite(frame, withResponse))
        log("→ ${cmd.name} payload=${payload.toHex()}")
    }

    /**
     * Fire a preset haptic buzz on the strap.
     * Port of `BLEManager.testAlarmBuzz()` / the contract's `buzz(loops:)`:
     * RUN_HAPTICS_PATTERN(79) with payload `[patternId=2, loops, 0, 0, 0]`.
     * patternId=2 is the graduated alarm buzz the official WHOOP app uses.
     */
    fun buzz(loops: Int = 2) {
        val n = loops.coerceIn(0, 255)
        send(CommandNumber.RUN_HAPTICS_PATTERN, byteArrayOf(2, n.toByte(), 0, 0, 0))
        log("Buzz: patternId=2 loops=$n")
    }

    /**
     * Haptic Clock (#460): buzz the current wall-clock time out on the strap so the user can read it
     * off their wrist without a screen. The pure, unit-tested [HapticClock] encoder turns now into an
     * ordered pulse list (long = a "ten", short = a "unit", in HH-tens / HH-units / MM-tens / MM-units
     * order); we then schedule each pulse with [handler].postDelayed, firing the EXISTING maverick
     * notification buzz ([buzz] → RUN_HAPTICS_PATTERN, remapped to cmd-0x13 on a 5/MG) at each pulse's
     * start. Only the SCHEDULE is new — the buzz itself is the hardware-confirmed one.
     *
     * [is24h] controls 12- vs 24-hour reading; a Settings toggle should supply it (default 12h). Public
     * so a Settings button can trigger it. Long-press / double-tap strap input is hardware-dependent and
     * not wired (no tap event is parsed yet — see the macOS hardwareUnverifiable note).
     *
     * Each WHOOP notification buzz is a fixed-length motor pulse, so we can't vary the on-time per pulse
     * from the app; instead a LONG pulse fires two stacked loops and a SHORT pulse one, which the wrist
     * feels as "longer vs shorter". Pulse-feel timing can only be confirmed on a real strap motor.
     */
    fun buzzTimeNow(is24h: Boolean = false, nowMs: Long = System.currentTimeMillis()) {
        val cal = java.util.Calendar.getInstance().apply { timeInMillis = nowMs }
        val hour = cal.get(java.util.Calendar.HOUR_OF_DAY)
        val minute = cal.get(java.util.Calendar.MINUTE)
        val pulses = HapticClock.pulses(hour, minute, is24h)
        if (pulses.isEmpty()) {
            log("Haptic Clock: nothing to buzz (00:00 in 24h form).")
            return
        }
        log("Haptic Clock: buzzing ${pulses.size} pulses for the current time (${if (is24h) "24h" else "12h"}).")
        // Walk the encoder's pulse list, converting each (durationMs,gapMs) into a scheduled buzz.
        // A long pulse is felt as a heavier buzz (2 stacked loops); a short pulse as a light one (1).
        var offsetMs = 0L
        for (pulse in pulses) {
            val loops = if (pulse.isLong) 2 else 1
            handler.postDelayed({ buzz(loops) }, offsetMs)
            offsetMs += (pulse.durationMs + pulse.gapMs).toLong()
        }
    }

    /**
     * Inactivity reminder (#419): on each natural offload completion, run the shipped, unit-tested
     * [SedentaryDetector] over the freshly-arrived gravity window and buzz the wrist if the user has
     * been seated too long. NO offload-timer change — a read-only hook on an event that already happens,
     * so the nudge lags the stillness by the offload cadence (~7-15 min). Best-effort.
     *
     * All gating + de-dup lives in the engine: we only supply honest inputs (recent gravity, the live
     * worn flag, the prefs→[SedentaryConfig]/[SedentaryState]) and persist the engine's `nextState`. The
     * engine acts only when this offload advanced the newest gravity ts (a replayed / no-new-rows sync
     * can't re-buzz), only for a bout whose end is still current, only through its mayBuzz gate (master /
     * quiet hours / worn / active-hours-by-bout-end-time), and either re-nudges a continuing bout on the
     * user's cadence or alerts a distinct new bout separated by movement.
     */
    private fun maybeBuzzInactivity() {
        if (!InactivityPrefs.enabled(context)) return
        ioScope.launch {
            try {
                val nowSec = System.currentTimeMillis() / 1000L
                val from = nowSec - INACTIVITY_LOOKBACK_S
                val grav = repository.gravitySamples(deviceId, from, nowSec)
                if (grav.isEmpty()) return@launch

                val decision = SedentaryDetector.evaluate(
                    gravity = grav,
                    state = InactivityPrefs.state(context),
                    config = InactivityPrefs.config(context),
                    worn = _state.value.worn,
                    nowSec = nowSec,
                    tzOffsetSec = InactivityPrefs.tzOffsetSec(nowSec),
                )
                // Persist the advanced de-dup state every run (the engine always advances
                // lastProcessedGravityTs when a window arrived), so a replayed window can't re-buzz.
                InactivityPrefs.saveState(context, decision.nextState)

                if (decision.shouldBuzz) {
                    handler.post { buzz(decision.buzzLoops) }
                    val mins = ((decision.bout?.durationS ?: 0.0) / 60).toInt()
                    log("Inactivity: nudged after a $mins-min sedentary stretch.")
                }
            } catch (t: Throwable) {
                log("Inactivity: check failed (${t.message})")
            }
        }
    }

    /**
     * L3 closed-loop stress check-in (v5 haptic-biofeedback). On the same natural offload completion that
     * drives [maybeBuzzInactivity], run the shipped, unit-tested [StressOnsetDetector] over the live R-R
     * buffer: a FRESH, non-metabolic HRV dip while still fires a single confirming buzz + a passive in-app
     * card via [StressNudgeCenter.present]. NEVER a push, NEVER a diagnosis — "stress" is an autonomic
     * proxy vs the user's OWN baseline. All gating + de-dup is in the engine; we only supply honest inputs
     * (the rolling R-R, the live HR, recent motion, the worn flag) and persist the engine's [nextState] so
     * a replayed window can't re-fire. Master/sub toggles + quiet hours come from [BiofeedbackPrefs].
     *
     * See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
     */
    private fun maybeNudgeStress() {
        val config = BiofeedbackPrefs.stressConfig(context)
        // Cheap master gate before any DB work — inert when the feature/auto-nudge is off.
        if (!config.enabled || !config.autoNudge) return
        ioScope.launch {
            try {
                val nowSec = System.currentTimeMillis() / 1000L
                // Recent wrist-motion (g): the smoothed activity intensity over the freshly-arrived
                // gravity window, the same primitive SedentaryDetector reuses. Null when there's no
                // recent gravity — the engine then leans on the resting-HR band gate (spec Q3).
                val from = nowSec - INACTIVITY_LOOKBACK_S
                val grav = runCatching { repository.gravitySamples(deviceId, from, nowSec) }.getOrDefault(emptyList())
                val recentMotionG = WorkoutDetector.activitySeries(grav).lastOrNull()?.intensity

                val live = _state.value
                val decision = StressOnsetDetector.evaluate(
                    rrBuffer = live.rrRecent,
                    currentHR = live.heartRate?.toDouble(),
                    recentMotionG = recentMotionG,
                    // We never offer the cue over a manual Breathe/L1/L2 session; the BLE layer doesn't
                    // track that, so leave it false — the in-app card is also suppressed by its own UI.
                    sessionActive = false,
                    state = BiofeedbackPrefs.loadStressState(context),
                    config = config,
                    nowSec = nowSec,
                    tzOffsetSec = InactivityPrefs.tzOffsetSec(nowSec),
                )
                // Persist the advanced de-dup/EMA state every run so a replayed window can't re-fire.
                BiofeedbackPrefs.saveStressState(context, decision.nextState)

                if (decision.shouldNudge) {
                    handler.post { buzz(decision.buzzLoops) }
                    StressNudgeCenter.present(
                        fastRMSSD = decision.fastRMSSD,
                        baselineRMSSD = decision.baselineRMSSD,
                    )
                    log("Stress check-in: nudged on a fresh non-metabolic HRV dip.")
                }
            } catch (t: Throwable) {
                log("Stress check-in: check failed (${t.message})")
            }
        }
    }

    /**
     * Rename the WHOOP 4.0's BLE advertising name (the name the OS shows in Bluetooth) via
     * SET_ADVERTISING_NAME (cmd 77). Payload `[0x00,0x00] + UTF-8 name + [0x00]`, clamped to 24 UTF-8
     * bytes so it can't overflow the advertising packet; the strap reboots to apply, so the new name
     * appears on the next connect (the OS re-reads it). WHOOP 4.0 only — a 5/MG uses puffin framing and
     * a different device-config path. Requires a bonded link. Result via [LiveState.renameStatus].
     * Port of macOS BLEManager.renameStrap. Reversible: rename again any time.
     */
    fun renameStrap(rawName: String) {
        val name = rawName.trim()
        if (connectedFamily != DeviceFamily.WHOOP4) {
            _state.value = _state.value.copy(renameStatus = "Renaming is WHOOP 4.0 only.")
            log("Strap rename: WHOOP 4.0 only — ignored.")
            return
        }
        if (!_state.value.connected || !_state.value.bonded) {
            _state.value = _state.value.copy(renameStatus = "Connect and pair your strap first.")
            return
        }
        if (name.isEmpty()) {
            _state.value = _state.value.copy(renameStatus = "Enter a name first.")
            return
        }
        // Clamp to 24 UTF-8 bytes on a whole-character boundary (never split a multibyte char), leaving
        // room for the rest of the BLE advertising structure. Mirrors WhoopCommand.advertisingNamePayload.
        var clamped = name
        while (clamped.toByteArray(Charsets.UTF_8).size > 24) clamped = clamped.dropLast(1)
        val payload = byteArrayOf(0, 0) + clamped.toByteArray(Charsets.UTF_8) + byteArrayOf(0)
        send(CommandNumber.SET_ADVERTISING_NAME, payload, withResponse = true)
        log("Strap rename: wrote advertising name=$clamped")
        _state.value = _state.value.copy(
            renameStatus = "Sent — your strap will reboot to apply, then reconnect with the new name.",
        )
    }

    /**
     * Refresh the battery reading on demand ("Refresh battery", screen entry).
     *
     * Source is FAMILY-SPECIFIC (#77): on a WHOOP 4.0 the standard 0x2A19 characteristic is a STUB that
     * reports a constant 100, while the real charge only comes from the proprietary GET_BATTERY_LEVEL
     * command (COMMAND_RESPONSE, u16/10) — reading both flashed 100% before the true value corrected it.
     * So WHOOP 4 uses ONLY the command; WHOOP 5/MG uses ONLY 0x2A19 (its proprietary command isn't framed
     * — see send()). Mirrors macOS BLEManager.refreshBattery().
     */
    fun refreshBattery() {
        val g = gatt
        if (g == null) {
            log("refreshBattery ignored — not connected")
            return
        }
        if (connectedFamily == DeviceFamily.WHOOP4) {
            send(CommandNumber.GET_BATTERY_LEVEL)
            return
        }
        val ops = gattOps ?: return
        val batt = g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)
        if (batt != null && (batt.properties and BluetoothGattCharacteristic.PROPERTY_READ) != 0) {
            // safeGatt: a dead binder here (radio off mid-link, #314) tears down instead of crashing.
            safeGatt("readCharacteristic(battery)") { ops.readCharacteristicCompat(batt) }
            log("Reading standard Battery Level (0x2A19)")
        } else {
            log("Battery Level read unavailable; relying on notifications")
        }
    }

    /**
     * Arm the strap's **firmware** alarm to buzz at [epochSec] (absolute UTC seconds). The strap fires
     * at that instant even if the phone is asleep or NOOP is closed. SET_CLOCK is sent first so the
     * strap's RTC is UTC-correct (a wrong RTC fires the alarm at the wrong wall-clock time). Payload =
     * `[0x01] + u32 LE epoch + [0x00, 0x00]`. Port of macOS `BLEManager.armStrapAlarm`. WHOOP 4.0; on
     * 5/MG `send()` drops it (the 5/MG command set isn't verified for this yet).
     */
    fun armStrapAlarm(epochSec: Long) {
        if (connectedFamily == DeviceFamily.WHOOP5) {
            // 5/MG SET_ALARM_TIME is REVISION_4 (the strap arms its own RTC alarm + fires the wake
            // haptic itself). EXPERIMENTAL/UNCONFIRMED on our side — gated behind the Experimental
            // probes opt-in so a normal user can't rely on an alarm that might silently not fire.
            // The strap maintains its RTC from the connect handshake / history sync, so no SET_CLOCK
            // here. (PR #85, AlarmPayload)
            if (!PuffinExperiment.from(context).isEnabled) {
                log("Alarm: 5/MG firmware alarm needs the Experimental toggle (unconfirmed) — not armed")
                return
            }
            send(CommandNumber.SET_ALARM_TIME, AlarmPayload.build(epochSec * 1000L))
            log("Alarm: armed 5/MG rev4 EXPERIMENTAL (epoch $epochSec)")
            return
        }
        sendSetClockBothForms()
        val e = epochSec.toInt()
        val payload = byteArrayOf(
            0x01,
            (e and 0xFF).toByte(),
            ((e shr 8) and 0xFF).toByte(),
            ((e shr 16) and 0xFF).toByte(),
            ((e shr 24) and 0xFF).toByte(),
            0x00, 0x00,
        )
        send(CommandNumber.SET_ALARM_TIME, payload)
        log("Alarm: armed (epoch $epochSec)")
    }

    /** Clear the strap's firmware alarm. Port of macOS `BLEManager.disableStrapAlarm`. */
    fun disableStrapAlarm() {
        if (connectedFamily == DeviceFamily.WHOOP5) {
            // 5/MG DISABLE_ALARM is REVISION_2 [0x02, 0xFF]. Sent unconditionally (clearing is safe
            // even if arming was gated off — a no-op on a strap with no alarm set). (PR #85)
            send(CommandNumber.DISABLE_ALARM, AlarmPayload.disableRev2())
            log("Alarm: disarmed (5/MG rev2)")
            return
        }
        send(CommandNumber.DISABLE_ALARM, byteArrayOf(0x01))
        log("Alarm: disarmed")
    }

    // ====================================================================================
    // MARK: Scanning
    // ====================================================================================

    /** Persist the WHOOP family that actually advertised so a later launch/scan starts on the right
     *  service — what makes a one-time fallback rotation stick. Mirrors macOS
     *  `UserDefaults.set(rawValue, forKey: "selectedWhoopModel")`. Self-contained in the shared
     *  noop_prefs store; failures are non-fatal (the rotation still worked this session). (PR#195) */
    private fun persistSelectedModel(model: WhoopModel) {
        try {
            context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
                .edit().putString("noop.selectedWhoopModel", model.name).apply()
        } catch (t: Throwable) {
            log("Couldn't persist selected model: ${t.message}")
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        handler.removeCallbacks(scanFallbackRunnable)
        if (!scanning) return
        scanning = false
        try {
            scanner?.stopScan(scanCallback)
        } catch (t: Throwable) {
            // Adapter may have been turned off underneath us; nothing to clean up.
            log("stopScan threw: ${t.message}")
        }
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device: BluetoothDevice = result.device
            val name = result.scanRecord?.deviceName ?: device.name ?: "unknown"
            // Multi-WHOOP present-scan (Add-a-device wizard, MW-4): accumulate the strap, do NOT
            // auto-connect, and return before touching the connect flow. Only reachable when the wizard
            // turned on [scanningForList] via scanForWhoops(); on the default path this branch is skipped
            // entirely and the auto-connect code below runs exactly as before.
            if (scanningForList) {
                val addr = device.address ?: return
                val list = _discoveredWhoops.value.toMutableList()
                val item = DiscoveredWhoop(address = addr, name = name.takeIf { it != "unknown" }, rssi = result.rssi)
                val i = list.indexOfFirst { it.address == addr }
                if (i >= 0) list[i] = item else list.add(item)   // refresh RSSI / append
                _discoveredWhoops.value = list
                return
            }
            // Multi-WHOOP preferred-peripheral filter (MW-2): when the app has pinned a specific strap,
            // ignore any OTHER discovered WHOOP and keep scanning. When [preferredAddress] is null (the
            // single-WHOOP default) this guard is skipped and the original "connect to the first
            // discovered" path below is byte-for-byte unchanged.
            val preferred = preferredAddress
            if (preferred != null && !device.address.equals(preferred, ignoreCase = true)) {
                log("Discovered $name (${device.address}) — not the preferred strap; ignoring")
                return
            }
            log("Discovered $name (rssi ${result.rssi}) — connecting")
            // Found it: cancel the not-found timeout AND the family-rotation fallback, then reflect
            // progress in the UI. (PR#195)
            handler.removeCallbacks(scanTimeoutRunnable)
            handler.removeCallbacks(scanFallbackRunnable)
            // Persist the family that actually advertised so the next scan starts on the right service —
            // this is what makes a one-time rotation stick after a stale-preference reconnect. (PR#195)
            persistSelectedModel(selectedModel)
            _state.value = _state.value.copy(statusNote = "Found $name, connecting…")
            // Port of didDiscover: stop scanning, then connect to this peripheral.
            stopScan()
            connectToDevice(device)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            log("Scan failed: $errorCode")
        }
    }

    /** The OS-bonded 5/MG-family strap, if any (name "WHOOP …" but not "WHOOP 4…" — MG-named units
     *  match too). Fails open to a scan on any lookup problem. (#78 fork) */
    @SuppressLint("MissingPermission")
    private fun bondedWhoopDevice(): BluetoothDevice? = try {
        val bonded = adapter?.bondedDevices?.filter { d ->
            val n = try { d.name } catch (se: SecurityException) { null } ?: return@filter false
            n.startsWith("WHOOP", ignoreCase = true) && !n.startsWith("WHOOP 4", ignoreCase = true)
        }.orEmpty()
        // With a multi-WHOOP pin set, take ONLY the pinned strap — never just "the first bonded 5/MG".
        // Grabbing the first ignored the active-device selection and kept the link on the wrong strap (the
        // 5/MG twin of the Mac/iOS attach-to-any-open-connection bug). No pin (single-WHOOP) → first, unchanged.
        val preferred = preferredAddress
        if (preferred != null) bonded.firstOrNull { it.address.equals(preferred, ignoreCase = true) }
        else bonded.firstOrNull()
    } catch (se: SecurityException) {
        null
    }

    /** True while a bonded-device fast-path connect is in flight and no session has been reached —
     *  deliberately NOT in reset() (it must survive into handleDisconnect's stale-bond fallback). */
    private var bondedDirectAttempt = false

    /** Consecutive OS-bonded direct-connect attempts that died before reaching a real bond. Two in a
     *  row = the strap genuinely wiped its pairing (firmware reset / official WHOOP app re-bond), not a
     *  one-off transient drop — gates the in-app reconnect guide so a single flaky disconnect doesn't
     *  nag the user. Reset to 0 on any genuine bond. (5/MG firmware reset parity, 2026-06) */
    private var staleDirectFailures = 0

    /** Guards the once-per-connect service-discovery kick. Discovery is deferred behind an MTU request
     *  (and a fallback timeout), so this ensures it fires EXACTLY once whichever path wins. AtomicBoolean
     *  (not @Volatile): on API 26/27 the GATT callbacks land on binder-pool threads, so onMtuChanged and
     *  the fallback can race — compareAndSet makes the once-only claim atomic. (PR #85) */
    private val serviceDiscoveryKicked = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Start service discovery exactly once per connection, whichever path (onMtuChanged or the
     *  fallback timeout) reaches here first. Idempotent via [serviceDiscoveryKicked]. */
    @SuppressLint("MissingPermission")
    private fun kickServiceDiscovery(g: BluetoothGatt, reason: String) {
        if (!serviceDiscoveryKicked.compareAndSet(false, true)) return
        val ops = gattOps ?: return
        log("Discovering services ($reason)")
        // safeGatt: discovery on a dead binder (radio off, #314) tears down rather than crashing.
        safeGatt("discoverServices") { ops.discoverServicesCompat() }
    }

    @SuppressLint("MissingPermission")
    private fun connectToDevice(device: BluetoothDevice, autoConnect: Boolean = false) {
        // Reset per-connection state (mirrors the Swift flags cleared on connect/disconnect).
        reset()
        // Remember the device so a later dropout can reconnect straight to it (#61).
        lastDevice = device
        // Close any prior/pending GATT so a direct-reconnect attempt doesn't leak the old client.
        // close() can throw on a dead binder (#314); swallow it — we're replacing the handle anyway.
        try { gatt?.close() } catch (t: Throwable) { log("prior gatt.close() threw ${t.javaClass.simpleName} (ignored)") }
        // autoConnect=false → a fast, direct connect (CoreBluetooth central.connect default), used for
        // the scan-discovered first connect. autoConnect=true → the OS reconnects whenever the bonded
        // strap is reachable WITHOUT needing an advertisement (used by the dropout auto-reconnect, #61).
        // TRANSPORT_LE pins the connection to BLE on dual-mode devices.
        gatt = when {
            // Pin EVERY GATT callback to the main looper. Without a handler, Android delivers
            // callbacks on arbitrary binder-pool threads: onServicesDiscovered then races a
            // concurrent callback, the CCCD queue gets drained to empty, and the bond's
            // with-response write fires BEFORE the notification subscriptions. The bond then
            // holds the stack's single GATT slot, so every writeDescriptor is rejected as BUSY
            // (logged by the stack as "isCallbackThread: Failed! / Callback env fail") and the
            // subscriptions are abandoned — leaving HR, battery, worn and events permanently
            // empty even though the strap is bonded and commands (e.g. buzz) still work.
            // One consistent thread serialises discovery → subscribe → bond in the right order.
            // Gated on API 28+ (P): the handler overload exists from API 26, but the stack only
            // reliably honours callback-thread affinity from Android 9 — which is also where this
            // race actually reproduces. On 26/27 we keep the default (callbacks off-main), which is
            // unchanged behaviour, so no regression and no main-thread decode on those older devices.
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                device.connectGatt(
                    context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE,
                    BluetoothDevice.PHY_LE_1M_MASK, handler,
                )
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
                device.connectGatt(context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
            else ->
                device.connectGatt(context, autoConnect, gattCallback)
        }
        gattOps = gatt?.let { gattOpsFactory(it) }
    }

    // ====================================================================================
    // MARK: GATT callback  (port of CBCentralManagerDelegate + CBPeripheralDelegate)
    // ====================================================================================

    private val gattCallback = object : BluetoothGattCallback() {

        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    // Port of didConnect: mark connected, negotiate a larger ATT MTU, THEN discover.
                    handler.removeCallbacks(scanTimeoutRunnable)
                    _state.value = _state.value.copy(connected = true, advertisingName = g.device.name, scanning = false, statusNote = null, encryptedBond = false, reconnectGuide = null)
                    // Multi-WHOOP: publish the connected strap's stable BLE address so SourceCoordinator can
                    // adopt it onto the active registry device's peripheralId on first connect. Additive twin
                    // of macOS BLEManager.connectedPeripheralUUID (set in didConnect). Decoupled from the
                    // registry — the coordinator observes this; the connect flow below is unchanged.
                    _connectedPeripheralAddress.value = g.device.address
                    serviceDiscoveryKicked.set(false)
                    // Capture link signal strength (logged via onReadRemoteRssi) — the scan
                    // "Discovered … (rssi …)" line never fires on a direct/auto-reconnect, so a weak-link
                    // sync (drops, busy storms) is otherwise undiagnosable. DEFERRED past the connect
                    // handshake: Android runs ONE GATT op at a time, so reading RSSI here (before
                    // requestMtu) could make requestMtu return false → MTU skipped → offload capped. A
                    // stray read after setup is harmless (just no RSSI line). (PR #241)
                    // safeGatt: a late RSSI read can land just after the radio went off (#314) — guard it.
                    handler.postDelayed({
                        gattOps?.let { safeGatt("readRemoteRssi") { it.readRemoteRssiCompat() } }
                    }, RSSI_READ_DELAY_MS)
                    // Request the larger MTU BEFORE discovery/subscribe so the offload isn't capped at
                    // 20-byte notifications (the official app does this in its GATT init). Discovery is
                    // gated on the result with a fallback timeout, so a stack that ignores requestMtu
                    // can't stall the connect. (PR #85)
                    val mtuOps = gattOps
                    val mtuOk = mtuOps != null &&
                        safeGatt("requestMtu") { mtuOps.requestMtuCompat(GATT_MTU) }
                    if (mtuOk) {
                        log("Connected — requesting MTU $GATT_MTU before discovery")
                        handler.postDelayed({ kickServiceDiscovery(g, "mtu timeout") }, MTU_FALLBACK_MS)
                    } else if (gatt != null) {
                        // requestMtu returned false (stack ignored it) but the link is still alive —
                        // discover directly. If safeGatt tore down (dead binder), gatt is null: skip.
                        kickServiceDiscovery(g, "requestMtu rejected")
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    // Port of didDisconnectPeripheral: tear down, then auto-rescan unless intentional.
                    handleDisconnect(status)
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            // Whatever the strap granted (≤ requested). Log it, then discover. kickServiceDiscovery is
            // idempotent, so a late callback after the fallback timeout already fired is a no-op. (PR #85)
            log("MTU negotiated: $mtu (status=$status)")
            kickServiceDiscovery(g, "mtu=$mtu")
        }

        override fun onReadRemoteRssi(g: BluetoothGatt, rssi: Int, status: Int) {
            // Signal strength at connect — diagnoses weak-link syncs (drops/busy storms/timeouts) that
            // otherwise look mysterious in the log. Only on a clean read; a failure just stays silent.
            if (status == BluetoothGatt.GATT_SUCCESS) log("Signal: RSSI $rssi dBm")
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Service discovery failed: $status")
                return
            }
            // Port of didDiscoverServices → didDiscoverCharacteristicsFor, collapsed: Android
            // delivers ALL services+characteristics in one callback, so we walk them directly.

            // 1. Custom service: capture the cmd-write char, FIRE THE BOND, queue the notify subs.
            val whoop4 = g.getService(WHOOP4_SERVICE)
            val whoop5 = g.getService(WHOOP5_SERVICE)
            if (whoop4 != null) {
                // Verified WHOOP 4.0 path: capture the cmd-write char + queue the notify subscriptions.
                // We do NOT fire the bond write here. Android allows only ONE outstanding GATT operation,
                // so writing the bond frame now would race the CCCD descriptor writes below and the stack
                // would reject every subscription — the strap bonds (the confirmed write succeeds) but no
                // notifications ever enable, so HR/battery/events stay empty (issue #12). The bond write
                // is deferred to startSession(), which runs once every notification is on.
                connectedFamily = DeviceFamily.WHOOP4
                cmdCharacteristic = whoop4.getCharacteristic(CMD_WRITE_CHAR)
                whoop4.getCharacteristic(CMD_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
                whoop4.getCharacteristic(EVENT_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
                whoop4.getCharacteristic(DATA_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
            } else if (whoop5 != null) {
                // EXPERIMENTAL WHOOP 5.0/MG: opens with CLIENT_HELLO (sent in startSession, after the
                // standard HR/battery notifications are enabled), not the WHOOP4 confirmed-write bond.
                connectedFamily = DeviceFamily.WHOOP5
                log("WHOOP 5/MG detected — will send CLIENT_HELLO after subscribing (experimental).")
                _state.value = _state.value.copy(
                    whoop5Detected = true,
                    statusNote = "WHOOP 5/MG connected — experimental. After bonding, NOOP brings up live " +
                        "heart rate from the strap's realtime stream. Deeper metrics (recovery, strain, " +
                        "sleep) for 5/MG are still being figured out. WHOOP 4.0 is fully supported today.",
                )
                cmdCharacteristic = whoop5.getCharacteristic(WHOOP5_CMD_WRITE_CHAR)
            } else {
                log("Custom WHOOP service not found on this peripheral")
            }
            // The reassembler frames per family — 5/MG uses a different length encoding (declLen @[2..4],
            // total +8) than WHOOP4 (length @[1..3], total +4), so it must match the connected strap.
            reassembler = Reassembler(connectedFamily)

            // 2. Standard HR profile (works unbonded — the reliable HR + R-R source).
            g.getService(HEART_RATE_SERVICE)?.getCharacteristic(HEART_RATE_CHAR)?.let { cccdQueue.add(it) }

            // 3. Standard battery profile (plain %).
            g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)?.let { cccdQueue.add(it) }

            // Enable notifications one at a time. When the queue is fully drained, startSession() fires
            // the first command (bond / CLIENT_HELLO) — never racing the descriptor writes.
            drainCccdQueue(g)
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            // Port of didWriteValueFor: a CONFIRMED-write completion (no error) == bonding succeeded.
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Confirmed write failed: status=$status")
            } else if (!didBond && connectedFamily == DeviceFamily.WHOOP5) {
                // EXPERIMENTAL (issue #17): the CLIENT_HELLO is now a confirmed write, so this ACK means
                // just-works bonding completed. Now subscribe the puffin notify chars (realtime HR rides
                // these as REALTIME_DATA — the strap rejected them on the unauthenticated link), then arm
                // realtime HR with puffin framing. Mirrors the macOS post-bond flow.
                didBond = true
                bondedDirectAttempt = false   // fast-path connect reached a real session (#78 fork)
                staleDirectFailures = 0       // genuine bond — clear the wiped-bond counter (#84 parity)
                _state.value = _state.value.copy(bonded = true, encryptedBond = true)   // genuine bond (#69)
                log("WHOOP 5/MG: CLIENT_HELLO acked — link established; subscribing notify chars (experimental).")
                g.getService(WHOOP5_SERVICE)?.let { svc ->
                    for (u in WHOOP5_NOTIFY_CHARS) svc.getCharacteristic(u)?.let { cccdQueue.add(it) }
                }
                // The 5/MG handshake tail (SET_CLOCK/GET_CLOCK + the offload kick) now runs when THIS
                // CCCD drain completes — see drainCccdQueue's queue-empty branch. Clock-before-history
                // is mandatory: an un-clocked WHOOP 5 doesn't save sensor data to flash at all
                // ("RTC timestamp … is invalid; not saving data to flash"), so history offloads
                // "succeed" with zero body frames. Hardware-validated ordering: CLIENT_HELLO →
                // subscribe puffin chars → clock → history. (#78 fork)
                drainCccdQueue(g)
                if (wantsRealtime) { realtimeArmed = true; send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1)) }
            } else if (!didBond && connectedFamily == DeviceFamily.WHOOP4) {
                didBond = true
                _state.value = _state.value.copy(bonded = true, encryptedBond = true)   // WHOOP4 bond is genuine (#69)
                log("BONDED (confirmed write acknowledged) — custom channels should now flow")
            }

            // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor / onCharacteristicWrite
            // re-fires on EVERY with-response write (the bond write, etc.); the guard prevents re-blasting
            // the handshake at the strap mid-session — THE iOS "won't serve" root cause from the Swift notes.
            // WHOOP 5.0/MG uses CLIENT_HELLO, not this WHOOP4 command sequence, so it is skipped for it.
            if (!connectHandshakeDone && connectedFamily == DeviceFamily.WHOOP4) {
                connectHandshakeDone = true
                runConnectHandshake()
            }

            // This with-response write is done; release the in-flight slot and send the next.
            writeInFlight = false
            drainWriteQueue()
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Notify enable failed for ${descriptor.characteristic?.uuid}: status=$status")
            } else {
                log("Subscribed ${descriptor.characteristic?.uuid}")
                // A subscribe landed — replenish the shared BUSY-retry budget so a transient stall on
                // one characteristic can't starve the others' retries (the counter is global).
                cccdRetries = 0
            }
            // This CCCD write is done; enable the next characteristic's notifications.
            cccdInFlight = false
            drainCccdQueue(g)
        }

        // Android 13+ delivers the value as a parameter; older APIs read it off the characteristic.
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            onInbound(characteristic.uuid, value)
        }

        @Deprecated("Deprecated in API 33; retained for API 26..32 where the value-bearing overload isn't called")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            val value = characteristic.value ?: return
            onInbound(characteristic.uuid, value)
        }

        // Result of an explicit readCharacteristic (refreshBattery's 0x2A19 read) — route it like a
        // notification so the existing battery handler in onInbound runs. Android 13+ passes the value.
        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) onInbound(characteristic.uuid, value)
        }

        @Deprecated("Deprecated in API 33; retained for API 26..32 where the value-bearing overload isn't called")
        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            @Suppress("DEPRECATION")
            if (status == BluetoothGatt.GATT_SUCCESS) characteristic.value?.let { onInbound(characteristic.uuid, it) }
        }
    }

    // ====================================================================================
    // MARK: Inbound routing  (port of didUpdateValueFor + FrameRouter.handle)
    // ====================================================================================

    private fun onInbound(uuid: UUID, bytes: ByteArray) {
        lastDataAtMs = System.currentTimeMillis()   // feeds the keep-alive liveness watchdog
        resubscribedSinceData = false               // data is flowing again — re-arm the one-shot resubscribe
        when {
            uuid == HEART_RATE_CHAR -> parseStandardHr(bytes)       // 0x2A37
            // 0x2A19 = percent — 5/MG ONLY. On a WHOOP 4.0 this characteristic is a stub constant 100
            // (the real value is the GET_BATTERY_LEVEL COMMAND_RESPONSE, u16/10), and it's also
            // SUBSCRIBED, so an unsolicited stub notification could flip the display back to 100 (#77).
            uuid == BATTERY_CHAR -> if (connectedFamily != DeviceFamily.WHOOP4) {
                bytes.firstOrNull()?.let { setBattery((it.toInt() and 0xFF).toDouble()) }
            } else Unit
            // WHOOP4 custom notify chars, OR the WHOOP 5/MG puffin notify chars (fd4b0003/4/5/7) once
            // bonded — both carry framed records (REALTIME_DATA etc.) through the family-aware reassembler.
            uuid == CMD_NOTIFY_CHAR || uuid == EVENT_NOTIFY_CHAR || uuid == DATA_NOTIFY_CHAR ||
                uuid in WHOOP5_NOTIFY_CHARS -> {
                // Reassemble (no-op for already-complete frames) then route each complete frame.
                // Port of: for frame in reassembler.feed(bytes) { router.handle(frame:) }.
                for (frame in reassembler.feed(bytes)) {
                  // #453 defense-in-depth: this loop runs on the GATT binder thread; an uncaught throw
                  // from ANY frame op (handleFrame, a decoder, the inline date-format, log) would crash
                  // the whole app — the exact chain the redactPii bug escaped through. Wrap the whole
                  // body so a bad frame drops ONE frame and the link stays up. (log() is itself total.)
                  try {
                    noteWhoop5R22Telemetry(frame, backfilling && isOffloadFrame(frame, connectedFamily))  // #174
                    handleFrame(frame)              // UI (always) — port of router.handle(frame:)

                    // Capture the strap's newest stored record from a GET_DATA_RANGE reply, feeding
                    // the liveness watchdog. The response command byte is family-dependent: @6 on
                    // WHOOP4, @10 on 5/MG (+4 puffin envelope) — reading 6 unconditionally meant
                    // strapNewestTs never updated from a 5/MG reply. dataRangeNewestUnix's scan-from-7
                    // stays: on 5/MG it lands word-aligned with the body at 11, and a straddling word
                    // can't fall in the unix-range window. (#78 fork)
                    val cmdOff = if (connectedFamily == DeviceFamily.WHOOP5) 10 else 6
                    if (frame.size > cmdOff && (frame[cmdOff].toInt() and 0xFF) == CommandNumber.GET_DATA_RANGE.rawValue) {
                        // #451: dump raw GET_DATA_RANGE response bytes unconditionally (even if decode returns
                        // null) so a stale/wrong-epoch "newest" can be told apart from a frame-alignment bug in
                        // dataRangeNewestUnix straight from a normal strap-log export. Mirrors the Swift line.
                        val hex = frame.joinToString("") { "%02x".format(it) }
                        log("Get Data Range raw frame (#451 — for offset analysis): $hex")
                        dataRangeNewestUnix(frame)?.let {
                            strapNewestTs = it
                            // Observability for "last night didn't sync" (#364): log the NEWEST record the
                            // strap actually holds. With the persisted-N line, one connect distinguishes a
                            // banked-but-not-yet-reached backlog (newest == last night, cursor grinding) from
                            // a genuinely un-banked night (newest is older) — mirrors the Swift line.
                            val fmt = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US)
                            log("Strap newest banked record: ${fmt.format(java.util.Date(it * 1000L))} (from data range)")
                            // Also surface the OLDEST banked record → the full backlog SPAN, i.e. the depth a
                            // deep oldest-first drain must cover before recent nights land (#364). Mirrors Swift.
                            dataRangeOldestUnix(frame)?.let { oldest ->
                                if (oldest < it) {
                                    val spanDays = (it - oldest) / 86_400L
                                    log("Strap banked history span: ${fmt.format(java.util.Date(oldest * 1000L))} → newest " +
                                        "(~$spanDays day${if (spanDays == 1L) "" else "s"} of backlog, drained oldest-first)")
                                }
                            }
                        }
                    }

                    // PERSISTENCE / OFFLOAD ROUTING — port of the didUpdateValueFor tail block.
                    if (backfilling) {
                        // Opt-in raw capture: record EVERY frame of the session (offload AND live
                        // flood — the offload flag lets analysis filter), BEFORE routing so frames
                        // are retained before the trim ack deletes the strap's copy. No-op (single
                        // null check) when the toggle is off. (#78 fork)
                        if (connectedFamily == DeviceFamily.WHOOP5 && captureWriter != null) {
                            writeWhoop5BackfillCapture(uuid.toString(), frame)
                        }
                        // Historical offload: route ONLY genuine offload frames (47/48/49/50) through
                        // the serial drain (preserves chunk order) + re-arm the idle watchdog on them.
                        // The live type-40/43 flood is dropped here (extractHistoricalStreams ignores
                        // it; feeding it only delays each chunk's insert->trim-ack and stalls the strap).
                        if (isOffloadFrame(frame, connectedFamily)) {
                            offloadFramesThisSession++
                            armBackfillTimeout()
                            routeBackfillFrame(frame)
                        }
                    } else {
                        // Live path: buffer the frame for a batched decode+insert (port of Collector.ingest).
                        ingestLiveFrame(frame)
                    }
                  } catch (t: Throwable) {
                    log("inbound frame handling threw ${t.javaClass.simpleName} — dropping this frame, link stays up")
                  }
                }
            }
            else -> { /* ignore */ }
        }
    }

    /**
     * EXPERIMENTAL R22 telemetry (#174) — port of macOS BLEManager.noteWhoop5R22Telemetry.
     * (1) A COMMAND_RESPONSE (type 0x24) to a SET_CONFIG (0x78) = the strap ACKing one enable_r22 flag.
     * (2) A type-0x2F record OUTSIDE our own history offload is NOT a separate live stream. #494 showed
     *     these are historical-offload data: they appear when a SECOND BLE client pulls the strap's
     *     history (SendHistoricalData) — the burst scales with the disconnect/backlog time, not
     *     wall-clock — and the SET_CONFIG enable_r22_* sequence (accepted 15/15) starts no separate
     *     stream. type-0x2F is only ever the historical offload (confirmed across #344's v20/v21 captures
     *     too). We still surface these as a diagnostic, but as what they are — another client's backlog
     *     reaching us over the shared notify channel — not a live R22 "unlock".
     * 5/MG puffin layout: packet_type @ byte 8, the responded-to cmd @ byte 10.
     *
     * #174 cooldown: when our own offload ENDS, the strap can keep flushing a few trailing type-0x2F
     * records AFTER `backfilling` has already flipped false. So we stamp [lastOffloadFrameAtMs] on every
     * offload frame (and at HISTORY_COMPLETE) and skip a non-offload 0x2F within
     * [DEEP_PACKET_LIVE_COOLDOWN_MS] of it. The flag-ACK counting (1) is unchanged.
     */
    private fun noteWhoop5R22Telemetry(frame: ByteArray, duringOffload: Boolean) {
        // R22 deep-data is a WHOOP 5/MG concept only. On a WHOOP 4 a type-0x2F frame is something else
        // entirely, so counting it as a "deep packet" gave 4.0 owners a bogus deep-data counter (#346).
        if (connectedFamily != DeviceFamily.WHOOP5) return
        if (frame.size <= 10) return
        val type = frame[8].toInt() and 0xFF
        if (type == 0x24 && (frame[10].toInt() and 0xFF) == CommandNumber.SET_CONFIG.rawValue) {
            val n = _state.value.r22FlagsAccepted + 1
            _state.value = _state.value.copy(r22FlagsAccepted = n)
            val total = Whoop5Config.enableR22Sequence.size
            if (n == total) log("Deep-data: strap ACCEPTED all $n/$total R22 flags ✓ — keep it on; watching for deep packets.")
        }
        if (type == 0x2F) {
            if (duringOffload) {
                // Trailing-history reference point: a 0x2F during the offload is banked history. Remember
                // when it landed so the cooldown below can discount the few that dribble in after the end.
                lastOffloadFrameAtMs = System.currentTimeMillis()
                return
            }
            // Cooldown guard: a 0x2F within DEEP_PACKET_LIVE_COOLDOWN_MS of our own last offload
            // frame/HISTORY_COMPLETE is a trailing historical record from that session.
            if (lastOffloadFrameAtMs != 0L &&
                System.currentTimeMillis() - lastOffloadFrameAtMs < DEEP_PACKET_LIVE_COOLDOWN_MS
            ) {
                return
            }
            // A 0x2F outside our offload is historical-offload data, not a live R22 stream (#494) —
            // typically another BLE client pulling the strap's backlog over the shared notify channel.
            // Surface it as a diagnostic, but don't claim a live-stream "unlock".
            val n = _state.value.deepPacketsThisSession + 1
            _state.value = _state.value.copy(deepPacketsThisSession = n)
            if (n == 1) log("Deep-data: type-0x2F received outside our offload — this is historical-offload data (another BLE client pulling the strap's history, or a trailing flush), not a live R22 stream (#494).")
            else if (n % 50 == 0) log("Deep-data: $n type-0x2F historical-offload frames seen outside our session.")
        }
    }

    /**
     * Pure decode→state router for one COMPLETE frame.
     * Direct port of `FrameRouter.handle(frame:)`.
     */
    private fun handleFrame(frame: ByteArray) {
        val parsed = Framing.parseFrame(frame, connectedFamily)
        if (!parsed.ok) return
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if (parsed.crcOk == false) return

        when (parsed.typeName) {
            "REALTIME_DATA" -> {
                // Reject 0 / out-of-range spikes; only accept physiologically plausible HR.
                (parsed.parsed["heart_rate"] as? Int)?.let { hr ->
                    if (hr in 30..220) _state.value = _state.value.copy(heartRate = hr)
                }
                // The realtime stream usually reports rr_count=0; only update R-R when this frame
                // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
                // withRRIntervals also feeds the Live console's rolling rrRecent buffer.
                intArrayValue(parsed.parsed["rr_intervals"])?.let { rr ->
                    if (rr.isNotEmpty()) _state.value = _state.value.withRRIntervals(rr)
                }
            }

            "COMMAND_RESPONSE" -> {
                doubleValue(parsed.parsed["battery_pct"])?.let { setBattery(it) }
                val respCmd = parsed.parsed["resp_cmd"] as? String
                val result = parsed.parsed["result"] as? String
                // 5/MG range-query gate: a GET_DATA_RANGE SUCCESS releases the history request
                // (PENDING precedes it; the 2s fail-open fallback covers a swallowed reply). (#78 fork)
                if (connectedFamily == DeviceFamily.WHOOP5 && backfilling && !historicalKickSent &&
                    respCmd?.startsWith("GET_DATA_RANGE") == true
                ) {
                    when {
                        result?.startsWith("SUCCESS") == true -> {
                            log("Backfill: GET_DATA_RANGE SUCCESS — requesting history")
                            sendHistoricalKick()
                        }
                        result != null -> log("Backfill: GET_DATA_RANGE → $result (waiting)")
                    }
                }
                // Surface non-success command results in the strap log — a result=UNSUPPORTED line
                // here is how the MG haptics rejection (#48) would have shown itself in-app.
                if (result != null && !result.startsWith("SUCCESS")) {
                    log("Command response: ${respCmd ?: "?"} → $result")
                }
            }

            "CONSOLE_LOGS" -> {
                // The 5/MG strap narrates its own sync engine here ("BLE: PullStats: Data: N…",
                // "RTC timestamp … is invalid") — gold for protocol research, so mirror it into the
                // strap log (capped; the ring buffer holds 2k lines). (#78 fork)
                (parsed.parsed["console"] as? String)?.let { txt ->
                    log("strap: ${txt.take(300)}")
                }
            }

            "EVENT" -> {
                (parsed.parsed["event"] as? String)?.let { ev ->
                    // Event strings are "NAME(rawValue)", e.g. "WRIST_ON(9)" (see Schema.enumName).
                    val isGesture = ev.startsWith("DOUBLE_TAP") ||
                        ev.startsWith("WRIST_ON") || ev.startsWith("WRIST_OFF")

                    // A BLE_BONDED event confirms a GENUINE encrypted bond (belt-and-suspenders; the
                    // confirmed-write ACK also sets this).
                    if (ev.startsWith("BLE_BONDED")) {
                        _state.value = _state.value.copy(bonded = true, encryptedBond = true)
                    }

                    if (!isGesture) {
                        // Non-gesture events (BLE_BONDED, BATTERY_LEVEL, …) surface in "Last Event" —
                        // except the live-HR stream toggle (BLE_REALTIME_HR_ON/OFF), which is internal
                        // plumbing that fires on every connect and just confuses users (#92).
                        if (!ev.startsWith("BLE_REALTIME_HR")) {
                            _state.value = _state.value.copy(lastEvent = ev)
                        }
                        // Charging flag — wire observation: BATTERY_LEVEL u8 bit0 (4.0 @26 / 5.0 @30).
                        // handleFrame also sees replayed HISTORICAL events during a backfill (old ts),
                        // so gate exactly like the gestures below: live ungated, backfill only if fresh —
                        // an old replayed charging=1 must not light the pill mid-sync.
                        if (ev.startsWith("BATTERY_LEVEL")) {
                            val ts = (parsed.parsed["event_timestamp"] as? Int)?.toLong()
                            val nowSec = System.currentTimeMillis() / 1000L
                            val fresh = !backfilling || (ts != null && ts > 0 &&
                                kotlin.math.abs(nowSec - ts) <= LIVE_GESTURE_WINDOW_SECONDS)
                            if (fresh) {
                                (parsed.parsed["battery_charging"] as? Int)?.let {
                                    _state.value = _state.value.copy(charging = it != 0)
                                }
                            }
                        }
                    } else {
                        // Physical inputs — LIVE ONLY. handleFrame runs for EVERY frame (live AND during a
                        // backfill offload), so gate ONLY while backfilling: a replayed *historical* gesture
                        // (old ts) is ignored during a sync, but a real-time gesture on the live path fires
                        // ungated (#69). The live path MUST stay ungated — a grossly-stale strap RTC (fix
                        // #72) makes a real gesture's event_timestamp look "old", and gating the live path
                        // would silently drop every double-tap / wrist event. (macOS gates only on its
                        // backfill-skip path; Android has no GET_CLOCK correlation to gate in the strap's
                        // clock domain, so backfill uses wall-now — a historical replay is still old.)
                        val ts = (parsed.parsed["event_timestamp"] as? Int)?.toLong()
                        val nowSec = System.currentTimeMillis() / 1000L
                        val fresh = !backfilling || (ts != null && ts > 0 &&
                            kotlin.math.abs(nowSec - ts) <= LIVE_GESTURE_WINDOW_SECONDS)
                        if (fresh) {
                            _state.value = _state.value.copy(lastEvent = ev)
                            when {
                                ev.startsWith("DOUBLE_TAP") -> {
                                    // Surfaced via lastEvent; the ViewModel maps it to the user's chosen action.
                                }
                                ev.startsWith("WRIST_ON") -> {
                                    if (!_state.value.worn) _state.value = _state.value.copy(worn = true)
                                }
                                ev.startsWith("WRIST_OFF") -> {
                                    if (_state.value.worn) _state.value = _state.value.copy(worn = false)
                                }
                            }
                        }
                    }
                }
            }

            else -> { /* ignore other packet types here (handled by the data layer in the full app) */ }
        }
    }

    /**
     * Parse a standard BLE Heart Rate Measurement (0x2A37).
     * Port of `BLEManager.parseStandardHR` + the StandardHeartRate parser:
     *   byte 0 = flags. bit0 = HR is u16 (else u8). bit4 = R-R intervals present (each u16 LE, 1/1024 s).
     * The standard profile is the RELIABLE source for both HR and R-R.
     */
    private fun parseStandardHr(data: ByteArray) {
        if (data.isEmpty()) return
        val flags = data[0].toInt() and 0xFF
        val hr16 = (flags and 0x01) != 0
        val rrPresent = (flags and 0x10) != 0

        var idx = 1
        val hr: Int
        if (hr16) {
            if (data.size < idx + 2) return
            hr = (data[idx].toInt() and 0xFF) or ((data[idx + 1].toInt() and 0xFF) shl 8)
            idx += 2
        } else {
            if (data.size < idx + 1) return
            hr = data[idx].toInt() and 0xFF
            idx += 1
        }

        // Energy-expended field (bit3) precedes R-R if present — skip its 2 bytes.
        if ((flags and 0x08) != 0) idx += 2

        val rr = mutableListOf<Int>()
        if (rrPresent) {
            while (idx + 1 < data.size) {
                val raw = (data[idx].toInt() and 0xFF) or ((data[idx + 1].toInt() and 0xFF) shl 8)
                idx += 2
                // Convert 1/1024 s units to milliseconds (matches the WHOOP store's R-R in ms).
                rr.add((raw * 1000) / 1024)
            }
        }

        // R-R: the standard profile is the reliable source — surface whenever present. withRRIntervals
        // also feeds the Live console's rolling rrRecent buffer.
        if (rr.isNotEmpty()) _state.value = _state.value.withRRIntervals(rr)
        // HR: accept only physiologically plausible values; reject 0/garbage (off-wrist).
        if (hr in 30..220) {
            _state.value = _state.value.copy(heartRate = hr)
            // EXPERIMENTAL WHOOP 5.0/MG: there is no confirmed-write bond for a 5/MG strap, so once
            // live HR actually streams over the standard profile we treat the link as established —
            // otherwise the UI sits on "Connecting…" forever even though data is flowing (issue #8).
            if (connectedFamily != DeviceFamily.WHOOP4 && !_state.value.bonded) {
                _state.value = _state.value.copy(bonded = true)
                log("WHOOP 5/MG: live HR streaming — marking the link established (experimental).")
                // 5/MG has no WHOOP4 confirmed-write handshake, so the keep-alive (re-subscribe +
                // 120s liveness bounce) is started here, on the bonded transition, instead of in
                // runConnectHandshake. Handler.postDelayed is thread-safe to call from this callback.
                startKeepAlive()
            }
        }

        // Record it continuously — independent of the realtime stream or which screen is open.
        // Port of BLEManager.parseStandardHR -> collector.ingestStandardHR(hr:rr:at:).
        ingestStandardHr(hr, rr, (System.currentTimeMillis() / 1000L))
    }

    /** Single funnel for battery readings (port of LiveState.setBattery). */
    private fun setBattery(pct: Double) {
        _state.value = _state.value.copy(batteryPct = pct)
    }

    // ====================================================================================
    // MARK: Connect handshake  (port of the didWriteValueFor once-per-connection block)
    // ====================================================================================

    /**
     * WHOOP-faithful connect lifecycle, run EXACTLY ONCE per connection after the bond ACK.
     * Port of the post-bond block in `BLEManager.didWriteValueFor`:
     *   hello → set RTC → stop the type-43 realtime flood → refresh data range.
     *
     * The heavy historical-offload / keep-alive / backfill timers from the Swift app are owned by
     * the data layer in the full Android port; this BLE client establishes the link and the live
     * stream. We DO stop the unprompted type-43 raw flood (SEND_R10_R11_REALTIME [0x00]) because it
     * eats BLE airtime, exactly as the Swift app does on connect.
     */
    private fun runConnectHandshake() {
        send(CommandNumber.GET_HELLO_HARVARD)
        sendSetClockBothForms()
        // GET_CLOCK's payload length is firmware-specific, exactly like SET_CLOCK's: newer firmware
        // answers the EMPTY form and ignores [0x00], while fw 41.17.x answers [0x00] and ignores the
        // empty form (#120). Send both — the strap answers whichever its firmware accepts.
        send(CommandNumber.GET_CLOCK, byteArrayOf())               // empty form (newer firmware)
        send(CommandNumber.GET_CLOCK, byteArrayOf(0))              // [0x00] form (fw 41.17.x, #120)
        send(CommandNumber.SEND_R10_R11_REALTIME, byteArrayOf(0))  // stop the type-43 realtime flood
        send(CommandNumber.GET_DATA_RANGE)                          // refresh stored range
        log("Connect handshake sent (hello/set-clock/get-clock/stop-raw/get-range)")

        // Historical offload: the type-47 store is the PRIMARY metric source. Kick it once on connect
        // (deferred so SET_CLOCK/GET_DATA_RANGE round-trip first, on a settled link — like the paced
        // Mac prototype), then re-offload every BACKFILL_INTERVAL_MS. Port of the didWriteValueFor
        // tail: asyncAfter(1.5s) { requestSync(.connect) } + startBackfillTimer().
        backfillStarted = true
        handler.postDelayed({ requestSync() }, INITIAL_BACKFILL_DELAY_MS)
        startBackfillTimer()
        startKeepAlive()
        // Arm realtime HR now if a screen already wants it (Live/Health Monitor opened before the bond
        // completed) OR the continuous-capture preference wants it — otherwise the stream would only
        // start at the next keep-alive tick (issue #18). Mark it armed so reconcileRealtime() tracks the
        // edge correctly (the strap forgot the toggle across the disconnect; reset() cleared realtimeArmed).
        if (wantsRealtime) { realtimeArmed = true; send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1)) }
    }

    // ====================================================================================
    // MARK: Live-stream keep-alive  (port of BLEManager.startKeepAlive / keepAliveFire)
    // ====================================================================================

    /** (Re)start the 30s keep-alive. Called from the connect handshake; cancelled in [reset]. */
    private fun startKeepAlive() {
        handler.removeCallbacks(keepAliveRunnable)
        keepAliveTick = 0
        lastDataAtMs = System.currentTimeMillis()   // arm the watchdog from "now", not 1970
        handler.postDelayed(keepAliveRunnable, KEEPALIVE_INTERVAL_MS)
    }

    private fun stopKeepAlive() {
        handler.removeCallbacks(keepAliveRunnable)
    }

    /**
     * Keep the live stream alive (port of `BLEManager.keepAliveFire`). The WHOOP firmware lets the
     * realtime HR stream lapse if it isn't periodically re-armed, and a CCCD can silently drop — both
     * leave HR frozen on a stale value while the GATT link still says "connected", which is exactly
     * what people hit ("only a disconnect/reconnect un-sticks it"). Every 30s we:
     *   1. bounce the link if NOTHING has arrived for >120s (the automatic disconnect+reconnect), or
     *   2. re-subscribe if the stream just went quiet, re-arm realtime HR, and poll battery.
     */
    @SuppressLint("MissingPermission")
    private fun keepAliveFire() {
        val s = _state.value
        if (!s.connected || !s.bonded) return   // disconnected: stop the cadence (restarts on reconnect)

        val silentMs = System.currentTimeMillis() - lastDataAtMs
        // Everything below is the LIVE-path keep-alive. During a historical offload the strap owns the
        // link and has its own 60s idle watchdog (backfillTimeoutRunnable), so we stay completely out
        // of the way — in particular we must NOT bounce, which would abandon the offload mid-session
        // and break the safe-trim cursor.
        if (!backfilling) {
            if (silentMs > KEEPALIVE_STALL_MS) {
                // Nothing for >120s — the live stream/link stalled. Bounce it: the auto-rescan on
                // disconnect re-bonds and resumes streaming (the automatic version of the manual fix).
                log("No data for ${silentMs / 1000}s — bouncing link to resume live stream")
                intentionalDisconnect = false    // make sure the auto-reconnect fires
                // disconnect() throwing on a dead binder (#314) would crash from the keep-alive timer;
                // tear down directly so the bounce degrades to a clean disconnect.
                try {
                    gatt?.disconnect()           // → handleDisconnect → reset() (cancels this) → reconnect
                } catch (t: Throwable) {
                    log("keep-alive bounce: gatt.disconnect() threw ${t.javaClass.simpleName}; tearing down")
                    teardownAfterGattFailure()
                }
            } else {
                // Recover a silently-dropped subscription once the stream has gone quiet (any family) —
                // but only ONCE per quiet episode. Re-subscribing all notify chars every 30s tick floods
                // descriptor writes that collide with the command queue on a slow stack (#77); a single
                // re-subscribe recovers a dropped CCCD, repeating it just adds congestion. Re-armed on data.
                if (silentMs > KEEPALIVE_QUIET_MS && !resubscribedSinceData) {
                    resubscribedSinceData = true
                    enableLiveNotifications()
                }
                // WHOOP 4.0 only: re-arm realtime HR so the firmware can't let it lapse (while the Live
                // screen wants it), and poll battery (~60s) — which also keeps the link warm. A 5/MG
                // strap rejects WHOOP4-framed commands, so we skip them and rely on re-subscribe + bounce.
                if (connectedFamily == DeviceFamily.WHOOP4) {
                    if (wantsRealtime) { realtimeArmed = true; send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1)) }
                    keepAliveTick += 1
                    if (keepAliveTick % 2 == 0) send(CommandNumber.GET_BATTERY_LEVEL)
                }
            }
        }

        // Always re-arm the cadence. After a bounce the pending disconnect cancels this via reset(); a
        // tick that fires while disconnected returns early above — so the keep-alive is never orphaned.
        handler.postDelayed(keepAliveRunnable, KEEPALIVE_INTERVAL_MS)
    }

    /**
     * Re-enable notifications on the live characteristics — recovers a CCCD subscription the stack
     * silently dropped. [drainCccdQueue] writes them one at a time; draining to empty is a no-op for
     * [startSession] (sessionStarted is already true), so this never re-fires the bond/hello.
     */
    @SuppressLint("MissingPermission")
    private fun enableLiveNotifications() {
        val g = gatt ?: return
        when (connectedFamily) {
            DeviceFamily.WHOOP4 -> g.getService(WHOOP4_SERVICE)?.let { svc ->
                svc.getCharacteristic(CMD_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
                svc.getCharacteristic(EVENT_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
                svc.getCharacteristic(DATA_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
            }
            DeviceFamily.WHOOP5 -> { /* 5/MG live HR rides the standard profile, re-subscribed below */ }
        }
        g.getService(HEART_RATE_SERVICE)?.getCharacteristic(HEART_RATE_CHAR)?.let { cccdQueue.add(it) }
        g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)?.let { cccdQueue.add(it) }
        drainCccdQueue(g)
    }

    /**
     * The Live screen wants realtime HR. Records the screen want and reconciles. Port of
     * `BLEManager.startRealtime`.
     */
    fun startRealtime() {
        screenWantsRealtime = true
        reconcileRealtime()
    }

    /** The Live screen no longer needs realtime HR; clear its want and reconcile. The stream stays armed
     *  if the continuous-capture preference ([keepStreamForData]) still wants it. Port of
     *  `BLEManager.stopRealtime`. */
    fun stopRealtime() {
        screenWantsRealtime = false
        reconcileRealtime()
    }

    /** The "Continuous HRV capture" preference flipped: hold the realtime stream open with no Live screen
     *  visible (true) or release it (false), then reconcile. Wired from [com.noop.ui.AppViewModel] and
     *  gated there on the background-connection preference. Mirrors the Swift `setKeepRealtimeForData`. */
    fun setKeepStreamForData(keep: Boolean) {
        keepStreamForData = keep
        reconcileRealtime()
    }

    /**
     * Single reconciler for the realtime-HR stream. The stream should be armed while EITHER a screen
     * wants it ([screenWantsRealtime]) OR the continuous-capture preference wants it ([keepStreamForData]).
     * We arm (TOGGLE_REALTIME_HR 1) / disarm (TOGGLE_REALTIME_HR 0) ONLY on the false↔true edge of that
     * derived want — so a Live screen closing while the preference still wants it does NOT disarm, and
     * turning the preference off with no screen open DOES disarm. The toggle only reaches the strap once
     * it's a WHOOP4 (custom channels are open immediately) or a bonded 5/MG (puffin framing); otherwise
     * the want is remembered and the post-bond branch arms it. Port of `BLEManager.reconcileRealtime`.
     */
    private fun reconcileRealtime() {
        val want = screenWantsRealtime || keepStreamForData
        wantsRealtime = want   // the keep-alive + post-bond arm-on-connect read this derived value
        if (want == realtimeArmed) return                          // no edge — nothing to send
        if (connectedFamily != DeviceFamily.WHOOP4 && !_state.value.bonded) return   // can't reach the strap yet
        realtimeArmed = want
        // Both families arm/disarm via TOGGLE_REALTIME_HR; send() frames it correctly per family (puffin
        // for 5/MG). A screen re-entry blanks its own smoothing window in the view-model, not here.
        send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(if (want) 1.toByte() else 0.toByte()))
    }

    /**
     * EXPERIMENTAL (#181): make the strap advertise its heart rate as a standard BLE HR sensor by
     * writing the device-config flag whoop_live_hr_in_adv_ind_pkt = "1" (on) / "0" (off) via
     * SET_DEVICE_CONFIG (0x77). Validated on real hardware: with it on, the strap advertises 0x180D +
     * the live HR in its manufacturer data, so a Garmin (Edge/watch), Zwift or gym HR client pairs to it
     * directly. Reversible; opt-in. Mirrors `BLEManager.setBroadcastHr`. (Broadcast HR)
     */
    fun setBroadcastHr(on: Boolean) {
        if (connectedFamily != DeviceFamily.WHOOP5) {
            log("Broadcast HR: needs a WHOOP 5.0/MG strap — ignored."); return
        }
        val s = _state.value
        if (!s.connected || !s.bonded) {
            log("Broadcast HR: connect and bond a 5/MG strap first — ignored."); return
        }
        val value = if (on) 0x31 else 0x30   // ASCII '1' / '0'
        send(
            CommandNumber.SET_DEVICE_CONFIG,
            byteArrayOf(0x01) + Whoop5Config.deviceConfigBody("whoop_live_hr_in_adv_ind_pkt", value),
            withResponse = true,
        )
        log("Broadcast HR: wrote whoop_live_hr_in_adv_ind_pkt=" + (if (on) "1" else "0"))
    }

    /**
     * EXPERIMENTAL (#174): write the official app's `enable_r22_*` SET_CONFIG sequence to a bonded
     * WHOOP 5/MG to switch on the deep biometric (type-0x2F "R22") streams the strap withholds from a
     * fresh third-party connection. Exact 15-flag sequence + values built byte-for-byte by
     * [Whoop5Config] (documented by judes.club + Asherlc/dofek). Port of `BLEManager.enableWhoop5DeepData`.
     *
     * Safety: only runs when the deep-data experiment is opted in AND the strap is a bonded, worn 5/MG.
     * The R22 stream is on-wrist gated. Each flag is one SET_CONFIG write WITH RESPONSE, spaced ~80 ms.
     * Reversible — it only changes which data the strap emits. After it runs, wear + sync and share the
     * strap log so we can confirm the deeper records start flowing.
     */
    fun enableWhoop5DeepData() {
        if (connectedFamily != DeviceFamily.WHOOP5) {
            log("Deep-data: needs a WHOOP 5.0/MG strap — ignored."); return
        }
        if (!puffinExperiment.isDeepDataEnabled) {
            log("Deep-data: the deep-data experiment is off — enable it in Settings first."); return
        }
        val s = _state.value
        if (!s.connected || !s.encryptedBond) {
            // The R22 SET_CONFIG writes go over the encrypted command channel, so the live-HR-only
            // shortcut (bonded true, encryptedBond false on a 5/MG still owned by the official app,
            // #69/#266) can't carry them. Require the genuine bond, or the writes silently fail (#269).
            log("Deep-data: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to NOOP first — ignored."); return
        }
        if (!s.worn) {
            log("Deep-data: the R22 stream is on-wrist only — put the strap ON, then try again."); return
        }
        _state.value = _state.value.copy(r22FlagsAccepted = 0)   // fresh attempt
        val flags = Whoop5Config.enableR22Sequence
        log("Deep-data: sending the ${flags.size}-flag enable_r22 sequence (experimental, reversible)…")
        flags.forEachIndexed { i, flag ->
            handler.postDelayed({
                send(
                    CommandNumber.SET_CONFIG,
                    byteArrayOf(0x01) + Whoop5Config.payloadBody(flag.name, flag.value),
                    withResponse = true,
                )
            }, 80L * i)
        }
        handler.postDelayed({
            log("Deep-data: sequence sent. Keep the strap on, let it sync, then share your strap log — we're looking for new deep records (type-0x2F) to start arriving. (#174)")
        }, 80L * flags.size + 200L)
    }

    /**
     * SET_CLOCK(10) payload = the strap's 8-byte form: [seconds u32 LE][subseconds u32 LE].
     * Port of `BLEManager.setClockPayload`. The payload LENGTH is firmware-specific: newer WHOOP 4
     * firmware latches this form, but fw 41.17.x ignores it (no COMMAND_RESPONSE, RTC unchanged) and
     * latches only the legacy 9-byte form below. A strap that misses the set keeps an invalid RTC and
     * stops banking sensor data to flash, surfacing as endless console-only syncs (#120). Send WHOOP 4
     * through [sendSetClockBothForms] so either firmware latches.
     */
    private fun setClockPayload(now: Long = System.currentTimeMillis() / 1000L): ByteArray {
        return byteArrayOf(
            (now and 0xFF).toByte(),
            ((now shr 8) and 0xFF).toByte(),
            ((now shr 16) and 0xFF).toByte(),
            ((now shr 24) and 0xFF).toByte(),
            0, 0, 0, 0,
        )
    }

    /**
     * SET_CLOCK(10) payload — the legacy 9-byte form `[seconds u32 LE][5 zero]` required by WHOOP 4
     * fw 41.17.x, which ignores the 8-byte form. Port of `BLEManager.setClockPayloadLegacy`. On a
     * strap whose RTC was stuck in the past, the 8-byte form drew no response while the 9-byte form was
     * ack'd, latched, and resumed flash banking (#120). On newer firmware this form is ack'd but NOT
     * latched, so it's a no-op there — both forms carry the same seconds.
     */
    private fun setClockPayloadLegacy(now: Long = System.currentTimeMillis() / 1000L): ByteArray {
        return byteArrayOf(
            (now and 0xFF).toByte(),
            ((now shr 8) and 0xFF).toByte(),
            ((now shr 16) and 0xFF).toByte(),
            ((now shr 24) and 0xFF).toByte(),
            0, 0, 0, 0, 0,
        )
    }

    /**
     * Send SET_CLOCK in every payload form the WHOOP 4 firmware family is known to accept (8-byte for
     * newer firmware, 9-byte for 41.17.x — each a no-op on the other). Both carry the same `now`, so
     * double-latching is harmless. WHOOP 5/MG keeps its single hardware-validated 8-byte send, so the
     * legacy form is gated to WHOOP 4. Port of `BLEManager.sendSetClockBothForms`. (#120)
     */
    private fun sendSetClockBothForms(withResponse: Boolean = false) {
        val now = System.currentTimeMillis() / 1000L
        send(CommandNumber.SET_CLOCK, setClockPayload(now), withResponse = withResponse)
        if (selectedModel == WhoopModel.WHOOP4) {
            send(CommandNumber.SET_CLOCK, setClockPayloadLegacy(now), withResponse = withResponse)
        }
    }

    // ====================================================================================
    // MARK: Write + descriptor queues (Android GATT one-op-at-a-time serialisation)
    // ====================================================================================

    private fun enqueueWrite(item: PendingWrite) {
        writeQueue.add(item)
        drainWriteQueue()
    }

    @SuppressLint("MissingPermission")
    private fun drainWriteQueue() {
        // Serialise onto the GATT thread (main looper) — see connectGatt(..., handler). A command
        // issued from a ViewModel coroutine (buzz/send) must not touch the stack off-thread.
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { drainWriteQueue() }
            return
        }
        if (writeInFlight) return
        gatt ?: return
        val ops = gattOps ?: return
        val ch = cmdCharacteristic ?: return
        // A frame rejected BUSY last tick takes priority so it keeps its place in the command sequence.
        val item = pendingRetry ?: writeQueue.poll() ?: return
        pendingRetry = null
        writeInFlight = true

        val writeType = if (item.withResponse) {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT      // with response (acked)
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        }

        // safeGatt: a throw here means the binder died (radio turned off mid-link, #314) — it tears the
        // link down and returns false. After teardown the queues are cleared and gatt is null, so the
        // recursive re-drain below immediately no-ops; we don't fall through into a retry against a dead
        // binder.
        val ok = safeGatt("writeCharacteristic") {
            ops.writeCharacteristicCompat(ch, item.frame, writeType)
        }

        if (!ok) {
            // Transient BUSY — the stack hasn't freed the previous write yet (common on Android 13+/16,
            // worst when the slot was freed too eagerly). Re-hold THIS frame and retry shortly instead
            // of dropping it: a dropped TOGGLE_REALTIME_HR / SET_CLOCK / offload-ack silently breaks
            // live HR, the clock, or the backfill (issue #77 — a Pixel 7 on Android 16 saw exactly this).
            // If safeGatt already tore down (dead binder), gatt is now null — bail before scheduling a
            // retry that would re-enter the dead write.
            writeInFlight = false
            if (gatt == null) return
            if (writeRetries < MAX_WRITE_RETRIES) {
                writeRetries++
                log("writeCharacteristic busy; retry $writeRetries/$MAX_WRITE_RETRIES")
                pendingRetry = item
                // Escalating backoff (12, 24, … capped ~96ms) — ride out a congestion spike instead of
                // exhausting the budget in a few tens of ms while the stack is still busy (#77). NAMED
                // runnable so teardown can cancel a pending retry (#314).
                handler.postDelayed(drainWriteRetryRunnable, WRITE_RETRY_DELAY_MS * minOf(writeRetries, 8))
            } else {
                // Genuinely stuck after several tries — drop this one frame so it can't wedge the queue.
                log("writeCharacteristic rejected by stack; dropping one frame (after $MAX_WRITE_RETRIES retries)")
                writeRetries = 0
                drainWriteQueue()
            }
            return
        }
        writeRetries = 0   // this frame went out — reset the per-frame retry budget

        // WITHOUT-response writes get NO onCharacteristicWrite callback, so free the slot ourselves —
        // but after a short PACING gap. A bare post fired the next write on the same looper tick, before
        // the stack had accepted this one, so Android 16 rejected it (issue #77). postDelayed, not post.
        if (!item.withResponse) {
            handler.postDelayed({
                writeInFlight = false
                drainWriteQueue()
            }, WITHOUT_RESPONSE_PACE_MS)
        }
    }

    /**
     * Fire the bonding write directly (bypasses the normal queue so it is unambiguously first),
     * mirroring how the Swift code writes the bond frame inline in didDiscoverCharacteristicsFor.
     */
    @SuppressLint("MissingPermission")
    private fun writeBondFrame(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
        val ops = gattOps ?: return
        seq = (seq + 1) and 0xFF
        val bondFrame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq)
        log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
        writeInFlight = true   // hold the slot until onCharacteristicWrite fires (with response).
        // safeGatt: a throw means the binder died (#314) — teardown, return false, fall into the
        // "rejected" branch which just clears the (now-stale) in-flight slot.
        val ok = safeGatt("writeBondFrame") {
            ops.writeCharacteristicCompat(ch, bondFrame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        }
        if (!ok) {
            writeInFlight = false
            log("Bond write rejected by stack")
        }
    }

    /**
     * EXPERIMENTAL: WHOOP 5.0/MG opens a session with a static CLIENT_HELLO frame written to its
     * fd4b0002 command characteristic, instead of the WHOOP4 confirmed-write bond. Written WITHOUT a
     * response (it is a complete framed command), and we do NOT hold the in-flight slot or run the
     * WHOOP4 handshake for it. Mirrors the order the WHOOP4 bond uses (write first, then drain the
     * notify subscriptions). Unverified on real MG hardware.
     */
    @SuppressLint("MissingPermission")
    private fun writeClientHello(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
        val hello = DeviceFamily.WHOOP5.clientHello ?: return
        val ops = gattOps ?: return
        // CONFIRMED (with-response) write — mirrors the macOS v1.5 fix and the hardware-verified finding
        // that the CLIENT_HELLO confirmed write triggers the strap's just-works bond. A 5/MG strap won't
        // stream HR (even over the standard 0x2A37 profile) on an UNauthenticated link, so the old
        // unacknowledged write left it bond-less and silent — CLIENT_HELLO written, then nothing (#17).
        // Hold the slot until the ACK; the opt-in puffin probe now fires post-bond (onCharacteristicWrite).
        log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (to trigger bonding, experimental).")
        writeInFlight = true
        val ok = safeGatt("writeClientHello") {
            ops.writeCharacteristicCompat(ch, hello, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        }
        if (!ok) {
            writeInFlight = false
            log("CLIENT_HELLO write rejected by stack")
        }
    }

    /**
     * Open the session once every notification is subscribed. Android serializes GATT operations, so
     * issuing the first command earlier raced the CCCD descriptor writes and dropped the subscriptions
     * (issue #12). WHOOP 4.0 fires the just-works bond write (its ACK triggers the connect handshake in
     * onCharacteristicWrite); WHOOP 5/MG sends CLIENT_HELLO (which itself fires the puffin probe when
     * the experiment is enabled). Guarded so it runs exactly once per connection.
     */
    @SuppressLint("MissingPermission")
    private fun startSession(g: BluetoothGatt) {
        if (sessionStarted) return
        sessionStarted = true
        val cmd = cmdCharacteristic
        if (cmd == null) {
            log("Subscribed, but no command characteristic — cannot open a session")
            return
        }
        when (connectedFamily) {
            DeviceFamily.WHOOP4 -> writeBondFrame(g, cmd)
            DeviceFamily.WHOOP5 -> writeClientHello(g, cmd)
        }
    }

    @SuppressLint("MissingPermission")
    private fun drainCccdQueue(g: BluetoothGatt) {
        // All GATT mutations must run on the one thread the callbacks are pinned to (the main looper,
        // via connectGatt(..., handler)). Re-post if we got here from any other thread.
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { drainCccdQueue(g) }
            return
        }
        if (cccdInFlight) return
        val ch = cccdQueue.poll()
        if (ch == null) {
            // 5/MG handshake tail: after the PUFFIN notify chars are subscribed (the post-CLIENT_HELLO
            // drain — didBond is true by then), clock the strap and only then kick the offload. An
            // un-clocked WHOOP 5 discards sensor data ("RTC timestamp … is invalid; not saving data to
            // flash") and offloads complete with zero body frames; the WHOOP4 path has always clocked
            // on connect (runConnectHandshake). connectHandshakeDone gates beginBackfill and makes this
            // once-per-connection (keep-alive resubscribes also land here). (#78 fork, hardware-proven)
            if (connectedFamily == DeviceFamily.WHOOP5 && didBond && !connectHandshakeDone) {
                connectHandshakeDone = true
                send(CommandNumber.SET_CLOCK, setClockPayload(), withResponse = true)
                send(CommandNumber.GET_CLOCK, byteArrayOf(), withResponse = true)
                log("WHOOP 5/MG: clock synced (set/get) — strap can persist history now")
                if (!backfillStarted) {
                    backfillStarted = true
                    handler.postDelayed({ requestSync() }, INITIAL_BACKFILL_DELAY_MS)
                    startBackfillTimer()
                }
                return
            }
            // Every notification is enabled — now it's safe to write the first command, one GATT
            // operation at a time. This is the fix for issue #12: the bond/hello no longer races the
            // CCCD descriptor writes (which had silently dropped every subscription).
            startSession(g)
            return
        }
        val ops = gattOps ?: return
        cccdInFlight = true

        // Tell the local stack to surface notifications, then write the CCCD so the remote starts
        // sending them. CoreBluetooth's setNotifyValue(true) does both implicitly. Both are routed
        // through safeGatt so a dead binder (#314) tears down instead of crashing.
        val notifyOk = safeGatt("setCharacteristicNotification") {
            ops.setCharacteristicNotificationCompat(ch, true)
        }
        if (!notifyOk && gatt == null) return   // safeGatt tore down — link is gone
        val cccd = ch.getDescriptor(CCCD)
        if (cccd == null) {
            log("No CCCD on ${ch.uuid}; skipping")
            cccdInFlight = false
            drainCccdQueue(g)
            return
        }
        val enableValue = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val ok = safeGatt("writeDescriptor") {
            ops.writeDescriptorCompat(cccd, enableValue)
        }
        if (!ok) {
            cccdInFlight = false
            if (gatt == null) return   // safeGatt tore down — don't schedule a retry against a dead link
            if (cccdRetries < MAX_CCCD_RETRIES) {
                // Transient BUSY (the stack slot hasn't freed): re-queue this subscribe and retry
                // shortly. Order among the notify chars doesn't matter, so re-add at the tail. NAMED
                // runnable so teardown can cancel a pending retry (#314).
                cccdRetries++
                log("writeDescriptor busy for ${ch.uuid}; retry $cccdRetries/$MAX_CCCD_RETRIES")
                cccdQueue.add(ch)
                handler.postDelayed(drainCccdRetryRunnable, CCCD_RETRY_DELAY_MS)
            } else {
                log("writeDescriptor rejected for ${ch.uuid} (gave up after $MAX_CCCD_RETRIES retries)")
                drainCccdQueue(g)
            }
        }
    }

    // ====================================================================================
    // MARK: Live persistence  (port of Collector.ingest / flush / ingestStandardHR / flushStandardHR)
    // ====================================================================================

    /**
     * Buffer one complete custom-channel frame and flush on the cadence threshold. Port of
     * `Collector.ingest`: append, then when the buffer hits [FLUSH_MAX_FRAMES] or
     * [FLUSH_MAX_INTERVAL_MS] since the last flush, drain it. Unlike the Swift Collector this does
     * NOT gate on a clock ref — the live realtime decode uses an identity clock (the strap rarely
     * serves GET_CLOCK on this firmware) and REALTIME_DATA's `timestamp` is mapped through it; the
     * historical store, which is the real metric source, carries its own unix ts and needs no clock.
     */
    private fun ingestLiveFrame(frame: ByteArray) {
        val shouldFlush = synchronized(collectorLock) {
            liveBuffer.add(frame)   // synchronous append preserves GATT-callback arrival order
            liveBuffer.size >= FLUSH_MAX_FRAMES ||
                (System.currentTimeMillis() - batchStartedAtMs) >= FLUSH_MAX_INTERVAL_MS
        }
        if (shouldFlush) ioScope.launch { flushLive() }
    }

    /**
     * Decode the buffered live frames and persist them. Snapshot+clear under the lock BEFORE the
     * suspend insert so concurrent ingests accumulate into the next batch (port of Collector.flush).
     */
    private suspend fun flushLive() {
        val frames = synchronized(collectorLock) {
            if (liveBuffer.isEmpty()) return
            val snapshot = ArrayList(liveBuffer)
            liveBuffer.clear()
            batchStartedAtMs = System.currentTimeMillis()
            snapshot
        }
        // REALTIME_DATA carries the strap's OWN timestamp, and we can't trust its absolute value: on a
        // strap whose RTC is invalid (the same bad clock that blocks history banking — #126) it's a
        // bogus uptime counter, not unix time, so an identity clock (device==wall==now) would stamp live
        // HR thousands of days off-today, where the 24h HR trend never finds it (live HR shows fine but
        // the trend reads empty). Live frames are arriving NOW, so anchor the batch's NEWEST realtime
        // timestamp to wall-clock `now` and let earlier samples fall relative to it. That lands live HR
        // on today's timeline whatever the strap's clock says, and is a no-op when the clock is already
        // valid (newest frame ≈ now). The dense, authoritative source is still the type-47 history store.
        val now = (System.currentTimeMillis() / 1000L).toInt()
        val parsed = frames.map { Framing.parseFrame(it, connectedFamily) }
        val newestRealtimeTs = parsed.asSequence()
            .filter { it.ok && it.crcOk != false && it.typeName == "REALTIME_DATA" }
            .mapNotNull { (it.parsed["timestamp"] as? Number)?.toInt() }
            .maxOrNull() ?: now
        val streams: Streams = extractStreams(parsed, deviceClockRef = newestRealtimeTs, wallClockRef = now)
        val batch = StreamPersistence.toBatch(streams)
        if (!batch.isEmpty) {
            try {
                repository.insert(batch, deviceId)
            } catch (t: Throwable) {
                // Re-buffer at the front so these frames retry on the next cadence (port of Collector).
                synchronized(collectorLock) { liveBuffer.addAll(0, frames) }
            }
        }
    }

    /**
     * Buffer one standard 0x2A37 reading (carries a wall-clock ts directly, no clock ref needed).
     * Auto-flushes ~every 30 readings. Port of `Collector.ingestStandardHR`.
     */
    private fun ingestStandardHr(hr: Int, rr: List<Int>, ts: Long) {
        val shouldFlush = synchronized(collectorLock) {
            if (hr in 30..220) stdHr.add(HrRow(ts, hr))
            for (r in rr) if (r in 250..3000) stdRr.add(RrRow(ts, r))
            stdHr.size + stdRr.size >= 30
        }
        if (shouldFlush) ioScope.launch { flushStandardHr() }
    }

    /** Persist the buffered standard HR/RR. Re-buffers on failure. Port of `Collector.flushStandardHR`. */
    private suspend fun flushStandardHr() {
        val (hr, rr) = synchronized(collectorLock) {
            if (stdHr.isEmpty() && stdRr.isEmpty()) return
            val h = ArrayList(stdHr); val r = ArrayList(stdRr)
            stdHr.clear(); stdRr.clear()
            h to r
        }
        try {
            repository.insert(StreamBatch(hr = hr, rr = rr), deviceId)
        } catch (t: Throwable) {
            synchronized(collectorLock) { stdHr.addAll(0, hr); stdRr.addAll(0, rr) }
        }
    }

    // ====================================================================================
    // MARK: Historical offload  (port of BLEManager backfill helpers + state machine)
    // ====================================================================================

    /**
     * Start a historical-offload session: tell the state machine to begin, flip the routing flag,
     * kick the strap with SEND_HISTORICAL_DATA, and arm the idle watchdog. Port of `beginBackfill`.
     *
     * Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
     * [0x00] (the Mac ground-truth offload uses [0x00] too). Plain offload — the strap streams
     * HISTORY_START -> type-47 records -> HISTORY_END (acked) ... -> HISTORY_COMPLETE.
     */
    private fun beginBackfill() {
        if (!connectHandshakeDone) {
            log("Backfill: deferred — connect handshake not done yet")
            return
        }
        if (backfilling) return
        backfiller.begin(connectedFamily)   // family drives the +4 puffin offset for 5/MG (#78)
        backfilling = true
        ackedChunksThisSession = 0
        decodedChunksThisSession = 0
        consoleChunksThisSession = 0
        offloadFramesThisSession = 0
        historicalKickSent = false
        _state.value = _state.value.copy(backfilling = true, syncChunksThisSession = 0)
        // Opt-in raw capture (research aid): pref read fresh per session, like the probes gate.
        if (connectedFamily == DeviceFamily.WHOOP5 && PuffinExperiment.from(context).isCaptureEnabled) {
            startWhoop5BackfillCapture()
        }
        if (connectedFamily == DeviceFamily.WHOOP5) {
            // Re-apply the Broadcast-HR device-config flag if the user opted in (#181).
            if (PuffinExperiment.from(context).broadcastHr) setBroadcastHr(true)
            // Goose parity, hardware-validated (#78 fork): query the strap's stored range first and
            // fire the transfer on its SUCCESS response (PENDING precedes it). FAIL-OPEN: real
            // hardware sometimes swallows the first GET_DATA_RANGE entirely, so a 2s fallback fires
            // the transfer anyway — the gate can delay the kick but never block it. WHOOP4 keeps its
            // proven blind-fire path untouched.
            send(CommandNumber.GET_DATA_RANGE, byteArrayOf(), withResponse = true)
            handler.postDelayed({
                if (backfilling && !historicalKickSent) {
                    log("Backfill: GET_DATA_RANGE unanswered — requesting history anyway (fail-open)")
                    sendHistoricalKick()
                }
            }, DATA_RANGE_GATE_MS)
        } else {
            sendHistoricalKick()
        }
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
    }

    /** Fire SEND_HISTORICAL_DATA exactly once per backfill session (gate + fallback can both call). */
    private fun sendHistoricalKick() {
        if (historicalKickSent) return
        historicalKickSent = true
        send(CommandNumber.SEND_HISTORICAL_DATA, byteArrayOf(0), withResponse = true)
    }

    /**
     * The single gated entry point for every historical-offload kick. Runs only when connected +
     * bonded and NOT already mid-backfill. Port of `requestSync` minus the BackfillPolicy
     * rate-limiter (see FLAG: the policy gate isn't ported here — the only triggers wired are the
     * once-per-connect kick and the 900s periodic timer, which is itself the coarse rate limit).
     */
    private fun requestSync() {
        val s = _state.value
        if (!canRequestSync(s.connected, s.bonded, backfilling)) return
        beginBackfill()
    }

    /**
     * Public "Sync now" entry point for a user-initiated manual offload (Live screen button, #93).
     *
     * Deliberately just forwards to the SAME gated [requestSync] the auto-kick and the 900s periodic
     * timer use, so a manual sync can never bypass the connected+bonded+not-already-backfilling guard.
     * It's therefore a safe no-op when the strap isn't ready or a session is already running. Posted to
     * the main looper because [beginBackfill] arms handler-scoped timers — the UI may call from any
     * thread, and every other timer/GATT path is pinned to this handler (see connectGatt(..., handler)).
     */
    fun syncNow() {
        handler.post { requestSync() }
    }

    /** Periodic-timer callback: re-runs the type-47 offload (the primary metric sync). */
    private fun triggerPeriodicBackfill() {
        requestSync()
        // Re-arm regardless so the cadence continues for the life of the connection.
        handler.postDelayed(periodicBackfillRunnable, BACKFILL_INTERVAL_MS)
    }

    private fun startBackfillTimer() {
        handler.removeCallbacks(periodicBackfillRunnable)
        handler.postDelayed(periodicBackfillRunnable, BACKFILL_INTERVAL_MS)
    }

    private fun stopBackfillTimer() {
        handler.removeCallbacks(periodicBackfillRunnable)
    }

    /**
     * Feed an offload frame to the Backfiller preserving exact arrival order. Frames are appended
     * synchronously (callback order) and drained sequentially by a single coroutine, so START/data/
     * END chunk assembly is never reordered. Port of `routeBackfillFrame` + the serial drain task.
     */
    private fun routeBackfillFrame(frame: ByteArray) {
        backfillFrameQueue.add(frame)
        if (backfillDraining) return
        backfillDraining = true
        ioScope.launch {
            // A throw from ingest() must NEVER leave backfillDraining stuck true (that would wedge the
            // offload — every later frame returns early and the queue never drains). finally guarantees
            // the flag is cleared even if a chunk handler throws. (#77/#91 hardening.)
            try {
                while (true) {
                    val f = backfillFrameQueue.poll() ?: break
                    try {
                        backfiller.ingest(f)
                    } catch (t: Throwable) {
                        log("Backfill: drain error (${t.message}) — skipping frame, offload continues")
                    }
                    // If the Backfiller consumed all historical data, exit the session cleanly.
                    if (backfilling && !backfiller.isBackfilling) {
                        handler.post { exitBackfilling("HISTORY_COMPLETE") }
                    }
                }
            } finally {
                backfillDraining = false
            }
        }
    }

    /**
     * Re-arm the idle watchdog. Called on every offload frame during backfill; if the strap goes
     * silent the timer fires and we exit the session. Port of `armBackfillTimeout`.
     */
    private fun armBackfillTimeout() {
        handler.removeCallbacks(backfillTimeoutRunnable)
        handler.postDelayed(backfillTimeoutRunnable, BACKFILL_IDLE_TIMEOUT_MS)
    }

    private fun onBackfillTimeout() {
        // 5/MG: a session that timed out with ZERO offload frames means the strap never answered the
        // history request (seen on real hardware — the first request after connect can be swallowed).
        // Retry once with a clean teardown; after 2 attempts the 900s periodic timer owns it. (#78 fork)
        if (connectedFamily == DeviceFamily.WHOOP5 && offloadFramesThisSession == 0 &&
            whoop5HistoryAttempts < 2 && _state.value.connected && _state.value.bonded
        ) {
            whoop5HistoryAttempts++
            backfiller.timeoutFired()
            backfilling = false
            _state.value = _state.value.copy(backfilling = false, syncChunksThisSession = 0)
            handler.removeCallbacks(backfillTimeoutRunnable)
            backfillFrameQueue.clear()
            log("Backfill: no history frames arrived — retrying request (attempt ${whoop5HistoryAttempts + 1})")
            handler.postDelayed({ requestSync() }, WHOOP5_HISTORY_RETRY_DELAY_MS)
            return
        }
        backfiller.timeoutFired()
        exitBackfilling("timeout")
    }

    /** Tear down the backfill session. Port of `exitBackfilling`. Does NOT auto-start live HR. */
    private fun exitBackfilling(reason: String) {
        if (!backfilling) return
        backfilling = false
        // #174: a backfill just ended. Start (or extend) the deep-packet cooldown from this instant so
        // any type-0x2F records the strap flushes in the seconds after the session aren't miscounted as
        // the live R22 stream — they're the offload's tail.
        lastOffloadFrameAtMs = System.currentTimeMillis()
        // Record an honest sync outcome so a cloud-free user can tell sync is working (or stuck):
        // HISTORY_COMPLETE stamps lastSyncAt + clears any error; an idle-watchdog timeout surfaces a
        // non-silent error. A plain disconnect mid-sync leaves both as-is (not a failure — the next
        // connect re-offloads). The freshly-published count is preserved as the progress read. (PR #85)
        val nowSec = System.currentTimeMillis() / 1000L
        // #77 / #214 family: a sync that COMPLETED but banked NO sensor records ⇒ the strap isn't
        // saving to flash (its RTC lost sync). Surface the actionable fix instead of a silent "synced".
        // The signal had ONE shape — console-only across ≥3 chunks — so a NEAR-EMPTY completion
        // (metadata-only ENDs, zero rows persisted, FEWER than 3 console frames) slipped through to the
        // silent branch (#214). Broaden it: a HISTORY_COMPLETE that decoded nothing AND persisted ZERO
        // sensor rows is ALSO "banked nothing", regardless of console-frame count. The #126 guard is
        // unchanged — the banner still only fires once SUSTAINED — so a genuinely caught-up strap that
        // banked rows on an earlier cycle won't trip it.
        val (bankedSensorRecords, bankedNothingRaw) = classifyCompletedOffload(
            decodedChunks = decodedChunksThisSession,
            consoleChunks = consoleChunksThisSession,
            rowsPersisted = backfiller.sessionRowsPersisted,
        )
        val bankedNothing = reason == "HISTORY_COMPLETE" && bankedNothingRaw
        // #126: only escalate to the clock-lost banner once emptiness is SUSTAINED. A banking cycle (any
        // decoded records / rows persisted) clears the streak, so a single transient empty cycle on a
        // healthy strap stays silent. Track on every completed sync so banking cycles reset it.
        val sustainedEmpty = if (reason == "HISTORY_COMPLETE")
            emptySyncTracker.recordCompletedSync(
                bankedSensorRecords = bankedSensorRecords,
                consoleOnly = bankedNothingRaw,
            ) else false
        if (bankedNothing) {
            val detail = if (consoleChunksThisSession >= 3)
                "console-only across $consoleChunksThisSession chunks"
            else "metadata-only, 0 sensor rows persisted"
            log(
                "Backfill: completed but the strap banked no sensor history ($detail); " +
                    "consecutive empty syncs = ${emptySyncTracker.consecutiveEmptySyncs}.",
            )
        }
        _state.value = when (reason) {
            "HISTORY_COMPLETE" -> _state.value.copy(
                backfilling = false,
                syncChunksThisSession = ackedChunksThisSession,
                lastSyncAt = nowSec,
                lastSyncError = if (bankedNothing && sustainedEmpty)
                    "Synced, but your strap had no stored history to hand over — only its diagnostic output. This usually means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then reconnect, and it should start banking again."
                else null,
            )
            "timeout" -> _state.value.copy(
                backfilling = false,
                syncChunksThisSession = ackedChunksThisSession,
                lastSyncError = "Sync interrupted — the strap went quiet. It will retry on the next sync.",
            )
            else -> _state.value.copy(
                backfilling = false,
                syncChunksThisSession = ackedChunksThisSession,
            )
        }
        handler.removeCallbacks(backfillTimeoutRunnable)
        backfillFrameQueue.clear()
        closeWhoop5BackfillCapture(flushSummary = true)
        log("Backfill: session ended — reason=$reason")
        // Inactivity reminder (#419): read-only hook on the natural offload completion (no cadence
        // change). Only on a true HISTORY_COMPLETE — a timeout/disconnect didn't bring a fresh window.
        if (reason == "HISTORY_COMPLETE") {
            maybeBuzzInactivity()
            // L3 stress check-in (v5): same read-only hook — fire the StressOnsetDetector over the live
            // R-R buffer. Self-gates on the BiofeedbackPrefs master/auto toggles (inert when off).
            maybeNudgeStress()
        }
        // Success-side summary (#150 forensics): we logged failures (decoded-to-0) but never successes,
        // so a strap log couldn't tell a banking strap from a broken one. Emit the per-session persistence
        // tally whenever anything actually landed — the win-rate signal a log previously lacked. Mirrors
        // the Swift exitBackfilling.
        Backfiller.sessionSummaryLine(
            backfiller.sessionRowsPersisted, backfiller.sessionMotionRows, backfiller.sessionNights,
        )?.let { log(it) }

        // #364 auto-continue spin-detector: did THIS session move the strap's trim cursor? Compare the
        // Backfiller's current high-water trim against where it stood when the previous session ended.
        // A frozen cursor (console-only / refusing to trim) ⇒ don't re-kick (it would spin forever).
        val currentTrim = backfiller.lastAckedTrim
        val trimAdvanced = currentTrim != null && currentTrim != lastSessionEndTrim
        lastSessionEndTrim = currentTrim
        // #364 / #25: a session that ended on the 60s idle-cap OR on a true HISTORY_COMPLETE, while still
        // connected, with more backlog and the trim advancing, immediately re-kicks instead of waiting the
        // 900s periodic floor — so a deep oldest-first backlog drains in back-to-back ~60s passes. #25:
        // fire on HISTORY_COMPLETE too — some straps segment a deep overnight offload into many small
        // HISTORY_COMPLETE slices and would otherwise stall between slices until the periodic floor. The
        // streak is NO LONGER reset unconditionally on HISTORY_COMPLETE: a sliced offload would otherwise
        // reset it on every slice and never engage the 6-per-connection cap. shouldAutoContinue's guards
        // make this safe (a caught-up strap returns false and stops); the streak is cleared only once that
        // predicate proves we're caught up — inside maybeAutoContinueBackfill's else path. Bounded by the
        // cap + spin-detector either way.
        if (reason == "timeout" || reason == "HISTORY_COMPLETE") {
            maybeAutoContinueBackfill(trimAdvanced, backfiller.sessionRowsPersisted)
        }
    }

    /**
     * #364 / #25: evaluate (and, if warranted, fire) an immediate back-to-back backfill after a 60s
     * idle-cap exit OR a HISTORY_COMPLETE. The "more backlog remains" test needs our persisted data
     * frontier (max HR ts) from the repository, so it reads on [ioScope] then re-kicks back on the main
     * looper via [requestSync] (the SAME gated path the auto-kick + periodic timer use — it re-checks
     * connected/bonded/not-backfilling, so this can't double-start). On the else (caught-up, under-cap)
     * path it instead clears [consecutiveAutoContinues] (#25). The decision is the pure [shouldAutoContinue]
     * so it stays unit-testable.
     * [trimAdvanced] is the spin-detector signal computed in [exitBackfilling] (passed in because that
     * method has already advanced [lastSessionEndTrim] past the comparison point). Android has no
     * BackfillPolicy floor ported (only the 900s timer), so [requestSync] needs no special bypass tier —
     * it always runs when the gate passes. Mirrors Swift `maybeAutoContinueBackfill`.
     */
    private fun maybeAutoContinueBackfill(trimAdvanced: Boolean, rowsPersisted: Int) {
        val s = _state.value
        if (!s.connected || !s.bonded) return
        val newest = strapNewestTs
        val count = consecutiveAutoContinues
        ioScope.launch {
            val frontier = runCatching { repository.latestHrSampleTs(deviceId) }.getOrNull()
            if (!shouldAutoContinue(
                    stillConnected = _state.value.connected && _state.value.bonded,
                    strapNewestTs = newest,
                    ourFrontierTs = frontier,
                    lastTrimAdvanced = trimAdvanced,
                    consecutiveCount = count,
                    rowsPersistedThisSession = rowsPersisted,
                )
            ) {
                // No re-kick. THIS is the real "we're done draining" signal (#25): clear the streak so the
                // NEXT deep backlog (e.g. after the app's been off again) gets a fresh budget of re-kicks.
                // Reset here — NOT unconditionally on every HISTORY_COMPLETE — so a strap that slices one
                // offload into many completions can't keep resetting the cap and spin forever. EXCEPTION: if
                // we stopped because the per-connection CAP is hit, leave the streak at/over the cap so it
                // STAYS engaged for the rest of this connection (the 900s floor takes over); zeroing it here
                // would immediately re-arm the cap and let a runaway strap spin again.
                if (count < MAX_AUTO_CONTINUES) {
                    handler.post { consecutiveAutoContinues = 0 }
                }
                return@launch
            }
            handler.post {
                // Re-check on the main looper: a real backfill may already have re-started (periodic) in
                // the gap. requestSync's own gate handles that, but skip the log/counter churn if so.
                if (backfilling) return@post
                consecutiveAutoContinues += 1
                log(
                    "Backfill: auto-continuing (#364/#451) — the trim advanced and the strap is still " +
                        "handing over real records (frontier ${frontier ?: "?"}, strap-reported newest " +
                        "${newest ?: "?"}); re-kicking offload $consecutiveAutoContinues/$MAX_AUTO_CONTINUES " +
                        "without waiting the 15-min floor.",
                )
                requestSync()
            }
        }
    }

    /**
     * Ack one HISTORY_END chunk so the strap may trim it. Confirmed write (with response): the strap
     * forgets the chunk once this lands (link-layer half of safe-trim; decoded already persisted).
     *
     * Ack form (matches the verified Mac offload): HISTORICAL_DATA_RESULT(23) payload =
     * `[0x01] + end_data`, where end_data is the verbatim 8 bytes of the HISTORY_END
     * metadata.data[10:18]. Port of `BLEManager.ackHistoricalChunk`.
     */
    private fun ackHistoricalChunk(trim: Long, endData: ByteArray) {
        val payload = ByteArray(1 + endData.size)
        payload[0] = 0x01
        System.arraycopy(endData, 0, payload, 1, endData.size)
        send(CommandNumber.HISTORICAL_DATA_RESULT, payload, withResponse = true)
        // Progress signal for the "Syncing strap history…" UI (#77). Republish every 10th chunk only —
        // the FGS notification re-posts on every LiveState emission. Runs on the single serial drain
        // coroutine, so the counter is race-free.
        ackedChunksThisSession += 1
        if (ackedChunksThisSession % 10 == 0) {
            _state.value = _state.value.copy(syncChunksThisSession = ackedChunksThisSession)
        }
        log("Backfill: acked chunk trim=$trim")
    }

    // ====================================================================================
    // MARK: GATT crash-safety  (#314 — dead-binder guards)
    // ====================================================================================

    /**
     * Run a raw GATT operation, swallowing the dead-binder exceptions that escape `BluetoothGatt`
     * once the OS Bluetooth radio is turned off mid-link, and route into full teardown if one fires.
     *
     * The bug (#314, Pixel 7): turning Bluetooth off doesn't disconnect NOOP's `BluetoothGatt`; the
     * next write hits a dead binder and `writeCharacteristic` throws `android.os.DeadObjectException`
     * (an unchecked `RuntimeException`) — which the GATT layer never declared, so nothing caught it
     * and the app crashed on the next buzz/sync. We also see `IllegalStateException` (adapter off) and
     * `SecurityException` (permission revoked) from the same calls. On ANY of these the link is gone:
     * tear down so the UI flips to disconnected instead of crashing.
     *
     * @return the block's boolean (stack-accepted) on success, or `false` if the binder was dead — a
     *   `false` lets callers run their normal "rejected by stack" path, which after teardown is inert
     *   (the queues are cleared and `gatt` is null, so the recursive re-drain immediately no-ops).
     */
    private fun safeGatt(reason: String, block: () -> Boolean): Boolean =
        try {
            block()
        } catch (t: Throwable) {
            // DeadObjectException / IllegalStateException / SecurityException all mean the link is
            // unusable. Catching Throwable here is deliberate: any GATT call that throws AT ALL once
            // the binder is dead must not crash the app — there's no recovery, only teardown. The
            // policy (always tear down) is single-sourced in shouldTeardownOnGattThrow so it's testable.
            if (shouldTeardownOnGattThrow(t)) {
                log("GATT op '$reason' failed (${t.javaClass.simpleName}); tearing down link")
                teardownAfterGattFailure()
            }
            false
        }

    /**
     * Full teardown after a raw GATT call threw because the binder died (#314). Mirrors the
     * intentional-disconnect teardown but is reached from the catch path, so it must do everything
     * [handleDisconnect]+[reset] do AND cancel the two BUSY-retry kicks — a still-pending
     * [drainWriteRetryRunnable]/[drainCccdRetryRunnable] would otherwise fire after the link is dead
     * and re-enter the dead write, throwing again. Marks the disconnect intentional so no auto-rescan
     * loops against a powered-off radio (the adapter.isEnabled gate already suppresses connect, but
     * suppressing the rescan keeps the log clean and avoids a tight retry loop).
     */
    private fun teardownAfterGattFailure() {
        // Cancel any scheduled BUSY-retry kicks BEFORE handleDisconnect/reset clears the queues, so a
        // retry can't re-enter drainWriteQueue/drainCccdQueue against the dead binder.
        handler.removeCallbacks(drainWriteRetryRunnable)
        handler.removeCallbacks(drainCccdRetryRunnable)
        intentionalDisconnect = true   // don't auto-rescan against a dead/off radio
        // reset() (inside handleDisconnect) clears writeInFlight + the write/cccd queues + pendingRetry
        // and cancels the keep-alive/backfill timers; handleDisconnect publishes connected=false and
        // closes + nulls gatt. Also drop the GattOps wrapper so a late call can't reach the dead gatt.
        handleDisconnect(BluetoothGatt.GATT_FAILURE)
        gattOps = null
    }

    // ====================================================================================
    // MARK: Disconnect / teardown  (port of didDisconnectPeripheral)
    // ====================================================================================

    @SuppressLint("MissingPermission")
    private fun handleDisconnect(status: Int) {
        // Capture BEFORE reset() wipes didBond: a bonded fast-path connect that dropped without ever
        // reaching a session means the OS bond is stale — fall back to a scan so a new/re-paired
        // strap can still be found (and "No WHOOP strap found" guidance still appears). (#78 fork)
        val staleDirectBond = bondedDirectAttempt && !didBond
        bondedDirectAttempt = false

        // Persist anything buffered before tearing down (port of the collector.flush() +
        // flushStandardHR() calls in didDisconnectPeripheral). Runs on the IO scope.
        ioScope.launch { flushLive(); flushStandardHr() }

        // Reset all per-connection state and clear UI flags (incl. the syncing pill — a dropped link
        // mid-offload must not leave "Syncing strap history…" stuck on, #77). clearedBiometrics() also
        // blanks HR / R-R / the rolling buffer so a stale heart rate or R-R strip can't outlive the link
        // (parity with macOS LiveState.clearBiometrics — PR#191; the Android client previously cleared
        // `charging` but left heartRate/rr stale).
        _state.value = _state.value.clearedBiometrics().copy(
            connected = false, bonded = false, encryptedBond = false,
            backfilling = false, syncChunksThisSession = 0,
            charging = null,   // a stale charging flag must not outlive the link
        )
        // Multi-WHOOP: the link is down — clear the published connected address so SourceCoordinator's
        // adoption sink can't re-fire on a stale strap id (twin of macOS clearing connectedPeripheralUUID).
        _connectedPeripheralAddress.value = null
        reset()

        // close() can itself throw DeadObjectException on a dead binder — teardown must NEVER throw,
        // or the catch in safeGatt re-raises and we're back to the #314 crash. Swallow it.
        try { gatt?.close() } catch (t: Throwable) { log("gatt.close() threw ${t.javaClass.simpleName} during teardown (ignored)") }
        gatt = null
        gattOps = null
        cmdCharacteristic = null

        if (!intentionalDisconnect) {
            if (staleDirectBond) {
                staleDirectFailures++
                log("Disconnected (status=$status) before the bonded fast-path reached a session — stale OS bond (attempt $staleDirectFailures); falling back to a scan")
                lastDevice = null
                // Two consecutive wiped-bond failures = the strap really reset its pairing (firmware
                // update / official WHOOP app re-bond), not a one-off transient drop. Surface the same
                // forget+re-pair guide the Mac shows (v1.73). We KEEP scanning so a fresh re-pair is
                // picked up automatically and the guide clears on the next successful connect.
                if (staleDirectFailures >= 2) {
                    _state.value = _state.value.copy(
                        reconnectGuide = """
                        Your strap's Bluetooth pairing was reset — usually by a WHOOP firmware update, or the official WHOOP app reconnecting. NOOP works fine on the new firmware; you just need to re-pair:

                        1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                        2. Open Settings → Bluetooth, find your WHOOP, and Forget / Unpair it.
                        3. Tap the band repeatedly until its LEDs flash blue (pairing mode).
                        4. Come back here and tap Connect.
                        """.trimIndent()
                    )
                }
                handler.postDelayed({
                    if (!intentionalDisconnect) connect(selectedModel)
                }, RECONNECT_DELAY_MS)
                return
            }
            val dev = lastDevice
            if (dev != null && isPreferred(dev)) {
                // Reconnect DIRECTLY to the strap we already know (autoConnect=true): the OS reconnects
                // as soon as it's reachable, with no scan and no advertisement required — fixing the
                // dropout loop where a bonded strap that wasn't advertising could never be re-found by
                // scanning, leaving the user stuck until they forced pairing mode (#61).
                // Multi-WHOOP: gated on [isPreferred] so an involuntary reconnect can never re-attach to a
                // strap that is no longer the active-pinned one — if [lastDevice] isn't the pinned strap we
                // fall through to the pin-aware rescan below (mirrors macOS re-asserting the pin on every
                // reconnect). On the single-WHOOP path [preferredAddress] is null → isPreferred is always
                // true → byte-for-byte unchanged.
                log("Disconnected (status=$status); reconnecting directly in ${RECONNECT_DELAY_MS / 1000}s")
                handler.postDelayed({
                    if (!intentionalDisconnect) connectToDevice(dev, autoConnect = true)
                }, RECONNECT_DELAY_MS)
            } else {
                log("Disconnected (status=$status); rescanning in ${RECONNECT_DELAY_MS / 1000}s")
                handler.postDelayed({
                    if (!intentionalDisconnect) connect(selectedModel)
                }, RECONNECT_DELAY_MS)
            }
        } else {
            log("Disconnected (intentional)")
        }
    }

    /** Clear per-connection state. Port of the flag resets in didConnect / didDisconnectPeripheral. */
    private fun reset() {
        didBond = false
        connectHandshakeDone = false
        seq = 0
        writeQueue.clear()
        cccdQueue.clear()
        writeInFlight = false
        pendingRetry = null
        writeRetries = 0
        // Cancel any scheduled BUSY-retry kicks so a queued retry can't fire after teardown and
        // re-enter a dead write/descriptor (#314).
        handler.removeCallbacks(drainWriteRetryRunnable)
        handler.removeCallbacks(drainCccdRetryRunnable)
        resubscribedSinceData = false
        cccdInFlight = false
        cccdRetries = 0
        sessionStarted = false
        // The strap forgets the realtime-HR toggle across a disconnect; the post-bond branch re-arms it
        // from [wantsRealtime]. Clear only the "what we last sent" flag — the screen/preference WANTS
        // ([screenWantsRealtime]/[keepStreamForData]/[wantsRealtime]) are intent and must survive a
        // reconnect so the stream comes back automatically.
        realtimeArmed = false

        // Reset offload state so the next connect starts a fresh session (port of the backfill
        // flag resets in didDisconnectPeripheral). Timers are handler-posted, so cancel them here.
        backfillStarted = false
        backfilling = false
        backfillDraining = false
        backfillFrameQueue.clear()
        strapNewestTs = null
        offloadFramesThisSession = 0
        lastOffloadFrameAtMs = 0L   // #174: don't carry a stale cooldown reference into the next session
        historicalKickSent = false
        whoop5HistoryAttempts = 0
        // #364: the auto-continue streak + spin-detector are per-connection — a fresh connection earns a
        // fresh budget of back-to-back re-kicks and restarts its trim-advance comparison from scratch.
        consecutiveAutoContinues = 0
        lastSessionEndTrim = null
        // A mid-offload link drop must still flush the capture file (summary already logged or not —
        // don't double-log it here).
        closeWhoop5BackfillCapture(flushSummary = false)
        handler.removeCallbacks(backfillTimeoutRunnable)
        stopBackfillTimer()
        stopKeepAlive()

        // Fresh reassembler per connection. The macOS BLEManager reassigns a NEW Reassembler on each
        // connect (BLEManager.swift:183); matching that here stops a partial/garbage frame left over
        // from one session wedging the live stream after a reconnect (so the keep-alive's link-bounce
        // actually recovers a frozen stream).
        reassembler.reset()
    }

    /**
     * Permanently release this client's background scope. Call from the owner's teardown
     * (e.g. AppViewModel.onCleared) AFTER [disconnect]. Idempotent.
     */
    fun shutdown() {
        ioScope.cancel()
    }

    // ====================================================================================
    // MARK: Helpers
    // ====================================================================================

    /** Coerce a parsed value to an Int list (rr_intervals may arrive as List<Int> or IntArray). */
    @Suppress("UNCHECKED_CAST")
    private fun intArrayValue(v: Any?): List<Int>? = when (v) {
        is List<*> -> v.mapNotNull { (it as? Number)?.toInt() }
        is IntArray -> v.toList()
        else -> null
    }

    /** Coerce a parsed value to a Double (battery_pct may arrive as Double or Int). */
    private fun doubleValue(v: Any?): Double? = (v as? Number)?.toDouble()

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    // MARK: 5/MG raw backfill capture (opt-in research aid, #78 fork)
    //
    // Records every frame of a 5/MG backfill session as one JSONL line (parsed fields + raw hex) so
    // real users — not just adb-equipped developers — can contribute the ground-truth material the
    // puffin biometric decode needs. Gated on PuffinExperiment.isCaptureEnabled (default OFF); APPENDS
    // across sessions with per-session ids (his fork truncated per session, losing overnight data);
    // rotates at the cap; fail-soft — capture can never break the sync it observes.

    @Volatile private var captureWriter: java.io.BufferedWriter? = null
    @Volatile private var captureDisabled = false
    @Volatile private var captureLines = 0
    private var captureSessionId = ""
    private val captureSummary = BackfillCaptureSummary()

    private fun startWhoop5BackfillCapture() {
        if (captureWriter != null || captureDisabled) return
        runCatching {
            val f = java.io.File(context.filesDir, WHOOP5_CAPTURE_FILE)
            // Rotate at the cap: keep one previous generation, then start fresh.
            if (f.exists() && f.length() > WHOOP5_CAPTURE_MAX_BYTES) {
                val old = java.io.File(context.filesDir, "$WHOOP5_CAPTURE_FILE.1")
                old.delete()
                f.renameTo(old)
            }
            captureWriter = java.io.BufferedWriter(java.io.FileWriter(f, true))
            captureLines = 0
            captureSessionId = "whoop5-${System.currentTimeMillis()}"
            captureSummary.reset()
            log("Capture: 5/MG backfill capture started ($captureSessionId)")
        }.onFailure {
            captureDisabled = true
            log("Capture: could not open capture file (${it.message}) — capture disabled")
        }
    }

    private fun writeWhoop5BackfillCapture(characteristic: String, frame: ByteArray) {
        val w = captureWriter ?: return
        runCatching {
            val parsed = Framing.parseFrame(frame, connectedFamily)
            captureSummary.record(parsed.typeName, parsed.crcOk, frame.size, characteristic, frame.toHex())
            val line = BackfillCaptureJsonl.encode(
                BackfillCaptureRecord(
                    capturedAtMs = System.currentTimeMillis(),
                    sessionId = captureSessionId,
                    characteristic = characteristic,
                    typeName = parsed.typeName,
                    crcOk = parsed.crcOk,
                    offload = isOffloadFrame(frame, connectedFamily),
                    size = frame.size,
                    parsed = parsed.parsed,
                    hex = frame.toHex(),
                ),
            )
            synchronized(w) {
                w.write(line)
                w.newLine()
                if (++captureLines % 100 == 0) w.flush()
            }
            if (captureLines >= WHOOP5_CAPTURE_MAX_LINES) {
                log("Capture: line cap reached — capture paused until next session")
                closeWhoop5BackfillCapture(flushSummary = false)
            }
        }.onFailure {
            captureDisabled = true
            closeWhoop5BackfillCapture(flushSummary = false)
            log("Capture: write failed (${it.message}) — capture disabled")
        }
    }

    private fun closeWhoop5BackfillCapture(flushSummary: Boolean) {
        val w = captureWriter ?: return
        captureWriter = null
        runCatching { synchronized(w) { w.flush(); w.close() } }
        if (flushSummary) {
            log("Capture: session frame counts — ${captureSummary.countsText()}")
            val unknown = captureSummary.unknownSamplesText()
            if (unknown != "none") log("Capture: UNKNOWN type samples — $unknown")
        }
    }

    private fun log(s: String) {
        // A diagnostic log line must NEVER be able to crash the app. log() runs on the GATT binder
        // thread and from the background reconnect service, so an uncaught throw here takes the WHOLE
        // process down — which is exactly what happened in #453: a redaction-regex bug crashed the
        // app on every Bluetooth-on reconnect, even when it was closed. Belt-and-suspenders: nothing
        // in here may propagate. (The regex bug itself is also fixed; this guarantees the class can't
        // recur.)
        try {
            // Scrub personal identifiers FIRST so a user can safely share the strap log (#445).
            val safe = redactPii(s)
            // logcat is opt-in (Settings → Strap → "Debug logging"); default OFF so normal users don't
            // emit the strap log to the system log. The in-app ring buffer below always records.
            if (debugLogcat) Log.d(TAG, safe)
            // Mirror into the in-app ring buffer (format under the lock — SimpleDateFormat isn't
            // thread-safe and log() is called from both the GATT binder thread and the main looper).
            synchronized(logBuffer) {
                logBuffer.addLast("${logTimeFmt.format(System.currentTimeMillis())}  $safe")
                while (logBuffer.size > LOG_BUFFER_MAX) logBuffer.removeFirst()
            }
        } catch (t: Throwable) {
            // Last resort: note that a log line failed, without risking another throw. Never rethrow.
            runCatching {
                synchronized(logBuffer) {
                    logBuffer.addLast("[log error: ${t.javaClass.simpleName}]")
                    while (logBuffer.size > LOG_BUFFER_MAX) logBuffer.removeFirst()
                }
            }
        }
    }

    /** Scrub personal identifiers from a strap-log line so it's safe to share publicly (#445, @maddognik):
     *  BLE MAC addresses are masked to their first + last byte, and the WHOOP's SERIAL — carried in its
     *  device name ("WHOOP 4C1594026") and tied to the owner's account — is removed. Applied at the single
     *  log sink so EVERY line is covered, including the generic-HR diagnostics. MACs require colons, so hex
     *  command payloads (no colons) are untouched; the model names "WHOOP 4.0"/"5.0" (dotted, short) don't
     *  match the serial pattern. */
    private fun redactPii(s: String): String = redactStrapLogPii(s)

    /**
     * Write a line into the SAME in-app strap-log ring buffer the user exports via [exportLogText],
     * from an ISOLATED BLE source (e.g. [StandardHrSource]) that must never import or share state with
     * this client. The coordinator injects this as a closure so generic-HR lifecycle lines land in the
     * one log the user copies for a bug report. (Issue #421 — the generic-HR path used to be invisible.)
     */
    fun externalLog(s: String) { log(s) }

    /** Snapshot of the recent strap log, newest last, for the "Share strap log" diagnostics export. */
    fun exportLogText(): String = synchronized(logBuffer) { logBuffer.joinToString("\n") }
}

// PII scrubbers for the shareable strap log (#445). Kept at FILE scope (not inside WhoopBleClient) so
// they're unit-testable without constructing the Android-only BLE client.
//
//   • MAC: keep the first + LAST octet, mask the four unique middle octets. The regex captures exactly
//     TWO groups — group 1 (first octet) and group 2 (last octet) — so the replacement must reference
//     $1 and $2. (#421: this previously referenced `$3`, which doesn't exist, so the moment any RAW MAC
//     was logged — e.g. a generic-HR strap's `device.address` in StandardHrSource.connectToDevice — the
//     replace() threw IndexOutOfBoundsException("No group 3"), and the thrown exception aborted that
//     strap's activation. The WHOOP path never hit it because it only ever logs "WHOOP <serial>", never
//     a raw MAC, so the bug was invisible until a Polar H10 / other 0x180D strap was used.)
//   • WHOOP serial: the device name carries it ("WHOOP 4C1594026"); the dotted model names ("WHOOP 4.0")
//     are too short / dotted to match.
private val PII_MAC_RE = Regex("([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})")
private val PII_WHOOP_SERIAL_RE = Regex("WHOOP (\\d[0-9A-Za-z]{5,})")

/** Mask MAC addresses and WHOOP serials in a strap-log line before it's shown/exported.
 *  TOTAL — never throws: a redaction failure returns a safe placeholder rather than leaking the raw
 *  line or crashing the caller (#453). The MAC regex captures exactly two groups (first + last octet),
 *  so the replacement references $1/$2 only. */
internal fun redactStrapLogPii(s: String): String = try {
    s.replace(PII_MAC_RE, "$1:••:••:••:••:$2")
        .replace(PII_WHOOP_SERIAL_RE, "WHOOP <serial>")
} catch (t: Throwable) {
    "[redaction error — line withheld]"
}
