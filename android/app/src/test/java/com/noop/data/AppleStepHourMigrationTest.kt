package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v30 -> v31 Room migration (the `appleStepHour` table), the Android twin of the Swift
 * WhoopStore `v38-apple-step-hour` migration (originally PR #369). This environment has no Robolectric /
 * Room-testing, so the migration's SQL is exposed as an internal constant
 * ([WhoopDatabase.APPLE_STEP_HOUR_MIGRATION_SQL]) and pinned here to Room's generated shape for
 * [AppleStepHour]:
 *
 *  - one CREATE TABLE IF NOT EXISTS statement — deviceId TEXT NOT NULL, ts INTEGER NOT NULL, steps INTEGER
 *    NOT NULL, composite PRIMARY KEY (deviceId, ts) in declaration order.
 *  - ADDITIVE: CREATE TABLE only; no DROP/DELETE/UPDATE/INSERT/ALTER on existing data.
 *
 * SCHEMA-ONLY parity: the Apple-Health hourly-step IMPORT that populates this table is iOS-only (HealthKit
 * has no Android analogue), so Android carries the table for .noopbak byte-parity but no importer writes it
 * — the same arrangement the older `appleDaily` table already has. The column set + order + PK must match
 * the GRDB migration in Packages/WhoopStore/Sources/WhoopStore/Database.swift so the two schemas agree.
 */
class AppleStepHourMigrationTest {

    @Test
    fun migration_isAdditive_onlyCreateTable() {
        val sql = WhoopDatabase.APPLE_STEP_HOUR_MIGRATION_SQL
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
                "CREATE TABLE IF NOT EXISTS `appleStepHour` (`deviceId` TEXT NOT NULL, " +
                    "`ts` INTEGER NOT NULL, `steps` INTEGER NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
            ),
            WhoopDatabase.APPLE_STEP_HOUR_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is30to31() {
        assertEquals(30, WhoopDatabase.MIGRATION_30_31.startVersion)
        assertEquals(31, WhoopDatabase.MIGRATION_30_31.endVersion)
    }

    /** The declared schema version must track the `@Database(version = …)` the migration lands on. */
    @Test
    fun schemaVersionConstant_matchesMigrationTarget() {
        assertEquals(WhoopDatabase.MIGRATION_30_31.endVersion, WhoopDatabase.SCHEMA_VERSION)
    }

    /**
     * The entity carries the hour-bucket start ts + the cumulative step sum verbatim; the natural key
     * (deviceId, ts) makes the hourly upsert idempotent, exactly like the GRDB ON CONFLICT(deviceId, ts).
     */
    @Test
    fun appleStepHour_entity_shape() {
        val row = AppleStepHour(deviceId = "apple-health", ts = 1_780_917_200L, steps = 250)
        assertEquals("apple-health", row.deviceId)
        assertEquals(1_780_917_200L, row.ts)
        assertEquals(250, row.steps)
    }
}
