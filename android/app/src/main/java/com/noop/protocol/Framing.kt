package com.noop.protocol

/*
 * Frame envelope handling: reassembly of BLE fragments, validation, decode, and command building.
 *
 * Ported from the hardware-verified Swift reference (Framing.swift / Interpreter.swift /
 * PostHooks.swift). The Whoop 4.0 envelope is:
 *
 *   [0]      SOF 0xAA
 *   [1..2]   length u16 LE
 *   [3]      CRC8 over the two length bytes
 *   [4]      packet type
 *   [5]      seq
 *   [6]      cmd / event / meta-type (type-dependent)
 *   [7..]    payload
 *   [len..]  CRC32 (zlib, LE) over frame[4..<length], 4 bytes;  total frame = length + 4
 *
 * The Whoop 5.0 ("puffin") envelope differs (CRC16-Modbus header, inner record at offset 8); it is
 * validated/decoded here for completeness, with biometric field offsets deferred (the inner record
 * is exposed but HR/RR/battery decoding for WHOOP5 is a later milestone, matching the Swift port).
 */

// MARK: - little-endian readers (null when out of range; mirror interpreter._read)
//
// [limit] is the EXCLUSIVE upper bound for a NAMED INNER FIELD (D7): the minimum of where the CRC32
// trailer starts and how many bytes the frame actually has. It is a required argument, not a
// defaulted one, so adding a field read without deciding its bound does not compile. Callers derive
// it with [payloadLimitOf], which never returns more than the frame size, so passing it is at least
// as safe as the old size-only bound and never reads a byte that is not there.

private fun ByteArray.u8(off: Int, limit: Int): Int? =
    if (off >= 0 && off + 1 <= limit) this[off].toInt() and 0xFF else null

private fun ByteArray.u16(off: Int, limit: Int): Int? =
    if (off >= 0 && off + 2 <= limit) (this[off].toInt() and 0xFF) or ((this[off + 1].toInt() and 0xFF) shl 8)
    else null

private fun ByteArray.u32(off: Int, limit: Int): Long? {
    if (off < 0 || off + 4 > limit) return null
    return (this[off].toLong() and 0xFFL) or
        ((this[off + 1].toLong() and 0xFFL) shl 8) or
        ((this[off + 2].toLong() and 0xFFL) shl 16) or
        ((this[off + 3].toLong() and 0xFFL) shl 24)
}

/**
 * The frame's OWN envelope words (declared length, CRC32 trailer) — bounded by the array itself, not
 * by [payloadLimitOf]. These bytes are the envelope, never a decoded inner field, so D7 does not
 * apply to them; keeping them on a separate reader is what stops a field read borrowing the wider
 * bound by accident.
 */
private fun ByteArray.envU32(off: Int): Long? {
    if (off < 0 || off + 4 > size) return null
    return (this[off].toLong() and 0xFFL) or
        ((this[off + 1].toLong() and 0xFFL) shl 8) or
        ((this[off + 2].toLong() and 0xFFL) shl 16) or
        ((this[off + 3].toLong() and 0xFFL) shl 24)
}

/**
 * The exclusive upper bound for reading named inner fields out of [frame] (D7).
 *
 * It is the MINIMUM of the CRC32 trailer's start and the frame's real size — not one or the other.
 * The trailer start follows from the DECLARED length, which on a truncated frame points past the
 * last byte we hold, so using it alone would read off the end of the array; using only the frame
 * size is what let a frame at the family minimum have its own checksum trailer decoded as a
 * sequence number, a command byte or a metadata type. A field counts as present when its start plus
 * its length does not EXCEED this bound: the smallest real WHOOP 4.0 history frame is 11 bytes with
 * its trailer at 7, and its metadata type occupies precisely the last payload byte.
 */
private fun payloadLimitOf(frame: ByteArray, trailerStart: Int?): Int {
    if (trailerStart == null) return frame.size
    return minOf(maxOf(0, trailerStart), frame.size)
}

/**
 * Accumulate BLE notification fragments into complete frames.
 *
 * A complete frame is `length + 4` bytes where `length` = u16 LE at buf[1..3]. Leading bytes before
 * the 0xAA SOF are discarded. Mirrors framing.py / Swift `Reassembler`.
 */
class Reassembler(private val family: DeviceFamily = DeviceFamily.WHOOP4) {
    // The backing store is a plain ByteArray plus a read cursor, not an ArrayList<Byte>. The old form
    // boxed each incoming byte and drained a completed frame with repeated removeAt(0) calls, every one
    // of which shifts the whole tail down by one slot. Draining a single frame was therefore O(n^2), and
    // the historical offload pushes thousands of ~1.9 KB records across a multi-night sync, so that cost
    // dominated. Here fragments are appended into [data], [head] simply advances past consumed bytes,
    // and the leftover tail is slid back to the front once per feed(). The emitted frames are identical
    // in bytes and order; FramingTest's reassembler vectors hold that contract.
    private var data = ByteArray(0)
    private var head = 0   // index of the first byte not yet consumed
    private var tail = 0   // index one past the last valid byte

    /**
     * How many start-of-frame bytes were dropped because the total length they declared was below
     * the family minimum. Such a byte run never reaches a parser, so without this counter it would
     * vanish without trace — and one of the readers downstream exists to preserve exactly the frames
     * nothing else can read. Monotonic for the lifetime of the reassembler; [reset] leaves it alone.
     */
    var belowMinimumLengthDrops = 0
        private set

    /**
     * Drop any partial-frame remnant. Called on (re)connect so a stalled or garbage frame from one
     * session can't wedge the live stream in the next. The macOS BLEManager achieves the same by
     * reassigning a fresh `Reassembler` on every connect (BLEManager.swift:183).
     */
    fun reset() {
        head = 0
        tail = 0
    }

