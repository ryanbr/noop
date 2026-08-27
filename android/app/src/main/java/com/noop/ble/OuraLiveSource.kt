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
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import com.noop.data.OuraStreamMapping
import com.noop.data.StreamBatch
import com.noop.data.StreamPersistence
import com.noop.oura.OuraAuth
import com.noop.oura.OuraCommand
import com.noop.oura.OuraDriver
import com.noop.oura.OuraDriverPhase
import com.noop.oura.OuraEvent
import com.noop.oura.OuraFraming
import com.noop.oura.OuraIbiHr
import com.noop.oura.OuraGatt
import com.noop.oura.OuraCommands
import com.noop.oura.OuraDecoders
import com.noop.oura.OuraHistoryDrain
import com.noop.oura.OuraHypnogramAssembler
import com.noop.oura.OuraHypnogramBurst
import com.noop.oura.OuraOuterFrame
import com.noop.oura.OuraReassembler
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraSleepSession
import com.noop.oura.OuraSleepSessionMapping
import com.noop.oura.OuraTransition
import com.noop.oura.OuraWearState
import com.noop.oura.OuraWearTracker
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen3 / gen4 / gen5).
 *
 * Faithful Kotlin twin of Strand/BLE/OuraLiveSource.swift. This replaced an earlier honest dead-end
 * probe: where that probe only proved "there's no OPEN stream", this transport speaks the
 * ring's OWN documented protocol (clean-room, see docs/OURA_PROTOCOL.md) to authenticate with the
 * 16-byte application key, enable the daytime-HR feature, and decode the ring's RAW signals
 * (HR / IBI / RMSSD / SpO2 / skin-temp / sleep-phase tags). NOOP computes its OWN Charge/Rest from
 * those raw signals; the ring's encrypted readiness/sleep SCORES are never read or surfaced
 * (honest-data invariant).
 *
 * All BLE specifics live here; all protocol specifics live in the JVM-pure [OuraDriver] (which holds
 * NO BluetoothGatt). This class owns the transport and feeds the driver only bytes + transition events.
 *
 * WHOOP-FIRST ISOLATION (identical to [StandardHrSource] / [HuamiHrSource]): this class runs its OWN
 * scan + [BluetoothGatt] and never imports, calls, or shares state with the WHOOP BLE client. The
 * WHOOP path cannot regress because of anything here. The only shared surfaces are injected closures:
 *   - [liveSink]  pushes the ring's live HR (bpm) + R-R (ms) into whatever the UI observes (the
 *                 [SourceCoordinator] wires it to the same live state a WHOOP/strap reading uses).
 *   - [persist]   wired by the app to `repository.insert(StreamBatch, deviceId)` for the active ring.
 *   - [log]       the SAME exportable strap log (issue #421); every line is prefixed "Oura: ".
 *   - [onBattery] surfaces the ring's battery percent the same place a strap's does.
 *
 * HONEST FALLBACK (Huami precedent): when no install key is available ([authKey] returns null) or the
 * ring reports it is in factory reset, the ring needs a pairing/provisioning handshake the live flow
 * does not silently perform. This source then publishes an HONEST message via [needsPairing] and stays
 * disconnected from data - it NEVER fabricates a reading and never displays Oura's own scores.
 *
 * Android runtime-permission notes (same contract as the other sources): the caller must hold
 * BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect]. Every android.bluetooth call is
 * @SuppressLint("MissingPermission") - the caller owns the grant.
 */
