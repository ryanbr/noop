package com.noop.protocol

/**
 * #891 / #103: the ONE device-config key this app may write beyond the Broadcast-HR flag —
 * `enable_raw_data_w_ecg` — and the key-aware allowlist that keeps every other key off the wire.
 *
 * ## Where the key came from
 *
 * The strap listed it itself. `START_DEVICE_CONFIG_KEY_EXCHANGE(115)` + `SEND_NEXT_DEVICE_CONFIG(116)` —
 * the read-only enumeration pair [ConfigKeySweep] builds — was answered by a WHOOP 5 MG with
 * `revision=1 count=7`, and the walk ran to a clean `index=255 validKey=false` terminator listing:
 *
 * ```
 * sigproc_wear_detect            enable_rfid                    max_collection_backlog
 * cont_collection_mode           whoop_live_hr_in_adv_ind_pkt   whoop_live_2_hrm_devices
 * enable_raw_data_w_ecg
 * ```
 *
 * Six of those seven were unknown to this codebase. Nothing here is guessed: the names are the strap's
 * own, read off its own enumeration.
 *
 * ## Why this key, and why now
 *
 * #891 records that all three TOGGLE_LABRADOR (ECG) commands — 139, 125, 124 — answer `SUCCESS(1)` on a
 * WHOOP 5 MG and produce **zero** ECG packets in a 30-second listen. What the echoed byte those replies
 * carry actually MEANS is still open: arg-echo is refuted (SELECT_WRIST was sent 0 and answered 1) and
 * blanket payload-echo is refuted (GET_BATTERY_LEVEL sends `[0x00]` and answers 0x2F), but "read-back of
 * stored state" remains an inference — a per-opcode handler echoing a constant fits every observation so
 * far just as well. Either way the practical lesson holds: a `SUCCESS` result byte is not evidence that
 * state changed.
 *
 * On the same strap `enable_raw_data_w_ecg` reads `'0'`. A device-config key whose name pairs "raw data"
 * with "ecg", sitting at `'0'` on a strap whose ECG toggles accept and emit nothing, is the leading
 * candidate for the gate. **Whether flipping it actually produces ECG data is UNKNOWN.** A negative result
 * — gate flipped to `'1'`, read back as `'1'`, still no packets — is a publishable answer that removes the
 * leading hypothesis from #891, and is the outcome this path is built to establish either way.
 *
 * ## Why a write is safe to offer at all
 *
 * Config writes on this firmware are demonstrated, not assumed: running the existing `enable_r22_*`
 * sequence (#174) moved `enable_sig12` from `'2'` (0x32) to `'1'` (0x31), confirmed by a 121 read before
 * and after. So a `SET_DEVICE_CONFIG_VALUE(119)` write lands, and the value that comes back afterwards is
 * real rather than an echo of what was sent.
 *
 * ## Read-back is the proof, not the ack
 *
 * The write's own `COMMAND_RESPONSE` is **not** treated as evidence. #891 is the standing example of why:
 * `SELECT_WRIST` returns SUCCESS for a no-op and FAILURE for a real change, so a result byte says nothing
 * reliable about whether state moved. Every write from this path is therefore followed by a
 * `GET_DEVICE_CONFIG_VALUE(121)` read of the same key, and only the value that comes back is reported.
 * (Framing owed to @ryanbr on #891.)
 *
 * ## The allowlist is key-aware, not just opcode-aware
 *
 * Opcode 119 is shared: the Broadcast-HR flag (#181) writes through it too. An opcode-only allowlist
 * therefore cannot express "this key and no other", and before this file the 5/MG send path admitted ANY
 * device-config key while the Broadcast-HR opt-in happened to be on. [admitsSend] closes that: it parses
 * the key name out of the body and admits exactly two keys, each only while its OWN opt-in is on. The five
 * remaining enumerated keys are named in [OUT_OF_SCOPE_KEYS] and are refused unconditionally — their
 * effects are unknown and nothing here has any reason to move them.
 *
 * This is the same discipline [DeviceConfigReadProbe.isReadOnlyOpcode] established for the read probes: a
 * single pure predicate that the BLE send path itself consults, so a unit test proving the predicate
 * rejects something is proving it about the real wire path and not about a parallel copy of the rule.
 *
 * Pure: no Android BLE, no I/O, no preferences. The caller supplies the two opt-in booleans. Twin of the
 * Swift `DeviceConfigWriteGate` — keep them byte-identical.
 */
