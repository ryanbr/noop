package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Re-broadcasts NOOP's LIVE heart rate back OUT as a standard Bluetooth Heart Rate peripheral, so a gym
 * treadmill, Zwift, Peloton, a bike computer, or any fitness app can read the WHOOP HR that NOOP is
 * already receiving off the strap. It runs a [BluetoothGattServer] hosting the standard Heart Rate
 * Service (0x180D) with the Heart Rate Measurement characteristic (0x2A37), and a [BluetoothLeAdvertiser]
 * advertising 0x180D, notifying 0x2A37 with the SIG-spec flags + bpm encoding whenever NOOP has a fresh
 * live HR sample.
 *
 * Faithful Kotlin twin of Strand/BLE/HrBroadcaster.swift.
 *
 * OFFLINE, OPT-IN, ADDITIVE
 * -------------------------
 * LOCAL Bluetooth only — nothing leaves the device to any cloud or server. It just re-shares the strap's
 * HR to nearby gym kit over a standard BLE profile, which fits NOOP's offline ethos. OFF by default; it
 * only runs while the user has the "Broadcast heart rate" toggle on (persisted by NoopPrefs).
 *
 * WHOOP-FIRST ISOLATION: this class runs its OWN advertiser + GATT server and never imports, calls, or
 * shares state with [WhoopBleClient] / [StandardHrSource] / [SourceCoordinator]. It is a pure CONSUMER of
 * whatever live HR the app already has — the input arrives via [update]. It writes nothing back into the
 * WHOOP path, so the strap connection, scoring, and history offload cannot regress. The pure 0x2A37
 * measurement *encoder* is [measurement], unit-tested away from android.bluetooth.
 *
 * Android runtime-permission notes (Android 12+ / API 31): advertising requires BLUETOOTH_ADVERTISE and
 * the GATT server requires BLUETOOTH_CONNECT — the caller (the Compose layer) must request them before
 * [start]. Every android.bluetooth call is @SuppressLint("MissingPermission") (the caller owns the grant)
 * AND wrapped so a missing/revoked permission degrades to a status note, never a crash.
 */
