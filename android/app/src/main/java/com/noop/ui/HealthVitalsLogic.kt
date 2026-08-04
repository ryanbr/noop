package com.noop.ui

import androidx.compose.ui.graphics.Color
import com.noop.R
import com.noop.analytics.Baselines
import com.noop.analytics.VitalBands
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

internal data class Vital(
    val key: String,
    val label: String,
    val unit: String,
    val value: Double?,
    val format: (Double) -> String,
    val deltaText: String? = null,
    val readingDay: String? = null,
    val asOfLabel: String? = null,
    val rangeCaption: String? = null,
    /** Metric-specific "no value" line, shown in place of a bare "No data" when nothing resolved, so an
     *  empty tile still says WHY. Required (no default) so a new vital must state its own reason.
     *  Kotlin twin of `BodyVitalReading.missingCaption` (VitalSignsSummary.swift) — same wording. */
    val missingCaption: String,
    /** Personal-baseline banding (population fallback until 14 trusted nights). */
    val banding: VitalBands.Result,
    /** The metric's category colour (used only when in range). */
    val metricColor: Color,
    /** Trailing values (oldest → newest) for the tile's metric-tinted sparkline trail, matching
     *  Today's Key-Metrics tiles. Presentation-only; defaulted so existing call sites compile. */
    val sparkline: List<Double> = emptyList(),
) {
    /** Value with its unit appended, or null when no data. */
    val formattedValue: String? = value?.let { "${format(it)} $unit" }

    /** Colour communicates state: in-range = the metric's category colour,
     *  out-of-range = warning amber, no data = tertiary. */
    val accent: Color = when (banding.band) {
        VitalBands.Band.NO_DATA -> Palette.textTertiary
        VitalBands.Band.IN_RANGE -> metricColor
        VitalBands.Band.OUT_OF_RANGE -> Palette.statusWarning
    }

    /** The in-range caption that stands in for a StatePill inside the fixed-height tile.
     *  The wording says which yardstick judged it: your baseline vs typical ranges. */
    val stateCaption: String = when {
        // Raw SpO₂ is a device-dependent ADC, not a clinical value — never claim an in/out-of-range
        // judgment. Show a plain "uncalibrated" note when a value decoded. (#93)
        key == "spo2raw" && banding.band != VitalBands.Band.NO_DATA -> "Uncalibrated"
        // Nothing resolved: say WHY this tile is empty rather than a bare "No data", which reads as a
        // bug for metrics NOOP cannot derive from a strap at all (the calibrated SpO₂ % is import-only:
        // AnalyticsEngine writes spo2Pct = null on purpose, see Spo2ReTrace). Ports the Apple behaviour
        // (`guard let day else { return missingCaption }`) — Android showed "No data" for every case.
        banding.band == VitalBands.Band.NO_DATA -> missingCaption
        banding.basis == VitalBands.Basis.PERSONAL ->
            if (banding.band == VitalBands.Band.IN_RANGE) "In your range" else "Off your baseline"
        else ->
            if (banding.band == VitalBands.Band.IN_RANGE) "In typical range" else "Outside typical range"
    }

    val accessibilityText: String =
        formattedValue?.let {
            listOfNotNull("$label: $it", asOfLabel, stateCaption).joinToString(", ")
        } ?: "$label: no data"
}

/**
 * Which "no value" line the Blood O₂ tile shows, given whether that night decoded raw red/IR counts.
 *
 * Two different empty states, and conflating them is what sends people to the forums. When the night HAS
 * raw counts the strap's Blood-O₂ sensor plainly worked — only the CALIBRATED % is missing, because WHOOP
 * derives that in their cloud from the raw ADCs and NOOP will not fabricate one (`spo2Pct` is import-only;
 * see `Spo2ReTrace`, and the #194 PPG→HR withdrawal for why). Showing "No SpO₂ import or Health value"
 * there reads as "your sensor recorded nothing" — directly beside a Raw SpO₂ tile displaying a live
 * number, which is exactly the contradiction that gets reported as a broken strap.
 *
 * Split out as a pure function purely so it is TESTABLE: `vitalsFor` resolves strings through
 * `NoopApplication`, so nothing in this file can run in a JVM unit test. The branch is the part worth
 * pinning; the resource lookup is not.
 */
internal fun spo2MissingCaptionRes(hasRawSpo2: Boolean): Int =
    if (hasRawSpo2) R.string.l10n_health_screen_raw_counts_only_needs_an_import_d0e33552
    else R.string.l10n_health_screen_no_spo_import_or_health_value_408f8c55

