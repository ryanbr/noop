import SwiftUI

/// The data-visualisation colour style: the brand "Titanium & Gold" data ramps, or a "Classic"
/// throwback — the recognizable red → amber → green readiness scale (cool→hot zones, green→red stress,
/// purple REM) that health apps have always used. Works in BOTH light and dark. It only re-colours the
/// DATA encodings (gauge rings, charts, sparklines, scales, stage bands) — never the chrome/surfaces.
///
/// Read globally via `StrandPalette.chartStyle` (set from `@AppStorage(ChartStyle.storageKey)` at the
/// app root); the data-ramp accessors in `StrandPalette` branch on it. The app root keys its content on
/// the raw value so a flip re-renders the visible charts live.
public enum ChartStyle: String, CaseIterable, Identifiable, Sendable {
    case titanium   // brand: gold recovery, amber strain, blue rest
    case classic    // throwback: red→green recovery, cool→hot zones, green→red stress

    public var id: String { rawValue }
    public static let storageKey = "chart.style"

    public var label: String {
        switch self {
        case .titanium: return String(localized: "Default", bundle: .module)
        case .classic:  return String(localized: "Classic", bundle: .module)
        }
    }

    public static func resolve(_ raw: String) -> ChartStyle { ChartStyle(rawValue: raw) ?? .titanium }
}

/// Applies the chart style: sets the global `StrandPalette.chartStyle` (read by the data-ramp
/// accessors) AND keys the content on the raw value so a flip re-renders the visible charts. The
/// global is set during body evaluation, before the keyed content renders, so the new ramps are live
/// on the rebuild. Apply at each app root: `.chartStyle(chartStyleRaw)`.
public extension View {
    func chartStyle(_ raw: String) -> some View {
        StrandPalette.chartStyle = ChartStyle.resolve(raw)
        return self.id("noop.chartStyle.\(raw)")
    }
}

/// The user's CHROME accent colour (buttons, links, focus rings, selected states). Only the chrome
/// accent — never the recovery/strain/sleep DATA colour worlds (those follow `ChartStyle`). Read globally
/// via `StrandPalette.accentChoice` (+ `StrandPalette.customAccentHex` for `.custom`), set from
/// `@AppStorage(AccentColor.storageKey)` / `@AppStorage(AccentColor.customHexKey)` at the app root; the
/// `accent`/`accentHover`/`accentMuted`/`focusRing` accessors in `StrandPalette` branch on it. Mirror in
/// Kotlin via `Palette.accentChoice` + `NoopPrefs.accentColor`/`accentCustomHex`.
public enum AccentColor: String, CaseIterable, Identifiable, Sendable {
    case mint        // the brand default (#1068 NoopVisualStyle.mint world)
    case whoopBlue   // the classic WHOOP link blue
    case custom      // a user-picked colour (hex stored separately)

    public var id: String { rawValue }
    public static let storageKey = "accent.color"
    /// The custom colour's hex, kept separate so switching away from `.custom` and back keeps the choice.
    public static let customHexKey = "accent.customHex"
    /// Seeds the custom picker (mint) so a fresh `.custom` selection is not black.
    public static let defaultCustomHex = "#149A78"

    public var label: String {
        switch self {
        case .mint:      return String(localized: "Mint", bundle: .module)
        case .whoopBlue: return String(localized: "WHOOP Blue", bundle: .module)
        case .custom:    return String(localized: "Custom", bundle: .module)
        }
    }

    public static func resolve(_ raw: String) -> AccentColor { AccentColor(rawValue: raw) ?? .mint }

    /// The chrome accent. `.custom` resolves the stored hex at read time.
    public var accent: Color {
        switch self {
        case .mint:      return NoopVisualStyle.mint
        case .whoopBlue: return Color(light: "#234F9E", dark: "#60A0E0")
        case .custom:    return Color(hex: StrandPalette.customAccentHex)
        }
    }

    /// The brighter hover/pressed accent. For `.custom` it is the chosen colour lightened toward white.
    public var accentHover: Color {
        switch self {
        case .mint:      return NoopVisualStyle.mintGlow
        case .whoopBlue: return Color(light: "#3A6FC0", dark: "#8FBEEC")
        case .custom:    return AccentColor.lighten(StrandPalette.customAccentHex)
        }
    }

    /// A low-opacity tint of the accent for muted fills (chips, selected rows). Translucent so it
    /// composites over whatever surface is behind it — the same 0.18 the mint world uses.
    public var accentMuted: Color {
        switch self {
        case .mint:      return NoopVisualStyle.mintDeep.opacity(0.18)
        case .whoopBlue: return Color(light: "#234F9E", dark: "#60A0E0").opacity(0.18)
        case .custom:    return Color(hex: StrandPalette.customAccentHex).opacity(0.18)
        }
    }

