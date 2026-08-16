package com.noop.polar

// MARK: - Polar Measurement Data (PMD) CONTROL POINT — clean-room command builder + response parse
//
// Faithful Kotlin twin of Packages/PolarProtocol/Sources/PolarProtocol/PmdControl.swift. The PMD Control
// Point characteristic (FB005C81-…, write + indicate) STARTS / STOPS a measurement stream and reads its
// supported settings, before data notifications arrive on the Data characteristic (FB005C82-…). Byte
// layout per docs/DEVICE_SUPPORT_ROADMAP.md §PMD (official polar-ble-sdk, cross-verified) — NOOP's own
// byte builder, not Polar code.
//
// SCOPE: the pure command/response layer only. The android.bluetooth wiring (discover the service, write
// these bytes, subscribe to the data char, feed PmdDecoder) is the hardware-gated PolarPMDSource still to
// build. HARDWARE-GATED: the 0xF0 control-point RESPONSE layout is per the SDK but not yet device-confirmed
// in this repo — no consumer should treat a parsed Response as authoritative until an H10 / Verity settles it.

object PolarPmdControl {

    /** Control-point opcodes — the FIRST byte of a control-point write. */
    const val OP_GET_MEASUREMENT_SETTINGS = 0x01
    const val OP_REQUEST_MEASUREMENT_START = 0x02
    const val OP_STOP_MEASUREMENT = 0x03

    /** Measurement SETTING types inside a start request (`[type, count, u16 LE × count]` blocks). */
    const val SETTING_SAMPLE_RATE = 0x00
    const val SETTING_RESOLUTION = 0x01
    const val SETTING_RANGE = 0x02

    /** The byte the PMD control point prefixes every indicate reply with (§PMD, SDK response frame). */
    const val RESPONSE_MARKER = 0xF0

    /** One setting block: a type plus its u16 values (little-endian on the wire). */
    data class Setting(val type: Int, val values: List<Int>)

    /** GET_MEASUREMENT_SETTINGS — ask which settings a measurement supports: `[0x01, measType]`. */
    fun getSettings(measurement: PolarPmdMeasurement): ByteArray =
        byteArrayOf(OP_GET_MEASUREMENT_SETTINGS.toByte(), measurement.raw.toByte())

    /**
     * REQUEST_MEASUREMENT_START — begin a stream: `[0x02, (recording shl 7) or measType, settingBlocks…]`.
     * recording=false (online streaming — what NOOP uses) leaves bit 7 clear. Each setting serialises as
     * `[type, count, lo, hi, …]` with u16 LE values.
     */
    fun start(
        measurement: PolarPmdMeasurement,
        recording: Boolean = false,
        settings: List<Setting> = emptyList(),
    ): ByteArray {
        val out = ArrayList<Byte>()
        out.add(OP_REQUEST_MEASUREMENT_START.toByte())
        out.add((((if (recording) 0x80 else 0x00) or (measurement.raw and 0x7F)).toByte()))
        for (s in settings) {
            out.add(s.type.toByte())
            out.add(s.values.size.toByte())
            for (v in s.values) {
                out.add((v and 0xFF).toByte())
                out.add(((v shr 8) and 0xFF).toByte())
            }
        }
        return out.toByteArray()
    }

    /** STOP_MEASUREMENT — end a stream: `[0x03, measType]`. */
    fun stop(measurement: PolarPmdMeasurement): ByteArray =
        byteArrayOf(OP_STOP_MEASUREMENT.toByte(), measurement.raw.toByte())

    /**
     * The control-point indicate reply `[0xF0, reqOpcode, measType, status, …]`. status==0 is success;
     * the rest (a "more" flag + GET_SETTINGS param blocks) is not parsed here. measurement is null when the
     * reply names a type NOOP doesn't recognise.
     */
    data class Response(val requestOpcode: Int, val measurement: PolarPmdMeasurement?, val status: Int) {
        val isSuccess: Boolean get() = status == 0x00
    }

    /** Parse a control-point indicate reply, or null when too short / not a control-point response. */
    fun parseResponse(data: ByteArray): Response? {
        if (data.size < 4 || (data[0].toInt() and 0xFF) != RESPONSE_MARKER) return null
        return Response(
            requestOpcode = data[1].toInt() and 0xFF,
            measurement = PolarPmdMeasurement.fromRaw(data[2].toInt() and 0x3F),
            status = data[3].toInt() and 0xFF,
        )
    }
}
