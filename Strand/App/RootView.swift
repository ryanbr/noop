import SwiftUI
import StrandDesign

enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case intelligence = "Intelligence"
    case insightsHub = "What Moves You"
    case coach = "Coach"
    case live = "Live"
    case breathe = "Breathe"
    case intervals = "Intervals"
    case explore = "Explore"
    case compare = "Compare"
    case insights = "Insights"
    case sleep = "Sleep"
    case trends = "Trends"
    case workouts = "Workouts"
    case health = "Health"
    case stress = "Stress"
    case labBook = "Lab Book"
    case rhythm = "Rhythm"
    case appleHealth = "Apple Health"
    case xiaomi = "Mi Band"
    case dataSources = "Data Sources"
    case backupSync = "Backup & Sync"
    case fusedRecord = "Your Data, Fused"
    case devices = "Devices"
    case noopLimitations = "NOOP Limitations"
    case notifications = "Notifications"
    case automation = "Automations"
    case smartAlarm = "Smart Alarm"
    case settings = "Settings"
    case testCentre = "Test Centre"

    var id: String { rawValue }

    /// Localized sidebar label. Each case maps to a string literal so Xcode extracts
    /// it into the String Catalog as an English (US) base entry.
    var titleKey: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .intelligence: return "Intelligence"
        case .insightsHub: return "What Moves You"
        case .coach: return "Coach"
        case .live: return "Live"
        case .breathe: return "Breathe"
        case .intervals: return "Intervals"
        case .explore: return "Explore"
        case .compare: return "Compare"
        case .insights: return "Insights"
        case .sleep: return "Sleep"
        case .trends: return "Trends"
        case .workouts: return "Workouts"
        case .health: return "Health"
        case .stress: return "Stress"
        case .labBook: return "Lab Book"
        case .rhythm: return "Rhythm"
        case .appleHealth: return "Apple Health"
        case .xiaomi: return "Mi Band"
        case .dataSources: return "Data Sources"
        case .backupSync: return "Backup & Sync"
        case .fusedRecord: return "Your Data, Fused"
        case .devices: return "Devices"
        case .noopLimitations: return "NOOP Limitations"
        case .notifications: return "Notifications"
        case .automation: return "Automations"
        // "Alarms" is the ONE alarm surface (#766): the strap's silent wake-alarm (moved in from
        // Automations) and the evening wind-down reminder, in one place. Previously "Wind-Down" (#730).
        // The case name and rawValue stay `smartAlarm`/"Smart Alarm" as the in-memory nav identifier only.
        case .smartAlarm: return "Alarms"
        case .settings: return "Settings"
        case .testCentre: return "Test Centre"
        }
    }

    /// The same label as `titleKey`, resolved to a plain `String` so the sidebar filter (#915) can
    /// match what the user actually reads in their language. `LocalizedStringKey` cannot be compared
    /// against typed text, so each case repeats its literal through `String(localized:)`: the
    /// extractor merges these with the `titleKey` literals into the same catalog entries, so no new
    /// keys appear. Keep the two switches in lockstep (the compiler forces a new case into both;
    /// a string edit must be mirrored by hand, or search stops finding that row).
    var localizedTitle: String {
        switch self {
        case .today: return String(localized: "Today")
        case .intelligence: return String(localized: "Intelligence")
        case .insightsHub: return String(localized: "What Moves You")
        case .coach: return String(localized: "Coach")
        case .live: return String(localized: "Live")
        case .breathe: return String(localized: "Breathe")
        case .intervals: return String(localized: "Intervals")
        case .explore: return String(localized: "Explore")
        case .compare: return String(localized: "Compare")
        case .insights: return String(localized: "Insights")
        case .sleep: return String(localized: "Sleep")
        case .trends: return String(localized: "Trends")
        case .workouts: return String(localized: "Workouts")
        case .health: return String(localized: "Health")
        case .stress: return String(localized: "Stress")
        case .labBook: return String(localized: "Lab Book")
        case .rhythm: return String(localized: "Rhythm")
        case .appleHealth: return String(localized: "Apple Health")
        case .xiaomi: return String(localized: "Mi Band")
        case .dataSources: return String(localized: "Data Sources")
        case .backupSync: return String(localized: "Backup & Sync")
        case .fusedRecord: return String(localized: "Your Data, Fused")
        case .devices: return String(localized: "Devices")
        case .noopLimitations: return String(localized: "NOOP Limitations")
        case .notifications: return String(localized: "Notifications")
        case .automation: return String(localized: "Automations")
        // Mirrors the `titleKey` remap above (#766): the row reads "Alarms", not the raw "Smart Alarm".
        case .smartAlarm: return String(localized: "Alarms")
        case .settings: return String(localized: "Settings")
        case .testCentre: return String(localized: "Test Centre")
        }
    }

    var icon: String {
        switch self {
        case .today: return "circle.hexagongrid.fill"
        case .intelligence: return "brain.head.profile"
        case .insightsHub: return "wand.and.sparkles"
        case .coach: return "sparkles"
        case .live: return "waveform.path.ecg"
        case .breathe: return "lungs.fill"
        case .intervals: return "timer"
        case .explore: return "square.grid.2x2.fill"
        case .compare: return "chart.line.uptrend.xyaxis"
        case .insights: return "lightbulb.fill"
        case .sleep: return "moon.stars.fill"
        case .trends: return "chart.xyaxis.line"
        case .workouts: return "figure.run"
        case .health: return "heart.text.square.fill"
        case .stress: return "gauge.with.dots.needle.50percent"
        case .labBook: return "books.vertical.fill"
        case .rhythm: return "waveform.path"
        case .appleHealth: return "heart.fill"
        case .xiaomi: return "figure.walk.motion"
        case .dataSources: return "square.and.arrow.down.fill"
        case .backupSync: return "externaldrive.fill.badge.icloud"
        case .fusedRecord: return "square.stack.3d.up.fill"
        case .devices: return "badge.plus.radiowaves.right"
        case .noopLimitations: return "list.bullet.rectangle"
        case .notifications: return "bell.badge.fill"
        case .automation: return "wand.and.stars"
        case .smartAlarm: return "alarm.fill"
        case .settings: return "gearshape.fill"
        case .testCentre: return "stethoscope"
        }
    }
}