    /** Feed one fragment; return zero or more complete frames now available, in order. */
    fun feed(fragment: ByteArray): List<ByteArray> {
        append(fragment)
        val out = ArrayList<ByteArray>()
        while (true) {
            val sof = indexOfSof()
            if (sof < 0) {
                // No SOF left in the window: nothing here is salvageable, so drop it all.
                head = 0
                tail = 0
                break
            }
            // Skip any leading bytes ahead of the SOF instead of physically removing them.
            if (sof > head) head = sof
            val avail = tail - head
            if (avail < 4) break
            // Frame length is encoded differently per family: WHOOP4 = u16 @[1..3], total = length + 4;
            // WHOOP5/MG ("puffin") = declaredLength u16 @[2..4], total = declaredLength + 8 (it counts
            // the payload + the 4-byte CRC32 trailer, and has 2 extra header bytes). Using the WHOOP4
            // formula on a 5/MG frame decodes a bogus 6 KB length and the live stream never emits.
            val total: Int = if (family == DeviceFamily.WHOOP5) {
                ((data[head + 2].toInt() and 0xFF) or ((data[head + 3].toInt() and 0xFF) shl 8)) + 8
            } else {
                ((data[head + 1].toInt() and 0xFF) or ((data[head + 2].toInt() and 0xFF) shl 8)) + 4
            }
            if (total < FrameLimits.minimumFrameBytes(family)) {
                // A declared total below the family minimum cannot be a frame: emitting it would hand
                // a parser a byte run whose "inner fields" are its own checksum trailer. Drop this
                // 0xAA, count it, and resync on the next one — same shape as the ceiling below.
                belowMinimumLengthDrops += 1
                head += 1
                continue
            }
            if (total > MAX_FRAME_BYTES) {
                // A corrupt or misaligned SOF decodes an impossibly large length and we'd wait forever
                // for bytes that can never arrive over BLE — the live stream would freeze until a
                // reconnect. The largest real WHOOP frame is ~1920 B, so anything past the 8 KB ceiling
                // is garbage: drop this 0xAA and resync to the next one.
                head += 1
                continue
            }
            if (avail < total) break
            out.add(data.copyOfRange(head, head + total))
            head += total
        }
        compact()
        return out
    }

    /** Index of the first 0xAA at or after [head] in the live window, or -1 if none remain. */
    private fun indexOfSof(): Int {
        var i = head
        while (i < tail) {
            if (data[i] == 0xAA.toByte()) return i
            i++
        }
        return -1
    }

    /** Append a fragment, doubling the backing array when it would otherwise overflow. */
    private fun append(fragment: ByteArray) {
        if (fragment.isEmpty()) return
        if (tail + fragment.size > data.size) {
            var cap = if (data.isEmpty()) 256 else data.size
            while (cap < tail + fragment.size) cap = cap shl 1
            data = data.copyOf(cap)
        }
        System.arraycopy(fragment, 0, data, tail, fragment.size)
        tail += fragment.size
    }

    /**
     * Slide the unconsumed tail back to offset 0 so [head] can't drift forever and the array stays
     * small. compact() runs at the end of every feed(), so [head] is always 0 when the next append()
     * lands. The leftover is at most one in-progress frame (< MAX_FRAME_BYTES), so the move is bounded.
     */
    private fun compact() {
        if (head == 0) return
        val remaining = tail - head
        if (remaining > 0) System.arraycopy(data, head, data, 0, remaining)
        head = 0
        tail = remaining
    }

    private companion object {
        /** ~4× the largest observed WHOOP frame (~1920 B raw/historical); above this is a bad length. */
        const val MAX_FRAME_BYTES = 8192
    }
}

/**
 * Why a frame failed the envelope check — one value, never null, so a consumer can report the cause
 * without verifying or parsing the frame a second time (the parse-once invariant).
 *
 * [NONE] is the ONLY value that accompanies a positive verdict. The two payload-CRC cases are kept
 * apart on purpose: a diagnostic may only assert what it observed, and "we could not compute the
 * CRC32" is not the same claim as "the CRC32 disagreed". Twin of the Swift `FrameRejectReason`,
 * value for value (`none` → [NONE], `noStartOfFrame` → [NO_START_OF_FRAME], … ).
 */
enum class FrameRejectReason {
    /** The frame is intact: header checksum, payload CRC32 and the structural length all agree. */
    NONE,

    /** No 0xAA start-of-frame byte — this byte run is not a frame at all. */
    NO_START_OF_FRAME,

    /** Fewer bytes than the device family's smallest well-formed frame can have. */
    BELOW_MINIMUM_LENGTH,

    /**
     * The byte count does not equal the total derived from the declared length field: the frame is
     * truncated, or it carries trailing bytes past its own end.
     */
    LENGTH_MISMATCH,

    /** The header checksum (CRC-8 on WHOOP 4.0, CRC-16-Modbus on WHOOP 5.0/MG) disagreed. */
    HEADER_CHECKSUM_MISMATCH,

    /** The payload CRC32 was computed and disagreed. */
    PAYLOAD_CRC_MISMATCH,

    /**
     * The payload CRC32 could not be computed at all. Fail-closed: an unverifiable CRC counts as a
     * negative verdict, never as "unknown". The structural rules above make this unreachable for a
     * frame that got past them, so it is defence in depth rather than an observed class.
     */
    PAYLOAD_CRC_UNVERIFIABLE,
}

/**
 * The structural lower bounds a frame must clear before any of its bytes are read as fields.
 *
 * WHOOP 4.0: `[SOF][len u16][crc8][type][seq][cmd] + [crc32 u32]` = 11 bytes. The zero-payload
 * metadata frames at this bound are valid and intentional; the minimum preserves the old `length >= 7` rule.
 * WHOOP 5.0/MG: `[SOF][fmt][declLen u16][hdr u16][crc16 u16] + >=1 payload byte + [crc32 u32]` = 13.
 * The smallest real frame in the project's captures is exactly 11 bytes (WHOOP 4.0) and 124 bytes
 * (WHOOP 5.0/MG), so neither bound rejects a recorded frame. Twin of the Swift `FrameLimits`.
 */
object FrameLimits {
    const val WHOOP4_MINIMUM_FRAME_BYTES = 11
    const val WHOOP5_MINIMUM_FRAME_BYTES = 13