object DeviceConfigWriteGate {

    // Opcodes ---------------------------------------------------------------------------------------

    /** `SET_DEVICE_CONFIG_VALUE` (119 / 0x77) — the only write verb this gate ever admits. */
    const val SET_DEVICE_CONFIG_VALUE_CMD = 119

    /** `SET_FF_VALUE` (120 / 0x78) — the FEATURE-FLAG write verb (the R22 sequence, #174). Named here for
     *  exactly one reason: so [admitsSend] can be proved to refuse it. */
    const val SET_FF_VALUE_CMD = 120

    /** `GET_DEVICE_CONFIG_VALUE` (121 / 0x79) — the read verb the mandatory read-back uses. */
    const val GET_DEVICE_CONFIG_VALUE_CMD = 121

    // Keys ------------------------------------------------------------------------------------------

    /** The key this file exists for. Written ONLY while the ECG-gate opt-in is on AND the strap has
     *  positively attested itself a WHOOP MG ([Whoop5Variant.isMG]) — a plain 5.0 has no electrodes. */
    const val ECG_RAW_DATA_KEY = "enable_raw_data_w_ecg"

    /** The Broadcast-HR key (#181), hardware-validated. Admitted only while ITS own opt-in is on. */
    const val BROADCAST_HR_KEY = "whoop_live_hr_in_adv_ind_pkt"

    /** The other five keys the strap's 115/116 enumeration listed. Each refused unconditionally: their
     *  effects are undocumented and unmeasured, and `max_collection_backlog` in particular reads `"0.0"`,
     *  which is not even a flag. Listed rather than merely omitted so the refusal is testable. */
    val OUT_OF_SCOPE_KEYS: List<String> = listOf(
        "sigproc_wear_detect",
        "enable_rfid",
        "max_collection_backlog",
        "cont_collection_mode",
        "whoop_live_2_hrm_devices",
    )

    /** Every device-config key the strap enumerated, in the order it served them. Reported in the UI and
     *  used by tests; never used to build a write. */
    val ENUMERATED_KEYS: List<String> = listOf(
        "sigproc_wear_detect",
        "enable_rfid",
        "max_collection_backlog",
        "cont_collection_mode",
        BROADCAST_HR_KEY,
        "whoop_live_2_hrm_devices",
        ECG_RAW_DATA_KEY,
    )

    // Values ----------------------------------------------------------------------------------------

    /** ASCII `'1'` — the gate on. */
    const val ENABLED_VALUE = 0x31

    /** ASCII `'0'` — the gate off, and what a subscription-free MG reads today. */
    const val DISABLED_VALUE = 0x30

    /** The value byte for a requested state. */
    fun value(on: Boolean): Int = if (on) ENABLED_VALUE else DISABLED_VALUE

    /** The value byte rendered as the character the strap stores. */
    fun valueString(on: Boolean): String = if (on) "1" else "0"

    /** Width of the key-name field in a device-config body. */
    const val NAME_FIELD_BYTES = 32

    // Body parsing ----------------------------------------------------------------------------------

    /**
     * The key name carried by a `SET_DEVICE_CONFIG_VALUE` payload, or null when the payload is not shaped
     * like one.
     *
     * The payload the send path holds is `[0x01] + deviceConfigBody(...)`: the b3 byte, then the 32-byte
     * NUL-padded name, then the value. A name is only returned when it is printable ASCII and the
     * remainder of the field is genuine NUL padding — so a body that is short, mis-shaped, or carrying
     * binary in the name field yields null and is refused rather than guessed at.
     */
    fun keyNameInSendPayload(payload: ByteArray): String? {
        if (payload.size < 1 + NAME_FIELD_BYTES) return null
        if ((payload[0].toInt() and 0xFF) != 0x01) return null
        val name = StringBuilder()
        var terminated = false
        for (i in 0 until NAME_FIELD_BYTES) {
            val b = payload[i + 1].toInt() and 0xFF
            if (b == 0) { terminated = true; break }
            if (b < 0x20 || b > 0x7E) return null
            name.append(b.toChar())
        }
        if (name.isEmpty()) return null
        // Everything after the name must be NUL, or this is not a NUL-padded name field.
        if (terminated) {
            for (i in name.length until NAME_FIELD_BYTES) {
                if ((payload[i + 1].toInt() and 0xFF) != 0) return null
            }
        }
        return name.toString()
    }

