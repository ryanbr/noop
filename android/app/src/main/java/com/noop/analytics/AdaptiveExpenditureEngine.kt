package com.noop.analytics

/**
 * One day's inputs for the retrospective expenditure estimate. Both fields are nullable because the two
 * series are independently sparse — a day with a weigh-in and no food log is common, and inventing a
 * value for the missing one is exactly what this engine must not do.
 */
data class AdaptiveExpenditureDay(
    val day: String,
    val caloriesIn: Double? = null,
    val weightKg: Double? = null,
)

/** How much the estimate deserves to be trusted. Coarse on purpose — a percentage would imply a
 *  precision this method does not have. */
enum class AdaptiveExpenditureConfidence { BUILDING, MODERATE, HIGH }

/**
 * A retrospective estimate of average daily energy expenditure, with an interval.
 *
 * Never a single number: the error is dominated by things this engine cannot see (hydration swings, an
 * under-logged weekend), so a bare figure would be the fabrication the rest of NOOP refuses to make.
 */
data class AdaptiveExpenditureEstimate(
    val estimatedDailyKcal: Double,
    val lowerKcal: Double,
    val upperKcal: Double,
    val meanIntakeKcal: Double,
    val weightSlopeKgPerDay: Double,
    val intakeDays: Int,
    val weightReadings: Int,
    val windowDays: Int,
    val confidence: AdaptiveExpenditureConfidence,
)

/**
 * Average daily expenditure inferred from logged intake and the weight trend (TDEE by energy balance).
 *
 * `expenditure = intake - change in stored energy`, with the conventional 7,700 kcal per kg of body
 * mass. The identity is exact; the inputs are not. Day-to-day weight is mostly water, and food logs are
 * under-reported by a wide and person-specific margin, so this is meaningful only over weeks and only as
 * a range.
 *
 * DELIBERATELY NOT AN INPUT TO ANYTHING. It never feeds Charge, the calorie card, or the workout calorie
 * estimate: those come from measured heart rate through Keytel, and quietly overwriting a measurement
 * with an inference from a food diary would be a strictly worse number wearing the same label.
 *
 * Swift twin: `AdaptiveExpenditureEngine`.
 */
object AdaptiveExpenditureEngine {
    /** The textbook 7,700 kcal/kg figure, which assumes the change is adipose; it over-states early loss,
     *  when a real share is glycogen and its bound water. That bias is one reason the output is a range. */
    const val KCAL_PER_KG = 7_700.0

    const val MIN_WINDOW_DAYS = 21
    const val MAX_WINDOW_DAYS = 42
    const val MIN_INTAKE_DAYS = 14
    const val MIN_INTAKE_COVERAGE = 0.70
    const val MIN_WEIGHT_READINGS = 6

    /** null when the history cannot support an estimate — the normal answer for most installs, and the
     *  point of the gates. [days] need not be sorted or contiguous. */
    fun estimate(days: List<AdaptiveExpenditureDay>): AdaptiveExpenditureEstimate? {
        val ordered = days.sortedBy { it.day }
        val first = ordered.firstOrNull()?.day ?: return null
        val last = ordered.last().day
        val span = dayCount(first, last) ?: return null
        if (span < MIN_WINDOW_DAYS) return null
        val window = minOf(span, MAX_WINDOW_DAYS)
        val recent = ordered.filter { d ->
            val back = dayCount(d.day, last) ?: return@filter false
            // `dayCount` is INCLUSIVE — `dayCount(last, last)` is 1 — so the last `window` days are
            // `back <= window`. A strict `<` silently drops the oldest day while still reporting the full
            // `window`, which both loses data and understates coverage.
            back <= window
        }

        val intake = recent.mapNotNull { it.caloriesIn }.filter { it > 0 }
        val weights = recent.mapNotNull { d ->
            val w = d.weightKg ?: return@mapNotNull null
            if (w <= 0) return@mapNotNull null
            val i = dayCount(first, d.day) ?: return@mapNotNull null
            i to w
        }
        if (intake.size < MIN_INTAKE_DAYS) return null
        // Clamped: `coverage` is "share of the window that was logged", so it cannot exceed 1. A caller
        // that merged its two sparse series badly and passed a day twice would otherwise push it above 1,
        // which SHRINKS the margin and RAISES the confidence — making the answer look more certain than
        // its data, the one direction this engine must never err in. Clamping rather than de-duplicating
        // on purpose: silently picking one of two conflicting values for a day would hide the caller's bug.
        val coverage = minOf(1.0, intake.size.toDouble() / window.toDouble())
        if (coverage < MIN_INTAKE_COVERAGE) return null
        // DISTINCT days, not readings. Two weigh-ins on one morning are one day of evidence about the
        // trend, and counting both would let a chatty scale — or a caller that passed a day twice — buy
        // the same confidence as a fortnight of extra data.
        val weightDays = weights.map { it.first }.distinct().size
        if (weightDays < MIN_WEIGHT_READINGS) return null
        val slope = leastSquaresSlope(weights) ?: return null

        val meanIntake = intake.sum() / intake.size.toDouble()
        // A RISING weight means intake exceeded expenditure, so the stored-energy term is SUBTRACTED.
        // Getting this sign backwards is the classic error, which is why the tests pin both directions.
        val estimate = meanIntake - slope * KCAL_PER_KG

        val waterKcalPerDay = (0.5 * KCAL_PER_KG) / window.toDouble()
        val intakeUncertainty = meanIntake * 0.10 * (1.0 - coverage) + meanIntake * 0.05
        val margin = waterKcalPerDay + intakeUncertainty

        val confidence = when {
            window >= 28 && coverage >= 0.90 && weightDays >= 12 -> AdaptiveExpenditureConfidence.HIGH
            window >= 21 && coverage >= 0.80 -> AdaptiveExpenditureConfidence.MODERATE
            else -> AdaptiveExpenditureConfidence.BUILDING
        }

        return AdaptiveExpenditureEstimate(
            estimatedDailyKcal = estimate,
            lowerKcal = estimate - margin,
            upperKcal = estimate + margin,
            meanIntakeKcal = meanIntake,
            weightSlopeKgPerDay = slope,
            intakeDays = minOf(intake.size, window),
            weightReadings = weightDays,
            windowDays = window,
            confidence = confidence,
        )
    }

    /** OLS slope in kg per DAY. null when every reading shares one day, which would divide by zero — a
     *  real case when a scale syncs several readings with one timestamp. */
    internal fun leastSquaresSlope(points: List<Pair<Int, Double>>): Double? {
        val n = points.size.toDouble()
        if (points.size < 2) return null
        val meanX = points.sumOf { it.first.toDouble() } / n
        val meanY = points.sumOf { it.second } / n
        var num = 0.0
        var den = 0.0
        for ((x, y) in points) {
            val dx = x.toDouble() - meanX
            num += dx * (y - meanY)
            den += dx * dx
        }
        return if (den > 0) num / den else null
    }

    /**
     * Whole days between two "yyyy-MM-dd" keys, inclusive of the first.
     *
     * null on an unparseable key. [AnalyticsEngine.dayStartUtcSeconds] is deliberately nil-tolerant and
     * returns 0 for one, which is indistinguishable from 1970 here — and a stray 0 would silently stretch
     * the window by twenty thousand days.
     */
    internal fun dayCount(from: String, to: String): Int? {
        val a = AnalyticsEngine.dayStartUtcSeconds(from)
        val b = AnalyticsEngine.dayStartUtcSeconds(to)
        if (a <= 0L || b <= 0L) return null
        return ((b - a) / 86_400L).toInt() + 1
    }
}
