import SwiftUI
import StrandDesign
import UserNotifications

@main
struct StrandApp: App {
    init() {
        // #1008: pin the pre-change Overnight-only default for existing installs before
        // anything reads it. Idempotent; a no-op on fresh installs and after the first launch.
        PuffinExperiment.migrateContinuousHrvOvernightDefault()
        #if DEBUG
        // DEBUG-only promo-screenshot harness: when launched with `--demo-hour <Int>`, pin the Today
        // screen to that hour's day-cycle scene + a plausible per-hour stat frame. Runs synchronously
        // here, before the first Today render. No-op (active stays nil) when the arg is absent, so
        // Release is unaffected (whole harness is `#if DEBUG`). See DemoDayHarness.swift.
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
        // Foreground presentation: without a delegate, macOS suppresses a notification's banner while the
        // app is frontmost, so a reminder tested with NOOP open would show nothing. Mirrors iOS.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    @StateObject private var model = AppModel()
    /// Shared cross-screen navigation hook (e.g. Live → Devices). The macOS shell (`RootView`)
    /// observes it and drives the sidebar selection.
    @StateObject private var router = NavRouter()
    /// #267: drives a foreground sync kick when the window becomes active (no scenePhase hook
    /// existed on macOS before this).
    @Environment(\.scenePhase) private var scenePhase
    /// Appearance preference (System/Light/Dark). Default follows the OS; the Settings picker writes it.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// Chart data-colour style (Titanium / Classic throwback). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.ble)   // #334: Today pull-to-sync reads BLEManager (no HR churn)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                // v5 L3: the shared stress check-in nudge surface, so the Breathe screen's passive
                // card observes the SAME instance the central detector (AppModel.evaluateStress) posts to.
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .frame(minWidth: 1000, minHeight: 700)
                .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
                .chartStyle(chartStyleRaw)
                // Dynamic Type now scales the prose/label roles (StrandFont). Cap the upper end so the
                // fixed-geometry tiles/gauges stay legible at the largest accessibility sizes rather than
                // clipping; the common Larger-Text range still scales fully.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                // #267: pull a reasonably fresh sync when the window comes to the foreground rather than
                // waiting for the 900s periodic timer or an incidental reconnect. Floored at 90s and never
                // clock/empty-streak-suppressed (BackfillPolicy.shouldRun's .foreground case), so this is
                // a safe no-op on rapid re-focusing. Mirrors the iOS scenePhase == .active handler.
                // Single-param form (not the two-param `{ _, phase in }`) — that overload needs macOS 14,
                // this target is macOS 13.
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.ble.requestSync(.foreground) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)

        // Menu-bar extra: glanceable live HR + a compact popover.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(model.repo)
                .environmentObject(model.live)
        }
        .menuBarExtraStyle(.window)
    }
}
