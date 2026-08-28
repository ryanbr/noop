package com.noop.analytics

/**
 * Whether the alarm time a strap reports back can be compared with the one we sent (#1706).
 *
 * The two halves are persisted under flat, device-less keys — `alarm.lastArmSentEpoch` and
 * `alarm.lastReportedEpoch`. On an install with more than one strap registered they can therefore
 * describe DIFFERENT devices, and comparing them then produces a confident "strap didn't accept the
 * time" about a strap that was never asked. On Android the readback is written only on the WHOOP 4.0
 * path, so a 5.0-active install could only ever be comparing across straps.
 *
 * That verdict is not cosmetic on Apple: it also drives `alarm.rejectStreak`, which raises a warning in
 * SmartAlarmView at two. A cross-strap comparison could climb that streak forever.
 *
 * So attribution is required, not assumed: unless both halves are known to come from the same strap,
 * this refuses to judge. Refusing is the same stance `WindowedStreamPlan` takes — a diagnosis that
 * cannot be proven is worse than none, because it sends the reader after the wrong device.
 *
 * Twin of Swift `AlarmReadback`.
 */
object AlarmReadback {

    /** Seconds of slack allowed between what we armed and what the strap reports back. */
    const val TOLERANCE_S: Long = 120

    enum class Verdict {
        /** Same strap, and the readback agrees within [TOLERANCE_S]. */
        MATCHES,
        /** Same strap, and it does not. This is the only value that means the strap refused. */
        MISMATCH,
        /** The two halves came from different straps. Nothing can be concluded about either. */
        DIFFERENT_STRAP,
        /** One or both halves predate device attribution, so they cannot be tied to a strap. */
        UNATTRIBUTED,
    }

    fun verdict(
        sentEpoch: Long,
        reportedEpoch: Long,
        sentDeviceId: String?,
        reportedDeviceId: String?,
        toleranceS: Long = TOLERANCE_S,
    ): Verdict {
        if (sentDeviceId.isNullOrBlank() || reportedDeviceId.isNullOrBlank()) return Verdict.UNATTRIBUTED
        if (sentDeviceId != reportedDeviceId) return Verdict.DIFFERENT_STRAP
        return if (kotlin.math.abs(reportedEpoch - sentEpoch) > toleranceS) Verdict.MISMATCH else Verdict.MATCHES
    }

    /** The suffix the debug export appends after the reported time. Byte-identical to the Swift twin. */
    fun suffix(verdict: Verdict): String = when (verdict) {
        Verdict.MATCHES -> "  ✓ matches"
        Verdict.MISMATCH -> "  ⚠️ MISMATCH — strap didn't accept the time"
        Verdict.DIFFERENT_STRAP -> "  (readback is from a different strap — not comparable)"
        Verdict.UNATTRIBUTED -> "  (no strap recorded for one of these — not comparable)"
    }

    /**
     * Whether this verdict may advance the consecutive-rejection streak. Only a proven same-strap
     * disagreement counts: an unattributed or cross-strap reading must leave the streak untouched
     * rather than reset it, since neither is evidence either way.
     */
    fun countsAsRejection(verdict: Verdict): Boolean = verdict == Verdict.MISMATCH

    /** Whether this verdict is evidence the strap DID accept, which clears the streak. */
    fun clearsRejectionStreak(verdict: Verdict): Boolean = verdict == Verdict.MATCHES
}
