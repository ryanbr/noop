package com.noop.protocol

/**
 * Decodes a `GET_BATTERY_PACK_INFO` (command 151) COMMAND_RESPONSE — the WHOOP 5.0/MG battery pack's
 * charge, serial and Bluetooth address, read THROUGH the strap (a 4.0 has no pack command). noop already
 * probes `GET_EXTENDED_BATTERY_INFO` (98), but the 5/MG reply to 98 is an undecoded stub; 151 is the
 * command that actually carries the pack's fuel gauge.
 *
 * Field offsets re-derived (clean-room; real captures, never invented offsets) from two captured 5/MG
 * frames — pack attached, then physically removed — so this is an UNVALIDATED CANDIDATE pending broader
 * hardware. Pure + deterministic; the Swift `BatteryPackInfo` (WhoopProtocol) is its byte-identical twin.
 */
object BatteryPackInfo {

    /** [present] tells an attached pack from a removed one — the command answers SUCCESS either way, so a
     *  removed pack's zeroed block is the only discriminator and MUST clear the card, never keep a stale
     *  charge. [socPct] is tenths-precision %, null when absent; [serial]/[btAddr] null when absent. */
    data class Info(
        val present: Boolean,
        val socPct: Double?,
        val serial: String?,
        val btAddr: String?,
    )

    /** Resp-cmd byte sits at [cmdOff] (10 on WHOOP 5/MG — the only family with a pack). Null when the
     *  frame is not a well-formed 151 SUCCESS response; the caller CRC-gates the frame (framing layer does). */
    fun decode(frame: ByteArray, cmdOff: Int = 10): Info? {
        // Layout vs cmdOff, pinned to the captures: +0 resp-cmd (151), +2 result (1 = SUCCESS), +4 present
        // flag, +5 BT address (6 bytes), +11 serial (16-byte ASCII, NUL-terminated), +27 SoC (u16 LE,
        // tenths of a percent).
        if (cmdOff < 0 || frame.size <= cmdOff + 4) return null
        if ((frame[cmdOff].toInt() and 0xFF) != 151 || (frame[cmdOff + 2].toInt() and 0xFF) != 1) return null
        val present = (frame[cmdOff + 4].toInt() and 0xFF) == 1
        if (!present) return Info(false, null, null, null)

        val btStart = cmdOff + 5
        val serStart = cmdOff + 11
        val socStart = cmdOff + 27
        if (frame.size < socStart + 2) return null

        val btAddr = (btStart until btStart + 6).joinToString("") { "%02x".format(frame[it].toInt() and 0xFF) }
        val serBytes = (serStart until serStart + 16).map { frame[it] }.takeWhile { it.toInt() != 0 }
        // Null on empty OR any non-ASCII byte, matching the Swift twin's `String(bytes:encoding:.ascii)`
        // (which returns nil for any byte > 127) — keeps the two byte-identical on a malformed serial.
        val serial = if (serBytes.isEmpty() || serBytes.any { (it.toInt() and 0xFF) >= 0x80 }) null
        else String(serBytes.toByteArray(), Charsets.US_ASCII)
        val raw = (frame[socStart].toInt() and 0xFF) or ((frame[socStart + 1].toInt() and 0xFF) shl 8)
        return Info(true, raw / 10.0, serial, btAddr)
    }
}
