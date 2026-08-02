#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else reachable
/// through the quick-launch panel (a "+" circle beside the tab bar). Every screen is the same
/// `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices is not a tab, so a
    /// request presents it as a sheet alongside the quick-action and launch-panel destinations.
    @EnvironmentObject private var router: NavRouter

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Selected tab — bound so tab switches can use the design-system calm crossfade. Defaults to Today.
    @State private var selectedTab: Int = 0
    /// One `NavigationPath` per tab, indexed by tab tag. Re-tapping the already-active tab pops
    /// that tab's stack to its root (#135) by clearing its path — an animated pop that leaves the
    /// root view alive, so an at-root re-tap keeps scroll position and never re-runs `.task`
    /// (#198; the #197 resetID/`.id()` rebuild reset both). Requires the tab roots' first-hop
    /// links to push `TabRoute` values — closure-destination links bypass the path.
    @State private var tabPaths: [NavigationPath] = Array(repeating: NavigationPath(), count: 3)
    /// One scroll-to-top token per tab. Bumped when the user re-taps the active tab while it's ALREADY
    /// at its root — the other half of the iOS convention #197/#198 left unserved (an at-root re-tap was
    /// a no-op). Threaded into each tab's root via `\.scrollToTopSignal`; ScreenScaffold / LiquidTodayView
    /// scroll to their top anchor when their tab's token changes.
    @State private var scrollTop: [Int] = Array(repeating: 0, count: 3)
    /// Whether the quick-launch panel is visible above the tab bar.
    @State private var launchPanelOpen: Bool = false
    /// Current page in the launch panel (persists while panel is open).
    @State private var launchPanelPage: Int = 0
    /// A panel-item destination waiting to be presented as a sheet. Set after the panel closes.
    @State private var launchedDestination: LaunchDestination? = nil

    /// V8 liquid redesign is the default Today; the Settings toggle lets a user fall back to the classic
    /// Today if they prefer it (keyed identically to the SettingsView toggle). Default ON.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true

    /// Honour Reduce Motion: the tab crossfade and the launch-panel slide collapse to an instant
    /// (or opacity-only) change when the user has asked the system to minimise motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Today tab root, honouring the liquid/classic preference.
    @ViewBuilder private var todayTabRoot: some View {
        if liquidTodayEnabled { LiquidTodayView() } else { TodayView() }
    }

    init() {
        // Plain Titanium bar: pin the background to `surfaceBase` and clear the system
        // selection-indicator tint so there is NO gold/accent pill behind the selected
        // icon — the gold `.tint` below colours only the selected icon + label, nothing
        // is filled behind it. (UIKit derives a selection-indicator fill from the tint
        // unless it's explicitly cleared.)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(StrandPalette.surfaceBase)
        appearance.selectionIndicatorTintColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    /// The anywhere-swipe tab-switch drag (2026-07-02). Held as a property so the attachment site can
    /// enable or disable it through a `GestureMask` instead of attaching it conditionally: a conditional
    /// attachment changes view identity, and this condition toggles on every push and pop, which would
    /// rebuild the tab roots underneath it. The same class of rebuild is what #197 caused with an
    /// `.id()` reset and #198 had to undo — it lost scroll position and re-ran `.task`.
    ///
    /// Only a decisive horizontal flick switches tabs, and Today is carved out because it uses
    /// horizontal swipe to change DAYS. Both thresholds are unchanged from the original gesture.
    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { v in
                // Today (tab 0) uses horizontal swipe to change DAYS, so tab-swipe is off there.
                guard selectedTab != 0 else { return }
                let dx = v.translation.width, dy = v.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                let next = min(tabPaths.count - 1, max(0, selectedTab + (dx < 0 ? 1 : -1)))
                if next != selectedTab {
                    withAnimation(StrandMotion.calm(reduced: reduceMotion)) { selectedTab = next }
                }
            }
    }

    /// Keep the panel at its final frame while the material's lensing resolves in place. Opacity is
    /// deliberately non-spatial, and—unlike `.identity`—retains the disappearing hierarchy long enough
    /// for Liquid Glass to render its materialize-out phase as well as materialize-in.
    private var launchPanelTransition: AnyTransition {
        return .opacity
    }

    var body: some View {
        // The native TabView keeps the three primary roots and their navigation state; the custom
        // floating bar and quick-launch panel replace only its visual tab-bar chrome.
        ZStack(alignment: .bottom) {
            // The native TabView still drives content and per-tab navigation; only its bar is hidden.
            TabView(selection: $selectedTab) {
                tab(todayTabRoot, "Today", "square.grid.2x2", path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
                tab(TrendsView(), "Trends", "chart.line.uptrend.xyaxis", path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
                tab(SleepView(), "Sleep", "bed.double", path: $tabPaths[2], scrollSignal: scrollTop[2]).tag(2)
            }
            .tint(StrandPalette.accent)
            .toolbar(.hidden, for: .tabBar)
            // Design-system calm crossfade, suppressed under Reduce Motion.
            .animation(StrandMotion.calm(reduced: reduceMotion), value: selectedTab)
            // Swipe left/right anywhere to move between tabs (2026-07-02), but ONLY while the current
            // tab is at its root. Attaching this ancestor drag gesture unconditionally defeated the
            // edge-restriction of a pushed NavigationStack screen's native interactive-pop gesture —
            // a pushed screen became draggable/rubber-banding from anywhere, not just the left edge
            // (#519). Disabling the recognizer once a push is active, rather than just gating the
            // onEnded action, is what stops the interference: the action never runs early enough,
            // because the recognizer competes during recognition.
            //
            // The mask does that WITHOUT changing view identity. #519 attached the gesture through a
            // conditional ViewModifier, which put the two states in separate _ConditionalContent
            // branches — and since this condition toggles on every push and pop, each navigation
            // rebuilt the whole TabView subtree and could reset @State inside the tab roots (scroll
            // offsets and chart ranges). `including:` keeps one view type in both states, so nothing
            // is torn down.
            //
            // The mask MUST be `.subviews`, not `.none`. `.subviews` means "enable the subview
            // hierarchy's gestures, disable the added one" — exactly this requirement. `.none` disables
            // the subview hierarchy TOO, which on a pushed screen would take out scrolling, taps and the
            // interactive-pop itself: far worse than the bug being fixed.
            .simultaneousGesture(tabSwipeGesture,
                                 including: tabPaths[selectedTab].isEmpty ? .all : .subviews)
            // The panel is modal while visible: the dedicated backdrop below owns outside taps, and
            // disabling this layer guarantees a tap cannot also activate a control behind it.
            .allowsHitTesting(!launchPanelOpen)

            if launchPanelOpen {
                Button {
                    StrandHaptic.selection.play()
                    withAnimation(StrandMotion.panel(reduced: reduceMotion)) {
                        launchPanelOpen = false
                    }
                } label: {
                    Rectangle()
                        // An effectively transparent design-system fill keeps the whole backdrop in
                        // SwiftUI's hit-test tree without adding a visible scrim to the existing design.
                        .fill(StrandPalette.surfaceBase.opacity(0.001))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close menu")
                // This layer is already visually transparent and only owns outside taps. Letting it
                // inherit the animated transaction's default fade kept an invisible full-screen
                // rectangle alive briefly after the visible panel had closed.
                .transition(.identity)
            }

            // Split bar + panel stack — aligned to the bottom of the screen.
            VStack(spacing: NoopMetrics.space2) {
                if launchPanelOpen {
                    QuickLaunchPanel(
                        isOpen: $launchPanelOpen,
                        currentPage: $launchPanelPage,
                        onSelect: { id in
                            if id == "coach" {
                                presentCoachPage()
                            } else {
                                launchedDestination = destination(for: id)
                            }
                        }
                    )
                    // Native materialization drives the glass on iOS 26. The accompanying opacity
                    // transition has no geometry and keeps removal alive for the materialize-out pass.
                    .quickLaunchGlassTransition(reduceMotion: reduceMotion)
                    .transition(launchPanelTransition)
                }
                FloatingTabBar(
                    selection: $selectedTab,
                    panelOpen: $launchPanelOpen,
                    onReselect: { tag in
                        Task { await repo.refresh() }
                        if !tabPaths[tag].isEmpty {
                            tabPaths[tag] = NavigationPath()
                        } else {
                            scrollTop[tag] += 1
                        }
                    },
                    onCoach: presentCoachPage
                )
                // Everything outside the rectangle is dismiss-only while it is open. Disabling the
                // bar lets its taps fall through to the full-screen backdrop instead of switching tabs.
                .allowsHitTesting(!launchPanelOpen)
            }
            .quickLaunchGlassContainer()
            .padding(.horizontal, NoopMetrics.LaunchChrome.shellInset)
            .padding(.bottom, NoopMetrics.space1)
            // No ambient `.animation(value:)` here — the toggle sites (FloatingTabBar's +/× button and
            // the tap-outside dismiss above) already wrap the state change in `withAnimation`. Adding an
            // implicit animation on TOP of that double-drove the transition and made the panel's
            // appear/disappear look like two overlapping animations racing each other.
        }
        .task {
            await repo.refresh()
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        .sheet(item: $quickAction) { action in
            quickActionDestination(action)
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        // v5 pillar deep-links (Insights hub / Lab Book / fused record / Rhythm) present as a sheet in
        // their own nav stack — the same idiom the quick-action + Devices screens use on iPhone.
        .sheet(item: $routedPillar) { dest in
            pillarScreen(dest)
        }
        // Launch-panel destinations use the same self-contained navigation chrome as other routed sheets.
        .sheet(item: $launchedDestination) { dest in
            NavigationStack {
                dest.destination
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .tabRouteDestinations()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { launchedDestination = nil }
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
        }
        // Honour a router request: Devices keeps its dedicated sheet; the v5 pillars route through the
        // shared pillar sheet. Cleared so the same tap can fire again later.
        .onChange(of: router.requestedDestination) { _, dest in
            switch dest {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm:
                routedPillar = dest
                router.requestedDestination = nil
            case .trends:
                // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it.
                withAnimation(StrandMotion.calm(reduced: reduceMotion)) { selectedTab = 1 }
                router.requestedDestination = nil
            case .activeWorkout:
                // The Today active-workout indicator opens Live through the quick-action Live sheet; once
                // it's up, LiveView consumes the one-shot `presentActiveWorkout` flag and presents the
                // in-exercise screen. Calm sheet easing, matching the other quick-action presents.
                withAnimation(StrandMotion.sheet(reduced: reduceMotion)) { quickAction = .live }
                router.requestedDestination = nil
            case .liveSession:
                // Live Sessions is presented from Today's own Start entry (a cover, not a routed sheet),
                // so a deep-link lands on the Today tab where that entry lives.
                withAnimation(StrandMotion.calm(reduced: reduceMotion)) { selectedTab = 0 }
                router.requestedDestination = nil
            case .journal:
                // The #627 Today journal widget opens the journal through the quick-action Journal sheet
                // (InsightsView), matching the FAB's "Log journal" action. Calm sheet easing.
                withAnimation(StrandMotion.sheet(reduced: reduceMotion)) { quickAction = .journal }
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(StrandMotion.sheet(reduced: reduceMotion)) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
    }

    /// A routed v5 pillar screen wrapped in its own nav stack + Done button (mirrors `quickScreen`).
    @ViewBuilder
    private func pillarScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                // .trends is never presented as a pillar sheet on iPhone (it's a primary tab — the
                // requestedDestination handler switches `selectedTab` instead), but the switch must stay
                // exhaustive. Fall back to Trends inside the sheet host if it ever arrives here.
                case .trends: TrendsView()
                // .activeWorkout routes through the quick-action Live sheet (handled above); this keeps the
                // switch exhaustive and falls back to Live if it ever reaches the pillar host.
                case .activeWorkout: LiveView()
                // .liveSession routes to the Today tab (handled above — its Start entry owns the cover);
                // this keeps the switch exhaustive and falls back to Today if it ever reaches the host.
                case .liveSession: LiquidTodayView()
                // .journal opens through the quick-action Journal sheet (handled above); this keeps the
                // switch exhaustive and falls back to the journal's Insights host if it ever reaches here.
                case .journal: InsightsView()
                }
            }
            // The Trends/Today fallbacks above emit TabRoute value pushes (#198), which need a
            // destination registered in THIS sheet's stack to resolve.
            .tabRouteDestinations()
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // #1027: same fix as quickScreen — the pillar screens draw the full-bleed liquid sky, so a
            // transparent nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Maps a LaunchItem id to the sheet destination presented by the quick-launch panel.
    private func destination(for id: String) -> LaunchDestination? {
        switch id {
        case "insightsHub":   return .insightsHub
        case "intelligence":  return .intelligence
        case "insights":      return .insights
        case "journal":       return .insights   // "Log journal" opens the same InsightsView
        case "explore":       return .explore
        case "compare":       return .compare
        case "live":          return .live
        case "workouts":      return .workouts
        case "health":        return .health
        case "labBook":       return .labBook
        case "stress":        return .stress
        case "breathe":       return .breathe
        case "intervals":     return .intervals
        case "rhythm":        return .rhythm
        case "fusedRecord":   return .fusedRecord
        case "appleHealth":   return .appleHealth
        case "miBand":        return .miBand
        case "dataSources":   return .dataSources
        case "backupSync":    return .backupSync
        case "shortcuts":     return .shortcutsExport
        case "alarms":        return .alarms
        case "automations":   return .automations
        case "testCentre":    return .testCentre
        case "siri":          return .siriShortcuts
        case "settings":      return .settings
        default:              return nil
        }
    }

    /// Coach is a real page in the currently selected tab's navigation stack, matching its former
    /// More-tab behavior. Quick Launch's Coach item and the plus-button hold both use this route.
    private func presentCoachPage() {
        tabPaths[selectedTab].append(TabRoute.coach)
    }

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                // Swap the menu for the chosen destination on the next runloop so the sheet
                // re-presents cleanly (avoids dismiss/re-present races). Calm easing on re-present.
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.sheetSwapDelay) {
                    withAnimation(StrandMotion.sheet(reduced: reduceMotion)) {
                        quickAction = picked
                    }
                }
            }
            .presentationDetents([.height(344)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
        }
    }

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching the quick-launch destination sheets.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: these screens draw a full-bleed liquid sky (ScreenScaffold topBackground) that runs
                // edge-to-edge under a transparent bar — exactly how the tab roots present it. An OPAQUE
                // surfaceBase toolbar background sat on top of that sky and, as the content scrolled up, its
                // extended status-bar band CLIPPED the sky + the in-content header ("Live Body Console").
                // Hiding the bar background lets the sky stay continuous under the floating Done button.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// The Devices manager wrapped in its own nav stack + Done button (mirrors `quickScreen`, but
    /// dismisses the dedicated `showDevices` sheet rather than the quick-action item).
    private var devicesScreen: some View {
        NavigationStack {
            DevicesView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: same fix as quickScreen — Devices draws the full-bleed liquid sky, so a transparent
                // nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
                              path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button. The stack is bound to the tab's path so a
        // re-tap of the active tab can pop it to the root (#135/#198); the roots' first-hop links push
        // TabRoute values, registered here ONCE per stack (a double registration double-pushes, #38).
        NavigationStack(path: path) {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .tabRouteDestinations()
        }
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        .environment(\.scrollToTopSignal, scrollSignal)
        .toolbar(.hidden, for: .tabBar)   // we draw our own FloatingTabBar
        .tabItem { Label(title, systemImage: icon) }
    }

}

/// Every screen the quick-launch panel can open. `Identifiable` so it drives `.sheet(item:)`.
private enum LaunchDestination: Hashable, Identifiable {
    case insightsHub, intelligence, insights, explore, compare
    case live, workouts, health, labBook, stress, breathe, intervals, rhythm
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport
    case alarms, automations, testCentre, siriShortcuts, settings

    var id: Self { self }

    @ViewBuilder var destination: some View {
        switch self {
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
        case .health:          HealthView()
        case .labBook:         LabBookView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .fusedRecord:     FusedRecordHost()
        case .appleHealth:     AppleHealthView()
        case .miBand:          XiaomiBandView()
        case .dataSources:     DataSourcesView()
        case .backupSync:      BackupSyncView()
        case .shortcutsExport: ShortcutExportSettingsView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .settings:        SettingsView()
        }
    }
}

// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// The bottom sheet of quick actions presented by the centre FAB. Spec bottom sheet: surfaceOverlay
/// fill, gold hairline top edge, grab handle, three flat action rows that route to existing screens.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .font(StrandFont.overline)
                .tracking(1.6)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                row("Live HR", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) { onPick(.live) }
                row("Start workout", icon: "figure.run", tint: StrandPalette.effortColor) { onPick(.workout) }
                row("Log journal", icon: "square.and.pencil", tint: StrandPalette.accent) { onPick(.journal) }
                row("Breathe", icon: "wind", tint: StrandPalette.restColor) { onPick(.breathe) }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            StrandPalette.surfaceOverlay
                .overlay(alignment: .top) {
                    // Gold hairline top edge per the bottom-sheet spec.
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }

    /// One flat action row: hued line-icon tile + title, inset surface, hairline border.
    private func row(_ title: LocalizedStringKey, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(StrandPalette.surfaceInset))
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Floating tab bar (split: left pill + right circle)

/// Split bottom bar: a liquid-glass pill holding the three primary tabs on the left, and a
/// separate liquid-glass circle with a +/× on the right that toggles the quick-launch panel.
/// Both shapes share the same vertical centre; together they span the full horizontal extent
/// from the 22 pt insets supplied by the parent VStack.
private struct FloatingTabBar: View {
    @Binding var selection: Int
    @Binding var panelOpen: Bool
    var onReselect: (Int) -> Void = { _ in }
    var onCoach: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coachShortcutFeedback = false

    private struct Item: Identifiable { let title: LocalizedStringKey; let icon: String; let tag: Int; var id: Int { tag } }
    private let nav = [Item(title: "Today",  icon: "square.grid.2x2",          tag: 0),
                       Item(title: "Trends", icon: "chart.line.uptrend.xyaxis", tag: 1),
                       Item(title: "Sleep",  icon: "bed.double",                tag: 2)]

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.rowSpacing) {
            // Left pill — three primary tabs.
            HStack(spacing: NoopMetrics.LaunchChrome.pillTabGap) {
                tabButton(nav[0])
                tabButton(nav[1])
                tabButton(nav[2])
            }
            .padding(.vertical, NoopMetrics.LaunchChrome.pillVInset)
            .padding(.horizontal, NoopMetrics.space2)
            .noopLiquidGlassSurface(in: Capsule())

            // Right circle — a tap toggles Quick Launch; a deliberate hold opens Coach directly.
            Group {
                // A SINGLE "plus" glyph, rotated 45° to form the ×. Two distinct SF Symbols ("plus" +
                // "xmark") can NEVER be forced to match visually — each has its own ink-to-bounding-box
                // ratio baked into its design (xmark's diagonal strokes reach further into their box
                // than plus's cross does), so no amount of frame/size tuning fully closes that gap.
                // Rotating one glyph is the only way to GUARANTEE identical stroke width and arm length
                // in both states, because it's the same drawing. (The earlier "weird rotation" bug was
                // rotating "xmark" — which is already diagonal, so +45° turns an X into a +. Rotating
                // "plus" instead has no such inversion: a + turned 45° is exactly an ×.)
                Image(systemName: coachShortcutFeedback ? "sparkles" : "plus")
                    .font(StrandFont.symbol(NoopMetrics.LaunchChrome.actionIcon, weight: .semibold))
                    .foregroundStyle(
                        coachShortcutFeedback
                            ? StrandPalette.accent
                            : panelOpen ? StrandPalette.textSecondary : StrandPalette.accent
                    )
                    .rotationEffect(.degrees(panelOpen && !coachShortcutFeedback ? 45 : 0))
                    // Treat both glyphs as single marks. Replacing each SF Symbol layer separately
                    // makes the three Coach sparkles scatter while the plus collapses.
                    .contentTransition(.symbolEffect(.replace.downUp.wholeSymbol))
                    .animation(reduceMotion ? nil : StrandMotion.calmQuick, value: coachShortcutFeedback)
                    .frame(
                        width: NoopMetrics.LaunchChrome.toggleDiameter,
                        height: NoopMetrics.LaunchChrome.toggleDiameter
                    )
                    .contentShape(Circle())
            }
            // The exclusive gesture guarantees a completed hold cannot also fire the normal tap.
            .gesture(launcherGesture)
            .noopLiquidGlassSurface(in: Circle())
            .accessibilityLabel(panelOpen ? "Close menu" : "Open menu")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                togglePanel()
            }
            .accessibilityAction(named: Text("Coach")) {
                commitCoachShortcut()
            }
        }
    }

    private var launcherGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: NoopMetrics.space3)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first:
                    commitCoachShortcut()
                case .second:
                    togglePanel()
                }
            }
    }

    /// The light toggle haptic lands on the same frame that the glass begins materializing.
    /// A deliberate Coach hold uses the stronger commit haptic instead.
    private func togglePanel() {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.panel(reduced: reduceMotion)) {
            panelOpen.toggle()
        }
    }

    /// Confirm the hidden Coach shortcut before routing: the plus becomes the same sparkle glyph used
    /// by Coach, the commit haptic lands with that visual change, then the destination opens.
    private func commitCoachShortcut() {
        guard !coachShortcutFeedback else { return }
        StrandHaptic.commit.play()
        guard !reduceMotion else {
            onCoach()
            return
        }
        withAnimation(StrandMotion.calmQuick) {
            coachShortcutFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.durationFast) {
            onCoach()
            // Keep the confirmed Coach glyph stable throughout the navigation push. Starting the
            // reverse replacement in the same update made both animations compete and tear.
            DispatchQueue.main.asyncAfter(deadline: .now() + StrandMotion.durationSheet) {
                guard coachShortcutFeedback else { return }
                withAnimation(StrandMotion.calmQuick) {
                    coachShortcutFeedback = false
                }
            }
        }
    }

    private func tabButton(_ item: Item) -> some View {
        let active = selection == item.tag
        return Button {
            if active { onReselect(item.tag) }
            else { withAnimation(StrandMotion.calm(reduced: reduceMotion)) { selection = item.tag } }
        } label: {
            VStack(spacing: NoopMetrics.LaunchChrome.tabIconLabelGap) {
                Image(systemName: item.icon)
                    .font(
                        StrandFont.symbol(
                            NoopMetrics.LaunchChrome.tabIcon,
                            weight: active ? .semibold : .regular
                        )
                    )
                Text(item.title)
                    .font(StrandFont.caption2)
                    .fontWeight(active ? .semibold : .medium)
            }
            .foregroundStyle(active ? StrandPalette.accent : StrandPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, NoopMetrics.LaunchChrome.tabIconLabelGap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Native Liquid Glass grouping and transition controls are iOS 26-only. The modifiers keep the call
/// site stable across the iOS 17 deployment range so the fallback remains the existing material surface.
private struct QuickLaunchGlassContainerModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                content
            }
        } else {
            content
        }
    }
}

private struct QuickLaunchGlassTransitionModifier: ViewModifier {
    let reduceMotion: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffectTransition(reduceMotion ? .identity : .materialize)
        } else {
            content
        }
    }
}

private extension View {
    func quickLaunchGlassContainer() -> some View {
        modifier(QuickLaunchGlassContainerModifier())
    }

    func quickLaunchGlassTransition(reduceMotion: Bool) -> some View {
        modifier(QuickLaunchGlassTransitionModifier(reduceMotion: reduceMotion))
    }
}

#endif
