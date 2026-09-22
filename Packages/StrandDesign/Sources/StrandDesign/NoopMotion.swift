import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
// For the #2393 window-visibility gate. SwiftUI already makes AppKit types reachable on macOS (the
// palette's NSColor path relies on it), but the dependency is explicit here because this file names
// NSApplication and NSWindow directly rather than a type SwiftUI itself vends.
import AppKit
#endif

// MARK: - NoopMotion — the "Design Reset" motion set (WHOOP design language, 2026-06-22)
//
// The house motion language for the WHOOP-flavoured redesign: smooth, snappy, almost no
// bounce. Beauty is in the restraint — type, spacing and a single confident settle, NOT
// effects. There is NO glow here and nothing that pulses or loops; that lives elsewhere
// and is being retired. This file adds three things screens reach for constantly:
//
//   • a refined spring/transition set (screen / card / value)
//   • `CountUpText` — big scores/metrics tick up to their new value
//   • `.staggeredAppear(index:)` — list/grid items fade + rise in, once, in sequence
//   • `.softCardTransition()` — card insert/remove (opacity + a hair of scale)
//
// Every helper is PUBLIC, GPU-cheap (opacity / offset / scale only), and honours
// `@Environment(\.accessibilityReduceMotion)` — under Reduce Motion animations collapse
// to their final frame instantly, with no offset, scale or counting.
//
// This complements `StrandMotion` (the physiological breathe/pulse set) rather than
// replacing it: where StrandMotion leans organic, NoopMotion leans crisp and mechanical,
// matching the white-on-near-black WHOOP target.

public enum NoopMotion {

    // MARK: Springs — smooth, snappy, minimal bounce

    /// Screen-level spring — page pushes, sheet/tab swaps, large layout moves. A touch
    /// slower so big surfaces feel weighted, still effectively bounce-free.
    public static let screen = Animation.spring(response: 0.46, dampingFraction: 0.88)

    /// Card-level spring — the default for card insert/remove, row reflow, expand/collapse.
    /// The house tempo: `spring(response: 0.4, dampingFraction: 0.85)`.
    public static let card = Animation.spring(response: 0.40, dampingFraction: 0.85)

    /// Value-level spring — number ticks, gauge fraction, small chip/state changes. Snappy
    /// and tightly damped so a changing read-out settles cleanly without overshoot.
    public static let value = Animation.spring(response: 0.34, dampingFraction: 0.90)

    // MARK: Stagger

    /// Per-item delay for a staggered list/grid reveal. Index 0 fires immediately; each
    /// subsequent item waits `index * stagger` so a column ripples in top-to-bottom.
    public static let stagger: Double = 0.04

    /// The pre-reveal vertical offset for a staggered/appear item (rises UP into place).
    public static let riseOffset: CGFloat = 8

    // MARK: Reduce-Motion gating

    /// Returns `animation` normally, or `nil` (instant, no animation) when Reduce Motion is on,
    /// so a `withAnimation` / `.animation(_:value:)` call site snaps straight to the final frame.
    /// Mirrors `StrandMotion.drawIn(reduced:)`.
    @inline(__always)
    public static func gated(_ animation: Animation, reduced: Bool) -> Animation? {
        reduced ? nil : animation
    }
}

// MARK: - Quiet Motion — the ONE gate every never-settling animation consults
//
// #909 taught the live gauges to pose still in Low Power Mode, but it read the flag inside
// `Strand/Liquid` and so could only reach the liquid layer. Everything else that never settles —
// the day-cycle atmosphere drift, the guardian breath, the connection halo — kept running, and a
// user in Low Power Mode still paid for it. The Android half (#911) had already put its gate in
// `com.noop.ui.NoopMotion`, one process-wide monitor read through `rememberPoseStill()`; this is
// that same shape on Apple, moved down into StrandDesign so the design system's own surfaces can
// reach it too (`LiquidPowerMonitor` in the app target could not).
//
// Three signals, OR-ed:
//   1. `@Environment(\.accessibilityReduceMotion)` — the system-wide setting. Supplied by the call
//      site, because only a View can read the environment.
//   2. Low Power Mode — the OS-level "stop discretionary work" signal.
//   3. "Reduce motion in NOOP" — an in-app preference, default OFF, for people who want the app
//      quiet without putting the whole phone in battery saver.

