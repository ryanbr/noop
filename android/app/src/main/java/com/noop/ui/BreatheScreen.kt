package com.noop.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.BreathPacer
import com.noop.analytics.Hrv
import com.noop.analytics.ResonanceEngine
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Pace presets (ported from BreathingView.Pace)

private enum class Pace(val label: String) {
    Relax("Relax 4-6"),
    Coherence("Coherence 5.5"),
    Box("Box 4-4"),
    Resonance("Resonance");   // the user's locked pace (br/min) — only offered once a pace is locked

    /** Inhale seconds — for [Resonance] it derives from the locked bpm at a 40:60 inhale:exhale split
     *  (mirrors macOS Pace.inhale(lockedBpm:)). */
    fun inhale(lockedBpm: Double? = null): Double = when (this) {
        Relax -> 4.0
        Coherence -> 5.5
        Box -> 4.0
        Resonance -> {
            val cycle = 60.0 / (lockedBpm ?: ResonanceEngine.FALLBACK_BPM)
            cycle * BreathPacer.DEFAULT_INHALE_FRACTION
        }
    }

    fun exhale(lockedBpm: Double? = null): Double = when (this) {
        Relax -> 6.0
        Coherence -> 5.5
        Box -> 4.0
        Resonance -> {
            val cycle = 60.0 / (lockedBpm ?: ResonanceEngine.FALLBACK_BPM)
            cycle * (1 - BreathPacer.DEFAULT_INHALE_FRACTION)
        }
    }

    fun cycle(lockedBpm: Double? = null): Double = inhale(lockedBpm) + exhale(lockedBpm)
    fun bpm(lockedBpm: Double? = null): Double = 60.0 / cycle(lockedBpm)

    fun tagline(lockedBpm: Double? = null): String = when (this) {
        Relax -> "Long exhale · downshift to rest"
        Coherence -> "Equal breath · ~5.5 br/min coherence"
        Box -> "Square breath · steady focus"
        Resonance -> String.format(Locale.US, "Your locked pace · %.1f br/min", lockedBpm ?: ResonanceEngine.FALLBACK_BPM)
    }
}

private enum class Phase { Inhale, Exhale }

/** The three biofeedback layers as a mode switch (mirrors BreathingView.Mode). */
private enum class BreatheMode(val label: String) {
    Breathe("Breathe"),
    Resonance("Resonance"),
    Calm("Calm me"),
}

/**
 * Breathe — HRV haptic breathing biofeedback. The strap both measures HRV (R-R
 * intervals) and buzzes (haptic motor), so we pace the breath with a felt cue and
 * watch HRV respond live. One pulse on the inhale, two on the exhale. Live HR + a
 * rolling RMSSD show the autonomic response building. Ports BreathingView.swift.
 */
