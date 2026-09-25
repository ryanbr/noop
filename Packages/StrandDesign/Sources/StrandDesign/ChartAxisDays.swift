import Foundation

/// The days a date axis puts a mark on: day-aligned, distinct, newest always among them.
///
/// Shared by every chart whose x-axis spans DAYS. Charts whose x-axis spans hours (the intraday HR
/// traces in `OverviewHRChart` and the Health detail) want time marks instead and do not use this.
public enum ChartAxisDays {

    /// The axis used to ask Swift Charts for a COUNT (`.automatic(desiredCount: 5)`) and let it choose the
    /// stride. Over a short window the stride it chooses is sub-day, so more than one mark lands inside a
    /// single calendar day, every one of them formats to the same date, and they print on top of each
    /// other. The reported screenshot is that duplication, not crowding: a wider card would have spread
    /// the duplicates apart and left them just as wrong.
    ///
    /// Explicit dates rather than `.stride(by: .day, count:)`, for two reasons. A stride steps from the
    /// domain's LOWER bound, so on a 30-day window it marks days 0/6/12/18/24 and leaves the newest day,
    /// the one a trend is usually read for, unlabelled. And `.stride` carries `roundLowerBound` /
    /// `roundUpperBound`, which can widen an inferred domain and put dead space at the chart edges. Naming
    /// the days outright settles both, and cannot alter the domain at all.
    ///
    /// Walks BACK from the newest day so that one is always present, then reverses into ascending order,
    /// which is what `AxisMarks(values:)` expects.
    public static func spanning(_ dates: [Date],
                                targetLabels: Int = 5,
                                calendar: Calendar = .current) -> [Date] {
        guard targetLabels > 0, let first = dates.min(), let last = dates.max() else { return [] }
        let lo = calendar.startOfDay(for: first)
        let hi = calendar.startOfDay(for: last)
        let span = calendar.dateComponents([.day], from: lo, to: hi).day ?? 0
        guard span > 0 else { return [hi] }
        // Days INCLUSIVE of both ends: a 4-day span carries 5 days, which is 5 labels a day apart.
        let stride = max(1, Int((Double(span + 1) / Double(targetLabels)).rounded(.up)))
        var days: [Date] = []
        var day = hi
        while day >= lo {
            days.append(day)
            guard let previous = calendar.date(byAdding: .day, value: -stride, to: day) else { break }
            // Re-anchored every step, because a day-add preserves the TIME of day and in a zone that
            // shifts its clocks at midnight the 00:00 it aims for does not exist on the transition date:
            // Foundation hands back 01:00 instead. Left alone, that one stepped mark is off the day
            // boundary and every mark after it inherits the 01:00, so the tail of the axis drifts. In
            // America/Santiago a sweep of two years' windows put 52 marks at 01:00 before this line.
            day = calendar.startOfDay(for: previous)
        }
        return days.reversed()
    }
    /// Whether the axis labels need a YEAR to stay distinct from one another.
    ///
    /// `spanning` returns distinct days; it never promised distinct LABELS, and the day-only format the
    /// date axes use drops the year. Two marks exactly a year apart are different days that render the
    /// same string, which is the duplication this whole arrangement exists to prevent, arriving by a
    /// different route. Sweeping spans from 1 to 3000 days at both label targets, 53 of them collide,
    /// the first at 1365 days: an ALL range on about four years of history prints, for example,
    /// "Jul 10, Jul 10, Jul 9, Jul 9".
    ///
    /// Asked of the MARKS rather than of the span, so the year appears only when it is actually needed
    /// and every shorter window keeps the shorter label.
    public static func needsYear(_ marks: [Date], calendar: Calendar = .current) -> Bool {
        let monthDays = marks.map { mark -> String in
            let parts = calendar.dateComponents([.month, .day], from: mark)
            return "\(parts.month ?? 0)-\(parts.day ?? 0)"
        }
        return Set(monthDays).count != monthDays.count
    }

    /// The label format the date axes use for a given set of marks: day-only, with the year added when
    /// [needsYear] says the marks would otherwise render the same string twice.
    ///
    /// Declared here rather than spelled at each axis so the three cannot drift into formatting the same
    /// marks differently. That is the whole reason: the ternary also type-checks inline, passed straight
    /// into the generic `AxisValueLabel(format:)`, so this is not working around an inference limit.
    public static func labelFormat(for marks: [Date], calendar: Calendar = .current) -> Date.FormatStyle {
        needsYear(marks, calendar: calendar)
            ? .dateTime.month(.abbreviated).day().year(.twoDigits)
            : .dateTime.month(.abbreviated).day()
    }

}