/// One collapsible sidebar section (S1, #805): the 27 flat `NavItem` cases are grouped into ~5
/// labelled sections so the macOS sidebar stops being a 28-item flat wall. The enum cases are NOT
/// touched (M5 gate): only the layout that consumes them changes. `NavGroup.all` is the single source
/// of truth for what each section holds, so the M5 routability test can assert every `NavItem` case is
/// still present across the groups (nothing vanished the way the iPhone Smart-Alarm row did).
struct NavGroup: Identifiable {
    let title: LocalizedStringKey
    /// Stable identity for the group's expand/collapse state. (LocalizedStringKey isn't Hashable.)
    let id: String
    let items: [NavItem]

    /// The 5 sidebar sections, in order, mirroring the iOS More-tab grouping idiom (Insights / Body /
    /// Data & App) plus Today + Sleep as their own top sections. Devices/pairing sits at the TOP of the
    /// Data & App group so the first thing a new user reaches for stays near the surface. Every one of the
    /// 27 `NavItem` cases appears exactly once across these groups (asserted by the M5 routability test).
    static let all: [NavGroup] = [
        NavGroup(title: "Today", id: "today", items: [.today]),
        NavGroup(title: "Sleep", id: "sleep", items: [.sleep]),
        NavGroup(title: "Body", id: "body", items: [
            .workouts, .live, .health, .stress, .intervals, .breathe,
        ]),
        // S6: the overlapping insight surfaces (Intelligence / What Moves You / Insights / Insights Hub)
        // all collapse under this single Insights group rather than scattering across the flat list.
        NavGroup(title: "Insights", id: "insights", items: [
            .intelligence, .insightsHub, .coach, .explore, .compare, .insights,
            .labBook, .rhythm, .trends,
        ]),
        NavGroup(title: "Data & App", id: "data_app", items: [
            .devices, .noopLimitations, .dataSources, .appleHealth, .xiaomi, .backupSync, .fusedRecord,
            .notifications, .automation, .smartAlarm, .settings, .testCentre,
        ]),
    ]

