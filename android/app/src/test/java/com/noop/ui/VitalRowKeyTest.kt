package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The RECOVERY VITALS rows and the dashboard cards show the same three vitals, so they must open the same
 * trends (#706/#684). The rows pass `dashboardCardMetricKey(...)` straight through rather than repeating
 * the strings, so drift is impossible by construction; these pin the values that route actually produces.
 */
class VitalRowKeyTest {

    /** The keys the `vital_detail/{key}` route is given. Pinned so a rename surfaces here, not on a blank screen. */
    @Test fun `the vital rows use the vital_detail keys`() {
        assertEquals("hrv", dashboardCardMetricKey(DashboardCard.HRV))
        assertEquals("rhr", dashboardCardMetricKey(DashboardCard.RESTING_HR))
        assertEquals("resp", dashboardCardMetricKey(DashboardCard.RESPIRATORY))
    }

    /** All three resolve, so all three rows are tappable and carry a chevron. */
    @Test fun `every vital row resolves to a destination`() {
        assertNotNull(dashboardCardMetricKey(DashboardCard.HRV))
        assertNotNull(dashboardCardMetricKey(DashboardCard.RESTING_HR))
        assertNotNull(dashboardCardMetricKey(DashboardCard.RESPIRATORY))
    }

    /**
     * The degradation path is real, not hypothetical: cards with their own screen return null. A row
     * pointed at one of those must lose its tap and its chevron rather than crash, which is why the row
     * takes a nullable key instead of asserting one.
     */
    @Test fun `a card with its own screen yields no metric key`() {
        assertNull(dashboardCardMetricKey(DashboardCard.SLEEP))
        assertNull(dashboardCardMetricKey(DashboardCard.STRESS))
        assertNull(dashboardCardMetricKey(DashboardCard.COACH))
    }
}
