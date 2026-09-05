package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * The RECOVERY VITALS rows and the dashboard cards show the same three vitals, so they must open the same
 * trends (#706/#684). The rows take their keys from [dashboardCardMetricKey] rather than repeating them,
 * and these pin both halves of that: the keys are what the cards use, and the three cards a row can name
 * always resolve, so [vitalRowKey]'s requireNotNull cannot fire in the field.
 */
class VitalRowKeyTest {

    @Test fun `a vital row opens the same trend as its dashboard card`() {
        assertEquals(dashboardCardMetricKey(DashboardCard.HRV), vitalRowKey(DashboardCard.HRV))
        assertEquals(dashboardCardMetricKey(DashboardCard.RESTING_HR), vitalRowKey(DashboardCard.RESTING_HR))
        assertEquals(dashboardCardMetricKey(DashboardCard.RESPIRATORY), vitalRowKey(DashboardCard.RESPIRATORY))
    }

    @Test fun `vital row keys resolve`() {
        assertNotNull(dashboardCardMetricKey(DashboardCard.HRV))
        assertNotNull(dashboardCardMetricKey(DashboardCard.RESTING_HR))
        assertNotNull(dashboardCardMetricKey(DashboardCard.RESPIRATORY))
    }

    /** The keys the VitalDetailScreen route is given; pinned so a rename shows up here, not on a blank screen. */
    @Test fun `the keys are the vital_detail keys`() {
        assertEquals("hrv", vitalRowKey(DashboardCard.HRV))
        assertEquals("rhr", vitalRowKey(DashboardCard.RESTING_HR))
        assertEquals("resp", vitalRowKey(DashboardCard.RESPIRATORY))
    }
}