    /** The single value byte a SET_DEVICE_CONFIG_VALUE payload carries immediately after the 32-byte
     *  NUL-padded name field, or null when the payload is too short to hold one. The gate only ever writes
     *  single-character values ('0'/'1'), so this one byte is the whole value. Used to tell a turn-OFF write
     *  from a turn-ON write in [admitsSend]. Twin of Swift `DeviceConfigWriteGate.valueByte(inSendPayload:)`. */
    fun valueByteInSendPayload(payload: ByteArray): Int? {
        if (payload.size <= 1 + NAME_FIELD_BYTES) return null
        if ((payload[0].toInt() and 0xFF) != 0x01) return null
        return payload[1 + NAME_FIELD_BYTES].toInt() and 0xFF
    }

    // The allowlist predicate -----------------------------------------------------------------------

    /**
     * Whether a device-config KEY may be written, given the two opt-ins and the hardware attestation.
     *
     * `false` for every key that is not one of the two named ones — including all five of
     * [OUT_OF_SCOPE_KEYS], and including any key a future edit invents. The ECG key additionally requires
     * [isMG]: `Whoop5Variant.UNKNOWN` is not MG, so an unattested strap fails this the same way a plain
     * 5.0 does.
     */
    fun isWritableKey(
        key: String,
        ecgGateOptIn: Boolean,
        isMG: Boolean,
        broadcastHrOptIn: Boolean,
    ): Boolean = when (key) {
        ECG_RAW_DATA_KEY -> ecgGateOptIn && isMG
        BROADCAST_HR_KEY -> broadcastHrOptIn
        else -> false
    }

    /**
     * **The send allowlist itself.** True only for `SET_DEVICE_CONFIG_VALUE(119)` carrying a well-formed
     * body whose key passes [isWritableKey].
     *
     * Every other opcode is false — explicitly including `SET_FF_VALUE(120)`, which the R22 sequence keeps
     * its own separate clause for and which must never be reachable from here.
     */
    fun admitsSend(
        opcode: Int,
        payload: ByteArray,
        ecgGateOptIn: Boolean,
        isMG: Boolean,
        broadcastHrOptIn: Boolean,
    ): Boolean {
        if (opcode != SET_DEVICE_CONFIG_VALUE_CMD) return false
        val key = keyNameInSendPayload(payload) ?: return false
        // #1061: turning the Broadcast-HR flag OFF is the safe UNDO and must NEVER be gated on the opt-in.
        // The opt-in is bound straight to the Settings switch, so it is already false by the time the user
        // disables — gating the OFF write on it made the toggle-off path DEAD (the disable refused here, the
        // strap left advertising, the app unable to clear it). Same lesson the #174 R22 disable clause
        // records for SET_FF_VALUE. Admit the Broadcast-HR OFF write unconditionally; the ON write (and the
        // ECG key, both directions) stay gated by [isWritableKey]. Byte-identical to the Swift twin.
        if (key == BROADCAST_HR_KEY && valueByteInSendPayload(payload) == DISABLED_VALUE) return true
        return isWritableKey(key, ecgGateOptIn, isMG, broadcastHrOptIn)
    }

    /** The read verb the post-write verification is allowed to send, and only that one. */
    fun isReadBackOpcode(opcode: Int): Boolean = opcode == GET_DEVICE_CONFIG_VALUE_CMD

    // Frames ----------------------------------------------------------------------------------------