/// "Reduce motion in NOOP" (opt-in, default OFF): pose every looping animation still and stop the
/// decorative motion sensor, without requiring system Low Power Mode or system Reduce Motion.
/// Toggled from Settings → Appearance.
///
/// **Apple-only for now — there is no Kotlin twin yet, and no parity to claim.** Android's
/// `rememberPoseStill()` reads two signals (system Reduce Motion ‖ battery saver); this third one is
/// tracked as #941. The KEY STRING is the cross-platform contract, so it is fixed here and Android must
/// adopt `"noop.quietMotion"` verbatim when it lands — a `.noopbak` round-trip carries the setting by
/// key, not by symbol name.
public enum QuietMotionPrefs {
    /// The `@AppStorage` / `UserDefaults` key shared by the Settings toggle and `NoopMotionState`.
    public static let enabledKey = "noop.quietMotion"
}

/// Publishes the two motion signals that have no SwiftUI environment key — Low Power Mode and the
/// in-app "Reduce motion in NOOP" preference — so any view can pose its looping animation still.
///
/// A singleton with ONE `NotificationCenter` observer rather than a per-view `DisposableEffect`,
/// for the reason #911 gives on the Android side: the liquid primitives alone have dozens of call
/// sites, and registering/unregistering an observer as gauges scroll in and out of view would be
/// churn introduced by the very change that exists to remove per-frame work.
///
/// Worth doing because a continuously-animating `Canvas` is not free: measured on an iPhone 17 Pro
/// simulator seeded with a real 746 MB store, the default Today screen sitting idle costs ~18% of a
/// CPU core in BOTH Debug and Release, and 0.0% once the live surfaces pose still.
@MainActor
public final class NoopMotionState: ObservableObject {
    public static let shared = NoopMotionState()

    /// System Low Power Mode / battery saver. Live: `.NSProcessInfoPowerStateDidChange` means
    /// toggling the setting takes effect without a relaunch.
    @Published public private(set) var isLowPower: Bool

    /// #2393, macOS only: every window of this app is hidden, minimised or fully covered, so nothing
    /// a frame loop draws can be seen.
    ///
    /// A decorative `TimelineView(.animation…)` keeps running when the app is hidden. A reporter
    /// measured NOOP at a third to half a core permanently on an M1 Pro, the largest single process on
    /// their machine, ahead of `WindowServer` — and Cmd+H did not reduce it, it RAISED it (28.8% to
    /// 49.3% of a core in one run, 34.2% to 41.8% in another, returning to baseline exactly on
    /// re-show). Their hypothesis is that the display link paces the timeline while the window is on
    /// screen and the schedule free-runs once it is not. That is unproven and does not need to be true:
    /// drawing frames nobody can see is not worth doing either way.
    ///
    /// iOS and watchOS never set this. The system already stops rendering a backgrounded app there, and
    /// `scenePhase` covers what it does not; this is the gap AppKit leaves.
    @Published public private(set) var windowObscured: Bool = false

    /// The in-app "Reduce motion in NOOP" preference. Kept in step with `UserDefaults` so a
    /// non-SwiftUI reader (the motion sensor) and the `@AppStorage` toggle never disagree.
    @Published public private(set) var quietMotion: Bool

