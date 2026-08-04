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

private fun ByteArray.u8(off: Int): Int? = if (off + 1 <= size) this[off].toInt() and 0xFF else null

private fun ByteArray.u16(off: Int): Int? =
    if (off + 2 <= size) (this[off].toInt() and 0xFF) or ((this[off + 1].toInt() and 0xFF) shl 8) else null

private fun ByteArray.u32(off: Int): Long? {
    if (off + 4 > size) return null
    return (this[off].toLong() and 0xFFL) or
        ((this[off + 1].toLong() and 0xFFL) shl 8) or
        ((this[off + 2].toLong() and 0xFFL) shl 16) or
        ((this[off + 3].toLong() and 0xFFL) shl 24)
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

/** Outcome of validating a frame envelope and its CRCs. */
private data class FrameCheck(
    val ok: Boolean,
    val length: Int? = null,
    val headerCrcOk: Boolean? = null,
    val crc32Ok: Boolean? = null,
)

object Framing {

    // MARK: - validation

    /**
     * Validate a complete Whoop 4.0 frame envelope and both CRCs.
     * Frame: [0xAA][len u16 LE][crc8(len)][...inner...][crc32 u32 LE], total = len + 4.
     */
    private fun verifyWhoop4(frame: ByteArray): FrameCheck {
        if (frame.size < 8 || frame[0] != 0xAA.toByte()) return FrameCheck(ok = false)
        val length = (frame[1].toInt() and 0xFF) or ((frame[2].toInt() and 0xFF) shl 8)
        // Ranged CRC checksums the two length bytes in place, with no per-frame allocation.
        val headerOk = Crc.crc8(frame, 1, 3) == (frame[3].toInt() and 0xFF)
        var crc32Ok: Boolean? = null
        // length must cover at least the envelope's inner bytes (mirrors framing.py).
        if (length in 7..(frame.size - 4)) {
            // inner record = frame[4 until length], checksummed in place.
            val want = Crc.crc32(frame, 4, length)
            val got = frame.u32(length) ?: 0L
            crc32Ok = want == got
        }
        return FrameCheck(ok = headerOk && (crc32Ok == true), length = length, headerCrcOk = headerOk, crc32Ok = crc32Ok)
    }

    /*
     * Validate a Whoop 5.0 frame:
     *   [0] 0xAA [1] format [2..3] declaredLength u16 LE [4..5] header
     *   [6..7] CRC16-Modbus over frame[0..<6] LE  [8..] payload   tail CRC32 LE over payload
     *   total = declaredLength + 8 (declaredLength counts payload + the 4-byte CRC32 trailer).
     */
    private fun verifyWhoop5(frame: ByteArray): FrameCheck {
        if (frame.size < 12 || frame[0] != 0xAA.toByte()) return FrameCheck(ok = false)
        val declaredLength = (frame[2].toInt() and 0xFF) or ((frame[3].toInt() and 0xFF) shl 8)
        if (declaredLength < 4) return FrameCheck(ok = false, length = declaredLength)
        val total = declaredLength + 8

        // Ranged CRC over the first 6 header bytes in place, with no copyOfRange.
        val wantHeader = Crc.crc16Modbus(frame, 0, 6)
        val gotHeader = (frame[6].toInt() and 0xFF) or ((frame[7].toInt() and 0xFF) shl 8)
        val headerOk = wantHeader == gotHeader

        var crc32Ok: Boolean? = null
        if (frame.size >= total) {
            val payloadEnd = total - 4
            // payload = frame[8 until payloadEnd], checksummed in place.
            val want = Crc.crc32(frame, 8, payloadEnd)
            val got = frame.u32(payloadEnd) ?: 0L
            crc32Ok = want == got
        }
        return FrameCheck(ok = headerOk && (crc32Ok == true), length = declaredLength, headerCrcOk = headerOk, crc32Ok = crc32Ok)
    }

    /**
     * Family-aware envelope + CRC check — true only when the envelope and BOTH CRCs verify. The Kotlin
     * twin of Swift's `verifyFrame(_:family:).ok`. Exposed so a decoder outside this object can CRC-gate
     * a frame before reading any field (the BLE safety contract's "bad bytes never drive state");
     * [parseFrame] uses the same two private validators internally.
     */
    fun frameCrcOk(frame: ByteArray, family: DeviceFamily): Boolean =
        when (family) {
            DeviceFamily.WHOOP4 -> verifyWhoop4(frame).ok
            DeviceFamily.WHOOP5 -> verifyWhoop5(frame).ok
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
        if (frame.size < 8 || frame[0] != 0xAA.toByte()) return ParsedFrame.invalid()

        val check = verifyWhoop4(frame)
        val length = check.length
        val crcOk = check.crc32Ok

        val t = frame[4].toInt() and 0xFF
        val name = typeName(t)
        val parsed = LinkedHashMap<String, Any?>()

        when (name) {
            "REALTIME_DATA" -> decodeRealtime(frame, parsed)
            "EVENT" -> decodeEvent(frame, length, parsed)
            "COMMAND_RESPONSE" -> decodeCommandResponse(frame, length, parsed)
            "METADATA" -> decodeMetadata(frame, length, parsed)
            else -> Unit
        }

        return ParsedFrame(ok = true, crcOk = crcOk, typeName = name, parsed = parsed)
    }

    private fun parseWhoop5(frame: ByteArray): ParsedFrame {
        // Minimum whoop5 frame: 8 header bytes + 1 inner (type) + 4 CRC32 trailer.
        if (frame.size < 12 || frame[0] != 0xAA.toByte()) return ParsedFrame.invalid()
        val check = verifyWhoop5(frame)
        val innerStart = 8
        val t = frame[innerStart].toInt() and 0xFF
        val name = typeName(t)
        val parsed = LinkedHashMap<String, Any?>()
        // WHOOP 5.0 field offsets are the 4.0 layout shifted by +4 (inner record starts at byte 8 vs 4).
        // REALTIME_DATA is hardware-verified at +4 (HR matched the 0x2A37 profile to ~0.4 bpm over 96
        // worn frames; see the Swift Whoop5RealtimeTests vector). Other types stay envelope-only until
        // their per-type 5.0 offsets are confirmed on hardware — we don't invent offsets.
        when (name) {
            "REALTIME_DATA" -> decodeRealtimeWhoop5(frame, parsed)
            "METADATA" -> decodeMetadataWhoop5(frame, parsed)
            "EVENT" -> decodeEventWhoop5(frame, parsed)
            "COMMAND_RESPONSE" -> decodeCommandResponseWhoop5(frame, parsed)
            "CONSOLE_LOGS" -> decodeConsoleLogsWhoop5(frame, parsed)
            else -> Unit
        }
        return ParsedFrame(ok = true, crcOk = check.crc32Ok, typeName = name, parsed = parsed)
    }

    /**
     * EVENT (type 48) for WHOOP 5.0/MG — the 4.0 layout + 4: event@10 (u8, EventNumber),
     * event_timestamp@12 (u32), opaque payload bytes @16..size-4 (kept as hex for protocol research —
     * real captures show uncatalogued events, e.g. 0x1D(29) with a 16-byte payload). For
     * BATTERY_LEVEL the 4.0 payload decode shifts with it: soc%=u16@21/10, mV=u16@25, charging@30
     * bit0 (mirrors Swift Interpreter's whoop5 event decode; all gated, fail closed). (#78 fork)
     */
    private fun decodeEventWhoop5(frame: ByteArray, parsed: MutableMap<String, Any?>) {
        val evVal = frame.u8(10) ?: return
        parsed["event"] = eventLabel(evVal)
        frame.u32(12)?.let { parsed["event_timestamp"] = it.toInt() }
        val payEnd = frame.size - 4
        if (payEnd > 16) {
            parsed["event_payload_hex"] = frame.copyOfRange(16, payEnd)
                .joinToString("") { "%02x".format(it) }
        }
        if (EventNumber.fromRaw(evVal) == EventNumber.BATTERY_LEVEL) {
            frame.u16(21)?.let { raw -> if (raw <= 1100) parsed["battery_pct"] = raw.toDouble() / 10.0 }
            frame.u16(25)?.let { mv -> if (mv in 3000..4300) parsed["battery_mV"] = mv }
            frame.u8(30)?.let { ch -> if (ch <= 1) parsed["battery_charging"] = ch and 1 }
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
    private fun decodeCommandResponseWhoop5(frame: ByteArray, parsed: MutableMap<String, Any?>) {
        val cmd = frame.u8(10) ?: return
        parsed["resp_cmd"] = commandLabel(cmd)
        frame.u8(11)?.let { parsed["resp_seq"] = it }
        frame.u8(12)?.let { parsed["result"] = commandResultLabel(it) }
        if (CommandNumber.fromRaw(cmd) == CommandNumber.GET_BATTERY_LEVEL) {
            frame.u8(13)?.let { pct -> if (pct <= 100) parsed["battery_pct"] = pct.toDouble() }
        }
        // GET_HELLO (145): device name + firmware version. Mirrors the Swift Interpreter decode of the
        // same 50.38.1.0 capture: payload base is frame[11]; the name is printable ASCII at pay[16],
        // the firmware is 4 bytes at pay[93] gated on pay[93]==50 (the "5.x" generation). The session
        // token in the same block is deliberately never read. Surfaced on the Devices card.
        if (cmd == 145) {
            val payEnd = frame.size - 4 // drop the trailing CRC32
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
    private fun decodeConsoleLogsWhoop5(frame: ByteArray, parsed: MutableMap<String, Any?>) {
        frame.u16(9)?.let { parsed["record_index"] = it }
        frame.u32(12)?.let { parsed["unix"] = it.toInt() }
        frame.u16(16)?.let { parsed["subsec"] = it }
        val payEnd = frame.size - 4
        if (payEnd <= 21) return
        val text = frame.copyOfRange(21, payEnd)
            .toString(Charsets.UTF_8)
            .trimEnd('\u0000')
        if (text.isNotEmpty()) parsed["console"] = text.take(2048)
    }

    /**
     * METADATA (PUFFIN_METADATA, type 56) for WHOOP 5.0/MG — the 4.0 METADATA layout + 4 (the inner
     * record starts at byte 8 vs 4): meta_type@10 (u8), and for a HISTORY_END additionally unix@11
     * (u32), subsec@15 (u16), trim_cursor@21 (u32). Without this, parseWhoop5 left every 5/MG METADATA
     * frame field-less, so classifyHistoricalMeta could never recognise HISTORY_END/COMPLETE → the
     * Backfiller never acked/trimmed → 5/MG offload never completed. Offsets verified against real
     * WHOOP 5 HISTORY_END frames (Swift decodeWhoop5Metadata, Interpreter.swift:407). (#78)
     */
    private fun decodeMetadataWhoop5(frame: ByteArray, parsed: MutableMap<String, Any?>) {
        val mt = frame.u8(10) ?: return
        parsed["meta_type"] = metaLabel(mt)
        // Only a HISTORY_END carries unix/subsec/trim; the u-reads null out on the shorter
        // START/COMPLETE frames, so classifyHistoricalMeta keys those off meta_type alone.
        frame.u32(11)?.let { parsed["unix"] = it.toInt() }
        frame.u16(15)?.let { parsed["subsec"] = it }
        frame.u32(21)?.let { parsed["trim_cursor"] = it.toInt() }
    }

    /**
     * REALTIME_DATA (type 40) for WHOOP 5.0 — the 4.0 layout + 4: timestamp@10 (u32),
     * subseconds@14 (u16), heart_rate@16 (u8), rr_count@17, rr@18.. (u16). Mirrors the Swift
     * parseFrameWhoop5 realtime decode and is covered by the same real-frame test vector.
     */
    private fun decodeRealtimeWhoop5(frame: ByteArray, parsed: MutableMap<String, Any?>) {
        frame.u32(10)?.let { parsed["timestamp"] = it.toInt() }
        frame.u16(14)?.let { parsed["subseconds"] = it }
        frame.u8(16)?.let { parsed["heart_rate"] = it }
        val rrn = frame.u8(17) ?: 0
        parsed["rr_count"] = rrn
        val rrs = ArrayList<Int>()
        for (i in 0 until rrn) {
            val v = frame.u16(18 + i * 2)
            if (v != null && v > 0) rrs.add(v)   // drop 0 ms placeholders, matching 4.0 / Swift
        }
        parsed["rr_intervals"] = rrs
    }

    // MARK: - per-type decoders (Whoop 4.0). Ported from PostHooks.swift + the static field specs.

    /** REALTIME_DATA (type 40): timestamp@6 (u32), heart_rate@12 (u8), rr_count@13, rr@14.. (u16). */
    private fun decodeRealtime(frame: ByteArray, parsed: MutableMap<String, Any?>) {
        frame.u32(6)?.let { parsed["timestamp"] = it.toInt() }
        frame.u16(10)?.let { parsed["subseconds"] = it }
        frame.u8(12)?.let { parsed["heart_rate"] = it }
        val rrn = frame.u8(13) ?: 0
        parsed["rr_count"] = rrn
        val rrs = ArrayList<Int>()
        for (i in 0 until rrn) {
            // Drop 0 ms intervals (placeholders, not beat-to-beat intervals), matching Swift.
            val v = frame.u16(14 + i * 2)
            if (v != null && v > 0) rrs.add(v)
        }
        parsed["rr_intervals"] = rrs
    }

    /**
     * EVENT (type 48): event@6 (u8, EventNumber), event_timestamp@8 (u32).
     * For BATTERY_LEVEL, additionally decode soc@17(/10), mV@21, charging@26 bit0.
     */
    private fun decodeEvent(frame: ByteArray, length: Int?, parsed: MutableMap<String, Any?>) {
        val evVal = frame.u8(6) ?: return
        parsed["event"] = eventLabel(evVal)
        frame.u32(8)?.let { parsed["event_timestamp"] = it.toInt() }

        if (EventNumber.fromRaw(evVal) == EventNumber.BATTERY_LEVEL && length != null) {
            // Fixed layout, empirically verified against captured frames:
            //   soc% = u16@17/10 · mV = u16@21 · charging = u8@26 bit0
            frame.u16(17)?.let { raw -> if (raw <= 1100) parsed["battery_pct"] = raw.toDouble() / 10.0 }
            frame.u16(21)?.let { mv -> if (mv in 3000..4300) parsed["battery_mV"] = mv }
            frame.u8(26)?.let { ch -> if (ch <= 1) parsed["battery_charging"] = ch and 1 }
        }
    }

    /**
     * COMMAND_RESPONSE (type 36): resp_cmd@6 (u8, CommandNumber). Decodes the battery level reply.
     * Payload begins at offset 7; GET_BATTERY_LEVEL stores soc% = u16(payload[2..4]) / 10.
     */
    private fun decodeCommandResponse(frame: ByteArray, length: Int?, parsed: MutableMap<String, Any?>) {
        if (length == null) return
        val payEnd = minOf(length, frame.size)
        if (payEnd < 7) return
        val pay = frame.copyOfRange(7, payEnd)
        val cmd = frame.u8(6) ?: return
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
    private fun decodeMetadata(frame: ByteArray, length: Int?, parsed: MutableMap<String, Any?>) {
        val mt = frame.u8(6) ?: return
        parsed["meta_type"] = metaLabel(mt)
        if (length == null) return
        val payEnd = minOf(length, frame.size)
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
