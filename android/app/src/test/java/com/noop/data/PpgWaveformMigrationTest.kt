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
}
