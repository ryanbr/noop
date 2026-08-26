package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowDropUp
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.data.DailyMetric
import com.noop.data.MoodStore
import com.noop.data.WhoopRepository
import com.noop.ingest.NutritionCsvImporter
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Explore (Metric Explorer)
//
// Port of the macOS MetricExplorerView focus: a metric picker → a hero LineChart of
// the chosen metric over a selectable window → a uniform StatTile row of summary
// stats (Average / Min / Max / Latest / Δ vs previous window).
//
// On macOS the catalog is driven by a shared MetricCatalog with per-metric formatters
// and a cross-catalog Pearson correlation sweep. On Android the daily metrics we hold
// are the built-in DailyMetric columns (recovery / strain / hrv / rhr / sleep / spo2 /
// respiratory / efficiency) plus any extra long-format keys in the metricSeries table.
// We expose exactly those as the picker, so there is no faked data: every chartable
// metric maps to a real cached series.
//
// macOS "sparse-window" rule preserved: a window is taken RELATIVE TO THE LATEST data
// point (not "now"); if the selected window holds ≥1 point we show it, and only when it
// holds ZERO points do we auto-widen to the smallest larger range that does. The hero
// always reads the latest available point + "as of <day>".

// MARK: - Window range (W / M / 3M / 6M / 1Y / ALL)

private enum class ExploreRange(val days: Int?, val label: String, val windowName: String) {
    Week(7, "W", "week"),
    Month(30, "M", "month"),
    Quarter(90, "3M", "quarter"),
    Half(180, "6M", "6 months"),
    Year(365, "1Y", "year"),
    All(null, "ALL", "all time");

    /** This range plus every larger range, ascending , the auto-widen search order. */
    val widening: List<ExploreRange>
        get() = entries.dropWhile { it != this }

    /** True when this range can reach PAST the bounded dashboard cap (WhoopRepository.RECENT_DAYS_CAP),
     *  so the built-in series must come from the UNCAPPED full history rather than the bounded `recentDays`
     *  flow to avoid silently truncating a deep import (#797 Explore-'All' follow-up). Only the open-ended
     *  'All' range ([days] == null) does; every fixed range is ≤ the cap, so it keeps using the cheap flow. */
    val reachesDeep: Boolean get() = days == null || days > WhoopRepository.RECENT_DAYS_CAP
}

// MARK: - Metric descriptor (Android analogue of MetricCatalog's MetricDescriptor)

/**
 * One chartable metric: how to label/format it, its accent, and where its series comes
 * from. [dailyPick] is non-null for built-in DailyMetric columns; otherwise the series
 * is loaded from the metricSeries table under [seriesKey].
 */
private data class MetricSpec(
    val key: String,
    val title: String,
    val unit: String,
    val category: String,
    val accent: Color,
    val higherIsBetter: Boolean?,
    val decimals: Int = 0,
    val dailyPick: ((DailyMetric) -> Double?)? = null,
    val seriesKey: String? = null,
    /** Source (deviceId) the [seriesKey] lives under when it is NOT the strap's own , e.g. the
     *  nutrition-csv import or the noop-mood check-in write under dedicated source ids (v2.2.0
     *  parity with the macOS MetricCatalog, whose descriptors carry key+source). */
    val seriesSource: String? = null,
    /** A short localized one-liner (the Explore header subtitle / catalog blurb). Only the
     *  three headline scores , Charge / Effort / Rest , carry one today; everything else is null.
     *  Mirrors macOS `MetricDescriptor.description`. */
    val description: String? = null,
    /** Effort display scale (#268) , only meaningful for the "strain" column, where it converts the
     *  stored 0–100 value + unit onto WHOOP's 0–21 axis. Default 0–100 leaves every other column alone. */
    val effortScale: EffortScale = EffortScale.HUNDRED,
) {
    /** True for the Effort column when the user picked WHOOP's 0–21 scale (the only value-converting case). */
    private val whoopEffort: Boolean get() = key == "strain" && effortScale == EffortScale.WHOOP

    /** The unit label, swapped to "/21" for the Effort column on the WHOOP scale. */
    val displayUnit: String get() = if (whoopEffort) "/21" else unit

    fun format(v: Double): String {
        if (!v.isFinite()) return ","
        // Effort (#268): the stored value is 0–100; convert to 0–21 for display when that scale is picked.
        val shown = if (whoopEffort) UnitFormatter.effortValue(v, EffortScale.WHOOP) else v
        val n = if (decimals == 0) "${shown.roundToInt()}" else String.format(Locale.US, "%.${decimals}f", shown)
        return if (displayUnit.isEmpty()) n else "$n $displayUnit"
    }
}

