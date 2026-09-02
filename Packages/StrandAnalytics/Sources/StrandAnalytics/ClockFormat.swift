import Foundation

/// #1821: which clock the UI shows times in. Twin of the Kotlin `ClockFormatPreference`.
///
/// NOOP had no such setting: every user-facing time came from the device REGION's convention. On Apple
/// `AppLanguage.activeLocale` builds `language_REGION` deliberately, to keep regional date order and
/// clock style - but constructing a locale from a region identifier DISCARDS the user's explicit
/// "24-Hour Time" switch, because that override lives on `Locale.autoupdatingCurrent`, not on the region
/// default. A reader in a 24-hour region who prefers 12-hour had no way to say so, which is the report
/// this exists to answer.
public enum ClockFormatPreference: String, CaseIterable, Sendable {
    /// Follow the device's own clock switch. The default, so nobody's display changes on upgrade.
    case system
    case twelveHour
    case twentyFourHour

    /// Persistence key, shared by the Apple `@AppStorage` binding and the Android preference so the two
    /// platforms cannot drift apart on the name of the thing they store.
    public static let defaultsKey = "clockFormatPreference"

    /// Unknown/absent stored values fall back to `.system` rather than to a hardcoded clock: a value we
    /// cannot parse must not silently pin every reader to one format.
    public static func from(stored: String?) -> ClockFormatPreference {
        guard let stored, let parsed = ClockFormatPreference(rawValue: stored) else { return .system }
        return parsed
    }
}

public enum ClockFormat {
    /// Resolve the preference against what the device reports. `systemUses24Hour` is injected rather than
    /// read here so this stays pure and identically testable on both platforms - Apple derives it from
    /// `Locale.autoupdatingCurrent` (which DOES carry the 24-Hour Time switch), Android from
    /// `DateFormat.is24HourFormat(context)`.
    public static func uses24Hour(preference: ClockFormatPreference, systemUses24Hour: Bool) -> Bool {
        switch preference {
        case .system:         return systemUses24Hour
        case .twelveHour:     return false
        case .twentyFourHour: return true
        }
    }

    /// Literal wall-clock pattern at minute precision, for formatters driven by an explicit pattern.
    /// Used by Android, whose existing time labels already build `SimpleDateFormat` from a literal.
    public static func hourMinutePattern(uses24Hour: Bool) -> String {
        uses24Hour ? "HH:mm" : "h:mm a"
    }

    /// A locale identifier carrying an explicit HOUR CYCLE, so a formatter driven by `timeStyle` or by a
    /// `j`-bearing template resolves the clock the reader chose instead of the region default.
    ///
    /// This is what lets the setting reach the ~17 Apple formatters that never mention "HH:mm" at all -
    /// they say `timeStyle = .short` or template `"jmm"`, and both ask the LOCALE for the hour. Rewriting
    /// each into an explicit pattern would have thrown away localized date order, separators and AM/PM
    /// wording; setting the hour cycle keeps all of it and changes only the part the reader asked for.
    ///
    /// `h23`/`h12` are the ICU `hours` keyword values. A malformed identifier would silently fall back to
    /// the base locale - a no-op that looks like a working setting - so `ClockFormatLocaleTests` asserts
    /// against a real `DateFormatter` on macOS rather than trusting the string.
    public static func hourCycleLocaleIdentifier(base: String, uses24Hour: Bool) -> String {
        "\(base)@hours=\(uses24Hour ? "h23" : "h12")"
    }

    /// SKELETON template for the same time, for `setLocalizedDateFormatFromTemplate`. Apple uses this
    /// rather than the literal above so the locale still decides ordering, separator and AM/PM wording,
    /// while the H-vs-h choice - the only part the reader asked to control - stays ours. Note this is
    /// deliberately NOT the `j` template the buggy path used: `j` resolves the hour from the locale, which
    /// is exactly how a reader's explicit preference got discarded.
    public static func hourMinuteTemplate(uses24Hour: Bool) -> String {
        uses24Hour ? "Hmm" : "hmm"
    }
}
