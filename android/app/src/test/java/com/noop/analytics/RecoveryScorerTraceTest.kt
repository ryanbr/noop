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

    /**
     * #47: the two-decimal trace-rounding contract itself, pinned as RAW BITS rather than as text.
     * Text would hide the divergence: Swift and Kotlin print the same Double differently ("1e+20" vs
     * "1.0E20"), and -0.0 vs 0.0 is a one-bit difference. Both cases the issue names live here — the
     * signed zero of a near-baseline driver term, and the large finite value that Math.round (a Long)
     * saturated at 2^63-1, turning 1e20 into 9.223372036854776e16 where Swift kept 1e20.
     *
     * The expected bit patterns are the VERBATIM stdout of the Swift twin compiled standalone
     * (`swiftc -O twin.swift -o t -Xlinker -lm && ./t`), not values re-derived here — that is what makes
     * this an oracle rather than a second opinion. The twin:
     *
     *     func traceRound2(_ x: Double) -> Double {
     *         (x * 100.0).rounded(.toNearestOrAwayFromZero) / 100.0
     *     }
     *     for (label, v) in cases {
     *         let r = traceRound2(v)
     *         print("\(label) -> \(r) bits=0x\(String(r.bitPattern, radix: 16))")
     *     }
     *
     * Twin: `testTraceRound2MatchesTheSwiftContract`.
     */
    @Test fun traceRound2MatchesTheSwiftContract() {
        val cases = listOf(
            Triple("-0.004", -0.004, "8000000000000000"), // -0.0: sign survives rounding to zero
            Triple("0.004", 0.004, "0"),
            Triple("1e20", 1e20, "4415af1d78b58c40"), // 1e+20, NOT the signed-64 ceiling
            Triple("-1e20", -1e20, "c415af1d78b58c40"),
            Triple("0.0", 0.0, "0"),
            Triple("-0.0", -0.0, "8000000000000000"),
            Triple("0.125", 0.125, "3fc0a3d70a3d70a4"), // positive half-tie -> away from zero (0.13)
            Triple("-0.125", -0.125, "bfc0a3d70a3d70a4"), // negative half-tie -> -0.13
            Triple("1.2349", 1.2349, "3ff3ae147ae147ae"), // ordinary non-ties
            Triple("-1.2349", -1.2349, "bff3ae147ae147ae"),
            // Just below the half-tie: floor(m + 0.5) would round this UP because m + 0.5 is not exact.
            Triple("0.0049999999999999994", 0.0049999999999999994, "0"),
            Triple("-0.0049999999999999994", -0.0049999999999999994, "8000000000000000"),
            Triple("1e306", 1e306, "7f76c8e5ca239029"), // largest magnitudes whose *100 is still finite
            Triple("-1e306", -1e306, "ff76c8e5ca239029"),
            // Finite input whose intermediate x * 100 overflows: both platforms yield an infinity.
            Triple("1e307", 1e307, "7ff0000000000000"),
            Triple("-1e307", -1e307, "fff0000000000000"),
        )
        for ((label, input, bits) in cases) {
            assertEquals(
                "r2($label)",
                bits,
                java.lang.Long.toHexString(java.lang.Double.doubleToRawLongBits(RecoveryScorerTrace.r2(input))),
            )
        }
    }

    /**
     * #47: the exact differential fixture. Every line of one full-term night, pinned verbatim, so a
     * rounding change on either platform shows up as a text diff rather than as two field logs that
     * quietly disagree. The skin-temp deviation is 0.004, the issue's near-zero negative: it must render
     * `z=-0.0` and `dev=0.0C`.
     *
     * The expected lines are the VERBATIM stdout of the Swift twin (RecoveryScorer.recoveryTrace on the
     * same inputs), not text re-derived here. Twin: `testTraceFixtureIsByteIdenticalAcrossPlatforms`.
     */
    @Test fun traceFixtureIsByteIdenticalAcrossPlatforms() {
        val (_, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 62.0, rhr = 51.0, resp = 15.0,
            hrvBaseline = baseline(50.0, 6.0), rhrBaseline = baseline(55.0, 3.0),
            respBaseline = baseline(16.0, 2.0),
            sleepPerf = 0.9, skinTempDev = 0.004,
        )
        assertEquals(
            listOf(
                "charge baseline hrv mean=50.0 spread=4.79 nValid=14 status=trusted",
                "charge baseline rhr mean=55.0 spread=2.39 nValid=14 status=trusted",
                "charge baseline resp mean=16.0 spread=1.6 nValid=14 status=trusted",
                "charge term hrv z=2.0 w=0.55 (higher HRV is better)",
                "charge term rhr z=1.33 w=0.2 (lower RHR is better)",
                "charge term resp z=0.5 w=0.05 (lower resp is better)",
                "charge term sleepPerf z=0.42 w=0.15 (rest=0.9 center=0.85)",
                "charge term skinTempDev z=-0.0 w=0.05 (dev=0.0C penalty=-|dev|/1.0)",
                "charge nilTerm dropped=[] (each dropped term renormalizes the remaining weights)",
                "charge renorm totalWeight=1.0 compositeZ=1.45 (z = sum(z*w)/sum(w))",
                "charge score=93.38 band=green (logistic k=1.6 z0=-0.2)",
            ),
            lines,
        )
    }
}