    /**
     * The `SET_DEVICE_CONFIG_VALUE(119)` payload that sets the ECG gate.
     *
     * Deliberately the SAME 33-byte single-value body the Broadcast-HR write has used on real hardware
     * since #181 — `[0x01] + [name NUL-padded to 32][value]`. The strap serves multi-character values
     * (`max_collection_backlog` reads `"0.0"`), so the READ side must handle them; but this key's observed
     * value is a single ASCII digit and a one-character write is the shape hardware has already accepted.
     */
    fun writePayload(on: Boolean): ByteArray =
        byteArrayOf(0x01) + Whoop5Config.deviceConfigBody(ECG_RAW_DATA_KEY, value(on))

    /** The `GET_DEVICE_CONFIG_VALUE(121)` payload that reads the ECG gate back. */
    fun readBackPayload(): ByteArray = DeviceConfigReadProbe.requestBody(ECG_RAW_DATA_KEY)
}

/**
 * The result of one ECG-gate write + mandatory read-back, as a copyable report.
 *
 * Order-dependent and pure (noteWriteAck → noteReadBack/noteReadBackTimeout → render), so the unit tests
 * cover the whole verdict table without a strap. Twin of the Swift `EcgRawDataGateReport`; [render] is
 * byte-identical across platforms so a shared strap log reads the same either side.
 */
class EcgRawDataGateReport(on: Boolean) {

    /** What the run established. Deliberately blunt about the case that matters: a write whose ack said
     *  SUCCESS but whose read-back did not move is [UNCHANGED], not success. */
    enum class Verdict(val label: String) {
        /** Read-back returned exactly the value that was requested. The only success case. */
        CONFIRMED("confirmed"),

        /** Read-back returned a DIFFERENT value than requested — the write did not take. */
        UNCHANGED("unchanged"),

        /** The strap answered the read-back but did not echo the key, so no value can be claimed. */
        NOT_CLAIMED("notClaimed"),

        /** The strap refused the read-back verb, or answered FAILURE for the key. */
        REFUSED("refused"),

        /** No reply to the read-back inside its window. */
        SILENT("silent"),

        /** A reply arrived that could not be decoded (CRC, envelope, short record). */
        UNDECODABLE("undecodable"),

        /** The read-back has not resolved yet. */
        PENDING("pending"),
    }

    /** The value that was requested, as the strap stores it ("1" or "0"). */
    val requested: String = DeviceConfigWriteGate.valueString(on)

    /** Result code of the WRITE's own COMMAND_RESPONSE, when one arrived. Recorded, never trusted. */
    var writeResultCode: Int? = null
        private set

    /** The value the read-back actually returned. null means "no value claimed", never "zero". */
    var storedValue: String? = null
        private set

    /** Result code of the READ-BACK's COMMAND_RESPONSE. */
    var readBackResultCode: Int? = null
        private set

    /** Raw read-back record bytes as hex, always reported whatever else decodes. */
    var readBackRecordHex: String? = null
        private set

    private val _trace = mutableListOf<String>()

    /** Trace lines, one per round-trip. */
    val trace: List<String> get() = _trace

    /** The verdict so far. */
    var verdict: Verdict = Verdict.PENDING
        private set

    init {
        _trace.add(
            "SET_DEVICE_CONFIG_VALUE(119) key=\"${DeviceConfigWriteGate.ECG_RAW_DATA_KEY}\" " +
                "value='$requested' sent",
        )
    }

    /** Record the write's own ack. It is logged and NOT used to decide anything: #891 established that a
     *  SUCCESS result code does not prove state changed. */
    fun noteWriteAck(resultCode: Int?) {
        writeResultCode = resultCode
        val label = resultCode?.let { "${FeatureFlagProbe.resultLabel(it)}($it)" } ?: "(unlabelled)"
        _trace.add(
            "write ack → result=$label — recorded, not treated as proof; the read-back below is the proof",
        )
    }

