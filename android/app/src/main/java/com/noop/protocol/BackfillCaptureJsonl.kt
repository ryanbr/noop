package com.noop.protocol

/**
 * The export spelling of a [FrameRejectReason], identical to the Swift enum's `rawValue`.
 *
 * The capture files and the strap-log readouts of the two platforms are read side by side by whoever
 * is mapping an unknown frame, so the reason has to READ the same on both — the Kotlin identifier
 * follows Kotlin's enum convention, the wire form follows Swift's. Defined here, next to the export
 * record, because this is where the export form lives; the BLE-side tally reads it from here rather
 * than keeping a second copy that could drift.
 */
val FrameRejectReason.wireName: String
    get() = when (this) {
        FrameRejectReason.NONE -> "none"
        FrameRejectReason.NO_START_OF_FRAME -> "noStartOfFrame"
        FrameRejectReason.BELOW_MINIMUM_LENGTH -> "belowMinimumLength"
        FrameRejectReason.LENGTH_MISMATCH -> "lengthMismatch"
        FrameRejectReason.HEADER_CHECKSUM_MISMATCH -> "headerChecksumMismatch"
        FrameRejectReason.PAYLOAD_CRC_MISMATCH -> "payloadCRCMismatch"
        FrameRejectReason.PAYLOAD_CRC_UNVERIFIABLE -> "payloadCRCUnverifiable"
    }

data class BackfillCaptureRecord(
    val capturedAtMs: Long,
    val sessionId: String,
    val characteristic: String,
    /**
     * The decoded packet type — kept even for a frame the verifier REJECTED. That is the point of a
     * capture: an unmapped or corrupted frame is precisely what a mapper wants to see, and blanking its
     * type would throw away the one thing the decoder did learn. The cause lives in [rejectReason].
     */
    val typeName: String,
    val crcOk: Boolean?,
    val offload: Boolean,
    val size: Int,
    val parsed: Map<String, Any?>,
    val hex: String,
    /**
     * Why the frame failed its integrity check; [FrameRejectReason.NONE] on an intact one. ADDITIVE in
     * the strict sense: it is encoded as a new trailing key ONLY when there is a reason, so the line an
     * intact frame produces is unchanged, and the default keeps existing constructions compiling. Twin
     * of the Swift `PuffinCaptureRecord.rejectReason` / `reject_reason`, whose decoder reads an absent
     * key as `none` for exactly the same reason.
     */
    val rejectReason: FrameRejectReason = FrameRejectReason.NONE,
)

object BackfillCaptureJsonl {
    fun encode(record: BackfillCaptureRecord): String =
        buildString {
            append('{')
            appendField("captured_at_ms", record.capturedAtMs)
            append(',')
            appendField("session_id", record.sessionId)
            append(',')
            appendField("characteristic", record.characteristic)
            append(',')
            appendField("type_name", record.typeName)
            append(',')
            appendField("crc_ok", record.crcOk)
            append(',')
            appendField("offload", record.offload)
            append(',')
            appendField("size", record.size)
            append(',')
            appendQuoted("parsed")
            append(':')
            appendJsonValue(record.parsed)
            append(',')
            appendField("hex", record.hex)
            // Only on a REJECTION, and only the reason the verifier actually reported. Two reasons for
            // the omission rather than an unconditional `"reject_reason":"none"`:
            //  - it keeps the line an intact frame produces byte-identical to the previous format, so
            //    every existing reader and every pinned golden line keeps working unchanged; and
            //  - "key absent ⇒ none" is exactly the Swift decoder's contract for this field
            //    (`decodeIfPresent(...) ?? .none`), so a capture written here still reads there.
            // A key printed on every line would also train the eye to skip the field, which is the
            // opposite of why it exists.
            if (record.rejectReason != FrameRejectReason.NONE) {
                append(',')
                appendField("reject_reason", record.rejectReason.wireName)
            }
            append('}')
        }

    private fun StringBuilder.appendField(name: String, value: Any?) {
        appendQuoted(name)
        append(':')
        appendJsonValue(value)
    }

    private fun StringBuilder.appendJsonValue(value: Any?) {
        when (value) {
            null -> append("null")
            is Boolean -> append(value)
            is Number -> append(value)
            is Map<*, *> -> {
                append('{')
                value.entries
                    .sortedBy { it.key.toString() }
                    .forEachIndexed { index, entry ->
                        if (index > 0) append(',')
                        appendQuoted(entry.key.toString())
                        append(':')
                        appendJsonValue(entry.value)
                    }
                append('}')
            }
            is Iterable<*> -> {
                append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) append(',')
                    appendJsonValue(item)
                }
                append(']')
            }
            is IntArray -> appendJsonValue(value.asIterable())
            is LongArray -> appendJsonValue(value.asIterable())
            is DoubleArray -> appendJsonValue(value.asIterable())
            is BooleanArray -> appendJsonValue(value.asIterable())
            else -> appendQuoted(value.toString())
        }
    }

    private fun StringBuilder.appendQuoted(value: String) {
        append('"')
        for (ch in value) {
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> {
                    if (ch.code < 0x20) {
                        append("\\u")
                        append(ch.code.toString(16).padStart(4, '0'))
                    } else {
                        append(ch)
                    }
                }
            }
        }
        append('"')
    }
}
