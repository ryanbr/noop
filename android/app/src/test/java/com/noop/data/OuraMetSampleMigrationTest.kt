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

/**
 * The insert's minute-level dedupe (#2242, 2026-09-17). `ts` is anchored ring time under a per-session
 * `0x13` anchor, so the same ring record re-served under a second session lands 2–5 s off its first copy
 * and the (deviceId, ts) key keeps both — 157 twins in 1,035 rows on the first hardware day, +8 % on the
 * day. A twin starts less than half a period after a kept start; a successor 59 s on — the ring's grid
 * stepping back a second (2026-09-18) — is the next minute and stays. Twin of Swift
 * `OuraMetStoreTests.testDroppingTwinsIsPureAndOrderIndependent`.
 */
class OuraMetSampleTwinTest {
    private fun s(ts: Long, met: Double = 1.0, epochS: Int = 60) = OuraMetSampleEntity("oura-A", ts, met, 0, epochS)

    @Test
    fun droppingTwins_isPureAndOrderIndependent() {
        val t = 1_000L
        val existing = listOf(s(t), s(t + 120))
        val incoming = listOf(
            s(t + 4, 9.0),     // 4-s twin of the stored t
            s(t + 60, 2.0),    // 1-s twin of the accepted t+59
            s(t + 59, 5.0),    // 59 s after t: the next minute, kept
            s(t + 149, 9.0),   // 29 s after the stored t+120: twin
            s(t + 150, 2.0),   // 30 s after: half a period, kept
            s(t + 240, 2.0),   // free minute
            s(t + 241, 2.0),   // 1-s twin of the accepted t+240
        )
        assertEquals(listOf(t + 59, t + 150, t + 240), OuraMetSampleEntity.droppingTwins(incoming, existing).map { it.ts })
        assertEquals(
            listOf(t + 59, t + 150, t + 240),
            OuraMetSampleEntity.droppingTwins(incoming.reversed(), existing).map { it.ts },
        )
        assertEquals(emptyList<OuraMetSampleEntity>(), OuraMetSampleEntity.droppingTwins(emptyList(), existing))
        // Mixed periods: half the SHORTER one decides.
        assertEquals(true, OuraMetSampleEntity.isTwin(s(t, epochS = 120), s(t + 29)))
        assertEquals(false, OuraMetSampleEntity.isTwin(s(t, epochS = 120), s(t + 30)))
    }

    /** Twins inside one batch collapse the same way: earlier start wins, lower MET on an exact tie. */
    @Test
    fun droppingTwins_withinOneBatch() {
        val t = 1_000L
        val out = OuraMetSampleEntity.droppingTwins(listOf(s(t, 5.0), s(t + 3, 2.0), s(t, 4.0)), emptyList())
        assertEquals(listOf(s(t, 4.0)), out)
    }

    /** The 2026-09-18 hardware shape: a grid that steps back one second every 30 minutes keeps every minute. */
    @Test
    fun droppingTwins_phaseStepSuccessorsAllKept() {
        val t = 1_755_208_800L
        val rows = (0 until 120).map { s(t + it * 60L - it / 30) }
        assertEquals(120, OuraMetSampleEntity.droppingTwins(rows, emptyList()).size)
    }
}
