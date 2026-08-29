import SwiftUI

// MARK: - Hex Color Helper

public extension Color {
    /// Parse a hex string ("#0B0D12" / "0B0D12" RGB, or "#AARRGGBB"/"RRGGBBAA" RGBA) to sRGB
    /// components in 0...1. Shared by `Color(hex:)` and the dynamic `Color(light:dark:)` provider.
    static func sRGBComponents(hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        switch raw.count {
        case 8: // RRGGBBAA
            return (Double((int >> 24) & 0xFF) / 255.0, Double((int >> 16) & 0xFF) / 255.0,
                    Double((int >> 8) & 0xFF) / 255.0, Double(int & 0xFF) / 255.0)
        default: // RRGGBB (6) and any fallback
            return (Double((int >> 16) & 0xFF) / 255.0, Double((int >> 8) & 0xFF) / 255.0,
                    Double(int & 0xFF) / 255.0, 1.0)
        }
    }

    /// Create a Color from a hex string like "#0B0D12" or "0B0D12" (RGB) or "#AARRGGBB" / "RRGGBBAA".
    /// Supported lengths: 6 (RGB), 8 (RGBA).
    init(hex: String) {
        let c = Color.sRGBComponents(hex: hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// A colour that resolves to `light` or `dark` (both hex strings) per the active appearance.
    /// Backed by a `UIColor`/`NSColor` dynamic provider, so a single token automatically re-resolves
    /// at every one of its call sites when the colour scheme flips — no per-view environment plumbing.
    /// This is the whole light-theme strategy: only the token definitions change, never the call sites.
    init(light: String, dark: String) {
        #if os(watchOS)
        // watchOS has no UITraitCollection / dynamic-provider UIColor, and our watch app is effectively
        // always dark, so a token resolves straight to its dark hex. No per-scheme plumbing on the wrist.
        self.init(hex: dark)
        #elseif canImport(UIKit)
        self.init(UIColor { trait in
            let c = Color.sRGBComponents(hex: trait.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = Color.sRGBComponents(hex: isDark ? dark : light)
            return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        })
        #else
        self.init(hex: dark)
        #endif
    }
}

// MARK: - Strand Palette
//
// The "Titanium & Gold" re-skin: a premium dark theme built on a deep navy canvas with
// per-domain accent "colour worlds" (Charge = gold, Effort = amber, Rest = blue,
// Stress = blue→gold→orange). GOLD is the dominant brand anchor; titanium drives the
// neutral chrome (tiles, avatars, icons).
//
// PUBLIC API IS FROZEN: every property name below is depended on by screens across
// macOS / iOS, so the names never change — only the VALUES were re-themed. New
// Titanium & Gold tokens (gold ramp, titanium ramp, gradients) are ADDED at the end
// of the type; nothing existing was removed or renamed.

public enum StrandPalette {

    // MARK: Surfaces — deep navy canvas, tinted frosted cards
    // Background is a near-black navy (NOT pure black); cards float just above it.
    public static let surfaceBase    = NoopVisualStyle.canvas
    public static let surfaceRaised  = NoopVisualStyle.surface
    public static let surfaceOverlay = NoopVisualStyle.surfaceTop
    public static let surfaceInset   = NoopVisualStyle.inset
    public static let hairline       = NoopVisualStyle.border
    public static let hairlineStrong = NoopVisualStyle.borderHighlight

    // MARK: Text — deep navy-ink on paper / cool off-white on navy
    public static let textPrimary    = NoopVisualStyle.primaryText
    public static let textSecondary  = NoopVisualStyle.secondaryText
    public static let textTertiary   = NoopVisualStyle.tertiaryText

    // MARK: Text ON a permanently-dark surface (scheme-invariant)
    // Use these — NOT textPrimary/Secondary/Tertiary — for labels/pills drawn over a fill that is pinned
    // dark in BOTH themes (e.g. the over-sky ScreenScaffold title, on the time-of-day sky backdrop). The
    // regular text tokens FLIP to dark ink in Light mode, so on a fixed-dark surface they render
    // dark-on-near-black and vanish (#1013). These hold the light-on-dark values in BOTH schemes, so a
    // label always reads. (The Liquid hero card USED to need these, but its `heroFill` is theme-aware as of
    // #1160, so the hero now uses the normal text* tokens.)
    public static let onDarkPrimary   = Color(hex: "#F4F6F8")
    public static let onDarkSecondary = Color(hex: "#C8CFD8")
    public static let onDarkTertiary  = Color(hex: "#8A94A4")

    // MARK: Liquid hero card surface (#1160/#1161)
    // Was pinned near-black in BOTH themes, which read as a broken dark block in Light mode (#1160) and
    // never honoured card transparency (#1161). Now THEME-AWARE: near-black in Dark, frosted white in
    // Light, so the hero fits in with the other cards. Its own text uses the regular text*/tint tokens
    // (which flip) — NOT onDark*, which stays fixed for the genuinely-always-dark SKY backdrop
    // (ScreenScaffold's over-sky title). 8-digit hex = RRGGBBAA (alpha last).
    public static let heroFill   = Color(light: "FFFFFFD9", dark: "0D0E14CC")
    public static let heroBorder = Color(light: "0000001A", dark: "FFFFFF1C")

    // MARK: Glow — ambient bloom behind heroes / charts (additive on dark; faint warm on light)
    public static let glowAmbient    = NoopVisualStyle.mintGlow.opacity(0.28)

    // MARK: Accent — chrome anchor (links, selection, focus, generic accent). USER-SELECTABLE (mint /
    // WHOOP blue / custom) via `accentChoice` below, default mint (#1068). Only the chrome accent is
    // user-themed — the recovery/strain/sleep DATA worlds follow `chartStyle`, never this.
    /// The user's chrome-accent choice. Set from `@AppStorage(AccentColor.storageKey)` at the app root
    /// via `.noopAccent(...)`; the four accessors below branch on it. Default mint.
    public static var accentChoice: AccentColor = .mint
    /// The custom accent's hex, used only when `accentChoice == .custom`. Set alongside `accentChoice`.
    public static var customAccentHex: String = AccentColor.defaultCustomHex
    public static var accent: Color { accentChoice.accent }
    public static var accentHover: Color { accentChoice.accentHover }
    public static var accentMuted: Color { accentChoice.accentMuted }
    /// Focus ring color — the same accent, on both schemes.
    public static var focusRing: Color { accentChoice.focusRing }
    /// Opacity for dimmed/disabled sections (shared so screens don't invent their own value).
    public static let disabledOpacity: Double = 0.45
    /// Liquid-scene activity tint shared by heart-rate feedback and transient sync chrome.
    public static let liquidHeart = Color(light: "#D94C64", dark: "#FF6B81")

    // MARK: - Chart style (data-viz colour mode) — Titanium (brand) or Classic (throwback)
    //
    // Set from `@AppStorage(ChartStyle.storageKey)` at the app root. The DATA-RAMP accessors below
    // (recoveryStops, strainStops, hrZones, sleepStageColor, stress gradient, status, metric, and the
    // DomainTheme worlds) branch on this — so flipping it re-colours every gauge/chart/scale to the
    // classic red→green readiness scale, in BOTH light and dark, with NO call-site changes. Chrome
    // (surfaces, text, accent) is never touched.
    public static var chartStyle: ChartStyle = .titanium
    @inline(__always) static var isClassic: Bool { chartStyle == .classic }

    // MARK: Classic (throwback) data ramps — the recognizable health-app scale. Light/dark tuned.
    // Recovery: red → orange → amber → lime → green.
    static let cRecovery000 = Color(light: "#CB3A2F", dark: "#E5483B")
    static let cRecovery030 = Color(light: "#D87328", dark: "#EE8B3C")
    static let cRecovery055 = Color(light: "#CFA528", dark: "#F2C53D")
    static let cRecovery078 = Color(light: "#74A53A", dark: "#A6D04E")
    static let cRecovery100 = Color(light: "#2E9E4F", dark: "#46B45A")
    static let cRecoveryStops: [Gradient.Stop] = [
        .init(color: cRecovery000, location: 0.00), .init(color: cRecovery030, location: 0.30),
        .init(color: cRecovery055, location: 0.55), .init(color: cRecovery078, location: 0.78),
        .init(color: cRecovery100, location: 1.00),
    ]
    // Strain: the classic light→deep blue cardiovascular ramp.
    static let cStrain000 = Color(light: "#5E92D6", dark: "#7FB2E8")
    static let cStrain033 = Color(light: "#3A74C4", dark: "#4A90E2")
    static let cStrain066 = Color(light: "#284F9C", dark: "#2F6FCB")
    static let cStrain100 = Color(light: "#1C3E80", dark: "#1E4FA0")
    static let cStrainStops: [Gradient.Stop] = [
        .init(color: cStrain000, location: 0.00), .init(color: cStrain033, location: 0.33),
        .init(color: cStrain066, location: 0.66), .init(color: cStrain100, location: 1.00),
    ]
    // Sleep: grey awake, blue light, deep indigo, purple REM.
    static let cSleepAwake = Color(light: "#8C95A3", dark: "#C9CCD6")
    static let cSleepLight = Color(light: "#3A80D6", dark: "#6FA8E8")
    static let cSleepDeep  = Color(light: "#203E73", dark: "#2A4C8F")
    static let cSleepREM   = Color(light: "#6A4FC0", dark: "#8E6FD6")
    // HR zones: grey → green → yellow → orange → red.
    static let cZone1 = Color(light: "#828D9B", dark: "#9AA7B5")
    static let cZone2 = Color(light: "#2E9E4F", dark: "#46B45A")
    static let cZone3 = Color(light: "#CFA528", dark: "#F2C53D")
    static let cZone4 = Color(light: "#D87328", dark: "#EE8B3C")
    static let cZone5 = Color(light: "#CB3A2F", dark: "#E5483B")
    // Stress: calm green → amber → red.
    static let cStressStops: [Gradient.Stop] = [
        .init(color: Color(light: "#2E9E4F", dark: "#46B45A"), location: 0.0),
        .init(color: Color(light: "#CFA528", dark: "#F2C53D"), location: 0.5),
        .init(color: Color(light: "#CB3A2F", dark: "#E5483B"), location: 1.0),
    ]

    // MARK: Recovery / Charge gradient — the gold "Charge" colour world.
    // A single warm metal ramp: a deep bronze floor climbs through brand gold into a
    // bright champagne peak — no green anywhere; depleted reads as dim gold, not coral.
    // 0.00 bronze → 0.30 antique gold → 0.55 brand gold → 0.78 soft gold → 1.00 champagne.
    public static let recovery000 = Color(light: "#C0392B", dark: "#E0463C") // depleted — WHOOP red
    public static let recovery030 = Color(light: "#D9682A", dark: "#E8743C") // low — red-orange
    public static let recovery055 = Color(light: "#C99A00", dark: "#F9DF4A") // moderate — WHOOP yellow
    public static let recovery078 = Color(light: "#6FB23A", dark: "#8FD86A") // primed — yellow-green
    public static let recovery100 = Color(light: "#0F9D62", dark: "#03E095") // peak — WHOOP green

    /// Ordered gradient stops for the recovery scale (Titanium gold ramp, or the Classic red→green).
    public static var recoveryStops: [Gradient.Stop] {
        isClassic ? cRecoveryStops : [
            .init(color: recovery000, location: 0.00),
            .init(color: recovery030, location: 0.30),
            .init(color: recovery055, location: 0.55),
            .init(color: recovery078, location: 0.78),
            .init(color: recovery100, location: 1.00),
        ]
    }

    /// The signature recovery gradient (bronze → champagne, or Classic red→green).
    public static var recoveryGradient: Gradient { Gradient(stops: recoveryStops) }

    // MARK: Strain / Effort ramp — the amber "Effort" colour world.
    // Deep ember → warm amber → bright amber → soft amber peak: heat/output, all in the
    // Effort accent family rather than veering into magenta.
    public static let strain000 = Color(light: "#7E460E", dark: "#9C5A14") // deep ember
    public static let strain033 = Color(light: "#A4621B", dark: "#C2762A") // warm amber
    public static let strain066 = Color(light: "#C2792E", dark: "#D98A3D") // bright amber
    public static let strain100 = Color(light: "#D89240", dark: "#F0A85A") // soft amber peak

    public static var strainStops: [Gradient.Stop] {
        isClassic ? cStrainStops : [
            .init(color: strain000, location: 0.00),
            .init(color: strain033, location: 0.33),
            .init(color: strain066, location: 0.66),
            .init(color: strain100, location: 1.00),
        ]
    }

    /// The strain gradient (output / heat, or the Classic blue ramp).
    public static var strainGradient: Gradient { Gradient(stops: strainStops) }

    // MARK: Sleep stages — the blue "Rest" colour world (Titanium); Classic adds a purple REM.
    // WHOOP sleep-stage palette (adopted from ryanAtriumAi #988): four distinct hues per stage —
    // Awake white-grey #CAC8CB, Light periwinkle #A7A4F4, SWS/Deep orchid-pink #FD96FD, REM purple
    // #AE5BEF — because the previous three near-identical blues made a fragmented on-device
    // hypnogram unreadable. Light-mode variants are the same hues darkened for contrast on white.
    public static var sleepAwake: Color { isClassic ? cSleepAwake : Color(light: "#8E949E", dark: "#CAC8CB") }
    public static var sleepLight: Color { isClassic ? cSleepLight : Color(light: "#7B78E0", dark: "#A7A4F4") }
    public static var sleepDeep:  Color { isClassic ? cSleepDeep  : Color(light: "#C13EC1", dark: "#FD96FD") }
    public static var sleepREM:   Color { isClassic ? cSleepREM   : Color(light: "#8E3BD6", dark: "#AE5BEF") }

    // MARK: HR zones — Titanium cool→warm (no green), or the Classic grey→green→yellow→orange→red.
    public static var zone1: Color { isClassic ? cZone1 : Color(light: "#3A80D6", dark: "#4A90E2") }
    public static var zone2: Color { isClassic ? cZone2 : Color(light: "#2E92B4", dark: "#3FA9C9") }
    public static var zone3: Color { isClassic ? cZone3 : Color(light: "#C28E26", dark: "#E8B84B") }
    public static var zone4: Color { isClassic ? cZone4 : Color(light: "#C2792E", dark: "#D98A3D") }
    public static var zone5: Color { isClassic ? cZone5 : Color(light: "#C84E1E", dark: "#E0662F") }

    /// HR zones indexed 1...5; index 0 mirrors zone1 for convenience.
    public static var hrZones: [Color] { [zone1, zone1, zone2, zone3, zone4, zone5] }

    // MARK: Status — Titanium gold/amber/orange, or the Classic green/amber/red.
    public static var statusPositive: Color { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : Color(light: "#1F8A5B", dark: "#03E095") }
    public static var statusWarning:  Color { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : Color(light: "#C2792E", dark: "#F0A020") }
    public static var statusCritical: Color { isClassic ? Color(light: "#CB3A2F", dark: "#E5483B") : Color(light: "#C84E1E", dark: "#E0662F") }

    // MARK: Per-metric accents — HRV / SpO₂ / energy / risk. Classic leans the traditional hues (purple HRV, red risk).
    public static var metricCyan:   Color { isClassic ? Color(light: "#2E92B4", dark: "#3FA9C9") : Color(light: "#2E92B4", dark: "#3FA9C9") }
    public static var metricPurple: Color { isClassic ? Color(light: "#6A4FC0", dark: "#8E6FD6") : Color(light: "#3A80D6", dark: "#4A90E2") }
    public static var metricAmber:  Color { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : Color(light: "#C2792E", dark: "#D98A3D") }
    public static var metricRose:   Color { isClassic ? Color(light: "#CB3A2F", dark: "#E5483B") : Color(light: "#C84E1E", dark: "#E0662F") }

    // MARK: - Titanium & Gold domain "colour worlds" (NEW)
    //
    // Each daily score owns a two-stop accent gradient (deep → bright) plus a glow.
    // These drive the layered gauges, frosted-card tints and scenic heroes. Charge
    // owns the brand gold; Effort the amber ramp; Rest the blue scale.

    // Each domain's accent / glow follows the chart style: Titanium (gold/amber/blue) or Classic
    // (Charge=green, Effort=blue, Rest=indigo, Stress=amber) so card tints + gauge tips + glows match
    // the data scale. The gauge ARC itself samples the recovery/strain/stress STOPS above, so it goes
    // full red→green / blue / green→red in Classic regardless of these.

    /// Charge (recovery) — gold world / Classic green.
    public static var chargeColor: Color  { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : Color(light: "#0F9D62", dark: "#03E095") }
    public static var chargeDeep: Color    { isClassic ? Color(light: "#207A3C", dark: "#2E9E4F") : Color(light: "#0B7A4A", dark: "#0B9D62") }
    public static var chargeBright: Color  { isClassic ? Color(light: "#5FBE6E", dark: "#86D98E") : Color(light: "#5FD89A", dark: "#6BF0B4") }
    public static var chargeGlow: Color    { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : Color(light: "#0F9D62", dark: "#03E095") }
    /// Diagonal accent pair for the Charge card wash + gauge stroke (deep → bright).
    public static var chargeGradient: Gradient { Gradient(colors: [chargeDeep, chargeBright]) }

    /// Effort (strain) — amber world / Classic blue.
    public static var effortColor: Color   { isClassic ? Color(light: "#3A74C4", dark: "#4A90E2") : Color(light: "#2A78C8", dark: "#4090E0") }
    public static var effortDeep: Color    { isClassic ? Color(light: "#284F9C", dark: "#2F6FCB") : Color(light: "#1E5B96", dark: "#2A6FB0") }
    public static var effortBright: Color  { isClassic ? Color(light: "#5E92D6", dark: "#7FB2E8") : Color(light: "#5AA0E0", dark: "#74B6F0") }
    public static var effortGlow: Color    { isClassic ? Color(light: "#3A74C4", dark: "#4A90E2") : Color(light: "#2A78C8", dark: "#4090E0") }
    public static var effortGradient: Gradient { Gradient(colors: [effortDeep, effortBright]) }

    /// Rest (sleep) — blue world / Classic indigo.
    public static var restColor: Color     { isClassic ? Color(light: "#3A80D6", dark: "#6FA8E8") : Color(light: "#5E7896", dark: "#83A0B8") }
    public static var restDeep: Color      { isClassic ? Color(light: "#203E73", dark: "#2A4C8F") : Color(light: "#234F9E", dark: "#2F6FCB") }
    public static var restBright: Color    { isClassic ? Color(light: "#6A4FC0", dark: "#8E6FD6") : Color(light: "#5790DA", dark: "#6FA8E8") }
    public static var restGlow: Color      { isClassic ? Color(light: "#3A80D6", dark: "#6FA8E8") : Color(light: "#3A80D6", dark: "#4A90E2") }
    /// The Rest family's most legible LINE colour — for strokes that must read on a busy or translucent
    /// surface, such as the body-clock dial's arcs over a custom background image.
    ///
    /// Introduces no new value: it selects the existing token that is the bright blue in each palette.
    /// The families are not parallel — classic's `restBright` is a PURPLE accent while modern's is the
    /// blue, and classic's `restColor` is the blue where modern's is a muted steel — so a card naming
    /// either token directly gets the right colour in one palette and the wrong one in the other. Both
    /// resolve to #6FA8E8 in dark.
    public static var restLine: Color { isClassic ? restColor : restBright }

    public static var restGradient: Gradient { Gradient(colors: [restDeep, restBright]) }

    /// Stress — blue→gold→orange world / Classic green→amber→red.
    public static var stressColor: Color   { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : Color(light: "#C7891A", dark: "#F0A020") }
    public static var stressDeep: Color    { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : Color(light: "#3A80D6", dark: "#4A90E2") }
    public static var stressBright: Color  { isClassic ? Color(light: "#CB3A2F", dark: "#E5483B") : Color(light: "#C84E1E", dark: "#E0662F") }
    public static var stressGlow: Color    { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : Color(light: "#C7891A", dark: "#F0A020") }
    /// 3-stop gauge ramp: calm → balanced → high.
    public static var stressGradient: Gradient { Gradient(colors: [stressDeep, stressColor, stressBright]) }

    // MARK: Scenic background (NEW) — detail-screen hero gradient + starfield.
    /// Radial canvas: lit center → deep edge. Used by `ScenicHeroBackground` (warm-lit on light).
    public static let scenicCenter     = Color(light: "#FBF6EA", dark: "#1C2128")
    public static let scenicEdge       = Color(light: "#EDE6D6", dark: "#121518")
    /// Star tint for the scenic starfield (very faint on light; the hero suppresses stars there).
    public static let scenicStar       = Color(light: "#D8CDB6", dark: "#C8CFD8")

    /// Frosted-card tint endpoints (white→warm on light; the accent wash sits over them).
    public static let cardFillTop      = Color(light: "#FFFFFF", dark: "#15243C")
    public static let cardFillBottom   = Color(light: "#FAF7F0", dark: "#0B1424")

    // MARK: - Titanium & Gold core tokens (NEW)
    //
    // The brand gold ramp (buttons, ring fills, FAB, active chrome) and the neutral
    // titanium ramp (tiles, avatars, icon plates). Same names + hexes on Android so
    // Apple and Android match byte-for-byte.

    /// Brand gold — primary accent. Gold FILLS stay bright (dark text on them is legible in both schemes);
    /// only a hair deeper on light so the fill doesn't wash out against white.
    public static let gold          = Color(light: "#3A78C8", dark: "#60A0E0") // repointed to WHOOP blue (gold killed 2026-06-22)
    /// Bright blue — accent highlight / hover (was champagne).
    public static let goldLight     = Color(light: "#6FA8E0", dark: "#9FC8F0")
    /// Deep blue — accent low stop (was bronze).
    public static let goldDeep      = Color(light: "#2A5C9E", dark: "#3A78C8")
    /// Near-black brown — text / icons placed ON gold surfaces (scheme-invariant; gold fills stay gold).
    public static let goldDeepText  = Color(hex: "#FFFFFF") // white text/icons on accent fills (WHOOP, gold killed)
    /// The bright core dot at a gauge arc tip / sparkline head. White reads as a highlight on the dark
    /// canvas; on light it would vanish into the white card, so it flips to a deep ink that reads as a
    /// crisp centre on the (deepened) coloured tip bead.
    public static let tipCore       = Color(light: "#241B06", dark: "#FFFFFF")
    /// High-vis signal yellow — sparing emphasis (badges / alerts); deepened on light to stay visible.
    public static let signalYellow  = Color(light: "#E8A800", dark: "#FFD63D")
    /// 135–155° gold ramp for buttons, ring fills, FAB (light → gold → deep).
    public static let goldGradient  = Gradient(colors: [goldLight, gold, goldDeep])

    /// Brushed-titanium ramp (top highlight → mid body → low → deep) for tiles, avatars and icon plates.
    /// Shifted to a MID-grey ramp on light so brushed-metal tiles stay visible against white cards.
    public static let titaniumTop   = Color(light: "#DDE1E6", dark: "#F1F3F5")
    public static let titaniumMid   = Color(light: "#BBC2C9", dark: "#C9CFD4")
    public static let titaniumLow   = Color(light: "#98A0A8", dark: "#969DA4")
    public static let titaniumDeep  = Color(hex: "#6B737B")
    /// 150° titanium ramp for tiles / avatars / icon plates.
    public static let titaniumGradient = Gradient(colors: [titaniumTop, titaniumMid, titaniumLow, titaniumDeep])

    // MARK: - Sampling helpers

    /// Sample the recovery gradient (bronze → champagne) at a recovery score 0...100.
    /// Returns the exact interpolated color used everywhere recovery is tinted.
    public static func recoveryColor(_ score: Double) -> Color {
        sample(stops: recoveryStops, at: score / 100.0)
    }

    /// Sample the strain ("Effort") gradient at a value on NOOP's 0...100 Effort scale.
    public static func strainColor(_ strain: Double) -> Color {
        sample(stops: strainStops, at: strain / 100.0)
    }

    /// Effort tint sampled by a 0...1 fraction (e.g. value/scaleMax), spreading the full ember→amber
    /// ramp. Prefer this for gauge tips / value-tinted accents so a high Effort reads as bright amber
    /// rather than ember. `strainColor(_:)` stays for callers holding a 0...100 value.
    public static func effortTint(fraction: Double) -> Color {
        sample(stops: strainStops, at: min(max(fraction, 0), 1))
    }

    /// The state word for a recovery score, per spec §9.3.
    /// DEPLETED · LOW · MODERATE · PRIMED · PEAK
    public static func recoveryState(_ score: Double) -> String {
        switch score {
        case ..<25:  return String(localized: "DEPLETED", bundle: .module)
        case ..<50:  return String(localized: "LOW", bundle: .module)
        case ..<70:  return String(localized: "MODERATE", bundle: .module)
        case ..<88:  return String(localized: "PRIMED", bundle: .module)
        default:     return String(localized: "PEAK", bundle: .module)
        }
    }

    /// HR-zone color for a 0...5 zone index (clamped).
    public static func hrZoneColor(_ zone: Int) -> Color {
        let z = max(1, min(5, zone))
        return hrZones[z]
    }

    /// Color for a sleep stage by canonical name (awake/light/deep/rem).
    public static func sleepStageColor(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return sleepAwake
        case .light: return sleepLight
        case .deep:  return sleepDeep
        case .rem:   return sleepREM
        }
    }

    // Brand sleep ramps for the two stepped-hypnogram styles, so the chart reads like the app it's modelled
    // on. Ribbon = Oura's ramp (cream awake + blues, sampled from the ring's app); Filled = Garmin's
    // (blue light/deep + magenta REM). Opt-in only (Sleep-tab stepped chart) — every other Hypnogram caller
    // keeps `sleepStageColor`. (#sleep-chart-style)
    //
    // WHY THERE IS A LIGHT VARIANT. Both source apps are dark-tuned, so the ramps shipped flat — the same
    // hex in both schemes. On the light card those bands are drawn on near-white (`NoopVisualStyle.surface`
    // = #FFFFFF; a real Sleep-screen capture samples #FEFEFF), and measured there the Oura ramp collapses:
    // three of its four bands fall under the 3:1 non-text minimum and `awake` #EAE3D3 sits at **1.28:1**,
    // i.e. not drawn. That is not a rare band — on one real ring night awake was 64% of the chart.
    //
    // HOW THE LIGHT VALUES WERE DERIVED (not eyeballed, and not invented hues). Clamping each band on its
    // own to 3:1 is the obvious fix and it BREAKS THE RAMP: Oura `rem` → #1E9EDD and `light` → #239FD5 land
    // 1.00:1 apart, two adjacent stages the same colour. Instead ONE uniform HLS-lightness scale is applied
    // per ramp, pinned so the ramp's lightest band reaches 3:1 on white — Oura ×0.575, Garmin ×0.912. Hue
    // and saturation are untouched, so it is still recognisably the brand ramp; stage ORDERING survives;
    // and the intra-ramp separation is no worse than the shipped dark ramp's (pinned in
    // `BrandSleepRampTests`, twin `BrandSleepRampTest` on Android).
    static let oSleepAwake = Color(light: BrandSleepRamp.ouraAwake.light, dark: BrandSleepRamp.ouraAwake.dark)
    static let oSleepREM   = Color(light: BrandSleepRamp.ouraREM.light,   dark: BrandSleepRamp.ouraREM.dark)
    static let oSleepLight = Color(light: BrandSleepRamp.ouraLight.light, dark: BrandSleepRamp.ouraLight.dark)
    static let oSleepDeep  = Color(light: BrandSleepRamp.ouraDeep.light,  dark: BrandSleepRamp.ouraDeep.dark)
    static let gSleepAwake = Color(light: BrandSleepRamp.garminAwake.light, dark: BrandSleepRamp.garminAwake.dark)
    static let gSleepREM   = Color(light: BrandSleepRamp.garminREM.light,   dark: BrandSleepRamp.garminREM.dark)
    static let gSleepLight = Color(light: BrandSleepRamp.garminLight.light, dark: BrandSleepRamp.garminLight.dark)
    static let gSleepDeep  = Color(light: BrandSleepRamp.garminDeep.light,  dark: BrandSleepRamp.garminDeep.dark)

    /// The brand ramps as hex PAIRS, so the properties above can be asserted in a test — a `SwiftUI.Color`
    /// built from a dynamic provider cannot be read back, and these are also the values the Kotlin twin
    /// must match byte for byte (`stageColorForBrand` in `SleepStageBreakdownUi.kt`). `.dark` is the
    /// shipped ramp, unchanged.
    enum BrandSleepRamp {
        static let ouraAwake   = (light: "#AD9153", dark: "#EAE3D3")
        static let ouraREM     = (light: "#1A8AC2", dark: "#90D0F0")
        static let ouraLight   = (light: "#176B8E", dark: "#40B0E0")
        static let ouraDeep    = (light: "#12374A", dark: "#206080")
        static let garminAwake = (light: "#EF52E3", dark: "#F26FE8")
        static let garminREM   = (light: "#D91EC7", dark: "#E22DD0")
        static let garminLight = (light: "#3099F0", dark: "#4AA6F2")
        static let garminDeep  = (light: "#2168C5", dark: "#2472D8")

        /// Oura's ramp in STAGE order (awake → rem → light → deep), which is not the same as luminance
        /// order — Garmin's `light` is lighter than its `rem`. What the light pass must preserve is each
        /// ramp's OWN luminance order, whatever it is; that is what the tests assert.
        static let oura   = [ouraAwake, ouraREM, ouraLight, ouraDeep]
        /// Garmin's ramp in stage order.
        static let garmin = [garminAwake, garminREM, garminLight, garminDeep]
    }

    /// A sleep-stage colour in a chosen ramp: NOOP's own tokens, Oura's (Ribbon), or Garmin's (Garmin Fill).
    public static func sleepStageColor(_ stage: SleepStage, palette: SleepStagePalette) -> Color {
        switch palette {
        case .noop: return sleepStageColor(stage)
        case .oura:
            switch stage {
            case .awake: return oSleepAwake
            case .light: return oSleepLight
            case .deep:  return oSleepDeep
            case .rem:   return oSleepREM
            }
        case .garmin:
            switch stage {
            case .awake: return gSleepAwake
            case .light: return gSleepLight
            case .deep:  return gSleepDeep
            case .rem:   return gSleepREM
            }
        }
    }

    // MARK: - Linear gradient stop interpolation

    /// Interpolate a set of gradient stops at a normalized position 0...1.
    /// Clamps out-of-range positions to the end stops.
    public static func sample(stops: [Gradient.Stop], at position: Double) -> Color {
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return first.color }
        let t = min(max(position, 0.0), 1.0)

        // Find the bracketing pair.
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if t >= a.location && t <= b.location {
                lower = a
                upper = b
                break
            }
        }
        let span = upper.location - lower.location
        let localT = span > 0 ? (t - lower.location) / span : 0
        return interpolate(lower.color, upper.color, localT)
    }

