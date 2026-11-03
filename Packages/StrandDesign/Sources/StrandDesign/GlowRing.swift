import SwiftUI

// MARK: - GlowRing — crisp dashboard score ring
//
// Quality here is CRISPNESS, not blur. A solid arc with rounded caps, lightly graded from 85% to full
// opacity of its colour, over a deep full-circle track (`NoopVisualStyle.ringTrack`, darker than the
// page), so the ring reads as "X% of a circle". A bold condensed centred number counts up, with an
// optional smaller unit beside it ("87%"). No glow. The arc springs in from 12 o'clock and re-animates
// when the value changes (day nav). Theme-aware. Motion gated on Reduce Motion; macOS-13 / iOS-17 safe.

public struct GlowRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre — rolls up to this.
    public var value: Double
    /// Formats the (animated) value into the centre string.
    public var format: (Double) -> String
    /// The arc colour (solid, saturated — the domain accent).
    public var color: Color
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    /// An optional unit drawn after the number at a smaller size (e.g. "%"). nil draws the number alone.
    public var unit: String?

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String,
                color: Color, diameter: CGFloat, lineWidth: CGFloat, unit: String? = nil) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.unit = unit
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// The centre-number font for a ring of the given diameter — the house numeral at `diameter * 0.36`,
    /// bold. Exposed so an EMPTY / carried / "No data" ring (which doesn't draw a `GlowRing`) can render
    /// its centre text in the EXACT same size + weight as a filled ring, keeping the hero trio's three
    /// centre read-outs visually consistent regardless of state.
    public static func centerFont(diameter: CGFloat) -> Font {
        StrandFont.rounded(diameter * 0.36, weight: .bold)
    }

    /// The unit font beside the centre number: about half the number's size, same face.
    public static func unitFont(diameter: CGFloat) -> Font {
        StrandFont.rounded(diameter * 0.18, weight: .bold)
    }

    private var clamped: CGFloat { CGFloat(min(max(fraction, 0), 1)) }
    private var filled: CGFloat { appeared ? clamped : 0 }
    private var shown: Double { appeared ? value : 0 }
    private var drawSpring: Animation { .spring(response: 0.9, dampingFraction: 0.86) }

    public var body: some View {
        ZStack {
            // Deep full-circle track, so the arc reads as a fraction of a circle.
            Circle()
                .stroke(NoopVisualStyle.ringTrack,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // NO glow. A flat solid arc, graded 85% → 100% of its colour across the ring.
            arc.stroke(
                LinearGradient(colors: [color.opacity(0.85), color], startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )

            // Centred rolling number, with the optional smaller unit sharing its baseline.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(format(shown))
                    .font(Self.centerFont(diameter: diameter))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(Self.unitFont(diameter: diameter))
                }
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, lineWidth + 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.85), value: shown)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : drawSpring, value: filled)
        .onAppear { appeared = true }
    }

    /// The trimmed arc, drawn from 12 o'clock clockwise.
    private var arc: some Shape {
        Circle().trim(from: 0, to: max(0.0001, filled)).rotation(.degrees(-90))
    }
}
