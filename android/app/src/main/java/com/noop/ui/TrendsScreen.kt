package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.WeeklyDigestEngine
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Trends
//
// The longitudinal view, ported from Strand/Screens/TrendsView.swift onto the locked
// Android component system so every surface, height and gap matches: one
// SegmentedPillControl for the range (W / M / 3M / 6M / 1Y / ALL), a hero Recovery
// ChartCard, and a uniform set of HRV / Resting HR / Day-strain ChartCards (all
// Metrics.chartHeight tall), followed by a recovery history strip.
//
// Windows are taken relative to the phone's actual local day, with the macOS auto-expand
// rule: if the selected window holds zero points for a metric, the smallest larger range
// that does is used and the card caption notes the widening.
//
// Data: full history is loaded once via repo.days("my-whoop"); until it arrives the
// reactive recentDays flow backs the charts, so the screen is never empty when data exists.
//
// Difference from macOS: the macOS Trends footer carries a YearHeatStrip calendar
// (a bespoke 53-week heat grid) that has no Android foundation equivalent. Rather than
// fake it, the "Recovery history" card renders the real per-day recovery series as a
// bar strip over the same window, with a short note pointing at the macOS calendar view.

// MARK: - Liquid hero tokens (the liquid Trends restyle)
//
// The Charge hero card floats over the day-of-sky, so it carries the liquid translucent near-black fill
// (rgba(13,14,20,.80)) rather than the classic frosted surface — the card does the contrast work so the
// crisp line chart + the count-up vessel accent read clean over the sky. Radius 26 + a white@0.11 hairline
// give it the frosted-glass edge. Mirrors the liquid Today heroCard (LiquidTodayView / TodayScreen).
private val LIQUID_HERO_FILL: Color = Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val LIQUID_HERO_RADIUS: Dp = 26.dp

