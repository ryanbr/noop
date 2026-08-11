import SwiftUI

/// Ring geometry and glyph tones for the charge-to-sync control.
///
/// Named rather than inline so the morph's two halves cannot drift apart: the entry and the wind-down
/// each interpolate between the SAME battery and spinner values, and a literal edited on one side only
/// is exactly the kind of asymmetry that reads as "one direction feels wrong" without being visible in a
/// diff. These are one component's internal drawing values — stroke weights and glyph tones — rather
/// than layout spacing, so they stay file-private instead of joining `NoopMetrics`, whose scale is for
/// margins BETWEEN things. The ring's inset is the exception and does live there, because the header
/// sizes its sibling controls against it.
private enum SyncRing {
    /// Stroke weight of the resting battery arc, and of the spinner it becomes.
    static let batteryWidth: CGFloat = 3.0
    static let spinnerWidth: CGFloat = 2.6
    /// The unfilled track sitting behind the spinner arc, and its tone.
    static let trackWidth: CGFloat = 2.4
    static let trackOpacity: Double = 0.13

    /// Point size of the central numeral. The battery percentage and the chunk tally share it so that
    /// across the morph one appears to replace the other in place.
    static let numberSize: CGFloat = 9
    /// Tone of that numeral, and the scale floor it recedes to as it crossfades out.
    static let numberOpacity: Double = 0.9
    static let numberMinScale: Double = 0.92

    /// The charging bolt: point size, and how far above centre it clears the ring.
    static let boltSize: CGFloat = 7
    static let boltOffset: CGFloat = -10

    /// Glyph sizes for the states that are a symbol rather than a reading, and their shared tone. The
    /// bolt carries a real reading (we know it is charging) so it is drawn at full weight; the ellipsis
    /// stands in for a reading we do not have yet, and sits at the numeral's size instead.
    static let symbolGlyphSize: CGFloat = 11
    static let ellipsisGlyphSize: CGFloat = 9
    static let dimGlyphOpacity: Double = 0.5

    /// The transient "Syncing" label's tone.
    static let labelOpacity: Double = 0.92

    /// Stroke weight `eased` of the way from the battery ring to the spinner. The entry passes its own
    /// progress and the wind-down passes the inverse, so both traverse one identical ramp rather than
    /// two hand-written ones that have to be kept in agreement.
    static func width(eased: Double) -> CGFloat {
        batteryWidth + (spinnerWidth - batteryWidth) * eased
    }

    /// Numeral scale for a crossfade at `opacity`: full size when fully visible, easing down to
    /// `numberMinScale` as it goes, so it recedes rather than simply vanishing.
    static func numberScale(opacity: Double) -> Double {
        numberMinScale + (1 - numberMinScale) * opacity
    }
}

/// Compact strap-battery chrome that morphs into an activity indicator while history is syncing.
///
/// The indicator owns its visual transition so screens only provide honest battery and sync state.
/// Its expanded width participates in the surrounding layout, pushing earlier controls aside instead
/// of painting over them. Motion-saving modes replace the morph and rotation with a static state.
public struct ChargeSyncIndicator: View {
    public enum BatteryState: Equatable {
        case offline
        case pending(charging: Bool)
        case charge(percent: Double, charging: Bool)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    private let batteryState: BatteryState
    private let syncing: Bool
    /// Chunks acked this session. Rendered inside the spinner, in the spot the battery percentage
    /// occupies when idle — 0 shows nothing, so a live-HR-only session spins with a bare ring.
    private let chunks: Int
    private let label: LocalizedStringKey

    /// The label's natural width, measured by `labelWidthReader`. 0 until the first layout pass, which
    /// only leaves `expandedWidth` at its compact floor — and the capsule is compact then anyway.
    @State private var labelWidth: CGFloat = 0
    @State private var visualProgress = 0.0
    @State private var pillProgress = 0.0
    @State private var endingSync = false
    @State private var animationActive = false
    @State private var showsLabel = false
    @State private var spinStartedAt: Date?
    /// Spin angle the CURRENT entry started from. The entry sweeps `(spin − this) · eased`, never the raw
    /// `spin`: when a sync begins while the previous one is still winding down, `spinStartedAt` is not
    /// reset, so the raw angle can already be thousands of degrees — and scaling THAT by the entry curve
    /// swept every one of them in 1.25s, which is the "spins twenty times, very fast" on expansion.
    @State private var spinBaseDegrees = 0.0
    @State private var exitStartDegrees = 0.0
    @State private var exitStartArc = 0.30
    /// The arc the battery ring draws, in turns. Mirrors `ChargeSyncMorph`'s own derivation so the exit
    /// can pick up from exactly the angle the entry left the ring at.
    private var currentBatteryArc: Double {
        guard case .charge(let percent, _) = batteryState else { return 0 }
        return max(0.02, min(1, percent / 100))
    }
    @State private var announcementTask: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?
    /// A sync that arrived while the wind-down was already drawing, held until the ring is back at rest.
    /// See `beginSync` for why it waits rather than cutting in.
    @State private var restartAfterSettle = false

