package com.noop.analytics

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The day-window primitive, one test per scenario of the `daily-windows` specification, plus the parity
 * oracle that the Swift twin reads from the same committed file.
 *
 * The test names mirror `LocalDayWindowsTests.swift` so the two suites read side by side. Every fixture
 * passes an explicit zone and an explicit reference instant, so nothing here depends on the machine's
 * zone or on when the suite runs. The two exceptions are the default-accessor tests, which are about the
 * defaults themselves and deliberately do not go through the oracle.
 */
class LocalDayWindowsTest {

    // MARK: - Fixture helpers

    /** A date written the way the specification writes it. */
    private fun date(text: String): LocalCalendarDate {
        val parts = text.split("-").map { it.toInt() }
        return LocalCalendarDate(year = parts[0], month = parts[1], day = parts[2])
    }

    /** An instant from whole seconds since the epoch. */
    private fun instant(epochSeconds: Long): Instant = Instant.ofEpochSecond(epochSeconds)

    /**
     * A UTC instant written as `YYYY-MM-DDTHH:MM:SSZ`, parsed without a formatter so the test's own
     * expectations do not depend on a locale or a calendar.
     */
    private fun utc(text: String): Instant {
        val halves = text.dropLast(1).split("T")
        val day = halves[0].split("-").map { it.toInt() }
        val time = halves[1].split(":").map { it.toInt() }
        val days = LocalCalendarDate(year = day[0], month = day[1], day = day[2]).daysSinceEpoch
        return instant(days.toLong() * 86_400L + time[0] * 3600L + time[1] * 60L + time[2])
    }

    /** The helper for a zone, with a reference instant that no scenario in this section depends on. */
    private fun windows(zoneName: String, reference: Instant = Instant.EPOCH): LocalDayWindows =
        LocalDayWindows(zone = ZoneId.of(zoneName), referenceInstant = reference)

    // MARK: - A local date begins at its own local midnight

    /**
     * The discriminating case: the helper and the analysis core's fixed-offset arithmetic disagree by an
     * hour across a transition.
     *
     * The core's arithmetic is re-derived inline, verbatim per the scenario, so that both platforms
     * compare against the same arm: floor to a local midnight using the zone's offset at the reference
     * instant, then subtract whole 86,400-second days.
     */
    @Test
    fun testResolvedStartDiffersFromFixedOffsetArithmeticAcrossATransition() {
        val zone = ZoneId.of("America/New_York")
        val reference = utc("2025-11-10T17:00:00Z") // 12:00 local, inside standard time
        val helper = LocalDayWindows(zone = zone, referenceInstant = reference)

        val resolved = helper.start(date("2025-10-19"))

        val offset = zone.rules.getOffset(reference).totalSeconds.toLong()
        val localSeconds = reference.epochSecond + offset
        val referenceMidnight = Math.floorDiv(localSeconds, 86_400L) * 86_400L - offset
        val fixedOffsetStart = instant(referenceMidnight - 22L * 86_400L)

        assertEquals(utc("2025-10-19T04:00:00Z"), resolved)
        assertEquals(utc("2025-10-19T05:00:00Z"), fixedOffsetStart)
        assertNotEquals(fixedOffsetStart, resolved)
    }

    /** Two reference instants on opposite sides of the zone's autumn transition give the same start. */
    @Test
    fun testResultDoesNotDependOnTheReferenceInstant() {
        val before = windows("America/New_York", reference = utc("2025-10-15T12:00:00Z"))
        val after = windows("America/New_York", reference = utc("2025-12-15T12:00:00Z"))

        assertEquals(utc("2025-10-19T04:00:00Z"), before.start(date("2025-10-19")))
        assertEquals(utc("2025-10-19T04:00:00Z"), after.start(date("2025-10-19")))
    }

