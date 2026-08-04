package com.noop.analytics

import java.util.Locale
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * "~X days left" for a strap, worked out from its battery state-of-charge (SoC) history (#713). Neither
 * the WHOOP app nor WHOOP's API ever give you a runtime estimate, but NOOP already banks a SoC time
 * series from the strap over BLE, so no manual logging is needed. We fit the recent DISCHARGE slope and
 * divide the current charge by it. When the discharge run is too short or too flat to trust, we fall back
 * to the device's typical full-charge life for its generation.
 *
 * The measured slope already bakes in how the user actually runs their strap (HR broadcast, strain,
 * recording), so there are no hand-tuned usage multipliers. The discharge curve IS the personalisation.
 *
 * Honest about the limits: battery drain is non-linear (faster near full and near empty) and the strap
 * reports SoC sparsely, so this is an estimate, not a guarantee. Behaviour-identical twin of the Swift
 * BatteryEstimator (same fixtures, same numbers).
 */
object BatteryEstimator {

    /** Typical full-charge life in hours per WHOOP generation, used before enough of the user's own
     *  discharge has been seen to fit a slope. WHOOP 4.0 is about 4.5 days, WHOOP 5.0 / MG about 12 days
     *  (the figures cited in #713). The caller maps its connected strap to one of these. */
    const val ratedLifeHoursWhoop4 = 108.0   // 4.5 days
    const val ratedLifeHoursWhoop5 = 288.0   // 12 days

    /** A discharge run has to span at least this long AND drop at least this much before its measured
     *  slope is trusted over the rated fallback. Short or noisy spans produce wild rates. */
    const val minSpanHours = 2.0
    const val minDropPct = 2.0

    /** A SoC rise larger than this (percentage points) between two consecutive readings marks a CHARGE.
     *  The discharge run restarts after it, so we never fit a rate across a charge. */
    const val chargeStepPct = 1.0

    /** A charge only ANCHORS a fresh discharge run when it returns the strap NEAR FULL (#8). A mere partial
     *  top-up (e.g. 40% -> 55% on a quick desk charge) used to reset the run exactly like a 0% -> 100%
     *  charge, discarding the long clean discharge history before it and inflating "days left" off the short
     *  post-top-up tail. So a rise is treated as a run-reset anchor only when the post-rise SoC reaches this;
     *  a partial top-up is instead stepped over, and the fit prefers the longer pre-top-up discharge segment. */
    const val nearFullPct = 90.0

    /** Where the drain rate came from: the user's own measured discharge, or the rated fallback. */
    enum class Source { MEASURED, RATED }

    data class Estimate(
        /** Estimated hours of runtime left at the latest reading. */
        val remainingHours: Double,
        val source: Source,
        /** The latest SoC the estimate is anchored to, in percent. */
        val currentSoc: Double,
    ) {
        /** Convenience for callers that just want the days figure. */
        val daysRemaining: Double get() = remainingHours / 24
        /** Mirror so callers can read either name. */
        val hoursRemaining: Double get() = remainingHours
    }

    /**
     * Estimate remaining runtime from a SoC series.
     *
     * [samples] = (unix-seconds, SoC%) pairs in any order. The caller drops nil-SoC rows and maps the
     * banked battery series into this shape. [ratedHours] = the strap's typical full-charge life, one of
     * the `ratedLifeHours…` constants, chosen by the caller from the connected strap's generation.
     * Returns null only when there isn't a single reading to anchor to. Mirrors the Swift estimate().
     */
    fun estimate(samples: List<Pair<Long, Double>>, ratedHours: Double): Estimate? {
        val sorted = samples.sortedBy { it.first }
        val last = sorted.lastOrNull() ?: return null
        val current = last.second

        // The discharge segment whose slope we fit: anchored at the most recent NEAR-FULL charge, and ending
        // before any later partial top-up, so neither a charge earlier in the buffer nor a quick desk top-up
        // distorts the fitted slope (#8).
        val dischargeRun = dischargeFitWindow(sorted)

        // Fit the discharge slope over the segment as a simple endpoints rate (%/h). The series is short and
        // monotone-ish within a segment, so endpoints are as good as a least-squares line and far cheaper,
        // and they keep the test fixtures exact. null when it's too short, too flat, or not discharging. The
        // estimate stays anchored to `current` (the latest SoC), even when the fit window ends earlier.
        val measuredRate: Double? = run {
            if (dischargeRun.size < 2) return@run null
            val first = dischargeRun.first()
            val lastRun = dischargeRun.last()
            val spanHours = (lastRun.first - first.first) / 3600.0
            val drop = first.second - lastRun.second
            if (spanHours < minSpanHours || drop < minDropPct) return@run null
            val rate = drop / spanHours
            if (rate > 0) rate else null
        }

        val rate = measuredRate ?: (100.0 / maxOf(ratedHours, 1.0))
        val remaining = maxOf(0.0, current) / rate
        // #99: cap scaled to the CURRENT SoC, not a flat multiple of the FULL rated life. The old
        // `ratedHours * 1.5` ignored SoC, so a too-slow measured slope at low charge (idle/off-wrist spans,
        // sparse 5/MG SoC readings) extrapolated 9% to ~3 days — more than a full 12-day MG charge. You can't
        // realistically stretch the rated per-% runtime past ~1.5x, so bound to that scaled to `current`%.
        val clamped = minOf(remaining, ratedHours * 1.5 * (maxOf(0.0, current) / 100.0))
        return Estimate(clamped, if (measuredRate != null) Source.MEASURED else Source.RATED, current)
    }

    /**
     * The slice of the sorted SoC series whose endpoints we fit the discharge slope on (#8). Two rules,
     * both keyed off "is this rise a real charge or a partial top-up":
     *  1. START at the most recent NEAR-FULL charge: the most recent rise > chargeStepPct that LANDS at
     *     >= nearFullPct. A partial top-up (rise that doesn't reach near-full) is NOT an anchor: the scan
     *     steps over it and keeps looking further back, so a quick 40->55 desk charge no longer throws away
     *     the long clean discharge before it. If there is no near-full charge in the buffer, start = 0.
     *  2. END before the most recent partial top-up that falls AFTER the start anchor (a rise > chargeStepPct
     *     that does NOT reach near-full), so the fitted slope is the longer pre-top-up discharge segment,
     *     never the short, slope-flattening post-top-up tail.
     * `current` (the latest SoC the estimate is anchored to) is taken by the caller from the series end, not
     * from this window, so trimming the tail changes only the slope, never the SoC the runtime divides into.
     * Pure; the Swift twin is `dischargeFitWindow`.
     */
    fun dischargeFitWindow(sorted: List<Pair<Long, Double>>): List<Pair<Long, Double>> {
        if (sorted.size < 2) return sorted

        // 1. Most recent NEAR-FULL charge anchors the run start; partial top-ups are stepped over.
        var startIdx = 0
        for (i in sorted.size - 1 downTo 1) {
            if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second >= nearFullPct) {
                startIdx = i
                break
            }
        }

        // 1b. #919: with no near-full (>=90%) charge to anchor on - common on a 12-day WHOOP 5.0 that rarely
        //     tops past 90% between charges - anchor at the HIGHEST SoC (the top of the most recent
        //     discharge) rather than the oldest reading, which can sit below a later charge and net to a
        //     NON-discharge window (drop < 0 -> stuck on rated). The max is >= every later reading, so the
        //     window can only discharge; the >=minDropPct gate still rejects a flat run. Preserves #8: its
        //     buffer starts at the max, so this stays index 0 there. Last occurrence of the max (>=).
        //     #99: that max search used to scan the WHOLE buffer, so a strap that tops up short of full
        //     every day (never tripping rule 1) could anchor on a peak several CYCLES back, netting the fit
        //     across multiple undetected intermediate top-ups and flattening the slope into something that
        //     no longer reflects how the strap is actually draining "today". Bounding the search to at most
        //     the last two charge-step cycles keeps it anchored to the CURRENT usage pattern; a buffer with
        //     0 or 1 charge-steps searches from the start exactly as before (#8, #919 unaffected).
        if (startIdx == 0) {
            val chargeStepIdxs = mutableListOf<Int>()
            for (i in 1 until sorted.size) {
                if (sorted[i].second > sorted[i - 1].second + chargeStepPct) chargeStepIdxs.add(i)
            }
            val searchFloor = if (chargeStepIdxs.size >= 2) chargeStepIdxs[chargeStepIdxs.size - 2] else 0
            var maxIdx = searchFloor
            for (i in searchFloor until sorted.size) if (sorted[i].second >= sorted[maxIdx].second) maxIdx = i
            startIdx = maxIdx
        }

        // 2. End before the most recent PARTIAL top-up after the start anchor (a rise > chargeStepPct that
        //    does NOT reach near-full), so the fit prefers the longer pre-top-up discharge segment.
        var endIdx = sorted.size - 1
        if (endIdx - startIdx >= 1) {
            for (i in sorted.size - 1 downTo startIdx + 1) {
                if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second < nearFullPct) {
                    endIdx = i - 1
                    break
                }
            }
        }
        if (endIdx <= startIdx) return sorted.subList(startIdx, sorted.size)
        return sorted.subList(startIdx, endIdx + 1)
    }

    /**
     * Side-effect-free diagnostic twin of [estimate]: returns the SAME Estimate plus a list of trace
     * lines describing the full (t, soc) series, the detected charge step(s), the trailing discharge run
     * start/span/drop, the fitted slope, and which gate (minSpanHours / minDropPct) decided source =
     * measured vs rated. The Battery test mode gates this behind TestCentre.active(BATTERY); when the mode
     * is off it is never called, so there is zero cost. Pure: no clock, no I/O. Twin of the Swift trace.
     */
    fun estimateTrace(samples: List<Pair<Long, Double>>, ratedHours: Double):
        Pair<Estimate?, List<String>> {
        val sorted = samples.sortedBy { it.first }
        val last = sorted.lastOrNull()
        val first0 = sorted.firstOrNull()
        if (last == null || first0 == null) {
            return null to listOf("battery series=0 readings, no reading to anchor to")
        }
        val lines = mutableListOf<String>()
        lines.add("battery series=${sorted.size} readings span ${first0.first}..${last.first}s")
        for (s in sorted) lines.add("battery read t=${s.first}s soc=${soc(s.second)}")

        // The most recent NEAR-FULL charge anchors the run start (same scan as estimate, #8); a partial
        // top-up does NOT anchor and is reported separately below.
        var startIdx = 0
        if (sorted.size >= 2) {
            for (i in sorted.size - 1 downTo 1) {
                if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second >= nearFullPct) {
                    startIdx = i
                    val rise = sorted[i].second - sorted[i - 1].second
                    lines.add("battery chargeStep at t=${sorted[i].first}s +${soc(rise)}pp " +
                        "(>chargeStepPct ${soc(chargeStepPct)})")
                    break
                }
            }
        }
        // The most recent PARTIAL top-up after the anchor (a rise that does NOT reach near-full): the fit
        // ends before it and prefers the longer pre-top-up discharge segment (#8).
        if (sorted.size >= 2 && startIdx < sorted.size - 1) {
            for (i in sorted.size - 1 downTo startIdx + 1) {
                if (sorted[i].second > sorted[i - 1].second + chargeStepPct && sorted[i].second < nearFullPct) {
                    val rise = sorted[i].second - sorted[i - 1].second
                    lines.add("battery partialTopUp at t=${sorted[i].first}s +${soc(rise)}pp " +
                        "(<nearFullPct ${soc(nearFullPct)}) -> fit pre-top-up segment")
                    break
                }
            }
        }
        val run = dischargeFitWindow(sorted)

        var spanPass = false
        var dropPass = false
        if (run.size >= 2) {
            val runFirst = run.first()
            val runLast = run.last()
            val spanHours = (runLast.first - runFirst.first) / 3600.0
            val drop = runFirst.second - runLast.second
            lines.add("battery dischargeRun start=${runFirst.first}s " +
                "span=${hrs(spanHours)}h drop=${soc(drop)}pp")
            spanPass = spanHours >= minSpanHours
            dropPass = drop >= minDropPct
            if (spanPass && dropPass && drop / spanHours > 0) {
                lines.add("battery slope=${slope(drop / spanHours)}pct/h fitted from run endpoints")
            }
        } else {
            lines.add("battery dischargeRun too short to fit (run=${run.size} readings)")
        }

        val measured = spanPass && dropPass && run.size >= 2 &&
            (run.first().second - run.last().second) /
            ((run.last().first - run.first().first) / 3600.0) > 0
        lines.add("battery gate minSpanHours ${hrs(minSpanHours)} " +
            "${if (spanPass) "PASS" else "FAIL"}, minDropPct ${soc(minDropPct)} " +
            "${if (dropPass) "PASS" else "FAIL"} -> source=${if (measured) "measured" else "rated"}")

        return estimate(samples, ratedHours) to lines
    }

    private fun soc(v: Double) = String.format(Locale.US, "%.1f", v)
    private fun hrs(v: Double) = String.format(Locale.US, "%.1f", v)
    private fun slope(v: Double) = String.format(Locale.US, "%.1f", v)

    /** Display rule from #713: hours under 48h ("~14h"), days above ("~4.5 days"). Unit text only, the UI
     *  adds the "left" / "remaining" copy. Locale-fixed so the tests stay stable. */
    fun label(hours: Double): String =
        if (hours < 48) "~${hours.roundToLong()}h"
        else "~${String.format(Locale.US, "%.1f", hours / 24)} days"

    // ---- Predictive low-battery alert policy ----

    /** Fire the runtime alert when the estimate drops to this many hours of remaining life. A fixed
     *  SoC threshold gives wildly different lead time per strap generation (15% is ~16 h on a 4.0 but
     *  ~1.8 days on a 5.0/MG); a runtime threshold means the same "charge it tonight" warning for both. */
    const val runtimeAlertHours = 24.0

    /** Re-arm only when the estimate recovers to this. The 12 h hysteresis band means jitter in the
     *  fitted slope around the alert line can't re-fire; only a genuine charge opens the gate again. */
    const val runtimeRearmHours = 36.0

    data class RuntimeAlertDecision(val fire: Boolean, val newAlerted: Boolean)

    /**
     * Crossing-with-hysteresis decision for the predictive alert, mirroring BatteryAlertPolicy's
     * shape: PERSISTED `alerted` gate in, fire decision plus next gate state out. Behaviour-identical
     * twin of the Swift `BatteryEstimator.runtimeAlert` (same fixtures, same numbers).
     *
     * `charging == null` means unknown — the alert still fires (only a confirmed `true` suppresses
     * it), the same null-tolerant rule as the SoC low alert: the strap reports its charge bit only
     * every ~8 min, and a strap that never reports one should still warn.
     */
    fun runtimeAlert(remainingHours: Double, charging: Boolean?, alerted: Boolean): RuntimeAlertDecision {
        var armedOff = alerted
        if (remainingHours >= runtimeRearmHours) armedOff = false
        val fire = !armedOff && remainingHours <= runtimeAlertHours && charging != true
        if (fire) armedOff = true
        return RuntimeAlertDecision(fire, armedOff)
    }

    // ---- The ~10% hardware cutoff ----

    /** The strap stops sampling and drops the link NEAR THIS SoC, not at 0%. Measured on a WHOOP 5.0
     *  running R22 deep-data + high-rate IMU capture: the SoC series ran 13.1% → 10.9% over 80 min and
     *  the last HR sample of the session landed 27 min after that 10.9% reading, with no reading below
     *  10.9% ever banked. At that run's 1.65 %/h those 27 min are ~0.7 pp — the strap went dark at ~10%
     *  with ~10 pp of nominal charge still showing.
     *
     *  This matters because [estimate] divides the FULL current SoC by the drain rate, so its
     *  `remainingHours` is time-to-**0%** and overstates usable life by `cutoffSocPct / rate` — ~6 h for
     *  that user. Any consumer asking "will the strap survive the next N hours" must ask
     *  [usableRemainingHours], never `Estimate.remainingHours`.
     *
     *  Deliberately NOT folded into [estimate] itself: `remainingHours` feeds the Today "~X left" badge
     *  and the shared Swift/Kotlin fixtures, so re-anchoring it there would change a displayed number
     *  and break documented cross-platform parity in the same commit. Kept additive instead. */
    const val cutoffSocPct = 10.0

    /** Runtime left before the strap goes dark at [cutoffSocPct], derived from an estimate's
     *  time-to-0% figure. Algebraically `(currentSoc - cutoff) / rate` where `rate = currentSoc /
     *  remainingHours`, rearranged so the rate is never recovered explicitly — which also carries the
     *  #99 clamp through CONSERVATIVELY: that clamp only ever lowers `remainingHours`, so the usable
     *  figure derived from it can only be pessimistic, never optimistic. 0 at or below the cutoff. */
    fun usableRemainingHours(remainingHours: Double, currentSoc: Double): Double {
        if (currentSoc <= 0 || remainingHours <= 0) return 0.0
        return maxOf(0.0, remainingHours * (currentSoc - cutoffSocPct) / currentSoc)
    }

    /** [usableRemainingHours] for a whole [Estimate] — the form callers holding the live estimate want. */
    fun usableRemainingHours(estimate: Estimate): Double =
        usableRemainingHours(estimate.remainingHours, estimate.currentSoc)

    // ---- Critical low-battery alert (the escalation the 15% alert can't give) ----

    /** SoC at which the CRITICAL "charge it now" alert fires — a second crossing below
     *  `BatteryAlertPolicy.LOW_THRESHOLD` (15%), with its own gate.
     *
     *  Derived from [cutoffSocPct], not picked round. The strap goes dark at ~10%, so the ENTIRE usable
     *  alert band is (10%, 15%]. A conventional 5% critical threshold is unreachable on this hardware —
     *  the strap is long dead — and even 10% is a coin flip (the lowest reading ever banked on the
     *  reference run was 10.9%, and SoC reaches this policy already rounded to an Int). 12% sits
     *  mid-band, was reliably reported on the reference run (12.4 / 12.1 / 11.9 / 11.6 / 11.4 / 11.1,
     *  the first of which rounds to 12), and still clears the 15% line by 3 pp, so it is a genuinely
     *  separate crossing rather than jitter around the same threshold.
     *
     *  Lead time scales with how hard the user drives the strap, which is the point: at the reference
     *  run's 1.65 %/h (R22 deep-data + high-rate IMU) 12% is ~1.2 h of warning before the cutoff; on a
     *  stock 5.0 sipping ~0.35 %/h it is ~5.7 h. The 15% alert already carries the "plan to charge"
     *  message — this one carries "you are about to lose data", which is worth sending even when the
     *  runway is short. */
    const val criticalSocPct = 12

    /** Re-arm the critical gate on the same genuine recovery the 15% alert uses
     *  (`BatteryAlertPolicy.LOW_REARM_ABOVE` = 25), so one charge re-arms both and 11↔12% jitter can't
     *  re-fire. Its own constant so the two policies stay independently tunable. */
    const val criticalRearmAbovePct = 25

    data class CriticalAlertDecision(val fire: Boolean, val newAlerted: Boolean)

    /**
     * Crossing-with-hysteresis decision for the CRITICAL low alert, mirroring `BatteryAlertPolicy`'s
     * shape: persisted gate in, fire decision plus next gate state out.
     *
     * Deliberately a SEPARATE policy with its OWN persisted flag rather than a second branch of
     * `BatteryAlertPolicy.evaluate`, because the failure this fixes IS the latch: the 15% alert fires
     * once and sets `lowAlerted = true` until SoC recovers to 25%, so on the reference incident the
     * user got one warning at 15% and then total silence across the ~3 h it took to reach the cutoff.
     * A latched `lowAlerted` must never be able to suppress this one.
     *
     * `charging == null` (unknown) still fires — only a confirmed `true` suppresses — matching the SoC
     * low alert's null-tolerant rule: the strap reports its charge bit only every ~8 min.
     * Behaviour-identical twin of the Swift `BatteryEstimator.criticalAlert`.
     */
    fun criticalAlert(pct: Int, charging: Boolean?, alerted: Boolean): CriticalAlertDecision {
        var armedOff = alerted
        if (pct >= criticalRearmAbovePct) armedOff = false
        val fire = !armedOff && pct <= criticalSocPct && charging != true
        if (fire) armedOff = true
        return CriticalAlertDecision(fire, armedOff)
    }

    // ---- Bedtime night-guard ("this won't last the night") ----

    /** How long before habitual bedtime the night-guard window opens. Wide enough that the strap's
     *  ~8-minute battery cadence lands several readings inside it even with link churn, and that the
     *  user can still act; narrow enough that the question is genuinely about TONIGHT. */
    const val bedtimeLeadHours = 3.0

    /** Safety margin added on top of "wait until bedtime + tonight's sleep". Covers the slope fit's
     *  error and the gap between the learned habitual night and any given night running long. */
    const val bedtimeMarginHours = 1.0

    /** Floor on the number of nights behind [typicalSleepHours]. The midsleep learner's own
     *  `SleepStageTotals.HABITUAL_MIN_DAYS` (14) already gates the whole night-guard — with no learned
     *  midsleep there is no bedtime and [bedtimeAlert] returns silently — so this is a local
     *  belt-and-braces bound ensuring the duration median itself is never taken off a night or two. */
    const val bedtimeMinNights = 7

    /** What tonight demands of the strap versus what it has. Returned by [bedtimeAlert] so the notifier
     *  can word the alert from real numbers and the tests can assert the arithmetic, not just the Bool. */
    data class NightRunway(
        val hoursUntilBedtime: Double,
        val sleepHours: Double,
        /** `hoursUntilBedtime + sleepHours + bedtimeMarginHours`. */
        val requiredHours: Double,
        /** Cutoff-aware runtime ([usableRemainingHours]), NOT the raw time-to-0% estimate. */
        val usableHours: Double,
    ) {
        /** How far short the strap falls, in hours. 0 when it makes it. */
        val shortfallHours: Double get() = maxOf(0.0, requiredHours - usableHours)
    }

    data class BedtimeAlertDecision(
        val fire: Boolean,
        val newAlerted: Boolean,
        val runway: NightRunway?,
    )

    /**
     * Typical night length (hours) for the night-guard: the MEDIAN of the recent per-night sleep
     * durations the app already banks — the daily rollup's total sleep (the longest block per LOCAL
     * day, so naps drop out). Median rather than mean so one all-nighter, or one night the strap itself
     * died at 0.4 h, can't shrink tonight's budget. null under [minNights] — cold-start stays honest
     * rather than inventing a night length. Twin of the Swift `typicalSleepHours`.
     */
    fun typicalSleepHours(nightlyHours: List<Double>, minNights: Int = bedtimeMinNights): Double? {
        val valid = nightlyHours.filter { it > 0 }
        if (valid.size < minNights) return null
        val sorted = valid.sorted()
        val n = sorted.size
        return if (n % 2 == 1) sorted[n / 2] else (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /**
     * Decide whether to tell the user, BEFORE they go to bed, that the strap won't survive the night.
     *
     * This is the alert the reference incident actually needed. That user's strap had already fired
     * both the 24 h "recharge tonight" runtime alert AND the 15% SoC alert — the device's persisted
     * flags confirm both — and both then LATCHED, so nothing spoke again through the final descent to
     * the cutoff, and a night of biometrics was lost. This policy is independent of both gates: it
     * asks a different question ("does the strap clear tonight specifically?") at a moment when the
     * answer is still actionable, so an earlier generic warning can never suppress it.
     *
     * Bedtime is derived from the sleep model the app ALREADY learns (#547) — `habitualMidsleepSec`
     * minus half the typical night — never from a fixed clock band, which would fire at the wrong hour
     * for exactly the shift/late sleepers that learner exists to serve.
     *
     * @param nowSecOfDay          local time-of-day seconds in [0, 86400).
     * @param habitualMidsleepSec  learned midsleep as local seconds-of-day; null at cold-start (< 14 nights).
     * @param typicalSleepHours    from [typicalSleepHours]; null at cold-start.
     * @param usableRemainingHours cutoff-aware runtime; null when there is no estimate at all.
     * @param alerted              the PERSISTED once-per-night gate.
     */
    fun bedtimeAlert(
        nowSecOfDay: Int,
        habitualMidsleepSec: Int?,
        typicalSleepHours: Double?,
        usableRemainingHours: Double?,
        charging: Boolean?,
        alerted: Boolean,
    ): BedtimeAlertDecision {
        // Cold start: no learned midsleep or no duration history → there is NO honest bedtime to test
        // against. Inventing one (a fixed 23:00) would fire at the wrong hour for the late/shift
        // sleepers #547 exists for. Stay silent and leave the gate untouched; the 15% and critical SoC
        // alerts remain the safety net.
        val sleepHours = typicalSleepHours
        if (habitualMidsleepSec == null || sleepHours == null || sleepHours <= 0 ||
            habitualMidsleepSec !in 0 until secondsPerDay || nowSecOfDay !in 0 until secondsPerDay
        ) {
            return BedtimeAlertDecision(false, alerted, null)
        }
        // Bedtime = midsleep - half the typical night, CIRCULAR so a 03:30 midsleep on an 8 h night is
        // a 23:30 bedtime rather than a negative one.
        val bedtimeSec = floorMod(habitualMidsleepSec - (sleepHours * 1800).roundToInt(), secondsPerDay)
        val hoursUntilBedtime = floorMod(bedtimeSec - nowSecOfDay, secondsPerDay) / 3600.0
        // Outside the pre-bed window — including the moment bedtime passes, when `hoursUntilBedtime`
        // wraps to ~24 — the gate RE-ARMS. That wrap is what makes this once-per-NIGHT rather than
        // once-per-discharge: each evening's window is a fresh crossing, so unlike the 15%/24 h alerts
        // this one can speak again tomorrow without needing a charge to re-arm it.
        if (hoursUntilBedtime > bedtimeLeadHours) return BedtimeAlertDecision(false, false, null)
        // No estimate at all (no banked SoC history yet) → nothing to judge; hold the gate.
        val usable = usableRemainingHours ?: return BedtimeAlertDecision(false, alerted, null)
        // The strap must survive the wait until bedtime AND the night itself, plus the margin.
        // Anchoring to `hoursUntilBedtime` rather than a flat `sleepHours` is what keeps the whole lead
        // window honest: firing 3 h before bed genuinely demands 3 h more runtime than firing at bed.
        val required = hoursUntilBedtime + sleepHours + bedtimeMarginHours
        val runway = NightRunway(hoursUntilBedtime, sleepHours, required, usable)
        val fire = !alerted && usable < required && charging != true
        // Charging suppression must NOT consume the gate: unplug still inside the window and the alert
        // must still be able to fire (mirrors [runtimeAlert]'s contract).
        return BedtimeAlertDecision(fire, if (fire) true else alerted, runway)
    }

    private const val secondsPerDay = 86_400

    /** Floored modulo — correct for negative operands, unlike Kotlin's `%`. Bedtime arithmetic wraps
     *  midnight in both directions. */
    private fun floorMod(a: Int, n: Int): Int {
        val r = a % n
        return if (r < 0) r + n else r
    }
}
