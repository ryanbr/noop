package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.LocalBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.analytics.DoseCurvePoint
import com.noop.analytics.DoseResponse
import com.noop.analytics.DoseResponseEngine
import com.noop.analytics.DoseResponsePriors
import com.noop.analytics.DosedBehavior
import com.noop.analytics.EffectRanker
import com.noop.analytics.RankedEffect
import com.noop.analytics.ScoreConfidence
import com.noop.data.DailyMetric
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// MARK: - Insights Hub (v5)
//
// The headline n-of-1 "what actually moves YOUR recovery" surface — the Compose twin of
// Strand/Screens/InsightsHubView.swift. Two halves, both pure association on the user's
// own logged days, never advice / cause / diagnosis:
//
//  1. WHAT MOVES YOUR CHARGE — the unified lag-aware EffectRanker feed. Each row keeps the
//     strongest honest lag ({0,+1,+2}) so it reads "shows up the next morning"; carries the
//     sign-aware sentence, with/without means, a lead/lag chip, the effect-size word, and a
//     Solid / Building / Calibrating confidence pill (not a bare "significant" stamp).
//
//  2. ALCOHOL / CAFFEINE DOSE-RESPONSE — the personal DoseResponseEngine curve that SHRINKS
//     toward a documented population prior until enough nights accrue. Plots the shrunk curve,
//     states "each extra drink ≈ −N for you" (honest when prior-dominated, or when YOUR data
//     contradicts the prior), and an evening "damage forecast" — "a 2nd drink tonight ≈ −X
//     Charge tomorrow" — driven by a small dose stepper on the latest Charge. Never a nudge
//     to drink or abstain.
//
// SELF-CONTAINED: owns its own InsightsHubViewModel (constructed from vm.repo + cached days);
// does NOT edit AppViewModel / AppRoot / the central nav. Wave 3 surfaces it at the head of the
// Insights hub. All maths is in com.noop.analytics (EffectRanker / DoseResponseEngine).

@Composable
fun InsightsHubScreen(vm: AppViewModel) {
    val days by vm.recentDays.collectAsState()
    val hub = remember { InsightsHubViewModel() }
    val state by hub.state.collectAsState()

    // Re-derive whenever the cached days change underneath (journal + dose are read via repo).
    androidx.compose.runtime.LaunchedEffect(days) { hub.load(vm, days) }

    var outcome by remember { mutableStateOf(InsightsOutcome.Recovery) }
    val ranked = remember(state, outcome) { hub.rankFor(state, outcome) }

    ScreenScaffold(title = "Insights", subtitle = "Patterns in your own data — association, not cause.") {
        if (!state.loaded) {
            NoopCard {
                Text("Reading your journal and outcomes…", style = NoopType.subhead, color = Palette.textTertiary)
            }
            return@ScreenScaffold
        }

        // --- What moves your Charge -------------------------------------------
        MoversSection(outcome = outcome, onOutcome = { outcome = it }, ranked = ranked)

        Spacer(Modifier.height(Metrics.sectionGap - 20.dp))

        // --- Dose-response (alcohol / caffeine) -------------------------------
        DoseSection(state.doseCards)

        Spacer(Modifier.height(Metrics.sectionGap - 20.dp))

        // --- Method / honesty note --------------------------------------------
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Overline("How to read this", color = Palette.textTertiary)
                Text(
                    "Everything here is a pattern in your own logged days — an association with an " +
                        "effect size and confidence, never a cause or a diagnosis. Population patterns " +
                        "are shown as “typical” and are always overridden by your own data once " +
                        "you have enough of it. Approximations, not WHOOP’s scores; not a medical device.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

// MARK: - What moves your Charge

@Composable
private fun MoversSection(
    outcome: InsightsOutcome,
    onOutcome: (InsightsOutcome) -> Unit,
    ranked: List<RankedEffect>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Header then the outcome selector on its own row below it — on a ~360dp phone the pill
        // control can't share a row with the weighted header without compressing (matches macOS).
        SectionHeader(
            "What moves your ${outcome.outcomeName.lowercase(Locale.US)}",
            overline = "Ranked · your data",
        )
        SegmentedPillControl(
            items = InsightsOutcome.entries.toList(),
            selection = outcome,
            label = { it.label },
            onSelect = onOutcome,
        )

        if (ranked.isEmpty()) {
            NoopCard {
                Text(
                    "Not enough overlap between your journal answers and " +
                        "${outcome.outcomeName.lowercase(Locale.US)} yet. Keep logging — each behaviour " +
                        "needs days both with and without it before NOOP can read its effect.",
                    style = NoopType.subhead,
                    color = Palette.textTertiary,
                )
            }
        } else {
            ranked.forEach { MoverCard(it, outcome) }
        }
    }
}

@Composable
private fun MoverCard(r: RankedEffect, outcome: InsightsOutcome) {
    val e = r.effect
    val movedGood: Boolean? = when {
        e.delta == 0.0 -> null
        else -> (e.delta > 0) == outcome.higherIsBetter
    }
    val tone: StrandTone = when (movedGood) {
        null -> StrandTone.Neutral
        true -> StrandTone.Positive
        false -> if (e.significant) StrandTone.Critical else StrandTone.Warning
    }
    val tintColor = tone.color
    val arrow = if (e.delta > 0) "↑" else if (e.delta < 0) "↓" else "→"
    val deltaText = e.pctChange?.let { "$arrow ${abs(it).roundToInt()}%" }
        ?: "$arrow ${String.format(Locale.US, "%.1f", abs(e.delta))}"

    NoopCard(tint = outcome.domain.color) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header: behaviour name + lead/lag chip + confidence pill.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .drawBehind { drawCircle(tintColor) },
                    )
                    Text(
                        r.behavior,
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                StatePill(r.leadLagText, tone = StrandTone.Accent, showsDot = false)
                Spacer(Modifier.width(6.dp))
                ConfidencePill(r.confidence)
            }

            Text(r.sentence(), style = NoopType.body, color = Palette.textSecondary)

            // With / without means as uniform StatTiles.
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = "With",
                    value = outcome.format(e.meanWith),
                    caption = "n = ${e.nWith}",
                    accent = tintColor,
                    delta = deltaText,
                    deltaColor = tintColor,
                )
                StatTile(
                    modifier = Modifier.weight(1f),
                    label = "Without",
                    value = outcome.format(e.meanWithout),
                    caption = "n = ${e.nWithout}",
                    accent = Palette.textPrimary,
                )
            }

            HorizontalDivider(color = Palette.hairline)

            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Overline("Effect size", modifier = Modifier.weight(1f))
                Text(
                    String.format(Locale.US, "d = %.2f", e.cohensD),
                    style = NoopType.captionNumber,
                    color = tintColor,
                )
                Spacer(Modifier.width(6.dp))
                Text(effectMagnitudeWord(e.cohensD), style = NoopType.caption, color = Palette.textTertiary)
            }
        }
    }
}

