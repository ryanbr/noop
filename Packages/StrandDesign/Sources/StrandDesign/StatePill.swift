import SwiftUI

// MARK: - StatePill (§9.4 chrome) & ConnectionDot (sidebar status footer)
//
// Small status chips used in chrome: a rounded pill with an optional leading dot
// and a tinted label. Tones map to the status palette (positive/warning/critical)
// plus neutral and accent. The ConnectionDot is a tiny pulsing presence indicator
// used in the strap-status footer / menu-bar.

public enum StrandTone: Sendable {
    case neutral
    case accent
    case positive
    case warning
    case critical

    public var color: Color {
        switch self {
        case .neutral:  return StrandPalette.textSecondary
        case .accent:   return StrandPalette.accent
        case .positive: return StrandPalette.statusPositive
        case .warning:  return StrandPalette.statusWarning
        case .critical: return StrandPalette.statusCritical
        }
    }
}

public struct StatePill: View {

    public var title: LocalizedStringKey
    public var tone: StrandTone
    public var showsDot: Bool
    /// Pulse the leading dot (e.g. "live" / "syncing").
    public var pulsing: Bool

    public init(_ title: LocalizedStringKey, tone: StrandTone = .neutral, showsDot: Bool = true, pulsing: Bool = false) {
        self.title = title
        self.tone = tone
        self.showsDot = showsDot
        self.pulsing = pulsing
    }

    public var body: some View {
        HStack(spacing: 6) {
            if showsDot {
                ConnectionDot(tone: tone, pulsing: pulsing, size: 7)
            }
            Text(title)
                .font(StrandFont.overline)
                .tracking(0.4)
                .foregroundStyle(tone.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tone.color.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(tone.color.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: - ConnectionDot

/// A tiny status dot with an optional breathing pulse halo. Used for connection
/// state, live indicators, and inside StatePill.
public struct ConnectionDot: View {

    public var tone: StrandTone
    public var pulsing: Bool
    public var size: CGFloat

    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP". This halo is a `repeatForever` loop that never
    /// settles and is on screen for long stretches — a connected strap in Settings, a backfill on
    /// every scaffolded screen — so it belongs behind the same gate as the liquid surfaces.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    @Environment(\.colorScheme) private var scheme

    public init(tone: StrandTone = .positive, pulsing: Bool = false, size: CGFloat = 9) {
        self.tone = tone
        self.pulsing = pulsing
        self.size = size
    }

    public var body: some View {
        ZStack {
            // Dark-mode only (#review): AdditiveBloom used to hide this expanding ring on light
            // (content.opacity(0)); now that we drop the offscreen bloom, gate it explicitly so light
            // mode stays ring-free (the resting dot + its shadow carry the live state there).
            if pulsing && scheme == .dark {
                Circle()
                    .fill(tone.color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
                    // No .additiveBloom(): the .plusLighter blend forced an offscreen pass every
                    // frame of the repeatForever pulse, a continuous cost while a strap is backfilling
                    // (exactly when this live dot is on screen). The expanding/fading ring reads the
                    // same without it; the resting dot's shadow still carries the "live" glow.
            }
            Circle()
                .fill(tone.color)
                .frame(width: size, height: size)
                .shadow(color: tone.color.opacity(0.8), radius: pulsing ? 4 : 2)
        }
        .frame(width: size, height: size)
        // Honour the quiet-motion gate (system Reduce Motion, Low Power Mode, or the in-app
        // toggle): don't kick off the looping pulse (it settles at the resting dot) and never
        // attach the repeatForever breathe animation.
        .onAppear { if pulsing && !poseStill { animate = true } }
        .animation(pulsing && !poseStill ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("StatePill / ConnectionDot") {
    VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 10) {
            StatePill("Connected", tone: .positive)
            StatePill("Syncing", tone: .accent, pulsing: true)
            StatePill("Battery 14%", tone: .warning)
            StatePill("Disconnected", tone: .critical)
            StatePill("Idle", tone: .neutral, showsDot: false)
        }
        HStack(spacing: 16) {
            ConnectionDot(tone: .positive)
            ConnectionDot(tone: .accent, pulsing: true)
            ConnectionDot(tone: .warning)
            ConnectionDot(tone: .critical, pulsing: true)
        }
        // mimic the sidebar strap-status footer chip
        HStack(spacing: 10) {
            Image(systemName: "applewatch")
                .foregroundStyle(StrandPalette.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Whoop 4.0").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("87% · streaming").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            ConnectionDot(tone: .positive, pulsing: true)
        }
        .padding(12)
        .background(NoopPanelSurface(cornerRadius: 12))
        .frame(width: 300)
    }
    .padding(28)
    .frame(width: 560, height: 280)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
