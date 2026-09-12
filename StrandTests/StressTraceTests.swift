import XCTest
import StrandAnalytics

/// The stress widget's pure half, and the parity that keeps it honest.
///
/// Mirrors the Kotlin `StressTraceTest` case for case. The two that matter most pin where this departs
/// from `HrTrace`: the domain is fixed rather than normalised, and an unscored hour is a hole rather
/// than a point to draw through.
final class StressTraceTests: XCTestCase {

    private let hour: Int64 = 3_600
    private func at(_ h: Int64, _ level: Double?, moving: Bool = false) -> StressPoint {
        StressPoint(ts: h * hour, level: level, moving: moving)
    }

    // MARK: - the constant the extension cannot import

    func testHighBandFloorStillMatchesTheAnalyticsConstant() {
        // `StressTrace` restates this because the widget extension links no packages, so it cannot see
        // `DaytimeStress`. This test is the only place that can compare them, and it exists so the copy
        // cannot drift silently the day the band moves. If this fails, change the copy, not this line.
        XCTAssertEqual(StressTrace.highBandFloor, DaytimeStress.highBandFloor)
    }

    func testDomainMaxMatchesTheScaleTheScoreIsOn() {
        // The 0-3 proxy's top. A widget drawing against a different ceiling would misplace every hour.
        XCTAssertEqual(StressTrace.domainMax, 3.0)
    }

    // MARK: - the fixed domain

    func testACalmDayIsDrawnLowRatherThanStretchedAcrossTheBox() {
        let calm = [at(0, 0.2), at(1, 0.3), at(2, 0.25)]
        let pts = StressTrace.segments(calm, width: 100, height: 100)[0]
        // Every point sits in the bottom tenth, because 0.3 of 3 IS low. Normalising to the day's own
        // range would have spread these three across the full height and drawn a dramatic day.
        XCTAssertTrue(pts.allSatisfy { $0.y >= 88 }, "calm day should hug the bottom, got \(pts)")
    }

    func testTheSameShapeAtAHigherLevelDrawsHigher() {
        let calm = StressTrace.segments([at(0, 0.2), at(1, 0.4)], width: 100, height: 100)[0]
        let tense = StressTrace.segments([at(0, 2.2), at(1, 2.4)], width: 100, height: 100)[0]
        // Identical spread, different absolute level: under a normalising domain these would be drawn
        // identically, which is the lie the fixed domain exists to prevent.
        XCTAssertLessThan(tense[0].y, calm[0].y)
    }

    func testTheTopOfTheDomainIsTheTopOfTheBoxAndZeroIsTheBottom() {
        let pts = StressTrace.segments([at(0, 3.0), at(1, 0.0)], width: 100, height: 100)[0]
        XCTAssertEqual(pts[0].y, 0, accuracy: 0.001)
        XCTAssertEqual(pts[1].y, 100, accuracy: 0.001)
    }

    // MARK: - gaps

    func testAnUnscoredHourSplitsTheLineRatherThanBeingDrawnThrough() {
        let day = [at(0, 1.0), at(1, 1.2), at(2, nil), at(3, 0.9), at(4, 1.1)]
        let segs = StressTrace.segments(day, width: 100, height: 100)
        XCTAssertEqual(segs.count, 2, "the hole must break the line in two")
        XCTAssertEqual(segs[0].count, 2)
        XCTAssertEqual(segs[1].count, 2)
    }

    func testTheGapKeepsItsWidthSoTheAfternoonDoesNotSlideLeft() {
        let segs = StressTrace.segments([at(0, 1.0), at(1, nil), at(2, 1.0)], width: 100, height: 100)
        XCTAssertEqual(segs[0][0].x, 0, accuracy: 0.001)
        XCTAssertEqual(segs[1][0].x, 100, accuracy: 0.001)
    }

    func testADayWithNothingScoredDrawsNothing() {
        let day = [at(0, nil), at(1, nil, moving: true)]
        XCTAssertTrue(StressTrace.segments(day, width: 100, height: 100).isEmpty)
        XCTAssertNil(StressTrace.stats(day))
    }

    // MARK: - movement

    func testHoursMaskedAsMovementAreMarkedAndDoNotJoinTheLine() {
        let day = [at(0, 1.0), at(1, nil, moving: true), at(2, 1.0)]
        XCTAssertEqual(StressTrace.segments(day, width: 100, height: 100).count, 2)
        let span = StressTrace.movingSpans(day, width: 100)[0]
        XCTAssertEqual(span.lowerBound, 25, accuracy: 0.001)
        XCTAssertEqual(span.upperBound, 75, accuracy: 0.001)
    }

