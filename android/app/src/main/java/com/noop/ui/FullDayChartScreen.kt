package com.noop.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.HrvAnalyzer
import com.noop.data.OuraRespScale
import com.noop.protocol.DeviceFamily
import com.noop.protocol.skinTempCelsius
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.util.Calendar
import java.util.Locale

// MARK: - Deep Timeline (Android twin of FullDayChartView) — #575
//
// A full-day, full-resolution metric viewer reached from the Explore tab. The hard problem — never
// drawing ~86k points for a worn 24h — is solved by reading adaptively: day scale → coarse Room HR
// buckets (WhoopDao.hrBuckets, which already COALESCEs measured + v26 PPG #156), zoomed-in → raw
// per-second rows (WhoopDao.hrSamples, same COALESCE). The chart's pinch/pan reports the new window and
// we re-read at the new resolution. Mirrors macOS FullDayChartView + OverviewHRChart's zoom binding.

private enum class TimelineMetric(val title: String) {
    Hr(uiString(R.string.timeline_metric_heart_rate)),
    // #803: this trace is a rolling rMSSD over the RR series, NOT the raw RR interval it used to plot.
    // The honest title says exactly what the curve is (windowed rMSSD), not a bare "HRV".
    Hrv(uiString(R.string.timeline_metric_rmssd)),
    Spo2(uiString(R.string.timeline_metric_spo2)),
    SkinTemp(uiString(R.string.timeline_metric_skin_temp)),
    Respiration(uiString(R.string.timeline_metric_respiration)),
    Motion(uiString(R.string.timeline_metric_motion)),
    // #175: the strap's OWN band sleep_state track (0 wake/1 still/2 asleep/3 up), shown as a distinct
    // stepped track alongside the derived hypnogram. This is the band's REPORTED state, NOT a stage NOOP
    // trusts as truth — the pill names it "Band Sleep State" so it can't be mistaken for the derived stages.
    BandSleepState(uiString(R.string.timeline_metric_band_sleep_state)),

    // The Oura ring's OWN per-window motion (0x47, OURA_MOTION events): seconds of movement in each ~30 s
    // window. An honest ACTIVITY signal — NOT gravity magnitude (the ring sends no continuous gravity) and
    // NEVER a step count. Empty for a WHOOP strap. Twin of Swift TimelineMetric.ouraMovement.
    Movement(uiString(R.string.timeline_metric_movement)),
}

