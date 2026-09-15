package com.noop.protocol

class BackfillCaptureSummary(
    private val maxUnknownSamples: Int = 20,
) {
    private data class UnknownSample(
        val typeName: String,
        val crcOk: Boolean?,
        val size: Int,
        val characteristic: String,
        val hex: String,
        val rejectReason: FrameRejectReason,
    )

    private val counts = linkedMapOf<String, Int>()
    private val unknownSamples = ArrayList<UnknownSample>()

    /**
     * Record one captured frame. [typeName] is kept exactly as the decoder read it, including for a
     * frame the verifier rejected — an unmapped type is what the summary exists to surface, and a
     * damaged envelope is no reason to stop naming it.
     *
     * [rejectReason] is ADDITIVE and defaulted, so the existing call shape stays valid. It says why the
     * sample was rejected, which is the difference between "this firmware has a type we cannot map" and
     * "this sample is a corrupted copy of a type we already know" — indistinguishable from the hex alone.
     */
    fun record(
        typeName: String,
        crcOk: Boolean?,
        size: Int,
        characteristic: String,
        hex: String,
        rejectReason: FrameRejectReason = FrameRejectReason.NONE,
    ) {
        counts[typeName] = (counts[typeName] ?: 0) + 1
        if (unknownSamples.size < maxUnknownSamples && isUnknownType(typeName)) {
            unknownSamples += UnknownSample(typeName, crcOk, size, characteristic, hex, rejectReason)
        }
    }

    fun countsText(): String =
        if (counts.isEmpty()) {
            "none"
        } else {
            counts.entries
                .sortedBy { it.key }
                .joinToString(", ") { (type, count) -> "$type=$count" }
        }

    fun unknownSamplesText(): String =
        if (unknownSamples.isEmpty()) {
            "none"
        } else {
            unknownSamples.joinToString("; ") {
                // `reject=` appears only when the frame WAS rejected. An intact sample's line is
                // unchanged, and a "reject=none" on every entry would train the eye to skip the field —
                // the same rule the frame inspector's line follows.
                val reject =
                    if (it.rejectReason == FrameRejectReason.NONE) "" else "reject=${it.rejectReason.wireName},"
                "${it.typeName}(size=${it.size},char=${it.characteristic},crc=${it.crcOk}," +
                    "${reject}hex=${it.hex})"
            }
        }

    fun reset() {
        counts.clear()
        unknownSamples.clear()
    }

    private fun isUnknownType(typeName: String): Boolean = typeName.startsWith("type")
}
