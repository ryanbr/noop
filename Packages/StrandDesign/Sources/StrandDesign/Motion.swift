import SwiftUI

// MARK: - Strand Motion (§9.6)
//
// Physiological motion — breathe / pulse / flow, no cartoon bounce.
// Ring draw-in, per-beat ripple, hover lift, sliding sidebar indicator.

public enum StrandMotion {

    // MARK: Spring presets

    /// Interactive spring — snappy, for direct manipulation (hover, press, sidebar slide).
    public static let interactive = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.1)

    /// Gentle spring — the house style for value changes (ring draw-in, gauges).
    /// spring(response: 0.5, damping: 0.8) per the brief.
    public static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.8)

    /// A slower, more deliberate spring for hero transitions (e.g. first ring materialize).
    public static let hero = Animation.spring(response: 0.85, dampingFraction: 0.85)

    // MARK: Durations

    /// Fast UI feedback (hover lift, chip state).
    public static let durationFast: Double = 0.18

    /// Standard transition (card appear, fades).
    public static let durationStandard: Double = 0.30

    /// Deliberate sheet presentation / navigation settle.
    public static let durationSheet: Double = 0.42

    /// Slow / draw-in (ring arc, waveform ignite).
    public static let durationSlow: Double = 0.9

    /// One breath cycle for ambient pulsing (bloom, listening flatline).
    public static let breathPeriod: Double = 3.2

    // MARK: Curves

    /// Ease for the ring/gauge draw-in when a value changes.
    public static let drawIn = Animation.easeOut(duration: durationSlow)

    /// The ring/gauge draw-in, suppressed when Reduce Motion is on. Returns `nil`
    /// (no animation) when reduced so `withAnimation` sets the fraction instantly and
    /// the arc/bead snaps to its final frame instead of sweeping. Mirrors
    /// `breathe(reduced:)` and honours Apple's Reduce Motion HIG.
    public static func drawIn(reduced: Bool) -> Animation? {
        reduced ? nil : drawIn
    }

    /// Looping breathe animation for ambient glow/pulse.
    public static var breathe: Animation {
        .easeInOut(duration: breathPeriod).repeatForever(autoreverses: true)
    }

    /// Looping breathe animation, suppressed when Reduce Motion is on. Returns
    /// `nil` (no animation) when reduced so call sites collapse to the resting
    /// frame instead of an indefinite loop. Honours Apple's Reduce Motion HIG.
    public static func breathe(reduced: Bool) -> Animation? {
        reduced ? nil : breathe
    }

    /// A single heartbeat ripple pulse.
    public static let pulse = Animation.easeOut(duration: 0.6)

    /// Standard fade.
    public static let fade = Animation.easeInOut(duration: durationStandard)

    // MARK: Shell transitions (iOS split tab bar + quick-launch panel)

    /// Delay between dismissing one system sheet and presenting its replacement.
    public static let sheetSwapDelay: Double = 0.05

    /// Delay before the edit-mode chrome and tile state overlap their exits.
    public static let editExitLeadDelay: Double = 0.04

    /// Completion point for the overlapping edit-mode exit.
    public static let editExitCompletionDelay: Double = 0.22

    /// Completion point for an `interactive` drag settle.
    public static let interactiveSettleDelay: Double = 0.28

    /// The design-system "calm" easing — the global tab crossfade / panel curve.
    /// cubic-bezier(0.22, 1, 0.36, 1) at the standard tab-swap duration.
    public static let calm = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)

    /// `calm`, suppressed under Reduce Motion (returns `nil` so the change applies instantly).
    public static func calm(reduced: Bool) -> Animation? { reduced ? nil : calm }

    /// Calm easing at the fast duration — chrome/label swaps that shouldn't linger.
    public static let calmQuick = Animation.timingCurve(0.22, 1, 0.36, 1, duration: durationFast)

    /// `calmQuick`, suppressed under Reduce Motion.
    public static func calmQuick(reduced: Bool) -> Animation? { reduced ? nil : calmQuick }

    /// Quick-launch panel open/close — also the interactive pull-down finish, so opening,
    /// button-dismiss, and pull-to-dismiss share one measured curve. The native glass transition needs
    /// enough time for its lensing to read, without spring overshoot extending the material past content.
    public static let panel = Animation.easeInOut(duration: durationStandard)

    /// `panel`, suppressed under Reduce Motion.
    public static func panel(reduced: Bool) -> Animation? { reduced ? nil : panel }

    /// System-sheet presentation on the same calm curve, at its deliberate presentation duration.
    public static let sheet = Animation.timingCurve(0.22, 1, 0.36, 1, duration: durationSheet)

    /// `sheet`, suppressed under Reduce Motion.
    public static func sheet(reduced: Bool) -> Animation? { reduced ? nil : sheet }

    /// Brief tap/selection fade (grid-tile launch, drop-target highlight).
    public static let tap = Animation.easeInOut(duration: 0.15)

    /// `tap`, suppressed under Reduce Motion.
    public static func tap(reduced: Bool) -> Animation? { reduced ? nil : tap }

    /// Quick chrome fade-out (edit-mode exit, remove-badge appearance).
    public static let quick = Animation.easeOut(duration: durationFast)

    /// `quick`, suppressed under Reduce Motion.
    public static func quick(reduced: Bool) -> Animation? { reduced ? nil : quick }

    /// Lifting a dragged tile off the grid — snappier than `interactive`.
    public static let lift = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.78)

    /// `lift`, suppressed under Reduce Motion.
    public static func lift(reduced: Bool) -> Animation? { reduced ? nil : lift }

    /// One half-cycle of the home-screen-style edit jiggle. The per-item duration and delay remain
    /// inputs so neighbouring tiles drift naturally, while the animation construction stays canonical.
    public static func jiggle(halfCycle: Double, delay: Double) -> Animation {
        .easeInOut(duration: halfCycle)
            .repeatForever(autoreverses: true)
            .delay(delay)
    }
}

#if DEBUG
private struct MotionDemo: View {
    @State private var on = false
    @State private var breathing = false
    var body: some View {
        VStack(spacing: 32) {
            Circle()
                .fill(StrandPalette.accent)
                .frame(width: 60, height: 60)
                .offset(y: on ? -24 : 24)
                .animation(StrandMotion.gentle, value: on)
            Circle()
                .fill(StrandPalette.recovery100)
                .frame(width: 60, height: 60)
                .scaleEffect(breathing ? 1.12 : 0.9)
                .opacity(breathing ? 0.9 : 0.5)
                .onAppear { breathing = true }
                .animation(StrandMotion.breathe, value: breathing)
            Button("Toggle gentle spring") { on.toggle() }
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(width: 360, height: 320)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("Motion") { MotionDemo() }
#endif
