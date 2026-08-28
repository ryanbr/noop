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

    /**
     * The one kind a MIXED series must be reduced to before any aggregate is taken (#1705).
     *
     * A CSV import writes absolute °C and the computed pipeline writes a deviation, both into this
     * same field, so one window can hold both. Formatting stays honest per value — [kind] is
     * re-derived for each — but a min, max, mean or window-over-window delta drawn across both is
     * arithmetic on two different scales, and it looks plausible: a handful of ~34 °C readings lift a
     * should-be-near-zero deviation average past a full degree, and the mean is then itself below 20
     * so it gets labelled Δ°C.
     *
     * The newest entry decides, matching what `HealthVitalsLogic` already does for its sparkline — the
     * reading the user is actually looking at sets the scale, and older entries of the other kind drop
     * out rather than being converted, because converting needs a baseline that a fresh import-only
     * install does not have.
     *
     * @param valuesAscendingByDay the window's values, ascending by day.
     * @return the kind to keep, or null for an empty window.
     */
    fun dominantKind(valuesAscendingByDay: List<Double>): Kind? =
        valuesAscendingByDay.lastOrNull()?.let { kind(it) }

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
