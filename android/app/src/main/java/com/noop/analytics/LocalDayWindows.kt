package com.noop.analytics

import java.time.Duration
import java.time.Instant
import java.time.ZoneId

/**
 * A local calendar date as a year/month/day triple, mirroring the components of `java.time.LocalDate`
 * without depending on its resolution rules.
 *
 * The Swift side carries its own value type because Swift has no calendar-date type free of a
 * `Calendar`. This twin carries the same triple rather than a `LocalDate`, so that both sides run the
 * same proleptic-Gregorian arithmetic and neither inherits a library's choice about a day boundary.
 *
 * Swift twin: `LocalCalendarDate`.
 */
internal data class LocalCalendarDate(
    /** The proleptic Gregorian year, negative before year 1. Swift twin: `LocalCalendarDate.year`. */
    val year: Int,
    /** The month, 1..12. Swift twin: `LocalCalendarDate.month`. */
    val month: Int,
    /**
     * The day of the month, 1..31. No validation happens here: an out-of-range day is normalised by the
     * day-number conversion, the same way `java.time` would reject it and callers here never construct
     * one. Swift twin: `LocalCalendarDate.day`.
     */
    val day: Int,
) : Comparable<LocalCalendarDate> {

    /**
     * The date that lies `daysSinceEpoch` days after 1970-01-01.
     *
     * This is the counterpart of the Swift initialiser init(daysSinceEpoch:) and carries no parity
     * claim, because the parity guard inventories function declarations only and has no initialiser to
     * pair a claim with.
     *
     * The conversion is Howard Hinnant's civil_from_days, which needs no calendar object. Kotlin's
     * integer division truncates toward zero as Swift's does, which is what the era shifts are written
     * for. It runs inline in the delegation below and hands its three components on as one array,
     * because a data class constructor may only delegate to the primary one and computing the
     * components in a named helper would leave that helper with no counterpart of its own.
     */
    constructor(daysSinceEpoch: Int) : this(
        // `kotlin.run` by its full name: the bare form resolves to the receiver extension, and there is
        // no receiver yet inside a constructor delegation.
        kotlin.run {
            var z = daysSinceEpoch + 719_468
            val era = (if (z >= 0) z else z - 146_096) / 146_097
            z -= era * 146_097
            val dayOfEra = z
            val yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            val monthPrime = (5 * dayOfYear + 2) / 153
            val d = dayOfYear - (153 * monthPrime + 2) / 5 + 1
            val m = monthPrime + (if (monthPrime < 10) 3 else -9)
            val y = yearOfEra + era * 400 + (if (m <= 2) 1 else 0)
            intArrayOf(y, m, d)
        },
    )

    /**
     * The year, month and day of a converted day number, in that order — the one hop that lets the day-
     * number constructor above reach the primary one.
     */
    private constructor(civil: IntArray) : this(year = civil[0], month = civil[1], day = civil[2])

    /**
     * The number of days from 1970-01-01 to this date, negative before it.
     *
     * Swift twin: `LocalCalendarDate.daysSinceEpoch`.
     */
    val daysSinceEpoch: Int
        get() {
            // Howard Hinnant's days_from_civil, the exact inverse of the day-number constructor above.
            val y = year - (if (month <= 2) 1 else 0)
            val era = (if (y >= 0) y else y - 399) / 400
            val yearOfEra = y - era * 400
            val dayOfYear = (153 * (month + (if (month > 2) -3 else 9)) + 2) / 5 + day - 1
            val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            return era * 146_097 + dayOfEra - 719_468
        }

    /**
     * The date rendered as `YYYY-MM-DD`, which is also the day key this helper hands out.
     *
     * Swift twin: `LocalCalendarDate.key`.
     */
    val key: String
        get() {
            val y = if (year < 0) "-" + pad(-year, 4) else pad(year, 4)
            return "$y-${pad(month, 2)}-${pad(day, 2)}"
        }

    /**
     * The date `count` days after this one, negative counts moving backward.
     *
     * Swift twin: `LocalCalendarDate.adding(days:)`.
     */
    fun adding(days: Int): LocalCalendarDate = LocalCalendarDate(daysSinceEpoch = daysSinceEpoch + days)

    /**
     * Order dates the way the calendar does.
     *
     * Kotlin orders through `compareTo` where Swift declares the `<` operator, so the Swift `<` has no
     * selector of its own to claim and this claim names the type that declares it.
     *
     * Swift twin: `LocalCalendarDate`.
     */
    override fun compareTo(other: LocalCalendarDate): Int {
        if (year != other.year) return year.compareTo(other.year)
        if (month != other.month) return month.compareTo(other.month)
        return day.compareTo(other.day)
    }

    /**
     * The zero-padding that belongs to the type rather than to an instance.
     *
     * Swift twin: `LocalCalendarDate`.
     */
    companion object {

        /**
         * Left-pad a non-negative number with zeroes, without a formatter — the Swift side does the same,
         * and a locale-aware formatter is one more thing that could differ between the platforms.
         *
         * Swift twin: `LocalCalendarDate.pad(_:_:)`.
         */
        private fun pad(value: Int, width: Int): String {
            var s = value.toString()
            while (s.length < width) s = "0$s"
            return s
        }
    }
}