    /// The group that owns a given destination (used to auto-expand the active group on launch / route).
    static func group(containing item: NavItem) -> NavGroup? {
        all.first { $0.items.contains(item) }
    }
}

struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR/frame stream). The live
    // status pill is isolated into SidebarStatus so HR/frame ticks don't re-render the whole
    // NavigationSplitView shell + sidebar list.
    @EnvironmentObject var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Observed here so a screen can
    /// switch the sidebar selection without owning it — see `NavRouter`.
    @EnvironmentObject var router: NavRouter
    /// The liquid Today (default) vs the classic Today, same flag the iOS shell + Settings toggle read.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true
    @State private var selection: NavItem? = .today
    /// Which sidebar groups are expanded (S1, #805). Default = the group owning the launch selection
    /// (`.today`). The single-item Today/Sleep sections always read expanded so their one row shows; the
    /// multi-item groups (Body / Insights / Data & App) collapse to just their header until tapped.
    @State private var expandedGroups: Set<String> = Self.initialExpandedGroups(for: .today)
    /// Sidebar filter text (#915). Since the collapsible sections landed (S1), 27 of the 28
    /// destinations sit inside collapsed groups; typing here filters every group by its localized row
    /// title so any screen is reachable without knowing which section owns it.
    @State private var searchQuery = ""
    /// The user's expand/collapse state as it stood the instant a search began (the trimmed query
    /// going empty to non-empty), so clearing the search puts every group back exactly as they left
    /// it. `nil` means no search is in flight; whitespace-only input never arms one.
    @State private var preSearchExpansion: Set<String>? = nil

    /// The groups expanded at rest: every single-item group (so its lone row is visible) plus the group
    /// owning the current selection. Keeps the sidebar to "headers + the active group" as the spec asks.
    /// `internal` (not `private`) so the M5 routability test can pin the contract via `@testable`.
    static func initialExpandedGroups(for item: NavItem?) -> Set<String> {
        var open = Set(NavGroup.all.filter { $0.items.count == 1 }.map(\.id))
        if let item, let g = NavGroup.group(containing: item) { open.insert(g.id) }
        return open
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Fixed brand header — a real row above the list, NOT a `.safeAreaInset`: a macOS
                // `List(.sidebar)` doesn't inset its scroll content for a top safe-area inset, so the
                // (transparent) lockup floated over the scrolling rows and overlapped "Intelligence".
                brand
                // S1 (#805): collapsible sections instead of 28 flat rows. Each multi-item group is a
                // DisclosureGroup bound to `expandedGroups`; single-item groups (Today / Sleep) render
                // their one row directly so there's nothing to expand into. The `NavItem` enum is
                // unchanged (M5 gate): only this layout that consumes it changed.
                List(selection: $selection) {
                    // One pass over NavGroup.all in data order (never split singles from multis into
                    // separate loops: ordering must survive future group additions). While a search is
                    // active each group shows only its matching rows; the bare-row vs DisclosureGroup
                    // shape keys on the group's FULL size, so a section narrowed to one hit keeps its
                    // header for context and Today/Sleep stay bare rows that simply drop out on a miss.
                    ForEach(NavGroup.all) { group in
                        let visible = visibleItems(in: group)
                        if group.items.count == 1 {
                            ForEach(visible) { sidebarRow($0) }
                        } else if !visible.isEmpty {
                            DisclosureGroup(isExpanded: groupExpansion(group.id)) {
                                ForEach(visible) { sidebarRow($0) }
                            } label: {
                                Text(group.title)
                                    .font(StrandFont.rounded(11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .textCase(.uppercase)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                // Hide the macOS system sidebar VIBRANCY material so the list rows sit on the same
                // flat surfaceBase as the brand header above — without this the translucent list read
                // as a lighter panel below an opaque black header strip (the "black upper" seam).
                .scrollContentBackground(.hidden)
                // Sidebar filter (#915, reimplemented): native .searchable on the sidebar column,
                // which macOS renders as a system search field in the sidebar's toolbar area with
                // focus, clear and Escape handling for free (macOS 12+, safely under our 13.0
                // target), so no hand-rolled TextField and no custom chrome. macOS-only BY DESIGN,
                // not a parity gap: iOS ships RootTabView, where the tab bar plus the More list
                // already puts every destination within a couple of taps, so there is no iOS
                // equivalent to add.
                .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search")

                Divider().overlay(StrandPalette.hairline)
                SidebarStatus().padding(.horizontal, 14).padding(.vertical, 12)
            }
            // One continuous flat WHOOP-grey surface behind the brand header, the list rows, and the
            // status pill, no black-vs-vibrancy seam (Design Reset, 2026-06-23).
            .background(StrandPalette.surfaceBase)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            // The crossfade `.id` lives on the INNER switched content, not on the detail-column root
            // the split view hosts. A stable ZStack hosts the column; only the `detail` child inside it
            // carries `.id(selection)`. Keeping the split view's hosted view identity stable across
            // sidebar switches stops SwiftUI cold-mounting the whole detail column every time (#833):
            // an `.id` on the column ROOT re-created the hosted subtree on each switch, cold-starting
            // the target screen and re-running its O(full-history) @MainActor reads, which froze macOS
            // on a large DB. The child still gets a per-selection identity, so the opacity crossfade
            // (README §Motion: "switching tabs uses a crossfade ~240ms", calm cubic-bezier
            // (0.22,1,0.36,1)) fires unchanged: it inserts/removes the id'd child on each change.
            ZStack {
                detail
                    .id(selection ?? .today)
                    .transition(.opacity)
            }
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
        .task {
            await repo.refresh()
            // Backup & Sync: on-launch catch-up. Gated on the auto toggle being ON (default OFF). A
            // whole-DB ZIP can be 100MB+, so it must never block startup: fire it in a DETACHED,
            // utility-priority task AFTER the launch-critical refresh, fully off the main actor (the
            // `FolderBackup` enum is nonisolated; only the picker hops to the main actor, and it isn't
            // reached here). The screen also offers an explicit "Back up now". (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Honour a cross-screen request to open a top-level destination (e.g. Live's "Manage devices"),
        // then clear it so the same tap can fire again later. Devices maps to the `.devices` sidebar item.
        .onChangeCompat(of: router.requestedDestination) { dest in
            switch dest {
            case .devices: selection = .devices
            case .insightsHub: selection = .insightsHub
            case .labBook: selection = .labBook
            case .fusedRecord: selection = .fusedRecord
            case .rhythm: selection = .rhythm
            case .trends: selection = .trends
            // The Today active-workout indicator routes to the Live surface; LiveView then consumes the
            // one-shot `presentActiveWorkout` flag on appear to open the in-exercise screen.
            case .activeWorkout: selection = .live
            // Live Sessions is presented from Today's own Start entry (a cover, not a sidebar item), so a
            // deep-link lands the user on Today where that entry lives.
            case .liveSession: selection = .today
            // The #627 Today journal widget routes to the Insights sidebar row (which hosts the journal card).
            case .journal: selection = .insights
            case nil: break
            }
            if dest != nil { router.requestedDestination = nil }
        }
        // Whenever the selection moves (a cross-screen route, or restoring a deep destination), make sure
        // the group that owns it is expanded so the selected row is actually visible, not hidden inside a
        // collapsed section (S1). User-driven collapses of OTHER groups are preserved.
        .onChangeCompat(of: selection) { sel in
            if let sel, let g = NavGroup.group(containing: sel) {
                expandedGroups.insert(g.id)
            }
        }
        // Sidebar filter transitions (#915). Entering a search (trimmed query going empty to
        // non-empty) snapshots the user's expand/collapse state ONCE, then every keystroke
        // auto-expands the groups that contain matches so the hits are actually visible, not hidden
        // behind collapsed headers. Clearing the search (or backspacing down to whitespace) restores
        // that snapshot exactly, with one carve-out: the group owning the current selection is
        // re-expanded, preserving the S1 invariant above that the selected row is never hidden
        // inside a collapsed section (the user may have just selected a hit from a group they had
        // collapsed before searching).
        .onChangeCompat(of: searchQuery) { raw in
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                // Whitespace-only never armed a search, so there may be nothing to restore.
                guard let saved = preSearchExpansion else { return }
                preSearchExpansion = nil
                expandedGroups = saved
                if let sel = selection, let g = NavGroup.group(containing: sel) {
                    expandedGroups.insert(g.id)
                }
            } else {
                if preSearchExpansion == nil { preSearchExpansion = expandedGroups }
                for group in NavGroup.all
                where group.items.contains(where: { $0.localizedTitle.localizedStandardContains(query) }) {
                    expandedGroups.insert(group.id)
                }
            }
        }
    }

    /// The filter text that actually applies: trimmed, so a whitespace-only query is no query at all.
    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A group's rows under the current filter: all of them when no search is active, otherwise the
    /// ones whose LOCALIZED title contains the query. `localizedStandardContains` gives the standard
    /// user-search semantics (case-insensitive, diacritic-insensitive, locale-aware) in one call.
    /// ALL groups filter, including single-item Today/Sleep; a group with no hits disappears entirely.
    private func visibleItems(in group: NavGroup) -> [NavItem] {
        let query = trimmedQuery
        guard !query.isEmpty else { return group.items }
        return group.items.filter { $0.localizedTitle.localizedStandardContains(query) }
    }

    /// One selectable destination row (same Label styling the flat list used), tagged for selection.
    private func sidebarRow(_ item: NavItem) -> some View {
        Label(item.titleKey, systemImage: item.icon)
            .font(StrandFont.rounded(13, weight: .medium))
            .tag(item)
    }

    /// A binding into `expandedGroups` for one group's id, so each DisclosureGroup drives the shared set.
    private func groupExpansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(id) },
            set: { isOpen in
                if isOpen { expandedGroups.insert(id) } else { expandedGroups.remove(id) }
            }
        )
    }

    private var brand: some View {
        HStack(spacing: 8) {
            // In-app logo: the open recovery-ring mark so the wordmark reads as a true lockup
            // (README logo system — mark + "NOOP"). Flat gold gradient, low glow per the v3 restraint.
            BrandMark(size: 22)
            Text("NOOP")
                .font(StrandFont.rounded(20, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
        }
        // Top padding clears the traffic-light controls (the window hides its title bar, so they sit
        // over the sidebar's top edge); the lockup sits just below them.
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .today {
        case .today: todayDetail
        case .intelligence: IntelligenceView()
        case .insightsHub: InsightsHubView()
        case .coach: CoachView()
        case .live: liveDetail
        case .breathe: BreathingView()
        case .intervals: IntervalTimerView()
        case .explore: MetricExplorerView()
        case .compare: CompareView()
        case .insights: InsightsView()
        case .sleep: SleepView()
        case .trends: TrendsView()
        case .workouts: WorkoutsView()
        case .health: HealthView()
        case .stress: StressView()
        case .labBook: LabBookView()
        case .rhythm: RhythmHost()
        case .appleHealth: AppleHealthView()
        case .xiaomi: XiaomiBandView()
        case .dataSources: DataSourcesView()
        case .backupSync: BackupSyncView()
        case .fusedRecord: FusedRecordHost()
        case .devices: DevicesView()
        case .noopLimitations: NoopLimitationsView()
        case .notifications: NotificationSettingsView()
        case .automation: AutomationsView()
        case .smartAlarm: SmartAlarmView()
        case .settings: settingsDetail
        case .testCentre: TestCentreView()
        }
    }

    // Today's "Your Cards" rows push Stress/Health/Hydration detail pages via NavigationLink. On macOS
    // the detail column has no enclosing NavigationStack of its own, so those pushes had no Back chrome
    // and switching sidebar items hung (#753 Bug 2). Give the Today pane its own NavigationStack the
    // same way MetricExplorerView wraps itself because "Explore is a standalone detail pane, so it owns
    // its NavigationStack". iOS already wraps each tab in a NavigationStack via RootTabView, so this is
    // macOS-only and leaves iOS untouched (TodayView's `.toolbar` stays on its own view body either way).
    @ViewBuilder private var todayDetail: some View {
        #if os(macOS)
        NavigationStack {
            // Today's root-level links push TabRoute VALUES (#198), so this stack must register
            // their destinations (once per stack — a double registration double-pushes, #38).
            Group {
                if liquidTodayEnabled { LiquidTodayView() } else { TodayView() }
            }
            .tabRouteDestinations()
        }
        #else
        TodayView()
        #endif
    }

    // Settings now pushes into Test Centre via a NavigationLink. On macOS the detail column has no
    // enclosing NavigationStack of its own, so the same #753 fix applies: wrap the Settings pane in its
    // own NavigationStack so the Test Centre push gets Back chrome. iOS already wraps each tab.
    @ViewBuilder private var settingsDetail: some View {
        #if os(macOS)
        NavigationStack { SettingsView() }
        #else
        SettingsView()
        #endif
    }

    // Live's strap-log card pushes into Test Centre (#507/#509). Same macOS NavigationStack wrap so the
    // push gets Back chrome on the detail column; iOS already wraps each tab.
    @ViewBuilder private var liveDetail: some View {
        #if os(macOS)
        NavigationStack { LiveView() }
        #else
        LiveView()
        #endif
    }
}

/// The NOOP logo mark — an **open recovery ring** (~80% arc, round caps, starting at 12 o'clock)
/// with a **solid centre core dot** ("on-device core"), per the README logo system. Rendered in the
/// gold gradient and kept deliberately flat / low-glow for the v3 Titanium & Gold restraint. Drawn
/// purely from design tokens so it tracks the palette. Sized to optically x-height-match the wordmark.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            // Open ring: leave ~20% of the circumference as a gap (trim 0 → 0.8), then rotate so the
            // gap sits at the top — the gold gradient sweeps clockwise from 12 o'clock.
            Circle()
                .trim(from: 0, to: 0.8)
                .stroke(
                    AngularGradient(gradient: StrandPalette.goldGradient,
                                    center: .center,
                                    angle: .degrees(-90)),
                    style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: size * 0.84, height: size * 0.84)

            // Solid centre core dot — the "on-device core".
            Circle()
                .fill(LinearGradient(gradient: StrandPalette.goldGradient,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.26, height: size * 0.26)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Isolated live-status pill — owns the LiveState observation so the rest of RootView (sidebar
/// list + detail) does not re-render on the ~1 Hz HR / frame stream.
private struct SidebarStatus: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .shadow(color: statusColor.opacity(0.6), radius: live.connected ? 4 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(StrandFont.rounded(12, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(live.batteryPct.map { String(localized: "Battery \(Int($0))%") } ?? String(localized: "Strap not connected"))
                    .font(StrandFont.rounded(11))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
        }
        .padding(10)
        .background(NoopPanelSurface(cornerRadius: 10))
    }

    // Shares LiveState.connectionStatus* with the Settings strap card so the two never disagree (#266):
    // a connected-but-unbonded 5/MG now reads "Connected" here too, not a misleading "Connecting…".
    private var statusColor: Color {
        live.connectionStatusIsActive ? StrandPalette.statusPositive
            : live.connectionStatusIsIdle ? StrandPalette.statusWarning
            : StrandPalette.statusCritical
    }
    private var statusText: String {
        live.connectionStatusLabel
    }
}
