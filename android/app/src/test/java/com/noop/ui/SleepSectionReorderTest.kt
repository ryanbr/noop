package com.noop.ui

import com.noop.ui.SleepSection.ASLEEP_DURATION
import com.noop.ui.SleepSection.CONSISTENCY
import com.noop.ui.SleepSection.HOURS_VS_NEEDED
import com.noop.ui.SleepSection.NIGHT_DETAIL
import com.noop.ui.SleepSection.SLEEP_DEBT
import com.noop.ui.SleepSection.SLEEP_MARKS
import com.noop.ui.SleepSection.STAGES
import com.noop.ui.SleepSection.STAGES_VS_TYPICAL
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [movedSleepSection] (#sleep-layout hold-to-drag): the pure "move this card to the target's slot"
 * step the drag frame loop applies on every swap. A bug here silently reorders the wrong card. This is the
 * behavioural twin of Today's `movedTodaySection`; the gesture/auto-scroll code around it can only be
 * validated on-device.
 */
class SleepSectionReorderTest {

    // MARKS, STAGES, NIGHT_DETAIL, SLEEP_DEBT, STAGES_VS_TYPICAL, ASLEEP_DURATION
    private val order = SleepSection.defaultOrder

    @Test fun movingDownPlacesTheCardAtTheTargetsSlot() {
        assertEquals(
            listOf(STAGES, NIGHT_DETAIL, SLEEP_MARKS, SLEEP_DEBT, STAGES_VS_TYPICAL, ASLEEP_DURATION, HOURS_VS_NEEDED, CONSISTENCY),
            order.movedSleepSection(SLEEP_MARKS, NIGHT_DETAIL),
        )
    }

    @Test fun movingUpPlacesTheCardAtTheTargetsSlot() {
        assertEquals(
            listOf(SLEEP_MARKS, ASLEEP_DURATION, STAGES, NIGHT_DETAIL, SLEEP_DEBT, STAGES_VS_TYPICAL, HOURS_VS_NEEDED, CONSISTENCY),
            order.movedSleepSection(ASLEEP_DURATION, STAGES),
        )
    }

    @Test fun movingOntoItselfIsANoOp() {
        assertEquals(order, order.movedSleepSection(STAGES, STAGES))
    }

    @Test fun aSectionNotInTheOrderLeavesItUnchanged() {
        // A hidden/absent section can't be moved (indexOf == -1) — guards a phantom drag key from mangling
        // the list.
        val partial = listOf(SLEEP_MARKS, STAGES)
        assertEquals(partial, partial.movedSleepSection(NIGHT_DETAIL, STAGES))
    }
}
