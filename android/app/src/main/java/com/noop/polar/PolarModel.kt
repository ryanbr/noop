package com.noop.polar

// MARK: - Polar model identification + PMD stream capability catalog (clean-room, public facts)
//
// Faithful Kotlin twin of Packages/PolarProtocol/Sources/PolarProtocol/PolarModel.swift. A Polar sensor
// advertises a stable BLE name "Polar <MODEL> <serial>" (public); this maps that to the model and the PMD
// streams it is documented to expose, so a future PolarPMDSource picks the right measurement per device
// (PPI for HRV on the optical bands; ECG on the H10) instead of probing blindly. R-R for HRV also arrives
// on the standard HR service (0x180D) for every model — that path already ships — so a model with no PMD
// entry is still a first-class HR/R-R source.
//
// Facts only: model names are public product identifiers; per-model PMD stream sets are from
// docs/DEVICE_SUPPORT_ROADMAP.md §PMD (official polar-ble-sdk). HARDWARE-GATED: confirm capabilities on a
// real device before gating behaviour. OH1 vs Verity Sense diverge on the gyroscope (Verity has the 9-axis
// IMU; OH1 does not).

enum class PolarModel {
    /** Chest strap: ECG + ACC over PMD, plus HR + R-R on the standard service. No optical. */
    H10,
    /** Chest strap: HR + R-R on the standard service only (no PMD service). */
    H9,
    /** Optical armband: PPG + PPI + ACC over PMD, plus HR. No ECG, no gyroscope. */
    OH1,
    /** Optical armband (Verity Sense): PPG + PPI + ACC + GYRO over PMD, plus HR. No ECG. */
    VERITY_SENSE,
    /** Unrecognised Polar device. Still a standard HR/R-R strap; PMD streams unknown — probe, don't assume. */
    UNKNOWN;

    /** The PMD measurement streams this model is documented to expose. Empty for HR-only (H9) / UNKNOWN. */
    val pmdStreams: Set<PolarPmdMeasurement>
        get() = when (this) {
            H10 -> setOf(PolarPmdMeasurement.ECG, PolarPmdMeasurement.ACC)
            H9 -> emptySet()
            OH1 -> setOf(PolarPmdMeasurement.PPG, PolarPmdMeasurement.PPI, PolarPmdMeasurement.ACC)
            VERITY_SENSE -> setOf(
                PolarPmdMeasurement.PPG, PolarPmdMeasurement.PPI,
                PolarPmdMeasurement.ACC, PolarPmdMeasurement.GYRO,
            )
            UNKNOWN -> emptySet()
        }

    /** The PMD measurement NOOP would request for HRV: PPI where the optical bands expose it, else null
     *  (H10/H9 R-R comes off the standard HR service — no PMD needed). */
    val hrvPmdStream: PolarPmdMeasurement?
        get() = if (pmdStreams.contains(PolarPmdMeasurement.PPI)) PolarPmdMeasurement.PPI else null

    /** Engineer-facing model label for the debug strap log (not localised). UNKNOWN reads as
     *  "(unrecognised model)" so it composes into "Polar (unrecognised model)". Twin of Swift displayLabel. */
    val displayLabel: String
        get() = when (this) {
            H10 -> "H10"
            H9 -> "H9"
            OH1 -> "OH1"
            VERITY_SENSE -> "Verity Sense"
            UNKNOWN -> "(unrecognised model)"
        }

    /** One-line PMD / HRV-route capability summary for the debug strap log — a pure restatement of
     *  pmdStreams / hrvPmdStream (no behaviour gates on it). Streams are ordered by their PMD type byte for
     *  a stable, protocol-natural order. Twin of Swift pmdDebugSummary. */
    val pmdDebugSummary: String
        get() {
            val streams = if (pmdStreams.isEmpty()) {
                if (this == UNKNOWN) "PMD unknown (probe)" else "no PMD service"
            } else {
                "PMD " + pmdStreams.sortedBy { it.raw }.joinToString(",") { it.label }
            }
            return "$streams; ${if (hrvPmdStream == null) "HRV via standard R-R" else "HRV via PMD PPI"}"
        }

    companion object {
        /** Identify the model from a peripheral's advertised name (case-insensitive on the "Polar <MODEL>"
         *  prefix). A non-Polar or unrecognised name → UNKNOWN. "Polar Sense" is the Verity Sense's
         *  advertised name (it does NOT advertise "Verity"). */
        fun fromAdvertisedName(name: String?): PolarModel {
            val raw = name?.trim().orEmpty()
            if (raw.isEmpty()) return UNKNOWN
            val n = raw.lowercase()
            if (!n.startsWith("polar ")) return UNKNOWN
            // Anchor on the model token — the word right after "Polar " — NOT a substring of the whole
            // name, so a device whose serial happened to carry a model token (e.g. a "Polar OH1 H10…"
            // serial matching h10) can't misidentify. startsWith is also order-independent here.
            return when {
                n.startsWith("polar h10") -> H10
                n.startsWith("polar h9") -> H9
                n.startsWith("polar oh1") -> OH1
                n.startsWith("polar sense") -> VERITY_SENSE
                else -> UNKNOWN
            }
        }

        /** Whether an advertised name belongs to a Polar sensor AT ALL — the public "Polar " prefix.
         *  Distinct from [fromAdvertisedName], which returns UNKNOWN for BOTH a non-Polar strap and an
         *  unrecognised Polar one; this separates "not a Polar device" from "a Polar device we can't name
         *  yet", so Polar-only diagnostics never fire for a Wahoo/Garmin strap. Works on a live scan name OR
         *  a stored PairedDevice model, so a paired strap auto-detects without a live connection.
         *  Twin of Swift PolarModel.isPolar. */
        fun isPolar(name: String?): Boolean =
            name?.trim()?.lowercase()?.startsWith("polar ") == true

        /** The full one-line identification for the debug strap log / Test Centre when a Polar strap is
         *  seen — e.g. "Polar H10 identified — PMD ecg,acc; HRV via standard R-R". Auto-detected from any
         *  advertised name, whether a live scan result or a stored PairedDevice model. Returns null for a
         *  non-Polar name, so a caller emits nothing for a Wahoo/Garmin strap. Twin of Swift
         *  debugIdentification. */
        fun debugIdentification(name: String?): String? {
            if (!isPolar(name)) return null
            val model = fromAdvertisedName(name)
            return "Polar ${model.displayLabel} identified — ${model.pmdDebugSummary}"
        }
    }
}