@Composable
fun FullDayChartScreen(vm: AppViewModel, onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    // #908: the deep timeline follows the ACTIVE strap id, not a hardcoded "my-whoop". A strap re-added
    // through the device manager banks its raw under its own fresh id, so a pinned "my-whoop" read left
    // the timeline empty. HR additionally reads the active ∪ canonical union (see [readTimeline]) so the
    // re-added strap's live curve AND the canonical import history both surface. Single-WHOOP install
    // resolves to "my-whoop" ⇒ byte-identical reads.
    val deviceId = vm.activeStrapId
    val recentDays by vm.recentDays.collectAsStateWithLifecycle()

    // Today's local calendar midnight — the clamp the day stepper can never pass.
    val todayStart = remember {
        val cal = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        cal.timeInMillis / 1000
    }
    // The day being shown … +24h. Mutable so the user can step back to days that actually have data
    // instead of a possibly-empty today (#597 — was today-only with no way back).
    var dayStartSec by remember { mutableStateOf(todayStart) }
    var didLand by remember { mutableStateOf(false) }
    val dayBounds = dayStartSec..(dayStartSec + 86_400)
    // #986: a continuous left-drag can scroll back to the shown day plus the two before it (a rolling 3-day
    // window), so older HR is reachable by dragging, not only the day-stepper. Deliberately bounded so one
    // drag can't fling through weeks; the reload keys on the visible window so panned-to days load, and a day
    // with no data falls to the empty state (parity with iOS FullDayChartView.panBounds).
    val panBounds = (dayStartSec - 2 * 86_400)..(dayStartSec + 86_400)

    var metric by remember { mutableStateOf(TimelineMetric.Hr) }
    var ownedOnly by remember { mutableStateOf(true) }
    // #623: is an empty SpO2 / respiration track "unsupported on this strap" or just "not this window"?
    // A 5.0/MG never decodes either (4.0-only wire signals). But the canonical registry-model resolver
    // (#171) maps legacy bare-"WHOOP" 4.0s to the 5.0 family too, and a 4.0-v24 DOES bank SpO2 — so gate
    // the "not supported" copy on 5.0-family AND the strap having NEVER produced that metric, else a legacy
    // 4.0-v24 with data on other days would contradict itself. `ever*` default true (assume produced) so a
    // 4.0-v24 never flashes the wrong message before the async reads resolve.
    var isWhoop5 by remember { mutableStateOf(false) }
    var everSpo2 by remember { mutableStateOf(true) }
    var everResp by remember { mutableStateOf(true) }
    LaunchedEffect(deviceId) {
        val d = runCatching { vm.pairedDevices() }.getOrDefault(emptyList())
            .firstOrNull { it.id == deviceId }
        // A positive "is it a 5/MG", never a coalesced one (#1086): the respiration copy tells the reader
        // their estimate is on the Health screen, which is true for a WHOOP 5 (the R-R RSA estimate runs)
        // and false for a non-WHOOP device whose banked stream that estimate refuses.
        val whoop5 = DeviceFamily.isWhoop5Registry(d?.model, d?.brand)
        isWhoop5 = whoop5
        val now = System.currentTimeMillis() / 1000
        everSpo2 = !whoop5 || runCatching { vm.repo.spo2Samples(deviceId, 0, now, 1) }.getOrDefault(emptyList()).isNotEmpty()
        everResp = !whoop5 || runCatching { vm.repo.respSamples(deviceId, 0, now, 1) }.getOrDefault(emptyList()).isNotEmpty()
    }
    // The visible window the gestures drive; null → the whole day.
    var window by remember { mutableStateOf<LongRange?>(null) }
    val visible = window ?: dayBounds

    // #597 / #863 , one-shot: open on the most recent day that has DATA, so a just-synced-history user
    // (and a calibrating 4.0 that has banked raw HR but no scored DailyMetric yet) lands on real data
    // instead of an empty today. The latest SCORED day (DailyMetric) is the first choice; when there is
    // none yet, we fall back to the most recent day that has raw HR (max hrSample.ts for the strap), so a
    // calibrating 4.0 still opens on the day its banked HR lives rather than a blank today (#863). Mirrors
    // iOS landOnLatestDayIfNeeded, which already keys on the raw-HR union via repo.latestDataDayStart.
    LaunchedEffect(recentDays) {
        if (!didLand) {
            // Only mark the one-shot done once we actually have something to key on , so a first compose
            // that runs before recentDays loads doesn't burn the jump and strand a scored user on today.
            val latestScoredKey = recentDays.maxByOrNull { it.day }?.day
            val latestRawHrTs = if (latestScoredKey == null) {
                runCatching { vm.repo.latestHrSampleTs(deviceId) }.getOrNull()
            } else {
                null
            }
            if (latestScoredKey != null || latestRawHrTs != null) {
                didLand = true
                val target = landTargetDayStart(
                    currentDayStart = dayStartSec,
                    latestScoredDayKey = latestScoredKey,
                    latestRawHrTs = latestRawHrTs,
                    dayStartOf = ::epochSecToLocalDayStart,
                )
                if (target != null) { dayStartSec = target; window = null }
            }
        }
    }

    var points by remember { mutableStateOf<List<TimelinePoint>>(emptyList()) }
    var isRaw by remember { mutableStateOf(false) }
    var bucketSeconds by remember { mutableStateOf(0L) }
    var loading by remember { mutableStateOf(true) }

    // Imperial/Metric temperature preference (#101) — skin temp is stored/read in °C, so when the user
    // has °F selected the chart line, y-axis, stats AND readout need the converted number, not just a
    // relabelled suffix. Mirrors CompareScreen (read once per composition, like the app's other unit reads).
    val context = LocalContext.current
    val tempUnit = UnitPrefs.temperature(context)

    // `points` in the DISPLAYED unit (#101). For every metric but skin temp this is just the raw points;
    // skin temp is the ABSOLUTE per-timestamp °C (skinTempCelsius), so when °F is selected convert with the
    // absolute ×9/5+32 (not a deviation rescale) so the chart line, y-axis AND stats read in °F — the
    // suffix relabel alone would leave the plotted numbers in Celsius. Mirrors the Swift FullDayChartView.
    val displayPoints = if (metric == TimelineMetric.SkinTemp && tempUnit == TemperatureUnit.FAHRENHEIT) {
        points.map { TimelinePoint(it.ts, UnitFormatter.celsiusToFahrenheit(it.value)) }
    } else {
        points
    }

    // Re-read on metric / source / settled-window / fresh-data change. The DB read picks raw vs buckets.
    LaunchedEffect(metric, ownedOnly, visible.first, visible.last, recentDays) {
        // PERF (#scroll-jank): a pinch/pan reports a NEW window on every gesture frame, each of which
        // re-keys this effect and previously fired a fresh Room query mid-gesture (heavy, on every
        // frame). Debounce by sleeping first: while the window is still moving, the next frame re-keys
        // the effect and cancels this one before the query runs, so ONLY the settled window (after the
        // gesture pauses ~130ms) actually hits the DB. The sleep is before `loading = true`, so during
        // a live gesture the existing chart stays put instead of flashing the "Loading the day…" state.
        // A metric/source/day switch re-keys too and waits the same ~130ms before loading — imperceptible,
        // and it keeps the chart showing the prior data until the new read lands. Behaviour-preserving:
        // the settled window still issues exactly the same query and renders identically.
        delay(130)
        loading = true
        val from = visible.first
        val to = visible.last
        val bucket = timelineBucketSeconds(to - from, targetPoints = 600)
        bucketSeconds = bucket
        isRaw = bucket <= 1L
        points = readTimeline(vm, deviceId, metric, from, to, bucket)
        loading = false
    }

    ScreenScaffold(
        title = stringResource(R.string.deep_timeline_title),
        subtitle = stringResource(R.string.timeline_subtitle),
    ) {
        // METRIC PILLS — horizontally scrollable so all six fit on a phone.
        Row(modifier = Modifier.horizontalScroll(rememberScrollState())) {
            SegmentedPillControl(
                items = TimelineMetric.entries.toList(),
                selection = metric,
                label = { it.title },
                onSelect = { metric = it; window = null },
            )
        }

        // SOURCE PILL — the owned strap, with the #574 owned/all scope toggle.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.timeline_my_whoop), style = NoopType.footnote, color = Palette.textSecondary)
            Spacer(Modifier.weight(1f))
            val ownedLabel = stringResource(R.string.timeline_owned)
            val allLabel = stringResource(R.string.timeline_all)
            SegmentedPillControl(
                items = listOf(true, false),
                selection = ownedOnly,
                label = { if (it) ownedLabel else allLabel },
                onSelect = { ownedOnly = it },
            )
        }

        // DAY STEPPER — move the whole timeline back/forward a day (#597). Forward clamps at today.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
        ) {
            Text(
                "‹", style = NoopType.title2, color = Palette.accent,
                modifier = Modifier
                    .clickable { dayStartSec -= 86_400; window = null }
                    .padding(horizontal = 12.dp, vertical = 2.dp),
            )
            Spacer(Modifier.weight(1f))
            Text(dayLabel(dayStartSec, todayStart), style = NoopType.headline, color = Palette.textPrimary)
            Spacer(Modifier.weight(1f))
            val onLatest = dayStartSec >= todayStart
            Text(
                "›", style = NoopType.title2, color = if (onLatest) Palette.textTertiary else Palette.accent,
                modifier = Modifier
                    .then(if (onLatest) Modifier else Modifier.clickable { dayStartSec += 86_400; window = null })
                    .padding(horizontal = 12.dp, vertical = 2.dp),
            )
        }

        NoopCard(tint = Palette.metricRose) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(metric.title)
                        Text(resolutionSubtitle(points, isRaw, bucketSeconds),
                            style = NoopType.footnote, color = Palette.textTertiary)
                    }
                    displayPoints.lastOrNull()?.let {
                        Text(formatValue(metric, it.value) + unitSuffix(metric, tempUnit),
                            style = NoopType.bodyNumber, color = Palette.textPrimary)
                    }
                }

                Box(modifier = Modifier.fillMaxWidth().height(280.dp), contentAlignment = Alignment.Center) {
                    when {
                        loading && points.isEmpty() ->
                            Text(stringResource(R.string.timeline_loading_day), style = NoopType.footnote, color = Palette.textTertiary)
                        points.isEmpty() -> {
                            // #623: the metric is genuinely UNSUPPORTED on this strap only when it's a
                            // 5.0-family strap that has never produced it — not merely an empty window.
                            val metricUnsupported = ownedOnly && isWhoop5 && when (metric) {
                                TimelineMetric.Spo2 -> !everSpo2
                                TimelineMetric.Respiration -> !everResp
                                else -> false
                            }
                            EmptyTimelineState(metric, ownedOnly, metricUnsupported)
                        }
                        else -> TimelineChart(
                            points = displayPoints,
                            windowStart = visible.first,
                            windowEnd = visible.last,
                            bounds = panBounds,   // #986: pan clamp is the rolling 3-day window, not one day
                            color = metricColor(metric),
                            modifier = Modifier.fillMaxWidth().height(280.dp),
                            onWindowChange = { window = it },
                        )
                    }
                }

                if (displayPoints.isNotEmpty()) {
                    val vals = displayPoints.map { it.value }
                    Row(modifier = Modifier.fillMaxWidth()) {
                        TimelineStat(stringResource(R.string.timeline_min), formatValue(metric, vals.minOrNull() ?: 0.0), Modifier.weight(1f))
                        TimelineStat(stringResource(R.string.timeline_avg), formatValue(metric, vals.average()), Modifier.weight(1f))
                        TimelineStat(stringResource(R.string.timeline_max), formatValue(metric, vals.maxOrNull() ?: 0.0), Modifier.weight(1f))
                    }
                }
            }
        }

        // ZOOM HINT + reset.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (window == null) stringResource(R.string.timeline_pinch_to_zoom) else stringResource(R.string.timeline_zoomed_in),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
            Spacer(Modifier.weight(1f))
            if (window != null) {
                Text(
                    stringResource(R.string.timeline_reset),
                    style = NoopType.footnote,
                    color = Palette.accent,
                    modifier = Modifier.clickable { window = null },
                )
            }
        }
    }
}