@Composable
fun BreatheScreen(viewModel: AppViewModel) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    val bpm by viewModel.bpm.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var mode by remember { mutableStateOf(BreatheMode.Breathe) }
    // The user's locked resonance pace (br/min), or null — read fresh; the sweep writes it.
    var lockedBpm by remember { mutableStateOf(BiofeedbackPrefs.lockedPace(context)) }

    var pace by remember { mutableStateOf(Pace.Coherence) }
    var running by remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf(Phase.Inhale) }
    var sessionSeconds by remember { mutableIntStateOf(0) }
    var breathCount by remember { mutableIntStateOf(0) }

    // Rolling R-R buffer + RMSSD (computed by the shared analytics Hrv).
    val rrBuffer = remember { mutableStateOf<List<Int>>(emptyList()) }
    var rmssd by remember { mutableStateOf<Double?>(null) }
    val rrWindow = 30

    // Pre/post outcome capture: the baseline locks at start (or to the first rolling
    // value inside the session's first ~60s); mean/peak stream while running. The last
    // completed outcome persists via NoopPrefs (display-only — no Room table).
    var baselineRmssd by remember { mutableStateOf<Double?>(null) }
    var sessionRmssdSum by remember { mutableDoubleStateOf(0.0) }
    var sessionRmssdCount by remember { mutableIntStateOf(0) }
    var sessionRmssdPeak by remember { mutableDoubleStateOf(0.0) }
    var endedOutcome by remember { mutableStateOf<String?>(null) }
    // SharedPreferences isn't reactive: read once, mirror writes into this state.
    var lastStoredOutcome by remember {
        mutableStateOf(NoopPrefs.of(context).getString(KEY_BREATHE_LAST_OUTCOME, "").orEmpty())
    }

    // Bank the just-ended session's outcome (mirrors BreathingView.captureOutcome):
    // null below the 2-minute floor; "—" stays display-only, never persisted.
    fun endSession() {
        val core = breatheOutcomeCore(
            baseline = baselineRmssd,
            sum = sessionRmssdSum,
            count = sessionRmssdCount,
            peak = sessionRmssdPeak,
            seconds = sessionSeconds,
        )
        endedOutcome = core
        if (core != null && core != "—") {
            lastStoredOutcome = core
            NoopPrefs.of(context).edit().putString(KEY_BREATHE_LAST_OUTCOME, core).apply()
        }
    }

    // Orb expansion 0..1; driven by an eased animation per breath phase.
    val orbTarget = if (running && phase == Phase.Inhale) 1f else 0f
    val phaseDurationMs = ((if (phase == Phase.Inhale) pace.inhale(lockedBpm) else pace.exhale(lockedBpm)) * 1000).toInt()
    val orbProgress by animateFloatAsState(
        targetValue = orbTarget,
        animationSpec = tween(if (running) phaseDurationMs else 800, easing = Motion.easeInOut),
        label = "orb",
    )

    // Ingest new R-R intervals into the rolling buffer and recompute RMSSD.
    // Collect the BLE state flow directly so updates are observed reactively.
    LaunchedEffect(Unit) {
        viewModel.live
            .map { it.rr }
            .distinctUntilChanged()
            .collect { rr ->
                if (rr.isEmpty()) return@collect
                val merged = (rrBuffer.value + rr).takeLast(rrWindow)
                rrBuffer.value = merged
                val r = if (merged.size >= 2) Hrv.rmssd(merged) else null
                rmssd = r
                // Outcome capture: while running, lock the baseline (first value
                // inside ~60s when none was available at start) and stream the
                // session mean/peak.
                if (running && r != null) {
                    if (baselineRmssd == null && sessionSeconds <= 60) baselineRmssd = r
                    sessionRmssdSum += r
                    sessionRmssdCount += 1
                    if (r > sessionRmssdPeak) sessionRmssdPeak = r
                }
            }
    }

    // Session clock — ticks only while running.
    LaunchedEffect(running) {
        if (!running) return@LaunchedEffect
        while (true) {
            delay(1000)
            sessionSeconds += 1
        }
    }

    // The breath engine: alternate phases, firing the haptic cue at the START of
    // each phase (1 pulse on inhale, 2 on exhale) — mirrors BreathingView.armPhase.
    LaunchedEffect(running, pace) {
        if (!running) return@LaunchedEffect
        while (true) {
            // Inhale: cue, then hold for the inhale duration.
            phase = Phase.Inhale
            viewModel.buzz(loops = 1)
            delay((pace.inhale(lockedBpm) * 1000).toLong())
            // Exhale: cue, then hold for the exhale duration.
            phase = Phase.Exhale
            viewModel.buzz(loops = 2)
            delay((pace.exhale(lockedBpm) * 1000).toLong())
            breathCount += 1
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            // Leaving mid-session still banks the outcome (mirrors macOS onDisappear → stop()).
            if (running) endSession()
            running = false
        }
    }

    ScreenScaffold(
        title = "Breathe",
        subtitle = "Haptic-paced breathing · find your pace · calm down",
    ) {
        // Mode switch — Breathe / Resonance / Calm me.
        SegmentedPillControl(
            items = BreatheMode.entries.toList(),
            selection = mode,
            label = { it.label },
            onSelect = {
                if (running) { running = false; endSession() }
                mode = it
                lockedBpm = BiofeedbackPrefs.lockedPace(context)
            },
        )

        // L3 passive stress check-in card (surfaces when StressOnsetDetector fires).
        StressCheckInCard(
            onBreatheNow = {
                // Switch to Breathe and start a one-minute session. Coherence (5.5 br/min) is the
                // resonance fallback pace; the felt cue is identical (one buzz in, two out).
                mode = BreatheMode.Breathe
                pace = Pace.Coherence
                sessionSeconds = 0; breathCount = 0; endedOutcome = null
                baselineRmssd = rmssd
                sessionRmssdSum = 0.0; sessionRmssdCount = 0; sessionRmssdPeak = 0.0
                running = true
            },
        )

        when (mode) {
            BreatheMode.Resonance -> {
                ResonanceMode(viewModel = viewModel, live = live, lockedBpm = lockedBpm,
                    onLocked = { lockedBpm = BiofeedbackPrefs.lockedPace(context) })
                return@ScreenScaffold
            }
            BreatheMode.Calm -> {
                CalmMode(viewModel = viewModel, live = live, bpm = bpm)
                return@ScreenScaffold
            }
            BreatheMode.Breathe -> Unit // fall through to the shipped trainer below
        }

        // Status row.
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            StatePill(
                if (running) "Session live" else "Ready",
                tone = if (running) StrandTone.Accent else StrandTone.Neutral,
                pulsing = running,
            )
            Spacer(Modifier.width(8.dp))
            if (live.bonded) {
                StatePill("Haptics on", tone = StrandTone.Positive)
            } else {
                StatePill("Visual only", tone = StrandTone.Warning)
            }
            Spacer(Modifier.weight(1f))
            Text(timeString(sessionSeconds), style = NoopType.number(15f), color = Palette.textPrimary)
            Spacer(Modifier.width(6.dp))
            Text("$breathCount breaths", style = NoopType.captionNumber, color = Palette.textSecondary)
        }

        // The orb card.
        NoopCard(padding = 24.dp, tint = Palette.restColor) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Overline(pace.label)
                    Spacer(Modifier.weight(1f))
                    Text(
                        String.format(Locale.US, "%.1f br/min", pace.bpm(lockedBpm)),
                        style = NoopType.captionNumber, color = Palette.textSecondary,
                    )
                }

                // The breathing orb is the immersive hero: it floats over a calm Rest-world
                // starfield, the scenic bloom deepening as the orb expands so the field breathes.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(300.dp)
                        .clip(RoundedCornerShape(Metrics.cardRadius)),
                    contentAlignment = Alignment.Center,
                ) {
                    ScenicHeroBackground(
                        modifier = Modifier.matchParentSize(),
                        domain = DomainTheme.Rest,
                        starCount = 56,
                    )
                    BreathingOrb(progress = orbProgress, bpm = bpm, modifier = Modifier.height(280.dp))
                }

                Text(
                    text = if (running) phaseWord(phase) else pace.tagline(lockedBpm),
                    style = NoopType.subhead,
                    color = if (running) Palette.restBright else Palette.textSecondary,
                )

                // The locked-resonance pill only appears once a pace has been locked (mirrors macOS
                // availablePaces) so a locked pace is selectable here.
                val availablePaces = if (lockedBpm != null) {
                    listOf(Pace.Relax, Pace.Coherence, Pace.Box, Pace.Resonance)
                } else {
                    listOf(Pace.Relax, Pace.Coherence, Pace.Box)
                }
                SegmentedPillControl(
                    items = availablePaces,
                    selection = pace,
                    label = { it.label },
                    onSelect = { pace = it },
                )
            }
        }

        // Controls.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            Button(
                onClick = {
                    if (running) {
                        running = false
                        endSession()
                    } else {
                        sessionSeconds = 0
                        breathCount = 0
                        endedOutcome = null
                        // Baseline: prefer the pre-session rolling value; otherwise the
                        // R-R collector locks the first value inside the first ~60s.
                        baselineRmssd = rmssd
                        sessionRmssdSum = 0.0
                        sessionRmssdCount = 0
                        sessionRmssdPeak = 0.0
                        running = true
                    }
                },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (running) Palette.statusCritical else Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                Icon(
                    if (running) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                    contentDescription = null,
                    modifier = Modifier.padding(end = 6.dp),
                )
                Text(if (running) "Stop session" else "Start session", style = NoopType.headline)
            }

            OutlinedButton(
                onClick = { viewModel.buzz(loops = 1) },
                enabled = live.bonded,
                colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
            ) {
                Icon(Icons.Filled.GraphicEq, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                Text("Test buzz", style = NoopType.body)
            }
        }

        // Calm one-line outcome — fresh after a finished session, persisted on re-entry.
        // Hidden while running and when there is nothing honest to show.
        val outcomeLine = when {
            running -> null
            endedOutcome == "—" -> "RMSSD — · not enough R-R data"
            endedOutcome != null -> "RMSSD $endedOutcome"
            lastStoredOutcome.isNotEmpty() -> "Last session: $lastStoredOutcome"
            else -> null
        }
        if (outcomeLine != null) {
            // The session's HRV outcome as a frosted Rest-tinted card with a TrendChip for the
            // vs-start RMSSD change. Presentation-only — the same outcome String + chip source.
            val chipSource = endedOutcome ?: lastStoredOutcome.takeIf { it.isNotEmpty() }
            val trend = chipSource?.takeIf { it != "—" }?.let { leadingSignedPercent(it) }
            NoopCard(padding = 14.dp, tint = Palette.restColor) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Filled.Air,
                        contentDescription = null,
                        tint = Palette.restBright,
                        modifier = Modifier.size(16.dp).padding(end = 8.dp),
                    )
                    Text(
                        outcomeLine,
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    if (trend != null) {
                        val sign = if (trend >= 0) "+" else "−"
                        TrendChip(
                            text = "$sign${kotlin.math.abs(trend)}% HRV",
                            color = if (trend >= 0) Palette.statusPositive else Palette.textTertiary,
                        )
                    }
                }
            }
        }

        // Readout tiles.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = "Heart rate",
                value = bpm?.toString() ?: "—",
                unit = "bpm",
                accent = Palette.metricRose,
                caption = if (live.worn) "Live" else "Strap not worn",
            )
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = "HRV (RMSSD)",
                value = rmssd?.let { String.format(Locale.US, "%.0f", it) } ?: "—",
                unit = "ms",
                accent = Palette.metricPurple,
                caption = if (rrBuffer.value.isEmpty()) "Waiting for R-R" else "Last ${rrBuffer.value.size} beats",
            )
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = "Pace",
                value = String.format(Locale.US, "%.1f", pace.bpm(lockedBpm)),
                unit = "br/min",
                accent = Palette.restBright,
                caption = String.format(Locale.US, "%.0f / %.0fs", pace.inhale(lockedBpm), pace.exhale(lockedBpm)),
            )
        }

        // Coherence estimate.
        CoherenceCard(rmssd)

        if (!live.bonded) HapticHint()
    }
}

