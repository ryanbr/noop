package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.exp
import kotlin.math.roundToInt

/**
 * #1545: Banister TRIMP needs its OWN log-map denominator, and the reason is easy to get wrong.
 *
 * [StrainScorer.strainDenominator] (7201) is derived from *Edwards'* daily ceiling — top zone weight 5
 * sustained for 24 h = 7200 — so ln(7201)/ln(7201) = 1 puts a theoretical maximum day at exactly 100.
 * Banister accumulates on a completely different scale, and its ceiling is SEX-DEPENDENT because the
 * exponent differs. Reusing 7201 would quietly score every Banister day against a ceiling it cannot reach.
 *
 * Byte-parity twin of Swift `StrainBanisterDenominatorTests`.
 */
class StrainBanisterDenominatorTest {

    private val eps = 1e-9

    private fun hr(bpm: Int, n: Int) = (0 until n).map { HrSample(deviceId = "t", ts = it.toLong(), bpm = bpm) }

    // ── The derivation ──────────────────────────────────────────────────────────────────────────

    /** Ceiling = 24 h × ΔHRR 1.0 × 0.64 × e^b, stated independently of the implementation. */
    @Test
    fun theDailyCeilingIsTwentyFourHoursAtFullReserve() {
        assertEquals(1440.0 * 0.64 * exp(1.92),
            StrainScorer.banisterDailyCeiling(StrainScorer.banisterBMen), eps)
        assertEquals(1440.0 * 0.64 * exp(1.67),
            StrainScorer.banisterDailyCeiling(StrainScorer.banisterBWomen), eps)
    }

