package com.noop.analytics

import kotlin.math.floor

/*
 * SleepPlanner.kt — tonight's sleep target, time in bed and bedtime for a wake time.
 *
 * Faithful Kotlin mirror of StrandAnalytics/SleepPlanner.swift. Keep the goal ladder, the
 * consecutive-night gate, the nap rule, the efficiency median/clamp and the rounding
 * byte-identical to Swift — the two clients must print the same plan for the same nights.
 *
 * Pure, deterministic, DB-free. PRESENTATION ONLY: nothing here feeds Rest, recovery, debt or
 * any stored value.
 *
 * The goal ladder (70 / 85 / 100 % of tonight's need) and the three-consecutive-night gate follow
 * the shape of the WHOOP app's sleep planner as observed in its shipped resources (facts only, no
 * WHOOP code). The rest is NOOP's own arithmetic:
 *   - tonight's need = base need + current debt − today's naps, where naps only repay debt;
 *   - time in bed = sleep target ÷ typical efficiency (median of the newest 14 usable nights,
 *     clamped to 50…100 %), or the target itself when there is no efficiency history;
 *   - bedtime = wake − time in bed, wrapped into the day.
 */

/** One sleep goal on the planner ladder. [raw] matches the Swift `SleepPlannerGoal` raw value. */
enum class SleepPlannerGoal(val raw: String) {
    MINIMUM("minimum"),
    SOLID("solid"),
    FULL("full"),
    ;

    /** Fraction of tonight's need this goal asks for. */
    val fraction: Double get() = when (this) {
        MINIMUM -> 0.70
        SOLID -> 0.85
        FULL -> 1.00
    }
}

/** The planner's read for one goal. Mirrors Swift `SleepPlanTier`. */
data class SleepPlanTier(
    val goal: SleepPlannerGoal,
    /** Asleep minutes the goal asks for. */
    val sleepTargetMin: Int,
    /** Minutes in bed needed to reach the target at the typical efficiency. */
    val timeInBedMin: Int,
    /** Bedtime as a local minute of day in [0, 1440). */
    val bedtimeMinuteOfDay: Int,
)

/** Tonight's plan: the need breakdown plus one tier per goal. Mirrors Swift `SleepPlan`. */
data class SleepPlan(
    val baseNeedMin: Int,
    val debtMin: Int,
    val napCreditMin: Int,
    val tonightNeedMin: Int,
    /** Efficiency used for time in bed, 0.5…1.0 (1.0 when there was no history). */
    val efficiencyUsed: Double,
    /** One tier per goal, in [SleepPlannerGoal.entries] order. */
    val tiers: List<SleepPlanTier>,
)

/** One night row for the planner: day key, asleep minutes and efficiency (fraction or percent). */
data class SleepPlannerNight(val day: String, val asleepMin: Double?, val efficiency: Double?)

object SleepPlanner {

    /** Consecutive nights with sleep the plan needs before it says anything. */
    const val REQUIRED_CONSECUTIVE_NIGHTS: Int = 3

    /** How many recent nights the typical efficiency is taken over. */
    const val EFFICIENCY_WINDOW_NIGHTS: Int = 14

    const val MIN_EFFICIENCY: Double = 0.5
    const val MAX_EFFICIENCY: Double = 1.0