// MARK: - Breathing orb

@Composable
private fun BreathingOrb(progress: Float, bpm: Int?, modifier: Modifier = Modifier) {
    val minScale = 0.42f
    val scale = minScale + (1f - minScale) * progress
    Box(
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(1f),
        contentAlignment = Alignment.Center,
    ) {
        // Static guide ring at the inhale extent.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(CircleShape)
                .border(1.dp, Palette.restColor.copy(alpha = 0.28f), CircleShape),
        )
        // Outer halo — a Rest-world bloom that brightens as the orb expands.
        Box(
            modifier = Modifier
                .fillMaxWidth(scale * 1.35f)
                .aspectRatio(1f)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(Palette.restBright.copy(alpha = 0.30f), Color.Transparent),
                    ),
                ),
        )
        // Orb body — soft indigo→periwinkle Rest gradient.
        Box(
            modifier = Modifier
                .fillMaxWidth(scale)
                .aspectRatio(1f)
                .clip(CircleShape)
                .background(
                    Brush.radialGradient(
                        colors = listOf(
                            Palette.restBright.copy(alpha = 0.90f),
                            Palette.restColor.copy(alpha = 0.62f),
                            Palette.restDeep.copy(alpha = 0.85f),
                        ),
                    ),
                )
                .border(1.dp, Palette.restBright.copy(alpha = 0.50f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(bpm?.toString() ?: "—", style = NoopType.number(40f), color = Palette.textPrimary)
                Text("BPM", style = NoopType.footnote.copy(letterSpacing = 0.8.sp), color = Palette.textTertiary)
            }
        }
    }
}