/** The built-in DailyMetric-backed metrics, in the macOS ordering (Charge first). */
private val builtInMetrics: List<MetricSpec> = listOf(
    MetricSpec(
        key = "recovery", title = uiString(R.string.l10n_trends_explore_screen_charge_d4e1aee4), unit = "%", category = uiString(R.string.explore_category_charge),
        accent = Palette.accent, higherIsBetter = true, decimals = 0,
        dailyPick = { it.recovery },
        description = uiString(R.string.explore_description_charge),
    ),
    MetricSpec(
        key = "strain", title = uiString(R.string.l10n_trends_explore_screen_effort_8c974bc6), unit = "/100", category = uiString(R.string.explore_category_effort),
        accent = Palette.strain066, higherIsBetter = null, decimals = 1,
        dailyPick = { it.strain },
        description = uiString(R.string.explore_description_effort),
    ),
    MetricSpec(
        key = "hrv", title = "HRV", unit = "ms", category = uiString(R.string.explore_category_charge),
        accent = Palette.metricPurple, higherIsBetter = true, decimals = 0,
        dailyPick = { it.avgHrv },
    ),
    MetricSpec(
        key = "rhr", title = uiString(R.string.l10n_trends_explore_screen_resting_hr_26677094), unit = "bpm", category = uiString(R.string.explore_category_charge),
        accent = Palette.metricRose, higherIsBetter = false, decimals = 0,
        dailyPick = { it.restingHr?.toDouble() },
    ),
    MetricSpec(
        key = "sleep", title = uiString(R.string.l10n_trends_explore_screen_sleep_3cac34e6), unit = "h", category = uiString(R.string.explore_category_rest),
        // Rest-score accent rides the reset accent token (iOS metricAccent maps every Rest metric ,
        // sleep_performance / sleep_total_min , to StrandPalette.accent), not a stray metric hue.
        accent = Palette.accent, higherIsBetter = true, decimals = 1,
        dailyPick = { it.totalSleepMin?.let { m -> m / 60.0 } },
        description = uiString(R.string.explore_description_rest),
    ),
    MetricSpec(
        key = "efficiency", title = uiString(R.string.l10n_trends_explore_screen_sleep_efficiency_b4b5c293), unit = "%", category = uiString(R.string.explore_category_rest),
        accent = Palette.accent, higherIsBetter = true, decimals = 0,
        dailyPick = { it.efficiency },
    ),
    MetricSpec(
        key = "spo2", title = uiString(R.string.l10n_trends_explore_screen_blood_oxygen_a8ad9ff5), unit = "%", category = uiString(R.string.explore_category_health),
        accent = Palette.metricCyan, higherIsBetter = true, decimals = 0,
        dailyPick = { it.spo2Pct },
    ),
    MetricSpec(
        key = "resp", title = uiString(R.string.l10n_trends_explore_screen_respiratory_rate_3fbb532f), unit = "rpm", category = uiString(R.string.explore_category_health),
        accent = Palette.accent, higherIsBetter = null, decimals = 1,
        dailyPick = { it.respRateBpm },
    ),
)

/** Proper titles/units/categories for series-backed keys written by the importers and the Mind
 *  check-in , matching the macOS MetricCatalog entries exactly (v2.2.0 parity). seriesKey/
 *  seriesSource are filled in at discovery time. */
