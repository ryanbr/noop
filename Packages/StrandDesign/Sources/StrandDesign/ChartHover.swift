#if !os(watchOS)
// The chart-hover toolkit (tooltips, crosshair, nearest-point) is for pointer/cursor charts the
// watch never shows; excluded on watchOS, iOS/macOS unchanged.
import SwiftUI

// MARK: - Chart Hover Toolkit (reusable across every visualization)
//
// A shared, instrument-grade hover affordance: a small dark tooltip card that
// names the exact datum under the cursor, plus geometry helpers for crosshairs
// and nearest-point lookup. Every StrandDesign visualization inherits the same
// look so nothing is ever a static, unexplained colour.
//
// Design tokens only: surfaceOverlay background, hairline border, StrandFont +
// StrandPalette text, StrandMotion fade-in. Never hardcode hex.

// MARK: - ChartTooltip

/// A small dark read-out card shown near the cursor while hovering a chart.
/// Renders a bold primary value line and a secondary label/date line.
public struct ChartTooltip: View {

    /// The bold value line (e.g. "62 ms", "Recovery 88").
    public var value: String
    /// The secondary context line (e.g. a formatted date, stage clock, index).
    public var label: String?
    /// An optional accent swatch shown as a leading dot (e.g. the sampled
    /// gradient colour for that datum) so the tooltip explains the colour.
    public var accent: Color?

    public init(value: String, label: String? = nil, accent: Color? = nil) {
        self.value = value
        self.label = label
        self.accent = accent
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let accent {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                    .shadow(color: accent.opacity(0.8), radius: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(StrandFont.captionNumber)
                    .fontWeight(.semibold)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let label {
                    Text(label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(NoopPanelSurface(cornerRadius: 8, elevated: true))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label != nil ? "\(value), \(label!)" : value)
    }
}

// MARK: - Tooltip positioning

/// Position a tooltip near an anchor point while keeping it inside `container`.
/// Estimates the tooltip's size, then flips/clamps so it never spills off-edge.
public struct ChartTooltipPlacement {

    /// Compute the tooltip centre for an anchor (typically the highlighted point
    /// or the cursor), given the tooltip's measured size and the chart bounds.
    /// Prefers to sit above-and-right of the anchor, flipping when near an edge.
    public static func position(
        anchor: CGPoint,
        tooltipSize: CGSize,
        in container: CGSize,
        gap: CGFloat = 12
    ) -> CGPoint {
        let halfW = tooltipSize.width / 2
        let halfH = tooltipSize.height / 2

        // Default: above the anchor.
        var y = anchor.y - gap - halfH
        if y - halfH < 0 {
            // Not enough room above — drop below.
            y = anchor.y + gap + halfH
        }
        y = min(max(y, halfH), max(halfH, container.height - halfH))

        // Default: centred on the anchor x, clamped to bounds.
        var x = anchor.x
        x = min(max(x, halfW), max(halfW, container.width - halfW))

        return CGPoint(x: x, y: y)
    }
}

// MARK: - Nearest-point lookup

/// Geometry helpers for mapping a hover location to the nearest datum.
public enum ChartHoverMath {

    /// Index of the sample whose x-position (evenly spaced across `width`) is
    /// closest to `x`. Returns nil for an empty series.
    public static func nearestIndex(toX x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, width > 0 else { return 0 }
        let step = width / CGFloat(count - 1)
        let raw = Int((x / step).rounded())
        return min(max(raw, 0), count - 1)
    }

    /// Index of the point in `xs` (arbitrary x-positions) closest to `x`.
    public static func nearestIndex(toX x: CGFloat, xs: [CGFloat]) -> Int? {
        guard !xs.isEmpty else { return nil }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, px) in xs.enumerated() {
            let d = abs(px - x)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }
}

// MARK: - Crosshair rule

/// A thin vertical crosshair line drawn at a given x with a hairline-strong
/// stroke. Shared by TrendChart / Sparkline so the rule reads identically.
struct CrosshairRule: View {
    var x: CGFloat
    var height: CGFloat
    var color: Color = StrandPalette.hairlineStrong

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: height))
        }
        .stroke(
            color,
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Highlighted point dot

/// A small accented dot used to mark the highlighted sample on a line.
struct HighlightDot: View {
    var color: Color
    var diameter: CGFloat = 9

    var body: some View {
        // Design Reset (WHOOP): a crisp solid dot with a clean surface ring, no blurred bloom halo.
        ZStack {
            Circle()
                .fill(StrandPalette.surfaceBase)
                .frame(width: diameter + 3, height: diameter + 3)
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - "Now" end-cap

/// The crisp "now" marker pinned to a trend line's latest point: a soft tinted outer ring, a brighter
/// mid-ring, and a white core — flat, no bloom (WHOOP). Positioned by `TrendChart` inside its own plot
/// coordinate space so it sits exactly on the curve (#458).
struct NowCapDot: View {
    var color: Color

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.30)).frame(width: 18, height: 18)
            Circle().fill(color.opacity(0.65)).frame(width: 11, height: 11)
            Circle().fill(StrandPalette.tipCore).frame(width: 5, height: 5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tooltip overlay container

/// Wraps a tooltip so its measured size feeds back into placement. Fades in
/// with StrandMotion and positions itself within `container` near `anchor`.
struct PositionedTooltip: View {
    var anchor: CGPoint
    var container: CGSize
    var tooltip: ChartTooltip

    @State private var measured: CGSize = .zero

    var body: some View {
        tooltip
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { measured = g.size }
                        .onChangeCompat(of: g.size) { measured = $0 }
                }
            )
            .position(
                ChartTooltipPlacement.position(
                    anchor: anchor,
                    tooltipSize: measured == .zero ? CGSize(width: 90, height: 40) : measured,
                    in: container
                )
            )
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("ChartTooltip") {
    VStack(spacing: 24) {
        ChartTooltip(value: "Recovery 88", label: "Tue 3 Jun", accent: StrandPalette.recoveryColor(88))
        ChartTooltip(value: "62 ms", label: "HRV · sample 14")
        ChartTooltip(value: "18.7", label: "STRAIN · all-out", accent: StrandPalette.strainColor(18.7))
    }
    .padding(40)
    .frame(width: 320, height: 240)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
