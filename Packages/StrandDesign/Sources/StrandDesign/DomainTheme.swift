import SwiftUI

// MARK: - Domain Theme (NEW — Bevel per-domain colour worlds)
//
// Maps a daily-score domain (Charge / Effort / Rest / Stress) to its accent
// "colour world": a primary colour, a deep→bright gradient for gauge strokes and
// card washes, and a glow colour for blooms / end-cap halos. Every Bevel surface
// (layered gauge, frosted card tint, scenic hero) reads its colours from here so a
// screen only has to name its domain.

public enum DomainTheme: String, CaseIterable, Sendable {
    case charge
    case effort
    case rest
    case stress

    /// The dominant accent colour for the world.
    public var color: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest:   return StrandPalette.restColor
        case .stress: return StrandPalette.stressColor
        }
    }

    /// The deep (low) end of the world's accent ramp.
    public var deep: Color {
        switch self {
        case .charge: return StrandPalette.chargeDeep
        case .effort: return StrandPalette.effortDeep
        case .rest:   return StrandPalette.restDeep
        case .stress: return StrandPalette.stressDeep
        }
    }

    /// The bright (high) end of the world's accent ramp.
    public var bright: Color {
        switch self {
        case .charge: return StrandPalette.chargeBright
        case .effort: return StrandPalette.effortBright
        case .rest:   return StrandPalette.restBright
        case .stress: return StrandPalette.stressBright
        }
    }

    /// The world's glow colour for blooms and gauge end-caps.
    public var glow: Color {
        switch self {
        case .charge: return StrandPalette.chargeGlow
        case .effort: return StrandPalette.effortGlow
        case .rest:   return StrandPalette.restGlow
        case .stress: return StrandPalette.stressGlow
        }
    }

    /// Deep → bright gradient for gauge strokes and the diagonal card wash.
    public var gradient: Gradient {
        switch self {
        case .charge: return StrandPalette.chargeGradient
        case .effort: return StrandPalette.effortGradient
        case .rest:   return StrandPalette.restGradient
        case .stress: return StrandPalette.stressGradient
        }
    }

    /// The data gradient the world samples values along (Charge/Rest = recovery
    /// scale, Effort = strain ramp), used by sparklines and value-tinted strokes.
    public var dataGradient: Gradient {
        switch self {
        case .charge, .rest, .stress: return StrandPalette.recoveryGradient
        case .effort:                 return StrandPalette.strainGradient
        }
    }
}

// MARK: - Scenic Hero Background (NEW)
//
// A Canvas-drawn premium backdrop for detail-screen heroes: a radial deep blue-black
// gradient (warm-lit center → near-black edge) sprinkled with a faint deterministic
// starfield, optionally tinted toward a domain's glow. Sits behind a ScoreGauge /
// hero number. Deterministic (no per-frame randomness) so it never flickers, and the
// starfield is purely decorative (hidden from VoiceOver via the caller's container).

public struct ScenicHeroBackground: View {

    /// Optional domain whose glow tints the upper bloom. nil = neutral blue-black.
    public var domain: DomainTheme?
    /// Star count — kept modest so the field reads as texture, not noise.
    public var starCount: Int
    /// Whether to draw the bottom fade that lets content sit cleanly over the field.
    public var fadesToBase: Bool

    @Environment(\.colorScheme) private var scheme

    public init(domain: DomainTheme? = nil, starCount: Int = 40, fadesToBase: Bool = true) {
        self.domain = domain
        self.starCount = starCount
        self.fadesToBase = fadesToBase
    }

    public var body: some View {
        ZStack {
            // Radial deep blue-black: lit center → near-black edge.
            RadialGradient(
                gradient: Gradient(colors: [StrandPalette.scenicCenter, StrandPalette.scenicEdge]),
                center: .init(x: 0.5, y: 0.36),
                startRadius: 0,
                endRadius: 520
            )

            // Design Reset (2026-06-22): the domain bloom + starfield are removed for the flat
            // WHOOP look. The hero is now a clean blue-grey radial — no glow, no stars. `domain` and
            // `starCount` stay on the type for API stability but no longer paint.

            // Bottom fade so a hero number / card reads cleanly over the field.
            if fadesToBase {
                LinearGradient(
                    colors: [.clear, StrandPalette.scenicEdge.opacity(0.72), StrandPalette.scenicEdge],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("ScenicHeroBackground") {
    VStack(spacing: 0) {
        ScenicHeroBackground(domain: .charge)
            .frame(height: 220)
            .overlay(
                Text("87").font(.system(size: 60, weight: .bold, design: .default))
                    .foregroundStyle(StrandPalette.textPrimary)
            )
        ScenicHeroBackground(domain: .rest)
            .frame(height: 220)
    }
    .frame(width: 420, height: 440)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
