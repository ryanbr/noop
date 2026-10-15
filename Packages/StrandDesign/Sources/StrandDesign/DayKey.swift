import Foundation

/// "yyyy-MM-dd" day keys, the calendar-day identity stored rows carry, turned into dates and back.
///
/// A key parses to UTC midnight. That is the app's convention because a UTC parse never fails, where a
/// device-zone parse returns nil on a day whose midnight DST skips (Santiago, Havana, Beirut). A date made
/// this way must also be marked and named in UTC: in the device zone it is the evening before west of UTC,
/// which is how "2026-08-25" read "24 Aug". Real timestamps keep the device zone.
public enum DayKey {

    /// The calendar a parsed day key is marked and named in. Charts plotting day keys pass it as theirs.
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The key at UTC midnight, or nil when it is not a "yyyy-MM-dd" day.
    public static func date(_ key: String) -> Date? { parser.date(from: key) }

    /// The key a `date(_:)` result came from.
    public static func key(_ date: Date) -> String { parser.string(from: date) }

    /// A formatter that names a parsed key's own day: `dateFormat` in UTC. Build it once and keep it, as a
    /// DateFormatter is expensive to create.
    public static func formatter(_ dateFormat: String,
                                 locale: Locale = Locale(identifier: "en_US_POSIX")) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.dateFormat = dateFormat
        return f
    }

    /// `formatter(_:locale:)` from a localized template ("dMMM"), resolved for `locale`.
    public static func formatter(template: String, locale: Locale) -> DateFormatter {
        let f = formatter("", locale: locale)
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let parser = formatter("yyyy-MM-dd")
}

/// A Monday-first Gregorian calendar and the chart components' two day formatters, all in one zone.
///
/// Cached per zone: `YearHeatStrip` reads `.component` for up to 365 days per layout and a chart tooltip
/// formats on every hover frame, so building a Calendar or a DateFormatter per access is too costly.
struct DayZone {
    let calendar: Calendar
    /// "MMM", the year strip's month labels.
    let month: DateFormatter
    /// "EEE d MMM", the chart tooltips and the year strip's cell labels.
    let day: DateFormatter

    private init(_ timeZone: TimeZone) {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday-first columns read nicely
        c.timeZone = timeZone
        calendar = c
        month = DateFormatter(); month.dateFormat = "MMM"; month.timeZone = timeZone
        day = DateFormatter(); day.dateFormat = "EEE d MMM"; day.timeZone = timeZone
    }

    private static let lock = NSLock()
    private static var cache: [String: DayZone] = [:]

    static func `for`(_ timeZone: TimeZone) -> DayZone {
        lock.lock(); defer { lock.unlock() }
        if let zone = cache[timeZone.identifier] { return zone }
        let zone = DayZone(timeZone)
        cache[timeZone.identifier] = zone
        return zone
    }
}
