package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DailySdnnMigrationTest {
    @Test
    fun migrationIsOneNullableAdditiveColumn() {
        val sql = WhoopDatabase.DAILY_SDNN_MIGRATION_SQL
        assertEquals(listOf("ALTER TABLE `dailyMetric` ADD COLUMN `avgSdnn` REAL"), sql)
        val upper = sql.single().uppercase()
        assertTrue(upper.startsWith("ALTER TABLE"))
        assertTrue(!upper.contains("NOT NULL") && !upper.contains("DEFAULT"))
        for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "RENAME ")) {
            assertTrue("migration must not contain $banned", !upper.contains(banned))
        }
    }

    @Test
    fun migrationAndEntityPreserveOldRowsAsNull() {
        assertEquals(31, WhoopDatabase.MIGRATION_31_32.startVersion)
        assertEquals(32, WhoopDatabase.MIGRATION_31_32.endVersion)
        // No SCHEMA_VERSION assertion here. It used to pin the literal, which made this unrelated file
        // part of every migration diff; replacing it with a `>= 32` bound would look like coverage while
        // asserting almost nothing. WhoopDatabaseMigrationChainTest owns that property properly — it
        // asserts the chain has no holes AND ends exactly at SCHEMA_VERSION.
        val old = DailyMetric(deviceId = "my-whoop", day = "2026-08-22", avgHrv = 44.0)
        assertNull(old.avgSdnn)
        assertEquals(88.4, old.copy(avgSdnn = 88.4).avgSdnn!!, 0.0)
    }
}
