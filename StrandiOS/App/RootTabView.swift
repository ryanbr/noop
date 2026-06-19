#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Drives the FAB press-state (gentle scale, dimmed gold shadow) — design-system feedback.
    @State private var fabPressed = false
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today.
    @State private var selectedTab: Int = 0

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

    var body: some View {
        // The native TabView keeps every existing destination + system gesture; the signature
        // raised gold FAB is overlaid on top, bottom-centre, floating ~20pt above the bar (a
        // native TabView can't host a centre item that overflows the bar, so we float it).
        ZStack(alignment: .bottom) {
            // Four everyday tabs flanking the raised centre FAB. The FAB sits in the gap between
            // Trends and Sleep (no tab is buried under it). Live (real-time HR) is a "watch it now"
            // action, so it lives in the FAB's quick-action sheet and the More list — not a tab.
            TabView(selection: $selectedTab) {
                tab(TodayView(), "Today", "circle.hexagongrid.fill").tag(0)
                tab(TrendsView(), "Trends", "chart.xyaxis.line").tag(1)
                tab(SleepView(), "Sleep", "bed.double.fill").tag(2)
                moreTab.tag(3)
            }
            .tint(StrandPalette.accent)
            // Tab crossfade — README §Motion: ~240ms opacity swap between tab roots, global calm
            // easing cubic-bezier(0.22,1,0.36,1). The native bar/gestures are untouched; the
            // animation only governs how the selected root settles in.
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)

            centreFAB
        }
        .task { await repo.refresh() }
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
            case nil:
                break
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
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Centre FAB

    /// The README "Tab bar" signature: a 46pt gold-gradient circle raised ~20pt above the bar,
    /// goldDeepText "+" glyph, FAB shadow `0 8 18 -6 gold@.7`. Tapping opens the quick-action sheet.
    private var centreFAB: some View {
        Button {
            withAnimation(Self.sheetEase) { quickAction = .menu }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(StrandPalette.goldDeepText)
                .frame(width: 46, height: 46)
                .background(
                    Circle()
                        .fill(LinearGradient(gradient: StrandPalette.goldGradient,
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                // Spec FAB shadow: 0 8 18 -6 gold@.7 (the -6 spread ≈ a tight radius on a 46pt disc).
                .shadow(color: StrandPalette.gold.opacity(fabPressed ? 0.3 : 0.7), radius: 9, x: 0, y: 8)
                .scaleEffect(fabPressed ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick actions")
        .accessibilityHint("Start a workout, log your journal, or breathe")
        // Raised ~20pt above the bar; the bottom inset keeps it clear of the home indicator.
        .offset(y: -20)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !fabPressed { withAnimation(StrandMotion.interactive) { fabPressed = true } } }
                .onEnded { _ in withAnimation(StrandMotion.interactive) { fabPressed = false } }
        )
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(Self.sheetEase) { quickAction = picked }
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
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
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
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        view
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .tabItem { Label(title, systemImage: icon) }
    }

    private var moreTab: some View {
        NavigationStack {
            List {
                Section("Insights") {
                    link("What Moves You", "wand.and.sparkles") { InsightsHubView() }
                    link("Intelligence", "brain.head.profile") { IntelligenceView() }
                    link("Coach", "sparkles") { CoachView() }
                    link("Insights", "lightbulb.fill") { InsightsView() }
                    link("Explore", "square.grid.2x2.fill") { MetricExplorerView() }
                    link("Compare", "rectangle.split.2x1.fill") { CompareView() }
                }
                Section("Body") {
                    link("Live", "waveform.path.ecg") { LiveView() }
                    link("Workouts", "figure.run") { WorkoutsView() }
                    link("Health", "heart.text.square.fill") { HealthView() }
                    link("Lab Book", "books.vertical.fill") { LabBookView() }
                    link("Stress", "bolt.heart.fill") { StressView() }
                    link("Breathe", "wind") { BreathingView() }
                    link("Intervals", "timer") { IntervalTimerView() }
                    // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                    link("Rhythm", "waveform.path") { RhythmHost() }
                }
                Section("Data") {
                    link("Your Data, Fused", "square.stack.3d.up.fill") { FusedRecordHost() }
                    link("Apple Health", "heart.fill") { AppleHealthView() }
                    link("Mi Band", "figure.walk.motion") { XiaomiBandView() }
                    link("Data Sources", "externaldrive.fill") { DataSourcesView() }
                    // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut
                    // reads the opt-in Documents/noop_sync.txt drop file).
                    link("Shortcuts Export", "square.and.arrow.up.fill") { ShortcutExportSettingsView() }
                }
                Section("App") {
                    link("Automations", "wand.and.stars") { AutomationsView() }
                    link("Siri & Shortcuts", "mic.fill") { SiriShortcutsSettingsView() }
                    link("Settings", "gearshape.fill") { SettingsView() }
                    link("Support", "hands.clap.fill") { SupportView() }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("More")
        }
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    private func link<V: View>(_ title: LocalizedStringKey, _ icon: String, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink {
            dest()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
        } label: {
            // Pin the icon to the accent explicitly. A plain `Label(_:systemImage:)` icon inherits the
            // list's tint, which iOS re-resolves to its default blue a beat after first render — so the
            // icons flashed green→blue (#184). An explicit foregroundStyle on the image overrides that;
            // the title keeps its default (primary) colour.
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(StrandPalette.accent)
            }
        }
        .listRowBackground(StrandPalette.surfaceRaised)
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
#endif
