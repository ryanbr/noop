package com.noop.protocol

// WHOOP MG ECG ("Labrador") packet decode + command construction — the Kotlin twin of
// Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift. Keep the two byte-identical.
//
// The WHOOP MG carries ECG electrodes in its conductive clasp (a plain WHOOP 5.0 does not — see
// Whoop5Variant). The strap's ECG subsystem is called "Labrador" in the protocol tables, and it is a
// SEPARATE realtime data type from the R-numbered StrapSensorData layouts: a FILTERED stream (live) and
// a RAW stream (persisted on the strap for later offload). Both open with the same 17-byte status header.
//
// Provenance. The four command NUMBERS are already in this repo's protocol table
// (WhoopProtocol/Resources/whoop_protocol.json, CommandNumber), from the upstream whoomp/goose work
// credited in ATTRIBUTION.md: 123 (0x7B) SELECT_WRIST, 124 (0x7C) TOGGLE_LABRADOR_DATA_GENERATION,
// 125 (0x7D) TOGGLE_LABRADOR_RAW_SAVE, 139 (0x8B) TOGGLE_LABRADOR_FILTERED. The packet field layouts and
// command payload shapes are protocol facts sourced from static analysis of the official iOS client and
// reimplemented here in NOOP's own code — facts with attribution, never copied expression.
//
// Deliberately NOT asserted: the packet TYPE byte these records arrive under (no capture exists, and the
// PacketType table has no Labrador entry), the WristSelection raw values (right-first is an inference),
// the heartKeyProgress "timed out" sentinel, and any clinical meaning at all. The arrhythmia result is
// computed on-strap by an embedded third-party classifier; NOOP decodes the byte. NOOP is not a medical
// device and this value is not a diagnosis — see DISCLAIMER.md.

/** Per-packet signal-quality grade. Declaration order is the raw value. */
enum class EcgSignalQuality(val raw: Int) {
    UNKNOWN(0), LOW(1), MEDIUM(2), HIGH(3);

    val label: String get() = name.lowercase()

