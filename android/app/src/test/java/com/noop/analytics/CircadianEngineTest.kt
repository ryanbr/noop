package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos

/** Mirror of the Swift CircadianEngineTests — identical math fixtures and expected values (parity guard). */
class CircadianEngineTest {

    private fun profile(mesor: Double, amp: Double, acrophase: Double): List<CircadianEngine.ActivityBin> =
        (0 until 24).map { h ->
            val v = mesor + amp * cos(2.0 * PI * (h - acrophase) / 24.0)
            CircadianEngine.ActivityBin(h.toDouble(), v)
        }

    @Test fun cosinorRecoversInjectedParameters() {
        val fit = CircadianEngine.cosinor(profile(50.0, 30.0, 15.0))!!
        assertEquals(50.0, fit.mesor, 1e-6)
        assertEquals(30.0, fit.amplitude, 1e-6)
        assertEquals(15.0, fit.acrophaseHours, 1e-6)
    }

    @Test fun cosinorAcrophaseWrapsIntoDay() {
        val fit = CircadianEngine.cosinor(profile(10.0, 5.0, 23.0))!!
        assertEquals(23.0, fit.acrophaseHours, 1e-6)
        assertTrue(fit.acrophaseHours in 0.0..24.0)
    }

    @Test fun cosinorRejectsTooFewPoints() {
        assertNull(CircadianEngine.cosinor(listOf(
            CircadianEngine.ActivityBin(1.0, 1.0), CircadianEngine.ActivityBin(2.0, 2.0))))
    }

    @Test fun strongRhythmEnoughDaysIsSolid() {
        val est = CircadianEngine.estimatePhase(profile(50.0, 30.0, 15.0), 20, 7.0)!!
        assertEquals(CircadianEngine.PhaseConfidence.SOLID, est.confidence)
        assertEquals(3.0, est.tempMinHour, 1e-6)
    }

    @Test fun thinDataIsUnreadable() {
        val est = CircadianEngine.estimatePhase(profile(50.0, 30.0, 15.0), 4, 7.0)!!
        assertEquals(CircadianEngine.PhaseConfidence.UNREADABLE, est.confidence)
        assertTrue(est.note.lowercase().contains("hard to read"))
    }

    @Test fun arrhythmicProfileIsUnreadable() {
        val est = CircadianEngine.estimatePhase(profile(50.0, 0.5, 15.0), 30, 7.0)!!
        assertEquals(CircadianEngine.PhaseConfidence.UNREADABLE, est.confidence)
    }

    @Test fun observedTempMinOverridesDerived() {
        val est = CircadianEngine.estimatePhase(profile(50.0, 30.0, 15.0), 20, 7.0, observedTempMinHour = 4.5)!!
        assertEquals(4.5, est.tempMinHour, 1e-9)
    }

    @Test fun eastwardAdvancePlanUsesMorningLight() {
        val plan = CircadianEngine.planShift(3.0, 23.0, 7.0)
        assertEquals(CircadianEngine.ShiftDirection.ADVANCE, plan.direction)
        assertEquals(3, plan.estimatedDays)
        assertEquals(3, plan.days.size)
        val last = plan.days.last()
        assertEquals(20.0, last.targetSleepHour, 1e-9)
        assertEquals(4.0, last.targetWakeHour, 1e-9)
        assertEquals(4.0, last.brightLightStartHour, 1e-9)
        assertTrue(last.guidance.contains("bright light early"))
    }

    @Test fun westwardDelayPlanUsesEveningLight() {
        val plan = CircadianEngine.planShift(-2.0, 23.0, 7.0)
        assertEquals(CircadianEngine.ShiftDirection.DELAY, plan.direction)
        assertEquals(2, plan.estimatedDays)
        val last = plan.days.last()
        assertEquals(1.0, last.targetSleepHour, 1e-9)
        assertEquals(9.0, last.targetWakeHour, 1e-9)
        assertTrue(last.guidance.contains("bright light in the evening"))
    }

