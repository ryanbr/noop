package com.noop.data

import com.noop.protocol.Whoop5Ecg
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * Guards the additive v41 -> v42 Room migration (the `ecgWaveformSample` table, #2847), the Android twin
 * of the Swift WhoopStore `v48-ecg-waveform` GRDB migration, plus the repository plumbing that banks a
 * record and sweeps the table.
 *
 * This environment has no Robolectric Room, so the migration SQL is exposed as an internal constant
 * ([WhoopDatabase.ECG_WAVEFORM_MIGRATION_SQL]) and pinned here against Room's generated shape for
 * [EcgWaveformSampleEntity]; the write plumbing is exercised through a Proxy [WhoopDao] with no DB. The
 * same split the PPG waveform table uses, for the same reason.
 *
 * Swift twin: `EcgWaveformSampleTests`, which runs the equivalents against a real database.
 */
class EcgWaveformMigrationTest {

    // Migration schema

    @Test
    fun migration_isAdditive_onlyCreateTable() {
        val sql = WhoopDatabase.ECG_WAVEFORM_MIGRATION_SQL
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
        // deviceId TEXT, ts INTEGER, sequence INTEGER, record BLOB — column order == entity field order,
        // matching the GRDB schema's t.column(deviceId/ts/sequence/record) order.
        //
        // The key is (deviceId, ts, SEQUENCE), three columns where every per-second stream beside this
        // one keys on two, because two R16 records can be stamped inside one strap-second at the start of
        // a reading and the two-column key dropped the second of them silently. The Swift twin proves
        // that against a real database; here the SQL is what must not drift back.
        //
        // The ENTITY's own key is not asserted here, and not for want of trying: Room's `@Entity` is
        // CLASS-retained, so `getAnnotation` hands back null at runtime and a reflection check throws
        // rather than failing. It is pinned twice over without reflection anyway, by
        // `WhoopDatabaseUpgradeTest` byte-matching Room's generated v42 export against the committed one,
        // and by `SchemaOracleTest` comparing that export's key to schema_oracle.json.
        assertEquals(
            listOf(
                "CREATE TABLE IF NOT EXISTS `ecgWaveformSample` (`deviceId` TEXT NOT NULL, " +
                    "`ts` INTEGER NOT NULL, `sequence` INTEGER NOT NULL, `record` BLOB NOT NULL, " +
                    "PRIMARY KEY(`deviceId`, `ts`, `sequence`))",
            ),
            WhoopDatabase.ECG_WAVEFORM_MIGRATION_SQL,
        )
    }


    @Test
    fun migration_versionPair_is41to42() {
        assertEquals(41, WhoopDatabase.MIGRATION_41_42.startVersion)
        assertEquals(42, WhoopDatabase.MIGRATION_41_42.endVersion)
    }

    // Store-write plumbing

    private fun record(seed: Int = 7) =
        ByteArray(Whoop5Ecg.R16_INNER_LENGTH) { ((seed + it) and 0xff).toByte() }

    @Test
    fun repositoryInsertBanksTheRecordVerbatim() = runBlocking {
        var captured: List<EcgWaveformSampleEntity>? = null
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertEcgWaveform" -> {
                    @Suppress("UNCHECKED_CAST")
                    captured = args[0] as List<EcgWaveformSampleEntity>
                    listOf(1L)
                }
                else -> throw UnsupportedOperationException("ECG-only insert must not call ${method.name}")
            }
        } as WhoopDao

        WhoopRepository(dao).insert(
            StreamBatch(ecgWaveform = listOf(
                EcgWaveformRow(ts = 1_760_000_000L, sequence = 74_565L, record = record()),
            )),
            deviceId = "my-whoop",
        )

        val rows = captured ?: error("insertEcgWaveform was never called")
        assertEquals(1, rows.size)
        assertEquals("my-whoop", rows[0].deviceId)
        assertEquals(1_760_000_000L, rows[0].ts)
        assertEquals(74_565L, rows[0].sequence)
        // The stored blob is the record, byte for byte: nothing is packed, re-encoded or truncated.
        assertArrayEquals(record(), rows[0].record)
    }

    /**
     * A record of the wrong length is SKIPPED rather than banked short. [Whoop5Ecg.parseR16] refuses any
     * other length, so a short blob would read back as undecodable for the rest of that row's life, and
     * keeping the table's one structural invariant true is worth more than a partial row. Twin of the
     * Swift insert's own guard.
     */
    @Test
    fun aRecordOfTheWrongLengthIsNotBanked() = runBlocking {
        var called = false
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "insertEcgWaveform" -> { called = true; listOf(1L) }
                else -> throw UnsupportedOperationException("must not call ${method.name}")
            }
        } as WhoopDao

        WhoopRepository(dao).insert(
            StreamBatch(ecgWaveform = listOf(
                EcgWaveformRow(ts = 100L, sequence = 1L, record = byteArrayOf(1, 2, 3)),
            )),
            deviceId = "my-whoop",
        )
        assertTrue("a short record must not reach the DAO at all", !called)
    }

    // Rolling retention
    //
    // WHAT THESE TESTS DO AND DO NOT COVER, on the same terms as the PPG waveform block in
    // PpgWaveformMigrationTest: they drive a Proxy DAO, so they pin the repository's AMORTISATION (when a
    // sweep fires, with which deviceId and cap, and whose budget paid for it) and never execute
    // `pruneEcgWaveform`'s SQL. The statement's semantics -- newest-N kept, and the DELETE scoped so one
    // strap's sweep cannot evict another's rows -- are proven on the Swift side against a real database by
    // `EcgWaveformSampleTests`, and the two statements are deliberately identical text modulo the
    // parameter syntax. A change to the SQL here MUST be mirrored there, because this file cannot fail
    // for it.

    /** Records every `pruneEcgWaveform(deviceId, keep)` the repository makes. */
    private fun sweepRecordingDao(sweeps: MutableList<Pair<String, Int>>): WhoopDao =
        Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "insertEcgWaveform" -> listOf(1L)
                "pruneEcgWaveform" -> { sweeps.add((args[0] as String) to (args[1] as Int)); Unit }
                else -> throw UnsupportedOperationException("unexpected DAO call ${method.name}")
            }
        } as WhoopDao

    private fun batch(ts: Long) =
        StreamBatch(ecgWaveform = listOf(EcgWaveformRow(ts = ts, sequence = ts, record = record())))

    @Test
    fun theSweepFiresOnceTheBudgetIsSpent() = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        val repo = WhoopRepository(sweepRecordingDao(sweeps))
        for (ts in 100L..103L) {
            repo.insert(batch(ts), deviceId = "my-whoop",
                ecgWaveformRetentionRows = 2, ecgWaveformPruneEveryRows = 4)
        }
        assertEquals(listOf("my-whoop" to 2), sweeps)
    }

    @Test
    fun theSweepDoesNotFireUnderTheBudget() = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        val repo = WhoopRepository(sweepRecordingDao(sweeps))
        for (ts in 100L..102L) {
            repo.insert(batch(ts), deviceId = "my-whoop",
                ecgWaveformRetentionRows = 2, ecgWaveformPruneEveryRows = 50)
        }
        assertEquals(emptyList<Pair<String, Int>>(), sweeps)
    }

    /** The counter resets, so a long reading sweeps repeatedly rather than latching after the first. */
    @Test
    fun theBudgetResetsAfterEachSweep() = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        val repo = WhoopRepository(sweepRecordingDao(sweeps))
        for (ts in 100L..103L) {
            repo.insert(batch(ts), deviceId = "my-whoop",
                ecgWaveformRetentionRows = 2, ecgWaveformPruneEveryRows = 2)
        }
        assertEquals(listOf("my-whoop" to 2, "my-whoop" to 2), sweeps)
    }

    /** The budget is per device, because the delete is: one strap must not spend another's. */
    @Test
    fun theBudgetIsNotSharedBetweenDevices() = runBlocking {
        val sweeps = mutableListOf<Pair<String, Int>>()
        val repo = WhoopRepository(sweepRecordingDao(sweeps))
        repo.insert(batch(100L), deviceId = "strap-a",
            ecgWaveformRetentionRows = 2, ecgWaveformPruneEveryRows = 2)
        repo.insert(batch(100L), deviceId = "strap-b",
            ecgWaveformRetentionRows = 2, ecgWaveformPruneEveryRows = 2)
        assertEquals("neither strap reached its own budget", emptyList<Pair<String, Int>>(), sweeps)
    }

    /** The shipped constants are the ones #2847's arithmetic was written against. */
    @Test
    fun theShippedCapsMatchTheirSwiftTwins() {
        assertEquals(36_000, WhoopRepository.ECG_WAVEFORM_RETENTION_ROWS)
        assertEquals(600, WhoopRepository.ECG_WAVEFORM_PRUNE_EVERY_ROWS)
    }
}
