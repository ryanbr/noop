package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.DaytimeStress
import com.noop.analytics.HrvFreqDomain
import com.noop.analytics.StressIndex
import com.noop.data.DailyMetric
import java.util.Locale
import kotlin.math.exp
import kotlin.math.roundToInt
import kotlin.math.sqrt

// MARK: - Stress Monitor (ported from Strand/Screens/StressView.swift)
//
// A Whoop-style "Stress Monitor": one 0–3 number, a band (LOW/MEDIUM/HIGH), and a
// single plain-English line on *why*. The score is a transparent proxy for autonomic
// load, DERIVED from how today's resting HR / HRV sit against a personal 30-day
// baseline (a stored "stress" series, if present, takes priority):
//
//   zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//   zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//   raw  = zRHR + zHRV                          // combined autonomic load
//   stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands: 0–1 LOW · 1–2 MEDIUM · 2–3 HIGH. Everything is computed live from
// `recentDays` (+ the stored series) so the math is fully inspectable — see the
// "How this is computed" card at the bottom.
//
// Source priority for today's value:
//   1. A persisted daily `stress` value from the metricSeries store ("my-whoop").
//   2. Otherwise the z-score derivation above.
// Both the hero number and the full trend line share ONE baseline so the line is
// internally comparable.

@Composable
fun StressScreen(vm: AppViewModel, onBreathe: () -> Unit = {}) {
    val days by vm.recentDays.collectAsStateWithLifecycle()

    // #698: the liquid day-of-sky backdrop is gated on the same "Day-cycle background" setting as Today,
    // so turning it off falls back to the flat theme canvas on every liquid screen alike.
    val context = LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    // Stored daily "stress" values (0–3), keyed by day. Loaded once per device; the
    // metricSeries store is the Android analogue of the macOS `repo.series(key:source:)`.
    // We pull a wide range so the whole history is covered.
    var stored by remember { mutableStateOf<Map<String, Double>>(emptyMap()) }
    var storedLoaded by remember { mutableStateOf(false) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val rows = runCatching {
            vm.repo.metricSeries("my-whoop", "stress", "0000-01-01", "9999-12-31")
        }.getOrDefault(emptyList())
        stored = rows.associate { it.day to it.value.coerceIn(0.0, 3.0) }
        storedLoaded = true
    }

    // Today's intraday stress read (hourly timeline + sustained-high flag), from the day's
    // banked HR + R-R via the SAME 0–3 proxy the daily score uses. Null until the read
    // completes; DaytimeStress.Result.EMPTY when the day has no usable intraday HR.
    var daytime by remember { mutableStateOf<DaytimeStress.Result?>(null) }
    // ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the daytime
    // timeline already reads. These do NOT feed the 0..3 score or the timeline; they are two extra,
    // clearly-labelled HRV lenses surfaced in their own card. Each stays null when its engine's
    // span/beat gate is not met. Faithful twin of the iOS StressView readouts.
    var stressIndex by remember { mutableStateOf<StressIndex.Components?>(null) }
    var freqHrv by remember { mutableStateOf<HrvFreqDomain.Bands?>(null) }
    androidx.compose.runtime.LaunchedEffect(Unit) {
        val read = runCatching { loadDaytimeStress(vm) }
            .getOrDefault(DaytimeReadout(DaytimeStress.Result.EMPTY, null, null))
        daytime = read.daytime
        stressIndex = read.stressIndex
        freqHrv = read.freqHrv
    }

    // Rebuild the model only when the inputs (days, stored) actually change — the
    // derivation is O(n) over the full history, so we memoize on the inputs.
    val model = remember(days, stored) { StressModel.build(days, stored) }

    LazyScreenScaffold(
        title = uiString(R.string.l10n_stress_screen_stress_bad33342),
        subtitle = "Autonomic load from HRV and resting heart rate",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles
        // into the theme canvas behind the header + hero vessel, full-bleed (full-width, up behind the
        // status bar via the scaffold's topBackground plumbing), and the cards float OVER it on the flat
        // surface below. The Android equivalent of the iOS `ScreenScaffold(topBackground: liquidScaffoldSky())`.
        // Gated on the "Day-cycle background" setting like Today; off passes null (the flat-canvas path).
        topBackground = screenBackdropSlot(showDayCycleBackground, skyBehindCards),
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = screenBackdropFullBleed(showDayCycleBackground, skyBehindCards),
    ) {
        when {
            model != null -> StressContent(model, daytime, stressIndex, freqHrv, onBreathe)
            !storedLoaded -> item { StressLoading() }
            else -> item { StressEmpty() }
        }
    }
}

/**
 * The daytime timeline result plus the two additive, on-demand HRV readouts, all derived from the
 * SAME day's R-R. The readouts are null when their engine's gate is not met (Baevsky needs >= 20
 * clean beats; freq-HRV needs >= 60 s span) or when the day had no usable intraday HR. None of this
 * touches the 0..3 score.
 */
private data class DaytimeReadout(
    val daytime: DaytimeStress.Result,
    val stressIndex: StressIndex.Components?,
    val freqHrv: HrvFreqDomain.Bands?,
)

/**
 * Read TODAY's banked HR + R-R and build the intraday stress timeline. Local-day window
 * [midnight, now]; [DaytimeStress] buckets it into waking hours and reuses the daily
 * score's math, so this is the same proxy at a finer grain (never a new score). The SAME `rr` is
 * then fed to the two additive HRV engines (no extra fetch, no DB / schema change).
 */
