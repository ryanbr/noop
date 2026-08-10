package com.noop.ui

import android.content.Context
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Unit system preference
//
// NOOP stores EVERYTHING in SI (km, kg, cm, °C) — the importers normalise on the way in, so this is a
// purely cosmetic, display-only layer. There is no data migration and nothing in Room changes when the
// user flips this. One Metric/Imperial switch for length+mass with a SEPARATE temperature override,
// because plenty of people think in kg/cm but still read body temperature in °F (and vice versa).
// Default is Metric — most of the world, and it matches what we store.
//
// Persisted via NoopPrefs (SharedPreferences), the same mechanism every other Android preference uses.
// This mirrors the macOS Units.swift + @AppStorage side exactly.

/** Length+mass unit system. Temperature has its own override (see [UnitPrefs.temperature]). */
enum class UnitSystem(val raw: String) {
    METRIC("metric"),
    IMPERIAL("imperial");

    /** Pairs temperature with the length/mass choice when no explicit override is set. */
    val temperatureMatching: TemperatureUnit
        get() = if (this == IMPERIAL) TemperatureUnit.FAHRENHEIT else TemperatureUnit.CELSIUS

    companion object {
        fun fromRaw(raw: String?): UnitSystem = entries.firstOrNull { it.raw == raw } ?: METRIC
    }
}

/** Temperature display unit, overridable independently of [UnitSystem]. */
enum class TemperatureUnit(val raw: String) {
    CELSIUS("celsius"),
    FAHRENHEIT("fahrenheit");

