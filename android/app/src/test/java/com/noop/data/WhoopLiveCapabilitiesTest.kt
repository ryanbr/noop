package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Byte-parity twin of Swift `WhoopLiveCapabilitiesTests` (#548). */
class WhoopLiveCapabilitiesTest {

    @Test
    fun baseExcludesCalibratedSpo2() {
        assertFalse(WhoopLiveCapabilities.base.contains(Metric.spo2))
        assertEquals(
            setOf(Metric.hr, Metric.hrv, Metric.skinTemp, Metric.sleep, Metric.strainLoad),
            WhoopLiveCapabilities.base,
        )
    }

    @Test
    fun fourPointOhHasNoSteps() {
        val caps = WhoopLiveCapabilities.metrics("4.0")
        assertFalse(caps.contains(Metric.steps))
        assertFalse(caps.contains(Metric.spo2))
        assertTrue(caps.contains(Metric.hr))
    }

    @Test
    fun fiveAndMGIncludeSteps() {
        for (model in listOf("5.0 MG", "WHOOP 5.0", "MG", "whoop5")) {
            val caps = WhoopLiveCapabilities.metrics(model)
            assertTrue(model, caps.contains(Metric.steps))
            assertFalse(model, caps.contains(Metric.spo2))
        }
    }

    @Test
    fun encodedIsSortedAndStable() {
        assertEquals(
            "hr,hrv,skinTemp,sleep,strainLoad",
            WhoopLiveCapabilities.encoded("4.0"),
        )
        assertEquals(
            "hr,hrv,skinTemp,sleep,steps,strainLoad",
            WhoopLiveCapabilities.encoded("5.0 MG"),
        )
    }

    @Test
    fun stripSpo2TokenHandlesPositions() {
        assertEquals(
            "hr,hrv,skinTemp,sleep,strainLoad",
            WhoopLiveCapabilities.stripSpo2Token("hr,hrv,spo2,skinTemp,sleep,strainLoad"),
        )
        assertEquals("hr", WhoopLiveCapabilities.stripSpo2Token("spo2,hr"))
        assertEquals("hr", WhoopLiveCapabilities.stripSpo2Token("hr,spo2"))
        assertEquals(
            "hr,hrv,skinTemp",
            WhoopLiveCapabilities.stripSpo2Token("hr,hrv,skinTemp"),
        )
    }

    @Test
    fun withoutCalibratedSpo2() {
        val raw = setOf(Metric.hr, Metric.hrv, Metric.spo2, Metric.skinTemp)
        assertEquals(
            setOf(Metric.hr, Metric.hrv, Metric.skinTemp),
            WhoopLiveCapabilities.withoutCalibratedSpo2(raw),
        )
    }
}
