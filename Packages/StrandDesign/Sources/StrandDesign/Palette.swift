import SwiftUI

// MARK: - Hex Color Helper

public extension Color {
    /// Create a Color from a hex string like "#0B0D12" or "0B0D12" (RGB) or "#AARRGGBB" / "RRGGBBAA".
    /// Supported lengths: 6 (RGB), 8 (RGBA).
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        let r, g, b, a: Double
        switch raw.count {
        case 8: // RRGGBBAA
            r = Double((int >> 24) & 0xFF) / 255.0
            g = Double((int >> 16) & 0xFF) / 255.0
            b = Double((int >> 8) & 0xFF) / 255.0
            a = Double(int & 0xFF) / 255.0
        default: // RRGGBB (6) and any fallback
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Strand Palette
//
// The "Bevel" re-skin: a premium dark theme built on a deep blue-black canvas with
// per-domain accent "colour worlds" (Charge = green, Effort = amber, Rest = indigo,
// Stress = teal). NOOP green stays the dominant brand anchor.
//
// PUBLIC API IS FROZEN: every property name below is depended on by screens across
// macOS / iOS, so the names never change — only the VALUES were re-themed. New
// Bevel tokens (domain worlds, gradient pairs, glows, scenic background colours)
// are ADDED at the end of the type; nothing existing was removed or renamed.

public enum StrandPalette {

    // MARK: Surfaces — deep blue-black canvas, tinted frosted cards
    // Background is a near-black blue (NOT pure black); cards float just above it.
    public static let surfaceBase    = Color(hex: "#080A11") // deep blue-black canvas
    public static let surfaceRaised  = Color(hex: "#141826") // frosted card fill
    public static let surfaceOverlay = Color(hex: "#1A1F30") // popovers / sheets / tooltips
    public static let surfaceInset   = Color(hex: "#0E1019") // wells / chart insets / segmented track
    public static let hairline       = Color(hex: "#262B3C") // soft blue-grey 1px border (≈ white 6%)
    public static let hairlineStrong = Color(hex: "#363D52") // hover / emphasis border

    // MARK: Text — cool off-white scale on the blue-black
    public static let textPrimary    = Color(hex: "#F2F4FA")
    public static let textSecondary  = Color(hex: "#A6ADC0")
    public static let textTertiary   = Color(hex: "#737A8E")

    // MARK: Glow — ambient bloom behind heroes / charts
    public static let glowAmbient    = Color(hex: "#1C2A4A")

    // MARK: Accent — NOOP green brand anchor (chrome + the Charge world)
    public static let accent         = Color(hex: "#2BCF8E") // brand health green
    public static let accentHover    = Color(hex: "#4DEBA8")
    public static let accentMuted    = Color(hex: "#12281F") // dark-green tint (selected rows)
    /// Focus ring color (same as accent).
    public static let focusRing      = Color(hex: "#2BCF8E")
    /// Opacity for dimmed/disabled sections (shared so screens don't invent their own value).
    public static let disabledOpacity: Double = 0.45

    // MARK: Recovery / Charge gradient — the green "Charge" colour world.
    // Low end keeps a warm warning blush so a depleted score still reads as "rest",
    // then climbs through gold into the deep→bright NOOP green that owns Charge.
    // 0.00 coral → 0.30 amber → 0.55 gold → 0.78 green → 1.00 mint.
    public static let recovery000 = Color(hex: "#FF5C7A") // depleted — coral
    public static let recovery030 = Color(hex: "#FFB23E") // low — amber
    public static let recovery055 = Color(hex: "#E8D14B") // moderate — gold
    public static let recovery078 = Color(hex: "#1D9E75") // primed — deep green
    public static let recovery100 = Color(hex: "#5DFFB0") // peak — bright mint

    /// Ordered gradient stops for the recovery scale (location + color).
    public static let recoveryStops: [Gradient.Stop] = [
        .init(color: recovery000, location: 0.00),
        .init(color: recovery030, location: 0.30),
        .init(color: recovery055, location: 0.55),
        .init(color: recovery078, location: 0.78),
        .init(color: recovery100, location: 1.00),
    ]

    /// The signature recovery gradient (indigo → mint).
    public static let recoveryGradient = Gradient(stops: recoveryStops)

    // MARK: Strain / Effort ramp — the amber "Effort" colour world.
    // Deep ember → warm gold → bright amber → hot orange: heat/output, all in the
    // Effort accent family rather than veering into magenta.
    public static let strain000 = Color(hex: "#B9740F") // deep ember
    public static let strain033 = Color(hex: "#E89020") // warm gold
    public static let strain066 = Color(hex: "#FFA836") // bright amber
    public static let strain100 = Color(hex: "#FFC861") // hot amber peak

    public static let strainStops: [Gradient.Stop] = [
        .init(color: strain000, location: 0.00),
        .init(color: strain033, location: 0.33),
        .init(color: strain066, location: 0.66),
        .init(color: strain100, location: 1.00),
    ]

    /// The strain gradient (output / heat).
    public static let strainGradient = Gradient(stops: strainStops)

    // MARK: Sleep stages — the indigo / periwinkle "Rest" colour world.
    public static let sleepAwake = Color(hex: "#FF6F8B") // rose (out of bed)
    public static let sleepLight = Color(hex: "#8E97E0") // periwinkle
    public static let sleepDeep  = Color(hex: "#5A63C7") // indigo
    public static let sleepREM   = Color(hex: "#B4BDFF") // pale periwinkle (glows)

    // MARK: HR zones — cool→warm ramp tuned to the Bevel worlds.
    public static let zone1 = Color(hex: "#5AA8E0") // easy — blue
    public static let zone2 = Color(hex: "#3ED1A0") // green
    public static let zone3 = Color(hex: "#E8D14B") // gold
    public static let zone4 = Color(hex: "#FFA836") // amber
    public static let zone5 = Color(hex: "#FF6F8B") // max — rose

    /// HR zones indexed 1...5; index 0 mirrors zone1 for convenience.
    public static let hrZones: [Color] = [zone1, zone1, zone2, zone3, zone4, zone5]

    // MARK: Status — never reused as recovery colors.
    public static let statusPositive = Color(hex: "#2BCF8E")
    public static let statusWarning  = Color(hex: "#FFB23E")
    public static let statusCritical = Color(hex: "#FF5C7A")

    // MARK: Per-metric accents — HRV / SpO₂ / energy / risk, on-brand for Bevel.
    public static let metricCyan   = Color(hex: "#46C8FF") // SpO₂ / steps / Apple Health
    public static let metricPurple = Color(hex: "#B4BDFF") // HRV (shares the Rest world)
    public static let metricAmber  = Color(hex: "#FFC861") // calories (shares the Effort world)
    public static let metricRose   = Color(hex: "#FF6F8B") // risk / heart rate / low recovery

    // MARK: - Bevel domain "colour worlds" (NEW)
    //
    // Each daily score owns a two-stop accent gradient (deep → bright) plus a glow.
    // These drive the layered gauges, frosted-card tints and scenic heroes. Charge
    // re-uses the brand green; Effort the amber ramp; Rest the indigo/periwinkle.

    /// Charge (recovery) — green world.
    public static let chargeColor      = Color(hex: "#2BCF8E")
    public static let chargeDeep       = Color(hex: "#1D9E75")
    public static let chargeBright      = Color(hex: "#5DFFB0")
    public static let chargeGlow       = Color(hex: "#2BCF8E")
    /// Diagonal accent pair for the Charge card wash + gauge stroke (deep → bright).
    public static let chargeGradient   = Gradient(colors: [chargeDeep, chargeBright])

    /// Effort (strain) — amber world.
    public static let effortColor      = Color(hex: "#FFA836")
    public static let effortDeep       = Color(hex: "#B9740F")
    public static let effortBright      = Color(hex: "#FFC861")
    public static let effortGlow       = Color(hex: "#FFA836")
    public static let effortGradient   = Gradient(colors: [effortDeep, effortBright])

    /// Rest (sleep) — indigo / periwinkle world.
    public static let restColor        = Color(hex: "#7E88E0")
    public static let restDeep         = Color(hex: "#5A63C7")
    public static let restBright        = Color(hex: "#B4BDFF")
    public static let restGlow         = Color(hex: "#8E97E0")
    public static let restGradient     = Gradient(colors: [restDeep, restBright])

    /// Stress — teal world (used by StressView's accents).
    public static let stressColor      = Color(hex: "#3FB8B0")
    public static let stressDeep       = Color(hex: "#1F7E78")
    public static let stressBright      = Color(hex: "#6FE0D6")
    public static let stressGlow       = Color(hex: "#3FB8B0")
    public static let stressGradient   = Gradient(colors: [stressDeep, stressBright])

    // MARK: Scenic background (NEW) — detail-screen hero gradient + starfield.
    /// Radial canvas: warm-lit center → deep edge. Used by `ScenicHeroBackground`.
    public static let scenicCenter     = Color(hex: "#0B0D14")
    public static let scenicEdge       = Color(hex: "#07080D")
    /// Star tint for the scenic starfield.
    public static let scenicStar       = Color(hex: "#C9D2F0")

    /// Frosted-card tint endpoints (a subtle dark fill the accent wash sits over).
    public static let cardFillTop      = Color(hex: "#161A26")
    public static let cardFillBottom   = Color(hex: "#101219")

    // MARK: - Sampling helpers

    /// Sample the recovery gradient (indigo → mint) at a recovery score 0...100.
    /// Returns the exact interpolated color used everywhere recovery is tinted.
    public static func recoveryColor(_ score: Double) -> Color {
        sample(stops: recoveryStops, at: score / 100.0)
    }

    /// Sample the strain ("Effort") gradient at a value on NOOP's 0...100 Effort scale.
    public static func strainColor(_ strain: Double) -> Color {
        sample(stops: strainStops, at: strain / 100.0)
    }

    /// The state word for a recovery score, per spec §9.3.
    /// DEPLETED · LOW · MODERATE · PRIMED · PEAK
    public static func recoveryState(_ score: Double) -> String {
        switch score {
        case ..<25:  return "DEPLETED"
        case ..<50:  return "LOW"
        case ..<70:  return "MODERATE"
        case ..<88:  return "PRIMED"
        default:     return "PEAK"
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
        let ca = a.rgbaComponents
        let cb = b.rgbaComponents
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

// MARK: - Sleep stage enum (shared with Hypnogram)

public enum SleepStage: String, CaseIterable, Sendable {
    case awake
    case light
    case deep
    case rem

    /// Display label.
    public var label: String {
        switch self {
        case .awake: return "Awake"
        case .light: return "Light"
        case .deep:  return "Deep"
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
