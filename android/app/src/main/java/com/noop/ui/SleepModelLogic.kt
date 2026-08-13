package com.noop.ui

import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.Baselines
import com.noop.analytics.SleepDebt
import com.noop.analytics.SleepStageTotals
import com.noop.data.DailyMetric
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import java.util.Calendar
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Resolve what the hero shows: the day-metric model when it resolved for the selected
 * night; else the session's own persisted segments (the day row can miss while the
 * segments exist); else null → the honest fallback. Never another night's data. (#160)
 */
internal fun heroDisplay(model: SleepModel?, night: HeroNight?): HeroDisplay? {
    if (model != null) {
        return HeroDisplay(model.stages, model.realSegments, model.hypnogramSegments, model.efficiencyText)
    }
    val segments = night?.realSegments ?: return null
    val stages = stagesFromSegments(segments) ?: return null
    val eff = night.session.efficiency
        ?.let { e -> "${(if (e <= 1.0) e * 100.0 else e).roundToInt()}%" } ?: "—"
    // Timestamped segments for the FILLED chart on the fallback path too: the group's full-night segments
    // when the night is fragmented, else this session's persisted array.
    val tsSegments = night.groupSegments ?: parsePersistedSegments(night.session.stagesJSON)
    return HeroDisplay(stages, segments, tsSegments, eff)
}

/** Sum (stage, minutes) weights into per-stage totals; null when nothing is > 0. */
internal fun stagesFromSegments(segments: List<Pair<String, Float>>): Stages? {
    var awake = 0.0; var light = 0.0; var deep = 0.0; var rem = 0.0
    for ((stage, minutes) in segments) {
        val m = minutes.toDouble()
        when (stage) {
            "wake", "awake" -> awake += m
            "light" -> light += m
            "deep" -> deep += m
            "rem" -> rem += m
        }
    }
    val s = Stages(awake = awake, light = light, deep = deep, rem = rem)
    return if (s.total > 0.0) s else null
}

/**
 * Extract stage minute counts from a session's stagesJSON, handling both formats:
 *  • Minute dict  {"awake":…,"light":…,"deep":…,"rem":…}  — imported nights (noopdb / WHOOP export)
 *  • Segment array [{start,end,stage}]                     — on-device computed nights
 * Returns null when the JSON is absent or unparseable, so callers fall back to DailyMetric columns.
 * SleepWindowReclip keeps the minute dict up to date after a wake-time edit, so stage counts
 * are correct immediately — no rescore needed for imported nights.
 */
internal fun parseSessionStages(stagesJSON: String?): StageMins? {
    stagesJSON ?: return null
    return runCatching {
        val trimmed = stagesJSON.trim()
        when {
            trimmed.startsWith("{") -> {
                val obj = JSONObject(trimmed)
                val aw = obj.optDouble("awake", 0.0)
                val li = obj.optDouble("light", 0.0)
                val dp = obj.optDouble("deep", 0.0)
                val rm = obj.optDouble("rem", 0.0)
                if (aw + li + dp + rm > 0.0) StageMins(aw, li, dp, rm) else null
            }
            trimmed.startsWith("[") -> {
                val arr = JSONArray(trimmed)
                var aw = 0.0; var li = 0.0; var dp = 0.0; var rm = 0.0
                for (i in 0 until arr.length()) {
                    val seg = arr.optJSONObject(i) ?: continue
                    val start = seg.optLong("start", -1)
                    val end = seg.optLong("end", -1)
                    if (end <= start) continue
                    val durMin = (end - start) / 60.0
                    when (seg.optString("stage")) {
                        "wake"  -> aw += durMin
                        "light" -> li += durMin
                        "deep"  -> dp += durMin
                        "rem"   -> rm += durMin
                    }
                }
                if (aw + li + dp + rm > 0.0) StageMins(aw, li, dp, rm) else null
            }
            else -> null
        }
    }.getOrNull()
}

/**
 * #today-hosted-cards: the pure trailing-14-night sleep-hours trend — hours + index-aligned day keys, the
 * SAME rows [buildSleepModel] derives `trendHours`/`trendDates` from. Nap-free (no debt/session data), so a
 * Today host can build it from `days` alone. Kept byte-identical to the inline logic in [buildSleepModel].
 */
