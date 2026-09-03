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

    /**
     * [raw] is the PERSISTED form of the #1846 setting and is byte-identical to the Swift `Kind.rawValue`
     * — lower-case, so `name` ("DEVIATION") must never be written to prefs. Same reasoning as
     * `KeyMetric.raw`: two independent implementations must not drift on how they spell a stored token,
     * and this one shares the `units.skinTempDisplay` key with Apple.
     */
    enum class Kind(val raw: String) {
        /** Absolute wrist temperature (°C scale, typically ~30–35 worn). */
        ABSOLUTE("absolute"),
        /** Signed deviation from the personal nightly baseline (±°C). */
        DEVIATION("deviation"),
        ;

        companion object {
            fun fromRaw(raw: String?): Kind? = entries.firstOrNull { it.raw == raw }
        }
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

    /** A resolved reading: the number to show and the scale it is on. */
    data class Reading(val value: Double, val kind: Kind)

    /**
     * Which of a night's two skin-temp numbers a surface should LEAD with (#1844), the pure form of the
     * rule `HealthVitalsLogic.skinTempLeadsWithAbsolute` has applied since #1665.
     *
     * The absolute wins whenever the night measured one, because a deviation with no anchor cannot be
     * read — "+0.9" is a fever or a warm bedroom and nothing on a card says which. The deviation is the
     * fallback, not the default, and it still carries its Δ unit so it is never mistaken for a wrist
     * temperature (#622).
     *
     * Two shapes make this more than a preference, and both are real rows rather than hypotheticals:
     *  - a night scored before `skinTempC` shipped (2026-08-27) has only a deviation, and keeps exactly
     *    the display that shipped before until a scoring pass refills it;
     *  - a CALIBRATING night is the reverse — `recomputeSkinTempDev` returns null until the baseline is
     *    usable (~4 nights) while the absolute is measured from night one, so those wearers otherwise see
     *    an empty card with a real temperature sitting behind it.
     *
     * [prefer] is the user's Settings choice (#1846): ABSOLUTE — the default, a temperature — or DEVIATION
     * for wearers who read the ±baseline move, which is the more sensitive illness signal. It picks which
     * number is tried FIRST; the other is still the fallback, so choosing one never blanks a card whose
     * night only measured the other, and the unit always names the scale actually shown.
     *
     * Both values must come from the SAME row; see `lastSkinTempReadingRow`. Twin of the Swift
     * `SkinTempDisplay.leadReading`.
     */
    fun leadReading(absC: Double?, devC: Double?, prefer: Kind = Kind.ABSOLUTE): Reading? {
        val first = if (prefer == Kind.ABSOLUTE) absC else devC
        first?.let { return Reading(it, prefer) }
        val other = if (prefer == Kind.ABSOLUTE) devC else absC
        val otherKind = if (prefer == Kind.ABSOLUTE) Kind.DEVIATION else Kind.ABSOLUTE
        return other?.let { Reading(it, otherKind) }
    }

    /** Formats whichever number [leadReading] chose, with the unit for THAT scale. */
    fun formatReading(reading: Reading, fahrenheit: Boolean, decimals: Int = 1): String =
        "${numberString(reading.value, reading.kind, fahrenheit, decimals)} ${unitSymbol(reading.kind, fahrenheit)}"

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
        if (kind == Kind.ABSOLUTE) {
            return String.format(java.util.Locale.US, "%.${decimals}f", display)
        }
        val signed = String.format(java.util.Locale.US, "%+.${decimals}f", display)
        // #1842: a deviation that ROUNDS to zero must not keep its sign. `%+` prints "-0.0" for anything
        // in (-0.05, 0), and "-0.0 Δ°C" on a card reads as a fault rather than as "no change from your
        // baseline" — which is exactly what it means. Drop the sign only when the rounded value is zero;
        // a real -0.1 keeps it.
        return if (signed.drop(1).toDoubleOrNull() == 0.0) signed.drop(1) else signed
    }

    /** Full `"34.2 °C"` / `"+0.1 Δ°C"` string for one-shot call sites (Today cards, explorers). */
    fun format(value: Double, fahrenheit: Boolean, decimals: Int = 1): String {
        val k = kind(value)
        val n = numberString(value, k, fahrenheit, decimals)
        return "$n ${unitSymbol(k, fahrenheit)}"
    }
}