@Composable
private fun EmptyTimelineState(metric: TimelineMetric, ownedOnly: Boolean, metricUnsupported: Boolean) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.padding(horizontal = 24.dp),
    ) {
        Text(stringResource(R.string.timeline_empty_metric, metric.title.lowercase(Locale.US)),
            style = NoopType.body, color = Palette.textSecondary)
        // #623: when SpO2 / raw respiration is genuinely unsupported on this strap (a 5.0-family strap that
        // has never produced it — those are 4.0-only wire signals), say so instead of a generic "nothing
        // offloaded" that reads as broken, and point respiration at the Health screen where the R-R/RSA
        // estimate surfaces. [metricUnsupported] already folds in the family + never-produced + ownedOnly
        // gate, so a 4.0-v24 with data on other days keeps the generic message.
        val reason = when {
            metricUnsupported && metric == TimelineMetric.Spo2 ->
                stringResource(R.string.timeline_spo2_not_on_whoop5)
            metricUnsupported && metric == TimelineMetric.Respiration ->
                stringResource(R.string.timeline_resp_not_on_whoop5)
            ownedOnly -> stringResource(R.string.timeline_nothing_offloaded)
            else -> stringResource(R.string.timeline_other_sources_no_offload)
        }
        Text(reason, style = NoopType.footnote, color = Palette.textTertiary, textAlign = TextAlign.Center)
    }
}

