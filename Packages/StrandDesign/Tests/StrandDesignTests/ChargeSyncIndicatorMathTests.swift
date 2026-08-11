import XCTest
@testable import StrandDesign

/// Pins the pure math behind the Today header's charge-to-sync control.
///
/// The control is a view, so nothing here can assert what it looks like. What it CAN assert is the part
/// that is neither a view nor a frame: the spin clock, the two easing curves, the colour-sweep boundary,
/// and the derivation that makes the morph's two halves the same length. Those are exactly the values a
/// later tweak is most likely to break silently — the failure mode is not a crash but "the wind-down
/// feels wrong", which no compile and no screenshot catches, and which `swift-packages.yml` (the one
/// workflow that runs by default) can only catch here.
final class ChargeSyncIndicatorMathTests: XCTestCase {

    private let epsilon = 1e-9

    // MARK: - The spin clock

    /// One shared clock feeds both the indicator (which captures the hand-off angle) and the morph
    /// (which draws from it), so the rate has to be exactly the advertised one at any elapsed time.
    func testPhaseAdvancesAtTheSpinRate() {
        let start = Date(timeIntervalSince1970: 1_000)
        let period = StrandMotion.syncIndicatorSpinPeriod

        for turns in [0.0, 0.25, 1.0, 7.5] {
            let phase = StrandMotion.syncIndicatorPhase(
                since: start,
                at: start.addingTimeInterval(period * turns),
                posed: false
            )
            XCTAssertEqual(phase.degrees, 360 * turns, accuracy: 1e-9,
                           "\(turns) turns of elapsed time must be \(360 * turns)°")
        }
    }

    /// The arc's length is deliberately constant — a breathing length modulates the tail's speed and
    /// reads as the ring slowing at one spot every revolution. Pin that it never varies with time.
    func testArcLengthIsConstantAcrossTheSpin() {
        let start = Date(timeIntervalSince1970: 1_000)
        for seconds in [0.0, 0.3, 1.25, 4.0, 60.0] {
            let phase = StrandMotion.syncIndicatorPhase(
                since: start,
                at: start.addingTimeInterval(seconds),
                posed: false
            )
            XCTAssertEqual(phase.arc, StrandMotion.syncIndicatorSpinnerArcTurns, accuracy: epsilon)
        }
    }

    /// A motion-saving mode parks the ring at 12 o'clock but keeps it at FULL length, so the static
    /// state is the moving one stopped rather than a different shape appearing in its place.
    func testPosedParksAtTopWithoutShorteningTheArc() {
        let start = Date(timeIntervalSince1970: 1_000)
        let phase = StrandMotion.syncIndicatorPhase(
            since: start,
            at: start.addingTimeInterval(9.3),
            posed: true
        )
        XCTAssertEqual(phase.degrees, 0, accuracy: epsilon)
        XCTAssertEqual(phase.arc, StrandMotion.syncIndicatorSpinnerArcTurns, accuracy: epsilon)
    }

