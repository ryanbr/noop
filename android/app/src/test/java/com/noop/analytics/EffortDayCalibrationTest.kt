package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
            "effort calib day=2026-09-25 hrmax=195 src=override tanaka=187 peak=178 rhr=52 sustained=171 span=4",
            StrainScorer.dayCalibrationLine(
                day = "2026-09-25", hrmax = 195.0, hrmaxSource = "override",
                tanaka = 187.0, observedPeak = 178.0, restingHR = 52.0,
            ) + StrainScorer.sustainedPeakField(171.0) + StrainScorer.sustainedPeakSpanField(4L),
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
            "effort calib day=2026-09-25 hrmax=nil src=default tanaka=nil peak=nil rhr=60 sustained=nil span=nil",
            StrainScorer.dayCalibrationLine(
                day = "2026-09-25", hrmax = null, hrmaxSource = "default",
                tanaka = null, observedPeak = null, restingHR = 60.0,
            ) + StrainScorer.sustainedPeakField(null) + StrainScorer.sustainedPeakSpanField(null),
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
            "effort calib day=2026-09-25 hrmax=195 src=override tanaka=187 peak=178 rhr=60 sustained=178 span=4",
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
            "effort calib day=2026-09-25 hrmax=187 src=tanaka tanaka=187 peak=178 rhr=60 sustained=178 span=4",
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
            "effort calib day=2026-09-25 hrmax=190 src=default tanaka=nil peak=178 rhr=60 sustained=178 span=4",
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
     * The same day through the engine: the one-sample spike reaches `peak` and stays out of `sustained`,
     * which still reports the ten-minute block. That gap is what the field exists to show.
     */
    @Test
    fun `a single high minute stays out of sustained`() {
        val line = calibLine(age = 30.0, maxHROverride = null, peakBpm = 178, spikeBpm = 201)
        assertTrue(line, line.contains(" peak=201 ") && line.endsWith(" sustained=178 span=4"))
    }

    // ---- sustained peak ----

    private fun run(bpms: List<Int>, stepS: Long = 1, start: Long = 1_790_294_400L): List<HrSample> =
        bpms.mapIndexed { i, b -> HrSample("t", start + i * stepS, b) }

    /** One sample, or four, at a high value is not held; five is. */
    @Test
    fun `sustained peak needs five consecutive samples`() {
        val base = List(8) { 90 }
        assertEquals(90.0, StrainScorer.sustainedPeak(run(base + listOf(200) + base)))
        assertEquals(90.0, StrainScorer.sustainedPeak(run(base + List(4) { 200 } + base)))
        assertEquals(200.0, StrainScorer.sustainedPeak(run(base + List(5) { 200 } + base)))
    }

    /** The minimum over the run, not the mean: a spike inside ordinary samples does not lift it. */
    @Test
    fun `sustained peak is the minimum of the run`() {
        assertEquals(150.0, StrainScorer.sustainedPeak(run(listOf(150, 150, 210, 150, 150))))
    }

    /** The five samples must fit in 60 s: a span of exactly 60 counts, 61 does not. */
    @Test
    fun `sustained peak window boundary`() {
        assertEquals(170.0, StrainScorer.sustainedPeak(run(List(5) { 170 }, stepS = 15)))
        val wide = run(List(4) { 170 }, stepS = 15) + HrSample("t", 1_790_294_400L + 61, 170)
        assertNull(StrainScorer.sustainedPeak(wide))
    }

    /**
     * A sparse day, such as a ring's five-minute cadence, and a day with fewer than five samples, read as
     * null: not measured, rather than a fallback to the raw peak.
     */
    @Test
    fun `sustained peak is null when not dense enough`() {
        assertNull(StrainScorer.sustainedPeak(run(listOf(120, 130, 140, 150, 160, 170), stepS = 300)))
        assertNull(StrainScorer.sustainedPeak(run(List(4) { 180 })))
        assertNull(StrainScorer.sustainedPeak(emptyList()))
    }

    /** Input order does not matter. */
    @Test
    fun `sustained peak ignores input order`() {
        val hr = run(listOf(100, 160, 161, 162, 163, 164, 100, 90))
        assertEquals(StrainScorer.sustainedPeak(hr), StrainScorer.sustainedPeak(hr.reversed()))
    }

    /**
     * Parity oracle. 48 generated days (a 64-bit LCG, the same one the Swift test runs), with duplicate
     * seconds, reversed input and gaps from dense to sparse. The expected literal is the stdout of the Swift
     * implementation compiled on its own; `EffortDayCalibrationTests` pins the same one.
     */
    @Test
    fun `sustained peak parity oracle`() {
        var state = 2438L
        fun next(m: Int): Int {
            state = state * 6364136223846793005L + 1442695040888963407L
            return ((state ushr 33) % m).toInt()
        }
        val out = mutableListOf<String>()
        for (c in 0 until 48) {
            val n = next(40)
            val maxGap = intArrayOf(2, 8, 20, 40)[c % 4]
            var ts = 1_790_294_400L
            val hr = mutableListOf<HrSample>()
            repeat(n) {
                ts += next(maxGap)
                hr.add(HrSample("t", ts, 60 + next(140)))
            }
            if (c % 3 == 0) hr.reverse()
            out.add(StrainScorer.sustainedPeak(hr)?.toInt()?.toString() ?: "nil")
        }
        assertEquals(
            "77,97,148,97,nil,90,113,69,87,147,109,nil,nil,115,102,112,89,88,130,87,114,128,75,nil,119,103,144,nil,123,124,82,119,136,62,161,nil,nil,79,nil,90,102,163,130,133,79,146,87,nil",
            out.joinToString(","),
        )
    }

    /**
     * The span is the run that set the value, not the widest qualifying run of the day: a dense run at a
     * high value wins over a sparse one at a lower value, and the span reported is the dense one's.
     */
    @Test
    fun `sustained peak span belongs to the winning run`() {
        val hr = run(List(5) { 180 }) + run(List(5) { 150 }, stepS = 15, start = 1_790_298_000L)
        assertEquals(180.0, StrainScorer.sustainedPeak(hr))
        assertEquals(4L, StrainScorer.sustainedPeakSpan(hr))
    }

    /**
     * Two runs reaching the same value report the longer span, the stronger evidence of a hold. The 60 s
     * boundary is inclusive here too.
     */
    @Test
    fun `sustained peak span takes the longest tie`() {
        val hr = run(List(5) { 170 }) + run(List(5) { 170 }, stepS = 15, start = 1_790_298_000L)
        assertEquals(60L, StrainScorer.sustainedPeakSpan(hr))
        assertEquals(60L, StrainScorer.sustainedPeakSpan(hr.reversed()))
    }

    /** Null exactly when `sustainedPeak` is null: a span without a value would describe no run. */
    @Test
    fun `sustained peak span is null when the value is`() {
        assertNull(StrainScorer.sustainedPeakSpan(run(listOf(120, 130, 140, 150, 160, 170), stepS = 300)))
        assertNull(StrainScorer.sustainedPeakSpan(run(List(4) { 180 })))
        assertNull(StrainScorer.sustainedPeakSpan(emptyList()))
    }

    /**
     * Parity oracle for the span, over the same 48 generated days as the value's oracle above. The
     * expected literal is the stdout of the Swift implementation compiled on its own;
     * `EffortDayCalibrationTests` pins the same one. Its nulls sit exactly where the value's do.
     */
    @Test
    fun `sustained peak span parity oracle`() {
        var state = 2438L
        fun next(m: Int): Int {
            state = state * 6364136223846793005L + 1442695040888963407L
            return ((state ushr 33) % m).toInt()
        }
        val out = mutableListOf<String>()
        for (c in 0 until 48) {
            val n = next(40)
            val maxGap = intArrayOf(2, 8, 20, 40)[c % 4]
            var ts = 1_790_294_400L
            val hr = mutableListOf<HrSample>()
            repeat(n) {
                ts += next(maxGap)
                hr.add(HrSample("t", ts, 60 + next(140)))
            }
            if (c % 3 == 0) hr.reverse()
            out.add(StrainScorer.sustainedPeakSpan(hr)?.toString() ?: "nil")
        }
        assertEquals(
            "2,19,33,49,nil,8,41,46,4,14,33,nil,nil,11,36,56,2,20,35,52,1,9,59,nil,3,11,44,nil,3,9,48,45,0,16,36,nil,nil,16,nil,60,1,7,23,57,0,19,52,nil",
            out.joinToString(","),
        )
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
