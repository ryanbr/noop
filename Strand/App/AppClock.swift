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
    /// the 24-Hour Time switch modifies.
    ///
    /// #1829: MEMOISED. This calls `DateFormatter.dateFormat(fromTemplate:options:locale:)`, which builds
    /// an ICU pattern generator - one of the more expensive things Foundation offers - and the first cut
    /// of this ran it on EVERY access, ahead of the formatter cache. Since ~17 call sites had just been
    /// converted from `static let` to computed properties, that put an ICU build behind every time label
    /// on screen. The cache saved the cheap allocation and missed the expensive call entirely.
    static var systemUses24Hour: Bool {
        // Arm the invalidator HERE, not in hourMinuteFormatter(): four call sites reach AppClock only
        // through `formattingLocale` and would never have registered it, leaving their memo pinned to a
        // stale clock for the life of the process. Every path lands here — Swift evaluates both arguments
        // of ClockFormat.uses24Hour(preference:systemUses24Hour:) eagerly — so this is the one chokepoint.
        // Touched before the lock: registration does not need it, and taking it twice would not nest.
        _ = localeObserver
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedSystem24 { return cachedSystem24 }
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0,
                                                locale: Locale.autoupdatingCurrent) ?? "H"
        let v = !template.contains("a")
        cachedSystem24 = v
        return v
    }

    static var uses24Hour: Bool {
        ClockFormat.uses24Hour(preference: preference, systemUses24Hour: systemUses24Hour)
    }

    /// #1829: memoised for the same reason - `AppLanguage.activeLocale` reads
    /// `Bundle.main.preferredLocalizations` and then CONSTRUCTS a `Locale`, per access.
    static var activeLocale: Locale {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedActiveLocale { return cachedActiveLocale }
        let l = AppLanguage.activeLocale
        cachedActiveLocale = l
        return l
    }

    /// The locale to hand any time-rendering `DateFormatter`. Carries an explicit hour cycle, so the
    /// setting also reaches formatters that never name a pattern (`timeStyle`, a `"jmm"` template).
    static var formattingLocale: Locale {
        let id = ClockFormat.hourCycleLocaleIdentifier(base: activeLocale.identifier,
                                                       uses24Hour: uses24Hour)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cachedFormattingLocale, cachedFormattingLocaleID == id { return cachedFormattingLocale }
        let l = Locale(identifier: id)
        cachedFormattingLocale = l
        cachedFormattingLocaleID = id
        return l
    }

    private static var cached: (template: String, locale: String, formatter: DateFormatter)?
    private static var cachedSystem24: Bool?
    private static var cachedActiveLocale: Locale?
    private static var cachedFormattingLocale: Locale?
    private static var cachedFormattingLocaleID: String?
    /// One lock for every cache here. Each accessor takes it around its own read-modify-write and
    /// releases before returning, so none of them nest - NSLock is not recursive and a nested take would
    /// deadlock the main thread, which is a far worse failure than the cost this exists to avoid.
    private static let cacheLock = NSLock()

    /// Drop every memo. Called when the reader changes the setting, and when the SYSTEM clock or locale
    /// changes underneath us - `systemUses24Hour` can flip with no write of our own, so without this the
    /// memo would pin a stale answer for the life of the process.
    static func invalidate() {
        cacheLock.lock()
        cached = nil
        cachedSystem24 = nil
        cachedActiveLocale = nil
        cachedFormattingLocale = nil
        cachedFormattingLocaleID = nil
        cacheLock.unlock()
    }

    /// #1829: registers exactly once, on first use — a `static let` is lazy and thread-safe in Swift, so
    /// touching it below is the whole registration. The system 24-hour switch and the device locale can
    /// both change with no write from us; without this the memo above would serve a stale answer for the
    /// rest of the process, which is worse than the per-access cost it replaced.
    private static let localeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
    ) { _ in AppClock.invalidate() }

    /// Wall-clock time at minute precision, honouring the setting.
    static func hourMinuteFormatter() -> DateFormatter {
        let template = ClockFormat.hourMinuteTemplate(uses24Hour: uses24Hour)
        let locale = activeLocale
        cacheLock.lock(); defer { cacheLock.unlock() }
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
