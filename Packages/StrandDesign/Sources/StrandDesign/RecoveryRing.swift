import SwiftUI

// MARK: - Recovery Ring (§9.3) — THE signature component
//
// A 240° open gauge arc (gap at the bottom), thick rounded-cap stroke filled
// with an AngularGradient sampling the recovery gradient (indigo → mint), filled
// to score/100 of the 240° span over a faint track. A soft outer BLOOM whose
// intensity scales with score; a luminous leading bead at the fill tip; a draw-in
// animation when the value changes. Center shows the big monospaced number (no %),
// a state word tinted to the sampled color, and an optional supporting line.

public struct RecoveryRing: View {

    /// Recovery score 0...100.
    public var score: Double
    /// Optional supporting line, e.g. "HRV 62ms · RHR 51 · ready for moderate strain".
    public var supporting: String?
    /// Diameter of the ring.
    public var diameter: CGFloat
    /// Stroke thickness (14–18pt per spec).
    public var lineWidth: CGFloat
    /// Whether to show the center read-out (number + state + supporting).
    public var showsLabel: Bool
    /// Whether hovering the ring shows a subtle tooltip (score + state word).
    public var showsHover: Bool
    /// Formats the score for the hover tooltip's bold line.
    public var valueFormat: (Double) -> String

    public init(
        score: Double,
        supporting: String? = nil,
        diameter: CGFloat = 240,
        lineWidth: CGFloat = 16,
        showsLabel: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" }
    ) {
        self.score = score
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.showsHover = showsHover
        self.valueFormat = valueFormat
    }

    /// Cursor location while hovering, in ring-local coordinates.
    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Animated fill fraction so changing `score` draws the arc in. The 240° open-gauge
    // geometry + bloom now live in the shared `BevelGauge` this delegates to.
    @State private var animatedFraction: Double = 0
    @State private var bloomPulse: Bool = false

    private var fraction: Double { min(max(score / 100.0, 0), 1) }
    private var tipColor: Color { StrandPalette.recoveryColor(score) }
    private var stateWord: String { StrandPalette.recoveryState(score) }

    public var body: some View {
        ZStack {
            BevelGauge(
                fraction: fraction,
                stops: StrandPalette.recoveryStops,
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
        // Collapse the loose center Text fragments (and the otherwise-unlabeled
        // standalone ring) into one coherent VoiceOver element.
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
            withAnimation(StrandMotion.drawIn) { animatedFraction = fraction }
            // Reduce Motion: leave the bloom at its resting opacity instead of breathing.
            if !reduceMotion { bloomPulse = true }
        }
        .onChange(of: score) { _ in
            withAnimation(StrandMotion.drawIn) { animatedFraction = fraction }
        }
    }

    private var numberString: String {
        String(Int(score.rounded()))
    }
}

// MARK: - Arc Shape

/// An open 240° gauge arc that fills clockwise from the start angle.
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

#if DEBUG
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
