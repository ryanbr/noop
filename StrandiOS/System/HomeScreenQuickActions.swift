#if os(iOS)
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