private val knownSeriesMetrics: Map<String, MetricSpec> = mapOf(
    // #605/#608: imported avg/max HR is written to metricSeries (Apple Health / WHOOP CSV / Xiaomi) and
    // the Compare screen exposes it, but Explore's picker didn't , iOS MetricCatalog has had both. Series-
    // backed (no DailyMetric column), "Heart" category, parity. (Strap-only per-second HR lives in the
    // Deep Timeline; this surfaces the per-day avg/max for imported sources.)
    "avg_hr" to MetricSpec("avg_hr", uiString(R.string.explore_metric_average_heart_rate), "bpm", uiString(R.string.explore_category_heart),
        Palette.metricRose, null, 0),
    "max_hr" to MetricSpec("max_hr", uiString(R.string.explore_metric_max_heart_rate), "bpm", uiString(R.string.explore_category_heart),
        Palette.metricRose, null, 0),
    "calories_in" to MetricSpec("calories_in", uiString(R.string.explore_metric_calories_in), "kcal", uiString(R.string.explore_category_nutrition),
        Palette.metricAmber, null, 0),
    "protein_g" to MetricSpec("protein_g", uiString(R.string.explore_metric_protein), "g", uiString(R.string.explore_category_nutrition),
        Palette.metricCyan, null, 0),
    "carbs_g" to MetricSpec("carbs_g", uiString(R.string.explore_metric_carbs), "g", uiString(R.string.explore_category_nutrition),
        Palette.metricCyan, null, 0),
    "fat_g" to MetricSpec("fat_g", uiString(R.string.explore_metric_fat), "g", uiString(R.string.explore_category_nutrition),
        Palette.metricCyan, null, 0),
    "mood" to MetricSpec("mood", uiString(R.string.explore_metric_mood), "/5", uiString(R.string.explore_category_mind),
        Palette.metricPurple, true, 0),
)

// MARK: - A loaded series point (day string + value), oldest first.

private data class SeriesPoint(val day: String, val value: Double)

/** Lightweight ordinal day index for slicing windows without date parsing. The series is
 *  already sorted ascending by day (YYYY-MM-DD), so the trailing N entries are the window;
 *  we slice by RELATIVE-TO-LATEST count, matching the macOS day-distance window closely
 *  enough for the per-day daily cache (one row per day). */
private fun List<SeriesPoint>.windowFor(range: ExploreRange): List<SeriesPoint> {
    val days = range.days ?: return this
    if (isEmpty()) return emptyList()
    return takeLast(days)
}

// MARK: - Summary stats over a window

private data class Stat(val n: Int, val mean: Double, val min: Double, val max: Double)

private fun statOf(values: List<Double>): Stat {
    val v = values.filter { it.isFinite() }
    if (v.isEmpty()) return Stat(0, Double.NaN, Double.NaN, Double.NaN)
    return Stat(v.size, v.sum() / v.size, v.min(), v.max())
}

// MARK: - Screen

