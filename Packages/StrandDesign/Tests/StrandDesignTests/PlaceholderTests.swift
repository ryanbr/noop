import XCTest
import SwiftUI
@testable import StrandDesign

final class StrandDesignTests: XCTestCase {

    func testVersion() {
        XCTAssertEqual(StrandDesign.version, "0.1.0")
    }

    func testHexParsing() {
        let c = Color(hex: "#0B0D12").rgbaComponents
        XCTAssertEqual(c.r, 0x0B / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.g, 0x0D / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.b, 0x12 / 255.0, accuracy: 0.01)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testRecoveryGradientStops() {
        XCTAssertEqual(StrandPalette.recoveryStops.count, 5)
        XCTAssertEqual(StrandPalette.recoveryStops.first?.location, 0.0)
        XCTAssertEqual(StrandPalette.recoveryStops.last?.location, 1.0)
    }

    func testRecoveryColorEndpoints() {
        // Score 0 should equal the indigo start; 100 the mint end.
        let low = StrandPalette.recoveryColor(0).rgbaComponents
        let indigo = StrandPalette.recovery000.rgbaComponents
        XCTAssertEqual(low.r, indigo.r, accuracy: 0.02)
        XCTAssertEqual(low.g, indigo.g, accuracy: 0.02)
        XCTAssertEqual(low.b, indigo.b, accuracy: 0.02)

        let high = StrandPalette.recoveryColor(100).rgbaComponents
        let mint = StrandPalette.recovery100.rgbaComponents
        XCTAssertEqual(high.r, mint.r, accuracy: 0.02)
        XCTAssertEqual(high.g, mint.g, accuracy: 0.02)
        XCTAssertEqual(high.b, mint.b, accuracy: 0.02)
    }

    func testRecoveryColorClamps() {
        // Out of range clamps to endpoints rather than crashing.
        let below = StrandPalette.recoveryColor(-50).rgbaComponents
        let zero = StrandPalette.recoveryColor(0).rgbaComponents
        XCTAssertEqual(below.r, zero.r, accuracy: 0.001)
        let above = StrandPalette.recoveryColor(150).rgbaComponents
        let hundred = StrandPalette.recoveryColor(100).rgbaComponents
        XCTAssertEqual(above.b, hundred.b, accuracy: 0.001)
    }

    func testRecoveryStateWords() {
        // State words come from the package bundle in the host's language. English literals reject
        // correct output on a localized Mac; pin the bands using labels resolved from that same bundle.
        let depleted = String(localized: "DEPLETED", bundle: .module)
        let low = String(localized: "LOW", bundle: .module)
        let moderate = String(localized: "MODERATE", bundle: .module)
        let primed = String(localized: "PRIMED", bundle: .module)
        let peak = String(localized: "PEAK", bundle: .module)
        let cases: [(Double, String)] = [
            (-1, depleted), (10, depleted), (24.999, depleted),
            (25, low), (40, low), (49.999, low),
            (50, moderate), (60, moderate), (69.999, moderate),
            (70, primed), (80, primed), (87.999, primed),
            (88, peak), (95, peak), (101, peak),
        ]
        for (score, expected) in cases {
            XCTAssertEqual(StrandPalette.recoveryState(score), expected, "score \(score)")
        }
    }

    func testStrainColorScaleAndEndpoints() {
        // Effort samples the 0...100 ramp; endpoints match ember/magenta.
        let ember = StrandPalette.strainColor(0).rgbaComponents
        let start = StrandPalette.strain000.rgbaComponents
        XCTAssertEqual(ember.r, start.r, accuracy: 0.02)
        let magenta = StrandPalette.strainColor(100).rgbaComponents
        let end = StrandPalette.strain100.rgbaComponents
        XCTAssertEqual(magenta.b, end.b, accuracy: 0.02)
    }

    func testHRZoneColor() {
        XCTAssertEqual(StrandPalette.hrZoneColor(1).rgbaComponents.b,
                       StrandPalette.zone1.rgbaComponents.b, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.hrZoneColor(5).rgbaComponents.r,
                       StrandPalette.zone5.rgbaComponents.r, accuracy: 0.001)
        // Clamps out-of-range.
        XCTAssertEqual(StrandPalette.hrZoneColor(99).rgbaComponents.r,
                       StrandPalette.zone5.rgbaComponents.r, accuracy: 0.001)
    }

    func testSleepStageColorMapping() {
        XCTAssertEqual(StrandPalette.sleepStageColor(.rem).rgbaComponents.g,
                       StrandPalette.sleepREM.rgbaComponents.g, accuracy: 0.001)
        XCTAssertEqual(StrandPalette.sleepStageColor(.awake).rgbaComponents.r,
                       StrandPalette.sleepAwake.rgbaComponents.r, accuracy: 0.001)
    }

    func testSleepStageBandRankOrdering() {
        XCTAssertEqual(SleepStage.awake.bandRank, 0)
        XCTAssertEqual(SleepStage.deep.bandRank, 3)
        XCTAssertLessThan(SleepStage.awake.bandRank, SleepStage.deep.bandRank)
    }

    func testSampleMidpointInterpolatesBetweenStops() {
        // Halfway between two black/white stops is mid-grey.
        let stops: [Gradient.Stop] = [
            .init(color: Color(hex: "#000000"), location: 0),
            .init(color: Color(hex: "#FFFFFF"), location: 1),
        ]
        let mid = StrandPalette.sample(stops: stops, at: 0.5).rgbaComponents
        XCTAssertEqual(mid.r, 0.5, accuracy: 0.03)
        XCTAssertEqual(mid.g, 0.5, accuracy: 0.03)
        XCTAssertEqual(mid.b, 0.5, accuracy: 0.03)
    }

    func testSleepIntervalDuration() {
        let i = SleepInterval(stage: .deep, start: 100, end: 460)
        XCTAssertEqual(i.duration, 360, accuracy: 0.001)
    }

    // MARK: - Chart hover toolkit

    func testNearestIndexEvenlySpaced() {
        // 5 samples across width 100 → stride 25. Cursor near each step.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 0, count: 5, width: 100), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 26, count: 5, width: 100), 1)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 60, count: 5, width: 100), 2)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 100, count: 5, width: 100), 4)
        // Out of range clamps to the ends.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: -50, count: 5, width: 100), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 999, count: 5, width: 100), 4)
    }

    func testNearestIndexEdgeCases() {
        XCTAssertNil(ChartHoverMath.nearestIndex(toX: 10, count: 0, width: 100))
        // Single sample always resolves to index 0.
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 80, count: 1, width: 100), 0)
    }

    func testNearestIndexArbitraryXs() {
        let xs: [CGFloat] = [0, 30, 90, 200]
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 5, xs: xs), 0)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 35, xs: xs), 1)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 100, xs: xs), 2)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toX: 195, xs: xs), 3)
        XCTAssertNil(ChartHoverMath.nearestIndex(toX: 10, xs: []))
    }

    func testTooltipPlacementStaysInBounds() {
        let container = CGSize(width: 200, height: 120)
        let size = CGSize(width: 80, height: 36)
        // Anchor in the top-left corner: tooltip must clamp fully inside.
        let topLeft = ChartTooltipPlacement.position(anchor: CGPoint(x: 0, y: 0),
                                                     tooltipSize: size, in: container)
        XCTAssertGreaterThanOrEqual(topLeft.x - size.width / 2, -0.001)
        XCTAssertGreaterThanOrEqual(topLeft.y - size.height / 2, -0.001)
        XCTAssertLessThanOrEqual(topLeft.x + size.width / 2, container.width + 0.001)
        XCTAssertLessThanOrEqual(topLeft.y + size.height / 2, container.height + 0.001)

        // Anchor in the bottom-right corner: still inside.
        let bottomRight = ChartTooltipPlacement.position(anchor: CGPoint(x: 200, y: 120),
                                                         tooltipSize: size, in: container)
        XCTAssertLessThanOrEqual(bottomRight.x + size.width / 2, container.width + 0.001)
        XCTAssertLessThanOrEqual(bottomRight.y + size.height / 2, container.height + 0.001)
    }

    func testTooltipPlacementFlipsBelowWhenNoRoomAbove() {
        let container = CGSize(width: 300, height: 200)
        let size = CGSize(width: 60, height: 40)
        // Anchor near the top: with gap 12 there's no room above, so it drops below.
        let pos = ChartTooltipPlacement.position(anchor: CGPoint(x: 150, y: 5),
                                                 tooltipSize: size, in: container, gap: 12)
        XCTAssertGreaterThan(pos.y, 5)
    }

    func testTrendChartDefaultDateStringNonEmpty() {
        let s = TrendChart.defaultDateString(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(s.isEmpty)
    }

    func testSparklineDefaultValueString() {
        XCTAssertEqual(Sparkline.defaultValueString(64), "64")
        XCTAssertEqual(Sparkline.defaultValueString(64.5), "64.5")
    }

    // MARK: - TrendChart Y domain (#974 top-headroom fix)

    /// With no explicit yDomain the axis falls back to the gradient's valueRange.
    func testTrendChartResolvedDomainDefaultsToValueRange() {
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 10),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 40),
        ]
        let chart = TrendChart(points: pts, valueRange: 0...100)
        XCTAssertEqual(chart.resolvedYDomain.lowerBound, 0, accuracy: 0.0001)
        XCTAssertEqual(chart.resolvedYDomain.upperBound, 100, accuracy: 0.0001)
    }

    /// An explicit yDomain (a data-fitted axis with top headroom) overrides valueRange, and its
    /// top sits ABOVE the highest reading so a peak curve + the top axis label clear the plot clip.
    func testTrendChartExplicitYDomainProvidesTopHeadroom() {
        let peak = 2.4
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 0.5),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: peak),
        ]
        // Mirrors StressView's fitted axis: round the peak up, add headroom, floor at 1.
        let yTop = max(1, peak.rounded(.up) + 0.3)
        let chart = TrendChart(points: pts, valueRange: 0...3, yDomain: 0...yTop)
        XCTAssertEqual(chart.resolvedYDomain.lowerBound, 0, accuracy: 0.0001)
        // 2.4 → ceil 3 → +0.3 = 3.3, comfortably above the peak.
        XCTAssertGreaterThan(chart.resolvedYDomain.upperBound, peak)
        XCTAssertEqual(chart.resolvedYDomain.upperBound, 3.3, accuracy: 0.0001)
    }

    /// A flat, all-calm history (max 0) must not collapse to a zero-height axis: the floor holds it at 1.
    func testTrendChartFittedDomainFloorsAtOne() {
        let peak = 0.0
        let yTop = max(1, peak.rounded(.up) + 0.3)
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 0),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 0),
        ]
        let chart = TrendChart(points: pts, valueRange: 0...3, yDomain: 0...yTop)
        XCTAssertEqual(chart.resolvedYDomain.upperBound, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(chart.resolvedYDomain.upperBound, chart.resolvedYDomain.lowerBound)
    }

    // MARK: - TrendChart bar mode (#85: sleep duration as a bar histogram)

    /// Bar mode must floor the plotted domain at 0 even when the data-fitted `resolvedYDomain` sits
    /// entirely above it (e.g. a trailing-30-days sleep-hours window like 5...9h) — otherwise a
    /// BarMark's length would no longer be proportional to its value.
    func testTrendChartBarModeFloorsPlotDomainAtZero() {
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 6.5),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 7.8),
        ]
        let chart = TrendChart(points: pts, valueRange: 5...9, showsBars: true)
        XCTAssertEqual(chart.resolvedYDomain.lowerBound, 5, accuracy: 0.0001,
                       "the gradient/axis-fitted domain itself is untouched")
        XCTAssertEqual(chart.plotYDomain.lowerBound, 0, accuracy: 0.0001,
                       "but the domain actually applied to the plot floors at 0 for bars")
        XCTAssertEqual(chart.plotYDomain.upperBound, chart.resolvedYDomain.upperBound, accuracy: 0.0001)
    }

    /// Line mode (the default) must NOT floor at 0 — `plotYDomain` should equal `resolvedYDomain`
    /// unchanged, preserving the data-fitted-axis behavior the other tests above pin.
    func testTrendChartLineModeDoesNotFloorPlotDomain() {
        let pts = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 6.5),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 7.8),
        ]
        let chart = TrendChart(points: pts, valueRange: 5...9)
        XCTAssertEqual(chart.plotYDomain.lowerBound, chart.resolvedYDomain.lowerBound, accuracy: 0.0001)
    }
}