    private init() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        quietMotion = UserDefaults.standard.bool(forKey: QuietMotionPrefs.enabledKey)
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        // `@AppStorage` writes straight to UserDefaults without telling us, so mirror the store.
        // `.didChangeNotification` is the only signal that covers a write from any target.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = UserDefaults.standard.bool(forKey: QuietMotionPrefs.enabledKey)
                if self?.quietMotion != now { self?.quietMotion = now }
            }
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // #2393: hide/unhide covers Cmd+H, occlusion covers "another window is over it" and, with the
        // miniaturise pair, the Dock. They all land on one recompute rather than each setting the flag
        // its own way: the states overlap (hiding an app also occludes its windows) and a flag written
        // from five places would disagree with itself the moment two of them arrived out of order.
        for name in [NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowObscured() }
            }
        }
        #endif
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// Recompute [windowObscured] from AppKit's current window list. Cheap: a handful of windows, and
    /// it runs on notifications a user generates by hand, not on a clock.
    private func refreshWindowObscured() {
        // `.titled` is what separates a real app window from the `MenuBarExtra`'s status-item window,
        // which lives in `NSApplication.shared.windows` for the whole life of the process and would
        // otherwise report something on screen forever.
        //
        // #2397: this was `canBecomeMain`, and that was wrong in the one case the gate exists for.
        // `canBecomeMain` describes a window's CURRENT STATE, not its kind: a hidden or miniaturised
        // window answers false, so the real window left the filtered list at exactly the moment the gate
        // should have closed, the list went empty, and the empty-list rule below then read that as "not
        // obscured". Two individually reasonable decisions cancelling out. @nichtlegacy measured it:
        //
        //     visible     all=3  cbm=1  titled=2 (one on screen)   obscured=N
        //     hidden      all=4  cbm=0  titled=2 (none on screen)  obscured=N, should be Y
        //     minimised   all=4  cbm=0  titled=2 (none on screen)  obscured=N, should be Y
        //
        // `NSStatusBarWindow` reported `titled=N` in every state they logged, and the app window kept
        // `titled=Y` in all three, which is the property this needs and `canBecomeMain` never had.
        let windows = NSApplication.shared.windows
            .filter { $0.styleMask.contains(.titled) }
            .map { WindowVisibility(onScreen: $0.isVisible && $0.occlusionState.contains(.visible)) }
        let now = NoopMotionState.obscured(windows)
        if windowObscured != now { windowObscured = now }
    }
    #endif

    /// One app window's contribution to the gate, as the pure decision sees it.
    ///
    /// #2397: a struct rather than two loose Bools because the decision is about a LIST of windows, and
    /// the bug it replaces was invisible to a test that could only be handed a summary. Given
    /// `hasWindows`/`anyWindowOnScreen` there was no way to express "the app window is hidden while the
    /// status-item window is on screen", which is the exact state that was misread.
    struct WindowVisibility: Equatable {
        /// Visible AND not fully occluded: what `isVisible && occlusionState.contains(.visible)` answers.
        let onScreen: Bool
    }

    /// Pure half of the recompute, so the rule can be tested without AppKit.
    ///
    /// Takes the already-filtered app windows: every entry is a titled window, the status-item window
    /// having been dropped by the caller. Obscured means "there are app windows and none of them is on
    /// screen".
    ///
    /// NO WINDOWS is deliberately NOT obscured, and the case is more common than it sounds: before the
    /// first window exists during launch, and again when someone closes the window and leaves NOOP
    /// running as a menu-bar app. Treating an empty list as "nothing on screen" would pose every surface
    /// still until the next occlusion notification arrived — a first frame of static gauges on the way
    /// to a live screen, caused by the optimisation. Nothing is lost by the other reading: with no
    /// window there is no view hierarchy, so there is no frame loop to stop.
    ///
    /// That rule is only safe while the filter is state-INDEPENDENT. Under #2394's `canBecomeMain` the
    /// list emptied whenever the window was hidden, so this clause silently answered the live question
    /// instead of the launch one. `.titled` keeps a hidden window in the list, which is what returns this
    /// rule to the case it was written for.
    ///
    /// `nonisolated` because the enclosing class is `@MainActor` and this decides nothing that needs the
    /// main actor — without it a test could not call it off the main actor at all.
    nonisolated static func obscured(_ windows: [WindowVisibility]) -> Bool {
        !windows.isEmpty && !windows.contains { $0.onScreen }
    }

    /// The gate. `reduceMotion` comes from `@Environment(\.accessibilityReduceMotion)` at the call
    /// site — the environment is the only place SwiftUI publishes it, and reading it imperatively
    /// would not invalidate the view when the user changes the setting.
    ///
    /// ```swift
    /// @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// @ObservedObject private var motion = NoopMotionState.shared
    /// private var poseStill: Bool { motion.poseStill(reduceMotion) }
    /// ```
    @inline(__always)
    public func poseStill(_ reduceMotion: Bool) -> Bool {
        reduceMotion || isLowPower || quietMotion || windowObscured
    }

    /// The non-environment signals on their own, for an imperative (non-View) reader that supplies its
    /// own Reduce Motion read — e.g. the decorative motion sensor deciding whether to start at all.
    /// Views must use `poseStill(_:)` instead so they invalidate correctly.
    public var poseStillIgnoringReduceMotion: Bool { isLowPower || quietMotion || windowObscured }
}

