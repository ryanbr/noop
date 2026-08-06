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
// PacketType table has no Labrador entry — an app layer finds it empirically, running
// filteredBytesPerSampleCandidates over unclassified frames and censusing EVERY one of them by type byte,
// hits and misses alike, because a heuristic that logs only its own hits destroys the evidence for its own
// misses), the filtered stream's bytes-per-sample (decodeFiltered implements 2; the triage admits 2, 3 and
// 4 — see FILTERED_WIDTH_CANDIDATES), the WristSelection raw values (right-first is an inference),
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
 *
 * BOTH variable-length-looking regions are really FIXED-SIZE containers with a count that says how many
 * leading slots are valid: the sample region (see [unusedSampleBytes] and [Whoop5Ecg.decodeRaw]) and the
 * leads-off block ([Whoop5Ecg.LEADS_OFF_SLOT_COUNT] slots for I and the same again for Q, with
 * [numberOfLeadsOffSamples] selecting how many are valid). In both, the unused slots are dropped rather
 * than carried, so a packet's arrays only ever hold values the record says are real.
 */
data class RawLabradorPacket(
    val header: EcgStatusHeader,
    /**
     * Exactly `numberOfECGSamples * bytesPerSample` bytes — the VALID part of the sample region, which on
     * a partly-filled record is shorter than the region itself.
     */
    val rawECGDataRaw: List<Int>,
    /**
     * Bytes of the fixed sample region that `numberOfECGSamples` did not fill. Zero for a full record.
     *
     * The strap zero-fills them, and the decoder requires that. They are counted, not carried, so
     * `HEADER_LENGTH + rawECGDataRaw.size + unusedSampleBytes` is where the leads-off block begins.
     */
    val unusedSampleBytes: Int,
    val numberOfLeadsOffSamples: Int,
    val leadsOffIRaw: List<Int>,
    val leadsOffQRaw: List<Int>,
    val padding: List<Int>,
) {
    /** Bytes per raw sample, or null when the packet carried no samples to divide by. */
    val bytesPerSample: Int?
        get() = if (header.numberOfECGSamples > 0) rawECGDataRaw.size / header.numberOfECGSamples else null

    /** The full sample region the record reserved, valid part plus unused capacity. */
    val sampleRegionBytes: Int
        get() = rawECGDataRaw.size + unusedSampleBytes
}

object Whoop5Ecg {

    /** Bytes in the shared status header that both packets open with. */
    const val HEADER_LENGTH = 17

    /** Inner-record data offset in a puffin frame: [8]type [9]seq [10]cmd [11..]data. */
    const val PUFFIN_PAYLOAD_START = 11

    /** Trailing bytes tolerated after the last decoded field (the puffin pad4 budget). */
    const val DEFAULT_MAX_PADDING = 3

    /**
     * Slots in the raw record's leads-off diagnostic block, per array.
     *
     * MEASURED FROM HARDWARE, not attested: two complete type-47 layout-16 flash records captured
     * 2026-08-06 (embedded verbatim in the Swift `Whoop5EcgRawHardwareTests`) show the block is
     * FIXED-SIZE — the count byte is followed by eleven i16 I slots and then eleven i16 Q slots, present
     * in full whether or not `numberOfLeadsOffSamples` fills them, with the unused tail slots zeroed.
     * Both counts seen in the capture (10 and 11) place the Q array at the same offset and leave the same
     * single trailing byte, which is what identifies the block as fixed rather than packed.
     *
     * Reading it as PACKED — `count` elements each — was the original assumption, and it is wrong in two
     * compounding ways whenever `count < 11`: Q is read two bytes early per missing slot (so it gains a
     * spurious leading value and loses its last real one), and the misplaced end-of-record leaves a
     * remainder over [DEFAULT_MAX_PADDING], which discarded 227 of the capture's 351 populated records
     * before any field was read.
     */
    const val LEADS_OFF_SLOT_COUNT = 11

    /**
     * The bytes-per-sample widths the FILTERED triage admits, in the order it reports them.
     *
     * 2 leads because it is the width [decodeFiltered] implements and the width the filtered layout is
     * documented with, so the triage's earlier behaviour is a strict subset of the widened one.
     *
     * 3 and 4 are here because the 2-byte assumption was, on this repo's own evidence, unsafe: a populated
     * RAW flash record read off hardware carried `numberOfECGSamples = 500` against a 1500-byte sample
     * blob — 3 bytes per sample. Nothing attests that the FILTERED stream uses the same width and nothing
     * rules it out; what a hardcoded 2 did was make the difference unobservable, because a 3-byte frame
     * failed the length agreement and was discarded before anyone could look at it.
     *
     * Only the WIDTH is loosened — the four Bool-typed bytes, the two classifier enums, the
     * signal-quality range and `n > 0` are unchanged.
     */
    val FILTERED_WIDTH_CANDIDATES = listOf(2, 3, 4)

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
     * Bytes the raw record's leads-off block occupies: the count byte, then a full I array, then a full Q
     * array. Fixed — see [LEADS_OFF_SLOT_COUNT].
     */
    const val LEADS_OFF_BLOCK_LENGTH = 1 + LEADS_OFF_SLOT_COUNT * 4

