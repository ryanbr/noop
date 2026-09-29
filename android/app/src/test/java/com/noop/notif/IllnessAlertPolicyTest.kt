package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [IllnessAlertPolicy], the pure once-per-local-day gate behind the illness
 * early-warning notification (CallAlertPolicy test idiom). The gate is persisted, so the two
 * call sites (app-open AppViewModel + background WhoopConnectionService) can never double-post.
 */
class IllnessAlertPolicyTest {

    @Test
    fun nullAlertNeverNotifies() {
        assertFalse(IllnessAlertPolicy.shouldNotify(null, false, null, "2026-06-10"))
        assertFalse(IllnessAlertPolicy.shouldNotify(null, false, "2026-06-09", "2026-06-10"))
    }

    @Test
    fun firstAlertOfTheDayNotifies() {
        assertTrue(IllnessAlertPolicy.shouldNotify("strained", false, null, "2026-06-10"))
        assertTrue(IllnessAlertPolicy.shouldNotify("strained", false, "2026-06-09", "2026-06-10"))
    }

    @Test
    fun sameDayRepeatIsSuppressed() {
        assertFalse(IllnessAlertPolicy.shouldNotify("strained", false, "2026-06-10", "2026-06-10"))
    }

    /**
     * #2586. The reported shape: one bad night raises the banner, the two-day scoring window keeps it
     * raised into the next day, and the app is reopened. Before the fix the in-memory edge made that
     * look like a fresh transition and the new calendar day opened the once-a-day gate, so the wearer
     * was told again, about a night they had already been told about.
     */
    @Test
    fun anAlertThatWasAlreadyRaisedDoesNotNotifyAgainOnANewDay() {
        assertFalse(IllnessAlertPolicy.shouldNotify("strained", true, "2026-06-09", "2026-06-10"))
    }

    /** Still raised, same day: suppressed by both guards, and neither alone is relied on. */
    @Test
    fun anAlertAlreadyRaisedIsSuppressedOnTheSameDayToo() {
        assertFalse(IllnessAlertPolicy.shouldNotify("strained", true, "2026-06-10", "2026-06-10"))
    }

    /**
     * Clearing re-arms it. Without this the fix would be a one-shot: a wearer who recovered and then
     * genuinely declined again weeks later would never be told, which is worse than the bug.
     */
    @Test
    fun aClearedThenRaisedAlertNotifiesAgain() {
        assertFalse(IllnessAlertPolicy.shouldNotify(null, true, "2026-06-09", "2026-06-10"))
        assertTrue(IllnessAlertPolicy.shouldNotify("strained", false, "2026-06-09", "2026-06-10"))
    }
}
