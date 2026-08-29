package com.noop.testcentre

import com.noop.analytics.CircadianEngine
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The body-clock verdict line. The card vanishing has two indistinguishable causes on screen — no
 * estimate at all (below the bucket or hour floor) versus an estimate marked unreadable (thin or flat
 * fit, which still draws its own card) — so the wording has to name WHICH floor is short.
 */
class CircadianVerdictTest {

    private fun verdict(buckets: Int, hours: Int, days: Int, amp: Double? = 0.5, bpm: Double? = null) =
        AndroidDiagnostics.circadianVerdict(buckets, hours, days, amp, bpm)

    /** Gates are reported in the order the pipeline applies them: the bucket floor short-circuits first. */
    @Test fun theBucketFloorIsReportedBeforeAnythingElse() {
        val v = verdict(buckets = 10, hours = 2, days = 1)
        assertTrue(v, v.startsWith("no estimate"))
        assertTrue(v, v.contains("10 hourly HR buckets") && v.contains("needs 24"))
    }

    @Test fun theHourFloorIsNamedWhenBucketsAreFine() {
        val v = verdict(buckets = 100, hours = 4, days = 9)
        assertTrue(v, v.startsWith("no estimate"))
        assertTrue(v, v.contains("4 of 24 local hours") && v.contains("needs 6"))
    }

    /**
     * A flat rhythm and a short history BOTH yield UNREADABLE from the engine, and the card still draws
     * for either — so the line must distinguish them or it explains nothing.
     */
    @Test fun aFlatRhythmIsDistinguishedFromAShortHistory() {
        val flat = verdict(buckets = 300, hours = 20, days = 20, amp = 0.02)
        assertTrue(flat, flat.startsWith("unreadable") && flat.contains("too flat"))
        val thin = verdict(buckets = 300, hours = 20, days = 3, amp = 0.5)
        assertTrue(thin, thin.startsWith("unreadable") && thin.contains("3 days observed"))
    }

    /** The readable tiers name the confidence the card will actually show. */
    @Test fun readableTiersMatchTheEnginesOwnThresholds() {
        val wide = verdict(buckets = 300, hours = 20, days = CircadianEngine.minDaysForFit)
        assertTrue(wide, wide.startsWith("wide"))
        val solid = verdict(buckets = 300, hours = 20, days = CircadianEngine.goodDaysForFit)
        assertTrue(solid, solid.startsWith("solid"))
    }

    /** An unmeasurable amplitude must not be read as a flat rhythm. */
    @Test fun anUnknownAmplitudeDoesNotReadAsFlat() {
        val v = verdict(buckets = 300, hours = 20, days = 20, amp = null)
        assertTrue(v, v.startsWith("solid"))
    }

    /**
     * The bucket floor is a bare literal inside `circadianBinsFrom`, so it cannot be referenced the way
     * the hour floor now is. Pin it against the real behaviour instead of trusting a comment to keep the
     * two in step — a diagnostic that names the wrong threshold sends its reader after the wrong thing.
     */
    @Test fun theReportedBucketFloorIsTheOneCircadianBinsFromActuallyApplies() {
        fun binsFor(n: Int) = com.noop.ui.circadianBinsFrom(
            (0 until n).map { com.noop.data.HrBucket(bucket = it * 3600L, avgBpm = 60.0) }, 0L,
        ).first
        val floor = AndroidDiagnostics.CIRCADIAN_MIN_BUCKETS
        assertTrue("one under the reported floor must still be refused", binsFor(floor - 1).isEmpty())
        assertTrue("the reported floor must be enough", binsFor(floor).isNotEmpty())
    }

    /**
     * The diagnostic must mirror the engine's OR, not just its relative half. The measured wearer -
     * 7.3% of mesor but 5.5 bpm of swing - is rhythmic to the engine, so a line still calling that "too
     * flat" would send its reader after a threshold that is no longer the reason for anything.
     */
    @Test fun anAbsoluteSwingClearsTheGateInTheVerdictToo() {
        val v = verdict(buckets = 328, hours = 24, days = 15, amp = 0.073, bpm = 5.5)
        assertTrue(v, !v.contains("too flat"))
        // WIDE, not solid: readable on the absolute floor but short of the proportional bar, which is
        // exactly how estimatePhase tiers it. This assertion said "solid" and so PINNED a divergence
        // between the diagnostic and the engine instead of catching it — the wearer it was written from
        // had a log reading "solid" beside a card the engine had marked wide.
        assertTrue(v, v.startsWith("wide"))
        assertTrue(v, v.contains("absolute floor"))
    }

    /** A proportional swing with the days behind it is the only thing that reads solid. */
    @Test fun onlyBothAxesReadSolid() {
        val v = verdict(buckets = 328, hours = 24, days = 15, amp = 0.15, bpm = 9.0)
        assertTrue(v, v.startsWith("solid"))
    }

    /** Below BOTH measures it is still reported as flat. */
    @Test fun belowBothMeasuresIsStillFlat() {
        val v = verdict(buckets = 328, hours = 24, days = 15, amp = 0.05, bpm = 3.0)
        assertTrue(v, v.startsWith("unreadable") && v.contains("too flat"))
    }

    /**
     * The structural guard. This line has drifted from the engine TWICE — once when the absolute floor
     * added an OR, once when SOLID started needing both axes — and each time a hand-written case either
     * missed it or pinned it. So rather than assert more cases, drive the REAL engine and the REAL
     * verdict over a grid and require they agree, which makes a future rule change fail here the moment
     * only one side is updated.
     */
    @Test fun theVerdictNeverDisagreesWithTheEngine() {
        fun bins(mesor: Double, amp: Double) = (0 until 24).map { h ->
            CircadianEngine.ActivityBin(
                h.toDouble(),
                mesor + amp * kotlin.math.cos(2.0 * Math.PI * (h - 16.0) / 24.0),
            )
        }
        for (days in listOf(5, 10, 15, 20)) {
            for (mesor in listOf(45.0, 65.0, 74.7)) {
                for (amp in listOf(3.0, 4.6, 5.5, 8.0, 12.0)) {
                    val b = bins(mesor, amp)
                    val est = CircadianEngine.estimatePhase(b, days, 7.0)
                    // Feed the verdict what the ENGINE saw — the recovered fit — not the nominal inputs,
                    // exactly as circadianLines does. Passing amp/mesor would test a pairing production
                    // never uses, and would go flaky the moment a grid point sat within the cosinor's
                    // recovery error of a threshold.
                    val fit = CircadianEngine.cosinor(b)!!
                    val rel = fit.amplitude / kotlin.math.abs(fit.mesor)
                    val expected = when (est?.confidence) {
                        CircadianEngine.PhaseConfidence.SOLID -> "solid"
                        CircadianEngine.PhaseConfidence.WIDE -> "wide"
                        CircadianEngine.PhaseConfidence.UNREADABLE -> "unreadable"
                        null -> "no estimate"
                    }
                    // The counts are deliberately generous: this isolates the amplitude/days rules, which
                    // are the halves that have drifted.
                    val v = AndroidDiagnostics.circadianVerdict(328, 24, days, rel, fit.amplitude)
                    assertTrue(
                        "mesor=$mesor amp=$amp days=$days -> engine says $expected, verdict says \"$v\"",
                        v.startsWith(expected),
                    )
                }
            }
        }
    }
}
