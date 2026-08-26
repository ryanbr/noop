package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v33 -> v34 (#1636): the nightly ABSOLUTE skin temperature, kept beside the deviation derived from it.
 *
 * Twin of the Swift `v40-daily-skin-temp-absolute` GRDB migration.
 *
 * This environment has no Robolectric / Room-testing (see [AppleStepHourMigrationTest]), so the SQL is
 * exposed as an internal constant and pinned to shape here rather than executed. The Swift side CAN open
 * a store in-memory, so `DailySkinTempAbsoluteTests` additionally round-trips the column and proves a
 * re-upsert corrects it; those two have no runnable Kotlin counterpart, which is a property of the test
 * environment and not of the column.
 */
class DailySkinTempAbsoluteMigrationTest {

    @Test
    fun migrationIsOneNullableAdditiveColumn() {
        val sql = WhoopDatabase.DAILY_SKIN_TEMP_ABSOLUTE_MIGRATION_SQL
        assertEquals(listOf("ALTER TABLE `dailyMetric` ADD COLUMN `skinTempC` REAL"), sql)
        val upper = sql.single().uppercase()
        assertTrue(upper.startsWith("ALTER TABLE"))
        // Nullable and defaultless on purpose: a night scored before v34 has no absolute, and inventing
        // one (a DEFAULT, or a backfill statement here) would fabricate a temperature nobody measured.
        assertTrue(!upper.contains("NOT NULL") && !upper.contains("DEFAULT"))
        for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "RENAME ")) {
            assertTrue("migration must not contain $banned", !upper.contains(banned))
        }
    }

    @Test
    fun migrationSpansTheRightVersions() {
        assertEquals(33, WhoopDatabase.MIGRATION_33_34.startVersion)
        assertEquals(34, WhoopDatabase.MIGRATION_33_34.endVersion)
    }

    @Test
    fun oldRowsStayNullAndTheColumnIsIndependentOfTheDeviation() {
        val old = DailyMetric(deviceId = "my-whoop", day = "2026-08-25", skinTempDevC = 0.11)
        assertNull("a pre-v34 row carries no absolute", old.skinTempC)
        // The two are separate columns: writing the absolute must not disturb the deviation, because the
        // deviation is what every existing gate (illness, Charge) reads.
        val scored = old.copy(skinTempC = 34.6)
        assertEquals(34.6, scored.skinTempC!!, 0.0)
        assertEquals(0.11, scored.skinTempDevC!!, 1e-12)
    }
}
