package com.noop.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2847: the flash-banked MG ECG record decodes AND has somewhere to be stored.
 *
 * `Whoop5EcgR16Test` pins the decoder; this file pins the route from an offloaded frame to a row, which is
 * the part that was missing. Layout version 16 is now in [MAPPED_WHOOP5_HISTORICAL_VERSIONS], and that
 * move is only safe because [extractHistoricalStreams] banks the record first: mapping a version takes its
 * frames off [rejectedHistoricalRecords]' unconditional-archive branch, and the strap frees them on the
 * trim ack either way, so the order of the two halves is the whole argument.
 *
 * Fixtures are SYNTHETIC, built from the documented layout exactly as the R16 suite's are. Nothing here
 * establishes volts per count, a sample rate, or anything clinical. Swift twin:
 * `Whoop5EcgHistoricalStorageTests`.
 */
class Whoop5EcgHistoricalStorageTest {

    /**
     * A complete, CRC-valid R16 frame with a full waveform.
     *
     * [strapSeconds] defaults above `MIN_PLAUSIBLE_UNIX`: the R16 suite's own 0x65430001 is 1,698,889,729,
     * which is BELOW the #547 floor, so a fixture built on it would exercise the dropped-record path
     * rather than the storage path.
     */
    private fun r16Frame(
        strapSeconds: Int = 1_760_000_000,
        sequence: Int = 0x0001_2345,
        declaredCount: Int = Whoop5Ecg.R16_MAX_SAMPLES,
        revision: Int = Whoop5Ecg.R16_REVISION,
        innerLength: Int = Whoop5Ecg.R16_INNER_LENGTH,
    ): ByteArray {
        val inner = IntArray(innerLength)
        inner[0] = Whoop5Ecg.STORED_RECORD_TYPE
        inner[1] = revision
        inner[2] = 0x5a
        put32(inner, 3, sequence)
        put32(inner, 7, strapSeconds)
        put16(inner, 11, 16_384)
        inner[13] = 3                                    // quality
        inner[14] = 0x08                                 // flags: presence
        inner[17] = 100                                  // progress: terminal
        inner[19] = 64                                   // averageHR
        put16(inner, 24, declaredCount)
        // A ramp rather than zeros, so a route that silently substituted an empty payload is visible.
        for (i in 0 until declaredCount) {
            val o = Whoop5Ecg.R16_SAMPLE_START + i * Whoop5Ecg.R16_SAMPLE_SLOT_BYTES
            if (o + 2 >= inner.size) break
            inner[o] = 0x80 or (i and 3)
            inner[o + 1] = (i shr 1) and 0xff
            inner[o + 2] = i and 0xff
        }
        if (innerLength == Whoop5Ecg.R16_INNER_LENGTH) {
            inner[Whoop5Ecg.R16_LEADS_OFF_COUNT_OFFSET] = 11
            for (i in 0 until Whoop5Ecg.R16_LEADS_OFF_SLOTS) {
                put16(inner, Whoop5Ecg.R16_LEADS_OFF_I_START + i * 2, 0x0100 + i)
                put16(inner, Whoop5Ecg.R16_LEADS_OFF_Q_START + i * 2, 0x0200 + i)
            }
        }
        return Framing.puffinCommandFrame(
            cmd = inner[2],
            seq = inner[1],
            payload = ByteArray(inner.size - 3) { inner[it + 3].toByte() },
            type = inner[0],
        )
    }

    private fun put16(b: IntArray, i: Int, v: Int) {
        b[i] = v and 0xff; b[i + 1] = (v shr 8) and 0xff
    }

    private fun put32(b: IntArray, i: Int, v: Int) {
        for (k in 0 until 4) b[i + k] = (v shr (8 * k)) and 0xff
    }

    /** Identity clock refs, the archive-replay seam, so the fixture's own strapSeconds is the ts. */
    private fun streams(frames: List<ByteArray>) =
        extractHistoricalStreams(frames, deviceClockRef = 0, wallClockRef = 0, family = DeviceFamily.WHOOP5)

    // the row

    @Test
    fun anOffloadedEcgRecordBanksExactlyOneRow() {
        val s = streams(listOf(r16Frame()))
        assertEquals(1, s.ecgWaveform.size)
        assertEquals(1_760_000_000L, s.ecgWaveform[0].ts)
        assertEquals(0x0001_2345L, s.ecgWaveform[0].sequence)
        assertEquals(Whoop5Ecg.R16_INNER_LENGTH, s.ecgWaveform[0].record.size)
    }