    /** A zone offset of 5 hours 45 minutes puts the start on its own local midnight, off the hour. */
    @Test
    fun testDayWithFortyFiveMinuteOffsetStartsAtItsOwnLocalMidnight() {
        val helper = windows("Asia/Kathmandu")

        val start = helper.start(date("2025-06-15"))

        assertEquals(utc("2025-06-14T18:15:00Z"), start)
        assertEquals(20_700, helper.offsetSeconds(start!!))
        assertNotEquals(0L, start.epochSecond % 3600L)
    }

    // MARK: - A day window lasts as long as the zone says and carries its own offset

    /** The spring-forward day is 23 hours long. */
    @Test
    fun testSpringForwardDayIsTwentyThreeHours() {
        val window = windows("America/New_York").window(date("2025-03-09"))

        assertEquals(Duration.ofHours(23), window?.duration)
    }

    /** The fall-back day is 25 hours long. */
    @Test
    fun testFallBackDayIsTwentyFiveHours() {
        val window = windows("America/New_York").window(date("2025-11-02"))

        assertEquals(Duration.ofHours(25), window?.duration)
    }

    /** A zone without daylight saving has 24-hour days. */
    @Test
    fun testDayInZoneWithoutDaylightSavingIsTwentyFourHours() {
        val window = windows("Asia/Kolkata").window(date("2025-06-15"))

        assertEquals(Duration.ofHours(24), window?.duration)
    }

    /** Consecutive windows meet exactly across a transition, leaving neither a gap nor an overlap. */
    @Test
    fun testConsecutiveWindowsMeetExactly() {
        val helper = windows("America/New_York")

        val first = helper.window(date("2025-11-01"))
        val second = helper.window(date("2025-11-02"))
        val third = helper.window(date("2025-11-03"))
        assertNotNull("2025-11-01 must have a window", first)
        assertNotNull("2025-11-02 must have a window", second)
        assertNotNull("2025-11-03 must have a window", third)

        assertEquals(second!!.start, first!!.nextStart)
        assertEquals(third!!.start, second.nextStart)
    }

    /** The window reports the offset in effect at its own start, not at some other moment of the day. */
    @Test
    fun testWindowReportsOffsetInEffectAtItsStart() {
        val helper = windows("America/New_York")

        assertEquals(-14_400, helper.window(date("2025-11-01"))?.utcOffsetSeconds)
        assertEquals(-18_000, helper.window(date("2025-11-03"))?.utcOffsetSeconds)
    }

    // MARK: - The helper resolves the start of the local day containing an instant

    /** An instant inside the repeated local hour still resolves to that day's start. */
    @Test
    fun testInstantInsideTwentyFiveHourDayResolvesToThatDaysStart() {
        val helper = windows("America/New_York")

        val start = helper.startOfDay(utc("2025-11-02T05:30:00Z"))

        assertEquals(utc("2025-11-02T04:00:00Z"), start)
    }

    /** A start instant resolves to itself, for every fixture date that exists. */
    @Test
    fun testContainingDayStartOfAStartInstantIsItself() {
        val fixtures = listOf(
            "America/New_York" to "2025-03-09",
            "America/New_York" to "2025-11-02",
            "America/New_York" to "2025-10-19",
            "America/Santiago" to "2025-09-07",
            "America/Havana" to "2025-11-02",
            "Pacific/Apia" to "2011-12-31",
            "Asia/Kolkata" to "2025-06-15",
            "Asia/Kathmandu" to "2025-06-15",
        )
        for ((zone, day) in fixtures) {
            val helper = windows(zone)
            val start = helper.start(date(day))
            assertNotNull("$zone $day must have a start", start)
            assertEquals("$zone $day", start, helper.startOfDay(start!!))
        }
    }

    // MARK: - An instant's day key names the window that contains it