    @Test fun noShiftNeededReturnsNonePlan() {
        val plan = CircadianEngine.planShift(0.2, 23.0, 7.0)
        assertEquals(CircadianEngine.ShiftDirection.NONE, plan.direction)
        assertTrue(plan.days.isEmpty())
    }

    @Test fun planNeverMentionsSupplements() {
        val banned = listOf("melatonin", "supplement", "pill", "drug", "caffeine pill", "medication")
        for (shift in listOf(3.0, -3.0, 6.0, -1.0)) {
            val plan = CircadianEngine.planShift(shift, 23.0, 7.0)
            var text = plan.note.lowercase()
            for (d in plan.days) text += " " + d.guidance.lowercase()
            for (b in banned) assertFalse("plan mentioned $b", text.contains(b))
        }
    }

    @Test fun steppedAtOneHourPerDay() {
        val plan = CircadianEngine.planShift(6.0, 23.0, 7.0)
        assertEquals(6, plan.estimatedDays)
        assertEquals(6, plan.days.size)
    }

    @Test fun clockFormatting() {
        assertEquals("20:00", CircadianEngine.clock(20.0))
        assertEquals("23:30", CircadianEngine.clock(23.5))
        assertEquals("23:00", CircadianEngine.clock(-1.0))
        assertEquals("07:15", CircadianEngine.clock(7.25))
    }

    // ── #982: what the RELATIVE gate costs, in bpm, at a real HR mesor ──

    /**
     * The engine is fed mean HEART RATE, not the motion volume its doc used to claim, and
     * [CircadianEngine.minRelativeAmplitude] gates on `amplitude / |mesor|`. Against a signal carrying a
     * ~45-75 bpm DC offset that makes the real bar an ABSOLUTE `0.10 x mesor` bpm.
     *
     * The pair that matters is [theSameSwingIsReadableAtALowerMesor]: the SAME 5 bpm swing is arrhythmic
     * at a 65 bpm mesor and readable at 45, so the bar scales WITH the mesor and a low-resting wearer
     * faces a LOWER absolute requirement. #982 raised the opposite concern. Pinned so the direction is a
     * fact rather than an argument. Twin of the Swift `CircadianEngineTests` pair.
     */
    private fun confidence(mesor: Double, amp: Double): CircadianEngine.PhaseConfidence =
        CircadianEngine.estimatePhase(
            profile(mesor, amp, 16.0),
            CircadianEngine.goodDaysForFit,
            7.0,
        )!!.confidence

    @Test fun aProportionalSwingStillPasses() {
        assertTrue(confidence(65.0, 8.0) != CircadianEngine.PhaseConfidence.UNREADABLE)   // 0.123
    }

    /**
     * The inconsistency the absolute floor removes. This pair USED to assert that 5 bpm was arrhythmic at
     * a 65 bpm mesor and rhythmic at 45 — the same swing, opposite verdicts, decided by the baseline
     * rather than by the rhythm. Both now read rhythmic.
     */
    @Test fun theSameSwingNoLongerDependsOnTheBaseline() {
        assertTrue(confidence(45.0, 5.0) != CircadianEngine.PhaseConfidence.UNREADABLE)
        assertTrue(confidence(65.0, 5.0) != CircadianEngine.PhaseConfidence.UNREADABLE)
        assertTrue(confidence(80.0, 5.0) != CircadianEngine.PhaseConfidence.UNREADABLE)
    }

    /** A genuinely flat rhythm is still refused — the floor widens the gate, it does not remove it. */
    @Test fun aFlatRhythmIsStillArrhythmicOnBothMeasures() {
        assertEquals(CircadianEngine.PhaseConfidence.UNREADABLE, confidence(45.0, 4.0))   // 0.089, 4.0 bpm
        assertEquals(CircadianEngine.PhaseConfidence.UNREADABLE, confidence(65.0, 4.0))   // 0.062, 4.0 bpm
        assertEquals(CircadianEngine.PhaseConfidence.UNREADABLE, confidence(74.7, 3.0))
    }

