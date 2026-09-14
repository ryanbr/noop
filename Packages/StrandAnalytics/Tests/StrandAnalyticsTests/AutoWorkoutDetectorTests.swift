import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Parity tests for the MVP `AutoWorkoutDetector` — mirrors
/// android/.../AutoWorkoutDetectorTest.kt case-for-case so the two platforms stay byte-parity on
/// the detection logic.
///
/// Cases: elevated span detected; brief dip tolerated; short/low spans rejected; near windows
/// merged; window overlapping a saved workout excluded.
final class AutoWorkoutDetectorTests: XCTestCase {

    /// A flat 1 Hz HR block [start, start+durS) at `bpm`.
    private func block(_ start: Int, _ durS: Int, _ bpm: Int) -> [(ts: Int, bpm: Int)] {
        (0..<durS).map { (ts: start + $0, bpm: bpm) }
    }

    /// A flat HR span with an exact wall-clock elapsed duration, including both endpoints.
    private func elapsedSpan(_ start: Int, _ elapsedS: Int, _ bpm: Int) -> [(ts: Int, bpm: Int)] {
        (0...elapsedS).map { (ts: start + $0, bpm: bpm) }
    }

    private func grav(_ ts: Int, _ x: Double) -> GravitySample {
        GravitySample(ts: ts, x: x, y: 0, z: 1)
    }

    // resting 60 → floor = 90. Workout bpm 120 is elevated; rest bpm 65 is not.

