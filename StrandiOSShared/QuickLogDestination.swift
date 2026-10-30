import Foundation

/// Navigation-only widget routes. Amounts and timestamps are chosen in the app's existing editors;
/// opening a URL never writes a health entry or changes a tracker preference.
enum QuickLogDestination: String, CaseIterable, Identifiable, Sendable {
    case hydration, caffeine, journal, workout

    var id: String { rawValue }

    var url: URL { URL(string: "noop://quick-log/\(rawValue)")! }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "noop", url.host?.lowercased() == "quick-log",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let destination = Self(rawValue: String(url.path.dropFirst())),
              url.path == "/\(destination.rawValue)" else { return nil }
        self = destination
    }

    var title: String {
        switch self {
        case .hydration: String(localized: "Hydration")
        case .caffeine: String(localized: "Caffeine")
        case .journal: String(localized: "Journal")
        case .workout: String(localized: "Workouts")
        }
    }

    var symbol: String {
        switch self {
        case .hydration: "drop.fill"
        case .caffeine: "cup.and.saucer.fill"
        case .journal: "square.and.pencil"
        case .workout: "figure.run"
        }
    }
}

/// Retains a cold-launch request until onboarding, terms, and automatic launch sheets are resolved.
/// Taking a request consumes it once; an unrelated URL cannot erase a deferred selection.
struct QuickLogRequest {
    private(set) var pending: QuickLogDestination?

    @discardableResult
    mutating func receive(_ url: URL) -> Bool {
        guard let destination = QuickLogDestination(url: url) else { return false }
        pending = destination
        return true
    }

    mutating func take(ifAllowed allowed: Bool) -> QuickLogDestination? {
        guard allowed else { return nil }
        defer { pending = nil }
        return pending
    }
}