private suspend fun loadDaytimeStress(vm: AppViewModel): DaytimeReadout {
    val nowSeconds = System.currentTimeMillis() / 1000L
    val tzOffsetSeconds = java.util.TimeZone.getDefault().getOffset(nowSeconds * 1_000L) / 1_000L
    // Local midnight (wall-clock seconds): floor the LOCAL time to the day, then undo the
    // offset so the bound is back on the wall clock the samples are stored in.
    val localNow = nowSeconds + tzOffsetSeconds
    val from = (localNow - Math.floorMod(localNow, 86_400L)) - tzOffsetSeconds
    val hr = vm.repo.hrSamples("my-whoop", from, nowSeconds, limit = 200_000)
    if (hr.size < DaytimeStress.minHourHrSamples) {
        return DaytimeReadout(DaytimeStress.Result.EMPTY, null, null)
    }
    val rr = vm.repo.rrIntervals("my-whoop", from, nowSeconds, limit = 200_000)
    // Wrist accelerometer for the motion gate: an ambulatory hour is EXERTION, not stress, so it is
    // masked rather than scored (DaytimeStress). Same repo read as R-R; empty on hardware or imports
    // with no gravity, which is exactly the "no masking, prior behaviour" degradation.
    val gravity = vm.repo.gravitySamples("my-whoop", from, nowSeconds, limit = 200_000)
    val daytime = DaytimeStress.analyze(hr, rr, gravity, tzOffsetSeconds)
    // ADDITIVE advanced readouts from the SAME `rr`. Each engine self-gates and returns null when
    // its requirement is not met, in which case its row is simply hidden in the UI.
    val si = StressIndex.components(rr)
    val freq = HrvFreqDomain.freqDomain(rr)
    return DaytimeReadout(daytime, si, freq)
}

// MARK: - Loaded content

// PERF (#scroll-jank): a [LazyListScope] extension so the 5 sections build lazily under
// [LazyScreenScaffold] (only the rows on screen are composed). Same order, the SAME
// `staggeredAppear(0..4)` indices, and the inter-section spacing is the scaffold's 20dp
// `Arrangement.spacedBy` — identical to the eager ColumnScope it replaced.
private fun androidx.compose.foundation.lazy.LazyListScope.StressContent(
    model: StressModel,
    daytime: DaytimeStress.Result?,
    stressIndex: StressIndex.Components?,
    freqHrv: HrvFreqDomain.Bands?,
    onBreathe: () -> Unit,
) {
    // 1 · HERO — the count-up PipBar + band + one plain-English line, all in one card
    //     (the needle/semicircle gauge is gone, matching the iOS redesign: a big WHITE
    //     CountUpText value with "of 3" + the band word beside it, over a band-tinted
    //     PipBar on the 0…3 scale. Flat, crisp, no needle, no gauge, no glow, no scenic).
    item { StressHeroCard(model, modifier = Modifier.staggeredAppear(0)) }

    // 1b · ADVANCED HRV readouts (additive, on-demand). A separate, clearly-labelled card shown
    //      only when at least one engine returned a value. It sits BELOW the hero and never alters
    //      the hero, the markers or the timeline.
    if (hasAdvancedReadouts(stressIndex, freqHrv)) {
        item { StressAdvancedCard(stressIndex, freqHrv, modifier = Modifier.staggeredAppear(1)) }
    }

    // 2 · Today's markers — uniform fixed-height tiles, two-up.
    item {
        Column(
            modifier = Modifier.staggeredAppear(1),
            verticalArrangement = Arrangement.spacedBy(Metrics.gap),
        ) {
            SectionHeader("Today", overline = "Markers", trailing = "vs 30-day baseline")
            StressTiles(model)
        }
    }

    // 3 · Today's intraday timeline — when in the day stress ran high, + a passive Breathe
    //     suggestion when the recent hours stay elevated.
    if (daytime != null && daytime.scored.isNotEmpty()) {
        item { StressDaytimeSection(daytime, onBreathe, modifier = Modifier.staggeredAppear(2)) }
    }

    // 4 · Trend over the chosen window.
    item { StressTrendSection(model, modifier = Modifier.staggeredAppear(3)) }

    // 5 · Transparency — how the number is built.
    item { StressMethodologyCard(model, modifier = Modifier.staggeredAppear(4)) }
}

// MARK: - Liquid hero tokens (the liquid restyle)
//
// The hero card the stress vessel floats on, ported from the iOS liquid heroCard. `LIQUID_HERO_FILL` is a
// translucent near-black (mock rgba(13,14,20,.80)) so it floats over the day-of-sky; the vessel + white
// count-up number read crisp on it. Radius 26 + a white@0.11 hairline give the frosted-glass edge. Same
// numbers as the Today pilot's hero card.
private val LIQUID_HERO_RADIUS = 26.dp

// MARK: - 1 · Hero — the liquid stress VESSEL (the flat PipBar is gone)
//
// The liquid restyle: the headline 0–3 read is now a band-tinted [LiquidVessel] filling to score/3, with
// the count-up value rolled up over it in white (the same HeroScoreVessel idiom as the liquid Today). The
// band word + StatePill + the one plain-English line ride beside / under it. The score, band, tints
// (StressRamp: calm blue → steady green → tense amber) and the explanation are UNCHANGED — only the
// presentation moved from the flat PipBar to the sloshing vessel. The card wrapper is the liquid frosted
// translucent-black hero surface so the vessel + white number stay crisp over the day-of-sky.

@Composable
private fun StressHeroCard(model: StressModel, modifier: Modifier = Modifier) {
    val bandColor = StressRamp.color(model.score)
    // The vessel fills on the SAME 0–3 scale the score uses (score / 3 → 0..1), tinted by the live band.
    val fraction = (model.score / 3.0).coerceIn(0.0, 1.0)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
            .background(Palette.heroFill.copy(alpha = Palette.heroFill.alpha * CardAppearance.opacity))
            .border(1.dp, Palette.heroBorder.copy(alpha = Palette.heroBorder.alpha * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
            .padding(Metrics.cardPadding),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Overline("Stress monitor", modifier = Modifier.weight(1f))
                StatePill(model.band.title, tone = model.band.tone, showsDot = true)
            }

            // The liquid vessel + the count-up value rolled over it, with "of 3" + the band word beside.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                // The band-tinted vessel with a WHITE count-up number over it — the HeroScoreVessel idiom.
                // `animated` only once a real score is loaded (model != null here, so always a real value).
                Box(
                    modifier = Modifier
                        .size(112.dp)
                        .semantics {
                            contentDescription = uiString(
                                R.string.stress_score_accessibility,
                                String.format(Locale.US, "%.1f", model.score),
                                model.band.title,
                            )
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    LiquidVessel(
                        value = fraction,
                        tint = bandColor,
                        animated = true,
                        modifier = Modifier.size(112.dp),
                    )
                    // Count-up value over the vessel — white, tabular, a soft shadow for legibility, and
                    // hit-transparent so the tap reaches the vessel (splash). Mirrors HeroScoreVessel.
                    CountUpText(
                        value = model.score,
                        format = { String.format(Locale.US, "%.1f", it) },
                        style = NoopType.number(30f, weight = FontWeight.Bold)
                            .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                        color = Color.White,
                        modifier = Modifier.clearAndSetSemantics {},
                    )
                }

                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            model.band.title,
                            style = NoopType.display(30f),
                            color = bandColor,
                        )
                        Text(
                            uiString(R.string.l10n_stress_screen_of_3_46203495),
                            style = NoopType.number(14f, FontWeight.Medium),
                            color = Palette.textTertiary,
                            modifier = Modifier.padding(start = 6.dp, bottom = 5.dp),
                        )
                    }
                    Text(
                        uiString(R.string.l10n_stress_screen_on_the_0_3_autonomic_load_8a0d5107),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }

            // One plain-English line, full width under the vessel row.
            Text(
                model.explanation,
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }
    }
}

