package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #386: the aggressive-OEM vendor classifier that gates the Settings "Keep NOOP alive overnight" toggle
 * and (via delegation) the Test Centre `oemKillHeuristic`. Pure + Context-free — the ONE canonical set,
 * so a phone that actually kills background apps is offered the whitelist. Case-insensitive, substring
 * match (real `Build.MANUFACTURER` values vary in casing and extra words).
 */
class BackgroundHealthTest {

    @Test
    fun `known aggressive vendors match, case-insensitively`() {
        // Real Build.MANUFACTURER values (a Redmi/Poco device reports "Xiaomi", not "Redmi").
        listOf(
            "Xiaomi", "xiaomi",
            "OPPO", "oppo", "realme", "Realme",
            "vivo", "Vivo",
            "HUAWEI", "Huawei",
            "OnePlus", "oneplus",
            "Meizu",
        ).forEach { assertTrue("$it should be aggressive", BackgroundHealth.isAggressiveVendor(it)) }
    }

    @Test
    fun `standard vendors do not match`() {
        listOf("Google", "samsung", "Samsung", "motorola", "Nothing", "Sony", "Fairphone", "")
            .forEach { assertFalse("$it should NOT be aggressive", BackgroundHealth.isAggressiveVendor(it)) }
    }

    @Test
    fun `the canonical set is exactly the dontkillmyapp vendors`() {
        // Pin the list so a future edit is a deliberate, reviewed change (it drives who gets prompted).
        assertEquals(
            listOf("xiaomi", "oppo", "vivo", "huawei", "oneplus", "realme", "meizu"),
            BackgroundHealth.AGGRESSIVE_VENDORS,
        )
    }

    // ── #386 follow-up: the "Keep NOOP alive overnight" switch ────────────────────────────────────

    /**
     * The reported bug: the switch could be turned on but not off.
     *
     * `onCheckedChange` handled only `wantOn && !isExempt`. Moving it the other way matched no branch, so
     * no state changed and the switch — bound to the live system exempt state — snapped straight back to
     * on. A Switch is a bidirectional control; one that silently swallows half its input is broken however
     * good the platform reason, and "the toggle doesn't work" was the correct read.
     */
    @Test
    fun turningItOffDoesSomething() {
        assertEquals(
            BackgroundHealth.BatteryToggleAction.OpenAppSettings,
            BackgroundHealth.batteryToggleAction(wantOn = false, isExempt = true),
        )
    }

    /** Turning it on when not yet exempt still fires the one-tap grant dialog. */
    @Test
    fun turningItOnRequestsTheExemption() {
        assertEquals(
            BackgroundHealth.BatteryToggleAction.RequestExemption,
            BackgroundHealth.batteryToggleAction(wantOn = true, isExempt = false),
        )
    }

    /**
     * Popup discipline (#386): an already-exempt phone must never be re-prompted, so a tap that agrees with
     * the current state does nothing at all.
     */
    @Test
    fun aTapThatAgreesWithTheCurrentStateDoesNothing() {
        assertEquals(
            BackgroundHealth.BatteryToggleAction.None,
            BackgroundHealth.batteryToggleAction(wantOn = true, isExempt = true),
        )
        assertEquals(
            BackgroundHealth.BatteryToggleAction.None,
            BackgroundHealth.batteryToggleAction(wantOn = false, isExempt = false),
        )
    }

    /**
     * The table is total: all four (wantOn, isExempt) combinations are covered, and only the two that agree
     * with the current state may be inert. This is what stops the original bug — a direction quietly
     * falling through to no action — from coming back.
     */
    @Test
    fun everyCombinationIsAccountedFor() {
        val inert = listOf(true to true, false to false)
        for (wantOn in listOf(true, false)) {
            for (isExempt in listOf(true, false)) {
                val action = BackgroundHealth.batteryToggleAction(wantOn, isExempt)
                if ((wantOn to isExempt) in inert) {
                    assertEquals("($wantOn,$isExempt) agrees with state", BackgroundHealth.BatteryToggleAction.None, action)
                } else {
                    assertNotEquals(
                        "($wantOn,$isExempt) asks for a CHANGE and must do something",
                        BackgroundHealth.BatteryToggleAction.None, action,
                    )
                }
            }
        }
    }
}
