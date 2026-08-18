package com.noop.analytics

import kotlin.math.exp

/**
 * Long-horizon training-load model using exponentially weighted daily load.
 *
 * Complements ReadinessEngine's existing rolling-mean ACWR and Foster monotony without replacing either
 * and without feeding the Readiness level. CTL, ATL, and TSB stay in the SAME units as the supplied daily
 * load; NOOP supplies daily Effort/strain, so these are not TRIMP. Missing calendar days are never
 * silently filled with zero — a real rest day must be present with load=0, and a missing row or a null
 * load breaks the contiguous suffix. Byte-parity twin of Swift `TrainingLoadEngine`.
 *
 * Model: alpha = 1 - exp(-1 / tauDays); state[t] = state[t-1] + alpha * (load[t] - state[t-1]);
 * TSB = CTL - ATL. Standard 42d chronic / 7d acute Banister-style horizons, seeded from the mean of the
 * first `primeDays` observed loads to avoid the artificial low bias of zero-seeding a new wearer.
 */
object TrainingLoadEngine {
    data class Configuration(
        val chronicTimeConstantDays: Double = 42.0,
        val acuteTimeConstantDays: Double = 7.0,
        val primeDays: Int = 7,
        val minimumDays: Int = 14,
        val establishedDays: Int = 42,
    ) {
        val isValid: Boolean
            get() = chronicTimeConstantDays.isFinite() && chronicTimeConstantDays > 0.0 &&
                acuteTimeConstantDays.isFinite() && acuteTimeConstantDays > 0.0 &&
                primeDays > 0 && minimumDays >= primeDays && establishedDays >= minimumDays
    }

    val standard = Configuration()

    /** Calendar-day input. `load == null` is no usable observation; `load == 0` is a measured rest day. */
    data class DailyLoad(val day: String, val load: Double?)

    enum class State { UNAVAILABLE, BUILDING, ESTABLISHED }

    enum class UnavailableReason {
        NO_DATA,
        MISSING_TARGET_DAY,
        NOT_ENOUGH_CONTIGUOUS_DAYS,
        INVALID_CONFIGURATION,
        INVALID_DAY,
        DUPLICATE_DAY,
        INVALID_LOAD,
    }

    data class Point(
        val day: String,
        val load: Double,
        val chronicLoad: Double,
        val acuteLoad: Double,
        val balance: Double,
    ) {
        val ctl: Double get() = chronicLoad
        val atl: Double get() = acuteLoad
        val tsb: Double get() = balance
    }

    data class Result(
        val state: State,
        val unavailableReason: UnavailableReason?,
        val contiguousDays: Int,
        val startDay: String?,
        val endDay: String?,
        val points: List<Point>,
    ) {
        val chronicLoad: Double? get() = points.lastOrNull()?.chronicLoad
        val acuteLoad: Double? get() = points.lastOrNull()?.acuteLoad
        val balance: Double? get() = points.lastOrNull()?.balance
        val ctl: Double? get() = chronicLoad
        val atl: Double? get() = acuteLoad
        val tsb: Double? get() = balance
        val isAvailable: Boolean get() = state != State.UNAVAILABLE
    }