    /// Linear-interpolate two colors in sRGB space.
    static func interpolate(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = ColorComponentCache.components(of: a)
        let cb = ColorComponentCache.components(of: b)
        let tt = min(max(t, 0.0), 1.0)
        return Color(
            .sRGB,
            red:   ca.r + (cb.r - ca.r) * tt,
            green: ca.g + (cb.g - ca.g) * tt,
            blue:  ca.b + (cb.b - ca.b) * tt,
            opacity: ca.a + (cb.a - ca.a) * tt
        )
    }
}

// MARK: - Resolved-component memo cache
//
// PERF: `interpolate(_:_:_:)` is the leaf of ALL gradient sampling — every sparkline point, every pip
// segment, every gauge tip, every heat-strip cell calls `sample(stops:at:)` → `interpolate`, which used
// to build a fresh UIColor/NSColor and run `getRed()` on BOTH endpoints on every single call. The stop
// colours are a tiny fixed set of static `let`s, so resolving them over and over dominated the draw.
//
// This memoizes the resolved sRGB components per Color. Crucially the cache is keyed on the CURRENT
// resolved appearance as well as the Color, because the palette tokens are dynamic `Color(light:dark:)`
// providers that resolve to DIFFERENT components per light/dark — so a bare Color key would return a
// stale, wrong-scheme value after an appearance flip. Including the appearance token in the key makes
// the cache miss (and re-resolve) exactly when the scheme changes, so the output stays byte-identical to
// calling `rgbaComponents` directly. Bounded so a pathological caller can't grow it without limit.
enum ColorComponentCache {
    private static var store: [Key: (r: Double, g: Double, b: Double, a: Double)] = [:]
    private static let lock = NSLock()

