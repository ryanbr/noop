import SwiftUI

// MARK: - Strain Gauge (§9.1 strain ramp)
//
// Ember → magenta gauge for the 0–21 Whoop strain scale. Same open-gauge
// instrument language as the Recovery Ring, but warm (output / heat) instead of
// the cool recovery scale. Filled to strain/21 of a 240° arc, with a soft bloom
// and a leading bead at the tip.

public struct StrainGauge: View {

    /// Strain value on the 0...21 scale.
    public var strain: Double
    /// Optional supporting line, e.g. "moderate cardiovascular load".
    public var supporting: String?
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var showsLabel: Bool
    /// Whether hovering the gauge shows a subtle tooltip (strain + state word).
    public var showsHover: Bool
    /// Formats the strain value for the hover tooltip's bold line.
    public var valueFormat: (Double) -> String

    public init(
        strain: Double,
        supporting: String? = nil,
        diameter: CGFloat = 200,
        lineWidth: CGFloat = 14,
        showsLabel: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { String(format: "Strain %.1f", $0) }
    ) {
        self.strain = strain
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.showsHover = showsHover
        self.valueFormat = valueFormat
    }

    /// Cursor location while hovering, in gauge-local coordinates.
    @State private var hoverPoint: CGPoint? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A short load word for the strain value, mirroring the recovery state idea.
    private var strainWord: String {
        switch strain {
        case ..<6:   return "LIGHT"
        case ..<10:  return "MODERATE"
        case ..<14:  return "STRENUOUS"
        case ..<18:  return "HIGH"
        default:     return "ALL-OUT"
        }
    }

    // The 240° open-gauge geometry + bloom now live in the shared `BevelGauge`.
    @State private var animatedFraction: Double = 0
    @State private var bloomPulse = false

    private var fraction: Double { min(max(strain / 21.0, 0), 1) }
    private var tipColor: Color { StrandPalette.strainColor(strain) }

    public var body: some View {
        ZStack {
            BevelGauge(
                fraction: fraction,
                stops: StrandPalette.strainStops,
                tipColor: tipColor,
                numberText: strainString,
                captionText: showsLabel ? "of 21" : nil,
                stateText: showsLabel ? strainWord : nil,
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
                        value: valueFormat(strain),
                        label: strainWord,
                        accent: tipColor
                    )
                )
                .animation(StrandMotion.fade, value: hoverPoint == nil)
            }
        }
        .frame(width: diameter, height: diameter)
        // Collapse the loose center Text fragments into one coherent VoiceOver element.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(valueFormat(strain)))
        .accessibilityValue(Text(strainWord))
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
        .onChange(of: strain) { _ in
            withAnimation(StrandMotion.drawIn) { animatedFraction = fraction }
        }
    }

    private var strainString: String {
        String(format: "%.1f", strain)
    }
}

#if DEBUG
#Preview("StrainGauge") {
    VStack(spacing: 16) {
        HStack(spacing: 28) {
            StrainGauge(strain: 4.2, supporting: "light day", diameter: 190)
            StrainGauge(strain: 11.5, supporting: "moderate load", diameter: 190)
            StrainGauge(strain: 18.7, supporting: "all-out effort", diameter: 190)
        }
        Text("Hover a gauge for a strain + load-word tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