    public var focusRing: Color { accent }

    /// Blend an sRGB hex toward white by `amount` (0…1) — the deterministic "hover" derivation for a
    /// custom accent, so a single picked colour still gets a sensible brighter pressed state.
    static func lighten(_ hex: String, by amount: Double = 0.24) -> Color {
        let c = Color.sRGBComponents(hex: hex)
        func up(_ x: Double) -> Double { min(1, x + (1 - x) * amount) }
        return Color(.sRGB, red: up(c.r), green: up(c.g), blue: up(c.b), opacity: 1)
    }
}

/// Applies the chrome accent: sets `StrandPalette.accentChoice` + `customAccentHex` (read by the accent
/// accessors) and keys the content so a change re-renders live. Apply at each app root:
/// `.noopAccent(accentRaw, customHex: accentCustomHex)`.
public extension View {
    func noopAccent(_ raw: String, customHex: String) -> some View {
        StrandPalette.accentChoice = AccentColor.resolve(raw)
        StrandPalette.customAccentHex = customHex
        return self.id("noop.accent.\(raw).\(customHex)")
    }
}

/// A named THEME preset — a one-tap bundle that coordinates the accent, the chart colour world, the
/// day-cycle backdrop, and the card opacity. Purely an orchestration over settings that already exist:
/// selecting a preset writes those four prefs, and the granular controls stay available underneath. There
/// is NO stored "current theme" — it's DERIVED from the live prefs via [matching], so tweaking any one
/// control simply resolves to `.custom`. Theme MODE (System/Light/Dark) is independent and never bundled.
/// Twin of Kotlin `ThemePreset`.
public enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case mint       // brand default: mint accent, Titanium charts, backdrop on, solid cards
    case ocean      // WHOOP-blue accent, Titanium charts, backdrop on, solid
    case classic    // WHOOP-blue accent, Classic throwback charts, backdrop on, solid
    case midnight   // mint accent, Titanium charts, backdrop OFF (plain canvas), solid
    case frosted    // mint accent, Titanium charts, backdrop on, translucent cards
    case custom     // sentinel: the live combination matches no preset

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mint:     return String(localized: "Mint", bundle: .module)
        case .ocean:    return String(localized: "Ocean", bundle: .module)
        case .classic:  return String(localized: "Classic", bundle: .module)
        case .midnight: return String(localized: "Midnight", bundle: .module)
        case .frosted:  return String(localized: "Frosted", bundle: .module)
        case .custom:   return String(localized: "Custom", bundle: .module)
        }
    }

    /// The four coordinated values a preset writes (nil for `.custom`, which sets nothing). Named `Recipe`
    /// rather than `Bundle` deliberately — `Bundle` would shadow `Foundation.Bundle`, used just above in
    /// `String(localized:bundle:)`.
    public struct Recipe: Sendable {
        public let accent: AccentColor
        public let chart: ChartStyle
        public let backdrop: Bool
        public let cardOpacity: Int
    }

    public var recipe: Recipe? {
        switch self {
        case .mint:     return Recipe(accent: .mint,      chart: .titanium, backdrop: true,  cardOpacity: 100)
        case .ocean:    return Recipe(accent: .whoopBlue, chart: .titanium, backdrop: true,  cardOpacity: 100)
        case .classic:  return Recipe(accent: .whoopBlue, chart: .classic,  backdrop: true,  cardOpacity: 100)
        case .midnight: return Recipe(accent: .mint,      chart: .titanium, backdrop: false, cardOpacity: 100)
        case .frosted:  return Recipe(accent: .mint,      chart: .titanium, backdrop: true,  cardOpacity: 85)
        case .custom:   return nil
        }
    }

    /// The presets a user can pick (everything except the derived `.custom` sentinel).
    public static var selectable: [ThemePreset] { allCases.filter { $0 != .custom } }

    public static func resolve(_ raw: String) -> ThemePreset { ThemePreset(rawValue: raw) ?? .mint }

    /// Which preset the live prefs correspond to, or `.custom` when none match.
    public static func matching(accent: AccentColor, chart: ChartStyle,
                                backdrop: Bool, cardOpacity: Int) -> ThemePreset {
        for p in selectable {
            if let r = p.recipe, r.accent == accent, r.chart == chart,
               r.backdrop == backdrop, r.cardOpacity == cardOpacity {
                return p
            }
        }
        return .custom
    }
}