    /** The key flips exactly at the window boundary and nowhere else. */
    @Test
    fun testDayKeyChangesExactlyAtTheWindowBoundary() {
        val helper = windows("America/New_York")
        val start = helper.start(date("2025-11-02"))!!

        assertEquals("2025-11-01", helper.dayKey(start.minusSeconds(1)))
        assertEquals("2025-11-02", helper.dayKey(start.plusSeconds(1)))
    }

    /** The key holds for all 25 hours of the fall-back day, including the repeated local hour. */
    @Test
    fun testDayKeyHoldsAcrossTheWholeOfATwentyFiveHourDay() {
        val helper = windows("America/New_York")
        val window = helper.window(date("2025-11-02"))!!

        assertEquals("2025-11-02", helper.dayKey(window.start))
        assertEquals("2025-11-02", helper.dayKey(utc("2025-11-02T05:30:00Z")))
        assertEquals("2025-11-02", helper.dayKey(window.nextStart.minusSeconds(1)))
    }

    // MARK: - An ambiguous or missing local midnight resolves by a stated rule

    /** A date with no 00:00 starts at its first existing instant, its local 01:00. */
    @Test
    fun testTransitionThatSkipsLocalMidnight() {
        val start = windows("America/Santiago").start(date("2025-09-07"))

        assertEquals(utc("2025-09-07T04:00:00Z"), start)
    }

    /** A date with two 00:00 starts at the earlier of them. */
    @Test
    fun testTransitionThatRepeatsLocalMidnight() {
        val helper = windows("America/Havana")

        val start = helper.start(date("2025-11-02"))

        assertEquals(utc("2025-11-02T04:00:00Z"), start)
        assertEquals(-14_400, helper.offsetSeconds(start!!))
        // The later of the two midnights, which the rule must not pick.
        assertEquals(-18_000, helper.offsetSeconds(utc("2025-11-02T05:00:00Z")))
    }

    // MARK: - A date that does not exist is skipped over

    /** A calendar date the zone skipped has no start at all. */
    @Test
    fun testSkippedCalendarDateProducesNoStart() {
        assertNull(windows("Pacific/Apia").start(date("2011-12-30")))
    }

    /** The preceding date's window reaches over the skipped date to the next existing one. */
    @Test
    fun testPrecedingDatesWindowReachesTheNextExistingDate() {
        val helper = windows("Pacific/Apia")

        val window = helper.window(date("2011-12-29"))

        assertEquals(helper.start(date("2011-12-31")), window?.nextStart)
        assertEquals(Duration.ofHours(24), window?.duration)
    }

    // MARK: - A backward run yields consecutive existing dates with their own starts

    /** A run spanning the autumn transition is consecutive and each entry carries its own start. */
    @Test
    fun testRunAcrossATransitionIsConsecutiveAndCorrectlyAnchored() {
        val helper = windows("America/New_York")

        val run = helper.backwardRun(endingAt = date("2025-11-10"), count = 21)

        assertEquals(21, run.size)
        assertEquals("2025-10-21", run.first().date.key)
        assertEquals("2025-11-10", run.last().date.key)
        run.forEachIndexed { index, entry ->
            assertEquals(
                "run must be consecutive at ${entry.date.key}",
                date("2025-10-21").daysSinceEpoch + index,
                entry.date.daysSinceEpoch,
            )
            assertEquals(entry.date.key, helper.start(entry.date), entry.start)
        }
    }

    /** A run containing a skipped date is shorter than requested and omits it. */
    @Test
    fun testRunContainingASkippedDateIsShorterThanRequested() {
        val run = windows("Pacific/Apia").backwardRun(endingAt = date("2012-01-02"), count = 5)

        assertEquals(4, run.size)
        assertEquals("2011-12-29", run.first().date.key)
        assertEquals(
            listOf("2011-12-29", "2011-12-31", "2012-01-01", "2012-01-02"),
            run.map { it.date.key },
        )
    }

