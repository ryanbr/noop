import SwiftUI

// MARK: - Frosted card surface (Titanium & Gold) + StrandCard
//
// The card surface: a flat `surfaceRaised` fill, continuous rounded corners and a
// single 1px `hairline` border — NO shadow (the Titanium look reads off the hairline
// + tint, not a drop shadow). The TINTED variant deepens into a navy bevel
// (150° #15243C → #0B1424) under a faint per-domain hue wash + a hue-biased border.
// `.frostedCardSurface(tint:…)` is the one place the look lives so StrandCard /
// NoopCard / ad-hoc surfaces all share it. Pass a domain tint (or nil for the neutral
// flat raised surface).

public extension View {
    /// Apply the frosted-card surface as a background. `tint` colours the diagonal
    /// wash + border bias; nil uses the flat raised surface with no wash.
    func frostedCardSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = 22,
        washStrength: Double = 1.0
    ) -> some View {
        background(FrostedCardSurface(tint: tint, cornerRadius: cornerRadius, washStrength: washStrength))
    }
}

/// The frosted-card background fill and border. Standalone so it can be a
/// `.background { }` (animation never reaches the card's content subtree — #104).
/// No drop shadow — the Titanium surface reads off the hairline + tint alone.
public struct FrostedCardSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var washStrength: Double
    // "Card transparency" setting (reactive): fades the whole glass surface toward the background. 100 =
    // solid (default). Reading it here makes every card update live when the Settings slider moves.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent

    public init(tint: Color? = nil, cornerRadius: CGFloat = 22, washStrength: Double = 1.0) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.washStrength = washStrength
    }

    public var body: some View {
        let op = max(0.0, min(1.0, Double(cardOpacityPercent) / 100.0))
        NoopPanelSurface(
            tint: tint?.opacity(washStrength),
            cornerRadius: cornerRadius,
            elevated: false,
            surfaceOpacity: op
        )
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
        cornerRadius: CGFloat = 22,
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
    @Environment(\.colorScheme) private var scheme

    public init(cornerRadius: CGFloat = 22) {
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
            // Incremental hover lift on top of the surface's resting elevation: a warm soft shadow on
            // light (the white card lifts off the paper), the signature black on dark.
            .shadow(
                color: hovering ? (scheme == .light ? Color(hex: "#1A2230").opacity(0.16)
                                                     : Color.black.opacity(0.45)) : .clear,
                radius: hovering ? (scheme == .light ? 14 : 16) : 0,
                x: 0,
                y: hovering ? (scheme == .light ? 6 : 10) : 0
            )
            .offset(y: hovering ? -1 : 0)
            .animation(StrandMotion.interactive, value: hovering)
            // .onHover is unavailable on watchOS (no pointer); the watch never hovers a card.
            #if !os(watchOS)
            .onHover { hovering = $0 }
            #endif
    }
}

public extension View {
    /// Apply the Strand card hover lift (shadow + -1px translate + border emphasis).
    func strandCardHover(cornerRadius: CGFloat = 22) -> some View {
        modifier(StrandCardHover(cornerRadius: cornerRadius))
    }
}

// MARK: - Touch press feedback (iOS) — the hover lift's touch analogue.
//
// `.onHover` never fires on a touchscreen, so tappable cards/rows feel dead on iPhone.
// This gives a subtle press-DOWN state (scale + edge emphasis) for direct manipulation,
// honouring Reduce Motion (which swaps the transform for a gentle dim). It's additive to
// the hover lift: hover (pointer NEAR) and pressed (finger/click DOWN) animate distinct
// properties on the shared StrandMotion.interactive spring, so they compose without a
// double-bounce. Exposed two ways — a ButtonStyle for Button/NavigationLink-as-card (the
// `.plain` replacement), and a `.strandPressable()` modifier for `.onTapGesture`-driven cards.

/// Drop-in replacement for `.buttonStyle(.plain)` on full-card Buttons / NavigationLinks:
/// a subtle press-down scale + hairline-strong edge.
public struct StrandPressableButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Backs `.strandPressable()` — a press-down state for cards driven by `.onTapGesture`
/// (no Button). A 0-distance drag tracks the finger; @GestureState auto-resets on release
/// or when a parent scroll claims the gesture.
public struct StrandPressableModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressed = false

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
    }
}

public extension View {
    /// Subtle touch press-down feedback for a tappable card/row that uses `.onTapGesture`
    /// (not a Button). For Buttons/NavigationLinks, use `StrandPressableButtonStyle` instead.
    func strandPressable(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) -> some View {
        modifier(StrandPressableModifier(cornerRadius: cornerRadius, scale: scale))
    }
}

#if DEBUG && !os(watchOS)
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