internal fun sleepDurationTrend(days: List<DailyMetric>): Pair<List<Double>, List<String>> {
    val trendRows = days.filter { (it.totalSleepMin ?: 0.0) > 0.0 }.takeLast(14)
    val hours = trendRows.mapNotNull { it.totalSleepMin?.let { minutes -> minutes / 60.0 } }
    val dates = trendRows.map { it.day }
    return hours to dates
}

/**
 * Build the whole model from the cached daily metrics + the latest sleep session + the
 * export-verbatim sleep figures. Returns null when there is no usable latest night (no
 * stage minutes), which renders the empty state. All series are computed in one pass-set
 * here, matching the macOS buildModel(). Internal so SleepImportedFiguresTest can pin the
 * prefer-imported logic (the recoveryCalibrationNights test pattern).
 */
internal fun buildSleepModel(
    days: List<DailyMetric>,
    session: SleepSession?,
    imported: ImportedSleepSeries = ImportedSleepSeries(),
    selectedDay: String? = null,
    // The bridged main-night GROUP's summed stage minutes + full-night segments (#561), threaded from
    // selectNight so a biphasic night's hero shows the WHOLE night, not one fragment (#555). Null for a
    // single-block day → the session/DailyMetric path below is unchanged.
    heroStages: StageMins? = null,
    heroSegments: List<PersistedSegment>? = null,
    // Actual asleep minutes from blocks outside each day's canonical main-night group. They repay
    // debt without changing DailyMetric.totalSleepMin, which remains the Rest/headline main-night figure.
    napSleepMinByDay: Map<String, Double> = emptyMap(),
    // #sleep-consistency-parity: the full session list (onset times), used by the consistency FALLBACK
    // (bedtime-onset spread). Defaults empty for callers/tests that only exercise the imported path.
    sessions: List<SleepSession> = emptyList(),
    // Today's logical-day key, the anchor for each tile's staleness bound (see [metric]). Injectable so
    // tests can pin the clock instead of depending on the day they happen to run.
    todayKey: String = logicalDayKeyNow(),
): SleepModel? {
    val effectiveDay = selectedDay ?: days.lastOrNull()?.day ?: return null
    // The HERO night = the selected day's stage-bearing row. The TILE / debt / need / trend
    // window, by contrast, is the FULL history (latest-anchored) — matching iOS SleepView, which
    // builds every tile series + the debt ledger + the personal need from `repo.days` regardless
    // of which night the hero is browsing. Browsing a past night only re-points the hero, never
    // the at-a-glance tiles or the "Last 14 nights" ledger. One cross-platform definition. (#5)
    val latest = days.lastOrNull {
        it.day == effectiveDay && (it.deepMin ?: 0.0) + (it.remMin ?: 0.0) + (it.lightMin ?: 0.0) > 0.0
    }
        ?: return null

    // Prefer stage minutes from the session's (possibly reclipped) stagesJSON when it belongs
    // to this night — so a wake-time edit on an imported or computed night updates stage cards
    // (StagesVsTypical, Hypnogram footer) immediately without waiting on a rescore.
    val sessionStageMins = session
        ?.takeIf { AnalyticsEngine.dayString(it.endTs) == latest.day || localDayString(it.endTs) == latest.day }
        // #259: trim to the EFFECTIVE onset before summing, so a hand-edited bedtime the raw was too sparse
        // to re-stage (WHOOP 4.0) can't show pre-onset stages that push asleep past time-in-bed. No-op when
        // the session already starts at its onset (the common case). Matches the analytics-side clamp.
        ?.let { parseSessionStages(SleepStageTotals.clampStagesToOnset(it.stagesJSON, it.effectiveStartTs)) }
    val deep = heroStages?.deep ?: sessionStageMins?.deep ?: latest.deepMin ?: 0.0
    val rem = heroStages?.rem ?: sessionStageMins?.rem ?: latest.remMin ?: 0.0
    val light = heroStages?.light ?: sessionStageMins?.light ?: latest.lightMin ?: 0.0

    // Hero awake estimate works off ASLEEP minutes (totalSleepMin), never the in-bed window. The
    // old code substituted the edited session's (wake − onset) duration — TIME IN BED — for the
    // asleep figure here and across every per-tile pass, which inflated awake / hours-vs-needed /
    // debt vs the actual sleep. iOS never did this (it derives awake straight from the decoded
    // stage segments). Dropped for parity (#1/#7); a sleep edit now reaches the tiles via the
    // re-score path, not a display-time in-bed swap.
    val asleep = latest.totalSleepMin ?: (deep + rem + light)
    // Awake estimate: prefer (time-in-bed − asleep) implied by efficiency; else from
    // disturbances; matches the macOS "awake minutes" carried in the stagesJSON.
    val effFrac = latest.efficiency?.let { if (it > 1.0) it / 100.0 else it }
    val awake = when {
        effFrac != null && effFrac in 0.01..0.999 -> max(0.0, asleep / effFrac - asleep)
        latest.disturbances != null -> latest.disturbances * 6.0
        else -> 0.0
    }
    val stages = Stages(awake = awake, light = light, deep = deep, rem = rem)
    if (stages.total <= 0.0) return null

    // Typical = mean across ALL nights with data (full history, latest-anchored — never bounded
    // to the browsed night), mirroring iOS typicalTotalMin / typicalStageMin over repo.days.
    val typicalTotalMin = mean(days.mapNotNull { it.totalSleepMin }.filter { it > 0.0 })
    val typicalDeepMin = mean(days.mapNotNull { it.deepMin }.filter { it > 0.0 })
    val typicalRemMin = mean(days.mapNotNull { it.remMin }.filter { it > 0.0 })
    val typicalLightMin = mean(days.mapNotNull { it.lightMin }.filter { it > 0.0 })

    // Personal sleep need (minutes): mean asleep, floored at 7.5h (450 min).
    val needMin = max(450.0, typicalTotalMin ?: 450.0)

    // Per-tile metrics — each a full pass over the FULL day history (asleep totals, no in-bed
    // substitution), latest = the most-recent day. Mirrors iOS SleepView, where every tile series
    // is `metric { … }` over repo.days. Where the WHOOP export carried the figure verbatim
    // (metricSeries), it wins per day; the on-device recomputation fills the rest.
    val performance = metric(days, todayKey) { d ->
        imported.performance[d.day]                       // WHOOP's own 0–100 figure wins per day
            // else the REAL Rest composite (RestScorer.restFromDaily) — the SAME single source of
            // truth the Today Rest score, the metric-detail overlay (below) and iOS SleepView
            // (AnalyticsEngine.Rest.composite(daily:)) read. The old hours-vs-need proxy ceilinged
            // live 5.0 nights at 100% here while every other surface showed the ~85% composite (#298).
            ?: com.noop.analytics.RestScorer.restFromDaily(d)
    }
    val efficiency = metric(days, todayKey) { d ->
        d.efficiency?.let { if (it <= 1.0) it * 100.0 else it }
    }
    val consistency = run {
        // Prefer the imported sleep_consistency series, but only when it covers the latest
        // night — otherwise "latest" would silently be a months-old import-era value.
        val lastDay = days.lastOrNull()?.day
        if (lastDay != null && imported.consistency[lastDay] != null) {
            val series = days.mapNotNull { imported.consistency[it.day] }
            Metric(series.lastOrNull(), mean(series), series)
        } else {
            consistencySeries(sessions)
        }
    }
    val hoursVsNeeded = metric(days, todayKey) { d ->
        val need = imported.needMin[d.day] ?: needMin   // imported need wins per day
        d.totalSleepMin?.takeIf { it > 0.0 && need > 0.0 }?.let { it / need * 100.0 }
    }
    val restorative = metric(days, todayKey) { d ->
        val dp = d.deepMin; val rm = d.remMin; val sl = d.totalSleepMin
        if (dp != null && rm != null && sl != null && sl > 0.0) (dp + rm) / sl * 100.0 else null
    }
    val respiratory = metric(days, todayKey) { it.respRateBpm }
    val sleepDebt = run {
        val series = days.mapNotNull { d ->
            imported.debtMin[d.day]   // minutes, export-verbatim
                ?: SleepDebt.creditedSleepMin(d.totalSleepMin, napSleepMinByDay[d.day] ?: 0.0)
                    ?.takeIf { needMin > 0.0 }
                    ?.let { max(0.0, needMin - it) }   // APPROXIMATE fallback
        }
        Metric(series.lastOrNull(), mean(series), series)
    }

    // Trend set = the most-recent nights with data (asleep totals, full history — latest-anchored,
    // not the browsed night). Mirrors iOS's trailing trend over repo.days.
    val trendRows = days.filter { (it.totalSleepMin ?: 0.0) > 0.0 }.takeLast(14)
    val trendHours = trendRows.mapNotNull { it.totalSleepMin?.let { minutes -> minutes / 60.0 } }
    val trendNeedHours = trendRows.map { row -> ((imported.needMin[row.day] ?: needMin) / 60.0) }
    val trendDebtHours = trendRows.map { row ->
        val sleptMin = SleepDebt.creditedSleepMin(row.totalSleepMin, napSleepMinByDay[row.day] ?: 0.0) ?: 0.0
        val neededMin = imported.needMin[row.day] ?: needMin
        ((imported.debtMin[row.day] ?: max(0.0, neededMin - sleptMin)) / 60.0)
    }
    val trendDates = trendRows.map { it.day }

    // Real per-epoch timeline only when the merged session IS this night — UTC OR local-tz
    // end-day match (imported DailyMetric.day is local-tz while dayString is UTC, so a
    // near-midnight-UTC wake only matches via the local key; selectNight attributes the
    // night the same way). A non-matching session degrades safely to synthesis, never to
    // a wrong night. (#160)
    // Real timestamped segments (group when fragmented, else this session's) — kept whole for the FILLED
    // hypnogram, and flattened to (stage, minutes) weights for the classic proportional/rows view.
    val hypnogramSegments: List<PersistedSegment>? = heroSegments
        ?: session
            ?.takeIf {
                AnalyticsEngine.dayString(it.endTs) == latest.day || localDayString(it.endTs) == latest.day
            }
            ?.let { parsePersistedSegments(it.stagesJSON) }
    val realSegments = hypnogramSegments?.map { seg -> seg.stage to ((seg.end - seg.start) / 60f) }

    // Rolling 14-night sleep-debt ledger over the FULL day history (the analytics caps to the
    // most-recent 14 counted nights and skips no-data nights), using the SAME personal need the
    // tiles use (`needMin`, ≥ 7.5 h — the per-user override over the 8 h default). Full history,
    // not the browsed-night window: the ledger is a "Last 14 nights" at-a-glance summary that
    // matches the debt TILE (both read main-night totals plus separately decoded nap credit),
    // and mirrors iOS's debtLedger over repo.days. (#242, #5)
    val sleepDebtLedger = SleepDebt.ledger(
        series = days.map { d ->
            d.day to SleepDebt.creditedSleepMin(d.totalSleepMin, napSleepMinByDay[d.day] ?: 0.0)
        },
        needHours = needMin / 60.0,
    )

    return SleepModel(
        stages = stages,
        clockLabel = clockLabel(latest, session),
        efficiencyText = efficiency.latest?.let { "${it.roundToInt()}%" } ?: "—",
        performance = performance,
        efficiency = efficiency,
        consistency = consistency,
        hoursVsNeeded = hoursVsNeeded,
        restorative = restorative,
        respiratory = respiratory,
        sleepDebt = sleepDebt,
        typicalTotalMin = typicalTotalMin,
        typicalDeepMin = typicalDeepMin,
        typicalRemMin = typicalRemMin,
        typicalLightMin = typicalLightMin,
        trendHours = trendHours,
        trendNeedHours = trendNeedHours,
        trendDebtHours = trendDebtHours,
        trendDates = trendDates,
        realSegments = realSegments,
        hypnogramSegments = hypnogramSegments,
        sleepDebtLedger = sleepDebtLedger,
    )
}

