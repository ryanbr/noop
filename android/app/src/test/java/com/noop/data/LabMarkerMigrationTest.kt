package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v10 -> v11 Room migration (the `labMarker` Lab Book table) — the Android twin
 * of the Swift WhoopStore v17 migration. This environment has no Robolectric / Room-testing, so the
 * migration's SQL is exposed as internal constants ([WhoopDatabase.LAB_MARKER_MIGRATION_SQL]) and
 * pinned here to Room's generated-schema shape:
 *
 *  - PRIMARY KEY is the single TEXT `id`.
 *  - `value`/`valueText`/`note`/`referenceText` are the only nullable columns; everything else is
 *    NOT NULL with NO SQL DEFAULT (a Kotlin construction default never reaches the schema).
 *  - Three indexes byte-for-byte the Swift v17 ones: a UNIQUE natural-key index + two lookup indexes,
 *    with the exact Room-derived names.
 *  - ADDITIVE: only CREATE statements; no ALTER/DROP/DELETE/UPDATE/INSERT on existing tables.
 */
class LabMarkerMigrationTest {

    @Test
    fun migration_isAdditive_onlyCreateStatements() {
        val sql = WhoopDatabase.LAB_MARKER_MIGRATION_SQL
        assertEquals("table + 3 indexes", 4, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only CREATE statements allowed, got: $s", up.startsWith("CREATE"))
            for (banned in listOf("DROP ", "ALTER ", "DELETE ", "UPDATE ", "INSERT ")) {
                assertTrue("additive migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_createsLabMarkerTable_withRoomSchemaShape() {
        val create = WhoopDatabase.LAB_MARKER_CREATE_SQL

        assertTrue("single-column TEXT primary key", create.contains("PRIMARY KEY(`id`)"))

        // NOT NULL columns (Kotlin non-null, no SQL default).
        for (col in listOf("`id`", "`deviceId`", "`markerKey`", "`category`", "`day`", "`unit`", "`source`")) {
            assertTrue("$col must be NOT NULL", create.contains("$col TEXT NOT NULL"))
        }
        assertTrue("`takenAt` must be INTEGER NOT NULL", create.contains("`takenAt` INTEGER NOT NULL"))

        // Nullable columns (Kotlin `?`): declared with the type and NO `NOT NULL`.
        assertTrue("`value` is nullable REAL", create.contains("`value` REAL") && !create.contains("`value` REAL NOT NULL"))
        for (nullableText in listOf("`valueText`", "`note`", "`referenceText`")) {
            assertTrue(
                "$nullableText is nullable TEXT",
                create.contains("$nullableText TEXT") && !create.contains("$nullableText TEXT NOT NULL"),
            )
        }

        // No SQL DEFAULT anywhere (a Kotlin construction default never reaches the schema).
        assertTrue("no SQL DEFAULT in the CREATE TABLE", !create.uppercase().contains("DEFAULT"))
    }

    @Test
    fun migration_createsExactIndexes() {
        assertEquals(
            listOf(
                "CREATE UNIQUE INDEX IF NOT EXISTS `idx_labMarker_natural` " +
                    "ON `labMarker` (`deviceId`, `markerKey`, `takenAt`, `source`)",
                "CREATE INDEX IF NOT EXISTS `idx_labMarker_device_marker_takenAt` " +
                    "ON `labMarker` (`deviceId`, `markerKey`, `takenAt`)",
                "CREATE INDEX IF NOT EXISTS `idx_labMarker_device_category` " +
                    "ON `labMarker` (`deviceId`, `category`)",
            ),
            WhoopDatabase.LAB_MARKER_INDEX_SQL,
        )
    }

    @Test
    fun migration_versionPair_is10to11() {
        assertEquals(10, WhoopDatabase.MIGRATION_10_11.startVersion)
        assertEquals(11, WhoopDatabase.MIGRATION_10_11.endVersion)
    }
}