    /** The minimum total frame size for [family], in bytes. */
    fun minimumFrameBytes(family: DeviceFamily): Int = when (family) {
        DeviceFamily.WHOOP4 -> WHOOP4_MINIMUM_FRAME_BYTES
        DeviceFamily.WHOOP5 -> WHOOP5_MINIMUM_FRAME_BYTES
    }
}

/**
 * Turn the individual outcomes into ONE verdict and ONE reason, in a fixed order: structure first
 * (a length we cannot trust makes every later read meaningless), then the header checksum, then the
 * payload CRC32. A null [crc32Ok] is a rejection, not an "unknown" that a consumer might read as a
 * pass — that tri-state is exactly what let malformed frames drive live state before this change.
 */
private fun frameRejectReason(
    totalFromLength: Int,
    actualCount: Int,
    minimumBytes: Int,
    headerCrcOk: Boolean,
    crc32Ok: Boolean?,
): FrameRejectReason {
    if (totalFromLength < minimumBytes) return FrameRejectReason.BELOW_MINIMUM_LENGTH
    if (totalFromLength != actualCount) return FrameRejectReason.LENGTH_MISMATCH
    if (!headerCrcOk) return FrameRejectReason.HEADER_CHECKSUM_MISMATCH
    return when (crc32Ok) {
        null -> FrameRejectReason.PAYLOAD_CRC_UNVERIFIABLE
        false -> FrameRejectReason.PAYLOAD_CRC_MISMATCH
        true -> FrameRejectReason.NONE
    }
}

/**
 * Outcome of validating a frame envelope and its CRCs.
 *
 * [ok] is the FULL verdict: start-of-frame, minimum length, exact length, header checksum and
 * payload CRC32 together. It is true exactly when [reason] is [FrameRejectReason.NONE]. The
 * individual outcomes stay on the result as diagnostics.
 */
data class FrameCheck(
    val ok: Boolean,
    val length: Int? = null,
    val headerCrcOk: Boolean? = null,
    val crc32Ok: Boolean? = null,
    val reason: FrameRejectReason = FrameRejectReason.NONE,
)

object Framing {

    // MARK: - validation

    /**
     * Validate a complete Whoop 4.0 frame envelope: structure, header checksum and payload CRC32.
     * Frame: [0xAA][len u16 LE][crc8(len)][...inner...][crc32 u32 LE], total = len + 4.
     *
     * A frame is accepted only when it is at least [FrameLimits.WHOOP4_MINIMUM_FRAME_BYTES] long,
     * carries EXACTLY `len + 4` bytes (so a truncated frame and one with trailing bytes are both
     * rejected), its CRC-8 over the length field matches, and its CRC32 over the inner record
     * matches. `reason` says which rule failed first.
     */
    private fun verifyWhoop4(frame: ByteArray): FrameCheck {
        if (frame.isEmpty() || frame[0] != 0xAA.toByte()) {
            return FrameCheck(ok = false, reason = FrameRejectReason.NO_START_OF_FRAME)
        }
        if (frame.size < FrameLimits.WHOOP4_MINIMUM_FRAME_BYTES) {
            // Too short even to hold an envelope plus one payload byte: no field of it is read, and
            // the length word it may carry is not worth reporting as a length.
            return FrameCheck(ok = false, reason = FrameRejectReason.BELOW_MINIMUM_LENGTH)
        }
        val length = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
        val total = length + 4
        // Ranged CRC checksums the two length bytes in place, with no per-frame allocation.
        val headerOk = Crc.crc8(frame, 1, 3) == (frame[3].toInt() and 0xFF)
        var crc32Ok: Boolean? = null
        // length must cover at least the envelope's inner bytes (mirrors framing.py). Trailing bytes
        // do not stop the CRC32 from being computed — that combination (payload CRC right, envelope
        // wrong) is precisely the class this change stops admitting, so it must stay observable.
        if (length >= 7 && total <= frame.size) {
            // inner record = frame[4 until length], checksummed in place.
            val want = Crc.crc32(frame, 4, length)
            val got = frame.envU32(length) ?: 0L
            crc32Ok = want == got
        }
        val reason = frameRejectReason(
            totalFromLength = total,
            actualCount = frame.size,
            minimumBytes = FrameLimits.WHOOP4_MINIMUM_FRAME_BYTES,
            headerCrcOk = headerOk,
            crc32Ok = crc32Ok,
        )
        return FrameCheck(
            ok = reason == FrameRejectReason.NONE,
            length = length,
            headerCrcOk = headerOk,
            crc32Ok = crc32Ok,
            reason = reason,
        )
    }

    /*
     * Validate a Whoop 5.0 frame:
     *   [0] 0xAA [1] format [2..3] declaredLength u16 LE [4..5] header
     *   [6..7] CRC16-Modbus over frame[0..<6] LE  [8..] payload   tail CRC32 LE over payload
     *   total = declaredLength + 8 (declaredLength counts payload + the 4-byte CRC32 trailer).
     */
    private fun verifyWhoop5(frame: ByteArray): FrameCheck {
        if (frame.isEmpty() || frame[0] != 0xAA.toByte()) {
            return FrameCheck(ok = false, reason = FrameRejectReason.NO_START_OF_FRAME)
        }
        // Smallest well-formed whoop5 frame: 8 header bytes (incl. CRC16) + 1 payload byte + 4 CRC32.
        if (frame.size < FrameLimits.WHOOP5_MINIMUM_FRAME_BYTES) {
            return FrameCheck(ok = false, reason = FrameRejectReason.BELOW_MINIMUM_LENGTH)
        }
        val declaredLength = (frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)
        val total = declaredLength + 8

        // Ranged CRC over the first 6 header bytes in place, with no copyOfRange.
        val wantHeader = Crc.crc16Modbus(frame, 0, 6)
        val gotHeader = (frame[6].toInt() and 0xFF) or ((frame[7].toInt() and 0xFF) shl 8)
        val headerOk = wantHeader == gotHeader

        var crc32Ok: Boolean? = null
        if (declaredLength >= 4 && total <= frame.size) {
            val payloadEnd = total - 4
            // payload = frame[8 until payloadEnd], checksummed in place.
            val want = Crc.crc32(frame, 8, payloadEnd)
            val got = frame.envU32(payloadEnd) ?: 0L
            crc32Ok = want == got
        }
        val reason = frameRejectReason(
            totalFromLength = total,
            actualCount = frame.size,
            minimumBytes = FrameLimits.WHOOP5_MINIMUM_FRAME_BYTES,
            headerCrcOk = headerOk,
            crc32Ok = crc32Ok,
        )
        return FrameCheck(
            ok = reason == FrameRejectReason.NONE,
            length = declaredLength,
            headerCrcOk = headerOk,
            crc32Ok = crc32Ok,
            reason = reason,
        )
    }

