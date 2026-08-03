#if !os(watchOS)
// Sparkline uses .onContinuousHover + ChartHover helpers (unavailable on watchOS); the watch
// doesn't draw sparklines, so the whole view is excluded there. iOS/macOS unchanged.
import SwiftUI

// MARK: - Sparkline (§9.4 Today / Live HR tile)
//
// A tiny inline line for live HR (or any short numeric series). Gradient-stroked,
// with an optional crisp leading dot at the latest sample and a faint area
// wash (WHOOP-flat: no bloom). Designed to sit in a card/tile or the menu-bar popover.

public struct Sparkline: View {

    public var values: [Double]
    /// Line gradient (defaults to recovery scale; pass strain/zone gradients as needed).
    public var gradient: Gradient
    /// Optional explicit value range; otherwise auto-fit with padding.
    public var range: ClosedRange<Double>?
    public var lineWidth: CGFloat
    public var showsArea: Bool
    public var showsHead: Bool
    /// Whether hovering highlights the nearest sample + shows a compact tooltip.
    public var showsHover: Bool
    /// Formats a sample value for the tooltip's bold line.
    public var valueFormat: (Double) -> String
    /// Optional secondary label for a sample by index (e.g. a timestamp). When
    /// nil the tooltip falls back to "sample N".
    public var indexLabel: ((Int) -> String)?

    public init(
        values: [Double],
        gradient: Gradient = StrandPalette.recoveryGradient,
        range: ClosedRange<Double>? = nil,
        lineWidth: CGFloat = 2,
        showsArea: Bool = true,
        showsHead: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { Sparkline.defaultValueString($0) },
        indexLabel: ((Int) -> String)? = nil
    ) {
        self.values = values
        self.gradient = gradient
        self.range = range
        self.lineWidth = lineWidth
        self.showsArea = showsArea
        self.showsHead = showsHead
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.indexLabel = indexLabel
    }

    /// The hovered x-position in local coordinates.
    @State private var hoverX: CGFloat? = nil

    /// Default value formatting: integer when whole, else one decimal.
    public static func defaultValueString(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private var bounds: (min: Double, max: Double) {
        if let range { return (range.lowerBound, range.upperBound) }
        guard let lo = values.min(), let hi = values.max() else { return (0, 1) }
        if lo == hi { return (lo - 1, hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad, hi + pad)
    }

    /// The area-wash top colour (gradient sampled at 0.7, dimmed). Computed once per body eval instead of
    /// re-sampling the gradient inside the ZStack on every draw.
    private var areaWashColor: Color {
        StrandPalette.sample(stops: gradient.stops, at: 0.7).opacity(0.22)
    }
    /// The head-dot ring colour (gradient sampled at its bright end). Computed once per body eval.
    private var headColor: Color {
        StrandPalette.sample(stops: gradient.stops, at: 1.0)
    }

    public var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                // STATIC LAYER: area wash + gradient line + head dot. Drawn INLINE — NO .drawingGroup().
                // A ~14-point polyline + fill + 2 dots is trivially cheap, and a per-sparkline offscreen
                // flatten costs FAR more (a dedicated MTLTexture + an extra composite pass) than it saves.
                // Today shows ~10-16 tiles at once, so per-tile .drawingGroup() piled up ~16 offscreen
                // passes that re-rasterised on every scroll / body re-eval — the v7.0.2 lag regression.
                // CoreAnimation already caches this flat layer natively.
                ZStack {
                    if showsArea, pts.count > 1 {
                        areaPath(pts, in: geo.size)
                            .fill(
                                LinearGradient(
                                    colors: [areaWashColor, Color.clear],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                    if pts.count > 1 {
                        linePath(pts)
                            .stroke(
                                LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                            )
                    }
                    if showsHead, let head = pts.last {
                        // Design Reset (WHOOP): a crisp solid leading dot, no blurred bloom halo.
                        // The line colour reads as the head ring; a small core sits inside it.
                        Circle().fill(headColor).frame(width: lineWidth * 2.2, height: lineWidth * 2.2)
                            .position(head)
                        Circle().fill(StrandPalette.tipCore).frame(width: lineWidth * 1.0, height: lineWidth * 1.0)
                            .position(head)
                    }
                }

                // Hover affordance: crosshair + highlighted sample + tooltip.
                if showsHover, !values.isEmpty, let hx = hoverX,
                   let idx = ChartHoverMath.nearestIndex(toX: hx, count: values.count, width: geo.size.width),
                   idx < pts.count {
                    let p = pts[idx]
                    let color = sampleColor(forIndex: idx)
                    CrosshairRule(x: p.x, height: geo.size.height)
                    HighlightDot(color: color, diameter: max(7, lineWidth * 3))
                        .position(p)
                    PositionedTooltip(
                        anchor: p,
                        container: geo.size,
                        tooltip: ChartTooltip(
                            value: valueFormat(values[idx]),
                            label: indexLabel?(idx) ?? "sample \(idx + 1)",
                            accent: color
                        )
                    )
                }
            }
            .animation(StrandMotion.fade, value: hoverX)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard showsHover else { return }
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
            // The line is pointer-hover only (dead on touch); give VoiceOver a
            // spoken summary of the series so the trend isn't silent on iPhone.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(axSummary))
        }
    }

    /// A spoken summary of the series for VoiceOver: count + latest/low/high,
    /// formatted via the same `valueFormat` closure so units match the call site.
    private var axSummary: String {
        guard let last = values.last, let lo = values.min(), let hi = values.max() else {
            return String(localized: "No data", bundle: .module)
        }
        return String(localized: "Trend, \(values.count) points, latest \(valueFormat(last)), low \(valueFormat(lo)), high \(valueFormat(hi))", bundle: .module)
    }

    /// The gradient colour at a sample's normalized position along the line.
    private func sampleColor(forIndex idx: Int) -> Color {
        let pos = values.count > 1 ? Double(idx) / Double(values.count - 1) : 1.0
        return StrandPalette.sample(stops: gradient.stops, at: pos)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let (lo, hi) = bounds
        let span = max(hi - lo, 0.0001)
        let n = values.count
        return values.enumerated().map { i, v in
            let x = n > 1 ? CGFloat(i) / CGFloat(n - 1) * size.width : size.width / 2
            let norm = (v - lo) / span
            let y = size.height - CGFloat(norm) * size.height
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        return path
    }

    private func areaPath(_ pts: [CGPoint], in size: CGSize) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.addLine(to: CGPoint(x: first.x, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

#if DEBUG
private func sampleHR() -> [Double] {
    (0..<48).map { i -> Double in
        let wave: Double = 10 * sin(Double(i) / 4.0)
        let jitter: Double = Double((i * 13) % 7)
        return 58 + wave + jitter
    }
}

#Preview("Sparkline") {
    VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("64").font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
            Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Sparkline(
                values: sampleHR(),
                valueFormat: { "\(Int($0.rounded())) bpm" },
                indexLabel: { "\($0)s ago" }
            )
            .frame(width: 160, height: 44)
        }
        Sparkline(values: sampleHR(), gradient: StrandPalette.strainGradient)
            .frame(height: 60)
        Text("Hover any sparkline to read the exact sample under the cursor.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(24)
    .frame(width: 380, height: 240)
    .background(NoopChromeSurface())
    .preferredColorScheme(.dark)
}
#endif
#endif