// MARK: - Readout tile

@Composable
private fun ReadoutTile(
    label: String,
    value: String,
    unit: String,
    accent: Color,
    caption: String,
    modifier: Modifier = Modifier,
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = 14.dp) {
        Column {
            Overline(label)
            Spacer(Modifier.weight(1f))
            Row(verticalAlignment = Alignment.Bottom) {
                Text(value, style = NoopType.number(26f), color = accent, maxLines = 1)
                Spacer(Modifier.width(4.dp))
                Text(unit, style = NoopType.caption, color = Palette.textTertiary)
            }
            Text(
                caption, style = NoopType.footnote, color = Palette.textTertiary,
                maxLines = 1, modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

// MARK: - Coherence card

@Composable
private fun CoherenceCard(rmssd: Double?) {
    val frac = (rmssd?.let { (it / 120.0).coerceIn(0.0, 1.0) } ?: 0.0).toFloat()
    val (label, tone) = coherenceState(rmssd)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Overline("Coherence estimate")
                Spacer(Modifier.weight(1f))
                StatePill(label, tone = tone)
            }
            // Normalized bar — RMSSD 0..120ms → 0..1.
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(10.dp)
                    .clip(RoundedCornerShape(50))
                    .background(Palette.surfaceInset),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(frac.coerceAtLeast(0.02f))
                        .height(10.dp)
                        .clip(RoundedCornerShape(50))
                        .background(
                            Brush.horizontalGradient(
                                listOf(Palette.restDeep, Palette.restBright),
                            ),
                        ),
                )
            }
            Text(
                "Estimate only — a higher RMSSD while paced usually means your parasympathetic \"rest\" branch is engaging. It is not a clinical reading; trends over a session matter more than any single number.",
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

private fun coherenceState(rmssd: Double?): Pair<String, StrandTone> = when {
    rmssd == null -> "No data" to StrandTone.Neutral
    rmssd < 20 -> "Building" to StrandTone.Warning
    rmssd < 45 -> "Settling" to StrandTone.Neutral
    rmssd < 80 -> "Coherent" to StrandTone.Positive
    else -> "Deep calm" to StrandTone.Positive
}

// MARK: - Session outcome

/** NoopPrefs key for the last completed session's outcome core (mirrors macOS
 *  `@AppStorage("breathe.lastOutcome")`). Display-only persistence — no Room table. */
private const val KEY_BREATHE_LAST_OUTCOME = "breathe.lastOutcome"

/**
 * End-of-session outcome core: "+18% vs start · peak 64 ms" — the session MEAN
 * rolling RMSSD vs the start baseline. Null below the 2-minute floor (abandoned —
 * show nothing); "—" when the session ran long enough but there was no usable
 * baseline or no R-R data (never invent a number). Mirrors
 * BreathingView.captureOutcome case-for-case.
 */
internal fun breatheOutcomeCore(
    baseline: Double?,
    sum: Double,
    count: Int,
    peak: Double,
    seconds: Int,
): String? {
    if (seconds < 120) return null
    if (baseline == null || baseline <= 0 || count == 0) return "—"
    val mean = sum / count
    val pct = ((mean - baseline) / baseline * 100).roundToInt()
    return String.format(Locale.US, "%+d%% vs start · peak %.0f ms", pct, peak)
}

/**
 * Parse a leading "+18%"/"-7%" from an outcome core, returning the integer percent — the signed
 * RMSSD-vs-start change shown as a TrendChip. Null when no signed % leads (abandoned / "—" line).
 * Display-only: it reads the same String the outcome line already shows, never new data.
 */
internal fun leadingSignedPercent(s: String): Int? {
    val pct = s.indexOf('%')
    if (pct <= 0) return null
    return s.substring(0, pct).replace("+", "").trim().toIntOrNull()
}

// MARK: - Haptic hint

@Composable
private fun HapticHint() {
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.statusWarning.copy(alpha = 0.08f), shape)
            .border(1.dp, Palette.statusWarning.copy(alpha = 0.25f), shape)
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.GraphicEq, contentDescription = null, tint = Palette.statusWarning)
        Text(
            "Connect your strap for haptic guidance — you'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.",
            style = NoopType.footnote, color = Palette.textSecondary,
        )
    }
}