// MARK: - 1b · Advanced HRV readouts (additive, on-demand)
//
// Two extra, clearly-labelled lenses on the SAME day's R-R the timeline already reads, surfaced in
// their own card so they are visibly separate from the 0..3 monitor. Each tile is shown only when
// its engine produced a value (the engines self-gate on clean-beat count / record span), and the
// whole card is gated by [hasAdvancedReadouts]. Nothing here feeds the score. Faithful twin of iOS.

/**
 * True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or at
 * least the HF power). Drives whether the advanced card is shown at all.
 */
private fun hasAdvancedReadouts(
    stressIndex: StressIndex.Components?,
    freqHrv: HrvFreqDomain.Bands?,
): Boolean {
    if (stressIndex != null) return true
    if (freqHrv != null && (freqHrv.lfhf != null || freqHrv.hf > 0)) return true
    return false
}

@Composable
private fun StressAdvancedCard(
    stressIndex: StressIndex.Components?,
    freqHrv: HrvFreqDomain.Bands?,
    modifier: Modifier = Modifier,
) {
    NoopCard(tint = Palette.stressColor, modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Overline("Advanced HRV", modifier = Modifier.weight(1f))
                Text(
                    uiString(R.string.l10n_stress_screen_on_demand_today_s_r_r_17d716e1),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }

            // The advanced tiles, two-up, mirroring the Today markers grid layout.
            val tiles = ArrayList<@Composable (Modifier) -> Unit>()
            // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
            if (stressIndex != null) {
                tiles.add { m ->
                    StatTile(
                        modifier = m,
                        label = uiString(R.string.l10n_stress_screen_baevsky_stress_index_296cf7c0),
                        value = "${stressIndex.si.roundToInt()}",
                        caption = "Autonomic rigidity from your heart-rate rhythm. Higher means a more rigid, stressed rhythm.",
                        accent = StressRamp.TENSE,
                    )
                }
            }
            // Frequency-domain HRV: prefer the LF/HF ratio; if the span was too short for LF
            // (lfhf null) fall back to the HF (rest) band power so the lens still reads.
            if (freqHrv != null) {
                val ratio = freqHrv.lfhf
                if (ratio != null) {
                    tiles.add { m ->
                        StatTile(
                            modifier = m,
                            label = uiString(R.string.l10n_stress_screen_autonomic_balance_lf_hf_776cb6f7),
                            value = String.format(Locale.US, "%.1f", ratio),
                            caption = "Sympathetic vs parasympathetic tone from frequency-domain HRV. Higher leans sympathetic (stress-ward).",
                            accent = StressRamp.STEADY,
                        )
                    }
                } else if (freqHrv.hf > 0) {
                    tiles.add { m ->
                        StatTile(
                            modifier = m,
                            label = uiString(R.string.l10n_stress_screen_hf_power_3a9fd8c9),
                            value = "${freqHrv.hf.roundToInt()}",
                            caption = "Parasympathetic (rest) band of your HRV.",
                            accent = StressRamp.STEADY,
                        )
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                tiles.chunked(2).forEach { rowTiles ->
                    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                        rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                        if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }

            Text(
                uiString(R.string.l10n_stress_screen_these_are_extra_on_demand_hrv_9303f1de),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - 3 · Daytime timeline (intraday, same 0–3 proxy)

@Composable
private fun StressDaytimeSection(
    day: DaytimeStress.Result,
    onBreathe: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Today's Timeline", overline = "Intraday", trailing = timelineTrailing(day))

        NoopCard(tint = Palette.stressColor) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Overline("Stress through the day", modifier = Modifier.weight(1f))
                    val peak = day.peak
                    val peakLevel = peak?.level
                    if (peak != null && peakLevel != null) {
                        Text(
                            uiString(
                                R.string.stress_peak_summary,
                                String.format(Locale.US, "%.1f", peakLevel),
                                hourLabel(peak.hour),
                            ),
                            style = NoopType.captionNumber,
                            color = StressRamp.color(peakLevel),
                        )
                    }
                }

                // Autonomic-load LINE for the day, drawn in the same blue→green→amber WHOOP
                // ramp as the hero PipBar (README screen 9 "day autonomic-load line").
                DaytimeStressLine(day.hours)

                // Hour ruler under the line (first / midday / last covered hour).
                // start padding matches stressYAxisWidth so labels align with the chart area.
                val lo = day.hours.firstOrNull()?.hour
                val hi = day.hours.lastOrNull()?.hour
                if (lo != null && hi != null) {
                    Row(modifier = Modifier.fillMaxWidth().padding(start = stressYAxisWidth)) {
                        Text(hourLabel(lo), style = NoopType.footnote, color = Palette.textTertiary)
                        Spacer(Modifier.weight(1f))
                        Text(hourLabel((lo + hi) / 2), style = NoopType.footnote, color = Palette.textTertiary)
                        Spacer(Modifier.weight(1f))
                        Text(hourLabel(hi), style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }

                Text(
                    uiString(R.string.l10n_stress_screen_the_line_traces_your_autonomic_load_804f4028) +
                        "against your own calm hours today (the same 0-3 proxy as the score " +
                        "above, read hour by hour). Hours without enough data are skipped.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }

        // Totals bar — how the scored hours split across Calm (blue) / Moderate (green) /
        // High (amber), mirroring the README screen-9 split.
        StressTotalsBar(day)

        // Sustained-high suggestion — only when the recent run stays in the HIGH band.
        if (day.sustainedHigh) SustainedBreatheCard(day, onBreathe)
    }
}

// MARK: - Daytime autonomic-load line (gradient, same scale as the gauge)
//
// Interactive Canvas line over the scored waking hours. Tap or drag to scrub across hours
// and see the stress level at a specific time in a tooltip pill. The Y-axis shows the 0–3
// scale with hairline grid lines. Unscored hours break the line (honest gap, no interpolation).

// Width reserved for the Y-axis labels. Matches the start padding on the X-axis ruler row.
private val stressYAxisWidth = 32.dp

@Composable
private fun DaytimeStressLine(hours: List<DaytimeStress.HourPoint>) {
    val levels = remember(hours) { hours.map { it.level } }
    if (levels.size < 2) return

    var scrubFrac by remember { mutableStateOf<Float?>(null) }
    // Same blue→green→amber WHOOP ramp as the hero PipBar / totals bar (no gold).
    val gradient = remember { Brush.horizontalGradient(*StressRamp.stops.toTypedArray()) }

    // Capture Compose colors at composition time — DrawScope lambdas run on the render thread.
    val hairline = Palette.hairline
    val textTertiary = Palette.textTertiary
    val textPrimary = Palette.textPrimary
    val stressColor = Palette.stressColor
    val yAxisPx = with(LocalDensity.current) { stressYAxisWidth.toPx() }

    // PERF (#scroll-jank — drawing-bound): this chart is scrubbable, so a finger drag re-records the
    // whole Canvas at ~60fps. Previously every frame rebuilt the gradient line + fill Paths and the
    // axis Paint from scratch, even though only the crosshair moves. Split the chart into two layers:
    //   • a STATIC base — the axis grid/labels and the gradient line+fill — drawn via `drawWithCache`,
    //     which rebuilds the Paths + label Paint ONLY when `levels`/size change (NOT per scrub frame);
    //   • a thin DYNAMIC overlay Canvas — just the crosshair, dot and tooltip — that reads `scrubFrac`.
    // The geometry (yAxisPx, 8dp top/bot pad, yFor, stepX) is byte-identical to the old single Canvas,
    // and the two layers share the same Box bounds, so the rendered pixels are unchanged. Hoisted Paints.
    val labelPaint = remember(textTertiary) {
        android.graphics.Paint().apply {
            isAntiAlias = true
            textSize = 22f
            textAlign = android.graphics.Paint.Align.RIGHT
            color = textTertiary.toArgb()
        }
    }
    val tooltipPaint = remember(textPrimary) {
        android.graphics.Paint().apply {
            isAntiAlias = true
            textSize = 26f
            color = textPrimary.toArgb()
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            textAlign = android.graphics.Paint.Align.CENTER
        }
    }

    fun DrawScope.yFor(level: Double, topPad: Float, usable: Float): Float =
        topPad + (1f - (level / 3.0).coerceIn(0.0, 1.0).toFloat()) * usable

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(100.dp)
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .semantics { contentDescription = daytimeLineDescription(hours) }
            .pointerInput(hours) {
                // Single gesture handler: first touch shows the crosshair; dragging scrubs
                // across hours; lifting the finger clears it.
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val chartW = (size.width - yAxisPx).coerceAtLeast(1f)
                    scrubFrac = ((down.position.x - yAxisPx) / chartW).coerceIn(0f, 1f)
                    var ptr = down
                    while (ptr.pressed) {
                        val event = awaitPointerEvent()
                        ptr = event.changes.firstOrNull() ?: break
                        if (ptr.pressed) {
                            ptr.consume()
                            scrubFrac = ((ptr.position.x - yAxisPx) / chartW).coerceIn(0f, 1f)
                        }
                    }
                    scrubFrac = null
                }
            },
    ) {
        // STATIC base layer — axis + gradient line/fill. `drawWithCache` rebuilds the cached Paths only
        // when the chart's size or `levels` change (the cache block reads neither `scrubFrac`), so a
        // scrub drag never re-walks the run-builder or re-allocates Paths. Same draw order as before.
        Box(
            modifier = Modifier
                .matchParentSize()
                .drawWithCache {
                    val w = size.width
                    val h = size.height
                    val topPad = 8.dp.toPx()
                    val botPad = 8.dp.toPx()
                    val usable = (h - topPad - botPad).coerceAtLeast(1f)
                    val chartLeft = yAxisPx
                    val chartW = (w - chartLeft).coerceAtLeast(1f)
                    val stepX = if (levels.size > 1) chartW / (levels.size - 1) else chartW
                    fun yForC(level: Double): Float =
                        topPad + (1f - (level / 3.0).coerceIn(0.0, 1.0).toFloat()) * usable

                    // Pre-build the gradient line + fill Paths for each contiguous run (null breaks).
                    data class Run(val fill: Path?, val line: Path?, val dot: Offset?, val dotColor: Color?)
                    val runs = ArrayList<Run>()
                    var i = 0
                    while (i < levels.size) {
                        if (levels[i] == null) { i++; continue }
                        var j = i
                        val pts = ArrayList<Offset>()
                        while (j < levels.size && levels[j] != null) {
                            pts.add(Offset(chartLeft + j * stepX, yForC(levels[j]!!)))
                            j++
                        }
                        if (pts.size >= 2) {
                            val fill = Path().apply {
                                moveTo(pts.first().x, h - botPad)
                                pts.forEach { lineTo(it.x, it.y) }
                                lineTo(pts.last().x, h - botPad)
                                close()
                            }
                            val line = Path().apply {
                                moveTo(pts.first().x, pts.first().y)
                                for (k in 1 until pts.size) lineTo(pts[k].x, pts[k].y)
                            }
                            runs.add(Run(fill, line, null, null))
                        } else if (pts.size == 1) {
                            runs.add(Run(null, null, pts.first(), StressRamp.color(levels[i]!!)))
                        }
                        i = j
                    }
                    val strokeW = 3.dp.toPx()
                    val dotR = 2.5.dp.toPx()

                    onDrawBehind {
                        if (w <= 0f || h <= 0f) return@onDrawBehind
                        // Y-axis: hairline grid lines + scale labels 0 / 1 / 2 / 3.
                        listOf(0.0, 1.0, 2.0, 3.0).forEach { lvl ->
                            val y = yForC(lvl)
                            drawLine(color = hairline, start = Offset(chartLeft, y), end = Offset(w, y), strokeWidth = 1f)
                            drawContext.canvas.nativeCanvas.drawText(lvl.toInt().toString(), chartLeft - 6f, y + 8f, labelPaint)
                        }
                        // Gradient line + fill — contiguous runs (null levels break the line).
                        runs.forEach { r ->
                            if (r.fill != null) drawPath(r.fill, brush = gradient, alpha = StrandAlpha.chartFillSoft + 0.10f)
                            if (r.line != null) drawPath(r.line, brush = gradient, style = Stroke(width = strokeW, cap = StrokeCap.Round, join = StrokeJoin.Round))
                            if (r.dot != null && r.dotColor != null) drawCircle(color = r.dotColor, radius = dotR, center = r.dot)
                        }
                    }
                },
        )

        // DYNAMIC overlay — crosshair + dot + tooltip pill, drawn only while the finger is down. A thin
        // Canvas that re-records on each scrub frame; the heavy static Paths above are untouched.
        Canvas(modifier = Modifier.matchParentSize()) {
            val w = size.width
            val h = size.height
            if (w <= 0f || h <= 0f) return@Canvas
            val frac = scrubFrac ?: return@Canvas

            val topPad = 8.dp.toPx()
            val botPad = 8.dp.toPx()
            val usable = (h - topPad - botPad).coerceAtLeast(1f)
            val chartLeft = yAxisPx
            val chartW = (w - chartLeft).coerceAtLeast(1f)
            val stepX = if (levels.size > 1) chartW / (levels.size - 1) else chartW

            val scrubIdx = (frac * (levels.size - 1)).roundToInt().coerceIn(0, levels.size - 1)
            val scrubX = chartLeft + scrubIdx * stepX
            val pt = hours[scrubIdx]

            // Dashed vertical crosshair at the selected hour.
            drawLine(
                color = textTertiary,
                start = Offset(scrubX, topPad),
                end = Offset(scrubX, h - botPad),
                strokeWidth = 1.5.dp.toPx(),
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 4f)),
            )

            val lvl = pt.level
            if (lvl != null) {
                val dotY = yFor(lvl, topPad, usable)
                // Ring dot at the scrubbed point.
                drawCircle(color = stressColor, radius = 5.dp.toPx(), center = Offset(scrubX, dotY))
                drawCircle(color = Palette.tipCore, radius = 2.5.dp.toPx(), center = Offset(scrubX, dotY))

                // Tooltip pill: "9 am · 1.4" — avoid String.format; use integer tenths.
                val tenths = (lvl * 10).roundToInt().coerceIn(0, 30)
                val label = uiString(R.string.l10n_stress_screen_hourlabel_pt_hour_tenths_10_tenths_cd4c9c16, hourLabel(pt.hour), tenths / 10, tenths % 10)
                val textW = tooltipPaint.measureText(label)
                val pillPad = 10f
                val pillW = textW + pillPad * 2
                val pillH = 34f
                val pillX = (scrubX - pillW / 2f).coerceIn(chartLeft, w - pillW)
                val pillY = (dotY - pillH - 10.dp.toPx()).coerceAtLeast(topPad)
                drawRoundRect(
                    color = stressColor.copy(alpha = 0.18f),
                    topLeft = Offset(pillX, pillY),
                    size = Size(pillW, pillH),
                    cornerRadius = CornerRadius(pillH / 2),
                )
                drawContext.canvas.nativeCanvas.drawText(label, pillX + pillW / 2f, pillY + pillH * 0.68f, tooltipPaint)
            }
        }
    }
}

private fun daytimeLineDescription(hours: List<DaytimeStress.HourPoint>): String {
    val scored = hours.mapNotNull { p -> p.level?.let { p.hour to it } }
    if (scored.isEmpty()) return "No intraday stress data yet today."
    val parts = scored.map { "${it.first}:00 ${String.format(Locale.US, "%.1f", it.second)}" }
    return "Hourly stress today: " + parts.joinToString(", ")
}

// MARK: - Time-in-band — Calm / Moderate / High split of the scored waking hours (liquid tubes)
//
// The liquid restyle of the README screen-9 totals split: instead of one stacked proportional bar, each
// band gets its OWN [LiquidTube] row filled to that band's SHARE of the day's scored hours (a genuine
// single-value 0..1 fraction per row — Calm hours / total, Moderate / total, High / total), tinted by the
// SAME StressRamp band colour (blue → green → amber). `animated = false` so the three tubes pose once and
// cost nothing per frame. The swatch + label sit on the left, the hour count on the right; the shares still
// sum to the day.

@Composable
private fun StressTotalsBar(day: DaytimeStress.Result) {
    val scored = day.scored
    if (scored.isEmpty()) return

    val calm = scored.count { (it.level ?: 0.0) < 1.0 }
    val high = scored.count { (it.level ?: 0.0) >= 2.0 }
    val moderate = scored.size - calm - high
    val total = scored.size.toDouble()

    NoopCard(tint = Palette.stressColor) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("Time in band")

            TimeInBandRow(StressTotalsBand.Calm, calm, total)
            TimeInBandRow(StressTotalsBand.Moderate, moderate, total)
            TimeInBandRow(StressTotalsBand.High, high, total)
        }
    }
}

private enum class StressTotalsBand(val title: String, val color: Color) {
    Calm("Calm", StressRamp.CALM),         // blue — low stress
    Moderate("Moderate", StressRamp.STEADY), // green — balanced
    High("High", StressRamp.TENSE),        // amber — high
}

/** One band's share of the scored waking hours as a liquid tube row: a swatch + label on the left, the
 *  band-tinted [LiquidTube] filled to hours/total, and the hour count on the right. Posed (animated=false). */
@Composable
private fun TimeInBandRow(band: StressTotalsBand, hours: Int, total: Double) {
    val frac = if (total > 0) hours / total else 0.0
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = uiString(R.string.l10n_stress_screen_band_title_hours_hours_f9779fd3, band.title, hours) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier
                .size(Metrics.legendSwatch)
                .clip(CircleShape)
                .background(if (hours > 0) band.color else Palette.surfaceInset),
        )
        Text(
            band.title,
            style = NoopType.captionNumber,
            color = if (hours > 0) band.color else Palette.textTertiary,
            modifier = Modifier.width(72.dp),
        )
        LiquidTube(
            frac = frac,
            tint = band.color,
            height = Metrics.progressHeight,
            animated = false,
            modifier = Modifier.weight(1f),
        )
        Text(
            uiString(R.string.l10n_stress_screen_hours_h_7610ac7c, hours),
            style = NoopType.captionNumber,
            color = if (hours > 0) Palette.textSecondary else Palette.textTertiary,
            textAlign = TextAlign.End,
            modifier = Modifier.width(32.dp),
        )
    }
}

