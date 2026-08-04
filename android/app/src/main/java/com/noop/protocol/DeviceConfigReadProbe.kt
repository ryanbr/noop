package com.noop.protocol

/**
 * #103: READ-ONLY probe of the two config **read** verbs — `GET_DEVICE_CONFIG_VALUE` (121 / 0x79) and
 * `GET_FF_VALUE` (128 / 0x80). Kotlin twin of Swift `DeviceConfigReadProbe` /
 * `DeviceConfigReadProbeReport` (`Packages/WhoopProtocol/…/DeviceConfigReadProbe.swift`); the decoded
 * fields, the plan the probe walks and the rendered report text are byte-identical across platforms, so
 * a strap log reads the same either side.
 *
 * Follow-up to the #761 enumeration probe, which asked the strap for key NAMES; this asks for a key's
 * VALUE.
 *
 * ## Why
 *
 * NOOP writes config two ways and reads it neither way. `SET_FF_VALUE` (120 / 0x78) writes the sixteen
 * R22 feature flags in [Whoop5Config.enableR22Sequence]; `SET_DEVICE_CONFIG_VALUE` (119 / 0x77) writes
 * the one device-config key NOOP knows (the Broadcast-HR flag, #181). Those are two *different
 * namespaces* sharing a body layout — and the 117/118 enumerate pair #761 built covers the feature-flag
 * namespace ONLY. The device-config namespace has never been read or enumerated here at all.
 *
 * That matters for #103. NOOP already decodes a byte the deep record carries at offset 82 that reads as
 * real SpO2 on some straps and is flat 0x00 on others, which is what a subscription gate would look
 * like. If a config value governs it, it is far more likely to live in the device-config namespace than
 * among the sixteen flags NOOP already writes — and nobody has ever asked a strap for one.
 *
 * ## What this establishes, and the honest failure case
 *
 * **Both target opcodes may simply not be implemented in firmware.** The repo's own protocol table
 * (`whoop_protocol.json`, [CommandNumber]) names 121 `GET_DEVICE_CONFIG_VALUE` and 128 `GET_FF_VALUE`,
 * but a name in a table is not a served verb: opcode 96 (`ENTER_HIGH_FREQ_HISTORICAL_MODE`) is a
 * standing example of a number the table carries that nothing in the wild sends. So the probe's PRIMARY
 * deliverable is a clean verdict per verb — **answered**, **rejected as UNSUPPORTED**, **silent**, or
 * **undecodable** — and "both verbs are unimplemented" is a useful, publishable result, not a failure.
 *
 * Those four are not interchangeable, and the verdict never treats them as such. **Only UNSUPPORTED is
 * the firmware's own answer**, so only UNSUPPORTED supports the sentence "this firmware does not serve
 * that verb". A timeout is a fact about one run and not even proof a frame reached the strap — the send
 * path returns without transmitting when the command characteristic is missing, and again when the 5/MG
 * allowlist does not carry the opcode — while an undecodable reply is affirmative evidence the strap DID
 * transmit, which is the opposite of "not served". Both are reported as **unconfirmed**.
 *
 * Only if a verb answers does the probe go on to read values: first the sixteen key names NOOP already
 * has (their VALUES on a real strap have never been read, only written), then a short list of GUESSED
 * oxygen-related key names against the device-config namespace.
 *
 * ## Read-only by construction
 *
 * The probe writes command frames purely in order to read, the same shape as the Oura feature-status
 * probes NOOP already ships and as the #761 enumeration. The SET verbs are named in [WRITE_OPCODES] for
 * exactly one reason: so the send allowlist can be expressed as "[READ_ONLY_OPCODES] only" and a unit
 * test can prove 119/120 are rejected by it. Nothing in this file or on its BLE path can form a SET
 * frame.
 *
 * ## Wire shape (a documented guess, and it fails closed)
 *
 * Request: command 121 or 128 with body `[0x01]` — the inner b3 convention CLIENT_HELLO and the
 * SET_CONFIG family use — followed by the key name as ASCII NUL-padded to 32 bytes, the same name field
 * [Whoop5Config.payloadBody] / [Whoop5Config.deviceConfigBody] build for the SET side, minus the
 * trailing value byte a read has no reason to carry. That body shape is inferred from the SET side, not
 * observed; if it is wrong the strap answers FAILURE or nothing, which the report says plainly.
 *
 * Response: an ordinary COMMAND_RESPONSE echoing the command byte, whose record sits behind the 2-byte
 * response header (`pay[1]` is the 5/MG result code) — the same offset every other COMMAND_RESPONSE
 * decoder here uses. Beyond that offset **no field layout is assumed**: the record is kept and reported
 * as raw hex. A value is only ever *claimed* when the reply echoes the key that was asked for inside a
 * 32-byte NUL-padded name field, in which case the byte immediately after that field is reported as the
 * value — the SET side's own layout, checked rather than assumed.
 *
 * Everything fails closed: a frame whose CRCs don't verify, whose type is not COMMAND_RESPONSE, or whose
 * record is too short is REJECTED rather than guessed at.
 */
