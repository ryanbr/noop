import SwiftUI

// MARK: - Recovery Ring (§9.3) — THE signature component
//
// watchOS NOTE: the `RecoveryRing` view (below) uses .onContinuousHover + BevelGauge + ChartHover
// tooltips, none of which exist on watchOS, so the VIEW is excluded there (the watch uses the
// lightweight GlowRing instead). The pure `RecoveryArc` Shape at the bottom of this file stays
// available on ALL platforms because the watch-safe BevelGauge / BrandMark depend on it.
//
// A full-circle score ring: a rounded-cap stroke in the score's band colour
// (`StrandPalette.recoveryColor`: red / yellow / green), filled clockwise from 12 o'clock to
// score/100 over the deep `ringTrack` well. NO outer bloom, no tip bead; a draw-in animation
// when the value changes. Center shows the
// big rounded-700 number (no %), a state word tinted to the sampled color, and an
// optional supporting line.
//
// This is also the app's BRAND GLYPH: an open ~80% ring + a SOLID ACCENT CORE DOT
// ("on-device core"). The recovery ring uniquely carries a micro "NOOP" wordmark
// above the number (letter-spacing ≈ .34em, tertiary) so the lock-up reads as the
// "O" in NOOP. The arc geometry, gradient stroke, track and centre number live in
// the shared `BevelGauge`; this view layers the wordmark + core dot on top.

#if !os(watchOS)
public struct RecoveryRing: View {

    /// Recovery score 0...100.
    public var score: Double
    /// Optional supporting line, e.g. "HRV 62ms · RHR 51 · ready for moderate strain".
    public var supporting: String?
    /// Diameter of the ring.
    public var diameter: CGFloat
    /// Stroke thickness — hero 13–14pt per the Titanium & Gold spec (§4).
    public var lineWidth: CGFloat
    /// Whether to show the center read-out (number + state + supporting).
    public var showsLabel: Bool
    /// Whether to draw the micro "NOOP" wordmark above the number. Turn it OFF for compact rings
    /// (e.g. a three-up hero row) where the number is large relative to the ring and the wordmark
    /// would crowd it.
    public var showsWordmark: Bool
    /// Whether hovering the ring shows a subtle tooltip (score + state word).
    public var showsHover: Bool
    /// Formats the score for the hover tooltip's bold line.
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

    /// Cursor location while hovering, in ring-local coordinates.
    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Animated fill fraction so changing `score` draws the arc in. The ring
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
            // Brand layers over the shared gauge: the solid gold CORE DOT (so the
            // open-ring + core-dot lock-up reads), then the micro "NOOP" wordmark
            // sitting just ABOVE the centre number.
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
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
            // Reduce Motion: leave the bloom at its resting opacity instead of breathing.
            if !reduceMotion { bloomPulse = true }
        }
        .onChangeCompat(of: score) { _ in
            withAnimation(StrandMotion.drawIn(reduced: reduceMotion)) { animatedFraction = fraction }
        }
    }

    private var numberString: String {
        String(Int(score.rounded()))
    }

    // MARK: Brand layers

    /// Micro "NOOP" wordmark above the number — the recovery ring carries the
    /// lock-up so its centre reads as the "O" in NOOP. ALL-CAPS, tertiary,
    /// letter-spacing ≈ .34em (× the cap height per the spec). Nudged up so it
    /// sits clear above BevelGauge's centred number.
    private var wordmark: some View {
        let size = diameter * 0.052
        return Text("NOOP")
            .font(StrandFont.rounded(size, weight: .bold))
            .tracking(size * 0.34)                 // ≈ .34em
            .foregroundStyle(StrandPalette.textTertiary)
            .offset(y: -diameter * 0.205)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The brand "on-device core" — a small solid ACCENT dot at the exact centre (WHOOP: blue, no
    /// gold). It belongs to the glyph-only brand lock-up (logo / nav / onboarding), where it reads as
    /// the core of the open ring. On a METRIC gauge the centre is occupied by the read-out number, and
    /// a dot sitting behind the digits just muddies them (community feedback at the v3 launch), so it
    /// is hidden whenever a number is shown — leaving a clean ring + number + micro-NOOP wordmark.
    private var coreDot: some View {
        Circle()
            .fill(StrandPalette.accent)
            .frame(width: diameter * 0.026, height: diameter * 0.026)
            .opacity(showsLabel ? 0.0 : 1.0)       // hidden under the number; full when glyph-only
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif

// MARK: - Arc Shape

/// A gauge arc spanning `spanDegrees` (240° for the open brand glyph, 360° for a score ring) that
/// fills clockwise from the start angle.
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