/** "avg 1.4 · 9h" summary for the timeline header, from the scored hours. */
private fun timelineTrailing(day: DaytimeStress.Result): String {
    val n = day.scored.size
    val mean = day.dayMean ?: return "${n}h"
    return "avg " + String.format(Locale.US, "%.1f", mean) + " · ${n}h"
}

/**
 * A passive, in-app nudge to run a Breathe session after a sustained high-stress run. No
 * notification — just a card with a CTA that opens the existing trainer.
 */
@Composable
private fun SustainedBreatheCard(day: DaytimeStress.Result, onBreathe: () -> Unit) {
    NoopCard(tint = Palette.stressColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Overline("Sustained high stress", modifier = Modifier.weight(1f))
                StatePill("${day.sustainedRun}h elevated", tone = StrandTone.Warning, showsDot = true)
            }
            Text(
                uiString(R.string.l10n_stress_screen_your_last_day_sustainedrun_hours_have_194825dd, day.sustainedRun) +
                    "of paced breathing can help downshift your nervous system.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            NoopButton(
                text = uiString(R.string.l10n_stress_screen_start_a_breathe_session_9619e5c0),
                leadingIcon = Icons.Filled.Air,
                kind = NoopButtonKind.Primary,
                fullWidth = true,
                onClick = onBreathe,
            )
        }
    }
}

