package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the SHARED-CONTRACT Charge "What shaped it" driver rows (RecoveryDrivers.chargeDrivers).
 * Proves: every present term yields exactly one honest row; a missing input yields NO row (never a
 * fabricated zero); deltaPoints sign tracks the signal direction; the cold-start gate yields an empty
 * list; and no row carries an em-dash. Pure-JVM, no Robolectric. Mirrors the iOS chargeDrivers tests.
 */
class RecoveryDriversTest {

    /** A usable baseline with a given mean and Gaussian sigma (spread is internal abs-dev units). */
    private fun baseline(mean: Double, sigma: Double, nValid: Int = 14): BaselineState =
        BaselineState(
            baseline = mean, spread = sigma / 1.253, nValid = nValid, nightsSinceUpdate = 0,
            status = if (nValid >= 14) BaselineStatus.TRUSTED else BaselineStatus.PROVISIONAL,
        )

    @Test fun driverPointRoundingUsesNearestWithHalfTiesAwayFromZero() {
        fun hrvMarginal(
            hrv: Double,
            rhr: Double,
            hrvBaseline: BaselineState,
            rhrBaseline: BaselineState? = null,
        ): Pair<Double, Int> {
            val full = RecoveryScorer.recovery(
                hrv = hrv, rhr = rhr, resp = null,
                hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                respBaseline = null, sleepPerf = null,
            )!!
            val neutral = RecoveryScorer.recovery(
                hrv = hrvBaseline.baseline, rhr = rhr, resp = null,
                hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                respBaseline = null, sleepPerf = null,
            )!!
            val row = RecoveryDrivers.chargeDrivers(
                hrv = hrv, rhr = rhr, resp = null,
                hrvBaseline = hrvBaseline, rhrBaseline = rhrBaseline,
                respBaseline = null, sleepPerf = null,
            ).first { it.label == ChargeDriverLabel.HEART_RATE_VARIABILITY }
            return (full - neutral) to row.deltaPoints
        }

        val negativeBaseline = BaselineState(
            baseline = 30.0, spread = 0.55, nValid = 14,
            nightsSinceUpdate = 0, status = BaselineStatus.TRUSTED,
        )
        val negativeBelowTie = hrvMarginal(29.991177275907276, 60.0, negativeBaseline)
        val negativeTie = hrvMarginal(29.99117725828923, 60.0, negativeBaseline)
        val negativeBeyondTie = hrvMarginal(29.991177240671185, 60.0, negativeBaseline)
        assertTrue(negativeBelowTie.first > -0.5)
        assertEquals(0, negativeBelowTie.second)
        assertEquals(-0.5, negativeTie.first, 0.0)
        assertEquals(-1, negativeTie.second)
        assertTrue(negativeBeyondTie.first < -0.5)
        assertEquals(-1, negativeBeyondTie.second)

        val positiveHRVBaseline = BaselineState(
            baseline = 30.0, spread = 0.55, nValid = 14,
            nightsSinceUpdate = 0, status = BaselineStatus.TRUSTED,
        )
        val positiveRHRBaseline = BaselineState(
            baseline = 60.0, spread = 0.1, nValid = 14,
            nightsSinceUpdate = 0, status = BaselineStatus.TRUSTED,
        )
        val positiveBelowTie = hrvMarginal(
            33.09890762408082, 58.541, positiveHRVBaseline, positiveRHRBaseline,
        )
        val positiveTie = hrvMarginal(
            33.099135135290354, 58.541, positiveHRVBaseline, positiveRHRBaseline,
        )
        val positiveBeyondTie = hrvMarginal(
            33.09936273466694, 58.541, positiveHRVBaseline, positiveRHRBaseline,
        )
        assertTrue(positiveBelowTie.first < 0.5)
        assertEquals(0, positiveBelowTie.second)
        assertEquals(0.5, positiveTie.first, 0.0)
        assertEquals(1, positiveTie.second)
        assertTrue(positiveBeyondTie.first > 0.5)
        assertEquals(1, positiveBeyondTie.second)
    }

