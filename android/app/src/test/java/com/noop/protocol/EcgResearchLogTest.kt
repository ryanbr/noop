package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EcgResearchLogTest {

    private fun newLog(maxRx: Int = EcgResearchLog.DEFAULT_MAX_RX_ROWS) =
        EcgResearchLog("mg-ecg-20260819-101112", startWallMs = 0L, startMonotonicMs = 0L, maxRxRows = maxRx)

    private fun tx(op: Int, mono: Long) = EcgResearchLog.TxRow(
        monotonicMs = mono, wallMs = mono, opcode = op,
        payload = byteArrayOf(0x01, 0x01), frame = byteArrayOf(0xAA.toByte(), 0x01),
        serviceUuid = "fd4b0001", characteristicUuid = "fd4b0002", writeType = "NO_RESPONSE",
    )

    private fun rx(mono: Long, size: Int, type: Int?, recognized: Boolean) = EcgResearchLog.RxRow(
        monotonicMs = mono, wallMs = mono, serviceUuid = "fd4b0001", characteristicUuid = "fd4b0003",
        payload = ByteArray(size), packetType = type, sequence = null, recognized = recognized,
        rejected = !recognized,
    )

    @Test
    fun recordsCountAcrossAllStreams() {
        val log = newLog()
        log.recordTx(tx(139, 10))
        log.recordRx(rx(20, 1584, 0x28, false))
        log.recordCommand(
            EcgResearchLog.CommandRow(30, 30, 139, "01", "Observed", "session", "SUCCESS(1)", "aabb", 42),
        )
        log.recordEvent(EcgResearchLog.EventRow(5, 5, "electrode_contact_started", ""))
        assertEquals(1, log.txCount)
        assertEquals(1, log.rxCount)
        assertEquals(1, log.commandCount)
        assertEquals(1, log.eventCount)
    }

    @Test
    fun eventCsvCarriesTimestampsAndMarkers() {
        val log = newLog()
        log.recordEvent(EcgResearchLog.EventRow(1234, 0L, "electrode_contact_started", "left index"))
        val csv = log.eventsCsv()
        assertTrue(csv.startsWith("monotonic_ms,wall_iso,kind,detail\n"))
        assertTrue(csv.contains("1234,1970-01-01T00:00:00Z,electrode_contact_started,left index"))
    }

    @Test
    fun txCsvCarriesDecimalAndHexOpcodeAndFrame() {
        val log = newLog()
        log.recordTx(tx(139, 10))
        val csv = log.bleTxCsv()
        assertTrue(csv.contains("opcode_dec,opcode_hex"))
        assertTrue(csv.contains("10,1970-01-01T00:00:00Z,139,0x8B,0101,aa01,fd4b0001,fd4b0002,NO_RESPONSE"))
    }

    @Test
    fun unknownPacketsCsvContainsOnlyUnrecognisedRows() {
        val log = newLog()
        log.recordRx(rx(1, 20, 40, recognized = true))     // recognised — excluded
        log.recordRx(rx(2, 1584, null, recognized = false)) // unknown — included
        val csv = log.unknownPacketsCsv()
        val lines = csv.trim().split("\n")
        assertEquals(2, lines.size)  // header + one unknown row
        assertTrue(lines[1].contains(",1584,"))
    }

    @Test
    fun rxCapCountsOverflowInsteadOfDroppingSilently() {
        val log = newLog(maxRx = 2)
        log.recordRx(rx(1, 10, 40, true))
        log.recordRx(rx(2, 10, 40, true))
        log.recordRx(rx(3, 10, 40, true)) // over the cap
        assertEquals(2, log.rxCount)
        assertEquals(1L, log.rxOverflow)
        assertTrue(log.statsJson().contains("\"rxOverflowDropped\": 1"))
    }

    @Test
    fun statsJsonReportsCandidateRawRecordsAndZeroFill() {
        val log = newLog()
        repeat(3) { log.recordRx(rx(it.toLong(), 1584, 0x28, recognized = false)) }
        val json = log.statsJson()
        assertTrue(json.contains("\"sessionId\": \"mg-ecg-20260819-101112\""))
        assertTrue(json.contains("\"candidateRawRecordSize\": 1584"))
        assertTrue(json.contains("\"candidateRawRecordCount\": 3"))
        // three all-zero 1584-byte records -> max zero fraction 1.0
        assertTrue(json.contains("\"maxZeroFractionOfLargeRecords\": 1.0"))
        assertTrue(json.contains("\"unknownRx\": 3"))
    }

    @Test
    fun statsJsonSurfacesTypesAppearingAfterAStartMarker() {
        val log = newLog()
        log.recordRx(rx(0, 4, 40, true))                    // type 40 present only BEFORE the marker
        log.recordEvent(EcgResearchLog.EventRow(100, 100, "command_sequence_started", ""))
        log.recordRx(rx(200, 1584, 99, false))              // type 99 present only AFTER the marker
        val json = log.statsJson()
        assertTrue(json.contains("\"packetTypesAppearedAfterStart\": [99]"))
        assertTrue(json.contains("\"packetTypesDisappearedAfterStop\": [40]"))
    }

    // ---- CRC verdict + volume bounds (added with the CRC-gating of the decode path) ----------------

    /** A 240-byte type-43 record whose waveform region carries [value] in every sample. */
    private fun rawRecordRow(monotonicMs: Long, value: Int, crcOk: Boolean?): EcgResearchLog.RxRow {
        val f = ByteArray(Whoop5Ecg.RAW_RECORD_LENGTH)
        f[Whoop5Ecg.RAW_TYPE_OFFSET] = PacketType.REALTIME_RAW_DATA.rawValue.toByte()
        var i = Whoop5Ecg.RAW_WAVEFORM_START
        while (i + 1 < Whoop5Ecg.RAW_BODY_END) {
            f[i] = (value and 0xFF).toByte()
            f[i + 1] = ((value shr 8) and 0xFF).toByte()
            i += 2
        }
        return EcgResearchLog.RxRow(
            monotonicMs = monotonicMs, wallMs = 1_700_000_000_000L, serviceUuid = "fd4b",
            characteristicUuid = "fd4b0003", payload = f,
            packetType = PacketType.REALTIME_RAW_DATA.rawValue, sequence = null,
            recognized = crcOk != false, rejected = crcOk == false, crcOk = crcOk,
        )
    }

    @Test
    fun aCrcFailureIsRecordedAndFlaggedRatherThanDropped() {
        val log = EcgResearchLog("s", 1_700_000_000_000L, 0L)
        log.recordRx(rawRecordRow(10, 100, crcOk = true))
        log.recordRx(rawRecordRow(20, 200, crcOk = false))
        log.recordRx(rawRecordRow(30, 300, crcOk = null))

        // Dropping a corrupt frame would make "the strap sent nothing" and "we threw it away" identical.
        assertEquals(3, log.rxCount)
        val csv = log.bleRxCsv()
        val header = csv.lineSequence().first().split(",")
        val crcCol = header.indexOf("crc_ok")
        assertTrue("the rx CSV must carry the verdict", crcCol >= 0)
        val rows = csv.trim().lines().drop(1).map { it.split(",") }
        assertEquals("true", rows[0][crcCol])
        assertEquals("false", rows[1][crcCol])
        // "nothing to check" must be distinguishable from "failed": an empty field, not the word false.
        assertEquals("", rows[2][crcCol])
    }

    @Test
    fun theWaveformExportNeverPlotsBytesThatFailedCrc() {
        val log = EcgResearchLog("s", 1_700_000_000_000L, 0L)
        log.recordRx(rawRecordRow(10, 111, crcOk = true))
        log.recordRx(rawRecordRow(20, 222, crcOk = false))   // corruption would render as a spike
        val csv = log.waveformCsv()
        assertTrue("the CRC-good record should be plotted", csv.contains(",111"))
        assertFalse("a CRC-failed record must never reach the waveform", csv.contains(",222"))
    }

    @Test
    fun anAllZeroRecordIsBaselineAndSkippedButRealZerosAreKept() {
        val log = EcgResearchLog("s", 1_700_000_000_000L, 0L)
        log.recordRx(rawRecordRow(10, 0, crcOk = true))       // pure baseline: skipped entirely
        assertEquals("record,monotonic_ms,sample_index,value\n", log.waveformCsv())

        // A record with content keeps its full 101 samples — no trailing-zero trimming, which would edit
        // the evidence. Build one with a single non-zero lead sample.
        val f = ByteArray(Whoop5Ecg.RAW_RECORD_LENGTH)
        f[Whoop5Ecg.RAW_TYPE_OFFSET] = PacketType.REALTIME_RAW_DATA.rawValue.toByte()
        f[Whoop5Ecg.RAW_WAVEFORM_START] = 9
        val log2 = EcgResearchLog("s", 1_700_000_000_000L, 0L)
        log2.recordRx(
            EcgResearchLog.RxRow(
                1, 1_700_000_000_000L, "fd4b", "fd4b0003", f,
                PacketType.REALTIME_RAW_DATA.rawValue, null, true, false, true,
            ),
        )
        assertEquals(
            "every sample of a non-empty record is written",
            Whoop5Ecg.SAMPLES_PER_RAW_RECORD,
            log2.waveformCsv().trim().lines().size - 1,
        )
    }

    @Test
    fun theCaptureIsBoundedByBytesNotJustRows() {
        // A row cap alone does not bound memory: 200k x 240 B is ~48 MB before object overhead, and an
        // offload can fill that faster than a UI notices. Whichever cap is hit first stops storage, and the
        // drops are counted either way.
        val log = EcgResearchLog("s", 1_700_000_000_000L, 0L, maxRxRows = 1_000, maxRxBytes = 1_000L)
        repeat(20) { log.recordRx(rawRecordRow(it.toLong(), 5, crcOk = true)) }
        assertTrue("the byte cap should bite well before the row cap", log.rxCount in 1..4)
        assertTrue("bytes stored must stay inside the cap", log.rxBytes <= 1_000L)
        assertEquals("every dropped frame is counted", (20 - log.rxCount).toLong(), log.rxOverflow)
        assertTrue("the bundle must report the drops", log.statsJson().contains("\"rxOverflowDropped\": ${log.rxOverflow}"))
    }
}