@Composable
fun TrendsScreen(vm: AppViewModel) {
    // Reactive cache (oldest → newest) as the immediate backing.
    val reactiveDays by vm.recentDays.collectAsStateWithLifecycle()

    // Full history loaded once for the long (1Y / ALL) ranges; falls back to the flow
    // until it lands so the screen is populated on first frame when any data exists.
    var fullHistory by remember { mutableStateOf<List<DailyMetric>?>(null) }
    LaunchedEffect(Unit) {
        // Merged: imported WHOOP days win; on-device computed days gap-fill the trends. Reads the registry's
        // ACTIVE strap id so daysMerged resolves the active-id ∪ canonical "my-whoop" union (SPINE / #814) ,
        // a re-added strap's data and the canonical import both surface; a single-WHOOP install is unchanged.
        fullHistory = vm.repo.daysMerged(vm.activeStrapId)
    }
    val days = fullHistory ?: reactiveDays

    // Effort display scale (#268) , routes the Effort small-multiple's numbers + unit. Display-only.
    val effortScale = UnitPrefs.effortScale(LocalContext.current)

    // Day-cycle sky backdrop (#698). Default ON. When off, Trends drops the liquid sky and the scaffold
    // paints the plain dark surface canvas instead. SharedPreferences isn't reactive, so this is read once
    // into local state (mirrors Today's showDayCycleBackground gate).
    val trendsCtx = LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(trendsCtx) }
    // Sky-behind-cards (#434 family): when on, the sky fills the whole viewport so the transparent
    // cards reveal it the whole way down, exactly like Today and the metric-detail screens.
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(trendsCtx) }

    var range by remember { mutableStateOf(TrendsRange.Quarter) }

    // #710 , browse previous weeks in the Week-in-review digest. 0 = the week containing today; each step
    // back is one Mon–Sun week earlier, clamped so it never runs past the earliest day we hold. The Trends
    // RANGE control above scopes the long charts; this only moves the weekly digest at the top.
    var weekOffset by remember { mutableStateOf(0) }
    // Re-clamp the offset whenever the loaded history changes (e.g. an import lands more weeks), so a
    // stored offset can never point past the new earliest week. Mirrors the iOS minWeekOffset clamp.
    val minWeekOffset = remember(days) { minWeekOffset(days) }
    LaunchedEffect(minWeekOffset) { weekOffset = weekOffset.coerceIn(minWeekOffset, 0) }

    // Resolve each metric's window ONCE per composition and reuse below , mirrors the macOS resolve(_:)
    // so caption / widened / points aren't recomputed per use. HOISTED above the lazy scaffold: these
    // are @Composable `remember` hooks, which can't run inside the LazyListScope content lambda. They're
    // cheap memoized resolves (no-ops over an empty `days`), so the empty branch below simply ignores
    // them , same as Intelligence's hoisted range/filter. Mirrors the eager body's per-composition resolve.
    val recovery = remember(days, range) { resolveMetric(days, range) { it.recovery } }
    val hrv = remember(days, range) { resolveMetric(days, range) { it.avgHrv } }
    val rhr = remember(days, range) { resolveMetric(days, range) { it.restingHr?.toDouble() } }
    val strain = remember(days, range) { resolveMetric(days, range) { it.strain } }
    // Rest = the sleep_performance COMPOSITE (0–100) , the SAME metric the Today Rest score/tile and the
    // Sleep Rest-detail plot (#614 follow-up), NOT raw efficiency, which is a different number under the
    // same "Rest" label and made the Trends Rest graph disagree with the Today Rest score (#732).
    // sleep_performance is a metricSeries (imported-wins resolved), not a DailyMetric column, so fetch the
    // resolved series and key it by day for the existing windowing/widening below. Mirrors the source
    // TodayScreen's restScore reads, so the two screens now plot the same number.
    var sleepPerfByDay by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    LaunchedEffect(days) {
        sleepPerfByDay = runCatching {
            vm.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99",
                strapDeviceId = vm.activeStrapId)
                .values.associate { it.first to it.second }
        }.getOrDefault(emptyMap())
    }
    val rest = remember(days, range, sleepPerfByDay) {
        resolveMetric(days, range) { d -> sleepPerfByDay[d.day] }
    }
    val recAvg = recovery.values.averageOrNull()

    LazyScreenScaffold(
        title = stringResource(R.string.nav_trends),
        subtitle = stringResource(R.string.trends_subtitle),
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles
        // into the theme canvas behind the header + top rows, full-bleed via the scaffold's topBackground
        // plumbing. Static (LiquidSkyStatic, inside the helper) — never an animated sky behind a scrolling
        // list. Gated on the same day-cycle pref as Today; when off, the scaffold paints the flat canvas.
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way down
        // (Today / metric-detail parity — the same two prefs drive the same two behaviours everywhere).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        if (days.isEmpty()) {
            item { EmptyTrends() }
            return@LazyScreenScaffold
        }

        // The main card list ripples in once on appear (Reduce-Motion safe), mirroring the iOS
        // staggeredAppear sequence , each top-level section is one staggered child.

        // --- Week-in-review digest (#208) with prev/next week browsing (#710). Past weeks render in the
        // same format; the chevrons stay visible on an empty PAST week so the user can step on. ---
        item {
            Column(modifier = Modifier.staggeredAppear(index = 0)) {
                WeeklyDigestNav(
                    days = days,
                    weekOffset = weekOffset,
                    minWeekOffset = minWeekOffset,
                    onStep = { delta -> weekOffset = (weekOffset + delta).coerceIn(minWeekOffset, 0) },
                )
            }
        }

        // --- Week in review , the Charge / Effort / Rest trio in NOOP's pip language (PipBar +
        // CountUpText), mirroring the iOS TrendsView.weekInReview card. White count-up numbers over
        // segmented count-up bars; self-hides when none of the three carry a window mean. ---
        item {
            WeekInReviewCard(
                charge = recovery,
                effort = strain,
                rest = rest,
                effortScale = effortScale,
                modifier = Modifier.staggeredAppear(index = 1),
            )
        }

        // --- Range control ---
        item {
            Column(
                modifier = Modifier.staggeredAppear(index = 2),
                verticalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SegmentedPillControl(
                        items = TrendsRange.entries.toList(),
                        selection = range,
                        label = { it.label },
                        onSelect = { range = it },
                    )
                    Spacer(Modifier.weight(1f))
                    Overline(range.subtitle, color = Palette.textTertiary)
                }
                Text(
                    recovery.caption,
                    style = NoopType.footnote,
                    color = if (recovery.widened) Palette.statusWarning else Palette.textTertiary,
                )
            }
        }

        // --- Hero , charge over time. Charge (green) world: domain card wash, a crisp flat line with a
        // bright "now" end-cap, and a TrendChip for the window's move. ---
        item {
            ChartCard(
                modifier = Modifier.staggeredAppear(index = 3),
                title = stringResource(R.string.trends_charge),
                // The range bar above already prints the authoritative reading-count caption;
                // the hero only names its window so the count isn't doubled in one card height.
                subtitle = range.subtitle,
                trailing = recAvg?.let { "${it.roundToInt()}" },
                // LIQUID hero: the translucent-black frosted wrapper + a small count-up Charge vessel accent
                // in the header (the screen's one headline single value — the window-average Charge). The
                // line chart below stays crisp. Small multiples pass liquidHero = false → untouched.
                liquidHero = true,
                headlineValue = recAvg,
                color = Palette.chargeColor,
                tipColor = Palette.chargeBright,
                values = recovery.values,
                dates = recovery.dates,
                formatY = { "${it.roundToInt()}" },
                change = periodChange(recovery.values),
                higherIsBetter = true,
                changeFmt = { "${it.roundToInt()}" },
                // Lift the ceiling ~6% so a near-100 peak and the now-cap halo clear the top gridline ,
                // mirrors the iOS hero's `valueRange: 0...106`.
                chartHeadroom = 0.06f,
                footer = listOf(
                    stringResource(R.string.trends_avg) to (recAvg?.let { "${it.roundToInt()}" } ?: EM_DASH),
                    stringResource(R.string.trends_peak) to (recovery.values.maxOrNull()?.let { "${it.roundToInt()}" } ?: EM_DASH),
                    stringResource(R.string.trends_low) to (recovery.values.minOrNull()?.let { "${it.roundToInt()}" } ?: EM_DASH),
                    stringResource(R.string.trends_days) to "${recovery.values.size}",
                ),
            )
        }

        // --- Small multiples , HRV / Resting HR / Effort. HRV/RHR are Charge sub-signals; the card
        // surface is neutral (EXP-004) and each line keeps its metric hue; Effort is the WHOOP blue
        // strain world. ---
        // No trailing window label , the range bar's overline already states it.
        item {
            Column(
                modifier = Modifier.staggeredAppear(index = 4),
                verticalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                SectionHeader(stringResource(R.string.trends_daily_signals), overline = stringResource(R.string.nav_trends))
                MetricTrendCard(
                    title = stringResource(R.string.trends_hrv_full), unit = "ms",
                    color = Palette.metricPurple,
                    higherIsBetter = true,
                    resolved = hrv,
                    fmt = { "${it.roundToInt()}" },
                )
                MetricTrendCard(
                    title = stringResource(R.string.trends_resting_hr_full), unit = "bpm",
                    color = Palette.metricRose,
                    higherIsBetter = false,
                    resolved = rhr,
                    fmt = { "${it.roundToInt()}" },
                )
                MetricTrendCard(
                    // Plotted values stay on the stored 0–100 scale (line shape unchanged); only the displayed
                    // numbers + unit follow the Effort-scale toggle, converted inside `fmt`. (#268)
                    title = stringResource(R.string.trends_effort), unit = "/ ${UnitFormatter.effortScaleMax(effortScale)}",
                    // WHOOP: Effort/Strain is always BLUE , a deep→bright blue line, not the amber ramp.
                    color = Palette.effortColor,
                    tint = Palette.effortColor,
                    tipColor = Palette.effortBright,
                    higherIsBetter = null,
                    resolved = strain,
                    fmt = { UnitFormatter.effortDisplay(it, effortScale) },
                )
            }
        }

        // --- Recovery history strip (stands in for the macOS YearHeatStrip) ---
        item {
            Column(modifier = Modifier.staggeredAppear(index = 5)) {
                RecoveryHistoryCard(days = days, range = range)
            }
        }

        // --- Export trends report (#436) , the shareable offline PDF exporter. Mirrors the iOS
        // TrendsView.exportReportRow footer; the same composable Settings hosts, so both surfaces
        // offer it. Routed through NoopButton like every other CTA (no gold). ---
        item {
            Column(modifier = Modifier.staggeredAppear(index = 6)) {
                TrendsReportExportSection(vm)
            }
        }
    }
}

