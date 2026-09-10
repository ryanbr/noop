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
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.noop.data.HrRow
import com.noop.data.StreamBatch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * EXPERIMENTAL, ISOLATED live-BLE source for the Huami family — Amazfit / Zepp (incl. Helio ring/band)
 * and Xiaomi Mi Band.
 *
 * Faithful Kotlin twin of Strand/BLE/HuamiHRSource.swift.
 *
 * "EXPERIMENTAL, HELP US TEST": best-effort, clean-room driver built from PUBLICLY DOCUMENTED protocol
 * FACTS (open projects document the Huami GATT layout; we reuse only the facts and wrote our own code —
 * no GPL/AGPL code copied). Shipped behind the experimental add-device tier because it can't be
 * hardware-verified here. It NEVER fabricates data: if it can't read a real HR it stays at "—".
 *
 * WHOOP-FIRST ISOLATION (identical to [StandardHrSource]): own scan + [BluetoothGatt], never touches
 * [WhoopBleClient]. Shared surfaces are injected closures: [liveSink], [persist], [log], [onBattery].
 *
 * HR strategy, honest at each step:
 *   1. Prefer the STANDARD SIG Heart Rate Service (0x180D / 0x2A37) — newer bands expose it; identical to
 *      [StandardHrSource]. Decoded via [StandardHeartRate].
 *   2. Else the documented Huami custom HR-measurement characteristic (on the Huami 0xFEE0 service). Many
 *      bands expose live HR here with NO auth handshake. Decoded via [HuamiHeartRate].
 *   3. If NEITHER is readable (the band needs the Huami auth pairing we don't implement), publish an
 *      HONEST message via [needsPairing] and stay disconnected from data — never fake a reading.
 *
 * Android runtime-permission notes (same contract as [WhoopBleClient]/[StandardHrSource]): the caller
 * must hold BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect].
 */
