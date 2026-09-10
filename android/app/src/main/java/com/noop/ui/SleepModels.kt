package com.noop.ui

import com.noop.R
import com.noop.analytics.SleepDebtLedger
import com.noop.data.SleepSession

/** Stage minutes for a single night (mirrors the macOS Stages struct). */
internal data class Stages(
    val awake: Double,
    val light: Double,
    val deep: Double,
    val rem: Double,
) {
    /** Total time in bed (includes awake). */
    val total: Double get() = awake + light + deep + rem

    /** Asleep time = total minus awake. */
    val asleep: Double get() = light + deep + rem
}

/** (latest, latestDay, typical mean, full history) per metric — mirrors the macOS Metric tuple.
 *  `latestDay` is the yyyy-MM-dd the `latest` value was carried from (null when there is no latest
 *  value, or when the latest value IS today's). #1946: a carried prior-day value is stamped with its
 *  day so it is not passed off as tonight's read. */
internal data class Metric(
    val latest: Double?,
    val latestDay: String?,
    val typical: Double?,
    val series: List<Double>,
) {

    companion object {
        /** #1946: the caption for a metric tile whose `latest` value was carried from a prior day.
         *  Returns null when the value is NOT carried (today's own, or no value) so the caller falls
         *  through to the normal "vs typical" caption. When carried, returns a [DisplayText.Resource]
         *  so the string lives in `strings.xml` where the i18n audit and the locale files can see it
         *  — matching [carriedCaption] in TodayScoring, which solved the same problem for the Today
         *  carry stamp. Mirror EXACTLY in Swift. */
        fun carriedMetricCaption(latestDay: String?, latest: Double?): DisplayText? {
            if (latestDay == null || latest == null) return null
            return DisplayText.Resource(
                R.string.sleep_carried_metric_caption,
                listOf(shortDayLabel(latestDay)),
            )
        }

        /** "12 Jul" for a "yyyy-MM-dd" key — the SAME format the Today carry stamp uses, so a carried
         *  Rest on Today and a carried metric on Sleep read identically. */
        private val dayKeyParser = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).apply {
            timeZone = java.util.TimeZone.getTimeZone("UTC")
        }

        fun shortDayLabel(key: String): String {
            val date = runCatching { dayKeyParser.parse(key) }.getOrNull() ?: return key
            val f = java.text.SimpleDateFormat("d MMM", java.util.Locale.getDefault())
            return f.format(date)
        }
    }
}

/** Export-verbatim per-day sleep figures (metricSeries keys mirroring macOS WhoopImporter). */
internal data class ImportedSleepSeries(
    val performance: Map<String, Double> = emptyMap(), // sleep_performance, 0–100
    val consistency: Map<String, Double> = emptyMap(), // sleep_consistency, 0–100
    val needMin: Map<String, Double> = emptyMap(),     // sleep_need_min, minutes
    val debtMin: Map<String, Double> = emptyMap(),     // sleep_debt_min, minutes
)

/** Everything the screen renders, derived once per data change. */
internal data class SleepModel(
    val stages: Stages,
    val clockLabel: String,
    val efficiencyText: String,
    val performance: Metric,
    val efficiency: Metric,
    val consistency: Metric,
    val hoursVsNeeded: Metric,
    val restorative: Metric,
    val respiratory: Metric,
    val sleepDebt: Metric,
    val typicalTotalMin: Double?,
    val typicalDeepMin: Double?,
    val typicalRemMin: Double?,
    val typicalLightMin: Double?,
    val trendHours: List<Double>,
    val trendNeedHours: List<Double>,
    val trendDebtHours: List<Double>,
    val trendDates: List<String>,
    /** Persisted per-epoch segments as ordered (stage, minutes) weights — the REAL
     *  hypnogram (on-device APPROXIMATE staging) — or null → synthesized fallback. */
    val realSegments: List<Pair<String, Float>>?,
    /** The SAME real segments but with their wall-clock start/end kept, for the opt-in FILLED
     *  stepped hypnogram (#sleep-chart-style) which plots stages at real times. Null when the night
     *  has no timestamped segments (then FILLED falls back to the classic view). */
    val hypnogramSegments: List<PersistedSegment>?,
    /** Rolling 14-night sleep-debt ledger: Σ(slept − personal need) across the recent
     *  fortnight, with the per-night deltas behind it. Computed once per data change. (#242) */
    val sleepDebtLedger: SleepDebtLedger,
)

