package com.noop.ble

import com.noop.protocol.StandardHrContact

/**
 * Pure parser for the standard BLE Heart Rate Measurement characteristic (0x2A37).
 *
 * Faithful Kotlin twin of Strand/BLE/StandardHeartRate.swift. Returns the heart rate (bpm) and any
 * R-R intervals (ms). Pure → unit-testable away from android.bluetooth.
 *
 * This is a SEPARATE parser from [WhoopBleClient.parseStandardHr] on purpose: the new isolated
 * [StandardHrSource] uses THIS one so the WHOOP client's inline parse stays untouched (slight
 * duplication is fine — it keeps the hardware-verified WHOOP path from regressing). Both encode the
 * same Bluetooth SIG layout:
 *   - flags bit0 (0x01): HR is u16 (else u8)
 *   - flags bit3 (0x08): Energy-Expended field present → skip its 2 bytes before R-R
 *   - flags bit4 (0x10): one or more R-R intervals follow, each a u16 in 1/1024-second units
 *
 * R-R is converted to milliseconds as `round(raw / 1024 * 1000)` to match the Swift parser exactly
 * (the WHOOP store keeps R-R in ms). `rrRawTicks` carries the unconverted u16 values; WHOOP 5
 * (firmware 50.41.1.0) sends milliseconds directly (non-compliant with BLE spec), so callers that
 * know they have a WHOOP 5 should use `rrRawTicks` instead of `rr`.
 */
object StandardHeartRate {

    /** The parsed reading: heart rate (bpm), R-R intervals (ms), raw R-R ticks (u16), and contact state. */
    data class Reading(val hr: Int, val rr: List<Int>, val rrRawTicks: List<Int>, val contact: StandardHrContact)

    /**
     * Parse one 0x2A37 notification payload. Returns null on an empty or truncated packet (a packet
     * whose declared HR/R-R bytes run past the buffer), matching the Swift `guard` bounds checks.
     */
    fun parse(data: ByteArray): Reading? {
        if (data.isEmpty()) return null
        val flags = data[0].toInt() and 0xFF
        val contact = StandardHrContact.fromMeasurementFlags(flags)
        var idx = 1

        val hr: Int
        if (flags and 0x01 != 0) {                       // 16-bit HR
            if (idx + 1 >= data.size) return null
            hr = (data[idx].toInt() and 0xFF) or ((data[idx + 1].toInt() and 0xFF) shl 8)
            idx += 2
        } else {                                         // 8-bit HR
            if (idx >= data.size) return null
            hr = data[idx].toInt() and 0xFF
            idx += 1
        }

        if (flags and 0x08 != 0) idx += 2                // skip Energy Expended (bit 3)

        val rr = ArrayList<Int>()
        val rrRawTicks = ArrayList<Int>()
        if ((flags shr 4) and 0x01 != 0) {               // R-R present (bit 4)
            while (idx + 1 < data.size) {
                val raw = (data[idx].toInt() and 0xFF) or ((data[idx + 1].toInt() and 0xFF) shl 8)
                rrRawTicks.add(raw)
                rr.add(Math.round(raw / 1024.0 * 1000.0).toInt())   // 1/1024 s → ms (rounded)
                idx += 2
            }
        }
        return Reading(hr, rr, rrRawTicks, contact)
    }
}
