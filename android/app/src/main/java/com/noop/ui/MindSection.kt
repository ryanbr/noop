package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.data.DailyMetric
import com.noop.data.MoodStore
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.abs
import kotlin.math.sqrt

// MARK: - Mind (mood check-in + mood ↔ body correlations)
//
// Kotlin mirror of the Swift Mind lane. One 5-face check-in per local day, stored via
// MoodStore under the shared cross-platform contract (source id "noop-mood", key "mood",
// value 1.0–5.0, overwrite on edit). Once ≥7 days are checked in, up to three Pearson
// correlation lines appear — mood vs HRV / recovery / sleep duration — computed over the
// cached DailyMetric rows with the same CorrelationEngine math as the Compare screen
// (the StrandAnalytics/CorrelationEngine.swift port). Deliberately NEUTRAL palette:
// mood is self-knowledge, not a score, so nothing here is tinted good/bad.

/** One face on the check-in scale. `value` is the stored 1.0–5.0 contract value. */
private data class MoodFace(val emoji: String, val value: Double, val word: String)

private val MOOD_FACES = listOf(
    MoodFace("😞", 1.0, "Awful"),   // 😞
    MoodFace("😕", 2.0, "Low"),     // 😕
    MoodFace("😐", 3.0, "Okay"),    // 😐
    MoodFace("🙂", 4.0, "Good"),    // 🙂
    MoodFace("😄", 5.0, "Great"),   // 😄
)

/** Check-ins needed before the correlation lines unlock (mirrors the Swift gate). */
private const val MIND_GATE_DAYS = 7

/** Shared verbatim footnote — IDENTICAL string on macOS/iOS; do not reword. */
private const val MIND_FOOTNOTE =
    "Self-tracking, not a clinical assessment. If low mood persists, talk to a " +
        "professional. You deserve support."

// MARK: - Section

/**
 * Mind — the daily mood check-in card plus the gated mood ↔ body correlations.
 * Hosted on the Insights screen between the journal logging card and the
 * behaviour-effects half.
 */
