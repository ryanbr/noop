package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** Mirror of the Swift CyclePhaseEngineTests — identical fixtures and expected classifications (parity guard). */
class CyclePhaseEngineTest {

    private fun biphasic(
        cycles: Int,
        cycleLen: Int = 28,
        lutealLen: Int = 12,
        start: String = "2026-01-01",
    ): List<CyclePhaseEngine.Night> {
        val nights = mutableListOf<CyclePhaseEngine.Night>()
        var idx = 0
        repeat(cycles) {
            for (dayInCycle in 0 until cycleLen) {
                val day = CyclePhaseEngine.shiftDay(start, idx)!!
                val luteal = dayInCycle >= (cycleLen - lutealLen)
                val tempZ = if (luteal) 1.4 else -0.2
                val rhrZ = if (luteal) 1.0 else -0.1
                val hrvZ = if (luteal) -1.0 else 0.1
                nights.add(CyclePhaseEngine.Night(day, tempZ, rhrZ, hrvZ))
                idx += 1
            }
        }
        return nights
    }

    @Test fun lutealNightClassifiesLuteal() {
        val r = CyclePhaseEngine.classify(biphasic(3), baselineUsable = true)
        assertEquals(CyclePhaseEngine.Phase.LUTEAL, r.phase)
        assertFalse(r.confidence == CyclePhaseEngine.Confidence.LEARNING)
        assertFalse(r.shiftMarkers.isEmpty())
    }

    @Test fun follicularNightClassifiesFollicular() {
        val nights = biphasic(3).toMutableList()
        val startNext = CyclePhaseEngine.shiftDay(nights.last().day, 1)!!
        for (i in 0 until 8) {
            val day = CyclePhaseEngine.shiftDay(startNext, i)!!
            nights.add(CyclePhaseEngine.Night(day, -0.2, -0.1, 0.1))
        }
        val r = CyclePhaseEngine.classify(nights, baselineUsable = true)
        assertEquals(CyclePhaseEngine.Phase.FOLLICULAR, r.phase)
    }

    @Test fun detectsPlausibleCycleLength() {
        val r = CyclePhaseEngine.classify(biphasic(4, 28), baselineUsable = true)
        assertNotNull(r.cycleLengthDays)
        r.cycleLengthDays?.let {
            assertTrue(it in CyclePhaseEngine.minCycleDays..CyclePhaseEngine.maxCycleDays)
            assertTrue(abs(it - 28) <= 2)
        }
        assertEquals(CyclePhaseEngine.Confidence.SOLID, r.confidence)
    }

    @Test fun cycleDayEstimateIsARangeNotAPoint() {
        val r = CyclePhaseEngine.classify(biphasic(3), baselineUsable = true)
        assertNotNull(r.cycleDayLow)
        assertNotNull(r.cycleDayHigh)
        assertTrue(r.cycleDayLow!! < r.cycleDayHigh!!)
    }

    @Test fun nextPeriodIsAWindow() {
        val r = CyclePhaseEngine.classify(biphasic(4), baselineUsable = true)
        r.nextPeriodWindow?.let {
            assertTrue(it.earliestDay <= it.latestDay)
            assertFalse(it.earliestDay == it.latestDay)
        }
    }

    @Test fun flatSeriesYieldsUnknownNotAPhase() {
        val nights = (0 until 60).map {
            CyclePhaseEngine.Night(CyclePhaseEngine.shiftDay("2026-01-01", it)!!, 0.05, 0.0, 0.0)
        }
        val r = CyclePhaseEngine.classify(nights, baselineUsable = true)
        assertEquals(CyclePhaseEngine.Phase.UNKNOWN, r.phase)
        assertNull(r.cycleLengthDays)
        assertNull(r.nextPeriodWindow)
    }

    @Test fun insufficientDataIsLearning() {
        val r = CyclePhaseEngine.classify(biphasic(1, 28), baselineUsable = true)
        assertEquals(CyclePhaseEngine.Phase.LEARNING, r.phase)
        assertEquals(CyclePhaseEngine.Confidence.LEARNING, r.confidence)
    }

    @Test fun unusableBaselineIsLearning() {
        val r = CyclePhaseEngine.classify(biphasic(3), baselineUsable = false)
        assertEquals(CyclePhaseEngine.Phase.LEARNING, r.phase)
    }

    @Test fun loggedPeriodMistimedIsFlagged() {
        val nights = biphasic(3)
        val lastDay = nights.last().day
        val badStart = CyclePhaseEngine.shiftDay(lastDay, -50)!!
        val r = CyclePhaseEngine.classify(nights, baselineUsable = true, loggedPeriodStarts = listOf(badStart))
        assertTrue(r.note.lowercase().contains("logged"))
    }

    @Test fun noFertilityOrContraceptionLanguage() {
        val banned = listOf("fertile", "fertility", "safe day", "safe days", "ovulation prediction",
            "contracept", "conceive", "conception", "pregnan")
        val flat = (0 until 60).map {
            CyclePhaseEngine.Night(CyclePhaseEngine.shiftDay("2026-01-01", it)!!, 0.05, 0.0, 0.0)
        }
        val follicular = biphasic(3).toMutableList().also { list ->
            val startNext = CyclePhaseEngine.shiftDay(list.last().day, 1)!!
            for (i in 0 until 8) {
                list.add(CyclePhaseEngine.Night(CyclePhaseEngine.shiftDay(startNext, i)!!, -0.2, -0.1, 0.1))
            }
        }
        for (nights in listOf(biphasic(3), follicular, flat)) {
            val note = CyclePhaseEngine.classify(nights, baselineUsable = true).note.lowercase()
            for (b in banned) assertFalse("note contained $b: $note", note.contains(b))
        }
        val awareness = CyclePhaseEngine.awarenessLine.lowercase()
        for (b in banned) {
            if (b == "contracept") continue
            assertFalse(awareness.contains(b))
        }
        assertTrue(CyclePhaseEngine.awarenessLine.contains("not contraception"))
    }

    @Test fun fusedIndexNegatesHrvAndRenormalises() {
        assertEquals(1.5, CyclePhaseEngine.fusedIndex(1.5, null, null)!!, 1e-9)
        assertEquals(1.0, CyclePhaseEngine.fusedIndex(1.0, 1.0, -1.0)!!, 1e-9)
        assertNull(CyclePhaseEngine.fusedIndex(null, null, null))
    }
}