@Composable
private fun TimelineStat(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Text(label, style = NoopType.footnote, color = Palette.textTertiary)
        Text(value, style = NoopType.captionNumber, color = Palette.textSecondary)
    }
}

// MARK: - Read

/** Adaptive read: HR rides the COALESCE-preserving Room reads (buckets at day scale, raw when zoomed);
 *  other metrics read their raw sample tables and bin in-process when zoomed out. */
private suspend fun readTimeline(
    vm: AppViewModel,
    deviceId: String,
    metric: TimelineMetric,
    from: Long,
    to: Long,
    bucket: Long,
): List<TimelinePoint> = withContext(Dispatchers.Default) {
    // PERF parity with macOS Repository.timelineSeries: the Room reads already hop to Room's executor,
    // but this function is called from a LaunchedEffect (Main), so the post-read mapping + downsample
    // (up to 200k 1 Hz HR rows on a dense day) would otherwise run on the MAIN thread and beach-ball the
    // UI. Run the whole assembly on Default; the suspend Room queries still execute off-main and only the
    // CPU work moves off the UI thread. Output is unchanged.
    val repo = vm.repo
    if (metric == TimelineMetric.Hr) {
        // #908: HR rides the active strap ∪ canonical "my-whoop" union so a re-added strap's live curve and
        // the canonical import history both render (matches Swift Repository.timelineSeries). [deviceId] is
        // already the active strap id; a single-WHOOP install resolves to "my-whoop" ⇒ one id ⇒ same read.
        return@withContext if (bucket <= 1L) {
            runCatching { repo.hrSamplesUnion(deviceId, from, to, limit = 200_000) }.getOrDefault(emptyList())
                .map { TimelinePoint(it.ts, it.bpm.toDouble()) }
        } else {
            runCatching { repo.hrBucketsUnion(deviceId, from, to, bucket) }.getOrDefault(emptyList())
                .map { TimelinePoint(it.bucket, it.avgBpm) }
        }
    }
    val raw: List<TimelinePoint> = when (metric) {
        TimelineMetric.Hr -> emptyList()
        TimelineMetric.Hrv -> {
            // #803: plot a rolling rMSSD (ms) over the RR series, NOT the raw RR interval. Raw RR is the
            // beat-to-beat heart PERIOD, not variability, so labelling it "HRV" was dishonest. HrvAnalyzer
            // applies the SAME Malik/range artifact filter the nightly RMSSD uses, then slides a 5-min
            // window. The result is already (ts, value); skip the in-process downsample below (the
            // windowing IS the smoothing) by returning here. A thinning stride (window/8, mirroring the
            // Swift Repository caller) keeps a 1 Hz RR stream from emitting a point per beat and flooding
            // the chart at day scale (the #575 point-count risk downsampleTimeline handles for the others).
            // #1036 (ryanbr): stepSec closes this Android-only day-scale flood gap.
            val hrvWindow = HrvAnalyzer.DEFAULT_ROLLING_WINDOW_SEC
            return@withContext runCatching { repo.rrIntervals(deviceId, from, to, 200_000) }.getOrDefault(emptyList())
                .let { HrvAnalyzer.rollingRmssd(it, windowSec = hrvWindow, stepSec = maxOf(1, hrvWindow / 8)) }
                .map { (ts, v) -> TimelinePoint(ts, v) }
        }
        TimelineMetric.Spo2 ->
            runCatching { repo.spo2Samples(deviceId, from, to, 200_000) }.getOrDefault(emptyList())
                .mapNotNull { if (it.ir > 0) TimelinePoint(it.ts, it.red.toDouble() / it.ir) else null }
        TimelineMetric.SkinTemp -> {
            // #938: family-aware raw→°C — 5/MG centidegrees (raw/100, #156), a WHOOP 4.0 v24 raw ADC map.
            // The registry-model-label → family mapping lives in DeviceFamily.forRegistryDevice (#171).
            // A non-WHOOP device (null) shares the non-4.0 scale, so coalesce to WHOOP5 — same conversion
            // as before; brand-awareness just stops it claiming to be a WHOOP (#1086).
            // Mirrors Swift Repository.timelineRawMetric.
            val d = runCatching { vm.pairedDevices() }.getOrDefault(emptyList())
                .firstOrNull { it.id == deviceId }
            val family = DeviceFamily.forRegistryDevice(d?.model, d?.brand) ?: DeviceFamily.WHOOP5
            runCatching { repo.skinTempSamples(deviceId, from, to, 200_000) }.getOrDefault(emptyList())
                .map { TimelinePoint(it.ts, skinTempCelsius(it.raw, family)) }
        }
        TimelineMetric.Respiration ->
            // Two quantities share this table: a WHOOP's raw respiration ADC waveform (plotted verbatim,
            // as before) and an Oura ring's own per-window RATE in milli-bpm (0x6A instrumentation), which
            // is scaled back to breaths/min so the track reads as ~14-16 instead of ~14,375.
            // `OuraRespScale` is the single place that mapping lives. Mirrors Swift.
            runCatching { repo.respSamples(deviceId, from, to, 200_000) }.getOrDefault(emptyList())
                .map { TimelinePoint(it.ts, OuraRespScale.displayValue(it.raw, deviceId)) }
        TimelineMetric.Motion ->
            runCatching { repo.gravitySamples(deviceId, from, to, 200_000) }.getOrDefault(emptyList())
                .map { TimelinePoint(it.ts, kotlin.math.sqrt(it.x * it.x + it.y * it.y + it.z * it.z)) }
        TimelineMetric.BandSleepState ->
            // #175: the strap's OWN band sleep_state (0 wake/1 still/2 asleep/3 up) as a stepped track. Read
            // the raw per-record stream (far sparser than 1 Hz HR, safe to load a day) and plot the 0-3 code
            // VERBATIM. Empty when the strap never reported it (a WHOOP 4.0, or a not-yet-offloaded window),
            // which the view renders as its honest "nothing here" state — never a fabricated flat line.
            runCatching { repo.sleepStateSamples(deviceId, from, to, 200_000) }.getOrDefault(emptyList())
                .map { TimelinePoint(it.ts, it.state.toDouble()) }
        TimelineMetric.Movement ->
            // The ring's OWN per-window motion from OURA_MOTION events (0x47): plot `motion_seconds`
            // (0 when still, up to 31 s in the ~30 s window). Honest activity, NEVER scored/steps; empty
            // for a WHOOP strap. Twin of Swift's ouraMovement series.
            runCatching { repo.events(deviceId, from, to, 200_000) }.getOrDefault(emptyList())
                .filter { it.kind == com.noop.data.OuraStreamMapping.EVENT_MOTION }
                .mapNotNull { row ->
                    val ms = runCatching { org.json.JSONObject(row.payloadJSON).optInt("motion_seconds", -1) }
                        .getOrDefault(-1)
                    if (ms < 0) null else TimelinePoint(row.ts, ms.toDouble())
                }
    }
    if (raw.isEmpty() || bucket <= 1L) return@withContext raw
    downsampleTimeline(raw, bucket)
}

