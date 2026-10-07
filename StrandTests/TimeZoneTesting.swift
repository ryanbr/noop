import Foundation

/// The zones the day-shift tests run in: both sides of UTC out to the date-line extremes, since a day key
/// parsed at UTC midnight is the evening before to the west and the same day to the east.
let dayShiftZones = ["Pacific/Honolulu", "America/New_York", "UTC", "Asia/Tokyo", "Pacific/Kiritimati"]

/// Runs `body` once per zone with the process default zone pinned to it, then restores the default.
///
/// Pinned in-process because a test that only fails west of UTC passes on a UTC runner. A DateFormatter
/// with no zone of its own follows `NSTimeZone.default`, so pinning it exposes the bug on any runner; a
/// `Date.FormatStyle` does not follow it, so assert such a style's `timeZone` directly instead.
func inEachTimeZone(_ zones: [String] = dayShiftZones, _ body: (String) throws -> Void) rethrows {
    let saved = NSTimeZone.default
    defer { NSTimeZone.default = saved }
    for zone in zones {
        NSTimeZone.default = TimeZone(identifier: zone)!
        try body(zone)
    }
}