@Composable
fun TrendsExploreScreen(vm: AppViewModel) {
    // The Deep Timeline (#575) is presented INLINE from Explore , no NavHost route needed, so this stays
    // self-contained in the Explore entry-point file. System back / the in-screen reset returns here.
    var showDeepTimeline by remember { mutableStateOf(false) }
    if (showDeepTimeline) {
        FullDayChartScreen(vm = vm, onBack = { showDeepTimeline = false })
        return
    }

    // The registry's ACTIVE strap id (SPINE / #814): the daysMerged / metricKeys reads resolve the
    // active-id ∪ canonical "my-whoop" union, so a re-added strap's data and the canonical import both
    // surface. A single-WHOOP install resolves this to "my-whoop", so the reads are byte-identical there.
    val deviceId = vm.activeStrapId
    val recentDays by vm.recentDays.collectAsStateWithLifecycle()

    // #797 follow-up (Explore 'All' truncation): `recentDays` is the BOUNDED dashboard flow (capped at
    // WhoopRepository.RECENT_DAYS_CAP), so a 3000+ day import would silently show only the most-recent ~800
    // days under the 'All' / 1Y ranges, which have no other full-history escape hatch. Mirror the uncapped
    // full-history path TrendsScreen already uses: load the merged daily history ONCE, and back the built-in
    // series off it whenever the effective range reaches into the deep past. Until it lands we fall back to
    // `recentDays` so the screen is populated on the first frame; the default (shallow-range) refresh keeps
    // using the cheap bounded flow, so the cap is NOT raised (#797 stays fixed). Same merge as the dashboard.
    var fullHistory by remember { mutableStateOf<List<DailyMetric>?>(null) }
    LaunchedEffect(deviceId) {
        fullHistory = runCatching { vm.repo.daysMerged(deviceId) }.getOrNull()
    }

    // Extra long-format keys from the metricSeries table (anything beyond the built-ins) , from the
    // strap source AND the dedicated import/check-in sources, which write under their OWN deviceIds
    // (nutrition-csv, noop-mood) and were invisible to a strap-only key scan (v2.2.0 parity).
    var extraKeys by remember { mutableStateOf<List<Pair<String, String?>>>(emptyList()) }
    LaunchedEffect(deviceId) {
        // Scan the strap's series keys across the active-id ∪ canonical "my-whoop" union (SPINE / #814), so a
        // re-added strap still discovers the keys the canonical import/engine wrote. `seriesSource = null`
        // keeps these resolving against the strap path below; a single-WHOOP install scans just "my-whoop".
        val strap = WhoopRepository.importedSourceIdsFor(deviceId)
            .flatMap { id -> runCatching { vm.repo.metricKeys(id) }.getOrDefault(emptyList()) }
            .distinct()
            .map { it to null as String? }
        val sourced = listOf(NutritionCsvImporter.SOURCE_ID, MoodStore.MOOD_DEVICE_ID).flatMap { src ->
            runCatching { vm.repo.metricKeys(src) }.getOrDefault(emptyList()).map { it to (src as String?) }
        }
        extraKeys = strap + sourced
    }

    // The full picker: built-ins first, then any extra metricSeries keys not already covered.
    // Known import/check-in keys get their proper titles/units/categories (matching the macOS
    // MetricCatalog); anything else falls back to a prettified key under "Other".
    val metrics = remember(extraKeys) {
        val builtInKeys = builtInMetrics.map { it.key }.toSet()
        val extras = extraKeys
            .filter { (k, _) -> k !in builtInKeys }
            .distinctBy { (k, src) -> "$src:$k" }
            .map { (k, src) ->
                val known = knownSeriesMetrics[k]
                known?.copy(seriesKey = k, seriesSource = src) ?: MetricSpec(
                    key = k,
                    title = k.replace('_', ' ').replaceFirstChar { c -> c.uppercase() },
                    unit = "",
                    category = "Other",
                    accent = Palette.metricCyan,
                    higherIsBetter = null,
                    decimals = 1,
                    seriesKey = k,
                    seriesSource = src,
                )
            }
        builtInMetrics + extras
    }

    // Effort display scale (#268) , carried on the selected spec so the Effort column's value + unit
    // follow the toggle through every read-out (hero, footer stats, Y-axis). Display-only.
    val effortScale = UnitPrefs.effortScale(LocalContext.current)

    var selectedKey by remember { mutableStateOf(builtInMetrics.first().key) }
    var range by remember { mutableStateOf(ExploreRange.Month) }
    val selected = (metrics.firstOrNull { it.key == selectedKey } ?: metrics.first())
        .copy(effortScale = effortScale)

    // Build the full ascending series for the selected metric. Built-ins come off the daily history;
    // metricSeries-backed metrics are loaded on demand.
    //
    // #797 Explore-'All' fix: for a deep range ([ExploreRange.reachesDeep]) back the built-in series off the
    // UNCAPPED `fullHistory` once it has loaded, so 'All' shows the WHOLE import instead of the most-recent
    // ~RECENT_DAYS_CAP days; until it lands (and for every shallow range) use the cheap bounded `recentDays`
    // flow, so the default dashboard refresh path is unchanged and the cap is not raised.
    val builtInDays = if (range.reachesDeep) (fullHistory ?: recentDays) else recentDays
    var seriesKeyLoaded by remember { mutableStateOf<String?>(null) }
    var loadedSeries by remember { mutableStateOf<List<SeriesPoint>>(emptyList()) }
    LaunchedEffect(selected.key, builtInDays) {
        val pick = selected.dailyPick
        if (pick != null) {
            loadedSeries = builtInDays.mapNotNull { d ->
                pick(d)?.takeIf { it.isFinite() }?.let { SeriesPoint(d.day, it) }
            }
            seriesKeyLoaded = selected.key
        } else if (selected.seriesKey != null) {
            // Series-backed metrics live under their own source id when imported/checked-in (nutrition-csv,
            // noop-mood): read from that source. A STRAP series (seriesSource == null) is read across the
            // active-id ∪ canonical "my-whoop" union (SPINE / #814), deduped per day with the active id
            // winning, so a re-added strap still shows the canonically-stored series; a single-WHOOP install
            // reads just "my-whoop" (v2.2.0 parity).
            val explicitSource = selected.seriesSource
            val rows = runCatching {
                if (explicitSource != null) {
                    vm.repo.metricSeries(explicitSource, selected.seriesKey, "0000-00-00", "9999-99-99")
                        .map { SeriesPoint(it.day, it.value) }
                } else {
                    val byDay = LinkedHashMap<String, Double>()
                    // Active id first ⇒ wins the day; canonical only fills days the active id lacks.
                    for (id in WhoopRepository.importedSourceIdsFor(deviceId)) {
                        for (r in vm.repo.metricSeries(id, selected.seriesKey, "0000-00-00", "9999-99-99")) {
                            byDay.putIfAbsent(r.day, r.value)
                        }
                    }
                    byDay.entries.sortedBy { it.key }.map { SeriesPoint(it.key, it.value) }
                }
            }.getOrDefault(emptyList())
            loadedSeries = rows
            seriesKeyLoaded = selected.key
        } else {
            loadedSeries = emptyList()
            seriesKeyLoaded = selected.key
        }
    }

    // Resolve the active window with the macOS sparse-widen rule.
    val series = if (seriesKeyLoaded == selected.key) loadedSeries else emptyList()
    val effectiveRange = remember(series, range) {
        if (series.isEmpty()) range
        else range.widening.firstOrNull { series.windowFor(it).isNotEmpty() } ?: ExploreRange.All
    }
    val windowed = remember(series, effectiveRange) { series.windowFor(effectiveRange) }
    val fellBack = effectiveRange != range

    // PERF (#707): lazy scaffold so only the on-screen rows (the hero chart card especially) compose +
    // are accessibility-walked on scroll. Each top-level child is one `item { }` in the same order; the
    // conditional empty-state note uses `if (cond) { item {} }` so it adds no row when hidden. No standalone
    // Spacers here , the LazyColumn's `spacedBy(20.dp)` reproduces the eager column's row spacing exactly.
    LazyScreenScaffold(title = stringResource(R.string.nav_explore), subtitle = stringResource(R.string.explore_subtitle)) {

        // The headline tap-through (#575): a full-day, full-resolution, zoomable timeline. Sits above the
        // per-metric catalog because it's a different kind of view , every second of one day, not one
        // number per day. Mirrors the macOS MetricExplorerView "Deep Timeline" hero row.
        item { DeepTimelineEntry(onClick = { showDeepTimeline = true }) }

        // Nothing to explore until history is imported , lead with the verbatim note so
        // the empty picker/chart below is explained.
        if (series.isEmpty()) {
            item {
            DataPendingNote(
                title = stringResource(R.string.explore_import_title),
                body = stringResource(R.string.explore_import_body),
            )
            }
        }

        // METRIC PICKER , a dropdown replacing the old horizontal chip row.
        item {
        MetricDropdown(
            metrics = metrics,
            selected = selected,
            onSelect = { selectedKey = it },
        )
        }

        // RANGE BAR , overline + title + the one segmented window control, with a caption
        // that flags a sparse auto-widen.
        item {
        Row(verticalAlignment = Alignment.Top) {
            Column(modifier = Modifier.weight(1f)) {
                Overline(selected.category)
                Text(selected.title, style = NoopType.title2, color = Palette.textPrimary)
                // The plain-English one-liner for the three headline scores (Charge/Effort/Rest);
                // null for every other metric, so only the scores show a subtitle here.
                selected.description?.let { blurb ->
                    Text(
                        blurb,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.padding(top = Metrics.space2),
                    )
                }
            }
            SegmentedPillControl(
                items = ExploreRange.entries.toList(),
                selection = range,
                label = { it.label },
                onSelect = { range = it },
            )
        }
        }
        item {
        Text(
            text = rangeCaption(series, windowed, range, effectiveRange, fellBack),
            style = NoopType.footnote,
            color = if (fellBack) Palette.statusWarning else Palette.textTertiary,
        )
        }

        // HERO CHART , line over the window + latest "as of" read-out in the card.
        item {
        HeroChartCard(
            metric = selected,
            windowed = windowed,
            latest = series.lastOrNull(),
            effectiveRange = effectiveRange,
            range = range,
            fellBack = fellBack,
        )
        }

        // STAT ROW , Average / Min / Max / Latest / Δ vs previous window.
        item {
        StatRow(
            metric = selected,
            series = series,
            windowed = windowed,
            effectiveRange = effectiveRange,
        )
        }
    }
}

