package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Which hosted cards open with a bare section header, and therefore must not wear a top-rounded clip.
 *
 * #2109: the Today host clipped every card slot to the card radius, on the premise that every hosted card
 * fills its slot with a `NoopCard`. Six do not. They open with a bare `SectionHeader`, whose text sits at
 * the slot's top-left, exactly where an 18dp corner cuts hardest, so the overline lost its first glyph and
 * "LAST NIGHT" rendered as "AST NIGHT".
 *
 * Pinned because the failure is quiet. A clipped heading still renders, still reads almost right, and is
 * the kind of wrong nobody files twice. The `when` behind [leadsWithSectionHeader] is exhaustive, so a new
 * card cannot silently inherit a shape; this pins the ANSWERS, so changing one is a deliberate edit to a
 * test rather than a side effect of editing a composable.
 */
class HostedCardShapeTest {

    /** The six whose first pixel is heading text rather than a card surface. NIGHT_DETAIL is the one a
     *  shallow reading misses: its header lives inside the `MetricGrid` it delegates to. */
    @Test
    fun `the cards that open with a bare section header are pinned`() {
        assertEquals(
            listOf(
                HostedCard.SLEEP_MARKS,
                HostedCard.ASLEEP_DURATION,
                HostedCard.STAGES_VS_TYPICAL,
                HostedCard.NIGHT_DETAIL,
                HostedCard.SLEEP_DEBT,
                HostedCard.STAGES,
            ),
            HostedCard.entries.filter { it.leadsWithSectionHeader },
        )
    }

    /** The rest fill their slot with their own rounded surface, so the full radius is right for them. */
    @Test
    fun `the cards that fill their slot with a card are pinned`() {
        assertEquals(
            listOf(
                HostedCard.HOURS_VS_NEEDED,
                HostedCard.CONSISTENCY,
                HostedCard.STRESS_TODAY,
                HostedCard.TREND_HRV,
                HostedCard.TREND_RESTING_HR,
                HostedCard.TREND_EFFORT,
            ),
            HostedCard.entries.filterNot { it.leadsWithSectionHeader },
        )
    }

    /**
     * Every card is classified. Trivially true while the `when` is exhaustive, and the point is that it
     * STAYS trivially true: if someone converts that `when` to an `else` branch, a card added afterwards
     * would quietly take the default, which is the shape that clips a heading.
     */
    @Test
    fun `every card is accounted for on exactly one side`() {
        val header = HostedCard.entries.filter { it.leadsWithSectionHeader }
        val filled = HostedCard.entries.filterNot { it.leadsWithSectionHeader }
        assertEquals(HostedCard.entries.size, header.size + filled.size)
        assertEquals(emptyList<HostedCard>(), header.intersect(filled.toSet()).toList())
    }
}