internal enum class VitalCaptionMode {
    AS_OF,
    RANGE,
}

/** Build the vitals, banded against the user's OWN trailing baseline once 14 trusted
 *  nights exist (population ranges before that — VitalBands does the deciding). */
internal fun vitalsFor(
    d: DailyMetric?,
    days: List<DailyMetric>,
    tempUnit: TemperatureUnit = TemperatureUnit.CELSIUS,
): List<Vital> {
    val todayKey = d?.day
    // History strictly before the displayed day, oldest→newest (recentDays is already
    // oldest→newest); calendar-padded so wear gaps count as missing nights (a stale
    // baseline then falls back to the population range).
    val history = days.filter { row -> todayKey == null || row.day < todayKey }
    fun series(selector: (DailyMetric) -> Double?): List<Double?> =
        VitalBands.calendarSeries(history.map { it.day to selector(it) })
    fun previous(selector: (DailyMetric) -> Double?): Double? =
        history.asReversed().asSequence().mapNotNull(selector).firstOrNull()
    fun deltaText(current: Double?, previous: Double?, decimals: Int = 1): String? {
        if (current == null || previous == null) return null
        val diff = current - previous
        val sign = if (diff >= 0.0) "+" else "-"
        val mag = kotlin.math.abs(diff)
        val num = if (decimals == 0) mag.roundToInt().toString()
        else String.format(Locale.US, "%.${decimals}f", mag)
        return "($sign$num)"
    }
    fun rangeCaption(allValues: List<Double>, unit: String, format: (Double) -> String): String? {
        val min = allValues.minOrNull() ?: return null
        val max = allValues.maxOrNull() ?: return null
        return "within ${format(min)} -- ${format(max)} $unit"
    }
    // Trailing values (oldest → newest) feeding each tile's sparkline trail. Built from the same
    // history already gathered for banding, including the displayed day's value. Presentation-only.
    fun trail(current: Double?, window: Int = 14, selector: (DailyMetric) -> Double?): List<Double> =
        (history.mapNotNull(selector) + listOfNotNull(current)).takeLast(window)

    // Skin temp is bimodal: CSV imports store ABSOLUTE °C, the on-device pipeline a ±°C
    // DEVIATION — partition the history to the displayed value's kind and pick the matching
    // config + population fallback (±0.6 °C mirrors the illness watch's flag threshold).
    // This also fixes the live bug where a strap-computed +0.2 °C deviation read
    // "Out of range" against the 33–36 absolute band.
    val skin = d?.skinTempDevC
    // Track which kind the value is so the temperature converter picks the right rule: an ABSOLUTE
    // reading uses the full C→F formula (×9/5 + 32); a ±DEVIATION must omit the offset.
    val skinIsAbsolute = skin?.let { VitalBands.isAbsoluteSkinTemp(it) } ?: true
    val skinResult: VitalBands.Result = if (skin == null) {
        VitalBands.Result(VitalBands.Band.NO_DATA, VitalBands.Basis.POPULATION, 0)
    } else {
        VitalBands.band(
            value = skin,
            history = VitalBands.skinTempHistory(skin, series { it.skinTempDevC }),
            populationRange = if (skinIsAbsolute) 33.0..36.0 else -0.6..0.6,
            cfg = if (skinIsAbsolute) Baselines.metricCfg.getValue("skin_temp") else VitalBands.skinTempDeviationCfg,
        )
    }
    // Resolve the skin-temp label + converter once, honouring the °C/°F preference. `Vital.formattedValue`
    // appends `unit`, so strip the trailing " °C/°F" the formatter adds.
    val skinUnitLabel = UnitFormatter.temperatureUnit(tempUnit)
    val skinFormat: (Double) -> String = { c ->
        val full = if (skinIsAbsolute) {
            UnitFormatter.temperatureFromCelsius(c, tempUnit, decimals = 1)
        } else {
            UnitFormatter.temperatureDeltaFromCelsius(c, tempUnit, decimals = 1)
        }
        full.removeSuffix(" $skinUnitLabel")
    }
    val previousSkin = history.asReversed().asSequence()
        .mapNotNull { row -> row.skinTempDevC?.takeIf { VitalBands.isAbsoluteSkinTemp(it) == skinIsAbsolute } }
        .firstOrNull()
    val respRangeCaption = rangeCaption(days.mapNotNull { it.respRateBpm }, "rpm") { String.format(Locale.US, "%.1f", it) }
    val spo2RangeCaption = rangeCaption(days.mapNotNull { it.spo2Pct }, "%") { String.format(Locale.US, "%.0f", it) }
    val rhrRangeCaption = rangeCaption(days.mapNotNull { it.restingHr?.toDouble() }, "bpm") { it.roundToInt().toString() }
    val hrvRangeCaption = rangeCaption(days.mapNotNull { it.avgHrv }, "ms") { it.roundToInt().toString() }
    val skinRangeCaption = rangeCaption(
        days.mapNotNull { row ->
            row.skinTempDevC?.takeIf { VitalBands.isAbsoluteSkinTemp(it) == skinIsAbsolute }
        },
        skinUnitLabel,
        skinFormat,
    )
    // WHOOP 4.0 raw SpO₂: the (red + IR) / 2 ADC mean per night, present only when both channels
    // decoded for the day. Averaged for a single "signal decoded" tile; both channels stay in the DB. (#93)
    val spo2RawMean: (DailyMetric) -> Double? = { row ->
        if (row.spo2Red != null && row.spo2Ir != null) (row.spo2Red + row.spo2Ir) / 2.0 else null
    }
    val spo2rawRangeCaption =
        rangeCaption(days.mapNotNull(spo2RawMean), "ADC") { String.format(Locale.US, "%.0f", it) }
    return listOf(
        Vital(
            key = "resp", label = uiString(R.string.l10n_health_screen_resp_rate_1c48dbd8), unit = "rpm",
            missingCaption = "No respiratory-rate value",
            value = d?.respRateBpm, format = { String.format("%.1f", it) },
            deltaText = deltaText(d?.respRateBpm, previous { it.respRateBpm }),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            rangeCaption = respRangeCaption,
            banding = VitalBands.band(d?.respRateBpm, series { it.respRateBpm }, 12.0..20.0, Baselines.respCfg),
            metricColor = Palette.metricCyan,
            sparkline = trail(d?.respRateBpm) { it.respRateBpm },
        ),
        Vital(
            key = "spo2", label = uiString(R.string.l10n_health_screen_blood_o_9bf5ed9b), unit = "%",
            // The condition is EXACTLY the Raw SpO₂ tile's own value expression (`d?.let(spo2RawMean)`,
            // below) and must stay that way: the caption's claim is "the tile beside this one is
            // showing a number", so if the two expressions drift, this says the sensor recorded on a
            // night where the neighbouring tile is blank. The platforms pick that row differently —
            // Android per selected day, Apple `logicalDay ?? most recent` — so the ROW is not the
            // parity contract here; the relationship between the two tiles is.
            missingCaption = uiString(spo2MissingCaptionRes(d?.let(spo2RawMean) != null)),
            value = d?.spo2Pct, format = { String.format("%.0f", it) },
            deltaText = deltaText(d?.spo2Pct, previous { it.spo2Pct }, decimals = 0),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            rangeCaption = spo2RangeCaption,
            // Population-only on purpose: an absolute <95% floor is meaningful regardless
            // of personal baseline (no "spo2" MetricCfg exists).
            banding = VitalBands.band(d?.spo2Pct, emptyList(), 95.0..100.0, null),
            metricColor = Palette.metricCyan,
            sparkline = trail(d?.spo2Pct) { it.spo2Pct },
        ),
        Vital(
            // Issue #93: WHOOP 4.0 raw SpO₂ PPG ADC mean (red+IR)/2 per night. NOT a calibrated
            // blood-oxygen % — that needs WHOOP's proprietary curve. Shown as RAW ADC so users can SEE
            // the sensor data decoded, without fabricating a clinical-looking number. Banding over the
            // full u16 span just keeps the tile cyan (never "off range"); `stateCaption` labels it
            // uncalibrated, so we never assert an in/out-of-range clinical judgment on raw sensor data.
            key = "spo2raw", label = uiString(R.string.l10n_health_screen_raw_spo_ccfe80c1), unit = "ADC",
            missingCaption = "No raw SpO₂ decode for the night",
            value = d?.let(spo2RawMean), format = { String.format("%.0f", it) },
            deltaText = deltaText(d?.let(spo2RawMean), previous(spo2RawMean), decimals = 0),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            rangeCaption = spo2rawRangeCaption,
            banding = VitalBands.band(d?.let(spo2RawMean), emptyList(), 0.0..65535.0, null),
            metricColor = Palette.metricCyan,
            sparkline = trail(d?.let(spo2RawMean)) { spo2RawMean(it) },
        ),
        Vital(
            key = "rhr", label = uiString(R.string.l10n_health_screen_resting_hr_26677094), unit = "bpm",
            missingCaption = "No resting HR value",
            value = d?.restingHr?.toDouble(), format = { it.roundToInt().toString() },
            deltaText = deltaText(d?.restingHr?.toDouble(), previous { it.restingHr?.toDouble() }, decimals = 0),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            rangeCaption = rhrRangeCaption,
            banding = VitalBands.band(
                d?.restingHr?.toDouble(), series { it.restingHr?.toDouble() }, 40.0..60.0,
                Baselines.restingHRCfg,
            ),
            metricColor = Palette.metricRose,
            sparkline = trail(d?.restingHr?.toDouble()) { it.restingHr?.toDouble() },
        ),
        Vital(
            key = "hrv", label = "HRV", unit = "ms",
            missingCaption = "No HRV value",
            value = d?.avgHrv, format = { it.roundToInt().toString() },
            deltaText = deltaText(d?.avgHrv, previous { it.avgHrv }, decimals = 0),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            rangeCaption = hrvRangeCaption,
            banding = VitalBands.band(d?.avgHrv, series { it.avgHrv }, 40.0..120.0, Baselines.hrvCfg),
            metricColor = Palette.metricPurple,
            sparkline = trail(d?.avgHrv) { it.avgHrv },
        ),
        Vital(
            key = "skin", label = uiString(R.string.l10n_health_screen_skin_temp_a4affc5a), unit = skinUnitLabel,
            missingCaption = "No nightly skin-temp value",
            value = skin, format = skinFormat,
            deltaText = deltaText(skin, previousSkin),
            readingDay = todayKey,
            asOfLabel = asOfLabel(todayKey),
            rangeCaption = skinRangeCaption,
            banding = skinResult, metricColor = Palette.metricAmber,
            // Keep the trail on the displayed value's kind — absolute °C and ±deviation must not mix.
            sparkline = trail(skin) { row ->
                row.skinTempDevC?.takeIf { VitalBands.isAbsoluteSkinTemp(it) == skinIsAbsolute }
            },
        ),
    )
}