// MARK: - Dose-response

@Composable
private fun DoseSection(cards: List<DoseCardData>) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Dose-response", overline = "Personal curve · prior-shrunk")
        if (cards.isEmpty()) {
            NoopCard {
                Text(
                    "Log alcohol or late caffeine with an amount and NOOP fits a personal dose curve " +
                        "— how much each extra unit tends to move your numbers. Until then it shows " +
                        "typical patterns, clearly labelled as not yet yours.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        } else {
            cards.forEach { DoseResponseCard(it) }
        }
    }
}

@Composable
private fun DoseResponseCard(card: DoseCardData) {
    val r = card.response
    val domain = if (card.outcomeName == "HRV") DomainTheme.Rest else DomainTheme.Charge
    // The evening preview dose, defaulting to a 2nd drink so the headline reads as a 2nd-drink forecast.
    var previewDose by remember(card.id) { mutableStateOf(2) }

    NoopCard(tint = domain.color) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(card.icon, contentDescription = null, tint = domain.color, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(card.title, style = NoopType.headline, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                ConfidencePill(r.confidence)
            }

            Text(r.sentence(), style = NoopType.body, color = Palette.textSecondary)

            // The prior-shrunk curve.
            DoseCurveChart(
                points = r.curve,
                accent = domain.color,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(132.dp)
                    .clearAndSetSemantics { contentDescription = curveDescription(card, r) },
            )

            if (r.priorDominated) {
                HonestyBanner(
                    "Based mostly on typical patterns — not yet yours. Log a few more " +
                        "${card.unitLabel.lowercase(Locale.US)} days and this becomes yours.",
                    accent = Palette.textTertiary,
                )
            } else if (r.contradictsPrior) {
                HonestyBanner(
                    "In your data so far, this doesn’t move your ${card.outcomeName} the way it typically does.",
                    accent = Palette.statusPositive,
                )
            }

            if (card.timingProxy) {
                Text(
                    "“Dose” here is timing (later in the day = stronger), not milligrams.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }

            HorizontalDivider(color = Palette.hairline)

            DamageForecast(card, previewDose = previewDose, onPreviewDose = { previewDose = it }, domain = domain)
        }
    }
}

@Composable
private fun DamageForecast(
    card: DoseCardData,
    previewDose: Int,
    onPreviewDose: (Int) -> Unit,
    domain: DomainTheme,
) {
    val r = card.response
    val fromDose = 1
    val delta = r.delta(fromDose, previewDose)
    val projected = card.latestOutcome?.let { max(0.0, min(card.outcomeCeiling, it + delta)) }
    val stepLabel = if (previewDose <= 1) "no extra" else "$previewDose${card.dosePlusSuffix(previewDose)}"

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Overline then the dose stepper on its own row — the choices (0…max+) overflow a ~360dp
        // phone if they share a row with the overline (matches the macOS fix).
        Overline(card.forecastOverline, modifier = Modifier.fillMaxWidth())
        SegmentedPillControl(
            items = card.doseChoices,
            selection = previewDose,
            label = { card.doseChoiceLabel(it) },
            onSelect = onPreviewDose,
        )

        Text(
            forecastSentence(card, previewDose, delta, stepLabel),
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Per extra ${card.unitNoun}",
                value = signed(r.perUnit, card.outcomeSuffix),
                caption = if (r.priorDominated) "typical" else "your data",
                accent = if (r.perUnit < 0) Palette.statusCritical else Palette.statusPositive,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = "Tomorrow’s ${card.outcomeName}",
                value = projected?.let { "${it.roundToInt()}${card.outcomeSuffix}" } ?: "—",
                caption = if (projected != null) "projected · $stepLabel" else "needs a recent day",
                accent = domain.color,
            )
        }
    }
}