object DeviceConfigReadProbe {

    /** `GET_DEVICE_CONFIG_VALUE` (121 / 0x79) — one device-config value by key name. Read-only. */
    const val GET_DEVICE_CONFIG_VALUE_CMD = 121

    /** `GET_FF_VALUE` (128 / 0x80) — one feature-flag value by key name. Read-only. */
    const val GET_FEATURE_FLAG_VALUE_CMD = 128

    /** `SET_DEVICE_CONFIG_VALUE` (119 / 0x77). Named ONLY so the allowlist can name what it excludes. */
    const val SET_DEVICE_CONFIG_VALUE_CMD = 119

    /** `SET_FF_VALUE` (120 / 0x78). Named ONLY so the allowlist can name what it excludes. */
    const val SET_FEATURE_FLAG_VALUE_CMD = 120

    /** The complete set of opcodes this probe may put on the wire. The BLE send path admits these two
     *  and only these two while a probe is in flight; [isReadOnlyOpcode] is the predicate it asks. */
    val READ_ONLY_OPCODES = setOf(GET_DEVICE_CONFIG_VALUE_CMD, GET_FEATURE_FLAG_VALUE_CMD)

    /** The config WRITE verbs, which this probe must never emit. Kept as a named set so the read-only
     *  contract is testable as a property of the allowlist rather than as a claim in a comment. */
    val WRITE_OPCODES = setOf(SET_DEVICE_CONFIG_VALUE_CMD, SET_FEATURE_FLAG_VALUE_CMD)

    /** The allowlist predicate itself. False for both SET verbs and for every opcode outside the pair. */
    fun isReadOnlyOpcode(opcode: Int): Boolean = READ_ONLY_OPCODES.contains(opcode)

    /** Width of the key-name field in the SET bodies (both NUL-pad the name to 32 bytes). */
    const val NAME_FIELD_BYTES = 32

    /** Hard ceiling on round-trips in one probe, independent of how many keys the plan holds. */
    const val MAX_STEPS = 64

    /** The one device-config key NOOP already knows a real strap accepts: the Broadcast-HR flag written
     *  via SET_DEVICE_CONFIG_VALUE and hardware-validated in #181. Used as the discovery key for opcode
     *  121 precisely because it is known-good — a FAILURE on this key is evidence about the verb. */
    const val DEVICE_CONFIG_DISCOVERY_KEY = "whoop_live_hr_in_adv_ind_pkt"

    /**
     * **GUESSES.** Candidate oxygen-related key names to try against the device-config namespace. None of
     * these has been observed on a wire, in a capture, or in any protocol table — they are constructed
     * from the naming conventions the *known* keys follow (`enable_…`, `…_enable`, snake_case, and the
     * `whoop_…` prefix the one known device-config key uses). They are reported as guesses everywhere
     * they appear.
     *
     * This list is the one place to extend. Adding a name here adds a probe step and nothing else — the
     * same pattern would let a future run try, say, `enable_sig13` (the undocumented `enable_sig11…` /
     * `enable_sig12` series continued) without touching any other code. Keep in lockstep with the Swift
     * `DeviceConfigReadProbe.oxygenCandidateKeys`.
     */
    val OXYGEN_CANDIDATE_KEYS: List<String> = listOf(
        "enable_spo2",
        "enable_spo2_packets",
        "spo2_enable",
        "enable_blood_oxygen",
        "blood_oxygen_enable",
        "enable_pulse_ox",
        "enable_oxygen_packets",
        "spo2_subscription_enabled",
    )