internal fun latestVitals(days: List<DailyMetric>, tempUnit: TemperatureUnit): List<Vital> {
    val emptyByKey = vitalsFor(null, days, tempUnit).associateBy { it.key }
    return listOf(
        latestVital("resp", days, tempUnit, emptyByKey) { it.respRateBpm != null },
        latestVital("spo2", days, tempUnit, emptyByKey) { it.spo2Pct != null },
        latestVital("spo2raw", days, tempUnit, emptyByKey) { it.spo2Red != null && it.spo2Ir != null },
        latestVital("rhr", days, tempUnit, emptyByKey) { it.restingHr != null },
        latestVital("hrv", days, tempUnit, emptyByKey) { it.avgHrv != null },
        latestVital("skin", days, tempUnit, emptyByKey) { it.skinTempDevC != null },
    )
}

private fun latestVital(
    key: String,
    days: List<DailyMetric>,
    tempUnit: TemperatureUnit,
    emptyByKey: Map<String, Vital>,
    hasValue: (DailyMetric) -> Boolean,
): Vital {
    val row = days.asReversed().firstOrNull(hasValue)
    return row
        ?.let { latestRow -> vitalsFor(latestRow, days, tempUnit).firstOrNull { it.key == key } }
        ?.copy(asOfLabel = asOfLabel(row.day))
        ?: emptyByKey.getValue(key)
}

internal fun selectedDayLabel(offset: Int): String = when (offset) {
    0 -> "Today"
    1 -> "Yesterday"
    else -> "2 days ago"
}

internal fun missingVitalsTitle(offset: Int): String = when (offset) {
    0 -> "We didn't get today's data"
    1 -> "We didn't get yesterday's data"
    else -> "We didn't get data from 2 days ago"
}

internal fun asOfLabel(day: String?): String? {
    if (day.isNullOrBlank()) return null
    val date = runCatching { LocalDate.parse(day) }.getOrNull() ?: return "as of $day"
    val today = LocalDate.now()
    return when (date) {
        today -> "as of today"
        today.minusDays(1) -> "as of yesterday"
        else -> "as of ${date.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))}"
    }
}
