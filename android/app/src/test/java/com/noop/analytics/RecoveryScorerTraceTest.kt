package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift RecoveryScorerTraceTests: the Recovery (Charge) test mode's pure term-breakdown
 * trace. Proves the trace's returned score equals RecoveryScorer.recovery exactly (byte-identical), that
 * the trace names which term was nil, and the cold-start nil reason. No em-dashes. Pure-JVM, no Robolectric.
 */
class RecoveryScorerTraceTest {

    /** A usable baseline with a given mean and Gaussian sigma (spread is internal abs-dev units). */
    private fun baseline(mean: Double, sigma: Double, nValid: Int = 14): BaselineState =
        BaselineState(
            baseline = mean, spread = sigma / 1.253, nValid = nValid, nightsSinceUpdate = 0,
            status = if (nValid >= 14) BaselineStatus.TRUSTED else BaselineStatus.PROVISIONAL,
        )

    @Test fun traceScoreIsByteIdenticalToRecovery() {
        val hrvB = baseline(50.0, 6.0)
        val rhrB = baseline(55.0, 3.0)
        val respB = baseline(16.0, 2.0)
        val plain = RecoveryScorer.recovery(
            hrv = 62.0, rhr = 51.0, resp = 15.0,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = respB,
            sleepPerf = 0.9, skinTempDev = 0.3,
        )
        val (traced, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 62.0, rhr = 51.0, resp = 15.0,
            hrvBaseline = hrvB, rhrBaseline = rhrB, respBaseline = respB,
            sleepPerf = 0.9, skinTempDev = 0.3,
        )
        assertEquals(plain, traced)
        assertTrue(lines.any { it.contains("charge term hrv ") })
        assertTrue(lines.any { it.contains("charge term rhr ") })
        assertTrue(lines.any { it.contains("charge term resp ") })
        assertTrue(lines.any { it.contains("charge term sleepPerf ") })
        assertTrue(lines.any { it.contains("charge term skinTempDev ") })
        assertTrue(lines.any { it.contains("nilTerm dropped=[]") })
        assertTrue(lines.any { it.startsWith("charge score=") && it.contains("band=") })
        assertFalse(lines.any { it.contains("\u2014") })
    }

    @Test fun traceNamesTheNilTermThatForcedRenorm() {
        val hrvB = baseline(50.0, 6.0)
        val plain = RecoveryScorer.recovery(
            hrv = 55.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = 0.85, skinTempDev = null,
        )
        val (traced, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 55.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = 0.85, skinTempDev = null,
        )
        assertEquals(plain, traced)
        val nilLine = lines.first { it.contains("nilTerm dropped=") }
        assertTrue(nilLine.contains("rhr"))
        assertTrue(nilLine.contains("resp"))
        assertTrue(nilLine.contains("skinTempDev"))
    }

    @Test fun coldStartTraceReportsTheGateAndNilScore() {
        val coldHRV = BaselineState(
            baseline = 50.0, spread = 5.0, nValid = 2, nightsSinceUpdate = 0,
            status = BaselineStatus.CALIBRATING,
        )
        val (traced, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 60.0, rhr = 50.0, resp = null,
            hrvBaseline = coldHRV, rhrBaseline = null, respBaseline = null,
            sleepPerf = 0.9, skinTempDev = null,
        )
        assertNull(traced)
        assertEquals(1, lines.size)
        assertTrue(lines[0].contains("nilScore reason=hrvBaselineNotUsable"))
        assertTrue(lines[0].contains("hrvStatus=calibrating"))
        assertTrue(lines[0].contains("hrvNValid=2"))
    }

    @Test fun baselineLinesCarryStatusAndNValid() {
        val hrvB = baseline(50.0, 6.0, nValid = 9)
        val (_, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = RecoveryScorer.sleepPerfCenter, skinTempDev = null,
        )
        val base = lines.first { it.startsWith("charge baseline hrv ") }
        assertTrue(base.contains("nValid=9"))
        assertTrue(base.contains("status=provisional"))
    }

    /**
     * #1437 follow-up: a term just below baseline rounds to zero but must keep its SIGN. Math.round
     * returns a Long, which has no negative zero, so negating it before the division collapsed -0.0 to
     * +0.0 and this line printed `z=0.0` while Swift's .rounded() kept `z=-0.0` — a disagreement on the
     * one line whose whole purpose is being byte-identical across platforms. Twin of Swift
     * `testTraceKeepsNegativeZeroOnNearBaselineTerm`.
     */
    @Test fun traceKeepsNegativeZeroOnNearBaselineTerm() {
        val hrvB = baseline(50.0, 6.0)
        val (_, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = null, skinTempDev = 0.001,
        )
        assertEquals(
            "charge term skinTempDev z=-0.0 w=0.05 (dev=0.0C penalty=-|dev|/1.0)",
            lines.first { it.startsWith("charge term skinTempDev ") },
        )
    }

    /**
     * The second trap in the same helper: an exact -0.0 cannot be routed by a sign COMPARISON, because
     * `-0.0 < 0.0` is false. It is reachable — a skin-temp deviation of exactly 0.0 (skin temp sitting
     * on the personal baseline) gives z = -|dev| = -0.0 — and Swift prints `z=-0.0` for it. Twin of
     * Swift `testTraceKeepsExactNegativeZeroTerm`.
     */
    @Test fun traceKeepsExactNegativeZeroTerm() {
        val hrvB = baseline(50.0, 6.0)
        val (_, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = null, skinTempDev = 0.0,
        )
        assertEquals(
            "charge term skinTempDev z=-0.0 w=0.05 (dev=0.0C penalty=-|dev|/1.0)",
            lines.first { it.startsWith("charge term skinTempDev ") },
        )
    }

    @Test fun traceRoundsHalfTiesAwayFromZeroWithoutChangingScore() {
        val hrvB = baseline(50.0, 6.0)
        val plain = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = null, skinTempDev = 0.125,
        )
        val (traced, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = null, skinTempDev = 0.125,
        )

        assertEquals(plain, traced)
        assertEquals(
            "charge term skinTempDev z=-0.13 w=0.05 (dev=0.13C penalty=-|dev|/1.0)",
            lines.first { it.startsWith("charge term skinTempDev ") },
        )
    }

    @Test fun tracePreservesNonTieRounding() {
        val hrvB = baseline(50.0, 6.0)
        val plain = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = null, skinTempDev = 0.124,
        )
        val (traced, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = null, skinTempDev = 0.124,
        )

        assertEquals(plain, traced)
        assertEquals(
            "charge term skinTempDev z=-0.12 w=0.05 (dev=0.12C penalty=-|dev|/1.0)",
            lines.first { it.startsWith("charge term skinTempDev ") },
        )
    }
}