@Composable
private fun HonestyBanner(text: String, accent: Color) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceInset)
            .padding(10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(modifier = Modifier.size(8.dp).clip(CircleShape).drawBehind { drawCircle(accent) })
        Text(text, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

/** The confidence-lifecycle pill: Solid (positive/gold) / Building (accent) / Calibrating (neutral). */
@Composable
private fun ConfidencePill(c: ScoreConfidence) {
    val (label, tone) = when (c) {
        ScoreConfidence.SOLID -> "Solid" to StrandTone.Positive
        ScoreConfidence.BUILDING -> "Building" to StrandTone.Accent
        ScoreConfidence.CALIBRATING -> "Calibrating" to StrandTone.Neutral
    }
    StatePill(label, tone = tone, showsDot = false)
}

// MARK: - Dose curve chart
//
// A compact line+area chart of the prior-shrunk curve: dose on x (0…max), modelled outcome
// DELTA on y, symmetric around a dashed zero line so the sign reads honestly. Drawn with the
// Compose Canvas idiom so it sits in the design system with no extra dependency.

@Composable
private fun DoseCurveChart(points: List<DoseCurvePoint>, accent: Color, modifier: Modifier = Modifier) {
    val zeroColor = Palette.hairlineStrong
    Canvas(modifier = modifier) {
        if (points.isEmpty()) return@Canvas
        val w = size.width
        val h = size.height
        val maxAbs = max(1.0, points.maxOf { abs(it.outcomeDelta) })
        fun yFor(d: Double): Float {
            val t = (d / maxAbs + 1) / 2          // 0 (most negative) … 1 (most positive)
            return (h - t * h).toFloat()
        }
        val n = max(1, points.size - 1)
        fun xFor(i: Int): Float = i.toFloat() / n * w
        val zeroY = yFor(0.0)

        // Zero baseline (dashed).
        drawLine(
            color = zeroColor,
            start = Offset(0f, zeroY),
            end = Offset(w, zeroY),
            strokeWidth = 1f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f)),
        )

        // Filled area between the curve and the zero line.
        val area = Path().apply {
            moveTo(xFor(0), zeroY)
            points.forEachIndexed { i, pt -> lineTo(xFor(i), yFor(pt.outcomeDelta)) }
            lineTo(xFor(points.size - 1), zeroY)
            close()
        }
        drawPath(
            area,
            brush = Brush.verticalGradient(listOf(accent.copy(alpha = 0.22f), accent.copy(alpha = 0.03f))),
        )

        // The curve line.
        val line = Path().apply {
            points.forEachIndexed { i, pt ->
                val x = xFor(i)
                val y = yFor(pt.outcomeDelta)
                if (i == 0) moveTo(x, y) else lineTo(x, y)
            }
        }
        drawPath(line, color = accent, style = Stroke(width = 2.5.dp.toPx(), cap = StrokeCap.Round))

        // Dose markers.
        points.forEachIndexed { i, pt ->
            drawCircle(accent, radius = 2.5.dp.toPx(), center = Offset(xFor(i), yFor(pt.outcomeDelta)))
        }
    }
}

