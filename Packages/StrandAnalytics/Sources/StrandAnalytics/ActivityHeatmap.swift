import Foundation

/// Build a GitHub-contribution-style heat grid from per-day values (e.g. daily active calories) — the
/// pure, cross-platform core of the Workouts "last 13 weeks" heatmap. Columns are calendar weeks
/// (Monday-first), rows are weekdays (0 = Mon … 6 = Sun); the LAST column is the current week and future
/// days in it are empty. Byte-for-byte twin of the Kotlin `ActivityHeatmap` — the calendar arithmetic is
/// pure integer `days_from_civil`/`civil_from_days` on the `"yyyy-MM-dd"` day keys the app stores, so the
/// two platforms bucket identically.
public enum ActivityHeatmap {

    public static let defaultWeeks = 13

    /// One grid cell. `day` = "yyyy-MM-dd" (nil for a future pad cell); `value` = the metric (nil = no
    /// data that day); `level` = 0 for no-data, 1...4 for intensity buckets.
    public struct Cell: Equatable, Sendable {
        public let day: String?
        public let value: Double?
        public let level: Int
        public init(day: String?, value: Double?, level: Int) {
            self.day = day
            self.value = value
            self.level = level
        }
    }

    /// `columns` is `weeks` arrays of 7 cells (row 0 = Monday). `maxValue` scales the intensity ramp.
    public struct Grid: Equatable, Sendable {
        public let weeks: Int
        public let columns: [[Cell]]
        public let maxValue: Double
        public init(weeks: Int, columns: [[Cell]], maxValue: Double) {
            self.weeks = weeks
            self.columns = columns
            self.maxValue = maxValue
        }
        public var isEmpty: Bool { columns.allSatisfy { col in col.allSatisfy { $0.value == nil } } }
    }

    /// - Parameters:
    ///   - values: day ("yyyy-MM-dd") → metric value. Missing days render as no-data cells.
    ///   - today: the "yyyy-MM-dd" anchoring the rightmost column.
    ///   - weeks: number of week columns (default 13).
    public static func build(values: [String: Double], today: String, weeks: Int = defaultWeeks) -> Grid {
        guard let e = epochDay(today) else { return Grid(weeks: weeks, columns: [], maxValue: 0) }
        let cols = max(weeks, 1)
        let todayWeekday = mondayFirstWeekday(e)
        let currentMonday = e - todayWeekday
        let firstMonday = currentMonday - (cols - 1) * 7

        var maxValue = 0.0
        var raw: [[Cell]] = []
        raw.reserveCapacity(cols)
        for c in 0..<cols {
            var col: [Cell] = []
            col.reserveCapacity(7)
            for r in 0..<7 {
                let d = firstMonday + c * 7 + r
                if d > e {
                    col.append(Cell(day: nil, value: nil, level: 0)) // future day in the current week
                } else {
                    let ds = civilDay(d)
                    let v = values[ds]
                    if let v, v > maxValue { maxValue = v }
                    col.append(Cell(day: ds, value: v, level: 0))
                }
            }
            raw.append(col)
        }
        let leveled = raw.map { col in
            col.map { Cell(day: $0.day, value: $0.value, level: levelFor($0.value, maxValue)) }
        }
        return Grid(weeks: cols, columns: leveled, maxValue: maxValue)
    }

    /// 0 = no data; otherwise 1...4 by fraction of `maxValue` (a present-but-zero day is still level 1).
    static func levelFor(_ value: Double?, _ maxValue: Double) -> Int {
        guard let value else { return 0 }
        if maxValue <= 0 { return 1 }
        return min(max(Int(ceil(value / maxValue * 4.0)), 1), 4)
    }

    /// Monday-first weekday (Mon = 0 … Sun = 6) of an epoch-day count. Epoch day 0 (1970-01-01) is a Thu.
    static func mondayFirstWeekday(_ epochDay: Int) -> Int { ((epochDay + 3) % 7 + 7) % 7 }

    /// Parse "yyyy-MM-dd" → days since 1970-01-01 (proleptic Gregorian), or nil if malformed.
    static func epochDay(_ ymd: String) -> Int? {
        let p = ymd.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        return daysFromCivil(y, m, d)
    }

    /// days since 1970-01-01 → "yyyy-MM-dd". Inverse of `epochDay` (Howard Hinnant's civil_from_days).
    static func civilDay(_ epochDay: Int) -> String {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y0 = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = m <= 2 ? y0 + 1 : y0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// "yyyy-MM-dd" fields → days since 1970-01-01 (Howard Hinnant's days_from_civil).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