    public init(
        batteryState: BatteryState,
        syncing: Bool,
        chunks: Int = 0,
        label: LocalizedStringKey = "Syncing"
    ) {
        self.batteryState = batteryState
        self.syncing = syncing
        self.chunks = chunks
        self.label = label
    }

    /// The capsule's width once fully expanded: the ring, a gap, the label at its natural width, then
    /// the SAME gap trailing — so the padding reads even instead of dumping every spare point after the
    /// text. A fixed width cannot do this, because one constant has to serve "Syncing" (43pt) and
    /// "Sincronizzazione" (91pt) alike, and sizing for the latter leaves the former visibly lopsided.
    ///
    /// Capped at `syncIndicatorExpandedWidth`, which is exactly what the longest translations need at
    /// `syncIndicatorMinimumLabelScale` — past that they shrink to fit, as they already did, rather than
    /// widening the control and shoving the day title further aside on a phone-width header.
    private var expandedWidth: CGFloat {
        Self.expandedWidth(labelWidth: labelWidth)
    }

    /// Reports the label's natural width. Lives in a `background`, so it never influences layout itself,
    /// and carries the visible label's font and Dynamic Type cap so the number it reports is the width
    /// that label would actually ask for before `minimumScaleFactor` shrinks it.
    private var labelWidthReader: some View {
        Text(label, bundle: .module)
            .font(StrandFont.overline)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SyncLabelWidthKey.self,
                        value: proxy.size.width
                    )
                }
            )
            .opacity(0)
            .accessibilityHidden(true)
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            indicatorContents
                .frame(
                    width: NoopMetrics.compactControlSize,
                    height: NoopMetrics.compactControlSize
                )

            // `bundle: .module` here and on the measuring reader: `Text(LocalizedStringKey)` resolves
            // against `Bundle.main`, i.e. the APP, so without it the package's own catalog entry is never
            // read and only the app happening to carry the same key makes this look translated. Every
            // other string in StrandDesign passes `.module` for that reason (see `Package.swift`).
            //
            // `overline` supplies the face and weight, but NOT its `.tracking(1.4)` — the letter-spacing
            // is what makes an overline read as one, and this is sentence-case status copy.
            Text(label, bundle: .module)
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.labelOpacity))
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(NoopMetrics.syncIndicatorMinimumLabelScale)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(
                    width: expandedWidth
                        - NoopMetrics.compactControlSize
                        - NoopMetrics.syncIndicatorLabelSpacing,
                    alignment: .leading
                )
                .offset(
                    x: NoopMetrics.compactControlSize
                        + NoopMetrics.syncIndicatorLabelSpacing
                )
                .opacity(showsLabel ? 1 : 0)
                .accessibilityHidden(true)
        }
        // Measure ABOVE the animated frame. Attached below it, the reader's GeometryReader is proposed the
        // width that is mid-animation, so it re-emits a preference every frame; that rewrites `labelWidth`,
        // which recomputes `expandedWidth`, which moves the frame's own target — the spring re-targets on
        // every frame of the expansion, which is what made the circle-to-pill glitch. Up here the proposal
        // is the ZStack's natural size, which does not move while `pillProgress` animates.
        .background(labelWidthReader, alignment: .leading)
        .onPreferenceChange(SyncLabelWidthKey.self) { measured in
            // Ignore sub-point churn, so a rounding wobble cannot restart the animation.
            guard measured > 0, abs(measured - labelWidth) > 0.5 else { return }
            labelWidth = measured
        }
        .frame(
            width: NoopMetrics.compactControlSize
                + (expandedWidth - NoopMetrics.compactControlSize)
                * CGFloat(pillProgress),
            height: NoopMetrics.compactControlSize,
            alignment: .leading
        )
        // No surface of its own. The host supplies the chrome — on the Today header that is
        // `nativeLiquidGlassSyncButton()`, the same way every sibling control in the cluster gets its
        // material from `nativeLiquidGlassHeaderButton()`. Drawing a fixed near-black capsule here
        // instead would force every glyph onto the fixed `onDark*` tones to stay legible over it, which
        // is the trap #1013 describes and which #1160 already backed the Liquid hero out of.
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onAppear { updateSyncState(syncing) }
        .onChangeCompat(of: syncing) { updateSyncState($0) }
        .onDisappear {
            announcementTask?.cancel()
            settleTask?.cancel()
            // Land at rest rather than freezing mid-morph. Without this the view can go away with
            // `endingSync` still armed and no task left to clear it, and a later re-appearance would
            // queue its restart behind a wind-down that is never going to finish.
            finishSyncImmediately()
            restartAfterSettle = false
        }
    }

    @ViewBuilder
    private var indicatorContents: some View {
        switch batteryState {
        case .charge(let percent, let charging):
            ChargeSyncMorph(
                progress: visualProgress,
                ending: endingSync,
                active: animationActive,
                reducedMotion: poseStill,
                percent: percent,
                charging: charging,
                batteryTint: Self.ringColor(percent),
                spinBaseDegrees: spinBaseDegrees,
                chunks: chunks,
                spinStartedAt: spinStartedAt,
                exitStartDegrees: exitStartDegrees,
                exitStartArc: exitStartArc
            )
        default:
            ZStack {
                batteryContents.opacity(1 - visualProgress)
                syncingContents.opacity(visualProgress)
            }
        }
    }

    @ViewBuilder
    private var batteryContents: some View {
        switch batteryState {
        case .charge(let percent, let charging):
            Circle()
                .trim(from: 0, to: max(0.02, min(1, percent / 100)))
                .stroke(
                    Self.ringColor(percent),
                    style: StrokeStyle(lineWidth: SyncRing.batteryWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(NoopMetrics.syncIndicatorArcInset)
            Text("\(Int(percent.rounded()))")
                .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
            if charging {
                Image(systemName: "bolt.fill")
                    .font(StrandFont.number(SyncRing.boltSize, weight: .bold))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .offset(y: SyncRing.boltOffset)
            }
        case .pending(let charging):
            Image(systemName: charging ? "bolt.fill" : "ellipsis")
                .font(
                    StrandFont.number(
                        charging ? SyncRing.symbolGlyphSize : SyncRing.ellipsisGlyphSize,
                        weight: .bold
                    )
                )
                .foregroundStyle(
                    charging
                        ? StrandPalette.chargeColor
                        : StrandPalette.textPrimary.opacity(SyncRing.dimGlyphOpacity)
                )
        case .offline:
            Image(systemName: "bolt.slash")
                .font(StrandFont.number(SyncRing.symbolGlyphSize))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.dimGlyphOpacity))
        }
    }

    private var syncingContents: some View {
        TimelineView(
            .animation(
                minimumInterval: StrandMotion.syncIndicatorFrameInterval,
                paused: !animationActive || poseStill
            )
        ) { timeline in
            let phase = syncPhase(at: timeline.date)
            ZStack {
                Circle()
                    .stroke(
                        StrandPalette.liquidHeart.opacity(SyncRing.trackOpacity),
                        lineWidth: SyncRing.trackWidth
                    )
                    .padding(NoopMetrics.syncIndicatorArcInset)
                Circle()
                    .trim(from: 0, to: phase.arc)
                    .stroke(
                        StrandPalette.liquidHeart,
                        style: StrokeStyle(lineWidth: SyncRing.spinnerWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(phase.degrees - 90))
                    .padding(NoopMetrics.syncIndicatorArcInset)
                chunkNumber
            }
        }
    }

    /// The chunk tally inside the spinner, sharing the battery percentage's font and centre so the two
    /// read-outs occupy the same spot across the morph. Hidden at 0 — before the first chunk is acked
    /// there is no count to state, and a live-HR-only session never gets one.
    @ViewBuilder
    private var chunkNumber: some View {
        if chunks > 0 {
            Text("\(chunks)")
                .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
                .accessibilityHidden(true)
        }
    }

    private func updateSyncState(_ active: Bool) {
        if active {
            beginSync()
        } else {
            endSync()
        }
    }

    /// Snap to the settled battery state with no motion at all.
    ///
    /// Shared by the Reduce-Motion path in `endSync`, by the settle task (which has to RE-CHECK — see
    /// there), and by `onDisappear`, so "at rest" means one thing rather than three hand-written
    /// approximations of it.
    private func finishSyncImmediately() {
        visualProgress = 0
        pillProgress = 0
        showsLabel = false
        animationActive = false
        spinStartedAt = nil
        spinBaseDegrees = 0
        endingSync = false
    }

    /// True only for the state whose ring the wind-down actually parks at 12 o'clock. `.offline` and
    /// `.pending` render as a plain crossfade (see `indicatorContents`) with no ring to align.
    private var alignsRingOnExit: Bool {
        if case .charge = batteryState { return true }
        return false
    }

    /// Resume a sync that arrived mid wind-down, now that the ring is back at rest.
    ///
    /// Drops the settle handle FIRST: this runs from inside that very task, and `beginSync` cancels
    /// `settleTask` — which would otherwise be the running task cancelling itself.
    private func restartIfPending() {
        settleTask = nil
        guard restartAfterSettle else { return }
        restartAfterSettle = false
        beginSync()
    }

    private func beginSync() {
        // Mid wind-down: do NOT cut into it. `entryBody` and `exitBody` draw different geometry for the
        // same `visualProgress` — swapping between them mid-flight snaps the ring by up to ~150° of
        // rotation and ~40° of arc length at the worst crossover. The exit lasts at most one morph, and
        // the raw signal has already been quiet for the host's whole debounce to have got here, so let it
        // land and start clean: a fresh entry departs from the static battery ring, which is the one
        // state both halves of the morph agree on.
        if endingSync {
            restartAfterSettle = true
            return
        }

        settleTask?.cancel()
        announcementTask?.cancel()
        restartAfterSettle = false
        endingSync = false

        if animationActive {
            // Already spinning: an exit was scheduled but has not begun drawing — it is still waiting for
            // the ring to reach its hand-off angle. Cancelling that task above IS the whole resume; the
            // ring simply keeps turning. Re-anchoring `spinBaseDegrees` here would zero `travel` and jump
            // the head back to the battery gauge's angle, which is the same snap by another route.
        } else {
            spinStartedAt = Date()
            animationActive = true
            // A fresh clock reads ~0°, so the entry sweeps from the battery ring exactly as designed.
            spinBaseDegrees = 0
        }
        showsLabel = false
        animate(poseStill ? nil : StrandMotion.syncIndicatorVisual) {
            visualProgress = 1
        }
        animate(poseStill ? nil : StrandMotion.syncIndicatorMorph) {
            pillProgress = 1
        }

        if poseStill {
            showsLabel = true
        }

        announcementTask = Task { @MainActor in
            if !poseStill {
                try? await Task.sleep(
                    nanoseconds: StrandMotion.syncIndicatorLabelDelayNanoseconds
                )
                guard !Task.isCancelled else { return }
            }
            animate(poseStill ? nil : StrandMotion.syncIndicatorLabelIn) {
                showsLabel = true
            }

            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorLabelVisibilityNanoseconds
            )
            guard !Task.isCancelled else { return }
            animate(poseStill ? nil : StrandMotion.syncIndicatorLabelOut) {
                showsLabel = false
            }
            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorCollapseDelayNanoseconds
            )
            guard !Task.isCancelled else { return }
            animate(poseStill ? nil : StrandMotion.syncIndicatorMorph) {
                pillProgress = 0
            }
        }
    }

    private func endSync() {
        announcementTask?.cancel()
        restartAfterSettle = false

        guard animationActive else {
            settleTask?.cancel()
            visualProgress = 0
            pillProgress = 0
            showsLabel = false
            return
        }

        if poseStill {
            settleTask?.cancel()
            finishSyncImmediately()
            return
        }

        // A wind-down already drawing finishes on its own terms; restarting it here would re-capture the
        // hand-off angle from a ring that has already left it.
        guard !endingSync else { return }
        settleTask?.cancel()

        // The wind-down always covers the SAME distance, so it is always the same length as the entry.
        // Deriving the duration from "however far it happens to be from 12 o'clock" instead made the exit
        // anything from 0.28s to 2.5s against a fixed 1.25s entry, which is why one half read as quicker.
        // Rather than braking from wherever it is, wait for the ring to reach the point that far out — it
        // is already spinning, so up to one extra revolution costs nothing and keeps the rate constant.
        let rate = StrandMotion.syncIndicatorSpinRateDegrees
        let target = StrandMotion.syncIndicatorExitTravelDegrees
        let duration = StrandMotion.syncIndicatorMorphDuration

        let phase = syncPhase(at: Date())
        // The tail `entryBody` ACTUALLY draws — head minus length — not the raw spin angle. The two differ
        // by `(batteryArc − spinnerArc)·360`, and using the raw value started the exit a third of a turn
        // from the visible ring, which showed up as a phantom extra spin.
        // Mirrors `entryBody` exactly, base included — the entry sweeps from `spinBaseDegrees`, so an exit
        // that read the raw angle would aim the wind-down at a place the ring is not.
        let renderedTail = currentBatteryArc * 360
            + (phase.degrees - spinBaseDegrees)
            - phase.arc * 360
        let wrapped = renderedTail.truncatingRemainder(dividingBy: 360)
        let tailAngle = wrapped < 0 ? wrapped + 360 : wrapped
        let alignment = ((target - tailAngle).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / rate
        // ONLY `.charge` has a ring to park. `.offline` and `.pending` crossfade a glyph, so there is no
        // hand-off angle to wait for — and waiting anyway kept them spinning for up to a full extra
        // revolution (1.25s) on top of the host's 3s debounce, to align something not on screen.
        let lead = alignsRingOnExit ? alignment : 0

        animate(StrandMotion.syncIndicatorMorph) {
            showsLabel = false
            pillProgress = 0
        }

        settleTask = Task { @MainActor in
            // Keep spinning, untouched, until the ring is exactly `target` degrees short of 12 o'clock.
            if lead > 0 {
                try? await Task.sleep(nanoseconds: UInt64(lead * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }

            // RE-CHECK, do not trust the reading taken when the exit was scheduled: the wait above runs
            // for up to a full revolution, and Reduce Motion (or Low Power) can be switched on inside it.
            // Without this the wind-down still played its full linear morph to a user who had just asked
            // for no motion.
            guard !poseStill else {
                finishSyncImmediately()
                restartIfPending()
                return
            }

            let atStart = syncPhase(at: Date())
            exitStartDegrees = currentBatteryArc * 360
                + (atStart.degrees - spinBaseDegrees)
                - atStart.arc * 360
            exitStartArc = atStart.arc
            endingSync = true
            // Linear in time on purpose: `exitBody` applies the deceleration curve analytically, so what
            // it draws is that curve rather than two easings composed on top of each other.
            animate(.linear(duration: duration)) {
                visualProgress = 0
            }

            try? await Task.sleep(
                nanoseconds: UInt64(
                    (duration + StrandMotion.syncIndicatorExitSettleMargin) * 1_000_000_000
                )
            )
            guard !Task.isCancelled else { return }
            animationActive = false
            spinStartedAt = nil
            spinBaseDegrees = 0
            endingSync = false
            // The ring is back at rest, so a sync that arrived mid wind-down can now start cleanly.
            restartIfPending()
        }
    }

    private func syncPhase(at date: Date) -> (degrees: Double, arc: Double) {
        StrandMotion.syncIndicatorPhase(since: spinStartedAt, at: date, posed: poseStill)
    }

    private func animate(_ animation: Animation?, changes: () -> Void) {
        withAnimation(animation, changes)
    }

    /// The three bands a strap charge reads in. Split from the colour lookup so the thresholds can be
    /// pinned by a test: SwiftUI `Color` wraps dynamic catalog colours in a fresh provider per access, so
    /// two reads of one palette token are not `==` and a test asserting on the colour itself would be
    /// comparing identities rather than the banding it means to check.
    enum ChargeBand: Equatable {
        case critical
        case warning
        case healthy
    }

    /// Boundaries belong to the calmer band above them, so a strap sitting exactly on 35 does not read
    /// as a warning.
    static func chargeBand(_ percent: Double) -> ChargeBand {
        if percent < 15 { return .critical }
        if percent < 35 { return .warning }
        return .healthy
    }

    static func ringColor(_ percent: Double) -> Color {
        switch chargeBand(percent) {
        case .critical: return StrandPalette.statusCritical
        case .warning:  return StrandPalette.statusWarning
        case .healthy:  return StrandPalette.chargeColor
        }
    }

    /// The capsule's fully-expanded width for a label of `labelWidth`. Split out from the view so the
    /// hug-then-cap behaviour is testable directly: at 0 it must not fall below the compact circle, and a
    /// label longer than the cap must not be allowed to widen the control.
    static func expandedWidth(labelWidth: CGFloat) -> CGFloat {
        let hugged = NoopMetrics.compactControlSize
            + NoopMetrics.syncIndicatorLabelSpacing
            + labelWidth
            + NoopMetrics.syncIndicatorLabelSpacing
        return min(
            NoopMetrics.syncIndicatorExpandedWidth,
            max(NoopMetrics.compactControlSize, hugged)
        )
    }
}

/// Carries the sync label's natural width out of the measuring background. `max` because a single
/// reader publishes one value — the reduce only matters if SwiftUI ever evaluates it more than once.
private struct SyncLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChargeSyncMorph: View, Animatable {
    var progress: Double
    let ending: Bool
    let active: Bool
    let reducedMotion: Bool
    let percent: Double
    let charging: Bool
    /// Slack past the arc's head where its colour is held constant, so the round lineCap that overhangs
    /// there samples a pure colour rather than the blend band. See `arcSweep`.
    static let capPadTurns = 0.03

    let batteryTint: Color
    /// Spin base for the morph's own reads, mirroring what the entry is handed.
    let spinBaseDegrees: Double
    let chunks: Int
    let spinStartedAt: Date?
    let exitStartDegrees: Double
    let exitStartArc: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: StrandMotion.syncIndicatorFrameInterval,
                paused: !active || reducedMotion
            )
        ) { timeline in
            let p = max(0, min(1, progress))
            let phase = syncPhase(at: timeline.date)
            let batteryArc = max(0.02, min(1, percent / 100))

            if ending {
                exitBody(progress: p, batteryArc: batteryArc)
            } else {
                entryBody(
                    progress: p,
                    batteryArc: batteryArc,
                    spinnerArc: phase.arc,
                    // Relative to where this entry began — see `spinBaseDegrees`.
                    spinDegrees: phase.degrees - spinBaseDegrees
                )
            }
        }
    }

    private func exitBody(progress: Double, batteryArc: Double) -> some View {
        let exit = 1 - progress
        // Quadratic ease-out, NOT smootherstep. Its slope is 2 at the start, so paired with the duration
        // `endSync` derives, the rotation begins at exactly the steady spin rate and decays linearly to
        // rest — the spinner coasts to a stop. Smootherstep starts at zero slope, which halted the spin
        // dead and then performed a second, separate rotation up to the top.
        //
        // Entry is the mirror case and correctly keeps smootherstep: it departs from a STATIC ring, so
        // zero initial velocity is right there, and `spinDegrees · eased` already arrives at the spin
        // rate because the curve's slope is zero at its end too.
        let eased = StrandMotion.syncIndicatorEaseOutQuad(exit)

        let wrapped = exitStartDegrees.truncatingRemainder(dividingBy: 360)
        let remainder = wrapped < 0 ? wrapped + 360 : wrapped
        let degreesToTop = remainder == 0 ? 0 : 360 - remainder
        let degrees = exitStartDegrees + degreesToTop * eased
        // Length converges ON the same curve as the rotation, so the arc has become the percentage at the
        // exact moment the ring stops at 12 o'clock. Holding it and filling afterwards made the remaining
        // percent appear as a separate tacked-on growth.
        let arc = exitStartArc + (batteryArc - exitStartArc) * eased
        // One radius across the whole morph — only colour, sweep and stroke weight move.
        let inset = NoopMetrics.syncIndicatorArcInset
        // `1 − eased`, because the wind-down runs the entry's ramp backwards: at eased 0 it is still the
        // spinner's weight, and it has arrived back at the battery ring's by the time eased reaches 1.
        let lineWidth = SyncRing.width(eased: 1 - eased)

        return ZStack {
            Circle()
                .stroke(
                    StrandPalette.liquidHeart.opacity(SyncRing.trackOpacity * (1 - eased)),
                    lineWidth: SyncRing.trackWidth
                )
                .padding(inset)
            // One stroke carrying a travelling colour boundary — see `arcSweep`. On the way out the tint
            // recedes, so the battery colour grows back from the tail while the sync colour retreats
            // toward the head, arriving fully green as the ring parks at 12 o'clock.
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    arcSweep(tint: 1 - eased, arc: arc),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
            batteryNumber(opacity: eased)
            chunkNumber(opacity: 1 - eased)
        }
    }

    private func entryBody(
        progress: Double,
        batteryArc: Double,
        spinnerArc: Double,
        spinDegrees: Double
    ) -> some View {
        let eased = StrandMotion.syncIndicatorSmootherStep(progress)
        let arc = batteryArc + (spinnerArc - batteryArc) * eased

        // Rotation is anchored to the arc's HEAD — the point the gauge already ends at — so the spin sets
        // off from where the percentage sits instead of from 12 o'clock. `trim` draws tail-first, so the
        // tail is derived by subtracting the (shrinking) length back off the head. At progress 0 that
        // yields head = batteryArc·360 and tail = 0, i.e. exactly the battery ring, untouched.
        let travel = reducedMotion ? 0 : spinDegrees * eased
        let head = batteryArc * 360 + travel
        let degrees = head - arc * 360

        // Tint trails the motion rather than switching on contact: the ring departs still reading as the
        // battery and has fully turned over once it has swept `syncIndicatorColourTravelDegrees`. Driving
        // it off `eased` instead made the colour arrive with the shape, which is what read as a swap
        // rather than a transformation. Reduced motion has no travel to measure, so it falls back to the
        // shape's own curve.
        let tint = reducedMotion
            ? eased
            : min(1, travel / StrandMotion.syncIndicatorColourTravelDegrees)

        // One radius across the whole morph — only colour, sweep and stroke weight move.
        let inset = NoopMetrics.syncIndicatorArcInset
        let lineWidth = SyncRing.width(eased: eased)

        return ZStack {
            Circle()
                .stroke(
                    StrandPalette.liquidHeart.opacity(SyncRing.trackOpacity * tint),
                    lineWidth: SyncRing.trackWidth
                )
                .padding(inset)
            // One stroke carrying a travelling colour boundary — see `arcSweep`.
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    arcSweep(tint: tint, arc: arc),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
            batteryNumber(opacity: 1 - tint)
            chunkNumber(opacity: tint)
        }
    }

    /// The arc's stroke as a sweep that turns over ALONG its length instead of all at once: the head
    /// carries the sync colour first and the boundary travels back toward the tail as `tint` rises, with
    /// a soft band so it reads as a gradient rather than an edge. Cross-fading two solid strokes changed
    /// every point of the ring at the same instant, which reads as one colour being swapped for another;
    /// a moving boundary reads as the ring itself turning over.
    ///
    /// Locations are in turns and line up with `trim`: both this gradient and the trim start at 3 o'clock,
    /// and `rotationEffect` carries the gradient around with the shape, so location 0 is always the tail.
    private func arcSweep(tint: Double, arc: Double) -> AngularGradient {
        let band = StrandMotion.syncIndicatorTintBandTurns
        let boundary = StrandMotion.syncIndicatorTintBoundary(tint: tint, arc: arc)

        // Colours at the arc's two ends, once the band has swept past them.
        let tailColor = boundary > 0 ? batteryTint : StrandPalette.liquidHeart
        let headColor = boundary < arc ? StrandPalette.liquidHeart : batteryTint

        // An AngularGradient WRAPS: location 1 meets location 0. The round lineCap at the tail overhangs
        // a few degrees before 0°, which wraps around and samples near location 1 — so the final stop has
        // to be the TAIL's colour, or the cap picks up the far end's colour and leaves a stray tip of it
        // on an otherwise uniform ring. `headPad` does the same job at the head, holding its colour for a
        // little past `arc` so that cap stays pure too. A cap overhangs by lineWidth/2 over the ring
        // radius — about 6° — so this pad is comfortably wider than it needs to be.
        let headPad = min(1, arc + ChargeSyncMorph.capPadTurns)
        let low = max(0, min(headPad, boundary - band))
        let high = max(low, min(headPad, boundary + band))
        return AngularGradient(
            stops: [
                .init(color: tailColor, location: 0),
                .init(color: tailColor, location: low),
                .init(color: headColor, location: high),
                .init(color: headColor, location: headPad),
                .init(color: tailColor, location: 1),
            ],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }

    /// The chunk tally, crossfading in as the battery percentage fades out — same font, weight and
    /// centre, so across the morph one number appears to replace the other in place. Hidden at 0.
    @ViewBuilder
    private func chunkNumber(opacity: Double) -> some View {
        if chunks > 0 {
            Text("\(chunks)")
                .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
                .scaleEffect(SyncRing.numberScale(opacity: opacity))
                .opacity(opacity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func batteryNumber(opacity: Double) -> some View {
        Text("\(Int(percent.rounded()))")
            .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
            .scaleEffect(SyncRing.numberScale(opacity: opacity))
            .opacity(opacity)
        if charging {
            Image(systemName: "bolt.fill")
                .font(StrandFont.number(SyncRing.boltSize, weight: .bold))
                .foregroundStyle(StrandPalette.chargeColor)
                .offset(y: SyncRing.boltOffset)
                .opacity(opacity)
        }
    }

    /// The same clock `ChargeSyncIndicator` reads when it captures the hand-off angle. One shared
    /// implementation rather than a matching pair: any divergence would put the wind-down somewhere the
    /// ring is not, and a comment asking two copies to stay identical does not enforce it.
    private func syncPhase(at date: Date) -> (degrees: Double, arc: Double) {
        StrandMotion.syncIndicatorPhase(since: spinStartedAt, at: date, posed: reducedMotion)
    }
}

public extension View {
    /// Fades long header copy underneath a trailing control row while reserving its footprint.
    ///
    /// `reserving` is the width the control row actually occupies, which the HOST measures and passes —
    /// it is not a constant here, because the cluster's composition belongs to the screen, not to the
    /// design system. `headerControlReserveWidth` is only the pre-measurement default, so the first
    /// frame is not laid out against a reserve of zero.
    func headerTrailingControlFadeMask(
        reserving reserve: CGFloat = NoopMetrics.headerControlReserveWidth
    ) -> some View {
        mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: NoopMetrics.headerTextFadeWidth)
                Color.clear.frame(width: max(0, reserve))
            }
        }
    }
}

