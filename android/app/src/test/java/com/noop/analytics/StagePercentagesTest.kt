package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Twin of Swift StagePercentagesTests — the SAME vectors, so the two apportionments stay byte-identical. */
class StagePercentagesTest {

    @Test fun workedExampleSumsTo100() {
        // 25 / 210 / 78 / 107 of a 420-minute night — always 100, never 99/101.
        assertEquals(listOf(6, 50, 19, 25), StagePercentages.wholePercentages(listOf(25.0, 210.0, 78.0, 107.0)))
    }

    @Test fun equalPartsSplitEvenly() {
        assertEquals(listOf(25, 25, 25, 25), StagePercentages.wholePercentages(listOf(1.0, 1.0, 1.0, 1.0)))
    }

    @Test fun leftoverGoesToLargestRemainderThenLowestIndex() {
        // Three-way tie for one leftover unit → the lowest index takes it.
        assertEquals(listOf(34, 33, 33, 0), StagePercentages.wholePercentages(listOf(10.0, 10.0, 10.0, 0.0)))
        // Two leftover units: the largest remainder first, then the lowest-index of the tied rest.
        assertEquals(listOf(30, 29, 29, 12), StagePercentages.wholePercentages(listOf(5.0, 5.0, 5.0, 2.0)))
    }

    @Test fun wholeNightInOneStage() {
        assertEquals(listOf(100, 0, 0, 0), StagePercentages.wholePercentages(listOf(420.0, 0.0, 0.0, 0.0)))
    }

    @Test fun noMinutesIsNull() {
        assertNull(StagePercentages.wholePercentages(listOf(0.0, 0.0, 0.0, 0.0)))
        assertNull(StagePercentages.wholePercentages(emptyList()))
    }

    @Test fun alwaysSumsToExactly100() {
        val nights = listOf(
            listOf(1.0, 2.0, 3.0, 4.0), listOf(33.0, 33.0, 33.0, 1.0), listOf(419.0, 1.0, 0.0, 0.0),
            listOf(90.0, 240.0, 60.0, 30.0), listOf(7.0, 7.0, 7.0, 7.0), listOf(100.0, 33.0, 33.0, 34.0),
            listOf(1.0, 0.0, 0.0, 0.0), listOf(12.5, 12.5, 12.5, 12.5),
        )
        for (n in nights) {
            val p = StagePercentages.wholePercentages(n)!!
            assertEquals("$n apportioned to $p", 100, p.sum())
            assert(p.all { it >= 0 })
        }
    }
}
