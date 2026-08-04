package com.noop.protocol

/**
 * #761: READ-ONLY enumeration of the strap's own feature-flag key list. Kotlin twin of Swift
 * `FeatureFlagProbe` / `FeatureFlagProbeReport` (`Packages/WhoopProtocol/…/FeatureFlagProbe.swift`);
 * the decoded fields and the rendered report text are byte-identical across platforms, so a strap log
 * reads the same either side.
 *
 * NOOP already WRITES feature flags (`SET_FF_VALUE` / 0x78, the R22 unlock in [Whoop5Config]) but has
 * never been able to ASK a strap which flags it knows. The protocol's own `CommandNumber` table names
 * the read side — 117 `START_FF_KEY_EXCHANGE`, 118 `SEND_NEXT_FF` — and only the SET pair was ever
 * implemented. This decodes the ENUMERATION pair only: names, no values.
 *
 * `GET_FF_VALUE` (128) is deliberately NOT implemented: the only hands-on report of it
 * (`johnmiddleton12/wearable`, docs/specs/2026-05-24-whoop-protocol-complete.md §4, run against the
 * author's own WHOOP 4.0 on fw 41.16.6.0) states its reply's value field is contaminated by a stale
 * shared buffer, so a read of on/off is unreliable. The same session ran the 117→118 loop and got a
 * complete key dump, which is why the enumerate path is the one built here.
 *
 * **Read-only.** The probe writes command frames in order to read — like the Oura feature-status probe
 * NOOP already ships — but sets no value; 120/119 are never sent from this path.
 *
 * Wire shape. Request: 117 or 118 with body `[0x01]` (the inner b3 convention CLIENT_HELLO and the
 * SET_CONFIG writes use); 118's body is a CURSOR, not an index, so the same frame is repeated to walk
 * the list. Response: an ordinary COMMAND_RESPONSE echoing the command byte, whose record sits behind
 * the 2-byte response header (`pay[1]` is the 5/MG result code) — the same offset every other
 * COMMAND_RESPONSE decoder here uses for its value:
 *
 * ```
 * 117  record = [revision u8][numberOfFeatureFlags u16 LE][padding…]
 * 118  record = [revision u8][index u8][validKey u8][key ASCII, NUL-terminated][padding…]
 * ```
 *
 * Two independent sources agree on that ordering: a decompiled official client's response types
 * (`{revision, numberOfFeatureFlags, padding}` and `{revision, index, validKey, keyStringId, padding}`)
 * and the hands-on WHOOP 4.0 dump above, whose literal replies are `0a 01 | 01 <count u16>` and
 * `0a 01 | 01 <index> 01 <key name…>`, with `0a 01 | 01 ff …` once the cursor is exhausted. Facts about
 * bytes on a wire, reimplemented in NOOP's own code — no client code or naming is copied
 * (see ATTRIBUTION.md).
 *
 * UNVERIFIED on 5/MG: the hardware behind this layout is a WHOOP 4.0 with an R19-era key list. So
 * everything fails closed — a frame whose CRCs fail, whose type is not COMMAND_RESPONSE, or whose
 * record is short is REJECTED rather than guessed at.
 */
object FeatureFlagProbe {

    /** START_FF_KEY_EXCHANGE (117 / 0x75) — how many feature flags the firmware knows. Read-only. */
    const val START_KEY_EXCHANGE_CMD = 117

    /** SEND_NEXT_FF (118 / 0x76) — advance the strap's own cursor, report one key name. Read-only. */
    const val SEND_NEXT_FLAG_CMD = 118

    /** Request body for both: the inner b3 byte `0x01`, as GET_HELLO and the SET_CONFIG family use. */
    val REQUEST_BODY = byteArrayOf(0x01)

    /**
     * Hard ceiling on 118 round-trips in one probe, independent of the count the strap reports. A
     * firmware that answers with a nonsense count (or never advances its cursor) must not be able to
     * drive an unbounded write loop on the command characteristic.
     */
    const val MAX_FLAGS = 128

