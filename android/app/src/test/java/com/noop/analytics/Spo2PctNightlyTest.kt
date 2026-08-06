package com.noop.analytics

import com.noop.data.Spo2PctRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * v34 / MIGRATION_25_26 — the nightly SpO2 percentage banked on `DailyMetric.spo2Pct` for a 5/MG night.
 *
 * The strap samples SpO2 in RUNS: ~30 one-second samples roughly once per ~1,200 s while asleep. The
 * first samples of each run are the optical front end settling and they read LOW. That makes a naive mean
 * over the night's in-band samples biased downward — and biased *more* on nights made of many short runs,
 * which is the opposite of when you would think to check. These pin the two corrections (per-run ramp
 * trim, then median) and, more usefully, pin the size of the bias they remove.
 *
 * Byte-parity twin of the Swift `Spo2PctNightlyTests`: same fixtures, same expected values.
 */
class Spo2PctNightlyTest {

    private fun session(start: Long, durSec: Long) = DetectedSleep(
        start = start, end = start + durSec, efficiency = 0.9,
        stages = emptyList(), restingHR = 50, avgHRV = 60.0,
    )

    /**
     * A measurement run: [count] consecutive one-second samples starting at [ts], the first [rampCount]
     * of them at the depressed [rampValue].
     */
    private fun run(
        ts: Long,
        count: Int,
        settled: Int,
        rampCount: Int = 0,
        rampValue: Int = 88,
    ): List<Spo2PctRow> = (0 until count).map { Spo2PctRow(ts + it, if (it < rampCount) rampValue else settled) }

    // MARK: - The bias this exists to remove

