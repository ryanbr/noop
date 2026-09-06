package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * Guards the additive v19 -> v20 Room migration (the `ppgWaveformSample` table, issue #156 follow-up), the
 * Android twin of the Swift WhoopStore `v27-ppg-waveform` GRDB migration (PR #415), plus the packed-BLOB
 * encoding that must be byte-identical to Swift `WhoopStore.packPpgSamples` for a `.noopbak` to round-trip.
 *
 * This environment has no Robolectric Room, so the migration SQL is exposed as an internal constant
 * ([WhoopDatabase.PPG_WAVEFORM_MIGRATION_SQL]) and pinned here to Room's generated shape for
 * [PpgWaveformSampleEntity]; the store-write plumbing is exercised through a Proxy [WhoopDao] (no DB).
 */
class PpgWaveformMigrationTest {

    // MARK: - Migration schema

    @Test
    fun migration_isAdditive_onlyCreateTable() {
        val sql = WhoopDatabase.PPG_WAVEFORM_MIGRATION_SQL
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
        // deviceId TEXT, ts INTEGER, samples BLOB — column order == entity field order, matching the GRDB
        // schema's t.column(deviceId/ts/samples) order and PRIMARY KEY(deviceId, ts).
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `ppgWaveformSample` (`deviceId` TEXT NOT NULL, " +
                    "`ts` INTEGER NOT NULL, `samples` BLOB NOT NULL, PRIMARY KEY(`deviceId`, `ts`))",
            ),
            WhoopDatabase.PPG_WAVEFORM_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is19to20() {
        assertEquals(19, WhoopDatabase.MIGRATION_19_20.startVersion)
        assertEquals(20, WhoopDatabase.MIGRATION_19_20.endVersion)
    }

    @Test
    fun burstIndexMigration_isAdditiveAndNullable() {
        assertEquals(
            listOf("ALTER TABLE `ppgWaveformSample` ADD COLUMN `burstIndex` INTEGER"),
            WhoopDatabase.PPG_BURST_INDEX_MIGRATION_SQL,
        )
        assertEquals(32, WhoopDatabase.MIGRATION_32_33.startVersion)
        assertEquals(33, WhoopDatabase.MIGRATION_32_33.endVersion)
    }

    // MARK: - Packed-BLOB encoding (byte-identical to Swift WhoopStore.packPpgSamples)

    @Test
    fun packUnpackRoundTrips() {
        // Includes the i16 extremes and real AC-coupled negatives — exercises signed packing end to end.
        val samples = listOf(0, 1, -1, 32767, -32768, -1432, 12345)
        val packed = StreamPersistence.packPpgSamples(samples)
        assertEquals("2 bytes/sample, no per-record overhead", samples.size * 2, packed.size)
        assertEquals(samples, StreamPersistence.unpackPpgSamples(packed))
    }

    @Test
    fun packIsLittleEndianI16() {
        // -1432 == 0xFA68: little-endian low byte 0x68 first, high byte 0xFA second (matches GRDB blob bytes).
        val packed = StreamPersistence.packPpgSamples(listOf(-1432))
        assertArrayEquals(byteArrayOf(0x68.toByte(), 0xFA.toByte()), packed)
    }

    @Test
    fun unpackDropsTrailingOddByte() {
        // A corrupt/truncated blob (odd byte count) must not crash the read path.
        val data = StreamPersistence.packPpgSamples(listOf(1, 2, 3)) + byteArrayOf(0xFF.toByte())
        assertEquals(listOf(1, 2, 3), StreamPersistence.unpackPpgSamples(data))
    }

    @Test
    fun packHandlesShortAndEmptyArrays() {
        assertEquals(listOf(7, -8), StreamPersistence.unpackPpgSamples(StreamPersistence.packPpgSamples(listOf(7, -8))))
        assertEquals(emptyList<Int>(), StreamPersistence.unpackPpgSamples(StreamPersistence.packPpgSamples(emptyList())))
    }

    // MARK: - Store-write plumbing (repository packs + inserts through the DAO)

    @Test
    fun repositoryInsertPacksWaveformAndCallsDao() = runBlocking {
        val realSamples = listOf(
            -1432, -1332, -1139, -954, -629, -436, -326, -294, -147, -170, -43, -5,
            -201, -918, -1563, -1833, -1313, -930, -616, -293, -422, -380, -235, -164,
        )
        var captured: List<PpgWaveformSampleEntity>? = null
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertPpgWaveform" -> {
                    @Suppress("UNCHECKED_CAST")
                    captured = args[0] as List<PpgWaveformSampleEntity>
                    listOf(1L)
                }
                else -> throw UnsupportedOperationException("waveform-only insert must not call ${method.name}")
            }
        } as WhoopDao

        WhoopRepository(dao).insert(
            StreamBatch(ppgWaveform = listOf(
                PpgWaveformRow(ts = 1_780_917_232L, samples = realSamples, burstIndex = 7),
            )),
            deviceId = "my-whoop",
        )

        val rows = captured ?: error("insertPpgWaveform was never called")
        assertEquals(1, rows.size)
        assertEquals("my-whoop", rows[0].deviceId)
        assertEquals(1_780_917_232L, rows[0].ts)
        assertEquals(7, rows[0].burstIndex)
        // The stored BLOB is exactly packPpgSamples(samples) — the byte-identical contract vs GRDB.
        assertArrayEquals(StreamPersistence.packPpgSamples(realSamples), rows[0].samples)
        // And it unpacks back to the original samples.
        assertEquals(realSamples, StreamPersistence.unpackPpgSamples(rows[0].samples))
    }

    // MARK: - #1911 rolling retention (twin of Swift PpgWaveformSampleTests' retention block)

    private fun waveformRow(ts: Long) = PpgWaveformRow(ts = ts, samples = listOf(1, -2, 3), burstIndex = 0)

    /** Records every `prunePpgWaveform(deviceId, keep)` the repository makes. */
    private fun sweepRecordingDao(sweeps: MutableList<Pair<String, Int>>): WhoopDao =
        Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertPpgWaveform" -> listOf(1L)
                "insertV18Aux" -> listOf(1L)
                "pruneV18Aux" -> Unit
                "prunePpgWaveform" -> { sweeps.add((args[0] as String) to (args[1] as Int)); Unit }
                else -> throw UnsupportedOperationException("unexpected DAO call ${method.name}")
            }
        } as WhoopDao

    /** Under the sweep threshold nothing is evicted — the overshoot is deliberate amortisation. */
    @Test
    fun waveformRetention_doesNotSweepUnderTheThreshold(): Unit = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        val repo = WhoopRepository(sweepRecordingDao(sweeps))
        repeat(3) { i ->
            repo.insert(
                StreamBatch(ppgWaveform = listOf(waveformRow(1_780_917_232L + i))),
                "my-whoop",
                ppgWaveformPruneEveryRows = 5_000,
            )
        }
        assertEquals("three rows must not reach a 5 000-row budget", 0, sweeps.size)
    }

    /**
     * Once the banked count crosses the threshold the sweep runs, and the counter resets so the next
     * window has to earn its own sweep. It must also pass the RETENTION cap as `keep`, not the budget.
     */
    @Test
    fun waveformRetention_sweepsOnThresholdThenResets(): Unit = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        val repo = WhoopRepository(sweepRecordingDao(sweeps))
        // Two rows per batch against a budget of 3: banked=2 (no sweep), 4 (sweep, reset), 2 (no sweep).
        repeat(3) { i ->
            repo.insert(
                StreamBatch(ppgWaveform = listOf(
                    waveformRow(1_780_917_232L + i * 2), waveformRow(1_780_917_233L + i * 2),
                )),
                "my-whoop",
                ppgWaveformPruneEveryRows = 3,
                ppgWaveformRetentionRows = 99,
            )
        }
        assertEquals("exactly one sweep — the counter must reset after it", 1, sweeps.size)
        assertEquals("my-whoop" to 99, sweeps[0])
    }

    /** The budget is per device, because the delete is — one strap must not spend another's. */
    @Test
    fun waveformRetention_budgetIsNotSharedBetweenDevices(): Unit = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        val repo = WhoopRepository(sweepRecordingDao(sweeps))
        repeat(3) { i ->
            repo.insert(StreamBatch(ppgWaveform = listOf(waveformRow(1_780_917_232L + i))),
                "strap-a", ppgWaveformPruneEveryRows = 4)
        }
        // With a SHARED counter this fourth banked row would cross the threshold and sweep strap-b,
        // evicting nothing from strap-a while zeroing strap-a's budget.
        repo.insert(StreamBatch(ppgWaveform = listOf(waveformRow(1_780_918_000L))),
            "strap-b", ppgWaveformPruneEveryRows = 4)
        assertEquals("neither strap has banked four of its OWN rows yet", 0, sweeps.size)

        repo.insert(StreamBatch(ppgWaveform = listOf(waveformRow(1_780_917_240L))),
            "strap-a", ppgWaveformPruneEveryRows = 4)
        assertEquals(1, sweeps.size)
        assertEquals("strap-a must sweep on its own fourth row", "strap-a", sweeps[0].first)
    }

    /**
     * A batch that banks no waveform row must not sweep, even with a budget of one — a WHOOP 4.0 offload
     * (or any non-v26 second) never pays for the index scan and never evicts. Guards specifically against
     * banking the waveform budget off a DIFFERENT stream's rows.
     */
    @Test
    fun waveformRetention_otherStreamsDoNotBankTheBudget(): Unit = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        WhoopRepository(sweepRecordingDao(sweeps)).insert(
            StreamBatch(v18Aux = listOf(V18AuxRow(ts = 1_780_916_150L, statusWord = 1_792L))),
            "my-whoop",
            ppgWaveformPruneEveryRows = 1,
        )
        assertEquals("a v18-aux batch must not sweep the waveform table", 0, sweeps.size)
    }

    /**
     * The shipped cap is a real bound and matches the Swift constant. Pinned so a future "just make it
     * 7 days" edit has to confront the NEWEST-N rationale on [WhoopRepository.PPG_WAVEFORM_RETENTION_ROWS].
     */
    @Test
    fun shippedWaveformRetentionConstants() {
        assertEquals(604_800, WhoopRepository.PPG_WAVEFORM_RETENTION_ROWS)  // 7 x 86_400 strap-seconds
        assertEquals(10_000, WhoopRepository.PPG_WAVEFORM_PRUNE_EVERY_ROWS)
    }
}
