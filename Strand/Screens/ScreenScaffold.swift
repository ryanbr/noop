import SwiftUI
import StrandDesign

/// Standard scrollable screen container: title + dark surface + content column.
struct ScreenScaffold<Content: View, Trailing: View>: View {
    /// Optional — when nil (and no subtitle) the header is omitted entirely, so a screen can supply its
    /// own custom header in `content` (iOS Today's compact top bar).
    let title: LocalizedStringKey?
    var subtitle: LocalizedStringKey? = nil
    /// Optional pull-to-refresh hook. When set, the scroll view becomes `.refreshable`
    /// (the standard iPhone gesture for a data dashboard). Defaults to nil so callers that
    /// don't opt in are unaffected — and on macOS `.refreshable` surfaces no affordance.
    var onRefresh: (() async -> Void)? = nil
    /// Lazily materialise the content column. When `true` the inner stack is a `LazyVStack`,
    /// so a screen whose content ends in a long `ForEach` only builds the cards on screen
    /// rather than all of them up-front — the fix for Intelligence "ALL" freezing on an
    /// 800+ day imported history (#345). Defaults to `false` so every existing caller keeps
    /// the eager `VStack` and its identical layout/scroll behaviour.
    var lazy: Bool = false
    /// Optional full-bleed view drawn behind the scroll content at the TOP of the screen (e.g. Today's
    /// day-cycle scene). Defaults to nil so other screens stay on the flat canvas; nil renders nothing.
    var topBackground: AnyView? = nil
    /// Optional element pinned to the header's trailing edge (e.g. the strap-battery badge on Today).
    /// Defaults to `EmptyView` via the convenience init below, so other screens are unaffected.
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    // iPad runs the shared screens full-screen, where an uncapped column gives 120+ character lines
    // in landscape. On iOS regular width (iPad) the readable column is capped + centred; compact
    // (iPhone) and macOS are unchanged. macOS also reports a horizontalSizeClass, so the cap is gated
    // by `#if os(iOS)` — a runtime size-class check alone would also narrow the Mac detail pane.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// Bumped (via the environment) when the iOS tab shell wants THIS screen scrolled to the top — an
    /// at-root re-tap of the active tab (#198 follow-up). Default 0 never changes, so macOS and every
    /// non-tab screen keep their exact prior scroll behaviour.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // Scroll-to-top anchor (#198 follow-up): a zero-height marker pinned above the content so an
            // at-root tab re-tap can bring the screen back to the very top. Layout-neutral.
            Color.clear.frame(height: 0).id(screenScaffoldTopAnchorID)
            column
            #if os(iOS)
            // Unified side margins matching the liquid home (16pt) so every page's cards + header line up
            // to the same edges (2026-07-02); macOS keeps the classic 28 in the #else branch.
            .padding(.horizontal, 16)
            .padding(.top, 24)
            // The tab bar floats over the scroll content, so the last card sat hidden behind it.
            // Reserve extra bottom scroll room so every screen's final card clears the floating bar.
            .padding(.bottom, NoopMetrics.tabBarClearance)
            // iPad: cap the readable column, then centre it in the full-width scroll viewport.
            // iPhone (.compact): the inner frame is .infinity/.leading, identical to before.
            .frame(maxWidth: hSizeClass == .regular ? 700 : .infinity,
                   alignment: hSizeClass == .regular ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            #else
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        #if os(iOS)
        // #697: stop a vertical scroll from drifting/bouncing the screen left-right. `.basedOnSize` only
        // permits horizontal bounce when content genuinely overflows the width (it does not here, the column
        // is width-capped), so the spurious horizontal rubber-band that caused the sideways drift is gone.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        // The flat canvas, plus an optional full-bleed TOP backdrop (Today's day-cycle scene) drawn behind
        // the scroll content — edge-to-edge under the status bar. The scene is CONFINED to the header+hero
        // band (see SceneScreenBackground.height) so it fades out ABOVE the dashboard cards, which then sit
        // on the opaque canvas and stay fully legible (2026-06-23: cards were "losing the data").
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                topBackground
            }
            .ignoresSafeArea()
        }
        .modifier(RefreshableIfNeeded(onRefresh: onRefresh))
        #if os(macOS)
        // The mac window toolbar's default vibrant material washed the top of the liquid day-of-sky WHITE
        // (the scroll-under-titlebar blend). Hide it so the sky reads edge-to-edge and dark, like iOS.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // Scroll-to-top on an at-root tab re-tap (#198 follow-up). iOS-only: the tab shell is the only
        // driver, and gating here keeps the two-param onChange off macOS 13. Inert until the signal moves.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(screenScaffoldTopAnchorID, anchor: .top) }
        }
        #endif
        }
    }

    /// The header + content column. `lazy` swaps the eager `VStack` for a `LazyVStack` so a long
    /// trailing `ForEach` (Intelligence "ALL") builds cards on demand instead of all at once. The
    /// alignment/spacing/header are identical in both branches, so the non-lazy path is byte-for-byte
    /// the previous layout. `@ViewBuilder` lets the two stack types resolve to one opaque return.
    @ViewBuilder private var column: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 20) {
                if title != nil || subtitle != nil { header }
                content()
            }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if title != nil || subtitle != nil { header }
                content()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    // Match the liquid home's title face (SF Rounded 28) so every page's header reads
                    // identically (2026-07-02 cohesion pass).
                    Text(title).font(StrandFont.rounded(28)).foregroundStyle(StrandPalette.textPrimary)
                }
                if let subtitle {
                    Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    /// Convenience init for the common case with no header trailing element — keeps every existing
    /// call site (which never passed `trailing`) source-compatible.
    init(title: LocalizedStringKey?, subtitle: LocalizedStringKey? = nil,
         onRefresh: (() async -> Void)? = nil, lazy: Bool = false, topBackground: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, onRefresh: onRefresh, lazy: lazy,
                  topBackground: topBackground, trailing: { EmptyView() }, content: content)
    }
}

