import SwiftUI
import StrandDesign

@main
struct StrandApp: App {
    @StateObject private var model = AppModel()
    /// Shared cross-screen navigation hook (e.g. Live → Devices). The macOS shell (`RootView`)
    /// observes it and drives the sidebar selection.
    @StateObject private var router = NavRouter()
    /// Appearance preference (System/Light/Dark). Default follows the OS; the Settings picker writes it.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// Chart data-colour style (Titanium / Classic throwback). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(router)
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
