package com.noop.protocol

/**
 * #1303: find a WHOOP 5/MG strap serial inside the GET_HELLO (145) info block.
 *
 * A stable per-strap id is the keystone the multi-strap work waits on, and today there is no strap
 * serial decoded anywhere: [BatteryPackInfo]'s serial is the BATTERY PACK's, read via cmd 151 and
 * answered only by a 5/MG, so it identifies a removable part rather than the strap wearing it.
 *
 * The 4.0 hunt has a capture aid already (the `GET_HELLO_HARVARD` (35) branch, which now reports
 * through this same probe — its payload carries a device key beside the serial). This is the 5/MG
 * half, and it needs no new traffic: the GET_HELLO block is ALREADY decoded — for the device name at
 * `pay[16]` and the firmware version at `pay[93]` — and everything else in it is simply discarded. If
 * the serial is in there, it is arriving on every connect and being thrown away.
 *
 * ## Why this reports structure instead of dumping the block
 *
 * The same response carries a SESSION TOKEN, which the decoder deliberately never reads. Dumping the
 * payload wholesale would put that token in a log, so this reports every printable run as
 * offset + length + class and prints the CONTENTS only of runs that could plausibly be the serial and
 * are not the already-known name: fully alphanumeric, [SERIAL_LEN_MIN]..[SERIAL_LEN_MAX] characters.
 *
 * That rule is a filter, not a guarantee — a token that happened to be alphanumeric and serial-length
 * would print. Which is precisely why the caller gates this behind an opt-in diagnostic rather than
 * the default, shareable strap log.
 *
 * Pure, so it unit-tests with no strap, no BLE and no Android. Byte-identical twin of the Swift
 * `HelloIdentityProbe`.
 */
object HelloIdentityProbe {

    const val SERIAL_LEN_MIN = 6
    const val SERIAL_LEN_MAX = 20

    /** ASCII digits/letters. A serial is alphanumeric; this is what separates a candidate from the
     *  punctuation-and-symbols runs that binary payloads produce by chance. */
    private fun isAlnum(b: Int): Boolean =
        (b in 48..57) || (b in 65..90) || (b in 97..122)

    /**
     * Printable-ASCII runs in a GET_HELLO payload, one line each, for a diagnostic log.
     *
     * [payload] is the GET_HELLO (145) response payload, token region included — nothing is stripped
     * before this call; the withholding happens here so a caller cannot get it wrong.
     * [knownNameOffset] is where the decoder already reads the device name (16 on the pinned capture);
     * a run starting there is labelled rather than printed. [minRun] is the shortest run worth
     * reporting — below it, a binary payload is all noise.
     */
    fun candidateLines(
        payload: ByteArray,
        knownNameOffset: Int = 16,
        minRun: Int = 4,
        serialLenMin: Int = SERIAL_LEN_MIN,
        serialLenMax: Int = SERIAL_LEN_MAX,
    ): List<String> {
        val out = ArrayList<String>()
        var i = 0
        while (i < payload.size) {
            val b = payload[i].toInt() and 0xFF
            if (b !in 32..126) { i++; continue }
            val start = i
            while (i < payload.size && (payload[i].toInt() and 0xFF) in 32..126) i++
            val run = payload.copyOfRange(start, i)
            if (run.size < minRun) continue

            val alnum = run.all { isAlnum(it.toInt() and 0xFF) }
            // The known-name offset is LABELLED but not suppressed. [knownNameOffset] is an assumption
            // taken from one firmware capture, and this is a discovery tool: if a firmware moved the name
            // and the serial landed here, suppressing the value would hide the exact thing being hunted.
            // Showing it costs nothing — the device name is already surfaced on the Devices card, so it is
            // not what the withholding rule exists to protect.
            var line = "off=$start len=${run.size} ${if (alnum) "alnum" else "mixed"}"
            if (start == knownNameOffset) line += " (device name, already decoded)"
            line += when {
                alnum && run.size in serialLenMin..serialLenMax -> " \"${String(run, Charsets.US_ASCII)}\""
                start != knownNameOffset -> " (withheld)"
                else -> ""
            }
            out.add(line)
        }
        return out
    }

    /**
     * One log line for the whole block: its length, and every candidate run.
     *
     * The length is reported even when nothing prints, because "no printable runs at all" is itself
     * the answer — it says the serial is not ASCII in this block and the search moves elsewhere.
     *
     * [block] names which response this payload came from, for the line's prefix. Defaults to the 5/MG
     * `GET_HELLO` this probe was written for; the WHOOP 4.0 `GET_HELLO_HARVARD(35)` capture aid passes
     * its own so one log can carry both without the two reading as the same frame. Twin of the Swift
     * `report(payload:block:…)`.
     */
    fun report(
        payload: ByteArray,
        block: String = "HELLO(145)",
        knownNameOffset: Int = 16,
        minRun: Int = 4,
        serialLenMin: Int = SERIAL_LEN_MIN,
        serialLenMax: Int = SERIAL_LEN_MAX,
    ): String {
        val lines = candidateLines(payload, knownNameOffset, minRun, serialLenMin, serialLenMax)
        val body = if (lines.isEmpty()) "none" else lines.joinToString("; ")
        return "$block block len=${payload.size} runs: $body"
    }
}
