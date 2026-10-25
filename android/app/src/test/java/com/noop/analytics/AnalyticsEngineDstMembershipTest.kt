package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId

/**
 * #2694, the evidence #2517 asked for before any day-model decision: WHICH samples land in which day when
 * a flat 86,400-second window scores a 23- or 25-hour local day.
 *
 * This characterises the CURRENT answer and is expected to change when the day policy does. Every
 * expectation is the compiled Swift engine's own output, pasted verbatim. Swift twin:
 * `AnalyticsEngineDstMembershipTests`.
 *
 * Distinct from its two neighbours, which is why it is its own file. `AnalyticsEngineDayBoundsTest` pins
 * the #996 integer-bounds equivalence and says nothing about transitions.
 * `AnalyticsEngineDayWindowSkewTest` pins the day's LENGTH on a transition. Neither says how many samples
 * move, which is the question a policy decision needs answered.
 */
class AnalyticsEngineDstMembershipTest {

    /**
     * One transition day, scored at one of the two offsets in effect around it. `before` threads the
     * offset at the day's first instant, `after` the one past the transition; a real pass captures ONE
     * offset for its whole run, so both are reachable depending on when it runs.
     */
    private data class Vector(val zone: String, val day: String, val whichOffset: String)

    private val vectors = listOf(
        Vector("America/New_York", "2025-03-09", "before"),
        Vector("America/New_York", "2025-03-09", "after"),
        Vector("America/New_York", "2025-11-02", "before"),
        Vector("America/New_York", "2025-11-02", "after"),
        Vector("Pacific/Auckland", "2026-09-27", "before"),
        Vector("Pacific/Auckland", "2026-09-27", "after"),
        Vector("Pacific/Auckland", "2027-04-04", "before"),
        Vector("Pacific/Auckland", "2027-04-04", "after"),
    )

    /**
     * One line per vector, in the order above, captured from the compiled Swift engine.
     *
     * THE SHAPE IS THE FINDING. A flat window always scores 1,440 minutes, so a 23-hour day (1,380 real
     * minutes) PULLS IN 60 minutes from a neighbour, and a 25-hour day (1,500 real minutes) MISSES 60 of
     * its own. Which side depends only on which offset the pass captured.
     *
     * These expectations characterise TODAY's behaviour and must be replaced, not defended, when the day
     * policy changes.
     */
    private val expected = listOf(
        "America/New_York 2025-03-09 offset=before(-18000) realS=82800 realMin=1380 scoredMin=1440 " +
            "missedStart=0 missedEnd=0 pulledPrev=0 pulledNext=60 steps=10073",
        "America/New_York 2025-03-09 offset=after(-14400) realS=82800 realMin=1380 scoredMin=1440 " +
            "missedStart=0 missedEnd=0 pulledPrev=60 pulledNext=0 steps=10073",
        "America/New_York 2025-11-02 offset=before(-14400) realS=90000 realMin=1500 scoredMin=1440 " +
            "missedStart=0 missedEnd=60 pulledPrev=0 pulledNext=0 steps=10073",
        "America/New_York 2025-11-02 offset=after(-18000) realS=90000 realMin=1500 scoredMin=1440 " +
            "missedStart=60 missedEnd=0 pulledPrev=0 pulledNext=0 steps=10073",
        "Pacific/Auckland 2026-09-27 offset=before(43200) realS=82800 realMin=1380 scoredMin=1440 " +
            "missedStart=0 missedEnd=0 pulledPrev=0 pulledNext=60 steps=10073",
        "Pacific/Auckland 2026-09-27 offset=after(46800) realS=82800 realMin=1380 scoredMin=1440 " +
            "missedStart=0 missedEnd=0 pulledPrev=60 pulledNext=0 steps=10073",
        "Pacific/Auckland 2027-04-04 offset=before(46800) realS=90000 realMin=1500 scoredMin=1440 " +
            "missedStart=0 missedEnd=60 pulledPrev=0 pulledNext=0 steps=10073",
        "Pacific/Auckland 2027-04-04 offset=after(43200) realS=90000 realMin=1500 scoredMin=1440 " +
            "missedStart=60 missedEnd=0 pulledPrev=0 pulledNext=0 steps=10073",
    )

    private data class Measured(
        val offsetSec: Long,
        val realSeconds: Long,
        val realMinutes: Int,
        val scoredMinutes: Int,
        val missedAtStart: Int,
        val missedAtEnd: Int,
        val pulledFromPrevious: Int,
        val pulledFromNext: Int,
        val scoredSteps: Int,
        /**
         * The total the REAL local day would have produced, over exactly the samples inside it.
         *
         * This comparison is the one the first version of this file did not make, and #2694 is what
         * supplied it. Without it the scored total looks invariant, because it IS invariant across the
         * two offsets; what it is not is correct.
         */
        val realDaySteps: Int,
    )

