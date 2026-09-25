package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #2438 step 0: the day's HRmax, where it came from, and what the day's heart rate actually reached.
 *
 * The proposal turns on a comparison a log could not previously be read for — the yardstick a day was
 * scored against, against the one the day itself suggests — because `effort score` prints `provided` for
 * a manual override and for the Tanaka age formula alike.
 *
 * These lines are contributed as evidence and then argued from, by people who cannot re-run the day that
 * produced them. A diagnostic that names the wrong branch is worse than none, which is why the branch is
 * pinned end to end here and not only as a string.
 *
 * Byte-parity twin of Swift `EffortDayCalibrationTests`.
 */
class EffortDayCalibrationTest {

    // ---- the line ----

    /** The exact bytes. Compared between two contributors' logs, and between Android and iOS. */
    @Test
    fun `the line is exactly this`() {
        assertEquals(
            "effort calib day=2026-09-25 hrmax=195 src=override tanaka=187 peak=178 rhr=52",
            StrainScorer.dayCalibrationLine(
                day = "2026-09-25", hrmax = 195.0, hrmaxSource = "override",
                tanaka = 187.0, observedPeak = 178.0, restingHR = 52.0,
            ),
        )
    }

    /**
     * An age-less profile has no formula value and a day with no heart rate has no peak. Both must say
     * so: printing 0 would make "we never measured it" indistinguishable from a reading of zero, and this
     * line exists to be subtracted from.
     */
    @Test
    fun `missing values render as nil not zero`() {
        assertEquals(
            "effort calib day=2026-09-25 hrmax=nil src=default tanaka=nil peak=nil rhr=60",
            StrainScorer.dayCalibrationLine(
                day = "2026-09-25", hrmax = null, hrmaxSource = "default",
                tanaka = null, observedPeak = null, restingHR = 60.0,
            ),
        )
    }

    /**
     * The three source words are disjoint, and none of them is `effort score`'s `provided` — the whole
     * point is that the word on this line resolves the one on that line.
     */
    @Test
    fun `the source words are disjoint and not provided`() {
        val words = listOf("override", "tanaka", "default")
        assertEquals(words.size, words.toSet().size)
        assertFalse(words.contains("provided"))
    }

    // ---- end to end, through the engine ----

    /**
     * A manual override must read as `override`, with the formula value still printed beside it. That
     * pair is the step-0 question in one line: an override of 195 on a profile Tanaka puts at 187 is a
     * day scored 8 bpm higher than the formula would have.
     */
    @Test
    fun `an override is named as one and still prints tanaka`() {
        assertEquals(
            "effort calib day=2026-09-25 hrmax=195 src=override tanaka=187 peak=178 rhr=60",
            calibLine(age = 30.0, maxHROverride = 195.0, peakBpm = 178),
        )
    }

    /**
     * With no override the day runs on the formula, and `hrmax` and `tanaka` are then the same number. A
     * reader seeing them agree knows no setting was in force without having to know the profile.
     */
    @Test
    fun `no override is named tanaka and agrees with it`() {
        assertEquals(
            "effort calib day=2026-09-25 hrmax=187 src=tanaka tanaka=187 peak=178 rhr=60",
            calibLine(age = 30.0, maxHROverride = null, peakBpm = 178),
        )
    }

    /**
     * No age, no override: [StrainScorer.strain] substitutes its own default internally, and the line
     * reports THAT number rather than null, because it is the yardstick the day was really scored
     * against. `tanaka` is null, since without an age there is no formula value, and that is the honest
     * half.
     *
     * The null version of this was the first draft, and it made the line contradict `effort score` about
     * the same day: that line prints the substituted 190 while this one claimed there was no HRmax.
     */
    @Test
    fun `an ageless profile reports the substituted default`() {
        assertEquals(
            "effort calib day=2026-09-25 hrmax=190 src=default tanaka=nil peak=178 rhr=60",
            calibLine(age = 0.0, maxHROverride = null, peakBpm = 178),
        )
    }

