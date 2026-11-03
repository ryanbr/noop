import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    // Slate dashboard surfaces. Dark mode is a cool blue-grey slate: the page runs from a lit slate top
    // (`canvasTop`) down to a near-black floor (`canvasBottom`), and cards are flat neutral greys with a
    // thin white rim. Light mode is the same structure on cool paper.
    /// The flat page colour, for surfaces that cannot take a gradient (sheets, sidebars, toolbars). It is
    /// the visual midpoint of `canvasTop` → `canvasBottom`, so a flat panel beside the gradient reads as the
    /// same page.
    public static let canvas = Color(light: "#EEF1F3", dark: "#1F282D")
    /// Top stop of the page gradient (see `NoopCanvasBackground`).
    public static let canvasTop = Color(light: "#F4F6F8", dark: "#283339")
    /// Bottom stop of the page gradient.
    public static let canvasBottom = Color(light: "#E3E8EB", dark: "#101518")
    /// The card fill: a flat neutral grey, with no top-lit ramp.
    public static let surface = Color(light: "#FFFFFF", dark: "#42474C")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#42474C")
    public static let surfaceBottom = Color(light: "#FFFFFF", dark: "#42474C")
    /// Sub-card / inner well: rows, stat cells and control tracks inside a card.
    public static let inset = Color(light: "#E9EDF0", dark: "#2A3137")
    /// The deep track a score ring is drawn over, darker than the page so the arc reads as filling a well.
    public static let ringTrack = Color(light: "#DCE2E6", dark: "#1A2125")

    // Rims are translucent white on dark (8-digit hex is RRGGBBAA), so the same rim reads on the grey
    // card, the inner well and the slate page alike.
    public static let border = Color(light: "#D5DBE0", dark: "#FFFFFF1A")
    public static let borderHighlight = Color(light: "#E4E8EC", dark: "#FFFFFF26")
    public static let divider = Color(light: "#E3E7EA", dark: "#FFFFFF0D")

    public static let primaryText = Color(light: "#101518", dark: "#FFFFFF")
    public static let secondaryText = Color(light: "#3B4650", dark: "#CBD5E1")
    public static let tertiaryText = Color(light: "#6B7280", dark: "#9CA3AF")
    /// Muted section-heading grey (the small ALL-CAPS label above a group of cards).
    public static let sectionText = Color(light: "#6B7280", dark: "#6B7280")
    /// Icon tint for stat-row glyphs (the small icon plate beside a metric).
    public static let iconTint = Color(light: "#3A7A9E", dark: "#4D94BB")
    /// The two ends of the insight-card rim and call-to-action gradient (violet → sky blue).
    public static let insightStart = Color(light: "#7B3AE0", dark: "#9747FF")
    public static let insightEnd = Color(light: "#2B8AE0", dark: "#4DA8FF")

    public static let mint = Color(light: "#149A78", dark: "#69DDB8")
    public static let mintDeep = Color(light: "#0D765C", dark: "#13A982")
    public static let mintGlow = Color(light: "#38C99E", dark: "#54E6BD")

    public static let cardRadius: CGFloat = 14
    public static let compactRadius: CGFloat = 10
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 26
}

/// The page background: a vertical slate gradient from `canvasTop` to `canvasBottom`. Screens place it
/// edge-to-edge (`.ignoresSafeArea()`) behind their scroll content; cards float over it.
public struct NoopCanvasBackground: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [NoopVisualStyle.canvasTop, NoopVisualStyle.canvasBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Shared card/panel treatment: a flat surface and a thin rim, plus a light drop shadow off iOS.
/// `tint` is intentionally faint so metric identity never turns the whole card into a coloured tile.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double
    #if !os(iOS)
    @Environment(\.colorScheme) private var scheme
    #endif

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // A flat neutral card: one solid fill and a thin translucent-white rim. `tint` is accepted for API
        // compatibility but deliberately not drawn: metric identity comes from the coloured number, ring
        // or label inside the card, never from a coloured card.
        let rim = NoopVisualStyle.border
        #if os(iOS)
        // Scrolling stacks contain many panels; blurred shadows multiply their compositing work, so iOS
        // draws the fill and rim only.
        shape
            .fill(NoopVisualStyle.surface)
            .overlay(shape.strokeBorder(rim, lineWidth: 1))
            .opacity(surfaceOpacity)
        #else
        shape
            .fill(NoopVisualStyle.surface)
            .overlay(shape.strokeBorder(elevated ? NoopVisualStyle.borderHighlight : rim, lineWidth: 1))
            .shadow(
                color: .black.opacity(scheme == .dark ? (elevated ? 0.24 : 0.10) : (elevated ? 0.12 : 0.06)),
                radius: elevated ? 12 : 3,
                x: 0,
                y: elevated ? 6 : 2
            )
            .opacity(surfaceOpacity)
        #endif
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline or elevation: it is the top page colour with the shared divider under it.
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        NoopVisualStyle.canvasTop
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(NoopVisualStyle.divider)
                    .frame(height: 0.5)
            }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