    /** Longest key name accepted from a reply (the SET side NUL-pads names to 32 bytes). */
    const val MAX_KEY_LENGTH = 32

    /** COMMAND_RESPONSE packet type (36 / 0x24). */
    private const val COMMAND_RESPONSE_TYPE = 36

    /** Bytes of response header ahead of the packet record. `pay[1]` is the 5/MG result code. */
    private const val RESPONSE_HEADER_BYTES = 2

    /** Why a frame was not decoded. Named cases so the probe can say what went wrong. */
    enum class ParseFailure { CRC, ENVELOPE, WRONG_COMMAND, TRUNCATED }

    /** Decoded `START_FF_KEY_EXCHANGE` reply. */
    data class StartResponse(val resultCode: Int?, val revision: Int, val count: Int) {
        /** True when the count is inside the range a real key list could plausibly occupy. */
        val countIsPlausible: Boolean get() = count > 0 && count <= MAX_FLAGS
    }

    /** Decoded `SEND_NEXT_FF` reply. */
    data class NextResponse(
        val resultCode: Int?,
        val revision: Int,
        /** Cursor position the strap reports for this entry; `0xFF` marks the walk finished. */
        val index: Int,
        val validKey: Boolean,
        val key: String?,
    ) {
        /**
         * The STRAP said stop: it returned the 0xFF end marker, or flagged the entry as not a real key.
         * Both are the firmware's own signal, so both are trusted.
         *
         * Deliberately does NOT include `key == null`. That is OUR parser declining a name — a byte
         * outside printable ASCII, or one longer than [MAX_KEY_LENGTH] — and it says nothing about
         * whether the strap has more entries. Treating it as a terminator meant one undecodable name
         * threw away every entry after it: a list of forty with a bad byte at seven yielded six keys.
         * See [isSkippable].
         */
        val isExhausted: Boolean get() = !validKey || index == 0xFF

        /**
         * The firmware calls this a real key but the name did not decode. Record it and KEEP WALKING.
         *
         * Safe because the walk was never bounded by this: [MAX_FLAGS] caps the replies and the announced
         * count bounds it further, so skipping can only spend budget that already exists. And it matters
         * most on the run that matters most — the first real capture is the expensive one to obtain, so
         * truncating it on our own strictness is the worst possible time to lose entries.
         */
        val isSkippable: Boolean get() = validKey && index != 0xFF && key == null
    }

    /** One decode outcome: exactly one of [value] / [failure] is non-null. */
    data class Parsed<T>(val value: T?, val failure: ParseFailure?)

    /** Decode a `START_FF_KEY_EXCHANGE` COMMAND_RESPONSE. CRC-gated. */
    fun parseStart(frame: ByteArray, family: DeviceFamily): Parsed<StartResponse> {
        val e = extract(frame, family, START_KEY_EXCHANGE_CMD)
        e.failure?.let { return Parsed(null, it) }
        val r = e.value!!
        if (r.record.size < 3) return Parsed(null, ParseFailure.TRUNCATED)
        val count = (r.record[1].toInt() and 0xFF) or ((r.record[2].toInt() and 0xFF) shl 8)
        return Parsed(StartResponse(r.resultCode, r.record[0].toInt() and 0xFF, count), null)
    }

    /** Decode a `SEND_NEXT_FF` COMMAND_RESPONSE. CRC-gated like [parseStart]. */
    fun parseNext(frame: ByteArray, family: DeviceFamily): Parsed<NextResponse> {
        val e = extract(frame, family, SEND_NEXT_FLAG_CMD)
        e.failure?.let { return Parsed(null, it) }
        val r = e.value!!
        // revision + index are the minimum: the 0xFF end marker arrives with nothing after it.
        if (r.record.size < 2) return Parsed(null, ParseFailure.TRUNCATED)
        val revision = r.record[0].toInt() and 0xFF
        val index = r.record[1].toInt() and 0xFF
        val validKey = if (r.record.size >= 3) r.record[2].toInt() != 0 else false
        val key = if (r.record.size >= 4) asciiKey(r.record.copyOfRange(3, r.record.size)) else null
        return Parsed(NextResponse(r.resultCode, revision, index, validKey, key), null)
    }

