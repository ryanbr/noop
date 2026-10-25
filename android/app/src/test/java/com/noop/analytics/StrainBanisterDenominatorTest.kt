package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
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

    /**
     * Ceiling = 24 h × ΔHRR 1.0 × scale × e^b, stated independently of the implementation, with the
     * PUBLISHED pair per sex: 0.64 and 1.92 for men, 0.86 and 1.67 for women.
     *
     * REPINNED (#2835). The women's line used to read `1440.0 * 0.64 * exp(1.67)`, hardcoding the men's
     * coefficient against the women's exponent, which is what the implementation did. So this test agreed
     * with the code because both made the same mistake, while its own doc claimed the ceiling was stated
     * independently of the implementation. An independent statement means the numbers come from the
     * paper, which is now what these two lines hold.
     */
    @Test
    fun theDailyCeilingIsTwentyFourHoursAtFullReserve() {
        assertEquals(1440.0 * 0.64 * exp(1.92),
            StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(false)), eps)
        assertEquals(1440.0 * 0.86 * exp(1.67),
            StrainScorer.banisterDailyCeiling(StrainScorer.banisterCoefficients(true)), eps)
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
            val c = StrainScorer.banisterCoefficients(sex == "female")
            assertEquals(
                StrainScorer.banisterDailyCeiling(c) - StrainScorer.banisterBaseline(day, c) + 1.0,
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
            val c = StrainScorer.banisterCoefficients(sex == "female")
            // #1624: the quantity that maps to the top is a maximum day's EXCESS over the sedentary
            // baseline, not its raw TRIMP — because that is what the scorer now feeds the log map. Feeding
            // the raw ceiling here overshoots (100.21), which is the arithmetic working, not breaking.
            // The end-to-end invariant — real samples at full reserve through strain() scoring exactly
            // 100 — is pinned in BanisterBaselineTest.
            val ceiling = StrainScorer.banisterDailyCeiling(c) -
                StrainScorer.banisterBaseline(24.0 * 60.0, c)
            assertEquals("$sex ceiling should map to the top of the scale", 100.0,
                StrainScorer.trimpToStrain(
                    ceiling, StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, sex)), 1e-6)
        }
    }

    /**
     * Sex matters, and the DIRECTION reversed with #2835, which is worth stating rather than quietly
     * re-sorting. Under the old single 0.64 the women's smaller exponent alone decided it, so the women's
     * denominator was the smaller. With the published pair the larger multiplier more than offsets the
     * smaller exponent (0.86·e^1.67 = 4.57 against 0.64·e^1.92 = 4.36), so it is now the larger. The
     * point of the test is unchanged: the two are not interchangeable.
     */
    @Test
    fun theDenominatorsDifferBySexAndFemaleIsNowTheLarger() {
        val male = StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, "male")
        val female = StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, "female")
        assertTrue("female $female should now be above male $male", female > male)
        for (spelling in listOf("f", "F", "Female", "female")) {
            assertEquals(female, StrainScorer.logMapDenominator(StrainScorer.Method.BANISTER, spelling), eps)
        }
    }

    /**
     * The pair cannot be split, which is the repair #2835 actually asked for. Selecting a sex yields BOTH
     * of that sex's published coefficients, so the earlier failure, women's exponent with men's
     * multiplier, is no longer expressible.
     */
    @Test
    fun eachSexGetsBothOfItsPublishedCoefficients() {
        assertEquals(0.64, StrainScorer.banisterCoefficients(false).scale, eps)
        assertEquals(1.92, StrainScorer.banisterCoefficients(false).b, eps)
        assertEquals(0.86, StrainScorer.banisterCoefficients(true).scale, eps)
        assertEquals(1.67, StrainScorer.banisterCoefficients(true).b, eps)
        assertNotEquals(
            "a shared multiplier is the defect this pair exists to prevent",
            StrainScorer.banisterCoefficients(false).scale,
            StrainScorer.banisterCoefficients(true).scale,
        )
    }

    // ── Why reusing Edwards' denominator would be wrong ─────────────────────────────────────────

    /**
     * The bug this guards against. With 7201 a maximum Banister day lands well short of 100 — nobody
     * would ever see the top of the scale, and the shortfall differs by sex, so the two would not even be
     * wrong in the same way.
     */
    @Test
    fun edwardsDenominatorWouldCapBanisterBelowFull() {
        // REPINNED from a 90-to-99 band to the exact figures (#2835). The band was chosen when a woman's
        // ceiling was 4,896 and scored 95.66 through 7201; with the published 0.86 it is 6,579 and scores
        // 98.98, which still satisfies `< 99.0` by two hundredths. A bound that survives by a sixtieth of a point
        // is not testing anything, and the next coefficient change would have broken it without any
        // statement of what the right answer is. Exact values also make THIS test catch a wrong
        // coefficient: the old pairing scored 95.66 here, three points away. Pinned exactly rather
        // than with a tolerance because `trimpToStrain` rounds to two decimals, so these ARE the outputs.
        for ((sex, want) in listOf("male" to 98.47, "female" to 98.98)) {
            val c = StrainScorer.banisterCoefficients(sex == "female")
            val wrong = StrainScorer.trimpToStrain(
                StrainScorer.banisterDailyCeiling(c), StrainScorer.strainDenominator)
            assertEquals("$sex: reusing 7201 caps a maximum Banister day here", want, wrong, 1e-9)
            assertTrue("$sex: nobody would ever see the top of the scale ($wrong)", wrong < 100.0)
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