/** "6 am" / "2 pm" style hour-of-day label. */
private fun hourLabel(hour: Int): String {
    val h = ((hour % 24) + 24) % 24
    val ampm = if (h < 12) "am" else "pm"
    val h12 = if (h % 12 == 0) 12 else h % 12
    return "$h12 $ampm"
}


// MARK: - 2 · Today's tiles (uniform grid)

@Composable
private fun StressTiles(model: StressModel) {
    val tiles = listOf<@Composable (Modifier) -> Unit>(
        { m ->
            // Today's stress value, with its band as the caption.
            StatTile(
                modifier = m,
                label = uiString(R.string.l10n_stress_screen_stress_bad33342),
                value = String.format(Locale.US, "%.1f", model.score),
                caption = "of 3 · ${model.band.title}",
                accent = StressRamp.color(model.score),
            )
        },
        { m ->
            // Resting HR — an INCREASE is the stressful direction.
            MarkerTile(
                modifier = m,
                label = uiString(R.string.l10n_stress_screen_resting_hr_26677094),
                value = model.rhrToday?.let { "$it bpm" } ?: "—",
                delta = model.rhrDelta,
                accent = Palette.metricRose,
                higherIsStress = true,
            )
        },
        { m ->
            // HRV — a DECREASE is the stressful direction.
            MarkerTile(
                modifier = m,
                label = "HRV",
                value = model.hrvToday?.let { "${it.roundToInt()} ms" } ?: "—",
                delta = model.hrvDelta,
                accent = Palette.metricPurple,
                higherIsStress = false,
            )
        },
        { m ->
            // Estimated calm time — share of recent days spent in the LOW band.
            StatTile(
                modifier = m,
                label = uiString(R.string.l10n_stress_screen_calm_time_fa546d52),
                value = model.calmTimeValue,
                caption = model.calmTimeCaption,
                accent = StressRamp.CALM,
            )
        },
    )
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        tiles.chunked(2).forEach { rowTiles ->
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                rowTiles.forEach { tile -> tile(Modifier.weight(1f)) }
                if (rowTiles.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/**
 * A vs-baseline marker as a fixed-height [StatTile]. The delta is tinted by whether
 * the move is toward stress (warning) or recovery (positive). Mirrors macOS markerTile.
 */
@Composable
private fun MarkerTile(
    label: String,
    value: String,
    delta: Double?,
    accent: Color,
    higherIsStress: Boolean,
    modifier: Modifier = Modifier,
) {
    val deltaText: String
    val deltaColor: Color
    if (delta != null && kotlin.math.abs(delta) >= 0.5) {
        val up = delta > 0
        val isStressful = (up == higherIsStress)
        deltaText = "${if (up) "+" else "−"}${kotlin.math.abs(delta).roundToInt()} vs base"
        deltaColor = if (isStressful) Palette.statusWarning else Palette.statusPositive
    } else {
        deltaText = "at baseline"
        deltaColor = Palette.textTertiary
    }
    StatTile(
        modifier = modifier,
        label = label,
        value = value,
        accent = accent,
        delta = deltaText,
        deltaColor = deltaColor,
        // #492 item 5: on narrow two-column cards the intrinsic-width "vs base" chip used to consume
        // nearly the whole row and leave the reading as "4…" / "73…". Share the row evenly so the real
        // physiological value stays intact; the explanatory chip is the element allowed to ellipsize.
        compactDelta = true,
    )
}

// MARK: - 3 · Trend (range-controlled)

@Composable
private fun StressTrendSection(model: StressModel, modifier: Modifier = Modifier) {
    var range by remember { mutableStateOf(StressRange.Month) }
    val points = remember(model, range) { model.windowedTrend(range) }

    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Stress Trend", overline = "History", trailing = range.label)
        if (points.size >= 2) {
            val avg = points.average()
            NoopCard(tint = Palette.stressColor) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Overline("Stress · ${range.label}")
                            Text(
                                uiString(R.string.l10n_stress_screen_daily_0_3_proxy_63247929),
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                        Text(
                            uiString(R.string.l10n_stress_screen_avg_a178769d) + String.format(Locale.US, "%.1f", avg),
                            style = NoopType.captionNumber,
                            color = Palette.textSecondary,
                        )
                    }
                    LineChart(
                        values = points,
                        modifier = Modifier.height(Metrics.chartHeight),
                        color = StressRamp.STEADY,
                        fill = true,
                        selectionEnabled = true,
                    )
                    HorizontalDivider(color = Palette.hairline)
                    Row(modifier = Modifier.fillMaxWidth()) {
                        TrendFooterItem("Today", String.format(Locale.US, "%.1f", model.score))
                        TrendFooterItem("Average", String.format(Locale.US, "%.1f", avg))
                        TrendFooterItem("Days", points.size.toString())
                    }
                }
            }
            // The one segmented control — full width, right-aligned.
            Row(modifier = Modifier.fillMaxWidth()) {
                Spacer(Modifier.weight(1f))
                SegmentedPillControl(
                    items = StressRange.entries,
                    selection = range,
                    label = { it.label },
                    onSelect = { range = it },
                )
            }
        } else {
            NoopCard(tint = Palette.stressColor) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(120.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        uiString(R.string.l10n_stress_screen_not_enough_recent_days_to_chart_c072bade),
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TrendFooterItem(label: String, value: String) {
    Column(modifier = Modifier.weight(1f)) {
        Overline(label)
        Text(value, style = NoopType.number(18f), color = Palette.textPrimary)
    }
}

// MARK: - 4 · Methodology (transparency)

@Composable
private fun StressMethodologyCard(model: StressModel, modifier: Modifier = Modifier) {
    NoopCard(tint = Palette.stressColor, modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Overline("How this is computed")
            Text(
                if (model.usingStored) {
                    "Today's value is your recorded daily stress score (0-3)."
                } else {
                    "Stress is derived from two autonomic signals."
                },
                style = NoopType.body,
                color = Palette.textPrimary,
            )
            Text(
                uiString(R.string.l10n_stress_screen_we_compare_today_s_resting_heart_a9cd0955) +
                    "baseline. A higher-than-usual resting HR and a lower-than-usual HRV " +
                    "both push the score up, classic signs the body is activated. The " +
                    "combined shift is mapped onto a 0-3 scale: 0 is calm, 1.5 sits at " +
                    "your baseline, 3 is highly activated.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            HorizontalDivider(color = Palette.hairline)
            Row(modifier = Modifier.fillMaxWidth()) {
                BandLegend("0-1", "LOW", StressRamp.CALM)
                BandLegend("1-2", "MEDIUM", StressRamp.STEADY)
                BandLegend("2-3", "HIGH", StressRamp.TENSE)
            }
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.BandLegend(range: String, label: String, color: Color) {
    Row(
        modifier = Modifier.weight(1f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(color),
        )
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(label, style = NoopType.captionNumber, color = Palette.textPrimary)
            Text(range, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

// MARK: - Empty / loading states

@Composable
private fun StressLoading() {
    NoopCard {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(160.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                uiString(R.string.l10n_stress_screen_reading_your_heart_rate_variability_and_c0249246),
                style = NoopType.subhead,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun StressEmpty() {
    DataPendingNote(
        title = uiString(R.string.l10n_stress_screen_no_stress_history_yet_ec962e3c),
        body = "No stress history yet. Import your WHOOP export in Data Sources to see it.",
    )
}

// MARK: - Stress band

internal enum class StressBand(val title: String, val tone: StrandTone) {
    Low("LOW", StrandTone.Positive),
    Medium("MEDIUM", StrandTone.Warning),
    High("HIGH", StrandTone.Critical);

    companion object {
        fun forScore(score: Double): StressBand = when {
            score < 1.0 -> Low
            score < 2.0 -> Medium
            else -> High
        }
    }
}

// MARK: - Stress ramp (the WHOOP Stress sweep: blue → green → amber)
//
// The Stress screen's one ramp, matching the iOS StressRamp exactly. WHOOP has NO gold:
// calm reads as the link blue, a balanced day as positive green, and a high-stress day as
// warning amber. The PipBar tint, the day autonomic-load line, the Calm/Moderate/High totals
// bar and the trend all sample this SAME ramp, so the colour language is identical across the
// screen. Never the gold or red→green recovery ramp.

private object StressRamp {
    val CALM = Palette.accent           // calm WHOOP blue — low
    val STEADY = Palette.statusPositive // balanced WHOOP green — baseline
    val TENSE = Palette.statusWarning   // high WHOOP amber — high

    /** The 3-stop ramp, evenly spaced (blue → green → amber). */
    val stops: List<Pair<Float, Color>> = listOf(
        0.00f to CALM,
        0.50f to STEADY,
        1.00f to TENSE,
    )

    /** Sample the ramp at a 0–3 stress score. */
    fun color(score: Double): Color = Palette.sample(stops, (score / 3.0).toFloat())
}

// MARK: - Trend range (the W/M/3M/6M/1Y/ALL window, mirroring ExploreRange)

internal enum class StressRange(val label: String, val days: Int?) {
    Week("W", 7),
    Month("M", 30),
    Quarter("3M", 90),
    Half("6M", 180),
    Year("1Y", 365),
    All("ALL", null),
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

// #753: `internal` (was file-private) so Today's pinned Stress card can build the SAME model the detail
// screen shows and read `model.score`, instead of taking the stress series' last banked row. The pinned card
// and the detail page then derive today's score identically (stored row preferred, else live RHR/HRV
// baseline) and refresh on the same data, so the pinned card never lags the detail page (e.g. a stale "2").
// The constructor stays private; only the companion `build` factory is exposed.
internal class StressModel private constructor(
    val score: Double,            // 0–3 (today)
    val band: StressBand,
    val explanation: String,
    val rhrToday: Int?,
    val hrvToday: Double?,
    val rhrDelta: Double?,        // today − baseline mean (bpm)
    val hrvDelta: Double?,        // today − baseline mean (ms)
    val fullTrend: List<TrendPoint>, // entire daily proxy history, oldest → newest
    val calmTimeValue: String,
    val calmTimeCaption: String,
    val usingStored: Boolean,     // true when today's value came from the stored series
) {
    data class TrendPoint(val day: String, val value: Double)

    /** The full daily proxy trend, sliced to the selected trailing window (count-based,
     *  matching the day budget). Falls back to ALL when the trailing slice has < 2 points. */
    fun windowedTrend(range: StressRange): List<Double> {
        val all = fullTrend.map { it.value }
        val days = range.days ?: return all
        val slice = fullTrend.takeLast(days).map { it.value }
        return if (slice.size >= 2) slice else all
    }

    companion object {
        /** Build from oldest→newest daily metrics plus any stored "stress" series.
         *  Returns null only when there is no usable signal at all. */
        fun build(days: List<DailyMetric>, stored: Map<String, Double>): StressModel? {
            // Carry (#543): today's own row is often vitals-less until the overnight is analyzed —
            // especially right after an app update relaunches and re-runs the pass — so score the NEWEST
            // day that actually carries usable signal (RHR/HRV, or a stored/imported stress value) instead
            // of calibrating, the same last-night carry every other Today vital uses. The predicate mirrors
            // the storedToday||derived gate below, so an imported stress-only latest day is still honored
            // (not skipped). Falls back to the last row when no day has any signal (cold start).
            val idx = days.indexOfLast {
                it.restingHr != null || it.avgHrv != null || stored.containsKey(it.day)
            }.let { if (it >= 0) it else days.size - 1 }
            if (idx < 0) return null   // no days at all
            val today = days[idx]

            // Baseline window: up to 30 days ending the day BEFORE the scored day, so it's measured
            // against its own recent past rather than itself.
            val baseline = if (idx > 0) days.subList(0, idx).takeLast(30) else emptyList()

            val rhrBase = baseline.mapNotNull { it.restingHr?.toDouble() }
            val hrvBase = baseline.mapNotNull { it.avgHrv }

            val meanRHR = mean(rhrBase)
            val sdRHR = std(rhrBase, meanRHR)
            val meanHRV = mean(hrvBase)
            val sdHRV = std(hrvBase, meanHRV)

            val rhrT = today.restingHr?.toDouble()
            val hrvT = today.avgHrv

            val derivedAvailable = (rhrT != null && meanRHR != null) || (hrvT != null && meanHRV != null)
            val storedToday = stored[today.day]
            if (storedToday == null && !derivedAvailable) return null

            val derivedToday: Double? = if (derivedAvailable) {
                squash(rawScore(rhrT, meanRHR, sdRHR, hrvT, meanHRV, sdHRV))
            } else {
                null
            }

            val s = storedToday ?: derivedToday ?: 1.5
            val usingStored = storedToday != null
            val band = StressBand.forScore(s)
            val rhrDelta = if (rhrT != null && meanRHR != null) rhrT - meanRHR else null
            val hrvDelta = if (hrvT != null && meanHRV != null) hrvT - meanHRV else null
            val explanation = explanation(band, rhrDelta, hrvDelta)

            // Full daily proxy history: stored value if present for the day, else the
            // z-score derivation against the SAME baseline so the line is comparable.
            val pts = ArrayList<TrendPoint>()
            for (d in days) {
                val v = stored[d.day]
                if (v != null) {
                    pts.add(TrendPoint(d.day, v.coerceIn(0.0, 3.0)))
                    continue
                }
                val dRHR = d.restingHr?.toDouble()
                val dHRV = d.avgHrv
                if ((dRHR == null || meanRHR == null) && (dHRV == null || meanHRV == null)) continue
                pts.add(TrendPoint(d.day, squash(rawScore(dRHR, meanRHR, sdRHR, dHRV, meanHRV, sdHRV))))
            }

            // "Calm time": share of the last 30 charted days that sat in the LOW band.
            val recent = pts.takeLast(30)
            val calmValue: String
            val calmCaption: String
            if (recent.isEmpty()) {
                calmValue = "—"
                calmCaption = "needs history"
            } else {
                val calm = recent.count { it.value < 1.0 }
                val pct = (calm.toDouble() / recent.size * 100).roundToInt()
                calmValue = "$pct%"
                calmCaption = "low-stress days · ${recent.size}d"
            }

            return StressModel(
                score = s,
                band = band,
                explanation = explanation,
                rhrToday = today.restingHr,
                hrvToday = hrvT,
                rhrDelta = rhrDelta,
                hrvDelta = hrvDelta,
                fullTrend = pts,
                calmTimeValue = calmValue,
                calmTimeCaption = calmCaption,
                usingStored = usingStored,
            )
        }

        // MARK: Stress math (pure helpers, ported from StressMath)

        private fun mean(xs: List<Double>): Double? =
            if (xs.isEmpty()) null else xs.sum() / xs.size

        /** Population standard deviation; 0 when there's no spread. */
        private fun std(xs: List<Double>, m: Double?): Double {
            if (m == null || xs.size <= 1) return 0.0
            val v = xs.sumOf { (it - m) * (it - m) } / xs.size
            return sqrt(v)
        }

        /** Combined autonomic z-score. RHR-up and HRV-down both push it positive. */
        private fun rawScore(
            rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
            hrvToday: Double?, meanHRV: Double?, sdHRV: Double,
        ): Double {
            var sum = 0.0
            if (rhrToday != null && meanRHR != null && sdRHR > 0.0001) {
                sum += (rhrToday - meanRHR) / sdRHR        // up = stress
            }
            if (hrvToday != null && meanHRV != null && sdHRV > 0.0001) {
                sum += (meanHRV - hrvToday) / sdHRV        // down = stress
            }
            return sum
        }

        /** Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5). */
        private fun squash(raw: Double): Double =
            (3.0 / (1.0 + exp(-raw))).coerceIn(0.0, 3.0)

        private fun explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?): String {
            val rhrUp = (rhrDelta ?: 0.0) > 1.0
            val hrvDn = (hrvDelta ?: 0.0) < -1.0
            val hrvUp = (hrvDelta ?: 0.0) > 1.0
            val rhrDn = (rhrDelta ?: 0.0) < -1.0
            return when (band) {
                StressBand.High -> when {
                    rhrUp && hrvDn -> "Resting HR is elevated and HRV is below your baseline, both classic signs of high activation. Prioritise rest, hydration and an easy day."
                    hrvDn -> "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover."
                    rhrUp -> "Resting heart rate is running high versus your norm. Your body is under load today. Keep effort light."
                    else -> "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day."
                }
                StressBand.Medium -> when {
                    rhrUp || hrvDn -> "Slightly off baseline (${if (rhrUp) "resting HR is a touch high" else "HRV is a little low"}), so you're moderately activated. Nothing alarming; just don't overreach."
                    else -> "You're sitting around your typical autonomic baseline: moderate stress, a normal, balanced day."
                }
                StressBand.Low -> when {
                    rhrDn && hrvUp -> "Resting heart rate is low and HRV is up. Your nervous system looks well-recovered and calm. A great day to push if you want to."
                    hrvUp -> "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low."
                    else -> "Resting heart rate and HRV are sitting at or below baseline: low physiological stress. You're in a calm, recovered state."
                }
            }
        }
    }
}
