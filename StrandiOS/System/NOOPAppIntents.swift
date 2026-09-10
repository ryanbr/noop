#if os(iOS)
import Foundation
import AppIntents

/// Queue of actions requested by an App Intent while the app may be suspended. Intents can't reach
/// into the running `AppModel` directly (BLE only lives in the foreground app), so they enqueue here
/// and the app drains the queue when it next becomes active.
enum PendingIntents {
    enum Action: String { case markMoment, buzz, askCoach }

    private static let key = "noop.pendingIntents"
    /// K9: the question text for a pending `.askCoach` action. Stored separately because the
    /// action queue encodes as `[String]` and a question can contain colons.
    private static let coachQuestionKey = "noop.pendingCoachQuestion"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Optional `at` is the invocation time, captured now and consumed on drain. Encoded into the
    /// stored string as "rawValue:epochSeconds" so the array stays a plain [String] (no schema
    /// migration; a legacy bare "markMoment" still decodes with a nil date).
    static func append(_ action: Action, at date: Date? = nil) {
        guard let d = defaults else { return }
        var list = d.stringArray(forKey: key) ?? []
        if let date { list.append("\(action.rawValue):\(date.timeIntervalSince1970)") }
        else { list.append(action.rawValue) }
        d.set(list, forKey: key)
    }

    /// K9: queue an "Ask Coach" action with the associated question text. The question is stored
    /// in a dedicated key (one pending question at a time — the user rarely queues multiple Siri
    /// questions before the app opens).
    static func appendAskCoach(question: String, at date: Date? = nil) {
        guard let d = defaults else { return }
        d.set(question, forKey: coachQuestionKey)
        append(.askCoach, at: date)
    }

    /// K9: read and clear the pending coach question. Returns nil when no question is queued.
    static func consumeCoachQuestion() -> String? {
        guard let d = defaults else { return nil }
        let q = d.string(forKey: coachQuestionKey)
        d.removeObject(forKey: coachQuestionKey)
        return q
    }

    static func drain() -> [(action: Action, date: Date?)] {
        guard let d = defaults else { return [] }
        let raw = d.stringArray(forKey: key) ?? []
        d.removeObject(forKey: key)
        return raw.compactMap { entry in
            // Guard `parts.first` rather than subscripting `parts[0]`: split(omittingEmptySubsequences:
            // true by default) returns an EMPTY array for an empty or ":"-leading entry, and indexing
            // [0] there is a fatal trap. This value comes from shared App Group defaults read untrusted,
            // so a corrupt/foreign entry must be skipped, not crash the app on foreground.
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard let first = parts.first, let action = Action(rawValue: String(first)) else { return nil }
            let date = parts.count == 2 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil
            return (action, date)
        }
    }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment in NOOP.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntents.append(.buzz)
        return .result()
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

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.appendAskCoach(question: question, at: Date())
        return .result(dialog: "Opening Coach with your question: \(question)")
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
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