    /** COMMAND_RESPONSE packet type (36 / 0x24). */
    private const val COMMAND_RESPONSE_TYPE = 36

    /** Bytes of response header ahead of the packet record. `pay[1]` is the 5/MG result code. */
    private const val RESPONSE_HEADER_BYTES = 2

    /** Record bytes rendered in the report before the hex is elided. */
    const val MAX_HEX_BYTES = 48

    /** The request body for one read: the inner b3 byte `0x01`, then the key name as ASCII NUL-padded to
     *  [NAME_FIELD_BYTES]. A name longer than the field is truncated to it, exactly as the SET side does. */
    fun requestBody(key: String): ByteArray {
        val body = ByteArray(NAME_FIELD_BYTES + 1)
        body[0] = 0x01
        val bytes = key.toByteArray(Charsets.UTF_8)
        for (i in 0 until minOf(NAME_FIELD_BYTES, bytes.size)) body[i + 1] = bytes[i]
        return body
    }

    /** Why a frame was not decoded. Named cases so the report can say what went wrong. */
    enum class ParseFailure { CRC, ENVELOPE, WRONG_COMMAND, TRUNCATED }

    /**
     * One decoded config-read reply. Deliberately shallow: the record is kept RAW because no field layout
     * for these two opcodes has ever been observed. The only structured read offered is [valueFor], and
     * it only answers when the strap echoed the key back in the SET side's own 32-byte name field.
     */
    data class ValueResponse(val resultCode: Int?, val record: ByteArray) {

        /** The firmware explicitly refused the verb — the outcome that settles "is 121/128 implemented". */
        val isUnsupported: Boolean get() = resultCode == 3

        /** The firmware answered but reported failure: the verb exists, the request did not satisfy it. */
        val isFailure: Boolean get() = resultCode == 0

        /** Raw record bytes as lowercase space-separated hex; always reported, whatever else decodes. */
        val recordHex: String get() = hex(record)

        /**
         * Where [key] appears in the record as a NUL-padded 32-byte name field, or null if it does not.
         * Requires the padding to actually be NUL so a coincidental substring can't be mistaken for the
         * name field.
         */
        fun echoOffset(key: String): Int? {
            val needle = key.toByteArray(Charsets.UTF_8)
            if (needle.isEmpty() || needle.size > NAME_FIELD_BYTES) return null
            if (record.size < NAME_FIELD_BYTES) return null
            for (start in 0..(record.size - NAME_FIELD_BYTES)) {
                var matched = true
                for (i in needle.indices) {
                    if (record[start + i] != needle[i]) { matched = false; break }
                }
                if (!matched) continue
                // The rest of the field must be NUL padding, or this is not the name field.
                var padded = true
                for (i in needle.size until NAME_FIELD_BYTES) {
                    if (record[start + i].toInt() != 0) { padded = false; break }
                }
                if (padded) return start
            }
            return null
        }

        /**
         * The value byte, reported ONLY when the strap echoed [key] in a 32-byte NUL-padded name field
         * and the record extends one byte past it — the same `[name 32][value]` layout the SET bodies
         * use. null means "no value claimed", never "value is zero".
         */
        fun valueFor(key: String): Int? {
            val off = echoOffset(key) ?: return null
            val valueIndex = off + NAME_FIELD_BYTES
            if (valueIndex >= record.size) return null
            return record[valueIndex].toInt() and 0xFF
        }

