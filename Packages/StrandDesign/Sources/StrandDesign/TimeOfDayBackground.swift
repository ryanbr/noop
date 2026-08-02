import SwiftUI

// MARK: - Time-of-Day Atmosphere (NOOP identity backdrop)
//
// A *whisper* behind content — never decoration, never the old gaudy Canvas starfield.
// Apple-Weather restraint dialled WAY down: every atmosphere layer sits at opacity <= 0.16,
// painted OVER the WHOOP `surfaceBase` canvas so screens stay dark, flat and clean.
//
// HARD RULES honoured here (standing):
//  - NO GLOW. No bloom, no blur halos, no neon. The sun/moon are plain filled `Circle`s at
//    very low opacity; stars are tiny crisp dots. Beauty = restraint, spacing, type, motion.
//  - TOKENS first (`StrandPalette`). The only literal hexes are the few subtle atmosphere
//    tints the spec calls for (warm peach lift, indigo wash, etc.) — kept deliberately faint.
//  - Reduce Motion — and Low Power Mode, and the in-app "Reduce motion in NOOP" toggle —
//    pin every drifting element still (no looping translation, and the frame loop is `paused:`).
//  - Light mode is even MORE restrained: warm-paper tints, fewer/softer elements.
//  - CPU-light: drift runs off a single `TimelineView(.animation)` tick that the system
//    pauses when the view is off-screen; no per-frame allocation, no timers we own.

// MARK: Day part

/// The four atmospheric parts of the day. `current` derives one from the clock.
public enum DayPart: String, CaseIterable, Sendable {
    case dawn, day, dusk, night

    /// Map an hour (0...23) to its day part: dawn 5–8, day 8–17, dusk 17–20, night 20–5.
    public static func current(hour: Int) -> DayPart {
        let h = ((hour % 24) + 24) % 24
        switch h {
        case 5..<8:   return .dawn
        case 8..<17:  return .day
        case 17..<20: return .dusk
        default:      return .night
        }
    }

    /// The day part for *now*, from the system clock.
    public static var current: DayPart {
        current(hour: Calendar.current.component(.hour, from: Date()))
    }
}

// MARK: - Time-of-day background

/// A full-bleed, very subtle atmosphere layer tuned per `DayPart`, painted over the
/// `surfaceBase` canvas. Drop it behind any screen via `.timeOfDayBackground()`.
///
/// Self-contained and `public`/stable: a screen only ever names the `DayPart` and whether
/// motion is wanted. All tuning lives here.
public struct TimeOfDayBackground: View {
    private let dayPart: DayPart
    private let animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Low Power Mode and the in-app "Reduce motion in NOOP" toggle, neither of which has a SwiftUI
    /// environment key. The Android twin (`TimeOfDayBackground.kt`) has consulted battery saver since
    /// #911; this side was left reading Reduce Motion alone.
    @ObservedObject private var motion = NoopMotionState.shared

    public init(dayPart: DayPart, animated: Bool = true) {
        self.dayPart = dayPart
        self.animated = animated
    }

    /// Whether drifting elements should actually move: the caller opted in AND nothing is asking
    /// for quiet (system Reduce Motion, Low Power Mode, or the in-app toggle).
    private var drift: Bool { animated && !motion.poseStill(reduceMotion) }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // 1) The canvas — always the WHOOP dark base (a hair deeper at night).
                base

                // 2) The per-part wash (gradients + sun/moon/stars). Static; cheap.
                AtmosphereWash(dayPart: dayPart, isLight: colorScheme == .light)

                // 3) Slow-drifting soft shapes (clouds for day/dusk, orbs for night/dawn).
                //    A single animation tick drives a horizontal loop; Reduce Motion pins it.
                FloatingLayer(dayPart: dayPart,
                              isLight: colorScheme == .light,
                              size: size,
                              drift: drift)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)            // pure backdrop — never steals touches
        .accessibilityHidden(true)          // decorative; invisible to VoiceOver
    }

    /// The base canvas. Night sits a touch deeper than `surfaceBase` for depth; the rest
    /// use the shared token verbatim so screens stay on-brand.
    @ViewBuilder private var base: some View {
        switch dayPart {
        case .night:
            StrandPalette.surfaceBase
                .overlay(Color(light: "#ECE7DC", dark: "#0D1014").opacity(colorScheme == .light ? 0.0 : 0.55))
        default:
            StrandPalette.surfaceBase
        }
    }
}

