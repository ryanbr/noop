package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Charge / Effort / Rest scoring redesign (2026-06-12).
 *
 * Mirrors the Swift StrandAnalytics scoring tests so cross-platform parity holds:
 *  - Effort (StrainScorer) now maps TRIMP onto 0–100 (maxStrain 21→100, D=7201 unchanged).
 *  - Charge (RecoveryScorer) folds in a symmetric skin-temp penalty (wHRV 0.60→0.55,
 *    wSkinTemp 0.05); the no-skin-temp path is byte-identical to the old model.
 *  - Rest (RestScorer) composite: duration 0.50 + efficiency 0.20 + restorative 0.20 +
 *    consistency 0.10, stored under the sleep_performance key (0–100).
 *  - ScoreConfidence tiers (calibrating / building / solid).
 *
 * Goldens are computed from the closed-form formulas (see the design spec) — keep every
 * constant byte-identical to the Swift source.
 */
class ChargeEffortRestScoringTest {

    private val EPS = 1e-9

    // ── Effort (StrainScorer 0–100) ────────────────────────────────────────────

    @Test
    fun effort_scaleConstantsAreRescaled() {
        // The whole rebrand is a pure linear rescale: maxStrain 21→100, denominator unchanged.
        assertEquals(100.0, StrainScorer.maxStrain, 0.0)
        assertEquals(21.0, StrainScorer.whoopMaxStrain, 0.0)
        assertEquals(7201.0, StrainScorer.strainDenominator, 0.0)
    }

    @Test
    fun effort_whoopAxisValuesMapAcrossTheWholeRange() {
        val cases = listOf(
            0.0 to 0.0,
            1.0 to 4.761904761904762,
            3.5 to 16.666666666666668,
            7.0 to 33.333333333333336,
            10.5 to 50.0,
            12.5 to 59.523809523809526,
            14.0 to 66.66666666666667,
            17.5 to 83.33333333333333,
            20.0 to 95.23809523809524,
            21.0 to 100.0,
        )

        cases.forEach { (whoop, effort) ->
            assertEquals(
                "WHOOP $whoop must map proportionally onto 0–100",
                effort,
                StrainScorer.effortValueFromWhoopStrain(whoop),
                0.0,
            )
        }
    }

    @Test
    fun effort_trimpToStrainMapsOntoZeroHundred() {
        // 100 × ln(t+1) / ln(7201), 2 dp.
        assertEquals(0.0, StrainScorer.trimpToStrain(0.0), 0.0)
        assertEquals(0.0, StrainScorer.trimpToStrain(-5.0), 0.0) // TRIMP ≤ 0 → 0
        assertEquals(51.96, StrainScorer.trimpToStrain(100.0), EPS)
        assertEquals(69.99, StrainScorer.trimpToStrain(500.0), EPS)
        assertEquals(77.78, StrainScorer.trimpToStrain(1000.0), EPS)
        assertEquals(92.20, StrainScorer.trimpToStrain(3600.0), EPS)
        // TRIMP 7200 (Edwards daily ceiling) saturates at the top of the scale.
        assertEquals(100.0, StrainScorer.trimpToStrain(7200.0), EPS)
    }

    @Test
    fun effort_oldGoldensRescaledByHundredOverTwentyOne() {
        // Every former 0–21 golden is the 0–100 value × 21/100 (within 2-dp rounding).
        // trimp=1000 was 16.33 on the 0–21 scale → 16.33 × 100/21 ≈ 77.76, our 0–100 value is 77.78.
        val effort = StrainScorer.trimpToStrain(1000.0)
        val legacy21 = 21.0 * kotlin.math.ln(1001.0) / kotlin.math.ln(7201.0)
        assertEquals(legacy21 * (100.0 / 21.0), effort, 0.02)
    }

