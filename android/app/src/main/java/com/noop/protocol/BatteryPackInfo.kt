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

    /** [present]: from [decode] (5/MG, cmd 151) this is a REAL flag — a removed pack's zeroed block is the
     *  only discriminator, so an absent reply MUST clear the card. From [decodeExtended] (4.0, cmd 98) it
     *  only means "a voltage decoded" — cmd 98 has no presence flag and its voltage may be the strap's, so
     *  it's ~always true; real 4.0 pack presence must come from the attach/detach events, NOT this field.
     *  [socPct] is tenths-precision %, null when absent; [serial]/[btAddr] null when absent. */
    data class Info(
        val present: Boolean,
        val socPct: Double?,
        val serial: String?,
        val btAddr: String?,
        /** WHOOP 4.0 only: pack VOLTAGE in mV — a 4.0 has no fuel-gauge command, so its pack is read via
         *  GET_EXTENDED_BATTERY_INFO (98) which reports voltage, not a charge %. null on 5/MG. */
        val voltageMv: Int? = null,
    ) {
        /**
         * Whether this reading is safe to SHOW.
         *
         * The offsets here are an unvalidated candidate re-derived from two captures, so a wrong one
         * would not fail — it would render a confident wrong number, which is the failure this project
         * treats as worse than a blank. A fuel gauge is a percentage: anything outside 0..100 means the
         * offset moved, and the caller must render nothing rather than the value.
         */
        val displayable: Boolean
            get() = present && socPct != null && socPct >= 0.0 && socPct <= 100.0
    }

    /**
     * Decode the pack RECORD itself, given the offset of its present-flag byte.
     *
     * Split out from [decode] because the same record reaches us by two entirely different transports:
     * as the payload of a `GET_BATTERY_PACK_INFO` (151) COMMAND_RESPONSE, and — hardware-confirmed on
     * WHOOP MG fw 50.39.1.0, 2026-09-01 — as the payload of the UNCATALOGUED pushed event `0x6D` (109),
     * which the strap volunteers every couple of minutes while a pack is attached. Only the framing
     * around the record differs; the fields are identical, so they must not be decoded twice.
     *
     * Layout from [base]: +0 present, +1 BT address (6 B), +7 serial (16 B ASCII, NUL-terminated),
     * +23 SoC (u16 LE, tenths of a percent). Null when the buffer is too short to hold it.
     */
    fun decodeRecord(bytes: ByteArray, base: Int): Info? {
        if (base < 0 || bytes.size <= base) return null
        val present = (bytes[base].toInt() and 0xFF) == 1
        if (!present) return Info(false, null, null, null)

        val btStart = base + 1
        val serStart = base + 7
        val socStart = base + 23
        if (bytes.size < socStart + 2) return null

        val btAddr = (btStart until btStart + 6).joinToString("") { "%02x".format(bytes[it].toInt() and 0xFF) }
        val serBytes = (serStart until serStart + 16).map { bytes[it] }.takeWhile { it.toInt() != 0 }
        // Null on empty OR any non-ASCII byte, matching the Swift twin's `String(bytes:encoding:.ascii)`
        // (which returns nil for any byte > 127) — keeps the two byte-identical on a malformed serial.
        val serial = if (serBytes.isEmpty() || serBytes.any { (it.toInt() and 0xFF) >= 0x80 }) null
        else String(serBytes.toByteArray(), Charsets.US_ASCII)
        val raw = (bytes[socStart].toInt() and 0xFF) or ((bytes[socStart + 1].toInt() and 0xFF) shl 8)
        return Info(true, raw / 10.0, serial, btAddr)
    }

    /**
     * Decode the pack record from the pushed event `0x6D` (109) payload — the transport that actually
     * works on a 5/MG. The strap sends this unprompted while a pack is attached, so it needs no command,
     * no send-allowlist entry and no polling; the repeat cadence makes it a self-refreshing LEVEL signal
     * that cannot go stale. The record's present flag sits at payload offset 4.
     *
     * Confirmed against three consecutive captures from one MG (serial WBB5AP0000001, SoC 57.1 % ->
     * 56.9 % -> 56.7 % as the pack drained into the strap) — the falling trend is what establishes the
     * SoC word as tenths of a percent rather than a plausible-looking constant.
     */
    fun decodeEventPayload(payload: ByteArray): Info? = decodeRecord(payload, EVENT_RECORD_BASE)

    /** Offset of the present flag inside the event-109 payload. */
    const val EVENT_RECORD_BASE = 4

    /**
     * Decode straight from a whole 5/MG EVENT frame, so callers never have to know where the payload
     * starts. A 5/MG event's opaque payload begins at frame offset 16 (`Framing.decodeEventWhoop5`), so
     * the record's present flag lands at 16 + [EVENT_RECORD_BASE]. Keeping that arithmetic here means the
     * BLE layer passes the frame it already has and no offset knowledge leaks out of the protocol package.
     *
     * Callers must check the event number is [PACK_INFO_EVENT] first — this does not re-check it, because
     * the event byte lives in the frame header rather than the record.
     */
    fun decodeEventFrame(frame: ByteArray): Info? = decodeRecord(frame, WHOOP5_EVENT_PAYLOAD_START + EVENT_RECORD_BASE)

    /** Where a WHOOP 5/MG EVENT frame's opaque payload begins. Mirrors `Framing.decodeEventWhoop5`. */
    const val WHOOP5_EVENT_PAYLOAD_START = 16

    /** Uncatalogued 5/MG event that carries the pack record. Named here because `EventNumber` has no
     *  entry for it — it decodes as `0x6D(109)`. */
    const val PACK_INFO_EVENT = 109

    /** Resp-cmd byte sits at [cmdOff] (10 on WHOOP 5/MG — the only family with a pack). Null when the
     *  frame is not a well-formed 151 SUCCESS response; the caller CRC-gates the frame (framing layer does).
     *
     *  NOTE this command path is retained for completeness only. On WHOOP MG fw 50.39.1.0 opcode 151
     *  answers FAILURE(0) whether or not a pack is attached, so the feature is driven by
     *  [decodeEventPayload] instead. See docs/DESIGN-battery-pack-charge.md. */
    fun decode(frame: ByteArray, cmdOff: Int = 10): Info? {
        // Header, pinned to the captures: +0 resp-cmd (151), +2 result (1 = SUCCESS). The record then
        // starts at +4, which is what [decodeRecord] expects as its base.
        if (cmdOff < 0 || frame.size <= cmdOff + 4) return null
        if ((frame[cmdOff].toInt() and 0xFF) != 151 || (frame[cmdOff + 2].toInt() and 0xFF) != 1) return null
        return decodeRecord(frame, cmdOff + 4)
    }

    /**
     * WHOOP 4.0 path. A 4.0 has no `GET_BATTERY_PACK_INFO` (151); its pack is read via
     * `GET_EXTENDED_BATTERY_INFO` (98), which reports the pack VOLTAGE (mV) — NOT a charge %. Voltage at
     * payload bytes 7..8 (LE), i.e. `frame[cmdOff+8..cmdOff+9]`, confirmed on WHOOP4 (#592: a 3970 mV
     * capture); [cmdOff] is 6 on WHOOP4. Same offset noop's `ExtendedBatteryProbe` reads. Null when the
     * frame is not a 98 response with a voltage payload. Byte-identical twin of Swift `decodeExtended`.
     *
     * NOTE on `present`: cmd 98 has no present/absent flag (unlike 151), so `present` here only marks "a
     * voltage decoded" and is ~always true — NOT a reliable "pack attached" signal. A 4.0 UI must take pack
     * presence from the attach/detach events and use this only for the voltage reading.
     */
    fun decodeExtended(frame: ByteArray, cmdOff: Int = 6): Info? {
        // The voltage bytes must fall inside the payload (before the 4-byte CRC32 trailer) ⇒ len >= cmdOff+14.
        if (cmdOff < 0 || frame.size < cmdOff + 14 || (frame[cmdOff].toInt() and 0xFF) != 98) return null
        val mv = (frame[cmdOff + 8].toInt() and 0xFF) or ((frame[cmdOff + 9].toInt() and 0xFF) shl 8)
        // 0 mV is not a real reading (no pack / empty answer) → report absence, not "0.00 V".
        if (mv <= 0) return Info(false, null, null, null)
        return Info(true, null, null, null, voltageMv = mv)
    }
}