    private struct Key: Hashable {
        let color: Color
        let appearance: Int
    }

    /// A small integer identifying the current resolved appearance (light vs dark), matching the trait
    /// that `UIColor(color)` / `NSColor(color)` resolves against at this call site.
    private static var appearanceToken: Int {
        #if os(watchOS)
        // No UITraitCollection on watchOS; the watch app is always dark, so the cache key is constant.
        return 1
        #elseif canImport(UIKit)
        return UITraitCollection.current.userInterfaceStyle == .dark ? 1 : 0
        #elseif canImport(AppKit)
        let match = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? 1 : 0
        #else
        return 0
        #endif
    }

    static func components(of color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let key = Key(color: color, appearance: appearanceToken)
        lock.lock()
        if let hit = store[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let resolved = color.rgbaComponents
        lock.lock()
        // Cap the cache so an adversarial stream of unique colours can't grow it unboundedly; the real
        // working set is the handful of static palette stops, so this ceiling is never hit in practice.
        if store.count > 512 { store.removeAll(keepingCapacity: true) }
        store[key] = resolved
        lock.unlock()
        return resolved
    }
}

// MARK: - Sleep stage enum (shared with Hypnogram)

public enum SleepStage: String, CaseIterable, Sendable {
    case awake
    case light
    case deep
    case rem

