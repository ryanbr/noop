package com.noop.protocol

// WHOOP 5.0 / MG "R22" feature-flag config (deep-stream unlock) — direct port of the macOS/iOS
// `Whoop5Config` (Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5Config.swift).
//
// WHOOP 5/MG straps withhold their deep biometric streams (the high-rate "R22" optical/HR/motion
// packets, type 0x2F) from a freshly-connected client. The official app switches them on by writing
// a short burst of persistent feature-flag config values right after the hello handshake — a sequence
// independently documented by two third parties: judes.club's "Cracking the WHOOP 5 Bluetooth
// Protocol" (whose interactive frame-builder is the byte-level ground truth this is validated against)
// and Asherlc/dofek's docs/whoop-ble-protocol.md (Android APK decompilation), which corroborate the
// key names, values and the SET_FF_VALUE (0x78) opcode.
//
// Each flag is one SET_CONFIG (0x78) command whose 40-byte payload is the flag NAME as ASCII,
// NUL-padded to 32 bytes, then a one-byte value (itself an ASCII digit: '1'=0x31 or '2'=0x32) at
// offset 32, then 7 zero bytes. The inner b3 byte (0x01) is carried as the first payload byte ahead
// of the body, exactly like CLIENT_HELLO. Reversible (only changes which data the strap emits), gated
// behind an explicit opt-in, and writable only on real iOS/Android hardware. (#174)
object Whoop5Config {

    /** SET_CONFIG / SET_FF_VALUE command opcode. */
    const val SET_CONFIG_CMD = 0x78

    /** SET_DEVICE_CONFIG opcode (0x77). Writes one persistent device-config value (vs the feature-flag
     *  SET_CONFIG/0x78). Used for the Broadcast-HR flag; validated on real hardware. Keep in lockstep
     *  with the Swift `Whoop5Config.setDeviceConfigCmd`. (#181) */
    const val SET_DEVICE_CONFIG_CMD = 0x77

    /** One persistent feature flag and the value the official app writes for it (ASCII '1'/'2'). */
    data class Flag(val name: String, val value: Int)

    /** The exact ordered enable sequence the official app sends (values ASCII '1'/'2').
     *  `enable_r22_packets` opens the type-0x2F biometric stream; the rest tune channel selection, wear
     *  detection and sleep behaviour. Flags 1–15 are transcribed verbatim from judes.club's frame-builder
     *  FLAGS array; flag 16 `enable_sig12` is NOT in that array — it was observed as a 16th SET_FF_VALUE
     *  write in a real on-strap iOS HCI capture (WHOOP 5.0, #103) that otherwise reproduced flags 1–15
     *  byte-for-byte in this order. `enable_sig12`'s value was corrected 0x32→0x31 (#423): a second real
     *  on-strap capture, this time spanning a live workout, reproduced flags 1–15 identically but decoded
     *  enable_sig12 as ASCII '1'. Keep in lockstep with the Swift `Whoop5Config.enableR22Sequence`. */
    val enableR22Sequence: List<Flag> = listOf(
        Flag("enable_r22_packets", 0x32),
        Flag("enable_r22_v2_packets", 0x32),
        Flag("enable_r22_v3_packets", 0x32),
        Flag("enable_r22_v4_packets", 0x31),
        Flag("enable_r22_v5_packets", 0x32),
        Flag("enable_r22_v6_packets", 0x32),
        Flag("enable_r22_v8_packets", 0x32),
        Flag("make_hrfm_visible", 0x32),
        Flag("disable_pip_r26_packets", 0x32),
        Flag("wear_detect_bias", 0x32),
        Flag("hr_ch_switching", 0x32),
        Flag("ir_hw_switching", 0x32),
        Flag("enable_passive_strap_fit_gen5", 0x31),
        Flag("enable_sig11_during_sleep", 0x32),
        Flag("dorset_inhibit_wpt", 0x32),
        Flag("enable_sig12", 0x31),   // #423: real on-strap capture during a live workout, corrected from 0x32
    )

    /** The 40-byte SET_CONFIG payload body: flag name as ASCII NUL-padded to 32 bytes, value byte at
     *  offset 32, then 7 zero bytes. (Mirrors judes.club `setConfigPayload(name, value)`.) */
    fun payloadBody(name: String, value: Int): ByteArray {
        val p = ByteArray(40)
        val bytes = name.toByteArray(Charsets.US_ASCII)
        for (i in 0 until minOf(32, bytes.size)) p[i] = bytes[i]
        p[32] = (value and 0xFF).toByte()
        return p
    }

