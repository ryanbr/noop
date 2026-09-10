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
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * An ISOLATED standard-Bluetooth source for FTMS gym equipment — a treadmill, indoor bike, rower, or
 * cross-trainer exposing the Fitness Machine Service (0x1826) with one of the machine-data
 * characteristics (Treadmill 0x2ACD, Indoor Bike 0x2AD2, Rower 0x2AD1, Cross Trainer 0x2ACE).
 *
 * Faithful Kotlin twin of Strand/BLE/FTMSSource.swift. WHOOP-FIRST ISOLATION (identical to
 * [StandardHrSource]): own scan + [BluetoothGatt], never touches [WhoopBleClient]. The shared surfaces
 * are injected closures: [liveSink] (machine HR → the live UI + the existing live-workout recorder),
 * [onBattery] (the machine's 0x180F battery), [log] (the exportable strap log). The pure FTMS field
 * decode lives in [FitnessMachine] so it's JVM-unit-tested away from android.bluetooth.
 *
 * RECORDING: no new scoring loop. HR (when the machine reports it) rides [liveSink] exactly like
 * [StandardHrSource], so a machine session is recorded by the EXISTING manual live-workout flow
 * ([AppViewModel.startWorkout]/[endWorkout] → StrainScorer → Effort). The machine metrics (speed,
 * cadence, power, distance, energy) are surfaced live via [latest] and logged.
 *
 * Android runtime-permission notes (same contract as [WhoopBleClient]/[StandardHrSource]): the caller
 * must hold BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect].
 */