/**
 * One local day as a half-open window, with the UTC offset that was in effect when it began.
 *
 * Swift twin: `LocalDayWindow`.
 */
internal data class LocalDayWindow(
    /** The date this window belongs to. Swift twin: `LocalDayWindow.date`. */
    val date: LocalCalendarDate,
    /** The first instant of the date. Swift twin: `LocalDayWindow.start`. */
    val start: Instant,
    /**
     * The start of the next date that exists in the zone, which is where this window ends. It is not
     * always `start` plus 24 hours, and where a calendar date is skipped entirely it is more than a day
     * away. Swift twin: `LocalDayWindow.nextStart`.
     */
    val nextStart: Instant,
    /**
     * The UTC offset in effect at `start`, in seconds east of UTC.
     *
     * It describes the window's start only. A time of day anywhere else inside the window is derived
     * from the zone, never by adding this number, because a transition inside the window would make that
     * wrong by an hour. Swift twin: `LocalDayWindow.utcOffsetSeconds`.
     */
    val utcOffsetSeconds: Int,
) {

    /**
     * How long the window lasts — 23, 24 or 25 hours in the fixture zones, and longer where the zone
     * skips a calendar date. Swift returns a `TimeInterval` of seconds; the twin returns the `Duration`
     * that carries the same seconds.
     *
     * Swift twin: `LocalDayWindow.duration`.
     */
    val duration: Duration
        get() = Duration.between(start, nextStart)
}

/**
 * One entry of a backward run: a date that exists in the zone, with the start resolved for it.
 *
 * Swift twin: `LocalDayStart`.
 */
internal data class LocalDayStart(
    /** The date. Swift twin: `LocalDayStart.date`. */
    val date: LocalCalendarDate,
    /** The first instant of that date in the zone. Swift twin: `LocalDayStart.start`. */
    val start: Instant,
)

/**
 * When a local calendar date begins and ends in a time zone, taken from the zone's own rules.
 *
 * The analysis core answers this question by adding fixed 86,400-second blocks to a midnight derived
 * from a single UTC offset. That is wrong by an hour on every day boundary beyond a transition, because
 * a day on which the clocks move is 23 or 25 hours long. This type is the shared primitive that answers
 * it correctly; it changes no caller on its own.
 *
 * Nothing here is inherited from the platform's date resolution: the ambiguous, skipped and
 * non-existent cases are resolved by the rules stated on each operation, so that a future change in
 * library behaviour is a change to this file rather than a silent change of a day boundary. That is why
 * neither `ZonedDateTime` nor `ZoneRules.getTransition` appears below — the only thing asked of the
 * platform is `ZoneRules.getOffset`, the zone's raw rule lookup.
 *
 * Both the zone and the reference instant are injectable and default to the named accessors
 * `defaultTimeZone` and `defaultReferenceInstant`, so every rule below is provable without a device.
 *
 * Swift twin: `LocalDayWindows`.
 */
