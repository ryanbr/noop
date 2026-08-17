package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HrvAnalyzer
import com.noop.analytics.HrvAnalyzerTrace
import com.noop.analytics.SpotHrvReading
import com.noop.data.MetricSeriesRow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.time.TimeSource
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Manual HRV snapshot — "Take an HRV reading" (#127). Kotlin parity twin of
 * Strand/Screens/HRVSnapshotView.swift.
 *
 * A short, deliberate seated capture: the user sits still and breathes normally while the strap's
 * live R-R intervals (the reliable 0x2A37 stream) accumulate for ~60 s. We then run the full
 * HrvAnalyzer cleaning pipeline (range filter → Malik ectopic rejection → ≥MIN_BEATS) and surface the
 * headline RMSSD plus SDNN, mean HR and the beats used. Saving banks the RMSSD as a single point in
 * the generic metric series ("hrv_snapshot", source "manual-hrv") so it sits beside every other
 * source for the explorer/trends.
 *
 * The live ingest uses the shared [rrPackets] stream; the capture buffer is uncapped (unlike
 * Breathe's rolling 30) because the analysis wants every clean beat. The window is a monotonic
 * 60-second deadline — countdown display and ingest cutoff both derive from it.
 */
@Composable
fun HrvSnapshotScreen(
    viewModel: AppViewModel,
    source: SpotHrvReading.Source = SpotHrvReading.Source.UNKNOWN,
    onClose: () -> Unit,
) {
    val live by viewModel.live.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var phase by remember { mutableStateOf(HrvPhase.Idle) }
    // Every R-R interval (ms) collected during the active capture window — uncapped on purpose; the
    // analyzer wants the whole window.
    val captureBuffer = remember { mutableStateOf<List<Int>>(emptyList()) }
    var secondsRemaining by remember { mutableIntStateOf(HRV_CAPTURE_SECONDS) }
    // Monotonic start of the active capture — the single time base for the countdown display, the
    // ingest cutoff, and the finish deadline. Null outside a capture.
    var captureStart by remember { mutableStateOf<TimeSource.Monotonic.ValueTimeMark?>(null) }
    // Live RMSSD over the beats gathered so far (a running indicator while capturing; the final figure
    // comes from the cleaned HrvAnalyzer.analyzeRaw).
    var runningRmssd by remember { mutableStateOf<Double?>(null) }
    // The completed analysis (null until Done).
    var result by remember { mutableStateOf<HrvAnalyzer.HrvResult?>(null) }
    // Whether the just-finished snapshot has been saved (drives the Save button → "Saved").
    var saved by remember { mutableStateOf(false) }

    val bonded = live.bonded

    // Keep the live HR stream on for the duration of the reading (ref-counted with Live/Health/Breathe).
    DisposableEffect(Unit) {
        viewModel.requestRealtimeHr()
        onDispose { viewModel.releaseRealtimeHr() }
    }

    // Pull new R-R intervals into the capture buffer as they arrive. rrSeq-keyed: equal
    // consecutive packets both count (see LiveRrPackets.kt).
    LaunchedEffect(Unit) {
        viewModel.live
            .rrPackets()
            .collect { rr ->
                if (phase != HrvPhase.Capturing) return@collect
                // Deadline gate: intervals on or after the 60-second mark stay out.
                val start = captureStart ?: return@collect
                if (!captureWindowOpen(start.elapsedNow().inWholeMilliseconds)) return@collect
                val merged = captureBuffer.value + rr
                captureBuffer.value = merged
                runningRmssd = HrvAnalyzer.rmssdRaw(merged.map { it.toDouble() })
            }
    }

    // Capture countdown — only ticks while capturing; on the deadline, run the cleaning analysis.
    // Derived from the monotonic clock: a late resume jumps to the correct remaining value instead
    // of stretching the window (the old per-callback decrement did).
    LaunchedEffect(phase) {
        if (phase != HrvPhase.Capturing) return@LaunchedEffect
        val start = captureStart ?: return@LaunchedEffect
        while (true) {
            val elapsedMs = start.elapsedNow().inWholeMilliseconds
            secondsRemaining = remainingCaptureSeconds(elapsedMs)
            if (secondsRemaining <= 0) break
            delay(1000 - elapsedMs % 1000)   // sleep to the next whole-second boundary
        }
        // End the capture and run the full cleaning analysis over everything collected.
        val captureMs = start.elapsedNow().inWholeMilliseconds
        val raw = captureBuffer.value.map { it.toDouble() }
        // A capture whose collected beat time exceeds the wall clock it ran for held duplicated
        // beats (e.g. overlapping live sources) — refuse the number rather than publish it.
        if (HrvAnalyzer.spotCaptureOverCounted(raw.sum(), captureMs)) {
            result = HrvAnalyzer.HrvResult.empty(raw.size)
            phase = HrvPhase.Done
            return@LaunchedEffect
        }
        // HRV & Autonomic test mode (Test Centre Group G): when the mode is on, emit the cleaning trace
        // (nInput / nClean / rejected fraction, the range + Malik ectopic counts, the minBeats + spot
        // gates, RMSSD/SDNN/meanNN) tagged HRV. analyzeTrace returns the SAME HrvResult analyzeRaw would
        // (it reuses analyzeRaw verbatim), so the headline RMSSD is byte-identical with the trace on or off.
        // Zero cost when off: one SharedPreferences bool read and analyzeTrace is never called, so the plain
        // analyzeRaw path below runs untouched. Mirrors the macOS HRVSnapshotView wiring.
        result = if (com.noop.testcentre.TestCentre.from(context)
                .active(com.noop.testcentre.TestDomain.HRV)
        ) {
            val (traced, lines) = HrvAnalyzerTrace.analyzeTrace(
                raw, HrvAnalyzer.DEFAULT_SPOT_MAX_REJECTED_FRACTION, path = "spot",
            )
            for (line in lines) viewModel.ble.externalLog(line, com.noop.testcentre.TestDomain.HRV)
            traced
        } else {
            HrvAnalyzer.analyzeRaw(raw, HrvAnalyzer.DEFAULT_SPOT_MAX_REJECTED_FRACTION)
        }
        phase = HrvPhase.Done
    }

    // PERF (#707): lazy scaffold — each section is one `item { }`; the capture dial ticks `secondsRemaining`
    // each second during a capture, and a LazyColumn confines that tick's recomposition to the visible
    // items. Conditional sections use `if (cond) { item {} }` so a hidden result/hint adds no row. Order +
    // spacing identical (LazyColumn reproduces the eager `spacedBy(20.dp)`).
    LazyScreenScaffold(
        title = uiString(R.string.l10n_hrv_snapshot_screen_hrv_reading_a2cf71f3),
        subtitle = "A still, seated snapshot of your heart-rate variability",
    ) {
        // Status row.
        item {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            when (phase) {
                HrvPhase.Idle -> StatePill("Ready", tone = StrandTone.Neutral)
                HrvPhase.Capturing -> StatePill("Capturing", tone = StrandTone.Accent, pulsing = true)
                HrvPhase.Done -> StatePill("Reading complete", tone = StrandTone.Positive)
            }
            Spacer(Modifier.width(8.dp))
            if (bonded) {
                StatePill("Strap live", tone = StrandTone.Positive)
            } else {
                StatePill("Not connected", tone = StrandTone.Warning)
            }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onClose) {
                Icon(
                    Icons.Filled.Close,
                    contentDescription = uiString(R.string.l10n_hrv_snapshot_screen_close_hrv_reading_a29a99a1),
                    tint = Palette.textTertiary,
                )
            }
        }
        }

        // Capture card — the progress dial over a calm Rest-world starfield.
        item {
        NoopCard(padding = 24.dp, tint = Palette.restColor) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(260.dp)
                        .clip(RoundedCornerShape(Metrics.cardRadius)),
                    contentAlignment = Alignment.Center,
                ) {
                    ScenicHeroBackground(
                        modifier = Modifier.matchParentSize(),
                        domain = DomainTheme.Rest,
                        starCount = 48,
                    )
                    CaptureDial(
                        fraction = captureFraction(phase, secondsRemaining),
                        value = dialValue(phase, runningRmssd, result),
                        unit = if (phase == HrvPhase.Idle) "RMSSD" else "MS RMSSD",
                        sub = if (phase == HrvPhase.Capturing) {
                            "${secondsRemaining}s left · ${captureBuffer.value.size} beats"
                        } else null,
                    )
                }

                Text(
                    text = instruction(phase, bonded, result),
                    style = NoopType.subhead,
                    color = if (phase == HrvPhase.Capturing) Palette.restBright else Palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
        }
        }

        // Controls.
        item {
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap), modifier = Modifier.fillMaxWidth()) {
            Button(
                onClick = {
                    if (phase == HrvPhase.Capturing) {
                        // Cancel.
                        phase = HrvPhase.Idle
                        captureStart = null
                        secondsRemaining = HRV_CAPTURE_SECONDS
                        runningRmssd = null
                    } else {
                        if (!bonded) return@Button
                        captureBuffer.value = emptyList()
                        secondsRemaining = HRV_CAPTURE_SECONDS
                        runningRmssd = null
                        result = null
                        saved = false
                        captureStart = TimeSource.Monotonic.markNow()
                        phase = HrvPhase.Capturing
                    }
                },
                modifier = Modifier.weight(1f),
                enabled = bonded || phase == HrvPhase.Capturing,
                colors = ButtonDefaults.buttonColors(
                    containerColor = if (phase == HrvPhase.Capturing) Palette.statusCritical else Palette.accent,
                    contentColor = Palette.surfaceBase,
                ),
            ) {
                if (phase == HrvPhase.Capturing) {
                    Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                } else {
                    Icon(Icons.Filled.MonitorHeart, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                }
                Text(primaryLabel(phase), style = NoopType.headline)
            }

            val r = result
            if (phase == HrvPhase.Done && r != null && r.rmssd != null) {
                OutlinedButton(
                    onClick = {
                        val rmssd = r.rmssd
                        val day = hrvDayKey(Date())
                        val row = MetricSeriesRow(
                            deviceId = HRV_SNAPSHOT_SOURCE_ID,
                            day = day,
                            key = HRV_SNAPSHOT_METRIC_KEY,
                            value = rmssd,
                        )
                        saved = true // optimistic — the write is local + idempotent
                        scope.launch {
                            runCatching {
                                viewModel.repo.upsertMetricSeries(listOf(row))
                            }.onFailure { saved = false }
                        }
                    },
                    enabled = !saved,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) {
                    Icon(Icons.Filled.Download, contentDescription = null, modifier = Modifier.padding(end = 6.dp))
                    Text(if (saved) "Saved" else "Save", style = NoopType.body)
                }
            }
        }
        }

        // Result.
        val done = result
        if (phase == HrvPhase.Done && done != null) {
            item { ResultCard(done) }
        }

        // Methodology — source-aware caveat (a 5/MG's R-R is optical PPG, noisier than a chest strap).
        // The same RMSSD math the nightly HRV uses (Task Force 1996, cleaned), so the spot number is
        // comparable to your overnight figure.
        item {
        NoopCard(tint = Palette.restColor) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Overline("How this is measured")
                Text(
                    uiString(R.string.l10n_hrv_snapshot_screen_a_60_second_snapshot_of_your_35f03f7c) +
                        "(range and ectopic-beat filtering) before computing RMSSD the same way your " +
                        "overnight HRV is computed.",
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
                Text(
                    SpotHrvReading.caveatFor(source),
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
        }
        }

        if (!bonded) { item { NotBondedHint() } }
    }
}