    /**
     * Family-aware frame validation — the ONE decision point. Kotlin twin of Swift's
     * `verifyFrame(_:family:)`: structure (minimum length, then exact length), header checksum,
     * then payload CRC32, with a non-null [FrameCheck.reason] saying which rule failed first.
     */
    fun verifyFrame(frame: ByteArray, family: DeviceFamily): FrameCheck =
        when (family) {
            DeviceFamily.WHOOP4 -> verifyWhoop4(frame)
            DeviceFamily.WHOOP5 -> verifyWhoop5(frame)
        }

    /**
     * Family-aware envelope + CRC check — true only when the envelope, the structural length and BOTH
     * CRCs verify. The Kotlin twin of Swift's `verifyFrame(_:family:).ok`. Exposed so a decoder
     * outside this object can gate a frame before reading any field (the BLE safety contract's "bad
     * bytes never drive state"); [parseFrame] uses the same validator internally.
     */
    fun frameCrcOk(frame: ByteArray, family: DeviceFamily): Boolean = verifyFrame(frame, family).ok

    /**
     * The D7 bound for reading named inner fields out of [frame] — the minimum of the CRC32
     * trailer's start (derived from the DECLARED length) and the frame's real size. Internal so the
     * historical record decoders, which read their fields outside this object, bound them exactly as
     * the envelope decoders here do.
     */
    internal fun payloadLimit(frame: ByteArray, family: DeviceFamily): Int {
        val trailerStart: Int? = when (family) {
            // WHOOP 4.0: the CRC32 trailer starts at the declared length.
            DeviceFamily.WHOOP4 ->
                if (frame.size >= 3) (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8) else null
            // WHOOP 5.0/MG: total = declaredLength + 8, and the trailer is the last 4 of those.
            DeviceFamily.WHOOP5 ->
                if (frame.size >= 4) ((frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)) + 4 else null
        }
        return payloadLimitOf(frame, trailerStart)
    }

    // MARK: - type / enum naming

    /**
     * Canonical packet-type name, aliasing the Whoop 5.0 "puffin" types onto their base names: the enum
     * name, or `type<N>` for a byte nothing names, exactly as Swift's `canonicalTypeName` does.
     *
     * Internal rather than private since #891 — the unhandled-packet-type census in `HistoricalStreams`
     * renders through this so the two platforms report the same string for the same byte, instead of
     * keeping a second copy of the rules that could drift.
     */
    internal fun typeName(t: Int): String = when (t) {
        PuffinPacketType.PUFFIN_COMMAND_RESPONSE -> "COMMAND_RESPONSE"
        PuffinPacketType.PUFFIN_METADATA -> "METADATA"
        else -> PacketType.fromRaw(t)?.name ?: "type$t"
    }

    /** "NAME(raw)" for a known enum value, else "0xHH(raw)" — matches Swift `Schema.enumName`. */
    private fun eventLabel(v: Int): String =
        EventNumber.fromRaw(v)?.let { "${it.name}($v)" } ?: hexLabel(v)

    private fun metaLabel(v: Int): String =
        MetadataType.fromRaw(v)?.let { "${it.name}($v)" } ?: hexLabel(v)

    // Labels from the schema-mirroring [CommandNames] table, NOT from the CommandNumber sender enum:
    // the sender enum is deliberately curated down to safe opcodes, so labelling from it left 46 of the
    // schema's 80 commands rendering as bare hex on Android while Apple named them, and printed a
    // different name than Apple for 77/119/120. Read path only; naming an opcode does not make it
    // sendable. (#891)
    private fun commandLabel(v: Int): String = CommandNames.label(v)

    /** COMMAND_RESPONSE result codes, on both families. 3=UNSUPPORTED matches our own MG haptics-rejection
     *  capture (#48); 2=PENDING precedes SUCCESS on GET_DATA_RANGE (hardware-confirmed, #78 fork). The same
     *  codes appear on a 4.0 at payload[1] — 0x01 on an answered GET_DATA_RANGE, 0x00 on an empty
     *  extended-battery reply (#791 captures). */
    private fun commandResultLabel(v: Int): String = when (v) {
        0 -> "FAILURE(0)"
        1 -> "SUCCESS(1)"
        2 -> "PENDING(2)"
        3 -> "UNSUPPORTED(3)"
        else -> hexLabel(v)
    }

    private fun hexLabel(v: Int): String = "0x%02X(%d)".format(v, v)

    // MARK: - parse

    /**
     * Decode a complete frame for the given [family]. Returns [ParsedFrame] with `ok`/`crcOk`,
     * the canonical `typeName`, and a flat `parsed` map of decoded fields.
     */
    fun parseFrame(frame: ByteArray, family: DeviceFamily = DeviceFamily.WHOOP4): ParsedFrame =
        when (family) {
            DeviceFamily.WHOOP4 -> parseWhoop4(frame)
            DeviceFamily.WHOOP5 -> parseWhoop5(frame)
        }

