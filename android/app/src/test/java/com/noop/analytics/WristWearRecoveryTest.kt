package com.noop.analytics

import com.noop.data.EventRow
import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.*
import org.junit.Test

class WristWearRecoveryTest {
    private fun hr(from: Long, to: Long, step: Long = 1, bpm: Int = 60) =
        (from..to step step).map { HrSample("test", it, bpm) }
    private fun event(ts: Long, off: Boolean) =
        EventRow("test", ts, if (off) "WRIST_OFF(10)" else "WRIST_ON(9)", "{}")
    private fun spans(events: List<EventRow>, samples: List<HrSample>, end: Long = 4000) =
        AnalyticsEngine.offWristIntervals(events, end, samples).map { "${it.first}:${it.second}" }

    @Test fun missingOnEndsAtStartOfSustainedHR() {
        assertEquals(listOf("100:1000"), spans(listOf(event(100, true)), hr(1000, 1600)))
        assertEquals(listOf("100:4000"), spans(listOf(event(100, true)), emptyList()))
        assertEquals(emptyList<String>(), spans(emptyList(), hr(1000, 1600)))
    }
    @Test fun pairedEventsStayAuthoritativeEvenWithDenseHR() {
        assertEquals(listOf("100:3000"), spans(listOf(event(100, true), event(3000, false)), hr(1000, 3500)))
    }
    @Test fun repeatedOffRestartsEvidenceAndPreservesEarlierPairs() {
        val events = listOf(event(2500, true), event(100, true), event(2000, true), event(500, false))
        assertEquals(listOf("100:500", "2000:2501"), spans(events, hr(2100, 2900)))
        assertEquals(listOf("100:500", "2000:4000"), spans(events, hr(2100, 2700)))
    }
    @Test fun futureSamplesAndEventsCannotCloseCurrentTail() {
        assertEquals(listOf("100:4000"), spans(listOf(event(100, true), event(5000, false)), hr(4100, 4500)))
        assertEquals(emptyList<String>(), spans(listOf(event(5000, true)), hr(1000, 1600)))
    }
    @Test fun fiveMinuteConfirmationAndFiveSecondGapBoundaries() {
        assertEquals(1000L, WristWearRecovery.firstSustainedHR(hr(1000, 1300, step = 5), 0, 2000))
        assertNull(WristWearRecovery.firstSustainedHR(hr(1000, 1299), 0, 2000))
        assertNull(WristWearRecovery.firstSustainedHR(hr(1000, 1600, step = 6), 0, 2000))
        assertNull(WristWearRecovery.firstSustainedHR(hr(1000, 1300), 1000, 2000))
        assertNull(WristWearRecovery.firstSustainedHR(hr(1000, 1300), 0, 1300))
    }
    @Test fun gapsAndInvalidReadingsResetConfirmation() {
        assertEquals(1200L, WristWearRecovery.firstSustainedHR(hr(1000, 1150) + hr(1200, 1500), 0, 2000))
        for (invalid in listOf(0, 29, 221, 255)) {
            val samples = hr(1000, 1199) + HrSample("test", 1200, invalid) + hr(1201, 1600)
            assertEquals(1201L, WristWearRecovery.firstSustainedHR(samples, 0, 2000))
        }
    }
    @Test fun duplicatesCannotManufactureCoverageAndInvalidWinsConflict() {
        assertNull(WristWearRecovery.firstSustainedHR(List(1000) { HrSample("test", 1000, 60) }, 0, 2000))
        val samples = hr(1000, 1600) + HrSample("test", 1200, 0)
        for (rows in listOf(samples, samples.reversed())) {
            assertEquals(1201L, WristWearRecovery.firstSustainedHR(rows, 0, 2000))
        }
    }
    @Test fun recoveredNightMatchesControlAndPairedOffStillDropsIt() {
        val start = 2 * 3600L; val end = start + 90 * 60
        val gravity = (start..end step 5).map { GravitySample("test", it, 0.0, 0.0, 1.0) }
        val samples = hr(start - 900, end, step = 5, bpm = 50)
        val control = SleepStager.detectSleep(hr = samples, gravity = gravity)
        assertEquals(1, control.size)
        val recovered = AnalyticsEngine.offWristIntervals(listOf(event(start - 1800, true)), end + 1, samples)
        val actual = SleepStager.detectSleep(hr = samples, gravity = gravity, wristOff = recovered)
        assertEquals(control.map { it.start }, actual.map { it.start })
        assertEquals(control.map { it.end }, actual.map { it.end })
        val paired = AnalyticsEngine.offWristIntervals(listOf(event(start - 1800, true), event(end, false)), end + 1, samples)
        assertTrue(SleepStager.detectSleep(hr = samples, gravity = gravity, wristOff = paired).isEmpty())
    }
    @Test fun recoveryDoesNotDisableSubsequentHRGapGuard() {
        val samples = hr(100, 1000) + hr(8000, 9000)
        val off = AnalyticsEngine.offWristIntervals(listOf(event(0, true)), 10000, samples)
        val period = SleepStager.Period("sleep", 2000, 7000)
        assertEquals(1.0, SleepStager.offWristFraction(period, samples, off), 0.0)
    }
    @Test fun swiftParityOracle() {
        val values = mutableListOf<String>()
        for (offset in listOf(0L, 86400L, 1700000000L)) {
            for (step in listOf(1L, 5L, 6L, 60L)) {
                for (duration in listOf(299L, 300L, 600L)) {
                    val result = WristWearRecovery.firstSustainedHR(hr(offset + 100, offset + 100 + duration, step), offset, offset + 1000)
                    values.add(result?.toString() ?: "nil")
                }
            }
        }
        // Verbatim output from Swift WristWearRecoveryTests.testParityOracle.
        assertEquals("nil,100,100,nil,100,100,nil,nil,nil,nil,nil,nil,nil,86500,86500,nil,86500,86500,nil,nil,nil,nil,nil,nil,nil,1700000100,1700000100,nil,1700000100,1700000100,nil,nil,nil,nil,nil,nil", values.joinToString(","))
    }
}