    @Test fun issue51NegativeHalfTieUsesDefaultArg8WithoutChangingScoreOrDriverFields() {
        val hrvBaseline = BaselineState(
            baseline = 30.0, spread = 0.55, nValid = 14,
            nightsSinceUpdate = 0, status = BaselineStatus.TRUSTED,
        )
        val scoreBefore = RecoveryScorer.recovery(
            hrv = 29.99117725828923, rhr = 60.0, resp = null,
            hrvBaseline = hrvBaseline, rhrBaseline = null,
            respBaseline = null, sleepPerf = null,
        )
        val neutralScore = RecoveryScorer.recovery(
            hrv = hrvBaseline.baseline, rhr = 60.0, resp = null,
            hrvBaseline = hrvBaseline, rhrBaseline = null,
            respBaseline = null, sleepPerf = null,
        )

        // Intentionally omit arg 8 (skinTempDev) to exercise the real default path from #51.
        val drivers = RecoveryDrivers.chargeDrivers(
            hrv = 29.99117725828923, rhr = 60.0, resp = null,
            hrvBaseline = hrvBaseline, rhrBaseline = null,
            respBaseline = null, sleepPerf = null,
        )
        val scoreAfter = RecoveryScorer.recovery(
            hrv = 29.99117725828923, rhr = 60.0, resp = null,
            hrvBaseline = hrvBaseline, rhrBaseline = null,
            respBaseline = null, sleepPerf = null,
        )

        assertEquals(-0.5, scoreBefore!! - neutralScore!!, 0.0)
        assertEquals(scoreBefore, scoreAfter)
        assertEquals(
            listOf(
                ChargeDriver(
                    label = ChargeDriverLabel.HEART_RATE_VARIABILITY,
                    deltaPoints = -1,
                    value = 29.99117725828923,
                    baseline = 30.0,
                    unit = ChargeDriverUnit.MILLISECONDS,
                    verdict = ChargeDriverVerdict.BELOW_BASELINE_LIMITING,
                ),
            ),
            drivers,
        )
    }

    @Test fun allTermsPresentYieldOneRowEachInOrder() {
        val drivers = RecoveryDrivers.chargeDrivers(
            hrv = 62.0, rhr = 51.0, resp = 15.0,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = baseline(16.0, 2.0),
            sleepPerf = 0.9, skinTempDev = 0.3,
        )
        // All five present terms produce one row each (order is biggest-mover-first, asserted below).
        assertEquals(
            ChargeDriverLabel.entries.toSet(),
            drivers.map { it.label }.toSet(),
        )
        // Rows are sorted biggest-mover-first, matching the Swift twin.
        val magnitudes = drivers.map { kotlin.math.abs(it.deltaPoints) }
        assertEquals(magnitudes.sortedDescending(), magnitudes)
        // Every row carries a finite numeric value and semantic unit/verdict. HRV / resting HR /
        // respiration name a learned baseline; Sleep + Skin temp intentionally carry no baseline
        // (no learned per-night baseline), exactly as the Swift twin does.
        drivers.forEach {
            assertTrue(it.value.isFinite())
            assertTrue(it.unit in ChargeDriverUnit.entries)
            assertTrue(it.verdict in ChargeDriverVerdict.entries)
        }
        listOf(
            ChargeDriverLabel.HEART_RATE_VARIABILITY,
            ChargeDriverLabel.RESTING_HEART_RATE,
            ChargeDriverLabel.RESPIRATORY_RATE,
        ).forEach { label ->
            assertTrue(drivers.first { it.label == label }.baseline != null)
        }
        // The HRV row names the night's value + the personal baseline it was scored against.
        val hrv = drivers.first { it.label == ChargeDriverLabel.HEART_RATE_VARIABILITY }
        assertEquals(62.0, hrv.value, 0.0)
        assertEquals(50.0, hrv.baseline!!, 0.0)
        assertEquals(ChargeDriverUnit.MILLISECONDS, hrv.unit)
    }

    @Test fun missingInputYieldsNoRowNotAFakeZero() {
        // No resp value, no resp baseline, no skin-temp -> those rows are absent entirely.
        val drivers = RecoveryDrivers.chargeDrivers(
            hrv = 55.0, rhr = 55.0, resp = null,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = null, respBaseline = null,
            sleepPerf = 0.85, skinTempDev = null,
        )
        val labels = drivers.map { it.label }
        assertTrue(labels.contains(ChargeDriverLabel.HEART_RATE_VARIABILITY))
        assertTrue(labels.contains(ChargeDriverLabel.SLEEP_QUALITY))
        assertFalse(labels.contains(ChargeDriverLabel.RESTING_HEART_RATE))
        assertFalse(labels.contains(ChargeDriverLabel.RESPIRATORY_RATE))
        assertFalse(labels.contains(ChargeDriverLabel.SKIN_TEMPERATURE))
    }