    /**
     * The stored bytes are the WIRE bytes. This is the claim the whole storage shape rests on, so it is
     * asserted against the frame rather than against a re-encode of the decode: a codec that packed decoded
     * samples back into slots could be byte-identical for every sample it decoded and still differ in the
     * padding past `sampleCount`, which no decode reads and no re-encode can invent.
     */
    @Test
    fun theStoredBytesAreTheRecordsOwnBytes() {
        val frame = r16Frame()
        val inner = Whoop5Ecg.innerPayload(frame, Whoop5Ecg.RAW_TYPE_OFFSET)
        assertNotNull(inner)
        val expected = ByteArray(inner!!.size) { inner[it].toByte() }
        assertArrayEquals(expected, streams(listOf(frame)).ecgWaveform[0].record)
    }

    /** And the row is READABLE by the decoder that is already pinned, rather than by a reader of its own. */
    @Test
    fun theStoredRowDecodesBackThroughParseR16() {
        val frame = r16Frame()
        val row = streams(listOf(frame)).ecgWaveform[0]
        val fromRow = Whoop5Ecg.parseR16(row.record.map { it.toInt() and 0xff })
        val fromFrame = Whoop5Ecg.r16FromFrame(frame)
        assertNotNull(fromRow)
        assertEquals(fromFrame, fromRow)
        assertEquals(Whoop5Ecg.R16_MAX_SAMPLES, fromRow!!.samples.size)
        assertEquals(Whoop5Ecg.R16_LEADS_OFF_SLOTS, fromRow.leadsOffIRaw.size)
    }

    /** A reading is many records, and each is its own row keyed on its own second. */
    @Test
    fun eachRecordOfAReadingIsItsOwnRow() {
        val frames = (0 until 5).map { r16Frame(strapSeconds = 1_760_000_000 + it, sequence = 100 + it) }
        val s = streams(frames)
        assertEquals((0 until 5).map { 1_760_000_000L + it }, s.ecgWaveform.map { it.ts })
        assertEquals((0 until 5).map { 100L + it }, s.ecgWaveform.map { it.sequence })
    }

    /**
     * An ECG record is not a scoreable record, and the funnel must not pretend otherwise. `averageHR` is
     * the strap's own average over a reading, so routing it into `hr` would feed a recovery input from a
     * quantity nobody has validated for it (#752 bounds what may be read off this signal at all).
     */
    @Test
    fun anEcgRecordContributesToNoScoredStream() {
        val s = streams(listOf(r16Frame()))
        assertTrue(s.hr.isEmpty())
        assertTrue(s.rr.isEmpty())
        assertTrue(s.gravity.isEmpty())
        assertTrue(s.ppgHr.isEmpty())
        assertTrue(s.ppgWaveform.isEmpty())
        assertTrue(s.spo2.isEmpty())
    }

    /**
     * A batch of nothing but ECG records has NOT lost its data, so the emptiness verdict that gates the
     * insert (and drives the Backfiller's silent-data-loss line) must read non-empty.
     */
    @Test
    fun aBatchOfOnlyEcgRecordsIsNotEmpty() {
        assertTrue(!streams(listOf(r16Frame())).isEmpty)
    }

    // the archive hand-off

    /**
     * Mapped and stored, so NOT also archived: the raw archive is a 5 MiB ring whose per-version floor
     * protects 64 lines, and a reading at one 1.5 KB record per second would both evict other evidence and
     * be evicted itself (@DX23876 measured that within a couple of hours of ordinary MG traffic).
     */
    @Test
    fun anIntactEcgRecordIsNotArchivedBecauseItIsStored() {
        assertTrue(rejectedHistoricalRecords(listOf(r16Frame()), DeviceFamily.WHOOP5).isEmpty())
    }

    /**
     * The skip is bound to the INTEGRITY VERDICT, not to the version byte. A broken record banks no row, so
     * its bytes are the only copy that can exist and the archive must keep them.
     */
    @Test
    fun aCorruptEcgRecordIsStillArchived() {
        val frame = r16Frame()
        frame[frame.size - 1] = (frame[frame.size - 1].toInt() xor 0xff).toByte()
        assertEquals(1, rejectedHistoricalRecords(listOf(frame), DeviceFamily.WHOOP5).size)
        assertTrue("a broken record must bank no row", streams(listOf(frame)).ecgWaveform.isEmpty())
    }