    private fun parseWhoop4(frame: ByteArray): ParsedFrame {
        val check = verifyWhoop4(frame)
        // Below the family minimum there is no inner record at all — every offset a field would use
        // lands in the checksum trailer — so nothing is decoded, not even a packet type.
        if (frame.size < FrameLimits.WHOOP4_MINIMUM_FRAME_BYTES || frame[0] != 0xAA.toByte()) {
            return ParsedFrame.invalid(check.reason)
        }

        val length = check.length
        val crcOk = check.crc32Ok
        // D7: named inner fields come only from payload bytes. On WHOOP 4.0 the CRC32 trailer starts
        // at the declared length.
        val limit = payloadLimitOf(frame, length)

        val t = frame[4].toInt() and 0xFF
        val name = typeName(t)
        val parsed = LinkedHashMap<String, Any?>()

        when (name) {
            "REALTIME_DATA" -> decodeRealtime(frame, limit, parsed)
            "EVENT" -> decodeEvent(frame, limit, parsed)
            "COMMAND_RESPONSE" -> decodeCommandResponse(frame, limit, parsed)
            "METADATA" -> decodeMetadata(frame, limit, parsed)
            else -> Unit
        }

        // `ok` is the verifier's full verdict, not a constant: the fields above stay decoded so an
        // inspector can still read a broken frame, but no consumer may mistake that for integrity.
        return ParsedFrame(
            ok = check.ok, crcOk = crcOk, typeName = name, parsed = parsed,
            rejectReason = check.reason,
        )
    }

    private fun parseWhoop5(frame: ByteArray): ParsedFrame {
        val check = verifyWhoop5(frame)
        // Minimum whoop5 frame: 8 header bytes + 1 payload byte + 4 CRC32 trailer. Below that, the
        // type byte at [8] would be the first byte of the frame's own CRC32 trailer.
        if (frame.size < FrameLimits.WHOOP5_MINIMUM_FRAME_BYTES || frame[0] != 0xAA.toByte()) {
            return ParsedFrame.invalid(check.reason)
        }
        val innerStart = 8
        // D7: bounded by the trailer AND the real size — total = declaredLength + 8, trailer = last 4.
        val limit = payloadLimitOf(frame, check.length?.let { it + 4 })
        val t = frame[innerStart].toInt() and 0xFF
        val name = typeName(t)
        val parsed = LinkedHashMap<String, Any?>()
        // WHOOP 5.0 field offsets are the 4.0 layout shifted by +4 (inner record starts at byte 8 vs 4).
        // REALTIME_DATA is hardware-verified at +4 (HR matched the 0x2A37 profile to ~0.4 bpm over 96
        // worn frames; see the Swift Whoop5RealtimeTests vector). Other types stay envelope-only until
        // their per-type 5.0 offsets are confirmed on hardware — we don't invent offsets.
        when (name) {
            "REALTIME_DATA" -> decodeRealtimeWhoop5(frame, limit, parsed)
            "METADATA" -> decodeMetadataWhoop5(frame, limit, parsed)
            "EVENT" -> decodeEventWhoop5(frame, limit, parsed)
            "COMMAND_RESPONSE" -> decodeCommandResponseWhoop5(frame, limit, parsed)
            // WHOOP 5/MG ONLY, and that is a gap rather than a decision. Swift decodes the 4.0 console
            // layout too (`PostHooks`, offsets 11..len-1, pinned by a test on real 4.0 text), so after the
            // Apple consumer was wired up a WHOOP 4.0 narrates into an iOS strap log and stays silent in an
            // Android one — the same defect this fixed on Apple, mirrored onto the other strap. Left for a
            // follow-up rather than smuggled in here: it needs the 4.0 offsets and its own vector, and this
            // change is already about a key three implementations disagreed on.
            "CONSOLE_LOGS" -> decodeConsoleLogsWhoop5(frame, limit, parsed)
            else -> Unit
        }
        return ParsedFrame(
            ok = check.ok, crcOk = check.crc32Ok, typeName = name, parsed = parsed,
            rejectReason = check.reason,
        )
    }

    /**
     * EVENT (type 48) for WHOOP 5.0/MG — the 4.0 layout + 4: event@10 (u8, EventNumber),
     * event_timestamp@12 (u32), opaque payload bytes @16..size-4 (kept as hex for protocol research —
     * real captures show uncatalogued events, e.g. 0x1D(29) with a 16-byte payload). For
     * BATTERY_LEVEL the 4.0 payload decode shifts with it: soc%=u16@21/10, mV=u16@25, charging@30
     * bit0 (mirrors Swift Interpreter's whoop5 event decode; all gated, fail closed). (#78 fork)
     */
    private fun decodeEventWhoop5(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        val evVal = frame.u8(10, limit) ?: return
        parsed["event"] = eventLabel(evVal)
        frame.u32(12, limit)?.let { parsed["event_timestamp"] = it.toInt() }
        if (limit > 16) {
            parsed["event_payload_hex"] = frame.copyOfRange(16, limit)
                .joinToString("") { "%02x".format(it) }
        }
        if (EventNumber.fromRaw(evVal) == EventNumber.BATTERY_LEVEL) {
            frame.u16(21, limit)?.let { raw -> if (raw <= 1100) parsed["battery_pct"] = raw.toDouble() / 10.0 }
            frame.u16(25, limit)?.let { mv -> if (mv in 3000..4300) parsed["battery_mV"] = mv }
            frame.u8(30, limit)?.let { ch -> if (ch <= 1) parsed["battery_charging"] = ch and 1 }
        }
    }

