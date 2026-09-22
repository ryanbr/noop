package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

/**
 * After the resting-HR rescore, the Health Connect export reaches past its rolling window once, so days older
 * than it are upserted with the recomputed value instead of keeping the lowest-bin figure they were given.
 */
class HealthConnectRestingHrRewriteTest {
    private val today = LocalDate.parse("2026-09-19")

    @Test
    fun theRollingExportCoversSixtyDays() {
        assertEquals("2026-07-21", HealthConnectWriter.dailyCutoff(historyRewrite = false, today = today))
    }

    @Test
    fun anOwedRewriteCoversEveryComputedDay() {
        assertNull(HealthConnectWriter.dailyCutoff(historyRewrite = true, today = today))
    }
}