        // ByteArray fields need explicit equals/hashCode for a data class to compare by content.
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is ValueResponse) return false
            return resultCode == other.resultCode && record.contentEquals(other.record)
        }

        override fun hashCode(): Int = 31 * (resultCode ?: 0) + record.contentHashCode()
    }

    /** One decode outcome: exactly one of [value] / [failure] is non-null. */
    data class Parsed(val value: ValueResponse?, val failure: ParseFailure?)

    /**
     * Decode a config-read COMMAND_RESPONSE for [expecting] (121 or 128). CRC-gated: a frame whose
     * checksums fail is rejected before any field is read.
     */
    fun parse(frame: ByteArray, family: DeviceFamily, expecting: Int): Parsed {
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
        return Parsed(ValueResponse(resultCode, pay.copyOfRange(RESPONSE_HEADER_BYTES, pay.size)), null)
    }

    /** Lowercase space-separated hex, capped so one oversized record can't flood the report. */
    fun hex(bytes: ByteArray): String {
        val shown = if (bytes.size > MAX_HEX_BYTES) bytes.copyOfRange(0, MAX_HEX_BYTES) else bytes
        var out = shown.joinToString(" ") { "%02x".format(it.toInt() and 0xFF) }
        if (bytes.size > MAX_HEX_BYTES) out += " … (${bytes.size} bytes)"
        return if (out.isEmpty()) "(empty)" else out
    }

    /** Pad [s] on the right to [width], used instead of a printf `%-Ns` so Swift and Kotlin render the
     *  report identically. */
    fun padded(s: String, width: Int): String =
        if (s.length >= width) s else s + " ".repeat(width - s.length)

    /** A value byte rendered as both its character (when printable) and its number. */
    fun valueLabel(v: Int): String =
        if (v in 32..126) "'${v.toChar()}' (0x${"%02x".format(v)})" else "0x${"%02x".format(v)}"
}

/**
 * The running result of one device-config read probe: the plan it walks, the per-verb verdict it
 * reaches, the values it manages to read, and the copyable transcript. Pure and order-dependent
 * (`nextStep` → `note…` → `nextStep` → …). Twin of Swift `DeviceConfigReadProbeReport`; [render] is
 * byte-identical across platforms.
 */
