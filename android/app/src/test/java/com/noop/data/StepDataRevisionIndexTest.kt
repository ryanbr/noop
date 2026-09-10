package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class StepDataRevisionIndexTest {
    @Test fun newRowsInvalidateOnlyIntersectingOwnerDaysAndDuplicatesDoNothing() {
        val index = StepDataRevisionIndex()
        val day = 86_400L
        val activeBefore = index.signature("strap-a", day, 2 * day)
        val neighbourBefore = index.signature("strap-a", 2 * day, 3 * day)

        index.record("strap-a", listOf(day + 100), insertedRows = 1)
        val activeAfter = index.signature("strap-a", day, 2 * day)
        assertNotEquals(activeBefore, activeAfter)
        assertEquals(neighbourBefore, index.signature("strap-a", 2 * day, 3 * day))
        assertEquals("0:0", index.signature("strap-b", 0, day))

        index.record("strap-a", listOf(day + 100), insertedRows = 0)
        assertEquals(activeAfter, index.signature("strap-a", day, 2 * day))
    }

    @Test fun delayedBackfillInvalidatesAClosedWindowButNotTheCurrentNeighbour() {
        val index = StepDataRevisionIndex()
        val day = 86_400L
        val closedBefore = index.signature("strap", day, 2 * day)
        val currentBefore = index.signature("strap", 2 * day, 3 * day)

        index.record("strap", listOf(day + 42), insertedRows = 1)

        assertNotEquals(closedBefore, index.signature("strap", day, 2 * day))
        assertEquals(currentBefore, index.signature("strap", 2 * day, 3 * day))
    }

    @Test fun mixedDuplicateAndNewRowsExposeOnlyActuallyInsertedTimestamps() {
        val day = 86_400L
        val index = StepDataRevisionIndex()
        val duplicateDayBefore = index.signature("strap", 0, day)
        val newDayBefore = index.signature("strap", day, 2 * day)
        val inserted = newlyInsertedStepTimestamps(
            listOf(10L, day + 20),
            listOf(-1L, 42L),
        )
        assertEquals(
            listOf(day + 20),
            inserted,
        )
        index.record("strap", inserted, insertedRows = inserted.size)
        assertEquals(duplicateDayBefore, index.signature("strap", 0, day))
        assertNotEquals(newDayBefore, index.signature("strap", day, 2 * day))
    }
}