/// The user's appearance preference for the whole app. Persisted via
/// `@AppStorage(AppearanceMode.storageKey)`. `.system` follows the OS (the default);
/// `.light` / `.dark` force a scheme regardless of the system setting.
///
/// Applied once at each app root via `.preferredColorScheme(mode.colorScheme)`. Because every
/// `StrandPalette` token is a dynamic `Color(light:dark:)`, flipping this re-resolves the entire
/// UI automatically — no per-view plumbing.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// The @AppStorage key shared by the app roots and the Settings picker.
    public static let storageKey = "theme.appearance"

    /// Human label for the Settings control.
    public var label: String {
        switch self {
        case .system: return String(localized: "System", bundle: .module)
        case .light:  return String(localized: "Light", bundle: .module)
        case .dark:   return String(localized: "Dark", bundle: .module)
        }
    }

    /// SF Symbol for the Settings control.
    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.stars"
        }
    }

    /// The `ColorScheme` to force, or `nil` to follow the system (the `.system` case).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Resolve a stored raw value (tolerant of an unknown/missing value → `.system`).
    public static func resolve(_ raw: String) -> AppearanceMode {
        AppearanceMode(rawValue: raw) ?? .system
    }
}

/// The day-cycle scene backdrop behind the Today screen (sunrise / day / dusk / night). Default ON —
/// the scene is the v7 atmosphere. Some people find it distracting and want a plain dark canvas (#698),
/// so this gates whether Today passes a `SceneScreenBackground` into its scaffold. When OFF, Today drops
/// the scene and falls back to the opaque `surfaceBase`; the cards already sit on an opaque canvas, so
/// they stay perfectly readable. Read in `TodayView` via `@AppStorage(SceneBackgroundPrefs.enabledKey)`
/// and toggled from Settings → Appearance. Mirror in Kotlin via `NoopPrefs.showDayCycleBackground`.
public enum SceneBackgroundPrefs {
    /// The @AppStorage key shared by TodayView and the Settings toggle. Default value is `true`.
    public static let enabledKey = "noop.showDayCycleBackground"
}

/// Card-surface opacity as a PERCENT (0 = fully see-through, 100 = solid; default 100). `FrostedCardSurface`
/// reads it via `@AppStorage(CardAppearancePrefs.opacityKey)` and fades the whole glass by it, so cards
/// (Heart Rate, Key Metrics, Recovery Vitals, …) can be made see-through from Settings → Appearance; the
/// card content stays fully readable. Mirror in Kotlin via `NoopPrefs.cardOpacityPercent`.
public enum CardAppearancePrefs {
    public static let opacityKey = "noop.cardOpacityPercent"
    public static let defaultPercent = 100
}

/// "Sky behind cards" (opt-in, default OFF): extend the day-cycle sky behind the WHOLE Today scroll (not
/// just the top band) so the Card-transparency setting reveals it under every card. Read in `LiquidTodayView`
/// via `@AppStorage(SkyBehindCardsPrefs.enabledKey)` and toggled from Settings → Appearance. Mirror in
/// Kotlin via `NoopPrefs.skyBehindCards`.
public enum SkyBehindCardsPrefs {
    public static let enabledKey = "noop.skyBehindCards"
}

// MARK: - Light-idiom helpers

/// An additive glow (ring blooms, sparkline heads, hero halos) only reads on a DARK canvas —
/// `.plusLighter` blending on white produces no visible glow and just muddies edges. On dark this
/// applies the additive blend; on light it hides the layer. Self-contained (reads the scheme itself)
/// so every glow becomes a one-token swap from `.blendMode(.plusLighter)` → `.additiveBloom()`.
private struct AdditiveBloom: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        // Dialed back (0.55) — the full-strength additive bloom read as too much glow against the
        // crisper design language. Still present on dark for depth, just restrained.
        if scheme == .dark { content.blendMode(.plusLighter).opacity(0.55) }
        else { content.opacity(0) }
    }
}

/// Card / floating-surface elevation. Dark separates surfaces by a lighter FILL (no resting shadow);
/// light separates white-on-paper by a soft DROP SHADOW. Reads the scheme itself and deepens on hover.
private struct NoopElevation: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var hovering: Bool
    func body(content: Content) -> some View {
        let lightShadow = Color(hex: "#1A2230")
        return content.shadow(
            color: scheme == .light ? lightShadow.opacity(hovering ? 0.16 : 0.09)
                                    : Color.black.opacity(hovering ? 0.45 : 0.0),
            radius: scheme == .light ? (hovering ? 14 : 10) : (hovering ? 18 : 0),
            x: 0, y: scheme == .light ? (hovering ? 5 : 3) : (hovering ? 8 : 0)
        )
    }
}

public extension View {
    /// Apply the additive glow only on dark; hide it on light. See `AdditiveBloom`.
    func additiveBloom() -> some View { modifier(AdditiveBloom()) }

    /// Apply the per-scheme card/surface elevation (shadow on light, lighter-fill idiom on dark).
    func noopElevation(hovering: Bool = false) -> some View { modifier(NoopElevation(hovering: hovering)) }
}
