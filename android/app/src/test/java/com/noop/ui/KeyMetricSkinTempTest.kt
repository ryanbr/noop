package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Queue 11c follow-up (2026-08-24): Skin Temp was already a "Your Cards" (`DashboardCard.SKIN_TEMP`)
 * option, but was never offered as a Key Metrics tile — not a bug, just never added. Pins the two
 * contract points that matter for a NEW persisted enum case: the raw token round-trips
 * ("skinTemp", byte-identical to the Swift `KeyMetric.skinTemp` rawValue so a backup/restore reads the
 * same layout on either OS), and it does NOT join `defaultOrder` — an existing user's saved layout, and
 * a fresh install's default, must stay byte-identical to before this case existed.
 */
class KeyMetricSkinTempTest {

    @Test fun rawTokenRoundTrips() {
        assertEquals(KeyMetric.SKIN_TEMP, KeyMetric.fromRaw("skinTemp"))
        assertEquals("skinTemp", KeyMetric.SKIN_TEMP.raw)
    }

    @Test fun notInDefaultOrder() {
        assertFalse(KeyMetric.defaultOrder.contains(KeyMetric.SKIN_TEMP))
    }

    @Test fun blankLayoutStillExcludesIt() {
        // A fresh install (blank saved layout) decodes to defaultOrder, which must not have picked up
        // the new case — the whole point of adding it to `entries`/CaseIterable without touching
        // defaultOrder.
        assertTrue(KeyMetricPrefs.decodeEnabled("").none { it == KeyMetric.SKIN_TEMP })
    }

    private fun day(skinTempDevC: Double?) =
        DailyMetric(deviceId = "my-whoop-noop", day = "2026-08-25", skinTempDevC = skinTempDevC)

    /**
     * Regression for ryanbr's PR #1589 review: carriedDay (lastScoredRecoveryDay) is a whole-row
     * carry that lands on a row with null skinTempDevC even when a genuine reading exists further
     * back, so the tile must fall through to the per-field skinTempCarryDay — exactly like
     * spo2CarryDay/respCarryDay, and matching iOS TodayView's lastSkinTempDay chain.
     */
    @Test fun nullSkinTempDevCFallsThroughToPerFieldCarry() {
        val perFieldCarry = day(skinTempDevC = 0.4)
        assertEquals(
            0.4,
            resolveSkinTempDevC(d = null, carriedDay = day(skinTempDevC = null), skinTempCarryDay = perFieldCarry)!!,
            0.0,
        )
    }

    @Test fun todaysOwnReadingWinsOverEitherCarry() {
        assertEquals(
            0.2,
            resolveSkinTempDevC(
                d = day(skinTempDevC = 0.2),
                carriedDay = day(skinTempDevC = -0.1),
                skinTempCarryDay = day(skinTempDevC = 0.4),
            )!!,
            0.0,
        )
    }

    @Test fun wholeRowCarryWinsOverPerFieldCarryWhenBothPresent() {
        assertEquals(
            -0.1,
            resolveSkinTempDevC(
                d = null,
                carriedDay = day(skinTempDevC = -0.1),
                skinTempCarryDay = day(skinTempDevC = 0.4),
            )!!,
            0.0,
        )
    }

    @Test fun noRowAnywhereYieldsNull() {
        assertNull(resolveSkinTempDevC(d = null, carriedDay = null, skinTempCarryDay = null))
    }
}