#if DEBUG
private struct ChargeSyncIndicatorPreview: View {
    @State private var syncing = false
    private let greeting = "Good evening, Maximilian Alexander"
    private var toggleTitle: String {
        syncing ? "Finish sync" : "Start sync"
    }

    var body: some View {
        VStack(spacing: NoopMetrics.space5) {
            HStack(spacing: NoopMetrics.space2) {
                Text(verbatim: greeting)
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                    .lineLimit(2)
                    .headerTrailingControlFadeMask()
                HStack(spacing: NoopMetrics.space1) {
                    Circle()
                        .fill(StrandPalette.onDarkPrimary.opacity(0.16))
                        .frame(
                            width: NoopMetrics.compactControlSize,
                            height: NoopMetrics.compactControlSize
                        )
                    ChargeSyncIndicator(
                        batteryState: .charge(percent: 68, charging: false),
                        syncing: syncing
                    )
                    Circle()
                        .fill(StrandPalette.onDarkPrimary.opacity(0.16))
                        .frame(
                            width: NoopMetrics.compactControlSize,
                            height: NoopMetrics.compactControlSize
                        )
                }
            }

            Button {
                syncing.toggle()
            } label: {
                Text(verbatim: toggleTitle)
            }
            .font(StrandFont.body)
        }
        .padding(NoopMetrics.space5)
        .frame(width: 440, height: 180)
        .background(StrandPalette.accent)
        .preferredColorScheme(.dark)
    }
}