    /** A long run lands on the right calendar date, 3999 days before the anchor. */
    @Test
    fun testLongRunReachesTheRightCalendarDate() {
        val run = windows("America/New_York").backwardRun(endingAt = date("2025-11-10"), count = 4000)

        assertEquals(4000, run.size)
        assertEquals("2014-11-29", run.first().date.key)
        assertEquals("2025-11-10", run.last().date.key)
    }

    // MARK: - The sleep read window never extends into the future

    /** The current date's window stops at the reference instant instead of its next start. */
    @Test
    fun testCurrentDatesWindowStopsAtTheReferenceInstant() {
        val helper = windows("America/New_York", reference = utc("2025-11-02T18:00:00Z"))

        val end = helper.sleepReadWindowEnd(date("2025-11-02"))

        assertEquals(utc("2025-11-02T18:00:00Z"), end)
        assertNotEquals(helper.window(date("2025-11-02"))?.nextStart, end)
    }

    /** A past 25-hour day reaches its own next start, 25 hours after it began. */
    @Test
    fun testPastTwentyFiveHourDayReachesItsOwnNextStart() {
        val helper = windows("America/New_York", reference = utc("2025-12-15T12:00:00Z"))

        val end = helper.sleepReadWindowEnd(date("2025-11-02"))
        val window = helper.window(date("2025-11-02"))!!

        assertEquals(window.nextStart, end)
        assertEquals(Duration.ofHours(25), Duration.between(window.start, end))
    }

    // MARK: - The default zone and reference instant are named, not implied

    /** The default zone is the system default zone id named in the design, not a snapshot of it. */
    @Test
    fun testDefaultZoneIsThePlatformsTrackingDeviceZone() {
        assertEquals(ZoneId.systemDefault(), LocalDayWindows.defaultTimeZone)
        assertEquals(ZoneId.systemDefault(), LocalDayWindows().zone)
        assertEquals(ZoneId.systemDefault(), LocalDayWindows(referenceInstant = Instant.now()).zone)
    }

    /**
     * The default reference instant is the current `Instant`, so it lies inside a bracket taken around
     * the call.
     */
    @Test
    fun testDefaultReferenceInstantIsThePlatformsCurrentInstant() {
        val before = Instant.now()
        val accessor = LocalDayWindows.defaultReferenceInstant
        val helperDefault = LocalDayWindows().referenceInstant
        val after = Instant.now()

        assertTrue(accessor >= before)
        assertTrue(accessor <= after)
        assertTrue(helperDefault >= before)
        assertTrue(helperDefault <= after)
    }

    // MARK: - Both platforms agree, proven by a committed oracle

    /**
     * The committed oracle, loaded from the test resources on the classpath.
     *
     * It fails rather than skips when the file is absent: an oracle nobody can find would otherwise let
     * both platforms stay green while they disagree, which is the whole thing this file guards.
     */
    private fun loadOracle(): JSONObject {
        val stream = javaClass.classLoader!!.getResourceAsStream(ORACLE_RESOURCE)
        if (stream == null) {
            fail("committed oracle $ORACLE_RESOURCE not on the test classpath — this test must not pass by default")
        }
        return JSONObject(stream!!.bufferedReader().use { it.readText() })
    }

    /** The oracle's own `start` field, which is JSON null for a date the zone never had. */
    private fun optionalEpochSeconds(record: JSONObject, field: String): Long? =
        if (record.isNull(field)) null else record.getLong(field)