/**
 * #940 no-blank fallback: one impossible/stage-less SELECTED day (typically the newest, after a bad
 * hand-edit staged it all-awake) must not hide the whole tab's full-history surfaces. Re-anchor the
 * model to the newest day that HAS stage minutes; the tiles / ledger / trends it feeds are
 * full-history by construction, so this only changes which day supplies the hero-independent
 * anchor. Null only when NO day carries stage data (the true first-run empty state). Internal so
 * SleepPhantomNightFallbackTest can pin the rule. Mirrors iOS buildModel's stage-less stub fallback.
 */
internal fun fallbackSleepModel(
    days: List<DailyMetric>,
    imported: ImportedSleepSeries = ImportedSleepSeries(),
    napSleepMinByDay: Map<String, Double> = emptyMap(),
    sessions: List<SleepSession> = emptyList(),
    todayKey: String = logicalDayKeyNow(),
): SleepModel? {
    val anchorDay = days.lastOrNull {
        (it.deepMin ?: 0.0) + (it.remMin ?: 0.0) + (it.lightMin ?: 0.0) > 0.0
    }?.day ?: return null
    return buildSleepModel(days, null, imported, selectedDay = anchorDay,
        napSleepMinByDay = napSleepMinByDay, sessions = sessions, todayKey = todayKey)
}

