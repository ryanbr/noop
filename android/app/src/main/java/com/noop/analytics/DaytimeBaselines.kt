package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.RrInterval

/*
 * DaytimeBaselines.kt — the CALLER-side folding path that turns a person's past DAYTIME history
 * into the personal rolling baselines DaytimeStress.analyze(mode = BaselineRelative(hr, rmssd))
 * scores today's waking hours against.
 *
 * Faithful Kotlin port of StrandAnalytics/DaytimeBaselines.swift (an extension on DaytimeStress;
 * here a sibling object so it can reuse DaytimeStress's internal bucketing helpers).
 *
 * BaselineRelative (see DaytimeStress.ScoringMode) is deliberately caller-fed: the scorer takes a
 * finished BaselineState and never fetches history itself. This is that missing caller — it
 * computes ONE daytime aggregate per past day and folds the ordered series through the SAME
 * Winsorized-EWMA machinery (Baselines.foldHistory) the nightly resting-HR / HRV baselines use,
 * with the daytime-specific Baselines.daytimeHRCfg / daytimeRMSSDCfg configs.
 *
 * The per-day aggregate is defined in terms of EXACTLY the hourly means the scorer references: it
 * reuses DaytimeStress's own floorDiv / bucketSeconds / isWakingHour / minHourHrSamples /
 * HrvAnalyzer so "the value we fold into the baseline" and "the value we later z-score against that
 * baseline" are the same quantity, never two drifting definitions.
 */
object DaytimeBaselines {

    // MARK: - Per-day daytime aggregate

    /**
     * Percentile of a day's waking-hour mean HRs used as that day's daytime-HR aggregate: the 10th,
     * i.e. the CALM FLOOR ("how low does my HR run when I'm calm and awake"). VALIDATED — this is
     * the ~65 bpm pooled figure from the 26-day Oura-reference correlation behind
     * DaytimeStress.baselineRelativeHighMarginBPM. It is intentionally the floor (not the median)
     * because the HR term pairs it with a FIXED bpm margin (a large effective spread via
     * marginToSigma), so anchoring at the floor makes "floor + margin" the exact HIGH cutoff.
     */
    const val daytimeHRAggregatePercentile: Double = 0.10

    /**
     * Percentile of a day's waking-hour RMSSDs used as that day's daytime-RMSSD aggregate: the 50th
     * (MEDIAN / typical), NOT the symmetric calm-ceiling percentile. The asymmetry with HR above is
     * deliberate and load-bearing: the RMSSD term is scaled by the person's OWN spread
     * (Baselines.sigma), not a fixed margin, so (baseline − hourRMSSD) / σ is only meaningful when
     * baseline is the TYPICAL daytime RMSSD — then a typical hour reads neutral and only genuine HRV
     * suppression reads stressed. Anchoring at a calm-ceiling percentile (the direct mirror of HR's
     * floor) would make an ordinary median hour sit ~1–2σ "below baseline" and stack a large false
     * stress term on top of the HR term. TUNING SEAM: like every RMSSD figure in this mode, the
     * median choice is a first pass pending an HR+HRV validation pass (the validated study was
     * HR-only).
     */
    const val daytimeRMSSDAggregatePercentile: Double = 0.50

    /**
     * One local day's waking HR + R-R streams, the input to the daytime-baseline fold. [hr]/[rr]
     * carry wall-clock ts; [tzOffsetSeconds] (seconds east of UTC for THAT day) places them on the
     * local clock exactly as DaytimeStress.analyze's tzOffsetSeconds does, so DST-varying days can
     * each carry their own offset.
     */
    data class DaytimeDayStreams(
        val hr: List<HrSample>,
        val rr: List<RrInterval>,
        val tzOffsetSeconds: Long,
    )

    /** One day's daytime aggregates. Either field is null independently. */
    data class DayAggregate(val hr: Double?, val rmssd: Double?)

    /** A folded personal daytime baseline pair; [rmssd] is null when withheld (thin history). */
    data class DaytimeBaselineStates(val hr: BaselineState, val rmssd: BaselineState?)