    /** The device-config write body: key name as ASCII NUL-padded to 32 bytes, then the value byte (an
     *  ASCII digit, e.g. '1'=0x31 / '0'=0x30). 33 bytes, no trailing padding (unlike the 40-byte
     *  feature-flag body). The caller prepends the b3 byte (0x01) before sending, like CLIENT_HELLO.
     *  Validated for whoop_live_hr_in_adv_ind_pkt on real hardware (paired on a Garmin Edge 840).
     *  Keep in lockstep with the Swift `Whoop5Config.deviceConfigBody`. (#181) */
    fun deviceConfigBody(name: String, value: Int): ByteArray {
        val b = ByteArray(33)
        val bytes = name.toByteArray(Charsets.US_ASCII)
        for (i in 0 until minOf(32, bytes.size)) b[i] = bytes[i]
        b[32] = (value and 0xFF).toByte()
        return b
    }

    /** The full puffin command-frame bytes for one feature-flag write (b3=0x01 ahead of the body),
     *  ready to send to the 5/MG command characteristic. Byte-for-byte identical to the official
     *  app's captured writes and to the Swift `Whoop5Config.frame`. */
    fun frame(flag: Flag, seq: Int): ByteArray =
        Framing.puffinCommandFrame(
            cmd = SET_CONFIG_CMD,
            seq = seq,
            payload = byteArrayOf(0x01) + payloadBody(flag.name, flag.value),
        )

    // Turning it back off (#174) ------------------------------------------------------------------

    /**
     * The value byte written to clear a feature flag: ASCII '0' (0x30).
     *
     * **Confirmed for the sibling opcode, inferred here by shared convention.**
     *
     * Confirmed on real hardware: 0x30 is how this firmware spells "off" for a config key. NOOP has
     * shipped that write since #181 — Broadcast-HR off writes 0x30 to `whoop_live_hr_in_adv_ind_pkt`
     * through SET_DEVICE_CONFIG_VALUE (119 / 0x77) and a Garmin Edge 840 stops seeing the broadcast.
     * `enable_raw_data_w_ecg` independently READS '0' on an MG whose ECG is not running. Both are the
     * device-config namespace.
     *
     * Shared convention, which is why it transfers: both bodies are the key name as ASCII NUL-padded to
     * 32 bytes then a single ASCII-digit value byte at offset 32, both are sent as `[0x01] + body` with
     * response. Only the opcode (0x77 vs 0x78) and the body length (33 vs 40) differ. Writes through
     * 0x78 demonstrably land and change stored state: the enable sequence moved `enable_sig12` from '2'
     * to '1', confirmed by a GET_FF_VALUE(128) read before and after.
     *
     * Inferred, stated plainly: '0' has NEVER been observed in the feature-flag namespace — every 128
     * read ever taken returned '1' or '2', and those are a round-trip of NOOP's own writes. The two
     * namespaces are proven separate at the verb level (a key asked through the wrong verb answers
     * FAILURE). And `disable_pip_r26_packets` is written '2' despite being named `disable_*`, while
     * `enable_sig12` was corrected '2'→'1' from a real capture — so the official app picks BETWEEN '1'
     * and '2' per flag rather than using one canonical "true", and tri-state semantics stay unestablished.
     *
     * So [R22DisableReport] tests the byte instead of asserting it: write it to ONE flag, read it back,
     * and only touch the rest if the strap stopped reporting the old value. Keep in lockstep with the
     * Swift `Whoop5Config.featureFlagOffValue`.
     */
    const val FEATURE_FLAG_OFF_VALUE = 0x30

    /**
     * The inverse of [enableR22Sequence]: the same sixteen keys, in the same order, each carrying
     * [FEATURE_FLAG_OFF_VALUE].
     *
     * Same order as the enable sequence deliberately — `enable_r22_packets`, the master flag, is cleared
     * FIRST, so a run interrupted by a disconnect leaves the strap nearer "off" than it started rather
     * than stranded with sub-streams cleared and the master still set.
     *
     * On `disable_pip_r26_packets`, whose name inverts: this sequence is the UNDO of the enable sequence,
     * not a per-key semantic inversion. Inverting per key would require knowing what '1' and '2' each
     * select, and that key is the evidence we do not. Writing '0' to it is expected to stop PIP R26
     * packets being suppressed — i.e. let them flow again, which is the pre-R22 behaviour.
     *
     * This does NOT restore a snapshot: NOOP never read these values before first writing them, so the
     * pre-NOOP state is unknown. The honest claim is "clears the sixteen flags NOOP set".
     * Keep in lockstep with the Swift `Whoop5Config.disableR22Sequence`.
     */
    val disableR22Sequence: List<Flag> = enableR22Sequence.map { Flag(it.name, FEATURE_FLAG_OFF_VALUE) }

    /** Every frame in the disable sequence, sequence-numbered from [firstSeq]. Written exactly like the
     *  enable frames — same opcode, same 40-byte body, same spacing, with response — because they differ
     *  only in the value byte. */
    fun disableSequenceFrames(firstSeq: Int = 1): List<ByteArray> =
        disableR22Sequence.mapIndexed { idx, flag -> frame(flag, (firstSeq + idx) and 0xFF) }
}
