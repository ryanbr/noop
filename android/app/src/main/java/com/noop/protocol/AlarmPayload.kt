package com.noop.protocol

import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId

/**
 * WHOOP 5.0/MG ("puffin") firmware wake-alarm command payload encoder.
 *
 * These are WHOOP 5.0/MG protocol facts — command numbers, field offsets, byte layouts — documented
 * as factual wire-format observations for interoperability; no proprietary code is reproduced.
 * (Adopted from PR #85, iHateSubscriptions.)
 *
 * EXPERIMENTAL: unlike the maverick buzz (hardware-confirmed on a real MG), the rev4 alarm layout
 * below is self-consistent and modelled on the official app, and one full wake chain has been
 * captured on an MG, STRAP_DRIVEN_ALARM_EXECUTED (57) then HAPTICS_FIRED (60) (#864, 2026-08-25),
 * with a second wake reported on a 5.0 without a log (#2464). Neither has been shown to repeat, so
 * the caller still gates it behind Protocol probes so a normal user can't rely on an alarm that
 * might silently not fire. All multi-byte fields are little-endian.
 */
object AlarmPayload {
    private const val OVERALL_LOOP: Byte = 7        // overallWaveformLoopControl (alarm pattern)
    private const val DURATION_SECONDS: Byte = 30   // alarmDurationInSeconds

    /** The canonical WHOOP wake waveform-effect pair (same 47/152 the notification buzz uses). */
    private val WAVEFORM_EFFECTS = byteArrayOf(47, 152.toByte(), 0, 0, 0, 0, 0, 0)

    /**
     * Next future epoch-millis for local wake [hour]:[minute], relative to [nowMs] in [zone].
     * Today's occurrence if strictly in the future, else tomorrow's (next occurrence after now).
     */
    fun nextWakeEpochMs(hour: Int, minute: Int, nowMs: Long, zone: ZoneId): Long {
        val now = Instant.ofEpochMilli(nowMs).atZone(zone)
        val candidate = now.with(LocalTime.of(hour, minute, 0, 0)) // second + nanos cleared → subseconds 0
        val target = if (candidate.toInstant().toEpochMilli() > nowMs) candidate else candidate.plusDays(1)
        return target.toInstant().toEpochMilli()
    }

    /**
     * SET_ALARM_TIME (cmd 66) REVISION_4 body — 20 bytes; the strap arms its own RTC and fires the
     * wake haptic itself (a strap-driven wake event) even with the phone away. Wire layout:
     * ```
     *   [0]      0x04 (REVISION_4)
     *   [1]      alarmId
     *   [2..5]   u32 LE epoch seconds
     *   [6..7]   u16 LE subseconds = (ms % 1000) * 32768 / 1000   (1/32768-s fixed point)
     *   [8..19]  haptic pattern: 8 effects + u16 LE loopControl(0) + overallLoop(7) + duration(30)
     * ```
     */
    fun build(wakeEpochMs: Long, alarmId: Int = 1): ByteArray {
        val seconds = wakeEpochMs / 1000L
        val subseconds = ((wakeEpochMs % 1000L) * 32768L) / 1000L // u16 fixed point
        val out = ByteArray(20)
        out[0] = 4 // REVISION_4
        out[1] = alarmId.toByte()
        out[2] = (seconds and 0xFF).toByte()
        out[3] = ((seconds ushr 8) and 0xFF).toByte()
        out[4] = ((seconds ushr 16) and 0xFF).toByte()
        out[5] = ((seconds ushr 24) and 0xFF).toByte()
        out[6] = (subseconds and 0xFF).toByte()
        out[7] = ((subseconds ushr 8) and 0xFF).toByte()
        System.arraycopy(WAVEFORM_EFFECTS, 0, out, 8, 8)
        out[16] = 0x00 // loopControlForEffects LE lo
        out[17] = 0x00 // loopControlForEffects LE hi
        out[18] = OVERALL_LOOP
        out[19] = DURATION_SECONDS
        return out
    }

    /** DISABLE_ALARM (cmd 69) REVISION_2 body `[0x02, 0xFF]` (the 5/MG form). */
    fun disableRev2(): ByteArray = byteArrayOf(0x02, 0xFF.toByte())
}