/// Applies `.refreshable` only when a refresh hook is provided. A ViewModifier (rather than an
/// inline `if`) keeps the two branches the same opaque type, and means nil callers — every macOS
/// screen — never attach the modifier at all.
private struct RefreshableIfNeeded: ViewModifier {
    let onRefresh: (() async -> Void)?
    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable { await onRefresh() }
        } else {
            content
        }
    }
}

/// Empty / pending-data placeholder for screens still gathering history. Mirrors `DataPendingNote`'s
/// icon-anchored card so an empty screen reads as an intentional state rather than a stray text box.
struct ComingSoon: View {
    let what: LocalizedStringKey
    var symbol: String = "sparkles"
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Coming together")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(what)
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface()
    }
}

/// A reusable "what shows now vs what needs an import" note. Bold title line plus a
/// body line, with an info/sparkles SF Symbol. Used for empty/pending data states so
/// every screen explains the live-now path and the import path with timing.
/// Pulsing "history sync in progress" line (#77). Shown above a screen's empty state while the
/// strap's historical offload runs, so a half-loaded screen ("No nights here yet") reads as
/// in-progress rather than final. Shows the honest live signal — chunks pulled so far — never a
/// percent (total pending is unknowable from the protocol, so a determinate bar would lie).
struct SyncingHistoryNote: View {
    let chunks: Int

    var body: some View {
        HStack(spacing: 10) {
            StatePill("Syncing strap history…", tone: .accent, pulsing: true)
            if chunks > 0 {
                Text("\(chunks) chunks pulled")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

/// Coarse relative-time label for the "History synced N ago" sync-status line. Pure — `now` is
/// injectable so the bucket edges are unit-testable (RelativeAgoTests) — and deliberately the same
/// buckets as the Android `relativeAgo` (LiveScreen.kt, ed6a31d) so the two apps read identically.
/// Clamps future timestamps (strap-clock skew) to "just now", never negative.
func relativeAgo(_ epochSeconds: TimeInterval,
                 now: TimeInterval = Date().timeIntervalSince1970) -> String {
    let d = max(0, Int(now - epochSeconds))
    switch d {
    case ..<60:     return String(localized: "just now")
    case ..<3600:   return String(localized: "\(d / 60) min ago")
    case ..<86_400: return String(localized: "\(d / 3600) h ago")
    default:        return String(localized: "\(d / 86_400) d ago")
    }
}

struct DataPendingNote: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var symbol: String = "sparkles"

    var body: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Scroll-to-top signal (#198 follow-up)

/// An incrementing token the iOS tab shell bumps when the user re-taps the ALREADY-at-root active tab,
/// to scroll that tab's root screen to the top (the other half of the iOS tab convention #197/#198 left
/// unserved — an at-root re-tap is otherwise a no-op). `ScreenScaffold` and `LiquidTodayView` observe it
/// and scroll to their top anchor when it changes. Default 0 is never bumped outside the tab shell, so
/// macOS (sidebar, no tab re-tap) and every non-tab screen are completely unaffected.
/// Zero-height scroll-to-top target id. File scope, not a `static` on `ScreenScaffold` — the latter is
/// generic (`<Content, Trailing>`) and Swift forbids stored static properties on generic types.
private let screenScaffoldTopAnchorID = "screenScaffold.top"

private struct ScrollToTopSignalKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var scrollToTopSignal: Int {
        get { self[ScrollToTopSignalKey.self] }
        set { self[ScrollToTopSignalKey.self] = newValue }
    }
}