    /**
     * The absolute floor's own boundary, isolated: at a 74.7 bpm mesor the relative test cannot pass
     * either value (0.061 and 0.059 against 0.10), so only [CircadianEngine.minAbsoluteAmplitudeBpm]
     * decides. Expressed RELATIVE to the constant so the test follows it, and with a 0.1 bpm margin
     * either side rather than testing the exact value — the cosinor recovers amplitude to ~1e-9, and a
     * test sitting exactly on `>=` would be pinning float recovery rather than the threshold.
     */
    @Test fun theAbsoluteFloorIsWhereItSays() {
        val floor = CircadianEngine.minAbsoluteAmplitudeBpm
        assertTrue(confidence(74.7, floor + 0.1) != CircadianEngine.PhaseConfidence.UNREADABLE)
        assertEquals(CircadianEngine.PhaseConfidence.UNREADABLE, confidence(74.7, floor - 0.1))
    }

    /**
     * The widening must not hand a thinner fit a FIRMER label. A rhythm admitted only by the absolute
     * floor caps at WIDE, which is what withholds [CircadianEngine.chronotype] — that names a category
     * off an acrophase a small swing pins loosely. A proportional rhythm still reaches SOLID.
     */
    @Test fun anAbsoluteOnlyRhythmIsReadableButNotSolid() {
        assertEquals(CircadianEngine.PhaseConfidence.WIDE, confidence(74.7, 5.5))   // 0.073 - floor only
        assertEquals(CircadianEngine.PhaseConfidence.SOLID, confidence(65.0, 8.0))  // 0.123 - proportional
        val wide = CircadianEngine.estimatePhase(profile(74.7, 5.5, 16.0), CircadianEngine.goodDaysForFit, 7.0)!!
        assertNull("a floor-only fit must not name a chronotype", CircadianEngine.chronotype(wide))
    }

    /**
     * The measured wearer this change exists for: 5.5 bpm on a 74.7 bpm mesor, which the relative test
     * refused at 7.3% against its 10% bar while the acrophase implied a textbook CBTmin near 04:06.
     */
    @Test fun theMeasuredWearerIsNoLongerSilenced() {
        assertTrue(confidence(74.7, 5.5) != CircadianEngine.PhaseConfidence.UNREADABLE)
    }

    // ---- chronotype lean (absolute phase, not schedule-relative) ----

    /**
     * VERBATIM stdout of the Swift twin's arithmetic compiled standalone (`swiftc -O`), pinned per
     * CLAUDE.md's byte-parity rule. Format: label|tempMinHour|signedDelta|lean.
     *
     * The `late-evening-wrap` row is the one that earns its place: 23:30 is five hours BEFORE the 04:30
     * anchor, so it is a strong MORNING lean. A naive `23.5 > 5.5` bucket would call it evening, and
     * reading the two implementations side by side would not settle which one is right.
     *
     * The antipode pair is pinned because it LOOKS like a bug and is not: 16.5 reads evening and 16.6
     * reads morning, because 16:30 is exactly half a day from the anchor and either direction is equally
     * far. Inherent to a circular bucket, unreachable in practice (a 16:30 CBTmin is not a physiology),
     * and pinned so nobody "corrects" the wrap and breaks the 23:30 case with it.
     */
    private val chronotypeOracle = """
        anchor|4.5|0.0|intermediate
        band-early-edge|3.5|-1.0|intermediate
        just-morning|3.49|-1.0099999999999998|morning
        band-late-edge|5.5|1.0|intermediate
        just-evening|5.51|1.0099999999999998|evening
        late-evening-wrap|23.5|-5.0|morning
        midnight|0.0|-4.5|morning
        noon|12.0|7.5|evening
        antipode|16.5|12.0|evening
        just-before-antipode|16.4|11.899999999999999|evening
        just-past-antipode|16.6|-11.899999999999999|morning
        over-24-input|28.5|0.0|intermediate
        negative-input|-1.0|-5.5|morning
    """.trimIndent()

