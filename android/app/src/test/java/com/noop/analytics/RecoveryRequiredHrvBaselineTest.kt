package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The raw [RecoveryScorer.DriverBaseline] overload must refuse to score without the REQUIRED HRV
 * baseline (#40). Faithful Kotlin mirror of testRawOverloadRefusesToScoreWithoutHRVBaseline /
 * testRawOverloadPreservesColdStartAndValidScores in RecoveryScorerTests.swift — same scenarios,
 * same expected value.
 *
 * The preserved-score literal below is produced by this standalone Swift oracle (swiftc -O
 * oracle.swift -o oracle && ./oracle), a twin of RecoveryScorer.recovery(...) for that one case:
 *
 *     import Foundation
 *     let wHRV = 0.55, wSleep = 0.15
 *     let sleepPerfCenter = 0.85, sleepPerfScale = 0.12
 *     let logisticK = 1.6, logisticZ0 = -0.20
 *     func zScore(_ v: Double, mean: Double, spread: Double) -> Double {
 *         let sigma = max(1.253 * spread, 1e-9)
 *         return (v - mean) / sigma
 *     }
 *     var terms: [(Double, Double)] = []
 *     terms.append((zScore(50, mean: 50, spread: 6 / 1.253), wHRV))
 *     terms.append(((0.85 - sleepPerfCenter) / sleepPerfScale, wSleep))
 *     let total = terms.reduce(0) { $0 + $1.1 }
 *     let z = terms.reduce(0) { $0 + $1.0 * $1.1 } / total
 *     let score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
 *     print(max(0.0, min(100.0, score)).debugDescription)
 *     // stdout: 57.932425214874954
 */
class RecoveryRequiredHrvBaselineTest {

    @Test
    fun rawOverloadRefusesToScoreWithoutHrvBaseline() {
        // The raw overload documents hrvBaseline as REQUIRED, but it is nullable and the
        // cold-start gate only consults hrvBaselineUsable (default true). Without this guard any
        // other optional term alone produced a Charge score carrying NO HRV term at all. Each
        // case below supplies exactly one optional driver with the HRV baseline absent.
        val rhrB = RecoveryScorer.DriverBaseline(mean = 55.0, spread = 3.0 / 1.253)
        val respB = RecoveryScorer.DriverBaseline(mean = 14.5, spread = 1.0 / 1.253)
        val effortB = RecoveryScorer.DriverBaseline(mean = 40.0, spread = 15.0 / 1.253)

        // The issue's minimal reproduction: sleepPerf as the only weighted term.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = null,
                hrvBaseline = null, rhrBaseline = null, respBaseline = null,
                sleepPerf = 0.85,
            ),
        )
        // RHR term alone.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = null,
                hrvBaseline = null, rhrBaseline = rhrB, respBaseline = null,
                sleepPerf = null,
            ),
        )
        // Resp term alone.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = 14.0,
                hrvBaseline = null, rhrBaseline = null, respBaseline = respB,
                sleepPerf = null,
            ),
        )
        // Skin-temp term alone.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = null,
                hrvBaseline = null, rhrBaseline = null, respBaseline = null,
                sleepPerf = null, skinTempDev = 0.4,
            ),
        )
        // Recovery-Index term alone.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = null,
                hrvBaseline = null, rhrBaseline = null, respBaseline = null,
                sleepPerf = null, recoveryIndexSlope = -1.0,
            ),
        )
        // Activity-Balance term alone.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = null,
                hrvBaseline = null, rhrBaseline = null, respBaseline = null,
                sleepPerf = null, effortBaseline = effortB, priorDayEffort = 80.0,
            ),
        )
        // Every optional driver at once still cannot substitute for the required HRV baseline.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = 14.0,
                hrvBaseline = null, rhrBaseline = rhrB, respBaseline = respB,
                sleepPerf = 0.85, skinTempDev = 0.4, recoveryIndexSlope = -1.0,
                effortBaseline = effortB, priorDayEffort = 80.0,
            ),
        )
    }

    @Test
    fun rawOverloadPreservesColdStartAndValidScores() {
        val hrvB = RecoveryScorer.DriverBaseline(mean = 50.0, spread = 6.0 / 1.253)
        // Cold start unchanged: baseline PRESENT but not usable → null, as before.
        assertNull(
            RecoveryScorer.recovery(
                hrv = 50.0, rhr = 60.0, resp = null,
                hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
                sleepPerf = 0.85, hrvBaselineUsable = false,
            ),
        )
        // A present, usable baseline scores exactly as before (Swift oracle literal above).
        val scored = RecoveryScorer.recovery(
            hrv = 50.0, rhr = 60.0, resp = null,
            hrvBaseline = hrvB, rhrBaseline = null, respBaseline = null,
            sleepPerf = 0.85,
        )
        assertEquals(57.932425214874954, scored!!, 1e-12)
    }
}
