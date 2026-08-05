package com.noop.data

import com.noop.oura.OuraDecoders
import com.noop.oura.OuraDriver
import com.noop.oura.OuraEvent
import com.noop.oura.OuraFraming
import com.noop.oura.OuraIBI
import com.noop.oura.OuraIbiChannel
import com.noop.oura.OuraRecord
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraTestHex
import com.noop.protocol.RrSourceChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * #1071 — `rrInterval` mixed two optical channels, so every Oura beat was stored twice.
 *
 * The ring measures the SAME heartbeats on more than one tag (0x80 green all night, 0x6E only while an
 * SpO2 measurement runs) and both decoded to an R-R row, so the table held roughly two complete copies
 * of a night: 2.06x the beats the measured HR curve allows over one 488-min window. That leaves the
 * MEAN correct — resting HR was never wrong — and destroys everything built on successive differences:
 * RMSSD, and a ~200 ms nocturnal SDNN where a healthy adult asleep is 40-100 ms.
 *
 * The fix is deliberately NOT a de-duplication: both rows are real measurements, so the channel is
 * LABELLED at decode, both rows are STORED, and the scoring read takes one. This is the Kotlin half of
 * the parity contract — the Swift twin is `RrSourceChannelTests` in WhoopStoreTests, which also
 * exercises the read end-to-end against a real SQLite. There is no SQLite driver on this unit-test
 * classpath (see [DeepCaptureMigrationTest]), so the read filter is guarded here by auditing the DAO
 * query text, the way [HrFrontierQueryShapeTest] does.
 */
class RrSourceChannelTest {

    // The same golden fixtures the Swift DecoderGoldenTests pin the VALUES of, so the channel is
    // asserted on exactly those bytes. rt = 0x00010002 throughout.
    private val green0x80 = "801202000100698c660e652a6a09670f6d2b693e"   // real capture, 6 good beats
    private val spo20x6E = "6e0a02000100000a141e2832"                    // synthetic, 5 beats
    private val amp0x60 = "601202000100807b77757a78e4ddccd4e8d79d33"     // real capture, 6 beats

    private fun record(hex: String): OuraRecord {
        val rec = OuraFraming.parseRecord(OuraTestHex.bytes(hex))
        assertNotNull("record failed to parse: $hex", rec)
        return rec!!
    }

    // MARK: - The decoders stamp their own channel

    @Test
    fun greenQualityDecoderStampsGreenChannel() {
        val ibis = OuraDecoders.decodeGreenIBIQuality(record(green0x80))
        assertEquals(6, ibis?.size)
        assertEquals(List(6) { OuraIbiChannel.GREEN_QUALITY }, ibis?.map { it.channel })
    }

    @Test
    fun spo2DecoderStampsSpO2Channel() {
        val ibis = OuraDecoders.decodeSpO2IBI(record(spo20x6E))
        assertEquals(5, ibis?.size)
        assertEquals(List(5) { OuraIbiChannel.SPO2_IBI }, ibis?.map { it.channel })
    }

    @Test
    fun ibiAmplitudeDecoderStampsAmplitudeChannel() {
        val ibis = OuraDecoders.decodeIBIAmplitude(record(amp0x60))
        assertEquals(6, ibis?.size)
        assertEquals(List(6) { OuraIbiChannel.IBI_AMPLITUDE }, ibis?.map { it.channel })
    }

    /**
     * 0x44 shares 0x60's layout byte for byte, so it shares the decoder — but it is a DIFFERENT tag, and
     * a stored beat has to be able to name which one produced it. The same bytes routed as each tag must
     * therefore yield the same intervals under different channels: identical values, distinct labels.
     * (Until this split both stamped IBI_AMPLITUDE, so a night in which that channel covered 1.25x its
     * own wall-clock could not say whether one tag repeats beats across records or two tags report the
     * same beats to each other — the question the scoring-channel choice turns on.) Twin of Swift.
     */
    @Test
    fun bare0x44StampsItsOwnChannelWhileDecodingIdenticalValues() {
        val asAmplitude = OuraDecoders.decodeIBIAmplitude(record(amp0x60))
        val asBare = OuraDecoders.decodeIBIAmplitude(record(amp0x60), OuraIbiChannel.IBI_BARE)
        assertEquals(asAmplitude?.map { it.ibiMs }, asBare?.map { it.ibiMs })
        assertEquals(asAmplitude?.map { it.amplitude }, asBare?.map { it.amplitude })
        assertEquals(List(6) { OuraIbiChannel.IBI_BARE }, asBare?.map { it.channel })
    }