    /** 600 constant-bpm samples at 1 Hz so Edwards TRIMP = 600·weight·(1/60) = 10·weight. */
    private fun hrConstant(bpm: Int, n: Int = 600): List<HrSample> =
        (0 until n).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = bpm) }

    @Test
    fun effort_edwardsZoneGoldens_onZeroHundredScale() {
        // restingHR 60, maxHR 160 → hrReserve 100 → %HRR = bpm − 60.
        // zone1 (50–60%): bpm 115 → trimp 10 → 27.00
        assertEquals(
            27.0,
            StrainScorer.strain(hrConstant(115), maxHR = 160.0, restingHR = 60.0)!!,
            EPS,
        )
        // zone3 (70–80%): bpm 135 → trimp 30 → 38.66
        assertEquals(
            38.66,
            StrainScorer.strain(hrConstant(135), maxHR = 160.0, restingHR = 60.0)!!,
            EPS,
        )
        // zone5 (≥90%): bpm 155 → trimp 50 → 44.27
        assertEquals(
            44.27,
            StrainScorer.strain(hrConstant(155), maxHR = 160.0, restingHR = 60.0)!!,
            EPS,
        )
    }

    @Test
    fun effort_nullWhenTooFewSamplesOrInvalidHrr() {
        assertNull(StrainScorer.strain(hrConstant(135, n = 599), maxHR = 160.0, restingHR = 60.0))
        assertNull(StrainScorer.strain(hrConstant(135), maxHR = 60.0, restingHR = 60.0)) // HRR ≤ 0
    }

    // ── #482/#480 sparse-strap acceptance + honest-zero (parity with Swift StrainScorerTests) ──

    /** n samples at a fixed cadence (default 30 s — the WHOOP 5/MG live-HR rate). */
    private fun hrEvery(bpm: Int, n: Int, stepS: Int = 30): List<HrSample> =
        (0 until n).map { HrSample(deviceId = "t", ts = (it * stepS).toLong(), bpm = bpm) }

    @Test
    fun effort_sparseStreamScoresOnceItSpansEnoughTime() {
        // 5/MG: ~30 samples at 30 s — under minReadings (600) but spanning ~15 min, so it scores
        // rather than returning null (which made the live gauge show a stale prior-day value).
        val sparse = hrEvery(155, 30) // 30 × 30 s = 870 s span; 155 bpm ≈ z5 on max 160
        assertTrue(sparse.last().ts - sparse.first().ts >= StrainScorer.minSpanSeconds)
        assertNotNull(StrainScorer.strain(sparse, maxHR = 160.0, restingHR = 60.0))
    }

    @Test
    fun effort_sparseStreamStillNullUnderSampleFloor() {
        val tooFew = hrEvery(155, 5, stepS = 200) // 5 samples, wide span, under floor
        assertNull(StrainScorer.strain(tooFew, maxHR = 160.0, restingHR = 60.0))
    }

    @Test
    fun effort_lightDayHonestlyScoresZeroNotFabricated() {
        // HR below ~50% HRR earns ZERO, by design — the sparse path must not invent load. With
        // max 184 / rest 60, zone 1 starts at 122 bpm; 105 bpm stays below it on both cadences.
        assertEquals(0.0, StrainScorer.strain(hrConstant(105, n = 1200), maxHR = 184.0, restingHR = 60.0))
        assertEquals(0.0, StrainScorer.strain(hrEvery(105, 40), maxHR = 184.0, restingHR = 60.0))
    }

    @Test
    fun effort_sparseStreamScoresRealWorkout() {
        val s = StrainScorer.strain(hrEvery(175, 40), maxHR = 184.0, restingHR = 60.0)
        assertNotNull(s)
        assertTrue(s!! > 0.0)
    }

    // ── Charge (RecoveryScorer skin-temp term) ─────────────────────────────────

    @Test
    fun charge_weightConstants() {
        assertEquals(0.55, RecoveryScorer.wHRV, 0.0)
        assertEquals(0.20, RecoveryScorer.wRHR, 0.0)
        assertEquals(0.15, RecoveryScorer.wSleep, 0.0)
        assertEquals(0.05, RecoveryScorer.wResp, 0.0)
        assertEquals(0.05, RecoveryScorer.wSkinTemp, 0.0)
        // 1.0 °C per z-unit, matching the Swift reference (RecoveryScorer.skinTempScaleC = 1.0). A
        // prior 0.5 here doubled the skin-temp penalty vs macOS/iOS — fixed for parity (#219 audit).
        assertEquals(1.0, RecoveryScorer.skinTempDevScale, 0.0)
    }

    private val hrvBase = RecoveryScorer.DriverBaseline(mean = 60.0, spread = 8.0)
    private val rhrBase = RecoveryScorer.DriverBaseline(mean = 55.0, spread = 4.0)

    /** HRV at baseline, RHR at baseline, sleepPerf at center → composite z = 0. */
    private fun chargeAt(skinDev: Double?): Double? = RecoveryScorer.recovery(
        hrv = 60.0,
        rhr = 55.0,
        resp = null,
        hrvBaseline = hrvBase,
        rhrBaseline = rhrBase,
        respBaseline = null,
        sleepPerf = RecoveryScorer.sleepPerfCenter,
        skinTempDev = skinDev,
    )

    @Test
    fun charge_nullSkinTempIsIdenticalToBefore() {
        // Dropping the skin-temp term must renormalize the remaining weights so the score is
        // unchanged from the pre-skin-temp model.
        val absent = chargeAt(null)!!
        val devZero = chargeAt(0.0)!! // present but zero deviation → same z, same renormalization
        assertNotNull(absent)
        assertEquals(absent, devZero, EPS)
    }

    @Test
    fun charge_skinTempDeviationLowersCharge() {
        val baseScore = chargeAt(null)!!
        val penalized = chargeAt(1.0)!!
        assertTrue("skin-temp deviation should lower Charge", penalized < baseScore)
    }

    @Test
    fun charge_skinTempPenaltyIsSymmetric() {
        // ±1.0 °C deviation costs the same (illness or overreach both penalize).
        assertEquals(chargeAt(1.0)!!, chargeAt(-1.0)!!, EPS)
    }

    @Test
    fun charge_coldStartGateUnaffectedBySkinTemp() {
        // An unusable HRV baseline still refuses to score even with a skin-temp value present.
        val score = RecoveryScorer.recovery(
            hrv = 60.0,
            rhr = 55.0,
            resp = null,
            hrvBaseline = hrvBase,
            rhrBaseline = rhrBase,
            respBaseline = null,
            sleepPerf = 0.85,
            skinTempDev = 0.7,
            hrvBaselineUsable = false,
        )
        assertNull(score)
    }

    // ── Rest (RestScorer composite) ────────────────────────────────────────────

    @Test
    fun rest_weightConstants() {
        assertEquals(0.50, RestScorer.wDuration, 0.0)
        assertEquals(0.20, RestScorer.wEfficiency, 0.0)
        assertEquals(0.20, RestScorer.wRestorative, 0.0)
        assertEquals(0.10, RestScorer.wConsistency, 0.0)
        assertEquals(8.0, RestScorer.defaultSleepNeedHours, 0.0)
        assertEquals(0.50, RestScorer.restorativeTargetShare, 0.0)
    }

    @Test
    fun rest_nullWhenNoAsleepTime() {
        assertNull(RestScorer.rest(0.0, 0.9, 0.0, 0.0))
    }

    @Test
    fun rest_compositeWithoutConsistencyUsesNeutral() {
        // 8h asleep (dur 100), eff 0.92 (92), deep 1.5h + REM 2h = 3.5h restorative,
        // share 0.4375 / 0.50 → 87.5. No consistency → NEUTRAL 50 at full weight (Swift parity: the
        // term is NOT dropped/renormalized). Weights 0.50/0.20/0.20/0.10 sum to 1.0.
        val score = RestScorer.rest(
            asleepSeconds = 8 * 3600.0,
            efficiency = 0.92,
            deepSeconds = 1.5 * 3600.0,
            remSeconds = 2.0 * 3600.0,
        )!!
        val expected = 100.0 * 0.50 + 92.0 * 0.20 + 87.5 * 0.20 + 50.0 * 0.10
        assertEquals(expected, score, EPS)
    }

    @Test
    fun rest_consistencyTermIncluded() {
        val score = RestScorer.rest(
            asleepSeconds = 8 * 3600.0,
            efficiency = 0.92,
            deepSeconds = 1.5 * 3600.0,
            remSeconds = 2.0 * 3600.0,
            consistency = 0.80,
        )!!
        val expected = (100.0 * 0.50 + 92.0 * 0.20 + 87.5 * 0.20 + 80.0 * 0.10) / 1.0
        assertEquals(expected, score, EPS)
    }

    @Test
    fun rest_durationDominatesShortNight() {
        // 4h asleep against the 8h default → duration 50; eff 0.95 (95); restorative share 0.5 → 100.
        // No consistency → neutral 50 at full weight (Swift parity). Weights sum to 1.0.
        val score = RestScorer.rest(
            asleepSeconds = 4 * 3600.0,
            efficiency = 0.95,
            deepSeconds = 1.0 * 3600.0,
            remSeconds = 1.0 * 3600.0,
        )!!
        val expected = 50.0 * 0.50 + 95.0 * 0.20 + 100.0 * 0.20 + 50.0 * 0.10
        assertEquals(expected, score, EPS)
    }

    @Test
    fun rest_personalNeedRefinementRaisesDuration() {
        // Same 6h asleep scores higher once personal need is refined down to 6h (duration → 100).
        val defaultNeed = RestScorer.rest(6 * 3600.0, 0.90, 1.0 * 3600.0, 1.5 * 3600.0)!!
        val refined = RestScorer.rest(6 * 3600.0, 0.90, 1.0 * 3600.0, 1.5 * 3600.0, sleepNeedHours = 6.0)!!
        assertTrue(refined > defaultNeed)
    }

    @Test
    fun rest_oversleepDurationClampsAtHundred() {
        // 10h asleep against an 8h need does not over-credit: duration clamps at 100.
        val score = RestScorer.rest(10 * 3600.0, 0.90, 2.0 * 3600.0, 2.5 * 3600.0)!!
        val restShare = (2.0 + 2.5) / 10.0 // 0.45 → /0.5 → 90
        // No consistency → neutral 50 at full weight (Swift parity). Weights sum to 1.0.
        val expected = 100.0 * 0.50 + 90.0 * 0.20 + (restShare / 0.50 * 100.0) * 0.20 + 50.0 * 0.10
        assertEquals(expected, score, EPS)
    }

    // ── ScoreConfidence tiers ──────────────────────────────────────────────────

    private fun baseline(nValid: Int, status: BaselineStatus): BaselineState =
        BaselineState(baseline = 60.0, spread = 8.0, nValid = nValid, nightsSinceUpdate = 0, status = status)

    @Test
    fun confidence_chargeTiers() {
        // No score → calibrating regardless of baseline.
        assertEquals(
            ScoreConfidence.CALIBRATING,
            ScoreConfidence.forCharge(null, baseline(20, BaselineStatus.TRUSTED)),
        )
        // Score but baseline not usable → calibrating.
        assertEquals(
            ScoreConfidence.CALIBRATING,
            ScoreConfidence.forCharge(60.0, baseline(2, BaselineStatus.CALIBRATING)),
        )
        // Score, provisional/thin baseline (< 7 nights) → building.
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.forCharge(60.0, baseline(5, BaselineStatus.PROVISIONAL)),
        )
        // Score, full trusted baseline → solid.
        assertEquals(
            ScoreConfidence.SOLID,
            ScoreConfidence.forCharge(60.0, baseline(20, BaselineStatus.TRUSTED)),
        )
    }

    @Test
    fun confidence_effortTiers() {
        assertEquals(ScoreConfidence.CALIBRATING, ScoreConfidence.forEffort(null, 5000))
        assertEquals(ScoreConfidence.BUILDING, ScoreConfidence.forEffort(40.0, 1200))
        assertEquals(ScoreConfidence.SOLID, ScoreConfidence.forEffort(40.0, 5000))
    }

    @Test
    fun confidence_restTiers() {
        // Mirrors Swift AnalyticsEngineTests: the tier depends on staged sleep for THIS night,
        // not on sleep-need history length.
        assertEquals(ScoreConfidence.CALIBRATING,
            ScoreConfidence.forRest(hasSession = false, hasStagedSleep = false))
        assertEquals(ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(hasSession = true, hasStagedSleep = false))
        assertEquals(ScoreConfidence.SOLID,
            ScoreConfidence.forRest(hasSession = true, hasStagedSleep = true))
    }

    @Test
    fun confidence_rawStringsMatchSwift() {
        assertEquals("calibrating", ScoreConfidence.CALIBRATING.raw)
        assertEquals("building", ScoreConfidence.BUILDING.raw)
        assertEquals("solid", ScoreConfidence.SOLID.raw)
    }

    // H9: a high-efficiency night whose deep+REM share is implausibly low is flagged LOW-CONFIDENCE
    // (downgraded SOLID → BUILDING) — honest "staging may be off", no faked stages. Mirrors Swift.
    @Test
    fun confidence_restH9DowngradesLowRestorativeHighEfficiencyNight() {
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.03, efficiency = 0.95,
            ),
        )
    }

    // Hypnogram coverage: a stage timeline that accounts for only part of the span it claims cannot earn
    // a SOLID Rest. The case the other two guards structurally cannot see. Mirrors Swift.
    @Test
    fun confidence_restCoverageDowngradesHoledHypnogram() {
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.80,
                stageCoverage = 0.23,
            ),
        )
    }

    @Test
    fun confidence_restCoverageKeepsSolidWhenTimelineCoversItsSpan() {
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.SOLID,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.80,
                stageCoverage = 1.0,
            ),
        )
    }

    /** Unknown coverage must fail OPEN — null is "not measured", never "measured badly". */
    @Test
    fun confidence_restCoverageUnknownDoesNotDowngrade() {
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.SOLID,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.80,
                stageCoverage = null,
            ),
        )
    }

    /**
     * The measured night this guard exists for (2026-08-18, Oura ring vs a paired WHOOP strap): the
     * hypnogram covered 140 of 601 minutes, so NOOP stored 70 minutes of sleep where the strap recorded
     * 494. It read SOLID because NEITHER existing guard applies — gravitySparse is false (Oura banks no
     * gravity at all) and H9 needs efficiency >= 0.85 against this night's 0.50. Mirrors Swift.
     */
    @Test
    fun confidence_restCoverageCatchesTheNightH9AndGravityMiss() {
        val asleep = 70.0 * 60.0
        val restorative = asleep * 0.45
        assertEquals(
            "precondition: without coverage this night reads SOLID — that is the bug",
            ScoreConfidence.SOLID,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = restorative, efficiency = 0.50,
                gravitySparse = false,
            ),
        )
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = restorative, efficiency = 0.50,
                gravitySparse = false, stageCoverage = 140.0 / 601.0,
            ),
        )
    }

    @Test
    fun confidence_restH9KeepsSolidWhenRestorativeHealthy() {
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.SOLID,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.95,
            ),
        )
    }

    @Test
    fun confidence_restH9DoesNotFlagLowEfficiencyNight() {
        // A fragmented (low-efficiency) night legitimately carries little deep/REM — must NOT flag it.
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.SOLID,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.03, efficiency = 0.60,
            ),
        )
    }

    @Test
    fun confidence_restH9NeverUpgradesNonSolidBase() {
        // No staged sleep → base BUILDING; H9 only DOWNGRADES, so it can't lift to SOLID.
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = false,
                asleepSeconds = 8.0 * 3600.0, restorativeSeconds = 0.0, efficiency = 0.95,
            ),
        )
    }

    // #345: a night staged on SPARSE gravity (WHOOP 4.0 offload banks motion coarsely) is downgraded to
    // low-confidence WHATEVER the engine filled in — this catches the #319 case H9 misses: high efficiency
    // AND healthy restorative (V2 manufactured stages on too little motion) would read SOLID under H9, but
    // the coarse motion can't support a confident 85–100.
    @Test
    fun confidence_restSparseGravityDowngradesEvenHealthyLookingNight() {
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.95,
                gravitySparse = true,
            ),
        )
    }

    @Test
    fun confidence_restSparseGravityDefaultsFalseSoDenseNightsUnchanged() {
        // Default gravitySparse=false → a dense healthy night stays SOLID (byte-identical to old callers).
        val asleep = 8.0 * 3600.0
        assertEquals(
            ScoreConfidence.SOLID,
            ScoreConfidence.forRest(
                hasSession = true, hasStagedSleep = true,
                asleepSeconds = asleep, restorativeSeconds = asleep * 0.45, efficiency = 0.95,
            ),
        )
    }
}
