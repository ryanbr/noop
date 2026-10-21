package com.noop.analytics

/** One tracked metric. [raw] matches the Swift `PersonalRecordMetric` raw value. */
enum class PersonalRecordMetric(val raw: String) {
    HRV("hrv"),
    RESTING_HR("restingHr"),
    RECOVERY("recovery"),
    STRAIN("strain"),
    SLEEP("sleep"),
    EFFICIENCY("efficiency"),
    DEEP_SLEEP("deepSleep"),
    REM_SLEEP("remSleep"),
    STEPS("steps"),
    ;

    /** True only for resting HR. */
    val lowerIsBetter: Boolean get() = this == RESTING_HR

    /** Inclusive plausibility range; values outside it are ignored. */
    val range: ClosedFloatingPointRange<Double> get() = when (this) {
        HRV -> 5.0..300.0
        RESTING_HR -> 25.0..120.0
        RECOVERY -> 0.0..100.0
        STRAIN -> 0.0..21.0
        SLEEP -> 60.0..960.0
        EFFICIENCY -> 0.5..1.0
        DEEP_SLEEP, REM_SLEEP -> 1.0..360.0
        STEPS -> 1.0..100_000.0
    }
}

/**
 * PersonalRecords - all-time personal bests over the user's own daily history.
 *
 * The WHOOP app has a "personal records" surface, but its records are computed server-side and limited
 * to weightlifting exercises (observed in the shipped app's model shapes; facts only, no WHOOP code).
 * NOOP has no server, so this is the local equivalent over the daily metrics NOOP already stores: the
 * best HRV, the lowest resting HR, the best Charge, the highest strain, the longest sleep and so on.
 *
 * Rules (Swift twin: StrandAnalytics/PersonalRecords.swift, held aligned by mirrored fixtures):
 *   - each metric has a plausibility range; values outside it never become a record, so one bad night
 *     (a 400 ms RMSSD artefact, a 12-minute "sleep") cannot sit at the top of the list forever;
 *   - higher is better for every metric except resting HR, where lower is better;
 *   - a tie does not beat a record: the EARLIEST day holding the best value keeps it;
 *   - a record is "new" when it was set within the last [NEW_WINDOW_DAYS] days ending at today AND at
 *     least [MIN_PRIOR_VALUES] usable values came before it, so the first weeks of history do not mark
 *     every metric as new.
 *
 * Civil-day arithmetic is TZ-free ([Baselines.isoEpochDay]). Pure: no clock, no I/O, no storage.
 * PRESENTATION ONLY: nothing here feeds a score, a baseline or a stored value.
 */
object PersonalRecords {

    /** Days (inclusive of today) a record counts as new. */
    const val NEW_WINDOW_DAYS: Int = 7

    /** Usable values that must precede a record before it can be called new. */
    const val MIN_PRIOR_VALUES: Int = 14

    /** One day of input. Efficiency may be a fraction (0.91) or a percent (91); it is read as a fraction. */
    data class Day(
        val day: String,
        val hrvMs: Double? = null,
        val restingHr: Double? = null,
        val recovery: Double? = null,
        val strain: Double? = null,
        val sleepMin: Double? = null,
        val efficiency: Double? = null,
        val deepMin: Double? = null,
        val remMin: Double? = null,
        val steps: Double? = null,
    )

    /** The best value of one metric, the day it was set and the best that stood before it (null if none). */
    data class Record(
        val metric: PersonalRecordMetric,
        val value: Double,
        val day: String,
        val previousBest: Double?,
        val isNew: Boolean,
        /** Usable values the record was chosen from. */
        val samples: Int,
    )

    /** Read [metric] off [d], normalising efficiency to a fraction. Swift twin: `PersonalRecords.value`. */
    fun value(d: Day, metric: PersonalRecordMetric): Double? = when (metric) {
        PersonalRecordMetric.HRV -> d.hrvMs
        PersonalRecordMetric.RESTING_HR -> d.restingHr
        PersonalRecordMetric.RECOVERY -> d.recovery
        PersonalRecordMetric.STRAIN -> d.strain
        PersonalRecordMetric.SLEEP -> d.sleepMin
        PersonalRecordMetric.EFFICIENCY -> d.efficiency?.let { if (it > 1.0) it / 100.0 else it }
        PersonalRecordMetric.DEEP_SLEEP -> d.deepMin
        PersonalRecordMetric.REM_SLEEP -> d.remMin
        PersonalRecordMetric.STEPS -> d.steps
    }

    /**
     * One [Record] per metric that has at least one usable value, in [PersonalRecordMetric] order. Rows with an
     * unparseable day key are ignored; rows may arrive in any order. [today] is an ISO `yyyy-MM-dd` key;
     * when it does not parse, nothing is marked new.
     * Swift twin: `PersonalRecords.records`.
     */
    fun records(days: List<Day>, today: String): List<Record> {
        // Chronological by civil day; stable, so same-day duplicates keep their input order.
        val dated = days.mapNotNull { d -> Baselines.isoEpochDay(d.day)?.let { it to d } }.sortedBy { it.first }
        val todayEpoch = Baselines.isoEpochDay(today)
        val out = ArrayList<Record>()
        for (metric in PersonalRecordMetric.entries) {
            var best: Double? = null
            var bestDay: String? = null
            var bestEpoch = 0
            var previous: Double? = null
            var priorCount = 0
            var samples = 0
            for ((epoch, d) in dated) {
                val v = value(d, metric) ?: continue
                if (v.isNaN() || v !in metric.range) continue
                val cur = best
                val beats = cur == null || (if (metric.lowerIsBetter) v < cur else v > cur)
                if (beats) {
                    previous = cur
                    best = v
                    bestDay = d.day
                    bestEpoch = epoch
                    priorCount = samples
                }
                samples += 1
            }
            val b = best ?: continue
            val isNew = todayEpoch != null &&
                bestEpoch <= todayEpoch && bestEpoch > todayEpoch - NEW_WINDOW_DAYS &&
                priorCount >= MIN_PRIOR_VALUES
            out.add(Record(metric, b, bestDay!!, previous, isNew, samples))
        }
        return out
    }
}
