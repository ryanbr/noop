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
import android.os.SystemClock
import android.util.Log
import com.noop.data.HrRow
import com.noop.data.RrRow
import com.noop.data.StreamBatch
import com.noop.data.RawImuSampleEntity
import com.noop.data.StreamPersistence
import com.noop.protocol.Whoop5RawImu
import com.noop.data.WhoopRepository
import com.noop.protocol.AlarmPayload
import com.noop.protocol.DYN_ACCEL_STILL_THRESHOLD_G
import com.noop.protocol.BackfillCaptureJsonl
import com.noop.protocol.BackfillCaptureRecord
import com.noop.protocol.BackfillCaptureSummary
import com.noop.protocol.CommandNumber
import com.noop.protocol.FeatureFlagWriteGate
import com.noop.protocol.R22DisableReport
import com.noop.protocol.DeviceFamily
import com.noop.protocol.DeviceConfigReadProbe
import com.noop.protocol.DeviceConfigReadProbeReport
import com.noop.protocol.FeatureFlagProbe
import com.noop.protocol.FeatureFlagProbeReport
import com.noop.protocol.Framing
import com.noop.protocol.HapticClock
import com.noop.protocol.Reassembler
import com.noop.protocol.Whoop5Variant
import com.noop.protocol.RebootProbeVariant
import com.noop.protocol.Streams
import com.noop.protocol.Whoop5Config
import com.noop.protocol.extractStreams
import com.noop.protocol.WhoopGattServiceFamily
import com.noop.protocol.whoopGattScanDecision
import com.noop.analytics.Baselines
import com.noop.analytics.BatterySocLine
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.NapDetector
import com.noop.analytics.NapPrefs
import com.noop.analytics.NapVerdict
import com.noop.analytics.SedentaryDetector
import com.noop.analytics.StressOnsetDetector
import com.noop.analytics.UserProfile
import com.noop.analytics.WorkoutDetector
import com.noop.data.NapStore
import com.noop.ingest.HealthConnectWriter
import com.noop.notif.InactivityNotifier
import com.noop.ui.BiofeedbackPrefs
import com.noop.ui.HrvWindow
import com.noop.ui.InactivityPrefs
import com.noop.ui.NoopPrefs
import com.noop.ui.NotifPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.StressNudgeCenter
import com.noop.ui.UnitPrefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger

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
    /** True ONLY when a non-WHOOP live source (currently the Oura ring) is actively streaming live HR.
     *  This is the green "streaming" signal for sources with no WHOOP-style encrypted bond: it is
     *  DELIBERATELY separate from [bonded], which carries WHOOP encrypted-bond + buzz semantics (it gates
     *  haptics) and must NOT be set by the Oura path. The owning source sets it true in its streaming
     *  branch and false at every teardown. Twin of macOS LiveState.streamingLiveHR (#903). */
    val streamingLiveHR: Boolean = false,
    val heartRate: Int? = null,
    val rr: List<Int> = emptyList(),
    /** Rolling UI buffer of recent R-R intervals (capped, oldest dropped first). The standard BLE HR
     *  notification usually carries only one or two intervals per packet, so the Live console needs a
     *  short history to render a moving R-R strip / rolling RMSSD. Appended (never replaced) via
     *  [withRRIntervals]; emptied by [clearedBiometrics]. Twin of macOS LiveState.rrRecent (PR#191). */
    val rrRecent: List<Int> = emptyList(),
    val batteryPct: Double? = null,
    /** Strap battery pack VOLTAGE (mV), decoded from the ~8-min BATTERY_LEVEL event (mv@21/@25) and the
     *  GET_EXTENDED_BATTERY_INFO response (#592). Shown on the Devices card as a "x.xx V" readout beside
     *  the percent. null until the first battery event lands. */
    val batteryMv: Int? = null,
    /** Strap firmware version captured during the connect handshake: WHOOP 4.0 reports `fw_harvard`
     *  (a.b.c.d) via REPORT_VERSION_INFO, WHOOP 5/MG reports `fw_version` via GET_HELLO. Shown on the
     *  Devices card. Null until the handshake response decodes. The Swift WhoopProtocol decodes the
     *  same fields; this is the Android send → state → UI wiring. */
    val strapFirmware: String? = null,
    /** Historical record layout version (`hist_version`, e.g. v24/v25 on WHOOP 4.0) observed from the
     *  active connection's backfill. This is distinct from [strapFirmware]: FW 41.17.6.0 is the strap
     *  firmware build, while v24/v25 is the binary layout used by banked history records. */
    val historyLayoutVersion: Int? = null,
    /** True while a user-initiated reboot (#166) is in flight — from sending REBOOT_STRAP until the strap
     *  reconnects (or the settle timeout gives up). With `!connected` it drives the Devices card's
     *  transient "Reconnecting…" pill. Twin of macOS LiveState.rebootInProgress. */
    val rebootInProgress: Boolean = false,
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
    /** Set when a WHOOP 5/MG strap keeps REFUSING the encrypted bond on connect (the strap is still
     *  bonded to the official WHOOP app, so a fresh just-works bond can't start). Carries concrete
     *  pairing-mode guidance; published once the refusal streak reaches two and cleared on a genuine
     *  bond or a fresh user-initiated connect. Parity with macOS LiveState.pairingHint (#78). The same
     *  text is mirrored into [statusNote] so the existing Live status surface shows it with no UI change. */
    val pairingHint: String? = null,
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
    /** #580: TRUE when a connected WHOOP 5/MG is streaming live HR fine but its firmware hands over NO
     *  history offload (it acks SEND_HISTORICAL_DATA but emits zero type-0x2F frames). The home/Settings
     *  surface then reads "connected, history sync experimental on 5.0" instead of a sync error, and the
     *  120s liveness bounce backs off so a healthy link isn't disconnected/rescanned every ~2 min. Set
     *  once empty offloads are SUSTAINED; cleared on connect or once the strap banks real records. Twin of
     *  macOS LiveState.historySyncExperimental. */
    val historySyncExperimental: Boolean = false,
    /** #612: TRUE when the WHOOP-4/generic empty-offload streak ([emptySyncTracker]) is currently
     *  SUSTAINED (3+ consecutive completed-but-empty offloads). Not 5/MG-specific and not coupled to HR:
     *  a connected strap that keeps handing over nothing has this true regardless of live-HR status.
     *  Cleared on disconnect; re-derived from the next offload. Twin of macOS LiveState.sustainedEmptyOffload. */
    val sustainedEmptyOffload: Boolean = false,
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
    fun clearedBiometrics(): LiveState = copy(heartRate = null, rr = emptyList(), rrRecent = emptyList(),
                                              streamingLiveHR = false)   // #56: a dropped link is no longer streaming
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
 *   3. onConnectionStateChange(CONNECTED) — request MTU, allow the GATT operation to settle, then
 *      `discoverServices` (didConnect → discoverServices).
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
    /** Request a GATT connection priority (battery, #477). Mirrors `BluetoothGatt`'s boolean contract;
     *  the stack no-ops a request equal to the current interval. */
    fun requestConnectionPriorityCompat(priority: Int): Boolean

    /** Ask the controller to prefer a PHY for this link (#533). Mirrors `BluetoothGatt.setPreferredPhy`,
     *  which is VOID and fire-and-forget: the real outcome arrives on `onPhyUpdate`, and the peer can
     *  decline. Masks (not single values) so the controller may fall back. API 26 = our minSdk. */
    fun setPreferredPhyCompat(txPhy: Int, rxPhy: Int, phyOptions: Int)
}

/**
 * Production [GattOps]: a straight delegate to a live [BluetoothGatt]. The TIRAMISU+/legacy branch
 * for the value-bearing write/descriptor calls lives here (one place) so the client call sites read
 * uniformly. Permission is owned by the caller (the client is @SuppressLint("MissingPermission")).
 */
@SuppressLint("MissingPermission")
class RealGattOps(private val gatt: BluetoothGatt) : GattOps {

    /**
     * #791: the raw status of the most recent Android 13+ write, kept because the `Boolean` contract throws
     * away WHY the stack refused — and that "why" is the open question.
     *
     * A reporter on a Galaxy S24 saw one `GET_DATA_RANGE` produce THREE CRC-valid responses with consecutive
     * strap-side sequence numbers, every time correlating with a burst of busy-retries, and single responses
     * on ticks with no retries. That means a write the stack reported as refused had in fact been delivered,
     * and the retry duplicated it. `ERROR_GATT_WRITE_REQUEST_BUSY` is documented as "not initiated", so
     * either this stack returns it while still delivering, or it is returning something else entirely. The
     * code distinguishes those, and nothing was recording it.
     *
     * Null on pre-TIRAMISU, where the legacy API only ever returned a Boolean.
     */
    @Volatile
    var lastWriteStatus: Int? = null
        private set

    override fun writeCharacteristicCompat(
        ch: BluetoothGattCharacteristic,
        value: ByteArray,
        writeType: Int,
    ): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = gatt.writeCharacteristic(ch, value, writeType)
            lastWriteStatus = status
            status == BluetoothGatt.GATT_SUCCESS
        } else {
            lastWriteStatus = null
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
    override fun requestConnectionPriorityCompat(priority: Int): Boolean = gatt.requestConnectionPriority(priority)
    override fun setPreferredPhyCompat(txPhy: Int, rxPhy: Int, phyOptions: Int) =
        gatt.setPreferredPhy(txPhy, rxPhy, phyOptions)
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

        // Standard Device Information Service — READ-ONLY. Used only to tell a WHOOP MG apart from a
        // plain 5.0 (#520); [Whoop5Variant] resolves the serial prefix + hardware-revision string.
        // Never written, never subscribed. A WHOOP 4.0 never reads these (see readDisIdentity).
        private val DIS_SERVICE: UUID = UUID.fromString("0000180a-0000-1000-8000-00805f9b34fb")
        private val DIS_SERIAL_CHAR: UUID = UUID.fromString("00002a25-0000-1000-8000-00805f9b34fb")
        private val DIS_HW_REV_CHAR: UUID = UUID.fromString("00002a27-0000-1000-8000-00805f9b34fb")

        // Client Characteristic Configuration Descriptor — written to enable notifications
        // (CoreBluetooth does this implicitly via setNotifyValue; Android requires the explicit write).
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Fixed rescan delay for the firmware-reset / stale-OS-bond re-pair path ONLY — that path
         *  deliberately KEEPS scanning at a steady 3s so a fresh re-pair is picked up promptly, so it
         *  stays un-backed-off. The ordinary involuntary-reconnect paths use the capped-exponential
         *  [ReconnectBackoff] instead (#48). (BLEManager: "rescanning in 3s".) */
        private const val RECONNECT_DELAY_MS = 3_000L
        /** PR #588: after this many CONSECUTIVE involuntary reconnect attempts, drop the scan from the
         *  battery-hungry LOW_LATENCY mode to a lower-power mode. A strap that's genuinely out of range
         *  (left at home, dead battery) would otherwise hold the radio at full power indefinitely while
         *  the capped-exponential [ReconnectBackoff] still fires a scan every up-to-60s. The first few
         *  reconnects stay snappy (LOW_LATENCY) for the common quick-blip drop; only a sustained streak
         *  backs off. A user-driven Connect resets [failedReconnectAttempts] to 0, so the wizard / a manual
         *  reconnect always scans at LOW_LATENCY. */
        const val SCAN_POWER_BACKOFF_THRESHOLD = 6

        /** Pure scan-mode decision (PR #588), unit-testable without a BLE stack. An INVOLUNTARY reconnect
         *  scan past [SCAN_POWER_BACKOFF_THRESHOLD] consecutive attempts uses the lower-power BALANCED
         *  mode; everything below that — and EVERY user-initiated connect, where the streak is 0 — stays
         *  on LOW_LATENCY. The Add-a-WHOOP wizard's present-scan never calls this (it's hard-wired
         *  LOW_LATENCY for a snappy wizard). */
        fun scanModeForReconnectAttempts(attempts: Int): Int =
            if (attempts >= SCAN_POWER_BACKOFF_THRESHOLD) ScanSettings.SCAN_MODE_BALANCED
            else ScanSettings.SCAN_MODE_LOW_LATENCY

        /** #313: escalate a reconnect to PASSIVE (autoConnect=true) by WHY the link is down, not just the
         *  attempt count. A strap the OS still holds ACL-connected — co-resident with the official WHOOP
         *  app — never re-emits the advertisement / connection-complete that autoConnect waits for, so
         *  PASSIVE STALLS it (frozen keep-alive battery poll + stopped offload) no matter how high the
         *  attempt count climbs; only fast DIRECT reconnect recovers it. So keep an ACL-held band on DIRECT;
         *  only a genuinely-out-of-range band (not ACL-held) falls back to PASSIVE past [threshold], where
         *  autoConnect is the correct power-efficient choice (#61). This replaces the old plain
         *  `failedAttempts >= 3` — which #265 kept alive only because a co-resident band usually flaps
         *  through STATE_CONNECTED and zeroes the counter; a band that fails BEFORE STATE_CONNECTED for
         *  [threshold]+ attempts hit the same stall. Pure, so the discrimination is pinned without a BLE
         *  stack (the [scanModeForReconnectAttempts] idiom). */
        fun passiveReconnectDecision(failedAttempts: Int, aclHeld: Boolean, threshold: Int = 3): Boolean =
            failedAttempts >= threshold && !aclHeld

        /** Pure GATT connection-priority decision (battery, #477), unit-testable without a BLE stack
         *  (the [scanModeForReconnectAttempts] idiom). TWO independent halves, split by risk:
         *   - SAFE (always, once management is on): escalate to HIGH during an offload burst or a
         *     live-HR session. HIGH is a SHORTER interval than BALANCED, so it CANNOT cause a
         *     supervision-timeout drop (it makes the link more robust, not less) and it shortens the
         *     radio-on window - faster sync, net battery win.
         *   - RISKY ([idleThrottleEnabled], default OFF): when idle, drop to LOW_POWER (a LONGER
         *     interval - the real all-day saving, but a too-long interval can drop the link, so it is
         *     opt-in and must be validated on a real strap, #477). When off, idle stays BALANCED -
         *     byte-for-byte today's default.
         *  Android-only by necessity: CoreBluetooth exposes no app-side connection-priority equivalent
         *  (the peripheral proposes the GAP connection parameters, iOS negotiates), so there is no Swift
         *  twin — a deliberate platform divergence, not a parity gap (#477). */
        fun connectionPriorityFor(
            offloadActive: Boolean,
            liveHrActive: Boolean,
            idleThrottleEnabled: Boolean,
        ): Int = when {
            offloadActive || liveHrActive -> BluetoothGatt.CONNECTION_PRIORITY_HIGH
            idleThrottleEnabled -> BluetoothGatt.CONNECTION_PRIORITY_LOW_POWER
            else -> BluetoothGatt.CONNECTION_PRIORITY_BALANCED
        }

        /**
         * The throughput summary for one offload burst (#1007), pure so it is testable without a BLE stack.
         *
         * #477 and #533 ship two levers that should shorten the offload — CONNECTION_PRIORITY_HIGH for the
         * burst, and LE 2M around it — and both default OFF, gated on validation against a real strap. That
         * validation never happened, and this is why: nothing measured the thing they change. The figures in
         * #1007 had to be counted by hand out of a raw capture ("3193 frames / 90 s"), which is not something
         * a reporter can be asked to do twice.
         *
         * Frames rather than records: [offloadFramesThisSession] counts genuine offload frames (47/48/49/50),
         * which is what the levers actually move, and is the same numerator #1007 measured. A non-positive
         * elapsed yields the count WITHOUT a rate rather than a fabricated one. Locale-fixed so a decimal
         * comma cannot follow the phone language into a log someone pastes into an issue.
         */
        fun offloadThroughputLine(frames: Int, elapsedMs: Long): String =
            if (elapsedMs <= 0L) "$frames frame(s)"
            else "%d frame(s) in %.1fs (%.1f frame/s)".format(
                java.util.Locale.US, frames, elapsedMs / 1000.0, frames * 1000.0 / elapsedMs)

        /**
         * The `reason=` token for a connection-down trace line (#1020), pure so the composition is
         * unit-testable without a BLE stack.
         *
         * A local teardown arrives as GATT status 22 and used to print the bare `localTerminate`, which
         * five different paths of ours produce. [localTeardownOrigin] names which one; `unknown` when the
         * drop was local but no path claimed it, which is itself worth seeing — it means a teardown route
         * exists that is not tagged.
         */
        fun connectionDownReason(status: Int, localTeardownOrigin: String?): String = when (status) {
            GATT_CONN_TIMEOUT -> "connectionTimeout"
            GATT_CONN_TERMINATE_LOCAL_HOST -> "localTerminate via=${localTeardownOrigin ?: "unknown"}"
            else -> "status$status"
        }

        /** Pure battery-adaptive gate (#477), unit-testable without a BLE stack. Keyed on the STRAP's
         *  battery (WHOOP/Oura/Fitbit): the lever is ARMED by [thresholdPct] > 0 and engages while the
         *  strap is DISCHARGING at/below [thresholdPct]. The
         *  phone's own Battery Saver deliberately does NOT trigger it — power saving is about the strap's
         *  charge, not the phone's. A charging strap never throttles. The threshold is its own hysteresis
         *  (battery % moves slowly, so a boundary crossing flips at most once per point). */
        fun idleThrottleActive(batteryPct: Int, charging: Boolean, thresholdPct: Int): Boolean =
            thresholdPct > 0 && !charging && batteryPct <= thresholdPct

        /** #533: whether flipping an experimental link lever from [wasEnabled] to [nowEnabled] must RELEASE
         *  what it changed. Shared by BOTH levers — the connection-priority escalation and the 2M PHY
         *  preference — hence the neutral name; each applies its own release.
         *
         *  ONLY the on→off edge does: both apply-paths early-return once disabled, so without an explicit
         *  release a link left pinned at HIGH (or at 2M) would stay there until the next reconnect — and a
         *  user switching an experiment off *because* it hurt would keep paying for it. Enabling, or
         *  re-applying while already off (every launch on the default), must issue no request at all. */
        fun releasesOnDisable(wasEnabled: Boolean, nowEnabled: Boolean): Boolean =
            wasEnabled && !nowEnabled

        /** #533: the PHY mask to ask the controller for. NOOP has never called `setPreferredPhy`, so every
         *  offload has run on the 1M PHY. LE 2M doubles the symbol rate, which for a bulk transfer means the
         *  SAME bytes spend HALF the air-time — unlike the connection-interval lever above it should cost
         *  LESS radio energy per byte, not more. The two are orthogonal and stack.
         *
         *  Always a MASK INCLUDING 1M, never 2M alone: this is a preference, and leaving 1M in it lets the
         *  controller fall back rather than cling to a 2M link that has gone marginal (2M trades range for
         *  speed). Off → plain 1M, byte-for-byte today's link. The peer still has the final say, and
         *  `onPhyUpdate` reports what was actually negotiated.
         *
         *  Android-only by necessity, exactly like [connectionPriorityFor]: CoreBluetooth exposes no
         *  app-side PHY API — Apple's stack negotiates the PHY itself and gives apps no say — so there is
         *  no Swift twin. A deliberate platform divergence, not a parity gap. (It also makes iOS/macOS a
         *  useful control: their link parameters are chosen for them, so a Mac draining a backlog faster
         *  than Android would show the strap is not the bottleneck.) */
        fun preferredPhyMask(fastLinkEnabled: Boolean): Int =
            if (fastLinkEnabled) BluetoothDevice.PHY_LE_1M_MASK or BluetoothDevice.PHY_LE_2M_MASK
            else BluetoothDevice.PHY_LE_1M_MASK

        /** Human-readable PHY for the strap log (#533). `onPhyUpdate` reports a PHY_LE_* VALUE (1/2/3),
         *  not the *_MASK constants used to request one — don't compare the two. */
        fun phyLabel(phy: Int): String = when (phy) {
            BluetoothDevice.PHY_LE_1M -> "1M"
            BluetoothDevice.PHY_LE_2M -> "2M"
            BluetoothDevice.PHY_LE_CODED -> "coded"
            else -> "unknown($phy)"
        }

        /** Stretched periodic-offload interval while the STRAP is low on battery (#477). The offload tick
         *  is a PURE sync timer (the live-stream keep-alive is separate), so stretching it can't affect
         *  link health — worst case is data arriving in slightly larger batches; the strap banks
         *  everything to flash meanwhile, so no data is lost. Left at [LOW_BATTERY_BACKFILL_INTERVAL_MS]
         *  while DISCHARGING at/below [thresholdPct], else the normal [baseMs]. Pure, unit-testable. */
        fun offloadIntervalMsFor(
            baseMs: Long,
            lowBatteryMs: Long,
            batteryPct: Int,
            charging: Boolean,
            thresholdPct: Int,
        ): Long = if (idleThrottleActive(batteryPct, charging, thresholdPct)) maxOf(baseMs, lowBatteryMs) else baseMs

        /** #battery: pure periodic-offload interval for a 5/MG whose history is known-empty, unit-testable
         *  without a BLE stack. Stretches to the low-battery floor (45 min) regardless of battery %, because
         *  an experimental-history 5/MG banks nothing per pass. Stacks with the BackfillPolicy empty-backoff
         *  (which engages one cycle later, at 3 empties). Twin of iOS `BLEManager.whoop5EmptyHistoryBackfillInterval`. */
        fun whoop5EmptyHistoryBackfillIntervalMs(baseMs: Long, lowBatteryMs: Long, historyEmpty: Boolean): Long =
            if (historyEmpty) maxOf(baseMs, lowBatteryMs) else baseMs

        /** Pure keep/teardown decision for [prepareForPresentScan] (#74), unit-testable without a BLE
         *  stack (the [scanModeForReconnectAttempts] idiom). Keep the live link ONLY when one exists AND
         *  the wizard is scanning the SAME model; Android [WhoopModel] has exactly two members (one per
         *  family), so enum equality IS the family check - do not invent a deviceFamily accessor. */
        fun shouldKeepLiveConnectionForPresentScan(
            connected: Boolean,
            selected: WhoopModel,
            requested: WhoopModel,
        ): Boolean = connected && selected == requested

        /** Minimum time since the bond-loop pause tripped (or since the last probe) before another
         *  salvage probe may fire (#78 hole-4). 10 minutes: long enough that a still-held strap sees a
         *  handful of bounded attempts per day, short enough that a strap the user freed reconnects on
         *  the next natural app open. Twin of iOS `BLEManager.bondLoopSalvageFloorSeconds`. */
        const val BOND_LOOP_SALVAGE_FLOOR_MS = 10L * 60_000L

        /** Pure gate for the one-shot bond-loop salvage probe (#78 hole-4): probe ONLY while the pause is
         *  latched, with no live link, no user teardown in force, and at least
         *  [BOND_LOOP_SALVAGE_FLOOR_MS] since the pause tripped (or since the previous probe re-stamped
         *  it). null ms = no trip timestamp = never probe. Pure so the never-hammer contract is pinned by
         *  unit tests. Twin of iOS `BLEManager.shouldSalvageProbe`. */
        fun shouldSalvageProbe(
            pausedForBondLoop: Boolean,
            connected: Boolean,
            intentionalDisconnect: Boolean,
            msSincePauseTripped: Long?,
        ): Boolean = pausedForBondLoop && !connected && !intentionalDisconnect &&
            msSincePauseTripped != null && msSincePauseTripped >= BOND_LOOP_SALVAGE_FLOOR_MS

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
        /** #477 battery: stretched offload cadence while low on battery (45 min). The strap banks to flash
         *  meanwhile, so this only delays sync (larger batches), never loses data. Gated on the discharging
         *  battery-% threshold; 0 = disabled → always [BACKFILL_INTERVAL_MS]. */
        private const val LOW_BATTERY_BACKFILL_INTERVAL_MS = 2_700_000L
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
        /** Fixed delay between the MTU attempt and service discovery. onMtuChanged can come from the
         *  connection itself or requestMtu, with no provenance bit, so it cannot safely end this wait. */
        private const val MTU_DISCOVERY_SETTLE_MS = 1_500L
        /** BASE bonded-handshake watchdog window (#50): if no genuine bond lands within this of service
         *  discovery starting, bounce the link rather than sit forever in "finishing secure handshake"
         *  (OnePlus Nord 2 wedged the post-discovery bond/CCCD phase, which had no timeout). 7s comfortably
         *  spans the MTU exchange → discovery → CCCD drain → confirmed bond write on a healthy link. #971:
         *  this is now just the FIRST window — [bondWatchdogBackoff] escalates it per consecutive bounce so
         *  a slower-but-healthy WHOOP 4.0 handshake gets more time before being bounced again. */
        private const val BOND_WATCHDOG_MS = 7_000L
        /** OnePlus-only settle delay before the FIRST CCCD descriptor write after service discovery
         *  (#50). The OnePlus Nord 2 GATT stack needs a beat to settle post-discovery; writing the first
         *  descriptor immediately races the still-unsettled stack and the subscribe returns BUSY. ~450ms
         *  is well within the 7s bond watchdog, so it can't cause a bounce. */
        private const val ONEPLUS_CCCD_SETTLE_MS = 450L
        /** Dedup window for a spurious duplicate onMtuChanged (#50): a second callback with the SAME mtu
         *  arriving within this of the first is the OnePlus double-MTU bug and is ignored. */
        private const val DUPLICATE_MTU_WINDOW_MS = 1_000L

        /** ATT error codes the GATT stack surfaces as `status` when a strap refuses the encrypted bond —
         *  the Android analogue of CoreBluetooth's "Encryption/Authentication is insufficient" error the
         *  iOS #52 path keys on. Equal to BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION/_ENCRYPTION;
         *  pinned here as raw values because the underlying ATT codes are what some stacks pass through. */
        private const val GATT_INSUFFICIENT_AUTHENTICATION = 5    // BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION
        private const val GATT_INSUFFICIENT_ENCRYPTION = 15       // BluetoothGatt.GATT_INSUFFICIENT_ENCRYPTION
        /** GATT disconnect `status` for a link-supervision/connection timeout — the Android analogue of
         *  CoreBluetooth's `CBError.connectionTimeout` that the iOS #617 bond-loop detector keys on. The
         *  stack's `GATT_CONN_TIMEOUT` (HCI 0x08). Pinned as a raw value (no public BluetoothGatt const). */
        private const val GATT_CONN_TIMEOUT = 0x08               // GATT_CONN_TIMEOUT (HCI link-supervision timeout)
        /** GATT disconnect `status` when the LOCAL host tears the link down — what the stack reports for our
         *  own `gatt.disconnect()`, including the #50/#971 bond-watchdog bounce. 22 / 0x16
         *  (GATT_CONN_TERMINATE_LOCAL_HOST). Distinct from [GATT_CONN_TIMEOUT] (0x08, the strap/link timing
         *  out): a bounce we initiated must NOT be mistaken for the #617 loop's remote timeout. */
        private const val GATT_CONN_TERMINATE_LOCAL_HOST = 0x16  // GATT_CONN_TERMINATE_LOCAL_HOST (local host ended it)

        /**
         * #982: should this involuntary disconnect feed the #971 bond-watchdog give-up counter? A WHOOP 4.0
         * that reaches STATE_CONNECTED and subscribes but never lands a genuine bond can self-drop (status 0)
         * at ~7s, BEFORE the escalating bond watchdog fires — so [onBondWatchdog]'s recordBounce (which only
         * runs when OUR OWN gatt.disconnect reports GATT_CONN_TERMINATE_LOCAL_HOST) never runs, and the #617
         * [PostBondTimeoutLoopDetector] skips it (never bonded, and status != GATT_CONN_TIMEOUT). Neither
         * give-up counter advances while STATE_CONNECTED keeps zeroing the reconnect backoff, so the connect →
         * subscribe → drop loop runs unbounded and drains the battery (#982). Pulled out as a pure function so
         * the gate is unit-testable without a BLE seam (same shape as [BondWatchdogBackoff]).
         *
         * True ONLY for that case: the link reached STATE_CONNECTED ([wasConnected]) but never bonded
         * ([didBond] false), the drop was involuntary (not [intentionalDisconnect]), it was not the
         * stale-direct-bond scan-fallback ([staleDirectBond]), it was not our OWN localTerminate bounce
         * (already counted by [onBondWatchdog]), and we are not already paused. A healthy strap that bonds on
         * the first connect has didBond == true, so it is never counted and its behaviour is unchanged.
         */
        internal fun shouldCountNeverBondedSelfDrop(
            wasConnected: Boolean,
            didBond: Boolean,
            intentionalDisconnect: Boolean,
            staleDirectBond: Boolean,
            status: Int,
            alreadyPausedForBondLoop: Boolean,
        ): Boolean = wasConnected && !didBond && !intentionalDisconnect && !staleDirectBond &&
            status != GATT_CONN_TERMINATE_LOCAL_HOST && !alreadyPausedForBondLoop

        /** Pure guard for a delayed service-discovery kick. The operation belongs only to the exact
         *  connection that scheduled it, and a temporarily-missing GATT wrapper must not consume the
         *  once-only claim. Kept pure because local JVM tests cannot instantiate BluetoothGatt. */
        internal fun serviceDiscoveryAttemptAllowed(
            expectedGeneration: Int,
            currentGeneration: Int,
            isCurrentGatt: Boolean,
            connected: Boolean,
            hasGattOps: Boolean,
        ): Boolean = expectedGeneration == currentGeneration && isCurrentGatt && connected && hasGattOps

        /** Consecutive bond refusals on the pinned strap before handing the pin off to a different,
         *  live-bonding strap (#52). 3 (not 1): a single "insufficient" can be a transient just-works
         *  race; three in a row on the pin while ANOTHER strap bonds fine is an unrecoverable stale pin.
         *  Mirrors the iOS `pinBondRefusalLimit`. */
        private const val PIN_BOND_REFUSAL_LIMIT = 3

        /** Encrypted-bond refusals before the pairing hint shows (#78). 2 (not 1): a single "insufficient"
         *  can be a transient just-works race, but two in a row means the strap is genuinely still bonded
         *  to another app. Mirrors the iOS BLEManager streak>=2 gate. */
        private const val BOND_REFUSAL_HINT_THRESHOLD = 2

        /** Concrete pairing-mode guidance for a WHOOP 5/MG that keeps refusing the encrypted bond because
         *  it's still bonded to the official WHOOP app (#78). Plain, country-neutral wording; Android
         *  settings path. Parity with the macOS pairingHint text. */
        private const val PAIRING_HINT_TEXT =
            "Your WHOOP won't pair because it's still bonded to the official WHOOP app. To fix it: " +
                "1. Close the official WHOOP app (or turn off Bluetooth on that phone). " +
                "2. Hold or tap the band until its LEDs flash blue (pairing mode). " +
                "3. Open Settings > Bluetooth, find your WHOOP, and choose Forget This Device. " +
                "Then come back and tap Connect."

        /** 5/MG raw-capture file (app filesDir; shared via Settings → "Share 5/MG capture"). */
        const val WHOOP5_CAPTURE_FILE = "whoop5-backfill-capture.jsonl"
        const val WHOOP5_EVENT_LOG_FILE = "whoop5-events.jsonl"
        // EVENT frames are ~40–120 B of hex each, a few KB per day of wear — 5 MB is years.
        private const val WHOOP5_EVENT_LOG_MAX_BYTES = 5L * 1024 * 1024

        /** #1121 detailed-capture: opt-in rolling mirror of the strap log to an on-device file (adb-like,
         *  but no computer). Shared via Test Centre → "Share captured log". */
        const val CAPTURE_LOG_FILE = "noop-capture-log.txt"
        // ~8 MB current + one rolled generation (.1) ≈ a full day even through heavy offload bursts.
        private const val CAPTURE_LOG_MAX_BYTES = 8L * 1024 * 1024

        /** High-rate R22 deep-buffer research log (#423) — the big type-0x2F buffers (1244/2140 B) that
         *  carry tens-of-Hz motion/optical, kept raw in their own file so they survive long enough to
         *  reverse. The 2140-B buffers are ~4.3 KB of hex and arrive in bursts, so a bigger cap than the
         *  EVENT log: 60 MB live (~a few hours of accumulated bursts), rotation bounds disk at ~120 MB. */
        const val WHOOP5_DEEPBUFFER_FILE = "whoop5-deepbuffers.jsonl"
        private const val WHOOP5_DEEPBUFFER_MAX_BYTES = 60L * 1024 * 1024

        /** WHOOP 5/MG inner-record type byte for EVENT frames (type 48). The inner record starts at
         *  offset 8 ([type][seq][cmd][data…]) — the SAME position [isOffloadFrame]/R22-telemetry index
         *  and the Interpreter reads the canonical type name from. */
        const val WHOOP5_EVENT_TYPE = 0x30
        private const val WHOOP5_INNER_RECORD_OFFSET = 8

        /**
         * Pure predicate: is [frame] a WHOOP 5/MG EVENT (type 48 / 0x30) frame? A reassembled frame's
         * inner-record type byte sits at offset 8, so this needs `size > 8` before indexing. Extracted
         * from [writeWhoop5EventLogIfEvent] so the offset-8 magic number is unit-testable without a strap
         * (BLE paths otherwise have no test). Byte-identical to the Swift twin `PuffinEventLog.isEventFrame`.
         */
        fun isWhoop5EventFrame(frame: ByteArray): Boolean =
            frame.size > WHOOP5_INNER_RECORD_OFFSET &&
                (frame[WHOOP5_INNER_RECORD_OFFSET].toInt() and 0xFF) == WHOOP5_EVENT_TYPE
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
        /** Delay after the 5/MG connect handshake before the first battery read (0x2A19), so it does not
         *  race the clock writes on a slow stack while still populating the ring within a couple of seconds
         *  of connect. */
        private const val BATTERY_ON_CONNECT_DELAY_MS = 1_500L
        /** No inbound data for this long ⇒ the link/stream stalled; bounce it to resume streaming. */
        private const val KEEPALIVE_STALL_MS = 120_000L
        /** #580: longer stall fuse for a known history-empty 5/MG. Live HR over 0x2A37 keeps the link alive
         *  but can lull >120s (off-wrist / resting) while the empty offload leaves the data channel quiet,
         *  so the tight 120s rule bounced a healthy link every ~2 min. 10 min stops the thrash. */
        private const val KEEPALIVE_STALL_5MG_EMPTY_MS = 600_000L
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
         * The mirror gate for stopping one: an abort is only meaningful while an offload is actually
         * running. Pure for the same reason as [canRequestSync] — the menu's visibility and the
         * client's own guard must not drift apart, and neither needs a live GATT stack to test.
         *
         * Note it does NOT require [connected]. A user can abort a session whose link has already
         * dropped; there is simply no opcode to send, and the local teardown is the whole point.
         */
        fun canAbortSync(backfilling: Boolean): Boolean = backfilling

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
         * #312: when the write queue DROPS a frame after [MAX_WRITE_RETRIES] busy-retries, should the
         * realtime stream be re-armed? True ONLY for [CommandNumber.TOGGLE_REALTIME_HR] — that write enables
         * live R-R (→ HRV / Autonomic), and reconcileRealtime latched `realtimeArmed` optimistically when it
         * queued the write, so a silent drop leaves R-R off with no re-send (plain HR keeps flowing on the
         * standard 0x2A37 profile — the exact #312 symptom on a 5/MG whose toggle lost a GATT-write race).
         * Every other dropped frame (haptics, offload-ack, clock, …) has its own recovery and must NOT poke
         * the realtime latch. Pure + instance-free so the unit harness can pin it without a live GATT stack.
         */
        /**
         * #791: name an Android 13+ write-refusal code for the strap log.
         *
         * The distinction that matters is `ERROR_GATT_WRITE_REQUEST_BUSY` (201), documented as the write not
         * having been initiated and therefore safe to retry, versus anything else. A reporter's captures show
         * a refused write being delivered anyway and the retry duplicating it, so which code the stack
         * returned is the evidence that separates "safe retry" from "we just sent it twice".
         *
         * Literal codes rather than `BluetoothStatusCodes` constants: these are compile-time-inlined API 33
         * values, and spelling them out keeps this readable in a log review and buildable on any compileSdk.
         */
        /**
         * #791: may a write-completion callback cancel the BUSY-retry currently held?
         *
         * Yes exactly when a frame is held for retry and the completion is for a command-channel write. A
         * completion for a frame the stack claimed to refuse proves the refusal was wrong and the frame went
         * out, so repeating it delivers the same command to the strap twice — the reported symptom, where one
         * GET_DATA_RANGE drew three responses carrying one unchanged origin-seq echo.
         *
         * `pendingRetry` is non-null only when the most recent DRAINED write returned BUSY, and the drain
         * never starts a write while one is in flight — so within the drain there is no other outstanding
         * command-channel write this completion could belong to. A frame the stack truly refused produces no
         * completion at all, leaving its retry to fire, so the #77/#312 protection against a silently dropped
         * TOGGLE_REALTIME_HR / SET_CLOCK / offload-ack is untouched.
         *
         * [writeBondFrame] is the exception that forces the third argument: it writes to the same
         * characteristic DELIBERATELY outside the queue, so its completion is not evidence about the held
         * frame. Acting on it would cancel a retry for a frame that never went out — turning the duplicate
         * this fixes into the silent loss #77/#312 is about, which is strictly worse. Excluded explicitly.
         *
         * Only WITH-response writes reach here at all: a without-response write gets no completion callback
         * (the drain frees its own slot after a pacing gap), so this cannot help those. That happens to cover
         * the reported case and the commands where a duplicate actually harms — GET_DATA_RANGE, SET_CLOCK,
         * the historical acks, haptics and RUN_ALARM are all sent with response — but it is a real limit, not
         * a general guarantee.
         *
         * Pure so it can be tested: the instance-level path cannot be, since the constructor needs a real
         * Looper and Context (see [GattCrashSafetyTest]'s infra note).
         */
        fun shouldCancelBusyRetryOnCompletion(
            writtenChar: UUID?,
            hasFrameHeldForRetry: Boolean,
            isBondWriteCompletion: Boolean,
        ): Boolean =
            hasFrameHeldForRetry &&
                !isBondWriteCompletion &&
                (writtenChar == CMD_WRITE_CHAR || writtenChar == WHOOP5_CMD_WRITE_CHAR)

        fun writeStatusLabel(status: Int?): String = when (status) {
            null -> "status=n/a(legacy-api)"
            0 -> "status=SUCCESS(0)"          // BluetoothStatusCodes.SUCCESS — should not reach the busy path
            1 -> "status=ERROR_BLUETOOTH_NOT_ENABLED(1)"
            2 -> "status=ERROR_BLUETOOTH_NOT_ALLOWED(2)"
            3 -> "status=ERROR_DEVICE_NOT_BONDED(3)"
            6 -> "status=ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION(6)"
            9 -> "status=ERROR_PROFILE_SERVICE_NOT_BOUND(9)"
            200 -> "status=ERROR_GATT_WRITE_NOT_ALLOWED(200)"
            201 -> "status=ERROR_GATT_WRITE_REQUEST_BUSY(201)"
            else -> "status=$status"
        }

        fun shouldReArmRealtimeAfterDrop(droppedCmd: CommandNumber?): Boolean =
            droppedCmd == CommandNumber.TOGGLE_REALTIME_HR

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
                // Stale firmware/layout readouts must not outlive the dropped link.
                strapFirmware = null, historyLayoutVersion = null,
                // #580: the 5/MG "history experimental" note is per-link — a fresh connect re-derives it
                // from the next offload, so it must not outlive the dropped link.
                historySyncExperimental = false,
                // #612: the display flag only, not the underlying emptySyncTracker streak (that counter
                // deliberately survives a reconnect, unchanged existing behaviour).
                sustainedEmptyOffload = false,
            )

        /**
         * PR #568: should a BATTERY_LEVEL event drive the LIVE charging pill? The old code gated on a 45s
         * event-timestamp freshness window, which suppressed the bolt for the first ~45s of every connect
         * on a strap with a stale RTC. The only thing we must still exclude is a HISTORICAL BATTERY_LEVEL
         * replayed mid-backfill — i.e. an offload frame. So the rule is simply "not a replayed offload
         * frame", matching iOS, where the offload path never reaches the live router. Pure so it's
         * unit-testable without a live GATT stack.
         */
        fun shouldApplyChargingFromBatteryEvent(replayedOffload: Boolean): Boolean = !replayedOffload

        /**
         * PR #577: is this EVENT string a PHYSICAL GESTURE (double-tap / wrist on/off)? Gestures take the
         * freshness-gated gesture branch; everything else (BLE_BONDED, BATTERY_LEVEL, and crucially
         * STRAP_DRIVEN_ALARM_EXECUTED=57) takes the non-gesture branch. Pure so the routing can be tested
         * without a live GATT stack. Event strings are "NAME(rawValue)" (Schema.enumName), so prefix-match.
         */
        fun isGestureEvent(event: String): Boolean =
            event.startsWith("DOUBLE_TAP") ||
                event.startsWith("WRIST_ON") || event.startsWith("WRIST_OFF")

        /**
         * PR #577: should this EVENT fire the smart-alarm re-arm (onSmartAlarmFired)? True ONLY for a LIVE
         * STRAP_DRIVEN_ALARM_EXECUTED (event 57) — a HISTORICAL one replayed mid-backfill ([replayedOffload])
         * must not spuriously re-arm. Event 57 is NOT a gesture ([isGestureEvent] returns false for it), so it
         * is dispatched from the NON-gesture branch; the bug this fixes is a half-port that placed the case
         * inside the gesture `when`, where it could never fire. Pure → unit-testable without a live GATT.
         */
        fun smartAlarmFiredForEvent(event: String, replayedOffload: Boolean): Boolean =
            event.startsWith("STRAP_DRIVEN_ALARM_EXECUTED") && !replayedOffload

        /**
         * H3 (#520): the LiveState the device-remove RELEASE publishes — the link fully dropped + every
         * stale live readout cleared, so a removed strap can't keep showing live HR / a bond / a charging
         * pill. Pure model of what [releaseStrap] applies, so a test can assert the released state without a
         * live instance. Mirrors iOS forgetDevice's state clears.
         */
        fun releasedLiveState(previous: LiveState): LiveState =
            previous.clearedBiometrics().copy(
                connected = false, bonded = false, encryptedBond = false,
                charging = null, strapFirmware = null, historyLayoutVersion = null,
                pairingHint = null, scanning = false,
                statusNote = null,
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
        // #286 follow-up: delegate to the pure, twin-tested com.noop.protocol.DataRange (byte-identical to
        // Swift WhoopProtocol.DataRange) so this parity-critical read — it gates auto-sync via
        // isFutureDatedNewest → BackfillPolicy — is CI-pinned on BOTH platforms. Thin wrapper so existing
        // call sites + DataRangeScanTest are unchanged.
        fun dataRangeNewestUnix(
            frame: ByteArray,
            wallNowUnix: Long = System.currentTimeMillis() / 1000L,
        ): Long? = com.noop.protocol.DataRange.newestUnix(frame, wallNowUnix, AUTO_CONTINUE_FUTURE_SKEW_SECONDS)

        /** OLDEST plausible record timestamp in a GET_DATA_RANGE frame — the start of the strap's stored
         *  history. Same scan as [dataRangeNewestUnix] but keeps the minimum, so one connect can report the
         *  full banked SPAN (oldest…newest) = the backlog DEPTH a deep oldest-first drain must cover before
         *  recent nights land (#364). Mirrors Swift `BLEManager.dataRangeOldestUnix`. */
        // #286 follow-up: delegate to the pure, twin-tested com.noop.protocol.DataRange (byte-identical Swift).
        fun dataRangeOldestUnix(frame: ByteArray): Long? = com.noop.protocol.DataRange.oldestUnix(frame)

        /** #364 auto-continue cap: consecutive immediate re-kicks per connection before falling back to
         *  the 900s periodic timer. Guards 1-3 in [shouldAutoContinue] (healthy link, genuine backlog,
         *  advancing trim, plus the #928/#1012 future-clock exclusion) already stop the pathological cases;
         *  this cap is only the backstop against a strap that advances its trim but never advances OUR
         *  frontier (a data-shape spin). #533: at 6, a WELL-BEHAVED deep backlog hit the cap and got
         *  throttled to the 15-min floor mid-drain (~9s bursts, 15-20 min apart, 95% waiting), so recent
         *  nights landed hours after waking (which surfaced as a false sleep-detection bug in #515). Raised
         *  so a typical deep backlog drains in ONE connection: 24 productive passes (~10-15s each) ≈ a few
         *  minutes of back-to-back draining; the ~24-min backstop only ever bites the rare data-shape spin.
         *  Mirrors Swift BackfillContinuation.defaultMaxAutoContinues. TUNABLE — needs on-strap validation. */
        /** #592: sentinel value of [extendedBatteryProbe] between sending the probe and its reply landing. */
        const val WAITING_EXTENDED_BATTERY_PROBE = "__waiting__"

        /** #592: how long to wait for a probe COMMAND_RESPONSE before treating silence as "no reply". */
        const val EXTENDED_BATTERY_PROBE_TIMEOUT_MS = 8_000L

        /** #592: persisted previous extended-battery payload hex, so a new capture can diff against it. */
        private const val KEY_592_PREV_PAYLOAD = "noop.592.prevPayload"

        /**
         * #592: format a GET_EXTENDED_BATTERY_INFO COMMAND_RESPONSE into a clean, readable, copyable report
         * (verdict, full raw hex, an offset-labelled payload hex grid, the decoded voltage, and a per-byte
         * diff vs [prevPayloadHex]). Pure + deterministic so it's unit-tested without a strap. Returns the
         * display text and the payload hex to persist for the next capture's diff (null when there's no
         * decodable payload). [cmdOff] is the response-command byte offset (6 on WHOOP4, 10 on 5/MG); the
         * 4-byte CRC32 trailer both families carry is excluded from the payload.
         */
        internal fun formatExtendedBatteryProbe(
            frame: ByteArray,
            cmdOff: Int,
            isWhoop5: Boolean,
            prevPayloadHex: String?,
        ): Pair<String, String?> {
            val fam = if (isWhoop5) "WHOOP 5/MG" else "WHOOP 4.0"
            val payStart = cmdOff + 1
            val payEnd = frame.size - 4
            val hasPayload = payEnd > payStart
            val pay = if (hasPayload) frame.copyOfRange(payStart, payEnd) else ByteArray(0)

            // 5/MG replies carry an explicit result code @12 (0 FAILURE / 1 SUCCESS / 2 PENDING /
            // 3 UNSUPPORTED — 3 is the MG's hardware-confirmed rejection code, #48).
            val resultCode = if (isWhoop5 && frame.size > 12) frame[12].toInt() and 0xFF else null
            val resultLabel = when (resultCode) {
                0 -> "FAILURE"; 1 -> "SUCCESS"; 2 -> "PENDING"; 3 -> "UNSUPPORTED"
                null -> null; else -> "result$resultCode"
            }
            val verdict = when {
                resultCode == 3 -> "opcode 98 REJECTED by firmware (UNSUPPORTED) — evidence for the decompile's 87"
                hasPayload -> "opcode 98 ACCEPTED — ${pay.size}-byte payload"
                else -> "opcode 98 answered with a bare stub — ambiguous"
            }

            val sb = StringBuilder()
            sb.append("#592 EXTENDED-BATTERY PROBE — ").append(fam).append('\n')
            sb.append("Verdict: ").append(verdict).append('\n')
            if (resultLabel != null) sb.append("Result code @12: ").append(resultLabel).append('(').append(resultCode).append(")\n")
            // Full raw hex on ONE line so it copies cleanly for sharing.
            sb.append("\nRaw frame (").append(frame.size).append(" B):\n")
            sb.append(frame.joinToString("") { "%02x".format(it) }).append('\n')

            var payloadHex: String? = null
            if (hasPayload) {
                payloadHex = pay.joinToString("") { "%02x".format(it) }
                sb.append("\nPayload (").append(pay.size).append(" B, CRC excluded):\n")
                sb.append(hexGrid(pay))
                // NOOP's decoder reads the pack voltage at payload bytes 7..8 (LE) — but that offset is only
                // confirmed on WHOOP 4.0 (the 5/MG response to 98 is an undecoded stub, #592), so DON'T print
                // a decoded voltage for 5/MG where it'd be a guess presented as fact; the raw grid stands.
                if (!isWhoop5 && pay.size >= 9) {
                    val mv = (pay[7].toInt() and 0xFF) or ((pay[8].toInt() and 0xFF) shl 8)
                    sb.append("\nVoltage: ").append("%.2f V".format(java.util.Locale.US, mv / 1000.0))
                        .append("  (mV=").append(mv).append(" @07) — the field NOOP already reads\n")
                }
                // Per-byte diff vs the previous capture — the field-mapping signal.
                sb.append('\n')
                if (prevPayloadHex != null && prevPayloadHex.length == payloadHex.length) {
                    val prev = prevPayloadHex.chunked(2).map { it.toInt(16) }
                    val deltas = StringBuilder()
                    for (i in pay.indices) {
                        val a = prev[i]
                        val b = pay[i].toInt() and 0xFF
                        if (a != b) deltas.append(" @%02d:%02x→%02x".format(i, a, b))
                    }
                    if (deltas.isEmpty()) {
                        sb.append("Δ vs previous capture: identical — re-probe at a different % / after wear to expose the fields")
                    } else {
                        sb.append("Δ vs previous capture:").append(deltas).append('\n')
                        sb.append("(a byte tracking battery % = SoC/capacity; drifting with wear = temperature; only ever climbing = cycle count)")
                    }
                } else {
                    sb.append("Δ vs previous capture: first capture — probe again at another battery % to diff")
                }
            } else {
                sb.append("\nNo payload beyond the command byte (bare stub) — no data over the battery event; ")
                sb.append("opcode 98 may be an unknown-command ack on this firmware")
            }
            return sb.toString() to payloadHex
        }

        /** Offset-labelled hex grid, 8 bytes per row ("  @00  0d 01 …"), for the #592 payload dump. */
        private fun hexGrid(bytes: ByteArray): String {
            val sb = StringBuilder()
            var i = 0
            while (i < bytes.size) {
                sb.append("  @%02d ".format(i))
                var j = i
                while (j < minOf(i + 8, bytes.size)) {
                    sb.append(" %02x".format(bytes[j]))
                    j++
                }
                sb.append('\n')
                i += 8
            }
            return sb.toString()
        }

        /** #690: sentinel value of [bodyLocationProbe] between sending the probe and its reply landing. */
        const val WAITING_BODY_LOCATION_PROBE = "__waiting__"

        /** #690: how long to wait for a body-location COMMAND_RESPONSE before treating silence as "no reply". */
        const val BODY_LOCATION_PROBE_TIMEOUT_MS = 8_000L

        /** #690: persisted previous body-location payload hex, so a new capture can diff against it. */
        private const val KEY_690_PREV_PAYLOAD = "noop.690.prevPayload"

        /** #761: sentinel value of [featureFlagProbe] while the read-only enumeration walk is running. */
        const val WAITING_FEATURE_FLAG_PROBE = "__waiting__"

        /** #761: per-step reply window. Each 118 is only sent after the previous reply lands, so this
         *  bounds one round-trip, not the whole walk. */
        const val FEATURE_FLAG_PROBE_TIMEOUT_MS = 8_000L

        /** #103: sentinel value of [deviceConfigProbe] while the read-only VALUE probe is walking. */
        const val WAITING_DEVICE_CONFIG_PROBE = "__waiting__"

        /** #103: per-step reply window. Each read is only sent after the previous reply lands (or times
         *  out), so this bounds one round-trip, not the whole plan. */
        const val DEVICE_CONFIG_PROBE_TIMEOUT_MS = 8_000L

        /**
         * #690: format a GET_BODY_LOCATION_AND_STATUS (0x54) COMMAND_RESPONSE into a clean, readable,
         * copyable report — verdict, full raw hex, an offset-labelled payload grid, the four decoded fields
         * (revision / location + enum label / confidence / status), and a per-byte diff vs [prevPayloadHex].
         * READ-ONLY: never changes wear detection, sleep gating, or scoring. Pure + deterministic so it's
         * unit-tested without a strap. Byte-identical to the Swift [BodyLocationProbe.format]. [cmdOff] is the
         * response-command byte offset (6 on WHOOP4, 10 on 5/MG); the 4-byte CRC32 trailer is excluded.
         *
         * Protocol facts (0x54, the 4-byte layout, the location enum) are RE'd from the WHOOP app and
         * reimplemented here in NOOP's own code — facts, not copied expression (see ATTRIBUTION.md).
         */
        internal fun formatBodyLocationProbe(
            frame: ByteArray,
            cmdOff: Int,
            isWhoop5: Boolean,
            prevPayloadHex: String?,
        ): Pair<String, String?> {
            val fam = if (isWhoop5) "WHOOP 5/MG" else "WHOOP 4.0"
            val payStart = cmdOff + 1
            val payEnd = frame.size - 4
            val hasPayload = payEnd > payStart
            val pay = if (hasPayload) frame.copyOfRange(payStart, payEnd) else ByteArray(0)

            val resultCode = if (isWhoop5 && frame.size > 12) frame[12].toInt() and 0xFF else null
            val resultLabel = when (resultCode) {
                0 -> "FAILURE"; 1 -> "SUCCESS"; 2 -> "PENDING"; 3 -> "UNSUPPORTED"
                null -> null; else -> "result$resultCode"
            }
            val verdict = when {
                resultCode == 3 -> "opcode 84 REJECTED by firmware (UNSUPPORTED)"
                hasPayload -> "opcode 84 ACCEPTED — ${pay.size}-byte payload"
                else -> "opcode 84 answered with a bare stub — ambiguous"
            }

            val sb = StringBuilder()
            sb.append("#690 BODY-LOCATION PROBE — ").append(fam).append('\n')
            sb.append("Verdict: ").append(verdict).append('\n')
            if (resultLabel != null) sb.append("Result code @12: ").append(resultLabel).append('(').append(resultCode).append(")\n")
            sb.append("\nRaw frame (").append(frame.size).append(" B):\n")
            sb.append(frame.joinToString("") { "%02x".format(it) }).append('\n')

            var payloadHex: String? = null
            if (hasPayload) {
                payloadHex = pay.joinToString("") { "%02x".format(it) }
                sb.append("\nPayload (").append(pay.size).append(" B, CRC excluded):\n")
                sb.append(hexGrid(pay))
                // 4-byte revision/location/confidence/status record — decoded only on WHOOP4, where the
                // inner payload starts at cmdOff+1. On 5/MG the puffin envelope inserts a result code @12
                // (= pay[1]), so decoding here would mislabel the RESULT CODE as the location; until a real
                // 5/MG capture maps the offset, 5/MG shows the raw grid only. Twin of Swift BodyLocationProbe.
                if (!isWhoop5 && pay.size >= 4) {
                    val revision = pay[0].toInt() and 0xFF
                    val location = pay[1].toInt() and 0xFF
                    val confidence = pay[2].toInt() and 0xFF
                    val status = pay[3].toInt() and 0xFF
                    sb.append("\nDecoded:\n")
                    sb.append("  revision:   ").append(revision).append('\n')
                    sb.append("  location:   ").append(location).append("  (").append(bodyLocationLabel(location)).append(")\n")
                    sb.append("  confidence: ").append(confidence).append("  (raw)\n")
                    sb.append("  status:     ").append(status).append("  (raw)\n")
                } else if (!isWhoop5) {
                    sb.append("\nPayload shorter than the 4-byte body-location record — fields kept raw only\n")
                } else {
                    sb.append("\n5/MG: the record's offset inside the puffin envelope is unconfirmed — NOT decoded (the raw grid above stands); a real capture is needed to map the fields\n")
                }
                sb.append('\n')
                if (prevPayloadHex != null && prevPayloadHex.length == payloadHex.length) {
                    val prev = prevPayloadHex.chunked(2).map { it.toInt(16) }
                    val deltas = StringBuilder()
                    for (i in pay.indices) {
                        val a = prev[i]
                        val b = pay[i].toInt() and 0xFF
                        if (a != b) deltas.append(" @%02d:%02x→%02x".format(i, a, b))
                    }
                    if (deltas.isEmpty()) {
                        sb.append("Δ vs previous capture: identical — re-probe after moving/re-seating the strap to expose the fields")
                    } else {
                        sb.append("Δ vs previous capture:").append(deltas)
                    }
                } else {
                    sb.append("Δ vs previous capture: first capture — probe again in another position to diff")
                }
            } else {
                sb.append("\nNo payload beyond the command byte (bare stub) — this reply carried no body-location data, which is not the same as the firmware having none (see the Verdict above)")
            }
            return sb.toString() to payloadHex
        }

        /** #690: 0x54 location enum. Unknown/gap values (e.g. 6) fall through to a raw label so a reading is
         *  preserved, never crashes, and is never coerced to a known position. Twin of Swift's locationLabel. */
        private fun bodyLocationLabel(v: Int): String = when (v) {
            0 -> "UNKNOWN"; 1 -> "WRIST"; 2 -> "BICEP"; 3 -> "CALF"; 4 -> "SIDE_TORSO"
            5 -> "GLUTE"; 7 -> "ANKLE"; 128 -> "NOT_CONCLUSIVE"; 160 -> "UNKNOWN_GARMENT"
            else -> "raw$v"
        }

        const val MAX_AUTO_CONTINUES = 24

        /** #364 "more backlog remains" margin (seconds): how far ahead the strap must be of our persisted
         *  data frontier before we treat it as behind, not clock noise. Matches the Swift
         *  BackfillContinuation.defaultBehindGapSeconds (and StuckStrapDetector's behindGapSeconds). */
        const val AUTO_CONTINUE_BEHIND_GAP_SECONDS = 300L

        /** #1151: rolling window over which detailed-capture frame timing is summarised into one line. */
        const val FRAME_TIMING_SUMMARY_WINDOW_MS = 60_000L

        /** One detailed-capture line summarising [counts] (frame typeName → count) over [windowSec] seconds,
         *  types listed most-frequent first: `frameTiming 60s: 84 frame(s) [EVENT×40, COMMAND_RESPONSE×30,
         *  METADATA×14]`. Empty counts → a `0 frame(s) []` line (harmless; the caller only flushes after real
         *  frames). Pure/deterministic (ties broken by type name) so it's unit-testable. */
        fun formatFrameTimingSummary(counts: Map<String, Int>, windowSec: Long): String {
            val total = counts.values.sum()
            val types = counts.entries
                .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
                .joinToString(", ") { "${it.key}×${it.value}" }
            return "frameTiming ${windowSec}s: $total frame(s) [$types]"
        }

        /** #928: how far past the WALL CLOCK the strap-reported "newest" may sit before it is implausible.
         *  A strap clock set in the FUTURE makes [dataRangeNewestUnix] read ahead of every real frontier,
         *  so the "backlog remains" guard would report backlog forever and burn the whole auto-continue
         *  cap in EMPTY offloads on every connect. 48 h absorbs genuine timezone confusion and mild drift;
         *  nothing legitimate banks records two days ahead of the phone's clock. Mirrors the Swift
         *  BackfillContinuation.defaultFutureSkewSeconds. */
        const val AUTO_CONTINUE_FUTURE_SKEW_SECONDS = 48L * 3600L

        /**
         * #1012: is the strap-reported "newest banked record" FUTURE-dated beyond the skew allowance —
         * more than [futureSkewSeconds] past the wall clock? The strap's clock is then almost certainly
         * set in the future (#928), so its range answer AND its freshly-persisted rows are untrustworthy
         * as backlog evidence. Pure, and shared between [shouldAutoContinue] (it gates 2a AND 2b) and the
         * call site's honest stop log so the two can never disagree on the reason. null ⇒ false: an
         * unanswered range is UNKNOWN, not future-dated, and 2b's stale-epoch rescue (#451) still applies
         * to it. Mirrors the Swift `BackfillContinuation.isFutureDatedNewest`.
         */
        fun isFutureDatedNewest(
            strapNewestTs: Long?,
            wallNowUnix: Long,
            futureSkewSeconds: Long = AUTO_CONTINUE_FUTURE_SKEW_SECONDS,
        ): Boolean = strapNewestTs != null && strapNewestTs > wallNowUnix + futureSkewSeconds

        /**
         * #324/#928: the post-sync banner for a strap whose clock is set in the FUTURE. Unlike the
         * "clock lost / not banking" case ([classifyCompletedOffload]'s bankedNothing), this strap DOES
         * bank records every pass — but its RTC relatched to a future base, so every banked timestamp
         * reads ahead of the wall clock and NOOP won't import them (importing would misfile the night
         * days or years ahead). The clock-lost banner is gated on empty syncs and never fires here, so
         * this failure mode was silent (#324). Returns the user-facing string when the strap-reported
         * newest is future-dated beyond the 48 h skew allowance ([isFutureDatedNewest]), else null. Pure
         * and deterministic — one detection is decisive (nothing legitimate banks 48 h ahead), so no
         * streak gate is needed. Mirrors the Swift `BLEManager.futureDatedStrapBanner`.
         */
        fun futureDatedStrapBanner(strapNewestTs: Long?, wallNowUnix: Long): String? =
            if (!isFutureDatedNewest(strapNewestTs, wallNowUnix)) null
            else "Synced, but your strap's clock is set in the future - its banked history is dated ahead of " +
                "today, so NOOP can't trust those timestamps and didn't import them (importing them would " +
                "misfile your data days or years ahead). Fully charge the strap to 100% and power-cycle it so " +
                "its clock re-syncs, then reconnect."

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
         *
         * #1012: a FUTURE-dated [strapNewestTs] (more than [futureSkewSeconds] past the wall clock, #928)
         * not only nulls guard 2a — it also STOPS guard 2b. A future-clock strap banks future-dated
         * records, so the rows it hands over are future-timestamped too and "real rows persisted" is no
         * evidence of genuine backlog; 2b would chase the future-dated range through the whole cap (every
         * consecutive pass back-to-back, each to its idle timeout — the reported ~15-min sync). The stale/PAST-epoch
         * case 2b actually exists for (#451) reads BEHIND the frontier, never future-dated, so it is
         * untouched.
         */
        fun shouldAutoContinue(
            stillConnected: Boolean,
            strapNewestTs: Long?,
            ourFrontierTs: Long?,
            wallNowUnix: Long,
            lastTrimAdvanced: Boolean,
            consecutiveCount: Int,
            rowsPersistedThisSession: Int = 0,
            maxAutoContinues: Int = MAX_AUTO_CONTINUES,
            behindGapSeconds: Long = AUTO_CONTINUE_BEHIND_GAP_SECONDS,
            futureSkewSeconds: Long = AUTO_CONTINUE_FUTURE_SKEW_SECONDS,
        ): Boolean {
            if (!stillConnected) return false                          // 1
            if (consecutiveCount >= maxAutoContinues) return false      // 4 (cap)
            if (!lastTrimAdvanced) return false                        // 3 (don't spin on a frozen cursor)
            // 3b (#1144): an EMPTY session (0 rows persisted) never auto-continues, whatever the reported
            // frontier gap. When the strap advertises a `newest` AHEAD of our frontier but the offload for
            // that range hands back chunkRows=0 (a PHANTOM gap — a timestamp it won't actually offload), 2a
            // below would latch `true` forever: the frontier can't advance without rows, so `newest -
            // frontier` stays > gap and it re-fires to the full cap in empty offloads (the storm observed on
            // a real 4.0). `lastTrimAdvanced` (3) doesn't catch it — the trim u32 climbs on empty ENDs. Stop
            // and let the 15-min floor retry; healthy backlog sessions persist real rows so this only bites
            // the empty spin. (Makes 2b's row check the ONE authority for both cases.)
            if (rowsPersistedThisSession <= 0) return false
            // #928: a strap clock set in the FUTURE makes "newest" read ahead of ANY real frontier, so 2a
            // would report backlog forever and drive up to the full cap in EMPTY offloads on every
            // connect. A newest more than [futureSkewSeconds] past [wallNowUnix] (the REAL wall clock,
            // passed in so the predicate stays pure) is implausible: exclude it from 2a.
            val futureDated = isFutureDatedNewest(strapNewestTs, wallNowUnix, futureSkewSeconds)
            val newest = strapNewestTs?.takeIf { !futureDated }
            val frontier = ourFrontierTs
            // 2a: strap reports newer data than we hold — reliable WHEN its clock epoch is sane.
            if (newest != null && frontier != null && (newest - frontier) > behindGapSeconds) return true
            // #1012: a future-dated newest also gates 2b, not just 2a. A strap whose clock is set ahead
            // (#928) BANKED future-dated records, so the rows this session persisted are themselves
            // future-timestamped — "real rows" is NOT evidence of genuine backlog there, and 2b used to
            // chase the future-dated range through the whole cap (every consecutive pass back-to-back,
            // each run to its idle timeout: the reported ~15-min sync). Stop after this single pass; the periodic
            // floor keeps draining across connects, restoring the pre-#928 single-pass behaviour. The
            // stale/PAST-epoch case 2b exists for (#451) reads BEHIND the frontier, never future-dated,
            // so it falls through untouched below.
            if (futureDated) return false
            // 2b (#451): GET_DATA_RANGE's "newest" can read a STALE / wrong-epoch value — a strap that was
            // fully discharged (or carries a previous owner's history) banks records across multiple clock
            // epochs and can latch an OLD one (e.g. 2024 when the real newest is 2026). That false "already
            // past it" would stop the drain after ONE session and make the user tap the strap to re-trigger
            // (#364 / #451). But guard #3 proved the trim advanced, so if this session also PERSISTED REAL
            // SENSOR ROWS the strap is still handing over real backlog — keep going. Empty / console-only
            // ENDs persist 0 rows, so a stuck or caught-up strap won't spin; the cap bounds it regardless.
            return rowsPersistedThisSession > 0
        }

        // #927: Continuous HRV "overnight only" window (pure, unit-tested in ContinuousHrvWindowTest).
        //
        // The window reuses the app's quiet-hours convention byte-for-byte (NotifPrefs.inQuietHours /
        // SedentaryDetector.windowContains): minutes since LOCAL midnight, inclusive start, exclusive
        // end, and the window may wrap midnight (22:00 → 07:00 by default). Local wall time keeps it
        // DST-agnostic the same way quiet hours are: a DST jump moves the wall clock, the window
        // definition never changes.

        /** Wrap-aware membership: is [minuteOfDay] inside `[startMin, endMin)`, where the window may
         *  cross midnight? Byte-for-byte the quiet-hours semantics. Mirrors the Swift
         *  `ContinuousHrvSchedule.windowContains`. */
        fun overnightWindowContains(minuteOfDay: Int, startMin: Int, endMin: Int): Boolean =
            if (startMin <= endMin) minuteOfDay >= startMin && minuteOfDay < endMin
            else minuteOfDay >= startMin || minuteOfDay < endMin

        /** The composed continuous-capture mode (#927): false when the feature is off; true 24/7 when
         *  [overnightOnly] is off (ALWAYS, the pre-#927 behaviour, so existing users read it with no
         *  migration since the new key defaults to false); window-gated when both are on. Mirrors the
         *  Swift `ContinuousHrvSchedule.streamWanted`. */
        fun continuousHrvStreamWanted(
            continuousHrv: Boolean,
            overnightOnly: Boolean,
            minuteOfDay: Int,
            startMin: Int,
            endMin: Int,
        ): Boolean {
            if (!continuousHrv) return false
            if (!overnightOnly) return true
            return overnightWindowContains(minuteOfDay, startMin, endMin)
        }
    }

    // MARK: Published state — the single source of truth the UI observes. Seeded with the PERSISTED
    // last-sync time (PR #556 reimpl) so a freshly-recreated client doesn't show "Never" when this
    // install has actually synced before; a 0 (never) leaves it null, unchanged.
    private val _state = MutableStateFlow(
        LiveState(lastSyncAt = NoopPrefs.lastSyncAt(context).takeIf { it > 0L }),
    )
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
     *
     * Backed by [_preferredAddress] so the setter can reset the #52 bond-refusal streak when a genuinely
     * NEW pin is set (the old streak belonged to the previous strap). Re-applying the SAME pin — the
     * common no-op when the active device doesn't change — preserves an in-progress count. Mirrors iOS
     * `setPreferredPeripheral`. The public read/write contract is unchanged for existing call sites.
     */
    @Volatile
    private var _preferredAddress: String? = null
    var preferredAddress: String?
        get() = _preferredAddress
        set(value) {
            if (!value.equals(_preferredAddress, ignoreCase = true)) pinnedBondRefusals = 0
            _preferredAddress = value
        }

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

    // #592 extended-battery probe result text (raw hex + payload triage), null until a probe reply lands.
    // Drives the Devices result dialog so a capture is readable/copyable without a full log export.
    private val _extendedBatteryProbe = MutableStateFlow<String?>(null)
    val extendedBatteryProbe: StateFlow<String?> = _extendedBatteryProbe.asStateFlow()

    // #690: the body-location probe result (or the waiting sentinel), shown + copied in the Devices dialog.
    private val _bodyLocationProbe = MutableStateFlow<String?>(null)
    val bodyLocationProbe: StateFlow<String?> = _bodyLocationProbe.asStateFlow()

    // #761: the READ-ONLY feature-flag ENUMERATION report — the flag NAMES the strap's own firmware lists
    // — or the waiting sentinel while the walk runs. Nothing is written to the strap to produce it.
    private val _featureFlagProbe = MutableStateFlow<String?>(null)
    val featureFlagProbe: StateFlow<String?> = _featureFlagProbe.asStateFlow()

    /** The in-flight #761 report; null when no probe is running. Doubles as the [send] allowlist's
     *  in-flight gate — 117/118 cannot leave the app unless this is non-null. */
    private var featureFlagReport: FeatureFlagProbeReport? = null
    /** Monotonic step counter so a late timeout from an earlier step can't cancel a live walk. */
    private var featureFlagStep = 0
    /** The opcode whose reply we are waiting for (117 or 118), null between steps. */
    private var featureFlagAwaiting: Int? = null

    // #103: the READ-ONLY device-config READ report — what 121/128 answer when asked for a key's VALUE —
    // or the waiting sentinel while the plan runs. Nothing is written to the strap to produce it.
    private val _deviceConfigProbe = MutableStateFlow<String?>(null)
    val deviceConfigProbe: StateFlow<String?> = _deviceConfigProbe.asStateFlow()

    /** The in-flight #103 report; null when no probe is running. Doubles as the [send] allowlist's
     *  in-flight gate — 121/128 cannot leave the app unless this is non-null. */
    private var deviceConfigReport: DeviceConfigReadProbeReport? = null
    /** The step whose reply we are waiting for, null between steps. */
    private var deviceConfigAwaiting: DeviceConfigReadProbeReport.Step? = null
    /** Monotonic step counter so a late timeout from an earlier step can't cancel a live walk. */
    private var deviceConfigStep = 0

    // #174: the R22 DISABLE report — the per-key result of writing '0' to the sixteen feature flags and
    // reading every one back with GET_FF_VALUE(128), or the waiting sentinel while the run walks. Unlike
    // the two probes above this one DOES write, which is exactly why it reports the value the strap stores
    // rather than the write's own ack.
    private val _r22DisableReport = MutableStateFlow<String?>(null)
    val r22DisableReport: StateFlow<String?> = _r22DisableReport.asStateFlow()

    /** The in-flight #174 disable run; null when none is running. Doubles as the [send] allowlist's
     *  in-flight gate for the 128 read-back. */
    private var r22DisableRun: R22DisableReport? = null
    /** The step whose reply we are waiting for, null between steps. */
    private var r22DisableAwaiting: R22DisableReport.Step? = null
    /** Monotonic step counter so a late timeout from an earlier step can't cancel a live run. */
    private var r22DisableStep = 0

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
        if (rr.isNotEmpty()) _state.update { it.withRRIntervals(rr) }
        if (hr in 30..220) {
            // #56: a non-WHOOP source (the Oura ring, an FTMS machine, a generic HR strap) is actively
            // streaming live HR. Set streamingLiveHR so the Live console reads it as a trusted stream
            // instead of "connecting / not trusted" — this seam is invoked ONLY when WHOOP's own BLE is
            // paused, so it never sets the flag for a WHOOP. `bonded` stays false (no encrypted bond), so
            // the buzz/alarm/HRV feature gates keep keying off the WHOOP bond. Twin of iOS OuraLiveSource
            // → LiveState.streamingLiveHR (PR #56).
            _state.update { it.copy(heartRate = hr, connected = true, streamingLiveHR = true) }
        }
    }

    /**
     * Surface a non-WHOOP source's battery percent ([pct], 0–100) in the SAME live [state] the UI reads,
     * so a generic strap / FTMS machine shows its charge where the WHOOP strap battery does. Additive twin
     * of [publishExternalLiveHr]; called by [SourceCoordinator] ONLY while WHOOP's own BLE is paused (a
     * non-WHOOP device is active), so it never races the WHOOP battery path. Out-of-range values are
     * ignored. Mirrors the Swift StandardHRSource→LiveState.setBattery wiring.
     */
    fun publishExternalBattery(pct: Int) {
        if (pct in 0..100) _state.update { it.copy(batteryPct = pct.toDouble()) }
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

    /** #477 battery: gates GATT connection-priority management. DEFAULT OFF, so this whole feature ships
     *  DORMANT - [refreshConnectionPriority] early-returns and issues ZERO new BLE ops, leaving the link
     *  at the stack default (BALANCED) exactly as before. Flip on ONLY after on-strap validation (see
     *  #477); a follow-up wires it to a persisted Settings toggle. [connectionPriorityEnabled] enables the
     *  SAFE half (HIGH during offload/live-HR). The RISKY half (LOW_POWER when idle) is BATTERY-ADAPTIVE:
     *  it engages only when the STRAP is discharging AND at/below [idleThrottleBatteryPct] (0 = never), so
     *  the drop-risk is confined to when the user actually wants power saving. Set on the main looper via
     *  [setConnectionPriorityManagement]. */
    @Volatile private var connectionPriorityEnabled: Boolean = false
    /** Battery-% at/below which the LOW_POWER idle throttle engages while the STRAP is discharging;
     *  0 = never (safe half only).
     *
     *  REACHABLE as of #1035, but still OFF by default. `AppViewModel.applyPowerSaving` now passes
     *  `NoopPrefs.idleThrottleBatteryPct` here instead of a hard-coded 0, so #477's validation plan can
     *  finally arm it on a real strap. There is deliberately still NO Settings row: the pref is set
     *  out-of-band on a debug build and CLAMPED to 0 or 10..30 on read, because the two preconditions
     *  below are invisible in a UI and LOW_POWER can drop a link. Default 0 keeps today's behaviour
     *  byte-identical for anyone who has not set it.
     *
     *  Note it ALSO needs [connectionPriorityEnabled], i.e. the Fast history sync toggle, since
     *  [refreshConnectionPriority] early-returns without it. Setting this pref alone does nothing.
     *
     *  Contrast [lowBatteryOffloadPct] below, which the Power saving master drives. Both key on the
     *  STRAP's battery — see [batteryPctAndCharging] — so neither is a lever a user can pull because their
     *  PHONE is draining. That is the gap #1005 runs into (this change does not close it). */
    @Volatile private var idleThrottleBatteryPct: Int = 0

    /** #533: also escalate to HIGH for the LIVE-HR stream, not just the offload burst. DEFAULT OFF, and
     *  deliberately so: [realtimeArmed] is true for the whole OVERNIGHT continuous-HRV window (22:00–07:00
     *  by default via [continuousCaptureWantsNow]), NOT just while a Live screen is open. Escalating it
     *  would hold an ~11.25 ms interval for hours to carry a 1 Hz HR/RR stream that BALANCED already
     *  serves — a sustained drain on both strap and phone for no throughput gain. The offload burst is the
     *  opposite: bounded (HISTORY_COMPLETE / idle timeout) and bandwidth-hungry, so escalating it moves the
     *  same bytes in LESS radio-on wall-clock. Kept as a knob rather than deleted because the opt-in R22
     *  deep-buffer capture IS high-rate and is the one live case that could legitimately want HIGH. */
    @Volatile private var escalateForLiveHr: Boolean = false

    /** Opt into connection-priority management (#477). No-op by default; see the fields above.
     *  [idleThrottleBatteryPct] 0 disables the risky idle throttle (safe half only).
     *  [escalateForLiveHr] false keeps the escalation to the bounded offload burst (#533). */
    fun setConnectionPriorityManagement(
        enabled: Boolean,
        idleThrottleBatteryPct: Int,
        escalateForLiveHr: Boolean = false,
    ) {
        val wasEnabled = connectionPriorityEnabled
        connectionPriorityEnabled = enabled
        this.idleThrottleBatteryPct = if (enabled) idleThrottleBatteryPct else 0
        this.escalateForLiveHr = enabled && escalateForLiveHr
        handler.post {
            // #533: switching the experiment OFF must UNDO a live escalation, not merely stop future ones.
            // [refreshConnectionPriority] early-returns on !connectionPriorityEnabled, so without this a
            // link currently pinned at HIGH would STAY there until the next reconnect — a user turning the
            // toggle off *because* of battery would keep paying for it, potentially for hours on a
            // background connection. Only fires on a real on→off edge; enabling (or a no-op re-apply while
            // already off) never issues a stray request. See [releasesOnDisable].
            if (releasesOnDisable(wasEnabled, enabled)) releaseConnectionPriority()
            else refreshConnectionPriority()
        }
    }

    /** #533: hand the link back to the stack default (BALANCED) when connection-priority management is
     *  switched off, undoing any escalation still in force. Same swallow-don't-teardown policy as
     *  [refreshConnectionPriority]: a priority hint must never drop the link. */
    private fun releaseConnectionPriority() {
        val ops = gattOps ?: return
        try {
            ops.requestConnectionPriorityCompat(BluetoothGatt.CONNECTION_PRIORITY_BALANCED)
        } catch (t: Throwable) {
            log("connection-priority release failed (${t.javaClass.simpleName}); skipped")
        }
    }

    /** #533 (EXPERIMENTAL, default off): ask for the LE 2M PHY around the historical offload. See
     *  [preferredPhyMask]. Requested at offload START rather than on connect ON PURPOSE: the connect
     *  handshake is fragile — an extra GATT op before `requestMtu` can make it return false, which skips
     *  the MTU bump and caps the very offload this is trying to speed up (#85/#50). The offload burst is
     *  where the throughput matters anyway, and PHY is a link-level setting that persists once negotiated. */
    @Volatile private var fastLinkPhyEnabled: Boolean = false

    /** Opt into the experimental LE 2M PHY preference (#533). No-op by default; applied at the next offload.
     *
     *  Turning it OFF hands the link back to 1M rather than merely stopping future offloads from asking for
     *  2M. A PHY PERSISTS once negotiated, so without this an already-2M link would stay 2M until the next
     *  reconnect — and this toggle's own copy tells the user to switch it off if syncing goes flaky at
     *  range, which is exactly the case where 2M is the suspect. Reuses [releasesOnDisable]'s
     *  edge rule, so the default path (re-applying `false` while already off, every launch) issues ZERO
     *  BLE ops. */
    fun setFastLinkPhy(enabled: Boolean) {
        val wasEnabled = fastLinkPhyEnabled
        fastLinkPhyEnabled = enabled
        if (releasesOnDisable(wasEnabled, enabled)) handler.post { releasePreferredPhy() }
    }

    /** #533: ask the controller to prefer 2M for this link (mask always includes 1M so it can fall back).
     *  Fire-and-forget — `setPreferredPhy` is void and the peer may decline; `onPhyUpdate` logs the PHY
     *  actually negotiated, which is also how we learn whether WHOOP supports 2M at all. Swallows throws
     *  like the connection-priority hint: a PHY preference must never tear the link down. No-op when off,
     *  so the default path issues ZERO extra BLE ops. */
    private fun applyPreferredPhy() {
        if (!fastLinkPhyEnabled) return
        val ops = gattOps ?: return
        val mask = preferredPhyMask(true)
        try {
            ops.setPreferredPhyCompat(mask, mask, BluetoothDevice.PHY_OPTION_NO_PREFERRED)
            log("Offload: requested LE 2M PHY preference (#533)")
        } catch (t: Throwable) {
            log("preferred-PHY request failed (${t.javaClass.simpleName}); skipped")
        }
    }

    /** #533: ask the controller back down to 1M when the experiment is switched off, undoing a 2M link
     *  still in force. Swallows throws like [applyPreferredPhy]. */
    private fun releasePreferredPhy() {
        val ops = gattOps ?: return
        val mask = preferredPhyMask(false)
        try {
            ops.setPreferredPhyCompat(mask, mask, BluetoothDevice.PHY_OPTION_NO_PREFERRED)
            log("Offload: released the LE 2M PHY preference — back to 1M (#533)")
        } catch (t: Throwable) {
            log("preferred-PHY release failed (${t.javaClass.simpleName}); skipped")
        }
    }

    /** Battery-% at/below which the periodic offload cadence stretches to
     *  [LOW_BATTERY_BACKFILL_INTERVAL_MS] while discharging; 0 = never (normal 15-min cadence). DEFAULT
     *  OFF, so this ships dormant. The Settings picker offers 10/15/20/25/30. */
    @Volatile private var lowBatteryOffloadPct: Int = 0

    /** Opt into the low-battery offload-cadence stretch (#477). Applies on the NEXT re-arm; a live sync
     *  in flight is never interrupted. */
    fun setLowBatteryOffloadThrottle(thresholdPct: Int) {
        lowBatteryOffloadPct = thresholdPct
    }

    /** #477: pause BACKGROUND continuous-HRV capture while the STRAP's battery is low (own toggle,
     *  DEFAULT OFF). A visible Live screen is unaffected — only the held-open background stream is
     *  released. Gated through [continuousCaptureWantsNow]. */
    @Volatile private var pauseCaptureBatteryPct: Int = 0

    /** Opt into pausing continuous capture when the strap is low (#477). Battery-%-aware like the other
     *  levers: pass the same threshold, so it engages at/below the STRAP's % (0 = off). Reconciles
     *  immediately so the change takes effect without waiting for the next keep-alive tick. */
    fun setPauseCaptureOnPowerSave(enabled: Boolean, thresholdPct: Int) {
        pauseCaptureBatteryPct = if (enabled) thresholdPct else 0
        handler.post { reconcileRealtime() }
    }

    /** The delay before the next periodic offload — normally [BACKFILL_INTERVAL_MS], stretched when low on
     *  battery (#477). Reads the battery snapshot at re-arm time.
     *  #battery: a 5/MG whose history offload is known-empty ([whoop5EmptyOffload.historyEmpty], crossed
     *  after 2 consecutive empty offloads) is stretched to [LOW_BATTERY_BACKFILL_INTERVAL_MS] (45 min)
     *  regardless of battery % — history sync is experimental on 5.0 and such a strap banks nothing per
     *  pass, so a 15-min periodic kick just holds the link ~60 s for zero data. The BackfillPolicy
     *  empty-backoff also stretches (after 3 empties), but this engages one cycle earlier (tracker
     *  quietThreshold = 2) at a fixed 45-min floor that stacks with it. Twin of iOS
     *  `BLEManager.nextBackfillInterval`. Resets with [whoop5EmptyOffload] on disconnect. */
    private fun nextBackfillDelayMs(): Long {
        // #battery: known-empty-history 5/MG → stretch to the 45-min floor before any battery lever.
        if (connectedFamily == DeviceFamily.WHOOP5) {
            val stretched = whoop5EmptyHistoryBackfillIntervalMs(
                baseMs = BACKFILL_INTERVAL_MS,
                lowBatteryMs = LOW_BATTERY_BACKFILL_INTERVAL_MS,
                historyEmpty = whoop5EmptyOffload.historyEmpty,
            )
            if (stretched != BACKFILL_INTERVAL_MS) return stretched
        }
        if (lowBatteryOffloadPct <= 0) return BACKFILL_INTERVAL_MS   // dormant: no battery read, unchanged cadence
        val (batteryPct, charging) = batteryPctAndCharging()
        return offloadIntervalMsFor(
            baseMs = BACKFILL_INTERVAL_MS,
            lowBatteryMs = LOW_BATTERY_BACKFILL_INTERVAL_MS,
            batteryPct = batteryPct,
            charging = charging,
            thresholdPct = lowBatteryOffloadPct,
        )
    }

    /** The connected STRAP's (battery-%, isCharging) — WHOOP, and the same for Oura/Fitbit. Power saving
     *  keys off the strap, not the phone: the levers reduce how much the STRAP transmits (fewer offloads,
     *  no continuous stream), so they extend the strap's life when it wasn't charged in time. Unknown
     *  (disconnected / not yet read) → (100, false), fails SAFE (a disconnected strap has nothing to
     *  throttle anyway). */
    private fun batteryPctAndCharging(): Pair<Int, Boolean> {
        val s = _state.value
        return (s.batteryPct?.toInt() ?: 100) to (s.charging == true)
    }

    /** (Re)apply the GATT connection priority for the current link state (#477). Idempotent + cheap: OFF
     *  or disconnected -> no BLE op. Called on connect-established and whenever offload / live-HR toggles. */
    private fun refreshConnectionPriority() {
        if (!connectionPriorityEnabled) return
        val ops = gattOps ?: return
        // Only read the battery when the RISKY idle throttle is actually armed (threshold > 0); the SAFE
        // HIGH-escalation half doesn't need it, so safe-half-only mode issues no battery read.
        val idleThrottle = idleThrottleBatteryPct > 0 && run {
            val (batteryPct, charging) = batteryPctAndCharging()
            idleThrottleActive(batteryPct, charging, idleThrottleBatteryPct)
        }
        // Read the authoritative INTERNAL flags (both set synchronously on this looper), not the
        // published LiveState mirror, which `exitBackfilling` may update a beat later.
        val priority = connectionPriorityFor(
            offloadActive = backfilling,
            // #533: gated — the live stream does NOT escalate by default. See [escalateForLiveHr]: the
            // overnight continuous-HRV window keeps this armed for hours, and a 1 Hz stream gains nothing
            // from HIGH. The offload burst below is the case that actually wants the shorter interval.
            liveHrActive = realtimeArmed && escalateForLiveHr,
            idleThrottleEnabled = idleThrottle,
        )
        // Deliberately NOT via safeGatt: a battery HINT must never tear the link down. safeGatt's policy
        // is "any throw ⇒ teardown", right for load-bearing writes/subscriptions but wrong here — a dead
        // binder is handled by the next real op, and skipping a priority request costs nothing. Swallow.
        try {
            ops.requestConnectionPriorityCompat(priority)
        } catch (t: Throwable) {
            log("connection-priority request failed (${t.javaClass.simpleName}); skipped")
        }
    }
    /** @Volatile: set on the GATT binder thread at service discovery, but read in send() on the main
     *  thread (user actions) - the barrier makes a main-thread send see the current characteristic. */
    @Volatile private var cmdCharacteristic: BluetoothGattCharacteristic? = null

    /** Frame reassembler for the fragmented custom notify chars (port of Reassembler). Reassigned per
     *  connection with the detected family — WHOOP5/MG frames use a different length encoding. */
    private var reassembler = Reassembler()

    /** Rolling command sequence byte; incremented before each send. ATOMIC because `send()` is called from
     *  BOTH the GATT binder thread (the connect handshake, offload acks, the bond frame) and the main thread
     *  (user actions - buzz/alarm/rename): a non-atomic `seq++` there let two sends emit the SAME seq byte.
     *  The wire value is `incrementAndGet() and 0xFF` (0..255, wraps). iOS is @MainActor so needs no atomic. */
    private val seq = AtomicInteger(0)

    /** True once the confirmed-write bond ACK lands (Swift `didBond`). @Volatile: written in a GATT
     *  callback (binder thread on API 26/27) and read in the onBondWatchdog / keepAlive main-looper
     *  timers, so it needs cross-thread visibility. (ryanbr, #1032) */
    @Volatile
    private var didBond = false

    /** Runs the connect handshake EXACTLY ONCE per connection (Swift `connectHandshakeDone`). @Volatile:
     *  written in a GATT callback (binder thread), read in beginBackfill (main-looper timer). (ryanbr, #1032) */
    @Volatile
    private var connectHandshakeDone = false

    /** True when the user asked to disconnect; suppresses the auto-rescan (Swift `intentionalDisconnect`).
     *  Written on the main looper (connect/disconnect/keep-alive bounce) and read on the GATT binder
     *  thread (handleDisconnect), so it must be @Volatile for cross-thread visibility. */
    @Volatile
    private var intentionalDisconnect = false
    /// The strap family the user chose to pair, remembered so an auto-reconnect after a
    /// dropout re-scans for the same model instead of falling back to WHOOP 4.0.
    private var selectedModel = WhoopModel.WHOOP4
    /** #716: true once the seeded "WHOOP" model has been stamped to the correct family. */
    private var modelStamped = false
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
    /// @Volatile: written on the binder thread at service discovery, read in send() on main (user
    /// actions) to pick the frame family - a stale read would frame a command for the wrong generation.
    @Volatile private var connectedFamily = DeviceFamily.WHOOP4

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

    /** PR #577: invoked (live only) when the strap reports it fired its firmware smart alarm
     *  (STRAP_DRIVEN_ALARM_EXECUTED, event 57). The firmware alarm is a single absolute instant with NO
     *  recurrence, so on receipt the ViewModel re-arms the next day's instant — belt-and-suspenders to
     *  the bond-edge / daily re-arm. Twin of macOS `LiveState.onSmartAlarmFired`. Wired by AppViewModel.
     *  Fired from the NON-gesture EVENT branch: event 57 is NOT a gesture, so routing it through the
     *  gesture path (freshness-gated, gesture `when`) would swallow it entirely. */
    var onSmartAlarmFired: (() -> Unit)? = null

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
            _state.update { it.copy(
                scanning = false,
                statusNote = "No strap found. Check it's charged and on your wrist, and that the " +
                    "official WHOOP app isn't connected to it (a strap will only pair with one app " +
                    "at a time). Then tap Connect again.",
            ) }
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
        // Connection & Sync test mode (Test Centre): the cheap gate + tagged sink the Backfiller checks
        // before building any .connection diagnostic line. The gate is one SharedPreferences bool; nothing
        // is emitted (or built) when the mode is off. Twin of the macOS Backfiller wiring.
        connectionActive = { testCentre.active(com.noop.testcentre.TestDomain.CONNECTION) },
        connectionLog = { s -> log(s, com.noop.testcentre.TestDomain.CONNECTION) },
        // Test Centre → Experimental algorithms: the opt-in v26 PPG-HR sub-lag interpolation variant, read
        // live each chunk so a mid-session toggle takes effect. Default OFF (byte-identical to today).
        ppgHrSubLagInterp = { puffinExperiment.ppgHrSubLagInterp },
        firmwareLayout = { v -> _state.update { it.copy(historyLayoutVersion = v) } },
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
                // #836: the post-backfill pass is a real update path, so it ALWAYS re-scores (mirroring the
                // Swift `analyzeRecent(force: true)` call `refreshAfterCompletedBackfill` makes) — but it must
                // ADVANCE the shared HR-fingerprint watermark on success, which it previously did NOT. That
                // watermark logic lived only in AppViewModel's 15-min loop, so after this pass the very next
                // idle tick saw `fp != watermark` and re-ran the IDENTICAL maxDays×~54h re-score — the
                // double-charge that made every reconnect pay for the multi-day pass twice. Swift already
                // advances the watermark at the end of EVERY successful analyzeRecent (IntelligenceEngine.swift);
                // this brings Android into lockstep. Captured before the run, written only on success, so an
                // interrupted/failed pass can never advance the watermark past unscored data.
                val analyzeFp = repository.hrFingerprint()
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
                        // Manual "Recalibrate baseline" anchor (noop.hrvBaselineEpoch, whole seconds in a
                        // Long). The analytics layer is Context-free, so read it here and thread it down so
                        // the post-backfill scoring pass honours the recalibration too — not just the UI's
                        // 15-min loop. 0 = no recalibration.
                        baselineEpoch = NoopPrefs.of(context)
                            .getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble(),
                        recoveryEpoch = NoopPrefs.of(context)
                            .getLong(Baselines.recoveryBaselineEpochKey, 0L).toDouble(),
                        // #195/#141: nightly HRV over deep-sleep windows only when the user picked WHOOP-style.
                        // Read here (the analytics layer is Context-free) and thread it down, exactly like
                        // baselineEpoch above — otherwise this post-backfill pass would recompute + persist every
                        // night's HRV over the WHOLE night, silently overwriting the deep-window value the UI
                        // loop just wrote (the "deep sleep window changes nothing" bug).
                        deepHrvWindow = UnitPrefs.hrvWindow(context) == HrvWindow.DEEP_SLEEP,
                        // #691: route the engine's per-day diagnostics (incl. the new RHR floor-vs-mean
                        // line) into THIS sync's strap log, so a "NOOP RHR reads lower than my sleeping-HR
                        // app" report carries the proof — the floor (NOOP's WHOOP-style resting HR) beside
                        // the night MEAN (the other app's number) — from the post-backfill scoring pass, not
                        // only the UI's 15-min loop. log() PII-scrubs at the sink. Best-effort + logging only.
                        diag = { s -> log(s) },
                        // Experimental sleep staging (V2): stage this post-backfill pass with the same
                        // engine the user chose in Settings, read off SharedPreferences here (the analytics
                        // layer is Context-free). The stored preference is default TRUE
                        // (getBoolean(KEY, true)), so this normally passes V2 — turning the Settings toggle
                        // off is what falls back to V1. (V7 Pillar 3b)
                        useExperimentalSleepV2 = PuffinExperiment.from(context).experimentalSleepV2,
                        // Opt-in motion-aware wake refinement (#364 follow-up) — same Context-free threading.
                        useMotionAwareWake = PuffinExperiment.from(context).motionAwareWake,
                        // Sleep & Rest test mode (Test Centre E5): when the SLEEP domain is on, route this
                        // post-backfill pass's per-day sleep gate trace into the .sleep-tagged strap log, so a
                        // shared report carries the staging proof from THIS scoring pass too, not only the UI
                        // 15-min loop. Zero-cost when off (the gate is one SharedPreferences bool read and the
                        // sink stays null → analyzeDay's byte-identical untraced path). log() PII-scrubs.
                        sleepTraceSink =
                            if (testCentre.active(com.noop.testcentre.TestDomain.SLEEP))
                                { s -> log(s, com.noop.testcentre.TestDomain.SLEEP) }
                            else null,
                        // Recovery (Charge) test mode (Test Centre Group G): when the RECOVERY domain is on,
                        // route this post-backfill pass's per-night Charge term-breakdown into the
                        // .recovery-tagged strap log too, not only the UI 15-min loop. Zero-cost when off
                        // (the gate is one SharedPreferences bool read and the sink stays null → the Charge
                        // score path is byte-identical). log() PII-scrubs.
                        recoveryTraceSink =
                            if (testCentre.active(com.noop.testcentre.TestDomain.RECOVERY))
                                { s -> log(s, com.noop.testcentre.TestDomain.RECOVERY) }
                            else null,
                        // Steps test mode (Test Centre): when the STEPS domain is on, route this post-backfill
                        // pass's per-day 5/MG raw-counter trace + WHOOP-4 calibration trace into the
                        // .steps-tagged strap log too, not only the UI 15-min loop. Zero-cost when off (the
                        // gate is one SharedPreferences bool read and the sink stays null, so the steps total
                        // path is byte-identical). log() PII-scrubs.
                        stepsTraceSink =
                            if (testCentre.active(com.noop.testcentre.TestDomain.STEPS))
                                { s -> log(s, com.noop.testcentre.TestDomain.STEPS) }
                            else null,
                    )
                }.onSuccess {
                    // Advance the shared watermark so the next 15-min tick sees no change and skips (#836).
                    NoopPrefs.setAnalyzeWatermark(context, analyzeFp)
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
                    // #660: log the count AND any PII-safe failure categories (the writer also persists
                    // the outcome to prefs, so Data Sources surfaces a failing background share).
                    runCatching { HealthConnectWriter.write(context, repository, deviceId) }
                        .onSuccess { r -> log("HC writeback: ${r.written} record(s)" + if (r.ok) "" else " (failed: ${r.failures.joinToString()})") }
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
    /** #617 bond-loop detector: tracks consecutive bond-then-quick-timeout cycles on a WHOOP 4. When it
     *  trips, the client surfaces the existing re-pair guide ([LiveState.reconnectGuide]) instead of
     *  looping silently. Reset on a user-initiated disconnect; the streak is otherwise broken naturally by
     *  any healthy (non-quick-timeout) disconnect. Twin of macOS BLEManager.postBondLoop. */
    private val postBondLoop = PostBondTimeoutLoopDetector()
    /** #971 bond-handshake watchdog pacer: escalates the #50 watchdog window per consecutive bounce (so a
     *  slow-but-healthy WHOOP 4.0 bond gets more time) and, after a capped number of bounces, stops
     *  bouncing and hands off to the re-pair guide + auto-reconnect pause. Distinct from [postBondLoop]:
     *  that one fires when a GENUINE bond drops ~1s later (status 0x08); this one fires when the handshake
     *  never LANDS inside its window and our own bounce reports status 0x16. Reset on a genuine bond or a
     *  user-initiated connect/disconnect. Android-only (the bond watchdog has no iOS twin). */
    private val bondWatchdogBackoff = BondWatchdogBackoff(baseWindowMs = BOND_WATCHDOG_MS)
    /** Monotonic per-connection token, bumped on every connect. The #711 bond-loop stabilization check
     *  captures it and clears the re-pair guide only if it is UNCHANGED when the check fires, i.e. the SAME
     *  continuous connection survived (a reconnect/loop cycle bumps it, so the device address staying equal
     *  across cycles can't fool it). Twin of macOS BLEManager.connectGeneration. */
    @Volatile private var connectGeneration = 0
    /** Wall time (System.currentTimeMillis) the encrypted bond was established this connection, to
     *  measure how soon a drop follows the bond (the #617 bond-loop tell). null until bonded; cleared on
     *  disconnect after the detector reads it. Twin of macOS BLEManager.bondedAt. */
    private var bondedAtMs: Long? = null
    // Connection & Sync test mode (Test Centre) - diagnostic-only counters, twins of the macOS
    // BLEManager fields. They change NO connect / bond / offload behaviour; every emit site that reads
    // them is gated behind testCentre.active(CONNECTION) BEFORE any string is built.
    /** Wall time (ms) the current connect attempt began, to measure connect latency at onConnectionStateChange
     *  CONNECTED. null between attempts; set when connect() kicks the radio. */
    private var connectAttemptStartedAtMs: Long? = null

    /**
     * Wall time (ms) this link reached STATE_CONNECTED, or null while down. Read only to LOG how long a
     * connection was held before it dropped.
     *
     * Why it is worth a field: reaching STATE_CONNECTED zeroes [failedReconnectAttempts], and that
     * counter is the ONLY input to [scanModeForReconnectAttempts]. So a strap that connects and drops
     * repeatedly — edge of range, phone in another room — never accumulates a streak and every rescan
     * stays on the battery-hungry SCAN_MODE_LOW_LATENCY, which the PR #588 backoff was meant to escape.
     * The #982 guard covers the never-bonded variant of that loop; a bonded-but-short-lived link is not
     * covered. Printing the hold time makes the pattern readable in an ordinary strap log: a run of
     * drops that all say `attempt 1` with a short `held` is that bug, with no instrumentation needed.
     *
     * Diagnostic only — nothing reads this to make a decision.
     */
    @Volatile
    private var linkUpSinceMs: Long? = null

    /** `, held 24s` for the drop log, or an empty string if we never reached STATE_CONNECTED. */
    private fun heldForLogSuffix(): String {
        val since = linkUpSinceMs ?: return ""
        return ", held ${(System.currentTimeMillis() - since) / 1000}s"
    }
    /** Count of INVOLUNTARY reconnects this run, surfaced as the reconnect-churn count. Reset by an
     *  intentional disconnect. */
    private var connReconnectCount = 0
    /** The last live frame TYPE name seen while the Connection test mode is ON, so it emits one frame-timing
     *  line per genuine type transition (never per frame - the raw flood repeats one type). Test-only: it is
     *  read AND written exclusively inside the mode gate, so the live hot path is untouched when the mode is
     *  off. The Swift side instead reuses LiveState.lastFrameType (a production field the Live console readout
     *  maintains anyway); Android has no such field, so this mirrors the emit while staying zero-cost off. */
    // #1151 detailed-capture: frame timing is accumulated per-type over a rolling window and flushed as ONE
    // summary line, instead of a line per frame-TYPE transition (which was ~a third of a real capture, so the
    // noise crowded actionable offload/reconnect/re-score history out of the 8MB rolling buffer). Test-only
    // state, touched only inside the CONNECTION-domain gate.
    private val connFrameCounts = LinkedHashMap<String, Int>()
    private var connFrameWindowStartMs = 0L

    /** Flush the accumulated frame-timing counts as ONE summary line and reset the window. No-op when
     *  nothing has accumulated (capture off, or already flushed). Called on the 60s boundary AND on
     *  disconnect — the latter so the frames RIGHT BEFORE a drop are recorded rather than stranded in an
     *  un-flushed window, and so the next connection's window can't span the (possibly hours-long) quiet
     *  gap and report a misleading windowSec. */
    private fun flushFrameTimingSummary() {
        if (connFrameCounts.isEmpty()) return
        val elapsedSec = ((System.currentTimeMillis() - connFrameWindowStartMs).coerceAtLeast(0L)) / 1000L
        log(formatFrameTimingSummary(connFrameCounts, elapsedSec), com.noop.testcentre.TestDomain.CONNECTION)
        connFrameCounts.clear()
        connFrameWindowStartMs = 0L
    }
    /** #580: tracks CONSECUTIVE empty 5/MG offloads so a 5/MG whose firmware serves no history (but streams
     *  live HR fine) reads as "history sync experimental on 5.0" instead of a sync error, and the 120s
     *  bounce loop backs off while live HR is flowing. Reset on connect / a banking offload. Twin of macOS. */
    private val whoop5EmptyOffload = Whoop5EmptyOffloadTracker()
    /** Genuine offload frames seen this session — zero at timeout means the strap never answered
     *  the history request at all (5/MG retry trigger, #78 fork). Main-looper only. */
    private var offloadFramesThisSession = 0
    /** Wall time (ms) this offload burst began, for the #1007 throughput line. Stamped by
     *  [enterBackfilling] and NEVER cleared, so it holds the PREVIOUS burst's start between bursts - both
     *  readers pair it with `backfilling`, which is only true when [enterBackfilling] has re-stamped it.
     *  Read in [exitBackfilling] for a classified exit, and in [reset] for a burst a disconnect cut short -
     *  the same two paths that already own [offloadFramesThisSession], so this adds no new thread. */
    private var backfillStartedAtMs = 0L
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

    // #520 DIS identity — read ONCE per connection, post-handshake, 5/MG only. Serial and hardware
    // revision are immutable, so they are never re-polled (unlike the battery). Reset on disconnect.
    private var disRead = false
    private var disSerial: String? = null
    private var disHwRev: String? = null

    /** #364 auto-continue: consecutive immediate re-kicks after a 60s idle-cap OR HISTORY_COMPLETE exit on
     *  THIS connection. Bounded by [MAX_AUTO_CONTINUES] so a pathological strap can't pin the radio. Reset
     *  to 0 once [shouldAutoContinue] proves we're caught up (its else path, under the cap) and on
     *  disconnect — NOT unconditionally on every HISTORY_COMPLETE, so a strap that slices one offload into
     *  many completions can't reset the cap each slice (#25). Main-looper only. Mirrors Swift
     *  `consecutiveAutoContinues`. */
    private var consecutiveAutoContinues = 0

    /** #battery: consecutive offload sessions that handed over ZERO sensor rows — whether a clean
     *  HISTORY_COMPLETE-empty OR an idle-timeout STALL (`result=stalled … rows=0`). Feeds BackfillPolicy's
     *  exponential backoff so the 15-min periodic poll STOPS spinning the radio on a strap that keeps
     *  returning nothing (a real battery drain: a capture showed ~6 empty stalls/hour at the 15-min floor
     *  with no backoff, because only HISTORY_COMPLETE fed [emptySyncTracker]). SEPARATE from that tracker —
     *  which stays console-only-specific for the clock-lost banner — so counting stalls here can never
     *  falsely fire that banner. Any banked rows reset it; the productive auto-continue tail doesn't count.
     *  Main-looper only. */
    private var consecutiveEmptyOffloads = 0

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
    // #47: buffer the (raw frame, pre-parsed) pair. Raw bytes stay for the raw path; the parse is the one
    // the dispatcher already did, so flushLive doesn't re-decode the batch.
    private val liveBuffer = ArrayList<Pair<ByteArray, com.noop.protocol.ParsedFrame>>()
    private var batchStartedAtMs = System.currentTimeMillis()

    /** Standard 0x2A37 HR/RR buffer — the reliable, always-on stream (port of Collector.stdHR/stdRR). */
    private val stdHr = ArrayList<HrRow>()
    private val stdRr = ArrayList<RrRow>()

    // --- Offload frame drain (preserves START/data/END arrival order; port of routeBackfillFrame) ---

    /** Ordered queue + generation-safe owner for the serial Backfiller drain. */
    private val backfillDrain = BackfillDrainGate<ByteArray>()

    /** Periodic re-offload + idle-watchdog tokens (handler-posted; cancelled on disconnect). */
    private val periodicBackfillRunnable = Runnable { triggerPeriodicBackfill() }

    /** Wall-clock of the last historical-offload KICK (a [beginBackfill] that actually started), or null
     *  before the first. Feeds [BackfillPolicy.shouldRun] so the automatic periodic/strap floors can space
     *  kicks — the Android side of the Swift `BLEManager.lastBackfillAt`. */
    @Volatile private var lastBackfillAtMs: Long? = null

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
     *  [setKeepStreamForData]. Mirrors the Swift `keepRealtimeForData`. #927: this is the RAW preference
     *  intent; the effective want is window-gated through [continuousCaptureWantsNow] when "overnight
     *  only" is on, re-derived at every arm site. */
    @Volatile private var keepStreamForData = false
    /** Derived want: the realtime stream should be armed while EITHER a screen wants it OR the
     *  continuous-capture preference wants it. The keep-alive re-arms it so it can't lapse, and the
     *  post-bond branch arms it on connect. Recomputed inside [reconcileRealtime] and RE-DERIVED at the
     *  post-bond arm sites (#927): a cached value can be a keep-alive tick stale, and a reconnect outside
     *  the overnight window must never arm the stream from it. */
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
    private data class PendingWrite(val frame: ByteArray, val withResponse: Boolean, val cmd: CommandNumber? = null)
    private val writeQueue = ConcurrentLinkedQueue<PendingWrite>()
    // @Volatile: read on the main looper in drainWriteQueue but CLEARED from the GATT binder thread in the
    // write-completion callbacks - the barrier guarantees the main-thread drain sees the flag flip promptly
    // (else a queued write could stall until the next drain trigger).
    @Volatile private var writeInFlight = false
    /** #791: set while [writeBondFrame]'s out-of-queue confirmed write is outstanding, so its completion is
     *  not mistaken for evidence about a frame held for retry. @Volatile: set on the main looper, read and
     *  cleared from the GATT binder thread in onCharacteristicWrite. */
    @Volatile private var bondWriteOutstanding = false

    /** A frame being retried after a transient BUSY rejection. Held here rather than re-added to the
     *  queue so it keeps its place AHEAD of later commands — command order matters (e.g. SET_CLOCK
     *  before GET_CLOCK). Only ever touched on the main looper inside [drainWriteQueue]. */
    private var pendingRetry: PendingWrite? = null
    private var writeRetries = 0

    /** The BUSY-retry kick for [drainWriteQueue], held as a NAMED runnable (not an inline lambda) so the
     *  teardown path can cancel a still-pending retry — otherwise a queued retry fires after the link is
     *  dead and re-enters the now-dead write, re-throwing `DeadObjectException` (#314). */
    private val drainWriteRetryRunnable = Runnable { drainWriteQueue() }

    /**
     * #791: drop a scheduled BUSY-retry because the write it would repeat has just completed.
     *
     * Called from `onCharacteristicWrite` (via the main looper, since [pendingRetry] is main-looper-only
     * state). A completion for a frame the stack said it refused means the refusal was wrong and the frame
     * went out, so repeating it would deliver the same command to the strap twice. Not re-draining here: the
     * caller's own `drainWriteQueue()` follows on the same looper and picks up the next queued frame.
     *
     * No-op when nothing is held for retry, which is the normal case for every successful write.
     */
    private fun cancelRetryOfWriteDeliveredDespiteBusy(writtenChar: UUID?, fromBondWrite: Boolean) {
        if (!shouldCancelBusyRetryOnCompletion(writtenChar, pendingRetry != null, fromBondWrite)) return
        val delivered = pendingRetry ?: return
        pendingRetry = null
        writeRetries = 0
        handler.removeCallbacks(drainWriteRetryRunnable)
        log(
            "write reported busy but then completed — dropping the duplicate retry of " +
                "${delivered.cmd?.name ?: "raw frame"} (#791)",
        )
    }

    /** Descriptor-write queue: enabling notifications is also a one-at-a-time GATT operation. */
    private val cccdQueue = ConcurrentLinkedQueue<BluetoothGattCharacteristic>()
    // @Volatile: the CCCD-write twin of [writeInFlight] - read on the main looper in drainCccdQueue but
    // CLEARED from the GATT binder thread in onDescriptorWrite, so the barrier stops a subscription write
    // from stalling on a stale flag (which would leave a notify channel un-enabled → no live data).
    @Volatile private var cccdInFlight = false
    /** Bounded retries for a transiently-BUSY CCCD write, so a single rejected subscribe doesn't
     *  permanently kill a stream (HR/battery/events). Reset per connection in [reset]. @Volatile: like
     *  [cccdInFlight], it's reset on the binder thread in onDescriptorWrite but incremented/read on main
     *  in drainCccdQueue - a stale budget could make a subscribe give up early. */
    @Volatile private var cccdRetries = 0
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
        // PR #588: an explicit user-driven Connect is never an out-of-range retry — clear the involuntary-
        // reconnect streak so this scan (and any reconnects it spawns) starts back at the snappy
        // LOW_LATENCY scan mode + the 3s backoff base, never inheriting a backed-off lower-power scan.
        resetReconnectBackoff()
        // #1030 (ryanbr): an explicit user Connect supersedes any pending involuntary reconnect timer.
        cancelPendingReconnect()
        selectedModel = model
        val adp = adapter
        // No Bluetooth LE hardware at all (most often an emulator / virtual device).
        if (adp == null || !context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            log("No Bluetooth LE on this device")
            _state.update { it.copy(
                scanning = false,
                statusNote = "This device has no Bluetooth LE. NOOP has to run on a real phone with " +
                    "Bluetooth, near your strap. It can't connect from an emulator or virtual device.") }
            return
        }
        if (!adp.isEnabled) {
            log("Bluetooth is off")
            _state.update { it.copy(
                scanning = false, statusNote = "Bluetooth is off. Turn it on, then tap Connect.") }
            return
        }
        val sc = scanner
        if (sc == null) {
            log("No BLE scanner available")
            _state.update { it.copy(statusNote = "Bluetooth isn't ready yet. Try again in a moment.") }
            return
        }
        if (scanning) {
            log("Scan already in progress — ignoring")
            return
        }
        // Reach a WHOOP 5/MG without a scan. Prefer a band the OS already holds connected
        // (getConnectedDevices returns it even after it stops advertising), then a bonded band that is not
        // currently connected (a direct connect avoids the status=133 first-operation failure seen on
        // scan-based 5/MG reconnects). Both helpers match only a 5/MG strap, so a WHOOP 4 falls through to
        // the scan below. The family is resolved from the discovered services rather than the selected
        // model, so this runs for any selected model and pins selectedModel to 5/MG on a hit to keep the
        // pipeline consistent. A stale connection or bond falls back to a scan via handleDisconnect.
        val direct = getConnectedWhoopDevice() ?: bondedWhoopDevice()
        if (direct != null) {
            selectedModel = WhoopModel.WHOOP5_MG
            log("Easy-connect: attaching directly to ${direct.name ?: "WHOOP"} (no scan needed)")
            _state.update { it.copy(
                scanning = false, whoop5Detected = false,
                statusNote = "Connecting to your ${WhoopModel.WHOOP5_MG.displayName}…",
            ) }
            connectToDevice(direct)
            bondedDirectAttempt = true   // after connectToDevice: reset() must not clear it
            return
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
            _state.update { it.copy(scanning = false, statusNote = "Bluetooth isn't ready yet. Try again in a moment.") }
            return
        }
        // Filter to the strap we're targeting plus diagnostic-only WHOOP service families. The callback
        // explicitly refuses unsupported families before any persist/connect path, so this broadens
        // visibility without routing unknown framing into GATT.
        val filters = (listOf(model.service.toString()) + WhoopGattServiceFamily.unsupportedServiceUuidStrings)
            .distinct()
            .map { uuid ->
                ScanFilter.Builder().setServiceUuid(ParcelUuid(UUID.fromString(uuid))).build()
            }
        // LOW_LATENCY for a snappy first connect, mirroring the desktop app's eager scan — but PR #588:
        // a SUSTAINED involuntary-reconnect streak ([failedReconnectAttempts] past the threshold) drops to
        // the lower-power BALANCED mode so an out-of-range strap stops pinning the radio at full power. A
        // user Connect resets the streak to 0, so a manual reconnect always scans at LOW_LATENCY.
        // We do NOT allow duplicates (CBCentralManagerScanOptionAllowDuplicatesKey: false).
        val scanMode = scanModeForReconnectAttempts(failedReconnectAttempts)
        if (scanMode != ScanSettings.SCAN_MODE_LOW_LATENCY) {
            log("Scan: backing off to lower-power mode after $failedReconnectAttempts involuntary reconnects (PR #588)")
        }
        val settings = ScanSettings.Builder()
            .setScanMode(scanMode)
            .build()
        log("Scanning for ${model.displayName}…")
        scanning = true
        _state.update { it.copy(scanning = true, whoop5Detected = false, statusNote = "Searching for your ${model.displayName}…") }
        try {
            sc.startScan(filters, settings, scanCallback)
        } catch (se: SecurityException) {
            // Android 12+: BLUETOOTH_SCAN/CONNECT not granted. This is the #1 reason connect fails.
            scanning = false
            log("Scan blocked (permission): ${se.message}")
            _state.update { it.copy(
                scanning = false,
                statusNote = "NOOP needs the Nearby devices / Bluetooth permission. Allow it in " +
                    "Settings → Apps → NOOP → Permissions, then tap Connect.") }
            return
        } catch (t: Throwable) {
            scanning = false
            log("Scan failed to start: ${t.message}")
            _state.update { it.copy(scanning = false, statusNote = "Couldn't start scanning: ${t.message}") }
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
        noteLocalTeardown("userDisconnect")   // #1020
        intentionalDisconnect = true
        handler.removeCallbacks(scanTimeoutRunnable)
        // #1030 (ryanbr): a user teardown supersedes any pending involuntary reconnect timer.
        cancelPendingReconnect()
        stopScan()
        // A user-initiated teardown is a clean slate: clear the #617 bond-loop streak so the next (manual)
        // reconnect starts fresh rather than inheriting old suspicion. Twin of macOS disconnect().
        postBondLoop.reset()
        // #747/#750: a clean teardown clears the bond-refusal give-up + un-pauses auto-reconnect.
        bondGiveUp.reset()
        // #971: a clean teardown also clears the bond-watchdog bounce streak (fresh escalation next time).
        bondWatchdogBackoff.reset()
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAtMs = null
        // #711: a user-initiated teardown resolves the re-pair guide (no longer looping).
        _state.update { it.copy(scanning = false, statusNote = null, reconnectGuide = null) }
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
            _state.update { it.copy(
                connected = false, scanning = false, streamingLiveHR = false,   // #56: keep streamingLiveHR ⟹ connected
                statusNote = "Bluetooth is off. Turn it on to reconnect.",
            ) }
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
            // #1030 (ryanbr): this radio-on reconnect supersedes any pending backoff timer (both branches below (re)connect).
            cancelPendingReconnect()
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
     * #78 hole-4: ONE bounded salvage attempt while the bond-loop pause is latched, fired on
     * app-foreground (the AppViewModel wires it to onActivityResumed). This is what makes the give-up
     * provably unable to strand a strap the user has since freed: a genuine bond on the probe fully
     * resets the pause via [clearPairingHint], while a still-refusing strap costs one attempt per
     * foreground per [BOND_LOOP_SALVAGE_FLOOR_MS] and NEVER re-enters the hammer loop (the give-up stays
     * latched so no second epitaph, [noteBondRefusalForPairingHint] doesn't flap the paused hint, and the
     * paused branch of handleDisconnect schedules nothing). Re-stamps [bondLoopPausedAtMs] so
     * back-to-back foregrounds can't chain probes. Gate extracted as the pure [shouldSalvageProbe].
     * Twin of iOS `BLEManager.salvageProbeIfBondLoopPaused` (which observes didBecomeActive itself).
     */
    fun salvageProbeIfBondLoopPaused() {
        handler.post {
            val since = bondLoopPausedAtMs?.let { System.currentTimeMillis() - it }
            if (!shouldSalvageProbe(autoReconnectPausedForBondLoop, _state.value.connected,
                                    intentionalDisconnect, since)) return@post
            if (gatt != null || scanning) return@post   // an attempt is already in flight - never stack one
            bondLoopPausedAtMs = System.currentTimeMillis()   // re-floor: max one probe per foreground AND per window
            log("Bond-loop pause: one salvage probe (the strap may have been freed since the give-up) - the give-up stays latched")
            intentionalDisconnect = false
            val dev = lastDevice
            if (dev != null && isPreferred(dev)) connectToDevice(dev, autoConnect = true)
            else connect(selectedModel)
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
        _state.update { it.copy(connected = false, bonded = false, encryptedBond = false,
                                streamingLiveHR = false,   // #56: a device switch drops any external stream too
                                r22FlagsAccepted = 0, deepPacketsThisSession = 0) }   // #174 reset per session
    }

    /**
     * Idle the engine before presenting an Add-a-WHOOP scan - but ONLY when we're not already connected
     * to a strap of this same model. Opening the scan must NOT tear down a live, bonded same-model
     * connection (#74, the Android half of the v5.2.3 iOS fix): [prepareForModelSwitch] dropped the live
     * strap mid-session (killing live HR/haptics/offload), set [intentionalDisconnect] AND nulled
     * [lastDevice], so a wizard dismissed without picking left the strap disconnected FOR GOOD - and a
     * 5/MG re-bond after the teardown refuses with insufficient-auth and loops on "connecting". The
     * keep-path touches NOTHING (not [gatt], not [lastDevice], not [intentionalDisconnect]):
     * [scanForWhoops] only borrows the LE scanner and never disturbs the connection. A genuine model
     * switch (live 4.0 while scanning 5/MG, or nothing connected) still idles via [prepareForModelSwitch]
     * so the scan starts clean. Decision extracted as the pure [shouldKeepLiveConnectionForPresentScan].
     * Kotlin twin of macOS `BLEManager.prepareForPresentScan`.
     */
    fun prepareForPresentScan(model: WhoopModel) {
        if (shouldKeepLiveConnectionForPresentScan(_state.value.connected, selectedModel, model)) {
            log("Add-a-WHOOP scan: keeping the live ${selectedModel.displayName} connection (#74) - presenting nearby straps without dropping it")
            return
        }
        prepareForModelSwitch()
    }

    /**
     * H3 (#520): fully RELEASE the strap when the user REMOVES it from the Devices screen, so the band can
     * enter pairing mode. Archiving the registry row alone left NOOP still holding the strap — the
     * disconnect→3s-reconnect timer, the targeted-connect pin, and the persisted last-device address ALL
     * still pointed at it, so it stayed connected and the user could never put it into pairing mode (a
     * connected WHOOP can't show its blue pairing LEDs). This stops auto-reconnect, drops the live link,
     * and clears EVERY reference that points at this strap so NOOP lets go for good — until the user
     * deliberately reconnects (which clears intentionalDisconnect again via connect()). Kotlin twin of iOS
     * `BLEManager.forgetDevice` (which iOS already wires from DevicesView's Remove). Runs on the main looper.
     */
    fun releaseStrap() {
        noteLocalTeardown("releaseStrap")   // #1020
        handler.post {
            intentionalDisconnect = true     // defuse the disconnect→3s-reconnect loop's guard
            handler.removeCallbacks(scanTimeoutRunnable)
            handler.removeCallbacks(scanFallbackRunnable)
            stopScan()
            // Clear the targeting that could re-grab this strap: the #52 pin and the remembered last device.
            preferredAddress = null          // back to "connect to the first WHOOP found" (single-WHOOP default)
            lastDevice = null                // don't fast-path reconnect to it (onBluetoothRadioOn / auto-reconnect)
            pinnedBondRefusals = 0
            // #747/#750 invariant: releasing a strap fully resets the give-up + pause (like disconnect())
            // so a paused state can never outlive the strap it belonged to and wedge a later re-add.
            bondRefusalStreak = 0
            bondGiveUp.reset()
            autoReconnectPausedForBondLoop = false
            bondLoopPausedAtMs = null
            // Drop the persisted last-device pin so a relaunch / radio-on doesn't auto-reconnect to it (#67).
            NoopPrefs.clearLastDevice(context)
            // Drop the live BLE link so the strap is free to enter pairing mode. disconnect() can throw on a
            // dead binder; tear down directly if so (the #314 path).
            try {
                gatt?.disconnect()           // onConnectionStateChange(DISCONNECTED) does the teardown + close
            } catch (t: Throwable) {
                log("releaseStrap: gatt.disconnect() threw ${t.javaClass.simpleName}; tearing down directly")
                teardownAfterGattFailure()
            }
            _state.update { releasedLiveState(it) }
            log("Device removed — released the strap: stopped auto-reconnect, dropped the link, cleared " +
                "targeting. Put it in pairing mode (blue LEDs) to re-pair if you want it back. (#520)")
        }
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
        // Also list a WHOOP 5/MG the OS already holds connected, so the wizard can add a band that is not
        // advertising (rssi 0 marks a connected, non-advertised entry). The scan below still adds any
        // advertising straps.
        getConnectedWhoopDevice()?.let { d ->
            val n = try { d.name } catch (se: SecurityException) { null }
            _discoveredWhoops.value = listOf(DiscoveredWhoop(address = d.address, name = n, rssi = 0))
        }
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
        // #1030 (ryanbr): a targeted reconnect supersedes any pending involuntary backoff timer.
        cancelPendingReconnect()
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
                // ABORT_HISTORICAL_TRANSMITS (20) over puffin: stop an offload already in flight. Allowed
                // ONLY while one actually is, so a default install can never form these bytes on a 5/MG —
                // and the gate is the same state the command is about. Non-destructive: the strap frees
                // records on our HISTORY_END ack, not on this, so an aborted drain re-offloads intact.
                !(cmd == CommandNumber.ABORT_HISTORICAL_TRANSMITS && backfilling) &&
                cmd != CommandNumber.SET_CLOCK && cmd != CommandNumber.GET_CLOCK &&
                cmd != CommandNumber.GET_DATA_RANGE &&
                cmd != CommandNumber.SET_ALARM_TIME && cmd != CommandNumber.DISABLE_ALARM &&
                // REBOOT_STRAP (29) over puffin: opcode shared with 4.0, framing is the puffin form built
                // below. NOT hardware-confirmed on 5/MG — rebootStrap() logs the COMMAND_RESPONSE so a strap
                // log confirms whether the frame is accepted. User-initiated + confirmation-gated only.
                cmd != CommandNumber.REBOOT_STRAP &&
                // GET_EXTENDED_BATTERY_INFO (98) over puffin: read-only opcode probe (#592) — a real
                // WHOOP 5 (fw 50.38.1.0) already answered this number, proving the frame is at least
                // accepted. Driven only by probeExtendedBatteryInfo() (user-initiated, Test Centre gated).
                cmd != CommandNumber.GET_EXTENDED_BATTERY_INFO &&
                // GET_BODY_LOCATION_AND_STATUS (84) over puffin: read-only opcode probe (#690). Driven only by
                // probeBodyLocationAndStatus() (user-initiated, Test Centre gated); response decoded to a
                // diagnostic report only, never gates wear/scoring. Whether 5/MG answers is a hardware check.
                cmd != CommandNumber.GET_BODY_LOCATION_AND_STATUS &&
                // START_FF_KEY_EXCHANGE (117) / SEND_NEXT_FF (118) over puffin: the READ-ONLY feature-flag
                // ENUMERATION probe (#761) — it reads the strap's own flag NAMES and writes no value. Gated
                // harder than the probes above: allowed ONLY while a probe is actually in flight, so on a
                // 5/MG a default install can never form these bytes. NOTE this whole allowlist is the 5/MG
                // path — WHOOP 4.0 has no send allowlist at all, so on a 4.0 the only thing keeping 117/118
                // off the wire is probeFeatureFlags()'s own Test Centre gate. Same practical result,
                // different mechanism, and worth knowing because the 4.0 is the family with a published key
                // dump to reproduce and so the likely first runner. The SET verbs (120 / 119) keep their own
                // separate opt-in clauses below and are never sent from this path. Driven only by
                // probeFeatureFlags() (user-initiated, Test Centre gated).
                !((cmd == CommandNumber.START_FF_KEY_EXCHANGE || cmd == CommandNumber.SEND_NEXT_FF) &&
                    featureFlagReport != null) &&
                // GET_DEVICE_CONFIG_VALUE (121) / GET_FF_VALUE (128) over puffin: the READ-ONLY
                // device-config READ probe (#103) — it asks for a key's VALUE and writes none. Gated the
                // same way as 117/118: allowed ONLY while a probe is actually in flight, and the opcode
                // must additionally satisfy DeviceConfigReadProbe.isReadOnlyOpcode, the same predicate a
                // unit test proves rejects SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119). Those two
                // keep their own separate opt-in clauses below and are never sent from this path. Driven
                // only by probeDeviceConfigValues() (user-initiated, Test Centre gated).
                !(DeviceConfigReadProbe.isReadOnlyOpcode(cmd.rawValue) && deviceConfigReport != null) &&
                // SET_CONFIG / SET_FF_VALUE (120), ENABLE direction — the R22 deep-stream unlock. Allowed
                // only while the deep-data experiment is opted in, and only for a KEY and a VALUE the gate
                // recognises: one of the sixteen R22 flags carrying that key's own enable value. The clause
                // this replaces was opcode-only, so it admitted ANY feature-flag key with ANY value for as
                // long as the opt-in happened to be on — the same weakness #907 closed on opcode 119.
                // Driven only by enableWhoop5DeepData(). (#174)
                !FeatureFlagWriteGate.admitsEnableWrite(
                    cmd.rawValue, payload, puffinExperiment.isDeepDataEnabled,
                ) &&
                // SET_FF_VALUE (120), DISABLE direction — the undo. Gated on a disable run being in flight
                // rather than on the opt-in, exactly like the 128 read-back clause below, and restricted to
                // FEATURE_FLAG_OFF_VALUE. The opt-in CANNOT gate this: the Settings switch writes the pref
                // false before it raises the confirmation dialog, so it is already false by the time the
                // user confirms the undo the switch itself offered — gating on it made the whole toggle-off
                // path dead. Driven only by disableWhoop5DeepData(). (#174)
                !FeatureFlagWriteGate.admitsDisableWrite(
                    cmd.rawValue, payload, r22DisableRun != null,
                ) &&
                // GET_FF_VALUE (128) as the disable run's mandatory READ-BACK. Gated on a disable run being
                // in flight, exactly like the read probes' 121/128 clause above, so a default install can
                // never form these bytes. The write ack is not trusted; this is what proves the clear.
                !(FeatureFlagWriteGate.isReadBackOpcode(cmd.rawValue) && r22DisableRun != null) &&
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
            val s = seq.incrementAndGet() and 0xFF
            val frame = Framing.puffinCommandFrame(cmd = puffinCmd, seq = s, payload = puffinPayload)
            enqueueWrite(PendingWrite(frame, withResponse, cmd))
            val cmdNote = if (isHaptics) " cmd=0x13" else ""
            log("→ ${cmd.name} payload=${puffinPayload.toHex()} (puffin$cmdNote)")
            return
        }
        val s = seq.incrementAndGet() and 0xFF
        val frame = Framing.buildCommand(cmd, payload, s)
        enqueueWrite(PendingWrite(frame, withResponse, cmd))
        log("→ ${cmd.name} payload=${payload.toHex()}")
    }

    /**
     * Fire a preset haptic buzz on the strap.
     * Port of the Swift contract's `buzz(loops:)`:
     * RUN_HAPTICS_PATTERN(79) with payload `[patternId=2, loops, 0, 0, 0]`.
     * patternId=2 is the graduated alarm buzz the official WHOOP app uses.
     * Used by scheduled cues (intervals, Breathe, notification mirrors); for a user-facing
     * "buzz the strap now" action use [buzzStrapOnce] instead (#921).
     */
    fun buzz(loops: Int = 2) {
        val n = loops.coerceIn(0, 255)
        send(CommandNumber.RUN_HAPTICS_PATTERN, byteArrayOf(2, n.toByte(), 0, 0, 0))
        log("Buzz: patternId=2 loops=$n")
    }

    /**
     * One-shot user buzz (#921): the on-device-confirmed "vibrate the strap now" sequence, the twin
     * of Swift `BLEManager.buzzStrapOnce()`. RUN_HAPTICS_PATTERN(79) with `[patternId=2, loops=3,
     * 0, 0, 0]` followed by RUN_ALARM(68) `[0x01]` as a belt-and-suspenders; a bare pattern write is
     * exactly what a WHOOP 4.0 was reported ignoring on the iOS shortcut path, and the Live-screen
     * Buzz button used the same bare write here.
     *
     * Both writes are ACKNOWLEDGED (withResponse = true): a busy link can silently drop a
     * without-response write, which logs the command with no vibration.
     *
     * 5/MG: [send] remaps cmd 79 to the maverick 0x13 notify buzz (hardware-confirmed), but the
     * Android 5/MG allow-list does NOT include RUN_ALARM, so the follow-up is WHOOP 4.0 only here.
     * That gate is intentional and unchanged; the maverick buzz alone is the confirmed 5/MG one-shot.
     */
    fun buzzStrapOnce() {
        send(CommandNumber.RUN_HAPTICS_PATTERN, byteArrayOf(2, 3, 0, 0, 0), withResponse = true)
        if (connectedFamily == DeviceFamily.WHOOP5) {
            log("Buzz: one-shot fired (5/MG maverick buzz, acked)")
            return
        }
        send(CommandNumber.RUN_ALARM, byteArrayOf(0x01), withResponse = true)
        log("Buzz: one-shot fired (patternId=2 loops=3 + RUN_ALARM, acked)")
    }

    /**
     * Tell the strap to STOP an in-progress haptic pattern (#769). The Breathe biofeedback loop schedules
     * a stream of buzzes; ending the session stops scheduling NEW pulses but cannot recall a pattern the
     * strap is already mid-way through. If the link then drops mid-pattern, the strap's haptic/UI manager
     * can be left wedged with no app able to clear it. STOP_HAPTICS (cmd 122, payload [0x00]) is the
     * documented, reversible clear for WHOOP 4.0.
     *
     * WHOOP 5/MG CAVEAT: the 5/MG buzz rides the maverick 0x13 path (a one-shot, not a sustained pattern),
     * and we have NOT confirmed the 5/MG honours cmd 122 there. [send] does not allow-list 122 for the
     * 5/MG family, so on a 5/MG this is a no-op (logged "skipped"), not a guessed write. So it is
     * BEST-EFFORT: it reliably clears a wedged WHOOP 4.0; on a 5/MG the one-shot buzz already limits the
     * wedge and we deliberately do not invent an unverified stop opcode. Twin of Swift AppModel.stopHaptics.
     * Safe to call always (no-op when not connected or when the family doesn't accept it).
     */
    fun stopHaptics() {
        send(CommandNumber.STOP_HAPTICS, byteArrayOf(0))
        log("Stop haptics (cmd 122)")
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
                    // #577 — also surface the wrist buzz as a local notification (a pocketed phone can't
                    // show it on screen the way the Mac does). Self-gated on the wrist-alerts master.
                    InactivityNotifier.onNudged(context, mins)
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
     * On-device SHORT-NAP detection (reimplemented from @cbarrado's PR #569 under NoopApp identity).
     *
     * Read-only hook on the natural offload completion — the SAME instant [maybeNudgeStress] /
     * [maybeBuzzInactivity] run, so it adds NO cadence of its own. Over the freshly-offloaded daytime
     * window it runs the pure, unit-tested [NapDetector] (dense-gravity eligibility gate → tri-state
     * NAP / NONE / INCONCLUSIVE) and, ONLY on a confident NAP, queues the candidate for review via
     * [NapStore]. It NEVER auto-writes a sleep session: a confirmed nap goes through the user's review
     * card → `addManualNap` (#508), the same overlap-guarded path a hand-corrected nap uses. Honest by
     * construction: an INCONCLUSIVE window queues nothing.
     *
     * Self-gates on the NapPrefs toggle (default OFF, opt-in), so it's fully inert until enabled.
     */
    private fun maybeDetectNaps() {
        if (!NapPrefs.enabled(context)) return   // cheap master gate before any DB work
        ioScope.launch {
            try {
                val nowSec = System.currentTimeMillis() / 1000L
                // Look back over the freshly-offloaded daytime window (the same lookback the inactivity /
                // stress hooks read), so a brief afternoon nap that just landed gets judged.
                val from = nowSec - INACTIVITY_LOOKBACK_S
                val grav = runCatching { repository.gravitySamples(deviceId, from, nowSec) }.getOrDefault(emptyList())
                if (grav.isEmpty()) return@launch
                val hr = runCatching { repository.hrSamples(deviceId, from, nowSec) }.getOrDefault(emptyList())
                // Honest resting band: the newest daily metric's resting HR, or null (the engine then
                // leans on motion alone at lower confidence — it never fabricates a band).
                val restingHr = runCatching {
                    repository.days(deviceId).mapNotNull { it.restingHr }.lastOrNull()
                }.getOrNull()

                // High-water mark: never surface a nap whose window ended before nap detection first ran
                // (a deep first-offload backlog would otherwise dredge up days of old naps). Seeded to
                // "now" on the first read.
                val highWater = NapPrefs.highWaterOrSeed(context, nowSec)

                val decision = NapDetector.evaluate(
                    gravity = grav,
                    hr = hr.map { HrRow(it.ts, it.bpm) },
                    restingHr = restingHr,
                    config = NapPrefs.config(context),
                )
                if (decision.verdict == NapVerdict.NAP && decision.candidate != null &&
                    decision.candidate.end > highWater
                ) {
                    val queued = NapStore.enqueue(context, decision.candidate, nowSec)
                    // Advance the mark past this nap's window so the same window isn't re-judged on the next
                    // overlapping offload — whether or not it newly queued (a dup the user already saw or
                    // dismissed is still "past"). NapStore's own dedup is the belt to this braces.
                    NapPrefs.setHighWaterTs(context, decision.candidate.end)
                    if (queued) {
                        val mins = decision.candidate.durationS / 60
                        log("Nap detection: queued a ~$mins-min nap for review.")
                    }
                }
            } catch (t: Throwable) {
                log("Nap detection: check failed (${t.message})")
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
            _state.update { it.copy(renameStatus = "Renaming is WHOOP 4.0 only.") }
            log("Strap rename: WHOOP 4.0 only — ignored.")
            return
        }
        if (!_state.value.connected || !_state.value.bonded) {
            _state.update { it.copy(renameStatus = "Connect and pair your strap first.") }
            return
        }
        if (name.isEmpty()) {
            _state.update { it.copy(renameStatus = "Enter a name first.") }
            return
        }
        // Clamp to 24 UTF-8 bytes on a whole-character boundary (never split a multibyte char), leaving
        // room for the rest of the BLE advertising structure. Mirrors WhoopCommand.advertisingNamePayload.
        var clamped = name
        while (clamped.toByteArray(Charsets.UTF_8).size > 24) clamped = clamped.dropLast(1)
        val payload = byteArrayOf(0, 0) + clamped.toByteArray(Charsets.UTF_8) + byteArrayOf(0)
        send(CommandNumber.SET_ADVERTISING_NAME, payload, withResponse = true)
        log("Strap rename: wrote advertising name=$clamped")
        _state.update { it.copy(
            renameStatus = "Sent - your strap will reboot to apply, then reconnect with the new name.",
        ) }
    }

    // Reboot (user-initiated, confirmation-gated) — see docs/PROTOCOL.md "Destructive commands".

    /** elapsedRealtime (ms) of the last user reboot, or null. Set by [rebootStrap]; consumed by the
     *  disconnect handler (link-up duration = the strap acting on the reboot) and the connect handshake
     *  (the reconnect round-trip). Cleared on reconnect or the no-disconnect watchdog. Twin of macOS
     *  BLEManager.rebootRequestedAt. */
    private var rebootRequestedAtMs: Long? = null
    private var rebootWatchdog: Runnable? = null
    private var rebootSettle: Runnable? = null

    /** Clear all reboot-in-flight state: the pending timestamp, both timers, and the `rebootInProgress`
     *  flag that drives the Devices "Reconnecting…" pill. Called from every terminal path (reconnect,
     *  no-disconnect, settle backstop) so the pill can never wedge. Twin of macOS clearRebootState. */
    private fun clearRebootState() {
        rebootRequestedAtMs = null
        rebootWatchdog?.let { handler.removeCallbacks(it) }; rebootWatchdog = null
        rebootSettle?.let { handler.removeCallbacks(it) }; rebootSettle = null
        if (_state.value.rebootInProgress) _state.update { it.copy(rebootInProgress = false) }
    }

    /**
     * Restart the connected strap (REBOOT_STRAP / opcode 29, empty body). Non-destructive: the strap keeps
     * its stored data and re-advertises after boot; the BLE link drops and NOOP auto-reconnects. Gated to a
     * connected + bonded strap; user-initiated and confirmation-gated at the call site (DevicesScreen).
     * Twin of macOS BLEManager.rebootStrap — emits the same reboot trail (request / sent / ack / link
     * dropped / reconnected) so a "restart did nothing" report, especially on the unverified 5/MG puffin
     * framing, is triageable from a strap log.
     */
    fun rebootStrap() {
        // Production Restart: opcode 29 REBOOT_STRAP, empty body per the official app's builder.
        // Confirmed on WHOOP 5.0 (#227); ignored on 4.0 (#235 — see rebootProbe).
        sendRebootFrame(CommandNumber.REBOOT_STRAP, byteArrayOf(), null)
    }

    /** Send one candidate reboot frame from the WHOOP 4.0 reboot probe (Test Centre → Connection).
     *  WHOOP 4.0 only — a 5.0 already reboots on the production frame (#227), so there is nothing to
     *  probe there. Reuses the full reboot watchdog/trail so the strap log shows whether THIS candidate
     *  dropped the link (`reboot: link dropped …`) or was ignored (`reboot: no disconnect within 12s …`).
     *  Confirmation-gated at the call site (DevicesScreen). Twin of macOS BLEManager.rebootProbe. */
    fun rebootProbe(variant: RebootProbeVariant) {
        if (connectedFamily != DeviceFamily.WHOOP4) {
            log("reboot: probe is WHOOP 4.0 only — ignored (family=$connectedFamily)")
            return
        }
        sendRebootFrame(variant.command, variant.payload, variant)
    }

    /** #592 opcode probe: send the read-only GET_EXTENDED_BATTERY_INFO(98) and let the COMMAND_RESPONSE
     *  hook dump the full raw reply to the strap log. The number is disputed (an APK decompile reads 87);
     *  a battery-shaped payload in the reply confirms 98 on this firmware, a short generic stub keeps it
     *  ambiguous. Works on both families (the 4.0 is the discriminating device — its firmware banks real
     *  EXTENDED_BATTERY_INFORMATION event payloads; the 5.0 answered 98 with a stub on fw 50.38.1.0).
     *  User-initiated only (Devices → strap menu, Test Centre → Connection gated); never automatic. */
    fun probeExtendedBatteryInfo() {
        if (!_state.value.connected) {
            log("Extended-battery probe (#592) ignored — not connected")
            return
        }
        // Sentinel so the Devices dialog can show "waiting for the strap's reply…" until the response lands
        // (or the user closes it). The COMMAND_RESPONSE hook overwrites this with the decoded result text.
        _extendedBatteryProbe.value = WAITING_EXTENDED_BATTERY_PROBE
        log("Extended-battery probe (#592): sending GET_EXTENDED_BATTERY_INFO(98, read-only) on family=$connectedFamily; the raw COMMAND_RESPONSE is dumped below when it lands")
        send(CommandNumber.GET_EXTENDED_BATTERY_INFO)
        // #592: if NO COMMAND_RESPONSE for 98 arrives within the window, the silence is itself the verdict —
        // the firmware served no reply, which is evidence AGAINST 98 (toward the decompile's 87). Surface +
        // log that instead of a dialog stuck on "waiting" forever. Guarded on the value still being the
        // sentinel, so a real reply (which overwrites it) is never clobbered by this late timeout.
        handler.postDelayed({
            val msg = "Extended-battery probe (#592): no COMMAND_RESPONSE for opcode 98 within " +
                "${EXTENDED_BATTERY_PROBE_TIMEOUT_MS / 1000}s — the strap served no reply. That silence " +
                "is evidence AGAINST 98 on this firmware (toward the decompile's 87); a gated 87 probe is " +
                "the follow-up. (If a sync/offload was mid-flight the response can be delayed — retry idle.)"
            // ATOMIC compare-and-set: only replace the still-waiting sentinel. If a real reply landed on the
            // binder thread in the meantime (even microseconds before this fires at the timeout boundary),
            // it already overwrote the value and the CAS fails — so a genuine capture is never clobbered by
            // a late "no reply". Log only when the CAS actually wins.
            if (_extendedBatteryProbe.compareAndSet(WAITING_EXTENDED_BATTERY_PROBE, msg)) log(msg)
        }, EXTENDED_BATTERY_PROBE_TIMEOUT_MS)
    }

    /** Clear the #592 probe result (Devices dialog dismissed). */
    fun clearExtendedBatteryProbe() { _extendedBatteryProbe.value = null }

    /** #690 opcode probe: send the read-only GET_BODY_LOCATION_AND_STATUS(84) and let the COMMAND_RESPONSE
     *  hook decode + surface it. User-initiated (Test Centre gated). Never changes wear/scoring. */
    fun probeBodyLocationAndStatus() {
        if (!_state.value.connected) {
            log("Body-location probe (#690) ignored — not connected")
            return
        }
        _bodyLocationProbe.value = WAITING_BODY_LOCATION_PROBE
        log("Body-location probe (#690): sending GET_BODY_LOCATION_AND_STATUS(84, read-only) on family=$connectedFamily; the raw COMMAND_RESPONSE is dumped below when it lands")
        send(CommandNumber.GET_BODY_LOCATION_AND_STATUS)
        // If NO COMMAND_RESPONSE for 84 arrives in the window, the silence is itself the verdict (the strap
        // served no reply / doesn't implement it on this firmware). ATOMIC compare-and-set so a real reply
        // landing microseconds before the timeout is never clobbered.
        handler.postDelayed({
            val msg = "Body-location probe (#690): no COMMAND_RESPONSE for opcode 84 within " +
                "${BODY_LOCATION_PROBE_TIMEOUT_MS / 1000}s — the strap served no reply (it may not implement " +
                "0x54 on this firmware). Retry idle if a sync/offload was mid-flight."
            if (_bodyLocationProbe.compareAndSet(WAITING_BODY_LOCATION_PROBE, msg)) log(msg)
        }, BODY_LOCATION_PROBE_TIMEOUT_MS)
    }

    /** Clear the #690 probe result (Devices dialog dismissed). */
    fun clearBodyLocationProbe() { _bodyLocationProbe.value = null }

    /**
     * #761 read-only probe: ask the strap to ENUMERATE the feature-flag key names its firmware knows —
     * `START_FF_KEY_EXCHANGE(117)` for the count, then `SEND_NEXT_FF(118)` repeatedly (its body is a
     * cursor, not an index) until the strap's own end marker. NOTHING is written: no `SET_FF_VALUE(120)`,
     * no `SET_DEVICE_CONFIG_VALUE(119)`, no value of any kind — this writes command frames purely to read,
     * exactly like the Oura feature-status probes NOOP already ships. `GET_FF_VALUE(128)` is deliberately
     * NOT sent (its reply's value field is reported unreliable — see [FeatureFlagProbe]).
     *
     * The strap's own key list is the direct evidence #103 lacks: if a 5/MG names no oxygen-related flag,
     * Blood Oxygen is not client-writable; if it names one, that is the answer outright. The report goes
     * to the Devices dialog and the strap log — no new storage. User-initiated only, Test Centre →
     * Connection gated at the call site. Twin of macOS BLEManager.probeFeatureFlags().
     */
    fun probeFeatureFlags() {
        if (!_state.value.connected) {
            log("Feature-flag probe (#761) ignored — not connected")
            return
        }
        // Defence in depth: the menu entry is already Test-Centre gated, but the sender re-checks so no
        // other path can start a probe on a default install (twin of the macOS guard).
        //
        // On WHOOP 4.0 this check is the ONLY thing standing between a default install and 117/118 on the
        // wire: the send() allowlist that also gates them is the 5/MG path, and 4.0 has no allowlist. So
        // this guard is not merely belt-and-braces on every family — for the family most likely to run
        // this first, it is the belt.
        if (!testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
            log("Feature-flag probe (#761) ignored — Test Centre → Connection is off")
            return
        }
        if (featureFlagReport != null) {
            log("Feature-flag probe (#761) ignored — a probe is already walking the list")
            return
        }
        featureFlagReport = FeatureFlagProbeReport(connectedFamily)
        _featureFlagProbe.value = WAITING_FEATURE_FLAG_PROBE
        log(
            "Feature-flag probe (#761): sending START_FF_KEY_EXCHANGE(117, read-only) on " +
                "family=$connectedFamily; no value is written (SET_FF_VALUE/120 is never sent from this path)",
        )
        sendFeatureFlagStep(CommandNumber.START_FF_KEY_EXCHANGE)
    }

    /** Send one read-only enumeration command and arm the per-step reply window. */
    private fun sendFeatureFlagStep(cmd: CommandNumber) {
        featureFlagStep += 1
        featureFlagAwaiting = cmd.rawValue
        val step = featureFlagStep
        send(cmd, FeatureFlagProbe.REQUEST_BODY)
        // A reply that already landed advanced featureFlagStep, so this stale closure no-ops (the same
        // guard the #592/#690 timeouts use, expressed as a step check because the walk has many hops).
        handler.postDelayed({
            if (featureFlagReport != null && featureFlagStep == step && featureFlagAwaiting != null) {
                featureFlagReport?.noteTimeout(cmd.rawValue, (FEATURE_FLAG_PROBE_TIMEOUT_MS / 1000).toInt())
                finishFeatureFlagProbe()
            }
        }, FEATURE_FLAG_PROBE_TIMEOUT_MS)
    }

    /** Render + publish + log the report and end the probe (which also re-closes the send() allowlist). */
    private fun finishFeatureFlagProbe() {
        val report = featureFlagReport ?: return
        featureFlagReport = null
        featureFlagAwaiting = null
        val text = report.render()
        log("Feature-flag probe (#761):\n$text")
        _featureFlagProbe.value = text
    }

    /** Clear the #761 probe result (Devices dialog dismissed). */
    fun clearFeatureFlagProbe() { _featureFlagProbe.value = null }

    /**
     * #103 read-only probe: ask the strap for config VALUES — `GET_DEVICE_CONFIG_VALUE(121)` and
     * `GET_FF_VALUE(128)`, one key per round-trip. The #761 probe asked the strap for key NAMES in the
     * feature-flag namespace; this asks for a named key's VALUE, and reaches the DEVICE-CONFIG namespace
     * (the one `SET_DEVICE_CONFIG_VALUE`/119 writes) that 117/118 never covered.
     *
     * NOTHING is written: no `SET_FF_VALUE(120)`, no `SET_DEVICE_CONFIG_VALUE(119)`, no value of any kind
     * — this writes command frames purely to read, exactly like the Oura feature-status probes NOOP
     * already ships.
     *
     * **Both target opcodes may simply be unimplemented.** The probe spends one round-trip per verb
     * establishing that before it does anything else, and a clean "neither verb is served" is a useful
     * result. Only a verb that answers goes on to read the sixteen known flag values and the short list
     * of guessed oxygen key names. The report goes to the Devices dialog and the strap log — no new
     * storage. User-initiated only, Test Centre → Connection gated at the call site. Twin of macOS
     * BLEManager.probeDeviceConfigValues().
     */
    fun probeDeviceConfigValues() {
        if (!_state.value.connected) {
            log("Device-config read probe (#103) ignored — not connected")
            return
        }
        // Defence in depth: the menu entry is already Test-Centre gated, but the sender re-checks so no
        // other path can start a probe on a default install (twin of the macOS guard).
        if (!testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
            log("Device-config read probe (#103) ignored — Test Centre → Connection is off")
            return
        }
        if (deviceConfigReport != null) {
            log("Device-config read probe (#103) ignored — a probe is already walking its plan")
            return
        }
        deviceConfigReport = DeviceConfigReadProbeReport(
            connectedFamily,
            // The flag names come from NOOP's own R22 sequence — never restated here.
            Whoop5Config.enableR22Sequence.map { it.name },
            DeviceConfigReadProbe.OXYGEN_CANDIDATE_KEYS,
        )
        _deviceConfigProbe.value = WAITING_DEVICE_CONFIG_PROBE
        log(
            "Device-config read probe (#103): asking for config VALUES via GET_DEVICE_CONFIG_VALUE(121) + " +
                "GET_FF_VALUE(128) on family=$connectedFamily; read-only (SET_FF_VALUE/120 and " +
                "SET_DEVICE_CONFIG_VALUE/119 are never sent from this path)",
        )
        advanceDeviceConfigProbe()
    }

    /** Send the next planned read, or finish when the plan is done. */
    private fun advanceDeviceConfigProbe() {
        val step = deviceConfigReport?.nextStep()
        if (step == null) {
            finishDeviceConfigProbe()
            return
        }
        val cmd = CommandNumber.fromRaw(step.opcode)
        if (cmd == null || !DeviceConfigReadProbe.isReadOnlyOpcode(step.opcode)) {
            // Unreachable with the plan as written; failing closed here means a future edit that widened
            // the plan cannot put a non-read opcode on the wire.
            log("Device-config read probe (#103): refusing to send opcode ${step.opcode} — not a read verb")
            finishDeviceConfigProbe()
            return
        }
        deviceConfigStep += 1
        deviceConfigAwaiting = step
        val armed = deviceConfigStep
        send(cmd, DeviceConfigReadProbe.requestBody(step.key))
        // A reply that already landed advanced deviceConfigStep, so this stale closure no-ops.
        handler.postDelayed({
            if (deviceConfigReport != null && deviceConfigStep == armed && deviceConfigAwaiting != null) {
                deviceConfigAwaiting = null
                deviceConfigReport?.noteTimeout(step, (DEVICE_CONFIG_PROBE_TIMEOUT_MS / 1000).toInt())
                // A silent verb is retired by the report, so the plan skips its remaining steps rather
                // than spending another eight seconds on each of them.
                advanceDeviceConfigProbe()
            }
        }, DEVICE_CONFIG_PROBE_TIMEOUT_MS)
    }

    /** Render + publish + log the report and end the probe (which also re-closes the send() allowlist). */
    private fun finishDeviceConfigProbe() {
        val report = deviceConfigReport ?: return
        deviceConfigReport = null
        deviceConfigAwaiting = null
        val text = report.render()
        log("Device-config read probe (#103):\n$text")
        _deviceConfigProbe.value = text
    }

    /** Clear the #103 probe result (Devices dialog dismissed). */
    fun clearDeviceConfigProbe() { _deviceConfigProbe.value = null }

    /**
     * #103: one COMMAND_RESPONSE for 121/128. Guarded on a probe being IN-FLIGHT (like #690/#761) so a
     * stray byte match can never surface a result. Parsing — including the CRC gate — lives in the pure
     * [DeviceConfigReadProbe]; a frame that fails any check retires that verb with a named reason instead
     * of being decoded. Twin of macOS BLEManager.handleDeviceConfigProbeResponse.
     */
    private fun handleDeviceConfigProbeResponse(frame: ByteArray) {
        if (deviceConfigReport == null) return
        val step = deviceConfigAwaiting ?: return
        deviceConfigAwaiting = null
        val parsed = DeviceConfigReadProbe.parse(frame, connectedFamily, step.opcode)
        val value = parsed.value
        if (value != null) {
            deviceConfigReport?.noteReply(value, step)
        } else {
            deviceConfigReport?.noteFailure(parsed.failure!!, step)
        }
        advanceDeviceConfigProbe()
    }

    /**
     * #761: one COMMAND_RESPONSE for 117/118. Guarded on a probe being IN-FLIGHT (like #690) so a stray
     * byte match can never surface a result. Parsing — including the CRC gate — lives in the pure
     * [FeatureFlagProbe]; a frame that fails any check ends the walk with a named reason instead of being
     * decoded. Twin of macOS BLEManager.handleFeatureFlagProbeResponse.
     */
    private fun handleFeatureFlagProbeResponse(frame: ByteArray) {
        if (featureFlagReport == null) return
        val awaiting = featureFlagAwaiting ?: return
        featureFlagAwaiting = null
        if (awaiting == CommandNumber.START_FF_KEY_EXCHANGE.rawValue) {
            val parsed = FeatureFlagProbe.parseStart(frame, connectedFamily)
            val start = parsed.value
            if (start != null) {
                featureFlagReport?.noteStart(start)
                sendFeatureFlagStep(CommandNumber.SEND_NEXT_FF)
            } else {
                featureFlagReport?.noteFailure(parsed.failure!!, awaiting)
                finishFeatureFlagProbe()
            }
            return
        }
        val parsed = FeatureFlagProbe.parseNext(frame, connectedFamily)
        val next = parsed.value
        if (next == null) {
            featureFlagReport?.noteFailure(parsed.failure!!, awaiting)
            finishFeatureFlagProbe()
            return
        }
        if (featureFlagReport?.noteNext(next) == true) {
            sendFeatureFlagStep(CommandNumber.SEND_NEXT_FF)
        } else {
            finishFeatureFlagProbe()
        }
    }

    /** Shared reboot send + debug trail + watchdog, used by both the production [rebootStrap] and the
     *  4.0 [rebootProbe]. `probe == null` is the normal restart; a non-null variant is a probe attempt
     *  (its `logTag` is stamped first so the strap log correlates the attempt with what the strap did).
     *  Twin of macOS BLEManager.sendRebootFrame. */
    private fun sendRebootFrame(command: CommandNumber, payload: ByteArray, probe: RebootProbeVariant?) {
        val family = connectedFamily
        if (!_state.value.connected || !_state.value.bonded || gatt == null) {
            log("reboot: connect + bond first — ignored (connected=${_state.value.connected} bonded=${_state.value.bonded})")
            return
        }
        // Supersede any still-pending reboot (cancels its timers + resets the flag) so a repeat tap can't
        // leave a stale watchdog/settle timer that fires during this new reboot's window.
        clearRebootState()
        // The logged opcode is always the command's on-wire value — never a separate field that could
        // disagree with the bytes actually sent.
        val opcode = command.rawValue
        val framing = if (family == DeviceFamily.WHOOP5) "puffin-crc16 (verified on 5.0 fw 50.40.1.0)" else "harvard-crc8 (UNVERIFIED on 4.0)"
        val fw = _state.value.strapFirmware ?: "unknown"
        val payloadDesc = if (payload.isEmpty()) "empty" else payload.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        if (probe != null) log("reboot: PROBE ${probe.logTag} — trying an unconfirmed WHOOP 4.0 reboot frame (#235)")
        log("reboot: request family=$family fw=$fw connected=true bonded=true")
        log("reboot: sent opcode=$opcode framing=$framing payload=$payloadDesc writeType=withResponse")
        // withResponse so the ATT write is acked before the strap drops the link.
        send(command, payload, withResponse = true)
        rebootRequestedAtMs = SystemClock.elapsedRealtime()
        // Drive the Devices "Reconnecting…" pill: true until the strap reconnects (or a terminal path
        // clears it). The pill only shows it once the link actually drops (it gates on !connected).
        _state.update { it.copy(rebootInProgress = true) }
        rebootWatchdog?.let { handler.removeCallbacks(it) }
        // No-disconnect watchdog: still connected after 12s ⇒ the strap didn't act on the command (the key
        // signal that a 5/MG puffin reboot frame was silently rejected). A real reboot drops within ~1-2s
        // when idle; a strap mid-offload finishes the transfer first (observed ~9s on 5.0 fw 50.40.1.0), so
        // 12s is the cutoff, not the expected latency.
        val work = Runnable {
            if (rebootRequestedAtMs != null && _state.value.connected) {
                log("reboot: no disconnect within 12s — strap may have ignored the command" +
                    if (connectedFamily == DeviceFamily.WHOOP5) " (5/MG reboot is verified on 5.0 fw 50.40.1.0; if your firmware differs, please share this log on #166)" else " (the WHOOP 4.0 reboot frame is NOT confirmed yet — please share this log on #235)")
                clearRebootState()
            }
        }
        rebootWatchdog = work
        handler.postDelayed(work, 12_000)
        // Absolute settle backstop: if the reboot never resolves (link dropped but the strap never comes
        // back), clear the pill after 60s so it can't wedge on "Reconnecting…". A normal reboot+reconnect
        // clears it earlier via noteRebootReconnectIfNeeded.
        val settle = Runnable {
            if (_state.value.rebootInProgress) {
                log("reboot: not settled within 60s — clearing the reconnecting state")
                clearRebootState()
            }
        }
        rebootSettle = settle
        handler.postDelayed(settle, 60_000)
    }

    /** Closes the reboot trail: when the connect handshake completes and a reboot was in flight, log the
     *  full round-trip (send → reboot → reconnect) and clear the pending state. No-op otherwise. Twin of
     *  macOS BLEManager.noteRebootReconnectIfNeeded. */
    private fun noteRebootReconnectIfNeeded() {
        val t = rebootRequestedAtMs ?: return
        val s = (SystemClock.elapsedRealtime() - t) / 1000.0
        log("reboot: reconnected %.1fs after send — round trip complete".format(s))
        clearRebootState()   // clears the "Reconnecting…" pill → back to "Active · Live"
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
    /**
     * #520: read the strap's DIS identity so a WHOOP MG can be told apart from a plain 5.0.
     *
     * Post-handshake ONLY (a 5/MG refuses standard reads on an unencrypted link — the same reason the
     * battery read is deferred), 5/MG ONLY (a 4.0 issues no new reads at all), and ONCE per connection:
     * serial and hardware revision are immutable, so unlike the battery they are never re-polled.
     *
     * Android serializes GATT operations, so the two reads are CHAINED, not fired together — the
     * hardware-revision read is issued from [onInbound] once the serial lands. Firing both here would
     * silently drop the second. Read-only and non-fatal: any failure just leaves the variant UNKNOWN.
     */
    fun readDisIdentity() {
        if (disRead) return
        val g = gatt ?: return
        if (connectedFamily == DeviceFamily.WHOOP4) return
        val ops = gattOps ?: return
        val ch = g.getService(DIS_SERVICE)?.getCharacteristic(DIS_SERIAL_CHAR)
        if (ch != null && (ch.properties and BluetoothGattCharacteristic.PROPERTY_READ) != 0) {
            disRead = true
            safeGatt("readCharacteristic(dis-serial)") { ops.readCharacteristicCompat(ch) }
        } else {
            log("DIS: serial characteristic unavailable — hardware variant stays unknown")
        }
    }

    /** Chained second half of [readDisIdentity] — issued only after the serial read has landed. */
    private fun readDisHardwareRevision() {
        val g = gatt ?: return
        val ops = gattOps ?: return
        val ch = g.getService(DIS_SERVICE)?.getCharacteristic(DIS_HW_REV_CHAR) ?: return
        if ((ch.properties and BluetoothGattCharacteristic.PROPERTY_READ) != 0) {
            safeGatt("readCharacteristic(dis-hwrev)") { ops.readCharacteristicCompat(ch) }
        }
    }

    /**
     * Resolve + log the 5/MG hardware variant from whatever DIS strings have landed (#520). Diagnostic
     * only — nothing gates on it yet.
     *
     * The serial is a device identifier, so ONLY its 3-character prefix is logged (that is the entire
     * information content here) — never the full string, which would end up in a shareable strap log.
     */
    private fun noteWhoop5VariantFromDis() {
        val variant = Whoop5Variant.from(disSerial, disHwRev)
        val prefix = disSerial?.trim()?.uppercase()?.take(3) ?: "?"
        log("DIS: serialPrefix=$prefix hwRev=${disHwRev ?: "?"} -> variant=${variant.label}")
    }

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
     * strap's RTC is UTC-correct (a wrong RTC fires the alarm at the wrong wall-clock time). The 4.0
     * payload is `[0x01] + u32 LE epoch + [0x00, 0x00] + [0x00, 0x00]` (9 bytes — see
     * [whoop4AlarmPayload]; the trailing two bytes are the haptic-mode field the official app sends,
     * added per @ujix's wire capture #535). Port of macOS `BLEManager.armStrapAlarm`. WHOOP 4.0; on
     * 5/MG `send()` uses the separate REVISION_4 path.
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
            recordAlarmArm(epochSec)
            log(if (_state.value.connected) "Alarm: armed 5/MG rev4 EXPERIMENTAL (epoch $epochSec)"
                else "Alarm: queued 5/MG rev4 EXPERIMENTAL (epoch $epochSec) — strap not connected")
            return
        }
        sendSetClockBothForms()
        send(CommandNumber.SET_ALARM_TIME, whoop4AlarmPayload(epochSec))
        recordAlarmArm(epochSec)
        // #34: only claim "armed" when the strap is connected (the send actually went out); otherwise it's
        // queued and re-sent on the next connect.
        if (_state.value.connected) log("Alarm: armed (epoch $epochSec)")
        else log("Alarm: queued (epoch $epochSec) — strap not connected; will send on next connect")
        // Arm READBACK (#401 close-out): ask the strap what it now has armed (GET_ALARM_TIME, cmd 67) so
        // the strap log carries armed + strap-reports + fired as one decidable sequence in any future
        // "didn't buzz" report. WHOOP 4.0 ONLY (this branch): the 5/MG puffin readback semantics are
        // unverified. Log-only: handleFrame parses the cmd-67 COMMAND_RESPONSE defensively
        // ([whoop4ArmedAlarmEpoch]) and NEVER gates behaviour on it (the 4.0 response layout is
        // undocumented; unparseable replies log raw hex). Twin of macOS armStrapAlarm.
        send(CommandNumber.GET_ALARM_TIME, byteArrayOf(0x01))
    }

    /** #34: persist the last alarm arm for the debug export's Alarm block (sent epoch + when + whether the
     *  strap was connected when we sent it), so a "didn't buzz" report shows sent-vs-strap-reports. */
    private fun recordAlarmArm(sentEpoch: Long) {
        runCatching {
            val editor = NoopPrefs.of(context).edit()
                .putLong("alarm.lastArmSentEpoch", sentEpoch)
                .putLong("alarm.lastArmAt", System.currentTimeMillis())
                .putBoolean("alarm.lastArmConnected", _state.value.connected)
            // #34: live HR at the moment of the arm, purely to test a hypothesis raised on a reporter's
            // log — morning wake-up and morning short-horizon arms have fired reliably since v9.0.0, but
            // an identical evening short-horizon arm (same code path, same commands, no day/night branch
            // anywhere in armStrapAlarm) did not. One firmware-side explanation that would fit every
            // reported case: the physical alarm haptic might only fire while the strap's OWN sleep/rest
            // detection considers the wearer sleep-adjacent, independent of anything NOOP sends. This
            // doesn't prove or fix that — it's a free read of state already tracked live, logged so the
            // next reported failure (ideally an evening one) can be compared against the resting HR of
            // the successful arms already on file. Absent key means no HR had streamed yet at arm time.
            val hr = _state.value.heartRate
            if (hr != null) editor.putInt("alarm.lastArmHeartRate", hr) else editor.remove("alarm.lastArmHeartRate")
            editor.apply()
        }
    }

    /** Whether a command written right now would actually reach the strap — the same conditions [send]
     *  guards on. Lets a caller that REPORTS an outcome to the user check first, instead of logging
     *  success for a write that was dropped (#730). Twin of macOS `commandChannelReady`. */
    private val commandChannelReady: Boolean get() = gatt != null && cmdCharacteristic != null

    /** Clear the strap's firmware alarm. Port of macOS `BLEManager.disableStrapAlarm`. */
    fun disableStrapAlarm() {
        // #730: report the OUTCOME, not the intent. [send] drops the write when the link isn't up and logs
        // "ignored — not connected", but this then logged "Alarm: disarmed" anyway — telling the user the
        // firmware alarm was cleared when the command never reached the strap, so a strap that IS armed
        // would still buzz. (reconcileStrapAlarm already re-runs on the bond edge, so a deferred disarm is
        // re-issued once the link is up — Android never had the iOS gap where that re-apply was skipped.)
        val willReach = commandChannelReady
        val notSent = "Alarm: disarm NOT sent — not connected; will retry on connect (strap may still be armed)"
        if (connectedFamily == DeviceFamily.WHOOP5) {
            // 5/MG DISABLE_ALARM is REVISION_2 [0x02, 0xFF]. Sent unconditionally (clearing is safe
            // even if arming was gated off — a no-op on a strap with no alarm set). (PR #85)
            send(CommandNumber.DISABLE_ALARM, AlarmPayload.disableRev2())
            log(if (willReach) "Alarm: disarmed (5/MG rev2)" else notSent)
            return
        }
        send(CommandNumber.DISABLE_ALARM, byteArrayOf(0x01))
        log(if (willReach) "Alarm: disarmed" else notSent)
    }

    // ====================================================================================
    // MARK: Scanning
    // ====================================================================================

    /** Persist the WHOOP family that actually advertised so a later launch/scan starts on the right
     *  service — what makes a one-time fallback rotation stick, and drives the Settings 5/MG-controls
     *  gate off the ACTUALLY-CONNECTED strap (not a stale device-list default). Mirrors macOS
     *  `UserDefaults.set(rawValue, forKey: "selectedWhoopModel")`. Self-contained in the shared
     *  noop_prefs store; failures are non-fatal (the rotation still worked this session). (PR#195)
     *
     *  On a genuine FAMILY switch (4.0 ↔ 5/MG) it also clears the 5/MG-only experimental toggles via
     *  [PuffinExperiment.resetFiveMGGatedProbes], so a 5/MG-only probe (raw capture, R22 deep-data
     *  write, broadcast-HR write) can't stay enabled across a switch and get applied to the wrong,
     *  unsupported strap. Same-family reconnects don't reset (the previous == new guard). */
    private fun persistSelectedModel(model: WhoopModel) {
        try {
            val prefs = context.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
            val previous = prefs.getString("noop.selectedWhoopModel", null)
            prefs.edit().putString("noop.selectedWhoopModel", model.name).apply()
            // Compare the GATT SERVICE, not the enum name — the service UUID is what actually
            // distinguishes the two families. Identical today (WhoopModel is exactly WHOOP4 and
            // WHOOP5_MG), but Whoop5Variant already tells MG from plain 5.0 at the hardware level; if
            // that ever becomes a third WhoopModel it would share WHOOP5_SERVICE, and a name compare
            // would then reset the probes on a 5.0 <-> MG switch — same family, must not reset.
            // runCatching: an unrecognised persisted string is a stale pref, not a family change.
            val previousService = previous?.let { runCatching { WhoopModel.valueOf(it).service }.getOrNull() }
            if (previousService != null && previousService != model.service) {
                // Family actually changed — untick the family-gated probes so nothing carries over.
                // Its own runCatching: the persist above has ALREADY succeeded by this point, so letting
                // a failure here fall into the outer catch would log "couldn't persist" about a write
                // that worked, and hide which half actually broke.
                runCatching { PuffinExperiment.from(context).resetFiveMGGatedProbes() }
                    .onSuccess {
                        log("Strap family switched ($previous → ${model.name}) — reset 5/MG-only " +
                            "experimental toggles (protocol probes, raw capture, deep-data, broadcast HR) to off.")
                    }
                    .onFailure {
                        log("Strap family switched ($previous → ${model.name}) but couldn't reset the " +
                            "5/MG-only toggles: ${it.message} — they may still be on for the wrong family.")
                    }
            }
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
            // #716: the seeded "my-whoop" device has model "WHOOP" (no generation). Once a live
            // scan confirms which service family the strap advertises, stamp the correct model so
            // forRegistryModel returns the right DeviceFamily (fixes skin-temp ADC scale + display).
            if (!modelStamped) {
                modelStamped = true
                ioScope.launch {
                    val stale = repository.pairedDevices().firstOrNull {
                        it.status == "active" && it.model == "WHOOP"
                    }
                    if (stale != null) {
                        val correct = if (selectedModel == WhoopModel.WHOOP4) "WHOOP 4.0" else "WHOOP 5.0 / MG"
                        repository.setDeviceModel(stale.id, correct)
                        log("Updated device model from \"WHOOP\" to \"$correct\" (#716)")
                    }
                }
            }
            val advertisedServiceUuids = result.scanRecord?.serviceUuids
                ?.map { it.uuid.toString().lowercase() }
                .orEmpty()
            val scanDecision = whoopGattScanDecision(selectedModel.service.toString(), advertisedServiceUuids)
            if (!scanDecision.shouldConnect) {
                scanDecision.unsupportedFamily?.let { family ->
                    log("Discovered $name (rssi ${result.rssi}) — ${family.diagnosticUnsupportedMessage}")
                    _state.update { it.copy(statusNote = family.diagnosticUnsupportedMessage) }
                    return
                }
                log("Discovered $name (rssi ${result.rssi}) without ${selectedModel.displayName} service — ignoring")
                return
            }
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
            _state.update { it.copy(statusNote = "Found $name, connecting…") }
            // Port of didDiscover: stop scanning, then connect to this peripheral.
            stopScan()
            connectToDevice(device)
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            log("Scan failed: $errorCode")
        }
    }

    /** #313: does the OS still hold [address]'s ACL? getConnectedDevices returns a band the OS keeps
     *  GATT-connected — co-resident with the official WHOOP app — even after it stops advertising, so this
     *  is the "contended, not out of range" signal. Model-agnostic (4.0 + 5.0), matched by exact address.
     *  Fails SAFE to false (→ normal attempt-count escalation, the pre-#313 behaviour) on any lookup issue,
     *  so a detection gap can never be worse than before. */
    @SuppressLint("MissingPermission")
    private fun isStrapAclHeld(address: String): Boolean = try {
        bluetoothManager?.getConnectedDevices(BluetoothProfile.GATT)
            ?.any { it.address.equals(address, ignoreCase = true) } == true
    } catch (se: SecurityException) {
        false
    }

    /** The OS-bonded 5/MG-family strap, if any (name "WHOOP …" but not "WHOOP 4…" — MG-named units
     *  match too). Fails open to a scan on any lookup problem. (#78 fork)
     *
     * A WHOOP 5/MG the OS already holds GATT-connected. Android multiplexes one ACL across GATT clients, so
     * a band connected to another app is still returned by getConnectedDevices even after it stops
     * advertising, and a client can attach to it without a scan. Uses the same 5/MG name filter and
     * multi-strap pin selection as [bondedWhoopDevice]; a WHOOP 4 is excluded and left to the scan. */
    @SuppressLint("MissingPermission")
    private fun getConnectedWhoopDevice(): BluetoothDevice? = try {
        val connected = bluetoothManager?.getConnectedDevices(BluetoothProfile.GATT)?.filter { d ->
            val n = try { d.name } catch (se: SecurityException) { null } ?: return@filter false
            n.startsWith("WHOOP", ignoreCase = true) && !n.startsWith("WHOOP 4", ignoreCase = true)
        }.orEmpty()
        val preferred = preferredAddress
        if (preferred != null) connected.firstOrNull { it.address.equals(preferred, ignoreCase = true) }
        else connected.firstOrNull()
    } catch (se: SecurityException) {
        null
    }

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

    /**
     * Which of OUR OWN paths last tore the link down, and when the current session started (#1020).
     *
     * A local teardown surfaces as GATT status 22 (`GATT_CONN_TERMINATE_LOCAL_HOST`), which the
     * connection trace has always reported as the bare `reason=localTerminate`. At least five paths
     * produce it — the bond watchdog, the keep-alive stall bounce, a user disconnect, releaseStrap, and
     * a safeGatt teardown after a dead binder — and the log could not tell them apart. A report showing
     * thousands of localTerminate reconnects (#1020) therefore could not be diagnosed from the log at
     * all; the existing comment beside the reason string just guesses ("e.g. #971 bond watchdog").
     *
     * Set at each initiating site, cleared when a new session comes up, and printed alongside the
     * reason. @Volatile because the setters run on the main looper and timer callbacks while
     * handleDisconnect reads it from a GATT binder thread on API 26/27.
     */
    @Volatile private var lastLocalTeardown: String? = null

    /** Wall clock when the current session reached STATE_CONNECTED, for the session-duration readout.
     *  0 until the first connect; set on EVERY connect (not gated on the test mode, which is usually
     *  switched on only after something looks wrong) and never cleared on the way down, so read it only
     *  under a `wasConnected` guard. @Volatile for the same reason as [lastLocalTeardown]. */
    @Volatile private var connectedAtMs = 0L

    /** Record which local path is about to drop the link. Unconditional rather than gated on the test
     *  mode, because the clear in the connect path is ungated too - gating one and not the other is what
     *  let a previous session's origin survive. Four of the five call sites pass a literal; `safeGatt`
     *  interpolates the failing op, but that is an exception path where a String allocation is noise
     *  against the teardown it is about to perform. None of the five is on a per-record path. */
    private fun noteLocalTeardown(origin: String) { lastLocalTeardown = origin }

    /** Consecutive involuntary reconnect attempts, feeding the capped-exponential [ReconnectBackoff]
     *  (3, 6, 12, 24, 48, 60s…). Replaces the old fixed [RECONNECT_DELAY_MS] rescan loop so a strap
     *  that's genuinely out of range stops hammering BLE — the Android twin of the iOS
     *  failedConnectAttempts schedule (BLEManager.swift didFailToConnect, #414). Bumped per scheduled
     *  reconnect; reset to 0 on STATE_CONNECTED and on an explicit user Connect. @Volatile because the
     *  GATT callbacks (where it's read/reset) land on binder-pool threads on API 26/27. (#48, adopt
     *  from ryanbr — reimplemented under NoopApp) */
    @Volatile
    private var failedReconnectAttempts = 0

    /** Bump the attempt counter and return the next backoff delay. Called from the disconnect path
     *  in place of the fixed [RECONNECT_DELAY_MS]. */
    private fun nextReconnectDelayMs(): Long {
        failedReconnectAttempts++
        return ReconnectBackoff.nextDelayMs(failedReconnectAttempts)
    }

    /** Clear the backoff so the next reconnect starts back at the 3s base — fired on a successful
     *  connect and on an explicit user-driven Connect (which must not inherit an accumulated delay). */
    fun resetReconnectBackoff() {
        failedReconnectAttempts = 0
    }

    // #1030 (author: ryanbr): make the involuntary-reconnect timer CANCELLABLE so a stale backoff
    // reconnect can't fire after the link is already back and tear down the live connection.
    /** The pending involuntary-reconnect timer, if one is scheduled. Held as a field (NOT an inline
     *  lambda) so a real (re)connect or an explicit user Connect can CANCEL it, and so its body can
     *  no-op if we're already back — otherwise a stale backoff reconnect fires AFTER the link returns
     *  and tears the live connection down (reset+close) or starts a redundant scan. iOS gets this free:
     *  its connectCore() early-returns on an already-connected peripheral; this ports that guard. */
    @Volatile
    private var pendingReconnectRunnable: Runnable? = null

    /** Schedule an involuntary reconnect [action] after [delayMs], replacing any already-pending timer.
     *  When it fires the action is skipped if we've been told to stop (intentional teardown / bond-loop
     *  pause) OR we're already connected-or-connecting — a stale timer must never tear down a live link. */
    private fun scheduleReconnect(delayMs: Long, action: () -> Unit) {
        cancelPendingReconnect()
        val r = Runnable {
            pendingReconnectRunnable = null
            // #78 hole-3: a timer in flight when the give-up trips must not fire an extra attempt.
            if (intentionalDisconnect || autoReconnectPausedForBondLoop) return@Runnable
            // A reconnect that fires AFTER we've re-linked (user Connect / radio-on beat the timer) must
            // not reset+close the live connection or start a redundant scan. handleDisconnect nulls `gatt`
            // and sets connected=false BEFORE scheduling, so a genuinely-disconnected state still proceeds.
            if (gatt != null || _state.value.connected) return@Runnable
            action()
        }
        pendingReconnectRunnable = r
        handler.postDelayed(r, delayMs)
    }

    /** Cancel any pending involuntary reconnect — a real (re)connect superseded it. */
    private fun cancelPendingReconnect() {
        pendingReconnectRunnable?.let { handler.removeCallbacks(it) }
        pendingReconnectRunnable = null
    }

    /** Run [action] after [delayMs], but ONLY if the SAME continuous connection is still up when it fires.
     *  A reconnect (or bond-loop cycle) bumps [connectGeneration], so a transient cycle-connect can't
     *  satisfy the guard even though the device address is identical across cycles. Used by the
     *  STATE_CONNECTED re-pair-guide clear (#711) — clear the guide only once the link proves it survived
     *  the bond-loop's quick-timeout window. */
    private fun runIfConnectionSurvives(delayMs: Long, action: () -> Unit) {
        val gen = connectGeneration
        handler.postDelayed({
            if (_state.value.connected && connectGeneration == gen) action()
        }, delayMs)
    }

    /** Clear the pairing-hint streak + any published hint for a FRESH user-initiated Connect (#78). Kept
     *  off the involuntary-reconnect path on purpose: the streak must SURVIVE automatic reconnects (like
     *  the #52 pinnedBondRefusals counter) so it can accumulate to the threshold across the strap dropping
     *  and re-bonding. Only an explicit user tap (AppViewModel.connect) starts it over. Public so the
     *  ViewModel can call it; a thin wrapper over the private [clearPairingHint]. */
    fun clearPairingHintForUserConnect() = clearPairingHint()

    /** Bonded-handshake watchdog (#50): every other connect phase has a timeout (scan; MTU settle delay;
     *  keep-alive) but the post-discovery bond/CCCD handshake had none — so a WHOOP 4.0 that wedges
     *  in "finishing secure handshake" (OnePlus Nord 2, #50) never bounced, and keep-alive recovery
     *  bails before [didBond]. This bonded-INDEPENDENT watchdog bounces the link if no genuine bond
     *  lands within its window, mirroring the MTU settle delay. #971: the window ESCALATES per consecutive
     *  bounce ([bondWatchdogBackoff]) so a slow-but-healthy bond gets more time, and after a capped number
     *  of bounces we stop bouncing (see [onBondWatchdog]). Armed when service discovery starts; cancelled
     *  on bond and in reset/teardown. */
    private val bondWatchdogRunnable = Runnable { onBondWatchdog() }

    @SuppressLint("MissingPermission")
    /** #1095 diagnostic: the 5/MG bond state at a watchdog fire, so a "connects + reads battery but never
     *  streams health data" report is legible. `writeInFlight=true` here is the smoking gun — the
     *  CLIENT_HELLO confirmed write never got its `onCharacteristicWrite` callback, i.e. the strap went
     *  SILENT (no ACK, and no 5/15 bond refusal that would have surfaced the pairing hint), so the watchdog
     *  is tearing the link down blind. `family=WHOOP5 encryptedBond=false` alongside confirms the 5/MG
     *  never authenticated. Diagnostic-only string; no behaviour change. */
    private fun bondWatchdogContext(): String =
        "(family=$connectedFamily writeInFlight=$writeInFlight didBond=$didBond " +
            "encryptedBond=${_state.value.encryptedBond})"

    private fun onBondWatchdog() {
        // Already bonded (or torn down) — nothing wedged; the cancel sites normally beat us here, but
        // a late post on a binder-pool thread could still fire, so re-check before bouncing.
        if (didBond || gatt == null) return
        // #971: count this bounce. If it crosses the cap, the handshake is genuinely stuck (a slow-but-
        // healthy bond would have landed inside one of the escalating windows by now), so STOP bouncing:
        // a WHOOP 4.0 that connects but never finishes the bond just loops forever otherwise (bond → 7s →
        // our own gatt.disconnect() reports status 0x16 → reconnect → bond → 7s …, and STATE_CONNECTED
        // zeroes the reconnect backoff every cycle so nothing ever backs off). Instead surface the SAME
        // re-pair guide the stale-bond / #617 paths show and PAUSE auto-reconnect (reusing the #747/#844
        // machinery [handleDisconnect] already honours) so the battery stops draining. A user Connect or a
        // genuine bond re-arms it via [bondWatchdogBackoff].reset().
        val gaveUp = bondWatchdogBackoff.recordBounce()
        intentionalDisconnect = false
        if (gaveUp) {
            log("Bond handshake never completed after ${bondWatchdogBackoff.consecutiveBounces} escalating tries " +
                bondWatchdogContext() + " — pausing auto-reconnect and surfacing the re-pair guide (#971)")
            autoReconnectPausedForBondLoop = true
            bondLoopPausedAtMs = System.currentTimeMillis()   // the #78 hole-4 salvage probe covers this pause too
            if (_state.value.reconnectGuide == null) {
                _state.update { it.copy(
                    reconnectGuide = """
                    Your strap connects but never finishes pairing with NOOP. This is almost always a stale Bluetooth pairing, usually after a WHOOP firmware update, or the official WHOOP app holding the strap. NOOP works fine once it's re-paired:

                    1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                    2. Open Settings → Bluetooth, find your WHOOP, and Forget / Unpair it.
                    3. Tap the band repeatedly until its LEDs flash blue (pairing mode).
                    4. Come back here and tap Connect.
                    """.trimIndent()
                ) }
            }
        } else {
            log("Bond handshake stuck for ${bondWatchdogBackoff.currentWindowMs() / 1000}s — bouncing link to retry " +
                "(attempt ${bondWatchdogBackoff.consecutiveBounces}, #50/#971) " + bondWatchdogContext())
            // #1095: a 5/MG whose CLIENT_HELLO confirmed write never ACKs (writeInFlight still true, never
            // bonded) gets NEITHER the 5/15-refusal pairing hint NOR — until the 4-bounce give-up — the
            // re-pair guide, so it loops for ~46s with no advice. Surface a 5/MG-tailored re-pair guide on
            // the 2nd such SILENT bounce (the usual cause is the official app still holding the strap).
            // Guidance STRING ONLY — the loop is unchanged (the give-up still pauses at the cap, and its own
            // `reconnectGuide == null` check won't overwrite this). Unpairing is the right first step for any
            // 5/MG that connects but never bonds, so surfacing it early is safe even before the capture.
            if (connectedFamily == DeviceFamily.WHOOP5 && !didBond && writeInFlight &&
                bondWatchdogBackoff.consecutiveBounces >= 2 && _state.value.reconnectGuide == null
            ) {
                log("WHOOP 5/MG: CLIENT_HELLO never acknowledged across ${bondWatchdogBackoff.consecutiveBounces} silent bounces — surfacing the re-pair guide early (#1095)")
                _state.update { it.copy(reconnectGuide = """
                    Your WHOOP 5.0/MG connects and reads battery, but never finishes pairing with NOOP, so no health data comes through. This is almost always the official WHOOP app still holding the strap (a 5.0 pairs with one phone at a time), or a stale Bluetooth pairing:

                    1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                    2. Open Settings → Bluetooth, find your WHOOP, and Forget / Unpair it.
                    3. Tap the band repeatedly until its LEDs flash blue (pairing mode).
                    4. Come back here and tap Connect.
                    """.trimIndent()) }
            }
        }
        // Drop the link either way: even on give-up we tear down the wedged GATT so it stops holding the
        // radio. gatt.disconnect() throwing on a dead binder (#314) must not crash from a timer — fall
        // through to a clean teardown if it does (mirrors the keep-alive bounce). When we gave up above,
        // [handleDisconnect] takes its paused branch and schedules NO reconnect; otherwise it backoff-
        // reconnects and [armBondWatchdog] arms the NEXT (wider) window from [bondWatchdogBackoff].
        noteLocalTeardown("bondWatchdog")   // #1020: name the origin of the localTerminate that follows
        try {
            gatt?.disconnect()   // → handleDisconnect → reset() (cancels this) → (paused | backoff reconnect)
        } catch (t: Throwable) {
            log("bond watchdog bounce: gatt.disconnect() threw ${t.javaClass.simpleName}; tearing down")
            teardownAfterGattFailure()
        }
    }

    private fun armBondWatchdog() {
        handler.removeCallbacks(bondWatchdogRunnable)
        // #971: escalating window — base 7s on the first handshake, wider on each subsequent bounce, so a
        // slow-but-healthy WHOOP 4.0 bond isn't bounced forever at a too-tight window. The 0-bounce window
        // is exactly the historical BOND_WATCHDOG_MS, so the common first connect is unchanged.
        handler.postDelayed(bondWatchdogRunnable, bondWatchdogBackoff.currentWindowMs())
    }

    private fun cancelBondWatchdog() {
        handler.removeCallbacks(bondWatchdogRunnable)
    }

    // MARK: Multi-WHOOP stale-pin recovery (#52) — Android twin of the iOS bond-fallback. When a pinned
    // strap keeps refusing the encrypted bond but a DIFFERENT WHOOP bonded fine this run, hand the pin to
    // the working strap rather than looping forever on the dead pin (which would also leave buzz/haptics
    // dead, since they gate on encryptedBond). Reimplemented under NoopApp, mirroring BLEManager's
    // pinnedBondRefusals/lastBondedPeripheralUUID/noteGenuineBond/readoptWorkingStrap.

    /** Address of the last strap that reached a GENUINE encrypted bond this run — the live working strap
     *  the registry pin should point at if the pinned one keeps refusing. Null until anything bonds.
     *  @Volatile: written from the GATT bond callback (binder-pool thread on API 26/27). */
    @Volatile
    private var lastBondedAddress: String? = null

    /** Consecutive INSUFFICIENT_AUTH/ENCRYPTION bond refusals on the CURRENTLY PINNED strap. A stale pin
     *  (pointing at a strap bonded elsewhere / not really here) makes [connect] drop the strap that DOES
     *  bond and loop on the dead pin. Counted here; cleared by any genuine bond. @Volatile — same thread
     *  rationale as above. */
    @Volatile
    private var pinnedBondRefusals = 0

    /** Consecutive WHOOP 5/MG encrypted-bond refusals this session, with NO genuine bond reached yet.
     *  Distinct from [pinnedBondRefusals] (which is about a stale multi-WHOOP registry pin): this one
     *  drives the user-facing pairing hint (#78). A 5/MG that's still bonded to the official WHOOP app
     *  keeps refusing the just-works bond, so after two refusals we surface concrete pairing-mode
     *  guidance. Reset to 0 on a genuine bond and on a fresh user-initiated connect. @Volatile — written
     *  from the GATT bond callback (binder-pool thread on API 26/27). */
    @Volatile
    private var bondRefusalStreak = 0

    /** #747 / #750: after the bond is refused persistently, pause auto-reconnect (stop hammering) and write
     *  a one-line epitaph. Fed by the SAME refusal events as [bondRefusalStreak]; its higher give-up
     *  threshold fires once the pairing hint has had several cycles to be acted on. Reset on a genuine bond
     *  or an explicit user reconnect. Twin of iOS `BLEManager.bondGiveUp`. */
    private val bondGiveUp = BondRefusalGiveUp()

    /** True while auto-reconnect is PAUSED by the #747 give-up. handleDisconnect consults this and skips
     *  scheduling a reconnect; a manual connect()/disconnect() clears it via [bondGiveUp].reset(). @Volatile
     *  because it's written from the GATT bond callback and read on the reconnect path. Twin of iOS
     *  `autoReconnectPausedForBondLoop`. */
    @Volatile
    private var autoReconnectPausedForBondLoop = false

    /** When the bond-loop pause last tripped (or last salvage-probed), epoch ms. Drives the #78 hole-4
     *  salvage probe's floor ([BOND_LOOP_SALVAGE_FLOOR_MS] via [shouldSalvageProbe]): a paused strap the
     *  user has since FREED self-heals on the next app-foreground instead of staying disconnected until a
     *  manual Connect, while a still-held strap gets at most one bounded attempt per foreground per floor
     *  window. Set wherever the pause trips (#747 give-up + the #617 bond-then-quick-timeout detector,
     *  deliberately both: probing a #617-paused link costs one bounded cycle and self-heals the same
     *  way); null whenever the pause clears. Never persisted. Twin of iOS `bondLoopPausedAt`. */
    @Volatile
    private var bondLoopPausedAtMs: Long? = null

    /** A genuine bond this run: [address] is a live working strap (re-adopt target), and a bond proves no
     *  stale pin is wedging us — so clear the refusal streak. Twin of iOS `noteGenuineBond`. */
    private fun noteGenuineBond(address: String?) {
        if (address != null) lastBondedAddress = address
        pinnedBondRefusals = 0
    }

    /** Count an encrypted-bond refusal IF it happened on the pinned strap, and once the streak reaches
     *  [PIN_BOND_REFUSAL_LIMIT] hand the pin to a different strap that bonded fine this run. [status] must
     *  be an insufficient-auth/encryption GATT code; other failures (BUSY, etc.) don't implicate the pin.
     *  No-op on the single-WHOOP path ([preferredAddress] null). Twin of the iOS didWriteValueFor block. */
    @SuppressLint("MissingPermission")
    private fun noteBondRefusalIfPinned(failedAddress: String?, status: Int) {
        if (!isInsufficientAuthStatus(status)) return
        if (didBond) return   // a refusal AFTER we already bonded this run isn't a stale-pin signal
        val pinned = preferredAddress ?: return                 // single-WHOOP: nothing to re-adopt
        if (failedAddress == null || !failedAddress.equals(pinned, ignoreCase = true)) return
        pinnedBondRefusals++
        log("Multi-WHOOP: pinned strap $pinned refused the encrypted bond (status=$status, refusal $pinnedBondRefusals/$PIN_BOND_REFUSAL_LIMIT)")
        val working = lastBondedAddress
        if (pinnedBondRefusals >= PIN_BOND_REFUSAL_LIMIT && working != null && !working.equals(pinned, ignoreCase = true)) {
            readoptWorkingStrap(working = working, awayFrom = pinned)
        }
    }

    /** Break out of the dead-pin loop and re-adopt the live-bonding [working] strap (#52), away from the
     *  pinned [awayFrom] one that keeps refusing the encrypted bond. Clears [preferredAddress] so the scan
     *  stops filtering to the dead strap — [working] (and any other WHOOP) is then eligible — and drops the
     *  dead-pin link so the auto-rescan reconnects. On reconnect, STATE_CONNECTED republishes the strap's
     *  address on the [connectedPeripheralAddress] seam the SourceCoordinator observes, so the registry's
     *  identity adoption runs through its normal first-connect path. (The registry re-point itself lives in
     *  the SourceCoordinator; this BLE side just stops the loop and frees the working strap to connect.) */
    @SuppressLint("MissingPermission")
    private fun readoptWorkingStrap(working: String, awayFrom: String) {
        log("Multi-WHOOP: pinned strap $awayFrom unreachable after $pinnedBondRefusals bond refusals — re-adopting the live strap $working")
        pinnedBondRefusals = 0
        // Drop the dead pin so onScanResult no longer ignores every OTHER WHOOP. The app re-asserts a pin
        // from the registry on the next active-device change; until then any bonded WHOOP is acceptable
        // (the single-WHOOP default), which is exactly the recovery we want — [working] can now connect.
        preferredAddress = null
        lastDevice = null   // don't fast-path reconnect to the dead-pin handle; rescan picks the working strap
        // Bonding the dead-pin link is still in teardown here, so route through the normal scan-based
        // connect — onScanResult (pin now null) connects to the working strap when it advertises.
        resetReconnectBackoff()   // a deliberate re-adopt, not an out-of-range retry — start fresh
        intentionalDisconnect = false
        // #1040: the FIFTH local-teardown route, and the only one that was never stamped — so the status-22
        // drop it causes printed `via=unknown`, which the reason doc calls out as meaning exactly this: a
        // teardown path that exists and is not tagged. A multi-WHOOP re-adopt looks identical in the trace
        // to a bond-watchdog bounce without it.
        noteLocalTeardown("readopt")   // #1020
        try {
            gatt?.disconnect()   // drop the dead-pin link → handleDisconnect → rescan (pin cleared)
        } catch (t: Throwable) {
            log("re-adopt: gatt.disconnect() threw ${t.javaClass.simpleName}; tearing down")
            teardownAfterGattFailure()
        }
    }

    /** True for the GATT statuses that mean the strap refused the encrypted bond: INSUFFICIENT_AUTHENTICATION
     *  (5) and INSUFFICIENT_ENCRYPTION (15) — the Android analogue of CoreBluetooth's "Encryption/Authentication
     *  is insufficient" error string the iOS #52 path keys on. */
    private fun isInsufficientAuthStatus(status: Int): Boolean =
        status == GATT_INSUFFICIENT_AUTHENTICATION || status == GATT_INSUFFICIENT_ENCRYPTION

    /** Count a WHOOP 5/MG encrypted-bond refusal toward the pairing-hint streak (#78) and, once it
     *  reaches [BOND_REFUSAL_HINT_THRESHOLD] with no genuine bond yet this session, publish concrete
     *  pairing-mode guidance. WHOOP 4 always reaches a genuine bond, so this is 5/MG-only (matching the
     *  iOS BLEManager, which only sets pairingHint on the puffin link). Independent of the multi-WHOOP
     *  pin recovery in [noteBondRefusalIfPinned], which is left untouched. The guidance is mirrored into
     *  [statusNote] (already rendered on the Live screen) so it surfaces with no UI-layer change. */
    private fun noteBondRefusalForPairingHint(status: Int, failedAddress: String?) {
        if (!isInsufficientAuthStatus(status)) return
        if (didBond) return                                       // already bonded — not a pairing problem
        if (connectedFamily != DeviceFamily.WHOOP5) return        // WHOOP 4 bonds cleanly; hint is 5/MG-only
        bondRefusalStreak++
        if (bondGiveUp.gaveUp) {
            // #78 hole-4: a refusal during a paused-state salvage probe must not stomp the paused hint
            // back to the pairing hint (or flap the banner per probe). The streak keeps counting
            // silently; recordRefusal() below stays false (latched), so no epitaph spam either.
            log("WHOOP 5/MG: bond still refused during a paused-state probe (streak $bondRefusalStreak) - the give-up stays latched")
        } else if (bondRefusalStreak >= BOND_REFUSAL_HINT_THRESHOLD) {
            // Re-assert BOTH the canonical hint and the statusNote mirror on every over-threshold refusal.
            // STATE_CONNECTED clears statusNote on each reconnect, so a once-only set would leave the Live
            // status blank after a reconnect — re-asserting keeps the already-rendered surface in sync.
            if (_state.value.pairingHint == null) {
                log("WHOOP 5/MG: encrypted bond refused $bondRefusalStreak times — surfacing pairing guidance (#78)")
            }
            _state.update { it.copy(pairingHint = PAIRING_HINT_TEXT, statusNote = PAIRING_HINT_TEXT) }
        }
        // #747 / #750: feed the same refusal into the give-up tracker. Once it crosses the higher threshold
        // (the pairing hint has had several cycles to be acted on), pause auto-reconnect so we stop hammering
        // a strap that can't bond, write the one-line epitaph (opaque hashed id only, no PII), and surface
        // the honest paused hint. A genuine bond or a manual reconnect re-arms it.
        if (bondGiveUp.recordRefusal()) {
            autoReconnectPausedForBondLoop = true
            bondLoopPausedAtMs = System.currentTimeMillis()   // starts the #78 hole-4 salvage-probe floor
            val opaque = BondRefusalGiveUp.opaqueId(failedAddress ?: "device")
            log(BondRefusalGiveUp.epitaphLine(bondGiveUp.refusals, opaque))
            _state.update { it.copy(pairingHint = BondRefusalGiveUp.pausedHint()) }
            if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
                log("bond gaveUp refusals=${bondGiveUp.refusals} id=$opaque (auto-reconnect paused)",
                    com.noop.testcentre.TestDomain.CONNECTION)
            }
        }
    }

    /** Clear the pairing-hint streak + published hint after a genuine bond or a fresh connect. Also clears
     *  the mirrored [statusNote] only when it still carries the hint, so we never wipe an unrelated note. */
    private fun clearPairingHint() {
        bondRefusalStreak = 0
        // #747/#750: a genuine bond or a fresh user connect re-arms auto-reconnect and clears the give-up.
        bondGiveUp.reset()
        // #971: a genuine bond or a fresh user connect also clears the bond-watchdog bounce streak, so the
        // next slow handshake starts back at the tight base window and can escalate afresh.
        bondWatchdogBackoff.reset()
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAtMs = null
        if (_state.value.pairingHint != null) {
            _state.update {
                val clearedNote = if (it.statusNote == PAIRING_HINT_TEXT) null else it.statusNote
                it.copy(pairingHint = null, statusNote = clearedNote)
            }
        }
    }

    /** Guards the once-per-connect service-discovery kick. AtomicBoolean (not @Volatile): callbacks can
     *  land on binder-pool threads on API 26/27, so a stale timer and teardown can race. */
    private val serviceDiscoveryKicked = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Named so reset can cancel it; an anonymous delayed kick can otherwise act on a later GATT. */
    @Volatile private var serviceDiscoveryRunnable: Runnable? = null

    /** Last MTU value reported by onMtuChanged and when (System.currentTimeMillis), to dedupe a
     *  spurious double callback. The OnePlus Nord 2 BT stack fires onMtuChanged TWICE in quick
     *  succession with the SAME mtu/status (#50). Before discovery was decoupled from this callback,
     *  the duplicate could re-enter discovery and leave every later CCCD write BUSY. Keep the dedup for
     *  stable telemetry and to avoid repeating any future callback-side work. */
    private var lastMtuValue = -1
    private var lastMtuAtMs = 0L

    /** #1066 follow-up: wall-clock of the `requestMtu` attempt, so `onMtuChanged` can log how long the MTU
     *  actually took to settle. `MTU_DISCOVERY_SETTLE_MS` (1.5s) is a deliberately-conservative FIXED wait
     *  (no provenance bit to end it early), added to EVERY connect's discovery; this measurement is what
     *  lets that constant be tuned down later with capture DATA rather than a guess. Reset per connection. */
    @Volatile private var mtuRequestedAtMs = 0L

    /** Start service discovery exactly once for the captured connection. */
    @SuppressLint("MissingPermission")
    private fun kickServiceDiscovery(g: BluetoothGatt, expectedGeneration: Int, reason: String) {
        val ops = gattOps
        if (!serviceDiscoveryAttemptAllowed(
                expectedGeneration = expectedGeneration,
                currentGeneration = connectGeneration,
                isCurrentGatt = gatt === g,
                connected = _state.value.connected,
                hasGattOps = ops != null,
            )
        ) return
        if (!serviceDiscoveryKicked.compareAndSet(false, true)) return
        log("Discovering services ($reason)")
        // Arm the bonded-independent handshake watchdog (#50): from here the post-discovery bond/CCCD
        // phase runs, and it's the one connect stage that previously had no timeout. If [didBond] is
        // still false after BOND_WATCHDOG_MS, [onBondWatchdog] bounces the link. Cancelled on bond and
        // in reset/teardown. Once-per-connection because kickServiceDiscovery is idempotent.
        armBondWatchdog()
        // safeGatt: discovery on a dead binder (radio off, #314) tears down rather than crashing.
        safeGatt("discoverServices") { ops!!.discoverServicesCompat() }
    }

    private fun scheduleServiceDiscovery(g: BluetoothGatt, expectedGeneration: Int, reason: String) {
        serviceDiscoveryRunnable?.let { handler.removeCallbacks(it) }
        val runnable = Runnable {
            serviceDiscoveryRunnable = null
            kickServiceDiscovery(g, expectedGeneration, reason)
        }
        serviceDiscoveryRunnable = runnable
        handler.postDelayed(runnable, MTU_DISCOVERY_SETTLE_MS)
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
        // Connection test mode: stamp when THIS GATT attempt began, so onConnectionStateChange reports the
        // latency of the attempt that just succeeded. Stamped here rather than in connect() (#1040): the
        // auto-reconnect path never calls connect(), so the mark went stale and `latencyMs` was measured
        // from the original user-initiated connect — #1040 reported latencyMs=7847081 (2.18 h) for a link
        // that came up 6 seconds after the previous drop, and it grows without bound the longer a reconnect
        // loop runs. connectToDevice is the single funnel every connect passes through, so every attempt
        // now gets a fresh mark. Latency is therefore GATT-attempt time, no longer including scan time on
        // the first connect. A plain timestamp; only read behind the CONNECTION gate.
        connectAttemptStartedAtMs = System.currentTimeMillis()
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
                    // #1030 (ryanbr): a real link is up — cancel any pending involuntary reconnect so a
                    // stale backoff timer can't fire and reset+close this connection.
                    cancelPendingReconnect()
                    // A successful connect clears the reconnect backoff — the next involuntary drop starts
                    // the 3,6,12…s schedule afresh (iOS didConnect: failedConnectAttempts=0, #48). Reset
                    // IMMEDIATELY, not behind a survival dwell: a band the OS holds bonded/ACL-connected
                    // (co-resident with the official WHOOP app) can ONLY be recovered by the fast DIRECT
                    // reconnect (failedReconnectAttempts < 3). The PASSIVE autoConnect a dwell-gate escalates
                    // to STALLS on such a band — it waits for an advertisement/connection-complete the OS
                    // never re-emits (see handleDisconnect, "passive mode stalls"). So letting the counter
                    // climb on a flapping co-resident band froze the link, and with it the keep-alive battery
                    // poll and every historical offload: sync + battery stopped updating (regression of #173).
                    resetReconnectBackoff()
                    // Diagnostic only (see linkUpSinceMs): how long this link is held before it drops is
                    // exactly what distinguishes a healthy connection from the flapping loop that keeps
                    // the reconnect streak — and so the scan mode — pinned at its most power-hungry.
                    linkUpSinceMs = System.currentTimeMillis()
                    // A connect succeeded → clear the stale-bond re-pair guide UNLESS we are in a known
                    // bond-loop (#617). In that loop the strap "connects" every ~3 s before timing out
                    // again, so clearing here wiped the guide on EVERY cycle: it flashed for ~1 s and
                    // vanished, so the user could never read it (#711). While tripped, keep the guide and
                    // clear it once THIS connection proves healthy (survives the loop's quick-timeout window,
                    // below) or on a clean teardown. Twin of macOS BLEManager.didConnect.
                    val keepGuide = postBondLoop.tripped
                    _state.update { it.copy(
                        connected = true, advertisingName = g.device.name, scanning = false,
                        statusNote = null, encryptedBond = false,
                        reconnectGuide = if (keepGuide) it.reconnectGuide else null,
                    ) }
                    connectGeneration += 1
                    if (keepGuide) {
                        // Clear the guide only if the SAME continuous connection survives the window (a
                        // reconnect/loop cycle bumps connectGeneration, so a transient cycle-connect can't
                        // satisfy the guard even though the device address is identical across cycles).
                        runIfConnectionSurvives(postBondLoop.quickTimeoutWindowMs + 1_000L) {
                            postBondLoop.reset()        // survived the window → the bond-loop is resolved
                            _state.update { it.copy(reconnectGuide = null) }
                        }
                    }
                    // Multi-WHOOP: publish the connected strap's stable BLE address so SourceCoordinator can
                    // adopt it onto the active registry device's peripheralId on first connect. Additive twin
                    // of macOS BLEManager.connectedPeripheralUUID (set in didConnect). Decoupled from the
                    // registry — the coordinator observes this; the connect flow below is unchanged.
                    _connectedPeripheralAddress.value = g.device.address
                    // Connection test mode: report the connect latency + the uptime-start marker the readout
                    // reads. Gated zero-cost (the CONNECTION bool is read before any string is built).
                    // Behaviour-neutral diagnostics only - the connect flow below is unchanged. Twin of macOS.
                    // #1020: both stamped OUTSIDE the gate. Test Centre is usually switched on AFTER
                    // something looks wrong, and noteLocalTeardown() writes are themselves ungated - so a
                    // clear that only ran when the mode was already on would let a PREVIOUS session's origin
                    // survive, printing a stale via=bondWatchdog where via=unknown is the honest answer.
                    // Field assignments, not log lines: no cost when the mode is off.
                    connectedAtMs = System.currentTimeMillis()
                    lastLocalTeardown = null
                    if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
                        val nowUnix = System.currentTimeMillis() / 1000L
                        val latencyMs = connectAttemptStartedAtMs?.let { System.currentTimeMillis() - it }
                        log("connect up gen=$connectGeneration latencyMs=${latencyMs ?: "?"} uptimeStart=$nowUnix",
                            com.noop.testcentre.TestDomain.CONNECTION)
                    }
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
                    // 20-byte notifications (the official app does this in its GATT init). Discovery
                    // follows one fixed settle delay whether the request is accepted or rejected, so a
                    // stack that ignores requestMtu cannot stall the connect. (PR #85)
                    val mtuOps = gattOps
                    mtuRequestedAtMs = System.currentTimeMillis()   // #1066: measure the real settle time
                    val mtuOk = mtuOps != null &&
                        safeGatt("requestMtu") { mtuOps.requestMtuCompat(GATT_MTU) }
                    if (mtuOk) {
                        log("Connected — requesting MTU $GATT_MTU before discovery")
                    } else if (gatt != null) {
                        // False can mean an automatic connection-event MTU is still busy. Do not start
                        // discovery immediately; use the same fixed settle delay as the accepted path.
                        log("Connected — MTU request rejected; settling before discovery")
                    }
                    // Android documents onMtuChanged as both a request result AND a connection event.
                    // There is no provenance bit, so neither the first callback nor a later duplicate
                    // proves our request is the operation that completed. Always wait one bounded delay,
                    // then discover once against this exact GATT/generation. If safeGatt tore
                    // the link down above, gatt is null and there is nothing to schedule.
                    if (gatt === g) {
                        scheduleServiceDiscovery(g, connectGeneration, "MTU settle timeout")
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    // Port of didDisconnectPeripheral: tear down, then auto-rescan unless intentional.
                    handleDisconnect(status)
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            // Dedupe the OnePlus double-MTU GATT bug (#50): the OnePlus Nord 2 stack fires onMtuChanged
            // TWICE in quick succession with the SAME mtu/status. Discovery no longer starts from this
            // callback, but duplicate telemetry is still noise and should not repeat future callback work.
            val now = System.currentTimeMillis()
            if (now - lastMtuAtMs < DUPLICATE_MTU_WINDOW_MS && mtu == lastMtuValue) {
                // #1066 follow-up: still log THIS callback's timing before dropping it. A same-value second
                // callback is often our requestMtu completing AFTER a fast connection-event MTU — dropping it
                // silently would make the settle measurement under-report the real bound the 1.5s must cover.
                val dupMs = if (mtuRequestedAtMs > 0L) now - mtuRequestedAtMs else -1L
                log("Ignoring duplicate MTU callback (mtu=$mtu) — OnePlus/spurious" +
                    if (dupMs >= 0L) " (${dupMs}ms after request)" else "")
                return
            }
            lastMtuValue = mtu
            lastMtuAtMs = now
            // Whatever the strap granted (≤ requested). Telemetry only: Android can emit this callback
            // for the connection itself as well as requestMtu, without saying which. Starting discovery
            // here can overlap the still-running MTU operation and wedge service discovery.
            // #1066 follow-up: log the ACTUAL settle time vs the fixed MTU_DISCOVERY_SETTLE_MS wait, so a
            // capture reveals how much headroom that 1.5s has before discovery. -1 when no request preceded
            // this callback (a bare connection-event MTU).
            val settledMs = if (mtuRequestedAtMs > 0L) now - mtuRequestedAtMs else -1L
            log("MTU negotiated: $mtu (status=$status)" +
                if (settledMs >= 0L) " — settled ${settledMs}ms after request (fixed wait ${MTU_DISCOVERY_SETTLE_MS}ms)" else "")
        }

        /** #533: what the controller and the strap ACTUALLY settled on — the request is only a preference
         *  and the peer can decline, so this is the only way to know whether 2M took (and whether WHOOP
         *  supports it at all). Fires on any PHY change, including a fall back to 1M on a marginal link, so
         *  a before/after strap log shows the negotiated PHY next to the offload's records/sec.
         *  Log-only: nothing branches on the PHY. */
        override fun onPhyUpdate(g: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            log("PHY negotiated: tx=${phyLabel(txPhy)} rx=${phyLabel(rxPhy)} (status=$status)")
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
                // Record the family on connect, not only in the scan path (persistSelectedModel is
                // otherwise called only from onScanResult). A strap reached via the co-resident
                // easy-connect route (getConnectedDevices / bondedDevices adopt, no scan) would never
                // persist its model, leaving model-gated UI stale for a genuinely-connected strap.
                persistSelectedModel(WhoopModel.WHOOP4)
                cmdCharacteristic = whoop4.getCharacteristic(CMD_WRITE_CHAR)
                whoop4.getCharacteristic(CMD_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
                whoop4.getCharacteristic(EVENT_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
                whoop4.getCharacteristic(DATA_NOTIFY_CHAR)?.let { cccdQueue.add(it) }
            } else if (whoop5 != null) {
                // EXPERIMENTAL WHOOP 5.0/MG: opens with CLIENT_HELLO (sent in startSession, after the
                // standard HR/battery notifications are enabled), not the WHOOP4 confirmed-write bond.
                connectedFamily = DeviceFamily.WHOOP5
                // Persist on connect too (see the WHOOP4 branch): otherwise an easy-connect 5/MG never
                // records WHOOP5_MG, so the 5/MG-only controls (raw capture, broadcast HR, deep data)
                // gated on noop.selectedWhoopModel stay hidden until the strap is live-detected that
                // session — even when it is the active paired device. This makes the choice stick.
                persistSelectedModel(WhoopModel.WHOOP5_MG)
                log("WHOOP 5/MG detected — will send CLIENT_HELLO after subscribing (experimental).")
                _state.update { it.copy(
                    whoop5Detected = true,
                    statusNote = "WHOOP 5/MG connected - experimental. After bonding, NOOP brings up live " +
                        "heart rate from the strap's realtime stream. Deeper metrics (recovery, strain, " +
                        "sleep) for 5/MG are still being figured out. WHOOP 4.0 is fully supported today.",
                ) }
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
            //
            // OnePlus double-MTU GATT bug settle (#50): on the OnePlus Nord 2, the stack is still
            // unsettled immediately after service discovery — the first CCCD descriptor write races it
            // and comes back BUSY (then every subscribe wedges and the WHOOP 4.0 bond never completes).
            // Give it a short beat to settle before the first write. The delay (~450ms) is well inside
            // the bond watchdog, so it can't cause a bounce; cancelled in reset/teardown like every other
            // posted runnable. Other devices drain immediately (unchanged behaviour).
            if (Build.MANUFACTURER.equals("OnePlus", ignoreCase = true)) {
                log("OnePlus detected — settling ${ONEPLUS_CCCD_SETTLE_MS}ms before first CCCD write (#50)")
                handler.postDelayed({ gatt?.let { drainCccdQueue(it) } }, ONEPLUS_CCCD_SETTLE_MS)
            } else {
                drainCccdQueue(g)
            }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            // Port of didWriteValueFor: a CONFIRMED-write completion (no error) == bonding succeeded.
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Confirmed write failed: status=$status")
                // Multi-WHOOP stale-pin recovery (#52). A status of INSUFFICIENT_AUTHENTICATION (5) /
                // INSUFFICIENT_ENCRYPTION (15) on the bond write == the strap refused the encrypted bond
                // (the Android twin of the iOS "Encryption/Authentication is insufficient" error). When a
                // STALE registry pin points at a strap that keeps refusing but a DIFFERENT strap bonded
                // fine this run, connect() otherwise drops the working strap and loops forever on the dead
                // pin (encryptedBond never turns true, which also kills buzz/haptics that gate on it).
                // Count consecutive refusals on the PINNED strap; after the limit, hand the pin to the
                // live-bonding strap so the registry re-adopts it. (Reimplemented under NoopApp, #52.)
                noteBondRefusalIfPinned(g.device.address, status)
                // Separately (#78): count the refusal toward the user-facing pairing hint. A 5/MG still
                // bonded to the official WHOOP app keeps refusing the just-works bond; after two refusals
                // we surface concrete pairing-mode guidance. Independent of the pin recovery above.
                noteBondRefusalForPairingHint(status, g.device.address)
                // Connection test mode: surface the failed-encrypt / "held by another central" hint as an
                // upfront tagged line. INSUFFICIENT_AUTHENTICATION (5) / INSUFFICIENT_ENCRYPTION (15) ==
                // the strap is still bonded to the official WHOOP app or a stale OS pairing. Gated
                // zero-cost; diagnostic only. Twin of the macOS didWriteValueFor emit.
                if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
                    val insufficient = status == 5 || status == 15
                    log(
                        if (insufficient)
                            "otherCentral bondWrite refused=insufficient (strap likely held by the WHOOP app or a stale pairing; cannot start a fresh encrypted bond)"
                        else "otherCentral bondWrite failed=status$status",
                        com.noop.testcentre.TestDomain.CONNECTION,
                    )
                }
            } else if (!didBond && connectedFamily == DeviceFamily.WHOOP5) {
                // EXPERIMENTAL (issue #17): the CLIENT_HELLO is now a confirmed write, so this ACK means
                // just-works bonding completed. Now subscribe the puffin notify chars (realtime HR rides
                // these as REALTIME_DATA — the strap rejected them on the unauthenticated link), then arm
                // realtime HR with puffin framing. Mirrors the macOS post-bond flow.
                didBond = true
                cancelBondWatchdog()          // genuine bond reached — the handshake watchdog stands down (#50)
                noteGenuineBond(g.device.address)   // #52: this strap bonds fine; clears any pin-refusal streak
                clearPairingHint()            // #78: a genuine bond means the pairing guidance no longer applies
                bondedDirectAttempt = false   // fast-path connect reached a real session (#78 fork)
                staleDirectFailures = 0       // genuine bond — clear the wiped-bond counter (#84 parity)
                _state.update { it.copy(bonded = true, encryptedBond = true) }   // genuine bond (#69)
                bondedAtMs = System.currentTimeMillis()   // #617: stamp the bond so handleDisconnect can spot a bond-then-quick-timeout loop
                emitConnectionBondState("encryptedBond family=whoop5 (CLIENT_HELLO acked)")
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
                // #927: RE-DERIVE the want at arm time, never the precomputed [wantsRealtime]: that value
                // can be up to a keep-alive tick (30 s) stale, and a reconnect just OUTSIDE the overnight
                // window would re-arm the stream from it and stay armed until the next tick.
                val realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
                wantsRealtime = realtimeWantNow
                if (realtimeWantNow) { realtimeArmed = true; send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1)) }
            } else if (!didBond && connectedFamily == DeviceFamily.WHOOP4) {
                didBond = true
                cancelBondWatchdog()          // secure handshake completed — stand the watchdog down (#50)
                noteGenuineBond(g.device.address)   // #52: this strap bonds fine; clears any pin-refusal streak
                clearPairingHint()            // #78: a genuine bond means the pairing guidance no longer applies
                _state.update { it.copy(bonded = true, encryptedBond = true) }   // WHOOP4 bond is genuine (#69)
                bondedAtMs = System.currentTimeMillis()   // #617: stamp the bond so handleDisconnect can spot a bond-then-quick-timeout loop
                emitConnectionBondState("encryptedBond family=whoop4 (confirmed write acked)")
                log("BONDED (confirmed write acknowledged) — custom channels should now flow")
            }

            // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor / onCharacteristicWrite
            // re-fires on EVERY with-response write (the bond write, etc.); the guard prevents re-blasting
            // the handshake at the strap mid-session — THE iOS "won't serve" root cause from the Swift notes.
            // WHOOP 5.0/MG uses CLIENT_HELLO, not this WHOOP4 command sequence, so it is skipped for it.
            if (!connectHandshakeDone && connectedFamily == DeviceFamily.WHOOP4) {
                connectHandshakeDone = true
                noteRebootReconnectIfNeeded()
                runConnectHandshake()
            }

            // #791: a completion callback arriving while a BUSY-refused frame is STILL held for retry is
            // proof that write was delivered after all — the stack refused it and sent it anyway. Cancel the
            // retry, or the strap receives the same command twice. Observed on a Galaxy S24 Ultra: one
            // GET_DATA_RANGE produced three CRC-valid responses with advancing strap-side sequence numbers
            // and one unchanged origin-seq echo, always after a burst of busy-retries and never without.
            //
            // This cannot cancel a legitimate retry. `pendingRetry` is non-null only when the MOST RECENT
            // write attempt returned BUSY, and the drain never starts a write while one is in flight, so
            // there is no other outstanding write this completion could belong to. A frame the stack truly
            // refused produces no completion at all, so its retry still fires — the #77/#312 protection
            // against a silently dropped TOGGLE_REALTIME_HR / SET_CLOCK / offload-ack is untouched.
            // Hops to the main looper because pendingRetry is main-looper-only state, and it is read there
            // rather than here. Posted with no delay, so it runs ahead of the >=12 ms retry it cancels. The
            // bond flag is consumed HERE, on the callback, so a later completion cannot inherit it.
            val wasBondWrite = bondWriteOutstanding
            bondWriteOutstanding = false
            handler.post { cancelRetryOfWriteDeliveredDespiteBusy(characteristic.uuid, wasBondWrite) }

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
            // #520 DIS identity. NUL-terminated ASCII per the DIS spec, so trim padding. The serial
            // lands first and CHAINS the hardware-revision read (Android serializes GATT ops).
            uuid == DIS_SERIAL_CHAR -> {
                disSerial = bytes.toString(Charsets.UTF_8).trim { it == '\u0000' || it.isWhitespace() }
                noteWhoop5VariantFromDis()
                readDisHardwareRevision()
            }
            uuid == DIS_HW_REV_CHAR -> {
                disHwRev = bytes.toString(Charsets.UTF_8).trim { it == '\u0000' || it.isWhitespace() }
                noteWhoop5VariantFromDis()
            }
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
                    // Compute the offload-frame flag ONCE — it feeds both the R22 telemetry note and
                    // handleFrame's replayedOffload gate, so evaluating it twice bounds-checked + indexed
                    // every offloaded frame for nothing. (The Swift 5/MG inbound loop already hoists this.)
                    val offloadFrame = backfilling && isOffloadFrame(frame, connectedFamily)
                    noteWhoop5R22Telemetry(frame, offloadFrame)  // #174
                    // #47: decode this frame ONCE and thread it to both consumers (the router below and the
                    // live collector) instead of each re-parsing it — steady-state drops 2→1 parse per live
                    // frame. Family-aware, so it's correct for WHOOP4 and 5/MG alike.
                    val parsed = Framing.parseFrame(frame, connectedFamily)
                    // A frame replayed as part of the historical offload (type 47/48/… during a backfill)
                    // must not drive LIVE-only state (the charging pill). Mirrors iOS, where the offload
                    // path skips the live router entirely. (PR #568 reimpl)
                    handleFrame(frame, parsed, replayedOffload = offloadFrame)

                    // Capture the strap's newest stored record from a GET_DATA_RANGE reply, feeding
                    // the liveness watchdog. The response command byte is family-dependent: @6 on
                    // WHOOP4, @10 on 5/MG (+4 puffin envelope) — reading 6 unconditionally meant
                    // strapNewestTs never updated from a 5/MG reply. dataRangeNewestUnix's scan-from-7
                    // stays: on 5/MG it lands word-aligned with the body at 11, and a straddling word
                    // can't fall in the unix-range window. (#78 fork)
                    val cmdOff = if (connectedFamily == DeviceFamily.WHOOP5) 10 else 6
                    // #592 opcode probe: dump the raw GET_EXTENDED_BATTERY_INFO(98) response in FULL (no
                    // prefix cap — the tail fields are the evidence) so a normal strap-log export settles
                    // the disputed number: a battery-shaped payload (mV etc.) confirms 98 on this firmware;
                    // a short generic stub keeps it ambiguous (see the probe note on the enum case).
                    if (frame.size > cmdOff && (frame[cmdOff].toInt() and 0xFF) == CommandNumber.GET_EXTENDED_BATTERY_INFO.rawValue) {
                        // Format the #592 result (pure + testable), then BOTH log it (so it rides the strap-log
                        // bundle) AND publish it to the StateFlow the Devices dialog shows + copies — so a
                        // capture doesn't require a full log export. Diffs against the persisted previous
                        // payload to help map the fields across captures.
                        val prevHex = NoopPrefs.of(context).getString(KEY_592_PREV_PAYLOAD, null)
                        val (text, payHex) = formatExtendedBatteryProbe(
                            frame, cmdOff, connectedFamily == DeviceFamily.WHOOP5, prevHex,
                        )
                        log("Extended-battery probe (#592):\n$text")
                        _extendedBatteryProbe.value = text
                        if (payHex != null) NoopPrefs.of(context).edit().putString(KEY_592_PREV_PAYLOAD, payHex).apply()
                    }
                    // #690 opcode probe: dump the raw GET_BODY_LOCATION_AND_STATUS(84) response in FULL,
                    // decode the 4-byte revision/location/confidence/status record, log it (rides the
                    // strap-log bundle) AND publish to the StateFlow the Devices dialog shows + copies.
                    // Gated on a probe being IN-FLIGHT (the waiting sentinel) — stricter than the #592
                    // probe on purpose: 0x54 could coincidentally be a data/event frame's cmd-offset byte,
                    // and this is a strictly user-triggered diagnostic, so a stray match must never pop the
                    // result dialog. (A reply arriving after the 8s timeout is dropped — acceptable.)
                    if (frame.size > cmdOff && (frame[cmdOff].toInt() and 0xFF) == CommandNumber.GET_BODY_LOCATION_AND_STATUS.rawValue &&
                        _bodyLocationProbe.value == WAITING_BODY_LOCATION_PROBE) {
                        val prevHex = NoopPrefs.of(context).getString(KEY_690_PREV_PAYLOAD, null)
                        val (text, payHex) = formatBodyLocationProbe(
                            frame, cmdOff, connectedFamily == DeviceFamily.WHOOP5, prevHex,
                        )
                        log("Body-location probe (#690):\n$text")
                        _bodyLocationProbe.value = text
                        if (payHex != null) NoopPrefs.of(context).edit().putString(KEY_690_PREV_PAYLOAD, payHex).apply()
                    }
                    // #761: a reply to the read-only feature-flag enumeration (117/118). In-flight-guarded
                    // inside handleFeatureFlagProbeResponse, so this is a byte compare on every other frame.
                    if (frame.size > cmdOff &&
                        ((frame[cmdOff].toInt() and 0xFF) == CommandNumber.START_FF_KEY_EXCHANGE.rawValue ||
                            (frame[cmdOff].toInt() and 0xFF) == CommandNumber.SEND_NEXT_FF.rawValue)
                    ) {
                        handleFeatureFlagProbeResponse(frame)
                    }
                    // #103: a reply to the read-only device-config READ probe (121/128). In-flight-guarded
                    // inside handleDeviceConfigProbeResponse, so this is a byte compare on other frames.
                    // The COMMAND_RESPONSE type gate (cmdOff - 2 on both families) is checked HERE as well
                    // as in the parser: a data frame that happens to carry 121/128 at the cmd offset would
                    // otherwise abort a live walk with an envelope failure instead of being ignored.
                    if (frame.size > cmdOff && (frame[cmdOff - 2].toInt() and 0xFF) == 0x24 &&
                        DeviceConfigReadProbe.isReadOnlyOpcode(frame[cmdOff].toInt() and 0xFF)
                    ) {
                        handleDeviceConfigProbeResponse(frame)
                    }
                    // #174: a reply belonging to an R22 DISABLE run — either the SET_FF_VALUE(120) write
                    // ack or the GET_FF_VALUE(128) read-back that verifies it. In-flight-guarded inside.
                    // 128 is also matched by the read-probe clause above; both handlers guard on their OWN
                    // run being live, so exactly one acts.
                    if (frame.size > cmdOff && (frame[cmdOff - 2].toInt() and 0xFF) == 0x24 &&
                        ((frame[cmdOff].toInt() and 0xFF) == CommandNumber.SET_CONFIG.rawValue ||
                            (frame[cmdOff].toInt() and 0xFF) == CommandNumber.GET_FF_VALUE.rawValue)
                    ) {
                        handleR22DisableResponse(frame)
                    }
                    if (frame.size > cmdOff && (frame[cmdOff].toInt() and 0xFF) == CommandNumber.GET_DATA_RANGE.rawValue) {
                        // #451: dump raw GET_DATA_RANGE response bytes unconditionally (even if decode returns
                        // null) so a stale/wrong-epoch "newest" can be told apart from a frame-alignment bug in
                        // dataRangeNewestUnix straight from a normal strap-log export. Mirrors the Swift line.
                        val hex = frame.joinToString("") { "%02x".format(it) }
                        log("Get Data Range raw frame (#451 — for offset analysis): $hex")
                        // #689: ring-buffer page backlog, DIAGNOSTIC ONLY — never gates sync/backfill.
                        // BOTH branches log, deliberately. Until #818 the offsets were two bytes early, so
                        // ring capacity always read 0, the `t > 0` guard rejected every real frame, and this
                        // logged NOTHING — a strap log was indistinguishable from one where the strap never
                        // answered, which is why a broken decode survived unnoticed. The raw-frame dump above
                        // is unconditional for the same reason. Twin of the Swift branch.
                        val pagesBehind = com.noop.protocol.DataRange.pagesBehind(frame, cmdOff)
                        if (pagesBehind != null) {
                            log("Strap backlog pages behind: $pagesBehind (#689 — GET_DATA_RANGE ring backlog, diagnostic only)")
                        } else {
                            log(
                                "Strap backlog pages behind: not decodable from this frame (#689 — offsets may " +
                                    "have moved; the raw frame above is the input). Diagnostic only, sync is unaffected.",
                            )
                        }
                        dataRangeNewestUnix(frame)?.let {
                            strapNewestTs = it
                            // #34: persist the strap's newest banked record so the debug export can flag a reset clock.
                            runCatching { NoopPrefs.of(context).edit().putLong("strap.newestRecordTs", it).apply() }
                            // #928: flag an implausibly FUTURE "newest" (strap clock set ahead) right where
                            // it lands, so a Test Centre export shows WHY auto-continue refused the range.
                            val wallNowForSkew = System.currentTimeMillis() / 1000L
                            if (it > wallNowForSkew + AUTO_CONTINUE_FUTURE_SKEW_SECONDS) {
                                log("Strap newest banked record reads ${(it - wallNowForSkew) / 3600L}h AHEAD of the wall clock (implausible; strap clock set in the future, #928). Auto-continue will not trust this range.")
                            }
                            // #547 SESSION-RELATIVE gate: publish the strap's banked-record window to the
                            // Backfiller so the historical ingest gate can reject a record dated months
                            // outside THIS strap's own [oldest, newest] (wandering-clock pollution that
                            // clears the absolute 2023-11 floor). The gate ignores a half/malformed window,
                            // so setting newest before oldest is decoded is safe.
                            backfiller.sessionNewestUnix = it
                            // Observability for "last night didn't sync" (#364): log the NEWEST record the
                            // strap actually holds. With the persisted-N line, one connect distinguishes a
                            // banked-but-not-yet-reached backlog (newest == last night, cursor grinding) from
                            // a genuinely un-banked night (newest is older) — mirrors the Swift line.
                            val fmt = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US)
                            log("Strap newest banked record: ${fmt.format(java.util.Date(it * 1000L))} (from data range)")
                            // Also surface the OLDEST banked record → the full backlog SPAN, i.e. the depth a
                            // deep oldest-first drain must cover before recent nights land (#364). Mirrors Swift.
                            val oldestUnix = dataRangeOldestUnix(frame)
                            if (oldestUnix != null && oldestUnix < it) {
                                backfiller.sessionOldestUnix = oldestUnix   // #547: closes the session window
                                val spanDays = (it - oldestUnix) / 86_400L
                                log("Strap banked history span: ${fmt.format(java.util.Date(oldestUnix * 1000L))} → newest " +
                                    "(~$spanDays day${if (spanDays == 1L) "" else "s"} of backlog, drained oldest-first)")
                            }
                            // CAPTURE-B parity: promote the CLOCK-DRIFT picture from the buried raw frames to
                            // one upfront line in the UNIVERSAL block - the strap-reported [oldest, newest]
                            // window vs wall clock with a FUTURE-DATE flag (#767 / #754 / #72 cluster). A
                            // wandering / un-clocked strap is the single most common root cause (live HR works
                            // but offloaded history lands months off), so this rides EVERY Test Centre export
                            // (gate = active(UNIVERSAL) == any mode on), tagged .universal, not just the
                            // Connection mode. Matches the universal dayOwner line. Gated zero-cost; pure
                            // formatter, no behaviour change. Twin of the macOS data-range emit.
                            if (testCentre.active(com.noop.testcentre.TestDomain.UNIVERSAL)) {
                                val line = com.noop.analytics.ConnectionTrace.clockDriftLine(
                                    oldestUnix = if (oldestUnix != null && oldestUnix < it) oldestUnix else null,
                                    newestUnix = it,
                                    wallNowUnix = System.currentTimeMillis() / 1000L,
                                )
                                log(line, com.noop.testcentre.TestDomain.UNIVERSAL)
                            }
                        }
                    }

                    // PERSISTENCE / OFFLOAD ROUTING — port of the didUpdateValueFor tail block.
                    // Durable EVENT-frame log for deep-data research (#103) — BEFORE the offload
                    // branch, so it sees both live events and their history replays (either path
                    // may be the only one that delivers a given record). Single byte compare when
                    // the frame is not an EVENT; no-op unless the capture toggle is on.
                    if (connectedFamily == DeviceFamily.WHOOP5) {
                        writeWhoop5EventLogIfEvent(uuid.toString(), frame)
                        // Durable log of the big high-rate R22 deep buffers (type-0x2F ≥ 1 KB) for #423
                        // reverse-engineering — its own file the bulk-capture eviction never churns.
                        // BEFORE the offload branch so it catches the burst; no-op unless capture is on.
                        writeWhoop5DeepBufferIfBig(uuid.toString(), frame, isOffloadFrame(frame, connectedFamily))
                        // #423: the queryable twin of that diagnostics line — persist the decoded IMU
                        // samples (100 Hz 6-axis) into the rawImuSample table when raw capture is on.
                        storeWhoop5RawImuIfBuffer(frame)
                    }
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
                        // Live path: buffer the frame + its parse for a batched insert (port of Collector.ingest).
                        // #47: thread the single parse so flushLive doesn't re-decode the batch.
                        ingestLiveFrame(frame, parsed)
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
        // #174: a SET_CONFIG ack means "one enable_r22_* flag accepted" ONLY when we are enabling. A
        // disable run writes through the same opcode, so without this guard turning R22 OFF would tick the
        // "Strap accepted N/16 R22 flags" counter upwards — the exact opposite of what happened. The
        // disable run scores its own acks (and does not trust them; the 128 read-back is its proof).
        if (type == 0x24 && (frame[10].toInt() and 0xFF) == CommandNumber.SET_CONFIG.rawValue &&
            r22DisableRun == null) {
            val n = _state.value.r22FlagsAccepted + 1
            _state.update { it.copy(r22FlagsAccepted = n) }
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
            _state.update { it.copy(deepPacketsThisSession = n) }
            if (n == 1) log("Deep-data: type-0x2F received outside our offload — this is historical-offload data (another BLE client pulling the strap's history, or a trailing flush), not a live R22 stream (#494).")
            else if (n % 50 == 0) log("Deep-data: $n type-0x2F historical-offload frames seen outside our session.")
        }
    }

    /**
     * Pure decode→state router for one COMPLETE frame.
     * Direct port of `FrameRouter.handle(frame:)`.
     */
    /** Parse-then-route shim (#47). Kept for any caller/test that passes raw bytes; the live dispatcher
     *  parses ONCE and calls the overload below with the result. */
    private fun handleFrame(frame: ByteArray, replayedOffload: Boolean = false) =
        handleFrame(frame, Framing.parseFrame(frame, connectedFamily), replayedOffload)

    /** #47: the dispatcher decodes each frame ONCE and threads it here, so a live frame is parsed once
     *  instead of twice (this router path + the live-collector flush). `frame` is still passed for the
     *  byte-level sub-decoders. */
    private fun handleFrame(frame: ByteArray, parsed: com.noop.protocol.ParsedFrame, replayedOffload: Boolean = false) {
        if (!parsed.ok) return
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if (parsed.crcOk == false) return

        // Connection test mode: accumulate frames by type and flush ONE `frameTiming` SUMMARY line per
        // rolling window (#1151), instead of a line per frame-TYPE transition — during offloads/command
        // bursts the type flips constantly, so the old per-transition log was ~a third of a real capture and
        // aged actionable history out of the 8MB rolling buffer. Gated FIRST so a frame on the non-test path
        // touches no extra state at all. (Android-only diagnostic; macOS uses FrameRouter's own lastFrameType
        // for the Live console — a different surface, untouched here.)
        if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
            val nowMs = System.currentTimeMillis()
            if (connFrameWindowStartMs == 0L) connFrameWindowStartMs = nowMs
            connFrameCounts[parsed.typeName] = (connFrameCounts[parsed.typeName] ?: 0) + 1
            if (nowMs - connFrameWindowStartMs >= FRAME_TIMING_SUMMARY_WINDOW_MS) flushFrameTimingSummary()
        }

        when (parsed.typeName) {
            "REALTIME_DATA" -> {
                // Reject 0 / out-of-range spikes; only accept physiologically plausible HR.
                (parsed.parsed["heart_rate"] as? Int)?.let { hr ->
                    if (hr in 30..220) _state.update { it.copy(heartRate = hr) }
                }
                // The realtime stream usually reports rr_count=0; only update R-R when this frame
                // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
                // withRRIntervals also feeds the Live console's rolling rrRecent buffer.
                intArrayValue(parsed.parsed["rr_intervals"])?.let { rr ->
                    if (rr.isNotEmpty()) _state.update { it.withRRIntervals(rr) }
                }
            }

            "COMMAND_RESPONSE" -> {
                doubleValue(parsed.parsed["battery_pct"])?.let { setBattery(it) }
                // #592: GET_EXTENDED_BATTERY_INFO / GET_BATTERY_LEVEL responses may carry pack voltage.
                (parsed.parsed["battery_mV"] as? Int)?.let { mv -> _state.update { it.copy(batteryMv = mv) } }
                // Firmware version from the handshake: 4.0 reports fw_harvard (REPORT_VERSION_INFO),
                // 5/MG reports fw_version (GET_HELLO). Keyed on whichever field decoded rather than
                // resp_cmd, so a single branch covers both families. Stable for the connection, so we
                // only republish state when it actually changes.
                (parsed.parsed["fw_version"] as? String ?: parsed.parsed["fw_harvard"] as? String)?.let { fw ->
                    if (_state.value.strapFirmware != fw) {
                        _state.update { it.copy(strapFirmware = fw) }
                        // Persist so the debug export can name the firmware offline (state clears on disconnect).
                        runCatching { NoopPrefs.setLastFirmware(context, fw) }
                    }
                }
                val respCmd = parsed.parsed["resp_cmd"] as? String
                val result = parsed.parsed["result"] as? String
                // Reboot ack (#166): log the COMMAND_RESPONSE result for a user reboot on BOTH families —
                // the accept/reject signal (the same one that exposed 5/MG haptics rejection). So a 5/MG
                // owner's strap log confirms whether the (unverified) puffin reboot frame is accepted. The
                // decoded result name is Android's richer twin of the macOS raw result byte. Log-only.
                // POWER_CYCLE_STRAP is matched too: it's the 4.0 reboot probe's candidate B (#235), and its
                // result byte is exactly what tells "opcode rejected (recognized, wrong args)" from "ignored".
                if (respCmd?.startsWith("REBOOT_STRAP") == true || respCmd?.startsWith("POWER_CYCLE_STRAP") == true) {
                    val verdict = when {
                        result == null -> "no result"
                        result.startsWith("SUCCESS") -> "accepted"
                        else -> "REJECTED"
                    }
                    log("reboot: strap acked result=${result ?: "none"} ($verdict)")
                }
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
                //
                // A reply that DELIVERED ITS VALUE is annotated rather than reported as a bare failure.
                // The 4.0 GET_BATTERY_LEVEL replies on record carry a zeroed [seq][result] prefix, so a
                // battery read that returned a perfectly good percentage logs as
                // "FAILURE(0)" — and a log line saying a battery read failed, next to a battery gauge
                // showing 42%, is the kind of artefact that gets quoted in an issue as evidence of a
                // fault that is not there. That is how #900 started. The line still prints, because
                // hiding it would hide the anomaly itself; it just no longer reads as a failure.
                if (result != null && !result.startsWith("SUCCESS")) {
                    val decodedValue = doubleValue(parsed.parsed["battery_pct"])
                    val note = if (decodedValue != null) {
                        " (the reply still carried a value: battery ${"%.1f".format(decodedValue)}%" +
                            " — the result byte on this reply is not established, see #900)"
                    } else {
                        ""
                    }
                    log("Command response: ${respCmd ?: "?"} → $result$note")
                }
                // Arm-readback diagnostic (#401 close-out): armStrapAlarm follows every WHOOP 4.0 arm
                // with GET_ALARM_TIME (67) so the log proves what the STRAP believes is armed, not just
                // what we sent. LOG-ONLY, never gates behaviour: the 4.0 response layout is undocumented,
                // so the decode is defensive ([whoop4ArmedAlarmEpoch]: SET-mirror form first, bare u32
                // second, plausibility-gated) and an unrecognised payload still logs its raw hex - which
                // is exactly as diagnostic. Labelled "strap reports", not "verified" (one firmware's
                // answer format must never mislead a triage). Twin of macOS FrameRouter.
                if (connectedFamily == DeviceFamily.WHOOP4 && respCmd?.startsWith("GET_ALARM_TIME") == true) {
                    val epoch = whoop4ArmedAlarmEpoch(frame)
                    if (epoch != null) {
                        // #34: log the RAW response bytes alongside the decoded epoch (previously only the
                        // decode-FAILURE branch below carried them). A successful-but-mismatched decode — the
                        // strap reporting a plausible epoch that never matches what we armed, the corrupted-
                        // register signature — needs the raw frame to tell a genuinely-stored stale alarm from
                        // a misdecode of a fixed response field. Log-only; the decode/behaviour is unchanged.
                        val raw = whoop4AlarmReadbackPayloadHex(frame) ?: "empty"
                        log("Alarm: strap reports armed for ${alarmReadbackLocalTime(epoch)} (epoch $epoch) [raw $raw]")
                        // #34: persist what the strap reports so the debug export can show sent-vs-reported.
                        runCatching {
                            NoopPrefs.of(context).edit()
                                .putLong("alarm.lastReportedEpoch", epoch)
                                .putLong("alarm.lastReportedAt", System.currentTimeMillis())
                                .apply()
                        }
                    } else if (whoop4ReadbackReportsNoAlarm(frame)) {
                        // #34 (issue comment 2026-07-12): the strap's "nothing armed" sentinel — the epoch
                        // field decodes to 0. This is NOT an undocumented layout; it's the strap telling us
                        // it has no alarm stored, so an arm we just sent did NOT persist. Calling this
                        // "unrecognised payload" hid the single most diagnostic signal in a "didn't buzz"
                        // report: SET went out, strap kept nothing. Name it plainly. Log-only. Twin of Swift.
                        val raw = whoop4AlarmReadbackPayloadHex(frame) ?: "empty"
                        log("Alarm: strap reports NO alarm currently stored (epoch 0) — the arm did not persist on the strap (raw $raw)")
                    } else {
                        val raw = whoop4AlarmReadbackPayloadHex(frame) ?: "empty"
                        log("Alarm: strap answered the alarm readback with an unrecognised payload (raw $raw) - layout undocumented, log-only")
                    }
                }
                // #34 (issue comment 2026-07-12): the strap's OWN answer to the arm we just sent — the
                // accept/reject datum previously thrown away. armStrapAlarm logs "armed" the instant the SET
                // goes out, which only proves NOOP transmitted the frame; if the firmware drops it the
                // GET_ALARM_TIME readback then reads back epoch 0 (a silently-unpersisted alarm — the exact
                // signature in this report). Logging the raw result byte lets a future report distinguish a
                // strap that accepted the arm from one that rejected it. LOG-ONLY, never gates behaviour. The
                // WHOOP 4.0 result-code meaning is UNVERIFIED (the 5/MG puffin table is 0=FAILURE 1=SUCCESS
                // 2=PENDING 3=UNSUPPORTED, but the 4.0 reboot probe assumed 0=accepted), so no verdict is
                // claimed — it surfaces the byte, nothing more. Twin of Swift FrameRouter. WHOOP4-only: the
                // 4.0 result byte sits at frame[8]; the 5/MG result lives at a different offset (decoded as
                // the `result` string above) and its alarm path is the Experimental one.
                if (connectedFamily == DeviceFamily.WHOOP4 && respCmd?.startsWith("SET_ALARM_TIME") == true) {
                    val r = frame.getOrNull(8)?.toInt()?.and(0xFF)
                    val rhex = if (r != null) "0x%02x".format(r) else "none"
                    log("Alarm: strap answered the arm (SET_ALARM_TIME) with result=$rhex — log-only, 4.0 result-code meaning unverified")
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
                    // Pure [isGestureEvent] so the gesture-vs-non-gesture routing is unit-testable (PR #577).
                    val isGesture = isGestureEvent(ev)

                    // A BLE_BONDED event confirms a GENUINE encrypted bond (belt-and-suspenders; the
                    // confirmed-write ACK also sets this).
                    if (ev.startsWith("BLE_BONDED")) {
                        _state.update { it.copy(bonded = true, encryptedBond = true) }
                    }

                    if (!isGesture) {
                        // Non-gesture events (BLE_BONDED, BATTERY_LEVEL, …) surface in "Last Event" —
                        // except the live-HR stream toggle (BLE_REALTIME_HR_ON/OFF), which is internal
                        // plumbing that fires on every connect and just confuses users (#92).
                        if (!ev.startsWith("BLE_REALTIME_HR")) {
                            _state.update { it.copy(lastEvent = ev) }
                        }
                        // Charging flag — wire observation: BATTERY_LEVEL u8 bit0 (4.0 @26 / 5.0 @30).
                        // PR #568 reimpl: drop the old 45s time-freshness gate (which suppressed the bolt
                        // for the first ~45s of every connect on a strap with a stale RTC). The only thing
                        // we must still exclude is a HISTORICAL BATTERY_LEVEL event replayed mid-backfill —
                        // and that's exactly [replayedOffload], the same offload discriminator iOS relies on
                        // by skipping its live router. A genuine live battery event now lights the pill
                        // immediately, regardless of its event_timestamp.
                        if (ev.startsWith("BATTERY_LEVEL") && shouldApplyChargingFromBatteryEvent(replayedOffload)) {
                            (parsed.parsed["battery_charging"] as? Int)?.let {
                                _state.update { s -> s.copy(charging = it != 0) }
                            }
                            // #592: the same battery event carries pack voltage (mv@21) — surface it on the
                            // Devices card. Range-gated by the parser already; only a live (non-replayed) event.
                            (parsed.parsed["battery_mV"] as? Int)?.let { mv ->
                                _state.update { s -> s.copy(batteryMv = mv) }
                            }
                        }
                        // PR #577: the strap fired its firmware smart alarm (STRAP_DRIVEN_ALARM_EXECUTED,
                        // event 57) → re-arm the next day's instant (single absolute time, no recurrence).
                        // This is NOT a gesture, so it MUST dispatch from here — the gesture branch never
                        // sees it (isGesture is false), which is exactly the bug being fixed. Gate on
                        // [replayedOffload] so a HISTORICAL alarm event replayed mid-backfill (old ts)
                        // can't spuriously re-arm; only a live event fires. Twin of macOS
                        // FrameRouter → LiveState.onSmartAlarmFired.
                        if (smartAlarmFiredForEvent(ev, replayedOffload)) {
                            log("Strap fired its smart alarm (event 57) — re-arming the next day's instant")
                            // #34: persist the fire so the debug export's Alarm block shows "last fired".
                            runCatching { NoopPrefs.of(context).edit().putLong("alarm.lastFiredAt", System.currentTimeMillis()).apply() }
                            onSmartAlarmFired?.invoke()
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
                            _state.update { it.copy(lastEvent = ev) }
                            when {
                                ev.startsWith("DOUBLE_TAP") -> {
                                    // Surfaced via lastEvent only — the decode is unchanged. AppViewModel's
                                    // LiveState collector (dispatchDoubleTap) debounces on the event identity
                                    // and runs the user's chosen DoubleTapAction (parity since 4.2.8).
                                }
                                ev.startsWith("WRIST_ON") -> {
                                    if (!_state.value.worn) _state.update { it.copy(worn = true) }
                                }
                                ev.startsWith("WRIST_OFF") -> {
                                    if (_state.value.worn) _state.update { it.copy(worn = false) }
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
                // Convert 1/1024 s units to milliseconds (matches the WHOOP store's R-R in ms). ROUNDED,
                // byte-identical to StandardHeartRate.parse + the Swift twin; plain integer division
                // truncated, diverging up to ~0.5 ms per interval into RMSSD/HRV. (ryanbr, #1032)
                rr.add(Math.round(raw / 1024.0 * 1000.0).toInt())
            }
        }

        // R-R: the standard profile is the reliable source — surface whenever present. withRRIntervals
        // also feeds the Live console's rolling rrRecent buffer.
        if (rr.isNotEmpty()) _state.update { it.withRRIntervals(rr) }
        // HR: accept only physiologically plausible values; reject 0/garbage (off-wrist).
        if (hr in 30..220) {
            _state.update { it.copy(heartRate = hr) }
            // EXPERIMENTAL WHOOP 5.0/MG: there is no confirmed-write bond for a 5/MG strap, so once
            // live HR actually streams over the standard profile we treat the link as established —
            // otherwise the UI sits on "Connecting…" forever even though data is flowing (issue #8).
            if (connectedFamily != DeviceFamily.WHOOP4 && !_state.value.bonded) {
                // atomic update: LiveState is written from multiple threads (binder/main/IO).
                _state.update { it.copy(bonded = true) }
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

    /** The Test Centre gate, bound once to the app's single "noop_testcentre" prefs file. Lazily built so
     *  the zero-cost gate below is one SharedPreferences.getBoolean read, never a fresh prefs open per
     *  reading (#713, Test Centre). */
    private val testCentre by lazy { com.noop.testcentre.TestCentre.from(context) }

    /** Single funnel for battery readings (port of LiveState.setBattery). */
    private fun setBattery(pct: Double) {
        _state.update { it.copy(batteryPct = pct) }
        // Battery test mode: one tagged (t, soc) line per reading, gated zero-cost when off (the gate is a
        // single SharedPreferences bool read; the formatter below only runs when the mode is on). Rides the
        // redacting log() sink; the Room battery series is the readout + trace source (#713, Test Centre).
        if (testCentre.active(com.noop.testcentre.TestDomain.BATTERY)) {
            log(BatterySocLine.format(pct, System.currentTimeMillis() / 1000L),
                com.noop.testcentre.TestDomain.BATTERY)
        }
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
        // One-shot firmware-version read for the Devices card. These are documented READ commands, not
        // firmware-load opcodes. Pick the family-appropriate one; a strap silently ignores the command
        // meant for the other generation. The response decodes to fw_harvard (4.0) / fw_version (5/MG)
        // in Framing.
        when (connectedFamily) {
            DeviceFamily.WHOOP4 -> send(CommandNumber.REPORT_VERSION_INFO)
            DeviceFamily.WHOOP5 -> send(CommandNumber.GET_HELLO)
        }
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
        handler.postDelayed({ requestSync(BackfillTrigger.CONNECT) }, INITIAL_BACKFILL_DELAY_MS)
        startBackfillTimer()
        startKeepAlive()
        // Arm realtime HR now if a screen already wants it (Live/Health Monitor opened before the bond
        // completed) OR the continuous-capture preference wants it — otherwise the stream would only
        // start at the next keep-alive tick (issue #18). Mark it armed so reconcileRealtime() tracks the
        // edge correctly (the strap forgot the toggle across the disconnect; reset() cleared realtimeArmed).
        // #927: RE-DERIVE the want at arm time (same reasoning as the 5/MG post-bond arm): a reconnect
        // outside the overnight window must not arm the stream from a stale precomputed [wantsRealtime].
        val realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = realtimeWantNow
        if (realtimeWantNow) { realtimeArmed = true; send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1)) }
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
            // #580: a known history-empty 5/MG (firmware serves no offload) gets a far longer fuse. Live HR
            // over the standard 0x2A37 profile keeps the link genuinely alive, but its packets can lull for
            // >120s when the strap is off-wrist / resting, and an empty offload leaves the data channel
            // quiet — so the old 120s rule disconnected/rescanned a perfectly healthy link every ~2 min (the
            // thrash this fixes). A WHOOP 4 (real "not recording" path) keeps the tight 120s fuse.
            val bounceFuse = if (connectedFamily == DeviceFamily.WHOOP5 && whoop5EmptyOffload.historyEmpty)
                KEEPALIVE_STALL_5MG_EMPTY_MS else KEEPALIVE_STALL_MS
            if (silentMs > bounceFuse) {
                // Nothing for the fuse window — the live stream/link stalled. Bounce it: the auto-rescan on
                // disconnect re-bonds and resumes streaming (the automatic version of the manual fix).
                log("No data for ${silentMs / 1000}s — bouncing link to resume live stream")
                noteLocalTeardown("keepAliveStall")   // #1020
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
                // #927: continuous capture can be overnight-only, which makes the want TIME-dependent;
                // nothing else re-evaluates it while the app just sits connected, so the keep-alive tick
                // re-derives it. A window-close tick DISARMS (TOGGLE 0 rides the reconciler's true→false
                // edge; Android never arms the R10/R11 flood, so the toggle is the whole stop). A
                // window-open tick re-arms on the false→true edge. Runs for BOTH families: send() routes
                // the 5/MG toggle with puffin framing. Mirrors the iOS keep-alive re-derivation.
                val captureWantNow = screenWantsRealtime || continuousCaptureWantsNow()
                if (wantsRealtime != captureWantNow && keepStreamForData && !screenWantsRealtime) {
                    log(
                        if (captureWantNow) "Continuous HRV: overnight window opened; arming the realtime stream (#927)"
                        else "Continuous HRV: overnight window closed; realtime stream disarmed until tonight (#927)",
                    )
                }
                reconcileRealtime()   // recomputes wantsRealtime from the fresh predicate; toggles only on an edge
                // WHOOP 4.0 only: re-arm realtime HR so the firmware can't let it lapse (while the Live
                // screen wants it), and poll battery (~60s) — which also keeps the link warm. A 5/MG
                // strap rejects WHOOP4-framed commands, so we skip them and rely on re-subscribe + bounce.
                // Advance the tick for both families so the ~60s battery cadence also fires on 5/MG (it
                // previously incremented only inside the WHOOP 4 branch).
                keepAliveTick += 1
                // #1121: ONLY while a detailed capture is running (zero work otherwise — one volatile read):
                // sample the PHONE battery on the same ~60s cadence as the strap poll, so the capture carries
                // a phone-battery curve on the offload/connection timeline ("phone dropped N% across this
                // offload"), and flush the rolling file this tick so a sparse idle tail survives an abrupt
                // kill. The strap `[battery]` line is the strap's SoC; this is the phone's. PII-free.
                if (captureLogWriter != null) {
                    if (keepAliveTick % 2 == 0) phoneBatteryLine()?.let { log(it) }
                    flushCaptureLog()
                }
                if (connectedFamily == DeviceFamily.WHOOP4) {
                    if (wantsRealtime) { realtimeArmed = true; send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1)) }
                    if (keepAliveTick % 2 == 0) send(CommandNumber.GET_BATTERY_LEVEL)
                } else if (connectedFamily == DeviceFamily.WHOOP5 && keepAliveTick % 2 == 0) {
                    // 5/MG battery comes only from a 0x2A19 read and the strap sends no unsolicited battery
                    // notification, so poll it here (about every 60s) rather than only while the Live screen
                    // is open. The ring then stays current on any screen without a manual sync, and the read
                    // keeps the link warm.
                    refreshBattery()
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
     *  gated there on the background-connection preference. Mirrors the Swift `setKeepRealtimeForData`.
     *  #927: also called with the UNCHANGED preference when "overnight only" flips, purely to re-run the
     *  reconciler with the fresh window gate. */
    fun setKeepStreamForData(keep: Boolean) {
        keepStreamForData = keep
        reconcileRealtime()
    }

    /** #927: the continuous-capture side of the realtime want, window-gated. True while the "Continuous
     *  HRV capture" preference wants the stream held open AND, when "overnight only" is on, the local
     *  wall clock sits inside the nightly window (the reused quiet-hours window, 22:00 → 07:00 by
     *  default). RE-DERIVED at every arm site (reconcile / keep-alive tick / post-bond arm) instead of
     *  precomputed, so a reconnect outside the window can never arm the stream from a stale value.
     *  Mirrors the Swift `continuousCaptureWantsNow`. */
    private fun continuousCaptureWantsNow(): Boolean {
        if (!keepStreamForData) return false
        // #477: optional power-saving pause — while power saving is ACTIVE (battery ≤ threshold or Battery
        // Saver, discharging), release the held-open continuous-capture stream (its own toggle, default
        // off). Battery-%-aware like the offload/defer levers, via the shared idleThrottleActive gate. The
        // realtime stream is one of the larger drains; a Live screen still arms it on demand
        // (screenWantsRealtime is checked separately in reconcileRealtime), so this only drops the
        // BACKGROUND capture the user opted into. Re-arms automatically once off power save.
        if (pauseCaptureBatteryPct > 0) {
            val (batteryPct, charging) = batteryPctAndCharging()
            if (idleThrottleActive(batteryPct, charging, pauseCaptureBatteryPct)) return false
        }
        val cal = java.util.Calendar.getInstance()
        val minuteOfDay = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
        return continuousHrvStreamWanted(
            continuousHrv = true,
            overnightOnly = NoopPrefs.continuousHrvOvernight(context),
            minuteOfDay = minuteOfDay,
            startMin = NotifPrefs.getInt(context, NotifPrefs.QUIET_START, 22 * 60),
            endMin = NotifPrefs.getInt(context, NotifPrefs.QUIET_END, 7 * 60),
        )
    }

    /**
     * Single reconciler for the realtime-HR stream. The stream should be armed while EITHER a screen
     * wants it ([screenWantsRealtime]) OR the continuous-capture preference wants it ([keepStreamForData],
     * window-gated by #927 overnight-only via [continuousCaptureWantsNow]).
     * We arm (TOGGLE_REALTIME_HR 1) / disarm (TOGGLE_REALTIME_HR 0) ONLY on the false↔true edge of that
     * derived want — so a Live screen closing while the preference still wants it does NOT disarm, and
     * turning the preference off with no screen open DOES disarm. The toggle only reaches the strap once
     * it's a WHOOP4 (custom channels are open immediately) or a bonded 5/MG (puffin framing); otherwise
     * the want is remembered and the post-bond branch arms it. Port of `BLEManager.reconcileRealtime`.
     */
    private fun reconcileRealtime() {
        // Confine to the GATT looper (main), exactly like [drainWriteQueue]/[drainCccdQueue]. This does an
        // order-sensitive check-then-set on [realtimeArmed] and is reachable from ViewModel callers
        // (startRealtime / stopRealtime / setKeepStreamForData) as well as the main-looper keep-alive tick
        // and post-bond arm. Every caller runs on Main today, so this is a no-op pass-through — but it makes
        // the battery-critical stream toggle self-enforcing: a future off-main caller is deferred onto the
        // looper instead of silently racing the keep-alive tick on [realtimeArmed]. iOS gets this for free
        // via @MainActor isolation on BLEManager; Kotlin has no compile-time actor, so the confinement is
        // enforced at runtime here. The deferred re-run re-derives `want` from the fresh flags, so it
        // reconciles against the latest state.
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { reconcileRealtime() }
            return
        }
        val want = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = want   // the keep-alive + post-bond arm-on-connect read this derived value
        if (want == realtimeArmed) return                          // no edge — nothing to send
        if (connectedFamily != DeviceFamily.WHOOP4 && !_state.value.bonded) return   // can't reach the strap yet
        realtimeArmed = want
        // Both families arm/disarm via TOGGLE_REALTIME_HR; send() frames it correctly per family (puffin
        // for 5/MG). A screen re-entry blanks its own smoothing window in the view-model, not here.
        send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(if (want) 1.toByte() else 0.toByte()))
        refreshConnectionPriority()   // #477: live-HR on → HIGH, off → back to idle. No-op unless enabled.
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
        _state.update { it.copy(r22FlagsAccepted = 0) }   // fresh attempt
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
            log("Deep-data: sequence sent. Keep the strap on, let it sync, then share your strap log — we're looking for new deep records (type-0x2F) to start arriving. To undo it later, use \"Turn deep data back off\" — disableWhoop5DeepData() writes '0' to the same sixteen keys and reads each one back. (#174)")
        }, 80L * flags.size + 200L)
    }

    /**
     * EXPERIMENTAL (#174): the undo of [enableWhoop5DeepData] — write '0' to the sixteen `enable_r22_*`
     * feature flags and report, per key, the value the strap actually stores afterwards. Port of
     * `BLEManager.disableWhoop5DeepData`.
     *
     * Why this exists: the Settings copy has promised since #174 that the R22 unlock is "reversible", and
     * that was true about the hardware and false about the app — NOOP shipped an enable button and no way
     * back, so the only routes out were the official WHOOP app or a factory reset.
     *
     * Why it is staged rather than sixteen writes: '0' is the confirmed off value in the device-config
     * namespace (#181, hardware-validated) and that namespace shares this one's entire wire idiom — but no
     * FEATURE flag has ever been observed holding '0', and the two namespaces are proven separate at the
     * verb level. So the run writes ONE flag, reads it back, and only touches the other fifteen if the
     * strap actually stopped reporting the old value.
     *
     * The ack is never the proof: SELECT_WRIST returns SUCCESS for a no-op and FAILURE for a real mutation
     * on this firmware, so only the value a GET_FF_VALUE(128) read returns is reported as state (#907/#891).
     *
     * Same guards as the enable minus wear: the on-wrist gate exists because the R22 STREAM is on-wrist
     * only, and turning a feature off should not require strapping the device back on.
     */
    fun disableWhoop5DeepData() {
        if (connectedFamily != DeviceFamily.WHOOP5) {
            log("Deep-data disable: needs a WHOOP 5.0/MG strap — ignored."); return
        }
        // NOTE there is deliberately NO isDeepDataEnabled guard here. There was one, and it made this whole
        // function unreachable from the control users actually use: the Settings switch writes the pref
        // false the moment it is flipped OFF, THEN raises the "Clear the R22 flags on your strap?" dialog.
        // By the time the user taps "Clear flags on strap" the pref is already false, so the guard returned
        // at the top and nothing happened — the same shape of defect this change exists to fix (UI
        // promising an undo that never runs). The send allowlist now gates the off-value writes on
        // r22DisableRun != null instead, which is the state that is actually about this operation. (#174)
        val s = _state.value
        if (!s.connected || !s.encryptedBond) {
            log("Deep-data disable: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to NOOP first — ignored."); return
        }
        if (r22DisableRun != null) {
            log("Deep-data disable: a disable run is already walking its plan — ignored."); return
        }
        r22DisableRun = R22DisableReport()
        _r22DisableReport.value = WAITING_DEVICE_CONFIG_PROBE
        log(
            "Deep-data disable (#174): clearing the ${Whoop5Config.disableR22Sequence.size}-flag R22 " +
                "sequence — writing '0' via SET_FF_VALUE(120), each verified with GET_FF_VALUE(128). " +
                "Probing ${R22DisableReport.PROBE_KEY} first; the other flags are only written if that one moves."
        )
        advanceR22Disable()
    }

    /** Send the next planned step, or finish when the plan is done. */
    private fun advanceR22Disable() {
        val step = r22DisableRun?.nextStep()
        if (step == null) { finishR22Disable(); return }
        val cmd = CommandNumber.entries.firstOrNull { it.rawValue == step.opcode }
        if (cmd == null) {
            log("Deep-data disable: refusing to send unknown opcode ${step.opcode}")
            finishR22Disable(); return
        }
        val payload: ByteArray
        if (step.isWrite) {
            payload = byteArrayOf(0x01) +
                Whoop5Config.payloadBody(step.key, Whoop5Config.FEATURE_FLAG_OFF_VALUE)
            // Fail closed: the same predicate the send path consults, asked here too, so a future edit that
            // widened the plan cannot put an unrecognised key or value on the wire. `r22DisableRun != null`
            // is true by construction here (this is only called from inside a run) — it is passed rather
            // than hardcoded so this and the send path evaluate the identical predicate.
            if (!FeatureFlagWriteGate.admitsDisableWrite(step.opcode, payload, r22DisableRun != null)) {
                log("Deep-data disable: refusing to write ${step.key} — not admitted by the feature-flag gate")
                finishR22Disable(); return
            }
        } else {
            if (!FeatureFlagWriteGate.isReadBackOpcode(step.opcode)) {
                log("Deep-data disable: refusing to read with opcode ${step.opcode}")
                finishR22Disable(); return
            }
            payload = DeviceConfigReadProbe.requestBody(step.key)
        }
        r22DisableStep++
        r22DisableAwaiting = step
        val armed = r22DisableStep
        send(cmd, payload, withResponse = true)
        handler.postDelayed({
            if (r22DisableRun != null && r22DisableStep == armed && r22DisableAwaiting != null) {
                r22DisableAwaiting = null
                r22DisableRun?.noteTimeout(step, (DEVICE_CONFIG_PROBE_TIMEOUT_MS / 1000).toInt())
                advanceR22Disable()
            }
        }, DEVICE_CONFIG_PROBE_TIMEOUT_MS)
    }

    /** Render + publish + log the report and end the run (which also re-closes the 128 send allowlist). */
    private fun finishR22Disable() {
        val report = r22DisableRun ?: return
        r22DisableRun = null
        r22DisableAwaiting = null
        // The "Strap accepted N/16 R22 flags" line reports the last ENABLE send. If this run cleared even
        // one key that claim is stale, so retire it rather than leaving the card asserting the strap is
        // unlocked while the report below says it was just cleared.
        if (report.outcomes.values.any { it.isSuccess }) {
            _state.update { it.copy(r22FlagsAccepted = 0) }
        }
        val text = report.render()
        log("Deep-data disable (#174):\n$text")
        _r22DisableReport.value = text
    }

    /** Clear the #174 disable result (Settings card dismissed). */
    fun clearR22DisableReport() { _r22DisableReport.value = null }

    /**
     * #174: one COMMAND_RESPONSE belonging to a disable run — either a SET_FF_VALUE(120) write ack or a
     * GET_FF_VALUE(128) read-back. Guarded on a run being IN-FLIGHT so a stray byte match can never
     * surface a result. Parsing — including the CRC gate — lives in the pure [DeviceConfigReadProbe].
     */
    private fun handleR22DisableResponse(frame: ByteArray) {
        if (r22DisableRun == null) return
        val step = r22DisableAwaiting ?: return
        r22DisableAwaiting = null
        if (step.isWrite) {
            // The ack is recorded for the transcript and decides nothing. The puffin envelope puts the type
            // at 8 and the cmd at 10, so the payload starts at 11 and the result byte is at 12.
            val resultCode = if (frame.size > 12) frame[12].toInt() and 0xFF else null
            r22DisableRun?.noteWriteAck(resultCode, step)
        } else {
            val parsed = DeviceConfigReadProbe.parse(frame, connectedFamily, step.opcode)
            val value = parsed.value
            if (value != null) r22DisableRun?.noteReadBack(value, step)
            else r22DisableRun?.noteReadFailure(parsed.failure!!, step)
        }
        advanceR22Disable()
    }

    /** Abandon a disable run the link interrupted, re-closing the 128 send allowlist. */
    private fun abandonR22DisableRun(why: String) {
        if (r22DisableRun == null) return
        r22DisableRun?.noteAbandoned(why)
        finishR22Disable()
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
                // #791: report WHICH refusal, not just that there was one. A retry is only safe if the write
                // truly was not initiated, and a reporter's captures show it sometimes WAS — so the status
                // code is the evidence that tells the two apart. Frame is named too, since the harm from a
                // duplicate depends entirely on which command got sent twice.
                log(
                    "writeCharacteristic busy; retry $writeRetries/$MAX_WRITE_RETRIES " +
                        "cmd=${item.cmd?.name ?: "raw"} ${writeStatusLabel((ops as? RealGattOps)?.lastWriteStatus)}",
                )
                pendingRetry = item
                // Escalating backoff (12, 24, … capped ~96ms) — ride out a congestion spike instead of
                // exhausting the budget in a few tens of ms while the stack is still busy (#77). NAMED
                // runnable so teardown can cancel a pending retry (#314).
                handler.postDelayed(drainWriteRetryRunnable, WRITE_RETRY_DELAY_MS * minOf(writeRetries, 8))
            } else {
                // Genuinely stuck after several tries — drop this one frame so it can't wedge the queue.
                log("writeCharacteristic rejected by stack; dropping one frame (after $MAX_WRITE_RETRIES retries)")
                // #312: a dropped TOGGLE_REALTIME_HR would leave live R-R (→ HRV / Autonomic) off FOREVER.
                // Whoever queued it latched [realtimeArmed] = the value it SENT (reconcileRealtime, or the
                // direct arm-on-connect / keep-alive paths), so it — and the 30s keep-alive tick that also
                // reconciles — see no edge (want == armed) and never re-send, while plain HR keeps flowing
                // over the standard 0x2A37 profile. But the write never reached the strap, so the strap's
                // TRUE state is the OPPOSITE of the latched value — flip it back, and the next keep-alive
                // reconcile detects the edge and re-sends the CURRENT want (recovers a dropped ARM *or* a
                // dropped disarm) within ~30s. Bounded by construction: the re-send rides the keep-alive
                // cadence, not this drop path, so a persistently-busy stack retries once per tick, never in a loop.
                if (shouldReArmRealtimeAfterDrop(item.cmd)) {
                    realtimeArmed = !realtimeArmed
                    log("realtime toggle dropped — reconciling on the next keep-alive tick (#312)")
                }
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
        val s = seq.incrementAndGet() and 0xFF
        val bondFrame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), s)
        log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
        writeInFlight = true   // hold the slot until onCharacteristicWrite fires (with response).
        bondWriteOutstanding = true   // #791: this write bypasses the queue; its ack proves nothing about pendingRetry
        // safeGatt: a throw means the binder died (#314) — teardown, return false, fall into the
        // "rejected" branch which just clears the (now-stale) in-flight slot.
        val ok = safeGatt("writeBondFrame") {
            ops.writeCharacteristicCompat(ch, bondFrame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        }
        if (!ok) {
            writeInFlight = false
            bondWriteOutstanding = false
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
                noteRebootReconnectIfNeeded()
                send(CommandNumber.SET_CLOCK, setClockPayload(), withResponse = true)
                send(CommandNumber.GET_CLOCK, byteArrayOf(), withResponse = true)
                // Populate the battery ring right after connect, not only once the Live screen opens. Posted
                // after the clock writes settle so the 0x2A19 read does not race them on a slow stack.
                handler.postDelayed({ refreshBattery() }, BATTERY_ON_CONNECT_DELAY_MS)
                // #520: read the DIS identity on the same post-handshake schedule, staggered after the
                // battery read so the two do not contend for the serialized GATT queue.
                handler.postDelayed({ readDisIdentity() }, BATTERY_ON_CONNECT_DELAY_MS * 2)
                log("WHOOP 5/MG: clock synced (set/get) — strap can persist history now")
                if (!backfillStarted) {
                    backfillStarted = true
                    handler.postDelayed({ requestSync(BackfillTrigger.CONNECT) }, INITIAL_BACKFILL_DELAY_MS)
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
    /** Parse-then-buffer shim (#47). Kept for callers that pass raw bytes; the live dispatcher passes the
     *  parse it already did. */
    private fun ingestLiveFrame(frame: ByteArray) =
        ingestLiveFrame(frame, Framing.parseFrame(frame, connectedFamily))

    private fun ingestLiveFrame(frame: ByteArray, parsed: com.noop.protocol.ParsedFrame) {
        val shouldFlush = synchronized(collectorLock) {
            liveBuffer.add(frame to parsed)   // synchronous append preserves GATT-callback arrival order
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
        val parsed = frames.map { it.second }   // #47: the dispatcher already decoded these — don't re-parse
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
        // #700: if GET_CLOCK never responded (Android has no explicit clockRef on the client — the
        // Backfiller defaults to identity), seed a rough correlation from the Data Range's newest-banked
        // timestamp. The offset is approximate but vastly better than identity (offset 0), which can
        // mis-date nights when the strap's RTC has drifted. No-op when strapNewestTs is null (no Data
        // Range received yet) — the Backfiller keeps its identity default, same as today.
        strapNewestTs?.let { newest ->
            val wall = (System.currentTimeMillis() / 1000L).toInt()
            backfiller.clockRef = ClockRef(device = newest.toInt(), wall = wall)
            log("Clock: seeded backfiller correlation from Data Range (device=$newest wall=$wall, offset ${wall - newest}s)")
        }
        // #42/#364: consecutiveAutoContinues > 0 means this offload is re-kicked after an EARLIER session
        // in the same burst banked rows — tell the backfiller so its no-cursor END reads as "caught up",
        // not "no banked history / charge to 100%". A fresh offload (count 0) keeps the honest guidance.
        backfiller.begin(connectedFamily, continuedAfterRows = consecutiveAutoContinues > 0)   // family drives the +4 puffin offset for 5/MG (#78)
        backfilling = true
        lastBackfillAtMs = System.currentTimeMillis()   // the BackfillPolicy floor is measured from the last KICK
        ackedChunksThisSession = 0
        decodedChunksThisSession = 0
        consoleChunksThisSession = 0
        offloadFramesThisSession = 0
        // #1007: wall time the burst began, for the throughput line at exit. Its own field rather than
        // reusing lastBackfillAtMs, which is the BackfillPolicy floor and measures from the last KICK.
        backfillStartedAtMs = System.currentTimeMillis()
        historicalKickSent = false
        _state.update { it.copy(backfilling = true, syncChunksThisSession = 0) }
        refreshConnectionPriority()   // #477: escalate to HIGH for the offload burst (faster sync). No-op unless enabled.
        applyPreferredPhy()           // #533: prefer LE 2M for the burst (halves air-time). No-op unless enabled.
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
     * bonded and NOT already mid-backfill, then through [BackfillPolicy] (the Swift parity gate, now
     * ported — see Strand/BLE/BackfillPolicy.swift): the caller passes the [BackfillTrigger] so the
     * AUTOMATIC periodic/strap kicks are floored, empty-streak-backed-off, and skipped on an untrusted
     * clock, while manual/connect/foreground run at the 90s event floor. Previously the fixed 900s timer
     * was the only coarse limit, so a not-banking strap was re-offloaded every 15 min forever.
     *
     * #266: clockUntrusted is recomputed HERE from the live [strapNewestTs] and wall clock on every call
     * (never cached) — a strap that stays connected with a self-correcting RTC is re-evaluated on the very
     * next sync attempt of any kind, not just at the next disconnect/reconnect. Twin of the Swift
     * `BLEManager.requestSync`, which recomputes inline the same way.
     */
    private fun requestSync(trigger: BackfillTrigger) {
        val s = _state.value
        if (!canRequestSync(s.connected, s.bonded, backfilling)) return
        val clockUntrusted = isFutureDatedNewest(strapNewestTs, System.currentTimeMillis() / 1000L)
        if (!BackfillPolicy.shouldRun(
                trigger = trigger,
                nowSeconds = System.currentTimeMillis() / 1000.0,
                lastBackfillAtSeconds = lastBackfillAtMs?.let { it / 1000.0 },
                // #battery: back off on EITHER a console-only streak (clock-lost, [emptySyncTracker]) OR a
                // plain empty-offload streak incl. idle-timeout stalls ([consecutiveEmptyOffloads]); the
                // latter is what stops the 15-min radio poll spinning on a caught-up strap.
                emptyStreak = maxOf(emptySyncTracker.consecutiveEmptySyncs, consecutiveEmptyOffloads),
                clockUntrusted = clockUntrusted,
            )
        ) {
            log(
                "Backfill: skipped ($trigger) - policy floor not met " +
                    "(empty streak ${emptySyncTracker.consecutiveEmptySyncs}" +
                    "${if (clockUntrusted) ", clock future-dated" else ""})",
            )
            return
        }
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
        handler.post { requestSync(BackfillTrigger.MANUAL) }
    }

    /**
     * App-active entry point (#267): call when NOOP comes to the foreground so opening the app pulls a
     * reasonably fresh sync instead of relying on the 900s periodic timer or an incidental reconnect.
     * Forwards to the SAME gated [requestSync] every other trigger uses — floored at the 90s event floor
     * and never empty-streak/clock-suppressed (see [BackfillPolicy.shouldRun]'s `.FOREGROUND` case) — so
     * it's a safe, cheap no-op no matter how often the caller invokes it.
     */
    fun onForeground() {
        handler.post { requestSync(BackfillTrigger.FOREGROUND) }
    }

    /** Periodic-timer callback: re-runs the type-47 offload (the primary metric sync). */
    private fun triggerPeriodicBackfill() {
        requestSync(BackfillTrigger.PERIODIC)
        // Re-arm regardless so the cadence continues for the life of the connection. #477: the delay is
        // battery-adaptive (stretched when low), read fresh at each re-arm.
        handler.postDelayed(periodicBackfillRunnable, nextBackfillDelayMs())
    }

    private fun startBackfillTimer() {
        handler.removeCallbacks(periodicBackfillRunnable)
        handler.postDelayed(periodicBackfillRunnable, nextBackfillDelayMs())
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
        val lease = backfillDrain.enqueue(frame) ?: return
        ioScope.launch {
            var ownsDrain = true
            // A throw from ingest() must NEVER leave the drain stuck owned (that would wedge the
            // offload — every later frame returns early and the queue never drains). finally guarantees
            // the lease is released even if a chunk handler throws. (#77/#91 hardening.)
            try {
                while (true) {
                    val f = backfillDrain.pollOrRelease(lease)
                    if (f == null) {
                        ownsDrain = false
                        break
                    }
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
                if (ownsDrain) backfillDrain.release(lease)
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
            _state.update { it.copy(backfilling = false, syncChunksThisSession = 0) }
            handler.removeCallbacks(backfillTimeoutRunnable)
            backfillDrain.clear()
            log("Backfill: no history frames arrived — retrying request (attempt ${whoop5HistoryAttempts + 1})")
            // Bounded mid-attempt retry (whoop5HistoryAttempts < 2): AUTO_CONTINUE so the 90s event floor
            // can't suppress it — it's continuing THIS connect's offload, not a fresh periodic kick.
            handler.postDelayed({ requestSync(BackfillTrigger.AUTO_CONTINUE) }, WHOOP5_HISTORY_RETRY_DELAY_MS)
            return
        }
        backfiller.timeoutFired()
        exitBackfilling("timeout")
    }

    /**
     * Stop an offload that is part-way through, at the user's request.
     *
     * NOOP has been able to START a drain since day one (SEND_HISTORICAL_DATA) with no way to stop it:
     * a session ran to HISTORY_COMPLETE, the backfill timeout, or a dropped link.
     *
     * NOTHING IS LOST. The strap frees banked records when we ack a HISTORY_END, so acked records are
     * persisted and unacked ones stay in flash and re-offload next sync. A stop, not a trim.
     *
     * The local teardown does NOT depend on the strap honouring opcode 20 — [exitBackfilling] runs
     * either way, the same path the timeout and disconnect already use — so a firmware that ignores
     * the abort degrades to today's behaviour rather than wedging the UI in "Syncing". Deliberate: the
     * opcode is confirmed in use on WHOOP 4.0 by OpenStrap Edge, and is NOT hardware-confirmed here on
     * either family. Twin of Swift `BLEManager.abortBackfill()`.
     */
    fun abortBackfill() {
        if (!canAbortSync(backfilling)) {
            log("Abort sync ignored — no offload in flight")
            return
        }
        // Send BEFORE tearing down: the 5/MG allow-list admits opcode 20 only while `backfilling` is
        // still true, so the ordering here is load-bearing, not stylistic.
        if (_state.value.connected) {
            send(CommandNumber.ABORT_HISTORICAL_TRANSMITS, byteArrayOf(0), withResponse = true)
            log("Abort sync: ABORT_HISTORICAL_TRANSMITS (20) sent; unacked records stay on the strap")
        } else {
            log("Abort sync: not connected — tearing down the local session only")
        }
        // The reason string is deliberately NOT one [exitBackfilling] classifies. Only "HISTORY_COMPLETE"
        // stamps lastSyncAt and only "timeout" raises a sync error; everything else hits the `else` branch
        // and leaves both untouched — exactly right for an abort. A cancelled sync is neither a success
        // nor a failure: nothing was lost, and the next sync re-offloads what was left. If a future edit
        // starts classifying more reasons, this one must stay in the fall-through. Twin of the Swift note.
        exitBackfilling("aborted by user")
    }

    /** Tear down the backfill session. Port of `exitBackfilling`. Does NOT auto-start live HR. */
    private fun exitBackfilling(reason: String) {
        if (!backfilling) return
        backfilling = false
        refreshConnectionPriority()   // #477: offload done — drop back to idle priority. No-op unless enabled.
        // #533: offload done — hand the PHY back to 1M too, so the 2M preference is BOUNDED to the burst
        // exactly like the priority escalation above. A PHY PERSISTS once negotiated, so without this a link
        // that went 2M for the sync stayed 2M for the WHOLE connection — including the overnight window —
        // which is not what the toggle's copy promises ("while your strap hands over its stored history"),
        // and left 2M's range trade-off in force long after the transfer it was for.
        // Guarded here rather than inside releasePreferredPhy: that method cannot check the flag, because
        // setFastLinkPhy's on→off edge calls it AFTER the flag is already false. So the default path still
        // issues ZERO BLE ops.
        if (fastLinkPhyEnabled) releasePreferredPhy()
        // #1007: what the burst actually achieved. Emitted unconditionally (one line per offload, not per
        // frame) so an ordinary exported strap log carries it — behind the test-mode gate it would need a
        // reporter to find Test Centre first, which is the friction that left #477/#533 unvalidated.
        val offloadElapsedMs =
            if (backfillStartedAtMs > 0L) System.currentTimeMillis() - backfillStartedAtMs else -1L
        log("Backfill: ${offloadThroughputLine(offloadFramesThisSession, offloadElapsedMs)} ($reason)")
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
        // #42: the empty tail of an auto-continue burst (consecutiveAutoContinues > 0) isn't a "banked
        // nothing" sync — an EARLIER session in the same burst handed over real rows and this pass just
        // confirms we're caught up. Don't surface the "charge to 100%" framing, and don't count it toward
        // the sustained-empty streak (the productive session already cleared it).
        val productiveBurstTail = consecutiveAutoContinues > 0
        val bankedNothing = reason == "HISTORY_COMPLETE" && bankedNothingRaw && !productiveBurstTail
        // #126: only escalate to the clock-lost banner once emptiness is SUSTAINED. A banking cycle (any
        // decoded records / rows persisted) clears the streak, so a single transient empty cycle on a
        // healthy strap stays silent. Track on every completed sync so banking cycles reset it.
        val sustainedEmpty = if (reason == "HISTORY_COMPLETE" && !productiveBurstTail)
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
        // #battery: maintain the empty-offload backoff counter (see [consecutiveEmptyOffloads]). A 0-row
        // session — clean HISTORY_COMPLETE-empty OR an idle-timeout STALL — means there was nothing new to
        // fetch, so let BackfillPolicy stretch the next PERIODIC/STRAP poll instead of re-spinning the radio
        // in 15 min. Any banked rows reset it; a productive auto-continue tail (an earlier session in the
        // burst already banked) neither counts nor resets.
        consecutiveEmptyOffloads = when {
            backfiller.sessionRowsPersisted > 0 -> 0
            productiveBurstTail -> consecutiveEmptyOffloads
            else -> consecutiveEmptyOffloads + 1
        }
        // #324/#928: a strap whose newest banked record is dated in the FUTURE (RTC relatched ahead) is
        // future-dated regardless of HOW this offload ended — a deep future-dated backlog TIMES OUT as
        // readily as it completes (the reporter's #324 session ended on timeout, not HISTORY_COMPLETE).
        // Compute the banner once so BOTH outcomes name the real cause instead of "strap went quiet".
        val futureClockBanner = futureDatedStrapBanner(strapNewestTs, nowSec)
        if (futureClockBanner != null) {
            val aheadH = ((strapNewestTs ?: 0L) - nowSec) / 3600
            log("Backfill: the strap's newest banked record is ${aheadH}h AHEAD of the wall clock (#324/#928) - clock set in the future; showing the future-clock banner and importing nothing from this range.")
        }
        // PR #556 reimpl: persist the HISTORY_COMPLETE instant so "Last synced N ago" survives a BLE-client
        // recreation / process restart and stops reverting to "Never".
        if (reason == "HISTORY_COMPLETE") NoopPrefs.setLastSyncAt(context, nowSec)
        // #57 debug: write-health signal for the export. "Last sync" fires even on an empty/failed offload,
        // so it can't distinguish "0 rows because the strap was empty" from "0 rows because writes FAILED".
        // Record the last time rows actually landed, and the last time an offload STALLED on a persist
        // failure (the closed-DB-after-restore class) — so a future "sync stuck at 0" report is decidable.
        runCatching {
            val p = NoopPrefs.of(context).edit()
            if (backfiller.sessionRowsPersisted > 0) p.putLong("sync.lastWriteOkAt", nowSec)
            if (backfiller.persistStalled) p.putLong("sync.lastWriteStalledAt", nowSec)
            p.apply()
        }
        // #580: a WHOOP 5/MG whose firmware serves no history offload (acks SEND_HISTORICAL_DATA but emits
        // zero type-0x2F frames) times out every session — but that's NOT a failure: live HR streams fine,
        // the offload is just experimental on that firmware. "Banked" = this offload made ANY offload
        // progress (frames routed, rows persisted, or deep packets). On a 5/MG, route the timeout through
        // the empty-offload tracker so a sustained empty streak reads as "history experimental", not the
        // WHOOP-4 "strap went quiet" error, and the bounce loop backs off (see keepalive). A WHOOP 4 keeps
        // the honest "went quiet" error.
        val isWhoop5 = connectedFamily == DeviceFamily.WHOOP5
        val bankedThisOffload = offloadFramesThisSession > 0 ||
            backfiller.sessionRowsPersisted > 0 || _state.value.deepPacketsThisSession > 0
        var whoop5HistoryExperimental = _state.value.historySyncExperimental
        if (reason == "timeout" && isWhoop5) {
            val crossed = whoop5EmptyOffload.recordOffload(bankedRecords = bankedThisOffload)
            whoop5HistoryExperimental = whoop5EmptyOffload.historyEmpty
            if (crossed) {
                log("Backfill: WHOOP 5/MG offload empty ${whoop5EmptyOffload.consecutiveEmpty}× — history sync is experimental on 5.0; surfacing 'connected, history experimental' (not a sync error) and backing off the bounce loop.")
            }
        } else if (reason == "HISTORY_COMPLETE" && isWhoop5 && bankedSensorRecords) {
            // A real HISTORY_COMPLETE with banked records proves the 5/MG offload IS working — recover.
            whoop5EmptyOffload.reset()
            whoop5HistoryExperimental = false
        }
        _state.update { when (reason) {
            "HISTORY_COMPLETE" -> it.copy(
                backfilling = false,
                syncChunksThisSession = ackedChunksThisSession,
                lastSyncAt = nowSec,
                // bankedNothing keeps its own sustained-empty precedence (#126/#214) — future-dated is
                // checked ONLY on the banked-something path, matching the Swift else-if order exactly so
                // the two platforms never disagree on which banner a given sync shows.
                lastSyncError = when {
                    bankedNothing && sustainedEmpty ->
                        "Synced, but your strap had no stored history to hand over - only its diagnostic output. This usually means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then reconnect, and it should start banking again."
                    bankedNothing -> null   // banked nothing but not yet sustained — stay silent (matches Swift)
                    // #324/#928: the strap banked records but its newest is dated implausibly in the future
                    // (RTC relatched ahead). #773 drops the samples so nothing is misfiled, but this path
                    // would otherwise report a clean sync and leave the user with no data + no reason.
                    else -> futureClockBanner
                },
                historySyncExperimental = whoop5HistoryExperimental,
                // #612: set on EVERY HISTORY_COMPLETE (not just the empty branch) so a productive sync
                // clears it immediately, exposing the streak previously reachable only via lastSyncError text.
                sustainedEmptyOffload = sustainedEmpty,
            )
            "timeout" -> it.copy(
                backfilling = false,
                syncChunksThisSession = ackedChunksThisSession,
                // #580: on a history-experimental 5/MG this isn't a sync failure — suppress the "went quiet"
                // error (it's just the empty offload), and surface the experimental flag instead.
                // #324/#928: a future-dated WHOOP-4 TIMES OUT on its deep future-dated backlog — prefer the
                // honest future-clock banner over "strap went quiet" (the reporter's #324 case timed out).
                lastSyncError = if (isWhoop5) null
                    else futureClockBanner ?: "Sync interrupted - the strap went quiet. It will retry on the next sync.",
                historySyncExperimental = whoop5HistoryExperimental,
            )
            else -> it.copy(
                backfilling = false,
                syncChunksThisSession = ackedChunksThisSession,
                historySyncExperimental = whoop5HistoryExperimental,
            )
        } }
        handler.removeCallbacks(backfillTimeoutRunnable)
        backfillDrain.clear()
        closeWhoop5BackfillCapture(flushSummary = true)
        log("Backfill: session ended — reason=$reason")
        // Inactivity reminder (#419): read-only hook on the natural offload completion (no cadence
        // change). Only on a true HISTORY_COMPLETE — a timeout/disconnect didn't bring a fresh window.
        if (reason == "HISTORY_COMPLETE") {
            maybeBuzzInactivity()
            // L3 stress check-in (v5): same read-only hook — fire the StressOnsetDetector over the live
            // R-R buffer. Self-gates on the BiofeedbackPrefs master/auto toggles (inert when off).
            maybeNudgeStress()
            // On-device short-nap detection (PR #569 reimpl): same read-only hook — judge the freshly
            // offloaded daytime window and queue a confident nap for review. Self-gates on NapPrefs (OFF
            // by default); never auto-writes a sleep session.
            maybeDetectNaps()
        }
        // Success-side summary (#150 forensics): we logged failures (decoded-to-0) but never successes,
        // so a strap log couldn't tell a banking strap from a broken one. Emit the per-session persistence
        // tally whenever anything actually landed — the win-rate signal a log previously lacked. Mirrors
        // the Swift exitBackfilling.
        Backfiller.sessionSummaryLine(
            backfiller.sessionRowsPersisted, backfiller.sessionMotionRows, backfiller.sessionSkinTempRows,
            backfiller.sessionNights,
        )?.let {
            log(it)
            // #990: fold this session's drained rows into the persisted ALL-TIME tally at the single
            // summary emit point, so the Connection readout can show install-lifetime progress beside
            // the per-session count (which resets on every reconnect). Unconditional, like the summary
            // itself - not gated on the Connection test mode. Twin of the macOS LiveState sink hook.
            testCentre.noteDrainedRows(backfiller.sessionRowsPersisted)
        }

        // #520: the motion-magnitude diagnostic for this session. Emitted independently of the summary
        // above (a caught-up session banks no rows but can still have decoded records), and silent when
        // nothing carried the field — a WHOOP 4.0 never does. Twin of the macOS exitBackfilling hook.
        backfiller.sessionDynAccel.logLine(DYN_ACCEL_STILL_THRESHOLD_G)?.let { log(it) }

        // Connection test mode: the offload OUTCOME the readout's lastOffloadResult id binds. Gated
        // zero-cost (the CONNECTION bool is read before any string is built). Diagnostic only - it reads
        // the same per-session tallies the summary above does. A timeout/idle-cap exit is a STALL; a
        // HISTORY_COMPLETE with rows is a clean complete; with none it is an empty cycle. Twin of macOS.
        if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
            val rows = backfiller.sessionRowsPersisted
            val result = when {
                reason == "timeout" -> "stalled (idle timeout, rows=$rows so far)"
                reason == "HISTORY_COMPLETE" && rows > 0 -> "complete rows=$rows nights=${backfiller.sessionNights}"
                reason == "HISTORY_COMPLETE" -> "empty (console only, no sensor records)"
                else -> "$reason rows=$rows"
            }
            log("offload result=$result", com.noop.testcentre.TestDomain.CONNECTION)
        }

        // #547 RE-POLLUTION: this session's ingest gate dropped bad-clock records, so the strap has a
        // wandering clock and may have banked similar garbage on an OLDER build whose gate was weaker. Arm a
        // heal re-run so the next analyze tick purges any such pollution — not gated behind the one-shot done
        // flag. Pure prefs set (no engine handle here); AppViewModel honours it on the next analyze tick.
        if (backfiller.sessionDroppedImplausible > 0) {
            NoopPrefs.setTsHealPending(context, true)
        }

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
     * method has already advanced [lastSessionEndTrim] past the comparison point). The re-kick uses
     * [BackfillTrigger.AUTO_CONTINUE], one of the un-floored triggers in [BackfillPolicy.shouldRun], so the
     * 15-min periodic floor can't suppress an in-progress backlog drain. Mirrors Swift `maybeAutoContinueBackfill`.
     */
    private fun maybeAutoContinueBackfill(trimAdvanced: Boolean, rowsPersisted: Int) {
        val s = _state.value
        if (!s.connected || !s.bonded) return
        val newest = strapNewestTs
        val count = consecutiveAutoContinues
        ioScope.launch {
            val frontier = runCatching { repository.latestHrSampleTs(deviceId) }.getOrNull()
            val wallNow = System.currentTimeMillis() / 1000L   // #928: real wall clock, at decision time
            // #266: local only — NOT cached on the instance. A future-dated newest (#1012) makes the
            // AUTOMATIC periodic/strap kicks near-useless for THIS decision; [requestSync] recomputes its
            // own verdict fresh from [strapNewestTs] on every call, so a stale value here can't leak forward.
            val clockUntrusted = isFutureDatedNewest(newest, wallNow)
            val stillConnected = _state.value.connected && _state.value.bonded
            if (!shouldAutoContinue(
                    stillConnected = stillConnected,
                    strapNewestTs = newest,
                    ourFrontierTs = frontier,
                    wallNowUnix = wallNow,
                    lastTrimAdvanced = trimAdvanced,
                    consecutiveCount = count,
                    rowsPersistedThisSession = rowsPersisted,
                )
            ) {
                // #1012: name the stop honestly when the future-clock gate is what ended the chain —
                // without this line the log just goes quiet after one pass and a strap-log export can't
                // tell "caught up" from "future-dated range refused". Fires ONLY when 2b would otherwise
                // have continued (still connected, rows banked, trim advanced, under the cap), so a
                // frozen-trim / cap / disconnect stop is never misattributed to the clock. Twin of the
                // Swift maybeAutoContinueBackfill line.
                if (stillConnected && rowsPersisted > 0 && trimAdvanced &&
                    count < MAX_AUTO_CONTINUES && clockUntrusted   // just set above from isFutureDatedNewest(newest, wallNow)
                ) {
                    val aheadH = ((newest ?: wallNow) - wallNow) / 3600L
                    log(
                        "Backfill: not auto-continuing (#1012) - the strap-reported newest banked record " +
                            "reads ${aheadH}h AHEAD of the wall clock, so the range is future-dated and " +
                            "the strap clock is likely wrong (#928). Stopping after one pass instead of " +
                            "chasing future-dated ranges; the periodic sync keeps draining across connects.",
                    )
                }
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
                requestSync(BackfillTrigger.AUTO_CONTINUE)
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
            _state.update { it.copy(syncChunksThisSession = ackedChunksThisSession) }
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
                noteLocalTeardown("gattThrow:$reason")   // #1020
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
        // #1151: flush any pending frame-timing window so the frames right before this drop are recorded
        // (not stranded), and the next connection starts a fresh window rather than spanning the gap. No-op
        // when capture is off. Do it BEFORE the connect-down line so the summary reads before the drop.
        flushFrameTimingSummary()
        // Snapshot the hold time and clear it IMMEDIATELY: every drop log below reads the snapshot, and a
        // stale `linkUpSinceMs` surviving into the next drop would report a hold time for a link that never
        // reached STATE_CONNECTED — the diagnostic would then invent exactly the evidence it exists to find.
        val heldSuffix = heldForLogSuffix()
        linkUpSinceMs = null
        // Reboot trail: if a user reboot is in flight, this drop is the strap acting on it. Log how long the
        // link stayed up (a real reboot drops within ~1-2s) and cancel the no-disconnect watchdog. The
        // reconnect time is logged separately once the handshake completes; rebootRequestedAtMs stays set so
        // the handshake can compute the round-trip. Twin of macOS didDisconnectPeripheral.
        rebootRequestedAtMs?.let { t ->
            rebootWatchdog?.let { handler.removeCallbacks(it) }; rebootWatchdog = null
            val ms = SystemClock.elapsedRealtime() - t
            // #275: a dropped LINK only proves a reboot on WHOOP 5.0 (verified fw). On WHOOP 4.0 the frame
            // is unconfirmed — opcode 29/payload01 was observed to drop the BLE link WITHOUT power-cycling
            // the strap (the sensor stayed on) — so don't claim a reboot; report the drop honestly. Twin of
            // Swift didDisconnectPeripheral.
            log(if (connectedFamily == DeviceFamily.WHOOP5)
                "reboot: link dropped ${ms}ms after send — reboot took effect; awaiting reconnect"
            else
                "reboot: link dropped ${ms}ms after send — but a WHOOP 4.0 reboot isn't confirmed; a dropped link alone isn't proof (a real reboot also switches the sensor light off). Awaiting reconnect")
        }
        // Connection test mode: capture whether THIS attempt ever reached STATE_CONNECTED before the
        // state copy below clears `connected`. Android delivers BOTH a post-connect involuntary drop AND a
        // connect attempt that never reached connected through this one onConnectionStateChange(DISCONNECTED)
        // seam, so `connected` here is the only signal that splits them. wasConnected == true => an
        // involuntary drop (macOS didDisconnectPeripheral, the plain `reconnect` line); false => a failed
        // connect that never came up (macOS didFailToConnect, the `failedConnect` variant). Read once.
        val wasConnected = _state.value.connected
        // Capture BEFORE reset() wipes didBond: a bonded fast-path connect that dropped without ever
        // reaching a session means the OS bond is stale — fall back to a scan so a new/re-paired
        // strap can still be found (and "No WHOOP strap found" guidance still appears). (#78 fork)
        val staleDirectBond = bondedDirectAttempt && !didBond
        bondedDirectAttempt = false

        // #617 bond-loop detection: read the bond timestamp before it's cleared below. The bond-loop
        // tell is a CONNECTION TIMEOUT that lands within seconds of a genuine bond — bond -> drop -> rescan
        // -> bond -> drop, forever. We require the stack to classify the drop as GATT_CONN_TIMEOUT (the twin
        // of iOS CBError.connectionTimeout), not merely any non-zero status, so a one-off radio blip or a
        // different failure doesn't get mistaken for the loop. Once it trips, surface the EXISTING re-pair
        // guide (the same forget-and-re-pair steps the stale-bond path shows) rather than letting the link
        // loop silently and drain the battery.
        val bondedAtSnapshot = bondedAtMs
        val msSinceBond = bondedAtSnapshot?.let { System.currentTimeMillis() - it }
        val connTimedOut = status == GATT_CONN_TIMEOUT && !intentionalDisconnect
        if (postBondLoop.connectionEnded(
                wasBonded = bondedAtSnapshot != null,
                msSinceBond = msSinceBond,
                timedOut = connTimedOut,
            )
        ) {
            log("Bond-loop (#617): ${postBondLoop.consecutiveBondTimeouts} bond-then-timeout cycles — surfacing the re-pair guide and pausing auto-reconnect")
            // #844 — the loop is bond → drop → rescan → bond → drop, forever, draining the battery. Surfacing
            // the guide alone left the involuntary-drop rescan running. Pause auto-reconnect too (the disconnect
            // rescan already skips while this is set); a user Connect or a genuine bond re-arms it. We do NOT
            // touch the bond/parse path — the bond is real; the stale OS pairing is the problem. Mirrors the
            // Swift BLEManager #844 fix.
            autoReconnectPausedForBondLoop = true
            bondLoopPausedAtMs = System.currentTimeMillis()   // the #78 hole-4 salvage probe covers this pause too (one bounded cycle)
            if (_state.value.reconnectGuide == null) {
                _state.update { it.copy(
                    reconnectGuide = """
                    Your strap keeps connecting and then dropping a second later. This is almost always a stale Bluetooth pairing - usually after a WHOOP firmware update, or the official WHOOP app holding the strap. NOOP works fine once it's re-paired:

                    1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                    2. Open Settings → Bluetooth, find your WHOOP, and Forget / Unpair it.
                    3. Tap the band repeatedly until its LEDs flash blue (pairing mode).
                    4. Come back here and tap Connect.
                    """.trimIndent()
                ) }
            }
        }
        bondedAtMs = null   // cleared after the bond-loop detector above read it (#617)

        // #982: the OTHER unbounded loop — a strap that connects + subscribes but never bonds, then
        // self-drops (status 0) BEFORE the escalating bond watchdog fires, advances neither give-up counter
        // ([onBondWatchdog] only counts its own localTerminate bounce; #617 needs a genuine bond + a
        // GATT_CONN_TIMEOUT). Feed THIS drop into the SAME #971 give-up counter so the loop is bounded and
        // hands off to the identical re-pair guide + paused auto-reconnect. `didBond` is still valid here
        // ([reset] clears it below); [shouldCountNeverBondedSelfDrop] excludes our own localTerminate bounce
        // to avoid double-counting a cycle. recordBounce() (short-circuited off the gate) increments the
        // shared streak and returns true only on the bounce that first crosses the give-up threshold.
        if (shouldCountNeverBondedSelfDrop(
                wasConnected = wasConnected,
                didBond = didBond,
                intentionalDisconnect = intentionalDisconnect,
                staleDirectBond = staleDirectBond,
                status = status,
                alreadyPausedForBondLoop = autoReconnectPausedForBondLoop,
            ) && bondWatchdogBackoff.recordBounce()
        ) {
            log("Strap connects and subscribes but never finishes pairing, then self-drops before the bond watchdog fires (${bondWatchdogBackoff.consecutiveBounces} cycles) " +
                bondWatchdogContext() + " — pausing auto-reconnect and surfacing the re-pair guide (#982/#971)")
            autoReconnectPausedForBondLoop = true
            bondLoopPausedAtMs = System.currentTimeMillis()   // the #78 hole-4 salvage probe covers this pause too
            if (_state.value.reconnectGuide == null) {
                _state.update { it.copy(
                    reconnectGuide = """
                    Your strap connects but never finishes pairing with NOOP, so it drops and retries in a loop. This is almost always a stale Bluetooth pairing, usually after a WHOOP firmware update, or the official WHOOP app holding the strap. NOOP works fine once it's re-paired:

                    1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                    2. Open Settings → Bluetooth, find your WHOOP, and Forget / Unpair it.
                    3. Tap the band repeatedly until its LEDs flash blue (pairing mode).
                    4. Come back here and tap Connect.
                    """.trimIndent()
                ) }
            }
        }

        // Persist anything buffered before tearing down (port of the collector.flush() +
        // flushStandardHR() calls in didDisconnectPeripheral). Runs on the IO scope.
        ioScope.launch { flushLive(); flushStandardHr() }

        // Reset all per-connection state and clear UI flags (incl. the syncing pill — a dropped link
        // mid-offload must not leave "Syncing strap history…" stuck on, #77). clearedBiometrics() also
        // blanks HR / R-R / the rolling buffer so a stale heart rate or R-R strip can't outlive the link
        // (parity with macOS LiveState.clearBiometrics — PR#191; the Android client previously cleared
        // `charging` but left heartRate/rr stale).
        // atomic update: LiveState is written from multiple threads (binder/main/IO).
        _state.update { it.clearedBiometrics().copy(
            connected = false, bonded = false, encryptedBond = false,
            backfilling = false, syncChunksThisSession = 0,
            charging = null,        // a stale charging flag must not outlive the link
            strapFirmware = null,   // nor stale firmware/layout versions
            historyLayoutVersion = null,
        ) }
        // Multi-WHOOP: the link is down — clear the published connected address so SourceCoordinator's
        // adoption sink can't re-fire on a stale strap id (twin of macOS clearing connectedPeripheralUUID).
        _connectedPeripheralAddress.value = null
        // #761: drop a stale probe result and abandon a walk the link interrupted, which also re-closes
        // the 117/118 send() allowlist (twin of the macOS disconnect cleanup).
        _featureFlagProbe.value = null
        featureFlagReport = null
        featureFlagAwaiting = null
        // #103: same for the device-config READ probe — dropping the report re-closes the 121/128
        // send() allowlist.
        _deviceConfigProbe.value = null
        // #174: a disable run interrupted mid-plan is RENDERED rather than dropped — unlike the read-only
        // probes it has already written to the strap, so the user must be told how far it got and which
        // keys are still set. This publishes the partial report and re-closes the 128 allowlist.
        abandonR22DisableRun("the strap disconnected mid-run")
        deviceConfigReport = null
        deviceConfigAwaiting = null
        reset()

        // close() can itself throw DeadObjectException on a dead binder — teardown must NEVER throw,
        // or the catch in safeGatt re-raises and we're back to the #314 crash. Swallow it.
        try { gatt?.close() } catch (t: Throwable) { log("gatt.close() threw ${t.javaClass.simpleName} during teardown (ignored)") }
        gatt = null
        gattOps = null
        cmdCharacteristic = null

        if (autoReconnectPausedForBondLoop) {
            // #747: the bond keeps being refused, so auto-reconnect is paused: we stop hammering a strap that
            // can't bond (the epitaph + paused hint were already surfaced when the give-up tripped). The user
            // re-arms it by tapping Connect (clearPairingHintForUserConnect). We do NOT schedule a reconnect.
            log("Disconnected (status=$status); auto-reconnect paused (strap keeps refusing to pair; tap Connect once it's free)")
            if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
                log("connect down (uptime ends)", com.noop.testcentre.TestDomain.CONNECTION)
                log("reconnect paused=bondLoop (strap refusing bond)", com.noop.testcentre.TestDomain.CONNECTION)
            }
        } else if (!intentionalDisconnect) {
            // Connection test mode: count + describe the reconnect churn, and mark the link down for the
            // uptime readout. Gated zero-cost (the CONNECTION bool is read before any string is built).
            // Diagnostic only - the reconnect logic below is unchanged. Twin of macOS, event-for-event:
            //  - a real drop AFTER a session (wasConnected) is the involuntary reconnect: increment the count
            //    THEN emit `connect down` + the plain `reconnect n=N` line (macOS didDisconnectPeripheral).
            //  - a FAILED connect (never reached STATE_CONNECTED) emits the `failedConnect` variant at the
            //    CURRENT count WITHOUT incrementing it (macOS didFailToConnect reports n but does not bump),
            //    so the reconnect-churn count means the same thing on both platforms.
            if (wasConnected) connReconnectCount += 1
            if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
                // #1020: `via=` names WHICH of our own paths dropped it — bondWatchdog, keepAliveStall,
                // userDisconnect, releaseStrap or gattThrow:<op>. Five paths produced one string before,
                // which made a thousands-of-reconnects report undiagnosable from the log alone.
                val reason = connectionDownReason(status, lastLocalTeardown)
                if (wasConnected) {
                    val heldMs = if (connectedAtMs > 0L) System.currentTimeMillis() - connectedAtMs else -1L
                    log("connect down (uptime ends${com.noop.analytics.ConnectionTrace.sessionHeldSuffix(heldMs)})",
                        com.noop.testcentre.TestDomain.CONNECTION)
                    log("reconnect n=$connReconnectCount reason=$reason", com.noop.testcentre.TestDomain.CONNECTION)
                } else {
                    log("reconnect n=$connReconnectCount failedConnect reason=$reason", com.noop.testcentre.TestDomain.CONNECTION)
                }
            }
            if (staleDirectBond) {
                staleDirectFailures++
                log("Disconnected (status=$status) before the bonded fast-path reached a session — stale OS bond (attempt $staleDirectFailures); falling back to a scan")
                lastDevice = null
                // Two consecutive wiped-bond failures = the strap really reset its pairing (firmware
                // update / official WHOOP app re-bond), not a one-off transient drop. Surface the same
                // forget+re-pair guide the Mac shows (v1.73). We KEEP scanning so a fresh re-pair is
                // picked up automatically and the guide clears on the next successful connect.
                if (staleDirectFailures >= 2) {
                    _state.update { it.copy(
                        reconnectGuide = """
                        Your strap's Bluetooth pairing was reset - usually by a WHOOP firmware update, or the official WHOOP app reconnecting. NOOP works fine on the new firmware; you just need to re-pair:

                        1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                        2. Open Settings → Bluetooth, find your WHOOP, and Forget / Unpair it.
                        3. Tap the band repeatedly until its LEDs flash blue (pairing mode).
                        4. Come back here and tap Connect.
                        """.trimIndent()
                    ) }
                }
                // #1030 (ryanbr): route through scheduleReconnect so this backoff timer is cancellable
                // and can't tear down a link that returns before it fires.
                scheduleReconnect(RECONNECT_DELAY_MS) { connect(selectedModel) }
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
                // Capped-exponential backoff (3,6,12,24,48,60s) so a strap that's genuinely out of
                // range stops hammering BLE — replaces the old fixed RECONNECT_DELAY_MS. The counter
                // resets on the next STATE_CONNECTED and on an explicit user Connect. (#48)
                val directDelay = nextReconnectDelayMs()
                // The first reconnect attempts use the fast direct connect (autoConnect=false), the same
                // path as the initial connect. A 5/MG the OS still holds bonded and ACL-connected never
                // re-emits the advertisement or connection-complete event that autoConnect=true waits for,
                // so the passive mode stalls. Fall back to autoConnect=true from the third attempt for a
                // strap that is genuinely out of range (#61: reconnect once it returns to range, with no
                // scan or advertisement needed).
                // #313: don't escalate to PASSIVE on attempt count alone. A band the OS still holds
                // ACL-connected (co-resident with the WHOOP app) stalls under autoConnect regardless of
                // count — keep it DIRECT; only a genuinely-out-of-range band escalates to PASSIVE for power.
                val aclHeld = isStrapAclHeld(dev.address)
                val passiveReconnect = passiveReconnectDecision(failedReconnectAttempts, aclHeld)
                log("Disconnected (status=$status); reconnecting ${if (passiveReconnect) "passively" else "directly"} in ${directDelay / 1000}s (attempt $failedReconnectAttempts$heldSuffix${if (aclHeld) ", ACL-held" else ""})")
                // #1030 (ryanbr): cancellable backoff timer (see scheduleReconnect).
                scheduleReconnect(directDelay) { connectToDevice(dev, autoConnect = passiveReconnect) }
            } else {
                val rescanDelay = nextReconnectDelayMs()
                log("Disconnected (status=$status); rescanning in ${rescanDelay / 1000}s (attempt $failedReconnectAttempts$heldSuffix)")
                // #1030 (ryanbr): cancellable backoff timer (see scheduleReconnect).
                scheduleReconnect(rescanDelay) { connect(selectedModel) }
            }
        } else {
            log("Disconnected (intentional)")
            // A user-initiated teardown ends the churn count for the run and marks the link down so the
            // uptime readout reads "not connected" rather than a stale uptime. Gated zero-cost. Twin of macOS.
            connReconnectCount = 0
            if (testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) {
                log("connect down (intentional)", com.noop.testcentre.TestDomain.CONNECTION)
            }
        }
    }

    /** Clear per-connection state. Port of the flag resets in didConnect / didDisconnectPeripheral. */
    private fun reset() {
        didBond = false
        connectHandshakeDone = false
        seq.set(0)
        writeQueue.clear()
        cccdQueue.clear()
        writeInFlight = false
        pendingRetry = null
        writeRetries = 0
        bondWriteOutstanding = false   // #791: a stale flag would suppress a legitimate cancel next session
        // Cancel any scheduled BUSY-retry kicks so a queued retry can't fire after teardown and
        // re-enter a dead write/descriptor (#314).
        handler.removeCallbacks(drainWriteRetryRunnable)
        handler.removeCallbacks(drainCccdRetryRunnable)
        resubscribedSinceData = false
        cccdInFlight = false
        cccdRetries = 0
        sessionStarted = false
        serviceDiscoveryRunnable?.let { handler.removeCallbacks(it) }
        serviceDiscoveryRunnable = null
        // Clear the onMtuChanged dedup (#50) so the first MTU callback of the NEXT connection — even to
        // the same strap with the same granted mtu — is never mistaken for a duplicate of the last one.
        lastMtuValue = -1
        lastMtuAtMs = 0L
        mtuRequestedAtMs = 0L   // #1066: don't measure settle time across a connection boundary
        // The strap forgets the realtime-HR toggle across a disconnect; the post-bond branch re-arms it
        // from [wantsRealtime]. Clear only the "what we last sent" flag — the screen/preference WANTS
        // ([screenWantsRealtime]/[keepStreamForData]/[wantsRealtime]) are intent and must survive a
        // reconnect so the stream comes back automatically.
        realtimeArmed = false

        // Reset offload state so the next connect starts a fresh session (port of the backfill
        // flag resets in didDisconnectPeripheral). Timers are handler-posted, so cancel them here.
        backfillStarted = false
        // #520: a re-connect must re-read the DIS identity (the strap may be a different one).
        disRead = false
        disSerial = null
        disHwRev = null
        // #1007: a burst cut short by a disconnect never reaches exitBackfilling — that path is only
        // HISTORY_COMPLETE / timeout / user-abort — so without this the throughput line simply would not
        // appear, and its ABSENCE is ambiguous: no offload at all, or one that was interrupted? For a
        // battery question those are opposite answers (the interrupted one spent radio for nothing).
        // Logged here rather than by calling exitBackfilling, which would also release the connection
        // priority and PHY and record a sync outcome — behaviour, on a path that does none of it today.
        if (backfilling && backfillStartedAtMs > 0L) {
            log("Backfill: ${offloadThroughputLine(offloadFramesThisSession,
                System.currentTimeMillis() - backfillStartedAtMs)} (interrupted)")
        }
        backfilling = false
        backfillDrain.reset()
        strapNewestTs = null
        offloadFramesThisSession = 0
        lastOffloadFrameAtMs = 0L   // #174: don't carry a stale cooldown reference into the next session
        historicalKickSent = false
        whoop5HistoryAttempts = 0
        // #580: a fresh connection earns a fresh empty-offload streak — a strap that was history-empty last
        // session might bank this time (or vice-versa). (The published flag is cleared in disconnectedLiveState.)
        whoop5EmptyOffload.reset()
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
        // The bonded-handshake watchdog (#50) is per-connection — cancel it so a pending bounce can't
        // fire after the link is already down (it would otherwise re-enter a dead/null gatt).
        cancelBondWatchdog()

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

    @Volatile private var eventLogDisabled = false

    /**
     * Durable append-only log of WHOOP 5.0/MG EVENT (type 48 / 0x30) frames, for deep-data protocol
     * research (#103). EVENT frames are the strap's rare, still mostly uncatalogued records — e.g.
     * the bi-hourly 56-byte record that tracks the nightly sleep-SpO2 measurement cycle. Decoding
     * them needs (raw bytes, ground-truth value) pairs collected across weeks, which the
     * session-scoped backfill capture cannot provide (its file churns under its own cap). This log
     * keeps ONLY the ~150 tiny EVENT frames a day in its own file so they survive long enough to
     * correlate. Gated on the same capture pref as the backfill capture; one JSONL line per frame
     * (`{"ts_ms":…,"char":…,"hex":"…"}`, same keys as the Swift twin `PuffinEventLog`); rotates at
     * the cap keeping one previous generation, the backfill capture's idiom.
     */
    private fun writeWhoop5EventLogIfEvent(characteristic: String, frame: ByteArray) {
        if (eventLogDisabled || !isWhoop5EventFrame(frame)) return
        if (!PuffinExperiment.from(context).isCaptureEnabled) return
        runCatching {
            val f = java.io.File(context.filesDir, WHOOP5_EVENT_LOG_FILE)
            if (f.exists() && f.length() > WHOOP5_EVENT_LOG_MAX_BYTES) {
                val old = java.io.File(context.filesDir, "$WHOOP5_EVENT_LOG_FILE.1")
                old.delete()
                f.renameTo(old)
            }
            val hex = frame.toHex()
            f.appendText("{\"ts_ms\":${System.currentTimeMillis()},\"char\":\"$characteristic\",\"hex\":\"$hex\"}\n")
        }.onFailure {
            // A diagnostics log must never affect the connection path: disable for this process.
            eventLogDisabled = true
            log("Capture: event log write failed (${it.message}) — event log disabled")
        }
    }

    @Volatile private var deepBufferDisabled = false

    /**
     * Durable append-only log of WHOOP 5.0/MG **high-rate R22 deep buffers** (#423) — the big type-0x2F
     * buffers (>= 1 KB: the 1244-B 6-axis IMU and 2140-B optical) that carry tens-of-Hz sensor data,
     * kept RAW in their own file so a byte-perfect decoder can be reversed offline from many
     * (raw buffer, wall-clock) pairs. NOOP's historical decoder pulls only the 1 Hz gravity vector out
     * of these and discards the high-rate remainder. Gated on the same capture pref as the backfill
     * capture; one JSONL line per buffer (`{"ts_ms":…,"strap_ts":…,"size":…,"offload":…,"char":…,
     * "hex":"…"[,"imu":{…}]}`, same keys as the Swift twin `PuffinDeepBufferLog`). `strap_ts` is the unix
     * second the strap stamped at frame offset 15 — the load-bearing key for aligning a buffer with what
     * the wearer was doing. The optional `imu` object is the decoded activity summary present only on the
     * 1244-B 6-axis buffer ([PuffinDeepBufferLog.decodedImuField], #455). Rotates at a soft cap keeping
     * one previous generation. Cheap for every other frame: a length + single-byte compare BEFORE the
     * pref read; no-op unless the capture toggle is on.
     */
    /** #423: persist the WHOOP 5/MG raw-IMU offload buffer NOOP already decodes for the deep-buffer log —
     *  the queryable twin of that (table-less) diagnostics line. Same `isCaptureEnabled` gate; only the
     *  1244-B 6-axis buffer decodes (rawColumns null otherwise). IO-dispatched so it never blocks the GATT
     *  thread; bounded by a rolling retention prune. Raw i16, no downstream consumer yet (instrument-first). */
    private fun storeWhoop5RawImuIfBuffer(frame: ByteArray) {
        if (!PuffinExperiment.from(context).isCaptureEnabled) return
        val cols = Whoop5RawImu.rawColumns(frame) ?: return
        val baseTs = PuffinDeepBufferLog.strapTs(frame)?.toLong() ?: return
        val dev = deviceId
        // #423 debug heartbeat: confirm the offload IMU is arriving + decoding on-device without pulling the
        // JSONL. Throttled (first buffer, then every 500) so a large offload can't flood the strap log; the
        // count is a per-connection running total. Off unless raw capture is enabled (gated above).
        rawImuDecodedCount++
        if (rawImuDecodedCount == 1 || rawImuDecodedCount % 500 == 0) {
            log("RAW IMU capture: $rawImuDecodedCount buffer(s) decoded, latest ts=$baseTs " +
                "(${cols.size / 6} samples/axis) — storing (retain ${WhoopRepository.RAW_IMU_RETENTION_ROWS})")
        }
        val row = RawImuSampleEntity(dev, baseTs, StreamPersistence.packImuColumns(cols))
        ioScope.launch {
            runCatching { repository.insertRawImu(dev, listOf(row)) }
                .onFailure { log("RAW IMU capture: store failed (${it.message})") }
        }
    }

    /** #423 debug: raw-IMU buffers decoded this connection (drives the throttled strap-log heartbeat). */
    private var rawImuDecodedCount = 0

    private fun writeWhoop5DeepBufferIfBig(characteristic: String, frame: ByteArray, isOffload: Boolean) {
        if (deepBufferDisabled || !PuffinDeepBufferLog.isDeepBuffer(frame)) return
        if (!PuffinExperiment.from(context).isCaptureEnabled) return
        runCatching {
            val f = java.io.File(context.filesDir, WHOOP5_DEEPBUFFER_FILE)
            if (f.exists() && f.length() > WHOOP5_DEEPBUFFER_MAX_BYTES) {
                val old = java.io.File(context.filesDir, "$WHOOP5_DEEPBUFFER_FILE.1")
                old.delete()
                f.renameTo(old)
            }
            val strapTs = PuffinDeepBufferLog.strapTs(frame)?.toString() ?: "null"
            val hex = frame.toHex()
            // #423/#455: decode the 1244-B IMU buffer inline so each captured line carries its activity
            // summary (cadence/energy/jerk/gyro) beside the raw hex — self-checking (raw ↔ decode) with
            // no stored table, migration, or downstream gate. Instrumentation only; the 2140-B optical
            // buffer stays raw (its layout isn't decoded yet).
            val imu = PuffinDeepBufferLog.decodedImuField(frame)
            f.appendText(
                "{\"ts_ms\":${System.currentTimeMillis()},\"strap_ts\":$strapTs,\"size\":${frame.size}," +
                    "\"offload\":$isOffload,\"char\":\"$characteristic\",\"hex\":\"$hex\"$imu}\n",
            )
        }.onFailure {
            // A diagnostics log must never affect the connection path: disable for this process.
            deepBufferDisabled = true
            log("Capture: deep-buffer log write failed (${it.message}) — deep-buffer log disabled")
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

    private fun log(s: String, domain: com.noop.testcentre.TestDomain? = null) {
        // A diagnostic log line must NEVER be able to crash the app. log() runs on the GATT binder
        // thread and from the background reconnect service, so an uncaught throw here takes the WHOLE
        // process down — which is exactly what happened in #453: a redaction-regex bug crashed the
        // app on every Bluetooth-on reconnect, even when it was closed. Belt-and-suspenders: nothing
        // in here may propagate. (The regex bug itself is also fixed; this guarantees the class can't
        // recur.)
        try {
            // Scrub personal identifiers FIRST so a user can safely share the strap log (#445), THEN
            // apply the optional Test Centre domain tag in front of the already-safe line.
            val safe = taggedStrapLogLine(redactPii(s), domain)
            // logcat is opt-in (Settings → Strap → "Debug logging"); default OFF so normal users don't
            // emit the strap log to the system log. The in-app ring buffer below always records.
            if (debugLogcat) Log.d(TAG, safe)
            // Mirror into the in-app ring buffer (format under the lock — SimpleDateFormat isn't
            // thread-safe and log() is called from both the GATT binder thread and the main looper).
            val stamped = synchronized(logBuffer) {
                val line = "${logTimeFmt.format(System.currentTimeMillis())}  $safe"
                logBuffer.addLast(line)
                while (logBuffer.size > LOG_BUFFER_MAX) logBuffer.removeFirst()
                line
            }
            // #1121: when detailed capture is on, ALSO append the (already PII-scrubbed) line to the
            // rolling on-device file, so a long-running issue is captured for hours rather than only the
            // ~5000-line (~50 min) in-memory ring. No-op + near-zero cost when capture is off, and inside
            // this same no-throw guard so a file error can never reach the connection path.
            appendCaptureLog(stamped)
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

    // ── #1121 Detailed capture: adb-like rolling strap-log file ────────────────────────────────────
    // Opt-in mirror of every log() line into a rolling on-device file (filesDir/[CAPTURE_LOG_FILE], capped
    // at [CAPTURE_LOG_MAX_BYTES] with one previous generation kept as ".1"), so a long-running diagnostic —
    // battery, an overnight offload — survives well past the ~50 min the in-memory ring holds AND survives
    // the process being killed (AppViewModel re-arms it from the persisted pref on launch). Lines are
    // ALREADY PII-scrubbed by log() before they reach here (they are the same `safe` text the ring stores),
    // so nothing extra is redacted on the way out. All file IO is under [captureLogLock]; a failure disables
    // capture for the process rather than ever propagating to the connection path.
    @Volatile private var captureLogWriter: java.io.BufferedWriter? = null
    @Volatile private var captureLogDisabled = false
    private var captureLogBytes = 0L
    private val captureLogLock = Any()

    /** Turn the rolling capture file on or off. Idempotent and safe to call from any thread. On enable it
     *  opens (rotating first if the existing file is already at the cap); on disable it flushes + closes. */
    fun setDetailedCapture(enabled: Boolean) {
        synchronized(captureLogLock) {
            if (enabled) {
                if (captureLogWriter != null || captureLogDisabled) return
                runCatching {
                    val f = java.io.File(context.filesDir, CAPTURE_LOG_FILE)
                    if (f.exists() && f.length() > CAPTURE_LOG_MAX_BYTES) rollCaptureFile(f)
                    captureLogBytes = if (f.exists()) f.length() else 0L
                    captureLogWriter = java.io.BufferedWriter(java.io.FileWriter(f, true))
                }.onFailure { captureLogDisabled = true }
            } else {
                runCatching { captureLogWriter?.flush(); captureLogWriter?.close() }
                captureLogWriter = null
            }
        }
        // Emit the marker OUTSIDE the lock — log() → appendCaptureLog re-enters [captureLogLock].
        when {
            captureLogWriter != null ->
                log("Detailed capture: rolling log ON (≤${CAPTURE_LOG_MAX_BYTES / (1024 * 1024)}MB ×2, filesDir/$CAPTURE_LOG_FILE)")
            !enabled -> log("Detailed capture: OFF")
        }
    }

    /** Append one already-scrubbed line to the rolling file, rotating at the cap. No-op when capture is
     *  off. Called ONLY from [log], inside its no-throw guard. Does NOT flush per line — that would be a
     *  syscall per line on the GATT binder thread during an offload burst; the BufferedWriter coalesces
     *  writes (and auto-flushes when its buffer fills), and [flushCaptureLog] on the ~30s keep-alive tick
     *  bounds how much of a sparse idle tail an abrupt kill could lose. Mirrors the 5/MG capture, which
     *  likewise flushes on a cadence rather than per line. */
    private fun appendCaptureLog(line: String) {
        if (captureLogWriter == null) return
        synchronized(captureLogLock) {
            val w = captureLogWriter ?: return
            runCatching {
                w.write(line); w.write("\n")
                captureLogBytes += line.length + 1
                if (captureLogBytes > CAPTURE_LOG_MAX_BYTES) {
                    w.flush(); w.close()
                    val f = java.io.File(context.filesDir, CAPTURE_LOG_FILE)
                    rollCaptureFile(f)
                    captureLogWriter = java.io.BufferedWriter(java.io.FileWriter(f, true))
                    captureLogBytes = 0L
                }
            }.onFailure {
                // A write/rotate failure (disk full, revoked FD) disables capture for the process rather
                // than failing every subsequent line — same self-quiescing contract as the 5/MG capture.
                captureLogDisabled = true
                runCatching { captureLogWriter?.close() }
                captureLogWriter = null
            }
        }
    }

    /** Push the buffered capture writer to the OS. Called on the ~30s keep-alive tick so a sparse idle tail
     *  (e.g. the 60s phone/strap battery lines) is durable within one tick of an abrupt kill, without
     *  paying a per-line flush during bursts. No-op + one volatile read when capture is off. */
    private fun flushCaptureLog() {
        if (captureLogWriter == null) return
        synchronized(captureLogLock) {
            runCatching { captureLogWriter?.flush() }.onFailure {
                captureLogDisabled = true
                runCatching { captureLogWriter?.close() }
                captureLogWriter = null
            }
        }
    }

    /** Rotate [f] → "f.1", dropping any prior generation. Caller holds [captureLogLock] and has already
     *  closed the writer (if any). */
    private fun rollCaptureFile(f: java.io.File) {
        val old = java.io.File(context.filesDir, "$CAPTURE_LOG_FILE.1")
        old.delete()
        f.renameTo(old)
    }

    /** #1121: a PHONE-battery snapshot line (`[phonebattery] level=NN% charging=y/n temp=..C t=..s`) for the
     *  strap log — the `[battery]` line is the STRAP's SoC; this is the phone's, so a capture can show the
     *  phone drain against the offload/connection activity on one timeline. One-shot read of the sticky
     *  ACTION_BATTERY_CHANGED intent (no receiver lifecycle). Null when unreadable. PII-free. */
    private fun phoneBatteryLine(): String? = runCatching {
        val i = context.registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
            ?: return null
        val level = i.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1)
        val pct = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val status = i.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1)
        val charging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            status == android.os.BatteryManager.BATTERY_STATUS_FULL
        val tenths = i.getIntExtra(android.os.BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        val tempStr = if (tenths != Int.MIN_VALUE) " temp=${tenths / 10.0}C" else ""
        "[phonebattery] level=$pct% charging=${if (charging) "yes" else "no"}$tempStr " +
            "t=${System.currentTimeMillis() / 1000L}s"
    }.getOrNull()

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
    fun externalLog(s: String, domain: com.noop.testcentre.TestDomain? = null) { log(s, domain) }

    /** Emit one Connection & Sync test-mode bond-state line, gated zero-cost behind testCentre.active(CONNECTION).
     *  The gate (one SharedPreferences bool) is read BEFORE the tagged string is built, so this is a no-op when
     *  the mode is off. Diagnostic only - it never changes the bond path. Twin of macOS emitConnectionBondState. */
    private fun emitConnectionBondState(detail: String) {
        if (!testCentre.active(com.noop.testcentre.TestDomain.CONNECTION)) return
        log("bondState $detail", com.noop.testcentre.TestDomain.CONNECTION)
    }

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

/**
 * Builds the 9-byte WHOOP 4.0 SET_ALARM_TIME (cmd 66) payload.
 * Layout: `[0x01] + u32 LE epoch + [0x00, 0x00]` subseconds + `[0x00, 0x00]` haptic-mode field.
 *
 * The earlier 7-byte form omitted the trailing two bytes; the strap ACKed it but never buzzed (#428).
 * @ujix's btsnoop capture of the official WHOOP app (#535) shows the official app always sends 9 bytes,
 * so we now match it. The buzz is confirmed on-device by the capture author (PR #535, 2026-06-20): a
 * real WHOOP 4.0 buzzes at the specified time with this 9-byte frame. That's one device/firmware, so
 * the Automations UI keeps a "keep a backup alarm" caveat for anything critical.
 * Pinned byte-for-byte by `Whoop4AlarmPayloadTest`.
 */
internal fun whoop4AlarmPayload(epochSec: Long): ByteArray {
    val e = epochSec.toInt()
    return byteArrayOf(
        0x01,
        (e and 0xFF).toByte(),
        ((e shr 8) and 0xFF).toByte(),
        ((e shr 16) and 0xFF).toByte(),
        ((e shr 24) and 0xFF).toByte(),
        0x00, 0x00, // subseconds (always 0 — minute-precision alarm)
        0x00, 0x00, // haptic-mode field required to actually buzz (official-app wire capture, #535)
    )
}

/**
 * The payload of a WHOOP 4.0 COMMAND_RESPONSE: the bytes after `[type,seq,cmd,origin_seq,result]`
 * (payload starts at absolute offset 9) up to the crc32 trailer at `length` (u16 LE at frame[1..2],
 * marking where the trailer starts - same envelope walk as the Swift `FrameRouter.advertisingName`).
 * null when the frame is too short to carry any payload. File-scope so it unit-tests without
 * constructing the Android-only BLE client (the [whoop4AlarmPayload] idiom).
 */
internal fun whoop4CommandResponsePayload(frame: ByteArray): ByteArray? {
    if (frame.size < 3) return null
    val length = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
    val start = 9   // SOF(1) + len(2) + crc8(1) + type,seq,cmd,origin_seq,result(5)
    if (length > frame.size || start >= length) return null
    return frame.copyOfRange(start, length)
}

/** Space-separated lowercase hex of a COMMAND_RESPONSE payload, for the raw-hex diagnostic fallback
 *  when a readback payload doesn't decode. null when the frame carries no payload. */
internal fun whoop4AlarmReadbackPayloadHex(frame: ByteArray): String? =
    whoop4CommandResponsePayload(frame)?.takeIf { it.isNotEmpty() }
        ?.joinToString(" ") { "%02x".format(it) }

/** Plausibility gate for a readback epoch: a real armed alarm is near-now, so anything outside
 *  2017..2100 (1_500_000_000 to 4_102_444_800, inclusive) is garbage or a strap with no alarm armed -
 *  the caller falls back to the raw-hex line rather than logging a misleading date. */
internal fun isPlausibleAlarmEpoch(epoch: Long): Boolean = epoch in 1_500_000_000L..4_102_444_800L

/**
 * Extract the armed-alarm epoch from a GET_ALARM_TIME (cmd 67) COMMAND_RESPONSE, defensively (#401
 * close-out). The WHOOP 4.0 response layout is UNDOCUMENTED, so this tries the two shapes the firmware
 * could plausibly answer with - the SET_ALARM_TIME mirror (`[form 0x01][u32 LE epoch]…`, matching the
 * 9-byte payload we arm with) first, then a bare leading u32 LE - and accepts a candidate only when it
 * passes [isPlausibleAlarmEpoch]. Anything else returns null and the caller logs raw hex instead.
 * Pinned by `AlarmReadbackDecodeTest`; twin of the Swift `FrameRouter.armedAlarmEpoch`.
 */
internal fun whoop4ArmedAlarmEpoch(frame: ByteArray): Long? {
    val payload = whoop4CommandResponsePayload(frame) ?: return null
    fun u32le(at: Int): Long? {
        if (payload.size < at + 4) return null
        return (payload[at].toLong() and 0xFFL) or
            ((payload[at + 1].toLong() and 0xFFL) shl 8) or
            ((payload[at + 2].toLong() and 0xFFL) shl 16) or
            ((payload[at + 3].toLong() and 0xFFL) shl 24)
    }
    if (payload.isNotEmpty() && payload[0] == 0x01.toByte()) {
        u32le(1)?.takeIf { isPlausibleAlarmEpoch(it) }?.let { return it }
    }
    return u32le(0)?.takeIf { isPlausibleAlarmEpoch(it) }
}

/**
 * True when a GET_ALARM_TIME readback explicitly reports NO alarm stored — the epoch field decodes to
 * 0 in the same shapes [whoop4ArmedAlarmEpoch] reads (SET-mirror `[0x01][u32=0]` first, then a bare
 * leading `u32=0`). This is the strap's "nothing armed" sentinel, distinct from a genuinely unparseable
 * payload: an arm the strap silently dropped reads back as epoch 0, so labelling it "unrecognised" hid
 * the real signal (#34). Only consulted AFTER [whoop4ArmedAlarmEpoch] returns null. Twin of the Swift
 * `FrameRouter.readbackReportsNoAlarm`; pinned by `AlarmReadbackDecodeTest`.
 */
internal fun whoop4ReadbackReportsNoAlarm(frame: ByteArray): Boolean {
    val payload = whoop4CommandResponsePayload(frame) ?: return false
    fun u32le(at: Int): Long? {
        if (payload.size < at + 4) return null
        return (payload[at].toLong() and 0xFFL) or
            ((payload[at + 1].toLong() and 0xFFL) shl 8) or
            ((payload[at + 2].toLong() and 0xFFL) shl 16) or
            ((payload[at + 3].toLong() and 0xFFL) shl 24)
    }
    if (payload.isNotEmpty() && payload[0] == 0x01.toByte()) {
        return u32le(1)?.let { it == 0L } ?: false
    }
    return u32le(0)?.let { it == 0L } ?: false
}

/** Local wall-clock render for the readback log line ("EEE HH:mm zzz", the armStrapAlarm idiom on the
 *  Swift side) so the armed + strap-reports lines read as one sequence. */
internal fun alarmReadbackLocalTime(epochSec: Long): String =
    java.text.SimpleDateFormat("EEE HH:mm zzz", java.util.Locale.US)
        .format(java.util.Date(epochSec * 1000L))

/** Mask MAC addresses and WHOOP serials in a strap-log line before it's shown/exported.
 *  TOTAL — never throws: a redaction failure returns a safe placeholder rather than leaking the raw
 *  line or crashing the caller (#453). The MAC regex captures exactly two groups (first + last octet),
 *  so the replacement references $1/$2 only. */
internal fun redactStrapLogPii(s: String): String = try {
    s.replace(PII_MAC_RE, "$1:••:••:••:••:$2")
        .replace(PII_WHOOP_SERIAL_RE, "WHOOP <serial>")
} catch (t: Throwable) {
    "[redaction error - line withheld]"
}

/** Prefix a compact, parseable domain marker onto an already-redacted strap-log line, or return it
 *  unchanged when no domain is given (today's behaviour, byte-identical). The export filters on this
 *  "[<id>] " marker. Pure and file-scope so it unit-tests without constructing the BLE client. */
internal fun taggedStrapLogLine(redacted: String, domain: com.noop.testcentre.TestDomain?): String =
    if (domain == null) redacted else "[${domain.id}] $redacted"

/**
 * #580: a connected WHOOP 5/MG whose firmware acks SEND_HISTORICAL_DATA but emits ZERO type-0x2F offload
 * frames. Live HR streams fine over the standard 0x2A37 profile, but the historical offload is empty, so
 * every session runs the 60s idle watchdog out to a "timeout" and surfaces the WHOOP-4 "strap went quiet"
 * sync error — even though nothing is wrong, the 5/MG history offload is simply experimental/unsupported
 * on that firmware. Worse, the empty offload leaves the link idle, so the 120s liveness watchdog can
 * bounce-disconnect/rescan every ~2 min in a thrash loop.
 *
 * This pure tracker counts CONSECUTIVE empty 5/MG offloads (a timeout with no offload frames and no rows
 * persisted). Once [quietThreshold] is reached it reports the strap as "history-empty" so the caller can
 * (a) surface an honest "history sync experimental on 5.0" state instead of a sync error, and (b) back off
 * the bounce loop. Any offload that DOES hand over real records clears the streak. Pure → JVM-unit-testable
 * without a BLE stack. Twin of macOS `Whoop5EmptyOffloadTracker`.
 */
internal class Whoop5EmptyOffloadTracker(
    /** Consecutive empty 5/MG offloads before we treat the strap as history-empty. 2 (not 1): the very
     *  first offload after connect can race the strap waking its flash, so one empty cycle is noise. */
    private val quietThreshold: Int = 2,
) {
    var consecutiveEmpty = 0
        private set

    /** True once [quietThreshold] consecutive empty offloads have been seen — the link is up + live HR is
     *  flowing but the 5/MG history offload is empty. Drives the honest flag AND the bounce backoff. */
    var historyEmpty = false
        private set

    /** Record a completed/timed-out 5/MG offload. [bankedRecords] = this offload routed real offload
     *  frames / persisted rows. Returns true if THIS call freshly crossed the threshold (log/surface once).
     *  A banking offload resets everything. */
    fun recordOffload(bankedRecords: Boolean): Boolean {
        if (bankedRecords) {
            consecutiveEmpty = 0
            historyEmpty = false
            return false
        }
        consecutiveEmpty++
        if (!historyEmpty && consecutiveEmpty >= quietThreshold) {
            historyEmpty = true
            return true
        }
        return false
    }

    /** Clear all suspicion — a fresh connect, or the user re-requested a sync. */
    fun reset() {
        consecutiveEmpty = 0
        historyEmpty = false
    }
}
