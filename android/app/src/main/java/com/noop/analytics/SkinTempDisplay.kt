package com.noop.analytics

/**
 * How to present the bimodal `skinTempDevC` / `skin_temp` field (#622).
 *
 * CSV / Health imports store **absolute** wrist °C (~30–35). The live BLE pipeline stores a
 * **signed deviation** from the personal baseline (±°C, e.g. −0.1). Both land in the same column;
 * [VitalBands.isAbsoluteSkinTemp] (v ≥ 20) tells them apart. Deep timeline charts raw absolute
 * samples, so a Today/Health tile that only shows −0.1 without saying "vs baseline" looks broken.
 *
 * Twin of Swift `SkinTempDisplay`. Pure — unit-tested.
 */
object SkinTempDisplay {

    enum class Kind {
        /** Absolute wrist temperature (°C scale, typically ~30–35 worn). */
        ABSOLUTE,
        /** Signed deviation from the personal nightly baseline (±°C). */
        DEVIATION,
    }

    fun kind(value: Double): Kind =
        if (VitalBands.isAbsoluteSkinTemp(value)) Kind.ABSOLUTE else Kind.DEVIATION

    /** Trailing unit chip: `"°C"` / `"°F"` for absolute, `"Δ°C"` / `"Δ°F"` for deviation. */
    fun unitSymbol(kind: Kind, fahrenheit: Boolean): String {
        val base = if (fahrenheit) "°F" else "°C"
        return if (kind == Kind.ABSOLUTE) base else "Δ$base"
    }

    /**
     * Format the **number only** (no unit suffix). Deviations are always signed; absolute readings
     * are unsigned. Applies °F conversion when [fahrenheit] is true.
     */
    fun numberString(
        value: Double,
        kind: Kind,
        fahrenheit: Boolean,
        decimals: Int = 1,
    ): String {
        val display = if (fahrenheit) {
            if (kind == Kind.ABSOLUTE) value * 9.0 / 5.0 + 32.0 else value * 9.0 / 5.0
        } else {
            value
        }
        return if (kind == Kind.ABSOLUTE) {
            String.format(java.util.Locale.US, "%.${decimals}f", display)
        } else {
            String.format(java.util.Locale.US, "%+.${decimals}f", display)
        }
    }

    /** Full `"34.2 °C"` / `"+0.1 Δ°C"` string for one-shot call sites (Today cards, explorers). */
    fun format(value: Double, fahrenheit: Boolean, decimals: Int = 1): String {
        val k = kind(value)
        val n = numberString(value, k, fahrenheit, decimals)
        return "$n ${unitSymbol(k, fahrenheit)}"
    }
}