// MARK: - Deep Timeline entry (#575)

/** The hero entry that opens the Deep Timeline , a full-bleed card above the per-metric catalog. */
@Composable
private fun DeepTimelineEntry(onClick: () -> Unit) {
    NoopCard(modifier = Modifier.clickable(onClick = onClick)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(42.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(Palette.metricRose.copy(alpha = StrandAlpha.chartFillStrong)),
                contentAlignment = Alignment.Center,
            ) {
                Text("∿", style = NoopType.title2, color = Palette.metricRose)
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.deep_timeline_title), style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    stringResource(R.string.explore_deep_timeline_hint),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Metric picker dropdown

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MetricDropdown(
    metrics: List<MetricSpec>,
    selected: MetricSpec,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val grouped = remember(metrics) { metrics.groupBy { it.category } }
    val shape = RoundedCornerShape(Metrics.cornerSm)

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor()
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(Metrics.divider, Palette.accent.copy(alpha = StrandAlpha.selectedBorder), shape)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(selected.accent))
            Column(modifier = Modifier.weight(1f)) {
                Overline(selected.category, color = Palette.textTertiary)
                Text(selected.title, style = NoopType.headline, color = Palette.textPrimary)
            }
            Icon(
                if (expanded) Icons.Filled.ArrowDropUp else Icons.Filled.ArrowDropDown,
                contentDescription = stringResource(R.string.explore_pick_metric),
                tint = if (expanded) Palette.accent else Palette.textSecondary,
            )
        }

        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier
                .background(Palette.surfaceRaised)
                .border(Metrics.divider, Palette.hairline, shape),
        ) {
            grouped.entries.forEachIndexed { groupIdx, (category, items) ->
                if (groupIdx > 0) {
                    HorizontalDivider(
                        color = Palette.hairline,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Palette.surfaceRaised)
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(modifier = Modifier.size(6.dp).clip(CircleShape).background(Palette.accent))
                    Overline(category, color = Palette.accent)
                }
                items.forEach { metric ->
                    val isSelected = metric.key == selected.key
                    DropdownMenuItem(
                        text = {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(metric.accent))
                                Text(
                                    metric.title,
                                    style = NoopType.body,
                                    color = if (isSelected) Palette.accent else Palette.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                if (isSelected) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = null,
                                        tint = Palette.accent,
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                        },
                        onClick = { onSelect(metric.key); expanded = false },
                        modifier = if (isSelected) {
                            Modifier.background(Palette.accent.copy(alpha = StrandAlpha.selectedFill))
                        } else Modifier,
                    )
                }
            }
        }
    }
}

