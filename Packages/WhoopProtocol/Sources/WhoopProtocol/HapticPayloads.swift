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
    /// 12-byte payload for RUN_HAPTIC_PATTERN_MAVERICK (cmd 19/0x13) — a buzz on a 5/MG strap:
    /// `[REVISION_1][waveFormEffect1..8][loopControlForEffects u16 LE = 0][overallLoop]`.
    ///
    /// `overallLoop` counts the repeats that follow the FIRST pulse, not the total, so `loops` is written
    /// as `loops - 1`. HARDWARE-CONFIRMED on a real WHOOP 5/MG by @dwehrmann (#926): writing 3 produced
    /// FOUR buzzes. The model also explains the behaviour that shipped for years — the hardcoded `0` in
    /// `BLEManager.send` / `WhoopBleClient.send` meant "no repeats", which is exactly the single identical
    /// buzz every BuzzPattern used to give; a reading where 0 meant "zero buzzes" would predict silence.
    ///
    /// This function ENCODED THE OPPOSITE convention until that measurement existed — it wrote `loops`
    /// straight into the byte, so asking it for one buzz would have produced two. It was documented as the
    /// only code that knew how to build a variable-loop body, which is precisely why the error mattered:
    /// the next caller to adopt it would have inherited a silent off-by-one from the file that claims
    /// authority over this field.
    ///
    /// Clamped to 1...8 (`overallLoop` 0...7), 7 being the largest value any captured body evidences — the
    /// alarm's long wake train (`AlarmPayload.setAlarmRev4`, pinned in `DeviceFamilyFramingTests`). The old
    /// `UInt8(clamping:)` admitted 255, a value nothing has ever observed on the wire.
    ///
    /// Kotlin twin: `WhoopBleClient.maverickHapticBody`.
    public static func notificationBuzz(loops: Int) -> [UInt8] {
        [0x01] + waveformEffects + [0x00, 0x00, UInt8(min(max(loops, 1), 8) - 1)]
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
