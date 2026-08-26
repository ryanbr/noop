package com.noop.protocol

/**
 * Why a WHOOP 5/MG hello carried no firmware version, in enough detail to re-derive the offset.
 *
 * The version is read as four bytes at `pay[93]`, guarded by `pay[93] == 50` ("5.0 generation"). Both the
 * offset and the guard are anchored to a SINGLE capture at firmware 50.38.1.0, and the decoder's own
 * comment says so: the name+token region ahead of the version is fixed-width *on that firmware*, and
 * re-verifying the offset across firmwares is explicitly left as future work. The guards fail closed, so
 * a strap that does not match simply reports nothing.
 *
 * That silence has two very different causes and no way to tell them apart from a log:
 *  - the byte at 93 is not 50 — a different generation marker, offset probably still right;
 *  - the name+token region is a different width, so byte 93 is not the version at all and the offset has
 *    MOVED. This is the one the decoder comment warns about, and the one a user cannot diagnose.
 *
 * So the line carries what distinguishes them: the payload length, the byte actually at 93, where the
 * printable-ASCII device name ended (the run whose width shifts everything after it), and a hex window
 * spanning the region the version should sit in. A capture from an undecoded strap then locates the real
 * offset without another round trip.
 *
 * Deliberately does NOT loosen the guard. Widening it blindly would render unrelated bytes as a version,
 * which is worse than "unknown" because it looks authoritative.
 *
 * Pure, and the window is clamped to the payload, so a short or malformed frame cannot trap. Swift twin:
 * `WhoopProtocol.firmwareGateDiagnostic`.
 */
fun firmwareGateDiagnostic(payload: ByteArray, nameEndIndex: Int): String {
    val at93 = if (payload.size > 93) (payload[93].toInt() and 0xFF).toString() else "n/a"
    val lo = minOf(88, payload.size)
    val hi = minOf(101, payload.size)
    val window = if (lo < hi) {
        payload.copyOfRange(lo, hi).joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    } else {
        ""
    }
    return "fw gate: no version decoded — len=${payload.size} at93=$at93 expected=50" +
        " nameEnd=$nameEndIndex hex[$lo..<$hi]=$window"
}