// MARK: - Outcome

internal enum class InsightsOutcome(
    val label: String,
    val outcomeName: String,
    val key: String,
    val higherIsBetter: Boolean,
    val domain: DomainTheme,
    val pick: (DailyMetric) -> Double?,
    val format: (Double) -> String,
) {
    Recovery("Charge", "Charge", "recovery", true, DomainTheme.Charge, { it.recovery }, { "${it.roundToInt()}%" }),
    Hrv("HRV", "HRV", "hrv", true, DomainTheme.Rest, { it.avgHrv }, { "${it.roundToInt()} ms" }),
    Sleep("Rest", "Rest", "sleep_performance", true, DomainTheme.Rest, { it.efficiency }, { "${it.roundToInt()}%" }),
    Rhr("RHR", "Resting HR", "rhr", false, DomainTheme.Stress, { it.restingHr?.toDouble() }, { "${it.roundToInt()} bpm" }),
}

// MARK: - Dose card view-data

internal data class DoseCardData(
    val behavior: DosedBehavior,
    val response: DoseResponse,
    val latestOutcome: Double?,
) {
    val id: String get() = behavior.raw
    val outcomeName: String get() = response.outcome
    val title: String get() = if (behavior == DosedBehavior.ALCOHOL) "Alcohol" else "Caffeine"
    val icon get() = if (behavior == DosedBehavior.ALCOHOL) Icons.Filled.LocalBar else Icons.Filled.Coffee
    val unitNoun: String get() = if (behavior == DosedBehavior.ALCOHOL) "drink" else "later step"
    val unitLabel: String get() = if (behavior == DosedBehavior.ALCOHOL) "drink" else "late-caffeine"
    val timingProxy: Boolean get() = behavior == DosedBehavior.CAFFEINE
    val outcomeSuffix: String get() = if (outcomeName == "HRV") " ms" else "%"
    val outcomeCeiling: Double get() = if (outcomeName == "HRV") 400.0 else 100.0
    val forecastOverline: String
        get() = if (behavior == DosedBehavior.ALCOHOL) "Tonight’s forecast" else "Timing forecast"

    val doseChoices: List<Int> get() = (0..DoseResponseEngine.maxCurveDose).toList()

    fun doseChoiceLabel(d: Int): String = when (behavior) {
        DosedBehavior.ALCOHOL -> if (d >= DoseResponseEngine.maxCurveDose) "$d+" else "$d"
        DosedBehavior.CAFFEINE -> when (d) {
            0 -> "AM"
            1 -> "Noon"
            2 -> "2pm+"
            else -> "Eve"
        }
    }

    fun dosePlusSuffix(d: Int): String =
        if (behavior == DosedBehavior.ALCOHOL) {
            if (d >= DoseResponseEngine.maxCurveDose) "+ drinks" else " drinks"
        } else ""
}

// MARK: - View-model
//
// Self-contained: loads the journal (behaviour → days), dose rows (under the dedicated
// noop-journal-dose source), and outcome series (cached DailyMetric rows), then runs
// EffectRanker for the ranked feed and DoseResponseEngine for each dosed behaviour with data.
// No edits to AppViewModel. Holds an immutable snapshot in a StateFlow.

internal class InsightsHubViewModel {

    data class Snapshot(
        val loaded: Boolean = false,
        val behaviours: Map<String, Set<String>> = emptyMap(),
        val outcomeByKey: Map<String, Map<String, Double>> = emptyMap(),
        val doseCards: List<DoseCardData> = emptyList(),
    )

    private val _state = MutableStateFlow(Snapshot())
    val state: StateFlow<Snapshot> = _state.asStateFlow()

    companion object {
        const val DOSE_SOURCE = "noop-journal-dose"
        private val OUTCOME_KEYS = listOf("recovery", "hrv", "sleep_performance", "rhr")

        fun doseKey(behavior: DosedBehavior): String = "dose_${behavior.raw}"

        fun matches(behavior: DosedBehavior, question: String): Boolean {
            val q = question.lowercase(Locale.US)
            return when (behavior) {
                DosedBehavior.ALCOHOL -> q.contains("alcohol") || q.contains("drink")
                DosedBehavior.CAFFEINE -> q.contains("caffeine") || q.contains("coffee")
            }
        }

        fun outcomeKeyFor(engineName: String): String = when (engineName) {
            "Charge" -> "recovery"
            "HRV" -> "hrv"
            "Rest" -> "sleep_performance"
            "Resting HR" -> "rhr"
            else -> "recovery"
        }
    }

