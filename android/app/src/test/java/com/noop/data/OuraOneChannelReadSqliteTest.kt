package com.noop.data

import java.sql.Connection
import java.sql.DriverManager
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** The one-Oura-channel scoring read ([RR_INTERVALS_SQL]) run against a real SQLite, so the selection is
 *  checked by behaviour and not only as source text. Every fixture and expected list is the Swift twin's
 *  (`RrSourceChannelTests`, "One Oura beat channel per window") verbatim; the channel codes are the durable
 *  storage values (1 green 0x80, 2 SpO2 0x6E, 3 amplitude 0x60, 4 bare 0x44). */
class OuraOneChannelReadSqliteTest {
    private lateinit var db: Connection
    private val ts = 1_750_000_000L

    @Before fun open() {
        db = DriverManager.getConnection("jdbc:sqlite::memory:")
        db.createStatement().use {
            it.execute("CREATE TABLE rrInterval(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL, " +
                "seq INTEGER NOT NULL DEFAULT 0, synced INTEGER NOT NULL DEFAULT 0, ord INTEGER, srcChannel INTEGER, " +
                "tsSuspect INTEGER, PRIMARY KEY(deviceId, ts, rrMs, seq))")
        }
    }

    @After fun close() = db.close()

    /** OR IGNORE, as the store inserts: a 0x6E beat landing on a 0x60 row's (ts, rrMs) key is dropped,
     *  exactly as it is in the Swift twin's fixture. */
    private fun insert(t: Long, rrMs: Int, channel: Int?) {
        db.prepareStatement("INSERT OR IGNORE INTO rrInterval(deviceId, ts, rrMs, srcChannel) VALUES('ring', ?, ?, ?)").use {
            it.setLong(1, t); it.setInt(2, rrMs); it.setObject(3, channel); it.executeUpdate()
        }
    }

    /** (rrMs, srcChannel) in read order, binding the production statement's named parameters. */
    private fun read(sql: String, from: Long, to: Long): List<Pair<Int, Int?>> {
        val names = mutableListOf<String>()
        val bound = Regex(":([A-Za-z][A-Za-z0-9]*)").replace(sql) { names += it.groupValues[1]; "?" }
        val values = mapOf("deviceId" to "ring", "from" to from, "to" to to, "limit" to 1000)
        return db.prepareStatement(bound).use { stmt ->
            names.forEachIndexed { i, n -> stmt.setObject(i + 1, values.getValue(n)) }
            stmt.executeQuery().use { r ->
                buildList {
                    while (r.next()) add(r.getInt("rrMs") to r.getInt("srcChannel").let { if (r.wasNull()) null else it })
                }
            }
        }
    }

    /** 12 s of 0x60, 4 overlapping 0x80 beats, 0x6E over the same seconds, one unlabelled row. */
    private fun oneChannelFixture() {
        for (i in 0 until 12) insert(ts + i, 1000 + i, 3)
        for (i in 0 until 4) insert(ts + 2 * i, 900 + i, 1)
        for (i in 0 until 12) insert(ts + i, 1000 + 8 * i, 2)
        insert(ts + 100, 777, null)
    }

    @Test fun twoOuraBeatChannelsOverOneNightScoreOnlyTheFullerOne() {
        oneChannelFixture()
        val read = read(RR_INTERVALS_SQL, ts, ts + 200)
        assertEquals(listOf(1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 777),
            read.map { it.first })
        assertEquals(setOf(3), read.mapNotNull { it.second }.toSet())
        assertEquals(1, read.count { it.second == null })
    }

    @Test fun whenGreenIsTheFullerChannelItIsTheOneScored() {
        for (i in 0 until 10) insert(ts + i, 950 + i, 1)
        for (i in 0 until 3) insert(ts + 3 * i, 1100 + i, 3)
        val read = read(RR_INTERVALS_SQL, ts, ts + 100)
        assertEquals((950..959).toList(), read.map { it.first })
        assertEquals(setOf(1), read.mapNotNull { it.second }.toSet())
    }

    @Test fun theChannelIsChosenWithinTheRequestedWindow() {
        oneChannelFixture()
        insert(ts + 300, 880, 1)
        insert(ts + 301, 881, 1)
        assertEquals(listOf(880, 881), read(RR_INTERVALS_SQL, ts + 250, ts + 350).map { it.first })
    }

    @Test fun aChannelTieResolvesToTheAmplitudeFamily() {
        for (i in 0 until 3) {
            insert(ts + i, 900 + i, 1)
            insert(ts + i, 1200 + i, 3)
        }
        assertEquals(listOf(1200, 1201, 1202), read(RR_INTERVALS_SQL, ts, ts + 100).map { it.first })
    }

    @Test fun theAmplitudeFamilyIsCountedAndKeptAsOne() {
        for (i in 0 until 6) insert(ts + i, 900 + i, 1)
        for (i in 0 until 8) insert(ts + i, 1000 + i, if (i % 2 == 0) 3 else 4)
        val read = read(RR_INTERVALS_SQL, ts, ts + 100)
        assertEquals((1000..1007).toList(), read.map { it.first })
        assertEquals(setOf(3, 4), read.mapNotNull { it.second }.toSet())
    }

    /** The export makes no selection: both Oura beat channels come back, 0x6E still excluded. */
    @Test fun theRawExportReadKeepsBothBeatChannels() {
        oneChannelFixture()
        val read = read(RAW_RR_INTERVALS_SQL, ts, ts + 200)
        assertEquals(setOf(1, 3), read.mapNotNull { it.second }.toSet())
        assertEquals(12 + 4 + 1, read.size)
    }
}
