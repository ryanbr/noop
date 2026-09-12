package com.noop.protocol

/**
 * Result of decoding a single complete frame.
 *
 * Mirrors the Swift reference `ParsedFrame` reduced to the fields the Android app consumes:
 *  - [ok]: the FULL integrity verdict of the frame verifier — header checksum, payload CRC32 and the
 *    structural length together. It means "this frame is intact", NOT "this frame could be parsed":
 *    a frame with a broken header still carries its decoded [typeName] and [parsed] fields for
 *    inspection. This is the one gate a consumer has to ask.
 *  - [crcOk]: payload CRC32 outcome ALONE — `true`/`false` when verifiable, `null` when not enough
 *    bytes were present to check (mirrors Swift's optional `crcOK`). A diagnostic field: it says
 *    nothing about the header checksum or the declared length, so it is not an integrity gate.
 *  - [rejectReason]: why [ok] is false; [FrameRejectReason.NONE] exactly when [ok] is true. Carried
 *    here so a consumer can report the cause from the value it was handed — the frame is parsed
 *    exactly once and the result threaded on, so a consumer that had to verify again to learn the
 *    reason would break that invariant.
 *  - [typeName]: canonical packet-type name (e.g. "REALTIME_DATA", "EVENT", "COMMAND_RESPONSE",
 *    "METADATA"), or "type{N}" / "INVALID/FRAGMENT" when unmapped/invalid.
 *  - [parsed]: a flat map of decoded fields. Values are plain Kotlin types (Int, Double, String,
 *    Boolean, or List<Int> for `rr_intervals`). Keys match the Swift parsed-dict keys exactly so
 *    higher layers (Streams, HistoricalMeta) port without renames.
 */
data class ParsedFrame(
    val ok: Boolean,
    val crcOk: Boolean?,
    val typeName: String,
    val parsed: Map<String, Any?>,
    /**
     * Defaulted to [FrameRejectReason.NONE] so a hand-built [ParsedFrame] (test fixtures, the
     * capture-replay paths that construct one directly) stays valid without naming the new field —
     * the Kotlin twin of the Swift decoder tolerating a missing `rejectReason`.
     */
    val rejectReason: FrameRejectReason = FrameRejectReason.NONE,
) {
    companion object {
        /**
         * A frame that could not be decoded at all (too short, wrong SOF, or a mid-stream fragment).
         * [reason] carries the verifier's verdict so even an undecodable byte run says WHY.
         */
        fun invalid(reason: FrameRejectReason): ParsedFrame =
            ParsedFrame(
                ok = false, crcOk = null, typeName = "INVALID/FRAGMENT", parsed = emptyMap(),
                rejectReason = reason,
            )
    }
}