@SuppressLint("MissingPermission")
class HuamiHrSource(
    context: Context,
    /** Datastore device id every sample is stamped with (the active Huami device's registry id). */
    private val deviceId: String,
    /** Push live HR (bpm) into whatever the UI observes. Called on the main looper. */
    private val liveSink: (hr: Int) -> Unit,
    /** Persist a batch under [deviceId] — wired to `repository.insert`. */
    private val persist: (StreamBatch, String) -> Unit = { _, _ -> },
    /** Diagnostic sink for the connect lifecycle — the SAME exportable strap log (issue #421). Every line
     *  is prefixed "Huami: " so it's distinguishable in the shared log. Default no-op keeps tests silent. */
    private val log: (String) -> Unit = {},
    /** Fired with the band's battery percent (0–100) when read off 0x2A19. */
    private val onBattery: (Int) -> Unit = {},
) : LiveHrSource {

    /** A Huami-family device seen during a scan (UI affordance). */
    data class DiscoveredDevice(val address: String, val name: String, val rssi: Int)

    private val _discovered = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val discovered: StateFlow<List<DiscoveredDevice>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

    private val _needsPairing = MutableStateFlow<String?>(null)
    /** Set to an HONEST explanation when the band needed the Huami auth pairing we can't do (no standard
     *  HR service AND no readable Huami HR characteristic). null otherwise; cleared on stop/disconnect. */
    val needsPairing: StateFlow<String?> = _needsPairing.asStateFlow()

    // MARK: - Android Bluetooth handles (OWN scanner + GATT, separate from WHOOP)

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    private var pendingConnectAddress: String? = null
    private var lastDevice: BluetoothDevice? = null
    private var retried133 = false
    private var loggedFirstHr = false

    private val handler = Handler(Looper.getMainLooper())

    // MARK: - Sample buffer

    private data class Sample(val hr: Int, val ts: Long)
    private val bufferLock = Any()
    private val buffer = ArrayList<Sample>()
    private var lastFlushMs = System.currentTimeMillis()
    private val flushCount = 30
    private val flushIntervalMs = 30_000L

    // MARK: - Scanning

    /**
     * Scan for Huami-family devices. We can't filter by one service (some advertise 0x180D, some the Huami
     * 0xFEE0, some neither), so scan broadly and keep only the ones whose advertised name reads as an
     * Amazfit / Zepp / Mi Band ([ExperimentalBrand]).
     */
    override fun scan() {
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        _needsPairing.value = null
        log("Huami: scanning for Amazfit / Zepp / Mi Band devices…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("Huami: no BLE scanner available — Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("Huami: Bluetooth adapter is off — cannot scan")
            return
        }
        // No ScanFilter (broad scan); the callback filters by recognised name.
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        sc.startScan(null, settings, scanCallback)
    }

    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    override fun connect(address: String) {
        stopScan()
        _needsPairing.value = null
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) { pendingConnectAddress = address; return }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        lastDevice = device
        log("Huami: connecting to ${device.address}")
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            log("Huami: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
            null
        }
    }

    override fun stop() {
        stopScan()
        pendingConnectAddress = null
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
        loggedFirstHr = false
        _batteryPct.value = null
        flush()
    }

    // MARK: - Buffer / persistence

    private fun enqueue(hr: Int) {
        val shouldFlush = synchronized(bufferLock) {
            buffer.add(Sample(hr, System.currentTimeMillis() / 1000L))
            buffer.size >= flushCount || System.currentTimeMillis() - lastFlushMs >= flushIntervalMs
        }
        if (shouldFlush) flush()
    }

    private fun flush() {
        val snapshot = synchronized(bufferLock) {
            lastFlushMs = System.currentTimeMillis()
            if (buffer.isEmpty()) return
            val s = ArrayList(buffer); buffer.clear(); s
        }
        // HR-only (no R-R on the Huami custom char). Same range gate the standard path uses.
        val hrRows = ArrayList<HrRow>()
        for (s in snapshot) if (s.hr in 30..220) hrRows.add(HrRow(s.ts, s.hr))
        if (hrRows.isNotEmpty()) persist(StreamBatch(hr = hrRows, rr = emptyList()), deviceId)
    }

    private fun ingest(hr: Int) {
        if (hr !in 30..220) return   // out of range → dropped, never shown / persisted
        if (!loggedFirstHr) {
            loggedFirstHr = true
            log("Huami: receiving data — first sample $hr bpm")
        }
        handler.post { guarded("live-sink") { liveSink(hr) } }
        enqueue(hr)
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
            // Keep only recognised Amazfit / Zepp / Mi Band devices — a broad scan sees everything nearby.
            val brand = ExperimentalBrand.recognise(name)
            if (brand != ExperimentalBrand.AMAZFIT && brand != ExperimentalBrand.MI_BAND) return
            val firstSight = seen.put(address, device) == null
            if (firstSight) log("Huami: found ${logSafeDeviceName(name)} ($address) rssi ${result.rssi}")
            val dev = DiscoveredDevice(
                address = address,
                name = name.ifBlank { brand.displayBrand },
                rssi = result.rssi,
            )
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = dev else list.add(dev)
            _discovered.value = list
            if (pendingConnectAddress == address) {
                pendingConnectAddress = null
                handler.post { connectToDevice(device) }
            }
        }
    }

    // MARK: - GATT callback

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = guarded("connection-state") {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    retried133 = false
                    log("Huami: connected (status=$status) — discovering services")
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    log("Huami: disconnected (status=$status)")
                    loggedFirstHr = false
                    _batteryPct.value = null
                    flush()
                    if (gatt === g) { runCatching { g.close() }; gatt = null }
                    if (status == GATT_ERROR_133) {
                        val device = lastDevice
                        if (!retried133 && device != null) {
                            retried133 = true
                            log("Huami: connect error 133 — retrying once in 1s")
                            handler.postDelayed({ connectToDevice(device) }, 1000)
                        } else {
                            log("Huami: still failing (133) — try forgetting the band in Android " +
                                "Settings → Bluetooth, then re-pair.")
                        }
                    }
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = guarded("services-discovered") {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Huami: WARNING service discovery failed (status=$status) — giving up on this band")
                return@guarded
            }
            val stdSvc = g.getService(STD_HEART_RATE_SERVICE)
            val huamiSvc = g.getService(HUAMI_SERVICE)
            when {
                stdSvc != null -> {
                    log("Huami: standard 0x180D heart-rate service FOUND — using it (preferred)")
                    val ch = stdSvc.getCharacteristic(STD_HEART_RATE_CHAR)
                    if (ch != null) enableNotify(g, ch) else announceNeedsPairing()
                }
                huamiSvc != null -> {
                    log("Huami: no standard 0x180D — trying the documented Huami custom HR characteristic")
                    val ch = huamiSvc.getCharacteristic(HUAMI_HEART_RATE_CHAR)
                    if (ch != null && ch.canNotify()) enableNotify(g, ch) else announceNeedsPairing()
                }
                else -> announceNeedsPairing()  // neither HR service → needs the Huami auth pairing
            }
            // Battery (0x2A19): read once if present.
            val batt = g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)
            if (batt != null) {
                log("Huami: 0x180F battery service found — reading level")
                runCatching { g.readCharacteristic(batt) }
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != CCCD) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                log("Huami: notifications enabled (CCCD write status=$status)")
            } else {
                // The band refused the subscription — almost always the Huami auth gate. Be honest.
                log("Huami: WARNING CCCD write FAILED (status=$status) — band may need pairing we can't do")
                announceNeedsPairing()
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            handleHr(ch.uuid, value)
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            handleHr(ch.uuid, ch.value ?: return)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            if (ch.uuid == BATTERY_CHAR && status == BluetoothGatt.GATT_SUCCESS) handleBattery(value)
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            if (ch.uuid == BATTERY_CHAR && status == BluetoothGatt.GATT_SUCCESS) handleBattery(ch.value ?: return)
        }
    }

    private fun BluetoothGattCharacteristic.canNotify(): Boolean =
        properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 ||
            properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0

    private fun enableNotify(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
        loggedFirstHr = false
        g.setCharacteristicNotification(ch, true)
        val cccd = ch.getDescriptor(CCCD) ?: run {
            log("Huami: WARNING ${ch.uuid} has no CCCD (0x2902) — cannot enable notifications")
            announceNeedsPairing()
            return
        }
        log("Huami: enabling notifications on ${if (ch.uuid == STD_HEART_RATE_CHAR) "standard" else "Huami"} HR characteristic")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                g.writeDescriptor(cccd)
            }
        }
    }

    /** Run a GATT-callback body so a throw on the binder thread can never crash the app (mirrors
     *  [StandardHrSource.guardedCallback]). */
    private fun guarded(label: String, block: () -> Unit) {
        runCatching(block).onFailure { log("Huami: $label error (${it.javaClass.simpleName}: ${it.message})") }
    }

    private fun handleBattery(data: ByteArray) = guarded("battery-parse") {
        val pct = StandardBattery.parse(data) ?: return@guarded
        log("Huami: battery $pct%")
        _batteryPct.value = pct
        handler.post { guarded("battery-sink") { onBattery(pct) } }
    }

    private fun handleHr(uuid: UUID, data: ByteArray) = guarded("hr-parse") {
        val hr = when (uuid) {
            STD_HEART_RATE_CHAR -> StandardHeartRate.parse(data)?.hr   // standard 0x2A37 layout
            HUAMI_HEART_RATE_CHAR -> HuamiHeartRate.parse(data)        // Huami custom layout
            else -> return@guarded
        } ?: return@guarded                                            // no usable reading → "—", never faked
        ingest(hr)
    }

    private fun announceNeedsPairing() {
        if (_needsPairing.value != null) return
        val msg = "This band needs a pairing handshake NOOP can't do yet. Live data isn't available - try " +
            "exporting from the Zepp app and importing the file instead."
        _needsPairing.value = msg
        log("Huami: $msg")
    }

    companion object {
        /** Standard SIG Heart Rate service / measurement (preferred when present). */
        val STD_HEART_RATE_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        val STD_HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")

        /** Documented Huami custom HR service + measurement characteristic (128-bit). FACTS only. */
        val HUAMI_SERVICE: UUID = UUID.fromString("0000fee0-0000-1000-8000-00805f9b34fb")
        val HUAMI_HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-3512-2118-0009af100700")

        private val BATTERY_SERVICE: UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_CHAR: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        private const val GATT_ERROR_133 = 133
    }
}
