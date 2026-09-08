package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1988: an UNUSABLE resting-HR baseline must be treated as absent, everywhere.
 *
 * `Baselines.foldHistory` returns the config's SYNTHETIC midpoint (about 75 bpm for resting HR) when the
 * history is empty or entirely out of physiological range. That is nobody's resting HR, so scoring
 * against it moved Charge, and a driver bar, on a baseline the user never had.
 *
 * The gate lives in two places on purpose, and both are pinned here: `RecoveryScorer.recovery`'s
 * BaselineState overload (every headline caller passes through it) and `RecoveryDrivers.chargeDrivers`
 * (which builds the ROW from the baseline directly, not only through the scorer). Gating one without the
 * other would let the breakdown disagree with the headline, which is exactly what chargeDrivers'
 * own contract promises never happens. Swift twin: `RecoveryRhrBaselineUsableTests`.
 */
class RecoveryRhrBaselineUsableTest {

    private fun state(mean: Double, sigma: Double, status: BaselineStatus, nValid: Int) =
        BaselineState(baseline = mean, spread = sigma / 1.253, nValid = nValid,
                      nightsSinceUpdate = if (status == BaselineStatus.STALE) 20 else 0, status = status)

    private val hrvBase = state(55.0, 12.0, BaselineStatus.TRUSTED, 20)
    private val usableRhr = state(52.0, 3.0, BaselineStatus.PROVISIONAL, 5)
    /** What an empty or all-implausible history folds to: the config midpoint, never banked. */
    private val syntheticRhr = state(75.0, 6.0, BaselineStatus.CALIBRATING, 0)
    private val staleRhr = state(52.0, 3.0, BaselineStatus.STALE, 20)

    private fun score(rhrBaseline: BaselineState?): Double? = RecoveryScorer.recovery(
        hrv = 55.0, rhr = 62.0, resp = null,
        hrvBaseline = hrvBase, rhrBaseline = rhrBaseline, respBaseline = null, sleepPerf = 0.85,
    )

    private fun rows(rhrBaseline: BaselineState?) = RecoveryDrivers.chargeDrivers(
        hrv = 55.0, rhr = 62.0, resp = null,
        hrvBaseline = hrvBase, rhrBaseline = rhrBaseline, respBaseline = null, sleepPerf = 0.85,
    )

    @Test fun aSyntheticRhrBaselineScoresLikeAnAbsentOne() {
        assertEquals(score(null)!!, score(syntheticRhr)!!, 1e-12)
    }

    @Test fun aStaleRhrBaselineScoresLikeAnAbsentOne() {
        // `usable` is provisional-or-trusted, so a real personal baseline that has gone stale is dropped
        // too. That is the same reading of "usable" the rest of the codebase uses.
        assertEquals(score(null)!!, score(staleRhr)!!, 1e-12)
    }

    @Test fun aUsableRhrBaselineStillContributes() {
        // The control: the gate is not a blanket off. A resting HR well above a usable baseline must pull
        // the score away from the HRV-only number.
        assertNotEquals(score(null)!!, score(usableRhr)!!, 1e-9)
    }

    @Test fun aSyntheticRhrBaselineProducesNoRhrDriverRow() {
        val labels = rows(syntheticRhr).map { it.label }
        assertTrue("the HRV row must still be present: $labels",
            labels.contains(ChargeDriverLabel.HEART_RATE_VARIABILITY))
        assertFalse("no usable resting-HR baseline, so no RHR row: $labels",
            labels.contains(ChargeDriverLabel.RESTING_HEART_RATE))
    }

    @Test fun aUsableRhrBaselineProducesItsRow() {
        assertTrue(rows(usableRhr).map { it.label }.contains(ChargeDriverLabel.RESTING_HEART_RATE))
    }

    /**
     * THE invariant this change exists to keep. `chargeDrivers` documents that its rows are scored
     * "against the identical inputs as the headline number", so the two gates must agree: passing an
     * unusable baseline has to be indistinguishable from passing none, row for row.
     */
    @Test fun theDriverRowsAndTheHeadlineApplyTheSameGate() {
        assertEquals(rows(null), rows(syntheticRhr))
        assertEquals(rows(null), rows(staleRhr))
    }

    /**
     * The trace is the THIRD place that reads this baseline directly, for its own
     * `charge baseline rhr` line, its rhrZ and the saturation guard. Its own contract is that the score
     * it reports is the dashboard's "verbatim, so the trace cannot diverge from it", so an unusable
     * baseline has to drop the rhr TERM there too. Without the gate the trace would name a term the
     * score never used, which is the one thing a trace must never do.
     */
    @Test fun theTraceDropsTheRhrTermForAnUnusableBaseline() {
        val (score, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 55.0, rhr = 62.0, resp = null,
            hrvBaseline = hrvBase, rhrBaseline = syntheticRhr, respBaseline = null, sleepPerf = 0.85,
        )
        assertEquals(score(syntheticRhr)!!, score!!, 1e-12)
        assertFalse("the trace must not name an rhr term the score did not use: $lines",
            lines.any { it.contains("charge term rhr ") })
        assertTrue("rhr must be reported as a dropped term: $lines",
            lines.any { it.contains("nilTerm dropped=") && it.contains("rhr") })
        assertFalse("no baseline line for a baseline that was not used: $lines",
            lines.any { it.contains("charge baseline rhr ") })
    }

    /** Control: a usable baseline still produces the trace's rhr term and its baseline line. */
    @Test fun theTraceKeepsTheRhrTermForAUsableBaseline() {
        val (_, lines) = RecoveryScorerTrace.recoveryTrace(
            hrv = 55.0, rhr = 62.0, resp = null,
            hrvBaseline = hrvBase, rhrBaseline = usableRhr, respBaseline = null, sleepPerf = 0.85,
        )
        assertTrue(lines.any { it.contains("charge term rhr ") })
        assertTrue(lines.any { it.contains("charge baseline rhr ") })
    }
}