/** The night the ◀/▶ chevrons selected: its MAIN session, the day-metric key it resolves to, its
 *  persisted per-epoch weights (or null), the "EEE d MMM · HH:mm–HH:mm" clock, and the day's other
 *  blocks (naps / split-sleep) for the naps card. (#160, #518) */
internal data class HeroNight(
    val session: SleepSession,
    val dayKey: String,
    val realSegments: List<Pair<String, Float>>?,
    val clockLabel: String,
    val napBlocks: List<SleepSession> = emptyList(),
    // The bridged main-night GROUP (#561): summed stage minutes + the full-night segments, when the night
    // is more than one fragment. `session` above stays the single WINNING block (the edit anchor); these
    // let buildSleepModel render the WHOLE night instead of one fragment (#555). Null for a single-block day.
    val groupStages: StageMins? = null,
    val groupSegments: List<PersistedSegment>? = null,
    // Per-epoch MOTION for the main-night GROUP (#407), laid fragment-by-fragment in the SAME order the
    // group's stage segments are laid. Empty when no group fragment has a persisted motionJSON (older rows)
    // → the hero shows an honest empty state instead of a fabricated zero trace. Read off the already-
    // resolved group, NOT a re-resolution of the night.
    val groupMotion: List<Double> = emptyList(),
    // Time-in-bed for the whole main-night GROUP (#561): Σ(endTs − effectiveStartTs) across the
    // hero fragments, in minutes. The hero subtitle previously derived in-bed from `session` alone
    // (the single WINNING fragment), so a fragmented night's "Xh in bed" undershot the stage total
    // it sat next to. Summing fragment windows (NOT wall-clock first-onset→last-wake) excludes the
    // inter-fragment awake gaps, mirroring sumGroupStages/AnalyticsEngine, so asleep ≤ in-bed and
    // the efficiency shown beside it stays coherent. Null for a single-block day → the hero keeps
    // its session-window / stage-total fallbacks.
    val groupInBedMin: Double? = null,
    // The whole bridged night's clock WINDOW (#345): the displayed bedtime (first non-stub fragment's
    // onset, #736) to the group's latest wake — the same pair `clockLabel` above is built from, carried
    // as timestamps so the Asleep/Woke row + the hypnogram axis can use them. On a split night `session`
    // (the single WINNING fragment, kept as the edit anchor) can end mid-night, so reading ITS endTs
    // made the WOKE time + the axis contradict the header pill and the group hypnogram. iOS needs no
    // analogue: its merged Night synthesizes a group-spanning session (mergeDay's `synth`), so its
    // window row and axis were already whole-night. Null only via the default → session fallback.
    val heroOnsetTs: Long? = null,
    val heroWakeTs: Long? = null,
    // The bridged night's fragments themselves (#1492). `session` is only the winning one, so an edit
    // anchored to it moved neither displayed bound on a split night. The editor frames itself on this
    // list — seeding, coverage-testing and writing across the whole night — instead of one block of it.
    val heroGroup: List<SleepSession> = emptyList(),
)

/** What the hero card draws for the selected night — null means no usable stage data
 *  (renders the honest "No stage data recorded for this night." fallback). (#160) */
internal data class HeroDisplay(
    val stages: Stages,
    val realSegments: List<Pair<String, Float>>?,
    /** Timestamped segments for the opt-in FILLED hypnogram (#sleep-chart-style); null → classic fallback. */
    val hypnogramSegments: List<PersistedSegment>?,
    val efficiencyText: String,
)

internal data class StageMins(val awake: Double, val light: Double, val deep: Double, val rem: Double)
