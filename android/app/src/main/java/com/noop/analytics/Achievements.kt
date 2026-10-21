package com.noop.analytics

/**
 * Achievements - milestones unlocked from the user's own daily history.
 *
 * The WHOOP app has a server-driven achievements surface with celebration screens (observed in the shipped
 * app's model shapes, facts only, no WHOOP code). NOOP has no server, so this is the local equivalent: a
 * fixed list of milestones, each unlocked on the first day the user's own stored metrics reach it.
 *
 * Rules (Swift twin: StrandAnalytics/Achievements.swift, held aligned by mirrored fixtures):
 *   - a "scored day" is a day with a Charge (recovery) value in 0..100;
 *   - streaks are consecutive civil days with a score (TZ-free epoch arithmetic); a streak milestone
 *     unlocks on the day the run first reaches its length;
 *   - single-day milestones unlock on the earliest day the value reaches the threshold inside the
 *     metric's plausible range, so an artefact never unlocks one;
 *   - `isNew` = unlocked within the last [NEW_WINDOW_DAYS] days ending at today.
 *
 * Pure: no clock, no I/O, no storage. PRESENTATION ONLY.
 */
object Achievements {

    const val NEW_WINDOW_DAYS: Int = 7

    /** One milestone. [raw] matches the Swift `AchievementId` raw value. */
    enum class Id(val raw: String) {
        FIRST_SCORE("firstScore"), STREAK_7("streak7"), STREAK_30("streak30"), SCORED_100("scored100"),
        CHARGE_90("charge90"), SLEEP_8H("sleep8h"), EFFORT_18("effort18"), STEPS_10K("steps10k"),
    }

    data class Day(
        val day: String,
        val recovery: Double? = null,
        val strain: Double? = null,
        val sleepMin: Double? = null,
        val steps: Double? = null,
    )

    /** [unlockedDay] is null while locked. */
    data class Achievement(val id: Id, val unlockedDay: String?, val isNew: Boolean)

    /** Swift twin: `Achievements.inRange`. */
    private fun inRange(v: Double?, lo: Double, hi: Double): Double? =
        v?.takeIf { !it.isNaN() && it >= lo && it <= hi }

    /** Every milestone in [Id.entries] order, locked or not. Rows may arrive in any order; unparseable day
     * Swift twin: `Achievements.evaluate`.
     *  keys are ignored. When [today] does not parse, nothing is new. */
    fun evaluate(days: List<Day>, today: String): List<Achievement> {
        val dated = days.mapNotNull { d -> Baselines.isoEpochDay(d.day)?.let { it to d } }.sortedBy { it.first }
        val unlocked = HashMap<Id, Pair<String, Int>>()
        var run = 0
        var lastScored: Int? = null
        var scored = 0
        for ((epoch, d) in dated) {
            val hits = ArrayList<Id>()
            if (inRange(d.recovery, 0.0, 100.0) != null) {
                if (lastScored != epoch) {   // same-day duplicates count once
                    run = if (lastScored == epoch - 1) run + 1 else 1
                    scored += 1
                    lastScored = epoch
                }
                hits += Id.FIRST_SCORE
                if (run >= 7) hits += Id.STREAK_7
                if (run >= 30) hits += Id.STREAK_30
                if (scored >= 100) hits += Id.SCORED_100
            }
            if ((inRange(d.recovery, 0.0, 100.0) ?: -1.0) >= 90.0) hits += Id.CHARGE_90
            if ((inRange(d.sleepMin, 60.0, 960.0) ?: -1.0) >= 480.0) hits += Id.SLEEP_8H
            if ((inRange(d.strain, 0.0, 21.0) ?: -1.0) >= 18.0) hits += Id.EFFORT_18
            if ((inRange(d.steps, 1.0, 100_000.0) ?: -1.0) >= 10_000.0) hits += Id.STEPS_10K
            for (id in hits) unlocked.putIfAbsent(id, d.day to epoch)
        }
        val t = Baselines.isoEpochDay(today)
        return Id.entries.map { id ->
            val u = unlocked[id]
            val isNew = u != null && t != null && u.second <= t && u.second > t - NEW_WINDOW_DAYS
            Achievement(id, u?.first, isNew)
        }
    }
}