    @Test fun deltaSignTracksDirection() {
        // HRV well above baseline -> lifts Charge (positive). RHR well above baseline (worse) -> pulls down.
        val drivers = RecoveryDrivers.chargeDrivers(
            hrv = 80.0, rhr = 70.0, resp = null,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = null, sleepPerf = null, skinTempDev = null,
        )
        val hrv = drivers.first { it.label == ChargeDriverLabel.HEART_RATE_VARIABILITY }
        val rhr = drivers.first { it.label == ChargeDriverLabel.RESTING_HEART_RATE }
        assertTrue("HRV above baseline should lift Charge", hrv.deltaPoints > 0)
        assertTrue("Elevated resting HR should pull Charge down", rhr.deltaPoints < 0)
        assertEquals(ChargeDriverVerdict.ABOVE_BASELINE_SUPPORTING, hrv.verdict)
        assertEquals(ChargeDriverVerdict.ABOVE_BASELINE_LIMITING, rhr.verdict)
    }

    @Test fun skinTempIsARelativeDeviationNeverAbsolute() {
        val drivers = RecoveryDrivers.chargeDrivers(
            hrv = 50.0, rhr = 55.0, resp = null,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = null, sleepPerf = null, skinTempDev = 0.4,
        )
        val skin = drivers.first { it.label == ChargeDriverLabel.SKIN_TEMPERATURE }
        assertEquals(ChargeDriverUnit.CELSIUS_DEVIATION, skin.unit)
        assertEquals(0.4, skin.value, 0.0)
        assertNull(skin.baseline)
        // The symmetric penalty never lifts Charge.
        assertTrue(skin.deltaPoints <= 0)
    }

    @Test fun skinTempAndRespirationPreserveRawSemanticMeasurements() {
        val deviations = listOf(-0.35, 0.35, -0.34, 0.34, -0.36, 0.36, -0.0, 0.0)

        deviations.forEach { deviation ->
            val drivers = RecoveryDrivers.chargeDrivers(
                hrv = 46.0, rhr = 58.0, resp = 14.0,
                hrvBaseline = baseline(51.0, 6.265),
                rhrBaseline = baseline(58.0, 5.012, nValid = 12),
                respBaseline = baseline(15.0, 1.8795, nValid = 12),
                sleepPerf = 0.9, skinTempDev = deviation,
            )
            val skin = drivers.first { it.label == ChargeDriverLabel.SKIN_TEMPERATURE }
            assertEquals(deviation.toBits(), skin.value.toBits())
            assertNull(skin.baseline)
            assertEquals(ChargeDriverUnit.CELSIUS_DEVIATION, skin.unit)
            assertTrue(skin.deltaPoints <= 0)

            val respiration = drivers.first { it.label == ChargeDriverLabel.RESPIRATORY_RATE }
            assertEquals(14.0, respiration.value, 0.0)
            assertEquals(15.0, respiration.baseline!!, 0.0)
            assertEquals(ChargeDriverUnit.BREATHS_PER_MINUTE, respiration.unit)
        }
    }

    @Test fun coldStartYieldsEmptyDrivers() {
        val coldHRV = BaselineState(
            baseline = 50.0, spread = 5.0, nValid = 2, nightsSinceUpdate = 0,
            status = BaselineStatus.CALIBRATING,
        )
        val drivers = RecoveryDrivers.chargeDrivers(
            hrv = 60.0, rhr = 50.0, resp = null,
            hrvBaseline = coldHRV, rhrBaseline = null, respBaseline = null,
            sleepPerf = 0.9, skinTempDev = null,
        )
        assertTrue(drivers.isEmpty())
    }

    @Test fun noRowCarriesAnEmDash() {
        val drivers = RecoveryDrivers.chargeDrivers(
            hrv = 62.0, rhr = 51.0, resp = 15.0,
            hrvBaseline = baseline(50.0, 6.0),
            rhrBaseline = baseline(55.0, 3.0),
            respBaseline = baseline(16.0, 2.0),
            sleepPerf = 0.9, skinTempDev = -0.5,
        )
        drivers.forEach { d ->
            val all = "${d.label}${d.unit}${d.verdict}"
            assertFalse("driver row must not contain an em-dash", all.contains("\u2014"))
        }
    }

    @Test fun chargeConfidenceTierIsSurfacedNotRecomputed() {
        // A present score on a trusted baseline surfaces SOLID; a null score surfaces CALIBRATING.
        assertEquals(ScoreConfidence.SOLID, ScoreConfidence.forCharge(60.0, baseline(50.0, 6.0, nValid = 20)))
        assertEquals(ScoreConfidence.CALIBRATING, ScoreConfidence.forCharge(null, baseline(50.0, 6.0)))
        assertNull(RecoveryScorer.recovery(
            hrv = 60.0, rhr = 50.0, resp = null,
            hrvBaseline = BaselineState(50.0, 5.0, 2, 0, BaselineStatus.CALIBRATING),
            rhrBaseline = null, respBaseline = null, sleepPerf = 0.9,
        ))
    }

