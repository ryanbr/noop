package com.noop.protocol

// WHOOP MG ECG ("Labrador") packet decode + command construction — the Kotlin twin of
// Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Ecg.swift. Keep the two byte-identical.
//
// The WHOOP MG carries ECG electrodes in its conductive clasp (a plain WHOOP 5.0 does not — see
// Whoop5Variant). The strap's ECG subsystem is called "Labrador" in the protocol tables, and it is a
// SEPARATE realtime data type from the R-numbered StrapSensorData layouts: a FILTERED stream (live, data
// revision 17) and a RAW stream (persisted on the strap for later offload, data revision 16).
//
// They do NOT share a status block. The filtered record's layout is [LabradorR17], read from the inner
// record at the offsets the official parser uses. [EcgStatusHeader] below is the earlier client-derived
// reading; it survives only on the RAW path, whose body layout nothing here can yet confirm.
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

/**
 * The 17-byte status block the RAW (revision 16) record is read with, in wire order. Multi-byte fields
 * are LE.
 *
 * NOT the filtered record's layout, though it was written believing it was: see [LabradorR17]. Whether
 * the raw record really opens this way is still unconfirmed, so this stays where it is rather than being
 * corrected to something equally unproven.
 */
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

/** R17 `inner[14]` — the on-strap classifier's state/transition bits plus electrode presence. */
@JvmInline
value class EcgLabradorFlags(val raw: Int) {
    /** bit 0 — entering classifier state 1. */
    val enteringStateOne: Boolean get() = raw and 0x01 != 0

    /**
     * bit 1 — the current classifier state IS 1. An ordinary active frame carries this set; a valid
     * active frame with it clear is the explicit-restart case, not a contact loss.
     */
    val currentStateOne: Boolean get() = raw and 0x02 != 0

    /** bit 2 — the 1 -> 2 state transition, set on the terminal frame. */
    val stateTransitionOneToTwo: Boolean get() = raw and 0x04 != 0

    /**
     * bit 3 — electrode contact, debounced on the strap. This is the bit `heartKeyLeadsAreOn` was
     * reaching for at the wrong offset.
     */
    val presence: Boolean get() = raw and 0x08 != 0

    /** The set bits by name, in bit order. Bits above 3 are reported as unknown rather than named. */
    val tokens: List<String>
        get() = buildList {
            if (enteringStateOne) add("entering_state_1")
            if (currentStateOne) add("state_1")
            if (stateTransitionOneToTwo) add("transition_1_2")
            if (presence) add("presence")
            val unknown = raw and 0x0F.inv() and 0xFF
            if (unknown != 0) add("unknown_bits_0x%02x".format(unknown))
        }
}

/**
 * R17 `inner[18]` — why the strap called a reading unreadable. Bits above 3 are reported as unknown
 * rather than given a meaning.
 */
@JvmInline
value class EcgUnreadableMask(val raw: Int) {
    val lowAmplitude: Boolean get() = raw and 0x01 != 0
    val significantNoise: Boolean get() = raw and 0x02 != 0
    val unstableSignal: Boolean get() = raw and 0x04 != 0
    val notEnoughData: Boolean get() = raw and 0x08 != 0

    /** The set bits by name, in bit order. */
    val reasons: List<String>
        get() = buildList {
            if (lowAmplitude) add("low_amplitude")
            if (significantNoise) add("significant_noise")
            if (unstableSignal) add("unstable_signal")
            if (notEnoughData) add("not_enough_data")
            val unknown = raw and 0x0F.inv() and 0xFF
            if (unknown != 0) add("unknown_bits_0x%02x".format(unknown))
        }
}

/**
 * One Labrador revision-17 packet — the strap's live filtered-ECG cycle. Twin of Swift `LabradorR17`.
 *
 * Offsets are into the INNER record, counted from the packet-type byte. On a 5/MG frame that byte is at
 * [Whoop5Ecg.RAW_TYPE_OFFSET] (8), so `inner[k]` is `frame[8 + k]`: fixed fields occupy `inner[0..25]`
 * and the samples start at `inner[26]` — `frame[34]`, which is exactly the waveform offset the type-43
 * constants in this file were already observing on hardware.
 *
 * [samples] are 100 Hz filtered signed i16 little-endian values as transmitted. No rescaling is applied
 * and no anatomical lead or polarity is claimed. [variabilityRaw] has no proven unit.
 */
