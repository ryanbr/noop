import Foundation

/// WHOOP 5.0 / MG (device family GOOSE/MAVERICK) haptic + alarm command payload encoders.
///
/// These are WHOOP 5.0/MG protocol facts — command numbers, field offsets and byte layouts —
/// documented as factual wire-format observations for interoperability; no proprietary code is
/// reproduced (see ATTRIBUTION.md / DISCLAIMER.md). Swift twin of the Android
/// `protocol/AlarmPayload.kt`; byte parity is pinned by cross-platform golden frames in both
/// test suites. All multi-byte fields are little-endian. Revision values: REVISION_1=1,
/// REVISION_2=2, REVISION_4=4.
///
/// EXPERIMENTAL / UNCONFIRMED (same posture as the Android client): unlike the maverick buzz
/// (hardware-confirmed on a real MG), the rev4 alarm layout is self-consistent and arming has
/// been ACKed on hardware, but a strap-driven wake fire has NOT been captured on our side
/// (no STRAP_DRIVEN_ALARM_EXECUTED event observed yet).

/// The canonical WHOOP waveform-effect pair, used by both the notification buzz and the wake alarm.
private let waveformEffects: [UInt8] = [47, 152, 0, 0, 0, 0, 0, 0]

public enum MaverickHaptics {
    /// 12-byte payload for RUN_HAPTIC_PATTERN_MAVERICK (cmd 19/0x13) — a one-shot buzz on a 5/MG
    /// strap: `[REVISION_1][waveFormEffect1..8][loopControlForEffects u16 LE = 0][overallLoop]`.
    /// `loops` maps to overallWaveformLoopControl; the official "buzz once" notification is 1.
    ///
    /// NOTHING SHIPS THIS (#926). `BLEManager.send` / `WhoopBleClient.send` substitute their own literal
    /// `[0x01, 47, 152, 0, …, 0]` for a 5/MG buzz, whose `overallLoop` is 0 — so the caller's repeat count
    /// never reaches the wire and this function's only callers are two assertions in
    /// `DeviceFamilyFramingTests`. There is no Kotlin twin. Kept because it is the only code that knows how
    /// to build a VARIABLE-loop buzz body, which is exactly what a future test of `overallLoop != 0` would
    /// need; the shipped literal is hardware-confirmed at 0 and deliberately unchanged until someone probes
    /// it (the alarm path already ships 7, so the field itself is accepted non-zero).
    public static func notificationBuzz(loops: Int) -> [UInt8] {
        [0x01] + waveformEffects + [0x00, 0x00, UInt8(clamping: loops)]
    }
}

public enum AlarmPayload {
    /// SET_ALARM_TIME (cmd 66) REVISION_4 body — 20 bytes; the strap arms its own RTC and fires the
    /// wake haptic itself (a strap-driven wake event) even with the Mac asleep. Wire layout,
    /// confirmed against captured frames:
    /// ```
    ///   [0]      0x04 (REVISION_4)
    ///   [1]      alarmId
    ///   [2..5]   u32 LE epoch seconds
    ///   [6..7]   u16 LE subseconds = (ms % 1000) * 32768 / 1000   (1/32768-s fixed point)
    ///   [8..19]  haptic pattern: 8 effects + u16 LE loopControl(0) + overallLoop(7) + duration(30)
    /// ```
    public static func setAlarmRev4(wakeEpochMs: Int64, alarmId: UInt8 = 1) -> [UInt8] {
        // Clamp rather than trap (matches armStrapAlarm's WHOOP4 posture for absurd dates).
        let seconds = UInt32(clamping: wakeEpochMs / 1000)
        let subseconds = UInt16(clamping: (max(0, wakeEpochMs % 1000) * 32768) / 1000)
        return [0x04, alarmId,
                UInt8(seconds & 0xFF), UInt8((seconds >> 8) & 0xFF),
                UInt8((seconds >> 16) & 0xFF), UInt8((seconds >> 24) & 0xFF),
                UInt8(subseconds & 0xFF), UInt8((subseconds >> 8) & 0xFF)]
            + waveformEffects
            + [0x00, 0x00, 0x07, 30]   // loopControl u16 LE, overallLoop=7, duration=30 s
    }

    /// DISABLE_ALARM (cmd 69) REVISION_2 body `[0x02, 0xFF]` (the 5/MG form).
    public static func disableRev2() -> [UInt8] { [0x02, 0xFF] }

    /// RUN_ALARM (cmd 68) REVISION_2 body `[0x02, alarmId]` — fire the stored alarm now.
    public static func runAlarmRev2(alarmId: UInt8 = 1) -> [UInt8] { [0x02, alarmId] }
}