    @Test
    fun chronotypeMatchesTheSwiftOracleExactly() {
        assertEquals("the anchor is derived from the engine's own constants, not hardcoded",
            4.5, CircadianEngine.chronotypeAnchorHour, 0.0)
        for (row in chronotypeOracle.lines().map { it.trim() }.filter { it.isNotEmpty() }) {
            val (label, hourText, deltaText, leanText) = row.split("|")
            val hour = hourText.toDouble()
            assertEquals(
                "$label: signed delta from the anchor",
                deltaText.toDouble(),
                CircadianEngine.signedHourDelta(CircadianEngine.chronotypeAnchorHour, CircadianEngine.wrap24(hour)),
                0.0,
            )
            assertEquals("$label: lean", leanText, CircadianEngine.chronotype(hour).raw)
        }
    }

    /**
     * A NAMED category reads as a fact about the person rather than a reading of the week, so it waits
     * for the strongest tier — unlike the continuous offset the card already shows at WIDE.
     */
    @Test
    fun chronotypeIsNamedOnlyForASolidFit() {
        fun estimate(confidence: CircadianEngine.PhaseConfidence) = CircadianEngine.PhaseEstimate(
            tempMinHour = 23.5, acrophaseHours = 11.5, offsetVsScheduleMinutes = 0.0,
            confidence = confidence, note = "",
        )
        assertEquals(CircadianEngine.Chronotype.MORNING,
            CircadianEngine.chronotype(estimate(CircadianEngine.PhaseConfidence.SOLID)))
        assertNull("a thin fit must not name a chronotype",
            CircadianEngine.chronotype(estimate(CircadianEngine.PhaseConfidence.WIDE)))
        assertNull(CircadianEngine.chronotype(estimate(CircadianEngine.PhaseConfidence.UNREADABLE)))
    }

    /**
     * The schedule-relative offset CANNOT name a chronotype, which is why this is bucketed from the
     * absolute phase instead. A consistent 03:00-11:00 sleeper is well aligned with their OWN schedule —
     * offset ~0 — while being strongly evening-type by the clock.
     */
    @Test
    fun aConsistentLateSleeperIsEveningTypeDespiteAZeroScheduleOffset() {
        val alignedButLate = CircadianEngine.PhaseEstimate(
            tempMinHour = 8.0, acrophaseHours = 20.0, offsetVsScheduleMinutes = 0.0,
            confidence = CircadianEngine.PhaseConfidence.SOLID, note = "",
        )
        assertEquals(CircadianEngine.Chronotype.EVENING, CircadianEngine.chronotype(alignedButLate))
    }

    /**
     * VERBATIM stdout of the Swift twin compiled standalone. Format:
     * label|tempMinHour|durationHours|bedHour|wakeHour ("nil" for a rejected duration).
     *
     * `typical` is the row that says the model is sane: a 04:30 temperature minimum and an 8 h night put
     * the ideal window at 23:00-07:00. The wrap rows matter because the ideal bedtime routinely lands on
     * the PREVIOUS day, so a subtraction without wrap24 would place it at a negative hour.
     */
    private val idealWindowOracle = """
        typical|4.5|8.0|23.0|7.0
        short-night|4.5|5.0|2.0|7.0
        long-night|4.5|10.0|21.0|7.0
        evening-type|7.0|8.0|1.5|9.5
        morning-type|2.0|8.0|20.5|4.5
        wrap-past-midnight|1.0|8.0|19.5|3.5
        tempmin-late-evening|23.0|8.0|17.5|1.5
        duration-just-under-24|4.5|23.9|7.100000000000001|7.0
        zero-duration|4.5|0.0|nil|nil
        negative-duration|4.5|-1.0|nil|nil
        24h-duration|4.5|24.0|nil|nil
    """.trimIndent()