// MARK: - Atmosphere wash (static gradients + sun / moon / stars)

private struct AtmosphereWash: View {
    let dayPart: DayPart
    let isLight: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                switch dayPart {
                case .dawn:  dawn(w: w, h: h)
                case .day:   day(w: w, h: h)
                case .dusk:  dusk(w: w, h: h)
                case .night: night(w: w, h: h)
                }
            }
        }
    }

    // Light-mode ceiling: knock atmosphere back further so it reads as warm paper, not colour.
    private func cap(_ dark: Double, _ light: Double) -> Double { isLight ? light : dark }

    // MARK: Dawn — cool indigo up top, faint warm peach lift low-centre, soft low sun disc.
    @ViewBuilder private func dawn(w: CGFloat, h: CGFloat) -> some View {
        // Cool indigo wash falling from the top.
        LinearGradient(
            colors: [Color(light: "#A9B2D6", dark: "#3A4470").opacity(cap(0.14, 0.06)), .clear],
            startPoint: .top, endPoint: .center
        )
        // Warm peach lift rising from the low centre.
        RadialGradient(
            colors: [Color(light: "#F3C9A4", dark: "#E8A56A").opacity(cap(0.12, 0.05)), .clear],
            center: UnitPoint(x: 0.5, y: 1.02),
            startRadius: 0, endRadius: max(w, h) * 0.75
        )
        // The sun: a plain filled disc, very low opacity, NO glow.
        Circle()
            .fill(Color(light: "#F4C98E", dark: "#F0B968"))
            .frame(width: min(w, h) * 0.22, height: min(w, h) * 0.22)
            .opacity(cap(0.10, 0.05))
            .position(x: w * 0.32, y: h * 0.84)
    }

    // MARK: Day — cleanest of the four: a barely-there cool top-light only.
    @ViewBuilder private func day(w: CGFloat, h: CGFloat) -> some View {
        LinearGradient(
            colors: [Color(light: "#BFD0E2", dark: "#4C5E78").opacity(cap(0.08, 0.04)), .clear],
            startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.55)
        )
    }

    // MARK: Dusk — cool violet wash up top, faint warm amber lift low.
    @ViewBuilder private func dusk(w: CGFloat, h: CGFloat) -> some View {
        LinearGradient(
            colors: [Color(light: "#B6A6CE", dark: "#4A3E66").opacity(cap(0.14, 0.06)), .clear],
            startPoint: .top, endPoint: .center
        )
        RadialGradient(
            colors: [Color(light: "#EBB084", dark: "#E0913E").opacity(cap(0.13, 0.05)), .clear],
            center: UnitPoint(x: 0.5, y: 1.04),
            startRadius: 0, endRadius: max(w, h) * 0.8
        )
    }

    // MARK: Night — a few tiny crisp stars + a faint crescent moon (Circle masked by an offset Circle).
    @ViewBuilder private func night(w: CGFloat, h: CGFloat) -> some View {
        // A whisper of indigo depth at the top.
        LinearGradient(
            colors: [Color(light: "#9FA8C8", dark: "#2C3458").opacity(cap(0.10, 0.05)), .clear],
            startPoint: .top, endPoint: .center
        )

        // <=7 deterministic tiny stars. Crisp dots, r <= 1pt, opacity 0.06–0.12. Light mode hides them.
        if !isLight {
            ForEach(Self.stars.indices, id: \.self) { i in
                let s = Self.stars[i]
                Circle()
                    .fill(StrandPalette.scenicStar)
                    .frame(width: s.r * 2, height: s.r * 2)
                    .opacity(s.o)
                    .position(x: w * s.x, y: h * s.y)
            }
        }

        // Crescent moon: a disc with an offset disc carved out (even-odd fill). Low opacity, no glow.
        CrescentMoon()
            .fill(Color(light: "#C9CEDC", dark: "#C8CFD8"), style: FillStyle(eoFill: true))
            .frame(width: min(w, h) * 0.13, height: min(w, h) * 0.13)
            .opacity(cap(0.12, 0.05))
            .position(x: w * 0.78, y: h * 0.18)
    }

    /// Deterministic star field: fixed positions (0...1), tiny radius (<=1pt), restrained opacity.
    /// Hand-placed (not random) so the layout never shifts between renders and never crowds.
    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double)] = [
        (0.14, 0.12, 0.9, 0.10),
        (0.27, 0.30, 0.7, 0.07),
        (0.46, 0.09, 1.0, 0.12),
        (0.61, 0.24, 0.8, 0.09),
        (0.83, 0.34, 0.7, 0.06),
        (0.36, 0.46, 0.8, 0.08),
        (0.90, 0.10, 0.9, 0.11),
    ]
}

