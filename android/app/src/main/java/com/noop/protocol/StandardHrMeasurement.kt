package com.noop.protocol

/** Structural completeness of the standard BLE Heart Rate Measurement (0x2A37). */
object StandardHrMeasurement {
    /**
     * Require the flag-selected HR and energy fields and whole declared R-R words.
     * Reserved flag bits, empty R-R fields and undeclared trailing bytes retain existing compatibility.
     * Swift twin: `StandardHRMeasurement.hasCompleteFields`.
     */
    fun hasCompleteFields(data: ByteArray): Boolean {
        if (data.isEmpty()) return false
        val flags = data[0].toInt() and 0xFF
        val prefixBytes = 1 + (if (flags and 0x01 != 0) 2 else 1) + (if (flags and 0x08 != 0) 2 else 0)
        if (data.size < prefixBytes) return false
        return flags and 0x10 == 0 || (data.size - prefixBytes) % 2 == 0
    }
}
