package com.noop.testcentre

import org.junit.Assert.assertEquals
import org.junit.Test

/** Kotlin parity for StrandAnalytics/TestCentreLayoutTests.swift, same vectors, same order + status. */
class TestCentreLayoutTest {

    // MARK: section 1 projection

    @Test
    fun phase1_order_highThenMed() {
        val rows = TestCentreLayout.visibleModes(is5MG = false)
        assertEquals(
            listOf(TestDomain.SLEEP, TestDomain.CONNECTION, TestDomain.WORKOUTS, TestDomain.DISPLAY,
                TestDomain.IMPORT, TestDomain.STEPS, TestDomain.BATTERY, TestDomain.RECOVERY, TestDomain.HRV),
            rows.map { it.domain },
        )
    }

    @Test
    fun fiveMGOwner_seesSame() {
        val rows = TestCentreLayout.visibleModes(is5MG = true)
        assertEquals(
            listOf(TestDomain.SLEEP, TestDomain.CONNECTION, TestDomain.WORKOUTS, TestDomain.DISPLAY,
                TestDomain.IMPORT, TestDomain.STEPS, TestDomain.BATTERY, TestDomain.RECOVERY, TestDomain.HRV),
            rows.map { it.domain },
        )
    }

    @Test
    fun requires5MG_hiddenForNon5MG() {
        val sleep = TestModeRegistry.mode(TestDomain.SLEEP)!!
        val gated = sleep.copy(domain = TestDomain.SOURCES, requires5MG = true)
        assertEquals(
            listOf(TestDomain.SLEEP),
            TestCentreLayout.order(listOf(gated, sleep), is5MG = false).map { it.domain },
        )
        assertEquals(
            listOf(TestDomain.SOURCES, TestDomain.SLEEP),
            TestCentreLayout.order(listOf(gated, sleep), is5MG = true).map { it.domain },
        )
    }

    // MARK: per-mode status string

    @Test
    fun status_off() {
        assertEquals(
            "Off",
            TestCentreLayout.statusText(TestModeRegistry.mode(TestDomain.SLEEP)!!, active = false, elapsedSeconds = null),
        )
    }

    @Test
    fun status_guided_midCapture() {
        assertEquals(
            "Capturing 2 of 3 nights",
            TestCentreLayout.statusText(TestModeRegistry.mode(TestDomain.SLEEP)!!, active = true, elapsedSeconds = 25.0 * 3600),
        )
    }

    @Test
    fun status_guided_clampsToTarget() {
        assertEquals(
            "Capturing 3 of 3 days",
            TestCentreLayout.statusText(TestModeRegistry.mode(TestDomain.BATTERY)!!, active = true, elapsedSeconds = 10.0 * 86400),
        )
    }
}
