package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * #386: the aggressive-OEM vendor classifier that gates the Settings "Keep NOOP alive overnight" row
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

    // ── #386 follow-up: the "Keep NOOP alive overnight" row ───────────────────────────────────────

    /**
     * The reported bug, at the level it actually lived.
     *
     * The row could be turned on but not off — Android has no API to revoke an app's own
     * battery-optimisation exemption, so the off direction did nothing and the switch sprang back.
     *
     * The row stays a Switch; what it needed was an off direction that goes somewhere. Every state maps
     * to an action here, so neither swipe is a dead end: "off" resolves to the screen that genuinely can
     * revoke the grant. That is what this pins — not the widget, and not which screen, but the guarantee
     * that no state exists which the UI cannot act on.
     */
    @Test
    fun bothStatesHaveAnAction() {
        assertEquals(
            BackgroundHealth.BatteryRowAction.RequestExemption,
            BackgroundHealth.batteryRowAction(isExempt = false),
        )
        assertEquals(
            BackgroundHealth.BatteryRowAction.OpenRevokeSettings,
            BackgroundHealth.batteryRowAction(isExempt = true),
        )
    }

    /**
     * The granted state must route somewhere the user can REVOKE.
     *
     * This is the whole complaint: once exempt, there was no way back from inside the app. The app cannot
     * revoke the grant itself, so the honest action is to open the page that owns it.
     */
    @Test
    fun theGrantedStateOffersAWayBack() {
        assertEquals(
            BackgroundHealth.BatteryRowAction.OpenRevokeSettings,
            BackgroundHealth.batteryRowAction(isExempt = true),
        )
    }

    /** The two states must not collapse to the same action — that would be the dead end returning. */
    @Test
    fun theTwoStatesDoDifferentThings() {
        assertNotEquals(
            BackgroundHealth.batteryRowAction(isExempt = true),
            BackgroundHealth.batteryRowAction(isExempt = false),
        )
    }
}