/** Mean-bin raw timeline points onto a bucketSeconds grid (the in-process twin of the SQL hrBuckets),
 *  ascending. Pure. */
fun downsampleTimeline(points: List<TimelinePoint>, bucketSeconds: Long): List<TimelinePoint> {
    val bucket = bucketSeconds.coerceAtLeast(1L)
    if (points.isEmpty()) return emptyList()
    val sums = HashMap<Long, Pair<Double, Int>>()
    for (p in points) {
        val key = (p.ts / bucket) * bucket
        val acc = sums[key] ?: (0.0 to 0)
        sums[key] = (acc.first + p.value) to (acc.second + 1)
    }
    return sums.keys.sorted().map { key ->
        val acc = sums.getValue(key)
        TimelinePoint(key, acc.first / acc.second)
    }
}

// MARK: - Presentation

private fun resolutionSubtitle(points: List<TimelinePoint>, isRaw: Boolean, bucketSeconds: Long): String {
    if (points.isEmpty()) return "—"
    if (isRaw) return "Raw · per second"
    val m = bucketSeconds / 60
    return if (m >= 1) "$m-minute average" else "${bucketSeconds}-second average"
}

private fun metricColor(metric: TimelineMetric): Color = when (metric) {
    TimelineMetric.Hr -> Palette.metricRose
    TimelineMetric.SkinTemp -> Palette.strain033
    TimelineMetric.Hrv, TimelineMetric.Spo2 -> Palette.sleepLight
    TimelineMetric.Respiration, TimelineMetric.Motion, TimelineMetric.Movement -> Palette.textSecondary
    // #175: the band-state track uses the deep-sleep hue so it reads as a distinct sleep track.
    TimelineMetric.BandSleepState -> Palette.sleepDeep
}

