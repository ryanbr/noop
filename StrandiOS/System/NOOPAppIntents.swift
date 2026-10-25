#if os(iOS)
import Foundation
import AppIntents

/// Queue of actions requested by an App Intent while the app may be suspended. Intents can't reach
/// into the running `AppModel` directly (BLE only lives in the foreground app), so they enqueue here
/// and the app drains the queue when it next becomes active.
@MainActor
enum PendingIntents {
    typealias Action = PendingIntentQueue.Action
    private static var queue: PendingIntentQueue {
        PendingIntentQueue(defaults: UserDefaults(suiteName: WidgetSnapshot.suiteName))
    }

    @discardableResult
    static func append(_ action: Action, at date: Date? = nil) -> Bool {
        queue.append(action, at: date)
    }

    static func appendAskCoach(question: String, at date: Date? = nil) {
        queue.appendAskCoach(question: question, at: date)
    }

    static func consumeCoachQuestion() -> String? { queue.consumeCoachQuestion() }
    static func drain() -> [PendingIntentQueue.Request] { queue.drain() }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment in NOOP.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// The typed sleep mark selected by a Shortcut; these choices match the existing Sleep card.
enum SleepMarkShortcutType: String, AppEnum {
    case bedtime, wake
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep Mark"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .bedtime: "Bedtime", .wake: "Wake"
    ]
    var action: PendingIntents.Action { self == .bedtime ? .markBedtime : .markWake }
}

enum SleepMarkShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case queueUnavailable
    var localizedStringResource: LocalizedStringResource {
        "NOOP couldn't queue the sleep mark. Open NOOP and try again."
    }
}

/// Capture the invocation time without foregrounding NOOP; the existing active-scene drain saves it.
struct LogSleepMarkIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Sleep Mark"
    static var description = IntentDescription("Queue a bedtime or wake mark. NOOP saves it when the app next becomes active.")
    static var openAppWhenRun = false

    @Parameter(title: "Sleep Mark", default: .bedtime)
    var markType: SleepMarkShortcutType

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard PendingIntents.append(markType.action, at: Date()) else {
            throw SleepMarkShortcutError.queueUnavailable
        }
        return .result(dialog: "Sleep mark queued for the next time NOOP becomes active.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntents.append(.buzz)
        return .result()
    }
}

/// Pull the strap's stored history now: the Shortcuts twin of the "Sync now" button, run WITHOUT opening NOOP.
/// iOS runs an in-app intent inside NOOP's own process (launching or resuming it in the background), where the
/// strap link lives under the bluetooth-central background mode, so the offload carries on after this returns.
/// The spoken/shown reply reports only what this path observed about the sync starting.
///
/// `LiveActivityIntent`, not plain `AppIntent`: that is what lets it START the strap-sync Live Activity
/// (the Dynamic Island "Connecting… / Syncing… N chunks" readout) from the background. A plain intent
/// running in a background-launched app is refused by ActivityKit.
struct SyncStrapIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Sync Strap"
    static var description = IntentDescription("Pull your WHOOP strap's stored history into NOOP now.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await AppModel.startStrapSyncFromShortcut() {
        case .started:               return .result(dialog: "Syncing your strap.")
        case .alreadyRunning:        return .result(dialog: "Your strap is already syncing.")
        case .willSyncWhenConnected: return .result(dialog: "NOOP is connecting to your strap and will sync as soon as it's ready.")
        case .strapNotReady:         return .result(dialog: "Your strap isn't connected to NOOP yet, so the sync didn't start.")
        case .notStarted:            return .result(dialog: "NOOP couldn't start the sync. Open NOOP to see the strap log.")
        }
    }
}

/// K9: Ask the Coach a question via Siri. Queues the question and opens the app, which sends it
/// to the configured provider and surfaces the response. The question is spoken or typed in Siri;
/// the app handles the actual network call using the user's saved key.
struct AskCoachIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Coach"
    static var description = IntentDescription("Ask your NOOP Coach a question about your recovery, sleep, or training.")
    static var openAppWhenRun = true

    /// The question to ask, populated by Siri from the user's spoken phrase.
    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.appendAskCoach(question: question, at: Date())
        return .result(dialog: "Opening Coach with your question: \(question)")
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncStrapIntent(),
                    phrases: [
                        "Sync my \(.applicationName) strap",
                        "Sync \(.applicationName)",
                    ],
                    shortTitle: "Sync Strap",
                    systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: LogSleepMarkIntent(),
                    phrases: ["Log a sleep mark in \(.applicationName)"],
                    shortTitle: "Log Sleep Mark",
                    systemImageName: "bed.double")
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my \(.applicationName) strap"],
                    shortTitle: "Buzz Strap",
                    systemImageName: "waveform.path")
        // K9: "Ask Coach" via Siri — opens Coach with the question and sends it. The question
        // parameter is provided via the Shortcuts app or Siri prompts for it when the phrase fires.
        AppShortcut(intent: AskCoachIntent(),
                    phrases: [
                        "Ask \(.applicationName) about my recovery",
                        "Ask \(.applicationName) how I'm doing",
                        "Ask \(.applicationName) Coach",
                    ],
                    shortTitle: "Ask Coach",
                    systemImageName: "sparkles")
    }
}
#endif