    private class Extracted(val record: ByteArray, val resultCode: Int?)

    /**
     * Shared envelope work: verify both CRCs, confirm this is a COMMAND_RESPONSE for [expecting], and
     * slice out the record. The command byte is at 6 on WHOOP 4.0 and 10 on 5/MG (the puffin envelope
     * inserts the format byte + CRC16 header); the 4-byte CRC32 trailer is excluded on both.
     */
    private fun extract(frame: ByteArray, family: DeviceFamily, expecting: Int): Parsed<Extracted> {
        // BLE safety contract: CRC-gate everything. A frame that fails either checksum is not data.
        if (!Framing.frameCrcOk(frame, family)) return Parsed(null, ParseFailure.CRC)
        val typeOff = if (family == DeviceFamily.WHOOP5) 8 else 4
        val cmdOff = typeOff + 2
        if (frame.size <= cmdOff + 4) return Parsed(null, ParseFailure.ENVELOPE)
        if ((frame[typeOff].toInt() and 0xFF) != COMMAND_RESPONSE_TYPE) return Parsed(null, ParseFailure.ENVELOPE)
        if ((frame[cmdOff].toInt() and 0xFF) != expecting) return Parsed(null, ParseFailure.WRONG_COMMAND)
        val payStart = cmdOff + 1
        val payEnd = frame.size - 4       // strip the CRC32 trailer
        if (payEnd <= payStart) return Parsed(null, ParseFailure.TRUNCATED)
        val pay = frame.copyOfRange(payStart, payEnd)
        if (pay.size <= RESPONSE_HEADER_BYTES) return Parsed(null, ParseFailure.TRUNCATED)
        val resultCode = if (family == DeviceFamily.WHOOP5) pay[1].toInt() and 0xFF else null
        return Parsed(Extracted(pay.copyOfRange(RESPONSE_HEADER_BYTES, pay.size), resultCode), null)
    }

    /**
     * Read a NUL-terminated printable-ASCII key name. Returns null when the first byte is already NUL
     * or non-printable, so a padding run can never be reported as a flag.
     */
    fun asciiKey(bytes: ByteArray): String? {
        val out = StringBuilder()
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            if (v == 0) break
            if (v < 32 || v > 126) return null
            out.append(v.toChar())
            if (out.length > MAX_KEY_LENGTH) return null
        }
        return if (out.isEmpty()) null else out.toString()
    }

    /** 5/MG result-code label, matching the body-location probe's table. */
    fun resultLabel(code: Int): String = when (code) {
        0 -> "FAILURE"
        1 -> "SUCCESS"
        2 -> "PENDING"
        3 -> "UNSUPPORTED"
        else -> "result$code"
    }
}

/**
 * The running result of one enumeration probe, rendered into the copyable text the Devices dialog and
 * the strap log both show. Pure and order-dependent (start → next… → finish). Twin of Swift
 * `FeatureFlagProbeReport`; [render] is byte-identical across platforms.
 */
class FeatureFlagProbeReport(private val family: DeviceFamily) {

    private val _keys = mutableListOf<String>()
    /** Key names collected, in the order the strap reported them. */
    val keys: List<String> get() = _keys

    private val _trace = mutableListOf<String>()
    /** Trace lines: one per reply plus any failure notes. */
    val trace: List<String> get() = _trace

    /** SEND_NEXT replies seen. Bounds the walk (see [noteNext]). */
    var steps: Int = 0
        private set

    /** The count the strap reported for START, when it answered. */
    var reportedCount: Int? = null
        private set

    /** Result code of the START reply on 5/MG (null on 4.0, or before it lands). */
    var startResult: Int? = null
        private set

    /**
     * Entries the strap flagged as real keys whose NAME did not decode, and which the walk stepped over
     * rather than stopping at. Surfaced in the report so a dump with holes never reads as a complete list.
     */
    var skipped: Int = 0
        private set

    /** Set once the walk stopped for a reason we can name. */
    var stopReason: String? = null
        private set