// MARK: - Hero chart card

@Composable
private fun HeroChartCard(
    metric: MetricSpec,
    windowed: List<SeriesPoint>,
    latest: SeriesPoint?,
    effectiveRange: ExploreRange,
    range: ExploreRange,
    fellBack: Boolean,
) {
    val heroValue = latest?.let { metric.format(it.value) } ?: ","
    val asOf = latest?.let { "as of ${it.day}" } ?: "no readings yet"
    // The range bar above already prints the authoritative reading-count caption; the hero only
    // names its window so the count isn't doubled in one card height.
    val subtitle = if (fellBack) {
        "Trailing ${effectiveRange.windowName}"
    } else {
        "Trailing ${range.windowName}"
    }
    // Wash the hero card in the metric's domain world (Charge green / Effort amber / Rest indigo).
    NoopCard(tint = domainTint(metric.category)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline(metric.title)
                    Text(subtitle, style = NoopType.footnote, color = Palette.textTertiary)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text(heroValue, style = NoopType.number(20f), color = metric.accent)
                    Text(asOf, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            if (windowed.size >= 2) {
                // Chart flanked by a max/avg/min Y-axis column and a first/mid/last date X-axis row,
                // so the line reads against real numbers and dates rather than a bare curve. The
                // Y-labels reuse the metric's own formatter but drop the unit suffix to keep the
                // narrow left gutter compact.
                val values = windowed.map { it.value }
                val maxV = values.max()
                val avgV = values.average()
                val minV = values.min()
                val fmtY: (Double) -> String = { v -> metric.format(v).substringBefore(' ').take(7) }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(
                        modifier = Modifier.height(IntrinsicSize.Min),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Column(
                            modifier = Modifier.height(Metrics.chartHeight),
                            verticalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text(fmtY(maxV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                            Text(fmtY(avgV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                            Text(fmtY(minV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                        }
                        // The shared LineChart with a glowing "now" end-cap on its latest sample ,
                        // the Bevel idiom from Today's OverviewHRChart.
                        Box(modifier = Modifier.weight(1f).height(Metrics.chartHeight)) {
                            LineChart(
                                values = values,
                                modifier = Modifier.fillMaxSize(),
                                color = metric.accent,
                                fill = true,
                                selectionEnabled = true,
                                selectionLabels = windowed.map { prettyExploreDate(it.day) },
                                // #1662, and here it was worse than a decimal: `values` are the RAW
                                // stored numbers, and `MetricSpec.format` is what rescales Effort to the
                                // WHOOP 0–21 axis. The Y labels and the hero went through it; the scrub
                                // read-out did not — so on that scale the axis said 12.4 and tapping the
                                // same point said 59. Routing the label through the same formatter makes
                                // the chart agree with itself.
                                formatValue = metric::format,
                            )
                            ExploreGlowEndCap(values = values, tipColor = metric.accent)
                        }
                    }
                    val days = windowed.map { it.day }
                    Row(modifier = Modifier.fillMaxWidth()) {
                        listOf(days.first(), days.getOrNull(days.lastIndex / 2), days.last()).forEach { d ->
                            Text(
                                prettyExploreDate(d),
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (windowed.isEmpty()) {
                            stringResource(R.string.explore_empty_metric, metric.title.lowercase())
                        } else {
                            stringResource(R.string.explore_single_reading)
                        },
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                }
            }

            // Footer chips, mirroring the macOS ChartFooter (Window / Points / Latest).
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sectionGap)) {
                ChartFootItem(stringResource(R.string.explore_chart_window), effectiveRange.label)
                ChartFootItem(stringResource(R.string.explore_chart_points), "${windowed.size}")
                ChartFootItem(stringResource(R.string.explore_latest), heroValue)
            }
        }
    }
}

/** ISO "yyyy-MM-dd" to the same compact date used by both the axis and selection label. */
private fun prettyExploreDate(day: String?): String =
    day?.let {
        runCatching { LocalDate.parse(it).format(DateTimeFormatter.ofPattern("d MMM", Locale.US)) }
            .getOrDefault(it)
    }.orEmpty()

@Composable
private fun ChartFootItem(label: String, value: String) {
    Column {
        Overline(label, color = Palette.textTertiary)
        Text(value, style = NoopType.captionNumber, color = Palette.textSecondary)
    }
}

/** The metric category's domain colour world for the card wash; brand green for neutral categories. */
private fun domainTint(category: String): Color = when (category) {
    uiString(R.string.explore_category_charge) -> Palette.chargeColor
    uiString(R.string.explore_category_effort) -> Palette.effortColor
    uiString(R.string.explore_category_rest) -> Palette.restColor
    else -> Palette.accent
}

/**
 * A glowing "now" end-cap on a LineChart's latest sample (soft halo + bright core + white centre),
 * matching Today's OverviewHRChart. Reproduces LineChart's own point geometry so the dot sits on the
 * curve's final point. Drawn as a sibling overlay , the shared LineChart stays untouched.
 */
@Composable
private fun ExploreGlowEndCap(values: List<Double>, tipColor: Color) {
    val clean = remember(values) { values.filter { it.isFinite() } }
    if (clean.size < 2) return
    Canvas(modifier = Modifier.fillMaxSize()) {
        val strokePx = 2.5f
        val topPad = strokePx + 4f
        val bottomPad = strokePx + 4f
        val minV = clean.min()
        val maxV = clean.max()
        val span = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
        val usableH = (size.height - topPad - bottomPad).coerceAtLeast(1f)
        val norm = ((clean.last() - minV) / span).toFloat().coerceIn(0f, 1f)
        val center = Offset(size.width, topPad + (1f - norm) * usableH)
        drawCircle(color = tipColor.copy(alpha = 0.30f), radius = 9f, center = center)
        drawCircle(color = tipColor.copy(alpha = 0.65f), radius = 5.5f, center = center)
        drawCircle(color = Palette.tipCore, radius = 2.4f, center = center)
    }
}

// MARK: - Stat tile row

@Composable
private fun StatRow(
    metric: MetricSpec,
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
    effectiveRange: ExploreRange,
) {
    val values = windowed.map { it.value }
    val s = statOf(values)
    val latest = series.lastOrNull()

    // Δ vs the previous equal-length window (by point count), tinted by higherIsBetter.
    val prev = remember(series, windowed) { previousWindow(series, windowed) }
    val prevStat = statOf(prev.map { it.value })
    val hasDelta = s.n > 0 && prevStat.n > 0
    val delta = if (hasDelta) s.mean - prevStat.mean else Double.NaN
    val deltaText = if (hasDelta) signed(metric, delta) else ","
    val pctChange = if (hasDelta && prevStat.mean != 0.0) {
        ((s.mean - prevStat.mean) / abs(prevStat.mean)) * 100.0
    } else null
    val deltaColor: Color = run {
        val better = metric.higherIsBetter
        if (!hasDelta || delta == 0.0 || better == null) Palette.textTertiary
        else if ((delta > 0) == better) Palette.statusPositive else Palette.statusCritical
    }
    val deltaCaption = when {
        hasDelta -> stringResource(R.string.explore_vs_prev_window, effectiveRange.windowName)
        effectiveRange == ExploreRange.All -> stringResource(R.string.explore_all_history)
        else -> stringResource(R.string.explore_no_prior_window, effectiveRange.windowName)
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(stringResource(R.string.explore_summary), overline = stringResource(R.string.explore_over_visible_window), trailing = stringResource(R.string.explore_n_pts, s.n))

        // Average summarizes the selected range, so it leads at the full two-column width.
        StatTile(
            modifier = Modifier.fillMaxWidth(),
            label = stringResource(R.string.explore_average),
            value = if (s.n > 0) metric.format(s.mean) else ",",
            caption = pluralStringResource(R.plurals.explore_n_days, s.n, s.n),
            accent = metric.accent,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_min),
                value = if (s.n > 0) metric.format(s.min) else ",",
                accent = Palette.textPrimary,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_max),
                value = if (s.n > 0) metric.format(s.max) else ",",
                accent = Palette.textPrimary,
            )
        }
        // Half-width gives the comparison tile room for its value, delta chip and window caption.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_delta_vs_prev),
                value = deltaText,
                caption = deltaCaption,
                accent = Palette.textPrimary,
                delta = pctChange?.let { "${if (it >= 0) "+" else ""}${String.format(Locale.US, "%.1f", it)}%" },
                deltaColor = deltaColor,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_latest),
                value = latest?.let { metric.format(it.value) } ?: ",",
                caption = latest?.day,
                accent = metric.accent,
            )
        }
    }
}

// MARK: - Window / formatting helpers

/** The window immediately preceding [windowed] (equal length, by point count). */
private fun previousWindow(
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
): List<SeriesPoint> {
    val size = windowed.size
    if (size == 0 || series.size <= size) return emptyList()
    val firstDay = windowed.firstOrNull()?.day ?: return emptyList()
    val lo = series.indexOfFirst { it.day == firstDay }
    if (lo <= 0) return emptyList()
    val prevLo = (lo - size).coerceAtLeast(0)
    return series.subList(prevLo, lo)
}

private fun signed(metric: MetricSpec, delta: Double): String {
    val sign = if (delta >= 0) "+" else "−"
    return sign + metric.format(abs(delta))
}

private fun rangeCaption(
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
    range: ExploreRange,
    effectiveRange: ExploreRange,
    fellBack: Boolean,
): String {
    if (series.isEmpty()) return ","
    val n = windowed.size
    val unit = if (n == 1) "reading" else "readings"
    return if (fellBack) "$n $unit · sparse , widened to ${effectiveRange.windowName}"
    else "$n $unit · ${range.windowName}"
}