private fun phaseWord(phase: Phase): String = when (phase) {
    Phase.Inhale -> "Breathe in…"
    Phase.Exhale -> "Breathe out…"
}

private fun timeString(total: Int): String =
    String.format(Locale.US, "%02d:%02d", total / 60, total % 60)

// ════════════════════════════════════════════════════════════════════════════
// L3 — Passive stress check-in card
// ════════════════════════════════════════════════════════════════════════════

/**
 * The L3 closed-loop JITAI surface — Kotlin twin of StressCheckInCard.swift. Observes
 * [StressNudgeCenter.pending]; when the shipped [com.noop.analytics.StressOnsetDetector] fires (a fresh,
 * non-metabolic HRV dip while still), the central hook (Wave 3) calls [StressNudgeCenter.present] and this
 * dismissible card appears. NEVER an alarm, NEVER a push, NEVER a diagnosis — "HRV dipped while you were
 * still", with Breathe now / Not now / Turn off.
 */
@Composable
private fun StressCheckInCard(onBreatheNow: () -> Unit) {
    val context = LocalContext.current
    val nudge by StressNudgeCenter.pending.collectAsStateWithLifecycle()
    val n = nudge ?: return

    NoopCard(tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Air, contentDescription = null, tint = Palette.restBright,
                    modifier = Modifier.size(16.dp).padding(end = 8.dp))
                Overline("Stress check-in")
                Spacer(Modifier.weight(1f))
                StatePill("Passive", tone = StrandTone.Neutral)
            }
            Text(
                "Your HRV dipped while you were still — want a minute to breathe?",
                style = NoopType.subhead, color = Palette.textPrimary,
            )
            honestNudgeLine(n)?.let {
                Text(it, style = NoopType.footnote, color = Palette.textTertiary)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                Button(
                    onClick = { StressNudgeCenter.dismiss(); onBreatheNow() },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase),
                    modifier = Modifier.weight(1f),
                ) { Text("Breathe now", style = NoopType.headline) }
                OutlinedButton(
                    onClick = { StressNudgeCenter.dismiss() },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text("Not now", style = NoopType.body) }
                TextButton(onClick = {
                    BiofeedbackPrefs.setCheckInEnabled(context, false)
                    StressNudgeCenter.dismiss()
                }) { Text("Turn off", style = NoopType.body, color = Palette.textSecondary) }
            }
            Text(
                "Relaxation guidance from your own numbers — not a health alert, and not a diagnosis. Trends matter more than any single number.",
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

private fun honestNudgeLine(n: StressNudgeCenter.Nudge): String? {
    val fast = n.fastRMSSD ?: return null
    val base = n.baselineRMSSD ?: return null
    if (base <= 0.0) return null
    return String.format(Locale.US,
        "RMSSD %.0f ms now vs your ~%.0f ms baseline (estimate from PPG-derived R-R).", fast, base)
}

// ════════════════════════════════════════════════════════════════════════════
// L1 — Resonance mode (the "find my pace" sweep + result)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The L1 surface — Kotlin twin of ResonanceModeView. Explainer → full/quick sweep → live
 * "Testing 5.5 br/min…" + RSA progress → dated result card (locked pace + RSA-by-pace curve, or the
 * honest "couldn't lock today" fallback). Self-contained: the sweep is driven by a coroutine
 * [LaunchedEffect] walking [BreathPacer] cue lists and firing [AppViewModel.buzz], collecting clean R-R
 * per pace, then scoring with [ResonanceEngine.sweep].
 */
@Composable
private fun ResonanceMode(
    viewModel: AppViewModel,
    live: com.noop.ble.LiveState,
    lockedBpm: Double?,
    onLocked: () -> Unit,
) {
    val context = LocalContext.current
    var sweeping by remember { mutableStateOf(false) }
    var quick by remember { mutableStateOf(false) }
    var sweepLabel by remember { mutableStateOf<String?>(null) }
    var sweepProgress by remember { mutableDoubleStateOf(0.0) }
    var result by remember { mutableStateOf<ResonanceEngine.SweepResult?>(null) }
    val secondsPerPace = 120

    // The sweep coroutine: pace each candidate, collect its clean R-R, score the whole thing.
    LaunchedEffect(sweeping, quick) {
        if (!sweeping) return@LaunchedEffect
        val paces = if (quick) ResonanceEngine.QUICK_SWEEP_PACES else ResonanceEngine.FULL_SWEEP_PACES
        val samples = ArrayList<ResonanceEngine.PaceSample>()
        for ((index, bpm) in paces.withIndex()) {
            sweepLabel = String.format(Locale.US, "Testing %.1f br/min…", bpm)
            val startTs = (System.currentTimeMillis() / 1000).toInt()
            val bucket = ArrayList<ResonanceEngine.RrBeat>()
            // Collect this pace's R-R while we pace it; fire the cue list (1 inhale / 2 exhale) on tempo.
            val cues = BreathPacer.schedule(bpm = bpm,
                cycles = maxOf(1, (secondsPerPace * bpm / 60.0).roundToInt()))
            var elapsedMs = 0
            for (cue in cues) {
                delay((cue.offsetMs - elapsedMs).toLong().coerceAtLeast(0))
                elapsedMs = cue.offsetMs
                // Read the LATEST live state off the flow (the captured `live` param is a snapshot that
                // only refreshes on recomposition; the standard profile is the reliable R-R source).
                val liveNow = viewModel.live.value
                if (liveNow.encryptedBond) viewModel.buzz(loops = cue.loops)
                val now = (System.currentTimeMillis() / 1000).toInt()
                for (ms in liveNow.rr) if (ms in 301..1999) bucket.add(ResonanceEngine.RrBeat(now, ms))
            }
            delay(4000) // let the last exhale finish before closing the window
            val endTs = (System.currentTimeMillis() / 1000).toInt()
            samples.add(ResonanceEngine.PaceSample(bpm, bucket, startTs, endTs))
            sweepProgress = (index + 1).toDouble() / paces.size
        }
        val swept = ResonanceEngine.sweep(samples)
        result = swept
        if (swept.didLock) {
            BiofeedbackPrefs.saveLockedPace(context, swept.lockedBpm, System.currentTimeMillis())
            onLocked()
        }
        sweepLabel = null
        sweepProgress = 0.0
        sweeping = false
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Explainer.
        NoopCard(tint = Palette.restColor) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Overline("Find your resonance pace")
                    Spacer(Modifier.weight(1f))
                    StatePill(if (live.bonded) "Haptics on" else "Visual only",
                        tone = if (live.bonded) StrandTone.Positive else StrandTone.Warning)
                }
                Text(
                    "Everyone has a breathing pace — usually between 4.5 and 7 breaths a minute — where the heart's rhythm swings the most with each breath. We pace you through a few candidate paces, measure how your HRV responds, and lock the one that resonates best for you.",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                Text(
                    "Estimate from PPG-derived R-R — relaxation guidance, not a clinical reading. Your pace drifts, so we date it and you can re-measure anytime.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
        }

        if (sweeping) {
            // Live sweep progress.
            NoopCard(tint = Palette.restColor) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(sweepLabel ?: "Sweeping…", style = NoopType.headline, color = Palette.textPrimary)
                        Spacer(Modifier.weight(1f))
                        StatePill("Live", tone = StrandTone.Accent, pulsing = true)
                    }
                    ProgressBar(sweepProgress.toFloat())
                    OutlinedButton(
                        onClick = { sweeping = false },
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.statusCritical),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text("Stop sweep", style = NoopType.body)
                    }
                }
            }
        } else {
            // Start controls.
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = { quick = false; result = null; sweeping = true },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent, contentColor = Palette.surfaceBase),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.GraphicEq, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text("Full sweep · ~13 min", style = NoopType.headline)
                    }
                    OutlinedButton(
                        onClick = { quick = true; result = null; sweeping = true },
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Bolt, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text("Quick sweep · ~7 min", style = NoopType.body)
                    }
                    Text(
                        "Sit still and breathe with the buzz. You can stop anytime; a stopped sweep won't lock a pace.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
            }
        }

        val shown = result
        if (shown != null) {
            ResonanceResultCard(shown, context)
        } else if (lockedBpm != null) {
            LockedPaceCard(lockedBpm, context)
        }

        if (!live.bonded) HapticHint()
    }
}

