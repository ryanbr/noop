package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Test

class ReadoutDataRevisionTest {

    @Test fun revisionsAdvanceOnlyForSuccessfullyInsertedRelevantRows() {
        val initial = ReadoutDataRevisions(sleepSamples = 7, battery = 11, steps = 13)

        assertEquals(initial, advanceReadoutDataRevisions(initial, InsertCounts()))
        assertEquals(
            ReadoutDataRevisions(sleepSamples = 8, battery = 11, steps = 13),
            advanceReadoutDataRevisions(initial, InsertCounts(hr = 1)),
        )
        assertEquals(
            ReadoutDataRevisions(sleepSamples = 8, battery = 11, steps = 13),
            advanceReadoutDataRevisions(initial, InsertCounts(gravity = 2)),
        )
        assertEquals(
            ReadoutDataRevisions(sleepSamples = 7, battery = 12, steps = 13),
            advanceReadoutDataRevisions(initial, InsertCounts(battery = 1)),
        )
        assertEquals(
            ReadoutDataRevisions(sleepSamples = 8, battery = 12, steps = 13),
            advanceReadoutDataRevisions(initial, InsertCounts(hr = 1, gravity = 1, battery = 1)),
        )
        assertEquals(
            ReadoutDataRevisions(sleepSamples = 7, battery = 11, steps = 14),
            advanceReadoutDataRevisions(initial, InsertCounts(steps = 1)),
        )
    }
}