    /**
     * Every value in the committed oracle, re-derived by the twin and compared.
     *
     * The Swift side asserts the same file, so a change on either side reddens one of the two suites.
     * The mismatch note rides along on every assertion message, so a moved value names both database
     * versions rather than only the numbers that differ.
     */
    @Test
    fun testKotlinTestAssertsTheCommittedOracle() {
        val oracle = loadOracle()

        assertFalse(oracle.getString("note").isEmpty())
        val producedBy = oracle.getJSONObject("producedBy")
        assertFalse(producedBy.getString("toolchain").isEmpty())
        assertFalse(producedBy.getString("timeZoneDataVersion").isEmpty())

        val recorded = producedBy.getString("timeZoneDataVersion")
        val note = LocalDayWindows.timeZoneDataVersionNote(
            recorded = recorded,
            observed = LocalDayWindows.observedTimeZoneDataVersion,
        )

        val starts = oracle.getJSONArray("starts")
        assertEquals("oracle section starts", 19, starts.length())
        for (i in 0 until starts.length()) {
            val record = starts.getJSONObject(i)
            val helper = windows(record.getString("zone"))
            val day = date(record.getString("date"))
            val context = "start ${record.getString("zone")} ${day.key} — $note"
            assertEquals(context, optionalEpochSeconds(record, "start"), helper.start(day)?.epochSecond)
        }

        val windowRecords = oracle.getJSONArray("windows")
        assertEquals("oracle section windows", 18, windowRecords.length())
        for (i in 0 until windowRecords.length()) {
            val record = windowRecords.getJSONObject(i)
            val helper = windows(record.getString("zone"))
            val day = date(record.getString("date"))
            val context = "window ${record.getString("zone")} ${day.key} — $note"
            val window = helper.window(day)
            assertNotNull(context, window)
            assertEquals(context, record.getLong("start"), window!!.start.epochSecond)
            assertEquals(context, record.getLong("nextStart"), window.nextStart.epochSecond)
            assertEquals(context, record.getInt("utcOffsetSeconds"), window.utcOffsetSeconds)
            assertEquals(context, record.getLong("durationSeconds"), window.duration.seconds)
        }

        val containing = oracle.getJSONArray("containingDayStarts")
        assertEquals("oracle section containingDayStarts", 8, containing.length())
        for (i in 0 until containing.length()) {
            val record = containing.getJSONObject(i)
            val helper = windows(record.getString("zone"))
            val at = instant(record.getLong("instant"))
            val context = "containing ${record.getString("zone")} ${record.getLong("instant")} — $note"
            assertEquals(context, record.getLong("start"), helper.startOfDay(at).epochSecond)
        }

        val keys = oracle.getJSONArray("dayKeys")
        assertEquals("oracle section dayKeys", 11, keys.length())
        for (i in 0 until keys.length()) {
            val record = keys.getJSONObject(i)
            val helper = windows(record.getString("zone"))
            val at = instant(record.getLong("instant"))
            val context = "key ${record.getString("zone")} ${record.getLong("instant")} — $note"
            assertEquals(context, record.getString("key"), helper.dayKey(at))
        }

        val runs = oracle.getJSONArray("runs")
        assertEquals("oracle section runs", 4, runs.length())
        for (i in 0 until runs.length()) {
            val record = runs.getJSONObject(i)
            val helper = windows(record.getString("zone"))
            val anchor = date(record.getString("endingAt"))
            val requested = record.getInt("requested")
            val context = "run ${record.getString("zone")} ${anchor.key}/$requested — $note"
            val run = helper.backwardRun(endingAt = anchor, count = requested)
            assertEquals(context, record.getInt("size"), run.size)
            for ((edge, entry) in listOf("oldest" to run.firstOrNull(), "newest" to run.lastOrNull())) {
                val expected = record.getJSONObject(edge)
                assertNotNull("$edge $context", entry)
                assertEquals("$edge $context", expected.getString("date"), entry!!.date.key)
                assertEquals("$edge $context", expected.getLong("start"), entry.start.epochSecond)
            }
            // Short runs carry every entry; the 4000-day run carries its edges and its size only, so that
            // the committed file stays reviewable, and says so in `daysTruncated`.
            val days = record.getJSONArray("days")
            if (record.getBoolean("daysTruncated")) {
                assertEquals(context, 0, days.length())
            } else {
                assertEquals(context, run.size, days.length())
                for (d in 0 until days.length()) {
                    val expected = days.getJSONObject(d)
                    assertEquals(context, expected.getString("date"), run[d].date.key)
                    assertEquals(context, expected.getLong("start"), run[d].start.epochSecond)
                }
            }
        }

        val sleepEnds = oracle.getJSONArray("sleepWindowEnds")
        assertEquals("oracle section sleepWindowEnds", 5, sleepEnds.length())
        for (i in 0 until sleepEnds.length()) {
            val record = sleepEnds.getJSONObject(i)
            val helper = windows(
                record.getString("zone"),
                reference = instant(record.getLong("referenceInstant")),
            )
            val day = date(record.getString("date"))
            val context = "sleep end ${record.getString("zone")} ${day.key} — $note"
            assertEquals(context, optionalEpochSeconds(record, "end"), helper.sleepReadWindowEnd(day)?.epochSecond)
        }
    }