    /**
     * Build tonight's plan, or null when there are fewer than [REQUIRED_CONSECUTIVE_NIGHTS]
     * consecutive nights ending at the newest night. [nights] are chronological; negative debt
     * reads as 0. Mirrors Swift `SleepPlanner.plan`.
     * Swift twin: `SleepPlanner.plan`.
     */
    fun plan(
        nights: List<SleepPlannerNight>,
        baseNeedMin: Double,
        debtMin: Double,
        napMinToday: Double,
        wakeMinuteOfDay: Int,
    ): SleepPlan? {
        if (consecutiveNights(nights.map { it.day to it.asleepMin }) < REQUIRED_CONSECUTIVE_NIGHTS) return null
        val base = maxOf(0.0, baseNeedMin)
        val debt = maxOf(0.0, debtMin)
        val napCredit = minOf(maxOf(0.0, napMinToday), debt)
        val tonight = base + debt - napCredit
        val eff = typicalEfficiency(nights.map { it.efficiency }) ?: 1.0

        val tiers = SleepPlannerGoal.entries.map { goal ->
            val target = tonight * goal.fraction
            val inBed = roundHalfAway(target / eff)
            SleepPlanTier(
                goal = goal,
                sleepTargetMin = roundHalfAway(target),
                timeInBedMin = inBed,
                bedtimeMinuteOfDay = wrapMinute(wakeMinuteOfDay - inBed),
            )
        }
        return SleepPlan(
            baseNeedMin = roundHalfAway(base),
            debtMin = roundHalfAway(debt),
            napCreditMin = roundHalfAway(napCredit),
            tonightNeedMin = roundHalfAway(tonight),
            efficiencyUsed = eff,
            tiers = tiers,
        )
    }

    /**
     * Length of the run of calendar-consecutive nights with sleep (> 0 min) ending at the newest
     * night carrying sleep. Rows without sleep are ignored; a gap ends the run, as does a
     * malformed day key. Mirrors Swift `SleepPlanner.consecutiveNights`.
     * Swift twin: `SleepPlanner.consecutiveNights`.
     */
    fun consecutiveNights(rows: List<Pair<String, Double?>>): Int {
        val slept = ArrayList<Int?>()
        for ((day, min) in rows) if (min != null && min > 0.0) slept.add(epochDay(day))
        if (slept.isEmpty()) return 0
        var previous = slept.last() ?: return 0
        var run = 1
        for (i in slept.lastIndex - 1 downTo 0) {
            val day = slept[i] ?: break
            if (day == previous) continue
            if (day != previous - 1) break
            run += 1
            previous = day
        }
        return run
    }

    /**
     * Median efficiency (fraction) over the newest [EFFICIENCY_WINDOW_NIGHTS] usable values,
     * clamped to [MIN_EFFICIENCY]..[MAX_EFFICIENCY]; null when none are usable.
     * Swift twin: `SleepPlanner.typicalEfficiency`.
     */
    fun typicalEfficiency(values: List<Double?>): Double? {
        val usable = values.mapNotNull { v -> v?.takeIf { it > 0.0 }?.let { if (it > 1.0) it / 100.0 else it } }
        val window = usable.takeLast(EFFICIENCY_WINDOW_NIGHTS).sorted()
        if (window.isEmpty()) return null
        val mid = window.size / 2
        val median = if (window.size % 2 == 1) window[mid] else (window[mid - 1] + window[mid]) / 2.0
        return minOf(MAX_EFFICIENCY, maxOf(MIN_EFFICIENCY, median))
    }

    /** Days since 1970-01-01 for a "yyyy-MM-dd" key (proleptic Gregorian), null if malformed. Swift twin: `SleepPlanner.epochDay`. */
    fun epochDay(key: String): Int? {
        val parts = key.split("-")
        if (parts.size != 3) return null
        val y0 = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        if (m !in 1..12 || d !in 1..31) return null
        val y = if (m <= 2) y0 - 1 else y0
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val mp = (m + 9) % 12
        val doy = (153 * mp + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /** Swift twin: `SleepPlanner.wrapMinute`. */
    internal fun wrapMinute(m: Int): Int {
        val day = 24 * 60
        return ((m % day) + day) % day
    }

    /**
     * Half-away-from-zero, matching Swift `Double.rounded()`. Uses the exact fractional part
     * rather than `floor(v + 0.5)`, which rounds 0.49999999999999994 up.
     * Swift twin: `SleepPlanner.roundHalfAway`.
     */
    internal fun roundHalfAway(v: Double): Int {
        val a = kotlin.math.abs(v)
        val f = floor(a)
        val r = if (a - f >= 0.5) f + 1.0 else f
        return (if (v < 0) -r else r).toInt()
    }
}
