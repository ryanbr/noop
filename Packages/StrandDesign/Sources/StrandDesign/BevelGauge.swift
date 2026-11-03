import SwiftUI

// MARK: - BevelGauge (NEW) — the layered ring gauge primitive
//
// The shared instrument behind RecoveryRing and StrainGauge: a full-circle score ring with
//   • a deep full-circle track (`NoopVisualStyle.ringTrack`, darker than the page — the "well")
//   • a SOLID progress arc in the value's colour (`tipColor`), lightly graded from 85% to full opacity,
//     drawn clockwise from 12 o'clock with rounded caps
//   • NO inner disc, NO end-cap bead, NO outer bloom — a flat dashboard ring
//   • a centred SF Pro condensed bold number with an "of N" caption + state word
//
// `stops` is still accepted (callers pass their domain ramp) but the arc is one colour, the colour of
// the value, so the ring, the state word and every other read-out of the score agree.
//
// It owns no domain logic — callers pass the fraction, the stroke gradient, the tip
// colour, and the centre read-out strings. RecoveryRing / StrainGauge keep their own
// public init signatures and delegate their visuals here, so every screen re-skins
// without any call-site change.

public struct BevelGauge: View {

    /// Fill fraction 0...1 of the 240° span.
    public var fraction: Double
    /// Angular gradient stops for the progress arc (the domain ramp).
    public var stops: [Gradient.Stop]
    /// Colour of the glowing end-cap + state word (usually the ramp sampled at `fraction`).
    public var tipColor: Color
    /// Big centred number, already formatted (e.g. "87" or "12.4").
    public var numberText: String
    /// Small caption under the number (e.g. "of 100" / "of 21"). nil hides it.
    public var captionText: String?
    /// State word above/below the number (e.g. "PRIMED"). nil hides it.
    public var stateText: String?
    /// Optional supporting line under the read-out.
    public var supporting: String?
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var showsLabel: Bool
    /// Animated draw-in fraction supplied by the caller (so it owns the @State + animation).
    public var animatedFraction: Double
    /// Whether the bloom is at full (vs resting) intensity — caller drives the breathe pulse.
    public var bloomActive: Bool

    public init(
        fraction: Double,
        stops: [Gradient.Stop],
        tipColor: Color,
        numberText: String,
        captionText: String? = nil,
        stateText: String? = nil,
        supporting: String? = nil,
        diameter: CGFloat = 200,
        lineWidth: CGFloat = 16,
        showsLabel: Bool = true,
        animatedFraction: Double,
        bloomActive: Bool = true
    ) {
        self.fraction = fraction
        self.stops = stops
        self.tipColor = tipColor
        self.numberText = numberText
        self.captionText = captionText
        self.stateText = stateText
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.animatedFraction = animatedFraction
        self.bloomActive = bloomActive
    }

    private let arcSpanDegrees: Double = 360
    private var startAngle: Angle { .degrees(-90) }

    public var body: some View {
        ZStack {
            // STATIC BACKDROP: the full-circle track. It does not depend on
            // `animatedFraction`, so SwiftUI/CoreAnimation already caches it as an unchanged layer and
            // does NOT re-render it when only the arc animates. No .drawingGroup() — a per-instance
            // offscreen flatten cost more than it saved (it was part of the v7.0.2 lag regression).
            staticBackdrop
                .frame(width: diameter, height: diameter)

            // LIVE LAYER: the progress arc, kept OUTSIDE the drawingGroup so the
            // shape's `animatableData` still animates smoothly (a drawingGroup would freeze it).
            animatedArc

            if showsLabel { centerLabel }
        }
        .frame(width: diameter, height: diameter)
    }

    /// The non-animating backdrop: the deep full-circle track "well" the score arc fills.
    private var staticBackdrop: some View {
        arcShape(to: 1.0)
            .stroke(NoopVisualStyle.ringTrack,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    /// The live layer: the filled arc in the value's colour (driven by animatedFraction).
    ///
    /// NO outer bloom and no end-cap bead: the colour against the dark track carries the arc edge.
    /// `bloomActive` stays in the signature (callers still pass it) but no longer renders.
    private var animatedArc: some View {
        arcShape(to: animatedFraction)
            .stroke(
                LinearGradient(colors: [tipColor.opacity(0.85), tipColor],
                               startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .opacity(animatedFraction > 0.001 ? 1 : 0)
    }

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text(numberText)
                .font(StrandFont.rounded(diameter * 0.30, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
            if let captionText {
                Text(captionText)
                    .font(StrandFont.rounded(diameter * 0.085, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let stateText {
                // Scale the state word WITH the gauge, like the number (0.30·d) and caption (0.085·d).
                // `min(11, …)` pins it to the original 11pt overline on the large solo-hero rings (≥130pt)
                // — byte-identical there — and shrinks it on the small three-up rings, where a fixed 11pt
                // word overflowed the arc and collided with the number/caption. Uses a *scaled overline*
                // (not rounded()) so Dynamic-Type text-scaling is preserved. Thanks @claypilat (#403).
                let stateSize = min(11, diameter * 0.085)
                Text(stateText)
                    .font(StrandFont.overlineScaled(stateSize))
                    .tracking(StrandFont.overlineTracking * stateSize / 11)
                    .foregroundStyle(tipColor)
                    .padding(.top, 2)
            }
            if let supporting {
                Text(supporting)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: diameter * 0.78)
                    .padding(.top, 2)
            }
        }
    }

    private func arcShape(to fraction: Double) -> RecoveryArc {
        RecoveryArc(startAngle: startAngle, spanDegrees: arcSpanDegrees,
                    fraction: fraction, lineWidth: lineWidth)
    }
}

#if DEBUG
#Preview("BevelGauge") {
    HStack(spacing: 24) {
        BevelGauge(
            fraction: 0.78, stops: StrandPalette.recoveryStops,
            tipColor: StrandPalette.recoveryColor(78), numberText: "78",
            captionText: "of 100", stateText: "PRIMED",
            diameter: 200, animatedFraction: 0.78
        )
        BevelGauge(
            fraction: 0.55, stops: StrandPalette.strainStops,
            tipColor: StrandPalette.strainColor(55), numberText: "11.6",
            captionText: "of 21", stateText: "MODERATE",
            diameter: 200, animatedFraction: 0.55
        )
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
