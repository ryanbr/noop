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
}
