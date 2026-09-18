package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The #345 "May be incomplete" gate: sparse motion is necessary, a short total is what makes it worth
 * saying. Twin of Swift `SleepSparseNoteGateTests`.
 *
 * The numbers here are the shape of the false positive this closes: nights of 10.5h, 12h and 12.75h that
 * carried the sparse flag and were captioned as possibly reading short.
 */
class SleepSparseNoteGateTest {

    private val need = 8.0

    @Test fun `a long night never earns the caveat however sparse its motion`() {
        for (hours in listOf(8.0, 10.5, 12.0, 12.75)) {
            assertFalse("a ${hours}h night cannot honestly be captioned as possibly reading short",
                        stageSparseNoteApplies(stagingSparse = true, asleepMin = hours * 60, needHours = need))
        }
    }

    @Test fun `a genuinely short sparse night still warns`() {
        assertTrue(stageSparseNoteApplies(stagingSparse = true, asleepMin = 60.0, needHours = need))
        assertTrue(stageSparseNoteApplies(stagingSparse = true, asleepMin = 7.9 * 60, needHours = need))
    }

    @Test fun `a night that staged to nothing is the strongest case, not an exemption`() {
        assertTrue(stageSparseNoteApplies(stagingSparse = true, asleepMin = 0.0, needHours = need))
    }

    @Test fun `sparse stays necessary - a short night alone says nothing about motion`() {
        assertFalse(stageSparseNoteApplies(stagingSparse = false, asleepMin = 60.0, needHours = need))
        assertFalse(stageSparseNoteApplies(stagingSparse = false, asleepMin = 0.0, needHours = need))
    }

    @Test fun `the boundary is the need itself`() {
        assertTrue(stageSparseNoteApplies(stagingSparse = true, asleepMin = need * 60 - 1, needHours = need))
        assertFalse(stageSparseNoteApplies(stagingSparse = true, asleepMin = need * 60, needHours = need))
    }

    @Test fun `the default need is the shared engine constant, not a local number`() {
        // 8h by default, so a 7h sparse night warns and a 9h one does not, with no needHours passed.
        assertTrue(stageSparseNoteApplies(stagingSparse = true, asleepMin = 7.0 * 60))
        assertFalse(stageSparseNoteApplies(stagingSparse = true, asleepMin = 9.0 * 60))
    }
}