internal class LocalDayWindows(
    /** The zone whose rules every operation reads. Swift twin: `LocalDayWindows.timeZone`. */
    val zone: ZoneId = defaultTimeZone,
    /**
     * The instant that stands for "now" — it clamps the sleep read window and nothing else. No start,
     * window, key or run depends on it. Swift twin: `LocalDayWindows.referenceInstant`.
     */
    val referenceInstant: Instant = defaultReferenceInstant,
) {

    /**
     * The first instant that belongs to `date` in this zone, or `null` when the zone has no instant on
     * that date at all.
     *
     * The rule, stated rather than inherited: where local midnight exists once, that is the start; where
     * it exists twice, the earlier of the two; where it does not exist, the first instant that does
     * exist on the date, which is the instant the clocks jumped to. Where that jump lands on a later
     * date the date itself never happened, and there is no start.
     *
     * The rule assumes at most one offset change within two days either side of the local midnight; no
     * zone in the database violates that today.
     *
     * The result does not depend on `referenceInstant`.
     *
     * Swift twin: `LocalDayWindows.start(of:)`.
     */
    fun start(date: LocalCalendarDate): Instant? {
        val localMidnight = date.daysSinceEpoch.toLong() * 86_400L
        val offsetBefore = offsetSeconds(localMidnight - probeWindow)
        val offsetAfter = offsetSeconds(localMidnight + probeWindow)

        val candidates = listOf(localMidnight - offsetBefore, localMidnight - offsetAfter)
            .sorted()
            .distinct()
        // An instant maps to this local midnight exactly when reading it in the zone gives that wall time
        // back. Ascending order means an ambiguous midnight yields the earlier instant first.
        for (candidate in candidates) {
            if (candidate + offsetSeconds(candidate) == localMidnight) return Instant.ofEpochSecond(candidate)
        }

        // Local midnight fell in a gap. The first instant that exists on or after it is the instant the
        // clocks jumped at; it belongs to this date only if it still reads as this date.
        if (offsetBefore == offsetAfter) return null
        val jump = transitionEpochSeconds(localMidnight, offsetBefore)
        if (localDate(jump) != date) return null
        return Instant.ofEpochSecond(jump)
    }

    /**
     * The half-open window `[start, nextStart)` of `date`, or `null` when the date does not exist.
     *
     * `nextStart` is the start of the next date that *exists*, so a window that precedes a skipped
     * calendar date spans more than a day rather than ending at an instant that never happened.
     *
     * Swift twin: `LocalDayWindows.window(of:)`.
     */
    fun window(date: LocalCalendarDate): LocalDayWindow? {
        val dayStart = start(date) ?: return null
        var next = date.adding(days = 1)
        var nextStart: Instant? = null
        // A zone skipping more than a couple of consecutive dates has never happened; the bound keeps a
        // corrupt zone from turning this into an unbounded walk.
        var probes = 0
        while (nextStart == null && probes < 8) {
            nextStart = start(next)
            if (nextStart == null) next = next.adding(days = 1)
            probes += 1
        }
        val end = nextStart ?: return null
        return LocalDayWindow(
            date = date,
            start = dayStart,
            nextStart = end,
            utcOffsetSeconds = offsetSeconds(dayStart),
        )
    }

    /**
     * The start of the local day that contains `instant`, as an instant and without formatting a date on
     * the way.
     *
     * Swift twin: `LocalDayWindows.startOfDay(containing:)`.
     */
    fun startOfDay(instant: Instant): Instant {
        val date = localDate(instant)
        // `instant` lies on `date` by construction, so the date exists and has a start. The fallback is
        // unreachable and exists only to keep the operation total.
        return start(date) ?: instant
    }

    /**
     * The `YYYY-MM-DD` key of the local day that contains `instant`.
     *
     * The key and the window agree by construction: the key names the date whose window contains the
     * instant, because both are derived from the same zone lookup.
     *
     * Swift twin: `LocalDayWindows.dayKey(for:)`.
     */
    fun dayKey(instant: Instant): String = localDate(instant).key

    /**
     * The local calendar date that contains `instant` in this zone.
     *
     * Swift twin: `LocalDayWindows.localDate(of:)`.
     */
    fun localDate(instant: Instant): LocalCalendarDate = localDate(instant.epochSecond)

    /**
     * Up to `count` consecutive local calendar dates ending at `date`, oldest first, each with its own
     * resolved start.
     *
     * A date the zone skipped is omitted rather than replaced, so the run can be shorter than requested;
     * if `date` itself does not exist, the newest entry is the latest existing date before it.
     *
     * Swift twin: `LocalDayWindows.backwardRun(endingAt:count:)`.
     */
    fun backwardRun(endingAt: LocalCalendarDate, count: Int): List<LocalDayStart> {
        if (count <= 0) return emptyList()
        val endDay = endingAt.daysSinceEpoch
        val run = ArrayList<LocalDayStart>(count)
        for (back in count - 1 downTo 0) {
            val day = LocalCalendarDate(daysSinceEpoch = endDay - back)
            val start = start(day)
            if (start != null) run.add(LocalDayStart(date = day, start = start))
        }
        return run
    }

    /**
     * The end of the sleep read window of `date`: the earlier of that date's next start and the
     * reference instant, so the current day's window never reaches into the future. `null` when the date
     * does not exist.
     *
     * For a date that begins after the reference instant the end precedes the start — an empty, inverted
     * window — by the D7 contract; a caller wanting a non-empty window must not ask for a future date.
     *
     * Swift twin: `LocalDayWindows.sleepReadWindowEnd(of:)`.
     */
    fun sleepReadWindowEnd(date: LocalCalendarDate): Instant? {
        val window = window(date) ?: return null
        return minOf(window.nextStart, referenceInstant)
    }

    /**
     * The UTC offset in effect at `instant`, in seconds east of UTC.
     *
     * Swift twin: `LocalDayWindows.offsetSeconds(at:)`.
     */
    fun offsetSeconds(instant: Instant): Int = zone.rules.getOffset(instant).totalSeconds

    /**
     * The UTC offset in effect at a whole-second instant.
     *
     * Swift twin: `LocalDayWindows.offsetSeconds(atEpochSeconds:)`.
     */
    private fun offsetSeconds(epochSeconds: Long): Int =
        zone.rules.getOffset(Instant.ofEpochSecond(epochSeconds)).totalSeconds

    /**
     * The local calendar date of a whole-second instant.
     *
     * Swift twin: `LocalDayWindows.localDate(ofEpochSeconds:)`.
     */
    private fun localDate(epochSeconds: Long): LocalCalendarDate {
        val localSeconds = epochSeconds + offsetSeconds(epochSeconds)
        var days = localSeconds / 86_400L
        if (localSeconds < 0 && localSeconds % 86_400L != 0L) days -= 1
        return LocalCalendarDate(daysSinceEpoch = days.toInt())
    }

    /**
     * The instant at which the zone's offset changes near `localMidnight`, found by bisecting the probe
     * window between the offset before and the offset after.
     *
     * Swift twin: `LocalDayWindows.transitionEpochSeconds(around:offsetBefore:)`.
     */
    private fun transitionEpochSeconds(localMidnight: Long, offsetBefore: Int): Long {
        var low = localMidnight - probeWindow
        var high = localMidnight + probeWindow
        while (high - low > 1) {
            val mid = low + (high - low) / 2
            if (offsetSeconds(mid) == offsetBefore) low = mid else high = mid
        }
        return high
    }

    /**
     * The named defaults and the version reporting, which belong to the type rather than to an instance.
     *
     * Swift twin: `LocalDayWindows`.
     */
    companion object {

        /**
         * The zone used when none is given: the system default zone id, which follows a change of device
         * zone during the process's life. The Swift twin's default is the auto-updating current zone,
         * which means the same thing.
         *
         * The zone is bound when the helper is constructed; a caller that must follow a device-zone
         * change during the process's life constructs a new helper.
         *
         * Swift twin: `LocalDayWindows.defaultTimeZone`.
         */
        val defaultTimeZone: ZoneId
            get() = ZoneId.systemDefault()

        /**
         * The reference instant used when none is given: the current `Instant`. The Swift twin's default
         * is the current `Date`.
         *
         * Swift twin: `LocalDayWindows.defaultReferenceInstant`.
         */
        val defaultReferenceInstant: Instant
            get() = Instant.now()

        /**
         * The time-zone database version this platform can observe about itself, or `null` where it
         * cannot.
         *
         * The JVM reports the database its own `java.time` rules were built from, which is a different
         * fact from the one the oracle records about the producing Swift toolchain. Where that fact
         * cannot be had the answer is `null` rather than a faked value, which is the same choice the
         * Swift side makes on Linux. `java.time.zone.ZoneRulesProvider` is not on the SDK compile
         * classpath, so it is read reflectively rather than called directly; what a device returns is
         * unverified here and belongs to A2's device counter-check. Where the read cannot be made the
         * answer is the `null` branch, which the note renders as the D6 cannot-observe wording; on the
         * JVM unit-test runner the read succeeds and the note names the version.
         *
         * Swift twin: `LocalDayWindows.observedTimeZoneDataVersion`.
         */
        val observedTimeZoneDataVersion: String?
            get() = try {
                val versions = Class.forName("java.time.zone.ZoneRulesProvider")
                    .getMethod("getVersions", String::class.java)
                    .invoke(null, ZoneId.systemDefault().id) as java.util.NavigableMap<*, *>
                if (versions.isEmpty()) null else versions.lastKey() as? String
            } catch (missing: ReflectiveOperationException) {
                null
            } catch (unsupported: RuntimeException) {
                // `ZoneRulesException` for a zone the provider does not know, wrapped or direct.
                null
            }

        /**
         * The note a platform attaches when a fixture value moves: it names the version recorded in the
         * oracle and the version this platform observes at run time.
         *
         * A version difference is not itself a failure — the fixtures are past and stable, so a routine
         * toolchain bump must not redden unrelated work. The note exists to make a *value* difference
         * explicable. It is a pure function so that its content can be asserted; where a platform cannot
         * observe its own version, the note says so in place of a version rather than omitting it.
         *
         * Swift twin: `LocalDayWindows.timeZoneDataVersionNote(recorded:observed:)`.
         */
        fun timeZoneDataVersionNote(recorded: String, observed: String?): String {
            val observedText = observed?.let { "observes $it" }
                ?: "cannot observe its own time-zone database version"
            return "time-zone database version: the oracle records $recorded; this platform $observedText."
        }

        /**
         * The number of seconds either side of a local midnight that is probed for the offsets in effect
         * around it. Two days is far more than any transition needs and still far less than the gap
         * between two transitions anywhere in the database.
         *
         * Swift twin: `LocalDayWindows.probeWindow`.
         */
        private const val probeWindow: Long = 2L * 86_400L
    }
}