/**
 * #today-hosted-cards: the ONE loader that builds the shared [SleepModel] backing every SleepModel-derived
 * hosted sleep card in Today (Stages vs typical today; more to follow). It mirrors the Sleep tab's own
 * inputs step-for-step — the active∪canonical session union with the #241 richness merge, the learned
 * habitual midsleep, the imported metric series, and the nap-minutes-by-day map — then hands them to the
 * SAME [fallbackSleepModel] the Sleep tab uses (SleepScreen.kt), so a hosted card renders numbers
 * byte-identical to the Sleep tab. Returns null when no day has stage data (the first-run empty state).
 * Suspends (a handful of repo reads); call it from a keyed LaunchedEffect and cache the result, and only
 * when a SleepModel-backed card is actually hosted, so a Today with none pays no cost. Twin of the iOS
 * `LiquidTodayView` hostedSleepModel build.
 */
internal suspend fun buildHostedSleepModel(
    repo: WhoopRepository,
    activeStrapId: String,
    days: List<DailyMetric>,
): SleepModel? {
    val now = System.currentTimeMillis() / 1000L
    // Active∪canonical union + #241 richness merge, keyed by LOCAL wake-day — the SAME merge SleepScreen
    // does for its `sleeps` (imported-wins, stage-less imports yield to a computed day that has stages),
    // ordered by effective onset.
    val sleeps: List<SleepSession> = runCatching {
        val imported = repo.sleepSessionsUnion(activeStrapId, 0L, now)
        val computed = repo.computedSleepSessionsUnion(activeStrapId, 0L, now)
        fun localEndDay(ts: Long): String {
            val offsetSec = (java.util.TimeZone.getDefault().getOffset(ts * 1000) / 1000).toLong()
            return AnalyticsEngine.dayString(ts, offsetSec)
        }
        WhoopRepository.mergeSleepRichness(imported, computed) { localEndDay(it.endTs) }
            .sortedBy { it.effectiveStartTs }
    }.getOrDefault(emptyList())

    // Learned habitual midsleep (threads the active strap id, as SleepScreen does); null under threshold.
    val habitualMidsleep = runCatching { repo.habitualMidsleepSec(activeStrapId) }.getOrNull()

    // Imported headline series (the SAME ImportedSleepSeries the Sleep tab loads). metricSeries has no Flow.
    suspend fun load(key: String) = runCatching {
        repo.metricSeries("my-whoop", key, "0000-00-00", "9999-99-99")
    }.getOrDefault(emptyList()).associate { it.day to it.value }
    val imported = ImportedSleepSeries(
        performance = load("sleep_performance"),
        consistency = load("sleep_consistency"),
        needMin = load("sleep_need_min"),
        debtMin = load("sleep_debt_min"),
    )

    val napSleepMinByDay = napSleepMinutesByDay(sleeps, habitualMidsleep)
    return fallbackSleepModel(days, imported, napSleepMinByDay, sessions = sleeps)
}

