import Foundation

struct TrainingFavorite: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var sport: String?
    var programID: String?
    static let defaults: [Self] = [
        .init(id: 0, name: "", sport: "Strength"),
        .init(id: 1, name: "", sport: "Running"),
        .init(id: 2, name: "")
    ]
    static let storageKey = "noop.trainingFavorites"
    static let configurationURL = URL(string: "noop://training-favorites")!
    static func load(from defaults: UserDefaults = .standard) -> [Self] {
        guard let data = defaults.data(forKey: storageKey),
              let values = try? JSONDecoder().decode([Self].self, from: data),
              values.count == 3, values.map(\.id) == [0, 1, 2] else { return Self.defaults }
        return values
    }
    static func save(_ values: [Self], into defaults: UserDefaults = .standard) {
        guard values.count == 3, values.map(\.id) == [0, 1, 2], let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct TrainingDisplay: Codable, Hashable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var clockStart: Date
    var pausedAt: Date?
    var pulseDeadline: Date?
    var confirmationUntil: Date?
    var confirmationToken: String?
    var error: String?
    var sport: String?
    func isConfirming(at now: Date = Date()) -> Bool { confirmationUntil.map { now < $0 } ?? false }
}

struct TrainingSnapshot: Codable, Equatable {
    var favorites: [TrainingFavorite]
    var sessions: [TrainingDisplay]
    var labels: [String: String]
    static let storageKey = "noop.trainingWidget"
    static var unavailable: Self { .init(favorites: [], sessions: [], labels: [:]) }
    static func load() -> Self {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .unavailable }
        return value
    }
    func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

struct TrainingEndConfirmation: Equatable {
    let sessionID: String
    let token: String
    let until: Date
    init(sessionID: String, now: Date = Date()) {
        self.sessionID = sessionID; token = UUID().uuidString; until = now.addingTimeInterval(30)
    }
    init?(restoring training: TrainingDisplay, now: Date = Date()) {
        guard let token = training.confirmationToken, let until = training.confirmationUntil,
              now < until, until.timeIntervalSince(now) <= 30 else { return nil }
        sessionID = training.id; self.token = token; self.until = until
    }
    func accepts(sessionID: String, token: String, now: Date = Date()) -> Bool {
        self.sessionID == sessionID && self.token == token && now < until
    }
}