/// The control as a host presents it: chrome supplied from outside, on a theme-following surface.
///
/// `heroFill` / `heroBorder` stand in for the Today header's Liquid Glass — the point is not the exact
/// material but that the backdrop FLIPS with the scheme, which is the condition the glyph tone has to
/// survive. A fixed backdrop here would prove nothing, since a fixed light glyph looks fine on one.
private struct ChargeSyncIndicatorHosted: View {
    var syncing = true

    var body: some View {
        ChargeSyncIndicator(
            batteryState: .charge(percent: 68, charging: false),
            syncing: syncing,
            chunks: 3
        )
        .padding(NoopMetrics.syncIndicatorGlassPadding)
        .background(Capsule(style: .continuous).fill(StrandPalette.heroFill))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.heroBorder, lineWidth: 1))
        .padding(NoopMetrics.space5)
    }
}

#Preview("Charge to sync morph") {
    ChargeSyncIndicatorPreview()
}

// Both schemes, deliberately. The ring and numerals read through `StrandPalette.textPrimary`, which
// flips with the theme — so Light is not a duplicate of Dark, it is the case that actually regressed
// when the control carried a fixed near-black surface and had to use fixed light glyphs to sit on it.
#Preview("Charge sync active — Dark") {
    ChargeSyncIndicatorHosted()
        .preferredColorScheme(.dark)
}

#Preview("Charge sync active — Light") {
    ChargeSyncIndicatorHosted()
        .preferredColorScheme(.light)
}

#Preview("Charge idle — Light") {
    ChargeSyncIndicatorHosted(syncing: false)
        .preferredColorScheme(.light)
}
#endif