    companion object {
        fun fromRaw(raw: String?): TemperatureUnit? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * How the Effort score is displayed (#268). NOOP stores Effort 0–100 (StrainScorer.maxStrain = 100);
 * people coming from WHOOP often think in its 0–21 Day Strain axis, so this purely cosmetic toggle lets
 * the SAME stored value be shown on either scale. Default is NOOP's own 0–100 — the data never changes.
 * Mirrors the macOS [EffortScale].
 */
enum class EffortScale(val raw: String) {
    /** NOOP's native 0–100 axis (the stored value, one decimal). */
    HUNDRED("hundred"),

    /** WHOOP's 0–21 Day Strain axis — the stored 0–100 value rescaled down for display only. */
    WHOOP("whoop");

    companion object {
        /** An unset/unknown value resolves to NOOP's native 0–100 axis. */
        fun fromRaw(raw: String?): EffortScale = entries.firstOrNull { it.raw == raw } ?: HUNDRED
    }
}

/**
 * How the Trends charts are drawn — line vs bar. A purely cosmetic, display-only toggle: the plotted
 * data is identical on both settings, only the mark geometry changes. Default is the classic line.
 * Distinct from [ChartStyle] (which picks the colour ramp); this picks the shape. Mirrors the macOS
 * [TrendChartStyle].
 */
enum class TrendChartStyle(val raw: String) {
    /** The classic gradient-stroked line with a soft area fill (the long-standing look). */
    LINE("line"),

    /** Vertical bars from the axis baseline, one per sample. */
    BAR("bar");

    companion object {
        /** An unset/unknown value resolves to the classic line. */
        fun fromRaw(raw: String?): TrendChartStyle = entries.firstOrNull { it.raw == raw } ?: LINE
    }
}

/**
 * Which sleep window the nightly HRV is measured over (#141). NOOP historically averages RMSSD across the
 * WHOLE night (every stage); WHOOP/Polar/etc. sample the last slow-wave-sleep window, which reads lower.
 * This lets a user match that. It CHANGES the computed avgHrv (not display-only), so a switch re-scores +
 * re-baselines. Default is the historical whole-night value. Mirrors the macOS [HrvWindow].
 */
enum class HrvWindow(val raw: String) {
    /** RMSSD averaged over every 5-min window of the night (NOOP's long-standing value). */
    WHOLE_NIGHT("whole"),

    /**
     * RMSSD over DEEP (slow-wave) sleep windows only — the window WHOOP samples.
     *
     * "Comparable to WHOOP" describes the METHOD, not the accuracy of the resulting number: the deep
     * windows come from NOOP's own stager, not the strap. `Tools/SleepPSG` scores that stager against
     * PSG truth over 31 subjects / 26 773 epochs and measures deep at 18.94 % predicted vs 13.76 %
     * truth — a +5.18 pp bias, roughly 38 % more deep epochs than exist, at four-class kappa 0.356.
     * An over-inclusive deep window pulls this value back toward the whole-night mean, which is the
     * one thing the setting exists not to be.
     *
     * So this stays opt-in and WHOLE_NIGHT stays the default. #1008 tracks moving it, gated on that
     * bias coming down; re-run the benchmark before changing the default rather than assuming it has.
     */
    DEEP_SLEEP("deep");

    companion object {
        /** An unset/unknown value resolves to the historical whole-night window. */
        fun fromRaw(raw: String?): HrvWindow = entries.firstOrNull { it.raw == raw } ?: WHOLE_NIGHT
    }
}

/**
 * How the Sleep tab draws the night's stage timeline (#sleep-chart-style). Display-only — no metric or
 * stored value changes; it only picks which chart renders. Default [CLASSIC] so nobody's view changes
 * unless they opt in.
 */
enum class SleepChartStyle(val raw: String) {
    /** The long-standing per-stage-rows timeline (Awake/Light/Deep/REM each on their own track). */
    CLASSIC("classic"),

    /** A single stepped hypnogram with the stages stacked by depth and each column FILLED to the
     *  baseline, WHOOP-style — needs the night's real timestamped segments, else falls back to CLASSIC. */
    FILLED("filled"),

    /** The same single stepped chart but drawn as a slim RIBBON (a uniform band at each stage level, not
     *  filled to the baseline) — the WHOOP-style stepped line, which reads cleaner on a fragmented night. */
    RIBBON("ribbon");

    companion object {
        fun fromRaw(raw: String?): SleepChartStyle = entries.firstOrNull { it.raw == raw } ?: CLASSIC
    }
}

/**
 * Reads the two unit preferences from [NoopPrefs] and resolves the "match the system" default for
 * temperature. SharedPreferences isn't reactive, so Compose screens read these once into remembered
 * state (exactly like the other toggles) and re-read on a recomposition triggered by the Settings write.
 */
object UnitPrefs {
    /** The length/mass system (default Metric). */
    fun system(context: Context): UnitSystem =
        UnitSystem.fromRaw(NoopPrefs.of(context).getString(NoopPrefs.KEY_UNIT_SYSTEM, null))

    /** The resolved temperature unit, applying the "match the length/mass system" default. */
    fun temperature(context: Context): TemperatureUnit {
        val override = TemperatureUnit.fromRaw(
            NoopPrefs.of(context).getString(NoopPrefs.KEY_TEMPERATURE_UNIT, null),
        )
        return override ?: system(context).temperatureMatching
    }

    /** Pure resolver shared with the tests: explicit override wins, else follow the system. */
    fun resolveTemperature(system: UnitSystem, override: String?): TemperatureUnit =
        TemperatureUnit.fromRaw(override) ?: system.temperatureMatching

    /** SharedPreferences key for the Effort display scale (#268). Mirrors macOS @AppStorage("effort.scale"). */
    const val KEY_EFFORT_SCALE = "effort.scale"

    /** The Effort display scale (default 0–100). Read once into Compose state like the other prefs. */
    fun effortScale(context: Context): EffortScale =
        EffortScale.fromRaw(NoopPrefs.of(context).getString(KEY_EFFORT_SCALE, null))

    /** Persist the Effort display scale. */
    fun setEffortScale(context: Context, scale: EffortScale) {
        NoopPrefs.of(context).edit().putString(KEY_EFFORT_SCALE, scale.raw).apply()
    }

    /** SharedPreferences key for the Trends chart style. Mirrors macOS @AppStorage("trend.chart.style"). */
    const val KEY_TREND_CHART_STYLE = "trend.chart.style"

    /** The Trends chart style (default line). Read once into Compose state like the other prefs. */
    fun trendChartStyle(context: Context): TrendChartStyle =
        TrendChartStyle.fromRaw(NoopPrefs.of(context).getString(KEY_TREND_CHART_STYLE, null))

    /** Persist the Trends chart style. */
    fun setTrendChartStyle(context: Context, style: TrendChartStyle) {
        NoopPrefs.of(context).edit().putString(KEY_TREND_CHART_STYLE, style.raw).apply()
    }

    /** SharedPreferences key for the nightly-HRV window (#141). Mirrors macOS @AppStorage("hrv.window"). */
    const val KEY_HRV_WINDOW = "hrv.window"

    /** The nightly-HRV window (default whole-night). Threaded into the engine's avgHrv computation. */
    fun hrvWindow(context: Context): HrvWindow =
        HrvWindow.fromRaw(NoopPrefs.of(context).getString(KEY_HRV_WINDOW, null))

    /** Persist the nightly-HRV window. Changing it re-scores + re-baselines (the value itself moves). */
    fun setHrvWindow(context: Context, window: HrvWindow) {
        NoopPrefs.of(context).edit().putString(KEY_HRV_WINDOW, window.raw).apply()
    }

    /** SharedPreferences key for the Sleep tab's stage-chart style (#sleep-chart-style). */
    const val KEY_SLEEP_CHART_STYLE = "sleep.chart.style"

    /** The Sleep stage-chart style (default CLASSIC per-stage rows). Display-only. */
    fun sleepChartStyle(context: Context): SleepChartStyle =
        SleepChartStyle.fromRaw(NoopPrefs.of(context).getString(KEY_SLEEP_CHART_STYLE, null))

    /** Persist the Sleep stage-chart style. Display-only — no re-score. */
    fun setSleepChartStyle(context: Context, style: SleepChartStyle) {
        NoopPrefs.of(context).edit().putString(KEY_SLEEP_CHART_STYLE, style.raw).apply()
    }
}

/**
 * Pure, Android-free unit conversion and display formatting. Every site that prints a distance, mass,
 * height or temperature goes through here so the unit toggle reaches all of them at once.
 *
 * The conversion factors are pinned by `UnitFormatterTest` — a wrong factor can't ship silently.
 * Nothing here reads SharedPreferences: callers pass the resolved [UnitSystem] / [TemperatureUnit] in,
 * which keeps the formatter trivially testable and side-effect free. Mirrors Swift's `UnitFormatter`.
 */
object UnitFormatter {

    // MARK: Factors (single source of truth — tests pin these exact numbers)

    /** 1 kilometre = 0.621371 miles. */
    const val MILES_PER_KILOMETER = 0.621371
    /** 1 kilogram = 2.20462 pounds. */
    const val POUNDS_PER_KILOGRAM = 2.20462
    /** 1 inch = 2.54 cm exactly → 1 cm = 1/2.54 inches. */
    const val CENTIMETERS_PER_INCH = 2.54

    // MARK: Distance (stored km)

    /** km → miles. */
    fun kmToMiles(km: Double): Double = km * MILES_PER_KILOMETER

    /**
     * Format a distance given in METRES (the stored unit for workout distance).
     * Metric: "1.2 km" / "850 m". Imperial: "0.7 mi" / "230 yd" for sub-mile distances.
     */
    fun distanceFromMeters(meters: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> {
            val km = meters / 1000.0
            if (km >= 1) oneDecimal(km) + " km" else "${meters.roundToInt()} m"
        }
        UnitSystem.IMPERIAL -> {
            val miles = kmToMiles(meters / 1000.0)
            if (miles >= 0.1) {
                oneDecimal(miles) + " mi"
            } else {
                // Below ~160 m show yards rather than a "0.0 mi" that reads as nothing.
                "${(meters * 1.09361).roundToInt()} yd"
            }
        }
    }

    /**
     * Average pace for display: "m:ss /km" (metric) or "m:ss /mi" (imperial). "—" when pace is undefined
     * (null or ≤ 0, i.e. no distance yet). [secPerKm] is the seconds-per-kilometre the GPS session
     * publishes. Byte-identical to the Swift `UnitFormatter.paceFromSecPerKm`. (#1195)
     */
    fun paceFromSecPerKm(secPerKm: Double?, system: UnitSystem): String {
        if (secPerKm == null || secPerKm <= 0) return "—"
        val (secs, label) = when (system) {
            UnitSystem.IMPERIAL -> (secPerKm / MILES_PER_KILOMETER) to "/mi"
            UnitSystem.METRIC -> secPerKm to "/km"
        }
        val s = secs.roundToInt()
        return "${s / 60}:${(s % 60).toString().padStart(2, '0')} $label"
    }

    /**
     * Format a distance given in KILOMETRES (e.g. the Workouts "Total Distance" sum), with one decimal
     * and a unit label. Metric: "12.4 km". Imperial: "7.7 mi".
     */
    fun distanceFromKilometers(km: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> oneDecimal(km) + " km"
        UnitSystem.IMPERIAL -> oneDecimal(kmToMiles(km)) + " mi"
    }

    /** Unit label only, for sites that format the number separately. "km" / "mi". */
    fun distanceUnit(system: UnitSystem): String = if (system == UnitSystem.IMPERIAL) "mi" else "km"

    // MARK: Mass (stored kg)

    /** kg → pounds. */
    fun kgToPounds(kg: Double): Double = kg * POUNDS_PER_KILOGRAM

    /** Format a mass given in KILOGRAMS with one decimal + unit. Metric: "74.5 kg". Imperial: "164.2 lb". */
    fun massFromKilograms(kg: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> oneDecimal(kg) + " kg"
        UnitSystem.IMPERIAL -> oneDecimal(kgToPounds(kg)) + " lb"
    }

    /** Mass unit label only. "kg" / "lb". */
    fun massUnit(system: UnitSystem): String = if (system == UnitSystem.IMPERIAL) "lb" else "kg"

    // MARK: Height (stored cm)

    /** cm → total inches. */
    fun cmToInches(cm: Double): Double = cm / CENTIMETERS_PER_INCH

    /** Decompose a height in CENTIMETRES into whole feet + inches (inches rounded, carried into feet). */
    fun cmToFeetInches(cm: Double): Pair<Int, Int> {
        val totalInches = cmToInches(cm).roundToInt()
        var feet = totalInches / 12
        var inches = totalInches % 12
        if (inches == 12) { feet += 1; inches = 0 } // rounding can push 11.5" → 12"
        return Pair(feet, inches)
    }

    /** Format a height given in CENTIMETRES. Metric: "178 cm". Imperial: "5′ 10″". */
    fun heightFromCentimeters(cm: Double, system: UnitSystem): String = when (system) {
        UnitSystem.METRIC -> "${cm.roundToInt()} cm"
        UnitSystem.IMPERIAL -> {
            val (ft, inch) = cmToFeetInches(cm)
            // Prime/double-prime are the conventional ft/in glyphs and read cleanly at small sizes.
            "$ft′ $inch″"
        }
    }

    // MARK: Temperature (stored °C — absolute)

    /** °C → °F: F = C * 9/5 + 32. */
    fun celsiusToFahrenheit(c: Double): Double = c * 9.0 / 5.0 + 32.0

    /** Format an ABSOLUTE temperature in CELSIUS. Metric: "33.4 °C". Imperial: "92.1 °F". */
    fun temperatureFromCelsius(c: Double, unit: TemperatureUnit, decimals: Int = 1): String = when (unit) {
        TemperatureUnit.CELSIUS -> decimalString(c, decimals) + " °C"
        TemperatureUnit.FAHRENHEIT -> decimalString(celsiusToFahrenheit(c), decimals) + " °F"
    }

    /**
     * Format a temperature DEVIATION (a ±Δ°C, e.g. the skin-temp deviation pipeline). A delta scales by
     * 9/5 but does NOT add the +32 offset — that would be wrong for a difference.
     */
    fun temperatureDeltaFromCelsius(dc: Double, unit: TemperatureUnit, decimals: Int = 1): String = when (unit) {
        TemperatureUnit.CELSIUS -> decimalString(dc, decimals) + " °C"
        TemperatureUnit.FAHRENHEIT -> decimalString(dc * 9.0 / 5.0, decimals) + " °F"
    }

    /** Temperature unit label only. "°C" / "°F". */
    fun temperatureUnit(unit: TemperatureUnit): String =
        if (unit == TemperatureUnit.FAHRENHEIT) "°F" else "°C"

    // MARK: Effort scale (stored 0–100 — #268)

    /**
     * NOOP stores Effort 0–100 (StrainScorer.maxStrain = 100). WHOOP's Day Strain axis is 0–21, and the
     * import boundary rescales by 100/21 (WhoopCsvImporter / WhoopExportImporter.dayStrainToEffortScale),
     * so the exact inverse for a display-only 0–100 → 0–21 conversion is ×21/100. Kept byte-identical to
     * that factor and to the macOS `UnitFormatter.effortScaleFactor`.
     */
    const val EFFORT_SCALE_FACTOR = 21.0 / 100.0

    /** The stored 0–100 Effort value mapped onto the selected display scale (the raw number, no unit). */
    fun effortValue(value: Double, scale: EffortScale): Double =
        if (scale == EffortScale.WHOOP) value * EFFORT_SCALE_FACTOR else value

    /**
     * Format a stored 0–100 Effort value for display on the selected scale, to one decimal — the single
     * helper every Effort read-out (Today tile, Intelligence, Live, Trends, Workouts) routes through so
     * the toggle reaches all of them at once. The stored value is unchanged; only the display converts.
     */
    fun effortDisplay(value: Double, scale: EffortScale): String =
        oneDecimal(effortValue(value, scale))

    /** The "out of" denominator label for the selected Effort scale — "100" or "21". */
    fun effortScaleMax(scale: EffortScale): String =
        if (scale == EffortScale.WHOOP) "21" else "100"

    // MARK: Helpers

    private fun oneDecimal(v: Double): String = String.format(Locale.US, "%.1f", v)

    private fun decimalString(v: Double, decimals: Int): String =
        if (decimals == 0) "${v.roundToInt()}" else String.format(Locale.US, "%.${decimals}f", v)
}