// MARK: - Week-in-review digest with prev/next week browsing (#710)

/**
 * The most-negative weekOffset allowed: the number of whole Mon–Sun weeks between the earliest day we
 * hold and this week. Beyond it there's no data to digest, so the back chevron disables. 0 when history
 * is empty or unparseable (so we stay on this week). `days` is oldest → newest. Mirrors iOS minWeekOffset.
 */
private fun minWeekOffset(days: List<DailyMetric>): Int {
    val earliest = days.firstOrNull()?.day ?: return 0
    val earliestMon = WeeklyDigestEngine.mondayOfWeek(earliest) ?: return 0
    val thisMon = WeeklyDigestEngine.mondayOfWeek(logicalDayKeyNow()) ?: return 0
    var off = 0
    var mon = thisMon
    // Walk weeks back until we pass the earliest week. Hard cap ~10 years so a bad date can't spin.
    while (mon > earliestMon && off > -520) {
        mon = WeeklyDigestEngine.addDays(mon, -7)
        off -= 1
    }
    return off
}

/**
 * The Week-in-review digest for the selected week, with prev/next chevrons in its header. The digest for
 * the offset week is built straight from the shared [buildWeeklyDigest] (the same builder
 * WeeklyDigestCard uses) so past weeks render in the identical format. The whole block self-hides only
 * when the WHOLE history is empty; an empty PAST week still shows the chevrons so the user can step on.
 * Mirrors iOS TrendsView.weeklyDigestNav.
 */
@Composable
private fun WeeklyDigestNav(
    days: List<DailyMetric>,
    weekOffset: Int,
    minWeekOffset: Int,
    onStep: (Int) -> Unit,
) {
    if (days.isEmpty()) return
    // Anchor day for this offset = today shifted back by weekOffset whole weeks; the engine snaps it to
    // that week's Monday. Memoised so the (cheap but non-trivial) digest rebuild only runs on a real change.
    val anchorDay = remember(weekOffset) {
        WeeklyDigestEngine.addDays(logicalDayKeyNow(), weekOffset * 7)
    }
    // #268/#463: past weeks quote Effort on the user's display scale too, same as the live card.
    val factor = effortDisplayFactor(UnitPrefs.effortScale(LocalContext.current))
    val digest = remember(days, anchorDay, factor) {
        buildWeeklyDigest(days, anchorDay, effortDisplayFactor = factor)
    }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        WeekNavBar(weekOffset = weekOffset, minWeekOffset = minWeekOffset, onStep = onStep)
        if (digest.isEmpty) {
            DataPendingNote(
                title = stringResource(R.string.trends_no_readings_this_week),
                body = stringResource(R.string.trends_no_readings_body),
            )
        } else {
            NoopCard { WeeklyDigestContent(digest = digest, compact = true) }
        }
    }
}

