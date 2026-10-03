import Foundation

/// Persisted foreground actions from iOS Shortcuts. The string-array format retains legacy requests.
struct PendingIntentQueue {
    enum Action: String {
        case markMoment, buzz, askCoach, markBedtime, markWake
    }

    struct Request: Equatable {
        let action: Action
        let date: Date?

        /// Sleep marks require the invocation time; a legacy bare action has no such timestamp.
        var sleepMark: SleepMark? {
            guard let date else { return nil }
            switch action {
            case .markBedtime: return SleepMark(type: .bedtime, at: date)
            case .markWake: return SleepMark(type: .wake, at: date)
            default: return nil
            }
        }
    }

    private static let key = "noop.pendingIntents"
    /// Existing Ask Coach contract: one pending question, stored apart because its text may contain colons.
    private static let coachQuestionKey = "noop.pendingCoachQuestion"
    let defaults: UserDefaults?

    @discardableResult
    func append(_ action: Action, at date: Date? = nil) -> Bool {
        guard let defaults else { return false }
        if let date {
            guard Self.validEpoch(date.timeIntervalSince1970) else { return false }
        } else if action == .markBedtime || action == .markWake {
            return false
        }
        var list = defaults.stringArray(forKey: Self.key) ?? []
        list.append(date.map { "\(action.rawValue):\($0.timeIntervalSince1970)" } ?? action.rawValue)
        defaults.set(list, forKey: Self.key)
        return true
    }

    func appendAskCoach(question: String, at date: Date? = nil) {
        guard let defaults else { return }
        defaults.set(question, forKey: Self.coachQuestionKey)
        append(.askCoach, at: date)
    }

    func consumeCoachQuestion() -> String? {
        let question = defaults?.string(forKey: Self.coachQuestionKey)
        defaults?.removeObject(forKey: Self.coachQuestionKey)
        return question
    }

    func drain() -> [Request] {
        guard let defaults else { return [] }
        let raw = defaults.stringArray(forKey: Self.key) ?? []
        defaults.removeObject(forKey: Self.key)
        return raw.compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let action = Action(rawValue: String(first)) else { return nil }
            if parts.count == 1 {
                guard action != .markBedtime && action != .markWake else { return nil }
                return Request(action: action, date: nil)
            }
            guard let epoch = Double(parts[1]), Self.validEpoch(epoch) else { return nil }
            return Request(action: action, date: Date(timeIntervalSince1970: epoch))
        }
    }

    /// Bound persisted timestamps before SleepMark converts seconds to integer milliseconds.
    private static func validEpoch(_ epoch: Double) -> Bool {
        epoch.isFinite && epoch >= Date.distantPast.timeIntervalSince1970
            && epoch <= Date.distantFuture.timeIntervalSince1970
    }
}
