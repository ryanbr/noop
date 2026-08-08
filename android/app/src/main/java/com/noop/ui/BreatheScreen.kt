package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.sin
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

// MARK: - Liquid hero tokens (the liquid Breathe restyle)
//
// The frosted hero panel the breathe vessel floats on, matching the liquid Today heroCard. `heroFill` is a
// translucent near-black (mock rgba(13,14,20,.80)) so it floats over the day-of-sky and the vessel + white
// count-up read crisp on it; radius 26 + a white@0.11 hairline give the frosted-glass edge. Declared here
// (not shared from Today) because the Today copies are file-private — same values, kept in lockstep.
private val LIQUID_HERO_FILL: Color = Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val LIQUID_HERO_RADIUS = 26.dp

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

    // Opt-in audio pacer — a soft tone at each phase change (a brighter note on the inhale, a lower one
    // on the exhale). Default OFF (manual-first). The tone player honours the ringer mode, so a phone on
    // silent/vibrate stays quiet — the Android twin of the iOS ambient session that obeys the silent
    // switch. SharedPreferences isn't reactive: read once, mirror writes into this state.
    var audioCues by remember {
        mutableStateOf(NoopPrefs.of(context).getBoolean(KEY_BREATHE_AUDIO_CUES, false))
    }
    val tonePlayer = remember { BreathTonePlayer(context) }
    DisposableEffect(Unit) { onDispose { tonePlayer.release() } }
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
            viewModel.buzz(loops = 1, gate = HapticPrefs.BREATHING)
            if (audioCues) tonePlayer.play(BreathTone.Inhale)
            delay((pace.inhale(lockedBpm) * 1000).toLong())
            // Exhale: cue, then hold for the exhale duration.
            phase = Phase.Exhale
            viewModel.buzz(loops = 2, gate = HapticPrefs.BREATHING)
            if (audioCues) tonePlayer.play(BreathTone.Exhale)
            delay((pace.exhale(lockedBpm) * 1000).toLong())
            breathCount += 1
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            // Leaving mid-session still banks the outcome (mirrors macOS onDisappear → stop()).
            if (running) {
                endSession()
                // #769: also tell the strap to stop haptics on the way out so a leftover pattern can't
                // wedge the strap if the link drops after we navigate away. Best-effort (guarded send).
                viewModel.stopHaptics()
            }
            running = false
        }
    }

    // #769: if the strap drops WHILE a session is live, end the session AND fire the stop-haptics clear.
    // The breath-engine LaunchedEffect already stops scheduling pulses once `running` flips false; this
    // adds the strap-side clear (best-effort) and banks the outcome, mirroring the macOS
    // BiofeedbackController bond watch.
    LaunchedEffect(live.bonded) {
        if (!live.bonded && running) {
            running = false
            endSession()
            viewModel.stopHaptics()
        }
    }

    // Day-cycle sky + sky-behind-cards: the SAME two Appearance gates every other screen honours.
    // (This screen previously drew the sky unconditionally - it now matches Today/Trends/Sleep,
    // including turning OFF with the day-cycle setting.) Read once; SharedPreferences isn't reactive.
    val skyCtx = androidx.compose.ui.platform.LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(skyCtx) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(skyCtx) }
    ScreenScaffold(
        title = uiString(R.string.l10n_breathe_screen_breathe_282be568),
        subtitle = "Haptic-paced breathing · find your pace · calm down",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles
        // into the theme canvas behind the header + top card and bleeds full-width up behind the status bar
        // via the scaffold's topBackground plumbing. The Android equivalent of the iOS
        // `ScreenScaffold(topBackground: liquidScaffoldSky())`; the cards float OVER it on the flat canvas.
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
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
            Text(uiString(R.string.l10n_breathe_screen_breathcount_breaths_ce036831, breathCount), style = NoopType.captionNumber, color = Palette.textSecondary)
        }

        // The liquid hero CARD: a translucent near-black frosted panel (mock rgba(13,14,20,.80), radius 26,
        // white@0.11 hairline) that floats over the day-of-sky so the breathe vessel + white count-up stay
        // crisp — the card does the contrast work, not a muted sky. Mirrors the iOS liquid heroCard.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
                .background(LIQUID_HERO_FILL.copy(alpha = LIQUID_HERO_FILL.alpha * CardAppearance.opacity))
                .border(1.dp, Color.White.copy(alpha = 0.11f * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
                .padding(24.dp),
        ) {
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

                // The breathe pacer is now a liquid VESSEL: it FILLS on the inhale and EMPTIES on the exhale,
                // driven by the SAME eased `orbProgress` the orb used (0..1, from the phase-duration tween), so
                // the breath timing is untouched — the fluid just replaces the scaling orb. Only animates while
                // a session is live (posed/static otherwise, so the still hero costs nothing). The live BPM
                // counts up over it (white, tabular, soft shadow, hit-transparent so a tap falls to the vessel,
                // which owns its own splash+haptic). Rest-tinted (restBright), matching the iOS breathe hero.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(280.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    LiquidVessel(
                        value = orbProgress.toDouble(),
                        tint = Palette.restBright,
                        animated = running,
                        modifier = Modifier.height(280.dp),
                    )
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.clearAndSetSemantics {},
                    ) {
                        Text(
                            bpm?.toString() ?: "—",
                            style = NoopType.number(40f, weight = FontWeight.Bold)
                                .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                            color = Color.White,
                        )
                        Text("BPM", style = NoopType.footnote.copy(letterSpacing = 0.8.sp), color = Palette.textTertiary)
                    }
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

                // Opt-in audio pacer toggle — soft tone on each phase, honours the ringer mode.
                AudioCueToggle(
                    checked = audioCues,
                    onChange = {
                        audioCues = it
                        NoopPrefs.of(context).edit().putBoolean(KEY_BREATHE_AUDIO_CUES, it).apply()
                    },
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
                        // #769: clear any pattern the strap is mid-way through so a drop right after stop
                        // can't wedge its haptic manager. Best-effort (no-op when unbonded / on a 5/MG).
                        viewModel.stopHaptics()
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
                Text(uiString(R.string.l10n_breathe_screen_test_buzz_deeab5ae), style = NoopType.body)
            }
        }

        // Calm one-line outcome — fresh after a finished session, persisted on re-entry.
        // Hidden while running and when there is nothing honest to show.
        val outcomeLine = when {
            running -> null
            endedOutcome == "—" -> "RMSSD - · not enough R-R data"
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
                            text = uiString(R.string.l10n_breathe_screen_sign_kotlin_math_abs_trend_hrv_e9362899, sign, kotlin.math.abs(trend)),
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
                label = uiString(R.string.l10n_breathe_screen_heart_rate_410aa15c),
                value = bpm?.toString() ?: "—",
                unit = "bpm",
                accent = Palette.metricRose,
                caption = if (live.worn) "Live" else "Strap not worn",
            )
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = uiString(R.string.l10n_breathe_screen_hrv_rmssd_51014f87),
                value = rmssd?.let { String.format(Locale.US, "%.0f", it) } ?: "—",
                unit = "ms",
                accent = Palette.metricPurple,
                caption = if (rrBuffer.value.isEmpty()) "Waiting for R-R" else "Last ${rrBuffer.value.size} beats",
            )
            ReadoutTile(
                modifier = Modifier.weight(1f),
                label = uiString(R.string.l10n_breathe_screen_pace_7a9a6226),
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

// MARK: - Audio cue toggle

@Composable
private fun AudioCueToggle(checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Icon(
            if (checked) Icons.AutoMirrored.Filled.VolumeUp else Icons.AutoMirrored.Filled.VolumeOff,
            contentDescription = null,
            tint = if (checked) Palette.restBright else Palette.textTertiary,
            modifier = Modifier.size(16.dp).padding(end = 10.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(uiString(R.string.l10n_breathe_screen_audio_cues_74430aec), style = NoopType.footnote, color = Palette.textSecondary)
            Text(
                uiString(R.string.l10n_breathe_screen_soft_tone_on_each_phase_honours_2a02c284),
                style = NoopType.caption, color = Palette.textTertiary, maxLines = 1,
            )
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Palette.surfaceBase,
                checkedTrackColor = Palette.accent,
                uncheckedThumbColor = Palette.textSecondary,
                uncheckedTrackColor = Palette.surfaceInset,
                uncheckedBorderColor = Palette.hairline,
            ),
            modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_breathe_screen_audio_cues_74430aec) },
        )
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
            // Normalized bar — RMSSD 0..120ms → 0..1 — as a liquid tube (a genuine single-value fill).
            // Static (animated = false): it settles to the level, no per-frame clock, matching the pilot's
            // tube usage on non-live contributor bars.
            LiquidTube(
                frac = frac.toDouble(),
                tint = Palette.restBright,
                animated = false,
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                uiString(R.string.l10n_breathe_screen_estimate_only_a_higher_rmssd_while_bfd71bb8),
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
            uiString(R.string.l10n_breathe_screen_connect_your_strap_for_haptic_guidance_65660684),
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
                uiString(R.string.l10n_breathe_screen_your_hrv_dipped_while_you_were_231d3c7a),
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
                ) { Text(uiString(R.string.l10n_breathe_screen_breathe_now_98d6c341), style = NoopType.headline) }
                OutlinedButton(
                    onClick = { StressNudgeCenter.dismiss() },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.textSecondary),
                ) { Text(uiString(R.string.l10n_breathe_screen_not_now_e4571490), style = NoopType.body) }
                TextButton(onClick = {
                    BiofeedbackPrefs.setCheckInEnabled(context, false)
                    StressNudgeCenter.dismiss()
                }) { Text(uiString(R.string.l10n_breathe_screen_turn_off_8807c2b3), style = NoopType.body, color = Palette.textSecondary) }
            }
            Text(
                uiString(R.string.l10n_breathe_screen_relaxation_guidance_from_your_own_numbers_16ee0ba1),
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
                if (liveNow.encryptedBond) viewModel.buzz(loops = cue.loops, gate = HapticPrefs.BREATHING)
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
                    uiString(R.string.l10n_breathe_screen_everyone_has_a_breathing_pace_usually_ad6ea0b4),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                Text(
                    uiString(R.string.l10n_breathe_screen_estimate_from_ppg_derived_r_r_9c92fbae),
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
                        Text(uiString(R.string.l10n_breathe_screen_stop_sweep_55299cf9), style = NoopType.body)
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
                        Text(uiString(R.string.l10n_breathe_screen_full_sweep_13_min_08e01d2c), style = NoopType.headline)
                    }
                    OutlinedButton(
                        onClick = { quick = true; result = null; sweeping = true },
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Bolt, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text(uiString(R.string.l10n_breathe_screen_quick_sweep_7_min_5d58f88d), style = NoopType.body)
                    }
                    Text(
                        uiString(R.string.l10n_breathe_screen_sit_still_and_breathe_with_the_b7c53c40),
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
                    uiString(R.string.l10n_breathe_screen_not_enough_clean_beat_data_to_865a1260),
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
            RsaCurve(result.scores)
            val dateMs = BiofeedbackPrefs.lockedPaceDateMs(context)
            if (result.didLock && dateMs > 0) {
                Text(uiString(R.string.l10n_breathe_screen_locked_formatday_datems_paces_drift_re_8ebec15b, formatDay(dateMs)),
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
                Text(uiString(R.string.l10n_breathe_screen_locked_formatday_datems_switch_to_breathe_3efc52c6, formatDay(dateMs)),
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
            if (canBuzz) viewModel.buzz(loops = 1, gate = HapticPrefs.BREATHING)
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
                    uiString(R.string.l10n_breathe_screen_the_strap_buzzes_a_gentle_rhythm_eb5c6a65),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                Text(
                    uiString(R.string.l10n_breathe_screen_a_relaxation_rhythm_not_cardiac_control_5c2f10a8),
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
                        Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null,
                            tint = Palette.textTertiary, modifier = Modifier.padding(bottom = 8.dp))
                        Column {
                            Text("target", style = NoopType.footnote, color = Palette.textTertiary)
                            Text(targetBpm?.let { String.format(Locale.US, "%.0f", it) } ?: "—",
                                style = NoopType.number(22f), color = Palette.restBright)
                        }
                    }
                    startHr?.let {
                        Text(uiString(R.string.l10n_breathe_screen_started_at_it_bpm_the_rhythm_dda6a573, it),
                            style = NoopType.footnote, color = Palette.textTertiary)
                    }
                    Button(
                        onClick = { running = false },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.statusCritical, contentColor = Palette.surfaceBase),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                        Text(uiString(R.string.l10n_breathe_screen_stop_9e253470), style = NoopType.headline)
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
                        Text(uiString(R.string.l10n_breathe_screen_calm_me_3_min_11250c77), style = NoopType.headline)
                    }
                    when {
                        !canBuzz -> Text(
                            uiString(R.string.l10n_breathe_screen_connect_your_strap_calm_me_is_71314744),
                            style = NoopType.footnote, color = Palette.textTertiary)
                        !canRun -> Text(
                            uiString(R.string.l10n_breathe_screen_waiting_for_a_resting_heart_rate_980cedbf),
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
                            uiString(R.string.l10n_breathe_screen_that_s_normal_a_paced_breath_72e2d011),
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
                "HR held steady ($startHr → $endHr). Try a paced breath instead."
            else "Session ended. Try a paced breath instead."
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
    // The sweep progress as a liquid tube — a single-value fill. Static (animated = false): it settles to
    // the current sweep fraction with no per-frame clock, matching the pilot's tube usage.
    LiquidTube(
        frac = frac.toDouble(),
        tint = Palette.restBright,
        animated = false,
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun formatDay(epochMs: Long): String =
    SimpleDateFormat("d MMM", Locale.getDefault()).format(Date(epochMs))

// ════════════════════════════════════════════════════════════════════════════
// Audio pacer (opt-in soft phase tones)
// ════════════════════════════════════════════════════════════════════════════

/** SharedPreferences key for the opt-in audio pacer toggle (mirrors macOS `@AppStorage("breathe.audioCues")`). */
private const val KEY_BREATHE_AUDIO_CUES = "breathe.audioCues"

enum class BreathTone(val frequencyHz: Double) {
    Inhale(440.0),   // A4, brighter for "in"
    Exhale(330.0),   // E4, lower for "out"
}

/**
 * The Android twin of [BreathTonePlayer] (iOS) — a tiny on-device tone player for the opt-in audio pacer.
 * It synthesises a short, soft sine "ding" per phase (a higher note on the inhale, a lower one on the
 * exhale) into an [AudioTrack].
 *
 * iOS uses an *ambient* audio session so the silent switch mutes it; Android has no silent switch, so the
 * honest equivalent is to honour the **ringer mode** — when the phone is on silent or vibrate we simply
 * don't play, the same "quiet means quiet" promise. The track is tagged as a sonification assistance cue
 * (not media), so it ducks politely and won't hijack the music stream. Buffers are generated once and
 * reused; [release] frees the track when the screen goes away or the pacer is switched off.
 */
class BreathTonePlayer(context: Context) {

    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private val sampleRate = 44_100
    private val toneSeconds = 0.45
    private val tracks = HashMap<BreathTone, AudioTrack?>()

    /** Play the phase tone, unless the phone is on silent/vibrate (the "honours silent mode" promise). */
    fun play(tone: BreathTone) {
        val am = audioManager ?: return
        if (am.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        val track = tracks.getOrPut(tone) { buildTrack(tone) } ?: return
        try {
            // Restart from the top each phase so a fresh tone fires even if the last one is still tailing.
            track.pause()
            track.flush()
            writeTone(track, tone)
            track.play()
        } catch (_: IllegalStateException) {
            // Audio is a nicety, never load-bearing — if the track is in a bad state we just stay silent.
        }
    }

    /** Release the underlying tracks. Idempotent. */
    fun release() {
        tracks.values.forEach { runCatching { it?.release() } }
        tracks.clear()
    }

    private fun buildTrack(tone: BreathTone): AudioTrack? {
        val samples = sampleData(tone)
        val sizeBytes = samples.size * 2  // 16-bit PCM
        return try {
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(sizeBytes, 1))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            writeTone(track, tone)
            track
        } catch (_: Exception) {
            null
        }
    }

    private fun writeTone(track: AudioTrack, tone: BreathTone) {
        val samples = sampleData(tone)
        track.write(samples, 0, samples.size)
    }

    /**
     * Build a single soft sine tone with a short attack and a longer release envelope, so it fades in and
     * out rather than clicking. Cached per tone so we synthesise it once.
     */
    private val cache = HashMap<BreathTone, ShortArray>()
    private fun sampleData(tone: BreathTone): ShortArray = cache.getOrPut(tone) {
        val total = (toneSeconds * sampleRate).toInt()
        val attack = (0.02 * sampleRate).toInt()
        val release = (0.18 * sampleRate).toInt()
        val peak = 0.28  // kept quiet — a gentle cue, not a beep
        ShortArray(total) { i ->
            val t = i.toDouble() / sampleRate
            val s = sin(2.0 * PI * tone.frequencyHz * t)
            val env = when {
                i < attack -> i.toDouble() / maxOf(attack, 1)
                i > total - release -> (total - i).toDouble() / maxOf(release, 1)
                else -> 1.0
            }
            (s * env * peak * Short.MAX_VALUE).toInt().toShort()
        }
    }
}