    private fun measure(v: Vector): Measured {
        val zone = ZoneId.of(v.zone)
        val helper = LocalDayWindows(zone = zone, referenceInstant = Instant.ofEpochSecond(3_000_000_000L))
        val parts = v.day.split("-").map { it.toInt() }
        val date = LocalCalendarDate(year = parts[0], month = parts[1], day = parts[2])
        val window = requireNotNull(helper.window(date)) { "${v.zone} ${v.day}" }
        val realStart = window.start.epochSecond
        val realEnd = window.nextStart.epochSecond
        val offsetSec = if (v.whichOffset == "before") {
            zone.rules.getOffset(window.start).totalSeconds.toLong()
        } else {
            zone.rules.getOffset(window.nextStart).totalSeconds.toLong()
        }

        // Minute-spaced samples across the real local day with two hours of spill either side, so a
        // window that reaches past a boundary has something to find there.
        val planted = (realStart - 7_200 until realEnd + 7_200 step 60).toList()
        val inRealDay = planted.filter { it >= realStart && it < realEnd }
        // The SHIPPED rule, exactly as the engine applies it.
        val scored = planted.filter { AnalyticsEngine.dayString(it, offsetSec) == v.day }

        var counter = 1_000
        val daySteps = planted.map { ts ->
            counter += 7
            StepSample(deviceId = "t", ts = ts, counter = counter and 0xFFFF)
        }
        val dayHr = planted.map { HrSample(deviceId = "t", ts = it, bpm = 60) }
        val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
        val result = AnalyticsEngine.analyzeDay(
            day = v.day, dayHr = dayHr, daySteps = daySteps,
            profile = profile, tzOffsetSeconds = offsetSec,
        )

        val scoredSet = scored.toSet()
        val realSet = inRealDay.toSet()
        val scoredMin = scored.minOrNull() ?: realStart
        val scoredMax = scored.maxOrNull() ?: realEnd
        return Measured(
            offsetSec = offsetSec,
            realSeconds = realEnd - realStart,
            realMinutes = inRealDay.size,
            scoredMinutes = scored.size,
            missedAtStart = (realSet - scoredSet).count { it < scoredMin },
            missedAtEnd = (realSet - scoredSet).count { it > scoredMax },
            pulledFromPrevious = (scoredSet - realSet).count { it < realStart },
            pulledFromNext = (scoredSet - realSet).count { it >= realEnd },
            scoredSteps = result.daily.steps ?: -1,
            realDaySteps = StepsCounter.stepsInWindow(daySteps.filter { it.ts in realSet }) ?: -1,
        )
    }

    private fun line(v: Vector, m: Measured): String =
        "${v.zone} ${v.day} offset=${v.whichOffset}(${m.offsetSec}) " +
            "realS=${m.realSeconds} realMin=${m.realMinutes} scoredMin=${m.scoredMinutes} " +
            "missedStart=${m.missedAtStart} missedEnd=${m.missedAtEnd} " +
            "pulledPrev=${m.pulledFromPrevious} pulledNext=${m.pulledFromNext} " +
            "steps=${m.scoredSteps}"

    @Test
    fun theFlatWindowsMembershipErrorIsPinnedAtEveryEdge() {
        val produced = vectors.map { line(it, measure(it)) }
        assertEquals(
            "the day model's membership moved; replace these expectations deliberately",
            expected,
            produced,
        )
    }

    /**
     * The scored total is INDEPENDENT of which offset the pass captured, and WRONG against the day it
     * names. Both halves matter, and the first version of this test asserted only the first.
     *
     * CORRECTING WHAT THIS FILE ORIGINALLY CLAIMED. It asserted that the total is identical across all
     * eight vectors, which is true, and concluded from that "the error is invisible in the size of what a
     * day reports" and that nobody could have found it by reading step or calorie numbers. That
     * conclusion was false, and the omission behind it was never comparing against the real local day at
     * all. A flat window scores 1,440 minutes at either offset, so of course the two offsets agree; the
     * true 23-hour day holds 1,380 of those minutes and the true 25-hour day 1,500, and the totals differ
     * accordingly. @kavemang made exactly that comparison in #2694 and it is what disproved the claim.
     *
     * So the real shape is a SIGNED error with a direction: a short day over-reports, because the window
     * reaches into a neighbour, and a long day under-reports, because the window stops short of its own
     * end. That is visible in a day's numbers, and it is why #2694's vectors assert
     * `scoredTicks != calendarTicks` rather than treating the totals as untouched.
     *
     * The recorded line in #2855 is still a log line rather than a field on the day, but for a narrower
     * reason than originally given: the hour is misplaced rather than lost, so there is no single day
     * whose number can be marked wrong without deciding where the hour belongs, which is the policy
     * question #2517 settled by leaving it where it is.
     */
    @Test
    fun theScoredTotalIsOffsetIndependentAndWrongAgainstTheRealDay() {
        val totals = HashSet<Int>()
        val scoredMinutes = HashSet<Int>()
        val realMinutes = HashSet<Int>()
        for (v in vectors) {
            val m = measure(v)
            totals.add(m.scoredSteps)
            scoredMinutes.add(m.scoredMinutes)
            realMinutes.add(m.realMinutes)

            // The half that was missing: the scored total against the day it claims to describe.
            assertNotEquals(
                "${v.zone} ${v.day} ${v.whichOffset}: the fixture must expose the discrepancy, or this " +
                    "vector proves nothing",
                m.realDaySteps.toLong(),
                m.scoredSteps.toLong(),
            )
            if (m.realMinutes < 1_440) {
                assertTrue(
                    "${v.day}: a 23-hour day OVER-reports, the window reaching into a neighbour",
                    m.scoredSteps > m.realDaySteps,
                )
            } else {
                assertTrue(
                    "${v.day}: a 25-hour day UNDER-reports, the window stopping short of its own end",
                    m.scoredSteps < m.realDaySteps,
                )
            }
        }
        assertEquals("a flat window always scores a flat 1,440 minutes", setOf(1_440), scoredMinutes)
        assertEquals(
            "the fixtures must cover both a short and a long day",
            setOf(1_380, 1_500),
            realMinutes,
        )
        assertEquals(
            "the scored total is the same at either offset, because both score 1,440 minutes. That is " +
                "offset-independence and NOT correctness: see the per-vector comparisons above.",
            1,
            totals.size,
        )
    }
}
