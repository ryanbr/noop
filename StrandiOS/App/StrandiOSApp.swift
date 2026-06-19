#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS entry point. Unlike the macOS app (which adds a `MenuBarExtra` scene), iOS uses a single
/// `WindowGroup`; the glanceable menu-bar role is filled by the Home/Lock-Screen widget instead.
///
/// The iOS shell is `RootTabView` (a `TabView`), NOT the macOS `ContentView`. `ContentView` embeds
/// `RootView()` — the `NavigationSplitView` sidebar shell — and `RootView.swift` is excluded from the
/// iOS target in `project.yml` (the sidebar has no iPhone analogue), so `ContentView` cannot compile
/// on iOS. The first-run onboarding/pairing wizard, the Terms acknowledgment gate, and the post-update
/// "What's New" sheet that `ContentView` layers on are reproduced here as `iOSRootView`, wrapped around
/// `RootTabView` so the iOS app keeps the same gating without depending on the macOS-only shell.
@main
struct StrandiOSApp: App {
    @StateObject private var model: AppModel
    @StateObject private var health: HealthKitBridge
    /// Shared cross-screen navigation hook (e.g. Live → Devices). The iOS shell (`RootTabView`)
    /// observes it and presents the Devices manager.
    @StateObject private var router = NavRouter()
    @State private var liveActivity = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase
    /// Appearance preference (System/Light/Dark). Default follows the OS; the Settings picker writes it.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// Chart data-colour style (Titanium / Classic throwback). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    init() {
        // Debug-only canary: trips if the App Group entitlement is missing on this target before any
        // silent no-op (PendingIntents, WidgetSnapshot.publish, Live Activity) can mask the issue as
        // "the widget doesn't show anything yet." No-op in Release.
        WidgetSnapshot.assertGroupProvisioned()
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _health = StateObject(wrappedValue: HealthKitBridge(
            repo: model.repo,
            appleDeviceId: model.appleDeviceId,
            noopDeviceId: model.deviceId
        ))
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(health)
                .environmentObject(router)
                // v5 L3: the shared stress check-in nudge surface, so the Breathe screen's passive
                // card observes the SAME instance the central detector (AppModel.evaluateStress) posts to.
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
                .chartStyle(chartStyleRaw)
                // Dynamic Type now scales the prose/label roles (StrandFont). Cap the upper end so the
                // fixed-geometry tiles/gauges stay legible at the largest accessibility sizes rather than
                // clipping; the common Larger-Text range still scales fully.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .onReceive(model.live.$heartRate) { _ in
                    liveActivity.update(
                        bpm: model.live.connected ? (model.bpm ?? model.live.heartRate) : nil,
                        recovery: model.repo.days.last(where: { $0.recovery != nil })?
                            .recovery.map { Int($0.rounded()) },
                        connected: model.live.connected
                    )
                }
                // End the Live Activity the moment the link drops, even if no further HR tick arrives.
                .onReceive(model.live.$connected) { isConnected in
                    liveActivity.update(
                        bpm: isConnected ? (model.bpm ?? model.live.heartRate) : nil,
                        recovery: model.repo.days.last(where: { $0.recovery != nil })?
                            .recovery.map { Int($0.rounded()) },
                        connected: isConnected
                    )
                }
        }
        // HealthKit authorization is intentionally NOT requested on launch. The system permission
        // dialog without prior in-app rationale violates Apple HIG / App Review guidance — the user
        // sees the prompt before any context. It is requested from an explicit user action instead:
        // the "Enable Apple Health" affordance in AppleHealthView (More → Data → Apple Health).
        // Below, `refreshAuthIfPreviouslyGranted` re-primes `auth` for users who already granted
        // access (it only reads write/share status, never prompts) so background syncs resume; and
        // HealthKitBridge.sync guards on `auth == .authorized`, so the scenePhase trigger stays a
        // safe no-op until the user opts in.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.drainPendingIntents()
                // Re-arm the strap's smart alarm on foreground: the firmware alarm is a single instant
                // and iOS can't re-arm it while suspended, so it would otherwise fire once and stop.
                model.applySmartAlarm()
                Task {
                    health.refreshAuthIfPreviouslyGranted()
                    await health.sync()
                    WidgetSnapshot.publish(from: model)
                }
            } else if phase == .background {
                // #155: refresh the Documents/noop_sync.txt drop file the user's Siri Shortcut logs
                // into Apple Health. Gated inside writeIfEnabled on the opt-in default (OFF) — a
                // no-op until the user turns on Shortcuts Export.
                Task { await ShortcutHealthExport.writeIfEnabled(repo: model.repo) }
            }
        }
    }
}