    companion object {
        fun from(raw: Int): EcgSignalQuality? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * The on-strap classifier's verdict, as carried in every Labrador packet.
 *
 * DECODE ONLY. NOOP does not compute it, cannot validate it, and must never present it as a finding.
 */
enum class EcgArrhythmiaCheckResult(val raw: Int, val token: String) {
    NOT_COMPLETE(0, "notComplete"),
    NORMAL_SINUS_RHYTHM(1, "normalSinusRhythm"),
    SIGNAL_UNREADABLE(2, "signalUnreadable"),
    BRADYCARDIA(3, "bradycardia"),
    AFIB_DETECTED(4, "afibDetected"),
    TACHYCARDIA(5, "tachycardia"),
    INCONCLUSIVE(6, "inconclusive");

    companion object {
        fun from(raw: Int): EcgArrhythmiaCheckResult? = entries.firstOrNull { it.raw == raw }
    }
}

/** Where the on-strap classifier is in its run. */
enum class EcgArrhythmiaCheckStatus(val raw: Int, val token: String) {
    NOT_RUNNING(0, "notRunning"),
    IN_PROGRESS(1, "inProgress"),
    CHECK_COMPLETE(2, "checkComplete");

    companion object {
        fun from(raw: Int): EcgArrhythmiaCheckStatus? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Classifier progress. The source type is a union of a percentage and a "timed out" case, but the
 * sentinel VALUE for the latter is not attested — so 0..100 decodes as a percentage and every other byte
 * is carried raw rather than promoted into a state we cannot prove.
 */
data class EcgHeartKeyProgress(val raw: Int) {
    val percentValue: Int? get() = if (raw in 0..100) raw else null
    val isMapped: Boolean get() = percentValue != null
}

/** The 17-byte status block both Labrador packets open with, in wire order. Multi-byte fields are LE. */
data class EcgStatusHeader(
    val signalQuality: EcgSignalQuality,
    /** Raw quality byte, kept so a value outside the known enum is never lost. */
    val signalQualityRaw: Int,
    val statusFlags: Int,
    val heartKeyStarted: Boolean,
    val heartKeyIsRunning: Boolean,
    val heartKeyIsStoppedAndComplete: Boolean,
    val heartKeyLeadsAreOn: Boolean,
    val heartKeyArrhythmiaCheckResult: EcgArrhythmiaCheckResult?,
    val heartKeyArrhythmiaCheckResultRaw: Int,
    val heartKeyArrhythmiaCheckStatus: EcgArrhythmiaCheckStatus?,
    val heartKeyArrhythmiaCheckStatusRaw: Int,
    val heartKeyProgress: EcgHeartKeyProgress,
    val heartKeyUnreadableReason: Int,
    val heartKeyAverageHR: Int,
    val heartKeyHR: Int,
    val heartKeyHRV: Int,
    val heartKeyStressScore: Int,
    val numberOfECGSamples: Int,
)

/**
 * The live ECG stream packet (TOGGLE_LABRADOR_FILTERED, 0x8B).
 *
 * The sample UNIT and SCALE are not attested, so the array is named `filteredECGDataRaw` and no µV
 * conversion is applied anywhere.
 */
data class FilteredLabradorPacket(
    val header: EcgStatusHeader,
    val filteredECGDataRaw: List<Int>,
    val padding: List<Int>,
)

/**
 * The persisted ECG record (TOGGLE_LABRADOR_RAW_SAVE, 0x7D).
 *
 * The raw blob is opaque: its bytes-per-sample is `rawECGDataRaw.size / numberOfECGSamples`, which means
 * the blob's LENGTH is not itself on the wire (see [Whoop5Ecg.rawBytesPerSampleCandidates]).
 */
data class RawLabradorPacket(
    val header: EcgStatusHeader,
    val rawECGDataRaw: List<Int>,
    val numberOfLeadsOffSamples: Int,
    val leadsOffIRaw: List<Int>,
    val leadsOffQRaw: List<Int>,
    val padding: List<Int>,
) {
    /** Bytes per raw sample, or null when the packet carried no samples to divide by. */
    val bytesPerSample: Int?
        get() = if (header.numberOfECGSamples > 0) rawECGDataRaw.size / header.numberOfECGSamples else null
}

object Whoop5Ecg {

    /** Bytes in the shared status header that both packets open with. */
    const val HEADER_LENGTH = 17

    /** Inner-record data offset in a puffin frame: [8]type [9]seq [10]cmd [11..]data. */
    const val PUFFIN_PAYLOAD_START = 11

    /** Trailing bytes tolerated after the last decoded field (the puffin pad4 budget). */
    const val DEFAULT_MAX_PADDING = 3

    // Commands. All four share the shape {revision, arg, padding}; `revision` is the leading inner byte
    // the 5/MG command family already uses (CLIENT_HELLO, SET_CONFIG), and the struct's trailing padding
    // is exactly what the puffin pad4 supplies.

    /** SELECT_WRIST (123 / 0x7B). PERSISTENT device config — survives a disconnect. Reversible. */
    const val SELECT_WRIST_CMD = 123

    /** TOGGLE_LABRADOR_DATA_GENERATION (124 / 0x7C) — the client's mainControlECGDataGeneration. */
    const val MAIN_CONTROL_ECG_DATA_GENERATION_CMD = 124

    /** TOGGLE_LABRADOR_RAW_SAVE (125 / 0x7D) — the client's toggleSaveRawECG. */
    const val TOGGLE_SAVE_RAW_ECG_CMD = 125

    /** TOGGLE_LABRADOR_FILTERED (139 / 0x8B) — the client's toggleRealtimeFilteredECG. */
    const val TOGGLE_REALTIME_FILTERED_ECG_CMD = 139

    /** The `revision` byte every one of these commands leads with. */
    const val COMMAND_REVISION = 0x01

    /**
     * Which wrist the strap is worn on.
     *
     * The raw values are INFERRED, not attested: `right` is listed first in the client's enum. Since this
     * command writes PERSISTENT strap state, a wrong inference writes a wrong persistent value.
     */
    enum class WristSelection(val raw: Int, val token: String) {
        RIGHT(0, "right"), LEFT(1, "left")
    }

    /** The mainControlECGDataGeneration argument. */
    enum class ControlSignal(val raw: Int, val token: String) {
        STOP(0, "stop"), START(1, "start"), RESTART(2, "restart")
    }

    fun commandPayload(arg: Int): List<Int> = listOf(COMMAND_REVISION, arg)

    fun selectWristPayload(wrist: WristSelection): List<Int> = commandPayload(wrist.raw)

    fun togglePayload(on: Boolean): List<Int> = commandPayload(if (on) 1 else 0)

    fun controlPayload(signal: ControlSignal): List<Int> = commandPayload(signal.raw)

    /**
     * The complete puffin frame for one Labrador command. Twin of the Swift builders, so the exact wire
     * form is pinned by a test on both platforms even though the Android app has no ECG UI yet.
     */
    fun commandFrame(cmd: Int, arg: Int, seq: Int): ByteArray =
        Framing.puffinCommandFrame(
            cmd = cmd, seq = seq,
            payload = commandPayload(arg).map { it.toByte() }.toByteArray(),
        )

    fun selectWristFrame(wrist: WristSelection, seq: Int): ByteArray =
        commandFrame(SELECT_WRIST_CMD, wrist.raw, seq)

    fun toggleRealtimeFilteredEcgFrame(on: Boolean, seq: Int): ByteArray =
        commandFrame(TOGGLE_REALTIME_FILTERED_ECG_CMD, if (on) 1 else 0, seq)

    fun toggleSaveRawEcgFrame(on: Boolean, seq: Int): ByteArray =
        commandFrame(TOGGLE_SAVE_RAW_ECG_CMD, if (on) 1 else 0, seq)

    fun mainControlEcgDataGenerationFrame(signal: ControlSignal, seq: Int): ByteArray =
        commandFrame(MAIN_CONTROL_ECG_DATA_GENERATION_CMD, signal.raw, seq)

    /**
     * Whether this Labrador command, **sent with this argument**, can make the strap emit ECG data on the
     * REALTIME channel — the only channel a fixed listen window can observe.
     *
     * This is the predicate every "the strap accepted it and then produced nothing" claim rests on, so it
     * lives here — pure, mirrored in Swift, and tested on both platforms — rather than in an app layer
     * where only one platform would check it.
     *
     * The ARGUMENT is half the answer. Three of the four opcodes gate a data path and all three are
     * toggles, so `toggleRealtimeFilteredEcg(0)` turns the stream **off** and can no more produce data
     * than `selectWrist` can. A run built only from such commands has asked for nothing, and its silence
     * is the expected outcome rather than a finding.
     *
     * Conservative by construction — three cases return `false`:
     *
     *  - `SELECT_WRIST` configures which wrist the strap is worn on. It starts nothing, on either argument.
     *  - `TOGGLE_LABRADOR_RAW_SAVE` names flash, not a live channel (`RAW_SAVE`), and the name is the only
     *    evidence anyone in this repo has about where its output lands. Counting it as observable would
     *    let a raw-save-only run be read as "accepted and then silent", which a realtime window cannot
     *    support — that is hypothesis (b) in #891, still open.
     *  - Any opcode outside the family, which includes an UNSOLICITED reply whose sent argument is not
     *    known.
     *
     * A `false` can only ever weaken a verdict, never strengthen one, so an omission here fails safe.
     */
    fun requestsRealtimeData(cmd: Int, arg: Int): Boolean = when (cmd) {
        TOGGLE_REALTIME_FILTERED_ECG_CMD -> arg != 0
        MAIN_CONTROL_ECG_DATA_GENERATION_CMD ->
            arg == ControlSignal.START.raw || arg == ControlSignal.RESTART.raw
        else -> false
    }

    // Decode — filtered

    /**
     * Parse the shared status header from the start of [payload], or null when it is too short — or when
     * any of the bytes it reads is outside 0..255.
     *
     * The domain check exists because Kotlin's `List<Int>` can express values Swift's `[UInt8]` cannot.
     * Without it the two decoders would disagree on inputs the Swift side can't even represent: a
     * negative element flows into the leads-off arithmetic and throws on a subscript, and an oversized
     * one makes `payload[12] or (payload[13] shl 8)` exceed 0xFFFF where Swift's `UInt16` cannot. Lists
     * that came from [innerPayload] are always in range; this guards the public API.
     */
    fun decodeHeader(payload: List<Int>): EcgStatusHeader? {
        if (payload.size < HEADER_LENGTH) return null
        for (i in 0 until HEADER_LENGTH) if (payload[i] !in 0..255) return null
        return EcgStatusHeader(
            signalQuality = EcgSignalQuality.from(payload[0]) ?: EcgSignalQuality.UNKNOWN,
            signalQualityRaw = payload[0],
            statusFlags = payload[1],
            heartKeyStarted = payload[2] != 0,
            heartKeyIsRunning = payload[3] != 0,
            heartKeyIsStoppedAndComplete = payload[4] != 0,
            heartKeyLeadsAreOn = payload[5] != 0,
            heartKeyArrhythmiaCheckResult = EcgArrhythmiaCheckResult.from(payload[6]),
            heartKeyArrhythmiaCheckResultRaw = payload[6],
            heartKeyArrhythmiaCheckStatus = EcgArrhythmiaCheckStatus.from(payload[7]),
            heartKeyArrhythmiaCheckStatusRaw = payload[7],
            heartKeyProgress = EcgHeartKeyProgress(payload[8]),
            heartKeyUnreadableReason = payload[9],
            heartKeyAverageHR = payload[10],
            heartKeyHR = payload[11],
            heartKeyHRV = payload[12] or (payload[13] shl 8),
            heartKeyStressScore = payload[14],
            numberOfECGSamples = payload[15] or (payload[16] shl 8),
        )
    }

    /**
     * Decode a filtered packet from the inner record's PAYLOAD.
     *
     * Fails closed on a short header and on a numberOfECGSamples the buffer cannot hold — a count that
     * disagrees with the bytes present is a decode error, never a truncated best effort.
     */
    fun decodeFiltered(payload: List<Int>): FilteredLabradorPacket? {
        val header = decodeHeader(payload) ?: return null
        val n = header.numberOfECGSamples
        val end = HEADER_LENGTH + n * 2
        if (end > payload.size) return null
        val samples = (0 until n).map { i ->
            val off = HEADER_LENGTH + i * 2
            val u = payload[off] or (payload[off + 1] shl 8)
            if (u >= 0x8000) u - 0x10000 else u          // signed 16-bit, LE
        }
        return FilteredLabradorPacket(header, samples, payload.subList(end, payload.size).toList())
    }

    /** CRC-gated decode straight off a complete 5/MG frame. A frame failing either CRC is rejected. */
    fun decodeFilteredFrame(frame: ByteArray, payloadStart: Int = PUFFIN_PAYLOAD_START): FilteredLabradorPacket? =
        innerPayload(frame, payloadStart)?.let { decodeFiltered(it) }

    // Decode — raw

    /**
     * Decode a raw packet from the inner record's PAYLOAD with an explicit sample width.
     *
     * The width has to be supplied because the raw blob's length is NOT on the wire.
     */
    fun decodeRaw(payload: List<Int>, bytesPerSample: Int): RawLabradorPacket? {
        if (bytesPerSample <= 0) return null
        val header = decodeHeader(payload) ?: return null
        // `bytesPerSample` is caller-supplied and `numberOfECGSamples` comes off the wire, so the product
        // is checked rather than assumed: a Kotlin Int overflow wraps silently to a NEGATIVE index, which
        // would throw on the subscript below. A decode failure is the correct outcome, not an exception.
        val blobLength = header.numberOfECGSamples.toLong() * bytesPerSample.toLong()
        if (blobLength > Int.MAX_VALUE - HEADER_LENGTH) return null
        val rawEnd = HEADER_LENGTH + blobLength.toInt()
        if (rawEnd < HEADER_LENGTH || rawEnd >= payload.size) return null   // the leads-off count byte must fit
        // Same domain check as decodeHeader: a negative count would make qEnd negative, slip past the
        // `qEnd > size` bound, and throw on subList. On the wire this byte is always 0..255.
        val leadsOffCount = payload[rawEnd]
        if (leadsOffCount !in 0..255) return null
        val iStart = rawEnd + 1
        val qStart = iStart + leadsOffCount * 2
        val qEnd = qStart + leadsOffCount * 2
        if (qEnd > payload.size) return null

        val leadsOffI = (0 until leadsOffCount).map { payload[iStart + it * 2] or (payload[iStart + it * 2 + 1] shl 8) }
        val leadsOffQ = (0 until leadsOffCount).map { payload[qStart + it * 2] or (payload[qStart + it * 2 + 1] shl 8) }
        return RawLabradorPacket(
            header = header,
            rawECGDataRaw = payload.subList(HEADER_LENGTH, rawEnd).toList(),
            numberOfLeadsOffSamples = leadsOffCount,
            leadsOffIRaw = leadsOffI,
            leadsOffQRaw = leadsOffQ,
            padding = payload.subList(qEnd, payload.size).toList(),
        )
    }

    /**
     * Every sample width in [widths] that yields a structurally consistent record leaving at most
     * [maxPadding] trailing bytes. A DISAMBIGUATION helper, not a claim.
     */
    fun rawBytesPerSampleCandidates(
        payload: List<Int>,
        widths: List<Int> = listOf(1, 2, 3, 4),
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): List<Int> = widths.filter { width ->
        val packet = decodeRaw(payload, width)
        packet != null && packet.padding.size <= maxPadding
    }

    /** Decode a raw record only when the buffer admits exactly ONE width; ambiguity returns null. */
    fun decodeRaw(
        payload: List<Int>,
        widths: List<Int> = listOf(1, 2, 3, 4),
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): RawLabradorPacket? {
        val candidates = rawBytesPerSampleCandidates(payload, widths, maxPadding)
        return if (candidates.size == 1) decodeRaw(payload, candidates[0]) else null
    }

    /** CRC-gated raw decode straight off a complete 5/MG frame, with an explicit sample width. */
    fun decodeRawFrame(frame: ByteArray, bytesPerSample: Int, payloadStart: Int = PUFFIN_PAYLOAD_START): RawLabradorPacket? =
        innerPayload(frame, payloadStart)?.let { decodeRaw(it, bytesPerSample) }

    // Discovery

    /**
     * The frame-level form of [plausibleFilteredPayload], CRC-gated. This is what the app layer runs over
     * unclassified 5/MG frames while an ECG probe is armed. Twin of the Swift helper.
     */
    fun plausibleFilteredFrame(
        frame: ByteArray,
        payloadStart: Int = PUFFIN_PAYLOAD_START,
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): Boolean {
        val payload = innerPayload(frame, payloadStart) ?: return false
        return plausibleFilteredPayload(payload, maxPadding)
    }

    /**
     * A cheap structural triage for "could these bytes be a filtered Labrador payload?".
     *
     * Used by the app layer to hunt for the packet TYPE byte, which is not attested: while an ECG probe is
     * armed, every unclassified 5/MG frame is run through this and the hits are logged with their type. It
     * is a HEURISTIC — four booleans, three enum ranges and a length agreement — not a classifier, and
     * nothing downstream may treat a hit as proof.
     */
    fun plausibleFilteredPayload(payload: List<Int>, maxPadding: Int = DEFAULT_MAX_PADDING): Boolean {
        val header = decodeHeader(payload) ?: return false
        if (header.signalQualityRaw > 3) return false
        if (header.heartKeyArrhythmiaCheckResult == null) return false
        if (header.heartKeyArrhythmiaCheckStatus == null) return false
        if (payload[2] > 1 || payload[3] > 1 || payload[4] > 1 || payload[5] > 1) return false
        val n = header.numberOfECGSamples
        if (n <= 0) return false
        val end = HEADER_LENGTH + n * 2
        return end <= payload.size && payload.size - end <= maxPadding
    }

    /**
     * The inner record's payload from a complete 5/MG frame, or null when the frame fails either CRC or
     * is too short. Every frame-level entry point goes through here, so no Labrador field is ever read
     * out of an unverified frame.
     *
     * Both CRCs are checked here rather than through `Framing.parseFrame`, whose `crcOk` reports only
     * the CRC32 payload check — this needs the same gate as the Swift `verifyFrame(_:family:).ok`, which
     * is the CRC16 header check AND the CRC32 payload check.
     */
    fun innerPayload(frame: ByteArray, payloadStart: Int = PUFFIN_PAYLOAD_START): List<Int>? {
        if (frame.size < 12 || frame[0] != 0xAA.toByte()) return null
        val declaredLength = (frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)
        if (declaredLength < 4) return null
        val total = declaredLength + 8
        if (frame.size < total) return null

        // CRC16-Modbus over the first six header bytes, stored LE at frame[6..8].
        val gotHeader = (frame[6].toInt() and 0xFF) or ((frame[7].toInt() and 0xFF) shl 8)
        if (Crc.crc16Modbus(frame, 0, 6) != gotHeader) return null

        val payloadEnd = total - 4                        // start of the CRC32 trailer
        val gotCrc32 = (frame[payloadEnd].toLong() and 0xFFL) or
            ((frame[payloadEnd + 1].toLong() and 0xFFL) shl 8) or
            ((frame[payloadEnd + 2].toLong() and 0xFFL) shl 16) or
            ((frame[payloadEnd + 3].toLong() and 0xFFL) shl 24)
        if (Crc.crc32(frame, 8, payloadEnd) != gotCrc32) return null

        if (payloadStart < 0 || payloadStart >= payloadEnd) return null
        return (payloadStart until payloadEnd).map { frame[it].toInt() and 0xFF }
    }
}