    /**
     * COMMAND_RESPONSE (puffin type 36 alias) for WHOOP 5.0/MG: resp_cmd@10 (u8, CommandNumber),
     * resp_seq@11 (u8), result@12 (u8 → FAILURE/SUCCESS/PENDING/UNSUPPORTED). GET_DATA_RANGE
     * typically answers PENDING then SUCCESS; the result codes are hardware-confirmed (#78 fork,
     * and 3=UNSUPPORTED matches our own MG haptics rejection, #48). GET_BATTERY_LEVEL carries a
     * direct percent at @13 (gated ≤100, fail closed; Swift parity — unused until the 5/MG
     * allowlist grows).
     */
    private fun decodeCommandResponseWhoop5(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        val cmd = frame.u8(10, limit) ?: return
        parsed["resp_cmd"] = commandLabel(cmd)
        frame.u8(11, limit)?.let { parsed["resp_seq"] = it }
        frame.u8(12, limit)?.let { parsed["result"] = commandResultLabel(it) }
        if (CommandNumber.fromRaw(cmd) == CommandNumber.GET_BATTERY_LEVEL) {
            frame.u8(13, limit)?.let { pct -> if (pct <= 100) parsed["battery_pct"] = pct.toDouble() }
        }
        // GET_HELLO (145): device name + firmware version. Mirrors the Swift Interpreter decode of the
        // same 50.38.1.0 capture: payload base is frame[11]; the name is printable ASCII at pay[16],
        // the firmware is 4 bytes at pay[93] gated on pay[93]==50 (the "5.x" generation). The session
        // token in the same block is deliberately never read. Surfaced on the Devices card.
        if (cmd == 145) {
            val payEnd = limit // payload only: stops where the CRC32 trailer starts (D7)
            if (payEnd > 11) {
                val pay = frame.copyOfRange(11, payEnd)
                val name = StringBuilder()
                var i = 16
                while (i < pay.size && pay[i].toInt() != 0 &&
                    (pay[i].toInt() and 0xFF) in 32..126 && name.length < 24
                ) {
                    name.append((pay[i].toInt() and 0xFF).toChar()); i++
                }
                if (name.length >= 6) parsed["device_name"] = name.toString()
                if (pay.size >= 97 && (pay[93].toInt() and 0xFF) == 50) {
                    parsed["fw_version"] = "${pay[93].toInt() and 0xFF}.${pay[94].toInt() and 0xFF}." +
                        "${pay[95].toInt() and 0xFF}.${pay[96].toInt() and 0xFF}"
                } else {
                    // The guards fail closed by design, which left a strap reporting no firmware with no way to
                    // say WHY - a different generation byte and a MOVED offset look identical from a log. Carry
                    // the evidence instead; see [firmwareGateDiagnostic].
                    parsed["fw_gate"] = firmwareGateDiagnostic(pay, i)
                }
            }
        }
    }

    /**
     * CONSOLE_LOGS (type 50) for WHOOP 5.0/MG: 13-byte record header after the inner type byte,
     * then UTF-8 console text @21..size-4 with an optional NUL terminator. The strap's own
     * diagnostics channel — it narrates history syncs ("BLE: PullStats: Data: N, Events: N…",
     * "RTC timestamp … is invalid; not saving data to flash"), which is how the clock-before-history
     * requirement was discovered. Capped at 2 KB (matches the Swift PostHooks console hardening).
     *
     * The record header carries record_index u16@9 (monotonic per-chunk counter — the console is
     * one continuous stream chunked into fixed-size pieces, and lines split mid-sentence across
     * frames, so consumers reassemble in record_index order), unix u32@12 and subsec u16@16 (batch
     * write time). Offsets verified across 3 257 real frames from two nights (all one shape:
     * 76-byte frame, chunk_len u16@18 = 52, channel u8@20 = 1); the Swift twin is
     * `decodeWhoop5ConsoleLogs` in Interpreter.swift (its text key is "log").
     * (#78 fork, real-frame verified)
     */
    private fun decodeConsoleLogsWhoop5(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        frame.u16(9, limit)?.let { parsed["record_index"] = it }
        frame.u32(12, limit)?.let { parsed["unix"] = it.toInt() }
        frame.u16(16, limit)?.let { parsed["subsec"] = it }
        val payEnd = limit // payload only: stops where the CRC32 trailer starts (D7)
        if (payEnd <= 21) return
        val text = frame.copyOfRange(21, payEnd)
            .toString(Charsets.UTF_8)
            .trimEnd('\u0000')
        // Key "log", not "console": the Python reference decoder golden.json is generated from uses
        // "log", and Swift matches it under a parity guard. This side was the odd one out, which is
        // how the Apple consumer ported from here read the wrong key and silently found nothing.
        if (text.isNotEmpty()) parsed["log"] = text.take(2048)
    }

    /**
     * METADATA (PUFFIN_METADATA, type 56) for WHOOP 5.0/MG — the 4.0 METADATA layout + 4 (the inner
     * record starts at byte 8 vs 4): meta_type@10 (u8), and for a HISTORY_END additionally unix@11
     * (u32), subsec@15 (u16), trim_cursor@21 (u32). Without this, parseWhoop5 left every 5/MG METADATA
     * frame field-less, so classifyHistoricalMeta could never recognise HISTORY_END/COMPLETE → the
     * Backfiller never acked/trimmed → 5/MG offload never completed. Offsets verified against real
     * WHOOP 5 HISTORY_END frames (Swift decodeWhoop5Metadata, Interpreter.swift:407). (#78)
     */
    private fun decodeMetadataWhoop5(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        val mt = frame.u8(10, limit) ?: return
        parsed["meta_type"] = metaLabel(mt)
        // Only a HISTORY_END carries unix/subsec/trim; the u-reads null out on the shorter
        // START/COMPLETE frames, so classifyHistoricalMeta keys those off meta_type alone.
        frame.u32(11, limit)?.let { parsed["unix"] = it.toInt() }
        frame.u16(15, limit)?.let { parsed["subsec"] = it }
        frame.u32(21, limit)?.let { parsed["trim_cursor"] = it.toInt() }
    }

    /**
     * REALTIME_DATA (type 40) for WHOOP 5.0 — the 4.0 layout + 4: timestamp@10 (u32),
     * subseconds@14 (u16), heart_rate@16 (u8), rr_count@17, rr@18.. (u16). Mirrors the Swift
     * parseFrameWhoop5 realtime decode and is covered by the same real-frame test vector.
     */
    private fun decodeRealtimeWhoop5(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        frame.u32(10, limit)?.let { parsed["timestamp"] = it.toInt() }
        frame.u16(14, limit)?.let { parsed["subseconds"] = it }
        frame.u8(16, limit)?.let { parsed["heart_rate"] = it }
        val rrn = frame.u8(17, limit) ?: 0
        parsed["rr_count"] = rrn
        val rrs = ArrayList<Int>()
        val rawTicks = ArrayList<Int>()
        for (i in 0 until rrn) {
            if (18 + i * 2 + 2 > limit) break
            val v = frame.u16(18 + i * 2, limit)
            if (v != null && v > 0) {
                rawTicks.add(v)
                rrs.add(Whoop5RR.milliseconds(v))
            }
        }
        parsed["rr_intervals"] = rrs
        parsed["rr_raw_ticks"] = rawTicks
        parsed["rr_source_channel"] = RrSourceChannel.WHOOP5_REALTIME.code
    }

