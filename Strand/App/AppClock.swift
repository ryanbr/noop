import Foundation
import StrandAnalytics

/// #1821: the app-side reader for the Clock format setting. Sits next to `AppLanguage` because it
/// answers the same shape of question - what conventions do we render in - and because the bug it fixes
/// lives in `AppLanguage.activeLocale`.
///
/// `activeLocale` builds `language_REGION` on purpose, to keep the device's regional date order and
/// clock style. But a locale built from a REGION identifier carries that region's DEFAULT hour cycle,
/// and the user's explicit Settings > General > Date & Time > 24-Hour Time switch is not part of it -
/// that override lives on `Locale.autoupdatingCurrent`. So the switch was silently discarded, and a
/// reader in a 24-hour region could not get a 12-hour clock by any means at all.
enum AppClock {
    /// The stored preference, defaulting to `.system` so an upgrade changes nobody's display.
    static var preference: ClockFormatPreference {
        ClockFormatPreference.from(stored: UserDefaults.standard.string(forKey: ClockFormatPreference.defaultsKey))
    }

    /// What the DEVICE is set to, read from `autoupdatingCurrent` precisely because that is the locale
    /// the 24-Hour Time switch modifies. A 12-hour locale's `j` template contains the AM/PM symbol.
    static var systemUses24Hour: Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0,
                                                locale: Locale.autoupdatingCurrent) ?? "H"
        return !template.contains("a")
    }

    static var uses24Hour: Bool {
        ClockFormat.uses24Hour(preference: preference, systemUses24Hour: systemUses24Hour)
    }

    /// The locale to hand any time-rendering `DateFormatter`. Carries an explicit hour cycle, so the
    /// setting also reaches the formatters that never name a pattern - the ones using `timeStyle = .short`
    /// or a `"jmm"` template, which ask the LOCALE for the hour and were therefore getting the region
    /// default. Everything else about the locale (date order, separators, AM/PM wording, month names)
    /// still comes from `AppLanguage.activeLocale`, exactly as before.
    static var formattingLocale: Locale {
        Locale(identifier: ClockFormat.hourCycleLocaleIdentifier(
            base: AppLanguage.activeLocale.identifier, uses24Hour: uses24Hour))
    }

    /// Cached by resolved template: building a `DateFormatter` is expensive and these are read per row in
    /// scrolling lists, but the cache MUST key on the template rather than being a plain `static let`, or
    /// changing the setting would not take effect until the app restarted.
    private static var cached: (template: String, locale: String, formatter: DateFormatter)?
    /// The cache is mutable global state and `onsetText` is read from whatever thread builds a
    /// `SleepModel`, so the read-modify-write below is serialised. SWIFT_VERSION is 5.0 here, so the
    /// compiler would not have objected - a torn read would just have been a rare, baffling crash.
    private static let cacheLock = NSLock()

    /// Wall-clock time at minute precision, honouring the setting. The locale still supplies ordering,
    /// separator and AM/PM wording; only the hour cycle is ours.
    static func hourMinuteFormatter() -> DateFormatter {
        let template = ClockFormat.hourMinuteTemplate(uses24Hour: uses24Hour)
        let locale = AppLanguage.activeLocale
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached, cached.template == template, cached.locale == locale.identifier {
            return cached.formatter
        }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        cached = (template, locale.identifier, f)
        return f
    }

    /// Convenience for the many call sites that just want the string.
    static func hourMinute(_ date: Date) -> String { hourMinuteFormatter().string(from: date) }

    static func hourMinute(unix ts: Int) -> String {
        hourMinute(Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