// MARK: - Crescent moon shape (Circle masked by an offset Circle — no glow)

/// A crescent: the full disc minus a disc offset up-and-right. Pure geometry, even-odd filled,
/// so it renders as a crisp sliver with no blur/bloom.
private struct CrescentMoon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: rect)
        // Punch out an offset disc to leave a crescent (even-odd fill removes the overlap).
        let inset = rect.width * 0.26
        let shifted = CGRect(
            x: rect.minX + inset * 1.15,
            y: rect.minY - inset * 0.55,
            width: rect.width,
            height: rect.height
        )
        p.addEllipse(in: shifted)
        return p
    }
}

// MARK: - Floating layer (2–3 huge, soft, low-opacity drifting shapes)

private struct FloatingLayer: View {
    let dayPart: DayPart
    let isLight: Bool
    let size: CGSize
    let drift: Bool

    var body: some View {
        // One animation clock drives every shape's horizontal phase. The system pauses this
        // TimelineView while off-screen, so it costs nothing when not visible.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !drift)) { timeline in
            let t = drift ? timeline.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                ForEach(shapes.indices, id: \.self) { i in
                    floater(shapes[i], t: t)
                }
            }
        }
    }

    /// A single soft drifting blob — a very large, very low-opacity rounded shape.
    @ViewBuilder private func floater(_ s: Floater, t: TimeInterval) -> some View {
        let w = size.width
        let h = size.height
        // Slow looping horizontal drift: full sweep takes `s.period` seconds. A gentle sine
        // makes it ease at the edges. Reduce Motion / opted-out → phase pinned at rest (t = 0).
        let phase = drift ? (t / s.period + s.offset) : s.offset
        let dx = CGFloat(sin(phase * 2 * .pi)) * w * s.travel
        let dim = max(w, h) * s.scale

        shapeView(s)
            .frame(width: dim, height: dim * (s.isCloud ? 0.62 : 1.0))
            .opacity(s.opacity * (isLight ? 0.55 : 1.0))   // even fainter in light mode
            .position(x: w * s.baseX + dx, y: h * s.baseY)
            // Dark: a faint additive lift off the near-black canvas (flat fill, never a halo).
            // Light: plain blending so pale tints don't blow out the warm-paper surface.
            .blendMode(isLight ? .normal : .plusLighter)
    }

    /// Clouds (day/dusk) read as wide soft ellipses; orbs (night/dawn) as round soft discs.
    /// Both are flat fills — NO blur, NO gradient halo. Softness comes from huge size + tiny opacity.
    @ViewBuilder private func shapeView(_ s: Floater) -> some View {
        if s.isCloud {
            Ellipse().fill(s.tint)
        } else {
            Circle().fill(s.tint)
        }
    }

    /// The 2–3 shapes for this part. Clouds suit day/dusk; orbs suit night/dawn.
    private var shapes: [Floater] {
        switch dayPart {
        case .day:
            return [
                Floater(isCloud: true,  tint: cloudTint, baseX: 0.30, baseY: 0.30, scale: 1.20, travel: 0.10, period: 64, offset: 0.0,  opacity: 0.05),
                Floater(isCloud: true,  tint: cloudTint, baseX: 0.72, baseY: 0.52, scale: 1.00, travel: 0.08, period: 82, offset: 0.4,  opacity: 0.04),
            ]
        case .dusk:
            return [
                Floater(isCloud: true,  tint: duskCloudTint, baseX: 0.40, baseY: 0.70, scale: 1.35, travel: 0.09, period: 70, offset: 0.1, opacity: 0.06),
                Floater(isCloud: true,  tint: duskCloudTint, baseX: 0.74, baseY: 0.40, scale: 1.05, travel: 0.07, period: 90, offset: 0.5, opacity: 0.04),
            ]
        case .dawn:
            return [
                Floater(isCloud: false, tint: dawnOrbTint, baseX: 0.30, baseY: 0.78, scale: 0.95, travel: 0.07, period: 78, offset: 0.0, opacity: 0.06),
                Floater(isCloud: true,  tint: dawnOrbTint, baseX: 0.66, baseY: 0.38, scale: 1.10, travel: 0.06, period: 96, offset: 0.5, opacity: 0.04),
            ]
        case .night:
            return [
                Floater(isCloud: false, tint: nightOrbTint, baseX: 0.28, baseY: 0.62, scale: 1.05, travel: 0.06, period: 88,  offset: 0.0, opacity: 0.05),
                Floater(isCloud: false, tint: nightOrbTint, baseX: 0.70, baseY: 0.36, scale: 0.85, travel: 0.05, period: 108, offset: 0.45, opacity: 0.04),
                Floater(isCloud: false, tint: nightOrbTint, baseX: 0.52, baseY: 0.86, scale: 0.70, travel: 0.05, period: 124, offset: 0.8, opacity: 0.03),
            ]
        }
    }

    // Tints stay close to the canvas so blobs read as faint atmosphere lift, not coloured shapes.
    private var cloudTint: Color     { Color(light: "#C9D4E2", dark: "#7C8AA8") }
    private var duskCloudTint: Color { Color(light: "#D6BEA8", dark: "#8A6E78") }
    private var dawnOrbTint: Color   { Color(light: "#E8C9A4", dark: "#6E7AA0") }
    private var nightOrbTint: Color  { Color(light: "#B6C0D6", dark: "#3E4A74") }
}

