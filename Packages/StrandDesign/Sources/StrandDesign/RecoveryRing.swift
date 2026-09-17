import SwiftUI

// MARK: - Recovery Ring (§9.3) — THE signature component
//
// watchOS NOTE: the `RecoveryRing` view (below) uses .onContinuousHover + BevelGauge + ChartHover
// tooltips, none of which exist on watchOS, so the VIEW is excluded there (the watch uses the
// lightweight GlowRing instead). The pure `RecoveryArc` Shape at the bottom of this file stays
// available on ALL platforms because the watch-safe BevelGauge / BrandMark depend on it.

#if !os(watchOS)
public struct RecoveryRing: View {

    public var score: Double
    public var supporting: String?
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var showsLabel: Bool
    public var showsWordmark: Bool
    public var showsHover: Bool
    public var valueFormat: (Double) -> String

    public init(
        score: Double,
        supporting: String? = nil,
        diameter: CGFloat = 240,
        lineWidth: CGFloat = 14,
        showsLabel: Bool = true,
        showsWordmark: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" }
    ) {
        self.score = score
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.showsWordmark = showsWordmark
        self.showsHover = showsHover
        self.valueFormat = valueFormat
    }

    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var animatedFraction: Double = 0
    @State private var bloomPulse: Bool = false

    private var fraction: Double { min(max(score / 100.0, 0), 1) }
    
    // Zone color: 67-100 green, 34-66 yellow, 0-33 red
    private var tipColor: Color {
        switch score {
        case 67...:
            return .green
        case 34..<67:
            return .yellow
        default:
            return .red
        }
    }

    private var stateWord: String { StrandPalette.recoveryState(score) }
    
    private var ringStops: [Gradient.Stop] {
        let color = tipColor
        return [
            .init(color: color.opacity(0.85), location: 0.0),
            .init(color: color, location: 1.0)
        ]
    }

    public var body: some View {
        ZStack {
            BevelGauge(
                fraction: fraction,
                stops: ringStops, // Uses dynamic stops based on recovery zones
                tipColor: tipColor,
                numberText: numberString,
                captionText: showsLabel ? "of 100" : nil,
                stateText: showsLabel ? stateWord : nil,
                supporting: supporting,
                diameter: diameter,
                lineWidth: lineWidth,
                showsLabel: showsLabel,
                animatedFraction: animatedFraction,
                bloomActive: bloomPulse
            )
            coreDot
            if showsLabel && showsWordmark { wordmark }
            if showsHover, let pt = hoverPoint {
                PositionedTooltip(
                    anchor: pt,
                    container: CGSize(width: diameter, height: diameter),
                    tooltip: ChartTooltip(
                        value: valueFormat(score),
                        label: stateWord,
                        accent: tipColor
                    )
                )
                .animation(StrandMotion.fade, value: hoverPoint == nil)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(valueFormat(score)))
        .accessibilityValue(Text(stateWord))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard showsHover else { return }
            switch phase {
            case .active(let location): hoverPoint = location
            case .ended: hoverPoint = nil
            }
        }
        .onAppear {
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
            if !reduceMotion { bloomPulse = true }
        }
        .onChangeCompat(of: score) { _ in
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
        }
    }

    private var numberString: String {
        String(Int(score.rounded()))
    }

    private var wordmark: some View {
        let size = diameter * 0.052
        return Text("NOOP")
            .font(StrandFont.rounded(size, weight: .bold))
            .tracking(size * 0.34)
            .foregroundStyle(StrandPalette.textTertiary)
            .offset(y: -diameter * 0.205)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var coreDot: some View {
        Circle()
            .fill(StrandPalette.accent)
            .frame(width: diameter * 0.026, height: diameter * 0.026)
            .opacity(showsLabel ? 0.0 : 1.0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif

// MARK: - Arc Shape

public struct RecoveryArc: Shape {
    public var startAngle: Angle
    public var spanDegrees: Double
    public var fraction: Double
    public var lineWidth: CGFloat

    public var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    public func path(in rect: CGRect) -> Path {
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let end = Angle.degrees(startAngle.degrees + spanDegrees * min(max(fraction, 0), 1))
        var path = Path()
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: end,
            clockwise: false
        )
        return path
    }
}

#if DEBUG && !os(watchOS)
#Preview("RecoveryRing — scores") {
    VStack(spacing: 16) {
        HStack(spacing: 28) {
            RecoveryRing(score: 22, supporting: "HRV 38ms · RHR 58 · take it easy", diameter: 220)
            RecoveryRing(score: 55, supporting: "HRV 49ms · RHR 54 · moderate ok", diameter: 220)
        }
        Text("Hover a ring for a recovery + state-word tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("RecoveryRing — primed/peak") {
    HStack(spacing: 28) {
        RecoveryRing(score: 78, supporting: "HRV 62ms · RHR 51 · ready for moderate strain", diameter: 220)
        RecoveryRing(score: 91, supporting: "HRV 74ms · RHR 47 · primed to push", diameter: 220)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

private struct RecoveryRingLive: View {
    @State private var score: Double = 64
    var body: some View {
        VStack(spacing: 24) {
            RecoveryRing(score: score, supporting: "drag to feel the draw-in", diameter: 260)
            Slider(value: $score, in: 0...100)
                .frame(width: 280)
        }
        .padding(40)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("RecoveryRing — interactive") { RecoveryRingLive() }
#endif