    /**
     * Decode a raw packet from the inner record's PAYLOAD with an explicit sample width.
     *
     * The width has to be supplied because the raw blob's length is NOT on the wire.
     *
     * **The sample region is a fixed-size container, not `n * bytesPerSample` bytes.** MEASURED FROM
     * HARDWARE, on the same capture and by the same argument as [LEADS_OFF_SLOT_COUNT]: the capture's one
     * partly-filled record (`numberOfECGSamples == 245`, embedded in the Swift `Whoop5EcgRawHardwareTests`
     * and its Kotlin twin) is the same 1584-byte frame as every full 500-sample record, its sample data
     * stops after `245 * 3` bytes, the rest of the region is zeroed, and its leads-off block sits at the
     * SAME frame offset as every other record's. So `numberOfECGSamples` says how many of the region's
     * slots are valid in exactly the way `numberOfLeadsOffSamples` says how many leads-off slots are.
     *
     * That is why the block is located from the END of the payload rather than from
     * `HEADER_LENGTH + n * bytesPerSample`: the region's LENGTH is no more on the wire than the width is,
     * and a decoder that assumes the region is exactly full lands the count byte inside the zero fill.
     * No region length is hardcoded; the block's own fixed size anchors it.
     *
     * Candidate ends are tried closest-to-the-end first, so the record claims the least padding it can —
     * the puffin pad4 filler is minimal by construction. That ordering is a tie-break, not a proof: an
     * all-zero tail can also validate a block placed a byte or two earlier, and the tightest placement is
     * the one that explains the most bytes. Two things then have to hold: the region must be long enough
     * for the declared samples, and every byte between them and the block must be ZERO. The zero-fill
     * check is what keeps the width enumeration honest — a width that under-reads the samples leaves real
     * sample bytes in the unused span and is rejected there.
     */
    fun decodeRaw(
        payload: List<Int>,
        bytesPerSample: Int,
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): RawLabradorPacket? {
        if (bytesPerSample <= 0 || maxPadding < 0) return null
        val header = decodeHeader(payload) ?: return null
        // `bytesPerSample` is caller-supplied and `numberOfECGSamples` comes off the wire, so the product
        // is checked rather than assumed: a Kotlin Int overflow wraps silently to a NEGATIVE index, which
        // would throw on the subscript below. A decode failure is the correct outcome, not an exception.
        val blobLength = header.numberOfECGSamples.toLong() * bytesPerSample.toLong()
        if (blobLength > Int.MAX_VALUE - HEADER_LENGTH) return null
        val sampleEnd = HEADER_LENGTH + blobLength.toInt()
        if (sampleEnd < HEADER_LENGTH || sampleEnd > payload.size) return null

        for (pad in 0..maxPadding) {
            val blockEnd = payload.size - pad
            val countIndex = blockEnd - LEADS_OFF_BLOCK_LENGTH
            // The block must sit entirely after the declared samples. This also bounds `countIndex` from
            // below, since `sampleEnd >= HEADER_LENGTH >= 0`.
            if (countIndex < sampleEnd) continue
            // Unused sample capacity is zero-filled on the wire. A non-zero byte here means the block is
            // not at this offset — including the case where it holds samples a wider width would read.
            if ((sampleEnd until countIndex).any { payload[it] != 0 }) continue
            // Same domain check the Swift twin makes: on the wire this byte is 0..255, and the block holds
            // only LEADS_OFF_SLOT_COUNT slots — a count above that is not a record this layout can
            // describe, so it fails closed rather than reading past the block.
            val leadsOffCount = payload[countIndex]
            if (leadsOffCount !in 0..LEADS_OFF_SLOT_COUNT) continue
            // Both arrays are FIXED-SIZE and always fully present — see [LEADS_OFF_SLOT_COUNT]. The count
            // byte selects how many leading slots are VALID; it does not size the block.
            val iStart = countIndex + 1
            val qStart = iStart + LEADS_OFF_SLOT_COUNT * 2

            val leadsOffI = (0 until leadsOffCount).map { payload[iStart + it * 2] or (payload[iStart + it * 2 + 1] shl 8) }
            val leadsOffQ = (0 until leadsOffCount).map { payload[qStart + it * 2] or (payload[qStart + it * 2 + 1] shl 8) }
            return RawLabradorPacket(
                header = header,
                rawECGDataRaw = payload.subList(HEADER_LENGTH, sampleEnd).toList(),
                unusedSampleBytes = countIndex - sampleEnd,
                numberOfLeadsOffSamples = leadsOffCount,
                leadsOffIRaw = leadsOffI,
                leadsOffQRaw = leadsOffQ,
                padding = payload.subList(blockEnd, payload.size).toList(),
            )
        }
        return null
    }