/**
 * Prev/next week stepper. Back is clamped at the earliest week we hold; forward at this week (no future
 * weeks). Flat accent chevrons, mirroring the iOS FullDayChart day stepper (#597).
 */
@Composable
private fun WeekNavBar(weekOffset: Int, minWeekOffset: Int, onStep: (Int) -> Unit) {
    val atOldest = weekOffset <= minWeekOffset
    val atNewest = weekOffset >= 0
    val label = when {
        weekOffset == 0 -> stringResource(R.string.trends_this_week)
        weekOffset == -1 -> stringResource(R.string.trends_last_week)
        else -> pluralStringResource(R.plurals.trends_weeks_ago, -weekOffset, -weekOffset)
    }
    // liquidPress on the two week-step chevrons (the screen's tappable controls): each settles inward on
    // press, wired to the SAME interactionSource the IconButton uses for its own ripple, matching the pilot.
    val prevInteraction = remember { MutableInteractionSource() }
    val nextInteraction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = Metrics.space4),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(
            onClick = { onStep(-1) },
            enabled = !atOldest,
            interactionSource = prevInteraction,
            modifier = Modifier.liquidPress(prevInteraction),
        ) {
            Icon(
                Icons.Filled.ChevronLeft,
                contentDescription = stringResource(R.string.trends_previous_week),
                tint = if (atOldest) Palette.textTertiary else Palette.accent,
            )
        }
        Spacer(Modifier.weight(1f))
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(label, style = NoopType.headline, color = Palette.textPrimary)
            Overline(stringResource(R.string.trends_week_in_review), color = Palette.textSecondary)
        }
        Spacer(Modifier.weight(1f))
        IconButton(
            onClick = { onStep(1) },
            enabled = !atNewest,
            interactionSource = nextInteraction,
            modifier = Modifier.liquidPress(nextInteraction),
        ) {
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = stringResource(R.string.trends_next_week),
                tint = if (atNewest) Palette.textTertiary else Palette.accent,
            )
        }
    }
}

// MARK: - Week in review , the Charge / Effort / Rest trio in pip language
//
// The three daily scores as NOOP pip rows over the resolved window: Charge (recovery, 0–100),
// Effort (strain, shown on the WHOOP 0–21 / 0–100 scale per the unit toggle) and Rest (sleep
// efficiency, 0–100). Each value ticks up via CountUpText; the segmented PipBar cascades on appear.
// Self-hides when none of the three carry a window mean. Mirrors iOS TrendsView.weekInReview.

@Composable
private fun WeekInReviewCard(
    charge: ResolvedMetric,
    effort: ResolvedMetric,
    rest: ResolvedMetric,
    effortScale: EffortScale,
    modifier: Modifier = Modifier,
) {
    val chargeAvg = charge.values.averageOrNull()
    val effortAvg = effort.values.averageOrNull() // stored 0–100 internal Effort scale
    val restAvg = rest.values.averageOrNull()
    if (chargeAvg == null && effortAvg == null && restAvg == null) return

    NoopCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SectionHeader(stringResource(R.string.trends_week_in_review), overline = stringResource(R.string.trends_charge_effort_rest))
            if (chargeAvg != null) {
                PipScoreRow(
                    label = stringResource(R.string.trends_charge), value = chargeAvg, range = 0f..100f,
                    tint = Palette.chargeColor, format = { "${it.roundToInt()}" },
                )
            }
            if (effortAvg != null) {
                // Effort is stored 0–100 but reads on the user's chosen scale: convert the displayed
                // number AND the bar position so the pip fill and the count-up value agree. On WHOOP's
                // 0–21 scale Effort reads to one decimal; on 0–100 it's a whole number.
                val display = UnitFormatter.effortValue(effortAvg, effortScale)
                val maxV = UnitFormatter.effortValue(100.0, effortScale)
                val oneDecimal = effortScale == EffortScale.WHOOP
                PipScoreRow(
                    label = stringResource(R.string.trends_effort), value = display, range = 0f..maxV.toFloat(),
                    tint = Palette.effortColor,
                    format = { if (oneDecimal) String.format(Locale.US, "%.1f", it) else "${it.roundToInt()}" },
                )
            }
            if (restAvg != null) {
                PipScoreRow(
                    label = stringResource(R.string.trends_rest), value = restAvg, range = 0f..100f,
                    tint = Palette.restColor, format = { "${it.roundToInt()}" },
                )
            }
        }
    }
}

/**
 * One pip row matching PipBarRow's layout, but with the value driven by [CountUpText] so the big
 * number ticks up. UPPERCASE label + big white count-up value over the segmented count-up bar.
 * Mirrors iOS TrendsView.pipScoreRow.
 */
@Composable
private fun PipScoreRow(
    label: String,
    value: Double,
    range: ClosedFloatingPointRange<Float>,
    tint: Color,
    format: (Double) -> String,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        Text(
            text = label.uppercase(),
            style = NoopType.overline,
            color = Palette.textSecondary,
        )
        CountUpText(
            value = value,
            format = format,
            style = NoopType.number(30f, weight = FontWeight.Bold),
            color = Palette.textPrimary,
        )
        PipBar(value = value.toFloat(), range = range, tint = tint)
    }
}

// MARK: - Range control model (ported from TrendsView.Range)