    /** Record the START reply. */
    fun noteStart(r: FeatureFlagProbe.StartResponse) {
        reportedCount = r.count
        startResult = r.resultCode
        var line = "START_FF_KEY_EXCHANGE(117) → revision=${r.revision} count=${r.count}"
        r.resultCode?.let { line += " result=${FeatureFlagProbe.resultLabel(it)}($it)" }
        if (!r.countIsPlausible) {
            line += "  ⚠︎ count outside 1…${FeatureFlagProbe.MAX_FLAGS} — treated as unknown, the walk " +
                "still stops on the strap's own end marker"
        }
        _trace.add(line)
    }

    /** Record one SEND_NEXT reply. Returns true when the walk should continue. */
    fun noteNext(r: FeatureFlagProbe.NextResponse): Boolean {
        steps += 1
        var line = "SEND_NEXT_FF(118) → index=${r.index} validKey=${r.validKey}"
        r.key?.let { line += " key=\"$it\"" }
        r.resultCode?.let { line += " result=${FeatureFlagProbe.resultLabel(it)}($it)" }
        _trace.add(line)
        if (r.isExhausted) {
            if (r.index == 0xFF) {
                stopReason = "cursor exhausted (index 0xFF)"
            } else {
                // `validKey = 0` is documented as an end marker alongside 0xFF, and it is the firmware's
                // own flag, so it is trusted here. But nothing observed so far rules out the other
                // reading — that it marks an EMPTY SLOT and the list continues past it. If so this stops
                // on the first hole, which is the same truncation [isSkippable] exists to prevent, one
                // condition over. It cannot be settled without a strap, so instead of guessing we make
                // the discrepancy loud: stopping here well short of the announced count is exactly the
                // evidence that would settle it.
                stopReason = "firmware reported validKey=false"
                val count = reportedCount
                if (count != null && count > steps) {
                    stopReason = "firmware reported validKey=false at index ${r.index} after $steps of " +
                        "$count announced entries — if validKey=0 marks an empty slot rather than the " +
                        "end of the list, the remainder was NOT walked (see #872 review)"
                }
            }
            return false
        }
        if (r.isSkippable) {
            // Our decode declined the name; the strap still says the entry is real and may have more after
            // it. Count it so a partial dump describes itself instead of looking complete.
            skipped += 1
            _trace[_trace.size - 1] = _trace[_trace.size - 1] +
                "  (name did not decode — skipped, walk continues)"
        }
        r.key?.let { if (!_keys.contains(it)) _keys.add(it) }
        // Bound the walk on REPLIES, not on distinct keys: a firmware whose cursor never advances would
        // repeat one name forever, and a key-count bound would never stop writing 118 to the strap.
        if (steps >= FeatureFlagProbe.MAX_FLAGS) {
            stopReason = "safety cap of ${FeatureFlagProbe.MAX_FLAGS} replies reached"
            return false
        }
        val count = reportedCount
        if (count != null && count > 0 && count <= FeatureFlagProbe.MAX_FLAGS && steps >= count) {
            stopReason = "walked the $count entries the strap announced"
            return false
        }
        return true
    }

    /** Record a reply that could not be decoded. */
    fun noteFailure(f: FeatureFlagProbe.ParseFailure, command: Int) {
        val why = when (f) {
            FeatureFlagProbe.ParseFailure.CRC -> "CRC failed — frame rejected (never decoded)"
            FeatureFlagProbe.ParseFailure.ENVELOPE -> "not a COMMAND_RESPONSE envelope"
            FeatureFlagProbe.ParseFailure.WRONG_COMMAND -> "COMMAND_RESPONSE for a different command"
            FeatureFlagProbe.ParseFailure.TRUNCATED -> "record too short for the documented layout"
        }
        _trace.add("cmd $command reply not decoded: $why")
        if (stopReason == null) stopReason = why
    }

    /** Record the strap answering nothing at all within the probe's window. */
    fun noteTimeout(command: Int, seconds: Int) {
        _trace.add("no COMMAND_RESPONSE for opcode $command within ${seconds}s")
        if (stopReason == null) stopReason = "strap served no reply to opcode $command within ${seconds}s"
    }