    /**
     * The denominator is (ceiling MINUS a full day of sedentary baseline) + 1.
     *
     * #1545 derived it as ceiling + 1, mirroring how [StrainScorer.strainDenominator] came from 7200.
     * #1624 subtracts the same baseline from the denominator that the scorer subtracts from each day, so
     * both ends of the axis line up with Edwards: no exertion maps to 0 AND a maximum day still maps to
     * 100. Anchoring one end only would trade one mismatch for the other.
     */
    @Test
    fun theDenominatorIsCeilingMinusBaselinePlusOne() {
        val day = 24.0 * 60.0
        for (sex in listOf("male", "female")) {
            val b = if (sex == "female") StrainScorer.banisterBWomen else StrainScorer.banisterBMen
            assertEquals(
                StrainScorer.banisterDailyCeiling(b) - StrainScorer.banisterBaseline(day, b) + 1.0,
                StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, sex), eps)
        }
    }

    /**
     * The property the whole derivation exists for: a theoretical maximum day maps to exactly 100 under
     * EITHER method, so the two are on the same axis and a user switching between them is not silently
     * rescaled.
     */
    @Test
    fun aMaximumDayIsOneHundredUnderBothMethods() {
        assertEquals(100.0, StrainScorer.trimpToStrain(7200.0, StrainScorer.strainDenominator), 1e-6)
        for (sex in listOf("male", "female")) {
            val b = if (sex == "female") StrainScorer.banisterBWomen else StrainScorer.banisterBMen
            // #1624: the quantity that maps to the top is a maximum day's EXCESS over the sedentary
            // baseline, not its raw TRIMP — because that is what the scorer now feeds the log map. Feeding
            // the raw ceiling here overshoots (100.21), which is the arithmetic working, not breaking.
            // The end-to-end invariant — real samples at full reserve through strain() scoring exactly
            // 100 — is pinned in BanisterBaselineTest.
            val ceiling = StrainScorer.banisterDailyCeiling(b) -
                StrainScorer.banisterBaseline(24.0 * 60.0, b)
            assertEquals("$sex ceiling should map to the top of the scale", 100.0,
                StrainScorer.trimpToStrain(
                    ceiling, StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, sex)), 1e-6)
        }
    }

    /** The smaller exponent gives the lower ceiling, so a woman's denominator is the smaller of the two. */
    @Test
    fun theFemaleDenominatorIsSmaller() {
        val male = StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, "male")
        val female = StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, "female")
        assertTrue("female $female should be below male $male", female < male)
        for (spelling in listOf("f", "F", "Female", "female")) {
            assertEquals(female, StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, spelling), eps)
        }
    }

    // ── Why reusing Edwards' denominator would be wrong ─────────────────────────────────────────

    /**
     * The bug this guards against. With 7201 a maximum Banister day lands well short of 100 — nobody
     * would ever see the top of the scale, and the shortfall differs by sex, so the two would not even be
     * wrong in the same way.
     */
    @Test
    fun edwardsDenominatorWouldCapBanisterBelowFull() {
        for (sex in listOf("male", "female")) {
            val b = if (sex == "female") StrainScorer.banisterBWomen else StrainScorer.banisterBMen
            val wrong = StrainScorer.trimpToStrain(
                StrainScorer.banisterDailyCeiling(b), StrainScorer.strainDenominator)
            assertTrue("$sex: reusing 7201 should visibly under-score, and does ($wrong)", wrong < 99.0)
            assertTrue("$sex: but not so far off that it looks obviously broken ($wrong)", wrong > 90.0)
        }
    }

    // ── Edwards is untouched ────────────────────────────────────────────────────────────────────

    /** The default is still Edwards and still resolves to 7201, so nothing about existing scores moves. */
    @Test
    fun edwardsIsUnchangedAndStillTheDefault() {
        assertEquals(StrainScorer.strainDenominator,
            StrainScorer.logMapDenominator(StrainScorer.Method.EDWARDS, "male"), eps)
        assertEquals(StrainScorer.strainDenominator,
            StrainScorer.logMapDenominator(StrainScorer.Method.EDWARDS, "female"), eps)

        val samples = hr(150, 900)
        val implicitDefault = StrainScorer.strain(samples, maxHR = 190.0, restingHR = 60.0)
        val explicitEdwards = StrainScorer.strain(
            samples, maxHR = 190.0, restingHR = 60.0, method = StrainScorer.Method.EDWARDS)
        assertNotNull(implicitDefault)
        assertEquals(explicitEdwards!!, implicitDefault!!, 1e-12)
    }

    // ── The behaviour #1545 asked about ─────────────────────────────────────────────────────────

    /**
     * The claim under the request: an intermittent session — hard sets with recovery between — is scored
     * relatively higher by Banister than by Edwards. Compared as a RATIO against a steady session of the
     * same length, because the two methods have different natural magnitudes.
     */
    @Test
    fun intermittentWorkFaresBetterUnderBanister() {
        val rest = 60.0; val max = 190.0; val reserve = max - rest
        fun bpm(pctHRR: Double) = (rest + reserve * pctHRR / 100.0).roundToInt()
        val lifting = (0 until 3600).map {
            HrSample("t", it.toLong(), if (it % 180 < 30) bpm(85.0) else bpm(40.0))
        }
        val walking = (0 until 3600).map { HrSample("t", it.toLong(), bpm(58.0)) }

        val liftEd = StrainScorer.strain(lifting, max, rest, StrainScorer.Method.EDWARDS)!!
        val walkEd = StrainScorer.strain(walking, max, rest, StrainScorer.Method.EDWARDS)!!
        val liftBa = StrainScorer.strain(lifting, max, rest, StrainScorer.Method.BANISTER)!!
        val walkBa = StrainScorer.strain(walking, max, rest, StrainScorer.Method.BANISTER)!!

        assertTrue("Edwards should favour the steady session; that is the complaint", walkEd > liftEd)
        assertTrue("Banister should rate the intermittent session relatively higher",
            liftBa / walkBa > liftEd / walkEd)
    }

    /**
     * The mechanism that actually explains #1545, and it is NOT the exponential weighting of peaks.
     *
     * Edwards pays ZERO below 50% HRR. A session that sits just under that floor — what an hour of
     * lifting looks like for plenty of people once the sets are averaged against the rests — scores
     * literally nothing, however long it lasts. Banister has no floor, so the same hour scores in the
     * same range as a moderate walk. That is the difference between "the metric under-rates lifting" and
     * "the metric cannot see it at all".
     */
    @Test
    fun aSessionBelowTheFiftyPercentFloorScoresNothingUnderEdwards() {
        val rest = 60.0; val max = 190.0
        val bpm = (rest + (max - rest) * 0.45).roundToInt()   // a flat 45% HRR — just under the floor
        val hour = hr(bpm, 3600)

        val edwards = StrainScorer.strain(hour, max, rest, StrainScorer.Method.EDWARDS)
        val banister = StrainScorer.strain(hour, max, rest, StrainScorer.Method.BANISTER)

        assertEquals("an hour below the floor earns nothing under Edwards, by design", 0.0, edwards!!, eps)
        assertNotNull(banister)
        assertTrue("Banister credits the same hour on the 0–100 axis ($banister)", banister!! > 40.0)
    }
}