    @Test fun pass2SkinTempDeviationBeforeRecoveryScoring() {
        val daily = recoveryDailyFixture()
        val baselines = ProfileBaselines(
            hrv = recoveryBaseline(50.0, 6.0), skinTemp = recoveryBaseline(34.5, 0.4),
        )
        val withoutSkin = expectedRecovery(daily, baselines, null)

        for ((nightly, deviation) in listOf(34.804 to 0.3, 34.196 to -0.3)) {
            val result = IntelligenceEngine.recomputeRecoveryDaily(daily, nightly, baselines)
            val expected = requireNotNull(expectedRecovery(daily, baselines, deviation))
            assertTrue("Fixture must distinguish a missing temperature term", expected != withoutSkin)
            assertEquals(expected, result.recovery)
            assertEquals(deviation, result.skinTempDevC)
            assertEquals(nightly, result.skinTempC)
            // Undo only the three intended substitutions; every other daily field must survive.
            assertEquals(daily, result.copy(
                recovery = daily.recovery, skinTempDevC = daily.skinTempDevC, skinTempC = daily.skinTempC,
            ))
        }
    }

    @Test fun pass2MissingOrUnusableSkinBaselineClearsStaleDeviation() {
        val daily = recoveryDailyFixture().copy(recovery = 99.0, skinTempDevC = 9.0, skinTempC = 36.0)
        val usable = recoveryBaseline(34.5, 0.4)
        val cases = listOf(
            null to usable, 34.8 to null,
            34.8 to recoveryBaseline(34.5, 0.4, BaselineStatus.CALIBRATING),
            34.8 to recoveryBaseline(34.5, 0.4, BaselineStatus.STALE),
        )
        for ((nightly, skinBaseline) in cases) {
            val baselines = ProfileBaselines(hrv = recoveryBaseline(50.0, 6.0), skinTemp = skinBaseline)
            val result = IntelligenceEngine.recomputeRecoveryDaily(daily, nightly, baselines)
            assertNull(result.skinTempDevC)
            assertEquals(nightly, result.skinTempC)
            assertEquals(expectedRecovery(daily, baselines, null), result.recovery)
        }
    }

    @Test fun pass2SkinTemperatureDoesNotBypassHrvColdStart() {
        for (hrv in listOf(null, recoveryBaseline(50.0, 6.0, BaselineStatus.CALIBRATING))) {
            val result = IntelligenceEngine.recomputeRecoveryDaily(
                recoveryDailyFixture(), 34.8,
                ProfileBaselines(hrv = hrv, skinTemp = recoveryBaseline(34.5, 0.4)),
            )
            assertNull(result.recovery)
            assertEquals(0.3, result.skinTempDevC)
        }
    }

    private fun recoveryBaseline(
        mean: Double, spread: Double, status: BaselineStatus = BaselineStatus.TRUSTED,
    ) = BaselineState(
        baseline = mean, spread = spread, nValid = if (status == BaselineStatus.CALIBRATING) 3 else 14,
        nightsSinceUpdate = if (status == BaselineStatus.STALE) 15 else 0, status = status,
    )

    private fun recoveryDailyFixture() = DailyMetric(
        deviceId = "test-noop", day = "2026-09-09", totalSleepMin = 420.0, efficiency = 0.85,
        deepMin = 80.0, remMin = 90.0, lightMin = 250.0, disturbances = 2,
        restingHr = 58, avgHrv = 48.0, recovery = 99.0, strain = 61.0, exerciseCount = 2,
        spo2Pct = 97.0, skinTempDevC = null, respRateBpm = 15.0, steps = 42, activeKcalEst = 1_840.0,
        spo2Red = 100, spo2Ir = 200, avgSdnn = 44.0, skinTempC = null, sleepHrOnly = true,
    )

    private fun expectedRecovery(daily: DailyMetric, baselines: ProfileBaselines, skinDev: Double?) =
        RecoveryScorer.recovery(
            hrv = 48.0, rhr = 58.0, resp = 15.0, hrvBaseline = baselines.hrv!!, rhrBaseline = null,
            respBaseline = null,
            sleepPerf = RestScorer.restFromDaily(daily)?.let { it / 100.0 } ?: daily.efficiency,
            skinTempDev = skinDev,
        )
}
