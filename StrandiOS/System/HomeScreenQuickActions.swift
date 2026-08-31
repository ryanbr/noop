#if os(iOS)
import StrandAnalytics
import SwiftUI
import UIKit

/// The app-specific actions shown when someone touches and holds NOOP's Home Screen icon.
///
/// These are dynamic rather than Info.plist actions so their titles come from NOOP's existing
/// localization catalog and follow the language selected in the app. The menu is installed at launch;
/// changing the app language requires the same process restart that updates every other localized bundle.
enum HomeScreenQuickAction: String, CaseIterable {
    case liveHeartRate = "com.noop.quick-action.live-heart-rate"
    case startWorkout = "com.noop.quick-action.start-workout"
    case logJournal = "com.noop.quick-action.log-journal"
    case breathe = "com.noop.quick-action.breathe"

    init?(shortcutItem: UIApplicationShortcutItem) {
        self.init(rawValue: shortcutItem.type)
    }

    private var localizedTitle: String {
        switch self {
        case .liveHeartRate: String(localized: "Live HR")
        case .startWorkout: String(localized: "Start workout")
        case .logJournal: String(localized: "Log journal")
        case .breathe: String(localized: "Breathe")
        }
    }

    private var symbolName: String {
        switch self {
        case .liveHeartRate: "waveform.path.ecg"
        case .startWorkout: "figure.run"
        case .logJournal: "square.and.pencil"
        case .breathe: "wind"
        }
    }

    private var shortcutItem: UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: rawValue,
            localizedTitle: localizedTitle,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: symbolName),
            userInfo: nil
        )
    }

    @MainActor
    static func install(in application: UIApplication) {
        application.shortcutItems = allCases.map(\.shortcutItem)
    }
}

/// Adds UIKit's scene callback to the SwiftUI app lifecycle. SwiftUI continues to create and own the
/// window; this delegate only names the scene delegate that receives Home Screen quick actions.
final class HomeScreenQuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        HomeScreenQuickAction.install(in: application)
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = HomeScreenQuickActionSceneDelegate.self
        }
        return configuration
    }
}

/// Receives a selected icon action whether it created a new scene or resumed an existing one. SwiftUI
/// automatically places an observable scene delegate in the environment for the scene it manages.
@MainActor
final class HomeScreenQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    // MARK: - Standard-HR persistence at the lifecycle edges (#1770)
    //
    // On the SCENE delegate, not the app delegate, and not on `StrandiOSApp.body`. Both placements are
    // load-bearing and both were arrived at the hard way.
    //
    // Not the body: the same two edges were added there in #1767 and took the iOS build down. `body` is a
    // SINGLE expression carrying ~28 chained modifiers; two more tipped it past the type-checker's budget,
    // and the error was reported at a modifier a hundred lines from the change. The cost was the
    // expression's length, not any leaf of it.
    //
    // Not the app delegate: this app is scene-based — it returns a UISceneConfiguration from
    // `application(_:configurationForConnecting:options:)` — and UIKit does not call
    // applicationDidEnterBackground or applicationWillTerminate on the app delegate of a scene-based app.
    // Those methods would have compiled, shipped, and silently never run, which is a worse failure than a
    // red build because nothing reports it.

    /// Give buffered standard-HR rows a real persistence attempt as the scene leaves the foreground.
    ///
    /// iOS suspends a connected strap WITHOUT a disconnect edge, and the Collector's 30-sample /
    /// 30-second cadence timer does not run while suspended — so a sub-cadence 0x2A37 batch sits in
    /// memory and dies with the app if iOS terminates it before it resumes.
    func sceneDidEnterBackground(_ scene: UIScene) {
        // A bare Task is suspended along with the app, which would leave this doing nothing at the one
        // moment it exists for. Ask UIKit for a window and end it on BOTH paths, so the assertion is
        // always released rather than expiring.
        let application = UIApplication.shared
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = application.beginBackgroundTask(withName: "standard-hr-lifecycle-flush") {
            application.endBackgroundTask(taskID)
            taskID = .invalid
        }
        // @MainActor explicitly: AppModel and BLEManager are both main-actor isolated, and a bare Task
        // from a nonisolated delegate callback does not inherit that. Same idiom BLEManager uses for this
        // exact call on the disconnect edge.
        Task { @MainActor in
            await Self.flushStandardHR(.background)
            if taskID != .invalid {
                application.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }

    /// The final retry edge, for a scene the system is discarding. Best effort BY CONSTRUCTION: there is
    /// no background window here and little time, so this is not a guarantee and must not be described as
    /// one. Usually `sceneDidEnterBackground` has already drained the buffer and an empty Collector is a
    /// cheap no-op.
    func sceneDidDisconnect(_ scene: UIScene) {
        Task { @MainActor in await Self.flushStandardHR(.termination) }
    }

    /// Reaches the live Collector through `AppModel.shared`, the seam App Intents already use. It is
    /// `weak`, so a nil here means no model is alive and there is nothing buffered to lose.
    @MainActor
    private static func flushStandardHR(_ event: StandardHRLifecycleFlush.Event) async {
        guard let ble = AppModel.shared?.ble else { return }
        await StandardHRLifecycleFlush.run(event: event) { reason in
            await ble.flushStandardHRForLifecycle(reason: reason)
        }
    }

    @Published private(set) var pendingAction: HomeScreenQuickAction?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem {
            pendingAction = HomeScreenQuickAction(shortcutItem: shortcutItem)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem
    ) async -> Bool {
        guard let action = HomeScreenQuickAction(shortcutItem: shortcutItem) else { return false }
        pendingAction = action
        return true
    }

    /// Clears only the action the shell is about to present, protecting a newer selection from an old
    /// subscriber callback if two lifecycle events arrive close together.
    func consume(_ action: HomeScreenQuickAction) {
        guard pendingAction == action else { return }
        pendingAction = nil
    }
}
#endif
