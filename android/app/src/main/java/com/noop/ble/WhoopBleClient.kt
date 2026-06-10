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
import com.noop.protocol.Reassembler
import com.noop.protocol.Streams
import com.noop.protocol.extractStreams
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.UserProfile
import com.noop.ingest.HealthConnectWriter
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
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
)

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
     * Stable device id; all rows are stamped with this. "my-whoop" matches the Swift default and
     * the rest of the Android app (AppViewModel reads "my-whoop").
     */
    private val deviceId: String = "my-whoop",
    /** Durable trim-cursor store for the offload safe-trim watermark (see [Backfiller]). */
    private val cursorStore: TrimCursorStore = PrefsTrimCursorStore(context),
    /**
     * Opt-in switch for the EXPERIMENTAL WHOOP 5.0/MG ("puffin") protocol probes (default OFF).
     * Read fresh from SharedPreferences each connect so a Settings toggle takes effect on the next
     * scan. Port of the macOS `PuffinExperiment` gate. NEVER consulted for WHOOP 4.0.
     */
    private val puffinExperiment: PuffinExperiment = PuffinExperiment.from(context),
) {

    companion object {
        private const val TAG = "WhoopBleClient"
        /** Cap on the in-app strap-log ring buffer (for the "Share strap log" diagnostics export). */
        private const val LOG_BUFFER_MAX = 2000

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

        // MARK: Live-persistence cadence (port of Swift CollectorPolicy.default).
        /** Flush the live buffer after this many frames OR [FLUSH_MAX_INTERVAL_MS], whichever first. */
        private const val FLUSH_MAX_FRAMES = 64
        private const val FLUSH_MAX_INTERVAL_MS = 30_000L

        // MARK: Historical-offload timers (ported from BLEManager.swift, same constants).
        /** Periodic re-offload of the type-47 store while connected+bonded. 900s = 15 min (matches WHOOP). */
        private const val BACKFILL_INTERVAL_MS = 900_000L
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
    }

    // MARK: Published state — the single source of truth the UI observes.
    private val _state = MutableStateFlow(LiveState())
    val state: StateFlow<LiveState> = _state.asStateFlow()

    // MARK: Android Bluetooth handles.
    private val bluetoothManager: BluetoothManager? =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
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

    // ====================================================================================
    // MARK: Persistence + historical offload (NEW — ports BLEManager.swift Collector/Backfiller)
    // ====================================================================================

    /**
     * Background scope for all DB writes (insert is a suspend Room call). SupervisorJob so one
     * failed insert never cancels the others; IO dispatcher keeps DB work off the main looper.
     * Cancelled in [shutdown].
     */
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The offload state machine. Ack callback writes HISTORICAL_DATA_RESULT (with response). */
    private val backfiller = Backfiller(
        repository = repository,
        deviceId = deviceId,
        cursorStore = cursorStore,
        ackTrim = { trim, endData -> ackHistoricalChunk(trim, endData) },
        onChunkCommitted = { batch -> onBackfillChunkCommitted(batch) },
        log = { s -> log(s) },
    )

    /**
     * Fresh history just landed durably (a backfill chunk committed + acked) — schedule one debounced
     * on-device scoring pass so recovery/strain/sleep appear right away instead of waiting for the
     * UI's 15-min analysis tick (which also doesn't run at all with the app UI closed and only the
     * foreground service alive). Mirrors the AppViewModel loop's profile + writeback behaviour. (#78 fork)
     */
    private fun onBackfillChunkCommitted(batch: StreamBatch) {
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
                )
                runCatching {
                    IntelligenceEngine.analyzeRecent(
                        repo = repository,
                        profile = profile,
                        importedDeviceId = deviceId,
                        maxHROverride = profileStore.hrMaxOverride.takeIf { it > 0 }?.toDouble(),
                    )
                }.onSuccess {
                    log("Backfill: post-sync scoring pass done")
                }.onFailure {
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
    /** Genuine offload frames seen this session — zero at timeout means the strap never answered
     *  the history request at all (5/MG retry trigger, #78 fork). Main-looper only. */
    private var offloadFramesThisSession = 0
    /** One-shot per session: SEND_HISTORICAL_DATA already fired (gate + fail-open can both call). */
    private var historicalKickSent = false
    /** 5/MG zero-frame retries used this CONNECTION (max 2 — then the 900s periodic timer owns it). */
    private var whoop5HistoryAttempts = 0
    /** One-shot debounce: a post-backfill scoring pass is already scheduled/running. */
    private val analyzeAfterBackfillScheduled = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Guards the once-per-connect initial offload kick (Swift `backfillStarted`). */
    private var backfillStarted = false

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
    /** True while the Live screen wants the realtime HR stream; the keep-alive re-arms it so it can't lapse. */
    @Volatile private var wantsRealtime = false
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

    /** Descriptor-write queue: enabling notifications is also a one-at-a-time GATT operation. */
    private val cccdQueue = ConcurrentLinkedQueue<BluetoothGattCharacteristic>()
    private var cccdInFlight = false
    /** Bounded retries for a transiently-BUSY CCCD write, so a single rejected subscribe doesn't
     *  permanently kill a stream (HR/battery/events). Reset per connection in [reset]. */
    private var cccdRetries = 0
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
        // Filter to the strap the user picked — a single service, so a WHOOP 4.0
        // scan never lingers on a WHOOP 5/MG wrist (or the reverse). The user
        // chooses the model before this runs.
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
        gatt?.disconnect()   // onConnectionStateChange(DISCONNECTED) does the teardown + close.
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
        _state.value = _state.value.copy(connected = false, bonded = false, encryptedBond = false)
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
                cmd != CommandNumber.SET_ALARM_TIME && cmd != CommandNumber.DISABLE_ALARM) {
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
        val batt = g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)
        if (batt != null && (batt.properties and BluetoothGattCharacteristic.PROPERTY_READ) != 0) {
            g.readCharacteristic(batt)
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
        send(CommandNumber.SET_CLOCK, setClockPayload())
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

    @SuppressLint("MissingPermission")
    private fun stopScan() {
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
            log("Discovered $name (rssi ${result.rssi}) — connecting")
            // Found it: cancel the not-found timeout and reflect progress in the UI.
            handler.removeCallbacks(scanTimeoutRunnable)
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
        adapter?.bondedDevices?.firstOrNull { d ->
            val n = try { d.name } catch (se: SecurityException) { null } ?: return@firstOrNull false
            n.startsWith("WHOOP", ignoreCase = true) && !n.startsWith("WHOOP 4", ignoreCase = true)
        }
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
        log("Discovering services ($reason)")
        g.discoverServices()
    }

    @SuppressLint("MissingPermission")
    private fun connectToDevice(device: BluetoothDevice, autoConnect: Boolean = false) {
        // Reset per-connection state (mirrors the Swift flags cleared on connect/disconnect).
        reset()
        // Remember the device so a later dropout can reconnect straight to it (#61).
        lastDevice = device
        // Close any prior/pending GATT so a direct-reconnect attempt doesn't leak the old client.
        gatt?.close()
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
                    _state.value = _state.value.copy(connected = true, scanning = false, statusNote = null, encryptedBond = false, reconnectGuide = null)
                    serviceDiscoveryKicked.set(false)
                    // Request the larger MTU BEFORE discovery/subscribe so the offload isn't capped at
                    // 20-byte notifications (the official app does this in its GATT init). Discovery is
                    // gated on the result with a fallback timeout, so a stack that ignores requestMtu
                    // can't stall the connect. (PR #85)
                    if (g.requestMtu(GATT_MTU)) {
                        log("Connected — requesting MTU $GATT_MTU before discovery")
                        handler.postDelayed({ kickServiceDiscovery(g, "mtu timeout") }, MTU_FALLBACK_MS)
                    } else {
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
                if (wantsRealtime) send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1))
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
                    handleFrame(frame)              // UI (always) — port of router.handle(frame:)

                    // Capture the strap's newest stored record from a GET_DATA_RANGE reply, feeding
                    // the liveness watchdog. The response command byte is family-dependent: @6 on
                    // WHOOP4, @10 on 5/MG (+4 puffin envelope) — reading 6 unconditionally meant
                    // strapNewestTs never updated from a 5/MG reply. dataRangeNewestUnix's scan-from-7
                    // stays: on 5/MG it lands word-aligned with the body at 11, and a straddling word
                    // can't fall in the unix-range window. (#78 fork)
                    val cmdOff = if (connectedFamily == DeviceFamily.WHOOP5) 10 else 6
                    if (frame.size > cmdOff && (frame[cmdOff].toInt() and 0xFF) == CommandNumber.GET_DATA_RANGE.rawValue) {
                        dataRangeNewestUnix(frame)?.let { strapNewestTs = it }
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
                }
            }
            else -> { /* ignore */ }
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
                intArrayValue(parsed.parsed["rr_intervals"])?.let { rr ->
                    if (rr.isNotEmpty()) _state.value = _state.value.copy(rr = rr)
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

        // R-R: the standard profile is the reliable source — surface whenever present.
        if (rr.isNotEmpty()) _state.value = _state.value.copy(rr = rr)
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
        send(CommandNumber.SET_CLOCK, setClockPayload())
        send(CommandNumber.GET_CLOCK, byteArrayOf())               // strap expects an EMPTY payload
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
        // completed) — otherwise the stream would only start at the next keep-alive tick (issue #18).
        if (wantsRealtime) send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1))
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
                gatt?.disconnect()               // → handleDisconnect → reset() (cancels this) → reconnect
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
                    if (wantsRealtime) send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1))
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
     * The Live screen wants realtime HR. Remember it ([wantsRealtime]) so the keep-alive keeps
     * re-arming the stream so it can't lapse, and kick it now. Port of `BLEManager.startRealtime`.
     */
    fun startRealtime() {
        wantsRealtime = true
        // Both families arm via TOGGLE_REALTIME_HR; send() frames it correctly per family (puffin for
        // 5/MG). The toggle only reaches a 5/MG strap once bonded — the post-bond branch arms it too.
        if (connectedFamily == DeviceFamily.WHOOP4 || _state.value.bonded) {
            send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(1))
        }
    }

    /** The Live screen no longer needs realtime HR; stop re-arming it. Port of `BLEManager.stopRealtime`. */
    fun stopRealtime() {
        wantsRealtime = false
        if (connectedFamily == DeviceFamily.WHOOP4 || _state.value.bonded) {
            send(CommandNumber.TOGGLE_REALTIME_HR, byteArrayOf(0))
        }
    }

    /**
     * SET_CLOCK(10) payload = the strap's 8-byte form: [seconds u32 LE][subseconds u32 LE].
     * Port of `BLEManager.setClockPayload`. A wrong-length SET_CLOCK is ack'd but NOT latched.
     */
    private fun setClockPayload(): ByteArray {
        val now = (System.currentTimeMillis() / 1000L)
        return byteArrayOf(
            (now and 0xFF).toByte(),
            ((now shr 8) and 0xFF).toByte(),
            ((now shr 16) and 0xFF).toByte(),
            ((now shr 24) and 0xFF).toByte(),
            0, 0, 0, 0,
        )
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
        val g = gatt ?: return
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

        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(ch, item.frame, writeType) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                ch.writeType = writeType
                ch.value = item.frame
                g.writeCharacteristic(ch)
            }
        }

        if (!ok) {
            // Transient BUSY — the stack hasn't freed the previous write yet (common on Android 13+/16,
            // worst when the slot was freed too eagerly). Re-hold THIS frame and retry shortly instead
            // of dropping it: a dropped TOGGLE_REALTIME_HR / SET_CLOCK / offload-ack silently breaks
            // live HR, the clock, or the backfill (issue #77 — a Pixel 7 on Android 16 saw exactly this).
            writeInFlight = false
            if (writeRetries < MAX_WRITE_RETRIES) {
                writeRetries++
                log("writeCharacteristic busy; retry $writeRetries/$MAX_WRITE_RETRIES")
                pendingRetry = item
                // Escalating backoff (12, 24, … capped ~96ms) — ride out a congestion spike instead of
                // exhausting the budget in a few tens of ms while the stack is still busy (#77).
                handler.postDelayed({ drainWriteQueue() }, WRITE_RETRY_DELAY_MS * minOf(writeRetries, 8))
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
        seq = (seq + 1) and 0xFF
        val bondFrame = Framing.buildCommand(CommandNumber.GET_BATTERY_LEVEL, byteArrayOf(0), seq)
        log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
        writeInFlight = true   // hold the slot until onCharacteristicWrite fires (with response).
        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(ch, bondFrame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                ch.value = bondFrame
                g.writeCharacteristic(ch)
            }
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
        // CONFIRMED (with-response) write — mirrors the macOS v1.5 fix and the hardware-verified finding
        // that the CLIENT_HELLO confirmed write triggers the strap's just-works bond. A 5/MG strap won't
        // stream HR (even over the standard 0x2A37 profile) on an UNauthenticated link, so the old
        // unacknowledged write left it bond-less and silent — CLIENT_HELLO written, then nothing (#17).
        // Hold the slot until the ACK; the opt-in puffin probe now fires post-bond (onCharacteristicWrite).
        log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (to trigger bonding, experimental).")
        writeInFlight = true
        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(ch, hello, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                ch.value = hello
                g.writeCharacteristic(ch)
            }
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
        cccdInFlight = true

        // Tell the local stack to surface notifications, then write the CCCD so the remote starts
        // sending them. CoreBluetooth's setNotifyValue(true) does both implicitly.
        g.setCharacteristicNotification(ch, true)
        val cccd = ch.getDescriptor(CCCD)
        if (cccd == null) {
            log("No CCCD on ${ch.uuid}; skipping")
            cccdInFlight = false
            drainCccdQueue(g)
            return
        }
        val enableValue = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, enableValue) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = enableValue
                g.writeDescriptor(cccd)
            }
        }
        if (!ok) {
            cccdInFlight = false
            if (cccdRetries < MAX_CCCD_RETRIES) {
                // Transient BUSY (the stack slot hasn't freed): re-queue this subscribe and retry
                // shortly. Order among the notify chars doesn't matter, so re-add at the tail.
                cccdRetries++
                log("writeDescriptor busy for ${ch.uuid}; retry $cccdRetries/$MAX_CCCD_RETRIES")
                cccdQueue.add(ch)
                handler.postDelayed({ drainCccdQueue(g) }, CCCD_RETRY_DELAY_MS)
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
        // Identity clock ref: REALTIME_DATA timestamps are device-epoch, but with device==wall the
        // offset is a no-op. The dense, authoritative metric stream is the type-47 historical store
        // (which carries real unix ts); this live path captures live REALTIME_DATA/EVENT/battery.
        val now = (System.currentTimeMillis() / 1000L).toInt()
        val parsed = frames.map { Framing.parseFrame(it, connectedFamily) }
        val streams: Streams = extractStreams(parsed, deviceClockRef = now, wallClockRef = now)
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
        offloadFramesThisSession = 0
        historicalKickSent = false
        _state.value = _state.value.copy(backfilling = true, syncChunksThisSession = 0)
        // Opt-in raw capture (research aid): pref read fresh per session, like the probes gate.
        if (connectedFamily == DeviceFamily.WHOOP5 && PuffinExperiment.from(context).isCaptureEnabled) {
            startWhoop5BackfillCapture()
        }
        if (connectedFamily == DeviceFamily.WHOOP5) {
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
        if (!_state.value.connected || !_state.value.bonded || backfilling) return
        beginBackfill()
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
            while (true) {
                val f = backfillFrameQueue.poll() ?: break
                backfiller.ingest(f)
                // If the Backfiller consumed all historical data, exit the session cleanly.
                if (backfilling && !backfiller.isBackfilling) {
                    handler.post { exitBackfilling("HISTORY_COMPLETE") }
                }
            }
            backfillDraining = false
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
        // Record an honest sync outcome so a cloud-free user can tell sync is working (or stuck):
        // HISTORY_COMPLETE stamps lastSyncAt + clears any error; an idle-watchdog timeout surfaces a
        // non-silent error. A plain disconnect mid-sync leaves both as-is (not a failure — the next
        // connect re-offloads). The freshly-published count is preserved as the progress read. (PR #85)
        val nowSec = System.currentTimeMillis() / 1000L
        _state.value = when (reason) {
            "HISTORY_COMPLETE" -> _state.value.copy(
                backfilling = false,
                syncChunksThisSession = ackedChunksThisSession,
                lastSyncAt = nowSec,
                lastSyncError = null,
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
        // mid-offload must not leave "Syncing strap history…" stuck on, #77).
        _state.value = _state.value.copy(
            connected = false, bonded = false, encryptedBond = false,
            backfilling = false, syncChunksThisSession = 0,
            charging = null,   // a stale charging flag must not outlive the link
        )
        reset()

        gatt?.close()
        gatt = null
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
            if (dev != null) {
                // Reconnect DIRECTLY to the strap we already know (autoConnect=true): the OS reconnects
                // as soon as it's reachable, with no scan and no advertisement required — fixing the
                // dropout loop where a bonded strap that wasn't advertising could never be re-found by
                // scanning, leaving the user stuck until they forced pairing mode (#61).
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
        resubscribedSinceData = false
        cccdInFlight = false
        cccdRetries = 0
        sessionStarted = false

        // Reset offload state so the next connect starts a fresh session (port of the backfill
        // flag resets in didDisconnectPeripheral). Timers are handler-posted, so cancel them here.
        backfillStarted = false
        backfilling = false
        backfillDraining = false
        backfillFrameQueue.clear()
        strapNewestTs = null
        offloadFramesThisSession = 0
        historicalKickSent = false
        whoop5HistoryAttempts = 0
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
        // logcat is opt-in (Settings → Strap → "Debug logging"); default OFF so normal users don't
        // emit the strap log to the system log. The in-app ring buffer below always records.
        if (debugLogcat) Log.d(TAG, s)
        // Mirror into the in-app ring buffer (format under the lock — SimpleDateFormat isn't
        // thread-safe and log() is called from both the GATT binder thread and the main looper).
        synchronized(logBuffer) {
            logBuffer.addLast("${logTimeFmt.format(System.currentTimeMillis())}  $s")
            while (logBuffer.size > LOG_BUFFER_MAX) logBuffer.removeFirst()
        }
    }

    /** Snapshot of the recent strap log, newest last, for the "Share strap log" diagnostics export. */
    fun exportLogText(): String = synchronized(logBuffer) { logBuffer.joinToString("\n") }
}
