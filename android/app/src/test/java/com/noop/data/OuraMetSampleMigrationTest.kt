package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v40 -> v41 Room migration (the `ouraMetSample` table, #2242), the Android twin of the
 * Swift WhoopStore `v47-oura-met-sample` migration. No Robolectric / Room-testing here, so the migration's
 * SQL is exposed as an internal constant ([WhoopDatabase.OURA_MET_SAMPLE_MIGRATION_SQL]) and pinned to
 * Room's generated shape for [OuraMetSampleEntity] — column order = field order = the GRDB order
 * (deviceId, ts, met, state, epochS), composite PRIMARY KEY (deviceId, ts). SchemaOracleTest holds the
 * cross-platform column/affinity pin; this test holds the migration itself.
 */
class OuraMetSampleMigrationTest {

    @Test
    fun migration_isAdditive_onlyCreateTable() {
        val sql = WhoopDatabase.OURA_MET_SAMPLE_MIGRATION_SQL
        assertEquals("one CREATE TABLE statement", 1, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only CREATE TABLE allowed, got: $s", up.startsWith("CREATE TABLE"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "ALTER ")) {
                assertTrue("additive migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_createsExactTable() {
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `ouraMetSample` (`deviceId` TEXT NOT NULL, `ts` INTEGER NOT NULL, " +
                    "`met` REAL NOT NULL, `state` INTEGER NOT NULL, `epochS` INTEGER NOT NULL, " +
                    "PRIMARY KEY(`deviceId`, `ts`))",
            ),
            WhoopDatabase.OURA_MET_SAMPLE_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is40to41() {
        assertEquals(40, WhoopDatabase.MIGRATION_40_41.startVersion)
        assertEquals(41, WhoopDatabase.MIGRATION_40_41.endVersion)
        assertEquals(41, WhoopDatabase.SCHEMA_VERSION)
    }

    /** The entity carries the decoded MET and the raw state byte verbatim; the default cadence is 60 s. */
    @Test
    fun entity_shape() {
        val e = OuraMetSampleEntity("oura-2H3B", 1_755_208_800L, 12.8, 3, 60)
        assertEquals(12.8, e.met, 0.0)
        assertEquals(3, e.state)
        assertEquals(60, e.epochS)
    }
}