// MARK: - Capture phase

private enum class HrvPhase { Idle, Capturing, Done }

// MARK: - Capture dial

/** The centre dial: a progress ring around the live RMSSD / countdown. */
@Composable
private fun CaptureDial(fraction: Float, value: String, unit: String, sub: String?) {
    val animatedFraction by animateFloatAsState(
        targetValue = fraction.coerceIn(0f, 1f),
        animationSpec = tween(400, easing = Motion.easeInOut),
        label = uiString(R.string.l10n_hrv_snapshot_screen_hrvdial_4c244c45),
    )
    val a11y = when {
        sub != null -> "Capturing. $value milliseconds RMSSD so far. $sub."
        else -> "$value $unit"
    }
    Box(
        modifier = Modifier
            .size(190.dp)
            .clearAndSetSemantics { contentDescription = a11y },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.matchParentSize()) {
            val stroke = 10.dp.toPx()
            val inset = stroke / 2f
            val arcSize = Size(size.width - stroke, size.height - stroke)
            // Track.
            drawArc(
                color = Palette.restColor.copy(alpha = 0.20f),
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
            // Progress — Rest-world sweep, 12 o'clock origin.
            drawArc(
                brush = Brush.sweepGradient(listOf(Palette.restDeep, Palette.restBright)),
                startAngle = -90f,
                sweepAngle = 360f * animatedFraction,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(value, style = NoopType.number(48f), color = Palette.metricPurple)
            Text(
                unit,
                style = NoopType.footnote.copy(letterSpacing = 0.8.sp),
                color = Palette.textTertiary,
            )
            if (sub != null) {
                Text(
                    sub,
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

// MARK: - Result

@Composable
private fun ResultCard(result: HrvAnalyzer.HrvResult) {
    NoopCard(padding = 18.dp, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Overline("Your reading")

            if (result.rmssd == null) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = Palette.statusWarning)
                    Text(
                        uiString(R.string.l10n_hrv_snapshot_screen_not_enough_clean_beats_sit_still_0893e6c2, result.nClean) +
                            "${result.nInput} beats survived filtering (need ${HrvAnalyzer.MIN_BEATS}).",
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                }
            } else {
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    StatTile(
                        modifier = Modifier.weight(1f),
                        label = uiString(R.string.l10n_hrv_snapshot_screen_rmssd_e240fd3c),
                        value = formatHrv(result.rmssd, "%.0f"),
                        caption = "ms",
                        accent = Palette.metricPurple,
                    )
                    StatTile(
                        modifier = Modifier.weight(1f),
                        label = uiString(R.string.l10n_hrv_snapshot_screen_sdnn_9ab9ee2a),
                        value = formatHrv(result.sdnn, "%.0f"),
                        caption = "ms",
                        accent = Palette.restBright,
                    )
                    StatTile(
                        modifier = Modifier.weight(1f),
                        label = uiString(R.string.l10n_hrv_snapshot_screen_mean_hr_6c9272dd),
                        value = formatHrv(meanHr(result.meanNN), "%.0f"),
                        caption = "bpm",
                        accent = Palette.metricRose,
                    )
                    StatTile(
                        modifier = Modifier.weight(1f),
                        label = uiString(R.string.l10n_hrv_snapshot_screen_beats_12aafda0),
                        value = "${result.nClean}",
                        caption = "used",
                        accent = Palette.metricCyan,
                    )
                }
            }
        }
    }
}

// MARK: - Not-bonded hint

@Composable
private fun NotBondedHint() {
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(Palette.statusWarning.copy(alpha = 0.08f), shape)
            .border(1.dp, Palette.statusWarning.copy(alpha = 0.25f), shape)
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.MonitorHeart, contentDescription = null, tint = Palette.statusWarning)
        Text(
            uiString(R.string.l10n_hrv_snapshot_screen_an_hrv_reading_needs_the_live_11b70bff),
            style = NoopType.footnote, color = Palette.textSecondary,
        )
    }
}