// MARK: - CountUpText
//
// Animates a numeric value counting up (or down) to its latest value whenever `value`
// changes, and on first appear (from 0 → value). Driven by a custom `Animatable` modifier
// so it works on the iOS 16 / macOS 13 floor (no TimelineView spring / PhaseAnimator needed)
// and rides whatever animation the environment supplies — by default `NoopMotion.value`.
//
// Reduce Motion → the final value is shown instantly, with no tick.

/// A text view whose number animates from its previous value to the new one.
/// Use for the big scores / hero metric read-outs.
///
/// ```swift
/// CountUpText(value: score,
///             format: { "\(Int($0.rounded()))" },
///             font: StrandFont.display(72),
///             color: StrandPalette.textPrimary)
///     .tracking(StrandFont.displayTracking(72))
/// ```
public struct CountUpText: View {
    private let value: Double
    private let format: (Double) -> String
    private let font: Font
    private let color: Color
    private let animation: Animation

    /// The value currently being animated TO. `_AnimatableNumber` interpolates from the
    /// last committed `target` to this one; on appear it starts the run from 0.
    @State private var target: Double = 0
    @State private var hasAppeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - value: the number to display / animate to.
    ///   - format: maps the (interpolated) number to its display string — round, clamp, add units here.
    ///   - font: the text font (e.g. `StrandFont.display(72)`).
    ///   - color: the text colour (e.g. `StrandPalette.textPrimary`).
    ///   - animation: the count-up curve. Defaults to `NoopMotion.value`.
    public init(value: Double,
                format: @escaping (Double) -> String,
                font: Font,
                color: Color,
                animation: Animation = NoopMotion.value) {
        self.value = value
        self.format = format
        self.font = font
        self.color = color
        self.animation = animation
    }

    public var body: some View {
        // `_AnimatableNumber` conforms to `Animatable`, so SwiftUI interpolates `number`
        // frame-by-frame under whatever animation wraps the `target` change.
        _AnimatableNumber(number: target, format: format, font: font, color: color)
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                if reduceMotion {
                    target = value                      // snap, no tick
                } else {
                    target = 0
                    withAnimation(animation) { target = value }
                }
            }
            .onChangeCompat(of: value) { newValue in
                if reduceMotion {
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { target = newValue }
                } else {
                    withAnimation(animation) { target = newValue }
                }
            }
            // Expose the formatted value to assistive tech as a single, stable label
            // (the visual ticking is decorative; VoiceOver reads the final number).
            .accessibilityElement()
            .accessibilityLabel(Text(format(value)))
    }
}

/// A `View` whose `number` is the animatable channel: SwiftUI interpolates it frame-by-frame
/// under whatever animation wraps the value change, and `body` re-renders `format(number)`
/// each frame. Conforming the VIEW to `Animatable` (rather than using the deprecated
/// `AnimatableModifier`) keeps this warning-clean on the iOS-17 / macOS-14 build while still
/// compiling on the iOS-16 / macOS-13 floor.
private struct _AnimatableNumber: View, Animatable {
    var number: Double
    let format: (Double) -> String
    let font: Font
    let color: Color

    var animatableData: Double {
        get { number }
        set { number = newValue }
    }

    var body: some View {
        Text(format(number))
            .font(font)
            .foregroundStyle(color)
            .fixedSize()                                // never truncate the number
            .accessibilityHidden(true)                  // CountUpText supplies the a11y label
    }
}

// MARK: - Staggered appear
//
// Fade-in + 8pt rise, sequenced by `index`. Runs ONCE per element (guarded by `hasAppeared`),
// so re-renders / scroll recycling don't re-trigger it. Reduce Motion → visible instantly,
// no offset.

private struct StaggeredAppear: ViewModifier {
    let index: Int
    let isVisible: Bool

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // `shown` is true once we've appeared (or immediately under Reduce Motion / when the
        // element is asked to appear without animation).
        let shown = hasAppeared || reduceMotion
        content
            .opacity(isVisible ? (shown ? 1 : 0) : 1)
            .offset(y: (isVisible && !shown) ? NoopMotion.riseOffset : 0)
            .onAppear {
                guard isVisible, !hasAppeared else { return }
                if reduceMotion {
                    hasAppeared = true                  // no animation, no delay
                } else {
                    let delay = Double(max(0, index)) * NoopMotion.stagger
                    withAnimation(NoopMotion.card.delay(delay)) {
                        hasAppeared = true
                    }
                }
            }
    }
}