@Composable
fun MindSection(vm: AppViewModel) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val store = remember { MoodStore(vm.repo) }

    var moodSeries by remember { mutableStateOf<List<Pair<String, Double>>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    var moodSeq by remember { mutableStateOf(0) }
    var editing by remember { mutableStateOf(false) }

    val todayKey = remember { MoodStore.todayKey() }
    LaunchedEffect(moodSeq) {
        moodSeries = store.moodSeries()
        loaded = true
    }
    val todayMood = moodSeries.lastOrNull { it.first == todayKey }?.second

    // One row per day by the storage PK, so size == distinct check-in days.
    val checkInDays = moodSeries.size
    val lines = remember(days, moodSeries) {
        if (moodSeries.size >= MIND_GATE_DAYS) buildMindCorrelations(days, moodSeries)
        else emptyList()
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Mind", overline = "Mood check-in")

        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                if (!loaded) {
                    Text(
                        uiString(R.string.l10n_mind_section_reading_your_check_ins_71a100a9),
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                } else if (todayMood == null || editing) {
                    // --- Open check-in: the 5-face scale -----------------------
                    Text(
                        uiString(R.string.l10n_mind_section_how_are_you_feeling_today_5667deff),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        MOOD_FACES.forEach { face ->
                            MoodFaceButton(
                                face = face,
                                selected = todayMood == face.value,
                                onClick = {
                                    editing = false
                                    scope.launch {
                                        store.setMood(todayKey, face.value)
                                        moodSeq++
                                    }
                                },
                            )
                        }
                    }
                    Text(
                        uiString(R.string.l10n_mind_section_one_check_in_per_day_picking_b103f22e),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                } else {
                    // --- Collapsed: today's face + Edit ------------------------
                    val face = MOOD_FACES.minByOrNull { abs(it.value - todayMood) } ?: MOOD_FACES[2]
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(face.emoji, style = NoopType.number(26f))
                        Spacer(Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(face.word, style = NoopType.headline, color = Palette.textPrimary)
                            Text(uiString(R.string.l10n_mind_section_logged_today_0071a46c), style = NoopType.caption, color = Palette.textTertiary)
                        }
                        MoodChip("Edit") { editing = true }
                    }
                }

                // --- Mood ↔ body correlations (≥7-day gate) --------------------
                if (loaded) {
                    HorizontalDivider(color = Palette.hairline)
                    if (checkInDays < MIND_GATE_DAYS) {
                        val left = MIND_GATE_DAYS - checkInDays
                        Text(
                            uiString(R.string.l10n_mind_section_mood_correlations_unlock_after_mind_gate_f0c62abe, MIND_GATE_DAYS) +
                                "check-ins: $left more ${if (left == 1) "day" else "days"} to go.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    } else if (lines.isEmpty()) {
                        Text(
                            uiString(R.string.l10n_mind_section_not_enough_overlapping_history_to_correlate_d36b91f9) +
                                " body metrics yet.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    } else {
                        lines.forEachIndexed { idx, line ->
                            MindCorrelationRow(line)
                            if (idx < lines.size - 1) HorizontalDivider(color = Palette.hairline)
                        }
                    }
                }
            }
        }

        Text(MIND_FOOTNOTE, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

// MARK: - Pieces

/** One tappable face. Neutral styling: an inset pill whose border firms up when selected —
 *  no good/bad tinting anywhere on the scale. */
@Composable
private fun MoodFaceButton(face: MoodFace, selected: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    val desc = "${face.word}, mood ${face.value.toInt()} of 5"
    Box(
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, if (selected) Palette.hairlineStrong else Palette.hairline, shape)
            .clickable(onClick = onClick)
            .semantics { contentDescription = desc },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            face.emoji,
            style = NoopType.number(22f),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
        )
    }
}

/** Neutral text chip (the collapsed card's Edit affordance). */
@Composable
private fun MoodChip(label: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Text(
        label,
        style = NoopType.caption,
        color = Palette.textSecondary,
        modifier = Modifier
            .clip(shape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

/** One correlation line: title + r on the first line, a plain-English reading under it.
 *  Neutral colours — r is information here, not a verdict. */
@Composable
private fun MindCorrelationRow(line: MindLine) {
    val dir = if (line.r > 0) "positive" else if (line.r < 0) "negative" else "flat"
    val sentence = "${mindStrengthWord(line.r)} $dir relationship (n = ${line.n})."
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp)
            .semantics { contentDescription = uiString(R.string.l10n_mind_section_line_title_sentence_6d3418f9, line.title, sentence) },
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                line.title,
                style = NoopType.subhead,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(
                String.format(Locale.US, "r = %+.2f", line.r),
                style = NoopType.captionNumber,
                color = Palette.textSecondary,
            )
        }
        Text(sentence, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

// MARK: - Correlation math

/** A computed mood ↔ outcome line. */
private data class MindLine(val title: String, val r: Double, val n: Int)

/**
 * Up to three mood ↔ body lines over the cached daily metrics: HRV, recovery and
 * total sleep. A line only appears when Pearson r is computable over the day-aligned
 * pairs (≥3 overlapping days with variance) — no fabricated values.
 */
private fun buildMindCorrelations(
    days: List<DailyMetric>,
    mood: List<Pair<String, Double>>,
): List<MindLine> {
    fun line(title: String, series: List<Pair<String, Double>>): MindLine? {
        val c = MindCorrelationEngine.pearson(MindCorrelationEngine.alignByDay(mood, series))
            ?: return null
        return MindLine(title, c.r, c.n)
    }
    return listOfNotNull(
        line("Mood ↔ HRV", days.mapNotNull { d -> d.avgHrv?.let { d.day to it } }),
        line("Mood ↔ Recovery", days.mapNotNull { d -> d.recovery?.let { d.day to it } }),
        line("Mood ↔ Sleep duration", days.mapNotNull { d -> d.totalSleepMin?.let { d.day to it } }),
    )
}

private fun mindStrengthWord(r: Double): String {
    val m = abs(r)
    return when {
        m < 0.1 -> "No"
        m < 0.3 -> "A weak"
        m < 0.5 -> "A moderate"
        m < 0.7 -> "A strong"
        else -> "A very strong"
    }
}

private data class MindCorrelation(val r: Double, val n: Int)

/** Same math as the Compare screen's engine — both are value-for-value ports of
 *  StrandAnalytics/CorrelationEngine.swift (kept private per file; there is no shared
 *  com.noop.analytics CorrelationEngine to import yet). */
private object MindCorrelationEngine {
    /** Inner-join two day-keyed series on the day key → (x, y) pairs sorted by day. */
    fun alignByDay(
        a: List<Pair<String, Double>>,
        b: List<Pair<String, Double>>,
    ): List<Pair<Double, Double>> {
        val mapA = HashMap<String, Double>()
        for ((day, v) in a) mapA[day] = v
        val mapB = HashMap<String, Double>()
        for ((day, v) in b) mapB[day] = v
        val common = mapA.keys.filter { mapB.containsKey(it) }.sorted()
        return common.map { mapA[it]!! to mapB[it]!! }
    }

    /** Pearson r over the pairs. Null when <3 pairs or either variable has zero variance. */
    fun pearson(xy: List<Pair<Double, Double>>): MindCorrelation? {
        val n = xy.size
        if (n < 3) return null
        val nD = n.toDouble()
        var sumX = 0.0
        var sumY = 0.0
        for (p in xy) { sumX += p.first; sumY += p.second }
        val meanX = sumX / nD
        val meanY = sumY / nD
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for (p in xy) {
            val dx = p.first - meanX
            val dy = p.second - meanY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        if (sxx <= 0.0 || syy <= 0.0) return null
        var r = sxy / (sqrt(sxx) * sqrt(syy))
        if (r > 1.0) r = 1.0
        if (r < -1.0) r = -1.0
        return MindCorrelation(r = r, n = n)
    }
}
