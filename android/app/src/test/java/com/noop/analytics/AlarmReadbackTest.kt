package com.noop.analytics

import com.noop.analytics.AlarmReadback.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1706. The values here are the ones from the field log that produced the issue: an arm sent
 * 2026-08-26 06:30 against a readback claiming 2045-06-10, on a phone with a 4.0 and a 5.0 registered.
 * Twin of Swift `AlarmReadbackTests`.
 */
class AlarmReadbackTest {

    private val sent = 1_787_682_600L      // 2026-08-26 06:30 +12:00
    private val reported = 2_380_672_980L  // 2045-06-10 14:03 +12:00, what the strap reported back

    @Test fun sameStrapAndAgreeing() {
        assertEquals(Verdict.MATCHES, AlarmReadback.verdict(sent, sent + 5, "whoop-a", "whoop-a"))
    }

    @Test fun sameStrapAtTheToleranceBoundary() {
        assertEquals(Verdict.MATCHES, AlarmReadback.verdict(sent, sent + 120, "whoop-a", "whoop-a"))
        assertEquals(Verdict.MISMATCH, AlarmReadback.verdict(sent, sent + 121, "whoop-a", "whoop-a"))
    }

    @Test fun sameStrapAndDisagreeingIsTheOnlyRealRefusal() {
        val v = AlarmReadback.verdict(sent, reported, "whoop-a", "whoop-a")
        assertEquals(Verdict.MISMATCH, v)
        assertTrue(AlarmReadback.countsAsRejection(v))
    }

    /** The field case: the readback can only come from the 4.0, the arm went to the active 5.0. */
    @Test fun crossStrapIsNotJudged() {
        val v = AlarmReadback.verdict(sent, reported, "whoop-5mg", "my-whoop")
        assertEquals(Verdict.DIFFERENT_STRAP, v)
        assertFalse("a strap that was never asked must not be blamed", AlarmReadback.countsAsRejection(v))
        assertFalse("nor may it clear a real refusal", AlarmReadback.clearsRejectionStreak(v))
    }

    /** Data written before attribution existed. Unknown is not the same as innocent. */
    @Test fun missingAttributionIsNotJudged() {
        for (pair in listOf(null to "whoop-a", "whoop-a" to null, null to null, "" to "whoop-a")) {
            val v = AlarmReadback.verdict(sent, reported, pair.first, pair.second)
            assertEquals("$pair", Verdict.UNATTRIBUTED, v)
            assertFalse("$pair", AlarmReadback.countsAsRejection(v))
            assertFalse("$pair", AlarmReadback.clearsRejectionStreak(v))
        }
    }

    @Test fun onlyAProvenAgreementClearsTheStreak() {
        assertTrue(AlarmReadback.clearsRejectionStreak(Verdict.MATCHES))
        assertFalse(AlarmReadback.clearsRejectionStreak(Verdict.MISMATCH))
        assertFalse(AlarmReadback.clearsRejectionStreak(Verdict.DIFFERENT_STRAP))
        assertFalse(AlarmReadback.clearsRejectionStreak(Verdict.UNATTRIBUTED))
    }

    @Test fun suffixShape() {
        assertEquals("  ✓ matches", AlarmReadback.suffix(Verdict.MATCHES))
        assertEquals("  ⚠️ MISMATCH — strap didn't accept the time", AlarmReadback.suffix(Verdict.MISMATCH))
        assertEquals("  (readback is from a different strap — not comparable)", AlarmReadback.suffix(Verdict.DIFFERENT_STRAP))
        assertEquals("  (no strap recorded for one of these — not comparable)", AlarmReadback.suffix(Verdict.UNATTRIBUTED))
    }

    // --- #2322: same strap, but was it the same ARM? ---

    private val armedAt = 1_789_728_000_000L   // wall clock when the arm went out, millis

    @Test fun aReadbackOlderThanTheArmIsNotComparable() {
        // The shape from #2322: an arm goes out, its readback frame fails to decode, so the PREVIOUS
        // readback is still what is stored. Judging it blames the strap for answering a question it was
        // never asked on this arm.
        val v = AlarmReadback.verdict(sent, reported, "whoop-a", "whoop-a",
                                      sentAt = armedAt, reportedAt = armedAt - 60_000L)
        assertEquals(Verdict.STALE_READBACK, v)
        assertFalse("a readback from an earlier arm must not climb the streak",
                    AlarmReadback.countsAsRejection(v))
        assertFalse("nor may it clear a real refusal", AlarmReadback.clearsRejectionStreak(v))
    }

    @Test fun aReadbackThatAnsweredThisArmIsStillJudged() {
        // The guard must not swallow the real signal it sits in front of.
        assertEquals(Verdict.MISMATCH, AlarmReadback.verdict(sent, reported, "whoop-a", "whoop-a",
                                                            sentAt = armedAt, reportedAt = armedAt + 900L))
        assertEquals(Verdict.MATCHES, AlarmReadback.verdict(sent, sent + 5, "whoop-a", "whoop-a",
                                                           sentAt = armedAt, reportedAt = armedAt + 900L))
    }

    @Test fun anInstallWithNoArrivalStampsJudgesAsBefore() {
        // 0 means the key was never written (an install predating them). Staleness is then not judged
        // rather than guessed, so behaviour is byte-identical to the pre-#2322 verdict.
        assertEquals(Verdict.MISMATCH, AlarmReadback.verdict(sent, reported, "whoop-a", "whoop-a",
                                                             sentAt = 0L, reportedAt = 0L))
        assertEquals(Verdict.MISMATCH, AlarmReadback.verdict(sent, reported, "whoop-a", "whoop-a",
                                                             sentAt = armedAt, reportedAt = 0L))
    }

    @Test fun aCrossStrapPairIsNamedBeforeStaleness() {
        // Both faults at once: the strap problem is the one that sends the reader to the right device.
        assertEquals(Verdict.DIFFERENT_STRAP,
                     AlarmReadback.verdict(sent, reported, "whoop-a", "whoop-b",
                                           sentAt = armedAt, reportedAt = armedAt - 60_000L))
    }

    @Test fun staleHasItsOwnSuffix() {
        assertEquals("  (readback predates this arm — not comparable)",
                     AlarmReadback.suffix(Verdict.STALE_READBACK))
    }
}