@SuppressLint("MissingPermission")
class FtmsSource(
    context: Context,
    /** Push the machine's live HR (bpm) into whatever the UI / recorder observe. Called on the main looper. */
    private val liveSink: (hr: Int) -> Unit,
    /** Push the machine's latest decoded reading into the in-exercise UI. Called on the main looper. */
    private val readingSink: (FitnessMachine.Reading) -> Unit = {},
    /** Fired with the machine's battery percent (0–100) when read off 0x2A19. */
    private val onBattery: (Int) -> Unit = {},
    /** Diagnostic sink for the connect lifecycle — the SAME exportable strap log (issue #421). Every line
     *  is prefixed "FTMS: " so it's distinguishable in the shared log. Default no-op keeps tests silent. */
    private val log: (String) -> Unit = {},
) : LiveHrSource {

    /** An FTMS machine seen during a scan (UI affordance). */
    data class DiscoveredMachine(val address: String, val name: String, val rssi: Int)

    private val _discovered = MutableStateFlow<List<DiscoveredMachine>>(emptyList())
    val discovered: StateFlow<List<DiscoveredMachine>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _latest = MutableStateFlow<FitnessMachine.Reading?>(null)
    /** The most recently decoded machine-data reading, for the live in-exercise readout; null until the
     *  first notification and after disconnect (a stale panel must not outlive the link). */
    val latest: StateFlow<FitnessMachine.Reading?> = _latest.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    /** The connected machine's 0x180F battery level, 0–100, if exposed; null otherwise / after disconnect. */
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

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
    private var loggedFirstReading = false

    private val handler = Handler(Looper.getMainLooper())

    // MARK: - Scanning

    /** Begin scanning for FTMS machines advertising the 0x1826 service. */
    override fun scan() {
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        log("FTMS: scanning for gym equipment (0x1826)…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("FTMS: no BLE scanner available — Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("FTMS: Bluetooth adapter is off — cannot scan")
            return
        }
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(FITNESS_MACHINE_SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        sc.startScan(listOf(filter), settings, scanCallback)
    }

    /** Stop an in-progress scan. Idempotent. */
    fun stopScan() {
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    /** Connect to the chosen machine (by address) and start streaming its machine data. */
    override fun connect(address: String) {
        stopScan()
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) { pendingConnectAddress = address; return }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        lastDevice = device
        log("FTMS: connecting to ${device.address}")
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            log("FTMS: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
            null
        }
    }

    /** Tear down: cancel the connection and stop scanning. Idempotent. */
    override fun stop() {
        stopScan()
        pendingConnectAddress = null
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
        loggedFirstReading = false
        _latest.value = null
        _batteryPct.value = null
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val address = device.address ?: return
            val firstSight = seen.put(address, device) == null
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull()
                ?: "Gym Equipment"
            if (firstSight) log("FTMS: found ${logSafeDeviceName(name)} ($address) rssi ${result.rssi}")
            val machine = DiscoveredMachine(address = address, name = name, rssi = result.rssi)
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = machine else list.add(machine)
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
                    log("FTMS: connected (status=$status) — discovering services")
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    log("FTMS: disconnected (status=$status)")
                    loggedFirstReading = false
                    _latest.value = null
                    _batteryPct.value = null
                    if (gatt === g) { runCatching { g.close() }; gatt = null }
                    if (status == GATT_ERROR_133) {
                        val device = lastDevice
                        if (!retried133 && device != null) {
                            retried133 = true
                            log("FTMS: connect error 133 — retrying once in 1s")
                            handler.postDelayed({ connectToDevice(device) }, 1000)
                        } else {
                            log("FTMS: still failing (133) — try forgetting the machine in Android " +
                                "Settings → Bluetooth, then re-pair.")
                        }
                    }
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = guarded("services-discovered") {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("FTMS: WARNING service discovery failed (status=$status) — giving up on this machine")
                return@guarded
            }
            val svc = g.getService(FITNESS_MACHINE_SERVICE)
            if (svc == null) {
                log("FTMS: 0x1826 service NOT FOUND — this device isn't a fitness machine")
                return@guarded
            }
            log("FTMS: 0x1826 fitness machine service FOUND — enabling machine-data notifications")
            // Subscribe to whichever machine-data characteristic this machine exposes.
            for ((uuid, kind) in MACHINE_CHARS) {
                val ch = svc.getCharacteristic(uuid) ?: continue
                log("FTMS: ${kind.displayName} data characteristic found — enabling notifications")
                enableNotify(g, ch)
            }
            // Battery (0x2A19): read once if present.
            val batt = g.getService(BATTERY_SERVICE)?.getCharacteristic(BATTERY_CHAR)
            if (batt != null) {
                log("FTMS: 0x180F battery service found — reading level")
                runCatching { g.readCharacteristic(batt) }
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) = handleMachine(ch.uuid, value)

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            handleMachine(ch.uuid, ch.value ?: return)
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (ch.uuid == BATTERY_CHAR && status == BluetoothGatt.GATT_SUCCESS) handleBattery(value)
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            if (ch.uuid == BATTERY_CHAR && status == BluetoothGatt.GATT_SUCCESS) handleBattery(ch.value ?: return)
        }
    }

    /** Enable notifications on a characteristic (setCharacteristicNotification + the explicit CCCD write). */
    private fun enableNotify(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
        g.setCharacteristicNotification(ch, true)
        val cccd = ch.getDescriptor(CCCD) ?: run {
            log("FTMS: WARNING ${ch.uuid} has no CCCD (0x2902) — cannot enable notifications")
            return
        }
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

    /**
     * Run a GATT-callback body so a throw on the binder thread can never crash the app — mirrors
     * [StandardHrSource.guardedCallback]. A misbehaving machine must degrade to "no data", never take
     * the app down; the message lands in the exportable strap log.
     */
    private fun guarded(label: String, block: () -> Unit) {
        runCatching(block).onFailure { log("FTMS: $label error (${it.javaClass.simpleName}: ${it.message})") }
    }

    private fun handleBattery(data: ByteArray) = guarded("battery-parse") {
        val pct = StandardBattery.parse(data) ?: return@guarded
        log("FTMS: battery $pct%")
        _batteryPct.value = pct
        handler.post { guarded("battery-sink") { onBattery(pct) } }
    }

    private fun handleMachine(uuid: UUID, data: ByteArray) = guarded("machine-parse") {
        val kind = MACHINE_CHARS.firstOrNull { it.first == uuid }?.second ?: return@guarded
        val reading = FitnessMachine.decode(kind.uuid16, data) ?: return@guarded
        if (!loggedFirstReading) {
            loggedFirstReading = true
            log("FTMS: receiving ${reading.kind.displayName} data — first reading" +
                (reading.heartRate?.let { " HR $it bpm" } ?: ""))
        }
        handler.post {
            guarded("reading-sink") {
                _latest.value = reading
                readingSink(reading)
                reading.heartRate?.takeIf { it in 30..220 }?.let { liveSink(it) }
            }
        }
    }

    companion object {
        val FITNESS_MACHINE_SERVICE: UUID = UUID.fromString("00001826-0000-1000-8000-00805f9b34fb")
        private val BATTERY_SERVICE: UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
        private val BATTERY_CHAR: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** The four machine-data characteristics → their FTMS kind. */
        private val MACHINE_CHARS: List<Pair<UUID, FitnessMachine.MachineKind>> = listOf(
            UUID.fromString("00002acd-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.TREADMILL,
            UUID.fromString("00002ad2-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.INDOOR_BIKE,
            UUID.fromString("00002ad1-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.ROWER,
            UUID.fromString("00002ace-0000-1000-8000-00805f9b34fb") to FitnessMachine.MachineKind.CROSS_TRAINER,
        )

        private const val GATT_ERROR_133 = 133
    }
}