    // #2106: contiguous masked stretches, so the marks read as regions rather than as axis ticks.

    /// Adjacent masked hours become ONE span: that is the whole point, a bar under the hole it explains.
    func testAdjacentMovingHoursJoinIntoOneSpan() {
        let day = [at(0, 1.0), at(1, nil, moving: true), at(2, nil, moving: true), at(3, 1.5)]
        XCTAssertEqual(StressTrace.movingSpans(day, width: 100).count, 1)
    }

    /// Separated runs stay separate, so two different stretches are not merged into one claim.
    func testSeparatedMovingRunsStaySeparate() {
        let day = [at(0, nil, moving: true), at(1, 1.0), at(2, nil, moving: true)]
        XCTAssertEqual(StressTrace.movingSpans(day, width: 100).count, 2)
    }

    /// A run ending at the LAST hour still closes, rather than being dropped for want of a terminator.
    func testARunEndingAtTheLastPointIsStillEmitted() {
        let day = [at(0, 1.0), at(1, nil, moving: true), at(2, nil, moving: true)]
        let spans = StressTrace.movingSpans(day, width: 100)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].upperBound, 100, accuracy: 0.001)
    }

    /// No moving hours means no marks, so an ordinary day carries no band at all.
    func testNoMovingHoursYieldsNoSpans() {
        XCTAssertTrue(StressTrace.movingSpans([at(0, 1.0), at(1, 2.0)], width: 100).isEmpty)
    }

    /// A LONE masked hour is the case the geometry exists for: centre to centre it has a width of zero,
    /// and it is the hour with no neighbours to make it obvious, so it is also the one that most needs
    /// to be legible. It covers its own hour, half a slot either side of its centre.
    func testALoneMovingHourSpansItsOwnHourNotAnInstant() {
        let day = [at(0, 1.0), at(1, 1.0), at(2, nil, moving: true), at(3, 1.0), at(4, 1.0)]
        let spans = StressTrace.movingSpans(day, width: 100)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].lowerBound, 37.5, accuracy: 0.001)
        XCTAssertEqual(spans[0].upperBound, 62.5, accuracy: 0.001)
    }

    /// A run covers its hours EDGE to edge, so the bar reaches past the outermost masked centres.
    func testARunCoversItsHoursEdgeToEdge() {
        let day = [at(0, 1.0), at(1, nil, moving: true), at(2, nil, moving: true), at(3, 1.0)]
        let spans = StressTrace.movingSpans(day, width: 100)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].lowerBound, 100.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(spans[0].upperBound, 100.0 * 5.0 / 6.0, accuracy: 0.001)
    }

    /// At the ends of the day the territory stops at the data: nothing is invented past what was sampled.
    func testARunStartingAtTheFirstHourStartsAtTheEdgeOfTheBox() {
        let day = [at(0, nil, moving: true), at(1, 1.0), at(2, 1.0)]
        let spans = StressTrace.movingSpans(day, width: 100)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].lowerBound, 0, accuracy: 0.001)
    }

    // MARK: - the high band

    func testOnlyHoursAtOrAboveTheHighBandGetADot() {
        let day = [at(0, 1.0), at(1, 1.9), at(2, 2.0), at(3, 2.8), at(4, nil)]
        // 2.0 is the floor itself, so it counts; 1.9 does not.
        XCTAssertEqual(StressTrace.highPoints(day, width: 100, height: 100).count, 2)
    }

    func testADotLandsOnItsOwnVertex() {
        let day = [at(0, 0.5), at(1, 2.5)]
        let vertex = StressTrace.segments(day, width: 100, height: 100)[0][1]
        let dot = StressTrace.highPoints(day, width: 100, height: 100)[0]
        // Dot and line are placed by the same rule, so a nudge to one cannot leave the other behind.
        // The view lifts the dot above the stroke; the geometry must agree exactly.
        XCTAssertEqual(vertex.x, dot.x, accuracy: 0.001)
        XCTAssertEqual(vertex.y, dot.y, accuracy: 0.001)
    }

    func testACalmDayGetsNoDotsAtAll() {
        XCTAssertTrue(StressTrace.highPoints([at(0, 0.4), at(1, 1.2)], width: 100, height: 100).isEmpty)
    }

    // MARK: - stats

    func testMeanCoversScoredHoursOnlyAndPeakIsTheHighestOfThem() throws {
        let day = [at(0, 1.0), at(1, nil), at(2, 2.0), at(3, nil, moving: true)]
        let stats = try XCTUnwrap(StressTrace.stats(day))
        XCTAssertEqual(stats.mean, 1.5, accuracy: 0.0001)
        XCTAssertEqual(stats.peak.level ?? 0, 2.0, accuracy: 0.0001)
        XCTAssertEqual(stats.peak.ts, 2 * hour)
        XCTAssertEqual(stats.scoredHours, 2)
        XCTAssertEqual(stats.movingHours, 1)
    }

    // MARK: - axes

    func testTheLevelScaleIsFixedSoTwoDaysCanBeCompared() {
        XCTAssertEqual(StressTrace.levelTicks(), [3, 2, 1, 0])
    }

    func testTimeTicksLabelTheAxisWhichSpansTheWholeSeries() {
        let day = [at(0, nil), at(8, 1.0), at(12, 1.5), at(16, 2.0), at(23, nil)]
        // Every renderer spreads these three evenly across the chart, and the chart spans the SERIES.
        // Anything narrower names the wrong instant at the edge it is drawn against.
        XCTAssertEqual(StressTrace.timeTicks(day), [0, 11 * hour + 1_800, 23 * hour])
    }

    /// #2106: scored to 18:30, masked as movement until 22:00, and the axis said the day ended at 18:30.
    /// The right-hand label is the end of the DAY, not the end of scoring, or a chart that is perfectly
    /// current reads as one that stopped updating hours ago.
    func testADayWhoseClosingHoursWereAllMaskedStillNamesItsTrueEnd() {
        let day = [at(6, 1.0), at(18, 1.5), at(20, nil, moving: true), at(22, nil, moving: true)]
        XCTAssertEqual(StressTrace.timeTicks(day).last, 22 * hour)
    }

    func testOneInstantNamesOneInstant() {
        // The renderers hide a lone label, so this is what keeps a one-point day from showing a stray.
        XCTAssertEqual(StressTrace.timeTicks([at(9, 1.0)]), [9 * hour])
    }

    func testTwoInstantsNameBothEndsAndTheMidpointBetweenThem() {
        XCTAssertEqual(StressTrace.timeTicks([at(9, 1.0), at(10, nil)]),
                       [9 * hour, 9 * hour + 1_800, 10 * hour])
    }

    // MARK: - the snapshot's day guard

    func testACurveScoredYesterdayIsNotDrawnToday() {
        let now = Date()
        var snap = WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: now)
        snap.stressSeries = [at(9, 1.5)]
        snap.stressDay = WidgetSnapshot.localDayNumber(now) - 1
        // Nothing runs at midnight to tidy the App Group, so the staleness check has to happen where the
        // value is read. Otherwise the card shows yesterday's afternoon under today's date until the
        // first scorable hour of the new day arrives.
        XCTAssertTrue(snap.stressCurve(now: now).isEmpty)
    }

    func testTodaysCurveIsDrawn() {
        let now = Date()
        var snap = WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: now)
        snap.stressSeries = [at(9, 1.5)]
        snap.stressDay = WidgetSnapshot.localDayNumber(now)
        XCTAssertEqual(snap.stressCurve(now: now).count, 1)
    }

    func testAnOlderSnapshotWithNoCurveDecodesAndDrawsNothing() {
        // Both fields are optional so a snapshot written before this existed still decodes; it simply
        // has no curve to draw.
        let snap = WidgetSnapshot(recovery: 50, bpm: 60, batteryPct: 80, bonded: true, updated: Date())
        XCTAssertNil(snap.stressDay)
        XCTAssertTrue(snap.stressCurve().isEmpty)
    }

    func testPublishingAFreshlyScoredHourIsNotDedupedAway() {
        let now = Date()
        var a = WidgetSnapshot(recovery: 50, bpm: 60, batteryPct: 80, bonded: true, updated: now)
        a.stressDay = WidgetSnapshot.localDayNumber(now)
        a.stressSeries = [at(9, 1.5)]
        var b = a
        b.stressSeries = [at(9, 1.5), at(10, 2.1)]
        // Without the curve in the comparison, a publish that scored a fresh hour and changed nothing
        // else would be dropped, and the widget would sit an hour behind until an unrelated field moved.
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: a, to: b))
    }
}