data class LabradorR17(
    /** `inner[0]`: 43 (REALTIME_RAW_DATA, the live path) or 47 (HISTORICAL_DATA, a stored copy). */
    val packetType: Int,
    /** `inner[2]` — a packet-context marker the consumer ignores. Kept raw rather than named. */
    val headerSecondary: Int,
    val sequence: Long,             // inner[3..6]   u32 LE
    val strapSeconds: Long,         // inner[7..10]  u32 LE
    val subseconds: Int,            // inner[11..12] u16 LE, 1/32768 s
    val signalQuality: EcgSignalQuality,
    val signalQualityRaw: Int,      // inner[13]
    val flags: EcgLabradorFlags,    // inner[14]
    /** `inner[15]` — the classifier result code. Null when it maps to no known case. */
    val arrhythmiaCheckResult: EcgArrhythmiaCheckResult?,
    val arrhythmiaCheckResultRaw: Int,
    val classifierState: Int,       // inner[16]; 2 is terminal
    val progress: EcgHeartKeyProgress,  // inner[17]; 100 terminal, 255 invalid
    val unreadable: EcgUnreadableMask,  // inner[18]
    val averageHR: Int,             // inner[19] — the final/stored heart rate
    val liveHR: Int,                // inner[20] — the current heart rate
    /** `inner[21..22]` u16 LE, or null when the wire carried the unavailable sentinel. */
    val variabilityRaw: Int?,
    val reserved: Int,              // inner[23]
    val sampleCount: Int,           // inner[24..25] u16 LE
    val samples: List<Int>,
    /** Aligned bytes after the sample block, byte-exact, meaning unassigned. */
    val tail: List<Int>,
) {
    /** Electrode contact, from the flags byte. */
    val presence: Boolean get() = flags.presence

    /** The strap's completion condition. */
    val isTerminal: Boolean get() = progress.raw == 100 || classifierState == 2

    /** The strap's invalid/abort sentinel. */
    val isInvalid: Boolean get() = progress.raw == 255

}

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
     * `RIGHT = 1`, `LEFT = 2` — one-based, NOT the client's zero-based declaration order.
     *
     * The previous `RIGHT(0) / LEFT(1)` was read off that order and shipped as an acknowledged
     * inference. It was wrong in exactly the way [ControlSignal]'s was (#896): the wire values for this
     * family start at 1, and 0 is not a member. Corrected against the official Android 5.458.0 Labrador
     * parser and the 50.41.1.0 firmware constructor, cross-checked against a third-party implementation
     * that drives a physical MG through a complete reading.
     *
     * This command writes PERSISTENT strap state, so the old values did not merely fail — they wrote a
     * wrong persistent selection, or were refused outright, on every strap that ran the probe.
     */
    enum class WristSelection(val raw: Int, val token: String) {
        RIGHT(1, "right"), LEFT(2, "left")
    }

    /**
     * The mainControlECGDataGeneration argument.
     *
     * ⚠️ These raw values are ATTESTED ON ONE DEVICE, and they are NOT the vendor client's declaration
     * order. The previous `STOP(0) / START(1) / RESTART(2)` was read off that order and shipped
     * unverified (#896). On a WHOOP MG (`WS50_r00`, fw `50.39.1.0`) each argument was sent on its own
     * while watching the type-43 stream rather than the ack:
     *
     *  - `0` is REFUSED — the strap answers `FAILURE(0)` and generation is unchanged, so there is no
     *    case for it here and nothing can send it.
     *  - `1` STOPS generation.
     *  - `2` STARTS it. The type-43 stream only follows once `TOGGLE_LABRADOR_FILTERED (139)` is on, so
     *    the working turn-on order is `139 = 1` then `124 = 2`. 139 gates the STREAM rather than the
     *    front end: with 139 closed, `124 = 2` still made the strap's own console log
     *    `MAX86176: Set ECG ON` while no packets arrived (8 sends, 8 console lines, #891).
     *
     * One device, one firmware. #1100 ran `WS50_r03` / `50.40.1.0` and nothing here says the two agree.
     * Whether `2` is a plain start or a stop-then-start is NOT distinguishable from a stream that was
     * already off, so the case is named for what it achieves rather than for the client's third name.
     * Twin of Swift `ControlSignal`.
     */
    enum class ControlSignal(val raw: Int, val token: String) {
        STOP(1, "stop"), START(2, "start")
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
            // Only the START value. `ControlSignal.STOP` (1) halts generation, so a run whose last act
            // was that one asked for nothing and its silence is the expected outcome, not a finding.
            arg == ControlSignal.START.raw
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
     * Decode a [LabradorR17] from a complete INNER record — the bytes from the packet-type byte onwards,
     * which on a 5/MG frame means `frame[8..]`. Swift twin: `Whoop5Ecg.parseR17`.
     *
     * Accepts only a type-43 (or, with [allowStored], type-47) record of data revision 17 whose declared
     * sample block fits: fixed fields through `inner[25]` present, `sampleCount <= 100`, and
     * `26 + 2 * sampleCount` bytes available. No fixed total length is required; bytes past the sample
     * block land in `tail`. CRC validity is the caller's business — [r17FromFrame] enforces it.
     *
     * Fails closed throughout: a count that disagrees with the bytes present is a decode error, never a
     * truncated best effort.
     */
    fun parseR17(inner: List<Int>, allowStored: Boolean = false): LabradorR17? {
        if (inner.size < R17_FIXED_LENGTH) return null
        for (i in 0 until R17_FIXED_LENGTH) if (inner[i] !in 0..255) return null
        val type = inner[0]
        if (type != RAW_RECORD_TYPE && !(allowStored && type == STORED_RECORD_TYPE)) return null
        if (inner[1] != R17_REVISION) return null
        val count = u16le(inner, 24)
        if (count > R17_MAX_SAMPLES) return null
        val end = R17_SAMPLE_START + count * 2
        if (inner.size < end) return null
        for (i in R17_SAMPLE_START until end) if (inner[i] !in 0..255) return null

        val samples = ArrayList<Int>(count)
        for (i in 0 until count) {
            val raw = u16le(inner, R17_SAMPLE_START + i * 2)
            samples.add(if (raw >= 0x8000) raw - 0x10000 else raw)
        }
        val variability = u16le(inner, 21)
        val quality = inner[13]
        return LabradorR17(
            packetType = type,
            headerSecondary = inner[2],
            sequence = u32le(inner, 3),
            strapSeconds = u32le(inner, 7),
            subseconds = u16le(inner, 11),
            signalQuality = EcgSignalQuality.entries.firstOrNull { it.raw == quality } ?: EcgSignalQuality.UNKNOWN,
            signalQualityRaw = quality,
            flags = EcgLabradorFlags(inner[14]),
            arrhythmiaCheckResult = EcgArrhythmiaCheckResult.entries.firstOrNull { it.raw == inner[15] },
            arrhythmiaCheckResultRaw = inner[15],
            classifierState = inner[16],
            progress = EcgHeartKeyProgress(inner[17]),
            unreadable = EcgUnreadableMask(inner[18]),
            averageHR = inner[19],
            liveHR = inner[20],
            variabilityRaw = if (variability == R17_VARIABILITY_UNAVAILABLE) null else variability,
            reserved = inner[23],
            sampleCount = count,
            samples = samples,
            tail = inner.subList(end, inner.size).toList(),
        )
    }

    /** Swift twin: `Whoop5Ecg.u16le`. */
    private fun u16le(b: List<Int>, i: Int): Int = b[i] or (b[i + 1] shl 8)

    /** Swift twin: `Whoop5Ecg.u32le`. */
    private fun u32le(b: List<Int>, i: Int): Long =
        (b[i].toLong()) or (b[i + 1].toLong() shl 8) or (b[i + 2].toLong() shl 16) or (b[i + 3].toLong() shl 24)

    /**
     * [parseR17] straight off a complete 5/MG frame, CRC-gated. The frame must pass the central verifier
     * before any field is read, per the BLE safety contract. Swift twin: `Whoop5Ecg.r17FromFrame`.
     */
    fun r17FromFrame(frame: ByteArray, allowStored: Boolean = false): LabradorR17? {
        // Through [innerPayload] with the INNER record's own start offset, not `frame.drop(8)`. It is the
        // one seam that both CRC-gates the frame and stops at the CRC32 trailer; slicing to the end of
        // the buffer instead would hand four envelope bytes to `tail` and call them record bytes.
        val inner = innerPayload(frame, RAW_TYPE_OFFSET) ?: return null
        return parseR17(inner, allowStored)
    }

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

    // ---- The type-43 REALTIME_RAW_DATA record: the live ECG sample carrier (#891/#1100) -----------
    //
    // OBSERVED on one WHOOP MG (WS50_r00, fw 50.39.1.0), not attested by any vendor document: once
    // TOGGLE_LABRADOR_FILTERED(139)=1 has opened the master gate, the strap emits fixed-size 240-byte
    // REALTIME_RAW_DATA (type 43) records whose body carries an i16-LE series. The offsets below are the
    // OBSERVED layout, and they live here — with the other Labrador protocol facts — rather than in the app
    // layer, so the three consumers (live view, signal classifier, waveform export) cannot drift apart and
    // so the decode is unit-testable without a strap.
    //
    // What this layout is NOT: [HEADER_LENGTH] belongs to the RAW record, not to this one. The record
    // these helpers walk IS the filtered R17 — [RAW_WAVEFORM_START] equals `RAW_TYPE_OFFSET +
    // R17_SAMPLE_START`, which is how the offset measured here and the source-closed layout were shown to
    // describe the same bytes. These helpers stay sample-only on purpose: nothing here decodes a status
    // field, an HR, or a rhythm classification, because [parseR17] is where that belongs. A record that
    // fails CRC must never reach them: callers gate on the frame's CRC first.

    /** Every REALTIME_RAW_DATA record OBSERVED on the MG was exactly this long. */
    const val RAW_RECORD_LENGTH = 240

    /** Frame offset of the inner record's type byte on 5/MG (`[8]type [9]seq [10]cmd`). */
    const val RAW_TYPE_OFFSET = 8

    /** The inner record type byte for REALTIME_RAW_DATA. */
    const val RAW_RECORD_TYPE = 43

    /**
     * The inner record type byte for HISTORICAL_DATA — a STORED R17, which the live turn-on path never
     * enables. [parseR17] accepts it only when asked to.
     */
    const val STORED_RECORD_TYPE = 47

    // The revision-17 layout.
    //
    // Offsets into the INNER record, from the packet-type byte. `inner[k]` is `frame[RAW_TYPE_OFFSET + k]`.
    // Source-closed against the official Android 5.458.0 Labrador parser and the 50.41.1.0 firmware
    // constructor, and corroborated here by [RAW_WAVEFORM_START]: the waveform offset OBSERVED on an MG
    // (34) is exactly `RAW_TYPE_OFFSET + R17_SAMPLE_START`, which is what says these two readings of the
    // same record agree.

    /** `inner[1]` — the data revision that makes a record an R17. */
    const val R17_REVISION = 17

    /** Fixed fields occupy `inner[0..25]`; the sample block follows. */
    const val R17_FIXED_LENGTH = 26

    /** First sample byte, `inner[26]`. */
    const val R17_SAMPLE_START = 26

    /** Wire capacity: 100 i16 samples per packet. */
    const val R17_MAX_SAMPLES = 100

    /** `0xffff` at `inner[21..22]` means the variability value is unavailable. */
    const val R17_VARIABILITY_UNAVAILABLE = 0xFFFF

    /** First body byte considered by [realtimeRawBodyNonZeroBytes] — excludes the constant sub-header. */
    const val RAW_BODY_START = 24

    /** First waveform byte. Bytes 24..33 are a constant 5x i16 sub-header that is NOT waveform. */
    const val RAW_WAVEFORM_START = 34

    /** One past the last body byte; the remaining 4 bytes are the frame's CRC32 trailer. */
    const val RAW_BODY_END = 236

    /**
     * Samples one record carries: 101. Load-bearing beyond arithmetic — a fixed sample count per record is
     * exactly the shape that makes autocorrelation manufacture a peak at the record period, so anything
     * estimating a rate from these samples must exclude this lag. See the #194 withdrawal.
     */
    const val SAMPLES_PER_RAW_RECORD = (RAW_BODY_END - RAW_WAVEFORM_START) / 2

    /** Non-zero body bytes above which a record is treated as carrying a waveform rather than baseline. */
    const val RAW_BODY_ACTIVE_NONZERO_BYTES = 20

    /** True for a frame shaped like a REALTIME_RAW_DATA record. Shape only — says nothing about CRC. */
    fun isRealtimeRawRecord(frame: ByteArray): Boolean =
        frame.size == RAW_RECORD_LENGTH &&
            (frame[RAW_TYPE_OFFSET].toInt() and 0xFF) == PacketType.REALTIME_RAW_DATA.rawValue

    /**
     * The record's i16-LE sample series, or null when [frame] is not a REALTIME_RAW_DATA record.
     *
     * Signed two's-complement, little-endian, exactly [SAMPLES_PER_RAW_RECORD] values. Zero samples are
     * returned as zeros and never trimmed: for a research artifact a trailing run of zeros is evidence
     * about the record, not padding to be tidied away.
     */
    fun realtimeRawSamples(frame: ByteArray): IntArray? {
        if (!isRealtimeRawRecord(frame)) return null
        val out = IntArray(SAMPLES_PER_RAW_RECORD)
        var i = RAW_WAVEFORM_START
        var n = 0
        while (i + 1 < RAW_BODY_END) {
            var v = (frame[i].toInt() and 0xFF) or ((frame[i + 1].toInt() and 0xFF) shl 8)
            if (v >= 0x8000) v -= 0x10000
            out[n] = v
            n += 1
            i += 2
        }
        return out
    }

    /** Non-zero bytes in the body region, or null when [frame] is not a REALTIME_RAW_DATA record. */
    fun realtimeRawBodyNonZeroBytes(frame: ByteArray): Int? {
        if (!isRealtimeRawRecord(frame)) return null
        var n = 0
        for (i in RAW_BODY_START until RAW_BODY_END) if (frame[i].toInt() != 0) n += 1
        return n
    }

    /**
     * ONE definition of "this record carries a waveform", so the live view, the command-lab signal line and
     * the reliability scorer cannot disagree about the same record. Null when not such a record.
     *
     * What it cannot tell you: a flat record means the electrode circuit is open OR generation is off. It is
     * a byte-fill observation, never a statement about the wearer.
     */
    fun realtimeRawSignalPresent(frame: ByteArray): Boolean? =
        realtimeRawBodyNonZeroBytes(frame)?.let { it > RAW_BODY_ACTIVE_NONZERO_BYTES }

    // Discovery


    /**
     * The inner record's payload from a complete 5/MG frame, or null when the frame fails the envelope
     * check. Every frame-level entry point goes through here, so no Labrador field is ever read out of
     * an unverified frame.
     *
     * The verdict comes from the ONE central verifier ([Framing.verifyFrame]), not from a second
     * inline copy of the envelope rules: this path used to re-derive them here with looser bounds
     * (`declaredLength >= 4`, no exact-length check), so a truncated frame or one with trailing bytes
     * was accepted here while its Swift twin — which has always delegated to the central verifier —
     * rejected it. Two field logs disagreeing about the same bytes is exactly what the cross-platform
     * contract forbids.
     */
    fun innerPayload(frame: ByteArray, payloadStart: Int = PUFFIN_PAYLOAD_START): List<Int>? {
        if (!Framing.frameCrcOk(frame, DeviceFamily.WHOOP5)) return null
        val declaredLength = (frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)
        val payloadEnd = declaredLength + 8 - 4           // start of the CRC32 trailer
        if (payloadStart < 0 || payloadStart >= payloadEnd) return null
        return (payloadStart until payloadEnd).map { frame[it].toInt() and 0xFF }
    }
}
