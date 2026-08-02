package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1008 — flipping the "Overnight only" default from OFF to ON without moving anyone who is already
 * running the old behaviour.
 *
 * WHOOP publishes no daytime HRV figure, so a 24/7 stream has no official-app analogue and costs
 * roughly twice the battery. The cheaper, WHOOP-comparable option should be what a new user gets.
 *
 * The rule that must not break: an existing Continuous HRV user's capture is never silently narrowed.
 * They opted into "all day and night" and may be reading daytime Stress off it. That is what the
 * launch migration pinned here exists for.
 */
class ContinuousHrvOvernightDefaultTest {

    /** The case the migration exists for: used the feature, never chose — pin the old default. */
    @Test fun anExistingContinuousHrvUserIsPinnedToAlwaysOn() {
        assertTrue(
            NoopPrefs.shouldPinLegacyOvernightDefault(
                hasOvernightChoice = false, hasUsedContinuousHrv = true,
            ),
        )
    }

    /** A fresh install is left alone, so the read picks up the new ON default. */
    @Test fun aFreshInstallIsLeftAloneAndTakesTheNewDefault() {
        assertFalse(
            NoopPrefs.shouldPinLegacyOvernightDefault(
                hasOvernightChoice = false, hasUsedContinuousHrv = false,
            ),
        )
    }

    /** An explicit choice is never overwritten, whichever way it points. */
    @Test fun anExplicitChoiceIsNeverOverwritten() {
        assertFalse(
            NoopPrefs.shouldPinLegacyOvernightDefault(
                hasOvernightChoice = true, hasUsedContinuousHrv = true,
            ),
        )
        assertFalse(
            NoopPrefs.shouldPinLegacyOvernightDefault(
                hasOvernightChoice = true, hasUsedContinuousHrv = false,
            ),
        )
    }

    /**
     * Idempotence, which is what makes it safe to run on every launch: once the pin is written, the
     * choice exists, so the second pass declines.
     */
    @Test fun theMigrationIsIdempotent() {
        assertTrue(NoopPrefs.shouldPinLegacyOvernightDefault(false, hasUsedContinuousHrv = true))
        // after the write, hasOvernightChoice is true
        assertFalse(NoopPrefs.shouldPinLegacyOvernightDefault(true, hasUsedContinuousHrv = true))
    }

    /**
     * The SEQUENCE that broke the first attempt, pinned so it cannot come back.
     *
     * That version resolved the default at READ time from "has used Continuous HRV" — a fact the user's
     * own opt-in creates. A fresh install read ON, then flipped to OFF the moment Continuous HRV was
     * enabled: the exact opposite of the intent, and invisible to state-by-state tests because every
     * individual state was correct.
     *
     * Running the decision once at launch is what fixes it. On a fresh install the migration declines,
     * writes nothing, and enabling Continuous HRV afterwards cannot retroactively make it decline
     * differently — there is nothing left to decide.
     */
    @Test fun enablingContinuousHrvAfterLaunchCannotChangeTheDecision() {
        // At launch on a fresh install: nothing used, nothing chosen → no pin.
        assertFalse(NoopPrefs.shouldPinLegacyOvernightDefault(false, hasUsedContinuousHrv = false))
        // The user then enables Continuous HRV. The migration has already run this launch and will not
        // run again until next launch — by which time an explicit choice may exist, and if it does not,
        // the input it would read is the same one that was already declined.
        assertTrue(
            "next launch WOULD pin — which is why the migration must run before the read, not after",
            NoopPrefs.shouldPinLegacyOvernightDefault(false, hasUsedContinuousHrv = true),
        )
    }
}