    @Test
    fun idealSleepWindowMatchesTheSwiftOracleExactly() {
        for (row in idealWindowOracle.lines().map { it.trim() }.filter { it.isNotEmpty() }) {
            val parts = row.split("|")
            val (label, tempText, durText) = Triple(parts[0], parts[1], parts[2])
            val w = CircadianEngine.idealSleepWindow(tempText.toDouble(), durText.toDouble())
            if (parts[3] == "nil") {
                assertNull("$label: an impossible duration cannot be placed on the ring", w)
            } else {
                assertEquals("$label: bed hour", parts[3].toDouble(), w!!.bedHour, 0.0)
                assertEquals("$label: wake hour", parts[4].toDouble(), w.wakeHour, 0.0)
            }
        }
    }

    /**
     * The ideal arc takes the night's OWN length, so the dial compares PHASE alone. A short night and a
     * long one on the same body clock share a wake time and differ only in where the arc starts — which
     * is what keeps a sleep DEBT from rendering as a body-clock problem.
     */
    @Test
    fun idealWindowSharesTheWakeAnchorAcrossDurations() {
        val short = CircadianEngine.idealSleepWindow(4.5, 5.0)!!
        val long = CircadianEngine.idealSleepWindow(4.5, 10.0)!!
        assertEquals("both nights wake at the same clock time", short.wakeHour, long.wakeHour, 0.0)
        assertTrue("only the bedtime moves", short.bedHour != long.bedHour)
    }

    /**
     * The dial's caption quantity: how far the night actually slept sits from where the CLOCK wanted it.
     * Verbatim Swift stdout. Format: label|tempMinHour|actualWakeHour|offsetHours.
     *
     * `wrap-late` is the row that earns its place — a 23:00 temperature minimum puts the ideal wake at
     * 01:30, so waking at 02:30 is one hour LATE, not twenty-three hours early.
     */
    @Test
    fun sleepWindowOffsetMatchesTheSwiftOracleExactly() {
        val oracle = """
            on-time|4.5|7.0|0.0
            late-1h|4.5|8.0|1.0
            early-1h|4.5|6.0|-1.0
            wrap-late|23.0|2.5|1.0
            wrap-early|1.0|23.0|-4.5
            antipode|4.5|19.0|12.0
        """.trimIndent()
        for (row in oracle.lines().map { it.trim() }.filter { it.isNotEmpty() }) {
            val p = row.split("|")
            assertEquals("${p[0]}: offset hours", p[3].toDouble(),
                CircadianEngine.sleepWindowOffsetHours(p[1].toDouble(), p[2].toDouble()), 0.0)
        }
    }

    /**
     * The dial's caption and the card's existing headline measure DIFFERENT things and must not be
     * conflated: a consistent late sleeper is well-aligned with their own schedule (offset ~0) while
     * sleeping hours away from what their clock wants. Pinned so the two never get merged by a refactor.
     */
    @Test
    fun windowOffsetAndScheduleOffsetAreDifferentQuantities() {
        // body clock at 08:00, so the clock wants a 10:30 wake; this sleeper wakes at 06:30.
        val windowOffset = CircadianEngine.sleepWindowOffsetHours(tempMinHour = 8.0, actualWakeHour = 6.5)
        assertEquals(-4.0, windowOffset, 1e-12)
        val scheduleAligned = CircadianEngine.PhaseEstimate(
            tempMinHour = 8.0, acrophaseHours = 20.0, offsetVsScheduleMinutes = 0.0,
            confidence = CircadianEngine.PhaseConfidence.SOLID, note = "",
        )
        assertEquals("schedule-relative reads aligned", 0.0, scheduleAligned.offsetVsScheduleMinutes, 0.0)
        assertTrue("while the clock-relative read is hours away", kotlin.math.abs(windowOffset) > 1.0)
    }
}