@Composable
private fun ResonanceResultCard(result: ResonanceEngine.SweepResult, context: android.content.Context) {
    NoopCard(tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Overline(if (result.didLock) "Your resonance pace" else "Couldn't lock today")
                Spacer(Modifier.weight(1f))
                StatePill(if (result.didLock) "Locked" else "Fallback",
                    tone = if (result.didLock) StrandTone.Positive else StrandTone.Neutral)
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text(String.format(Locale.US, "%.1f", result.lockedBpm),
                    style = NoopType.number(40f), color = Palette.restBright)
                Spacer(Modifier.width(6.dp))
                Text("br/min", style = NoopType.subhead, color = Palette.textTertiary,
                    modifier = Modifier.padding(bottom = 6.dp))
            }
            if (!result.didLock) {
                Text(
                    "Not enough clean beat data to lock a pace today — try again rested, sitting still with the strap snug. For now we'll pace you at 5.5 br/min (coherence).",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
            RsaCurve(result.scores)
            val dateMs = BiofeedbackPrefs.lockedPaceDateMs(context)
            if (result.didLock && dateMs > 0) {
                Text("Locked ${formatDay(dateMs)} · paces drift, re-measure anytime.",
                    style = NoopType.footnote, color = Palette.textTertiary)
            }
        }
    }
}

