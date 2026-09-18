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
 * #2322 extends that from the same strap to the same ARM. `alarm.lastReportedEpoch` is written ONLY when
 * the readback frame decodes; the decode-failure branch logs raw hex and leaves the old value standing.
 * So an arm whose readback never decoded leaves a FRESH sent epoch beside a STALE reported one, and the
 * export then prints a confident "strap didn't accept the time" assembled from two different arms.
 * Decode failures are not hypothetical: the strap log attached to issue #2302 carries one on a
 * neighbouring frame, which is where this was noticed. That issue is about HRV, not alarms.
 *
 * The arrival times were already persisted for both halves (`alarm.lastArmAt`, `alarm.lastReportedAt`) and
 * simply were not consulted; comparing them is the whole guard.
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
        /** The readback on hand is OLDER than the arm it is being compared against, so it answered an
         *  EARLIER arm. Same strap, but not the same question, and nothing can be concluded. */
        STALE_READBACK,
    }

    /**
     * [sentAt] and [reportedAt] are WALL-CLOCK arrival stamps for the two halves, in whatever unit this
     * platform's store already holds (Android: `System.currentTimeMillis()`). Only their ORDER is read,
     * never their difference, so the unit does not have to match the Swift twin's; both sides compare two
     * stamps taken from their OWN clock. 0 on either means "not recorded" (an install that predates the
     * keys), and staleness is then not judged rather than guessed.
     */
    fun verdict(
        sentEpoch: Long,
        reportedEpoch: Long,
        sentDeviceId: String?,
        reportedDeviceId: String?,
        // toleranceS stays in the position it has always held. Kotlin allows positional calls, so moving
        // it would silently rebind a `verdict(a, b, c, d, 300)` written against the old signature to
        // sentAt, turning a tuning value into a timestamp with no compiler complaint. The new parameters
        // are appended instead, which is the only order that cannot break a caller written before them.
        toleranceS: Long = TOLERANCE_S,
        sentAt: Long = 0L,
        reportedAt: Long = 0L,
    ): Verdict {
        if (sentDeviceId.isNullOrBlank() || reportedDeviceId.isNullOrBlank()) return Verdict.UNATTRIBUTED
        if (sentDeviceId != reportedDeviceId) return Verdict.DIFFERENT_STRAP
        // Ordered AFTER attribution on purpose: a cross-strap pair is unusable whether or not it is also
        // stale, and naming the strap problem first sends the reader to the real one.
        if (sentAt > 0L && reportedAt > 0L && reportedAt < sentAt) return Verdict.STALE_READBACK
        return if (kotlin.math.abs(reportedEpoch - sentEpoch) > toleranceS) Verdict.MISMATCH else Verdict.MATCHES
    }

    /** The suffix the debug export appends after the reported time. Byte-identical to the Swift twin. */
    fun suffix(verdict: Verdict): String = when (verdict) {
        Verdict.MATCHES -> "  ✓ matches"
        Verdict.MISMATCH -> "  ⚠️ MISMATCH — strap didn't accept the time"
        Verdict.DIFFERENT_STRAP -> "  (readback is from a different strap — not comparable)"
        Verdict.UNATTRIBUTED -> "  (no strap recorded for one of these — not comparable)"
        Verdict.STALE_READBACK -> "  (readback predates this arm — not comparable)"
    }

    /**
     * Whether this verdict may advance the consecutive-rejection streak. Only a proven same-strap,
     * same-arm disagreement counts: an unattributed, cross-strap or stale reading must leave the streak
     * untouched rather than reset it, since none of the three is evidence either way.
     */
    fun countsAsRejection(verdict: Verdict): Boolean = verdict == Verdict.MISMATCH

    /** Whether this verdict is evidence the strap DID accept, which clears the streak. */
    fun clearsRejectionStreak(verdict: Verdict): Boolean = verdict == Verdict.MATCHES
}