// MARK: - Pure view helpers (mirrors HRVSnapshotView)

/** Length of a capture in seconds. Mirrors HRVSnapshotView.captureSeconds. */
const val HRV_CAPTURE_SECONDS = 60

/** Generic metric-series key for a manual HRV reading (matches Swift `HRVSnapshot.metricKey`). */
const val HRV_SNAPSHOT_METRIC_KEY = "hrv_snapshot"

/**
 * Source id this manual reading is stored under — its own source so it sits beside WHOOP / Apple for
 * the per-source explorer (matches Swift `HRVSnapshot.sourceId`).
 */
const val HRV_SNAPSHOT_SOURCE_ID = "manual-hrv"

/**
 * Whole seconds left for a monotonic elapsed time, never negative. Mirrors
 * HRVSnapshotView.remainingSeconds.
 */
fun remainingCaptureSeconds(elapsedMs: Long): Int =
    (HRV_CAPTURE_SECONDS - elapsedMs / 1000).coerceAtLeast(0L).toInt()

/**
 * The ingest gate: intervals on or after the 60-second deadline stay out, however late the
 * countdown coroutine runs. Mirrors HRVSnapshotView.captureWindowOpen.
 */
fun captureWindowOpen(elapsedMs: Long): Boolean = elapsedMs < HRV_CAPTURE_SECONDS * 1000L

