package com.noop.analytics

/** One kind of weekly goal. [raw] matches the Swift `WeeklyPlanKind` raw value. */
enum class WeeklyPlanKind(val raw: String) {
    SLEEP("sleep"),
    EFFORT("effort"),
    STEPS("steps"),
    ;

    /** Inclusive plausibility range of the daily value (asleep minutes, strain, steps). */
    val range: ClosedFloatingPointRange<Double> get() = when (this) {
        SLEEP -> 60.0..960.0
        EFFORT -> 0.0..21.0
        STEPS -> 1.0..100_000.0
    }

    /** Default threshold: 7 h asleep, Effort 10, 8,000 steps. */
    val defaultThreshold: Double get() = when (this) {
        SLEEP -> 420.0
        EFFORT -> 10.0
        STEPS -> 8_000.0
    }

    /** Default days per week. */
    val defaultTargetDays: Int get() = when (this) {
        SLEEP, STEPS -> 5
        EFFORT -> 3
    }
}

/**
 * WeeklyPlan - this week's progress toward the user's own weekly habit goals.
 *
 * The WHOOP app has a server-driven "weekly plan" (behaviour goals with a per-week check-in; observed in
 * the shipped app's model shapes, facts only, no WHOOP code). NOOP has no server, so this is the local
 * equivalent over the daily metrics NOOP already stores: "sleep at least X on N nights", "reach Effort Y on
 * N days", "walk Z steps on N days", counted over the Monday-to-Sunday week that contains today.
 *
 * Rules (Swift twin: StrandAnalytics/WeeklyPlan.swift, held aligned by mirrored fixtures):
 *   - the week is the ISO week (Monday first) containing `today`, by TZ-free civil-day arithmetic;
 *   - a day counts once per goal when its value reaches the threshold (>=) and lies inside the plausible
 *     range of the metric, so an artefact cannot tick a goal;
 *   - `daysLeft` is the days from today through Sunday that have not hit yet; `onTrack` is
 *     daysHit + daysLeft >= targetDays; a goal with targetDays 0 is off and is left out.
 *
 * Pure: no clock, no I/O, no storage. PRESENTATION ONLY: nothing here feeds a score or a stored value.
 */
object WeeklyPlan {

    /** [targetDays] is 0..7 (0 = goal off). */
    data class Goal(val kind: WeeklyPlanKind, val threshold: Double, val targetDays: Int)

    /** Swift twin: `WeeklyPlan.defaultGoals`. */
    fun defaultGoals(): List<Goal> = WeeklyPlanKind.entries.map { Goal(it, it.defaultThreshold, it.defaultTargetDays) }

    data class Day(val day: String, val sleepMin: Double? = null, val strain: Double? = null, val steps: Double? = null)

    /** [hitWeekdays] are Monday-first weekday indexes (0..6) of each day that hit, ascending. */
    data class Progress(
        val goal: Goal,
        val daysHit: Int,
        val daysLeft: Int,
        val onTrack: Boolean,
        val met: Boolean,
        val hitWeekdays: List<Int>,
    )

    /** [mondayEpochDay]: days since 1970-01-01 of this week's Monday. [todayIndex]: Monday-first, 0..6. */
    data class Week(val mondayEpochDay: Int, val todayIndex: Int, val progress: List<Progress>)

    /** Monday-first weekday index (0 = Monday) of an epoch day. 1970-01-01 was a Thursday. Swift twin: `WeeklyPlan.weekdayIndex`. */
    fun weekdayIndex(epochDay: Int): Int = Math.floorMod(epochDay + 3, 7)

    /** Swift twin: `WeeklyPlan.value`. */
    private fun value(d: Day, kind: WeeklyPlanKind): Double? = when (kind) {
        WeeklyPlanKind.SLEEP -> d.sleepMin
        WeeklyPlanKind.EFFORT -> d.strain
        WeeklyPlanKind.STEPS -> d.steps
    }

    /** This week's progress per active goal, in input order. null when [today] does not parse. Swift twin: `WeeklyPlan.week`. */
    fun week(days: List<Day>, today: String, goals: List<Goal>): Week? {
        val t = Baselines.isoEpochDay(today) ?: return null
        val idx = weekdayIndex(t)
        val monday = t - idx
        val inWeek = HashMap<Int, MutableList<Day>>()
        for (d in days) {
            val e = Baselines.isoEpochDay(d.day) ?: continue
            if (e < monday || e > t) continue
            inWeek.getOrPut(e - monday) { mutableListOf() }.add(d)
        }
        val progress = goals.mapNotNull { raw ->
            val goal = raw.copy(targetDays = raw.targetDays.coerceIn(0, 7))
            if (goal.targetDays <= 0) return@mapNotNull null
            val hits = (0..idx).filter { i ->
                inWeek[i].orEmpty().any { d ->
                    val v = value(d, goal.kind)
                    v != null && !v.isNaN() && v in goal.kind.range && v >= goal.threshold
                }
            }
            val left = (6 - idx) + (if (idx in hits) 0 else 1)
            Progress(goal, hits.size, left, hits.size + left >= goal.targetDays, hits.size >= goal.targetDays, hits)
        }
        return Week(monday, idx, progress)
    }
}
