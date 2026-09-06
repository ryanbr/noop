import Foundation

/// A local calendar date as a year/month/day triple, mirroring the components of the Kotlin twin's
/// `java.time.LocalDate`.
///
/// Swift has no calendar-date type that is free of a `Calendar`, and a `Calendar` is exactly what this
/// helper must not lean on: the day-window rules in this file are stated explicitly so that a future
/// change of library behaviour cannot move a day boundary silently. So the date is carried as its own
/// value type and converted to and from a day number with proleptic-Gregorian arithmetic.
public struct LocalCalendarDate: Hashable, Comparable, Sendable {

    /// The proleptic Gregorian year, negative before year 1.
    public let year: Int

    /// The month, 1...12.
    public let month: Int

    /// The day of the month, 1...31. No validation happens here: an out-of-range day is normalised by
    /// the day-number conversion, the same way `java.time` would reject it and callers here never
    /// construct one.
    public let day: Int

    /// Build a date from its components.
    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Build the date that lies `daysSinceEpoch` days after 1970-01-01.
    public init(daysSinceEpoch: Int) {
        // Howard Hinnant's civil_from_days, which is exact over the whole Int range and needs no
        // calendar object. Divisions truncate toward zero in Swift as they do in C, which is what the
        // era shifts below are written for.
        var z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        z -= era * 146_097
        let dayOfEra = z
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let d = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let m = monthPrime + (monthPrime < 10 ? 3 : -9)
        let y = yearOfEra + era * 400 + (m <= 2 ? 1 : 0)
        self.init(year: y, month: m, day: d)
    }

