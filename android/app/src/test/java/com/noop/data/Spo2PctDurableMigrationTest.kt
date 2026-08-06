package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * MIGRATION_25_26 — the durable `@82` SpO2 percentage table. Twin of the Swift GRDB migration
 * `v34-spo2-pct-durable` and its `Spo2PctDurableTests`.
 *
 * The 5/MG emits its own computed SpO2 % on `@82` of the v18 record. That byte has been banked since
 * MIGRATION_24_25 — inside `v18AuxSample.fields`, a table CAPPED at 604,800 rows/device (~7 days at 1 Hz)
 * because the aux blob costs ~30 MB/day. So every reading rolled off after a week and was gone
 * permanently: the strap trims its own history the moment an offload is acked, leaving no second copy
 * anywhere. `spo2PctSample` is the narrow, never-pruned sibling that fixes that.
 *
 * The SQL here is hand-written, which is exactly where a mistake is possible, so this test guards its
 * shape; the write path is exercised through a Proxy DAO (the DeepCaptureMigrationTest pattern — there is
 * no SQLite driver on this unit-test classpath) and the DELETE/upsert semantics are proved end-to-end on
 * the Swift twin, which CI runs.
 */
class Spo2PctDurableMigrationTest {

    @Test
    fun migrationCreatesTheDurableTableAndTouchesNothingElse() {
        val sql = WhoopDatabase.SPO2_PCT_DURABLE_MIGRATION_SQL
        assertEquals("one statement: a brand-new table, nothing altered", 1, sql.size)

        // The column order must match Spo2PctSampleEntity's field order (deviceId, ts, pct) and the GRDB
        // schema, or a fresh install, a migrated install and an iOS `.noopbak` disagree.
        assertEquals(
            "CREATE TABLE IF NOT EXISTS `spo2PctSample` (`deviceId` TEXT NOT NULL, " +
                "`ts` INTEGER NOT NULL, `pct` INTEGER NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `ts`))",
            sql[0],
        )

        // Nothing in this migration may touch an existing row or an existing table.
        for (stmt in sql) {
            val upper = stmt.uppercase()
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "ALTER ")) {
                assertFalse("migration must not contain $banned", upper.contains(banned))
            }
        }
        assertEquals(25, WhoopDatabase.MIGRATION_25_26.startVersion)
        assertEquals(26, WhoopDatabase.MIGRATION_25_26.endVersion)
    }

    /**
     * The v3 `spo2Sample` table is NOT the home for this and must be left exactly as it was: its
     * `red`/`ir` are NOT NULL raw ADC channels off the WHOOP 4.0 v24 layout, and
     * `AnalyticsEngine.nightlySpo2RawMeans` averages them into a live tile. Storing percentages there
     * would have meant fabricating red/ir zeros on every insert and dragging that mean toward zero.
     */
    @Test
    fun theWhoop4RawTableIsUntouched() {
        assertFalse(
            "the percentage and the raw ADC pair never share a table",
            WhoopDatabase.SPO2_PCT_DURABLE_MIGRATION_SQL.any { it.contains("spo2Sample") },
        )
        // Its own entity, unchanged: a percentage has no home among these columns.
        val raw = Spo2Sample("d", 1L, red = 100, ir = 200)
        assertEquals(100, raw.red)
        assertEquals(200, raw.ir)
    }

    // MARK: - the in-band demultiplex, exercised through the real insert path

    /** Capture every `spo2PctSample` row `WhoopRepository.insert` would write for [aux]. */
    private fun bankedFor(aux: List<V18AuxRow>): List<Spo2PctSampleEntity> = runBlocking {
        var rows: List<Spo2PctSampleEntity> = emptyList()
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertV18Aux" -> listOf(1L)
                "pruneV18Aux" -> Unit
                "insertSpo2Pct" -> {
                    @Suppress("UNCHECKED_CAST")
                    rows = args[0] as List<Spo2PctSampleEntity>
                    rows.map { 1L }
                }
                else -> throw UnsupportedOperationException("spo2-pct insert must not call ${method.name}")
            }
        } as WhoopDao
        WhoopRepository(dao).insert(StreamBatch(v18Aux = aux), "my-whoop")
        rows
    }

    @Test
    fun inBandValuesPersistVerbatim() {
        val banked = bankedFor(
            listOf(
                V18AuxRow(ts = 100, auxByte82 = 97),
                V18AuxRow(ts = 101, auxByte82 = 94),
                V18AuxRow(ts = 102, auxByte82 = 88),
            ),
        )
        assertEquals(listOf(100L, 101L, 102L), banked.map { it.ts })
        assertEquals(listOf(97, 94, 88), banked.map { it.pct })
        assertEquals(listOf("my-whoop", "my-whoop", "my-whoop"), banked.map { it.deviceId })
    }

    /**
     * The band is INCLUSIVE at both ends — 70 and 100 are real readings, and a gate that quietly dropped
     * the endpoints would bias every night's median upward at exactly the readings that matter most.
     */
    @Test
    fun bandBoundariesAreInclusive() {
        val banked = bankedFor(listOf(V18AuxRow(ts = 200, auxByte82 = 70), V18AuxRow(ts = 201, auxByte82 = 100)))
        assertEquals(listOf(70, 100), banked.map { it.pct })
        assertEquals(70..100, SPO2_CANDIDATE_IN_BAND)
    }

    /**
     * `@82` is MULTIPLEXED: the same byte carries measurements, bit-7 status sentinels, sub-70 diagnostic
     * codes, and 0 for "not emitted". Only 70..100 is a percentage of anything. A sentinel banked as a
     * percentage would not merely be wrong, it would be *plausible* — 0x88 is 136, which no reader would
     * flag, and 0x08 is 8, which reads as catastrophic hypoxia. Rejection has to happen at the boundary.
     */
    @Test
    fun statusSentinelsAndDiagnosticCodesAreRejected() {
        val rejected = listOf(0x00L, 0x08L, 0x45L, 0x80L, 0x88L, 0x90L, 0xA0L, 0xA8L, 0xFFL)
        val banked = bankedFor(rejected.mapIndexed { i, v -> V18AuxRow(ts = 300L + i, auxByte82 = v) })
        assertTrue("no sentinel or diagnostic code may be banked as a percentage", banked.isEmpty())
    }

    /**
     * 101..127 is the EMPTY BAND — nothing has ever been observed there across 626,725 production
     * records. It is what makes measurements and bit-7 sentinels separable by value alone, with no side
     * channel. A value appearing there would mean the demultiplex assumption has broken, so it must not be
     * admitted on the strength of merely being "close to 100".
     */
    @Test
    fun theEmptyBandAbove100IsRejected() {
        val banked = bankedFor((101..127).mapIndexed { i, v -> V18AuxRow(ts = 400L + i, auxByte82 = v.toLong()) })
        assertTrue(banked.isEmpty())
    }

    /** An aux record with no `@82` slot at all banks no percentage — absence stays absence. */
    @Test
    fun absentSlotBanksNothing() {
        assertTrue(bankedFor(listOf(V18AuxRow(ts = 500, statusWord = 7))).isEmpty())
    }

    /**
     * The durable rows are forked from the SAME aux samples, but through their OWN loop — the empty-blob
     * skip on the aux side must never be able to drop an SpO2 reading, and the aux write must still happen.
     */
    @Test
    fun theAuxRowAndThePercentageAreBothBanked(): Unit = runBlocking {
        var auxRows = 0
        var pctRows = 0
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertV18Aux" -> { auxRows = (args[0] as List<*>).size; listOf(1L) }
                "pruneV18Aux" -> Unit
                "insertSpo2Pct" -> { pctRows = (args[0] as List<*>).size; listOf(1L) }
                else -> throw UnsupportedOperationException("must not call ${method.name}")
            }
        } as WhoopDao
        WhoopRepository(dao).insert(
            StreamBatch(v18Aux = listOf(V18AuxRow(ts = 600, auxByte82 = 96))),
            "my-whoop",
        )
        assertEquals("the raw byte is still captured in the aux table — this gate demultiplexes, " +
            "it does not discard", 1, auxRows)
        assertEquals(1, pctRows)
    }

    /**
     * THE LOAD-BEARING PROPERTY. The aux sweep must not reach this table: `pruneV18Aux` deletes only
     * `FROM v18AuxSample`, and there is deliberately no prune query for `spo2PctSample` at all. This is
     * the entire reason MIGRATION_25_26 exists — before it, seven-day-old SpO2 was destroyed with no
     * recoverable copy.
     */
    @Test
    fun thereIsNoPruneForTheDurableTable() {
        val prunes = WhoopDao::class.java.methods.filter { it.name.startsWith("prune") }.map { it.name }
        assertTrue("v18AuxSample is the capped one", prunes.contains("pruneV18Aux"))
        assertTrue(
            "spo2PctSample must have NO rolling prune — it is retained forever, by design. " +
                "Found: $prunes",
            prunes.none { it.startsWith("pruneSpo2Pct") && it != "pruneSpo2PctByTs" },
        )
        // The timestamp heal is the one exception, and it deletes only implausible-clock rows: those are
        // never pruned on AGE, so an unhealed out-of-bounds row here would persist forever.
        assertTrue(prunes.contains("pruneSpo2PctByTs"))
    }

    /**
     * A never-pruned table makes delete-means-gone MORE important, not less: without this the wipe would
     * leave years of blood-oxygen readings behind after the user asked for them to be erased. The
     * whole-set guard is `DeviceRegistryTest.deleteDeviceDataCallsEveryDaoDeleteMethod`; this pins that
     * the DAO method exists at all.
     */
    @Test
    fun theTableIsDeviceScopedForDeleteAllData() {
        val names = DeviceRegistryDao::class.java.methods.map { it.name }
        assertTrue(names.contains("deleteSpo2PctFor"))
        assertTrue("adopt-serial must re-key it too", names.contains("reKeySpo2Pct"))
    }
}
