import Foundation

// MARK: - WHOOP 5.0 / MG "R22" feature-flag config (deep-stream unlock)
//
// WHOOP 5.0/MG straps withhold their deep biometric streams (the high-rate "R22" optical/HR/motion
// packets, type 0x2F) from a freshly-connected client. The official app switches them on by writing a
// short burst of persistent feature-flag config values right after the hello handshake — a sequence
// independently documented by two third parties:
//   • judes.club, "Cracking the WHOOP 5 Bluetooth Protocol" (decrypted HCI capture of the official app),
//     whose interactive frame-builder is the byte-level ground truth this file is validated against.
//   • Asherlc/dofek docs/whoop-ble-protocol.md (Android APK decompilation), corroborating the key names,
//     values and the SET_FF_VALUE (0x78) opcode.
//
// Each flag is ONE `SET_CONFIG` (0x78) command whose 40-byte payload is the flag NAME as ASCII, NUL-padded
// to 32 bytes, followed by a one-byte value (itself an ASCII digit: '1' = 0x31 or '2' = 0x32) at offset 32,
// then 7 bytes of zero. The command is built with the normal puffin envelope via `puffinCommandFrame`
// (cmd 0x78, the inner b3 byte 0x01 carried as the first payload byte, exactly like CLIENT_HELLO).
//
// It is gated behind an explicit opt-in in the app, and on real hardware it can only be written from
// iOS/Android: macOS CoreBluetooth cannot complete the authenticated SMP bond the command characteristic
// requires.
//
// **Reversing it.** The write only changes which data the strap chooses to emit, and the same opcode that
// sets a flag can clear it — see `disableR22Sequence` below, and `R22DisableReport` for the write +
// mandatory read-back that proves what the strap actually stores. For the first year of this file that
// claim was made in a comment with nothing implementing it; the value byte that spells "off" is still
// inferred rather than observed, which is why the disable path tests it on one key before touching the
// rest. Read `featureFlagOffValue` before relying on any of this.
public enum Whoop5Config {

    /// SET_CONFIG / SET_FF_VALUE command opcode.
    public static let setConfigCmd: UInt8 = 0x78

    /// SET_DEVICE_CONFIG opcode (0x77) — writes ONE persistent device-config value, distinct from the
    /// feature-flag SET_CONFIG (0x78) sequence above. Used for the "Broadcast HR" flag
    /// (`whoop_live_hr_in_adv_ind_pkt`), which makes the strap advertise its heart rate as a standard
    /// 0x180D BLE sensor. Validated on real hardware (paired on a Garmin Edge 840). (#181)
    public static let setDeviceConfigCmd: UInt8 = 0x77

    /// One persistent feature flag and the value the official app writes for it.
    public struct Flag: Equatable, Sendable {
        public let name: String
        public let value: UInt8   // ASCII digit byte: 0x32 = '2', 0x31 = '1'
        public init(_ name: String, _ value: UInt8) { self.name = name; self.value = value }
    }

    /// The exact ordered enable sequence the official app sends (values are ASCII '1'/'2').
    /// `enable_r22_packets` is what opens the type-0x2F biometric stream; the rest tune channel
    /// selection, wear detection and sleep behaviour.
    ///
    /// Flags 1–15 are transcribed verbatim from judes.club's frame-builder `FLAGS` array. Flag 16,
    /// `enable_sig12`, is NOT in that array: it was observed as a 16th `SET_FF_VALUE` write in a real
    /// on-strap iOS HCI capture of the official app (WHOOP 5.0, #103), which otherwise reproduced flags
    /// 1–15 byte-for-byte in this exact order. Its effect is undocumented (like `enable_sig11_during_sleep`);
    /// it is included because it is part of what the official app actually writes on every connect.
    /// `enable_sig12`'s value was corrected 0x32→0x31 (#423): a second real on-strap capture, this time
    /// spanning a live workout, reproduced flags 1–15 identically but decoded `enable_sig12` as ASCII '1'.
    public static let enableR22Sequence: [Flag] = [
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
    ]