    suspend fun load(vm: AppViewModel, days: List<DailyMetric>) {
        // Journal → behaviour → days (imported ∪ native, native wins; only "yes" counts).
        val imported = vm.repo.journal("my-whoop", "0000-01-01", "9999-12-31")
        val native = vm.repo.journal(JOURNAL_DEVICE_ID, "0000-01-01", "9999-12-31")
        val entries = mergeJournalEntries(imported, native)
        val byBehaviour = HashMap<String, MutableSet<String>>()
        for (e in entries) if (e.answeredYes) byBehaviour.getOrPut(e.question) { mutableSetOf() }.add(e.day)
        val behaviours = byBehaviour.mapValues { it.value.toSet() }

        // Outcome series straight off the cached DailyMetric rows (the guaranteed Android source).
        val outcomeByKey = HashMap<String, Map<String, Double>>()
        for (o in InsightsOutcome.entries) {
            val dict = HashMap<String, Double>()
            for (d in days) o.pick(d)?.let { dict[d.day] = it }
            outcomeByKey[o.key] = dict
        }

        // Dose rows per dosed behaviour, under the dedicated dose source; logged "yes" days
        // back-fill dose = 1, explicit dose rows override (matches the Swift contract).
        val doseCards = ArrayList<DoseCardData>()
        for (behavior in DosedBehavior.entries) {
            val doses = HashMap<String, Int>()
            for ((question, set) in behaviours) if (matches(behavior, question)) {
                for (day in set) doses[day] = max(doses[day] ?: 0, 1)
            }
            val rows = vm.repo.metricSeries(DOSE_SOURCE, doseKey(behavior), "0000-01-01", "9999-12-31")
            for (row in rows) doses[row.day] = row.value.roundToInt()
            if (doses.isEmpty()) continue

            val outcomeName = DoseResponsePriors.defaultOutcome(behavior)
            val outcomeDays = outcomeByKey[outcomeKeyFor(outcomeName)] ?: emptyMap()
            val response = DoseResponseEngine.estimate(behavior, doses, outcomeDays) ?: continue
            val latest = outcomeDays.keys.maxOrNull()?.let { outcomeDays[it] }
            doseCards.add(DoseCardData(behavior, response, latest))
        }

        _state.value = Snapshot(
            loaded = true,
            behaviours = behaviours,
            outcomeByKey = outcomeByKey,
            doseCards = doseCards,
        )
    }

    /** Re-rank the mover feed for a (possibly new) outcome — cheap, no DB. */
    fun rankFor(snapshot: Snapshot, outcome: InsightsOutcome): List<RankedEffect> {
        if (!snapshot.loaded) return emptyList()
        val outcomeDays = snapshot.outcomeByKey[outcome.key] ?: emptyMap()
        return EffectRanker.rank(snapshot.behaviours, outcomeDays, outcome.outcomeName)
    }
}

// MARK: - Copy helpers

private fun forecastSentence(card: DoseCardData, previewDose: Int, delta: Double, stepLabel: String): String {
    if (previewDose <= 1) {
        return "No extra tonight — your ${card.outcomeName.lowercase(Locale.US)} forecast stays where it is."
    }
    val mag = abs(delta).roundToInt()
    val dir = if (delta <= 0) "lower" else "higher"
    val basis = if (card.response.priorDominated) {
        "based on typical patterns"
    } else {
        "based on ${card.response.nUser} of your ${card.unitLabel.lowercase(Locale.US)} days"
    }
    return "A $stepLabel tonight tends to line up with about $mag${card.outcomeSuffix} $dir on " +
        "tomorrow’s ${card.outcomeName.lowercase(Locale.US)} for you — $basis."
}

private fun curveDescription(card: DoseCardData, r: DoseResponse): String =
    "Dose-response curve. Each extra ${card.unitNoun} lines up with about " +
        "${signed(r.perUnit, card.outcomeSuffix)} on ${card.outcomeName}, " +
        if (r.priorDominated) "typical patterns." else "your own data."

private fun signed(v: Double, suffix: String): String {
    val mag = abs(v)
    val rounded = (mag * 10).roundToInt() / 10.0
    val sign = if (v < 0) "−" else if (v > 0) "+" else ""
    val body = if (rounded == rounded.toLong().toDouble()) "${rounded.toLong()}" else String.format(Locale.US, "%.1f", rounded)
    return "$sign$body$suffix"
}

private fun effectMagnitudeWord(d: Double): String = when {
    abs(d) < 0.2 -> "negligible"
    abs(d) < 0.5 -> "small"
    abs(d) < 0.8 -> "moderate"
    else -> "large"
}
