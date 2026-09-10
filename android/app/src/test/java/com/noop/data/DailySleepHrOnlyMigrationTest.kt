package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v35 -> v36 (#1801): whether every sleep session that day was staged from heart rate alone.
 *
 * Twin of the Swift `v42-daily-sleep-hr-only` GRDB migration.
 *
 * This environment has no Robolectric / Room-testing (see [AppleStepHourMigrationTest]), so the SQL is
 * exposed as an internal constant and pinned to shape here rather than executed.
 */
class DailySleepHrOnlyMigrationTest {

    @Test
    fun migrationIsOneNullableAdditiveColumn() {
        val sql = WhoopDatabase.DAILY_SLEEP_HR_ONLY_MIGRATION_SQL
        assertEquals(listOf("ALTER TABLE `dailyMetric` ADD COLUMN `sleepHrOnly` INTEGER"), sql)
        val upper = sql.single().uppercase()
        assertTrue(upper.startsWith("ALTER TABLE"))
        // Nullable and defaultless on purpose. The flag is only knowable from a re-score, and defaulting
        // it to 0 would state "this night had motion" about every night scored before v36 — the exact
        // false reassurance the column exists to remove.
        assertTrue(!upper.contains("NOT NULL") && !upper.contains("DEFAULT"))
        for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "RENAME ")) {
            assertTrue("migration must not contain $banned", !upper.contains(banned))
        }
    }

    @Test
    fun migrationSpansTheRightVersions() {
        assertEquals(35, WhoopDatabase.MIGRATION_35_36.startVersion)
        assertEquals(36, WhoopDatabase.MIGRATION_35_36.endVersion)
    }

    @Test
    fun theFlagIsTriStateAndOldRowsStayUnknown() {
        val old = DailyMetric(deviceId = "my-whoop", day = "2026-09-03", respRateBpm = 13.3)
        assertNull("a pre-v36 row knows nothing about its staging", old.sleepHrOnly)
        // The three states are distinct: unknown, staged with motion, staged without.
        assertEquals(false, old.copy(sleepHrOnly = false).sleepHrOnly)
        assertEquals(true, old.copy(sleepHrOnly = true).sleepHrOnly)
    }
}
