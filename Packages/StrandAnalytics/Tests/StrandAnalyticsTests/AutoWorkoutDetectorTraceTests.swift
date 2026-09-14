import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The Workouts & GPS test mode's pure traces. Proves the auto-detect trace returns the SAME
/// [DetectedWorkout] detect(...) does (byte-identical) AND names why each window was offered or dropped,
/// plus the WorkoutsTrace line formatters and the WorkoutsReadout parser. Twin of the Android
/// AutoWorkoutDetectorTraceTest. No em-dashes.
final class AutoWorkoutDetectorTraceTests: XCTestCase {

    /// A flat 1 Hz HR block [start, start+durS) at `bpm`.
    private func block(_ start: Int, _ durS: Int, _ bpm: Int) -> [(ts: Int, bpm: Int)] {
        (0..<durS).map { (ts: start + $0, bpm: bpm) }
    }

    private func elapsedSpan(_ start: Int, _ elapsedS: Int, _ bpm: Int) -> [(ts: Int, bpm: Int)] {
        (0...elapsedS).map { (ts: start + $0, bpm: bpm) }
    }

    func testTraceResultsAreByteIdenticalToDetect() {
        let start = 1_000_000
        let durS = 20 * 60
        let hr = block(start - 600, 600, 65) + block(start, durS, 120) + block(start + durS, 600, 65)
        let plain = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60)
        XCTAssertEqual(traced, plain)
        XCTAssertEqual(traced.count, 1)
        // Inputs + thresholds lines present.
        XCTAssertTrue(lines.contains { $0.hasPrefix("autoDetect path=autoDetect hrSamples=") })
        XCTAssertTrue(lines.contains { $0.contains("autoDetect thresholds elevatedMargin=30bpm") })
        XCTAssertTrue(lines.contains { $0.contains("verdict=offered") })
        XCTAssertTrue(lines.contains { $0.contains("autoDetect result windows=1") })
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testTraceNamesNoSustainedSpan() {
        // All rest, never above the floor → no span; the trace must say why.
        let hr = block(1_000_000, 1_800, 65)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60)
        XCTAssertTrue(traced.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("why=noSustainedSpan") })
        XCTAssertTrue(lines.contains { $0.contains("result windows=0") })
    }

    func testTraceNamesSavedOverlapDrop() {
        // A real 20-min window, but a saved span covers it → detect returns [], trace says why.
        let start = 1_000_000
        let durS = 20 * 60
        let hr = block(start, durS, 120)
        let saved = [SavedWorkoutSpan(startSec: start - 60, endSec: start + durS + 60)]
        let plain = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60, savedSpans: saved)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60, savedSpans: saved)
        XCTAssertEqual(traced, plain)
        XCTAssertTrue(traced.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("verdict=dropped why=overlapsSavedWorkout") })
    }

    func testTraceNamesMotionNotConfirmed() {
        // A real HR window but a flat (no-motion) series → motion-confirm gate drops it.
        let start = 1_000_000
        let durS = 20 * 60
        let hr = block(start, durS, 120)
        let motion = (0..<durS).map { AutoWorkoutDetector.MotionPoint(ts: start + $0, intensity: 0.0) }
        let plain = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60, motion: motion)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(hr: hr, restingBpm: 60, motion: motion)
        XCTAssertEqual(traced, plain)
        XCTAssertTrue(traced.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("verdict=dropped why=motionNotConfirmed") })
    }

    func testTraceUsesExplicitShadowPolicyWithoutChangingDefault() {
        let start = 2_000_000
        let hr = elapsedSpan(start, 10 * 60, 120)

        XCTAssertTrue(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60).isEmpty)
        let (traced, lines) = AutoWorkoutDetector.detectTrace(
            hr: hr, restingBpm: 60, minimumSustainedMinutes: 10.0, path: "shadow")

        XCTAssertEqual(traced.count, 1)
        XCTAssertTrue(lines.contains { $0.contains("path=shadow") })
        XCTAssertTrue(lines.contains { $0.contains("minSustainedMin=10.0") })
    }

    func testShadowComparisonLinesAreExactAndDoNotSuppressLabels() {
        let start = 3_000_000
        let hr = elapsedSpan(start, 12 * 60, 120)
        let labels = [SavedWorkoutSpan(startSec: start + 60, endSec: start + 11 * 60)]

        let lines = AutoWorkoutDetector.shadowComparisonLines(
            hr: hr, restingBpm: 60, savedSpans: labels)

        XCTAssertEqual(lines, [
            "workout shadow policy=10min candidates=1 matched=1 missed=0 unobservable=0 unmatched=0 "
                + "medianOnsetErrorS=60 medianEndErrorS=60",
            "workout shadow policy=12min candidates=1 matched=1 missed=0 unobservable=0 unmatched=0 "
                + "medianOnsetErrorS=60 medianEndErrorS=60",
            "workout shadow policy=15min candidates=0 matched=0 missed=1 unobservable=0 unmatched=0 "
                + "medianOnsetErrorS=n/a medianEndErrorS=n/a",
        ])
        XCTAssertEqual(labels, [SavedWorkoutSpan(startSec: start + 60, endSec: start + 11 * 60)])
    }

    func testShadowComparisonCountsMatchedMissedAndUnmatchedIndependently() {
        let candidates = [
            DetectedWorkout(startSec: 100, endSec: 200, avgBpm: 120, peakBpm: 140, durationMin: 1),
            DetectedWorkout(startSec: 500, endSec: 600, avgBpm: 125, peakBpm: 145, durationMin: 1),
        ]
        let labels = [
            SavedWorkoutSpan(startSec: 200, endSec: 300), // endpoint-only contact is not a real overlap
            SavedWorkoutSpan(startSec: 800, endSec: 900),
        ]

        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 10.0, candidates: candidates, savedSpans: labels),
            "workout shadow policy=10min candidates=2 matched=0 missed=2 unobservable=0 unmatched=2 "
                + "medianOnsetErrorS=n/a medianEndErrorS=n/a")
    }

    func testShadowComparisonPairsHighestOverlapOneToOneAndMediansErrors() {
        let candidates = [
            DetectedWorkout(startSec: 90, endSec: 210, avgBpm: 120, peakBpm: 140, durationMin: 2),
            DetectedWorkout(startSec: 480, endSec: 640, avgBpm: 125, peakBpm: 145, durationMin: 2),
            DetectedWorkout(startSec: 550, endSec: 615, avgBpm: 125, peakBpm: 145, durationMin: 1),
        ]
        let labels = [
            SavedWorkoutSpan(startSec: 100, endSec: 200),
            SavedWorkoutSpan(startSec: 500, endSec: 600),
        ]

        // Candidate 1 has the larger overlap with label 1 and wins it; candidate 2 remains unmatched.
        // Pair errors are [10, 20] at onset and [10, 40] at end, giving medians 15 and 25.
        let expected = "workout shadow policy=15min candidates=3 matched=2 missed=0 unobservable=0 unmatched=1 "
            + "medianOnsetErrorS=15 medianEndErrorS=25"
        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 15.0, candidates: candidates, savedSpans: labels),
            expected)
        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 15.0, candidates: Array(candidates.reversed()),
                savedSpans: Array(labels.reversed())),
            expected,
            "shadow matching must not depend on database/union ordering")
    }

    func testShadowComparisonTieBreakIsInvariantToInputOrdering() {
        let candidates = [
            DetectedWorkout(startSec: 50, endSec: 150, avgBpm: 120, peakBpm: 140, durationMin: 1),
            DetectedWorkout(startSec: 100, endSec: 150, avgBpm: 125, peakBpm: 145, durationMin: 1),
            DetectedWorkout(startSec: 1_000, endSec: 1_100, avgBpm: 130, peakBpm: 150, durationMin: 1),
        ]
        let labels = [
            SavedWorkoutSpan(startSec: 100, endSec: 200),
            SavedWorkoutSpan(startSec: 950, endSec: 1_050),
            SavedWorkoutSpan(startSec: 1_000, endSec: 1_050),
        ]
        // Equal-overlap optima use the canonical Hungarian tie-break: onset errors [0, 50],
        // end errors [50, 50]. Reversing either source list must retain that same assignment.
        let expected = "workout shadow policy=10min candidates=3 matched=2 missed=1 unobservable=0 unmatched=1 "
            + "medianOnsetErrorS=25 medianEndErrorS=50"

        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 10.0, candidates: candidates, savedSpans: labels),
            expected)
        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 10.0, candidates: Array(candidates.reversed()),
                savedSpans: Array(labels.reversed())),
            expected)
    }

    func testShadowComparisonMaximizesMatchCountBeforeOverlapPreference() {
        let candidates = [
            DetectedWorkout(startSec: 0, endSec: 600, avgBpm: 120, peakBpm: 140, durationMin: 10),
            DetectedWorkout(startSec: 900, endSec: 1_500, avgBpm: 125, peakBpm: 145, durationMin: 10),
        ]
        let labels = [
            SavedWorkoutSpan(startSec: 0, endSec: 1_000),
            SavedWorkoutSpan(startSec: 0, endSec: 500),
        ]

        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 10.0, candidates: candidates, savedSpans: labels),
            "workout shadow policy=10min candidates=2 matched=2 missed=0 unobservable=0 unmatched=0 "
                + "medianOnsetErrorS=450 medianEndErrorS=300")
    }

    func testShadowComparisonMaximizesTotalOverlapAfterCardinality() {
        let candidates = [
            DetectedWorkout(startSec: 0, endSec: 100, avgBpm: 120, peakBpm: 140, durationMin: 1),
            DetectedWorkout(startSec: 50, endSec: 110, avgBpm: 125, peakBpm: 145, durationMin: 1),
        ]
        let labels = [
            SavedWorkoutSpan(startSec: 0, endSec: 100),
            SavedWorkoutSpan(startSec: 90, endSec: 120),
        ]

        // The diagonal assignment overlaps for 100 + 20 seconds. The other maximum-cardinality
        // assignment overlaps for only 10 + 50 seconds and must not skew the boundary medians.
        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 10.0, candidates: candidates, savedSpans: labels),
            "workout shadow policy=10min candidates=2 matched=2 missed=0 unobservable=0 unmatched=0 "
                + "medianOnsetErrorS=20 medianEndErrorS=5")
    }

    func testShadowComparisonSeparatesLabelsWithoutRecordedHR() {
        let start = 4_000_000
        let hr = elapsedSpan(start, 12 * 60, 120)
        let labels = [
            SavedWorkoutSpan(startSec: start + 60, endSec: start + 11 * 60),
            SavedWorkoutSpan(startSec: start + 5_000, endSec: start + 5_600),
        ]

        let lines = AutoWorkoutDetector.shadowComparisonLines(
            hr: hr, restingBpm: 60, savedSpans: labels, policies: [12.0, 15.0])

        XCTAssertEqual(lines, [
            "workout shadow policy=12min candidates=1 matched=1 missed=0 unobservable=1 unmatched=0 "
                + "medianOnsetErrorS=60 medianEndErrorS=60",
            "workout shadow policy=15min candidates=0 matched=0 missed=1 unobservable=1 unmatched=0 "
                + "medianOnsetErrorS=n/a medianEndErrorS=n/a",
        ])
    }

    func testShadowComparisonDoesNotTreatTwoAdjacentSamplesAsCoverage() {
        let sparseHR = [(ts: 5_000, bpm: 60), (ts: 5_001, bpm: 60)]
        let label = SavedWorkoutSpan(startSec: 5_000, endSec: 5_600)

        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 10.0,
                candidates: [],
                savedSpans: [label],
                hrForObservability: sparseHR),
            "workout shadow policy=10min candidates=0 matched=0 missed=0 unobservable=1 unmatched=0 "
                + "medianOnsetErrorS=n/a medianEndErrorS=n/a")
    }

    func testShadowObservabilityUsesEachPoliciesQualificationWindow() {
        let hr = elapsedSpan(0, 10 * 60, 60)
        let label = SavedWorkoutSpan(startSec: 0, endSec: 15 * 60)

        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 10.0, candidates: [], savedSpans: [label], hrForObservability: hr),
            "workout shadow policy=10min candidates=0 matched=0 missed=1 unobservable=0 unmatched=0 "
                + "medianOnsetErrorS=n/a medianEndErrorS=n/a")
        XCTAssertEqual(
            AutoWorkoutDetector.shadowComparisonLine(
                policyMinutes: 15.0, candidates: [], savedSpans: [label], hrForObservability: hr),
            "workout shadow policy=15min candidates=0 matched=0 missed=0 unobservable=1 unmatched=0 "
                + "medianOnsetErrorS=n/a medianEndErrorS=n/a")
    }

    func testWorkoutsTraceLineShapes() {
        XCTAssertEqual(
            WorkoutsTrace.sessionLine(event: "start", sportKey: "running", hrSamples: 0),
            "session event=start sport=running hrSamples=0")
        XCTAssertEqual(
            WorkoutsTrace.sessionLine(event: "end", sportKey: "running", hrSamples: 1200,
                                      durationSec: 1260, gpsPoints: 240),
            "session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240")
        XCTAssertEqual(
            WorkoutsTrace.gpsLine(rawFixes: 250, acceptedPoints: 240, distanceM: 5012.6),
            "gps rawFixes=250 accepted=240 distanceM=5013 (filter: accuracy+speed gate)")
        XCTAssertEqual(
            WorkoutsTrace.dedupLine(sportKey: "running", keptSource: "strap", droppedSource: "apple",
                                    keptRichness: 5, droppedRichness: 1),
            "dedup sport=running kept=strap(richness=5) dropped=apple(richness=1) (same activity, richer kept)")
        // #1735/#2187: analytics bouts never create generic workout rows. They either remain analytics-only
        // or enrich/drop against a real manual/imported workout.
        XCTAssertEqual(
            WorkoutsTrace.detectedBoutLine(verdict: "analyticsOnly", durMin: 42, avgBpm: 148),
            "detectedBout verdict=analyticsOnly durMin=42 avgBpm=148")
        XCTAssertEqual(
            WorkoutsTrace.detectedBoutLine(verdict: "droppedOverlap", durMin: 42, avgBpm: 148,
                                                 overlapSource: "manual"),
            "detectedBout verdict=droppedOverlap durMin=42 avgBpm=148 overlapSource=manual")
        XCTAssertEqual(
            WorkoutsTrace.detectedBoutLine(verdict: "droppedOverlapBackfilled", durMin: 42, avgBpm: 148,
                                            overlapSource: "apple"),
            "detectedBout verdict=droppedOverlapBackfilled durMin=42 avgBpm=148 overlapSource=apple")
    }

    func testWorkoutsReadoutParsesLastSession() {
        let tail = [
            "[workouts] session event=start sport=running hrSamples=0",
            "[workouts] session event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240",
        ]
        XCTAssertEqual(WorkoutsReadout.lastSessionSummary(taggedTail: tail),
                       "event=end sport=running hrSamples=1200 durationSec=1260 gpsPoints=240")
        XCTAssertNil(WorkoutsReadout.lastSessionSummary(taggedTail: []))
    }
}