    // MARK: - per-type decoders (Whoop 4.0). Ported from PostHooks.swift + the static field specs.

    /** REALTIME_DATA (type 40): timestamp@6 (u32), heart_rate@12 (u8), rr_count@13, rr@14.. (u16). */
    private fun decodeRealtime(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        frame.u32(6, limit)?.let { parsed["timestamp"] = it.toInt() }
        frame.u16(10, limit)?.let { parsed["subseconds"] = it }
        frame.u8(12, limit)?.let { parsed["heart_rate"] = it }
        val rrn = frame.u8(13, limit) ?: 0
        parsed["rr_count"] = rrn
        val rrs = ArrayList<Int>()
        for (i in 0 until rrn) {
            // Drop 0 ms intervals (placeholders, not beat-to-beat intervals), matching Swift.
            val v = frame.u16(14 + i * 2, limit)
            if (v != null && v > 0) rrs.add(v)
        }
        parsed["rr_intervals"] = rrs
    }

    /**
     * EVENT (type 48): event@6 (u8, EventNumber), event_timestamp@8 (u32).
     * For BATTERY_LEVEL, additionally decode soc@17(/10), mV@21, charging@26 bit0.
     */
    private fun decodeEvent(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        val evVal = frame.u8(6, limit) ?: return
        parsed["event"] = eventLabel(evVal)
        frame.u32(8, limit)?.let { parsed["event_timestamp"] = it.toInt() }

        if (EventNumber.fromRaw(evVal) == EventNumber.BATTERY_LEVEL) {
            // Fixed layout, empirically verified against captured frames:
            //   soc% = u16@17/10 · mV = u16@21 · charging = u8@26 bit0
            frame.u16(17, limit)?.let { raw -> if (raw <= 1100) parsed["battery_pct"] = raw.toDouble() / 10.0 }
            frame.u16(21, limit)?.let { mv -> if (mv in 3000..4300) parsed["battery_mV"] = mv }
            frame.u8(26, limit)?.let { ch -> if (ch <= 1) parsed["battery_charging"] = ch and 1 }
        }
    }

    /**
     * COMMAND_RESPONSE (type 36): resp_cmd@6 (u8, CommandNumber). Decodes the battery level reply.
     * Payload begins at offset 7; GET_BATTERY_LEVEL stores soc% = u16(payload[2..4]) / 10.
     */
    private fun decodeCommandResponse(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        val payEnd = limit // payload only: stops where the CRC32 trailer starts (D7)
        if (payEnd < 7) return
        val pay = frame.copyOfRange(7, payEnd)
        val cmd = frame.u8(6, limit) ?: return
        parsed["resp_cmd"] = commandLabel(cmd)
        // #791: the origin-seq echo and the result code, which the 5/MG path has always exposed (at @11/@12)
        // and this one never did. Without them a 4.0 strap log cannot say whether a command SUCCEEDED or
        // FAILED — a reporter had to hand-decode `result=0x00` from raw hex to discover that their strap was
        // answering GET_EXTENDED_BATTERY_INFO with FAILURE rather than an empty success.
        //
        // Grounded in real 4.0 captures, not inferred: an answered GET_DATA_RANGE carries pay[1] = 0x01
        // (SUCCESS) and the empty extended-battery reply carries 0x00 (FAILURE), and the GET_BATTERY_LEVEL
        // decode below has always read its value from payload[2..4] — already skipping these two bytes.
        //
        // The echo also makes a duplicated write self-evident: the same resp_seq arriving two or three times
        // for one send is the #791 write-queue bug, visible in a log instead of needing frame archaeology.
        if (pay.isNotEmpty()) parsed["resp_seq"] = pay[0].toInt() and 0xFF
        if (pay.size >= 2) parsed["result"] = commandResultLabel(pay[1].toInt() and 0xFF)
        when (CommandNumber.fromRaw(cmd)) {
            CommandNumber.GET_BATTERY_LEVEL -> {
                if (pay.size >= 4) {
                    val v = (pay[2].toInt() and 0xFF) or ((pay[3].toInt() and 0xFF) shl 8)
                    parsed["battery_pct"] = v.toDouble() / 10.0
                }
            }
            CommandNumber.GET_CLOCK -> {
                if (pay.size >= 6) {
                    val v = (pay[2].toLong() and 0xFFL) or
                        ((pay[3].toLong() and 0xFFL) shl 8) or
                        ((pay[4].toLong() and 0xFFL) shl 16) or
                        ((pay[5].toLong() and 0xFFL) shl 24)
                    parsed["clock"] = v.toInt()
                }
            }
            CommandNumber.REPORT_VERSION_INFO -> {
                // WHOOP 4.0 firmware version (the main "Harvard" MCU): four little-endian u32 at
                // pay[3,7,11,15]. Same base/offsets as the Swift PostHooks fw_harvard decode (pay also
                // starts at frame[7] there). Surfaced on the Devices card.
                if (pay.size >= 19) {
                    fun le32(at: Int): Long = (pay[at].toLong() and 0xFFL) or
                        ((pay[at + 1].toLong() and 0xFFL) shl 8) or
                        ((pay[at + 2].toLong() and 0xFFL) shl 16) or
                        ((pay[at + 3].toLong() and 0xFFL) shl 24)
                    parsed["fw_harvard"] = "${le32(3)}.${le32(7)}.${le32(11)}.${le32(15)}"
                }
            }
            else -> Unit
        }
    }