    /**
     * Evaluate the latest day in the input, or an explicit target day. Inputs may be in any order. Only
     * the longest fully observed contiguous suffix ending on the target is modeled; older history before a
     * gap is ignored rather than compressing calendar time or inventing zero load.
     */
    fun evaluate(
        days: List<DailyLoad>,
        through: String? = null,
        configuration: Configuration = standard,
    ): Result {
        if (!configuration.isValid) return unavailable(UnavailableReason.INVALID_CONFIGURATION, 0)
        if (days.isEmpty()) return unavailable(UnavailableReason.NO_DATA, 0)

        data class Parsed(val day: String, val ordinal: Int, val load: Double?)
        val parsed = ArrayList<Parsed>(days.size)
        val seen = HashSet<Int>()
        for (item in days) {
            val ordinal = dayOrdinal(item.day) ?: return unavailable(UnavailableReason.INVALID_DAY, 0)
            if (!seen.add(ordinal)) return unavailable(UnavailableReason.DUPLICATE_DAY, 0)
            val load = item.load
            if (load != null && (!load.isFinite() || load < 0.0)) {
                return unavailable(UnavailableReason.INVALID_LOAD, 0)
            }
            parsed += Parsed(item.day, ordinal, load)
        }
        parsed.sortBy { it.ordinal }

        val targetOrdinal = if (through != null) {
            dayOrdinal(through) ?: return unavailable(UnavailableReason.INVALID_DAY, 0)
        } else {
            parsed.last().ordinal
        }
        val targetIndex = parsed.indexOfLast { it.ordinal == targetOrdinal }
        if (targetIndex < 0) return unavailable(UnavailableReason.MISSING_TARGET_DAY, 0)

        // Walk backwards from the target until the first calendar gap OR unobserved load. A stored zero
        // stays valid; future rows and older history before the break do not affect this target's model.
        val suffixReversed = ArrayList<Parsed>()
        var expectedOrdinal = targetOrdinal
        var index = targetIndex
        while (index >= 0) {
            val item = parsed[index]
            val load = item.load
            if (item.ordinal != expectedOrdinal || load == null) break
            suffixReversed += item
            expectedOrdinal -= 1
            index -= 1
        }
        val ordered = suffixReversed.asReversed()
        val contiguousDays = ordered.size
        if (contiguousDays < configuration.minimumDays) {
            return unavailable(
                UnavailableReason.NOT_ENOUGH_CONTIGUOUS_DAYS,
                contiguousDays,
                ordered.firstOrNull()?.day,
                ordered.lastOrNull()?.day,
            )
        }

        val seed = ordered.take(configuration.primeDays).sumOf { it.load!! } / configuration.primeDays.toDouble()
        val alphaChronic = 1.0 - exp(-1.0 / configuration.chronicTimeConstantDays)
        val alphaAcute = 1.0 - exp(-1.0 / configuration.acuteTimeConstantDays)
        var chronic = seed
        var acute = seed
        val points = ArrayList<Point>(ordered.size - configuration.primeDays + 1)

        val seedDay = ordered[configuration.primeDays - 1]
        points += Point(seedDay.day, seedDay.load!!, chronic, acute, chronic - acute)
        for (item in ordered.drop(configuration.primeDays)) {
            val load = item.load!!
            chronic += alphaChronic * (load - chronic)
            acute += alphaAcute * (load - acute)
            points += Point(item.day, load, chronic, acute, chronic - acute)
        }

        return Result(
            state = if (contiguousDays >= configuration.establishedDays) State.ESTABLISHED else State.BUILDING,
            unavailableReason = null,
            contiguousDays = contiguousDays,
            startDay = ordered.firstOrNull()?.day,
            endDay = ordered.lastOrNull()?.day,
            points = points,
        )
    }

    /** Convenience for dense load arrays. Day labels are synthetic but deterministic; math is identical. */
    fun evaluateDense(loads: List<Double>, configuration: Configuration = standard): Result {
        val baseOrdinal = dayOrdinal("2000-01-01")!!
        val days = loads.mapIndexed { index, load -> DailyLoad(dayString(baseOrdinal + index), load) }
        return evaluate(days, configuration = configuration)
    }

    private fun unavailable(
        reason: UnavailableReason,
        contiguousDays: Int,
        startDay: String? = null,
        endDay: String? = null,
    ) = Result(State.UNAVAILABLE, reason, contiguousDays, startDay, endDay, emptyList())

    // Integer-only proleptic-Gregorian (Howard Hinnant) transform. Avoids timezone/DST/locale drift
    // between platforms so the Swift twin cannot diverge around DST or locale boundaries.
    private fun dayOrdinal(value: String): Int? {
        val parts = value.split('-', limit = 3)
        if (parts.size != 3 || parts[0].length != 4 || parts[1].length != 2 || parts[2].length != 2) return null
        val year = parts[0].toIntOrNull() ?: return null
        val month = parts[1].toIntOrNull() ?: return null
        val day = parts[2].toIntOrNull() ?: return null
        if (year < 1 || month !in 1..12) return null
        val daysInMonth = intArrayOf(31, if (isLeapYear(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        if (day !in 1..daysInMonth[month - 1]) return null

        val adjustedYear = year - if (month <= 2) 1 else 0
        val era = floorDiv(adjustedYear, 400)
        val yearOfEra = adjustedYear - era * 400
        val shiftedMonth = month + if (month > 2) -3 else 9
        val dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private fun dayString(ordinal: Int): String {
        val z = ordinal + 719_468
        val era = floorDiv(z, 146_097)
        val dayOfEra = z - era * 146_097
        val yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        var year = yearOfEra + era * 400
        val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        val monthPrime = (5 * dayOfYear + 2) / 153
        val day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        val month = monthPrime + if (monthPrime < 10) 3 else -9
        if (month <= 2) year += 1
        return "%04d-%02d-%02d".format(java.util.Locale.US, year, month, day)
    }

    private fun isLeapYear(year: Int) = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)

    private fun floorDiv(value: Int, divisor: Int): Int {
        val quotient = value / divisor
        val remainder = value % divisor
        return if (remainder < 0) quotient - 1 else quotient
    }
}