/// iOS root — the `RootTabView` shell with the first-run onboarding/pairing wizard overlaid until
/// complete, the Terms acknowledgment gate over everything until the current version is accepted, and
/// a "What's New" changelog sheet shown automatically after an update.
///
/// This mirrors the macOS `ContentView` (same `@AppStorage` keys, same gate ordering) but swaps the
/// excluded `RootView()` sidebar for `RootTabView()`. The shared `OnboardingWizard`, `TermsGateView`,
/// `WhatsNewView`, `AppChangelog`, and `Terms` symbols all compile into the iOS target unchanged.
private struct iOSRootView: View {
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTerms = ""
    @State private var showWhatsNew = false

    var body: some View {
        #if DEBUG
        // DEBUG-only: `--demo-screen <name>` renders one screen full-bleed (gates bypassed) so a
        // seeded simulator build can be screenshotted deterministically for verification + marketing.
        // No-op in Release (whole branch is #if DEBUG) and when the arg is absent.
        if let demo = DemoScreens.requested {
            // Inherit the app appearance (set via the Theme picker, or `-theme.appearance light|dark`
            // in the launch arguments) so demo/marketing shots can be taken in either scheme.
            return AnyView(
                NavigationStack {
                    demo
                        .background(StrandPalette.surfaceBase.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                }
            )
        }
        #endif
        return AnyView(shell)
    }

    private var shell: some View {
        ZStack {
            RootTabView()
            if !onboarded {
                OnboardingWizard(onFinished: {
                    onboarded = true
                    // A brand-new user just saw the expectations in onboarding — don't also pop the
                    // changelog at them; mark them current.
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            // Terms acknowledgment gate — over EVERYTHING (before onboarding/pairing/Bluetooth) until
            // the current terms version is accepted; re-appears if the terms materially change.
            if acceptedTerms != Terms.currentVersion {
                TermsGateView(onAccept: { acceptedTerms = Terms.currentVersion })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarded)
        .animation(.easeInOut(duration: 0.35), value: acceptedTerms)
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                lastSeenChangelog = AppChangelog.currentVersion
                showWhatsNew = false
            })
        }
        // The Terms gate must stay "over everything" — don't pop What's New on top of it after a
        // combined terms+version update. Gate on terms being current, and re-check when they're
        // accepted (onAppear already fired before acceptance), so What's New shows right after.
        .onAppear { showWhatsNewIfDue() }
        .onChange(of: acceptedTerms) { _, _ in showWhatsNewIfDue() }
    }

    private func showWhatsNewIfDue() {
        // Existing users who updated: their last-seen version is behind the current one.
        if onboarded && acceptedTerms == Terms.currentVersion
            && lastSeenChangelog != AppChangelog.currentVersion {
            showWhatsNew = true
        }
    }
}

#if DEBUG
/// DEBUG-only screenshot harness. Maps `--demo-screen <name>` to a single screen so a seeded
/// simulator build can be captured deterministically (verification + marketing). Stripped from Release.
enum DemoScreens {
    /// The screen named by `--demo-screen <name>`, or nil if the arg is absent/unknown.
    static var requested: AnyView? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-screen"), i + 1 < args.count else { return nil }
        switch args[i + 1].lowercased() {
        case "today":    return AnyView(TodayView())
        case "trends":   return AnyView(TrendsView())
        case "sleep":    return AnyView(SleepView())
        case "live":     return AnyView(LiveView())
        case "stress":   return AnyView(StressView())
        case "workouts": return AnyView(WorkoutsView())
        case "health":   return AnyView(HealthView())
        case "insights": return AnyView(InsightsView())
        case "explore":  return AnyView(MetricExplorerView())
        case "compare":  return AnyView(CompareView())
        case "settings": return AnyView(SettingsView())
        case "devices":  return AnyView(DevicesView())
        case "devicescatalog": return AnyView(DeviceCardCatalog())
        case "fitnessage": return AnyView(FitnessAgeDemoScreen())
        case "vitality": return AnyView(VitalityDemoScreen())
        case "addwizard": return AnyView(AddWizardDemoHost())
        default:         return nil
        }
    }
}
#endif
#endif

#if DEBUG
/// DEBUG-only host so `--demo-screen addwizard` can render the multi-step Add-a-device wizard.
/// A SwiftUI View body is main-actor, so it can pull the injected LiveState and hand it to the
/// wizard's `init(live:)` (the nonisolated DemoScreens switch can't construct a LiveState itself).
private struct AddWizardDemoHost: View {
    @EnvironmentObject var live: LiveState
    var body: some View { AddDeviceWizard(live: live, onClose: {}) }
}
#endif