    /**
     * The time-zone database version of the JVM this suite runs on, read from
     * `java.time.zone.ZoneRulesProvider.getVersions` — the last key of the map for the zone in use, and
     * `null` where the map is empty or where the read is unavailable at all, so a runner that cannot
     * make it takes the cannot-observe branch below instead of erroring on a non-defect.
     */
    private fun runnerTimeZoneDataVersion(): String? =
        try {
            val versions = Class.forName("java.time.zone.ZoneRulesProvider")
                .getMethod("getVersions", String::class.java)
                .invoke(null, ZoneId.systemDefault().id) as java.util.NavigableMap<*, *>
            if (versions.isEmpty()) null else versions.lastKey() as String?
        } catch (missing: ReflectiveOperationException) {
            null
        } catch (unsupported: RuntimeException) {
            // `ZoneRulesException` for a zone the provider does not know, wrapped or direct.
            null
        }

    /**
     * The mismatch note names the recorded version and the observed one, and says so plainly where the
     * platform has no version of its own to report.
     *
     * The observed version is read but never gated on (D6): the fixtures are past and stable, so a
     * routine runner-image bump must not redden unrelated work.
     */
    @Test
    fun testMismatchNoteNamesBothDatabaseVersions() {
        val observed = LocalDayWindows.timeZoneDataVersionNote(recorded = "2025b", observed = "2025a")
        assertEquals(
            "time-zone database version: the oracle records 2025b; this platform observes 2025a.",
            observed,
        )

        val blind = LocalDayWindows.timeZoneDataVersionNote(recorded = "unavailable", observed = null)
        assertEquals(
            "time-zone database version: the oracle records unavailable; " +
                "this platform cannot observe its own time-zone database version.",
            blind,
        )
        assertTrue(blind.contains("cannot observe"))
        assertTrue(blind.contains("unavailable"))

        // What this JVM reports about itself goes into the note verbatim, whichever branch it takes. The
        // runner's own version is read here independently, and by reflection for the same reason the
        // implementation uses it: `java.time.zone.ZoneRulesProvider` is not on the SDK compile
        // classpath this test source is built against, although the JVM the test runs on has it. What a
        // device returns is unverified here and belongs to A2's device counter-check; where the read
        // cannot be made at all, the `null` branch below asserts the D6 cannot-observe wording.
        val version = runnerTimeZoneDataVersion()
        assertEquals(version, LocalDayWindows.observedTimeZoneDataVersion)
        val live = LocalDayWindows.timeZoneDataVersionNote(recorded = "unavailable", observed = version)
        if (version == null) {
            assertTrue(live.contains("cannot observe its own time-zone database version"))
        } else {
            assertFalse(version.isEmpty())
            assertTrue(live.contains("observes $version"))
            assertEquals(
                "time-zone database version: the oracle records unavailable; this platform observes $version.",
                live,
            )
        }
    }

    private companion object {

        /** The oracle file package 1 committed under the Android test resources. */
        const val ORACLE_RESOURCE = "local_day_windows_oracle.json"
    }
}