    /// Display label.
    public var label: String {
        switch self {
        case .awake: return String(localized: "Awake", bundle: .module)
        case .light: return String(localized: "Light", bundle: .module)
        case .deep:  return String(localized: "Deep", bundle: .module)
        case .rem:   return "REM"
        }
    }

    /// Vertical band order (top = awake, bottom = deep) for hypnogram layout.
    public var bandRank: Int {
        switch self {
        case .awake: return 0
        case .rem:   return 1
        case .light: return 2
        case .deep:  return 3
        }
    }
}

// MARK: - Color component extraction

extension Color {
    /// Resolve to sRGB RGBA components in 0...1. Works on macOS 13+ via platform color bridge.
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}

#if DEBUG
#Preview("Palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            swatchRow("Surfaces", [
                ("base", StrandPalette.surfaceBase),
                ("raised", StrandPalette.surfaceRaised),
                ("overlay", StrandPalette.surfaceOverlay),
                ("inset", StrandPalette.surfaceInset),
                ("hairline", StrandPalette.hairline),
                ("hairline.strong", StrandPalette.hairlineStrong),
            ])
            swatchRow("Text", [
                ("primary", StrandPalette.textPrimary),
                ("secondary", StrandPalette.textSecondary),
                ("tertiary", StrandPalette.textTertiary),
            ])
            swatchRow("Accent", [
                ("accent", StrandPalette.accent),
                ("hover", StrandPalette.accentHover),
                ("muted", StrandPalette.accentMuted),
            ])
            swatchRow("Gold", [
                ("gold", StrandPalette.gold),
                ("light", StrandPalette.goldLight),
                ("deep", StrandPalette.goldDeep),
                ("deepText", StrandPalette.goldDeepText),
                ("signal", StrandPalette.signalYellow),
            ])
            swatchRow("Titanium", [
                ("top", StrandPalette.titaniumTop),
                ("mid", StrandPalette.titaniumMid),
                ("low", StrandPalette.titaniumLow),
                ("deep", StrandPalette.titaniumDeep),
            ])
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY GRADIENT").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("STRAIN RAMP").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.strainGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            swatchRow("Sleep stages", [
                ("awake", StrandPalette.sleepAwake),
                ("light", StrandPalette.sleepLight),
                ("deep", StrandPalette.sleepDeep),
                ("REM", StrandPalette.sleepREM),
            ])
            swatchRow("HR zones", [
                ("Z1", StrandPalette.zone1), ("Z2", StrandPalette.zone2),
                ("Z3", StrandPalette.zone3), ("Z4", StrandPalette.zone4),
                ("Z5", StrandPalette.zone5),
            ])
        }
        .padding(24)
    }
    .frame(width: 520, height: 760)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func swatchRow(_ title: String, _ items: [(String, Color)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color)
                        .frame(width: 64, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StrandPalette.hairline, lineWidth: 1))
                    Text(name).font(.system(size: 9)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
