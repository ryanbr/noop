package com.noop.ble

import com.noop.protocol.FrameRejectReason
import com.noop.protocol.ParsedFrame
import com.noop.protocol.wireName

/**
 * Diagnosis for the frame-integrity gate: what a rejected frame still tells us, and how often each
 * reason occurred on one connection. Kotlin twin of `FrameDiagnostics.swift` in `WhoopProtocol`.
 *
 * It lives beside the BLE client rather than in `com.noop.protocol` because the tally is a per-
 * connection diagnostic of the link, not a property of the wire format — and because the one thing
 * that must stay literally identical across the platforms is what it PRINTS, which is pinned by the
 * tests below it, not by where the class sits.
 *
 * Naming note: Swift spells the named counter `payloadCRCOKButEnvelopeRejected`. This side follows the
 * repository's established Kotlin twin casing (`crcOk` for Swift's `crcOK`, as `ParsedFrame` already
 * does) for the PROPERTY, while the emitted strings are byte-identical to the Swift ones — the log
 * line is the shared artefact a reader compares across two field reports, the identifier is not.
 */

/**
 * Whether the decoder got a PACKET TYPE out of this frame — the parseability question, which is NOT
 * the integrity question [ParsedFrame.ok] answers.
 *
 * The two used to be the same value, so every diagnostic surface that wanted "did this decode?" read
 * `ok`. Now `ok` means "header checksum, payload CRC32 and structural length all agree", and reading
 * it as parseability would blank the packet type of exactly the frames a capture exists to map: a
 * frame with a flipped header byte still decodes its type, its sequence number and its fields, and
 * losing that in the record is losing the evidence.
 */
val ParsedFrame.isParsable: Boolean
    get() = typeName != UNPARSABLE_TYPE_NAME

/** The placeholder type name both parsers use for a byte run they could not read at all. */
const val UNPARSABLE_TYPE_NAME = "INVALID/FRAGMENT"

/**
 * True for the frame class that passed the gates BEFORE this change: the payload CRC32 verified, but
 * the envelope did not — a wrong header checksum, a declared length below the family minimum, a
 * truncated frame or one with trailing bytes.
 *
 * Read straight off the parse result; it needs no second verification, because both values are already
 * on the frame the consumer was handed.
 */
val ParsedFrame.payloadCrcOkButEnvelopeRejected: Boolean
    get() = !ok && crcOk == true

/**
 * Per-reason rejection counters for one connection, plus the ONE extra named counter the hardware run
 * is read from.
 *
 * Why a plain per-reason count is not enough (D3): the abort criterion for the hardware run is a
 * CONJUNCTION — "header checksum or length wrong WHILE the payload CRC32 verifies" — and no single
 * reason bucket can express it. The length bucket in particular also collects the harmless resyncs
 * after a lost notification, which were happening before this change too. So
 * [payloadCrcOkButEnvelopeRejected] is counted separately; it is the class that used to pass, and thus
 * the cleanest regression signal.
 *
 * Counted per reason only — NOT additionally per device family. A connection talks to exactly one
 * strap, so a family dimension would be constant.
 *
 * A tally asserts only what it observed: an unverifiable payload CRC32 is counted as
 * [FrameRejectReason.PAYLOAD_CRC_UNVERIFIABLE], never folded into
 * [FrameRejectReason.PAYLOAD_CRC_MISMATCH]. "Could not be checked" is not "was wrong".
 *
 * Not thread-safe on its own: the BLE client mutates it only from the GATT binder thread that feeds
 * the reassembler, and reads it on the same thread at teardown.
 */
class FrameRejectTally {

    private val counts = HashMap<FrameRejectReason, Int>()

    /** The named class from D3: envelope rejected while the payload CRC32 verified. */
    var payloadCrcOkButEnvelopeRejected = 0
        private set

    /**
     * The reassembler's monotonic drop count already folded into [FrameRejectReason.BELOW_MINIMUM_LENGTH],
     * so repeated folds of the same counter cannot double-count.
     */
    private var absorbedReassemblerDrops = 0

    /**
     * Count one parse result. Intact frames are ignored, so this can sit on the frame path unguarded.
     * Returns the reason recorded, or [FrameRejectReason.NONE] when the frame was intact and nothing
     * was counted.
     */
    fun note(parsed: ParsedFrame): FrameRejectReason {
        if (parsed.ok) return FrameRejectReason.NONE
        val reason = parsed.rejectReason
        counts[reason] = (counts[reason] ?: 0) + 1
        if (parsed.payloadCrcOkButEnvelopeRejected) payloadCrcOkButEnvelopeRejected += 1
        return reason
    }

    /**
     * Fold a reassembler's [Reassembler.belowMinimumLengthDrops] into the
     * [FrameRejectReason.BELOW_MINIMUM_LENGTH] bucket.
     *
     * A byte run the reassembler drops never reaches a parser — and never reaches the evidence-
     * preserving reader either — so without this it would vanish with no trace at all. The argument is
     * the reassembler's MONOTONIC total; only the growth since the last fold is added, so calling this
     * once per notification is correct and idempotent.
     */
    fun absorbReassemblerDrops(monotonicTotal: Int) {
        if (monotonicTotal <= absorbedReassemblerDrops) return
        val reason = FrameRejectReason.BELOW_MINIMUM_LENGTH
        counts[reason] = (counts[reason] ?: 0) + (monotonicTotal - absorbedReassemblerDrops)
        absorbedReassemblerDrops = monotonicTotal
    }

    /** How often [reason] was recorded. */
    fun count(reason: FrameRejectReason): Int = counts[reason] ?: 0

    /** Every rejection counted, across all reasons. */
    val totalRejected: Int
        get() = counts.values.sum()

    /**
     * One line naming every reason that actually occurred, in a stable order, or null when nothing was
     * rejected — a per-connection readout, so its caller gates it behind the Test Centre domain.
     * Silence when there is nothing to report; no "0 rejections" line to read past.
     *
     * Byte-identical in shape to the Swift `FrameRejectTally.summaryLine()`, including the reasons'
     * wire spellings, so the two platforms' strap logs can be read with one eye.
     */
    fun summaryLine(): String? {
        if (totalRejected == 0) return null
        val parts = FrameRejectReason.entries
            .filter { it != FrameRejectReason.NONE && count(it) > 0 }
            .joinToString(" ") { "${it.wireName}=${count(it)}" }
        return "frameReject total=$totalRejected $parts" +
            " payloadCRCOKButEnvelopeRejected=$payloadCrcOkButEnvelopeRejected"
    }

    /** Drop every count, for a fresh connection. */
    fun reset() {
        counts.clear()
        payloadCrcOkButEnvelopeRejected = 0
        absorbedReassemblerDrops = 0
    }
}