    /// The number of days from 1970-01-01 to this date, negative before it.
    public var daysSinceEpoch: Int {
        // Howard Hinnant's days_from_civil, the exact inverse of the initialiser above.
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The date rendered as `YYYY-MM-DD`, which is also the day key this helper hands out.
    public var key: String {
        let y = year < 0 ? "-" + Self.pad(-year, 4) : Self.pad(year, 4)
        return "\(y)-\(Self.pad(month, 2))-\(Self.pad(day, 2))"
    }

    /// The date `count` days after this one, negative counts moving backward.
    public func adding(days count: Int) -> LocalCalendarDate {
        LocalCalendarDate(daysSinceEpoch: daysSinceEpoch + count)
    }

    /// Order dates the way the calendar does.
    public static func < (lhs: LocalCalendarDate, rhs: LocalCalendarDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    /// Left-pad a non-negative number with zeroes, without a formatter — the twin does the same, and a
    /// locale-aware formatter is one more thing that could differ between the platforms.
    private static func pad(_ value: Int, _ width: Int) -> String {
        var s = String(value)
        while s.count < width { s = "0" + s }
        return s
    }
}

/// One local day as a half-open window, with the UTC offset that was in effect when it began.
public struct LocalDayWindow: Hashable, Sendable {

    /// The date this window belongs to.
    public let date: LocalCalendarDate

    /// The first instant of the date.
    public let start: Date

    /// The start of the next date that exists in the zone, which is where this window ends. It is not
    /// always `start` plus 24 hours, and where a calendar date is skipped entirely it is more than a
    /// day away.
    public let nextStart: Date

    /// The UTC offset in effect at `start`, in seconds east of UTC.
    ///
    /// It describes the window's start only. A time of day anywhere else inside the window is derived
    /// from the zone, never by adding this number, because a transition inside the window would make
    /// that wrong by an hour.
    public let utcOffsetSeconds: Int

    /// Build a window from its parts.
    public init(date: LocalCalendarDate, start: Date, nextStart: Date, utcOffsetSeconds: Int) {
        self.date = date
        self.start = start
        self.nextStart = nextStart
        self.utcOffsetSeconds = utcOffsetSeconds
    }

    /// How long the window lasts — 23, 24 or 25 hours in the fixture zones, and longer where the zone
    /// skips a calendar date.
    public var duration: TimeInterval {
        nextStart.timeIntervalSince(start)
    }
}

/// One entry of a backward run: a date that exists in the zone, with the start resolved for it.
public struct LocalDayStart: Hashable, Sendable {

    /// The date.
    public let date: LocalCalendarDate

    /// The first instant of that date in the zone.
    public let start: Date

    /// Build an entry from its parts.
    public init(date: LocalCalendarDate, start: Date) {
        self.date = date
        self.start = start
    }
}

/// When a local calendar date begins and ends in a time zone, taken from the zone's own rules.
///
/// The analysis core answers this question by adding fixed 86,400-second blocks to a midnight derived
/// from a single UTC offset. That is wrong by an hour on every day boundary beyond a transition,
/// because a day on which the clocks move is 23 or 25 hours long. This type is the shared primitive
/// that answers it correctly; it changes no caller on its own.
///
/// SO TWO ANSWERS COEXIST, and this one is not yet the shipped one. `AnalyticsEngine.dayStartUtcSeconds`
/// with `AnalyticsEngine.dayString` remains what every scored day actually uses; this file is called by
/// nothing but its own tests until a switch-over lands. They disagree by an hour on the far side of a
/// transition, which `LocalDayWindowsTests` pins deliberately by asserting BOTH answers for
/// America/New_York on 2025-10-19. Reach for the core unless you are writing that switch-over.
///
/// Kotlin twin: `LocalDayWindows`.
///
/// Nothing here is inherited from a calendar: the ambiguous, skipped and non-existent cases are
/// resolved by the rules stated on each operation, so that a future change in library behaviour is a
/// change to this file rather than a silent change of a day boundary. The only thing asked of the
/// platform is `TimeZone.secondsFromGMT(for:)`, the zone's raw rule lookup.
///
/// Both the zone and the reference instant are injectable and default to the named accessors
/// `defaultTimeZone` and `defaultReferenceInstant`, so every rule below is provable without a device.
public struct LocalDayWindows: Sendable {

    /// The zone used when none is given: the auto-updating current zone, which follows a change of
    /// device zone during the process's life. The Kotlin twin's default is the system default zone id,
    /// which means the same thing.
    ///
    /// The zone is bound when the helper is constructed; a caller that must follow a device-zone change
    /// during the process's life constructs a new helper.
    public static var defaultTimeZone: TimeZone { TimeZone.autoupdatingCurrent }

    /// The reference instant used when none is given: the current `Date`. The Kotlin twin's default is
    /// the current `Instant`.
    public static var defaultReferenceInstant: Date { Date() }

    /// The zone whose rules every operation reads.
    public let timeZone: TimeZone

    /// The instant that stands for "now" — it clamps the sleep read window and nothing else. No start,
    /// window, key or run depends on it.
    public let referenceInstant: Date

    /// Build a helper for a zone and a reference instant, both defaulting to the named accessors.
    public init(timeZone: TimeZone = LocalDayWindows.defaultTimeZone,
                referenceInstant: Date = LocalDayWindows.defaultReferenceInstant) {
        self.timeZone = timeZone
        self.referenceInstant = referenceInstant
    }

    /// The number of seconds either side of a local midnight that is probed for the offsets in effect
    /// around it. Two days is far more than any transition needs and still far less than the gap
    /// between two transitions anywhere in the database.
    private static let probeWindow: Int64 = 2 * 86_400

    /// The first instant that belongs to `date` in this zone, or `nil` when the zone has no instant on
    /// that date at all.
    ///
    /// The rule, stated rather than inherited: where local midnight exists once, that is the start;
    /// where it exists twice, the earlier of the two; where it does not exist, the first instant that
    /// does exist on the date, which is the instant the clocks jumped to. Where that jump lands on a
    /// later date the date itself never happened, and there is no start.
    ///
    /// The rule assumes at most one offset change within two days either side of the local midnight; no
    /// zone in the database violates that today.
    ///
    /// The result does not depend on `referenceInstant`.
    public func start(of date: LocalCalendarDate) -> Date? {
        let localMidnight = Int64(date.daysSinceEpoch) * 86_400
        let offsetBefore = offsetSeconds(atEpochSeconds: localMidnight - Self.probeWindow)
        let offsetAfter = offsetSeconds(atEpochSeconds: localMidnight + Self.probeWindow)

        var candidates = [localMidnight - Int64(offsetBefore), localMidnight - Int64(offsetAfter)].sorted()
        if candidates.count == 2 && candidates[0] == candidates[1] { candidates.removeLast() }
        // An instant maps to this local midnight exactly when reading it in the zone gives that wall
        // time back. Ascending order means an ambiguous midnight yields the earlier instant first.
        for candidate in candidates
        where candidate + Int64(offsetSeconds(atEpochSeconds: candidate)) == localMidnight {
            return Date(timeIntervalSince1970: TimeInterval(candidate))
        }

        // Local midnight fell in a gap. The first instant that exists on or after it is the instant the
        // clocks jumped at; it belongs to this date only if it still reads as this date.
        guard offsetBefore != offsetAfter else { return nil }
        let jump = transitionEpochSeconds(around: localMidnight, offsetBefore: offsetBefore)
        guard localDate(ofEpochSeconds: jump) == date else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(jump))
    }

    /// The half-open window `[start, nextStart)` of `date`, or `nil` when the date does not exist.
    ///
    /// `nextStart` is the start of the next date that *exists*, so a window that precedes a skipped
    /// calendar date spans more than a day rather than ending at an instant that never happened.
    public func window(of date: LocalCalendarDate) -> LocalDayWindow? {
        guard let dayStart = start(of: date) else { return nil }
        var next = date.adding(days: 1)
        var nextStart: Date?
        // A zone skipping more than a couple of consecutive dates has never happened; the bound keeps a
        // corrupt zone from turning this into an unbounded walk.
        for _ in 0..<8 {
            if let candidate = start(of: next) {
                nextStart = candidate
                break
            }
            next = next.adding(days: 1)
        }
        guard let end = nextStart else { return nil }
        return LocalDayWindow(date: date,
                              start: dayStart,
                              nextStart: end,
                              utcOffsetSeconds: offsetSeconds(at: dayStart))
    }

    /// The start of the local day that contains `instant`, as an instant and without formatting a date
    /// on the way.
    public func startOfDay(containing instant: Date) -> Date {
        let date = localDate(of: instant)
        // `instant` lies on `date` by construction, so the date exists and has a start. The fallback
        // is unreachable and exists only to keep the operation total.
        guard let start = start(of: date) else { return instant }
        return start
    }

    /// The `YYYY-MM-DD` key of the local day that contains `instant`.
    ///
    /// The key and the window agree by construction: the key names the date whose window contains the
    /// instant, because both are derived from the same zone lookup.
    public func dayKey(for instant: Date) -> String {
        localDate(of: instant).key
    }

    /// The local calendar date that contains `instant` in this zone.
    public func localDate(of instant: Date) -> LocalCalendarDate {
        localDate(ofEpochSeconds: Int64(instant.timeIntervalSince1970.rounded(.down)))
    }

    /// Up to `count` consecutive local calendar dates ending at `date`, oldest first, each with its own
    /// resolved start.
    ///
    /// A date the zone skipped is omitted rather than replaced, so the run can be shorter than
    /// requested; if `date` itself does not exist, the newest entry is the latest existing date before
    /// it.
    public func backwardRun(endingAt date: LocalCalendarDate, count: Int) -> [LocalDayStart] {
        guard count > 0 else { return [] }
        let endDay = date.daysSinceEpoch
        var run: [LocalDayStart] = []
        run.reserveCapacity(count)
        for back in stride(from: count - 1, through: 0, by: -1) {
            let day = LocalCalendarDate(daysSinceEpoch: endDay - back)
            if let start = start(of: day) {
                run.append(LocalDayStart(date: day, start: start))
            }
        }
        return run
    }

    /// The end of the sleep read window of `date`: the earlier of that date's next start and the
    /// reference instant, so the current day's window never reaches into the future. `nil` when the
    /// date does not exist.
    ///
    /// For a date that begins after the reference instant the end precedes the start — an empty,
    /// inverted window — by the D7 contract; a caller wanting a non-empty window must not ask for a
    /// future date.
    public func sleepReadWindowEnd(of date: LocalCalendarDate) -> Date? {
        guard let window = window(of: date) else { return nil }
        return min(window.nextStart, referenceInstant)
    }

    /// The UTC offset in effect at `instant`, in seconds east of UTC.
    public func offsetSeconds(at instant: Date) -> Int {
        timeZone.secondsFromGMT(for: instant)
    }

    /// The time-zone database version this platform can observe about itself, or `nil` where it cannot.
    ///
    /// Only Darwin exposes one; on Linux the Foundation port has no equivalent, and saying so is the
    /// point — a faked value would claim a fact nobody checked.
    public static var observedTimeZoneDataVersion: String? {
        #if canImport(Darwin)
        return NSTimeZone.timeZoneDataVersion
        #else
        return nil
        #endif
    }

    /// The note a platform attaches when a fixture value moves: it names the version recorded in the
    /// oracle and the version this platform observes at run time.
    ///
    /// A version difference is not itself a failure — the fixtures are past and stable, so a routine
    /// toolchain bump must not redden unrelated work. The note exists to make a *value* difference
    /// explicable. It is a pure function so that its content can be asserted; where a platform cannot
    /// observe its own version, the note says so in place of a version rather than omitting it.
    public static func timeZoneDataVersionNote(recorded: String, observed: String?) -> String {
        let observedText = observed.map { "observes \($0)" }
            ?? "cannot observe its own time-zone database version"
        return "time-zone database version: the oracle records \(recorded); this platform \(observedText)."
    }

    /// The UTC offset in effect at a whole-second instant.
    private func offsetSeconds(atEpochSeconds seconds: Int64) -> Int {
        timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// The local calendar date of a whole-second instant.
    private func localDate(ofEpochSeconds seconds: Int64) -> LocalCalendarDate {
        let localSeconds = seconds + Int64(offsetSeconds(atEpochSeconds: seconds))
        var days = localSeconds / 86_400
        if localSeconds < 0 && localSeconds % 86_400 != 0 { days -= 1 }
        return LocalCalendarDate(daysSinceEpoch: Int(days))
    }

    /// The instant at which the zone's offset changes near `localMidnight`, found by bisecting the
    /// probe window between the offset before and the offset after.
    private func transitionEpochSeconds(around localMidnight: Int64, offsetBefore: Int) -> Int64 {
        var low = localMidnight - Self.probeWindow
        var high = localMidnight + Self.probeWindow
        while high - low > 1 {
            let mid = low + (high - low) / 2
            if offsetSeconds(atEpochSeconds: mid) == offsetBefore {
                low = mid
            } else {
                high = mid
            }
        }
        return high
    }
}