    /**
     * THE MOTIVATING CASE. One 30-sample run whose first 5 are the acquisition ramp at 88 and whose
     * settled 25 are 97. A naive mean lands at 95.5 — a full 1.5 points below what the strap actually
     * settled on, entirely from a one-sided artifact. The ramp trim removes exactly those 5 samples and
     * the median returns the settled value.
     */
    @Test fun theAcquisitionRampBiasesANaiveMeanAndTheTrimRemovesIt() {
        val samples = run(1_000, count = 30, settled = 97, rampCount = 5)
        val naiveMean = samples.sumOf { it.pct }.toDouble() / samples.size
        assertEquals("the bias is real and this is its size", 95.5, naiveMean, 0.001)

        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), samples)
        assertEquals(97.0, r!!.first, 0.001)
        assertEquals("the five ramp samples are dropped, the settled 25 are kept", 25, r.second)
    }

    // MARK: - Run segmentation

    /**
     * Runs are separated by a gap far larger than the 1 s spacing inside one, so EACH run gets its own
     * ramp trim. Trimming only the night's first five samples would leave every later run's ramp in.
     */
    @Test fun eachRunIsTrimmedSeparately() {
        val samples = run(1_000, count = 20, settled = 97, rampCount = 5) +
            run(3_000, count = 20, settled = 97, rampCount = 5) +
            run(5_000, count = 20, settled = 97, rampCount = 5)
        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 5_000)), samples)
        assertEquals("3 runs x (20 - 5) survivors", 45, r!!.second)
        assertEquals(97.0, r.first, 0.001)
    }

    /**
     * A dropped second or two inside a run must NOT split it — the gap threshold sits in the gulf between
     * 1 s (within a run) and ~1,200 s (between runs), so a small hole is tolerated.
     */
    @Test fun aSmallHoleDoesNotSplitARun() {
        // 10 samples, then a 20 s hole, then 10 more: still ONE run, so ONE ramp trim.
        val samples = run(1_000, count = 10, settled = 97, rampCount = 5) + run(1_030, count = 10, settled = 97)
        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), samples)
        assertEquals("one run: 20 samples less one 5-sample ramp", 15, r!!.second)
    }

    @Test fun theRunGapThresholdIsTheDocumentedOne() {
        assertEquals(60L, AnalyticsEngine.SPO2_RUN_GAP_SECONDS)
        assertEquals(5, AnalyticsEngine.SPO2_RAMP_SAMPLES)
    }

    // MARK: - The half-run cap

    /**
     * The trim never eats more than half a run. A short run must contribute its settled tail rather than
     * vanishing — otherwise the night would be silently reweighted toward whichever runs happened to be
     * long, which is a selection effect nobody would see in the output.
     */
    @Test fun aShortRunKeepsItsTailInsteadOfVanishing() {
        // 4 samples: drop min(5, 2) = 2, keep 2.
        val r = AnalyticsEngine.nightlySpo2Pct(
            listOf(session(900, 600)),
            listOf(Spo2PctRow(1_000, 88), Spo2PctRow(1_001, 90), Spo2PctRow(1_002, 96), Spo2PctRow(1_003, 96)),
        )
        assertEquals(2, r!!.second)
        assertEquals(96.0, r.first, 0.001)
    }

    /** A single-sample run keeps its one sample (drop = min(5, 0) = 0) rather than being erased. */
    @Test fun aSingleSampleRunSurvives() {
        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), listOf(Spo2PctRow(1_000, 95)))
        assertEquals(1, r!!.second)
        assertEquals(95.0, r.first, 0.001)
    }

    // MARK: - The statistic

    /**
     * The median is the statistic, matching what the cloud reader reports for the same rows — a phone that
     * disagreed with the server on identical data would poison every future cross-check.
     */
    @Test fun medianNotMeanOverTheSurvivors() {
        // Survivors after the ramp trim: 90, 97, 97, 97, 97 — median 97, mean 95.6.
        val pcts = listOf(90, 90, 90, 90, 90, 90, 97, 97, 97, 97)
        val samples = pcts.mapIndexed { i, v -> Spo2PctRow(1_000L + i, v) }
        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), samples)
        assertEquals(5, r!!.second)
        assertEquals("a single low survivor must not drag the answer the way a mean would",
            97.0, r.first, 0.001)
    }

    /** An even survivor count averages the two middle values, so the result can land on a half. */
    @Test fun evenSurvivorCountAveragesTheTwoMiddleValues() {
        // A 4-sample run: the half-run cap drops 2, leaving survivors 94 and 97 -> (94 + 97) / 2 = 95.5.
        val samples = listOf(88, 88, 94, 97).mapIndexed { i, v -> Spo2PctRow(1_000L + i, v) }
        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), samples)
        assertNotNull(r)
        assertEquals(2, r!!.second)
        assertEquals(95.5, r.first, 0.001)
    }

    /**
     * The half-run cap governs whenever a run is shorter than twice the ramp, so the survivor count is
     * `count - min(5, count/2)` and not simply `count - 5`. Pinned across the crossover at 10.
     */
    @Test fun survivorCountFollowsTheCappedTrim() {
        for ((count, want) in listOf(1 to 1, 2 to 1, 4 to 2, 6 to 3, 9 to 5, 10 to 5, 11 to 6, 30 to 25)) {
            val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), run(1_000, count, settled = 97))
            assertEquals("a $count-sample run must keep $want", want, r!!.second)
        }
    }

    // MARK: - Session gating and absence

    /** Only in-bed samples count — a daytime reading is not part of the night's saturation. */
    @Test fun samplesOutsideEverySessionAreExcluded() {
        val samples = run(1_000, count = 10, settled = 97) + run(9_000, count = 10, settled = 80)
        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), samples)
        assertEquals("only the in-bed run contributes", 5, r!!.second)
        assertEquals(97.0, r.first, 0.001)
    }

    /**
     * Gap size is the ONLY run signal — a session edge is not a second one. A brief out-of-bed moment
     * mid-run leaves the run intact and singly-trimmed, because the acquisition ramp is a property of the
     * SENSOR restarting and the sensor does not restart because the sleep detector drew a line.
     */
    @Test fun aBriefSessionEdgeDoesNotSplitARun() {
        val samples = run(1_000, count = 20, settled = 97)
        // Sessions carve out [1000..1004] and [1010..1019] — 15 in-bed samples with only a 6 s hole,
        // which is under the threshold, so this stays ONE run and is trimmed ONCE.
        val r = AnalyticsEngine.nightlySpo2Pct(listOf(session(1_000, 4), session(1_010, 9)), samples)
        assertEquals("one run of 15, less one 5-sample ramp", 10, r!!.second)
    }

    /**
     * When the excluded stretch IS longer than the gap threshold, the two halves are genuinely separate
     * runs and each pays its own ramp trim.
     */
    @Test fun aWideSessionGapDoesSplitARun() {
        val samples = run(1_000, count = 10, settled = 97) + run(1_200, count = 10, settled = 97)
        // 200 s apart — comfortably over the 60 s threshold, so two runs: (10-5) + (10-5).
        assertEquals(10, AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), samples)!!.second)
    }

    /** Absence stays absence — nothing here may invent a percentage. */
    @Test fun nullWhenThereIsNothingToAverage() {
        assertNull(AnalyticsEngine.nightlySpo2Pct(emptyList(), listOf(Spo2PctRow(1_000, 97))))
        assertNull(AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), emptyList()))
        // In-band samples exist, but none of them fall in a session.
        assertNull(AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 100)), listOf(Spo2PctRow(9_999, 97))))
    }

    /**
     * Unsorted input must not change the answer — run boundaries are a property of the timestamps, not of
     * the order the store happened to hand them over in.
     */
    @Test fun inputOrderDoesNotMatter() {
        val ordered = run(1_000, count = 20, settled = 97, rampCount = 5)
        val shuffled = ordered.reversed()
        assertEquals(
            AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), ordered)!!.second,
            AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), shuffled)!!.second,
        )
        assertEquals(97.0, AnalyticsEngine.nightlySpo2Pct(listOf(session(900, 600)), shuffled)!!.first, 0.001)
    }
}
