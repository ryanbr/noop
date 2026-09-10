import Foundation

public enum DayCycleMode: String, CaseIterable, Sendable {
    case sleepOnset = "sleep_onset"
    case midnight = "midnight"

    public static let storageKey = "noop.dayCycleMode"
    /// Kotlin twin: `DayCycleMode.fromPersisted`.
    public static func persisted(_ value: String?) -> DayCycleMode {
        value.flatMap(Self.init(rawValue:)) ?? .sleepOnset
    }
}

public struct DayCycleWindow: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case detectedSleep, editedSleep, syntheticMidnight, calendar }
    public let id: String
    public let startInclusive: Int
    public let endExclusive: Int
    public let displayDay: String
    public let source: Source

    public init(id: String, startInclusive: Int, endExclusive: Int, displayDay: String, source: Source) {
        self.id = id; self.startInclusive = startInclusive; self.endExclusive = endExclusive
        self.displayDay = displayDay; self.source = source
    }
}

public enum DayCycleResolver {
    public static let minSyntheticMidnightAgeSeconds = 18 * 3_600
    public static let absoluteMaxOpenSeconds = 40 * 3_600

    /// Kotlin twin: `DayCycleResolver.calendarWindow`.
    public static func calendarWindow(now: Int, offsetSec: Int) -> DayCycleWindow {
        let local = now + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let start = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        let day = AnalyticsEngine.dayString(start, offsetSec: offsetSec)
        return DayCycleWindow(id: "calendar:\(day)", startInclusive: start, endExclusive: now,
                              displayDay: day, source: .calendar)
    }

    /// Kotlin twin: `DayCycleResolver.fallbackMidnightAfter`.
    public static func fallbackMidnight(after start: Int, offsetSec: Int) -> Int {
        let minimum = start + minSyntheticMidnightAgeSeconds
        let local = minimum + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let midnight = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        return midnight >= minimum ? midnight : (dayNumber + 1) * SleepStageTotals.secondsPerDay - offsetSec
    }

    /// Kotlin twin: `DayCycleResolver.activeWindow`.
    public static func activeWindow(mode: DayCycleMode, latestSleep: DayCycleWindow?, now: Int,
                                    offsetSec: Int) -> DayCycleWindow {
        guard mode == .sleepOnset, let latestSleep else { return calendarWindow(now: now, offsetSec: offsetSec) }
        let age = now - latestSleep.startInclusive
        let fallback = fallbackMidnight(after: latestSleep.startInclusive, offsetSec: offsetSec)
        // Sleep-onset mode stays anchored across midnight unconditionally: only the absolute safety cap
        // may synthesize a fallback boundary. An earlier design gated this on whether awake coverage was
        // reliable and carried a `reliableAwakeCoverage` parameter for it; the gate was dropped but the
        // parameter survived, unread on both platforms and passed `false` by every one of its five call
        // sites. Removed rather than left looking like a switch someone could flip.
        guard age < absoluteMaxOpenSeconds else {
            let day = AnalyticsEngine.dayString(fallback, offsetSec: offsetSec)
            return DayCycleWindow(id: "synthetic:\(day)", startInclusive: fallback, endExclusive: now,
                                  displayDay: day, source: .syntheticMidnight)
        }
        return DayCycleWindow(id: latestSleep.id, startInclusive: latestSleep.startInclusive,
                              endExclusive: now, displayDay: latestSleep.displayDay, source: latestSleep.source)
    }
}
