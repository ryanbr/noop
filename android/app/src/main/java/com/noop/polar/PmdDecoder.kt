package com.noop.polar

// MARK: - Polar Measurement Data (PMD) decode — clean-room, pure, no android.bluetooth
//
// Faithful Kotlin twin of Packages/PolarProtocol/Sources/PolarProtocol/PmdDecoder.swift. Polar's PMD
// service is proprietary but PUBLICLY DOCUMENTED (Polar's official BLE SDK); this is NOOP's own clean
// parser of the documented byte layout — no Polar code, no firmware, nothing fabricated.
//
// PMD data notifications share a 10-byte header: byte 0 = measurement type, bytes 1..8 = timestamp
// (uint64 LE ns since 2000-01-01 UTC — the PMD epoch, NOT Unix — of the last sample), byte 9 = frame type
// (bit 7 = compressed flag; bits 0..6 = format).
// This decodes the PPI stream (0x03): heart rate + peak-to-peak (inter-beat) interval per beat — NOOP's
// HRV input, the same signal WHOOP R-R gives — so a Polar H10 / OH1 / Verity Sense needs no ECG peak
// detection. PPI is never compressed: each sample is a fixed 6-byte record (hr u8, ppi u16 LE, error u16
// LE, flags u8 [bit0 blocker, bit1 skinContact, bit2 skinContactSupported]).

/** A PMD measurement type (the subset NOOP recognises); an unrecognised type decodes to null (no guess). */
enum class PolarPmdMeasurement(val raw: Int) {
    ECG(0x00),
    PPG(0x01),
    ACC(0x02),
    PPI(0x03),
    GYRO(0x05),
    MAGNETOMETER(0x06);

    companion object {
        fun fromRaw(raw: Int): PolarPmdMeasurement? = entries.firstOrNull { it.raw == raw }
    }
}

/** The parsed 10-byte PMD data-frame header, common to every measurement type. */
data class PolarPmdFrameHeader(
    val measurement: PolarPmdMeasurement,
    /** Frame timestamp in nanoseconds since **2000-01-01 UTC** — the PMD epoch, NOT the Unix epoch (a raw
     *  read is ~30 years behind wall clock). Applies to the last sample in the frame. Use [unixTimestampNs]
     *  for wall clock. Only load-bearing for the fixed-rate streams (ECG/ACC/PPG) when those land — for PPI,
     *  samples are event-based and callers timestamp on arrival. */
    val timestampNs: Long,
    /** The data-format id (frame type bits 0..6). */
    val frameType: Int,
    /** True when the compressed/delta bit (0x80) is set on the frame-type byte. */
    val isCompressed: Boolean,
) {
    /** [timestampNs] re-based to the Unix epoch (ns since 1970-01-01 UTC), for wall-clock use. */
    val unixTimestampNs: Long get() = timestampNs + PMD_EPOCH_UNIX_OFFSET_NS

    companion object {
        /** Nanoseconds between the Unix epoch (1970-01-01) and the PMD epoch (2000-01-01): 946 684 800 s.
         *  Add to a PMD [timestampNs] to re-base it onto the Unix epoch. */
        const val PMD_EPOCH_UNIX_OFFSET_NS: Long = 946_684_800_000_000_000L
    }
}

/** One decoded PPI (peak-to-peak interval) sample. */
data class PolarPpiSample(
    /** Heart rate in bpm as reported; 0 = "no valid beat right now", surfaced as-is (never faked). */
    val heartRate: Int,
    /** The peak-to-peak / inter-beat interval in ms — NOOP's HRV input (≈ an R-R interval). */
    val ppiMs: Int,
    /** The sensor's own error estimate for this interval, in ms. */
    val errorEstimateMs: Int,
    /** Blocker bit (flags bit0): the sensor flagged this interval unreliable (movement / poor contact) —
     *  drop from HRV. Unambiguous across sources. */
    val blocker: Boolean,
    /** Raw flags bit1. Named per the Polar SDK's `skinContactStatus` (set = contact). NOTE: NOOP's
     *  DEVICE_SUPPORT_ROADMAP.md §PMD phrases bit1 as "poor/no skin contact" (opposite polarity), so the
     *  real-world meaning is UNCONFIRMED on hardware — do not gate on it until verified. */
    val skinContact: Boolean,
    /** Raw flags bit2. Named per the Polar SDK's `skinContactSupported` (set = supported); the roadmap
     *  phrases it as "contact unsupported" (opposite). Same on-hardware confirmation caveat. */
    val skinContactSupported: Boolean,
)

object PmdDecoder {

    /** The fixed PMD data-frame header length (type + 8-byte timestamp + frame-type byte). */
    const val HEADER_LENGTH = 10
    /** The byte length of one PPI sample record. */
    internal const val PPI_SAMPLE_LENGTH = 6

    /** Parse the 10-byte PMD data-frame header. Returns null if shorter than the header or the measurement
     *  type is unrecognised (no wrong guess). */
    fun header(data: ByteArray): PolarPmdFrameHeader? {
        if (data.size < HEADER_LENGTH) return null
        // The measurement type is the low 6 bits of byte 0 (top 2 reserved) — mask before matching so a
        // frame with reserved bits set still resolves (DEVICE_SUPPORT_ROADMAP.md §PMD: "mask 0x3F").
        val measurement = PolarPmdMeasurement.fromRaw(data[0].toInt() and 0x3F) ?: return null
        val frameByte = data[9].toInt() and 0xFF
        return PolarPmdFrameHeader(
            measurement = measurement,
            timestampNs = uint64LE(data, 1),
            frameType = frameByte and 0x7F,
            isCompressed = (frameByte and 0x80) != 0,
        )
    }

    /** Decode a PPI (0x03) frame into its samples. Returns null when the frame isn't a valid PPI frame
     *  (too short, unknown type, or not PPI); an empty list for a well-formed PPI header with no complete
     *  sample. A trailing partial record (fewer than 6 bytes) is ignored. */
    fun decodePPI(data: ByteArray): List<PolarPpiSample>? {
        val header = header(data) ?: return null
        if (header.measurement != PolarPmdMeasurement.PPI) return null
        val samples = ArrayList<PolarPpiSample>()
        var i = HEADER_LENGTH
        while (i + PPI_SAMPLE_LENGTH <= data.size) {
            val flags = data[i + 5].toInt() and 0xFF
            samples.add(
                PolarPpiSample(
                    heartRate = data[i].toInt() and 0xFF,
                    ppiMs = uint16LE(data, i + 1),
                    errorEstimateMs = uint16LE(data, i + 3),
                    blocker = (flags and 0x01) != 0,
                    skinContact = (flags and 0x02) != 0,
                    skinContactSupported = (flags and 0x04) != 0,
                ),
            )
            i += PPI_SAMPLE_LENGTH
        }
        return samples
    }

    // MARK: - Little-endian readers (bounds are pre-checked by callers)

    private fun uint16LE(data: ByteArray, i: Int): Int =
        (data[i].toInt() and 0xFF) or ((data[i + 1].toInt() and 0xFF) shl 8)

    private fun uint64LE(data: ByteArray, i: Int): Long {
        var v = 0L
        for (b in 0 until 8) v = v or ((data[i + b].toLong() and 0xFF) shl (8 * b))
        return v
    }
}
