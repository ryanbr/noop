package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
}