/** W(7) / M(30) / 3M(90) / 6M(180) / 1Y(365) / ALL. */
private enum class TrendsRange(val days: Int?, val label: String, val longName: String) {
    Week(7, "W", "week"),
    Month(30, "M", "month"),
    Quarter(90, "3M", "3 months"),
    Half(180, "6M", "6 months"),
    Year(365, "1Y", "year"),
    All(null, "ALL", "all history");

    /** "Trailing 90 days" / "All history" , the card/range subtitle. */
    val subtitle: String get() = days?.let { "Trailing $it days" } ?: "All history"

    /** This range plus every LARGER range, ascending , the auto-expand search order. */
    val widening: List<TrendsRange>
        get() = entries.dropWhile { it != this }
}

// MARK: - Resolved metric (mirrors TrendsView.ResolvedMetric / resolve)

/** A metric's window: its plotted values + the day-string of each point, the range it
 *  resolved to, whether the selection was widened to find data, and the caption to show. */
private data class ResolvedMetric(
    val values: List<Double>,
    val dates: List<String>,
    val effective: TrendsRange,
    val widened: Boolean,
    val caption: String,
)

/**
 * Walk the widening order once: take the smallest range ≥ selected whose window holds
 * ≥1 non-null point for [value]; if none do, fall back to ALL. Windows are taken
 * relative to the LATEST recorded day, exactly like the macOS `days(for:)`.
 */
private fun resolveMetric(
    days: List<DailyMetric>,
    selected: TrendsRange,
    value: (DailyMetric) -> Double?,
): ResolvedMetric {
    for (r in selected.widening) {
        val pts = windowPoints(days, r, value)
        if (pts.isNotEmpty()) {
            return ResolvedMetric(
                values = pts.map { it.second },
                dates = pts.map { it.first },
                effective = r,
                widened = r != selected,
                caption = caption(pts.size, r, selected),
            )
        }
    }
    val pts = windowPoints(days, TrendsRange.All, value)
    return ResolvedMetric(
        values = pts.map { it.second },
        dates = pts.map { it.first },
        effective = TrendsRange.All,
        widened = TrendsRange.All != selected,
        caption = caption(pts.size, TrendsRange.All, selected),
    )
}

/**
 * Non-null metric points (day, value) within [range]'s trailing window, taken relative to
 * the latest recorded day (oldest → newest). `days` is the full oldest-first history. A null
 * `range.days` (ALL) returns every non-null point. The day string is carried alongside each
 * value so the chart can draw a real date X-axis.
 */
private fun windowPoints(
    days: List<DailyMetric>,
    range: TrendsRange,
    value: (DailyMetric) -> Double?,
): List<Pair<String, Double>> {
    if (days.isEmpty()) return emptyList()
    val sliced = when (val n = range.days) {
        null -> days
        // Trailing N CALENDAR days ending today , anchored to the phone's date, NOT the last N rows
        // (which on a stale import made months-old data fill the W/M/3M windows, looking current , #23).
        // ISO yyyy-MM-dd sorts chronologically. Empty short windows auto-widen via resolveMetric, so old
        // imports surface under a wider range / All history rather than masquerading as recent.
        else -> {
            val cutoff = LocalDate.now().minusDays((n - 1).toLong()).toString()
            days.filter { it.day >= cutoff }
        }
    }
    return sliced.mapNotNull { d -> value(d)?.let { d.day to it } }
}

/** Caption text, mirroring TrendsView.caption(count:eff:). */
private fun caption(count: Int, eff: TrendsRange, selected: TrendsRange): String {
    val unit = if (count == 1) "reading" else "readings"
    return if (eff != selected) {
        "$count $unit · sparse , widened to ${eff.longName}"
    } else {
        "$count $unit · ${selected.longName}"
    }
}

// MARK: - ChartCard , the uniform fixed-height trend card
//
// A NoopCard holding a header (overline-styled title + caption + trailing read-out), a
// fixed-height LineChart, and a divided footer of labelled stats. Mirrors the macOS
// ChartCard used across Trends so every card is Metrics.chartHeight-class and identical.

