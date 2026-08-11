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

    // MARK: Compact charge-to-sync indicator
    //
    // Only `syncIndicatorSignalDebounceNanoseconds` is `public`: the screen owns the raw sync signal and
    // therefore has to debounce it before handing it over. Everything else here is the indicator's own
    // internal timing, consumed exclusively by `ChargeSyncIndicator` in this module, so it stays
    // `internal` per the "public API is intentional" rule in docs/CONTRIBUTING.md.

    /// Responsive capsule geometry for the compact charge-to-sync indicator.
    static let syncIndicatorMorph = Animation.spring(
        response: 0.60,
        dampingFraction: 0.94,
        blendDuration: 0.14
    )

    /// Coordinated charge-number, arc, and colour transition.
    ///
    /// Matched to what the wind-down takes for an average half-turn (`2 · 180 / rate`), so both halves of
    /// the morph are the same length and read as one gesture. At a fixed 0.58s the entry ran to less than
    /// half the typical exit, which made the start feel instant against a visibly slower finish.
    ///
    /// Linear on purpose, like the exit: `entryBody` applies smootherstep itself, so the curve it draws is
    /// the curve you see instead of an easing composed on top of an easing.
    static var syncIndicatorVisual: Animation {
        .linear(duration: syncIndicatorMorphDuration)
    }

    /// Length of BOTH halves of the morph. Constant deceleration over `syncIndicatorExitTravelDegrees`
    /// takes `2 · distance / rate`; the entry is given the same, so neither half can feel quicker.
    static var syncIndicatorMorphDuration: Double {
        2 * syncIndicatorExitTravelDegrees / syncIndicatorSpinRateDegrees
    }

    /// Half-width, in turns, of the blend band that travels along the arc as it changes colour. Wide
    /// enough to read as a gradient rather than a hard edge, narrow enough that the two ends stay
    /// distinct mid-sweep.
    static let syncIndicatorTintBandTurns: Double = 0.10

    /// Transient label fades after the capsule has settled.
    static let syncIndicatorLabelIn = Animation.easeOut(duration: 0.26)
    static let syncIndicatorLabelOut = Animation.easeInOut(duration: 0.26)

    static let syncIndicatorFrameInterval = 1.0 / 60.0
    static let syncIndicatorSpinPeriod = 1.25

    /// Fixed sweep of the spinner arc, in turns.
    ///
    /// Deliberately NOT breathing. Rotation is anchored to the arc's head, so the tail's speed is
    /// `rate − 360·d(arc)/dt` — a breathing length modulates the tail by ~±17%, and with a 1.2s breath
    /// against a 1.25s spin that wobble lands at nearly the same screen position every revolution, which
    /// reads as the ring repeatedly slowing at one spot. A constant length makes both ends travel at
    /// exactly the spin rate, which is also what lets the wind-down hand off cleanly.
    static let syncIndicatorSpinnerArcTurns = 0.38

    /// Distance the wind-down covers. Fixed rather than "whatever is left to 12 o'clock", so the exit is
    /// always the same length as the entry; `endSync` waits for the ring to reach this far out instead.
    static let syncIndicatorExitTravelDegrees: Double = 180

    /// Grace period the SCREEN applies to the falling edge of the sync signal before it tells the
    /// indicator to wind down. Public because the raw signal is the screen's to own: `backfilling` drops
    /// between history chunks, and without this the control would flap back to the battery reading in the
    /// middle of one logical sync.
    public static let syncIndicatorSignalDebounceNanoseconds: UInt64 = 3_000_000_000

    static let syncIndicatorLabelDelayNanoseconds: UInt64 = 650_000_000
    static let syncIndicatorLabelVisibilityNanoseconds: UInt64 = 1_900_000_000
    static let syncIndicatorCollapseDelayNanoseconds: UInt64 = 240_000_000
    /// Steady spinner rate in degrees per second. Derived from the spin period rather than written out,
    /// so the wind-down cannot drift out of step with the spin it has to hand off from.
    static var syncIndicatorSpinRateDegrees: Double { 360 / syncIndicatorSpinPeriod }

    /// Grace after the wind-down lands before the morph view is torn down, so the swap back to the
    /// static battery ring happens on an already-settled frame rather than mid-motion.
    static let syncIndicatorExitSettleMargin: Double = 0.06

    /// How far the ring must sweep for the battery colour to finish becoming the sync colour. The tint
    /// trails the motion rather than switching on contact.
    ///
    /// A full turn, so the colour lands exactly as the entry ends. At half a turn it finished around the
    /// entry's midpoint and read as rushed: `spinDegrees` accrues at the full rate from the outset, so by
    /// the close of a 1.25s entry the ring has already carried 360°, not 180°.
    static let syncIndicatorColourTravelDegrees: Double = 360

    // MARK: Charge-to-sync curve math
    //
    // Pure, frame-free and therefore unit-testable — see `ChargeSyncIndicatorMathTests`. It lives here
    // rather than on the views because BOTH `ChargeSyncIndicator` and its `ChargeSyncMorph` child read
    // the same spin clock: the indicator captures the hand-off angle from it while the morph draws from
    // it, so two copies of the curve would put the wind-down somewhere the ring is not.

    /// Where the spinner is at `date`: rotation in degrees since `start`, and the arc's fixed length in
    /// turns. `posed` (a motion-saving mode) parks it at 0° with the arc still at full length, so the
    /// static state is the moving one stopped rather than a different shape.
    static func syncIndicatorPhase(
        since start: Date?,
        at date: Date,
        posed: Bool
    ) -> (degrees: Double, arc: Double) {
        let arc = syncIndicatorSpinnerArcTurns
        guard !posed else { return (0, arc) }
        let seconds = max(0, date.timeIntervalSince(start ?? date))
        return ((seconds / syncIndicatorSpinPeriod) * 360, arc)
    }

    /// Smootherstep (6t⁵ − 15t⁴ + 10t³). Every value the morph's ENTRY interpolates — arc, sweep, stroke
    /// weight and the colour blend — rides this one curve, so they start, travel and land together.
    ///
    /// The quintic rather than the classic 3t² − 2t³: smoothstep zeroes only the FIRST derivative at each
    /// end, so the morph still enters and leaves with a perceptible kick in acceleration. This also zeroes
    /// the second derivative, so it eases out of rest and back into it with no such break.
    static func syncIndicatorSmootherStep(_ value: Double) -> Double {
        let t = max(0, min(1, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Quadratic ease-out, `1 − (1 − t)²`: slope 2 at t = 0 falling linearly to 0 at t = 1 — constant
    /// deceleration. Used for the wind-down, whose duration is derived to match that opening slope to the
    /// spinner's actual rate, so the ring coasts to a stop instead of halting and then re-rotating.
    static func syncIndicatorEaseOutQuad(_ value: Double) -> Double {
        let t = max(0, min(1, value))
        return 1 - (1 - t) * (1 - t)
    }

    /// Position, in turns, of the travelling colour boundary along an arc of length `arc` at `tint`.
    ///
    /// Sweeps from `arc + band` down to `−band`, not from `arc` to 0, so the blend band clears the arc
    /// completely at BOTH ends. Sweeping only across `[0, arc]` left half a band width hanging over each
    /// end, which showed as a green tail still on the ring after it had otherwise fully turned red.
    static func syncIndicatorTintBoundary(tint: Double, arc: Double) -> Double {
        let band = syncIndicatorTintBandTurns
        return arc + band - tint * (arc + 2 * band)
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