class DeviceConfigReadProbeReport(
    private val family: DeviceFamily,
    /** The flag names whose values to read — supplied by the caller from [Whoop5Config.enableR22Sequence]
     *  so this file never restates them. */
    private val knownFlagKeys: List<String>,
    /** The guessed oxygen key names — supplied by the caller from [DeviceConfigReadProbe]. */
    private val candidateKeys: List<String>,
) {

    /** Which part of the plan a step belongs to. Drives both the ordering and the report's sections. */
    enum class Group { DISCOVERY, KNOWN_FLAG, CANDIDATE }

    /** One planned round-trip. */
    data class Step(val opcode: Int, val key: String, val group: Group)

    /** What one verb has been shown to do. `UNTRIED` until its discovery step resolves. */
    enum class VerbStatus(val label: String) {
        UNTRIED("untried"),
        /** A decodable COMMAND_RESPONSE came back and was not an explicit UNSUPPORTED. */
        ANSWERED("answered"),
        /** The firmware refused the opcode (5/MG result code 3). */
        UNSUPPORTED("unsupported"),
        /** No reply inside the probe's per-step window. */
        SILENT("silent"),
        /** A reply arrived but could not be decoded (CRC, envelope, or a short record). */
        UNDECODABLE("undecodable"),
    }

    /** One value read (or attempted) for one key. */
    data class Reading(
        val group: Group,
        val opcode: Int,
        val key: String,
        /** The value byte, only when the strap echoed the key in a 32-byte name field. */
        val value: Int?,
        val resultCode: Int?,
        val recordHex: String,
    )

    /** Status of `GET_FF_VALUE` (128). */
    var featureFlagVerb: VerbStatus = VerbStatus.UNTRIED
        private set

    /** Status of `GET_DEVICE_CONFIG_VALUE` (121). */
    var deviceConfigVerb: VerbStatus = VerbStatus.UNTRIED
        private set

    private val _readings = mutableListOf<Reading>()
    /** Every reading, in the order the strap served it. */
    val readings: List<Reading> get() = _readings

    private val _trace = mutableListOf<String>()
    /** Trace lines: one per round-trip plus any failure notes. */
    val trace: List<String> get() = _trace

    /** Round-trips attempted. Bounds the walk against [DeviceConfigReadProbe.MAX_STEPS]. */
    var steps: Int = 0
        private set

    /** Set once the walk stopped for a reason worth naming beyond "the plan ran out". */
    var stopReason: String? = null
        private set

    /**
     * Per-verb reply window, in seconds, recorded by [noteTimeout]. The verdict names the window a verb
     * went silent through instead of converting that silence into a claim about the firmware.
     */
    private val silenceWindow = mutableMapOf<Int, Int>()

    private var phase = 0            // 0 discovery, 1 known flags, 2 candidates, 3 done
    private var cursor = 0
    /** `"opcode:key"` pairs already attempted, so discovery's key is not re-read in a later phase. */
    private val attempted = mutableSetOf<String>()

    /**
     * The next round-trip to send, or null when the probe is done. Called after the previous reply has
     * been noted, so a verb proved dead is skipped for every step it would otherwise have owned.
     */
    fun nextStep(): Step? {
        if (steps >= DeviceConfigReadProbe.MAX_STEPS) {
            if (stopReason == null) {
                stopReason = "safety cap of ${DeviceConfigReadProbe.MAX_STEPS} round-trips reached"
            }
            phase = 3
            return null
        }
        while (phase < 3) {
            val step = stepInCurrentPhase()
            if (step != null) {
                cursor += 1
                val id = "${step.opcode}:${step.key}"
                if (attempted.contains(id)) continue
                attempted.add(id)
                steps += 1
                return step
            }
            phase += 1
            cursor = 0
        }
        return null
    }

    /** One candidate step from the current phase, or null when that phase is exhausted. */
    private fun stepInCurrentPhase(): Step? = when (phase) {
        0 -> {
            // Discovery: one round-trip per verb, each against a key that verb has a reason to know.
            // 128 gets a flag NOOP writes; 121 gets the Broadcast-HR key, hardware-validated in #181.
            val plan = listOf(
                Step(
                    DeviceConfigReadProbe.GET_FEATURE_FLAG_VALUE_CMD,
                    knownFlagKeys.firstOrNull() ?: DeviceConfigReadProbe.DEVICE_CONFIG_DISCOVERY_KEY,
                    Group.DISCOVERY,
                ),
                Step(
                    DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD,
                    DeviceConfigReadProbe.DEVICE_CONFIG_DISCOVERY_KEY,
                    Group.DISCOVERY,
                ),
            )
            if (cursor < plan.size) plan[cursor] else null
        }
        1 -> {
            // Known flag values, through whichever verb answered — 128 by preference (it owns the
            // feature-flag namespace), 121 as a fallback worth one look if only it survived.
            val verb = verbForFlags()
            if (verb != null && cursor < knownFlagKeys.size) {
                Step(verb, knownFlagKeys[cursor], Group.KNOWN_FLAG)
            } else {
                null
            }
        }
        2 -> {
            // Guessed oxygen keys, through the device-config verb by preference — that namespace is the
            // one this probe exists to reach.
            val verb = verbForCandidates()
            if (verb != null && cursor < candidateKeys.size) {
                Step(verb, candidateKeys[cursor], Group.CANDIDATE)
            } else {
                null
            }
        }
        else -> null
    }

    /** The verb to read feature-flag values through, or null when neither answered. */
    private fun verbForFlags(): Int? = when {
        featureFlagVerb == VerbStatus.ANSWERED -> DeviceConfigReadProbe.GET_FEATURE_FLAG_VALUE_CMD
        deviceConfigVerb == VerbStatus.ANSWERED -> DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD
        else -> null
    }

    /** The verb to try guessed device-config keys through, or null when neither answered. */
    private fun verbForCandidates(): Int? = when {
        deviceConfigVerb == VerbStatus.ANSWERED -> DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD
        featureFlagVerb == VerbStatus.ANSWERED -> DeviceConfigReadProbe.GET_FEATURE_FLAG_VALUE_CMD
        else -> null
    }

    /** Record one decoded reply. */
    fun noteReply(r: DeviceConfigReadProbe.ValueResponse, step: Step) {
        setStatus(if (r.isUnsupported) VerbStatus.UNSUPPORTED else VerbStatus.ANSWERED, step.opcode)
        val value = r.valueFor(step.key)
        _readings.add(
            Reading(step.group, step.opcode, step.key, value, r.resultCode, r.recordHex),
        )
        var line = "${opcodeLabel(step.opcode)} key=\"${step.key}\""
        val code = r.resultCode
        line += if (code != null) " → result=${FeatureFlagProbe.resultLabel(code)}($code)" else " →"
        if (value != null) line += " value=${DeviceConfigReadProbe.valueLabel(value)}"
        line += " record=[${r.recordHex}]"
        _trace.add(line)
    }

    /** Record a reply that could not be decoded. The verb is marked undecodable, which retires it. */
    fun noteFailure(f: DeviceConfigReadProbe.ParseFailure, step: Step) {
        val why = when (f) {
            DeviceConfigReadProbe.ParseFailure.CRC -> "CRC failed — frame rejected (never decoded)"
            DeviceConfigReadProbe.ParseFailure.ENVELOPE -> "not a COMMAND_RESPONSE envelope"
            DeviceConfigReadProbe.ParseFailure.WRONG_COMMAND -> "COMMAND_RESPONSE for a different command"
            DeviceConfigReadProbe.ParseFailure.TRUNCATED -> "record too short to hold a response"
        }
        setStatus(VerbStatus.UNDECODABLE, step.opcode)
        _trace.add("${opcodeLabel(step.opcode)} key=\"${step.key}\" reply not decoded: $why")
        if (stopReason == null) stopReason = why
    }

    /**
     * Record the strap answering nothing at all within the per-step window. The verb is marked silent,
     * which retires it — one no-reply must not cost another twenty timeouts.
     *
     * The window is kept, not just printed, because the verdict has to be able to say how long nothing
     * came back for. Silence is not the firmware refusing; it does not even establish that a frame was
     * transmitted (see the header), so it can never be reported as what the firmware serves.
     */
    fun noteTimeout(step: Step, seconds: Int) {
        silenceWindow[step.opcode] = seconds
        setStatus(VerbStatus.SILENT, step.opcode)
        _trace.add("${opcodeLabel(step.opcode)} key=\"${step.key}\" → no COMMAND_RESPONSE within ${seconds}s")
    }

    /**
     * A verb's status only ever moves off UNTRIED; a later step never upgrades a verdict already reached,
     * so one lucky reply after an UNSUPPORTED cannot rewrite the headline.
     */
    private fun setStatus(s: VerbStatus, opcode: Int) {
        if (opcode == DeviceConfigReadProbe.GET_FEATURE_FLAG_VALUE_CMD) {
            if (featureFlagVerb == VerbStatus.UNTRIED || featureFlagVerb == VerbStatus.ANSWERED) {
                featureFlagVerb = s
            }
        } else if (opcode == DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD) {
            if (deviceConfigVerb == VerbStatus.UNTRIED || deviceConfigVerb == VerbStatus.ANSWERED) {
                deviceConfigVerb = s
            }
        }
    }

    /** Short opcode label used in the transcript. */
    private fun opcodeLabel(opcode: Int): String =
        if (opcode == DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD) {
            "GET_DEVICE_CONFIG_VALUE(121)"
        } else {
            "GET_FF_VALUE(128)"
        }

    /**
     * How one verb ended, worded to exactly the evidence behind it. See the file header for why the four
     * statuses are not interchangeable; the short version is that only UNSUPPORTED is the firmware
     * answering, so only UNSUPPORTED speaks for the firmware.
     */
    private fun outcome(status: VerbStatus, opcode: Int): String = when (status) {
        VerbStatus.UNTRIED -> "not asked"
        VerbStatus.ANSWERED -> "answered"
        VerbStatus.UNSUPPORTED -> "refused by firmware (UNSUPPORTED)"
        VerbStatus.SILENT -> silenceWindow[opcode]
            ?.let { "served no reply in ${it}s — unconfirmed" }
            ?: "served no reply — unconfirmed"
        VerbStatus.UNDECODABLE -> "replied but the frame did not decode — unconfirmed"
    }

    /**
     * One-line summary of what the probe established.
     *
     * "not served by this firmware" is a claim about the firmware, so it is made in exactly one case: the
     * firmware refused BOTH verbs itself. Every other run in which nothing answered reports each verb
     * against the evidence that verb produced, because two timeouts, one refusal plus one timeout, and a
     * reply that failed to decode are three different findings that used to print as the same sentence.
     */
    val verdict: String
        get() {
            val answered = listOf(featureFlagVerb, deviceConfigVerb).count { it == VerbStatus.ANSWERED }
            if (answered == 0) {
                if (featureFlagVerb == VerbStatus.UNSUPPORTED && deviceConfigVerb == VerbStatus.UNSUPPORTED) {
                    return "neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121) is served by this " +
                        "firmware — rejected as UNSUPPORTED"
                }
                val ff = outcome(featureFlagVerb, DeviceConfigReadProbe.GET_FEATURE_FLAG_VALUE_CMD)
                val dc = outcome(deviceConfigVerb, DeviceConfigReadProbe.GET_DEVICE_CONFIG_VALUE_CMD)
                return "no read verb answered — GET_FF_VALUE(128) $ff; GET_DEVICE_CONFIG_VALUE(121) $dc"
            }
            val named = _readings.count { it.value != null }
            if (named == 0) {
                return "$answered of 2 read verbs answered, but no reply echoed its key so no value is claimed"
            }
            return "$answered of 2 read verbs answered; read $named config value(s)"
        }

    /** The full copyable report (byte-identical to the Swift `render()`). */
    fun render(): String {
        val fam = if (family == DeviceFamily.WHOOP5) "WHOOP 5/MG" else "WHOOP 4.0"
        val sb = StringBuilder()
        sb.append("#103 DEVICE-CONFIG READ PROBE — $fam\n")
        sb.append("Read-only: GET_DEVICE_CONFIG_VALUE(121) + GET_FF_VALUE(128). No value is written; ")
        sb.append("SET_DEVICE_CONFIG_VALUE(119) and SET_FF_VALUE(120) are never sent from this path.\n")
        sb.append("Follow-up to the #761 enumeration probe: that one asked for key NAMES, this asks for VALUES.\n")
        sb.append("\nVerdict: $verdict\n")
        stopReason?.let { sb.append("Stopped: $it\n") }

        sb.append("\nRead verbs:\n")
        sb.append("  ").append(DeviceConfigReadProbe.padded("GET_FF_VALUE(128)", 30))
            .append(featureFlagVerb.label).append("\n")
        sb.append("  ").append(DeviceConfigReadProbe.padded("GET_DEVICE_CONFIG_VALUE(121)", 30))
            .append(deviceConfigVerb.label).append("\n")

        sb.append(
            section(
                Group.DISCOVERY,
                "Discovery — one round-trip per verb against a key it should know",
                "(none — no reply was decoded)",
            ),
        )
        sb.append(
            section(
                Group.KNOWN_FLAG,
                "Known feature-flag values (names NOOP already writes; values never read before)",
                "(none — the verb that would carry them did not answer)",
            ),
        )
        sb.append(
            section(
                Group.CANDIDATE,
                "Candidate oxygen keys — GUESSES, never observed on a wire or in any table",
                "(none — the verb that would carry them did not answer)",
            ),
        )

        sb.append("\nExchange:\n")
        for (line in _trace) sb.append("  ").append(line).append("\n")
        return sb.toString()
    }

    /** One rendered section of readings. */
    private fun section(group: Group, title: String, empty: String): String {
        val rows = _readings.filter { it.group == group }
        val sb = StringBuilder()
        sb.append("\n$title (${rows.size}):\n")
        if (rows.isEmpty()) {
            sb.append("  ").append(empty).append("\n")
            return sb.toString()
        }
        rows.forEachIndexed { i, r ->
            val line = StringBuilder()
            line.append("  %2d. ".format(i + 1)).append(DeviceConfigReadProbe.padded(r.key, 32))
            val v = r.value
            val code = r.resultCode
            when {
                v != null -> line.append("= ").append(DeviceConfigReadProbe.valueLabel(v))
                code != null ->
                    line.append("— no value (result=${FeatureFlagProbe.resultLabel(code)}($code))")
                else -> line.append("— no value (the reply did not echo the key)")
            }
            sb.append(line).append("\n")
        }
        return sb.toString()
    }
}