@Composable
private fun ChartCard(
    title: String,
    subtitle: String?,
    trailing: String?,
    color: Color,
    values: List<Double>,
    footer: List<Pair<String, String>>,
    modifier: Modifier = Modifier,
    dates: List<String> = emptyList(),
    formatY: (Double) -> String = { "${it.roundToInt()}" },
    // Bevel: a domain card wash, a bright end-cap "now" colour, and an optional window-change TrendChip.
    tint: Color? = null,
    tipColor: Color = color,
    change: Double? = null,
    higherIsBetter: Boolean? = null,
    changeFmt: (Double) -> String = { "${it.roundToInt()}" },
    // Fraction of the plot height left empty above the peak , the Android stand-in for the iOS
    // hero's `valueRange: 0...106` padded ceiling, so the peak + now-cap halo clear the top
    // gridline. 0 keeps the curve filling the full height (the small multiples). (#458/parity)
    chartHeadroom: Float = 0f,
    // LIQUID: the hero card only. When true the card carries the liquid translucent-black frosted wrapper
    // (rgba(13,14,20,.80), radius 26, white@0.11 hairline) instead of the classic NoopCard surface, and the
    // trailing readout becomes a small count-up Charge vessel filled to [headlineValue] (0..100). Every
    // small-multiple card leaves this false → identical classic NoopCard + plain text readout as before.
    liquidHero: Boolean = false,
    headlineValue: Double? = null,
) {
    // The card body — one composable reused by both the classic and the liquid-hero container so the
    // header / chart / footer layout is byte-identical between them; only the surface + the header readout
    // treatment differ.
    val body: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Header.
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline(title)
                    if (subtitle != null) {
                        Text(subtitle, style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
                if (liquidHero && headlineValue != null) {
                    // The one liquid accent on this screen: a small Charge vessel filled to the window
                    // average, the value counting up over it (white, tabular, soft shadow, hit-transparent).
                    // Same value + charge tint as the plain readout it replaces — the chart stays crisp.
                    HeadlineVessel(value = headlineValue, tint = Palette.recoveryColor(headlineValue))
                } else if (trailing != null) {
                    // Neutral 15pt readout (matches iOS TrendsView) , not the 22sp tinted figure.
                    Text(trailing, style = NoopType.bodyNumber, color = Palette.textPrimary)
                }
            }

            // Chart (fixed height) or sparse placeholder. The chart is flanked by a max/avg/min
            // Y-axis column on the left and a first/mid/last date X-axis row underneath, so the
            // line reads against real numbers and dates instead of a bare unlabelled curve.
            if (values.size >= 2) {
                ChartWithAxes(
                    values = values,
                    dates = dates,
                    color = color,
                    tipColor = tipColor,
                    formatY = formatY,
                    headroom = chartHeadroom,
                )
            } else {
                SparsePlaceholder()
            }

            // Footer stats + a window-change chip aligned to the trailing edge.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.weight(1f)) { ChartFooter(footer) }
                ChangeChip(change, higherIsBetter, changeFmt)
            }
        }
    }

    if (liquidHero) {
        // The liquid hero surface: a translucent near-black that floats over the day-of-sky so the crisp
        // chart + the vessel accent read clean — the card does the contrast work, not a muted sky. Radius 26
        // + a faint white hairline give the frosted-glass edge of the iOS liquid heroCard. Mirrors Today.
        Box(
            modifier = modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
                .background(LIQUID_HERO_FILL.copy(alpha = LIQUID_HERO_FILL.alpha * CardAppearance.opacity))
                .border(1.dp, Color.White.copy(alpha = 0.11f * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
                .padding(Metrics.cardPadding),
        ) {
            body()
        }
    } else {
        NoopCard(modifier = modifier, padding = Metrics.cardPadding, tint = tint) { body() }
    }
}

/**
 * The screen's single liquid accent: a small [LiquidVessel] filled to [value] (0..100 → 0..1) in the
 * charge [tint], the number rolling up over it via [CountUpText] (white, tabular, a soft shadow so it reads
 * on the vessel, hit-transparent so a tap falls through to the vessel's own splash). The Trends echo of the
 * liquid Today `HeroScoreVessel`, sized down to a header readout so it accents the headline value without
 * competing with the crisp chart below.
 */
@Composable
private fun HeadlineVessel(value: Double, tint: Color) {
    val diameter = 44.dp
    Box(modifier = Modifier.size(diameter), contentAlignment = Alignment.Center) {
        LiquidVessel(
            value = (value / 100.0).coerceIn(0.0, 1.0),
            tint = tint,
            animated = true,
            modifier = Modifier.size(diameter),
        )
        CountUpText(
            value = value,
            format = { "${it.roundToInt()}" },
            style = NoopType.number(17f, weight = FontWeight.Bold)
                .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
            color = Color.White,
            modifier = Modifier.clearAndSetSemantics {},
        )
    }
}

/** A TrendChip for a window's period change , green/rose by whether the move is good for THIS metric. */
@Composable
private fun ChangeChip(change: Double?, higherIsBetter: Boolean?, fmt: (Double) -> String) {
    if (change == null || kotlin.math.abs(change) <= 0.0001) return
    val sign = if (change >= 0) "+" else "−"
    val color = when (higherIsBetter) {
        null -> Palette.textTertiary
        else -> if ((change > 0) == higherIsBetter) Palette.statusPositive else Palette.metricRose
    }
    TrendChip(text = uiString(R.string.l10n_trends_screen_sign_fmt_kotlin_math_abs_change_9ad2f71e, sign, fmt(kotlin.math.abs(change))), color = color)
}

/**
 * A [LineChart] with a max/avg/min Y-axis label column and a first/mid/last date X-axis row.
 * Shared by the hero + small-multiple trend cards so every chart gets the same axis treatment.
 * Date strings (ISO yyyy-MM-dd) are reformatted to "d MMM"; an unparseable string falls back to
 * its raw value so a non-ISO key never blanks a label.
 */
@Composable
private fun ChartWithAxes(
    values: List<Double>,
    dates: List<String>,
    color: Color,
    formatY: (Double) -> String,
    tipColor: Color = color,
    // See ChartCard.chartHeadroom , fraction of the plot left empty above the peak.
    headroom: Float = 0f,
) {
    val maxV = values.max()
    val avgV = values.average()
    val minV = values.min()
    // Trend chart style (line vs bar). Read here at the single chart choke point (every trend card routes
    // through ChartWithAxes); SharedPreferences isn't reactive, but returning from Settings recomposes the
    // Trends screen, which re-reads it — the same read-on-recompose the Effort scale toggle relies on.
    val chartStyle = UnitPrefs.trendChartStyle(LocalContext.current)
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Column(
            modifier = Modifier.height(Metrics.chartHeight),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(formatY(maxV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            Text(formatY(avgV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            Text(formatY(minV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // The shared LineChart with a glowing "now" end-cap drawn on top , the Bevel idiom from
            // Today's OverviewHRChart. The cap reproduces LineChart's own point geometry (same
            // strokePx/topPad/bottomPad) so the dot lands exactly on the line's final sample.
            //
            // headroom leaves the top fraction of the card empty and pins the plotting Box to the
            // bottom , the Android stand-in for the iOS hero's `valueRange: 0...106` (LineChart has
            // no value-domain hook, so we shrink its drawing box instead). Both LineChart and the
            // GlowEndCap fill this same Box, so the cap stays on the line.
            val plotHeight = Metrics.chartHeight * (1f - headroom.coerceIn(0f, 0.5f))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.chartHeight),
                contentAlignment = Alignment.BottomCenter,
            ) {
                Box(modifier = Modifier.fillMaxWidth().height(plotHeight)) {
                    if (chartStyle == TrendChartStyle.BAR) {
                        // Bar mode: value-ramp bars from the baseline. No GlowEndCap (the "now" halo is a
                        // line idiom). selectionEnabled is OFF so BarChart mean-bins a dense window (the
                        // multi-year "ALL" span) down to the pixel width — a clean silhouette instead of a
                        // 1000-bar sub-pixel smear. The max/avg/min axis column + footer carry the numbers.
                        BarChart(
                            values = values,
                            modifier = Modifier.fillMaxSize(),
                            color = color,
                            selectionEnabled = false,
                        )
                    } else {
                        LineChart(
                            values = values,
                            modifier = Modifier.fillMaxSize(),
                            color = color,
                            fill = true,
                            selectionEnabled = true,
                            // #463: the pinpoint label goes through the SAME formatter as the axis column,
                            // so a tapped Effort day can't print the stored 0-100 value beside a 0-21 axis.
                            formatValue = formatY,
                            selectionLabels = dates.map(::prettyAxisDate),
                        )
                        GlowEndCap(values = values, tipColor = tipColor)
                    }
                }
            }
            val axisLabels = trendAxisLabels(dates)
            if (axisLabels.isNotEmpty()) {
                Row(modifier = Modifier.fillMaxWidth()) {
                    axisLabels.forEach { label ->
                        Text(
                            prettyAxisDate(label.day),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                            modifier = Modifier.weight(1f),
                            textAlign = when (label.anchor) {
                                TrendAxisAnchor.START -> TextAlign.Start
                                TrendAxisAnchor.CENTER -> TextAlign.Center
                                TrendAxisAnchor.END -> TextAlign.End
                            },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

internal enum class TrendAxisAnchor { START, CENTER, END }

internal data class TrendAxisLabel(val day: String, val anchor: TrendAxisAnchor)

/** Selects date labels and pins them to the corresponding start, middle, and end of the plot. */
internal fun trendAxisLabels(dates: List<String>): List<TrendAxisLabel> = when {
    dates.size < 2 -> emptyList()
    dates.size == 2 -> listOf(
        TrendAxisLabel(dates.first(), TrendAxisAnchor.START),
        TrendAxisLabel(dates.last(), TrendAxisAnchor.END),
    )
    else -> listOf(
        TrendAxisLabel(dates.first(), TrendAxisAnchor.START),
        TrendAxisLabel(dates[dates.lastIndex / 2], TrendAxisAnchor.CENTER),
        TrendAxisLabel(dates.last(), TrendAxisAnchor.END),
    )
}

/** ISO "yyyy-MM-dd" → "d MMM"; falls back to the raw string (or "" when null) if it doesn't parse. */
private fun prettyAxisDate(day: String?): String =
    day?.let {
        runCatching { LocalDate.parse(it).format(DateTimeFormatter.ofPattern("d MMM", Locale.US)) }
            .getOrDefault(it)
    }.orEmpty()

/** A labelled metric-trend card built from a [ResolvedMetric] with mean / min / max. */
@Composable
private fun MetricTrendCard(
    title: String,
    unit: String,
    color: Color,
    resolved: ResolvedMetric,
    fmt: (Double) -> String,
    tint: Color? = null,
    tipColor: Color = color,
    higherIsBetter: Boolean? = null,
) {
    val avg = resolved.values.averageOrNull()
    ChartCard(
        title = title,
        subtitle = null,
        trailing = avg?.let { fmt(it) },
        color = color,
        tint = tint,
        tipColor = tipColor,
        values = resolved.values,
        dates = resolved.dates,
        formatY = fmt,
        change = periodChange(resolved.values),
        higherIsBetter = higherIsBetter,
        changeFmt = fmt,
        footer = listOf(
            // Plain "Mean" to match the bare Min/Max columns; the unit moves into the value
            // (e.g. "58 ms") so uppercasing can't render a shouty "MEAN MS".
            stringResource(R.string.trends_mean) to (avg?.let { "${fmt(it)} $unit" } ?: EM_DASH),
            stringResource(R.string.trends_min) to (resolved.values.minOrNull()?.let { fmt(it) } ?: EM_DASH),
            stringResource(R.string.trends_max) to (resolved.values.maxOrNull()?.let { fmt(it) } ?: EM_DASH),
        ),
    )
}

/**
 * The window's trend as a signed mean-of-recent-half minus mean-of-earlier-half , drives the card's
 * TrendChip so a glance reads the direction, like Today's deltas. null for a window too short to split.
 */
private fun periodChange(values: List<Double>): Double? {
    if (values.size < 4) return null
    val mid = values.size / 2
    val earlier = values.take(mid)
    val recent = values.drop(mid)
    if (earlier.isEmpty() || recent.isEmpty()) return null
    return recent.average() - earlier.average()
}

/** Evenly-spaced labelled stats under a chart, separated by a hairline rule. */
@Composable
private fun ChartFooter(items: List<Pair<String, String>>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
        HorizontalDivider(color = Palette.hairline)
        Row(modifier = Modifier.fillMaxWidth()) {
            items.forEach { (label, value) ->
                Column(modifier = Modifier.weight(1f)) {
                    Overline(label, color = Palette.textTertiary)
                    Text(value, style = NoopType.bodyNumber, color = Palette.textPrimary)
                }
            }
        }
    }
}

// MARK: - Recovery history strip (stands in for the macOS YearHeatStrip)

/**
 * The recovery history card. macOS shows a YearHeatStrip (a 53-week calendar heat grid);
 * that bespoke component has no Android foundation equivalent, so we plot the real
 * per-day recovery series as a bar strip over the same window and note the difference.
 * Always shows at least a full year of context, like the macOS strip.
 */
@Composable
private fun RecoveryHistoryCard(days: List<DailyMetric>, range: TrendsRange) {
    // PERF (#scroll-jank): memoise the window slice + recovery extraction on (days, range) so the
    // 800+-day takeLast + mapNotNull don't re-run on every recomposition (e.g. the staggered-appear
    // animation frames that drive this whole strip). Same span rule, same values, same order , purely
    // skips redundant re-slicing. NOTE: the bars are NOT caller-downsampled , BarChart already mean-
    // bucket-downsamples internally to ~one bar per horizontal pixel (pixel-identical), so a second,
    // coarser caller-side bucket (e.g. ≤180) would visibly widen the bars and is deliberately avoided.
    val recovery = remember(days, range) {
        // Always show at least a year; expand to all history on ALL.
        val span = (range.days ?: days.size).coerceAtLeast(365)
        days.takeLast(span).mapNotNull { it.recovery }
    }
    val title = if (range == TrendsRange.All && days.size > 365) {
        "Charge , all history"
    } else {
        "Charge , past year"
    }

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SectionHeader(title, overline = stringResource(R.string.trends_calendar), trailing = "${recovery.size} days")
            if (recovery.size >= 2) {
                BarChart(
                    values = recovery,
                    modifier = Modifier.height(Metrics.trendStripHeight),
                    color = Palette.accent,
                )
            } else {
                SparsePlaceholder(height = Metrics.trendStripHeight)
            }
            HorizontalDivider(color = Palette.hairline)
            Text(
                stringResource(R.string.trends_calendar_footnote),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Shared bits

/**
 * A glowing dot pinned to a LineChart's latest sample , the Bevel "now" end-cap (a soft halo + bright
 * core + white centre), matching Today's OverviewHRChart. Drawn as a sibling overlay so the shared
 * LineChart stays untouched; it reproduces that chart's point geometry exactly (strokePx 2.5, top/
 * bottom pad strokePx+4, finite-value min/max) so the cap sits on the curve's final point.
 */
@Composable
private fun GlowEndCap(values: List<Double>, tipColor: Color) {
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
        val x = size.width  // the latest point sits at the right edge
        val norm = ((clean.last() - minV) / span).toFloat().coerceIn(0f, 1f)
        val y = topPad + (1f - norm) * usableH
        val center = Offset(x, y)
        drawCircle(color = tipColor.copy(alpha = 0.30f), radius = 9f, center = center)
        drawCircle(color = tipColor.copy(alpha = 0.65f), radius = 5.5f, center = center)
        drawCircle(color = Palette.tipCore, radius = 2.4f, center = center)
    }
}

/** Inset well shown when a window has too few points to plot, mirroring sparsePlaceholder. */
@Composable
private fun SparsePlaceholder(height: Dp = Metrics.chartHeight) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(height)
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .background(Palette.surfaceInset),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            stringResource(R.string.trends_not_enough_data),
            style = NoopType.subhead,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun EmptyTrends() {
    DataPendingNote(
        title = stringResource(R.string.trends_empty_title),
        body = stringResource(R.string.trends_empty_body),
    )
}

// MARK: - Small numeric helpers

private const val EM_DASH = ","

private fun List<Double>.averageOrNull(): Double? =
    if (isEmpty()) null else sum() / size
