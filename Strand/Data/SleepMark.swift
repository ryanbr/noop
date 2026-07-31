import Foundation
import WhoopStore

// MARK: - SleepMark (#461 Phase 1 — tap-to-mark "going to sleep" / "awake")
//
// A user-tapped sleep boundary, captured for the record only — it does NOT feed the sleep detector
// (that stays the strap's job). Phase 1 is pure logging: every mark is persisted into the existing
// long-format `metricSeries` store under the key "sleep_mark" AND appended as a human-readable line
// to the shareable strap log, so a mark shows up in a debug export.
//
// The store's natural key is (deviceId, day, key) with a single REAL `value`, so we encode the mark
// TYPE in the value (0 = bedtime, 1 = wake) and key the row on the mark's local calendar day. The
// precise wall-clock instant lives in the strap-log line (and `tsMs` here). Tap-driven sleep bounds
// and personal calibration build on this in later phases.
//
// Everything here is pure + platform-free so it unit-tests without a UI: encode → MetricPoint,
// decode ← MetricPoint, and the formatted log line. The view is the only place that does I/O.

/// One sleep boundary the user tapped.
enum SleepMarkType: Int, Equatable, Sendable {
    case bedtime = 0   // "Going to sleep"
    case wake = 1      // "I'm awake"

    /// The value persisted into the `sleep_mark` metric series (0 = bedtime, 1 = wake).
    var seriesValue: Double { Double(rawValue) }

    /// Decode a persisted series value back to a type. Tolerant of float drift (rounds) and clamps
    /// any unexpected value to the nearest valid case so a corrupt row never crashes a read-back.
    static func from(seriesValue: Double) -> SleepMarkType {
        Int(seriesValue.rounded()) == SleepMarkType.wake.rawValue ? .wake : .bedtime
    }

    /// Short word used in the confirming toast / strap-log line.
    var word: String { self == .bedtime ? "bedtime" : "wake" }
}

/// A captured mark: a type plus the wall-clock instant it was tapped (unix MILLISECONDS, matching the
/// `tsMs` the spec asks for). The calendar `day` is derived locally for the store's natural key.
struct SleepMark: Equatable, Sendable {
    let type: SleepMarkType
    let tsMs: Int64

    init(type: SleepMarkType, tsMs: Int64) {
        self.type = type
        self.tsMs = tsMs
    }

    /// Capture a mark at `now` (defaults to the current instant — injectable for tests).
    init(type: SleepMarkType, at now: Date = Date()) {
        self.type = type
        self.tsMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
    }

    /// The mark's local calendar day (yyyy-MM-dd) — the `day` component of the store's natural key.
    /// Uses the device's local zone so a mark lands on the day the user actually tapped it.
    var dayKey: String { SleepMark.dayFormatter.string(from: date) }

    /// The tap instant as a `Date`.
    var date: Date { Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0) }

    /// Project this mark into a `metricSeries` row: key "sleep_mark", value 0/1 = type, day = local
    /// calendar day. (Upsert is idempotent by (deviceId, day, key); a later same-day mark replaces the
    /// earlier value — the strap log keeps the full sequence, which Phase-1 logging relies on.)
    var metricPoint: MetricPoint {
        MetricPoint(day: dayKey, key: SleepMark.seriesKey, value: type.seriesValue)
    }

    /// Reconstruct a mark from a persisted point — the round-trip read-back. The point carries no
    /// sub-day time, so the instant resolves to that day's local midnight; the type is exact.
    static func from(point: MetricPoint) -> SleepMark? {
        guard point.key == seriesKey,
              let day = dayFormatter.date(from: point.day) else { return nil }
        return SleepMark(type: .from(seriesValue: point.value),
                         tsMs: Int64((day.timeIntervalSince1970 * 1000).rounded()))
    }

    /// The human-readable strap-log line, e.g. "Sleep mark · bedtime (going to sleep) @ 23:42".
    /// Appended to the shared strap log so the mark appears in a debug export. Carries no PII.
    var logLine: String {
        let clock = SleepMark.clockFormatter.string(from: date)
        let phrase = type == .bedtime ? "going to sleep" : "awake"
        return "Sleep mark · \(type.word) (\(phrase)) @ \(clock)"
    }

    /// The confirming toast / transient line shown after a tap, e.g. "Logged bedtime at 23:42."
    /// Identical copy on both platforms (Kotlin twin: SleepMark.confirmation()).
    var confirmation: String {
        let clock = SleepMark.clockFormatter.string(from: date)
        // Two whole-phrase variants (not a stitched noun) so each localizes naturally.
        return type == .bedtime
            ? String(localized: "Logged bedtime at \(clock).")
            : String(localized: "Logged wake-up at \(clock).")
    }

    // MARK: - Constants / formatters

    /// The metric-series key all sleep marks share.
    static let seriesKey = "sleep_mark"

    /// yyyy-MM-dd in the device's local zone, matching how the rest of the store keys days.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Device-locale clock for the log line ("11:42 PM" / "23:42") — follows the 12-/24-hour setting,
    /// matching the Sleep screen's Asleep/Woke row.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}