/**
 * Build a metric from a per-day transform, keeping only finite values.
 *
 * `latest` is STALENESS-BOUNDED ([Baselines.vitalCarryDays]): it is the newest value only while that
 * value's own day is recent enough to still be presented as this night's reading, and null otherwise.
 * Unbounded, `series.lastOrNull()` reached back arbitrarily far — a respiratory rate last written by a
 * WHOOP CSV import on 30 Jul kept rendering as "Respiratory 15.6" in the Night detail card a fortnight
 * later, with no date anywhere beside it. `typical` and `series` stay UNBOUNDED on purpose: they are
 * explicitly historical (the trend line and the "vs typical" mean span the whole history); only the
 * headline number claims to be current. Byte-twin of the Swift `SleepModel.metric`.
 */
private fun metric(
    days: List<DailyMetric>,
    todayKey: String = logicalDayKeyNow(),
    transform: (DailyMetric) -> Double?,
): Metric {
    val points = days.mapNotNull { d ->
        transform(d)?.takeIf { it.isFinite() }?.let { d.day to it }
    }
    val series = points.map { it.second }
    return Metric(Baselines.freshestCarried(points, todayKey)?.second, mean(series), series)
}

/**
 * Consistency per night from the rolling BEDTIME-ONSET spread — the real "sleep consistency" (steadier
 * bed times → higher score), now reconstructed from the session onset timestamps (`sessions`) rather than
 * the old duration proxy that read only `days`. Byte-identical to iOS `SleepView.consistencySeries` so the
 * tile shows the SAME number on both platforms (#sleep-consistency-parity). The imported `sleep_consistency`
 * series still wins when present; this is the strap-only fallback.
 */