    /**
     * THE HOLE v26 ALREADY HAS, pinned rather than left to be discovered: an INTACT record whose own @15
     * fails the #547 plausibility gate banks no row (the extraction drops it) and is not archived either
     * (the skip only asks whether the frame is intact), so it is stored nowhere.
     *
     * Pinned as the current behaviour because it is shared with v26's far larger population and closing it
     * needs [rejectedHistoricalRecords] to know a wall clock it has no parameter for. If someone closes
     * it, this test is what tells them v16 was covered by the same change.
     */
    @Test
    fun anIntactButImplausiblyDatedRecordIsStoredNowhereForNowLikeV26() {
        val frame = r16Frame(strapSeconds = 1_000)      // below MIN_PLAUSIBLE_UNIX
        assertTrue(streams(listOf(frame)).ecgWaveform.isEmpty())
        assertTrue(rejectedHistoricalRecords(listOf(frame), DeviceFamily.WHOOP5).isEmpty())
    }

    /**
     * A v16 frame whose record is NOT R16_INNER_LENGTH long stays ARCHIVED, however intact it is.
     *
     * Found by re-reading this change: [Whoop5Ecg.parseR16] accepts exactly one length, so such a frame
     * banks no row whatever its state, while the archive skip was asking only whether the frame was
     * intact. A 1,484-byte record with both CRCs valid was skipped here AND dropped by the extraction,
     * which is the one outcome this filter exists to prevent. Before v16 was mapped the same frame was
     * archived by the unmapped-layout rule, so the hole arrived with the mapping.
     */
    @Test
    fun anIntactVersionSixteenFrameOfTheWrongLengthIsStillArchived() {
        val frame = r16Frame(declaredCount = 10, innerLength = Whoop5Ecg.R16_INNER_LENGTH - 100)
        assertTrue("the fixture must be INTACT", Framing.parseFrame(frame, DeviceFamily.WHOOP5).ok)
        assertNull("and undecodable, which is the point", Whoop5Ecg.r16FromFrame(frame))
        assertTrue(streams(listOf(frame)).ecgWaveform.isEmpty())
        assertEquals(
            "a record nothing can store must keep its bytes in the archive",
            1,
            rejectedHistoricalRecords(listOf(frame), DeviceFamily.WHOOP5).size,
        )
    }

    /**
     * A record declaring ZERO samples is still banked, and that is a decision rather than an accident.
     * The opening records of a real run declare 0 and then 245 before the first full 500, so a count-0
     * record marks where a reading began, and the row here is the RECORD rather than a waveform-only row.
     */
    @Test
    fun aRecordDeclaringNoSamplesIsStillBanked() {
        val row = streams(listOf(r16Frame(declaredCount = 0))).ecgWaveform.single()
        assertEquals(Whoop5Ecg.R16_INNER_LENGTH, row.record.size)
        val decoded = Whoop5Ecg.parseR16(row.record.map { it.toInt() and 0xff })
        assertNotNull(decoded)
        assertEquals(0, decoded!!.sampleCount)
        assertTrue(decoded.samples.isEmpty())
    }

    /**
     * Two records stamped in ONE strap-second both reach the store as separate rows. The store's key is
     * what keeps them apart, and `EcgWaveformMigrationTest` pins that key; this end pins that the
     * extraction does not merge or drop one first.
     */
    @Test
    fun twoRecordsStampedInOneSecondBothReachTheStore() {
        val frames = listOf(
            r16Frame(sequence = 10, declaredCount = 0),
            r16Frame(sequence = 11, declaredCount = 245),
        )
        val rows = streams(frames).ecgWaveform
        assertEquals(2, rows.size)
        assertEquals(listOf(1_760_000_000L, 1_760_000_000L), rows.map { it.ts })
        assertEquals(listOf(10L, 11L), rows.map { it.sequence })
    }

    // the layout claim is exactly one version wide

    @Test
    fun onlyRevisionSixteenTakesTheEcgRoute() {
        // Revision 17 is the LIVE record (type 43), and a type-47 frame carrying 17 is not a layout NOOP
        // maps: it must stay unmapped, and therefore archived, rather than fall into the ECG route.
        val wrongRevision = r16Frame(revision = 17)
        assertTrue(streams(listOf(wrongRevision)).ecgWaveform.isEmpty())
        assertEquals(1, rejectedHistoricalRecords(listOf(wrongRevision), DeviceFamily.WHOOP5).size)
    }

    /**
     * Mapping v16 changes the strap-log line for these records, and the new one must not ask the user to
     * report working software. Pinned here as well as in `HistoricalLayoutSupportTest` because the mapped
     * set is what moved, and this file is where that move is covered.
     */
    @Test
    fun theEcgLayoutReportsAsDecodingIntoItsOwnStream() {
        assertEquals(
            HistoricalLayoutSupport.DECODES_INTO_ITS_OWN_STREAM,
            historicalLayoutSupport(
                version = 16, family = DeviceFamily.WHOOP5,
                hasHeartRate = false, hasGravity = false, hasPpgWaveform = false,
            ),
        )
    }
}
