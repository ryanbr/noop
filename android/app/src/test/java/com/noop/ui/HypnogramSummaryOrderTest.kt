package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hypnogram's screen-reader read-out agrees with the rows a sighted user sees, in both order and value.
 *
 * #2534 is about stage order. The read-out was announcing deep first while every row stack draws awake
 * first, so a TalkBack user heard a different order from the one on screen.
 *
 * Pulling on that turned up a second, quieter problem. The read-out fed its OWN order into
 * [StagePercentages.wholePercentages], which breaks ties by lower index, so the input order decides which
 * stage receives the spare percentage point. On a night where two stages share a fractional remainder the
 * read-out therefore announced a different number than the row on screen for that same stage. Display order
 * and apportionment order are separate concerns and are now separate lists.
 */
class HypnogramSummaryOrderTest {

    /** Weights are relative widths, which is what the hypnogram passes. */
    private fun stages(awake: Float, light: Float, deep: Float, rem: Float) =
        listOf("awake" to awake, "light" to light, "deep" to deep, "rem" to rem)

    @Test
    fun `the read-out names stages in the same order the rows draw them`() {
        val text = hypnogramSummary(stages(awake = 40f, light = 200f, deep = 90f, rem = 70f))
        val heard = Regex("""percent (\w+)""").findAll(text).map { it.groupValues[1] }.toList()
        assertEquals(listOf("Awake", "REM", "Light", "Deep"), heard)
    }

    /**
     * A tie night: awake and REM carry identical fractional remainders, so exactly one of them gets the
     * spare point and WHICH one is decided by the order handed to the apportionment.
     *
     * With the old shared list the read-out said 12 percent Awake while the Awake row said 13.
     */
    @Test
    fun `on a tie night the spoken percentages equal the rows`() {
        val s = Stages(awake = 50.0, light = 205.0, deep = 95.0, rem = 50.0)
        val text = hypnogramSummary(stages(awake = 50f, light = 205f, deep = 95f, rem = 50f))

        val spoken = Regex("""(\d+) percent (\w+)""").findAll(text)
            .associate { it.groupValues[2] to it.groupValues[1].toInt() }

        for (label in listOf("Awake", "Light", "Deep", "REM")) {
            val key = if (label == "REM") "REM" else label
            assertEquals(
                "$label: the read-out and the row must print one apportionment",
                stageSharePercent(label, s), spoken.getValue(key),
            )
        }
    }

    /** Absent stages are skipped rather than announced as zero, which was already true and must stay so. */
    @Test
    fun `a night with no deep sleep does not announce deep`() {
        val text = hypnogramSummary(stages(awake = 30f, light = 200f, deep = 0f, rem = 70f))
        assertTrue("deep must not be named: $text", !text.contains("Deep"))
        val heard = Regex("""percent (\w+)""").findAll(text).map { it.groupValues[1] }.toList()
        assertEquals(listOf("Awake", "REM", "Light"), heard)
    }

    @Test
    fun `an empty night says so rather than reading zeroes`() {
        assertEquals("Sleep stages, no data", hypnogramSummary(emptyList()))
        assertEquals("Sleep stages, no data", hypnogramSummary(stages(0f, 0f, 0f, 0f)))
    }
}