    /**
     * Every sample width in [widths] that yields a structurally consistent record leaving at most
     * [maxPadding] trailing bytes. A DISAMBIGUATION helper, not a claim.
     *
     * A PARTLY-FILLED record is genuinely ambiguous, and that is a fact about the record rather than a gap
     * here: 245 samples inside a 1500-byte region fits 3 bytes per sample and 4 alike, so the capture's
     * short record reports `[3, 4]` and the single-candidate [decodeRaw] below declines it. The width is a
     * property of the STREAM — the 350 full records in the same capture resolve to `[3]` on their own.
     */
    fun rawBytesPerSampleCandidates(
        payload: List<Int>,
        widths: List<Int> = listOf(1, 2, 3, 4),
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): List<Int> = widths.filter { width -> decodeRaw(payload, width, maxPadding) != null }

    /** Decode a raw record only when the buffer admits exactly ONE width; ambiguity returns null. */
    fun decodeRaw(
        payload: List<Int>,
        widths: List<Int> = listOf(1, 2, 3, 4),
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): RawLabradorPacket? {
        val candidates = rawBytesPerSampleCandidates(payload, widths, maxPadding)
        return if (candidates.size == 1) decodeRaw(payload, candidates[0], maxPadding) else null
    }

    /** CRC-gated raw decode straight off a complete 5/MG frame, with an explicit sample width. */
    fun decodeRawFrame(
        frame: ByteArray,
        bytesPerSample: Int,
        payloadStart: Int = PUFFIN_PAYLOAD_START,
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): RawLabradorPacket? =
        innerPayload(frame, payloadStart)?.let { decodeRaw(it, bytesPerSample, maxPadding) }

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
     *
     * A pass under ANY width in [FILTERED_WIDTH_CANDIDATES] is a pass; callers that need to know WHICH
     * width agreed call [filteredBytesPerSampleCandidates] instead of re-deriving it.
     */
    fun plausibleFilteredPayload(payload: List<Int>, maxPadding: Int = DEFAULT_MAX_PADDING): Boolean =
        filteredBytesPerSampleCandidates(payload, maxPadding = maxPadding).isNotEmpty()

    /**
     * Every width in [widths] under which [payload] could be a filtered Labrador payload — the widths
     * whose length agreement holds once the buffer has passed the field guards.
     *
     * Empty is the triage's rejection. More than one width means the buffer genuinely does not determine
     * the answer; like [rawBytesPerSampleCandidates] this REPORTS the ambiguity rather than picking one.
     */
    fun filteredBytesPerSampleCandidates(
        payload: List<Int>,
        widths: List<Int> = FILTERED_WIDTH_CANDIDATES,
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): List<Int> {
        val header = decodeHeader(payload) ?: return emptyList()
        if (header.signalQualityRaw > 3) return emptyList()
        if (header.heartKeyArrhythmiaCheckResult == null) return emptyList()
        if (header.heartKeyArrhythmiaCheckStatus == null) return emptyList()
        if (payload[2] > 1 || payload[3] > 1 || payload[4] > 1 || payload[5] > 1) return emptyList()
        val n = header.numberOfECGSamples
        if (n <= 0) return emptyList()
        return widths.filter { width ->
            // `widths` is caller-supplied and `n` comes off the wire, so the offset math is done in Long
            // and range-checked: a Kotlin Int overflow wraps silently NEGATIVE and would slip past the
            // bounds test below. Same discipline as decodeRaw.
            if (width <= 0) return@filter false
            val end = HEADER_LENGTH + n.toLong() * width.toLong()
            end <= payload.size && payload.size - end <= maxPadding
        }
    }

    /** The frame-level form of [filteredBytesPerSampleCandidates], CRC-gated. */
    fun filteredBytesPerSampleCandidates(
        frame: ByteArray,
        payloadStart: Int = PUFFIN_PAYLOAD_START,
        widths: List<Int> = FILTERED_WIDTH_CANDIDATES,
        maxPadding: Int = DEFAULT_MAX_PADDING,
    ): List<Int> {
        val payload = innerPayload(frame, payloadStart) ?: return emptyList()
        return filteredBytesPerSampleCandidates(payload, widths, maxPadding)
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
