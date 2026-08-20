package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kotlin parity for StrandAnalytics/CaptureAccumulatorTests.swift (#965): each active mode's captured-day
 * count is the number of DISTINCT days that mode produced its own trace on, read off the shareable log, so
 * Sleep / Battery / Steps accumulate INDEPENDENTLY rather than sharing one elapsed-clock number. Same
 * vectors + expectations as the Swift twin.
 */
class CaptureAccumulatorTest {

    private val report = """
        [sleep] gate run=0 spanS=1163 DROPPED gate=minSleepMin spanMin=19 minSleepMin=60
        sleep day=2026-07-02 totalSleepMin=131 matched=3 source=computed
        sleep day=2026-07-01 totalSleepMin=331 matched=1 source=computed
        sleep day=2026-06-30 totalSleepMin=381 matched=1 source=computed
        [steps] stepsRaw day=2026-07-02 counterSamples=29248 firstCounter=65046 lastCounter=5336
        [steps] stepsRaw day=2026-07-01 counterSamples=1000
        [battery] bank soc=26.0 t=1782957600s
        [battery] bank soc=25.0 t=1782961200s
        [battery] bank soc=24.0 t=1782964800s
        [universal] dayOwner day=2026-07-02 readId=my-whoop writeActiveId=my-whoop hrRows=120 provenance=measured
        [universal] dayOwner day=2026-07-01 readId=my-whoop writeActiveId=my-whoop hrRows=120 provenance=measured
    """.trimIndent()

    @Test
    fun sleep_countsDistinctNights() {
        assertEquals(3, CaptureAccumulator.capturedDays(TestDomain.SLEEP, report, 0L))
    }

    @Test
    fun steps_countsDistinctDays() {
        assertEquals(2, CaptureAccumulator.capturedDays(TestDomain.STEPS, report, 0L))
    }

    @Test
    fun battery_foldsEpochSamplesToOneDay() {
        assertEquals(1, CaptureAccumulator.capturedDays(TestDomain.BATTERY, report, 0L))
    }

    @Test
    fun universal_countsScoredDays() {
        assertEquals(2, CaptureAccumulator.capturedDays(TestDomain.UNIVERSAL, report, 0L))
    }

    @Test
    fun modesAccumulateIndependently() {
        assertEquals(3, CaptureAccumulator.capturedDays(TestDomain.SLEEP, report, 0L))
        assertEquals(2, CaptureAccumulator.capturedDays(TestDomain.STEPS, report, 0L))
        assertEquals(1, CaptureAccumulator.capturedDays(TestDomain.BATTERY, report, 0L))
    }

    @Test
    fun deadTraceIsZero() {
        val onlyBattery = "[battery] bank soc=50.0 t=1782957600s"
        assertEquals(0, CaptureAccumulator.capturedDays(TestDomain.SLEEP, onlyBattery, 0L))
        assertEquals(0, CaptureAccumulator.capturedDays(TestDomain.STEPS, onlyBattery, 0L))
    }

    @Test
    fun unmarkedDomainIsZero() {
        assertEquals(0, CaptureAccumulator.capturedDays(TestDomain.CONNECTION, report, 0L))
    }

    @Test
    fun dayKeyDoesNotLeakAcrossModes() {
        val cross =
            "[workouts] autoDetect day=2026-07-05 windows=1\n" +
                "sleep day=2026-07-02 totalSleepMin=100 matched=1 source=computed"
        assertEquals(1, CaptureAccumulator.capturedDays(TestDomain.SLEEP, cross, 0L))
    }

    @Test
    fun battery_localDayFold() {
        // 1782957600 = 2026-07-02 02:00 UTC. At UTC-9h (-32400s) it is 2026-07-01 17:00 local => prior day.
        val one = "[battery] bank soc=40.0 t=1782957600s"
        assertEquals(setOf("2026-07-02"), CaptureAccumulator.capturedDayKeys(TestDomain.BATTERY, one, 0L))
        assertEquals(setOf("2026-07-01"), CaptureAccumulator.capturedDayKeys(TestDomain.BATTERY, one, -32400L))
    }

    /**
     * #1468 follow-up: the String and List overloads must find the same days. The Test Centre now scans the
     * line list it already holds rather than joining it so this could split it again; if the two ever
     * disagreed, a guided capture's "K of N days" would depend on which caller asked.
     */
    @Test
    fun stringAndLineOverloadsAgree() {
        val lines = listOf(
            "[recovery] charge day=2026-08-18 score=61.0 band=yellow",
            "noise that carries no marker",
            "[recovery] charge day=2026-08-19 score=62.5 band=yellow",
            "[recovery] charge day=2026-08-19 score=63.0 band=yellow",
        )
        val fromLines = CaptureAccumulator.capturedDayKeys(TestDomain.RECOVERY, lines, 0L)
        val fromText = CaptureAccumulator.capturedDayKeys(TestDomain.RECOVERY, lines.joinToString("\n"), 0L)
        assertEquals(fromText, fromLines)
        assertEquals(setOf("2026-08-18", "2026-08-19"), fromLines)
        assertEquals(
            CaptureAccumulator.capturedDays(TestDomain.RECOVERY, lines.joinToString("\n"), 0L),
            CaptureAccumulator.capturedDays(TestDomain.RECOVERY, lines, 0L),
        )
    }
}