    /** Record the decoded read-back and reach a verdict. */
    fun noteReadBack(r: DeviceConfigReadProbe.ValueResponse) {
        readBackResultCode = r.resultCode
        readBackRecordHex = r.recordHex
        // The gate stores a single ASCII digit ('0'/'1'), so the one byte after the echoed name field is
        // the whole value — read it with the shared read-probe's single-byte accessor. (Multi-character
        // device-config values like max_collection_backlog="0.0" belong to the read probe, not this gate.)
        val stored = r.valueFor(DeviceConfigWriteGate.ECG_RAW_DATA_KEY)
            ?.takeIf { it in 0x20..0x7E }?.toChar()?.toString()
        storedValue = stored
        val sb = StringBuilder(
            "GET_DEVICE_CONFIG_VALUE(121) key=\"${DeviceConfigWriteGate.ECG_RAW_DATA_KEY}\"",
        )
        val c = r.resultCode
        if (c != null) sb.append(" → result=${FeatureFlagProbe.resultLabel(c)}($c)") else sb.append(" →")
        if (stored != null) sb.append(" value='$stored'")
        sb.append(" record=[${r.recordHex}]")
        _trace.add(sb.toString())

        verdict = when {
            r.isUnsupported || r.isFailure -> Verdict.REFUSED
            stored == null -> Verdict.NOT_CLAIMED
            stored == requested -> Verdict.CONFIRMED
            else -> Verdict.UNCHANGED
        }
    }

    /** Record a read-back reply that could not be decoded. */
    fun noteReadBackFailure(f: DeviceConfigReadProbe.ParseFailure) {
        val why = when (f) {
            DeviceConfigReadProbe.ParseFailure.CRC -> "CRC failed — frame rejected (never decoded)"
            DeviceConfigReadProbe.ParseFailure.ENVELOPE -> "not a COMMAND_RESPONSE envelope"
            DeviceConfigReadProbe.ParseFailure.WRONG_COMMAND -> "COMMAND_RESPONSE for a different command"
            DeviceConfigReadProbe.ParseFailure.TRUNCATED -> "record too short to hold a response"
        }
        _trace.add("read-back reply not decoded: $why")
        verdict = Verdict.UNDECODABLE
    }

    /** Record the strap answering nothing at all to the read-back. */
    fun noteReadBackTimeout(seconds: Int) {
        _trace.add("GET_DEVICE_CONFIG_VALUE(121) → no COMMAND_RESPONSE within ${seconds}s")
        verdict = Verdict.SILENT
    }

    /** One-line summary, suitable for a Settings row. */
    val summary: String
        get() = when (verdict) {
            Verdict.CONFIRMED ->
                "Strap now reports ${DeviceConfigWriteGate.ECG_RAW_DATA_KEY}='$requested' " +
                    "(read back, not just acked)."
            Verdict.UNCHANGED ->
                "Write did NOT take: asked for '$requested', strap still reports '${storedValue ?: "?"}'."
            Verdict.NOT_CLAIMED ->
                "Strap answered the read-back but did not echo the key, so no value is claimed."
            Verdict.REFUSED ->
                "Strap refused the read-back for this key — the stored value is unknown."
            Verdict.SILENT -> "No reply to the read-back — the stored value is unknown."
            Verdict.UNDECODABLE ->
                "The read-back reply did not decode — the stored value is unknown."
            Verdict.PENDING -> "Waiting for the read-back…"
        }

    /** The full copyable report. */
    fun render(): String {
        val sb = StringBuilder()
        sb.append("#891 ECG RAW-DATA GATE — WHOOP MG\n")
        sb.append("Key: ${DeviceConfigWriteGate.ECG_RAW_DATA_KEY} ")
        sb.append("(the strap's own 115/116 enumeration listed it)\n")
        sb.append("Wrote '$requested' via SET_DEVICE_CONFIG_VALUE(119), then read it back with ")
        sb.append("GET_DEVICE_CONFIG_VALUE(121). SET_FF_VALUE(120) is never sent from this path, and no ")
        sb.append("other device-config key is writable from it.\n")
        sb.append("\nVerdict: ${verdict.label} — $summary\n")
        sb.append("\nExchange:\n")
        for (line in _trace) sb.append("  ").append(line).append("\n")
        sb.append("\nWhether this gate actually produces ECG data is UNKNOWN. If it now reads '1' and a ")
        sb.append("TOGGLE_LABRADOR listen still yields zero packets, that is a real result for #891 — ")
        sb.append("please share this report there either way.\n")
        return sb.toString()
    }
}