public extension View {
    /// Fade-in + 8pt rise on first appearance, delayed by `index * 0.04s` for a sequenced
    /// list/grid reveal. Runs ONCE per element. Honours Reduce Motion (appears instantly,
    /// no offset).
    ///
    /// - Parameters:
    ///   - index: position in the sequence (0 = first / no delay).
    ///   - isVisible: set `false` to opt an element out of the animation (it stays fully shown).
    func staggeredAppear(index: Int, isVisible: Bool = true) -> some View {
        modifier(StaggeredAppear(index: index, isVisible: isVisible))
    }
}

// MARK: - Soft card transition
//
// For card insertion/removal inside an animated container (`if`/`ForEach`). Opacity + a
// tiny scale (0.98), asymmetric so an inserted card grows in and a removed card fades out
// without a jarring collapse. Reduce Motion → a plain opacity fade (no scale).

public extension AnyTransition {
    /// The house card insert/remove transition: opacity + a hair of scale. Pass
    /// `reduced:` from `@Environment(\.accessibilityReduceMotion)` so it degrades to a
    /// plain fade when Reduce Motion is on.
    static func softCard(reduced: Bool) -> AnyTransition {
        if reduced {
            return .opacity
        }
        let insertion = AnyTransition.opacity.combined(with: .scale(scale: 0.98, anchor: .center))
        let removal = AnyTransition.opacity.combined(with: .scale(scale: 0.98, anchor: .center))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

private struct SoftCardTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transition(.softCard(reduced: reduceMotion))
    }
}

public extension View {
    /// Applies the house card insert/remove transition (`opacity` + tiny `scale`), wired to
    /// Reduce Motion automatically. Drive the change with `NoopMotion.card`, e.g.
    /// `withAnimation(NoopMotion.card) { cards.append(...) }`.
    func softCardTransition() -> some View {
        modifier(SoftCardTransition())
    }
}

// MARK: - Preview

#if DEBUG
private struct NoopMotionDemo: View {
    @State private var score: Double = 72
    @State private var revealKey = 0
    @State private var cards: [Int] = [0, 1, 2]
    private let labels = ["SLEEP", "RECOVERY", "STRAIN", "HRV", "RHR", "CALORIES"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // CountUpText — the big score ticks to a new value.
                VStack(alignment: .leading, spacing: 8) {
                    Text("COUNT-UP SCORE").strandOverline()
                    CountUpText(value: score,
                                format: { "\(Int($0.rounded()))" },
                                font: StrandFont.display(72),
                                color: StrandPalette.textPrimary)
                        .tracking(StrandFont.displayTracking(72))
                    Button("Roll the number") {
                        withAnimation(NoopMotion.value) {
                            score = Double(Int.random(in: 12...99))
                        }
                    }
                    .foregroundStyle(StrandPalette.accent)
                }

                Divider().overlay(StrandPalette.hairline)

                // staggeredAppear — a list ripples in. `id` reset replays it.
                VStack(alignment: .leading, spacing: 8) {
                    Text("STAGGERED APPEAR").strandOverline()
                    VStack(spacing: 10) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                            HStack {
                                Text(label).font(StrandFont.headline)
                                Spacer()
                                Text("\(42 + i * 7)").font(StrandFont.number(20))
                            }
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(NoopPanelSurface(cornerRadius: 14))
                            .staggeredAppear(index: i)
                        }
                    }
                    .id(revealKey)
                    Button("Replay reveal") { revealKey += 1 }
                        .foregroundStyle(StrandPalette.accent)
                }

                Divider().overlay(StrandPalette.hairline)

                // softCardTransition — insert/remove.
                VStack(alignment: .leading, spacing: 8) {
                    Text("SOFT CARD TRANSITION").strandOverline()
                    VStack(spacing: 10) {
                        ForEach(cards, id: \.self) { c in
                            Text("Card \(c)")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(NoopPanelSurface(cornerRadius: 14))
                                .softCardTransition()
                        }
                    }
                    HStack {
                        Button("Add") {
                            withAnimation(NoopMotion.card) { cards.append((cards.max() ?? -1) + 1) }
                        }
                        Button("Remove") {
                            withAnimation(NoopMotion.card) { if !cards.isEmpty { cards.removeLast() } }
                        }
                    }
                    .foregroundStyle(StrandPalette.accent)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 720)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("NoopMotion") { NoopMotionDemo() }
#endif