@SuppressLint("MissingPermission")
class HrBroadcaster(
    context: Context,
    /** Diagnostic sink for the broadcast lifecycle, wired to the SAME exportable strap log if desired.
     *  Every line is prefixed "HR-out: " so it's distinguishable from the WHOOP and HR-strap lines.
     *  Default no-op keeps existing call sites + tests silent. */
    private val log: (String) -> Unit = {},
) {

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter get() = bluetoothManager?.adapter
    private val advertiser: BluetoothLeAdvertiser? get() = adapter?.bluetoothLeAdvertiser

    private val handler = Handler(Looper.getMainLooper())

    private var gattServer: BluetoothGattServer? = null
    private var hrCharacteristic: BluetoothGattCharacteristic? = null

    /** Centrals (gym kit / apps) currently subscribed to 0x2A37 notifications, keyed by address. */
    private val subscribers = ConcurrentHashMap<String, BluetoothDevice>()

    /** True once [start] was called and we want to be advertising; gates auto-restart on radio events.
     *  @Volatile: set on the caller/main thread, read on the BLE binder callback + radio-receiver threads. */
    @Volatile
    private var wantAdvertising = false
    /** The most recent live HR pushed in, re-sent to a central that subscribes mid-session so a newly
     *  connected machine shows a value at once. null until the first sample; cleared on stop.
     *  @Volatile: written by [update] (LiveState collector) and read in [onDescriptorWriteRequest] (binder). */
    @Volatile
    private var lastBpm: Int? = null

    /** True once [bluetoothStateReceiver] is registered, so a repeat [start] never double-registers
     *  (which would later throw on a single unregister). */
    private var radioReceiverRegistered = false

    /**
     * Watches the OS Bluetooth radio so the broadcast SURVIVES a toggle (the auto-restart [wantAdvertising]
     * gates): STATE_ON re-opens the server + re-advertises when the user's toggle is still on; STATE_OFF
     * drops the now-dead server handles so the next open rebuilds cleanly. Without this the advertiser
     * stayed down after a radio off->on cycle until the user manually re-toggled the setting. Scoped
     * ENTIRELY to the broadcast (WHOOP-first isolation: it never touches the WHOOP path). iOS gets this
     * free from CBPeripheralManager's state delegate.
     *
     * Credit: ryanbr (pre-fork #1029 — that number is not this repo's).
     */
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> onRadioOff()
                BluetoothAdapter.STATE_ON -> onRadioOn()
            }
        }
    }

    private val _advertising = MutableStateFlow(false)
    /** True while the advertiser is running (the radio is on and [start] succeeded). */
    val advertising: StateFlow<Boolean> = _advertising.asStateFlow()

    private val _subscriberCount = MutableStateFlow(0)
    /** How many centrals are subscribed to 0x2A37 right now. 0 = advertising but nothing connected yet. */
    val subscriberCount: StateFlow<Int> = _subscriberCount.asStateFlow()

    private val _statusNote = MutableStateFlow<String?>(null)
    /** A human-readable reason the broadcast can't run (Bluetooth off / no permission), or null when fine.
     *  No em-dashes, US-neutral. Surfaced under the toggle so a silent no-op is never a mystery. */
    val statusNote: StateFlow<String?> = _statusNote.asStateFlow()

    // MARK: - Lifecycle

    /**
     * Begin acting as a standard HR peripheral: open the GATT server, publish the 0x180D service, and
     * start advertising 0x180D. Idempotent. Degrades to a [statusNote] (never a crash) if Bluetooth is
     * off, unsupported, or the runtime permission was revoked.
     */
    fun start() {
        wantAdvertising = true
        _statusNote.value = null
        // Listen for the radio toggling BEFORE the adapter check, so enabling the broadcast while
        // Bluetooth is off still auto-starts the instant the radio comes back. Idempotent (guarded).
        registerRadioReceiver()

        val ad = adapter
        if (ad == null || !ad.isEnabled) {
            _advertising.value = false
            _statusNote.value = "Bluetooth is off. Turn it on to broadcast your heart rate."
            log("HR-out: Bluetooth adapter off or unavailable, cannot broadcast")
            return
        }
        if (ad.bluetoothLeAdvertiser == null) {
            _advertising.value = false
            _statusNote.value = "This device can't broadcast Bluetooth heart rate."
            log("HR-out: no BLE advertiser, peripheral mode unsupported on this device")
            return
        }

        if (!openServer()) return
        startAdvertising()
    }

    /**
     * Stop advertising, close the GATT server, and clear all state. Idempotent. A stale HR is cleared so
     * a later restart never re-emits an old value.
     */
    fun stop() {
        wantAdvertising = false
        lastBpm = null
        subscribers.clear()
        _subscriberCount.value = 0
        runCatching { advertiser?.stopAdvertising(advertiseCallback) }
        runCatching { gattServer?.close() }
        gattServer = null
        hrCharacteristic = null
        _advertising.value = false
        if (radioReceiverRegistered) {
            runCatching { appContext.unregisterReceiver(bluetoothStateReceiver) }
            radioReceiverRegistered = false
        }
    }

    /** Register [bluetoothStateReceiver] once so radio toggles auto-restart the broadcast. Guarded so a
     *  repeat [start] can't stack registrations (which would throw on the single [stop] unregister). */
    private fun registerRadioReceiver() {
        if (radioReceiverRegistered) return
        runCatching {
            ContextCompat.registerReceiver(
                appContext,
                bluetoothStateReceiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }.onSuccess { radioReceiverRegistered = true }
    }

    /** Radio down: the OS already tore down our advertiser + GATT server, so drop the now-dead handles
     *  (nulling them so a later [openServer] REBUILDS instead of short-circuiting on the stale ref) and
     *  reset live state. [wantAdvertising] is KEPT so [onRadioOn] auto-resumes. Idempotent across
     *  TURNING_OFF then OFF. */
    private fun onRadioOff() {
        runCatching { advertiser?.stopAdvertising(advertiseCallback) }
        runCatching { gattServer?.close() }
        gattServer = null
        hrCharacteristic = null
        subscribers.clear()
        _subscriberCount.value = 0
        _advertising.value = false
        _statusNote.value = "Bluetooth is off. Turn it on to broadcast your heart rate."
        log("HR-out: Bluetooth radio off, broadcast paused (resumes when it returns)")
    }

    /** Radio back: if the user still wants to broadcast, rebuild via the idempotent [start] path (which
     *  re-checks the adapter, re-opens the server, re-advertises, and no-ops the receiver registration). */
    private fun onRadioOn() {
        if (wantAdvertising) {
            log("HR-out: Bluetooth radio on, resuming broadcast")
            start()
        }
    }

    /**
     * Feed a live HR sample (bpm) to broadcast. null (no current reading) sends nothing — we never invent
     * a value. A non-physiological bpm is dropped so untrusted/garbage input can't be re-broadcast.
     */
    fun update(bpm: Int?) {
        if (!wantAdvertising || bpm == null || bpm < 20 || bpm > 255) return
        lastBpm = bpm
        handler.post { notify(bpm) }
    }

    // MARK: - GATT server + advertising

    private fun openServer(): Boolean {
        if (gattServer != null) return true
        val server = runCatching {
            bluetoothManager?.openGattServer(appContext, gattServerCallback)
        }.getOrElse {
            log("HR-out: openGattServer failed (${it.javaClass.simpleName}: ${it.message})")
            null
        }
        if (server == null) {
            _statusNote.value = "Couldn't start the heart-rate broadcast. Check Bluetooth permission."
            return false
        }
        val characteristic = BluetoothGattCharacteristic(
            HEART_RATE_CHAR,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        // The CCCD (0x2902) a central writes to subscribe to notifications.
        characteristic.addDescriptor(
            BluetoothGattDescriptor(
                CCCD,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        val service = BluetoothGattService(HEART_RATE_SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(characteristic)
        val added = runCatching { server.addService(service) }.getOrDefault(false)
        if (added != true) {
            log("HR-out: addService(0x180D) failed")
            runCatching { server.close() }
            _statusNote.value = "Couldn't publish the heart-rate service."
            return false
        }
        gattServer = server
        hrCharacteristic = characteristic
        log("HR-out: GATT server up, 0x180D / 0x2A37 published")
        return true
    }

    private fun startAdvertising() {
        val adv = advertiser ?: run {
            _statusNote.value = "This device can't broadcast Bluetooth heart rate."
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()
        // Keep the advertisement small: the 16-bit service UUID fits the 31-byte primary packet; the
        // friendly name rides the scan response so the UUID is never crowded out.
        val data = AdvertiseData.Builder()
            .setIncludeTxPowerLevel(false)
            .addServiceUuid(ParcelUuid(HEART_RATE_SERVICE))
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()
        runCatching { adv.startAdvertising(settings, data, scanResponse, advertiseCallback) }
            .onFailure {
                log("HR-out: startAdvertising threw (${it.javaClass.simpleName}: ${it.message})")
                _statusNote.value = "Couldn't start broadcasting. Check Bluetooth permission."
            }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            _advertising.value = true
            _statusNote.value = null
            log("HR-out: advertising 0x180D heart-rate service")
        }

        override fun onStartFailure(errorCode: Int) {
            // ALREADY_STARTED means we ARE advertising — e.g. a redundant restart from a spurious STATE_ON
            // while the broadcast was already up. Treat it as success so the state + note don't flip to a
            // false error while we're actually broadcasting.
            if (errorCode == ADVERTISE_FAILED_ALREADY_STARTED) {
                _advertising.value = true
                _statusNote.value = null
                return
            }
            _advertising.value = false
            _statusNote.value = when (errorCode) {
                ADVERTISE_FAILED_FEATURE_UNSUPPORTED ->
                    "This device can't broadcast Bluetooth heart rate."
                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS ->
                    "Too many Bluetooth broadcasts are running. Try again in a moment."
                else -> "Couldn't start the heart-rate broadcast (error $errorCode)."
            }
            log("HR-out: advertise failed (code=$errorCode)")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            // A clean disconnect must drop the central from the subscriber set so the count stays honest.
            if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (subscribers.remove(device.address) != null) {
                    _subscriberCount.value = subscribers.size
                }
            }
        }

        // A central reading the CCCD before subscribing (some stacks do): report notifications disabled
        // until it writes ENABLE_NOTIFICATION_VALUE.
        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor,
        ) {
            if (descriptor.uuid == CCCD) {
                runCatching {
                    gattServer?.sendResponse(
                        device, requestId, android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset,
                        BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE,
                    )
                }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (descriptor.uuid == CCCD) {
                val enable = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                if (enable) {
                    if (subscribers.put(device.address, device) == null) {
                        _subscriberCount.value = subscribers.size
                        log("HR-out: a central subscribed (now ${subscribers.size})")
                    }
                } else {
                    if (subscribers.remove(device.address) != null) {
                        _subscriberCount.value = subscribers.size
                    }
                }
                if (responseNeeded) {
                    runCatching {
                        gattServer?.sendResponse(
                            device, requestId, android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset, value,
                        )
                    }
                }
                // Push the latest reading immediately so a freshly subscribed machine shows a value at once.
                if (enable) lastBpm?.let { handler.post { notifyDevice(device, it) } }
            } else if (responseNeeded) {
                runCatching {
                    gattServer?.sendResponse(
                        device, requestId, android.bluetooth.BluetoothGatt.GATT_SUCCESS, offset, value,
                    )
                }
            }
        }
    }

    // MARK: - Notify

    /** Send a 0x2A37 measurement to every subscribed central. */
    private fun notify(bpm: Int) {
        val server = gattServer ?: return
        val ch = hrCharacteristic ?: return
        val payload = measurement(bpm)
        for (device in subscribers.values) {
            sendNotification(server, ch, device, payload)
        }
    }

    /** Send a 0x2A37 measurement to one specific central (the just-subscribed case). */
    private fun notifyDevice(device: BluetoothDevice, bpm: Int) {
        val server = gattServer ?: return
        val ch = hrCharacteristic ?: return
        sendNotification(server, ch, device, measurement(bpm))
    }

    private fun sendNotification(
        server: BluetoothGattServer,
        ch: BluetoothGattCharacteristic,
        device: BluetoothDevice,
        payload: ByteArray,
    ) {
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // API 33+ takes the value as a parameter and returns a status code.
                server.notifyCharacteristicChanged(device, ch, false, payload)
            } else {
                @Suppress("DEPRECATION")
                run {
                    ch.value = payload
                    server.notifyCharacteristicChanged(device, ch, false)
                }
            }
        }
    }

    companion object {
        /** Standard BLE Heart Rate service + measurement characteristic + the CCCD. */
        val HEART_RATE_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /**
         * Encode one Bluetooth SIG Heart Rate Measurement (0x2A37) payload for a given bpm.
         *
         * Layout (the inverse of [StandardHeartRate.parse]): a flags byte then the HR value.
         *   - flags bit0 = 0 → HR is a single u8 byte (emitted for any bpm < 256);
         *   - flags bit0 = 1 → HR is u16 little-endian (only for an out-of-range bpm >= 256).
         * Bit3 (Energy Expended) and bit4 (R-R) are never set — NOOP broadcasts a plain instantaneous HR.
         * The bpm is clamped to a non-negative 16-bit range so a stray value can't overflow the encoding.
         */
        fun measurement(bpm: Int): ByteArray {
            val clamped = bpm.coerceIn(0, 0xFFFF)
            return if (clamped < 256) {
                byteArrayOf(0x00, clamped.toByte())                                   // flags=0 (u8 HR)
            } else {
                byteArrayOf(0x01, (clamped and 0xFF).toByte(), ((clamped shr 8) and 0xFF).toByte()) // u16 LE
            }
        }
    }
}