    /**
     * The announced count as a phrase for the verdict line, qualified when it falls outside the range a
     * real key list could occupy. [noteStart] already marks an implausible count in the trace, but the
     * verdict is the line that gets pasted into an issue, and restating a number the probe itself
     * distrusts as bare fact is the same over-claim in a smaller place. A plausible count renders
     * exactly as before, so the common report is unchanged.
     */
    private val announcedFlags: String
        get() {
            val n = reportedCount ?: 0
            val plausible = n > 0 && n <= FeatureFlagProbe.MAX_FLAGS
            return if (plausible) "$n flag(s)" else "an implausible $n flag(s)"
        }

    /** One-line summary of what the probe established. */
    val verdict: String
        get() {
            if (startResult == 3) {
                return "opcode 117 REJECTED by firmware (UNSUPPORTED) — this strap does not serve the enumerate verb"
            }
            if (_keys.isEmpty() && reportedCount == null) {
                return "no usable reply — the enumerate path is unconfirmed on this firmware"
            }
            // "named none" would blame the strap for OUR decode. If entries were skipped the strap did
            // name them and this parser rejected the names, which is the opposite conclusion and the one
            // a reader would carry into #103. Same class as [FeatureFlagProbe.NextResponse.isSkippable]:
            // never report our limitation as the strap's behaviour.
            if (_keys.isEmpty() && skipped > 0) {
                return "strap named $skipped flag(s), none of which decoded as printable ASCII within " +
                    "${FeatureFlagProbe.MAX_KEY_LENGTH} chars — this is our parser rejecting them, NOT " +
                    "the strap serving blanks; see the trace for the raw replies"
            }
            // Same discipline one condition over: with no 118 reply decoded, the walk never asked for a
            // single name, so "named none" would blame the strap for OUR timeout (or our parse failure).
            // [steps] counts decoded SEND_NEXT replies, so `steps == 0` is exactly "the key list was
            // never read" — the reachable case being `probeFeatureFlags()` getting its 117 answer and
            // then the 8s timer firing on the first 118. What the strap would have named is unknown, and
            // the report has to say unknown. [stopReason], rendered directly under this line, names
            // which of the two it was.
            if (_keys.isEmpty() && steps == 0) {
                return "strap announced $announcedFlags; no SEND_NEXT_FF(118) reply was decoded — " +
                    "the key list was never read (inconclusive)"
            }
            if (_keys.isEmpty()) return "strap announced $announcedFlags but named none"
            if (skipped > 0) {
                return "enumerated ${_keys.size} feature-flag key name(s); $skipped further name(s) did not decode"
            }
            return "enumerated ${_keys.size} feature-flag key name(s)"
        }

    /** The full copyable report (byte-identical to the Swift `render()`). */
    fun render(): String {
        val fam = if (family == DeviceFamily.WHOOP5) "WHOOP 5/MG" else "WHOOP 4.0"
        val sb = StringBuilder()
        sb.append("#761 FEATURE-FLAG ENUMERATION PROBE — $fam\n")
        sb.append("Read-only: START_FF_KEY_EXCHANGE(117) + SEND_NEXT_FF(118). No value is written; ")
        sb.append("SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119) are never sent from this path.\n")
        sb.append("\nVerdict: $verdict\n")
        stopReason?.let { sb.append("Stopped: $it\n") }
        sb.append("\nFlags reported by the strap (${_keys.size}")
        reportedCount?.let { sb.append(" of $it announced") }
        if (skipped > 0) sb.append(", $skipped name(s) did not decode and were skipped")
        sb.append("):\n")
        if (_keys.isEmpty()) {
            sb.append("  (none)\n")
        } else {
            _keys.forEachIndexed { i, k -> sb.append("  %2d. ".format(i + 1)).append(k).append("\n") }
        }
        sb.append("\nExchange:\n")
        for (line in _trace) sb.append("  ").append(line).append("\n")
        return sb.toString()
    }
}
