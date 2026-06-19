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
}