    /**
     * The peak is the day's RAW maximum, not a percentile and not a trimmed one. The rule under
     * discussion counts days whose peak crossed a threshold, so a single high minute has to reach the
     * line — the two-different-days requirement is what absorbs an artefact, not a quiet formatter.
     */
    @Test
    fun `a single high minute reaches the peak`() {
        assertTrue(calibLine(age = 30.0, maxHROverride = null, peakBpm = 178, spikeBpm = 201)
            .contains(" peak=201 "))
    }

    /**
     * The two lines must agree about the day. `effort calib` reads the branch at the call site and
     * `effort score` reads the HRmax that actually reached the scorer, by two different routes — so they
     * can disagree, and a contributor reading one against the other would be reading a fiction. `src`
     * maps onto the score line's coarser word: override and tanaka are both `provided` there.
     */
    @Test
    fun `the calib and score lines agree about the same day`() {
        val cases = listOf(
            Triple(30.0, 195.0, "override") to "provided",
            Triple(30.0, null, "tanaka") to "provided",
            Triple(0.0, null, "default") to "default",
        )
        for ((profileCase, expectedWord) in cases) {
            val (age, hrMaxOverride, expectedSrc) = profileCase
            val emitted = mutableListOf<String>()
            AnalyticsEngine.analyzeDay(
                day = "2026-09-25",
                strainDiag = { emitted.add(it) },
                hr = dayHR(peakBpm = 178),
                profile = UserProfile(age = age),
                maxHROverride = hrMaxOverride,
            )
            val calib = emitted.first { it.startsWith("effort calib ") }
            val score = emitted.first { it.startsWith("effort score ") }
            assertTrue(calib, calib.contains(" src=$expectedSrc "))
            assertTrue(score, score.contains("($expectedWord)"))
            // hrmax=187 on the calib line and hrMax=187.0 on the score line are the same number written
            // to different precisions, so compare the value rather than the text.
            // No exception for the age-less case: the two lines report the same number there too, which
            // is the whole invariant. Carving that case out was what hid the contradiction.
            val calibMax = field(calib, "hrmax=")
            val scoreMax = field(score, "hrMax=").substringBefore("(")
            assertEquals("$calib | $score", calibMax.toDouble(), scoreMax.toDouble(), 1e-9)
        }
    }

    // ---- fixture ----

    /** Value of `key=` up to the next space. */
    private fun field(line: String, key: String): String =
        line.substringAfter(key).substringBefore(" ")

    /**
     * A day whose heart rate is flat at 60 with a ten-minute block at [peakBpm], plus one optional
     * single-sample spike. 1 Hz across an hour, which clears the scorer's density gate.
     */
    private fun dayHR(peakBpm: Int, spikeBpm: Int? = null): List<HrSample> {
        val base = 1_790_294_400L // 2026-09-25T00:00:00Z
        val out = (0 until 3600).map { i ->
            HrSample("t", base + i, if (i in 600 until 1200) peakBpm else 60)
        }.toMutableList()
        if (spikeBpm != null) out.add(HrSample("t", base + 3600, spikeBpm))
        return out
    }

    private fun calibLine(age: Double, maxHROverride: Double?, peakBpm: Int,
                          spikeBpm: Int? = null): String {
        val emitted = mutableListOf<String>()
        AnalyticsEngine.analyzeDay(
            day = "2026-09-25",
            strainDiag = { emitted.add(it) },
            hr = dayHR(peakBpm = peakBpm, spikeBpm = spikeBpm),
            profile = UserProfile(age = age),
            maxHROverride = maxHROverride,
        )
        val calib = emitted.filter { it.startsWith("effort calib ") }
        assertEquals("exactly one calibration line per scored day: $emitted", 1, calib.size)
        return calib.first()
    }
}