    /**
     * And the driver is what routes them: a 0x44 record reaches the app labelled IBI_BARE, a 0x60 record
     * IBI_AMPLITUDE, from the same decoder. Both still emit every beat — a label, not a filter.
     */
    @Test
    fun driverLabels0x44AndLeaves0x60Unchanged() {
        val driver = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        val bare0x44 = "441202000100807b77757a78e4ddccd4e8d79d33"   // 0x60 golden body, 0x44 tag
        fun channels(events: List<OuraEvent>) =
            events.mapNotNull { (it as? OuraEvent.Ibi)?.value?.channel }
        val fromBare = channels(driver.ingest(record(bare0x44)))
        val fromAmp = channels(driver.ingest(record(amp0x60)))
        assertEquals(6, fromBare.size)
        assertEquals(setOf(OuraIbiChannel.IBI_BARE), fromBare.toSet())
        assertEquals(setOf(OuraIbiChannel.IBI_AMPLITUDE), fromAmp.toSet())
    }

    /**
     * The end-to-end shape of the defect: two records covering the same wall-clock moment, one per
     * channel, both reaching the driver as `Ibi`. Before #1071 the resulting events were
     * indistinguishable; now the channel survives dispatch, which is what makes the two streams
     * separable downstream instead of silently summed. Neither is dropped at decode.
     */
    @Test
    fun driverPreservesTheChannelSoTwoTagsAreDistinguishable() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        fun channels(events: List<OuraEvent>) =
            events.filterIsInstance<OuraEvent.Ibi>().map { it.value.channel }