/// One drifting atmosphere shape. All values are fractions of the view size so it scales freely.
private struct Floater {
    let isCloud: Bool       // cloud → wide ellipse; orb → round disc
    let tint: Color
    let baseX: CGFloat      // resting centre, fraction of width
    let baseY: CGFloat      // resting centre, fraction of height
    let scale: CGFloat      // diameter as a fraction of max(w,h) — huge by design
    let travel: CGFloat     // horizontal sweep amplitude, fraction of width
    let period: Double      // seconds for one full drift loop (slow)
    let offset: Double      // phase offset so shapes don't move in lockstep
    let opacity: Double     // <= 0.06 — atmosphere, never a blob
}

// MARK: - Modifier + convenience

public extension View {
    /// Place a subtle `TimeOfDayBackground` behind this content. Defaults to the current
    /// clock-derived part with drift on (drift auto-disables under Reduce Motion).
    ///
    ///     SomeScreen().timeOfDayBackground()              // auto, animated
    ///     SomeScreen().timeOfDayBackground(.night)        // pinned part
    ///     SomeScreen().timeOfDayBackground(.day, animated: false)
    func timeOfDayBackground(_ dayPart: DayPart = .current, animated: Bool = true) -> some View {
        background(TimeOfDayBackground(dayPart: dayPart, animated: animated))
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Time of Day — all four parts") {
    VStack(spacing: 0) {
        ForEach(DayPart.allCases, id: \.self) { part in
            ZStack {
                TimeOfDayBackground(dayPart: part)
                VStack(spacing: 4) {
                    Text(part.rawValue.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("88")
                        .font(StrandFont.display(44))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    .frame(width: 360, height: 720)
    .preferredColorScheme(.dark)
}
#endif
