package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * MIGRATION_24_25 — the additive shape that lets the four named v18 channels and the fifteen leftover
 * slots be banked at all. Twin of the Swift GRDB `v31-deep-capture-channels` migration test.
 *
 * The SQL here is hand-written, which is exactly where a mistake is possible (Room does not validate it
 * at build time with `exportSchema=false`), so this test guards its shape. The end-to-end read/write is
 * exercised on the Swift twin (`WhoopStoreTests.DeepCaptureChannelsTests`, which CI runs); there is no
 * SQLite driver on this unit-test classpath, matching how every other migration here is covered.
 */
class DeepCaptureMigrationTest {

    @Test
    fun migrationIsAdditiveAndNullablePreserving() {
        val sql = WhoopDatabase.DEEP_CAPTURE_MIGRATION_SQL
        assertEquals(5, sql.size)

        val alters = sql.take(4)
        assertEquals(
            listOf(
                "ALTER TABLE `gravitySample` ADD COLUMN `dynAccel` REAL",
                "ALTER TABLE `sleepStateSample` ADD COLUMN `rawByte` INTEGER",
                "ALTER TABLE `skinTempSample` ADD COLUMN `aux1Raw` INTEGER",
                "ALTER TABLE `skinTempSample` ADD COLUMN `aux2Raw` INTEGER",
            ),
            alters,
        )
        for (stmt in alters) {
            val upper = stmt.uppercase()
            assertTrue(upper.startsWith("ALTER TABLE"))
            assertTrue("must be additive", upper.contains("ADD COLUMN"))
            // NULL is load-bearing: a WHOOP 4.0 never reports these, and history banked before this
            // migration cannot be backfilled (the strap already trimmed it), so an absent channel must
            // stay absent rather than become a fabricated 0 indistinguishable from a real zero reading.
            assertFalse("added columns must be nullable", upper.contains("NOT NULL"))
            assertFalse("no default — absent means the strap never reported it", upper.contains("DEFAULT"))
        }

        // The new table's column order must match V18AuxSampleEntity's field order (deviceId, ts,
        // fields) and the GRDB schema, or a fresh install and a migrated install disagree.
        assertEquals(
            "CREATE TABLE IF NOT EXISTS `v18AuxSample` (`deviceId` TEXT NOT NULL, " +
                "`ts` INTEGER NOT NULL, `fields` BLOB NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `ts`))",
            sql[4],
        )

        // Nothing in this migration may touch an existing row.
        for (stmt in sql) {
            val upper = stmt.uppercase()
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ")) {
                assertFalse("migration must not contain $banned", upper.contains(banned))
            }
        }
        assertEquals(24, WhoopDatabase.MIGRATION_24_25.startVersion)
        assertEquals(25, WhoopDatabase.MIGRATION_24_25.endVersion)
    }

    /** The added columns must be absent — not 0 — on a row that never carried them. */
    @Test
    fun entitiesDefaultTheNewColumnsToNullSoLegacyRowsStayHonest() {
        assertEquals(null, GravitySample("d", 1L, 0.0, 0.0, 1.0).dynAccel)
        assertEquals(null, SleepStateSampleEntity("d", 1L, 2).rawByte)
        assertEquals(null, SkinTempSample("d", 1L, 3057).aux1Raw)
        assertEquals(null, SkinTempSample("d", 1L, 3057).aux2Raw)
    }

    /** `state` must stay exactly the high nibble of the raw byte — #175's behaviour is bit-identical. */
    @Test
    fun sleepStateColumnStaysTheHighNibbleOfTheRawByte() {
        for (raw in 0..0xFF) {
            val e = SleepStateSampleEntity("d", 1L, (raw shr 4) and 3, rawByte = raw)
            assertEquals((e.rawByte!! shr 4) and 3, e.state)
        }
    }

    // MARK: - Rolling retention (insert plumbing through a Proxy DAO, the RawImuMigrationTest pattern)

    /**
     * `v18AuxSample` is CAPPED, not unbounded — the insert must follow the write with the rolling prune,
     * passing the shipped constant. Twin of the Swift `testAuxRowsAreCappedNewestFirst`; the DELETE's own
     * semantics are proved end-to-end there (no SQLite driver on this classpath).
     */
    @Test
    fun repositoryInsertV18Aux_insertsThenPrunes() = runBlocking {
        var inserted: List<V18AuxSampleEntity>? = null
        var prunedDevice: String? = null
        var prunedKeep = -1
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertV18Aux" -> {
                    @Suppress("UNCHECKED_CAST")
                    inserted = args[0] as List<V18AuxSampleEntity>
                    listOf(1L)
                }
                "pruneV18Aux" -> { prunedDevice = args[0] as String; prunedKeep = args[1] as Int; Unit }
                else -> throw UnsupportedOperationException("v18-aux insert must not call ${method.name}")
            }
        } as WhoopDao

        WhoopRepository(dao).insert(
            StreamBatch(v18Aux = listOf(V18AuxRow(ts = 1_780_916_150L, statusWord = 1_792L))),
            "my-whoop",
            // Threshold 1 so a single row crosses it. Before #888 the sweep ran on every batch and this
            // test passed without saying anything about the threshold; once the sweep became amortised at
            // 10 000 rows, one row could no longer trigger it and this assertion could not hold. The Swift
            // twin was given injectable parameters in that PR and this one was not, so it has been failing
            // on main ever since — invisibly, because android.yml is disabled.
            v18AuxPruneEveryRows = 1,
        )

        assertEquals(1, inserted!!.size)
        assertEquals("my-whoop", prunedDevice)
        assertEquals(WhoopRepository.V18_AUX_RETENTION_ROWS, prunedKeep)
    }

    /**
     * Under the threshold the sweep must NOT run — overshoot is the whole point of amortising it, and a
     * sweep per batch is the cost #888 removed. Twin of Swift's
     * `testRetentionSweepIsDeferredBelowTheThreshold`.
     */
    @Test
    fun repositoryInsertV18Aux_defersSweepBelowTheThreshold(): Unit = runBlocking {
        var pruneCalls = 0
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "insertV18Aux" -> listOf(1L)
                "pruneV18Aux" -> { pruneCalls++; Unit }
                else -> throw UnsupportedOperationException("v18-aux insert must not call ${method.name}")
            }
        } as WhoopDao

        val repo = WhoopRepository(dao)
        repeat(3) { i ->
            repo.insert(
                StreamBatch(v18Aux = listOf(V18AuxRow(ts = 1_780_916_150L + i, statusWord = 1_792L))),
                "my-whoop",
                v18AuxPruneEveryRows = 5_000,
            )
        }
        assertEquals("three rows must not reach a 5 000-row budget", 0, pruneCalls)
    }

    /**
     * Once the banked count crosses the threshold the sweep runs, and the counter resets so the next
     * window has to earn its own sweep. Twin of Swift's `testRetentionSweepRunsOnceTheThresholdIsCrossed`
     * and `testTheAmortisationCounterResetsAfterEachSweep`.
     */
    @Test
    fun repositoryInsertV18Aux_sweepsOnThresholdThenResets(): Unit = runBlocking {
        var pruneCalls = 0
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "insertV18Aux" -> listOf(1L)
                "pruneV18Aux" -> { pruneCalls++; Unit }
                else -> throw UnsupportedOperationException("v18-aux insert must not call ${method.name}")
            }
        } as WhoopDao

        val repo = WhoopRepository(dao)
        // Two rows per batch against a budget of 3: after batch 1 banked=2 (no sweep), after batch 2
        // banked=4 (sweep, reset to 0), after batch 3 banked=2 (no second sweep).
        repeat(3) { i ->
            repo.insert(
                StreamBatch(
                    v18Aux = listOf(
                        V18AuxRow(ts = 1_780_916_150L + i * 2, statusWord = 1_792L),
                        V18AuxRow(ts = 1_780_916_151L + i * 2, statusWord = 1_792L),
                    ),
                ),
                "my-whoop",
                v18AuxPruneEveryRows = 3,
            )
        }
        assertEquals("exactly one sweep — the counter must reset after it", 1, pruneCalls)
    }

    /** A batch whose aux rows all pack to nothing writes no row, so it must not sweep either. */
    @Test
    fun repositoryInsertV18Aux_allAbsentTouchesNoDao(): Unit = runBlocking {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            throw AssertionError("an all-absent aux batch must not touch the DAO (${method.name})")
        } as WhoopDao
        WhoopRepository(dao).insert(StreamBatch(v18Aux = listOf(V18AuxRow(ts = 1L))), "my-whoop")
        Unit
    }

    /**
     * A batch of ONLY aux rows must not read as empty. `insert` early-returns on [StreamBatch.isEmpty],
     * so leaving `v18Aux` out of it silently banks nothing — and Swift's `Streams.isEmpty` counts it, so
     * the same offload would drop rows on Android alone.
     */
    @Test
    fun auxOnlyBatchIsNotEmpty() {
        assertFalse(StreamBatch(v18Aux = listOf(V18AuxRow(ts = 1L, statusWord = 7L))).isEmpty)
        assertTrue(StreamBatch().isEmpty)
    }

    /** The shipped cap is a real bound, matching the Swift constant. */
    @Test
    fun shippedRetentionConstant() {
        assertEquals(604_800, WhoopRepository.V18_AUX_RETENTION_ROWS)   // 7 x 86_400 strap-seconds
        assertTrue(WhoopRepository.V18_AUX_RETENTION_ROWS > WhoopRepository.RAW_IMU_RETENTION_ROWS)
    }
}