    /**
     * One day's daytime aggregates, computed with the SCORER's own hourly bucketing so the folded
     * value matches what BaselineRelative later references:
     *   - hr: the [daytimeHRAggregatePercentile] (P10) of the day's WAKING-hour mean HRs, where each
     *     hour's mean HR is gated at DaytimeStress.minHourHrSamples exactly like the scorer (a
     *     sparse/imported day whose hours never clear the gate yields null — it contributes no
     *     daytime-HR floor, honestly).
     *   - rmssd: the [daytimeRMSSDAggregatePercentile] (P50) of the day's WAKING-hour RMSSDs, each
     *     run through the same HrvAnalyzer.analyzeRaw cleaner the scorer uses (so ectopic beats
     *     can't fabricate variability); null when no waking hour had enough clean R-R.
     * Bucketing keys off the HR buckets (like the scorer), so an hour with R-R but no HR contributes
     * neither.
     */
    fun dayDaytimeAggregate(hr: List<HrSample>, rr: List<RrInterval>, tzOffsetSeconds: Long): DayAggregate {
        if (hr.isEmpty()) return DayAggregate(null, null)

        // Bucket HR + R-R into LOCAL hour-of-day buckets, byte-for-byte the scorer's step 1.
        val hrByBucket = HashMap<Long, MutableList<Double>>()
        for (s in hr) {
            val local = s.ts + tzOffsetSeconds
            val bucket = DaytimeStress.floorDiv(local, DaytimeStress.bucketSeconds) * DaytimeStress.bucketSeconds
            hrByBucket.getOrPut(bucket) { ArrayList() }.add(s.bpm.toDouble())
        }
        val rrByBucket = HashMap<Long, MutableList<Double>>()
        for (s in rr) {
            val local = s.ts + tzOffsetSeconds
            val bucket = DaytimeStress.floorDiv(local, DaytimeStress.bucketSeconds) * DaytimeStress.bucketSeconds
            rrByBucket.getOrPut(bucket) { ArrayList() }.add(s.rrMs.toDouble())
        }

        // Per WAKING hour: the gated mean HR + the cleaned RMSSD, mirroring the scorer's step 2 +
        // waking filter. Keyed off HR buckets so an R-R-only hour is ignored exactly as the scorer
        // ignores it.
        val wakingMeanHRs = ArrayList<Double>()
        val wakingRMSSDs = ArrayList<Double>()
        for ((bucket, hrs) in hrByBucket) {
            if (!DaytimeStress.isWakingHour(bucket)) continue
            if (hrs.size >= DaytimeStress.minHourHrSamples) {
                DaytimeStress.mean(hrs)?.let { wakingMeanHRs.add(it) }
            }
            HrvAnalyzer.analyzeRaw(rrByBucket[bucket] ?: emptyList()).rmssd?.let { wakingRMSSDs.add(it) }
        }

        val hrAgg = if (wakingMeanHRs.isEmpty()) null
            else DaytimeStress.quantile(wakingMeanHRs.sorted(), daytimeHRAggregatePercentile)
        val rmssdAgg = if (wakingRMSSDs.isEmpty()) null
            else DaytimeStress.quantile(wakingRMSSDs.sorted(), daytimeRMSSDAggregatePercentile)
        return DayAggregate(hrAgg, rmssdAgg)
    }

    // MARK: - Fold the trailing history into personal baselines

    /**
     * Fold a person's trailing per-day daytime streams (OLDEST → NEWEST, TODAY EXCLUDED — today is
     * the day being scored, not part of its own baseline) into the personal baselines
     * BaselineRelative consumes.
     *
     * Each day contributes one [dayDaytimeAggregate]; the ordered series is replayed through
     * Baselines.foldHistory (the identical Winsorized-EWMA path as the nightly baselines) with
     * daytimeHRCfg / daytimeRMSSDCfg. null aggregates (sparse/HR-only days) become skip-and-hold
     * nights, exactly like a missing nightly value.
     *
     * The HR baseline is always returned (it may be calibrating; the caller checks usable to decide
     * whether to use BaselineRelative at all). The RMSSD baseline is returned ONLY when it is usable
     * (≥ Baselines.minNightsSeed days actually carried a daytime RMSSD); otherwise null, so the
     * scorer honestly runs HR-only rather than z-scoring against a 1–2-day, untrustworthy HRV
     * baseline — the whole-baseline grain of the per-hour graceful-null already in rawScore.
     */
    fun foldDaytimeBaselines(days: List<DaytimeDayStreams>): DaytimeBaselineStates {
        val hrAggs = ArrayList<Double?>(days.size)
        val rmssdAggs = ArrayList<Double?>(days.size)
        for (d in days) {
            val agg = dayDaytimeAggregate(d.hr, d.rr, d.tzOffsetSeconds)
            hrAggs.add(agg.hr)
            rmssdAggs.add(agg.rmssd)
        }
        val hrState = Baselines.foldHistory(hrAggs, Baselines.daytimeHRCfg)
        val rmssdState = Baselines.foldHistory(rmssdAggs, Baselines.daytimeRMSSDCfg)
        return DaytimeBaselineStates(hrState, if (rmssdState.usable) rmssdState else null)
    }

    /**
     * The scoring mode to hand DaytimeStress.analyze for TODAY, decided from the trailing daytime
     * [days] history: BaselineRelative once the personal HR baseline is usable (≥
     * Baselines.minNightsSeed days of real daytime HR aggregates — the Oura-style, validated-r≈0.6
     * path), else DayRelative (the unchanged default). This is the single graceful-degradation gate:
     * a cold start, or a trailing window that is all sparse/imported days, keeps EXACTLY today's
     * pre-existing day-relative behaviour.
     */
    fun scoringMode(days: List<DaytimeDayStreams>): DaytimeStress.ScoringMode {
        val baselines = foldDaytimeBaselines(days)
        if (!baselines.hr.usable) return DaytimeStress.ScoringMode.DayRelative
        // RMSSD stays out of the LIVE score until it has its own validation pass — see
        // DaytimeStress.daytimeRMSSDScoringEnabled. The baseline is still folded above (so the
        // machinery + tests exercise the real path); it just doesn't reach scoring while gated off.
        val rmssd = if (DaytimeStress.daytimeRMSSDScoringEnabled) baselines.rmssd else null
        return DaytimeStress.ScoringMode.BaselineRelative(baselines.hr, rmssd)
    }
}
