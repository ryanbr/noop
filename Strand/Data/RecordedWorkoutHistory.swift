import Foundation
import WhoopProtocol
import WhoopStore

/// Recorded sessions remain eligible as history arrives; hand-entered workouts keep their metrics.
enum RecordedWorkoutHistory {
    static let defaultsKey = "noop.recordedWorkoutHistory"
    static let retentionSeconds = 14 * 86_400

    struct Entry: Codable, Equatable {
        var deviceId: String
        var startTs: Int
        var endTs: Int
        var sport: String
        var pauses: [DateInterval]

        func matches(_ row: WorkoutRow, deviceId: String) -> Bool {
            row.source == "manual" && self.deviceId == deviceId
                && startTs == row.startTs && endTs == row.endTs && sport == row.sport
        }

        func activeSamples(_ samples: [HRSample]) -> [HRSample] {
            samples.compactMap { sample in
                let stamp = Double(sample.ts)
                guard sample.ts >= startTs, sample.ts <= endTs,
                      !pauses.contains(where: { stamp >= $0.start.timeIntervalSince1970 && stamp < $0.end.timeIntervalSince1970 })
                else { return nil }
                // Compress completed pauses so the scorer cannot credit the gap as training.
                let pausedSeconds = pauses.filter { $0.end.timeIntervalSince1970 <= stamp }.reduce(0) { $0 + $1.duration }
                return HRSample(ts: sample.ts - Int(pausedSeconds), bpm: sample.bpm)
            }
        }
    }

    static func load(from defaults: UserDefaults = .standard, now: Int = Int(Date().timeIntervalSince1970)) -> [Entry] {
        let entries = defaults.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        return entries.filter { entry in
            entry.startTs > 0 && entry.endTs >= entry.startTs && entry.endTs >= now - retentionSeconds
                && entry.endTs <= now + 86_400 && entry.pauses.allSatisfy {
                    $0.duration.isFinite && $0.start.timeIntervalSince1970.isFinite
                        && $0.start.timeIntervalSince1970 >= Double(entry.startTs)
                        && $0.end.timeIntervalSince1970 <= Double(entry.endTs)
                }
        }
    }

    static func remember(_ row: WorkoutRow, deviceId: String, pauses: [DateInterval],
                         into defaults: UserDefaults = .standard) {
        var entries = load(from: defaults)
        entries.removeAll { $0.deviceId == deviceId && $0.startTs == row.startTs && $0.sport == row.sport }
        let window = DateInterval(start: Date(timeIntervalSince1970: Double(row.startTs)),
                                  end: Date(timeIntervalSince1970: Double(row.endTs)))
        let clipped = pauses.compactMap { $0.intersection(with: window) }.filter { $0.duration > 0 }
        entries.append(Entry(deviceId: deviceId, startTs: row.startTs, endTs: row.endTs, sport: row.sport, pauses: clipped))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: defaultsKey) }
    }

    static func forget(_ row: WorkoutRow, deviceId: String, in defaults: UserDefaults = .standard) {
        let entries = load(from: defaults).filter { !$0.matches(row, deviceId: deviceId) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: defaultsKey) }
    }
}
