package com.noop.protocol

/**
 * #891 / #1100: the PURE in-memory record of one MG ECG research capture — every TX/RX/command/marker row,
 * plus the serializers that turn them into the export bundle's CSV/JSON/README files.
 *
 * No Android, no I/O, no clock of its own: the caller ([com.noop.ble.EcgResearchSession]) supplies both a
 * monotonic and a wall-clock timestamp for every row, so the whole model is deterministic and unit-tested
 * without a strap or a device. The Android wrapper owns the file writing and the clocks; this owns the
 * shape of the evidence.
 *
 * Volume: an ECG capture must NOT sample away high-rate packets (#891), so every inbound frame is kept.
 * Appends are O(1) (a row holds raw bytes, hex-encoded only at serialize time) so they never block the BLE
 * callback thread. A safety cap ([maxRxRows]) bounds worst-case memory; frames past it are COUNTED
 * ([rxOverflow]) and reported in `stats.json`, never silently dropped.
 *
 * Not medical: this records protocol bytes and user-set physical markers. It never records or derives a
 * clinical interpretation — the on-strap rhythm classifier byte is decoded elsewhere and never surfaced as
 * a finding.
 */
class EcgResearchLog(
    val sessionId: String,
    val startWallMs: Long,
    val startMonotonicMs: Long,
    private val maxRxRows: Int = DEFAULT_MAX_RX_ROWS,
    private val maxRxBytes: Long = DEFAULT_MAX_RX_BYTES,
) {
    companion object {
        /** ~ enough for many minutes of a high-rate stream; past this, frames are counted not stored. */
        const val DEFAULT_MAX_RX_ROWS = 200_000

        /**
         * Bytes of inbound payload a capture will hold. A row cap alone does not bound memory: 200,000 rows
         * of 240-byte records is ~48 MB of payload before object overhead, and an offload can deliver frames
         * far faster than a UI can notice, so a capture left running through a long sync could push the app
         * to an OOM. Whichever cap is reached first stops storage; the drops are counted either way.
         */
        const val DEFAULT_MAX_RX_BYTES = 24L * 1024 * 1024

        /** #891 flagged a repeated 1,584-byte record as a candidate raw ECG block. */
        const val CANDIDATE_RAW_RECORD_SIZE = 1584

        /** Samples `waveform.csv` will emit before truncating — and it SAYS it truncated, in the file. */
        const val WAVEFORM_CSV_SAMPLE_CAP = 60_000
    }

    // ---- Row types ---------------------------------------------------------------------------------

    /** An experimental command written to the strap (Phase 4 TX fields). */
    data class TxRow(
        val monotonicMs: Long,
        val wallMs: Long,
        val opcode: Int,
        val payload: ByteArray,
        val frame: ByteArray,
        val serviceUuid: String,
        val characteristicUuid: String,
        val writeType: String,
    )

    /** An inbound BLE notification/read during the capture (Phase 4 RX fields). */
    data class RxRow(
        val monotonicMs: Long,
        val wallMs: Long,
        val serviceUuid: String,
        val characteristicUuid: String,
        val payload: ByteArray,
        val packetType: Int?,
        val sequence: Int?,
        val recognized: Boolean,
        val rejected: Boolean,
        /** The frame's CRC verdict, or null when there was nothing to check (the house `crcOk != false`
         *  idiom). A CRC FAILURE is recorded, not dropped: for a research capture a corrupt frame is
         *  evidence, and dropping it would make "the strap sent nothing" indistinguishable from "we threw it
         *  away". No decoder reads a row whose verdict is false. */
        val crcOk: Boolean? = null,
    )

    /** The result of one allow-listed experimental command: outcome + timing + raw ack. */
    data class CommandRow(
        val monotonicMs: Long,
        val wallMs: Long,
        val opcode: Int,
        val argHex: String,
        val statusLevel: String,       // Confirmed / Observed / Hypothesized
        val persistence: String,       // persistent / session
        val ackResult: String?,        // SUCCESS(1) etc.
        val ackRawHex: String?,
        val elapsedToAckMs: Long?,
    )

    /** A user marker or connection event (Phase 5). */
    data class EventRow(
        val monotonicMs: Long,
        val wallMs: Long,
        val kind: String,
        val detail: String,
    )

    /** A raw write-callback status (Phase 4 write callback status). */
    data class WriteStatusRow(val monotonicMs: Long, val wallMs: Long, val characteristicUuid: String, val status: Int)

    // ---- Storage -----------------------------------------------------------------------------------

    private val lock = Any()
    private val _tx = ArrayList<TxRow>()
    private val _rx = ArrayList<RxRow>()
    private val _commands = ArrayList<CommandRow>()
    private val _events = ArrayList<EventRow>()
    private val _writeStatus = ArrayList<WriteStatusRow>()

    /** Inbound frames dropped by the [maxRxRows]/[maxRxBytes] safety caps (reported, never silent). */
    var rxOverflow: Long = 0L
        private set

    /** Stored inbound payload bytes, against [maxRxBytes]. */
    var rxBytes: Long = 0L
        private set

    val txRows: List<TxRow> get() = synchronized(lock) { _tx.toList() }
    val rxRows: List<RxRow> get() = synchronized(lock) { _rx.toList() }
    val commandRows: List<CommandRow> get() = synchronized(lock) { _commands.toList() }
    val eventRows: List<EventRow> get() = synchronized(lock) { _events.toList() }

    val txCount: Int get() = synchronized(lock) { _tx.size }
    val rxCount: Int get() = synchronized(lock) { _rx.size }
    val commandCount: Int get() = synchronized(lock) { _commands.size }
    val eventCount: Int get() = synchronized(lock) { _events.size }

    // ---- Recording ---------------------------------------------------------------------------------

    fun recordTx(row: TxRow) = synchronized(lock) { _tx.add(row) }

    fun recordRx(row: RxRow) = synchronized(lock) {
        if (_rx.size >= maxRxRows || rxBytes + row.payload.size > maxRxBytes) { rxOverflow++; return@synchronized }
        _rx.add(row)
        rxBytes += row.payload.size
    }

    fun recordCommand(row: CommandRow) = synchronized(lock) { _commands.add(row) }

    fun recordEvent(row: EventRow) = synchronized(lock) { _events.add(row) }

    fun recordWriteStatus(row: WriteStatusRow) = synchronized(lock) { _writeStatus.add(row) }

    // ---- Derived stats input -----------------------------------------------------------------------

    private fun rxRecords(): List<EcgResearchStats.RxRecord> = synchronized(lock) {
        _rx.map {
            EcgResearchStats.RxRecord(
                monotonicMs = it.monotonicMs,
                characteristic = shortUuid(it.characteristicUuid),
                payload = it.payload,
                packetType = it.packetType,
                recognized = it.recognized,
            )
        }
    }

    // ---- Serializers -------------------------------------------------------------------------------

    fun eventsCsv(): String {
        val sb = StringBuilder("monotonic_ms,wall_iso,kind,detail\n")
        for (e in eventRows) {
            sb.append(e.monotonicMs).append(',').append(iso(e.wallMs)).append(',')
                .append(csv(e.kind)).append(',').append(csv(e.detail)).append('\n')
        }
        return sb.toString()
    }

    fun bleTxCsv(): String {
        val sb = StringBuilder(
            "monotonic_ms,wall_iso,opcode_dec,opcode_hex,payload_hex,frame_hex,service_uuid,char_uuid,write_type\n",
        )
        for (t in txRows) {
            sb.append(t.monotonicMs).append(',').append(iso(t.wallMs)).append(',')
                .append(t.opcode).append(',').append(hex2(t.opcode)).append(',')
                .append(hex(t.payload)).append(',').append(hex(t.frame)).append(',')
                .append(csv(t.serviceUuid)).append(',').append(csv(t.characteristicUuid)).append(',')
                .append(csv(t.writeType)).append('\n')
        }
        return sb.toString()
    }

    fun bleRxCsv(): String {
        val sb = StringBuilder(
            "monotonic_ms,wall_iso,service_uuid,char_uuid,len,packet_type,sequence,crc_ok,recognized,rejected,payload_hex\n",
        )
        for (r in rxRows) {
            sb.append(r.monotonicMs).append(',').append(iso(r.wallMs)).append(',')
                .append(csv(r.serviceUuid)).append(',').append(csv(r.characteristicUuid)).append(',')
                .append(r.payload.size).append(',')
                .append(r.packetType?.toString() ?: "").append(',')
                .append(r.sequence?.toString() ?: "").append(',')
                .append(r.crcOk?.toString() ?: "").append(',')
                .append(r.recognized).append(',').append(r.rejected).append(',')
                .append(hex(r.payload)).append('\n')
        }
        return sb.toString()
    }

    fun commandsCsv(): String {
        val sb = StringBuilder(
            "monotonic_ms,wall_iso,opcode_dec,opcode_hex,command,arg_hex,status_level,persistence,ack_result,elapsed_ms,ack_raw_hex\n",
        )
        for (c in commandRows) {
            sb.append(c.monotonicMs).append(',').append(iso(c.wallMs)).append(',')
                .append(c.opcode).append(',').append(hex2(c.opcode)).append(',')
                .append(csv(CommandNames.label(c.opcode))).append(',').append(csv(c.argHex)).append(',')
                .append(csv(c.statusLevel)).append(',').append(csv(c.persistence)).append(',')
                .append(csv(c.ackResult ?: "")).append(',')
                .append(c.elapsedToAckMs?.toString() ?: "").append(',')
                .append(csv(c.ackRawHex ?: "")).append('\n')
        }
        return sb.toString()
    }

    /** Only the RX rows the framing parser did NOT recognise — the unknown-packet corpus (Phase 6/7). */
    fun unknownPacketsCsv(): String {
        val sb = StringBuilder("monotonic_ms,wall_iso,char_uuid,len,packet_type,crc_ok,payload_hex\n")
        for (r in rxRows) {
            if (r.recognized) continue
            sb.append(r.monotonicMs).append(',').append(iso(r.wallMs)).append(',')
                .append(csv(r.characteristicUuid)).append(',').append(r.payload.size).append(',')
                .append(r.packetType?.toString() ?: "").append(',')
                .append(r.crcOk?.toString() ?: "").append(',').append(hex(r.payload)).append('\n')
        }
        return sb.toString()
    }

    /**
     * `waveform.csv` — the i16 samples carried by each filled type-43 record, long format
     * (record, monotonic_ms, sample_index, value). Non-diagnostic raw samples for plotting/analysis.
     *
     * The type-43 body opens with a constant 5×i16 sub-header at byte offsets 24..33; the waveform is the
     * i16 LE series from offset 34 to 236. Empty (baseline) records are skipped. Capped so one long capture
     * can't produce an unbounded file.
     */
    fun waveformCsv(): String {
        val sb = StringBuilder("record,monotonic_ms,sample_index,value\n")
        var rec = 0
        var total = 0
        val cap = WAVEFORM_CSV_SAMPLE_CAP
        for (r in rxRows) {
            if (r.crcOk == false) continue                          // never plot bytes that failed CRC
            val vals = Whoop5Ecg.realtimeRawSamples(r.payload) ?: continue
            // A record of all zeros is baseline, not waveform, and would swamp the file. A record that has
            // ANY content is written in full, zeros included: trimming a trailing zero run (as this once did)
            // silently edits the evidence, and a run of zeros at the end of a real record is itself a fact.
            if (vals.all { it == 0 }) continue
            for ((idx, v) in vals.withIndex()) {
                sb.append(rec).append(',').append(r.monotonicMs).append(',').append(idx).append(',').append(v).append('\n')
                if (++total >= cap) {
                    sb.append("# truncated at ").append(cap).append(" samples\n")
                    return sb.toString()
                }
            }
            rec++
        }
        return sb.toString()
    }

    /** `stats.json` — non-diagnostic protocol statistics for a maintainer. */
    fun statsJson(): String {
        val records = rxRecords()
        val pps = EcgResearchStats.packetsPerSecondByCharacteristic(records)
        val hist = EcgResearchStats.payloadSizeHistogram(records)
        val largest = EcgResearchStats.largestPayloadSizes(records, 8)
        val typeCounts = EcgResearchStats.packetTypeCounts(records)
        val repeatedSizes = hist.filterValues { it >= 3 }
        val candidateRawCount = EcgResearchStats.countOfSize(records, CANDIDATE_RAW_RECORD_SIZE)
        val maxZero = EcgResearchStats.maxZeroFractionOfLargeRecords(records, 64)
        // "appeared after Start" — measured around the first command-sequence marker if the run set one.
        val startMarker = eventRows.firstOrNull { it.kind == "command_sequence_started" }?.monotonicMs
        val delta = startMarker?.let { EcgResearchStats.typeDeltaAround(records, it) }
        // A changing-position map for the most common large record size (candidate counter/timestamp fields).
        val dominantLarge = hist.entries.filter { it.key >= 64 }.maxByOrNull { it.value }?.key
        val changing = dominantLarge?.let { size ->
            EcgResearchStats.changingPositionsAcross(
                synchronized(lock) { _rx.filter { it.payload.size == size }.map { it.payload } },
            )
        }

        val sb = StringBuilder()
        sb.append("{\n")
        sb.append("  \"sessionId\": ").append(jstr(sessionId)).append(",\n")
        sb.append("  \"startWallIso\": ").append(jstr(iso(startWallMs))).append(",\n")
        sb.append("  \"counts\": {")
        sb.append("\"tx\": ").append(txCount).append(", \"rx\": ").append(rxCount)
        sb.append(", \"commands\": ").append(commandCount).append(", \"events\": ").append(eventCount)
        sb.append(", \"unknownRx\": ").append(EcgResearchStats.unrecognizedCount(records))
        sb.append(", \"rxOverflowDropped\": ").append(rxOverflow).append("},\n")
        sb.append("  \"packetsPerSecondByCharacteristic\": ").append(jnumMap(pps)).append(",\n")
        sb.append("  \"payloadSizeHistogram\": ").append(jintMap(hist.mapKeys { it.key.toString() })).append(",\n")
        sb.append("  \"largestPayloadSizes\": ").append(jintList(largest)).append(",\n")
        sb.append("  \"packetTypeCounts\": ")
            .append(jintMap(typeCounts.mapKeys { it.key?.toString() ?: "unrecognized" })).append(",\n")
        sb.append("  \"repeatedSizes\": ").append(jintMap(repeatedSizes.mapKeys { it.key.toString() })).append(",\n")
        sb.append("  \"candidateRawRecordSize\": ").append(CANDIDATE_RAW_RECORD_SIZE).append(",\n")
        sb.append("  \"candidateRawRecordCount\": ").append(candidateRawCount).append(",\n")
        sb.append("  \"maxZeroFractionOfLargeRecords\": ").append(maxZero?.let { round3(it).toString() } ?: "null").append(",\n")
        sb.append("  \"changingBytePositionsForSize\": ")
            .append(dominantLarge?.toString() ?: "null").append(",\n")
        sb.append("  \"changingBytePositions\": ").append(jintList(changing ?: emptyList())).append(",\n")
        sb.append("  \"packetTypesAppearedAfterStart\": ")
            .append(jNullableIntList(delta?.appearedAfter)).append(",\n")
        sb.append("  \"packetTypesDisappearedAfterStop\": ")
            .append(jNullableIntList(delta?.disappearedAfter)).append("\n")
        sb.append("}\n")
        return sb.toString()
    }

    // ---- formatting helpers (pure) -----------------------------------------------------------------

    /** ISO-8601 UTC to the second, computed WITHOUT java.time.Instant.now so it is deterministic. */
    private fun iso(wallMs: Long): String {
        var days = Math.floorDiv(wallMs, 86_400_000L)
        val msOfDay = Math.floorMod(wallMs, 86_400_000L)
        val hh = (msOfDay / 3_600_000L).toInt()
        val mm = ((msOfDay % 3_600_000L) / 60_000L).toInt()
        val ss = ((msOfDay % 60_000L) / 1000L).toInt()
        // civil-from-days (Howard Hinnant's algorithm), epoch 1970-01-01.
        var z = days + 719_468L
        val era = (if (z >= 0) z else z - 146_096) / 146_097
        val doe = z - era * 146_097
        val yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        val y = yoe + era * 400
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = (doy - (153 * mp + 2) / 5 + 1).toInt()
        val m = (if (mp < 10) mp + 3 else mp - 9).toInt()
        val year = (if (m <= 2) y + 1 else y).toInt()
        return "%04d-%02d-%02dT%02d:%02d:%02dZ".format(year, m, d, hh, mm, ss)
    }

    private fun csv(s: String): String =
        if (s.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) {
            "\"" + s.replace("\"", "\"\"") + "\""
        } else s

    private fun jstr(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) when (c) {
            '"' -> sb.append("\\\"")
            '\\' -> sb.append("\\\\")
            '\n' -> sb.append("\\n")
            '\r' -> sb.append("\\r")
            '\t' -> sb.append("\\t")
            else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
        }
        return sb.append('"').toString()
    }

    private fun jintList(xs: List<Int>): String = xs.joinToString(", ", "[", "]")
    private fun jNullableIntList(xs: List<Int?>?): String =
        (xs ?: emptyList()).joinToString(", ", "[", "]") { it?.toString() ?: "null" }
    private fun jintMap(m: Map<String, Int>): String =
        m.entries.joinToString(", ", "{", "}") { "${jstr(it.key)}: ${it.value}" }
    private fun jnumMap(m: Map<String, Double>): String =
        m.entries.joinToString(", ", "{", "}") { "${jstr(it.key)}: ${round3(it.value)}" }
    private fun round3(d: Double): Double = Math.round(d * 1000.0) / 1000.0

    private fun hex2(v: Int): String = "0x%02X".format(v and 0xFF)
    private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    /** Last 4 hex of a 128-bit UUID, or the string itself if short — the compact char label stats use. */
    private fun shortUuid(u: String): String {
        val first = u.substringBefore('-')
        return if (first.length >= 4) first.takeLast(4) else u
    }
}