private fun unitSuffix(metric: TimelineMetric, tempUnit: TemperatureUnit): String = when (metric) {
    TimelineMetric.Hr -> " bpm"
    TimelineMetric.SkinTemp -> UnitFormatter.temperatureUnit(tempUnit)   // #101: °C / °F per preference
    TimelineMetric.Hrv -> " ms"
    TimelineMetric.Movement -> " s"   // seconds of movement per ~30 s window (ring's 0x47 activity)
    else -> ""
}

private fun formatValue(metric: TimelineMetric, v: Double): String = when (metric) {
    TimelineMetric.Hr, TimelineMetric.Respiration, TimelineMetric.Hrv, TimelineMetric.Movement -> v.toInt().toString()
    // `v` already arrives in the displayed unit — callers read from `displayPoints`, which converts skin
    // temp to °F upfront so the chart's axis (plotted from the same points) agrees with this readout (#101).
    TimelineMetric.SkinTemp -> String.format(Locale.US, "%.1f", v)
    TimelineMetric.Spo2, TimelineMetric.Motion -> String.format(Locale.US, "%.2f", v)
    // #175: name the band's own state at the nearest code so the readout reads "asleep", not "2.0". A
    // bucket-averaged fractional value (when zoomed out) rounds to the nearest code — honest for a readout
    // label; the track itself plots the numeric code. Names the BAND's reported state, never a derived stage.
    TimelineMetric.BandSleepState -> when (Math.round(v).toInt()) {
        0 -> "wake"
        1 -> "still"
        2 -> "asleep"
        3 -> "up"
        else -> Math.round(v).toInt().toString()
    }
}