@SuppressLint("MissingPermission")
class OuraLiveSource(
    context: Context,
    /** Datastore device id every sample is stamped with (the active ring's registry id). */
    private val deviceId: String,
    /** The ring generation (selected by the user in the wizard, recovered from the row model). Drives
     *  the MTU clamp, discovered-characteristic set, and the live-HR enable command set. */
    private val ringGen: OuraRingGen,
    /** Push live HR (bpm) + R-R (ms) into whatever the UI observes. Called on the main looper. Mirrors
     *  [StandardHrSource.liveSink] so the [SourceCoordinator] wires both the same way. */
    private val liveSink: (hr: Int, rr: List<Int>) -> Unit,
    /** Returns the 16-byte application auth key (unsigned bytes 0..255) for this ring, or null when none
     *  has been provisioned. INJECTED, never hardcoded (the key lives in [OuraInstallKeyStore], backed by
     *  the Android Keystore). null drives the honest [needsPairing] path - no faked data. */
    private val authKey: () -> IntArray?,
    /** Persist a batch under [deviceId] - wired to `repository.insert`. Mirrors the other sources. */
    private val persist: (StreamBatch, String) -> Unit = { _, _ -> },
    /** Upsert the ring-PROVIDED reconstructed hypnogram as a night under [deviceId] (the imported/measured
     *  side, NOT the "-noop" computed sibling) so `mergeSleepRichness`'s imported-over-computed rule makes
     *  Oura's SleepNet staging win over NOOP's sparse-motion computed night. Wired to
     *  `repository.upsertSleepSessions`; default no-op so the discovery-only scanner + tests stay inert. */
    private val persistSleepSession: (OuraSleepSession, String) -> Unit = { _, _ -> },
    /** #1284 residual 3 (default OFF): read live at persist — when true, an Oura hypnogram night is keyed on
     *  its rounded 0x49 onset (stable per-night anchor) instead of the end-anchored first-code time. */
    private val onsetKeying: () -> Boolean = { false },
    /** Diagnostic sink for the connect/auth/stream lifecycle - the SAME exportable strap log (#421).
     *  Every line is prefixed "Oura: ". Statuses / UUIDs / counts only, NEVER a device address. Default
     *  no-op keeps existing call sites compiling and tests silent. */
    private val log: (String) -> Unit = {},
    /** Fired with the ring's battery percent (0-100) when decoded. */
    private val onBattery: (Int) -> Unit = {},
    /** Fired with the ring's TRUE model label ("Oura Ring 3/4/5") once the GetProductInfo hardware id
     *  resolves a generation on connect, so the app can correct a registry row mis-stamped from the
     *  advertised name (#772). Default no-op. Twin of Swift's `onModel`. */
    private val onModel: (String) -> Unit = {},
    /** Fired with the ring's STABLE serial once the GetProductInfo serial page is read on connect, so the app
     *  can re-point this device onto its `oura-<serial>` id — the identity that survives a re-pair, unlike the
     *  transient address (#771). Default no-op. Only plausible serials are surfaced. Twin of Swift's `onSerial`. */
    private val onSerial: (String) -> Unit = {},
    /**
     * Source of cryptographically-random bytes for a freshly-generated install key (adopt flow step 1).
     * Injected so a test can pin a deterministic key; production defaults to [java.security.SecureRandom]
     * (the platform CSPRNG) so a forgotten injection is still secure, never a predictable key. Returns null
     * on RNG failure (then provisioning stays honest rather than installing a weak key).
     */
    private val randomKey: () -> IntArray? = { secureRandom16() },
) : LiveHrSource {

    /**
     * The live outcome of an in-flight adopt (the wizard observes this to leave its Adopting step). Kotlin
     * twin of Swift's `OuraLiveSource.AdoptPhase`. Reset to [Idle] on every connect/stop/disconnect so a
     * stale outcome never drives a transition.
     */
    enum class AdoptPhase {
        /** No adopt in flight (the default; a read-only connect never leaves this until streaming). */
        Idle,

        /** The dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running). */
        InstallingKey,

        /** Auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete. */
        Streaming,

        /** An honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success. */
        Failed,
    }

    /** An Oura ring seen during a scan (UI affordance). [detectedGen] is a best-effort generation guess
     *  from the advertised name (null when the name carries no generation marker); the wizard confirms it
     *  via the model the user picks. Mirrors the Swift DiscoveredRing.detectedGen. */
    data class DiscoveredRing(
        val address: String,
        val name: String,
        val rssi: Int,
        val detectedGen: OuraRingGen? = null,
    )

    private val _discovered = MutableStateFlow<List<DiscoveredRing>>(emptyList())
    /** Rings discovered during the current scan, keyed by address (newest RSSI wins). */
    val discovered: StateFlow<List<DiscoveredRing>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    /** True while a scan is running. */
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    /** The connected ring's battery percent, 0-100, once decoded; null until then or after disconnect
     *  (a stale value must not outlive the link). Surfaced on the device card like the WHOOP battery. */
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

    private val _needsPairing = MutableStateFlow<String?>(null)
    /** Set to an HONEST explanation when the ring needs a key install / pairing the live flow can't do
     *  (no app key, or the ring is in factory reset). null otherwise; cleared on scan/connect/stop. The
     *  source stays at "-" while this is set - never a fabricated value. */
    val needsPairing: StateFlow<String?> = _needsPairing.asStateFlow()

    private val _adoptPhase = MutableStateFlow(AdoptPhase.Idle)
    /** The live adopt outcome (see [AdoptPhase]). The wizard observes this to leave its Adopting step. Reset
     *  to [AdoptPhase.Idle] on every connect/stop/disconnect so a stale outcome never drives a transition. */
    val adoptPhase: StateFlow<AdoptPhase> = _adoptPhase.asStateFlow()

    // MARK: - Live wear/charge indicator (#628 twin) — On wrist / Off wrist / charging
    //
    // The ring emits no "worn" event, so wear is inferred: a LIVE-HR push (0x2F) means a finger; a silent
    // live stream past a grace window means it came off; the ring's "chg. detected"/"stopped" STATE strings
    // mean charging. All pure logic lives in [OuraWearTracker]; this source just feeds it the live signals.
    // Faithful twin of Strand/BLE/OuraLiveSource.swift's wear wiring.
    private val wearTracker = OuraWearTracker()
    /** The last published wear state, so each TRANSITION is logged once (steady state is not). */
    private var loggedWearState: OuraWearState? = null
    /** When the last LIVE-HR beat arrived (epoch ms). If the stream goes quiet for [wornPulseTimeoutMs]
     *  while we keep re-engaging it, the ring came off the finger -> NOT WORN. null until the first beat. */
    private var lastLivePulseAt: Long? = null
    /** Grace before a silent live-HR stream reads as "removed": the ring auto-reverts live HR ~20 s and we
     *  re-engage every [reengageIntervalMs] (15 s), so a worn ring resumes beats well within this window;
     *  exceeding it means no finger. Checked on the re-engage tick. Mirrors iOS `wornPulseTimeout` (40 s). */
    private val wornPulseTimeoutMs = 40_000L

    private val _ouraWearState = MutableStateFlow<OuraWearState?>(null)
    /** The ring's live wear/charge state (worn/charging/off), or null before any evidence this session and
     *  after disconnect (a stale badge must not outlive the link). Twin of iOS `LiveState.ouraWearState`. */
    val ouraWearState: StateFlow<OuraWearState?> = _ouraWearState.asStateFlow()

    // MARK: - Adopt consent (gates the DANGEROUS post-factory-reset key install, OURA_PROTOCOL.md s3.2)

    /**
     * EXPLICIT user-granted adopt consent for the NEXT connection. Default FALSE. The dangerous `0x24`
     * install opcode may be sent ONLY when this is true (it is wired straight to the per-connection driver's
     * `allowKeyInstall` gate). The Advanced-key path and every read-only connect leave it false, so they
     * NEVER provision a key (they stay honest via [announceNeedsPairing] when no valid key authenticates).
     */
    private var adoptIntent: Boolean = false

    /**
     * The freshly-generated install key, held in memory ONLY between writing the `0x24` install and the
     * `0x25` ack. It is persisted to the keystore ONLY once the ring acks OK (see [handleKeyInstallAck]), so
     * a failed/absent ack never leaves a wrongly-trusted key the next session would authenticate against.
     * The key is never logged. Mirrors Swift's `pendingInstallKey`.
     */
    private var pendingInstallKey: IntArray? = null

    /**
     * Grant (or revoke) adopt consent for the NEXT connection. The wizard's destructive adopt path calls
     * this with true AFTER its irreversible-consent gate AND its second "Take over" confirm, BEFORE
     * connecting, so the fresh per-connection driver is built with `allowKeyInstall == true` and the
     * dangerous install can run for exactly that session. It takes effect on the next connect (the driver
     * is re-created per connection); a connection already mid-flight is not retro-granted. Default-false
     * everywhere else keeps the dangerous opcode unreachable. On Swift, the architectural counterpart is
     * the immutable `OuraLiveSource.adoptIntent` initializer input; there is no setter twin.
     */
    fun setAdoptIntent(intent: Boolean) {
        adoptIntent = intent
    }

    // MARK: - Android Bluetooth handles (OWN scanner + GATT, separate from WHOOP)

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter

    /** Tier-B activity/MET research corpus writer (diagnostic JSONL sidecar; never scored, never a Streams
     *  row). Null when there is no device id. The Kotlin twin of the Swift `OuraActivityDump`. */
    private val activityDump: OuraActivityDump? =
        if (deviceId.isNotEmpty()) OuraActivityDump(appContext, deviceId, log) else null

    /** 0x47 motion calibration corpus (Tier-A), for offline LSB→g scale + cadence work (#804). Kotlin twin
     *  of the Swift `OuraMotionDump`. Null when there is no device id. */
    private val motionDump: OuraMotionDump? =
        if (deviceId.isNotEmpty()) OuraMotionDump(appContext, deviceId, log) else null

    /** 0x7E/0x7F real_steps research corpus (Tier-B), for offline investigation. Kotlin twin of the Swift
     *  `OuraRealStepsDump`. Null when there is no device id. */
    private val realStepsDump: OuraRealStepsDump? =
        if (deviceId.isNotEmpty()) OuraRealStepsDump(appContext, deviceId, log) else null
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    /** Peripherals seen in the current scan, retained by address so a chosen one survives to connect. */
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    /** A device asked to connect before a scan result for it landed (connect-by-address path). */
    private var pendingConnectAddress: String? = null

    /** The device of the in-flight connection, remembered so a status-133 disconnect can retry it. */
    private var lastDevice: BluetoothDevice? = null
    /** Guards the single status-133 (Android GATT_ERROR) auto-retry; reset on a successful connect. */
    private var retried133 = false
    /** Logs the FIRST live-HR sample of a connection only; reset on stop/disconnect. */
    private var loggedFirstHr = false
    /**
     * True once the driver first reached Streaming this connection, so the one-shot streaming work
     * (adoptPhase, re-engage timer, history-fetch kick-off, battery request) runs exactly once and is NOT
     * re-run when the driver returns to Streaming after each history-fetch pass completes. Reset on
     * stop/disconnect. Kotlin twin of Swift's `reachedStreaming`.
     */
    private var reachedStreaming = false
    /** Logs the FIRST skin-temp sample DECODED THIS SESSION only (never every record); reset on
     *  stop/disconnect. These are last-night values from the history fetch, not live pushes, but we still
     *  only want one log line, not one per sample. Twin of [loggedFirstHr]. */
    private var loggedFirstTemp = false
    /** Logs the FIRST SpO2 sample decoded this session only. Twin of [loggedFirstTemp]. */
    private var loggedFirstSpo2 = false
    /** Logs the FIRST ring-time -> UTC anchor of this session only (s5.5); reset on stop/disconnect. */
    private var loggedAnchor = false
    /** Tier-B (UNVERIFIED) kinds ("activity" / "real_steps" / "sleep_summary" / "spo2_smoothed") already
     *  logged this session, so a repeated tag logs once per KIND, not once per record. INVESTIGATION
     *  ONLY (see the `allowTierB = true` comment at driver construction) - the log is how we collect raw
     *  captures to validate these layouts; nothing here ever persists or scores. Reset on stop/disconnect. */
    private val loggedTierBKinds = mutableSetOf<String>()
    /** Feature ids whose status we have already logged this session (SpO2 0x04 / real_steps 0x0b), so the
     *  read-only feature-status diagnostic prints once per feature, not on every reconnect. */
    private val loggedFeatureStatuses = mutableSetOf<Int>()
    /** Product-info replies already logged this session, keyed by op+body so the #771/#772 serial/hardware
     *  capture prints each DISTINCT reply once — get_serial and get_hardware both answer under op 0x19, so a
     *  per-op guard would swallow the second (observed on-device: only the serial reached the log). Twin of
     *  Swift's `loggedProductInfo`. Cleared on reset. */
    private val loggedProductInfo = mutableSetOf<String>()

    // MARK: - Auto-reconnect (#912)

    /**
     * The paired ring's address we should keep re-reaching. Set by [connect]/[connectToDevice], cleared by
     * [stop]. While it is non-null an INVOLUNTARY drop (or a failed connect) re-issues a connect on a capped
     * backoff, so the ring comes back on its own once it's in range again, exactly like the WHOOP strap's
     * auto-reconnect. WHOOP has this loop; the non-WHOOP sources never did, so a dropped Oura ring stayed
     * down until a manual reconnect. This never touches the WHOOP path or its client.
     *
     * @Volatile: written from [connect]/[stop] (main) and read in [scheduleReconnect]'s posted block and
     * the GATT-delivery-thread disconnect handler, so it needs cross-thread visibility - matching the WHOOP
     * client's reconnect state.
     */
    @Volatile
    private var reconnectAddress: String? = null
    /**
     * True while a teardown was USER/COORDINATOR-initiated ([stop]), so the disconnect handler suppresses
     * the auto-reconnect (twin of the Swift `intentionalDisconnect` / the WHOOP client's flag). Cleared on
     * every [connect].
     *
     * @Volatile: read on the GATT-delivery thread (onConnectionStateChange) and written on main
     * ([connect]/[stop]/[announceNeedsPairing]), so it needs cross-thread visibility - same as the WHOOP client.
     */
    @Volatile
    private var intentionalDisconnect = false
    /**
     * Consecutive involuntary reconnect attempts, feeding the capped-exponential [ReconnectBackoff] (3, 6,
     * 12, 24, 48, 60s). Reset to 0 on a successful connect and on an explicit [connect] so a ring genuinely
     * out of range doesn't hammer BLE. Twin of the WHOOP client's `failedReconnectAttempts` (which is
     * `@Volatile` for exactly this reason: it's read/reset on the GATT-delivery thread and written on main).
     */
    @Volatile
    private var failedReconnectAttempts = 0

    /**
     * The pending auto-reconnect, held as a NAMED field (not an anonymous lambda) so [stop] can remove it
     * from the main-looper handler via [handler.removeCallbacks] - exactly like [reengageRunnable] /
     * [cancelReengage]. An anonymous `postDelayed` lambda would otherwise be retained by the handler for the
     * full backoff (up to 60s) after a teardown. It reads the CURRENT [reconnectAddress]: a [stop] nulls
     * that (and sets [intentionalDisconnect]) so a firing runnable bails, and a fresh [connect] repoints it.
     */
    private val reconnectRunnable = Runnable {
        val address = reconnectAddress
        if (!intentionalDisconnect && address != null) connect(address)
    }

    /**
     * The one-shot status-133 retry, held as a NAMED field (like [reconnectRunnable]) so [stop] can remove
     * it from the handler rather than letting an anonymous lambda linger for its 1s window after a teardown.
     * Reads the CURRENT [lastDevice] at fire time (the newest connect target is the right one to retry).
     */
    private val retry133Runnable = Runnable {
        val device = lastDevice
        if (!intentionalDisconnect && device != null) connectToDevice(device)
    }

    /**
     * Schedule an auto-reconnect to the paired ring after a backoff delay, unless the teardown was
     * intentional or there is no known ring. Guarded again inside [reconnectRunnable]: a [stop] that lands
     * in the meantime removes the callback AND nulls the target/sets the flag, so a deliberate teardown
     * never races a stale reconnect. Re-posts the SAME named runnable (removing any prior one first) so at
     * most one reconnect is ever pending.
     */
    private fun scheduleReconnect() {
        if (intentionalDisconnect) return
        if (reconnectAddress == null) return
        failedReconnectAttempts += 1
        val delay = ReconnectBackoff.nextDelayMs(failedReconnectAttempts)
        log("Oura: reconnecting in ${delay / 1000}s (attempt $failedReconnectAttempts)")
        handler.removeCallbacks(reconnectRunnable)
        handler.postDelayed(reconnectRunnable, delay)
    }

    /** All BLE work hops onto the main looper, matching the other sources + CBCentralManager(queue:.main). */
    private val handler = Handler(Looper.getMainLooper())

    // MARK: - Protocol state (the pure driver + reassembler own all protocol logic)

    /**
     * The transport-agnostic protocol state machine. Recreated on each connect with a fresh snapshot of
     * the app key so a key provisioned mid-session is picked up on the next connect, and so a Stopped
     * driver never lingers. JVM-pure: holds NO BluetoothGatt.
     */
    private var driver: OuraDriver? = null

    /** Reassembles BLE notification fragments into complete TLV records (s2.4). Reset on disconnect so a
     *  half-record never bleeds into the next session. */
    private val reassembler = OuraReassembler()

    /** Cached characteristics, resolved in onServicesDiscovered. */
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null

    /** Periodic live-HR re-engage: daytime HR auto-reverts after ~20 s, so while streaming we re-send the
     *  enable+subscribe every ~15 s (OURA_PROTOCOL.md s5.7). The token lets stop() cancel it. */
    private var reengageScheduled = false
    private val reengageIntervalMs = 15_000L
    private val reengageRunnable = object : Runnable {
        override fun run() {
            val d = driver ?: return
            if (d.phase == OuraDriverPhase.Streaming) {
                for (cmd in d.reengageLiveHRCommands()) write(cmd)
            }
            // Removal watchdog (#628): if the live-HR stream has gone silent past the grace window while we
            // keep re-engaging it, the ring came off the finger (there is no "removed" event). Downgrades
            // WORN -> OFF; the tracker never overrides CHARGING. Mirrors the iOS re-engage-tick watchdog.
            lastLivePulseAt?.let { last ->
                if (System.currentTimeMillis() - last > wornPulseTimeoutMs) {
                    wearTracker.noteLivePulseTimeout()
                    publishWearState()
                }
            }
            // Reschedule only while a session is live; stop() clears reengageScheduled + removes callbacks.
            if (reengageScheduled) handler.postDelayed(this, reengageIntervalMs)
        }
    }

    // MARK: - History fetch (GetEvents, s5) - the ONLY path skin temp / SpO2 / HRV / sleep-phase ever
    // arrive by. Neither temp nor SpO2 is ever pushed live on this hardware; both are banked overnight and
    // retrievable only by asking the ring for its history. Kotlin twin of the Swift lane9 history wiring.

    /**
     * The GetEvents cursor to resume from, loaded from [OuraHistoryCursorStore] on connect and advanced as
     * `0x11` summaries arrive. 0 = fetch everything the ring has banked (first-ever connect for this ring;
     * OURA_PROTOCOL.md s5.1). Held as a Long (the unsigned 32-bit ring timestamp).
     */
    private var historyCursor: Long = 0

    /**
     * Periodic re-fetch while connected, so an overnight-connected session (or one left open after a nap)
     * picks up freshly-banked sleep data without needing a reconnect. Mirrors the WHOOP ~15 min periodic
     * history-offload floor. Held as a NAMED runnable so [stop]/disconnect can remove it from the handler,
     * matching [reengageRunnable] / [reconnectRunnable].
     */
    private var historyFetchScheduled = false
    private val historyFetchIntervalMs = 900_000L
    private val historyFetchRunnable = object : Runnable {
        override fun run() {
            fetchHistoryIfIdle()
            // Reschedule only while a session is live; stop()/disconnect clears the flag + removes callbacks.
            if (historyFetchScheduled) handler.postDelayed(this, historyFetchIntervalMs)
        }
    }

    /**
     * History-fetched events decoded BEFORE a ring-time -> UTC anchor exists this session, held here (with
     * their own ring timestamp) until the anchor lands ([drainPendingAnchorEvents]), so they get their real
     * historical time instead of a premature wall-clock guess. The ring's 0x42 time-sync can arrive
     * anywhere in a history-fetch stream, not necessarily first, so records that land before it are parked
     * here and re-stamped the moment an anchor lands. Drained with an honest wall-clock fallback at teardown
     * if no anchor ever arrived this session (never silently dropped). Reset on stop/disconnect. Kotlin twin
     * of Swift's `pendingAnchorEvents`.
     */
    private val pendingAnchorEvents = ArrayList<Pair<OuraEvent, Long>>()

    /**
     * Pure decision core for the drain guards + resume cursor (#91). Twin of the Swift `drain` field;
     * see [OuraHistoryDrain] for the two-cursor model (seen = in-session continuation, stored = durable).
     */
    private val drain = OuraHistoryDrain()

    /** Where this fetch sought from (reboot detection floor); armed per drain. */
    private var resumeCursorAtFetchStart = 0L

    /** Wall-clock start of the current drain; feeds the deadline guard. */
    private var drainStartedAtMs: Long? = null

    /**
     * The cursor the LAST GetEvents request was issued at — the `start` of open_oura's progress test
     * (`next > start`). Continuation requests must advance past it or the drain stops.
     */
    private var lastRequestCursor = 0L

    /**
     * True between a `0x11` summary that wants more data and the batch-quiet continuation request. The
     * ring emits the summary EARLY (observed before its batch finished streaming), so the next request
     * waits for the stream to go quiet — open_oura's `transact()` collects until a 1.5 s silence for
     * the same reason. Re-requesting mid-stream at a stale cursor restarts the ring's serve.
     */
    private var pendingContinuation = false
    private val batchQuietMs = 1_500L
    private val batchQuietRunnable = Runnable { continueDrainAfterQuiet() }

    /**
     * Self-chained drain passes: a drain that ends with KNOWN remaining work (ring reboot → full pull
     * pending, or a deadline stop with banked progress) schedules its own next pass instead of waiting
     * for a reconnect / the 15 min periodic fetch. Capped per session; a stall/no-progress stop never
     * chains (that is the ring looping). Twin of Swift's chainedDrainPasses.
     */
    private var chainedDrainPasses = 0
    private val chainedDrainRunnable = Runnable { fetchHistoryIfIdle() }

    /**
     * TIME-AXIS RECONSTRUCTION (twin of Swift): the ring's SleepNet writes a night's whole hypnogram in
     * one burst AFTER wake, every record stamped with the WRITE moment — codes are accumulated here and
     * laid out backward (30 s/code from the anchored burst end) when the burst closes, instead of being
     * persisted at the (meaningless for sleep) envelope time.
     */
    private val hypnogramAssembler = OuraHypnogramAssembler()

    /** Bursts held while unanchored (park-until-anchor; dropped honestly at teardown — they re-arrive). */
    private val pendingUnanchoredBursts = ArrayList<OuraHypnogramBurst>()

    /**
     * The recent 0x49 sleep_summary_1 windows (rt, start/end offsets in MINUTES BEFORE the event time,
     * ringverse-validated): each pairs with the hypnogram burst of the SAME finalization so its end
     * anchors at the TRUE sleep end (`event − end_offset`) instead of the write moment (observed trailing
     * the real sleep end by 10–43 min). A COLLECTION, not a single slot: a drain can carry an overnight
     * AND a daytime nap, and keeping only the latest let the nap's 0x49 clobber the overnight's before
     * its burst finalized (overnight then fell back to its +4 h write time, 2026-07-17 capture). Each
     * burst matches its OWN by ring-time proximity. Bounded (oldest dropped past the cap). Twin of Swift's
     * recentSleepWindows049.
     */
    private val recentSleepWindows049 = ArrayList<Triple<Long, Int, Int>>()

    /**
     * #1284 residual 3 (duplicate-generation diagnostic): the [start, end] window of each sleep session
     * banked THIS connection. The session PK is (deviceId, startTs) and the burst end moves with the 0x49
     * drain, so an early partial drain can bank a short session that a later full burst then nests inside,
     * minting a second row that the #899 heal only cleans up afterwards. Comparing each new persist against
     * this list surfaces the GENERATION in the strap log (the heal side is #899's own line). Diagnostic only,
     * nothing is skipped. Bounded; cleared on disconnect with the 0x49 windows. Twin of Swift's.
     */
    private val recentPersistedSessionWindows = ArrayList<Pair<Long, Long>>()

    /** 0x71 fixture capture (#287): per-session count + observed payload lengths; log cap vs flooding. */
    private var greenIbiAmpCount = 0
    private val greenIbiAmpLengths = sortedSetOf<Int>()

    /**
     * Kick a history-fetch pass at the current cursor, but ONLY when the driver is idle-streaming (never
     * overlaps a fetch already in flight - the driver's own phase is the guard, so this is safe to call
     * both right after reaching Streaming and from the periodic timer). Kotlin twin of Swift's
     * `fetchHistoryIfIdle`.
     */
    private fun fetchHistoryIfIdle(): Unit = guardedCallback("history-fetch") {
        val d = driver ?: return@guardedCallback
        if (d.phase != OuraDriverPhase.Streaming) return@guardedCallback
        // Arm the per-drain state: where we sought from (reboot detection), the seen/stored high-water
        // marks, and the stall/deadline guards.
        resumeCursorAtFetchStart = historyCursor
        drainStartedAtMs = System.currentTimeMillis()
        drain.reset()
        lastRequestCursor = historyCursor
        pendingContinuation = false
        handler.removeCallbacks(batchQuietRunnable)
        log("Oura: fetching history from cursor $historyCursor [cursor-fix]")
        advance(OuraTransition.StartHistoryFetch(cursor = historyCursor))
    }

    private fun scheduleHistoryFetch() {
        if (historyFetchScheduled) return
        historyFetchScheduled = true
        handler.postDelayed(historyFetchRunnable, historyFetchIntervalMs)
    }

    private fun cancelHistoryFetch() {
        historyFetchScheduled = false
        handler.removeCallbacks(historyFetchRunnable)
    }

    /**
     * Handle a `0x11` GetEvents summary (open_oura `EventBatchSummary`): the drain continues while
     * `bytes_left > 0` and is complete at `bytes_left == 0`. The response's byte-count is NEVER
     * persisted — persisting it and comparing byte-counts across sessions as clocks was the #91
     * re-dump loop. The durable resume point is the newest STORED sample's ring-time, committed at
     * drain end. Kotlin twin of Swift's `handleHistorySummary` (2bbdaa42).
     */
    private fun handleHistorySummary(summary: com.noop.oura.GetEventsSummary): Unit = guardedCallback("history-summary") {
        val elapsed = drainStartedAtMs?.let { (System.currentTimeMillis() - it) / 1000.0 } ?: 0.0
        val continueDrain = drain.onSummary(summary.bytesLeft, summary.moreData, elapsed)
        if (summary.moreData && !continueDrain) {
            val reason = if (elapsed > OuraHistoryDrain.MAX_DRAIN_SECONDS) {
                "exceeded ${OuraHistoryDrain.MAX_DRAIN_SECONDS.toInt()}s deadline"
            } else {
                "bytes_left stalled"
            }
            log("Oura: history drain force-stopped - $reason at bytes_left ${summary.bytesLeft} (guard)")
        }
        if (!continueDrain) {
            // A deadline stop with more data behind it is resumable backlog (progress banked); a STALL
            // stop is the ring looping and must not chain.
            val deadlineBacklog = summary.moreData && elapsed > OuraHistoryDrain.MAX_DRAIN_SECONDS
            finishDrain(completed = !summary.moreData, resumeBacklog = deadlineBacklog)
            return@guardedCallback
        }
        // More data behind this batch. Do NOT re-request yet: the ring emits the 0x11 summary EARLY
        // (observed arriving before its batch finished streaming), and a mid-stream request at a stale
        // cursor restarts the serve from that cursor (the 5x same-window re-serve, 2026-07-12). Wait
        // for the batch to go quiet, then continue from max-seen-ring-time + 1 (open_oura drain_events).
        pendingContinuation = true
        handler.removeCallbacks(batchQuietRunnable)
        handler.postDelayed(batchQuietRunnable, batchQuietMs)
    }

    /**
     * The batch went quiet after a more-data summary: issue the next GetEvents at the ADVANCED cursor,
     * or end the drain when the batch made no progress (open_oura `!progressed → break` — re-sending a
     * non-advancing cursor is exactly what loops the ring).
     */
    private fun continueDrainAfterQuiet(): Unit = guardedCallback("batch-quiet") {
        if (!pendingContinuation) return@guardedCallback
        pendingContinuation = false
        val d = driver ?: return@guardedCallback
        if (d.phase != OuraDriverPhase.FetchingHistory) return@guardedCallback
        val next = drain.continuationCursor(lastRequestCursor)
        if (next != null) {
            lastRequestCursor = next
            log("Oura: history batch done - continuing from cursor $next")
            advance(OuraTransition.HistoryCursorAdvanced(cursor = next, moreData = true))
        } else {
            log("Oura: history batch made no cursor progress - stopping drain (ring would re-serve)")
            finishDrain(completed = false, resumeBacklog = false)
        }
    }

    /**
     * Common drain-end path: close the in-progress hypnogram burst BEFORE committing the cursor (so
     * its banked ring-time can advance the resume point in the same drain), commit, and return the
     * driver to Streaming. When the drain ends with KNOWN remaining work — a detected ring reboot
     * (cursor honestly reset to 0; full pull pending) or a deadline stop with backlog — the next pass
     * self-schedules 5 s later, so catching up never needs a manual reconnect.
     */
    private fun finishDrain(completed: Boolean, resumeBacklog: Boolean) {
        pendingContinuation = false
        handler.removeCallbacks(batchQuietRunnable)
        hypnogramAssembler.flush()?.let { persistHypnogramBurst(it) }
        val rebootFullPullPending = drain.sawPreResumeData
        commitResumeCursor(completed)
        advance(OuraTransition.HistoryCursorAdvanced(cursor = historyCursor, moreData = false))
        if (rebootFullPullPending || resumeBacklog) {
            if (chainedDrainPasses >= MAX_CHAINED_DRAIN_PASSES) {
                log("Oura: drain pass cap ($MAX_CHAINED_DRAIN_PASSES) reached with work remaining - " +
                    "next periodic fetch / reconnect continues from the banked cursor")
                return
            }
            chainedDrainPasses += 1
            val why = if (rebootFullPullPending) {
                "ring reboot detected - starting the honest full re-pull"
            } else {
                "backlog remains after the deadline guard"
            }
            log("Oura: $why; next drain pass in 5 s ($chainedDrainPasses/$MAX_CHAINED_DRAIN_PASSES)")
            handler.postDelayed(chainedDrainRunnable, 5_000L)
        } else if (completed) {
            chainedDrainPasses = 0   // healthy full completion re-arms the cap for future backlogs
        }
    }

    /**
     * Commit the durable resume cursor at drain end. Only a cursor that (a) moved forward, (b) is
     * below the plausibility ceiling, and (c) resolves to a real time under the CURRENT anchor is
     * persisted; a reboot (`sawPreResumeData`) resets to 0 so next connect does an honest full pull.
     */
    private fun commitResumeCursor(drainCompleted: Boolean) {
        val how = if (drainCompleted) "caught up (bytes_left 0)" else "stopped early"
        val resolves = drain.maxStoredRingTime > 0 &&
            driver?.unixSeconds(forRingTimestamp = drain.maxStoredRingTime) != null
        val newCursor = drain.resumeCursorAtDrainEnd(historyCursor, resolves)
        if (drain.sawPreResumeData) {
            log("Oura: history $how but the ring served data older than cursor $resumeCursorAtFetchStart" +
                " - clock reset/seek ignored; next connect does a full pull")
            historyCursor = 0
            OuraHistoryCursorStore.save(appContext, deviceId, 0)
        } else if (newCursor != historyCursor) {
            historyCursor = newCursor
            OuraHistoryCursorStore.save(appContext, deviceId, newCursor)
            log("Oura: history $how - resume cursor advanced to $historyCursor")
        } else if (drain.maxStoredRingTime > historyCursor) {
            log("Oura: history $how but resume candidate ${drain.maxStoredRingTime} does not resolve " +
                "under the current anchor - keeping cursor $historyCursor")
        } else {
            log("Oura: history $how (resume cursor unchanged $historyCursor)")
        }
    }

    /**
     * Persist a closed hypnogram burst with its RECONSTRUCTED time axis: codes laid backward at the
     * 30 s SleepNet epoch from the anchored burst END — the matching 0x49 window's TRUE sleep end
     * (`event − end_offset`) when one arrived in the same finalization burst, else the write-moment
     * envelope. HOLD-UNTIL-ANCHOR: an unanchored burst is parked (re-tried when the anchor lands) or
     * dropped honestly at teardown — safe, the cursor only advances on an anchored persist, so the
     * ring re-serves the same records next drain. Kotlin twin of Swift's persistHypnogramBurst.
     */
    private fun persistHypnogramBurst(burst: OuraHypnogramBurst) {
        val d = driver ?: return
        if (burst.totalCodes <= 0) return
        val writeEnd = d.unixSeconds(forRingTimestamp = burst.lastRingTimestamp)
        if (writeEnd == null) {
            pendingUnanchoredBursts.add(burst)
            log("Oura: hypnogram burst (${burst.totalCodes} codes) held - no anchor yet; reconstructs when the anchor lands")
            return
        }
        if (burst.hasNonMonotonicRingTimes) {
            log("Oura: hypnogram burst has NON-MONOTONIC envelope ring-times (${burst.records.size} records)" +
                " - sequence order taken from arrival order")
        }
        var end = writeEnd
        var sleepStart: Long? = null   // the 0x49 onset; clips leading pre-window codes (symmetric with `end`)
        // Same-finalization match: the 0x49 and the phase records carry near-identical envelope ring-times
        // (observed seconds apart); 6000 ticks = 10 min never pairs a different night. Pick the CLOSEST
        // window, not merely the newest — a drain can hold an overnight AND a nap, and the newer (nap)
        // window would otherwise mis-anchor the overnight burst.
        val w = closestSleepWindow049(recentSleepWindows049, burst.lastRingTimestamp, 6_000L)
        if (w != null) {
            val eventUtc = d.unixSeconds(forRingTimestamp = w.first)
            if (eventUtc != null) {
                val sleepEnd = eventUtc - w.third * 60L
                // Sanity: the true end precedes the write and by a plausible margin (< 6 h).
                if (sleepEnd <= writeEnd && writeEnd - sleepEnd < 6 * 3600L) {
                    end = sleepEnd
                    log("Oura: hypnogram burst end refined by 0x49 - SleepNet write $writeEnd -> " +
                        "true sleep end $sleepEnd (event-${w.third} min)")
                }
                // The 0x49 window ALSO carries the ONSET (startOffMin = w.second). The SleepNet burst runs
                // a few epochs before that onset (~7 min / 14 codes observed), so the reconstruction start
                // would otherwise precede the ring's OWN sleep window. Clamp symmetrically with the end.
                val onset = eventUtc - w.second * 60L
                if (onset < end && end - onset < 16 * 3600L) sleepStart = onset
            }
        }
        // Reconstruct the time axis; `sleepStart` (the 0x49 onset, or null) clips leading pre-window codes
        // in the PURE assembler (never emptying the night). Testable there; the app just logs the trim.
        val laid = burst.codesWithTimes(endUnixSeconds = end, sleepStartUnixSeconds = sleepStart)
        // #1246: an all-unwritten burst (every hypnogram page erased) reconstructs to nothing. Note the
        // resume cursor so the ring stops re-serving it, but persist no blank/awake session.
        if (laid.isEmpty()) {
            log("Oura: hypnogram burst entirely unwritten (0xFF) - ${burst.totalCodes} code(s), no stageable sleep; skipped")
            drain.noteStoredRingTime(burst.lastRingTimestamp, resumeCursorAtFetchStart)
            return
        }
        if (laid.size < burst.totalCodes) {
            // Fewer laid than decoded = unwritten (#1246, 0xFF pages) and/or pre-0x49-onset epochs trimmed.
            log("Oura: hypnogram trimmed ${burst.totalCodes - laid.size} code(s) - unwritten (0xFF) and/or pre-onset")
        }
        for (code in laid) enqueue(listOf(OuraEvent.SleepPhaseEvent(code.phase)), code.ts.toInt())
        drain.noteStoredRingTime(burst.lastRingTimestamp, resumeCursorAtFetchStart)
        val mins = DoubleArray(4)
        for (code in laid) mins[code.phase.stage.raw] += 0.5   // 30 s/code = 0.5 min
        log("Oura: hypnogram reconstructed [${laid.first().ts} -> $end, anchored] codes=${burst.totalCodes}" +
            " deep/light/rem/awake=${mins[0].toInt()}/${mins[1].toInt()}/${mins[2].toInt()}/${mins[3].toInt()} min")
        // Bank the SAME anchored codes as a ring-PROVIDED night (a SleepSession with the [{start,end,stage}]
        // breakdown) under the ring's own deviceId, so mergeSleepRichness surfaces Oura's SleepNet staging
        // over NOOP's computed night (#325 persist). Uses the anchored+0x49-refined `end` via `laid`. The
        // confirmation line makes the persist self-evident in the strap log for on-device validation.
        OuraSleepSessionMapping.session(laid.map { m -> m.ts to m.phase.stage })?.let { mapped ->
            // #1284 residual 3: when onset keying is on and a 0x49 onset was applied, key the session's
            // startTs on the ROUNDED onset (stable across the ring's re-serves) rather than the end-anchored
            // first-code time — so re-serves of one night share a PK and the bedtime is the true onset. The
            // completeness guard in the persist closure then suppresses/replaces any duplicate.
            val onset = sleepStart
            val session = if (onsetKeying() && onset != null) {
                mapped.copy(startTs = com.noop.analytics.SleepSessionDedup.keyedStart(onset))
            } else {
                mapped
            }
            val start = session.startTs
            // #1284 residual 3: log when this persist lands wholly inside — or overlapping — a session already
            // banked this connection. That is the duplicate GENERATION (an early partial drain banked a short
            // session; this fuller burst nests it), which the #899 heal only cleans up afterward. Include the
            // 0x49 anchor state, since a persist with NO 0x49 anchor is the prime suspect for the short row.
            // Diagnostic only — nothing is skipped here; the fix is 0x49-window session keying (hardware-gated).
            recentPersistedSessionWindows.firstOrNull { (s, e) -> start < e && end > s }?.let { (s, e) ->
                val nested = start >= s && end <= e
                val anchor = if (sleepStart != null) "0x49 onset=$sleepStart" else "no 0x49 onset (start derived from burst end)"
                log("Oura: duplicate-gen(#1284) new session [$start -> $end] ${if (nested) "NESTED IN" else "OVERLAPS"} " +
                    "already-banked [$s -> $e] this connection - $anchor; PK=(deviceId,startTs) mints a 2nd row")
            }
            recentPersistedSessionWindows.add(start to end)
            if (recentPersistedSessionWindows.size > RECENT_PERSISTED_SESSIONS_CAP) {
                recentPersistedSessionWindows.subList(0, recentPersistedSessionWindows.size - RECENT_PERSISTED_SESSIONS_CAP).clear()
            }
            persistSleepSession(session, deviceId)
            val effStr = session.efficiency?.let { e -> "${(e * 100).toInt()}%" } ?: "n/a"
            // #1284 residual 3: stamp the 0x49 anchor state on EVERY persist, so an unanchored early-drain row
            // (the prime suspect for the short nested duplicate) is self-evident even when it is the FIRST
            // persist, before the duplicate-gen line above can fire.
            // #1284: log the SESSION's STORED window, not the pre-trim burst window. The #1293
            // trailing-run trim shortens the persisted end, so [$start -> $end] (from the burst) reads
            // ~tens of minutes wider than the row — every future capture then reads the wrong window out
            // of the log. session.startTs/.endTs are exactly what persistSleepSession banks.
            val anchorTag = if (sleepStart != null) "0x49-onset" else "no-0x49-onset"
            log("Oura: sleep session persisted [${session.startTs} -> ${session.endTs}] eff=$effStr [$anchorTag] -> $deviceId (ring-provided night; wins merge over computed)")
        }
    }

    /** Re-try bursts parked while unanchored (called right after an anchor lands). */
    private fun drainPendingHypnogramBursts() {
        if (pendingUnanchoredBursts.isEmpty()) return
        val held = ArrayList(pendingUnanchoredBursts)
        pendingUnanchoredBursts.clear()
        for (burst in held) persistHypnogramBurst(burst)
    }

    /**
     * Teardown for bursts that never anchored this session: DROP them honestly instead of persisting a
     * wall-clock-guessed time axis. Nothing is lost — the resume cursor only advances on an anchored
     * persist, so the ring re-serves the same records on the next drain.
     */
    private fun dropUnanchoredHypnogramBursts() {
        if (pendingUnanchoredBursts.isEmpty()) return
        val codes = pendingUnanchoredBursts.sumOf { it.totalCodes }
        log("Oura: dropping ${pendingUnanchoredBursts.size} unanchored hypnogram burst(s) ($codes codes)" +
            " - no anchor this session; cursor did not advance, so they re-arrive next drain")
        pendingUnanchoredBursts.clear()
    }

    /**
     * Anchor from the 0x13 SyncTime response (ringverse: the ring's clock counter when it processed
     * our SyncTime, paired with host wall-clock at receipt). The tick unit is disambiguated against
     * the persisted resume cursor; no unambiguous reading → log the raw value and adopt NOTHING (an
     * honest missing anchor beats a guessed one). Kotlin twin of Swift's handleSyncTimeResponse.
     */
    private fun handleSyncTimeResponse(d: OuraDriver, resp: com.noop.oura.SyncTimeResponse) {
        val now = System.currentTimeMillis() / 1000L
        val raw = "0x%08x".format(resp.deviceTimestamp)
        val rt = OuraDriver.syncTimeAnchorCandidate(resp.deviceTimestamp, historyCursor)
        if (rt != null && d.adoptSyncTimeAnchor(ringTimestamp = rt, unixSeconds = now)) {
            val unit = if (rt == resp.deviceTimestamp) "ticks" else "seconds x10"
            if (!loggedAnchor) {
                loggedAnchor = true
                log("Oura: UTC anchor from SyncTime response (0x13) - device rt $rt [$unit, raw $raw, " +
                    "status ${resp.status}] = now; no 0x42 needed this session")
            }
            drainPendingAnchorEvents()
            drainPendingHypnogramBursts()
        } else {
            log("Oura: SyncTime response (0x13) raw $raw status ${resp.status} - no unambiguous tick " +
                "reading vs cursor $historyCursor; anchor NOT adopted (investigation)")
        }
    }

    // MARK: - Sample buffer (flushed in batches off the per-notification hot loop)

    /**
     * One buffered batch of decoded events, stamped with its own [ts] (unix seconds): genuinely-live
     * pushes (HR, battery) are stamped at wall-clock arrival time; ring-time-carrying events (IBI, temp,
     * SpO2, HRV, sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) when an anchor is available,
     * so last night's data is never mis-recorded as happening right now. Mirrors the Swift buffer
     * `(events, ts)`. [flush] folds each batch through the unit-tested [OuraStreamMapping] so the SAME pure
     * mapping the tests pin is the production path.
     */
    private data class Batch(val events: List<OuraEvent>, val ts: Int)

    private val bufferLock = Any()
    private val buffer = ArrayList<Batch>()
    private var lastFlushMs = System.currentTimeMillis()
    private val flushCount = 30
    private val flushIntervalMs = 30_000L

    // MARK: - Scanning

    /** Begin scanning for Oura rings advertising the ring's base service. */
    override fun scan() {
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        _needsPairing.value = null
        log("Oura: scanning for an Oura ring (${ringGen.displayName})…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("Oura: no BLE scanner available - Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("Oura: Bluetooth adapter is off - cannot scan")
            return
        }
        // Filter by the ring's base service so a broad scan does not surface unrelated peripherals; the
        // callback further confirms the advertised name reads as an Oura ring.
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        sc.startScan(listOf(filter), settings, scanCallback)
    }

    /** Stop an in-progress scan. Idempotent. */
    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    /** Connect to the chosen discovered ring (by address) and start the auth → enable → stream flow. */
    override fun connect(address: String) {
        stopScan()
        _needsPairing.value = null
        // Remember the paired ring so an involuntary drop auto-reconnects to it (#912). An explicit connect
        // is never the intentional-teardown case, so clear the suppression flag.
        reconnectAddress = address
        intentionalDisconnect = false
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) { pendingConnectAddress = address; return }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        lastDevice = device   // remembered so a status-133 disconnect can auto-retry the same ring
        log("Oura: connecting to ${device.address}")
        // Tear down any prior link first so we never run two GATTs for this source.
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        // A fresh driver per connection: the app key is session-scoped (the proof handshake re-runs on
        // every connection), and a key provisioned since the last attempt is picked up here. allowKeyInstall
        // is wired straight from the connection's adoptIntent so the dangerous 0x24 write is reachable ONLY
        // under an explicit adopt consent (OURA_PROTOCOL.md s3.2).
        // allowTierB = true - INVESTIGATION ONLY (activity/real_steps/sleep-summary/smoothed-SpO2 tags,
        // OURA_PROTOCOL.md s7.3 Tier B, UNVERIFIED layouts; PR #960). This lets `emit` LOG what the ring
        // actually sends (raw bytes per kind, decoded MET for 0x50) so the layouts can be validated
        // against real captures. It can never leak a value into scoring: OuraStreamMapping drops
        // TierB/ActivityInfo unconditionally - the Tier-discipline gate that matters lives there, not here.
        driver = OuraDriver(ringGen = ringGen, authKey = authKey(), allowTierB = true,
                            allowKeyInstall = adoptIntent)
        reassembler.reset()
        pendingInstallKey = null       // a new connection starts with no install in flight
        _adoptPhase.value = AdoptPhase.Idle   // a stale outcome must never drive the wizard's transition
        resetWear()   // #628: fresh session — clear any stale worn/charging badge
        // A fresh session: reset the one-shot streaming/anchor state, and never replay a stale-anchor guess.
        reachedStreaming = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.clear()
        loggedFeatureStatuses.clear()
        loggedProductInfo.clear()
        pendingAnchorEvents.clear()
        // Per-drain / per-session protocol state starts clean (twin of Swift's connect-setup reset).
        drain.reset()
        resumeCursorAtFetchStart = 0
        drainStartedAtMs = null
        lastRequestCursor = 0
        pendingContinuation = false
        handler.removeCallbacks(batchQuietRunnable)
        chainedDrainPasses = 0
        handler.removeCallbacks(chainedDrainRunnable)
        hypnogramAssembler.reset()        // never replay a half-accumulated burst from a dead session
        pendingUnanchoredBursts.clear()
        recentSleepWindows049.clear()
        recentPersistedSessionWindows.clear()
        greenIbiAmpCount = 0
        greenIbiAmpLengths.clear()
        // Resume the GetEvents cursor from where the LAST connection to this ring left off (s5.1/5.3), so a
        // routine reconnect doesn't re-fetch the ring's entire banked history every time. A persisted value
        // above the plausibility ceiling is pre-fix garbage; reset to a full pull instead of seeking to it.
        val loadedCursor = OuraHistoryCursorStore.read(appContext, deviceId)
        historyCursor = OuraHistoryDrain.sanitizeLoadedCursor(loadedCursor)
        if (historyCursor != loadedCursor) {
            log("Oura: persisted resume cursor $loadedCursor exceeds the plausibility ceiling (pre-fix garbage) - full pull")
            OuraHistoryCursorStore.save(appContext, deviceId, 0)
        }
        // connectGatt can throw (SecurityException if BLUETOOTH_CONNECT was revoked mid-session,
        // IllegalArgumentException on a stale device) - never let that crash the app; a failed start
        // simply leaves the previous source in place (mirrors [StandardHrSource]).
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            log("Oura: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
            null
        }
    }

    /** Tear down: cancel the connection and stop scanning, persisting anything still buffered. Idempotent. */
    override fun stop() {
        // A deliberate teardown (device switch / removal) must NOT auto-reconnect: mark it intentional and
        // drop the reconnect target so any pending backoff bails and no fresh one is scheduled (#912). Remove
        // any already-posted reconnect from the main-looper handler too, so it isn't retained for the full
        // backoff (mirrors cancelReengage's removeCallbacks).
        intentionalDisconnect = true
        reconnectAddress = null
        failedReconnectAttempts = 0
        handler.removeCallbacks(reconnectRunnable)
        handler.removeCallbacks(retry133Runnable)
        stopScan()
        pendingConnectAddress = null
        cancelReengage()
        cancelHistoryFetch()
        handler.removeCallbacks(batchQuietRunnable)
        handler.removeCallbacks(chainedDrainRunnable)
        pendingContinuation = false
        chainedDrainPasses = 0
        // Drain BEFORE driver.stop() clears its anchor, so a pending event still gets a real anchored time
        // if one exists rather than always falling back to wall-clock at teardown (mirrors Swift's stop()).
        // Same for a hypnogram burst still accumulating (e.g. the session ended mid-drain); one that never
        // anchored is dropped honestly — the cursor did not advance, so it re-arrives next drain.
        hypnogramAssembler.flush()?.let { persistHypnogramBurst(it) }
        drainPendingAnchorEvents()
        dropUnanchoredHypnogramBursts()
        // #1526 follow-up, twin of the Swift `stop()` call: cancelling the re-engage does NOT stop the
        // ring. That is the "just stop poking it" assumption #1526's captures falsified -- daytime-HR
        // left in mode 0x01 kept pushing green 0x80 all night, and the ring's ~20 s auto-revert never
        // fired. A teardown that only cancels the timer therefore hands back a ring still in daytime
        // mode, blocking its own sleep suite. Send the same disable + unsubscribe pair before the link
        // goes, and BEFORE driver.stop() so the phase check below still sees Streaming.
        //
        // Best-effort by nature: WRITE_TYPE_NO_RESPONSE goes to the controller immediately, but the
        // disconnect follows in the next statement and nothing guarantees a flush. It closes the common
        // cases -- user disconnect, source switch, Bluetooth off -- and a process kill cannot be covered
        // at all, which is a transport limit rather than a gap in this fix.
        disableLiveHR()
        driver?.stop()
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
        writeChar = null
        notifyChar = null
        reassembler.reset()
        loggedFirstHr = false      // a later reconnect should log its first sample again
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.clear()
        loggedFeatureStatuses.clear()
        loggedProductInfo.clear()
        reachedStreaming = false
        // A stop MID-install is an honest failure (no ack will come); a stop after streaming leaves the
        // completed Streaming outcome intact so the wizard's success transition is not undone.
        if (_adoptPhase.value == AdoptPhase.InstallingKey) _adoptPhase.value = AdoptPhase.Failed
        pendingInstallKey = null
        _batteryPct.value = null   // a stale charge must not outlive the link
        resetWear()                // #628: clear the wear badge too
        flush()
    }

    // MARK: - Buffer / persistence

    /** Buffer one batch of decoded events under the supplied [ts] (unix seconds: wall-clock for live
     *  pushes, ring-time-anchored for history-fetched records), flushing on count/interval. Mirrors the
     *  Swift `enqueue(_ events:ts:)`. */
    private fun enqueue(events: List<OuraEvent>, ts: Int) {
        if (events.isEmpty()) return
        val shouldFlush = synchronized(bufferLock) {
            buffer.add(Batch(events, ts))
            buffer.size >= flushCount ||
                System.currentTimeMillis() - lastFlushMs >= flushIntervalMs
        }
        if (shouldFlush) flush()
    }

    private fun flush() {
        val snapshot: List<Batch>
        synchronized(bufferLock) {
            lastFlushMs = System.currentTimeMillis()
            if (buffer.isEmpty()) return
            snapshot = ArrayList(buffer); buffer.clear()
        }
        // PRODUCTION PATH THROUGH THE TESTED MAPPING: fold each batch's raw events into a protocol Streams
        // via the unit-tested [OuraStreamMapping] (its Tier-B-drop + honest-data invariants), then widen to
        // the Room StreamBatch via [StreamPersistence.toBatch]. Each batch carries its OWN resolved ts
        // (wall-clock for live pushes; the ring-time-anchored UTC (s5.5) for history-fetched records), so
        // the mapping's per-batch constant anchor `{ batch.ts }` matches the Swift twin's
        // `OuraStreamMapping.streams(from: entry.events, at: entry.ts)`. Routing through the mapping (not
        // hand-built rows) is what keeps the production persist parity with Swift and under test.
        for (batch in snapshot) {
            val streams = OuraStreamMapping.streams(batch.events) { batch.ts }
            val out = StreamPersistence.toBatch(streams)
            if (out.hr.isNotEmpty() || out.rr.isNotEmpty() || out.spo2.isNotEmpty() ||
                out.skinTemp.isNotEmpty() || out.events.isNotEmpty() || out.battery.isNotEmpty()
            ) {
                persist(out, deviceId)
            }
        }
    }

    /**
     * Flush every event parked in [pendingAnchorEvents], now that `driver.unixSeconds` can resolve them
     * (called right after the anchor is set) - OR, if called at session teardown with NO anchor ever having
     * arrived, with an honest wall-clock fallback (a rough stamp beats silently dropping real decoded
     * samples). Reset the buffer afterward so nothing is drained twice. Kotlin twin of Swift's
     * `drainPendingAnchorEvents`.
     */
    private fun drainPendingAnchorEvents(): Unit = guardedCallback("drain-pending") {
        if (pendingAnchorEvents.isEmpty()) return@guardedCallback
        val d = driver ?: return@guardedCallback
        val now = (System.currentTimeMillis() / 1000L).toInt()
        // Batched by resolved second, exactly like the live path (#1072): a record's parked beats are
        // released as ONE persist so `ord` records their emission order instead of restarting at 0 per beat.
        val stamped = pendingAnchorEvents.map { (event, ringTimestamp) ->
            event to (d.unixSeconds(forRingTimestamp = ringTimestamp)?.toInt() ?: now)
        }
        for ((ts, batch) in OuraStreamMapping.batched(stamped)) enqueue(batch, ts)
        pendingAnchorEvents.clear()
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
            // Confirm the advertised name reads as an Oura ring (the service filter is the primary gate;
            // this rejects anything that slipped through advertising the same base service).
            if (ExperimentalBrand.recognise(name) != ExperimentalBrand.OURA) return
            val firstSight = seen.put(address, device) == null   // null → not seen before this scan
            if (firstSight) log("Oura: found $name ($address) rssi ${result.rssi}")
            // Best-effort generation guess from the advertised name (confirmed by the model the user picks).
            val detectedGen = OuraRingGen.recognise(name)
            val ring = DiscoveredRing(
                address = address,
                name = name.ifBlank { "Oura" },
                rssi = result.rssi,
                detectedGen = detectedGen,
            )
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = ring else list.add(ring)
            _discovered.value = list
            // Replay a connect intent that arrived before the ring was discovered.
            if (pendingConnectAddress == address) {
                pendingConnectAddress = null
                handler.post { connectToDevice(device) }
            }
        }
    }

    // MARK: - GATT callback

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = guardedCallback("connection-state") {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        log("Oura: WARNING connected with non-success status=$status")
                    }
                    retried133 = false   // a real connection clears the one-shot 133 retry guard
                    failedReconnectAttempts = 0   // a real connection clears the reconnect backoff (#912)
                    log("Oura: connected (status=$status) - discovering services")
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    log("Oura: disconnected (status=$status)")
                    loggedFirstHr = false   // a reconnect should log its first sample again
                    _batteryPct.value = null
                    resetWear()             // #628: the wear badge must not survive the link dropping
                    cancelReengage()
                    cancelHistoryFetch()
                    handler.removeCallbacks(batchQuietRunnable)
                    handler.removeCallbacks(chainedDrainRunnable)
                    pendingContinuation = false
                    // Drain BEFORE the driver's anchor is gone (same reasoning as stop()): a pending event
                    // still gets a real anchored time if the current session set one, else an honest
                    // wall-clock fallback rather than being silently dropped. A hypnogram burst still
                    // accumulating flushes first for the same reason; unanchored ones drop honestly.
                    hypnogramAssembler.flush()?.let { persistHypnogramBurst(it) }
                    drainPendingAnchorEvents()
                    dropUnanchoredHypnogramBursts()
                    reassembler.reset()
                    loggedFirstTemp = false
                    loggedFirstSpo2 = false
                    loggedAnchor = false
                    loggedTierBKinds.clear()
        loggedFeatureStatuses.clear()
        loggedProductInfo.clear()
                    reachedStreaming = false
                    // A disconnect MID-install is an honest failure (no 0x25 ack will arrive); a disconnect
                    // after streaming leaves the completed Streaming outcome intact. Drop any in-flight key
                    // WITHOUT persisting it (a failed install must never leave a wrongly-trusted key).
                    if (_adoptPhase.value == AdoptPhase.InstallingKey) _adoptPhase.value = AdoptPhase.Failed
                    pendingInstallKey = null
                    flush()
                    if (gatt === g) { runCatching { g.close() }; gatt = null }
                    // Hardening: status 133 is Android's infamous generic GATT_ERROR on connect - almost
                    // always transient. Auto-retry ONCE (immediately, 1s) before falling through to the
                    // general capped-backoff auto-reconnect below.
                    if (status == GATT_ERROR_133 && !retried133 && lastDevice != null && !intentionalDisconnect) {
                        retried133 = true
                        log("Oura: connect error 133 - retrying once in 1s")
                        handler.postDelayed(retry133Runnable, 1000)
                        return@guardedCallback   // the one-shot 133 retry owns the reconnect for this drop
                    }
                    if (status == GATT_ERROR_133 && retried133) {
                        log("Oura: still failing (133) - try forgetting the ring in Android " +
                            "Settings → Bluetooth, then re-pair.")
                        // Fall through to the capped-backoff reconnect so a transient 133 storm still recovers
                        // on its own once the ring settles, rather than giving up until a manual reconnect.
                    }
                    // Auto-reconnect on an INVOLUNTARY drop / failed connect (#912): the paired ring went out
                    // of range or the link dropped. Re-issue a connect on the capped backoff so it comes back
                    // on its own, exactly like the WHOOP strap. A deliberate stop() set intentionalDisconnect
                    // and cleared reconnectAddress, so this is a no-op there; a needs-pairing dead-end also
                    // suppressed it. This owns its OWN scan/GATT and never touches the WHOOP path.
                    scheduleReconnect()
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = guardedCallback("services-discovered") {
            log("Oura: services discovered (status=$status)")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Oura: WARNING service discovery failed (status=$status) - giving up on this ring")
                return@guardedCallback
            }
            // Request the gen-appropriate MTU (gen3=203, gen4/5=247) so multi-record notifications and
            // the auth proof fit. The flow continues from onMtuChanged (or falls through if it fails).
            log("Oura: requesting MTU ${ringGen.mtu}")
            val requested = runCatching { g.requestMtu(ringGen.mtu) }.getOrDefault(false)
            if (!requested) {
                // Some stacks reject requestMtu; proceed at the default MTU rather than stall.
                log("Oura: MTU request not accepted - proceeding at default MTU")
                setUpNotifications(g)
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = guardedCallback("mtu-changed") {
            log("Oura: MTU negotiated = $mtu (status=$status)")
            setUpNotifications(g)
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) = guardedCallback("descriptor-write") {
            if (descriptor.uuid != CCCD) return@guardedCallback
            if (status == BluetoothGatt.GATT_SUCCESS) {
                log("Oura: notifications enabled (CCCD write status=$status) - beginning auth")
                // Notifications are live: tell the driver we are Ready. It returns the enable-notify +
                // get-nonce commands (or drives the honest needs-pairing path when there is no app key).
                advance(OuraTransition.Ready)
            } else {
                log("Oura: WARNING CCCD write FAILED (status=$status) - ring will send no data")
                announceNeedsPairing(KEY_INSTALL_MESSAGE)
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (ch.uuid == NOTIFY_UUID) handleNotification(value)
        }

        // Legacy (< API 33) characteristic-changed callback: read the value off the characteristic.
        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (ch.uuid == NOTIFY_UUID) handleNotification(ch.value ?: return)
        }
    }

    /** Resolve the write/notify characteristics, enable notifications on ...0003, and write the CCCD.
     *  The auth flow begins from onDescriptorWrite once the CCCD write is acknowledged. */
    private fun setUpNotifications(g: BluetoothGatt) = guardedCallback("setup-notify") {
        val svc = g.getService(SERVICE_UUID)
        if (svc == null) {
            log("Oura: base service NOT FOUND - this peripheral is not a supported Oura ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        writeChar = svc.getCharacteristic(WRITE_UUID)
        notifyChar = svc.getCharacteristic(NOTIFY_UUID)
        val notify = notifyChar
        if (writeChar == null || notify == null) {
            log("Oura: write/notify characteristics NOT FOUND - cannot drive the ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        log("Oura: write + notify characteristics found - enabling notifications on the notify char")
        g.setCharacteristicNotification(notify, true)
        val cccd = notify.getDescriptor(CCCD)
        if (cccd == null) {
            log("Oura: WARNING notify char has no CCCD (0x2902) - cannot enable notifications")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val rc = g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            log("Oura: CCCD write requested (rc=$rc)")
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                val ok = g.writeDescriptor(cccd)
                log("Oura: CCCD write requested (rc=$ok)")
            }
        }
    }

    // MARK: - Driver flow

    /** Feed a transport transition to the driver and write back the commands it returns. After the
     *  enable triplet completes the driver reports Streaming; we then begin the periodic re-engage. */
    private fun advance(transition: OuraTransition) = guardedCallback("advance") {
        val d = driver ?: return@guardedCallback
        val commands = d.nextStep(transition)
        for (cmd in commands) write(cmd)
        when (d.phase) {
            OuraDriverPhase.Streaming -> {
                // The driver returns to Streaming after EACH history-fetch pass completes, so gate all the
                // one-shot streaming work on reachedStreaming (twin of Swift's `if !reachedStreaming`) - it
                // must run exactly once per connection, not on every history summary.
                if (!reachedStreaming) {
                    reachedStreaming = true
                    // Re-auth after an install (or a normal auth) reached the stream: adoption is complete.
                    // The OK ack already persisted the key; nothing is left in flight.
                    _adoptPhase.value = AdoptPhase.Streaming
                    pendingInstallKey = null
                    log("Oura: live HR enabled - streaming")
                    scheduleReengage()
                    // SyncTime FIRST (s5.4, twin of Swift): sets the ring clock AND its 0x13 response
                    // carries the ring's current clock counter — the deterministic anchor that lets the
                    // whole drain below resolve real times without waiting for a lucky 0x42.
                    write(OuraCommands.syncTime(System.currentTimeMillis() / 1000L))
                    // Pull last night's banked temp/SpO2/HRV/sleep-phase right away + keep a periodic pass
                    // running, and ask for battery once (the 0x0D reply routes to onBattery).
                    scheduleHistoryFetch()
                    fetchHistoryIfIdle()
                    write(OuraCommands.getBattery())
                    // Read-only diagnostic: ask the ring its SpO2 / real-steps feature status once, so a
                    // capture confirms (from the ring itself) that these server-flag features are
                    // subscription-gated OFF for an offline ring. NEVER an enable/set-mode write.
                    write(OuraCommands.spo2ReadStatus())
                    write(OuraCommands.realStepsReadStatus())
                    // Read-only capture (#771/#772): the ring's GetProductInfo serial + hardware pages are
                    // pre-auth readable. The SERIAL is a STABLE per-ring identity (Android mints the id from
                    // the MAC today, but the serial is the platform-neutral identity Swift needs too, #771),
                    // and the HARDWARE id (e.g. "BLB_03") maps to the generation, confirming it from the ring
                    // instead of stray digits in the advertised name (#772). Here we only ASK and LOG the raw
                    // replies to capture their byte layout; nothing is decoded, minted into an id, or persisted
                    // yet (capture-first). Same read-only class as the SpO2 / real-steps reads above.
                    write(OuraCommands.getProductSerial())
                    write(OuraCommands.getProductHardware())
                }
            }
            OuraDriverPhase.NeedsKeyInstall -> {
                // Factory-reset ring (auth status 0x02) or no key. The dangerous key install is the ONLY
                // thing that recovers it, and ONLY with explicit adopt consent: provision when adoptIntent,
                // otherwise stay honest and never loop the dangerous command.
                if (adoptIntent) provisionKeyInstall(d) else announceNeedsPairing(KEY_INSTALL_MESSAGE)
            }
            is OuraDriverPhase.AuthFailed -> {
                log("Oura: auth failed - the stored install key does not match this ring")
                announceNeedsPairing(AUTH_FAILED_MESSAGE)
            }
            else -> Unit
        }
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /**
     * PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from [advance]
     * when the driver phase is NeedsKeyInstall AND [adoptIntent] is true. Steps:
     *   1. generate a fresh cryptographically-random 16-byte key;
     *   2. ask the driver for the dangerous `24 10 <key>` install command (the driver's own
     *      `allowKeyInstall`/phase gate is the second guard) and write it;
     *   3. hold the key in memory and mark [AdoptPhase.InstallingKey] (an install IS now running).
     * The key is NOT persisted yet: it is written to the keystore only once the ring acks OK
     * ([handleKeyInstallAck]), so a failed install never leaves a key the next session would wrongly trust.
     * On any RNG/build failure we stay honest (announceNeedsPairing) and never retry the dangerous command.
     * Kotlin twin of Swift's `provisionKeyInstall`.
     */
    private fun provisionKeyInstall(d: OuraDriver) = guardedCallback("provision-key") {
        if (!adoptIntent) return@guardedCallback             // belt-and-braces: never provision without consent
        if (pendingInstallKey != null) return@guardedCallback // an install is already in flight; don't double-send
        val key = runCatching { randomKey() }.getOrNull()
        if (key == null || key.size != OuraAuth.keyLength || key.any { it !in 0..255 }) {
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        val cmd = d.beginKeyInstall(key)
        if (cmd == null) {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            log("Oura: the install command could not be prepared - staying honest")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        pendingInstallKey = key
        _adoptPhase.value = AdoptPhase.InstallingKey
        log("Oura: installing NOOP's key on the reset ring")
        write(cmd)
    }

    /**
     * Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
     * Acts ONLY when an install we initiated is in flight (a pending key is held AND driver phase is
     * InstallingKey); a stray 0x25 outside an adopt is ignored. On OK: PERSIST the freshly-provisioned key
     * under this deviceId (so every future session authenticates with it), then drive the driver's
     * keyInstallAcknowledged() to re-run the auth handshake (GetAuthNonce then Authenticate) with the NEW
     * key. On a non-OK status (or a failed store) announce an honest failure and do NOT retry the dangerous
     * command. Kotlin twin of Swift's `handleKeyInstallAck`.
     */
    private fun handleKeyInstallAck(d: OuraDriver, frame: OuraOuterFrame) = guardedCallback("key-install-ack") {
        val key = pendingInstallKey ?: return@guardedCallback              // no install in flight
        if (d.phase != OuraDriverPhase.InstallingKey) return@guardedCallback // not our install in flight
        val status = frame.body.firstOrNull()
        if (status == SET_AUTH_KEY_OK) {
            // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
            if (!OuraInstallKeyStore.save(appContext, deviceId, key)) {
                log("Oura: the installed key could not be stored - cannot adopt this ring")
                announceNeedsPairing(KEY_INSTALL_MESSAGE)
                return@guardedCallback
            }
            log("Oura: key installed and stored - re-authenticating with the new key")
            pendingInstallKey = null
            // Re-auth with the freshly-installed key. The driver returns enable-notify + get-nonce; the
            // nonce response then flows through the normal routeSecure -> advance path to streaming.
            for (cmd in d.keyInstallAcknowledged()) write(cmd)
        } else {
            log("Oura: the ring did not accept the key (status=${status ?: "none"}) - cannot adopt this ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
        }
    }

    /**
     * Hand the ring back out of daytime-HR mode: the feature-mode write plus the unsubscribe the enable
     * triplet leaves standing. Twin of Swift `OuraLiveSource.disableLiveHR`.
     *
     * `liveHRDisable` alone only touches the MODE byte, so without the unsubscribe the notification
     * channel stays open for the ring's own adaptive sampling to push through -- which is why #1526
     * corrected the byte (0x01 "automatic" was never "off") and added the pair. The Streaming guard
     * covers the callers: there is nothing to disable if the session never got that far.
     */
    private fun disableLiveHR() {
        val d = driver ?: return
        if (d.phase != OuraDriverPhase.Streaming) return
        write(OuraCommands.liveHRDisable())
        write(OuraCommands.liveHRUnsubscribe())
    }

    /** Write one built command to the ring's write characteristic (Write Without Response). Logged by its
     *  short label only (never bytes or an address). */
    private fun write(cmd: OuraCommand) = guardedCallback("write") {
        val g = gatt ?: return@guardedCallback
        val ch = writeChar ?: return@guardedCallback
        val bytes = ByteArray(cmd.bytes.size) { cmd.bytes[it].toByte() }
        log("Oura: → ${cmd.label}")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(ch, bytes, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE)
        } else {
            @Suppress("DEPRECATION")
            run {
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                ch.value = bytes
                g.writeCharacteristic(ch)
            }
        }
    }

    /**
     * Handle one inbound notification value. Two framing layers ride the same notify char (s2):
     *   - 0x2F secure-session sub-frames carry the auth nonce/status, live-HR pushes, and enable ACKs.
     *   - everything else is one or more TLV event records (reassembled across notifications).
     * The pure driver owns every decode; we only route bytes and turn its results into transitions /
     * persisted rows. A throw anywhere here is contained by [guardedCallback] (degrade to "no data").
     */
    private fun handleNotification(data: ByteArray) = guardedCallback("notification") {
        val d = driver ?: return@guardedCallback
        val bytes = IntArray(data.size) { data[it].toInt() and 0xFF }
        // Split any packed outer frames; route 0x2F secure sub-frames through the driver's secure handler
        // and feed all other bytes to the TLV reassembler.
        val nonSecure = ArrayList<Int>()
        for (frame in OuraFraming.parseOuterFrames(bytes)) {
            // #771/#772 capture: log each DISTINCT GetProductInfo reply (serial + hardware pages) raw, once
            // per op+body per session. Peek only — like the 0x11 summary / 0x0D battery below, a product-info
            // op is below the event-tag range (>= 0x41), so letting it fall through to the reassembler is a
            // harmless unknown-tag no-op; nothing here decodes it into a stable id (#771) or a generation
            // (#772) yet. get_serial and get_hardware both answer under op 0x19, so dedupe by content (not op)
            // or the second is swallowed. Rendered hex AND ASCII, since both are strings (e.g. "BLB_03").
            if (frame.op in PRODUCT_INFO_RESPONSE_OPS) {
                val hex = frame.body.joinToString(" ") { "%02x".format(it) }
                if (loggedProductInfo.add("${frame.op}:$hex")) {
                    val ascii = String(CharArray(frame.body.size) { i ->
                        val b = frame.body[i]; if (b in 0x20..0x7e) b.toChar() else '.'
                    })
                    log("Oura: product-info reply op=0x%02x (%dB) raw: %s | ascii: %s".format(frame.op, frame.body.size, hex, ascii))
                    // The two GetProductInfo pages both arrive under op 0x19; tell them apart by content:
                    //  • hardware page ("BLB_03") -> resolves a generation -> correct the model (#772).
                    //  • serial page ("2H3B2405003655", no "_NN" gen marker) -> the ring's STABLE identity ->
                    //    surface it so the app can re-point onto its `oura-<serial>` id (#771).
                    val str = OuraDecoders.productInfoString(frame.body)
                    if (str != null) {
                        val gen = OuraRingGen.fromHardwareId(str)
                        if (gen != null) {
                            if (gen != ringGen) {
                                log("Oura: generation from hardware id $str is ${gen.displayName} (was ${ringGen.displayName}) - correcting model")
                                onModel(gen.displayName)
                            }
                        } else if (isPlausibleSerial(str)) {
                            onSerial(str)
                        }
                    }
                }
            }
            if (frame.op == OuraFraming.secureSessionOp) {
                val secure = OuraFraming.parseSecureFrame(frame) ?: continue
                routeSecure(d, secure)
            } else if (frame.op == SET_AUTH_KEY_RESP_OP) {
                // The post-factory-reset key-install acknowledgement (`25 01 00`, OURA_PROTOCOL.md s3.2):
                // an OUTER frame, not a 0x2F secure sub-frame and not a TLV record. Route it to the adopt
                // handler ONLY (it self-guards: it acts solely when an install we initiated is in flight).
                handleKeyInstallAck(d, frame)
            } else if (frame.op == OuraFraming.getEventsResponseOp) {
                // The `0x11` GetEvents summary drives the history-fetch cursor loop (OURA_PROTOCOL.md
                // s5.2/5.3): an OUTER frame, never a TLV record. Its op (0x11) is well below the event-tag
                // range (tags are >= 0x41), so had it fallen through to the reassembler it would decode as a
                // safe "unknown tag" no-op; we route it to the cursor loop instead (same convention as the
                // 0x25 ack above - handled, not re-serialised).
                val summary = OuraFraming.parseGetEventsResponse(frame.body)
                if (summary != null) handleHistorySummary(summary)
            } else if (frame.op == OuraFraming.syncTimeResponseOp) {
                // The `0x13` SyncTime response is ALSO an OUTER frame ([ringverse BLE.md]): it carries the
                // ring's CURRENT clock counter, which paired with the host wall-clock right now is a
                // DETERMINISTIC anchor — the 0x42 record is only logged when the ring actually adjusts its
                // clock, so an already-synced ring can serve a whole drain with no anchor (2026-07-13).
                val resp = OuraFraming.parseSyncTimeResponse(frame.body)
                if (resp != null) handleSyncTimeResponse(d, resp)
            } else if (frame.op == OuraFraming.batteryResponseOp) {
                // The `0x0D` GetBattery response is ALSO an OUTER frame (never a TLV record, s6.10). Its op
                // is below the event-tag range too, so it is a safe no-op if it ever fell through; we route
                // it through the existing `.battery` ingest path (batteryPct/onBattery/log side effects).
                val battery = OuraDecoders.decodeBattery(frame.body)
                if (battery != null) emit(listOf(OuraEvent.Battery(battery)))
            } else {
                // Re-serialise the outer frame (op, len, body) so the reassembler sees the original wire
                // bytes; TLV records and outer frames share the op/len header shape.
                nonSecure.add(frame.op)
                nonSecure.add(frame.body.size)
                for (b in frame.body) nonSecure.add(b)
            }
        }
        if (nonSecure.isNotEmpty()) {
            val records = reassembler.feed(IntArray(nonSecure.size) { nonSecure[it] })
            for (rec in records) {
                // HISTORY-LOG records (the live-HR path is ingestLiveHRPush via routeSecure): every
                // envelope ring-time advances the drain's in-session continuation cursor (open_oura
                // drain_events tracks the max timestamp of EVERY batch event), and while a continuation
                // is pending the batch-quiet window stays open as long as records keep arriving.
                val events = d.ingest(rec)
                for (e in events) {
                    e.envelopeRingTimestamp?.let { drain.noteSeenRingTime(it) }
                }
                if (pendingContinuation && events.isNotEmpty()) {
                    handler.removeCallbacks(batchQuietRunnable)
                    handler.postDelayed(batchQuietRunnable, batchQuietMs)
                }
                emit(events)
            }
        }
    }

    /** Route a 0x2F secure sub-frame to the driver and turn its result into a transition or live events. */
    private fun routeSecure(d: OuraDriver, secure: com.noop.oura.OuraSecureFrame) = guardedCallback("secure-route") {
        when (val routing = d.handleSecureFrame(secure)) {
            is OuraDriver.SecureRouting.Nonce -> advance(OuraTransition.NonceReceived(routing.nonce))
            is OuraDriver.SecureRouting.AuthStatus -> {
                log("Oura: auth status = ${routing.status.name}")
                advance(OuraTransition.AuthCompleted(routing.status))
            }
            OuraDriver.SecureRouting.EnableAck -> advance(OuraTransition.EnableAckReceived)
            is OuraDriver.SecureRouting.FeatureStatus -> logFeatureStatus(routing.value)   // read-only; no advance
            is OuraDriver.SecureRouting.LiveHRPush -> emit(d.ingestLiveHRPush(routing.body))
            OuraDriver.SecureRouting.Unhandled -> Unit
        }
    }

    /**
     * Log a feature-status read reply once per feature (read-only diagnostic). Confirms, from the ring
     * itself, whether a server-flag feature (SpO2 0x04 / real_steps 0x0b) is subscribed/emitting — NOOP
     * cannot enable these offline (server ClientConfiguration gate), so a `subscription == 0` here is the
     * honest "not a bug, it's a gate" reading. Never scored, never stored.
     */
    private fun logFeatureStatus(st: com.noop.oura.OuraFeatureStatus) {
        if (!loggedFeatureStatuses.add(st.feature)) return
        val name = when (st.feature) {
            OuraCommands.featureSpO2 -> "SpO2 (0x04)"
            OuraCommands.featureRealSteps -> "real_steps (0x0b)"
            OuraCommands.featureDaytimeHR -> "daytime-HR (0x02)"
            else -> "0x${st.feature.toString(16)}"
        }
        // A gated/unavailable feature reports ALL-ZERO (mode/status/state); the streaming daytime-HR, by
        // contrast, reads mode=1 status=0x11 state=2. Flag the all-zero case as the honest "cloud never
        // enabled it" — NOT `subscription==0` alone, since daytime-HR is subscription=0 yet active.
        val off = st.mode == 0 && st.status == 0 && st.state == 0
        val gate = if (off) " - INACTIVE (server-gated off; the cloud never enabled it, not emitted offline)" else ""
        // Name the enum fields so the log reads plainly (OURA_PROTOCOL.md s7.1 [ring4-ble]) — e.g. a gated
        // feature prints `mode=0 (off) … subscription=0 (off)`, the active daytime-HR `mode=1 (automatic)`.
        log("Oura: feature status $name mode=${st.mode} (${featureModeName(st.mode)}) status=${st.status} " +
            "state=${st.state} subscription=${st.subscription} (${subscriptionName(st.subscription)})$gate")
    }

    /** The ring's feature-MODE enum (`2f 03 22` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble]. */
    private fun featureModeName(m: Int) = when (m) {
        0 -> "off"; 1 -> "automatic"; 2 -> "requested"; 3 -> "connected_live"; else -> "?"
    }
    /** The ring's SUBSCRIPTION enum (`2f 03 26` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble]. */
    private fun subscriptionName(s: Int) = when (s) {
        0 -> "off"; 1 -> "state"; 2 -> "latest"; 4 -> "feature_data"; else -> "?"
    }

    /**
     * Fold decoded driver events into live-UI updates + the persist buffer (the production path, parity
     * with Swift's `ingest`). Genuinely-live pushes (HR/battery) are stamped at wall-clock arrival time,
     * since they really are "now"; HR is range-gated for the LIVE display (off-finger / garbage never
     * shown) and battery surfaces immediately (a status, not a timestamped row). Ring-time-carrying events
     * (IBI, temp, SpO2, HRV, sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) so last
     * night's banked data is never mis-recorded as happening right now (IBI arrives both live and banked, so
     * it anchors like history but never advances the resume cursor); when no anchor has arrived yet this
     * session, the event is PARKED
     * ([pendingAnchorEvents]) until one does, rather than immediately guessing wall-clock. A 0x42
     * time-sync (the anchor) drains anything parked. Tier-B events (allowed for INVESTIGATION - see the
     * driver construction comment) are LOGGED only, never enqueued: OuraStreamMapping drops them anyway,
     * so an unverified layout can never feed a durable stream or scoring.
     */
    private fun emit(events: List<OuraEvent>) = guardedCallback("emit") {
        if (events.isEmpty()) return@guardedCallback
        val d = driver ?: return@guardedCallback
        val now = (System.currentTimeMillis() / 1000L).toInt()
        // TIME-AXIS RECONSTRUCTION (twin of Swift): one 0x4B/0x4E/0x5A record's codes arrive as one
        // events list; the codes are accumulated per burst and laid out backward from the anchored
        // burst end when it closes (persistHypnogramBurst), instead of being persisted at the
        // (meaningless for sleep) envelope time. A returned burst means a ring-time gap closed the
        // previous one.
        val phases = events.mapNotNull { (it as? OuraEvent.SleepPhaseEvent)?.value }
        if (phases.isNotEmpty()) {
            val counts = IntArray(4)
            for (p in phases) counts[p.stage.raw] += 1
            log("Oura: sleep-phase record codes=${phases.size} " +
                "deep/light/rem/awake=${counts[0]}/${counts[1]}/${counts[2]}/${counts[3]}")
            hypnogramAssembler.feed(phases.first().ringTimestamp, phases)?.let { persistHypnogramBurst(it) }
        }
        // #728: materialise hrSample from BANKED IBI. A batch with NO live-HR push (Hr) is history data —
        // the ring banks overnight IBI (0x60/0x80/0x6E) but no HR, and the nightly pipeline gates on
        // hrSample (day-owner probe + hr.count >= 200), so an Oura night otherwise never scores. Derive one
        // median HR per IBI-record (OuraIbiHr) and enqueue it as Hr → the mapping writes hrSample, WITHOUT
        // this switch's wear/live-badge side-effects (enqueue buffers for the mapping, it never re-enters
        // emit). Live batches ([Hr, Ibi]) are excluded, so live HR is never double-counted. Per-record
        // ring-time anchored; an unanchored record is skipped (re-derived when it re-serves after 0x42).
        val hasLiveHR = events.any { it is OuraEvent.Hr }
        if (!hasLiveHR) {
            val bankedIbis = events.mapNotNull { (it as? OuraEvent.Ibi)?.value }
            for (hr in OuraIbiHr.perRecordMedianHR(bankedIbis)) {
                val ts = d.unixSeconds(forRingTimestamp = hr.ringTimestamp)
                if (ts != null) enqueue(listOf(OuraEvent.Hr(hr)), ts.toInt())
            }
        }
        // #1072 (root cause for #823): a RECORD's beats must reach the store as ONE batch. [assignRrSeq]'s
        // `ord` counter is batch-local — a beat's position among the beats sharing its second WITHIN one
        // persist is the only place emission order still exists — so enqueuing one beat at a time (what the
        // Ibi arm below used to do) restarted the counter on every beat and wrote `ord = 0` on every row:
        // 575,630 of 575,630 rows in a real database. With `ord` tied the read falls through to
        // `(rrMs, seq)`, i.e. a second's beats come back sorted by VALUE, which minimises successive
        // differences by construction and biases RMSSD down (#823). All of one record's beats carry that
        // record's ring time, so grouping the anchored ones by their resolved ts hands the store a record
        // at a time. Unanchored beats still park below and are batched the same way when the 0x42 lands
        // (drainPendingAnchorEvents). Twin of the Swift ingest() batching.
        val anchoredBeats = events.mapNotNull { e ->
            if (e !is OuraEvent.Ibi) null
            else d.unixSeconds(forRingTimestamp = e.value.ringTimestamp)?.let { ts -> e as OuraEvent to ts.toInt() }
        }
        for ((ts, batch) in OuraStreamMapping.batched(anchoredBeats)) enqueue(batch, ts)
        for (e in events) when (e) {
            is OuraEvent.Hr -> {
                val bpm = e.value.bpm
                if (bpm in 30..220) {   // physiological gate for the LIVE readout only
                    if (!loggedFirstHr) {
                        loggedFirstHr = true
                        log("Oura: receiving data - first sample $bpm bpm")
                    }
                    handler.post { guardedCallback("live-sink") { liveSink(bpm, emptyList()) } }
                }
                // A LIVE HR push (0x2F) exists only while the ring is measuring on a finger, so it is the
                // sole safe "worn now" signal — fed unconditionally (even a gated-out bpm still proves the
                // ring is on a finger). NEVER fed from OuraEvent.Ibi below: the history path decodes IBI
                // tags to .Ibi only (never .Hr), so a past-night re-serve can't reach here and falsely
                // flip the badge to worn. Mirrors iOS OuraLiveSource `.hr` case. Posted to the main looper
                // (emit runs on the GATT binder thread) so ALL wear-tracker access — here + the re-engage
                // watchdog — is single-threaded, matching how liveSink is posted just above.
                val pulseAt = System.currentTimeMillis()
                handler.post {
                    lastLivePulseAt = pulseAt
                    wearTracker.notePulse()
                    publishWearState()
                }
                enqueue(listOf(e), now)
            }
            is OuraEvent.StateEvent -> {
                // The ring's own lifecycle strings (0x45/0x53). Charger transitions drive the wear badge;
                // never a durable Streams row. Posted to the main looper (see the .Hr note) so wear-tracker
                // access stays single-threaded. Mirrors iOS OuraLiveSource `.state` case.
                val st = e.value
                handler.post {
                    wearTracker.note(st)
                    publishWearState()
                }
            }
            is OuraEvent.Ibi -> {
                val rr = e.value.ibiMs
                if (rr in 250..3000) handler.post { guardedCallback("live-sink") { liveSink(0, listOf(rr)) } }
                // A banked IBI is history data: anchor it to its REAL ring-time, exactly like the sibling
                // banked streams (.Hrv/.Temp/.Spo2/.SleepPhaseEvent) - never the drain-arrival `now`.
                // Stamping at `now` misfiled every overnight beat to the daytime sync moment, so the sleep
                // window ended up with zero R-R -> no restingHr/avgHrv for the night. The anchored beats
                // were ALREADY enqueued above, as one batch per record (#1072); all this arm still owns is
                // the live readout and parking the ones no anchor can place yet.
                if (d.unixSeconds(forRingTimestamp = e.value.ringTimestamp) == null) {
                    pendingAnchorEvents.add(e to e.value.ringTimestamp)
                }
            }
            is OuraEvent.Battery -> {
                handleBattery(e.value.percent)
                enqueue(listOf(e), now)
            }
            is OuraEvent.Temp -> {
                // physiological gate (wrist skin temp); an out-of-range read is dropped, never shown.
                if (e.value.celsius in 20.0..45.0) {
                    if (!loggedFirstTemp) {
                        loggedFirstTemp = true
                        log("Oura: first skin temp decoded (last night) - %.2fC".format(e.value.celsius))
                    }
                    enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
                }
            }
            is OuraEvent.Spo2 -> {
                if (!loggedFirstSpo2) {
                    loggedFirstSpo2 = true
                    log("Oura: first SpO2 decoded (last night) - value ${e.value.value} (${e.value.unit})")
                }
                enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
            }
            is OuraEvent.Hrv -> enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
            is OuraEvent.SleepPhaseEvent -> Unit
            // ^ handled at the record level above (hypnogramAssembler): the envelope time marks the
            //   analysis WRITE moment, not the sleep, so a per-code enqueue here would mis-place the
            //   night. Codes persist when the burst closes (persistHypnogramBurst).
            is OuraEvent.TimeSyncEvent -> {
                // #91: a 0x42 whose epoch is outside the 2020–2035 plausibility window is silently ignored,
                // so history samples stay unanchored (no sleep/daily). Log the rejection with the offending
                // epoch; only announce "acquired" when the sync ACTUALLY anchored (the old unconditional
                // "acquired" line fired even on a rejected sync). `epochMs` holds the raw wire value, which
                // is unix SECONDS despite the name (s6.11).
                if (d.isPlausibleAnchorEpoch(e.value.epochMs)) {
                    if (!loggedAnchor) {
                        loggedAnchor = true
                        log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                    }
                } else {
                    log("Oura: 0x42 time-sync REJECTED - implausible epoch ${e.value.epochMs}s (outside the " +
                        "2020–2035 anchor window); history samples stay unanchored (#91)")
                }
                // The 0x42 time-sync can arrive ANYWHERE in a history-fetch stream, not necessarily first.
                // Anything parked while unanchored gets its real time retroactively the moment it lands.
                drainPendingAnchorEvents()
                drainPendingHypnogramBursts()
            }
            is OuraEvent.RtcBeaconEvent -> {
                // #91: the 0x85 beacon is the SECONDARY anchor (fills the gap only until a 0x42 arrives). A
                // beacon ignored because a primary anchor already exists is NORMAL and not logged; only an
                // IMPLAUSIBLE-epoch beacon is a real failure (it can never anchor), so log just that.
                if (!d.isPlausibleAnchorEpoch(e.value.unixSeconds)) {
                    log("Oura: 0x85 RTC beacon REJECTED - implausible epoch ${e.value.unixSeconds}s (outside " +
                        "the 2020–2035 anchor window) (#91)")
                }
            }
            is OuraEvent.TierB -> {
                // 0x71 green_ibi_amp FIXTURE CAPTURE (upstream #287/#333): unlike the other Tier-B
                // tags, EVERY occurrence is logged (up to a flood cap) with its envelope rt, length,
                // full raw bytes, and the ringverse candidate decode side by side — a verified decoder
                // needs several real payloads cross-checked against concurrent live-HR R-R. Never
                // persisted, never scored (OuraStreamMapping drops TierB unconditionally).
                if (e.value.kind == "green_ibi_amp") {
                    greenIbiAmpCount += 1
                    greenIbiAmpLengths.add(e.value.rawPayload.size)
                    if (greenIbiAmpCount <= GREEN_IBI_AMP_LOG_CAP) {
                        val hex = e.value.rawPayload.joinToString(" ") { "%02x".format(it) }
                        val cand = OuraDecoders.decodeGreenIBIAmpCandidate(e.value.rawPayload, e.value.ringTimestamp)
                        val candStr = if (cand != null) {
                            val ibis = cand.samples.drop(1).joinToString(",") { it.ibiMs.toString() }
                            val amps = cand.samples.joinToString(",") { (it.amplitude ?: 0).toString() }
                            "candidate [ringverse]: shift=${cand.shift} ibis_ms=[$ibis] amps=[$amps]"
                        } else {
                            "candidate [ringverse]: GATE FAILED (len != 14 or reserved bit set)"
                        }
                        log("Oura: 0x71 green_ibi_amp #$greenIbiAmpCount rt=${e.value.ringTimestamp} " +
                            "len=${e.value.rawPayload.size} raw: $hex | $candStr")
                        if (greenIbiAmpCount == GREEN_IBI_AMP_LOG_CAP) {
                            log("Oura: 0x71 log cap ($GREEN_IBI_AMP_LOG_CAP) reached - further records counted only")
                        }
                    }
                } else {
                    // 0x49 sleep_summary_1 window (ringverse, VALIDATED 2026-07-13: both uint16 LE
                    // fields are MINUTES BEFORE the event time — the tracked sleep window). Stash for
                    // the hypnogram burst of the SAME finalization (it follows right after) and log the
                    // window as an independent cross-check of the reconstruction axis. Tier-B: log-only.
                    if (e.value.tag == 0x49 && e.value.rawPayload.size >= 4) {
                        val startOff = (e.value.rawPayload[0] and 0xFF) or ((e.value.rawPayload[1] and 0xFF) shl 8)
                        val endOff = (e.value.rawPayload[2] and 0xFF) or ((e.value.rawPayload[3] and 0xFF) shl 8)
                        // Append (don't overwrite): a drain may carry an overnight AND a nap window, and
                        // each burst pairs with its OWN by ring-time proximity. Bounded — oldest dropped.
                        recentSleepWindows049.add(Triple(e.value.ringTimestamp, startOff, endOff))
                        if (recentSleepWindows049.size > RECENT_SLEEP_WINDOWS_049_CAP) {
                            recentSleepWindows049.subList(0, recentSleepWindows049.size - RECENT_SLEEP_WINDOWS_049_CAP).clear()
                        }
                        log("Oura: 0x49 sleep window candidate [ringverse] offsets start-${startOff}min " +
                            "end-${endOff}min")
                    }
                    // Other Tier-B tags (real_steps / activity-summary / sleep-summary / smoothed-SpO2,
                    // OURA_PROTOCOL.md s7.3; PR #960): logged ONCE PER KIND with the raw bytes so we can
                    // see whether the ring sends these tags at all and collect capture material - e.g.
                    // real_steps 0x7E/0x7F was assumed server-flag-gated OFF ([open_oura-feat]), which
                    // made its absence self-explanatory. That no longer holds: the ring's own status read
                    // came back ENABLED on-device (#1629), so gating does NOT explain why these tags never
                    // arrive, and whether that is the ring's doing or a decode gap is currently unknown.
                    if (loggedTierBKinds.add(e.value.kind)) {
                        val hex = e.value.rawPayload.joinToString(" ") { "%02x".format(it) }
                        log("Oura: Tier-B ${e.value.kind} seen (tag 0x${e.value.tag.toString(16)}) - raw: $hex")
                    }
                }
            }
            is OuraEvent.ActivityInfo -> {
                // INVESTIGATION ONLY (0x50 activity/MET, Tier B - a plausible third-party formula, NOT
                // ground-truth-validated; see OuraActivityInfo). Logged with the DECODED state/MET values
                // every time (not once-per-kind): this is the tag under active plausibility evaluation, so
                // every real capture is evidence. Never persisted, never scored, and NEVER converted into
                // steps (MET is not a step count; OuraStreamMapping drops ActivityInfo unconditionally).
                log("Oura: activity (Tier-B) state=${e.value.state} met=${e.value.met}")
                // Append the raw record to the Tier-B research corpus (anchored records only; deduped by
                // ring-time in the writer). Diagnostic sidecar - never persisted to the DB, never scored.
                d.unixSeconds(forRingTimestamp = e.value.ringTimestamp)?.let { utc ->
                    activityDump?.record(
                        ringTs = e.value.ringTimestamp, utc = utc, state = e.value.state,
                        secPerSample = 60, met = e.value.met, // 60 s = assumed MET cadence (s6.13)
                    )
                }
            }
            is OuraEvent.RealStepsFields -> {
                // INVESTIGATION ONLY (0x7E/0x7F real_steps_features, Tier B - a cited third-party unpack
                // formula [oura-rs], NOT ground-truth-validated; see OuraRealStepsFields). Logged once per
                // kind (like the other raw Tier-B tags) rather than every occurrence - this stream runs at
                // a much higher rate than 0x50 MET, so the JSONL corpus is the real record; the strap log
                // just confirms the ring sends it at all. Never persisted, never scored, and NEVER
                // converted into steps (OuraStreamMapping drops RealStepsFields unconditionally) - not
                // even from fields[0]/fields[8], which ground truth showed are movement FEATURES, not a
                // count (a 13,349-step day; every field large and non-zero asleep - OURA_PROTOCOL.md s6.13).
                if (loggedTierBKinds.add("real_steps_fields")) {
                    log("Oura: Tier-B real_steps_fields seen (tag 0x${e.value.tag.toString(16)}) - first fields: ${e.value.fields}")
                }
                d.unixSeconds(forRingTimestamp = e.value.ringTimestamp)?.let { utc ->
                    realStepsDump?.record(tag = e.value.tag, ringTs = e.value.ringTimestamp, utc = utc, fields = e.value.fields)
                }
            }
            is OuraEvent.SleepPeriodInfo -> {
                // 0x6A sleep_period_info (Tier B - third-party field NAMES [open_ring] over offsets our
                // own s6.12 already had; see OuraSleepPeriodInfo). Logged with the DECODED values every
                // time, like 0x50 MET rather than once-per-kind: its cadence is a modest ~5 min and the
                // series is what the respiration ledger is reconstructed from, sample by sample.
                //
                // The record's `breath` field is also PERSISTED, and on a ring night it is what
                // `dailyMetric.respRateBpm` is scored from: anchored to its own ring-time and enqueued
                // exactly like the sibling banked streams (Hrv/Temp/Spo2), so a night's ~5-min windows
                // land where they were MEASURED and never at the drain-arrival moment. OuraStreamMapping
                // maps that ONE field onto a `respSample` row in milli-bpm; everything else in this record
                // stays here in the log. The logging is kept as well as the row: it covers records no
                // anchor can place, and it carries the fields the store deliberately does not.
                //
                // Twin of Swift's `.sleepPeriodInfo` log line, with one deliberate difference: Swift
                // prints a formatted clock time because that source already holds a formatter, and this
                // one holds none - the anchored epoch seconds correlate just as well, and adding a
                // formatter here only to match a log string would be the wrong kind of parity.
                val v = e.value
                val whenUtc = d.unixSeconds(forRingTimestamp = v.ringTimestamp)?.toString() ?: "no anchor yet"
                log(
                    "Oura: sleep_period (Tier-B) [$whenUtc] hr=${v.averageHrBpm} trend=${v.hrTrend} " +
                        "breath=${v.breathsPerMin} breathV=${v.breathVariability} " +
                        "motion=${v.motionCount} state=${v.sleepState}",
                )
                enqueueAnchoredOrPark(e, v.ringTimestamp, d)
            }
            is OuraEvent.MotionVectorEvent -> {
                // 0x47 averaged accel vector (Tier-A). Persisted as an OURA_MOTION event (same event-table
                // path as OURA_HRV / OURA_SLEEP_PHASE — see OuraStreamMapping), AND appended to the raw
                // calibration sidecar. Instrumentation only: never scored, never fed to the sleep stager
                // (0x47 is movement-gated, a shape mismatch for the gravity-stillness stager, #804). Anchor
                // per record so each window lands on a distinct (deviceId, ts, kind) row. Twin of Swift.
                d.unixSeconds(forRingTimestamp = e.value.ringTimestamp)?.let { utc ->
                    motionDump?.record(
                        ringTs = e.value.ringTimestamp, utc = utc, orientation = e.value.orientation,
                        motionSeconds = e.value.motionSeconds, x = e.value.avgX, y = e.value.avgY,
                        z = e.value.avgZ, lowIntensity = e.value.lowIntensity,
                        highIntensity = e.value.highIntensity,
                    )
                }
                enqueueAnchoredOrPark(e, e.value.ringTimestamp, d)
            }
            // Motion (0x6b) / debugText / etc: not a durable Streams row (see OuraStreamMapping). StateEvent
            // is handled above (wear badge only, also not a Streams row).
            else -> Unit
        }
    }

    /** Mirror the tracker's current wear/charge state to [ouraWearState], logging each TRANSITION once (a
     *  charger on/off or first pulse is worth a strap-log line; steady state is not). Twin of iOS
     *  `publishWearState`. */
    private fun publishWearState() {
        val s = wearTracker.current
        _ouraWearState.value = s
        if (s != loggedWearState) {
            loggedWearState = s
            when (s) {
                OuraWearState.WORN -> log("Oura: ring WORN - live HR streaming")
                OuraWearState.CHARGING -> log("Oura: ring NOT WORN - on charger (HR/IBI paused until removed)")
                OuraWearState.OFF -> log("Oura: ring NOT WORN - no live HR (removed / off charger)")
                OuraWearState.UNKNOWN -> Unit
            }
        }
    }

    /** Reset the wear indicator on a fresh session / disconnect: a stale worn/charging badge must not
     *  outlive the link. Twin of the iOS resets at connect/stop/disconnect. Posted to the main looper so
     *  the wear-tracker mutation stays single-threaded even when called from the GATT-thread disconnect
     *  handler — the queued reset lands in FIFO order relative to any pending live-pulse posts. */
    private fun resetWear() {
        handler.post {
            wearTracker.reset()
            loggedWearState = null
            lastLivePulseAt = null
            _ouraWearState.value = null
        }
    }

    /**
     * Stamp a history-fetched event with its ring-time-anchored UTC (s5.5) and enqueue it, or - when no
     * anchor has arrived yet this session - park it in [pendingAnchorEvents] to be re-stamped the moment
     * one lands (drained by a 0x42 time-sync, or with an honest wall-clock fallback at teardown). Kotlin
     * twin of the Swift `if let ts = driver.unixSeconds(...) { enqueue } else { pendingAnchorEvents.append }`
     * pattern repeated per history signal.
     */
    private fun enqueueAnchoredOrPark(event: OuraEvent, ringTimestamp: Long, d: OuraDriver) {
        val ts = d.unixSeconds(forRingTimestamp = ringTimestamp)
        if (ts != null) enqueue(listOf(event), ts.toInt()) else pendingAnchorEvents.add(event to ringTimestamp)
    }

    private fun handleBattery(pct: Int) = guardedCallback("battery") {
        if (pct !in 0..100) return@guardedCallback
        log("Oura: battery $pct%")
        _batteryPct.value = pct
        // Battery is NOT persisted as a stream row here: it carries no ring timestamp, and OuraStreamMapping
        // intentionally drops it (honest: no faked ts). It flows only via the live onBattery path, exactly
        // like the Swift twin.
        handler.post { guardedCallback("battery-sink") { onBattery(pct) } }
    }

    // MARK: - Live-HR re-engage scheduling

    private fun scheduleReengage() {
        if (reengageScheduled) return
        reengageScheduled = true
        handler.postDelayed(reengageRunnable, reengageIntervalMs)
    }

    private fun cancelReengage() {
        reengageScheduled = false
        handler.removeCallbacks(reengageRunnable)
    }

    // MARK: - Honest fallback

    /**
     * Record the honest "this ring needs a pairing handshake NOOP can't complete" outcome (the message is
     * already RECOVERY-HONEST: a factory-reset ring is NOT bricked, re-pairing in the Oura app brings it
     * back, and adopt is Beta). Also marks [AdoptPhase.Failed] so an in-flight adopt's Adopting step lands
     * on a REACHABLE honest Failed state, and clears any in-flight install key WITHOUT persisting it (a
     * failed install must never leave a wrongly-trusted key). We never claim a key was installed here.
     * Mirrors the Swift `announceNeedsPairing`.
     */
    private fun announceNeedsPairing(message: String) {
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = null
        _adoptPhase.value = AdoptPhase.Failed
        // This is an honest dead-end (no key / auth rejected / install failed), NOT a transient drop, so a
        // later disconnect must NOT auto-reconnect (that would loop the same auth failure and drain the
        // ring). Suppress it the same way a deliberate teardown does (#912); a user reconnect re-arms it.
        intentionalDisconnect = true
        reconnectAddress = null
        failedReconnectAttempts = 0
        if (_needsPairing.value != null) return
        _needsPairing.value = message
        log("Oura: $message")
    }

    /**
     * Run a GATT-callback body so a throw on the binder thread (or a posted main-thread block) can never
     * crash the app. BLE callbacks run outside any try/catch and outside the SourceCoordinator reconcile
     * guard, so an exception in a decode / live sink would otherwise crash the process - and because the
     * ring is the persisted active source, it would crash-LOOP on every launch (#421 regression). A
     * misbehaving ring must degrade to "no data", never take the app down. The message lands in the
     * exportable strap log. Mirrors [StandardHrSource.guardedCallback].
     */
    private fun guardedCallback(label: String, block: () -> Unit) {
        runCatching(block).onFailure {
            log("Oura: $label error (${it.javaClass.simpleName}: ${it.message})")
        }
    }

    companion object {
        /** The ring's base service + write/notify characteristics (OURA_PROTOCOL.md s1.1). Built from the
         *  protocol package's UUID strings so the facts live in exactly one place. */
        val SERVICE_UUID: UUID = UUID.fromString(OuraGatt.serviceUUID)
        val WRITE_UUID: UUID = UUID.fromString(OuraGatt.writeCharacteristicUUID)
        val NOTIFY_UUID: UUID = UUID.fromString(OuraGatt.notifyCharacteristicUUID)

        /** The standard client-characteristic-configuration descriptor (0x2902). */
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Android's infamous generic GATT connect failure (`BluetoothGatt.GATT_ERROR`, not a public
         *  constant). We auto-retry it once. */
        private const val GATT_ERROR_133 = 133

        /** Max self-chained drain passes per session (twin of Swift's maxChainedDrainPasses). */
        private const val MAX_CHAINED_DRAIN_PASSES = 6

        /** Per-session cap on individually-logged 0x71 records (twin of Swift's greenIbiAmpLogCap). */
        private const val GREEN_IBI_AMP_LOG_CAP = 50

        /** Bound on stashed 0x49 windows (twin of Swift's recentSleepWindows049Cap). */
        private const val RECENT_SLEEP_WINDOWS_049_CAP = 16

        /** Bound on the #1284 duplicate-generation window list (twin of Swift's). */
        private const val RECENT_PERSISTED_SESSIONS_CAP = 16

        /**
         * The 0x49 window in [windows] whose envelope ring-time is nearest [rt] and within [tolerance]
         * ticks, or null when none is in range. A drain can hold several windows (overnight + nap); each
         * burst must pair with its OWN, so match by ring-time proximity — keeping a single latest slot
         * mis-anchored the overnight burst to the nap's window when both finalized in one drain
         * (2026-07-17 capture). Pure + static so the pairing is unit-testable. Twin of Swift's
         * closestSleepWindow049.
         */
        internal fun closestSleepWindow049(
            windows: List<Triple<Long, Int, Int>>,
            rt: Long,
            tolerance: Long,
        ): Triple<Long, Int, Int>? {
            var best: Triple<Long, Int, Int>? = null
            var bestGap = Long.MAX_VALUE
            for (w in windows) {
                val gap = if (w.first >= rt) w.first - rt else rt - w.first
                if (gap <= tolerance && gap < bestGap) {
                    bestGap = gap
                    best = w
                }
            }
            return best
        }

        /** The SetAuthKey-response OUTER opcode (`0x25`) and its OK status byte (`0x00`). The ring replies
         *  `25 01 00` to a successful `0x24` key install (OURA_PROTOCOL.md s3.2). */
        private const val SET_AUTH_KEY_RESP_OP = 0x25

        /** Outer-frame ops a GetProductInfo (`0x18`) reply can arrive under. The request op is `0x18`; by the
         *  request→response +1 convention (GetBattery `0x0C` request → `0x0D` reply) it may be `0x19`. Both are
         *  captured so the #771/#772 fixture lands whatever the firmware uses. Twin of Swift's
         *  `productInfoResponseOps`. Neither is an event tag (tags are ≥ 0x41), so peeking never disturbs the
         *  TLV decode. */
        private val PRODUCT_INFO_RESPONSE_OPS = setOf(0x18, 0x19)

        /** A GetProductInfo string is a usable ring SERIAL only when it is plain alphanumeric and a sane
         *  length, so a misframed reply can never mint a bogus `oura-<serial>` id (#771 honest-data guard).
         *  Twin of Swift's `isPlausibleSerial`. */
        private fun isPlausibleSerial(s: String): Boolean =
            s.length in 8..24 && s.all { it.isLetterOrDigit() }
        private const val SET_AUTH_KEY_OK = 0x00

        /** Generate a fresh cryptographically-random 16-byte install key as unsigned bytes 0..255
         *  (OURA_PROTOCOL.md s3.2 step 1). [java.security.SecureRandom] is the platform CSPRNG. */
        private fun secureRandom16(): IntArray {
            val bytes = ByteArray(OuraAuth.keyLength)
            SecureRandom().nextBytes(bytes)
            return IntArray(OuraAuth.keyLength) { bytes[it].toInt() and 0xFF }
        }

        /**
         * Honest fallback copy: live data is not available, AND the ring is RECOVERABLE. A factory-reset
         * ring is not bricked: re-pairing it in the Oura app sets it up again. NOOP adopt is Beta and may
         * not succeed on every ring or firmware yet. No "installing key" wording (no install ran here).
         */
        private const val KEY_INSTALL_MESSAGE =
            "NOOP couldn't pair with this Oura ring. Live data isn't available. The ring is not damaged: " +
                "re-pair it in the Oura app to set it up again. NOOP adopt is Beta and may not work on " +
                "every ring or firmware yet. You can also export from the Oura app and use file import."

        /** Honest fallback copy: a key IS installed but it does not match this ring. Same recovery note. */
        private const val AUTH_FAILED_MESSAGE =
            "This Oura ring rejected the stored pairing key. Live data isn't available. The ring is not " +
                "damaged: re-pair it in the Oura app to set it up again, or export from the Oura app and " +
                "use file import."
    }
}

// MARK: - Oura GetEvents cursor persistence

/**
 * Persists the Oura `GetEvents` cursor (OURA_PROTOCOL.md s5.1/5.3) per ring, so a later connection
 * resumes from where the last session left off instead of re-fetching the ring's entire banked history on
 * every single connect. Kotlin twin of Swift's `OuraHistoryCursorStore` (which uses `UserDefaults`).
 *
 * Unlike [OuraInstallKeyStore] this is NOT sensitive - it's an opaque ring-clock tick counter, not a
 * credential - so plain [SharedPreferences] is the right (and simplest) store (no EncryptedSharedPreferences
 * / keystore round-trip). The cursor is the unsigned 32-bit ring timestamp; it is stored as a Long (the JVM
 * has no unsigned int) so the full 0..0xFFFFFFFF range survives a round-trip.
 */
object OuraHistoryCursorStore {
    private const val FILE_NAME = "noop_oura_history_cursor"
    private const val KEY_PREFIX = "history_cursor_"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    private fun prefKey(deviceId: String) = "$KEY_PREFIX$deviceId"

    /** The persisted cursor for [deviceId], or 0 (fetch everything) if none is stored yet. Clamped to the
     *  unsigned-32 range so a corrupt/negative stored value can never drive a malformed GetEvents request. */
    fun read(ctx: Context, deviceId: String): Long {
        val raw = runCatching { prefs(ctx).getLong(prefKey(deviceId), 0L) }.getOrDefault(0L)
        return raw.coerceIn(0L, 0xFFFF_FFFFL)
    }

    /** Store the advanced cursor for [deviceId]. */
    fun save(ctx: Context, deviceId: String, cursor: Long) {
        runCatching { prefs(ctx).edit().putLong(prefKey(deviceId), cursor and 0xFFFF_FFFFL).apply() }
    }
}
