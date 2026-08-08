package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WhoopBleClient.formatFrameTimingSummary] (#1151): the detailed capture now flushes ONE rolling
 * summary line for frame timing instead of a line per frame-TYPE transition (which was ~a third of a real
 * capture). Pure formatter → unit-testable without a GATT stack.
 */
class FrameTimingSummaryTest {

    @Test
    fun summarisesTotalAndListsTypesMostFrequentFirst() {
        val counts = linkedMapOf("METADATA" to 14, "EVENT" to 40, "COMMAND_RESPONSE" to 30)
        assertEquals(
            "frameTiming 60s: 84 frame(s) [EVENT×40, COMMAND_RESPONSE×30, METADATA×14]",
            WhoopBleClient.formatFrameTimingSummary(counts, 60L),
        )
    }

    /** Deterministic ordering: equal counts break ties by type name, so the line never flaps run-to-run. */
    @Test
    fun tiesAreBrokenByTypeNameSoTheLineIsStable() {
        val counts = linkedMapOf("EVENT" to 5, "COMMAND_RESPONSE" to 5, "METADATA" to 5)
        assertEquals(
            "frameTiming 30s: 15 frame(s) [COMMAND_RESPONSE×5, EVENT×5, METADATA×5]",
            WhoopBleClient.formatFrameTimingSummary(counts, 30L),
        )
    }

    @Test
    fun singleTypeAndWindowSecondsAreEchoed() {
        assertEquals(
            "frameTiming 75s: 3 frame(s) [EVENT×3]",
            WhoopBleClient.formatFrameTimingSummary(linkedMapOf("EVENT" to 3), 75L),
        )
    }

    /** The compression the change is FOR: N frame lines collapse to one, and the total is preserved. */
    @Test
    fun collapsesManyTransitionsIntoOneLineKeepingTheTotal() {
        val counts = linkedMapOf("EVENT" to 500, "COMMAND_RESPONSE" to 300, "METADATA" to 200)
        val line = WhoopBleClient.formatFrameTimingSummary(counts, 60L)
        assertTrue("total must be the sum", line.contains("1000 frame(s)"))
        assertEquals("one line, not 1000", 1, line.lines().size)
    }
}