        val green = channels(d.ingest(record(green0x80)))
        val spo2 = channels(d.ingest(record(spo20x6E)))
        assertEquals(setOf(OuraIbiChannel.GREEN_QUALITY), green.toSet())
        assertEquals(setOf(OuraIbiChannel.SPO2_IBI), spo2.toSet())
        assertEquals("both channels still reach the store", 11, green.size + spo2.size)
    }

    // MARK: - The label survives the mapping

    /**
     * A 0x6E record and a 0x80 record covering the same interval must produce rows with DISTINCT
     * `srcChannel` values — the requirement that makes everything downstream possible.
     */
    @Test
    fun twoChannelsOverTheSameIntervalMapToDistinctSrcChannels() {
        val ts = 1_750_000_000
        val s = OuraStreamMapping.streams(
            listOf(
                OuraEvent.Ibi(OuraIBI(100L, 848, channel = OuraIbiChannel.GREEN_QUALITY)),
                OuraEvent.Ibi(OuraIBI(100L, 848, channel = OuraIbiChannel.SPO2_IBI)),
            ),
        ) { ts }
        assertEquals(
            listOf(RrSourceChannel.GREEN_QUALITY, RrSourceChannel.SPO2_IBI),
            s.rr.map { it.srcChannel },
        )
        // Same beat, same second, same value — nothing but the channel tells them apart.
        assertEquals(listOf(848, 848), s.rr.map { it.rrMs })
        assertEquals(listOf(ts, ts), s.rr.map { it.ts })
    }

    /**
     * A channel is never invented. An IBI from a source that does not report one stays null all the way
     * to the row, where it reads as an unlabelled beat rather than a guessed channel.
     */
    @Test
    fun anUnlabelledIbiStaysNullRatherThanBeingGuessed() {
        val s = OuraStreamMapping.streams(listOf(OuraEvent.Ibi(OuraIBI(100L, 820)))) { 1_750_000_000 }
        assertEquals(listOf<RrSourceChannel?>(null), s.rr.map { it.srcChannel })
    }

    /**
     * The two enums are pinned to the same codes on purpose: one durable storage value split across two
     * packages only because the pure ring decoder does not depend on the storage carriers.
     */
    @Test
    fun theTwoChannelEnumsAgreeCaseForCaseAndCodeForCode() {
        assertEquals(OuraIbiChannel.entries.size, RrSourceChannel.entries.size)
        for (c in OuraIbiChannel.entries) {
            assertEquals(
                "$c must map to the SAME durable storage code on both sides",
                c.code,
                OuraStreamMapping.rrChannel(c)?.code,
            )
        }
        assertNull(OuraStreamMapping.rrChannel(null))
    }

    /**
     * The raw codes are a DURABLE storage format (`rrInterval.srcChannel`, and the `.noopbak` that
     * carries it between platforms), so renumbering a case would silently relabel stored history.
     * Pinned here rather than trusted to declaration order. Twin of the Swift assertion.
     */
    @Test
    fun channelCodesAreTheDurableStorageValues() {
        assertEquals(1, RrSourceChannel.GREEN_QUALITY.code)
        assertEquals(2, RrSourceChannel.SPO2_IBI.code)
        assertEquals(3, RrSourceChannel.IBI_AMPLITUDE.code)
        assertEquals(4, RrSourceChannel.IBI_BARE.code)
        assertEquals(1, OuraIbiChannel.GREEN_QUALITY.code)
        assertEquals(2, OuraIbiChannel.SPO2_IBI.code)
        assertEquals(3, OuraIbiChannel.IBI_AMPLITUDE.code)
        assertEquals(4, OuraIbiChannel.IBI_BARE.code)
        assertEquals(RrSourceChannel.SPO2_IBI, RrSourceChannel.fromCode(2))
        assertNull("an unknown code is unknown, not a default", RrSourceChannel.fromCode(99))
        assertNull(RrSourceChannel.fromCode(null))
    }

    // MARK: - The insert path

    @Test
    fun assignRrSeqCarriesTheChannelOntoTheRowWithoutTouchingTheKey() {
        val ts = 1_780_916_150L
        val out = assignRrSeq(
            "ring",
            listOf(
                RrRow(ts, 848, RrSourceChannel.GREEN_QUALITY),
                RrRow(ts, 848, RrSourceChannel.SPO2_IBI),
                RrRow(ts, 856, null),
            ),
        )
        assertEquals(listOf(1, 2, null), out.map { it.srcChannel })
        // seq/ord are unaffected: the two equal beats still get distinct seq (so both are storable),
        // and all three keep their emission order.
        assertEquals(listOf(0, 1, 0), out.map { it.seq })
        assertEquals(listOf(0, 1, 2), out.map { it.ord })
    }

    @Test
    fun entityDefaultsSrcChannelToNull_soWhoopAndLegacyRowsStayHonest() {
        // A WHOOP strap has ONE beat source: there is no channel to name, and NULL says exactly that
        // rather than asserting a channel nobody measured.
        assertNull(RrInterval(deviceId = "d", ts = 1L, rrMs = 800).srcChannel)
        assertNull(RrRow(1L, 800).srcChannel)
    }

    // MARK: - The migration

    @Test
    fun migrationIsAdditiveNullableAndNotAKeyChange() {
        val sql = WhoopDatabase.RR_SRC_CHANNEL_MIGRATION_SQL
        assertEquals(1, sql.size)
        assertEquals("ALTER TABLE `rrInterval` ADD COLUMN `srcChannel` INTEGER", sql[0])
        val upper = sql[0].uppercase()
        assertTrue(upper.startsWith("ALTER TABLE"))
        assertTrue("must be additive", upper.contains("ADD COLUMN"))
        assertFalse("srcChannel must be nullable", upper.contains("NOT NULL"))
        assertFalse("no default — absent means no channel to name", upper.contains("DEFAULT"))
        for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "PRIMARY KEY")) {
            assertFalse("migration must not contain $banned", upper.contains(banned))
        }
        assertEquals(25, WhoopDatabase.MIGRATION_25_26.startVersion)
        assertEquals(26, WhoopDatabase.MIGRATION_25_26.endVersion)
    }

    // MARK: - The read filter

    /**
     * The read is the half that actually fixes the numbers, and it is SQL — so it is audited as source.
     * The behavioural end of it is the Swift twin, which CI runs against a real SQLite.
     */
    @Test
    fun rrIntervalsReadsOneChannelAndKeepsNullRows() {
        val q = rrIntervalsQuery().replace(Regex("\\s+"), " ")

        assertTrue(
            "the scoring read must exclude the SpO2 channel: $q",
            q.contains("srcChannel <> ${RrSourceChannel.SPO2_IBI.code}"),
        )
        // NULL must survive the filter. `srcChannel <> 2` alone is NULL (not true) for a NULL row, so
        // SQLite would drop every WHOOP night and every pre-v26 row — the one way this predicate can
        // quietly delete real data.
        assertTrue(
            "NULL rows (WHOOP, pre-v26) must be kept explicitly: $q",
            q.contains("srcChannel IS NULL OR"),
        )
        // The amplitude channel is deliberately NOT excluded: on a ring where 0x60 is the only beat
        // source, excluding it would leave nothing to score.
        assertFalse(
            "only the demonstrated duplicate is excluded: $q",
            q.contains("srcChannel <> ${RrSourceChannel.IBI_AMPLITUDE.code}"),
        )
        // #823's emission order still leads the sort — the filter must not have displaced it.
        assertTrue("emission order must still lead: $q", q.contains("ORDER BY ts ASC, ord ASC"))
    }

    /** The `@Query` body attached to `rrIntervals`, string fragments joined, comments excluded. */
    private fun rrIntervalsQuery(): String {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val rel = "src/main/java/com/noop/data/WhoopDao.kt"
        val found = listOf(File(userDir, rel), File(userDir, "app/$rel"), File(userDir, "android/app/$rel"))
            .firstOrNull { it.isFile }
        assertNotNull(
            "WhoopDao.kt not found from user.dir=$userDir — this guard cannot run, and a skip here " +
                "reads as a pass. Add this host's working dir to the list rather than letting it slide.",
            found,
        )
        val src = found!!.readText()
        val decl = src.indexOf("suspend fun rrIntervals(")
        assertTrue("rrIntervals not found — was it renamed?", decl > 0)
        val annotationStart = src.lastIndexOf("@Query(", decl)
        assertTrue("no @Query above rrIntervals", annotationStart > 0)
        val block = src.substring(annotationStart, decl)
        return Regex("\"([^\"]*)\"").findAll(block).joinToString("") { it.groupValues[1] }
    }
}