private fun captureFraction(phase: HrvPhase, secondsRemaining: Int): Float = when (phase) {
    HrvPhase.Idle -> 0f
    HrvPhase.Capturing -> (HRV_CAPTURE_SECONDS - secondsRemaining).toFloat() / HRV_CAPTURE_SECONDS.toFloat()
    HrvPhase.Done -> 1f
}

private fun dialValue(phase: HrvPhase, runningRmssd: Double?, result: HrvAnalyzer.HrvResult?): String =
    when (phase) {
        HrvPhase.Idle -> "—"
        HrvPhase.Capturing -> runningRmssd?.let { String.format(Locale.US, "%.0f", it) } ?: "…"
        HrvPhase.Done -> result?.rmssd?.let { String.format(Locale.US, "%.0f", it) } ?: "—"
    }

private fun primaryLabel(phase: HrvPhase): String = when (phase) {
    HrvPhase.Idle -> "Take an HRV reading"
    HrvPhase.Capturing -> "Cancel"
    HrvPhase.Done -> "Take another reading"
}

private fun instruction(phase: HrvPhase, bonded: Boolean, result: HrvAnalyzer.HrvResult?): String =
    when (phase) {
        HrvPhase.Idle -> if (bonded) {
            "Sit still and breathe normally. Tap below to take a 60-second reading."
        } else {
            "Connect your strap on the Live screen to take a reading."
        }
        HrvPhase.Capturing -> "Sit still, breathe normally. Keep your wrist relaxed and steady."
        HrvPhase.Done -> if (result != null && result.rmssd == null) {
            "Not enough clean beats - sit still and try again."
        } else {
            "Done. Save this reading to keep it in your trends."
        }
    }

/** Format a nullable Double with a C-style format, em-dash for null. Shared with the tests. */
internal fun formatHrv(value: Double?, fmt: String): String =
    if (value == null) "—" else String.format(Locale.US, fmt, value)

/**
 * Mean heart rate (bpm) from the mean NN interval (ms): 60000 / meanNN. null when meanNN is missing
 * or non-positive. Mirrors HRVSnapshotView.meanHR.
 */
internal fun meanHr(meanNN: Double?): Double? =
    if (meanNN == null || meanNN <= 0) null else 60_000.0 / meanNN

/** The reading's local calendar day (yyyy-MM-dd) — the `day` of the metric store's natural key. */
private fun hrvDayKey(date: Date): String =
    SimpleDateFormat("yyyy-MM-dd", Locale.US).apply { timeZone = TimeZone.getDefault() }.format(date)