internal fun consistencySeries(sessions: List<SleepSession>): Metric {
    // Byte-identical to iOS SleepView.consistencySeries (#sleep-consistency-parity): BEDTIME-ONSET
    // regularity, not the old duration proxy. Each session's local bed-minute (hour*60+min, evening
    // onsets wrapped +24h) over a trailing-14 SD → 100*(1 - sd/120). Sessions are ordered by startTs to
    // match iOS's repo.sleeps ordering (the onset VALUE uses effectiveStartTs = startTsAdjusted ?: startTs).
    val cal = Calendar.getInstance()
    fun bedMinutes(effectiveStartTs: Long): Double {
        cal.timeInMillis = effectiveStartTs * 1000L
        var m = (cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)).toDouble()
        if (m < 12 * 60) m += 24 * 60   // wrap evening onsets into one continuous scale
        return m
    }
    val mins = sessions.sortedBy { it.startTs }.map { bedMinutes(it.effectiveStartTs) }
    if (mins.size < 3) return Metric(null, null, emptyList())
    val scores = ArrayList<Double>()
    for (i in mins.indices) {
        val lo = max(0, i - 13)
        val window = mins.subList(lo, i + 1)
        if (window.size < 3) continue
        val m = window.average()
        val variance = window.sumOf { (it - m) * (it - m) } / window.size
        val sd = Math.sqrt(variance)
        // 120 min of onset SD maps to a 0 score; tighter routines climb to 100.
        scores.add((100.0 * (1.0 - sd / 120.0)).coerceIn(0.0, 100.0))
    }
    return Metric(scores.lastOrNull(), mean(scores), scores)
}

private fun mean(vals: List<Double>): Double? = if (vals.isEmpty()) null else vals.sum() / vals.size

// MARK: - Stage segment reconstruction (durations only — same architecture as macOS)

/**
 * Lay the stage minutes end-to-end as proportional hypnogram segments: light → deep →
 * light → rem → light → awake (deep early, REM later, awake last). Weights are minutes;
 * the Hypnogram normalizes them to width.
 */
internal fun stageSegments(s: Stages): List<Pair<String, Float>> {
    val out = ArrayList<Pair<String, Float>>()
    fun add(name: String, minutes: Double) {
        if (minutes > 0.0) out.add(name to minutes.toFloat())
    }
    add("light", s.light * 0.4)
    add("deep", s.deep)
    add("light", s.light * 0.3)
    add("rem", s.rem)
    add("light", s.light * 0.3)
    add("awake", s.awake)
    return out
}