    func testElevatedSpanIsDetected() {
        // 20 min sustained at 120 bpm, embedded in rest. One workout, ~20 min, avg/peak 120.
        let start = 1_000_000
        let durS = 20 * 60
        let hr = block(start - 600, 600, 65) + block(start, durS, 120) + block(start + durS, 600, 65)
        let out = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60)
        XCTAssertEqual(out.count, 1)
        let w = out[0]
        XCTAssertEqual(w.avgBpm, 120)
        XCTAssertEqual(w.peakBpm, 120)
        XCTAssertGreaterThanOrEqual(w.durationMin, 19)
        XCTAssertEqual(w.startSec, start)
    }

    func testBriefDipIsTolerated() {
        // 10 min at 120, a 60 s dip to 70 (below floor, but <= 90 s), then 10 min at 120.
        // The dip must NOT split the span → one ~21 min workout.
        let start = 2_000_000
        let first = block(start, 600, 120)
        let dip = block(start + 600, 60, 70)
        let second = block(start + 660, 600, 120)
        let hr = block(start - 300, 300, 65) + first + dip + second + block(start + 1260, 300, 65)
        let out = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60)
        XCTAssertEqual(out.count, 1, "dip split the span into \(out.count)")
        XCTAssertGreaterThanOrEqual(out[0].durationMin, 20, "merged span too short: \(out[0].durationMin) min")
    }

    func testShortSpanIsRejected() {
        // 8 min at 120 (< 12 min minimum) → nothing.
        let start = 3_000_000
        let hr = block(start - 300, 300, 65) + block(start, 8 * 60, 120) + block(start + 480, 300, 65)
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60).isEmpty)
    }

    func testLowSpanIsRejected() {
        // 20 min at 85 bpm: resting 60 → floor 90, so 85 never clears the gate → nothing.
        let start = 4_000_000
        let hr = block(start - 300, 300, 65) + block(start, 20 * 60, 85) + block(start + 1200, 300, 65)
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60).isEmpty)
    }

    func testNearWindowsAreMerged() {
        // Two 15 min bouts at 120 separated by a 3 min true rest at 65 (< 5 min merge gap, but the rest
        // is > 90 s so it CLOSES each span). The two closed spans are then MERGED into one (gap < 5 min).
        let start = 5_000_000
        let a = block(start, 15 * 60, 120)
        let gap = block(start + 900, 3 * 60, 65)   // 180 s rest > maxDipS → span closes
        let b = block(start + 1080, 15 * 60, 120)
        let hr = block(start - 300, 300, 65) + a + gap + b + block(start + 1980, 300, 65)
        let out = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60)
        XCTAssertEqual(out.count, 1, "near windows not merged: \(out.count)")
        // Merged span runs from the first bout's start to the second bout's end (~33 min).
        XCTAssertGreaterThanOrEqual(out[0].durationMin, 30, "merged span too short: \(out[0].durationMin) min")
    }

    func testFarWindowsStaySeparate() {
        // Two 15 min bouts at 120 separated by a 10 min rest (>= 5 min merge gap) → two workouts.
        let start = 6_000_000
        let a = block(start, 15 * 60, 120)
        let gap = block(start + 900, 10 * 60, 65)
        let b = block(start + 1500, 15 * 60, 120)
        let hr = block(start - 300, 300, 65) + a + gap + b + block(start + 2400, 300, 65)
        let out = AutoWorkoutDetector.detect(hr: hr, restingBpm: 60)
        XCTAssertEqual(out.count, 2)
    }

    func testWindowOverlappingSavedWorkoutIsExcluded() {
        // A clean 20 min bout, but a saved workout already covers the middle of it → suggestion suppressed.
        let start = 7_000_000
        let hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        let saved = [SavedWorkoutSpan(startSec: start + 300, endSec: start + 600)]  // overlaps the span
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60, savedSpans: saved).isEmpty)
        // Sanity: with the overlap removed, it IS detected.
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60).count, 1)
    }

    func testMotionConfirmationGatesWhenSeriesPresent() {
        // Same elevated HR bout, but the gravity series is perfectly STILL over the window → no motion
        // confirmation → rejected. With no gravity series (HR-only) the same bout IS detected.
        let start = 8_000_000
        let hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        let still = (start..<(start + 1200)).map { grav($0, 0.0) }   // zero motion delta
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60,
                                                 motion: AutoWorkoutDetector.motionPoints(still)).isEmpty)
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60).count, 1)
        // Moving gravity (alternating x) confirms motion → detected.
        let moving = (start..<(start + 1200)).map { grav($0, Double(($0 - start) % 2) * 0.5) }
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: hr, restingBpm: 60,
                                                  motion: AutoWorkoutDetector.motionPoints(moving)).count, 1)
    }

    func testEmptyInputIsEmpty() {
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: [], restingBpm: nil).isEmpty)
    }

    func testDefaultRestingHrIsUsedWhenNull() {
        // No restingBpm → default 60 → floor 90. 20 min at 120 is detected.
        let start = 9_000_000
        let hr = block(start - 300, 300, 65) + block(start, 20 * 60, 120) + block(start + 1200, 300, 65)
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: hr, restingBpm: nil).count, 1)
    }

    func testTenMinuteShadowPolicyBoundary() {
        let start = 10_000_000
        let below = elapsedSpan(start, 10 * 60 - 1, 120)
        let exact = elapsedSpan(start, 10 * 60, 120)

        XCTAssertTrue(AutoWorkoutDetector.detect(
            hr: below, restingBpm: 60, minimumSustainedMinutes: 10.0).isEmpty)
        XCTAssertEqual(AutoWorkoutDetector.detect(
            hr: exact, restingBpm: 60, minimumSustainedMinutes: 10.0).count, 1)
        // The same exact ten-minute span must not change the published 12-minute result.
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: exact, restingBpm: 60).isEmpty)
    }

    func testPublishedDefaultRemainsTwelveMinutes() {
        let start = 10_500_000
        let below = elapsedSpan(start, 12 * 60 - 1, 120)
        let exact = elapsedSpan(start, 12 * 60, 120)

        XCTAssertEqual(AutoWorkoutDetector.minSustainedMin, 12.0)
        XCTAssertEqual(AutoWorkoutDetector.shadowSustainedMinutes, [10.0, 15.0])
        XCTAssertTrue(AutoWorkoutDetector.detect(hr: below, restingBpm: 60).isEmpty)
        XCTAssertEqual(AutoWorkoutDetector.detect(hr: exact, restingBpm: 60).count, 1)
    }

    func testFifteenMinuteShadowPolicyBoundary() {
        let start = 11_000_000
        let below = elapsedSpan(start, 15 * 60 - 1, 120)
        let exact = elapsedSpan(start, 15 * 60, 120)

        XCTAssertTrue(AutoWorkoutDetector.detect(
            hr: below, restingBpm: 60, minimumSustainedMinutes: 15.0).isEmpty)
        XCTAssertEqual(AutoWorkoutDetector.detect(
            hr: exact, restingBpm: 60, minimumSustainedMinutes: 15.0).count, 1)
    }
}