@Composable
private fun LockedPaceCard(bpm: Double, context: android.content.Context) {
    NoopCard(tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Overline("Your locked pace")
                Spacer(Modifier.weight(1f))
                StatePill("Locked", tone = StrandTone.Positive)
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text(String.format(Locale.US, "%.1f", bpm), style = NoopType.number(34f), color = Palette.restBright)
                Spacer(Modifier.width(6.dp))
                Text("br/min", style = NoopType.subhead, color = Palette.textTertiary,
                    modifier = Modifier.padding(bottom = 4.dp))
            }
            val dateMs = BiofeedbackPrefs.lockedPaceDateMs(context)
            if (dateMs > 0) {
                Text("Locked ${formatDay(dateMs)}. Switch to Breathe to use it, or re-measure above.",
                    style = NoopType.footnote, color = Palette.textTertiary)
            }
        }
    }
}

/** A compact RSA-amplitude-by-pace summary (the resonance curve). Unscored paces read "—". */
@Composable
private fun RsaCurve(scores: List<ResonanceEngine.PaceScore>) {
    val maxRsa = scores.mapNotNull { it.rsaAmplitude }.maxOrNull() ?: 1.0
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Overline("RSA response by pace")
        scores.forEach { s ->
            Row(verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(String.format(Locale.US, "%.1f", s.bpm), style = NoopType.captionNumber,
                    color = Palette.textSecondary, modifier = Modifier.width(34.dp))
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(8.dp)
                        .clip(RoundedCornerShape(50))
                        .background(Palette.surfaceInset),
                ) {
                    val frac = ((s.rsaAmplitude ?: 0.0) / maxOf(maxRsa, 0.0001)).toFloat()
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(frac.coerceIn(0.04f, 1f))
                            .height(8.dp)
                            .clip(RoundedCornerShape(50))
                            .background(Palette.restBright.copy(alpha = if (s.scored) 0.9f else 0.25f)),
                    )
                }
                Text(s.rsaAmplitude?.let { String.format(Locale.US, "%.1f", it) } ?: "—",
                    style = NoopType.captionNumber,
                    color = if (s.scored) Palette.textSecondary else Palette.textTertiary,
                    modifier = Modifier.width(34.dp), textAlign = TextAlign.End)
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// L2 — "Calm me" mode (below-HR relaxation metronome)
// ════════════════════════════════════════════════════════════════════════════

/**
 * The L2 surface — Kotlin twin of CalmModeView. A "Calm me · 3 min" button runs [HrDownPacer] (one light
 * pulse per target beat at a bounded Δ below live HR, recomputed each step so the cue trails the heart
 * down), a minimal live "HR 78 → settling" readout, a stop control, and an honest outcome (settled vs
 * held steady — no fabricated win). Haptic-first → disabled when the encrypted channel isn't up.
 */
@Composable
private fun CalmMode(viewModel: AppViewModel, live: com.noop.ble.LiveState, bpm: Int?) {
    var running by remember { mutableStateOf(false) }
    var startHr by remember { mutableStateOf<Int?>(null) }
    var targetBpm by remember { mutableStateOf<Double?>(null) }
    var elapsed by remember { mutableIntStateOf(0) }
    var outcome by remember { mutableStateOf<String?>(null) }
    var didNotFall by remember { mutableStateOf(false) }

    val canBuzz = live.bonded && live.encryptedBond
    val canRun = canBuzz && (bpm?.let { it in 55..120 } ?: false)

    // The metronome coroutine: ask HrDownPacer.next each step, fire a light pulse, schedule the next.
    // Reads the LATEST smoothed HR off the viewModel flow each step (StateFlow.value is always current),
    // so the cue trails the live heart rather than a snapshot — mirrors BiofeedbackController reading
    // model.bpm fresh each tick.
    LaunchedEffect(running) {
        if (!running) return@LaunchedEffect
        val config = com.noop.analytics.HrDownPacer.Config.DEFAULT
        elapsed = 0
        while (running) {
            val liveHr = viewModel.bpm.value
            val step = com.noop.analytics.HrDownPacer.next((liveHr ?: 0).toDouble(), elapsed.toDouble(), config)
            if (step.stop) {
                outcome = calmOutcomeLine(step.stopReason, startHr, liveHr, elapsed)
                didNotFall = calmDidNotFall(step.stopReason, startHr, liveHr)
                running = false
                break
            }
            targetBpm = step.targetBpm
            if (canBuzz) viewModel.buzz(loops = 1)
            val interval = step.intervalMs ?: 1000
            delay(interval.toLong())
            elapsed += interval / 1000
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Explainer.
        NoopCard(tint = Palette.restColor) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Overline("Calm me")
                    Spacer(Modifier.weight(1f))
                    StatePill(if (canRun) "Ready" else "Strap needed",
                        tone = if (canRun) StrandTone.Neutral else StrandTone.Warning)
                }
                Text(
                    "The strap buzzes a gentle rhythm just below your current heart rate — a felt metronome to relax toward. It trails your heart down rather than yanking it, and stops on its own.",
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                Text(
                    "A relaxation rhythm, not cardiac control. It never paces below a safe rate and you can stop anytime. If your heart rate doesn't settle, we'll say so plainly.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
        }

        if (running) {
            NoopCard(tint = Palette.restColor) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Overline("Settling")
                        Spacer(Modifier.weight(1f))
                        StatePill("Live", tone = StrandTone.Accent, pulsing = true)
                    }
                    Row(verticalAlignment = Alignment.Bottom,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(bpm?.toString() ?: "—", style = NoopType.number(48f), color = Palette.metricRose)
                        Icon(Icons.Filled.ArrowForward, contentDescription = null,
                            tint = Palette.textTertiary, modifier = Modifier.padding(bottom = 8.dp))
                        Column {
                            Text("target", style = NoopType.footnote, color = Palette.textTertiary)
                            Text(targetBpm?.let { String.format(Locale.US, "%.0f", it) } ?: "—",
                                style = NoopType.number(22f), color = Palette.restBright)
                        }
                    }
                    startHr?.let {
                        Text("Started at $it bpm · the rhythm trails your heart down.",
                            style = NoopType.footnote, color = Palette.textTertiary)
                    }
                    Button(
                        onClick = { running = false },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.statusCritical, contentColor = Palette.surfaceBase),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text("Stop", style = NoopType.headline)
                    }
                }
            }
        } else {
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = {
                            startHr = bpm; outcome = null; didNotFall = false; targetBpm = null
                            running = true
                        },
                        enabled = canRun,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent, contentColor = Palette.surfaceBase),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Favorite, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text("Calm me · 3 min", style = NoopType.headline)
                    }
                    when {
                        !canBuzz -> Text(
                            "Connect your strap — Calm me is a felt rhythm on the wrist, so it needs a bonded connection.",
                            style = NoopType.footnote, color = Palette.textTertiary)
                        !canRun -> Text(
                            "Waiting for a resting heart rate — start a live reading first, or come back when you're still.",
                            style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
            }
        }

        val o = outcome
        if (o != null && !running) {
            NoopCard(tint = Palette.restColor) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(
                            if (didNotFall) Icons.Filled.Remove else Icons.Filled.Check,
                            contentDescription = null,
                            tint = if (didNotFall) Palette.textTertiary else Palette.statusPositive,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(o, style = NoopType.subhead, color = Palette.textPrimary,
                            modifier = Modifier.weight(1f))
                    }
                    if (didNotFall) {
                        Text(
                            "That's normal — a paced breath often settles things when a metronome alone doesn't.",
                            style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Calm-me outcome helpers (mirror BiofeedbackController.finishCalm)

private fun calmOutcomeLine(
    reason: com.noop.analytics.HrDownPacer.StopReason?,
    startHr: Int?, endHr: Int?, elapsed: Int,
): String {
    val mmss = String.format(Locale.US, "%d:%02d", elapsed / 60, elapsed % 60)
    return when (reason) {
        com.noop.analytics.HrDownPacer.StopReason.SETTLED ->
            if (startHr != null && endHr != null) "HR settled $startHr → $endHr over $mmss."
            else "HR settled over $mmss."
        else ->
            if (startHr != null && endHr != null && endHr < startHr) "HR eased $startHr → $endHr over $mmss."
            else if (startHr != null && endHr != null)
                "HR held steady ($startHr → $endHr) — try a paced breath instead."
            else "Session ended — try a paced breath instead."
    }
}

private fun calmDidNotFall(
    reason: com.noop.analytics.HrDownPacer.StopReason?,
    startHr: Int?, endHr: Int?,
): Boolean {
    if (reason == com.noop.analytics.HrDownPacer.StopReason.SETTLED) return false
    if (startHr != null && endHr != null && endHr < startHr) return false
    return true
}

// MARK: - Small shared bits

@Composable
private fun ProgressBar(frac: Float) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(10.dp)
            .clip(RoundedCornerShape(50))
            .background(Palette.surfaceInset),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(frac.coerceIn(0.02f, 1f))
                .height(10.dp)
                .clip(RoundedCornerShape(50))
                .background(
                    Brush.horizontalGradient(listOf(Palette.restDeep, Palette.restBright)),
                ),
        )
    }
}

private fun formatDay(epochMs: Long): String =
    SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(epochMs))