/** Parse a yyyy-MM-dd day key to its LOCAL midnight epoch-seconds, or null if unparseable (#597). */
private fun dayKeyToEpochSec(day: String): Long? = runCatching {
    val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", Locale.US)
    sdf.timeZone = java.util.TimeZone.getDefault()
    (sdf.parse(day)?.time ?: return null) / 1000
}.getOrNull()

/** An arbitrary epoch-second to its LOCAL midnight epoch-seconds (the same clamp `todayStart` uses), so a
 *  raw hrSample.ts can be mapped to the day it belongs to for the #863 raw-HR land fallback. */
private fun epochSecToLocalDayStart(ts: Long): Long {
    val cal = Calendar.getInstance().apply {
        timeInMillis = ts * 1000
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }
    return cal.timeInMillis / 1000
}

/**
 * PURE land-on-day decision for the Deep Timeline's one-shot open (#597 / #863). Given the day currently
 * shown, the latest SCORED day key (DailyMetric, yyyy-MM-dd) and the latest RAW HR sample timestamp, return
 * the day-start to land on, or null to stay put.
 *
 * Preference order: a scored day wins (the historical #597 behaviour); when there is no scored day yet, fall
 * back to the day that holds the most recent raw HR (the calibrating-4.0 case , banked HR, no DailyMetric
 * yet, #863). Only jumps to a day STRICTLY EARLIER than where we already are, so it can't fight a forward
 * step or land us "ahead" of today. [dayStartOf] maps an epoch-second to its local midnight (injected so the
 * decision is testable without a Calendar/zone).
 */
internal fun landTargetDayStart(
    currentDayStart: Long,
    latestScoredDayKey: String?,
    latestRawHrTs: Long?,
    dayStartOf: (Long) -> Long,
): Long? {
    val target = latestScoredDayKey?.let { dayKeyToEpochSec(it) }
        ?: latestRawHrTs?.let { dayStartOf(it) }
    return if (target != null && target < currentDayStart) target else null
}

/** "Today" / "Yesterday" / "Wed 18 Jun" label for the Deep Timeline day stepper (#597). */
private fun dayLabel(dayStartSec: Long, todayStart: Long): String = when (dayStartSec) {
    todayStart -> "Today"
    todayStart - 86_400 -> "Yesterday"
    else -> java.text.SimpleDateFormat("EEE d MMM", Locale.US).format(java.util.Date(dayStartSec * 1000))
}