    /// The 40-byte SET_CONFIG payload body: flag name as UTF-8/ASCII NUL-padded to 32 bytes, value byte
    /// at offset 32, then 7 zero bytes. (Mirrors judes.club `setConfigPayload(name, value)`.)
    public static func payloadBody(name: String, value: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 40)
        let bytes = Array(name.utf8)
        for i in 0..<min(32, bytes.count) { p[i] = bytes[i] }
        p[32] = value
        return p
    }

    /// The 33-byte SET_DEVICE_CONFIG body: key name as ASCII NUL-padded to 32 bytes, then the value byte
    /// (an ASCII digit, '1' = 0x31 / '0' = 0x30) at offset 32 — NO trailing padding (unlike the 40-byte
    /// feature-flag body). The caller prepends the inner b3 byte (0x01) before sending, like CLIENT_HELLO.
    /// Mirrors the Android `Whoop5Config.deviceConfigBody`; validated on real hardware. (#181)
    public static func deviceConfigBody(name: String, value: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 33)
        let bytes = Array(name.utf8)
        for i in 0..<min(32, bytes.count) { p[i] = bytes[i] }
        p[32] = value
        return p
    }

    /// The full puffin command-frame bytes for one feature-flag write, ready to send to the 5/MG
    /// command characteristic. The inner b3 byte (0x01, as SET_CONFIG-class commands require) is carried
    /// as the first payload byte ahead of the 40-byte body — matching the CLIENT_HELLO convention and
    /// byte-for-byte identical to the official app's captured writes.
    public static func frame(flag: Flag, seq: UInt8) -> [UInt8] {
        puffinCommandFrame(cmd: setConfigCmd, seq: seq, payload: [0x01] + payloadBody(name: flag.name, value: flag.value))
    }

    /// Every frame in the enable sequence, sequence-numbered from `firstSeq`. The caller writes these in
    /// order, WITH RESPONSE, spacing them out (the official app pauses ~tens of ms between writes), and
    /// only while the strap is on-wrist — the R22 stream is on-wrist gated.
    public static func enableSequenceFrames(firstSeq: UInt8 = 1) -> [[UInt8]] {
        enableR22Sequence.enumerated().map { idx, flag in
            frame(flag: flag, seq: UInt8((Int(firstSeq) + idx) & 0xFF))
        }
    }

    // MARK: - Turning it back off (#174)

    /// The value byte written to clear a feature flag: ASCII `'0'` (0x30).
    ///
    /// **Confirmed for the sibling opcode, inferred here by shared convention.** The distinction is worth
    /// stating precisely, because it is stronger than a guess and weaker than a measurement.
    ///
    /// *Confirmed, on real hardware:* `0x30` is how this firmware spells "off" for a config key. NOOP has
    /// shipped that write since #181 — `setBroadcastHr(false)` writes `0x30` to
    /// `whoop_live_hr_in_adv_ind_pkt` through `SET_DEVICE_CONFIG_VALUE` (119 / 0x77) and a Garmin Edge 840
    /// stops seeing the broadcast. `enable_raw_data_w_ecg` independently *reads* `'0'` on an MG whose ECG
    /// is not running. Both are the device-config namespace.
    ///
    /// *Shared convention, which is why it transfers:* the two namespaces are the same wire idiom. Both
    /// bodies are the key name as ASCII NUL-padded to 32 bytes followed by a single ASCII-digit value byte
    /// at offset 32, both are sent as `[0x01] + body` WITH RESPONSE, and `deviceConfigBody`'s own doc spells
    /// the value convention out as "an ASCII digit, '1' = 0x31 / '0' = 0x30". The only differences are the
    /// opcode (0x77 vs 0x78) and the body length (33 vs 40 bytes, the feature-flag body carrying 7 trailing
    /// zeroes). Nothing about 0x78 makes it one-way: writes through it demonstrably land and demonstrably
    /// change stored state — running `enableR22Sequence` moved `enable_sig12` from `'2'` (0x32) to `'1'`
    /// (0x31), confirmed by a `GET_FF_VALUE(128)` read before and after. A key that can be written is a key
    /// that can be rewritten.
    ///
    /// *Inferred, and stated plainly:* **`'0'` has never been observed in the feature-flag namespace.** Every
    /// `GET_FF_VALUE(128)` read ever taken returned `'1'` or `'2'` — and those sixteen readings are a
    /// round-trip of NOOP's own `enableR22Sequence` writes, so they say nothing about what the firmware does
    /// with a value it was not handed. The two namespaces are also proven separate at the verb level: a key
    /// asked through the wrong verb answers FAILURE. So the device-config evidence above is a strong
    /// argument by shared convention, not a measurement of this opcode.
    ///
    /// *And two pieces of counter-evidence, which is why "0 = false" is not assumed anywhere in this file:*
    /// `disable_pip_r26_packets` is written `'2'` despite being named `disable_*` — if these were plain
    /// booleans that key would be the one written `'0'`. And `enable_sig12` was corrected `'2'` → `'1'` from
    /// a real on-strap capture (#423), i.e. the official app picks *between* `'1'` and `'2'` per flag rather
    /// than using one canonical "true". Whatever those two values select, it is probably not a bare boolean,
    /// so tri-state `'0'`/`'1'`/`'2'` semantics stay UNESTABLISHED rather than assumed.
    ///
    /// *Which makes the read-back decisive rather than ceremonial.* A single `GET_FF_VALUE(128)` on the
    /// written key separates the three live possibilities, and `R22DisableReport` reports which one happened
    /// instead of averaging over them:
    ///
    /// | Read-back | Meaning |
    /// |---|---|
    /// | value `'0'` | The write landed and the key now HOLDS `'0'`. Cleared as a value — the expected success. |
    /// | `FAILURE(0)` | The key no longer has a stored value at all. Genuinely removed; nothing predicts this. |
    /// | value unchanged (`'2'`/`'1'`) | The write was refused or no-oped. `'0'` is not how this namespace says off. |
    ///
    /// Note that **enumeration cannot substitute for this read.** `'0'` is a stored value, not an absence —
    /// six of the seven keys the device-config walk returned read `'0'` and were still enumerated — so a
    /// cleared key stays present in a walk rather than dropping out. And the 117/118 feature-flag
    /// enumeration carries no value field at all (its record is `[revision][index][validKey][key]`), so it
    /// can only ever answer presence. `GET_FF_VALUE(128)` is the only verb that can verify a clear, and it
    /// answered cleanly for all sixteen flags on a 5/MG — the older 4.0-derived caution about a stale shared
    /// buffer contaminating its value field does not reproduce on this family.
    ///
    /// The path therefore writes `'0'` to ONE flag first, reads it back, and declines to touch the other
    /// fifteen unless the strap actually stopped reporting the old value. One round-trip converts the
    /// inference into a measurement on first run. See `R22DisableReport.probeKey` for why that key.
    ///
    /// What stays unverified even after a clean read-back is narrower than the byte: whether clearing the
    /// flags makes the strap's R22 *behaviour* revert. Only wearing the strap and watching the deep records
    /// stop answers that, and the report says so rather than claiming it.
    public static let featureFlagOffValue: UInt8 = 0x30

    /// The inverse of `enableR22Sequence`: the same sixteen keys, in the same order, each carrying
    /// `featureFlagOffValue`.
    ///
    /// **Same order as the enable sequence, deliberately.** `enable_r22_packets` — the master flag — is
    /// cleared FIRST, so a run interrupted by a disconnect leaves the strap nearer "off" than it started
    /// rather than stranded with sub-streams cleared and the master still set. It also keeps the two
    /// sequences trivially diffable: same names, same order, only the value byte differs.
    ///
    /// **On `disable_pip_r26_packets`, whose name inverts.** Fifteen of these keys read as "enable/tune X"
    /// and one reads as "disable X", so writing the same byte to all sixteen looks wrong at a glance. It is
    /// deliberate, and the reasoning is worth being explicit about because it is the one place a reviewer
    /// should push back.
    ///
    /// This sequence is defined as *the undo of the enable sequence* — clear every flag that sequence set —
    /// rather than as "set each flag to its semantic opposite". Those are different operations, and only
    /// the first one is well defined here. Inverting per key would require knowing what `'1'` and `'2'`
    /// each select, and this key is the evidence that we do not: a flag named `disable_*` written `'2'`
    /// alongside `enable_*` flags also written `'2'` cannot be reconciled with plain-boolean semantics.
    ///
    /// So: writing `'0'` to `disable_pip_r26_packets` is expected to stop PIP R26 packets being suppressed
    /// — i.e. to let them flow again, which is the pre-R22 behaviour and the correct restoration. The
    /// polarity inversion is real, but it lives in what the key MEANS, not in which byte undoes it, and it
    /// is called out in the report so nobody is surprised that one key's "off" is another feature's "on".
    /// `make_hrfm_visible`, `wear_detect_bias`, `hr_ch_switching`, `ir_hw_switching` and `dorset_inhibit_wpt`
    /// are milder versions of the same story: they tune behaviour rather than gate a stream, and clearing
    /// them returns that tuning to whatever the firmware does with the flag unset.
    ///
    /// **What this does NOT do: restore a snapshot.** NOOP has never read these values *before* writing
    /// them, so the strap's pre-NOOP state is unknown and unrecoverable. If the firmware's own default for
    /// some key is `'1'` rather than unset, this writes a value the factory never used. The honest claim
    /// is "clears the sixteen flags NOOP set", not "restores the strap to how it shipped". Making the
    /// stronger claim true needs a read-before-write snapshot on the ENABLE path; see #174.
    public static let disableR22Sequence: [Flag] = enableR22Sequence.map {
        Flag($0.name, featureFlagOffValue)
    }

    /// Every frame in the disable sequence, sequence-numbered from `firstSeq`. Written exactly like the
    /// enable frames — same opcode, same 40-byte body, same spacing, WITH RESPONSE — because they differ
    /// only in the value byte.
    public static func disableSequenceFrames(firstSeq: UInt8 = 1) -> [[UInt8]] {
        disableR22Sequence.enumerated().map { idx, flag in
            frame(flag: flag, seq: UInt8((Int(firstSeq) + idx) & 0xFF))
        }
    }
}