    /// A nil start (before the first spin) and a clock that has gone backwards must both read 0° rather
    /// than a negative rotation, which would wind the ring the wrong way.
    func testPhaseNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            StrandMotion.syncIndicatorPhase(since: nil, at: now, posed: false).degrees,
            0, accuracy: epsilon
        )
        XCTAssertEqual(
            StrandMotion.syncIndicatorPhase(
                since: now, at: now.addingTimeInterval(-5), posed: false
            ).degrees,
            0, accuracy: epsilon
        )
    }

    // MARK: - The easing curves

    func testSmootherStepEndpointsAndMidpoint() {
        XCTAssertEqual(StrandMotion.syncIndicatorSmootherStep(0), 0, accuracy: epsilon)
        XCTAssertEqual(StrandMotion.syncIndicatorSmootherStep(1), 1, accuracy: epsilon)
        XCTAssertEqual(StrandMotion.syncIndicatorSmootherStep(0.5), 0.5, accuracy: epsilon)
    }

    func testSmootherStepIsMonotonicAndClamped() {
        var previous = -1.0
        for step in 0...100 {
            let value = StrandMotion.syncIndicatorSmootherStep(Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous, "curve must never go backwards")
            XCTAssertTrue((0...1).contains(value), "curve must stay in 0…1, got \(value)")
            previous = value
        }
        XCTAssertEqual(StrandMotion.syncIndicatorSmootherStep(-3), 0, accuracy: epsilon)
        XCTAssertEqual(StrandMotion.syncIndicatorSmootherStep(4), 1, accuracy: epsilon)
    }

    /// The whole reason for the quintic over the classic 3t² − 2t³: BOTH the first and second
    /// derivatives vanish at each end, so the morph eases out of rest and back into it with no kick.
    /// Swapping in smoothstep would leave the second derivative non-zero and pass every other test here.
    func testSmootherStepHasZeroFirstAndSecondDerivativeAtBothEnds() {
        let h = 1e-4
        for end in [0.0, 1.0] {
            let f = StrandMotion.syncIndicatorSmootherStep
            let first = (f(end + h) - f(end - h)) / (2 * h)
            let second = (f(end + h) - 2 * f(end) + f(end - h)) / (h * h)
            XCTAssertEqual(first, 0, accuracy: 1e-6, "slope at \(end) must be flat")
            XCTAssertEqual(second, 0, accuracy: 1e-3, "curvature at \(end) must be flat")
        }
    }

    func testEaseOutQuadEndpointsAndClamping() {
        XCTAssertEqual(StrandMotion.syncIndicatorEaseOutQuad(0), 0, accuracy: epsilon)
        XCTAssertEqual(StrandMotion.syncIndicatorEaseOutQuad(1), 1, accuracy: epsilon)
        XCTAssertEqual(StrandMotion.syncIndicatorEaseOutQuad(0.5), 0.75, accuracy: epsilon)
        XCTAssertEqual(StrandMotion.syncIndicatorEaseOutQuad(-2), 0, accuracy: epsilon)
        XCTAssertEqual(StrandMotion.syncIndicatorEaseOutQuad(2), 1, accuracy: epsilon)
    }

    /// The wind-down's duration is derived to match this curve's OPENING slope to the spinner's actual
    /// rate, which is what makes the ring coast to a stop instead of halting and then re-rotating. That
    /// only holds if the slope at t = 0 is exactly 2.
    func testEaseOutQuadOpensAtDoubleRate() {
        let h = 1e-6
        let slope = (StrandMotion.syncIndicatorEaseOutQuad(h)
            - StrandMotion.syncIndicatorEaseOutQuad(0)) / h
        XCTAssertEqual(slope, 2, accuracy: 1e-4)
    }

    // MARK: - The derivation that keeps both halves equal

    /// Constant deceleration over `exitTravel` takes `2 · distance / rate`, and the entry is handed the
    /// same duration. Written out as a literal on either side, the two would drift apart the moment the
    /// spin period was retuned — and the symptom is only ever "one half feels quicker".
    func testMorphDurationIsBothHalvesOfTheSameGesture() {
        XCTAssertEqual(
            StrandMotion.syncIndicatorSpinRateDegrees,
            360 / StrandMotion.syncIndicatorSpinPeriod,
            accuracy: epsilon
        )
        XCTAssertEqual(
            StrandMotion.syncIndicatorMorphDuration,
            2 * StrandMotion.syncIndicatorExitTravelDegrees
                / StrandMotion.syncIndicatorSpinRateDegrees,
            accuracy: epsilon
        )
        XCTAssertGreaterThan(StrandMotion.syncIndicatorMorphDuration, 0)
    }

    // MARK: - The travelling colour boundary

    /// At either extreme the blend band must sit entirely OFF the arc, or a sliver of the outgoing
    /// colour is left behind on a ring that has otherwise finished turning over.
    func testTintBoundaryClearsTheArcAtBothEnds() {
        let band = StrandMotion.syncIndicatorTintBandTurns
        // A float tolerance, not a slack allowance: the boundary lands exactly on the arc's ends by
        // construction, so the residue here is representation error (~1e-16), not a real overhang.
        let tolerance = 1e-12
        for arc in [0.02, StrandMotion.syncIndicatorSpinnerArcTurns, 1.0] {
            let untinted = StrandMotion.syncIndicatorTintBoundary(tint: 0, arc: arc)
            XCTAssertGreaterThanOrEqual(untinted - band, arc - tolerance,
                                        "at tint 0 the whole arc must still be the battery colour")

            let fullyTinted = StrandMotion.syncIndicatorTintBoundary(tint: 1, arc: arc)
            XCTAssertLessThanOrEqual(fullyTinted + band, tolerance,
                                     "at tint 1 the whole arc must be the sync colour")
        }
    }

    /// The boundary sweeps head-to-tail, so it only ever decreases as the tint rises.
    func testTintBoundarySweepsMonotonically() {
        let arc = StrandMotion.syncIndicatorSpinnerArcTurns
        var previous = Double.infinity
        for step in 0...100 {
            let boundary = StrandMotion.syncIndicatorTintBoundary(
                tint: Double(step) / 100, arc: arc
            )
            XCTAssertLessThan(boundary, previous, "the boundary must travel one way only")
            previous = boundary
        }
    }

    // MARK: - Capsule width

    /// The capsule hugs its label instead of using one constant for every language, so a short label is
    /// not left with lopsided padding and a long one is not clipped. Both ends of that need pinning.
    func testExpandedWidthHugsTheLabelBetweenItsFloorAndCap() {
        let floor = NoopMetrics.compactControlSize
        let cap = NoopMetrics.syncIndicatorExpandedWidth
        let gap = NoopMetrics.syncIndicatorLabelSpacing

        // No measurement yet (first layout pass) must not collapse the control below its circle.
        XCTAssertEqual(ChargeSyncIndicator.expandedWidth(labelWidth: 0), floor + 2 * gap)
        XCTAssertGreaterThanOrEqual(ChargeSyncIndicator.expandedWidth(labelWidth: 0), floor)

        // A label that fits gets an even gap on both sides of itself.
        let modest: CGFloat = 30
        XCTAssertEqual(
            ChargeSyncIndicator.expandedWidth(labelWidth: modest),
            floor + gap + modest + gap
        )

        // A translation longer than the cap shrinks to fit rather than widening the control and
        // shoving the day title aside on a phone-width header.
        XCTAssertEqual(ChargeSyncIndicator.expandedWidth(labelWidth: 400), cap)
        XCTAssertLessThanOrEqual(ChargeSyncIndicator.expandedWidth(labelWidth: 10_000), cap)
    }

    func testExpandedWidthIsMonotonicInLabelWidth() {
        var previous: CGFloat = 0
        for width in stride(from: CGFloat(0), through: 200, by: 5) {
            let expanded = ChargeSyncIndicator.expandedWidth(labelWidth: width)
            XCTAssertGreaterThanOrEqual(expanded, previous)
            previous = expanded
        }
    }

    // MARK: - Ring tint

    /// The three battery bands. Boundary values are the point: 15 and 35 belong to the calmer band above
    /// them, so a strap sitting exactly on 35 does not read as a warning.
    ///
    /// Asserted on the band rather than the `Color`, because SwiftUI wraps a dynamic catalog colour in a
    /// fresh provider per access — two reads of one palette token are not `==`, so a colour comparison
    /// would fail on identity while telling you nothing about the thresholds.
    func testChargeBandThresholds() {
        XCTAssertEqual(ChargeSyncIndicator.chargeBand(0), .critical)
        XCTAssertEqual(ChargeSyncIndicator.chargeBand(14.9), .critical)
        XCTAssertEqual(ChargeSyncIndicator.chargeBand(15), .warning)
        XCTAssertEqual(ChargeSyncIndicator.chargeBand(34.9), .warning)
        XCTAssertEqual(ChargeSyncIndicator.chargeBand(35), .healthy)
        XCTAssertEqual(ChargeSyncIndicator.chargeBand(100), .healthy)
    }
}
