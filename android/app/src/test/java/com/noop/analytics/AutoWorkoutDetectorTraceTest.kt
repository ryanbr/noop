package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Twin of the Swift AutoWorkoutDetectorTraceTests: the Workouts & GPS test mode's pure traces. Proves the
 * auto-detect trace returns the SAME List<DetectedWorkout> detect(...) does (byte-identical) AND names why
 * each window was offered or dropped, plus the WorkoutsTrace line formatters and the WorkoutsReadout parser.
 * No em-dashes. Pure-JVM, no Robolectric / Mockito.
 */
class AutoWorkoutDetectorTraceTest {

    private val dev = "test-device"
    private fun hr(ts: Long, bpm: Int) = HrSample(deviceId = dev, ts = ts, bpm = bpm)
    private fun grav(ts: Long, x: Double) = GravitySample(deviceId = dev, ts = ts, x = x, y = 0.0, z = 1.0)
    private fun block(start: Long, durS: Int, bpm: Int): List<HrSample> =
        (0 until durS).map { hr(start + it, bpm) }

    @Test fun traceResultsAreByteIdenticalToDetect() {
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start - 600, 600, 65) + block(start, durS, 120) + block(start + durS, 600, 65)
        val plain = AutoWorkoutDetector.detect(hr, restingHR = 60)
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60)
        assertEquals(plain, traced)
        assertEquals(1, traced.size)
        assertTrue(lines.any { it.startsWith("autoDetect path=autoDetect hrSamples=") })
        assertTrue(lines.any { it.contains("autoDetect thresholds elevatedMargin=30bpm") })
        assertTrue(lines.any { it.contains("verdict=offered") })
        assertTrue(lines.any { it.contains("autoDetect result windows=1") })
        assertFalse(lines.any { it.contains("\u2014") })
    }

    @Test fun traceNamesNoSustainedSpan() {
        val hr = block(1_000_000L, 1_800, 65) // all rest, never above the floor
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60)
        assertTrue(traced.isEmpty())
        assertTrue(lines.any { it.contains("why=noSustainedSpan") })
        assertTrue(lines.any { it.contains("result windows=0") })
    }

    @Test fun traceNamesSavedOverlapDrop() {
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start, durS, 120)
        val saved = listOf((start - 60) to (start + durS + 60))
        val plain = AutoWorkoutDetector.detect(hr, restingHR = 60, savedWorkouts = saved)
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60, savedWorkouts = saved)
        assertEquals(plain, traced)
        assertTrue(traced.isEmpty())
        assertTrue(lines.any { it.contains("verdict=dropped why=overlapsSavedWorkout") })
    }

    @Test fun traceNamesMotionNotConfirmed() {
        val start = 1_000_000L
        val durS = 20 * 60
        val hr = block(start, durS, 120)
        // A flat (no-motion) gravity series → motion-confirm gate drops the window.
        val gravity = (0 until durS).map { grav(start + it, 0.0) }
        val plain = AutoWorkoutDetector.detect(hr, restingHR = 60, gravity = gravity)
        val (traced, lines) = AutoWorkoutDetectorTrace.detectTrace(hr, restingHR = 60, gravity = gravity)
        assertEquals(plain, traced)
        assertTrue(traced.isEmpty())
        assertTrue(lines.any { it.contains("verdict=dropped why=motionNotConfirmed") })
    }

    @Test fun shadowPoliciesDoNotChangePublishedResult() {
        val start = 2_000_000L
        val elevenMinutes = block(start, 11 * 60 + 1, 120)

        val (published, _) = AutoWorkoutDetectorTrace.detectTrace(elevenMinutes, restingHR = 60)
        val tenMinuteShadow = AutoWorkoutDetector.detect(
            elevenMinutes, restingHR = 60, minimumSustainedMinutes = 10.0,
        )
        val fifteenMinuteShadow = AutoWorkoutDetector.detect(
            elevenMinutes, restingHR = 60, minimumSustainedMinutes = 15.0,
        )

        assertTrue("published 12-minute policy must remain unchanged", published.isEmpty())
        assertEquals(1, tenMinuteShadow.size)
        assertTrue(fifteenMinuteShadow.isEmpty())
    }

    @Test fun shadowComparisonReportsMatchesMissesAndUnmatchedCandidates() {
        val candidates = listOf(
            AutoWorkoutDetector.DetectedWorkout(100, 200, 120, 140, 1),
            AutoWorkoutDetector.DetectedWorkout(500, 600, 125, 145, 1),
        )
        val saved = listOf(50L to 150L, 300L to 400L)

        assertEquals(
            "workout shadow policy=10min candidates=2 matched=1 missed=1 unobservable=0 unmatched=1 " +
                "medianOnsetErrorS=50 medianEndErrorS=50",
            AutoWorkoutDetectorTrace.shadowComparisonLine(10.0, candidates, saved),
        )
    }

    @Test fun shadowComparisonUsesDeterministicOneToOneMatching() {
        val candidates = listOf(
            AutoWorkoutDetector.DetectedWorkout(100, 200, 120, 140, 1),
            AutoWorkoutDetector.DetectedWorkout(150, 250, 125, 145, 1),
        )
        val saved = listOf(90L to 210L)

        assertEquals(
            "workout shadow policy=15min candidates=2 matched=1 missed=0 unobservable=0 unmatched=1 " +
                "medianOnsetErrorS=10 medianEndErrorS=10",
            AutoWorkoutDetectorTrace.shadowComparisonLine(15.0, candidates, saved),
        )
        assertTrue(
            AutoWorkoutDetectorTrace.shadowComparisonLine(15.0, emptyList(), saved)
                .endsWith("medianOnsetErrorS=n/a medianEndErrorS=n/a"),
        )
    }

    @Test fun shadowComparisonIsInvariantToInputOrdering() {
        val candidates = listOf(
            AutoWorkoutDetector.DetectedWorkout(50, 150, 120, 140, 1),
            AutoWorkoutDetector.DetectedWorkout(100, 150, 125, 145, 1),
            AutoWorkoutDetector.DetectedWorkout(1_000, 1_100, 130, 150, 1),
        )
        val saved = listOf(
            100L to 200L,
            950L to 1_050L,
            1_000L to 1_050L,
        )
        val canonical = AutoWorkoutDetectorTrace.shadowComparisonLine(10.0, candidates, saved)

        // Equal-overlap optima use the canonical Hungarian tie-break: onset errors [0, 50],
        // end errors [50, 50]. Reversing either source list must retain that same assignment.
        assertEquals(
            "workout shadow policy=10min candidates=3 matched=2 missed=1 unobservable=0 unmatched=1 " +
                "medianOnsetErrorS=25 medianEndErrorS=50",
            canonical,
        )
        assertEquals(
            "source ordering must not change shadow-policy evidence",
            canonical,
            AutoWorkoutDetectorTrace.shadowComparisonLine(10.0, candidates.reversed(), saved.reversed()),
        )
    }

    @Test fun shadowComparisonMaximizesMatchCountBeforeOverlapPreference() {
        val candidates = listOf(
            AutoWorkoutDetector.DetectedWorkout(0, 600, 120, 140, 10),
            AutoWorkoutDetector.DetectedWorkout(900, 1_500, 125, 145, 10),
        )
        val saved = listOf(0L to 1_000L, 0L to 500L)

        assertEquals(
            "workout shadow policy=10min candidates=2 matched=2 missed=0 unobservable=0 unmatched=0 " +
                "medianOnsetErrorS=450 medianEndErrorS=300",
            AutoWorkoutDetectorTrace.shadowComparisonLine(10.0, candidates, saved),
        )
    }

    @Test fun shadowComparisonRequiresPositiveOverlap() {
        val candidates = listOf(
            AutoWorkoutDetector.DetectedWorkout(100, 200, 120, 140, 1),
        )
        val saved = listOf(200L to 300L)

        assertEquals(
            "workout shadow policy=10min candidates=1 matched=0 missed=1 unobservable=0 unmatched=1 " +
                "medianOnsetErrorS=n/a medianEndErrorS=n/a",
            AutoWorkoutDetectorTrace.shadowComparisonLine(10.0, candidates, saved),
        )
    }

    @Test fun shadowComparisonMaximizesTotalOverlapAfterCardinality() {
        val candidates = listOf(
            AutoWorkoutDetector.DetectedWorkout(0, 100, 120, 140, 1),
            AutoWorkoutDetector.DetectedWorkout(50, 110, 125, 145, 1),
        )
        val saved = listOf(0L to 100L, 90L to 120L)

        // The diagonal assignment overlaps for 100 + 20 seconds. The other maximum-cardinality
        // assignment overlaps for only 10 + 50 seconds and must not skew the boundary medians.
        assertEquals(
            "workout shadow policy=10min candidates=2 matched=2 missed=0 unobservable=0 unmatched=0 " +
                "medianOnsetErrorS=20 medianEndErrorS=5",
            AutoWorkoutDetectorTrace.shadowComparisonLine(10.0, candidates, saved),
        )
    }

    @Test fun shadowComparisonSeparatesLabelsWithoutRecordedHr() {
        val candidates = listOf(
            AutoWorkoutDetector.DetectedWorkout(0, 720, 120, 140, 12),
        )
        val saved = listOf(60L to 660L, 5_000L to 5_600L)
        val hr = block(0, 12 * 60 + 1, 120)

        assertEquals(
            "workout shadow policy=12min candidates=1 matched=1 missed=0 unobservable=1 unmatched=0 " +
                "medianOnsetErrorS=60 medianEndErrorS=60",
            AutoWorkoutDetectorTrace.shadowComparisonLine(
                12.0,
                candidates,
                saved,
                hrForObservability = hr,
            ),
        )
    }

    @Test fun shadowComparisonDoesNotTreatTwoAdjacentSamplesAsCoverage() {
        val sparseHr = listOf(hr(5_000, 60), hr(5_001, 60))

        assertEquals(
            "workout shadow policy=10min candidates=0 matched=0 missed=0 unobservable=1 unmatched=0 " +
                "medianOnsetErrorS=n/a medianEndErrorS=n/a",
            AutoWorkoutDetectorTrace.shadowComparisonLine(
                10.0,
                emptyList(),
                listOf(5_000L to 5_600L),
                hrForObservability = sparseHr,
            ),
        )
    }

    @Test fun shadowObservabilityUsesEachPoliciesQualificationWindow() {
        val tenMinutesHr = block(0, 10 * 60 + 1, 60)
        val label = listOf(0L to 15L * 60L)

        assertEquals(
            "workout shadow policy=10min candidates=0 matched=0 missed=1 unobservable=0 unmatched=0 " +
                "medianOnsetErrorS=n/a medianEndErrorS=n/a",
            AutoWorkoutDetectorTrace.shadowComparisonLine(
                10.0, emptyList(), label, hrForObservability = tenMinutesHr,
            ),
        )
        assertEquals(
            "workout shadow policy=15min candidates=0 matched=0 missed=0 unobservable=1 unmatched=0 " +
                "medianOnsetErrorS=n/a medianEndErrorS=n/a",
            AutoWorkoutDetectorTrace.shadowComparisonLine(
                15.0, emptyList(), label, hrForObservability = tenMinutesHr,
            ),
        )
    }

    @Test fun workoutsTraceLineShapes() {
        assertEquals(
            "session event=start sport=running hrSamples=0",
            WorkoutsTrace.sessionLine(event = "start", sportKey = "running", hrSamples = 0),
        )
        assertEquals(
            "session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
            WorkoutsTrace.sessionLine(
                event = "end", sportKey = "running", hrSamples = 1200, durationSec = 1260, gpsPoints = 240,
            ),
        )
        assertEquals(
            "gps rawFixes=250 accepted=240 distanceM=5013 (filter: accuracy+speed gate)",
            WorkoutsTrace.gpsLine(rawFixes = 250, acceptedPoints = 240, distanceM = 5012.6),
        )
        assertEquals(
            "dedup sport=running kept=strap(richness=5) dropped=apple(richness=1) (same activity, richer kept)",
            WorkoutsTrace.dedupLine(
                sportKey = "running", keptSource = "strap", droppedSource = "apple",
                keptRichness = 5, droppedRichness = 1,
            ),
        )
        // #2187: the engine detected-bout decision line , analytics-only (no overlap) and dropped (overlaps a real).
        assertEquals(
            "detectedBout verdict=analyticsOnly durMin=42 avgBpm=148",
            WorkoutsTrace.detectedBoutLine(verdict = "analyticsOnly", durMin = 42, avgBpm = 148),
        )
        assertEquals(
            "detectedBout verdict=droppedOverlap durMin=42 avgBpm=148 overlapSource=manual",
            WorkoutsTrace.detectedBoutLine(
                verdict = "droppedOverlap", durMin = 42, avgBpm = 148, overlapSource = "manual",
            ),
        )
    }

    @Test fun workoutsReadoutParsesLastSession() {
        val tail = listOf(
            "[workouts] session event=start sport=running hrSamples=0",
            "[workouts] session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
        )
        assertEquals(
            "event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
            WorkoutsReadout.lastSessionSummary(tail),
        )
        assertNull(WorkoutsReadout.lastSessionSummary(emptyList()))
    }
}
