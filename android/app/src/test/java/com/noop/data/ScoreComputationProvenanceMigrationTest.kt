package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the additive score-computation provenance schema and deterministic row construction. */
class ScoreComputationProvenanceMigrationTest {
    @Test
    fun migrationIsAdditiveAndMatchesEntityShape() {
        val sql = WhoopDatabase.SCORE_COMPUTATION_PROVENANCE_MIGRATION_SQL
        assertEquals(2, sql.size)
        assertEquals(
            "CREATE TABLE IF NOT EXISTS `scoreComputationProvenance` (`deviceId` TEXT NOT NULL, " +
                "`day` TEXT NOT NULL, `key` TEXT NOT NULL, `computedBy` TEXT NOT NULL, " +
                "`computedAt` INTEGER NOT NULL, `scope` TEXT NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `day`, `key`))",
            sql[0],
        )
        assertEquals(
            "CREATE INDEX IF NOT EXISTS `idx_scoreComputationProvenance_computedBy` " +
                "ON `scoreComputationProvenance` (`computedBy`)",
            sql[1],
        )
        for (statement in sql) {
            val upper = statement.uppercase()
            assertTrue(upper.startsWith("CREATE "))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "ALTER ")) {
                assertFalse("migration must not contain $banned", upper.contains(banned))
            }
        }
        assertEquals(33, WhoopDatabase.MIGRATION_33_34.startVersion)
        assertEquals(34, WhoopDatabase.MIGRATION_33_34.endVersion)
        assertEquals(34, WhoopDatabase.SCHEMA_VERSION)
    }

    @Test
    fun rowsAreDeduplicatedOrderedAndStampedAsOnePass() {
        val stamp = ScoreComputationStamp(
            computedBy = ScoreComputationStamp.buildIdentity("android", "10.5.0", "221"),
            computedAt = 1_724_460_000_000,
        )
        val rows = scoreComputationProvenanceRows(
            deviceId = "my-whoop-noop",
            cells = listOf(
                "2026-07-25" to "strain",
                "2026-07-24" to "recovery",
                "2026-07-24" to "recovery",
            ),
            stamp = stamp,
            scope = ScoreComputationScope.SCORE_WINDOW,
        )

        assertEquals("android:10.5.0+221", stamp.computedBy)
        assertEquals(2, rows.size)
        assertEquals(listOf("2026-07-24", "2026-07-25"), rows.map { it.day })
        assertTrue(rows.all { it.computedBy == stamp.computedBy })
        assertTrue(rows.all { it.computedAt == stamp.computedAt })
        assertTrue(rows.all { it.scope == "score-window" })
        assertEquals(ScoreComputationScope.METRIC_SERIES, ScoreComputationScope.fromStorageId("metric-series"))
        assertNull(ScoreComputationScope.fromStorageId("future-scope"))
    }
}
