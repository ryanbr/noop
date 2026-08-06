package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the v28 -> v29 Room migration (#1073): adds `rrInterval.tsSuspect` and one-time MARKS every
 * stored R-R beat whose ts is in the future (a corrupt Oura ring timestamp), so scoring stops reading
 * them while they stay on disk. This environment has no Robolectric/Room-testing, so the migration SQL is
 * exposed as [WhoopDatabase.RR_FUTURE_QUARANTINE_MIGRATION_SQL] and pinned here. Twin of the Swift
 * WhoopStore `RrFutureQuarantineTests`.
 */
class RrFutureQuarantineMigrationTest {

    @Test
    fun migration_addsNullableColumnThenMarksFutureRowsNonDestructively() {
        val sql = WhoopDatabase.RR_FUTURE_QUARANTINE_MIGRATION_SQL
        assertEquals("one ADD COLUMN + one backfill UPDATE", 2, sql.size)

        // 1. additive nullable column, exactly like srcChannel/ord (no NOT NULL, no DEFAULT).
        assertEquals("ALTER TABLE `rrInterval` ADD COLUMN `tsSuspect` INTEGER", sql[0])
        val alter = sql[0].uppercase()
        assertFalse("column stays nullable: ${sql[0]}", alter.contains("NOT NULL"))
        assertFalse("column has no DEFAULT: ${sql[0]}", alter.contains("DEFAULT"))

        // 2. the backfill only MARKS future rows — never deletes, drops, or rewrites other data.
        val update = sql[1].uppercase()
        assertTrue("marks suspect rows: ${sql[1]}", update.startsWith("UPDATE") && update.contains("SET `TSSUSPECT` = 1"))
        assertTrue("only rows whose ts is in the future: ${sql[1]}", update.contains("WHERE `TS` >"))
        for (banned in listOf("DELETE", "DROP", "CREATE", "INSERT")) {
            assertFalse("quarantine must not '$banned' (real beats, kept inspectable): ${sql[1]}", update.contains(banned))
        }
    }

    @Test
    fun migration_versionPair_is28to29() {
        assertEquals(28, WhoopDatabase.MIGRATION_28_29.startVersion)
        assertEquals(29, WhoopDatabase.MIGRATION_28_29.endVersion)
    }
}