    /**
     * METADATA (type 49): meta_type@6 (u8, MetadataType). For a 14-byte payload ('<LHLL'):
     * unix@7 (u32), subsec@11 (u16), unk0@13 (u32), trim_cursor@17 (u32).
     */
    private fun decodeMetadata(frame: ByteArray, limit: Int, parsed: MutableMap<String, Any?>) {
        val mt = frame.u8(6, limit) ?: return
        parsed["meta_type"] = metaLabel(mt)
        val payEnd = limit // payload only: stops where the CRC32 trailer starts (D7)
        if (payEnd <= 7) return
        val pay = frame.copyOfRange(7, payEnd)
        if (pay.size >= 14) {
            val unix = (pay[0].toLong() and 0xFFL) or ((pay[1].toLong() and 0xFFL) shl 8) or
                ((pay[2].toLong() and 0xFFL) shl 16) or ((pay[3].toLong() and 0xFFL) shl 24)
            val ss = (pay[4].toInt() and 0xFF) or ((pay[5].toInt() and 0xFF) shl 8)
            val trim = (pay[10].toLong() and 0xFFL) or ((pay[11].toLong() and 0xFFL) shl 8) or
                ((pay[12].toLong() and 0xFFL) shl 16) or ((pay[13].toLong() and 0xFFL) shl 24)
            parsed["unix"] = unix.toInt()
            parsed["subsec"] = ss
            parsed["trim_cursor"] = trim.toInt()
        }
    }

    // MARK: - command building

    /**
     * Build a complete, framed COMMAND packet ready to write to the command characteristic.
     *
     * Layout (verified against the device): `[0xAA][len u16 LE][crc8(len)][type=35][seq][cmd][payload][crc32 LE]`
     *  - `len`  = (3 + payload.size) + 4  (inner type+seq+cmd+payload, plus the 4 envelope bytes)
     *  - `crc8` is over the two length bytes only
     *  - `crc32` (zlib) is over the inner `[type][seq][cmd][payload]`, stored little-endian
     */
    fun buildCommand(cmd: CommandNumber, payload: ByteArray = byteArrayOf(0), seq: Int = 0): ByteArray {
        val inner = ByteArray(3 + payload.size)
        inner[0] = PacketType.COMMAND.rawValue.toByte()     // type = 35
        inner[1] = (seq and 0xFF).toByte()
        inner[2] = (cmd.rawValue and 0xFF).toByte()
        System.arraycopy(payload, 0, inner, 3, payload.size)

        val length = inner.size + 4
        val lenLo = (length and 0xFF).toByte()
        val lenHi = ((length ushr 8) and 0xFF).toByte()
        val headerCrc = Crc.crc8(byteArrayOf(lenLo, lenHi)).toByte()
        val trailer = Crc.crc32(inner)

        val frame = ByteArray(1 + 2 + 1 + inner.size + 4)
        var i = 0
        frame[i++] = 0xAA.toByte()
        frame[i++] = lenLo
        frame[i++] = lenHi
        frame[i++] = headerCrc
        System.arraycopy(inner, 0, frame, i, inner.size)
        i += inner.size
        frame[i++] = (trailer and 0xFFL).toByte()
        frame[i++] = ((trailer ushr 8) and 0xFFL).toByte()
        frame[i++] = ((trailer ushr 16) and 0xFFL).toByte()
        frame[i] = ((trailer ushr 24) and 0xFFL).toByte()
        return frame
    }

    /**
     * EXPERIMENTAL: build a WHOOP 5.0/MG ("puffin") command frame in the CRC16 envelope.
     *
     * Direct port of the Swift `puffinCommandFrame` (WhoopProtocol/Framing.swift). The inner record
     * is `[type][seq][cmd] + payload`; `declLen = inner.size + 4` (the CRC32 tail); the CRC16-Modbus
     * covers the first six header bytes. `type` defaults to 35 (COMMAND) and `header` to `[0x00,
     * 0x01]`, mirroring the structure of the only puffin frame we know a real strap accepts (the
     * static CLIENT_HELLO). The returned frame round-trips through `parseFrame(frame, WHOOP5)`.
     *
     * Layout (LE = little-endian):
     *   inner  = [type][seq][cmd] + payload
     *   declLen = inner.size + 4
     *   frame  = [0xAA, 0x01, declLen LE(2), header[0], header[1]]
     *          + crc16Modbus(frame[0..6)) LE(2)
     *          + inner
     *          + crc32(inner) LE(4)
     */
    fun puffinCommandFrame(
        cmd: Int,
        seq: Int,
        payload: ByteArray = byteArrayOf(0x00),
        type: Int = PacketType.COMMAND.rawValue,   // 35
        header: ByteArray = byteArrayOf(0x00, 0x01),
    ): ByteArray {
        val inner0 = ByteArray(3 + payload.size)
        inner0[0] = (type and 0xFF).toByte()
        inner0[1] = (seq and 0xFF).toByte()
        inner0[2] = (cmd and 0xFF).toByte()
        System.arraycopy(payload, 0, inner0, 3, payload.size)
        // Pad the inner record to a 4-byte boundary before length/CRC, exactly as the strap's maverick
        // framing does (pad4). No-op for the 4-aligned commands shipped so far (toggle HR, historical),
        // but REQUIRED for the 12-byte haptics payload (inner 15 -> 16) — otherwise the declared length
        // and CRC32 cover the wrong byte count and the strap rejects the frame (#48).
        val pad = (4 - inner0.size % 4) % 4
        val inner = if (pad == 0) inner0 else inner0 + ByteArray(pad)

        val declLen = inner.size + 4

        // Six-byte header: SOF, format byte, declLen LE(2), header(2). CRC16-Modbus is over these.
        val head = ByteArray(6)
        head[0] = 0xAA.toByte()
        head[1] = 0x01
        head[2] = (declLen and 0xFF).toByte()
        head[3] = ((declLen ushr 8) and 0xFF).toByte()
        head[4] = header[0]
        head[5] = header[1]
        val c16 = Crc.crc16Modbus(head)
        val c32 = Crc.crc32(inner)

        val frame = ByteArray(6 + 2 + inner.size + 4)
        var i = 0
        System.arraycopy(head, 0, frame, i, 6); i += 6
        frame[i++] = (c16 and 0xFF).toByte()
        frame[i++] = ((c16 ushr 8) and 0xFF).toByte()
        System.arraycopy(inner, 0, frame, i, inner.size); i += inner.size
        frame[i++] = (c32 and 0xFFL).toByte()
        frame[i++] = ((c32 ushr 8) and 0xFFL).toByte()
        frame[i++] = ((c32 ushr 16) and 0xFFL).toByte()
        frame[i] = ((c32 ushr 24) and 0xFFL).toByte()
        return frame
    }
}
