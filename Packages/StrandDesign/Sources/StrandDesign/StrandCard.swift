import SwiftUI

// MARK: - Frosted card surface (NEW — Bevel) + StrandCard
//
// The Bevel card surface: a dark blue-black fill (cardFillTop → cardFillBottom),
// continuous rounded corners, a subtle DIAGONAL accent-gradient wash, a hairline
// rgba(255,255,255,0.06) border and a soft shadow. `.frostedCardSurface(tint:…)`
// is the one place the look lives so StrandCard / NoopCard / ad-hoc surfaces all
// share it. Pass a domain tint (or nil for the neutral brand-green wash).

public extension View {
    /// Apply the Bevel frosted-card surface as a background. `tint` colours the
    /// diagonal wash + border bias; nil uses a near-neutral brand wash.
    func frostedCardSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = 18,
        washStrength: Double = 1.0
    ) -> some View {
        background(FrostedCardSurface(tint: tint, cornerRadius: cornerRadius, washStrength: washStrength))
    }
}

/// The frosted-card background fill, border and shadow. Standalone so it can be a
/// `.background { }` (animation never reaches the card's content subtree — #104).
public struct FrostedCardSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var washStrength: Double

    public init(tint: Color? = nil, cornerRadius: CGFloat = 18, washStrength: Double = 1.0) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.washStrength = washStrength
    }

    private var washColor: Color { tint ?? StrandPalette.accent }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [StrandPalette.cardFillTop, StrandPalette.cardFillBottom],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                // The subtle diagonal accent wash over the dark fill.
                shape.fill(
                    LinearGradient(
                        colors: [
                            washColor.opacity(0.10 * washStrength),
                            washColor.opacity(0.03 * washStrength),
                            .clear
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            StrandPalette.hairline.opacity(0.9),
                            washColor.opacity(0.10)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
    }
}

// MARK: - StrandCard (§9.4 Cards)
//
// The card container — now the Bevel frosted surface, but the PUBLIC API is
// unchanged (padding, cornerRadius, content). Adds an optional `tint` (defaulted)
// so callers can opt into a domain wash without breaking existing call sites.
// Keeps the mandated hover lift via `.strandCardHover()`.

public struct StrandCard<Content: View>: View {

    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var tint: Color?
    @ViewBuilder public var content: () -> Content

    public init(
        padding: CGFloat = 16,
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(tint: tint, cornerRadius: cornerRadius)
            .strandCardHover(cornerRadius: cornerRadius)
    }
}

// MARK: - Hover lift modifier

/// The mandated hover behavior: shadow-md + translateY(-1px) and a hairline →
/// hairline.strong border on hover. Apply to any card-like surface.
public struct StrandCardHover: ViewModifier {
    public var cornerRadius: CGFloat
    @State private var hovering = false

    public init(cornerRadius: CGFloat = 18) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            // Hover emphasis: brighten the hairline edge (the frosted surface owns the
            // resting border) and add the mandated lift (shadow + translateY(-1px)).
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(hovering ? 1 : 0)
            )
            .shadow(
                color: Color.black.opacity(hovering ? 0.45 : 0.0),
                radius: hovering ? 16 : 0,
                x: 0,
                y: hovering ? 10 : 0
            )
            .offset(y: hovering ? -1 : 0)
            .animation(StrandMotion.interactive, value: hovering)
            .onHover { hovering = $0 }
    }
}

public extension View {
    /// Apply the Strand card hover lift (shadow + -1px translate + border emphasis).
    func strandCardHover(cornerRadius: CGFloat = 16) -> some View {
        modifier(StrandCardHover(cornerRadius: cornerRadius))
    }
}

#if DEBUG
#Preview("StrandCard") {
    VStack(spacing: 16) {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sleep performance").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("87").font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
                    Text("%").font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
                }
                Text("7h 42m asleep · 92% efficiency")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        StrandCard {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resting HR").strandOverline()
                    Text("51 bpm").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                Sparkline(values: (0..<30).map { i -> Double in 50 + 4 * sin(Double(i) / 5) })
                    .frame(width: 120, height: 40)
            }
        }
        Text("Hover the cards to see the lift.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(28)
    .frame(width: 420, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
