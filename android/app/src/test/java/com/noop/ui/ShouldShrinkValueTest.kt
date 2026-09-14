package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shrink rule behind [AutoSizeValue] (#2171).
 *
 * This replaces a source-text grep that asserted `Components.kt` contained two literals. That could not
 * tell a working shrink loop from an inverted one, passed just as well with the line commented out, and
 * failed on renames that changed nothing. These pin the rule itself, so the composable is free to be
 * rewritten as long as the decision it makes stays the same.
 */
class ShouldShrinkValueTest {

    /** The #2171 case: under Ellipsis the width flag goes false, and the ellipsis alone must drive it. */
    @Test
    fun anEllipsizedLineShrinksEvenWhenTheWidthFlagIsFalse() {
        assertTrue(shouldShrinkValue(didOverflowWidth = false, lineEllipsized = true,
                                     scale = 1f, minScale = 0.6f))
    }

    /** The original signal still works, for the overflow modes that report an unconstrained width. */
    @Test
    fun aWidthOverflowShrinksWithoutAnEllipsis() {
        assertTrue(shouldShrinkValue(didOverflowWidth = true, lineEllipsized = false,
                                     scale = 1f, minScale = 0.6f))
    }

    /**
     * The case that catches an inverted condition, which the grep this replaces could not. A value that
     * fits must be left at the size it already has.
     */
    @Test
    fun aValueThatFitsIsLeftAlone() {
        assertFalse(shouldShrinkValue(didOverflowWidth = false, lineEllipsized = false,
                                      scale = 1f, minScale = 0.6f))
    }

    /** At the floor the answer is no, however badly it overflows: this is what terminates the loop. */
    @Test
    fun theFloorIsStrictSoTheLoopTerminates() {
        assertFalse(shouldShrinkValue(didOverflowWidth = true, lineEllipsized = true,
                                      scale = 0.6f, minScale = 0.6f))
    }

    /** One step above the floor still shrinks, so the floor is a stop rather than an early exit. */
    @Test
    fun justAboveTheFloorStillShrinks() {
        assertTrue(shouldShrinkValue(didOverflowWidth = false, lineEllipsized = true,
                                     scale = 0.68f, minScale = 0.6f))
    }

    /** A scale already below the floor cannot walk further down. */
    @Test
    fun belowTheFloorDoesNotShrinkFurther() {
        assertFalse(shouldShrinkValue(didOverflowWidth = true, lineEllipsized = true,
                                      scale = 0.5f, minScale = 0.6f))
    }
}
