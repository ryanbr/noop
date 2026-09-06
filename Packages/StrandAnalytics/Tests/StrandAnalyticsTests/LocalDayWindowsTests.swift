import Foundation
import XCTest
@testable import StrandAnalytics

/// The day-window primitive, one test per scenario of the `daily-windows` specification, plus the
/// parity oracle that the Kotlin twin reads from the same committed file.
///
/// Every fixture passes an explicit zone and an explicit reference instant, so nothing here depends on
/// the machine's zone or on when the suite runs. The two exceptions are the default-accessor tests,
/// which are about the defaults themselves and deliberately do not go through the oracle.
final class LocalDayWindowsTests: XCTestCase {

    // MARK: - Fixture helpers

    /// A date written the way the specification writes it.
    private func date(_ text: String) -> LocalCalendarDate {
        let parts = text.split(separator: "-").map { Int($0)! }
        return LocalCalendarDate(year: parts[0], month: parts[1], day: parts[2])
    }

    /// An instant from whole seconds since the epoch.
    private func instant(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    /// A UTC instant written as `YYYY-MM-DDTHH:MM:SSZ`, parsed without a formatter so the test's own
    /// expectations do not depend on a locale or a calendar.
    private func utc(_ text: String) -> Date {
        let halves = text.dropLast().split(separator: "T")
        let day = halves[0].split(separator: "-").map { Int($0)! }
        let time = halves[1].split(separator: ":").map { Int($0)! }
        let days = LocalCalendarDate(year: day[0], month: day[1], day: day[2]).daysSinceEpoch
        return instant(days * 86_400 + time[0] * 3600 + time[1] * 60 + time[2])
    }

    /// The helper for a zone, with a reference instant that no scenario in this section depends on.
    private func windows(_ zoneName: String,
                         reference: Date = Date(timeIntervalSince1970: 0)) -> LocalDayWindows {
        LocalDayWindows(timeZone: TimeZone(identifier: zoneName)!, referenceInstant: reference)
    }

    // MARK: - A local date begins at its own local midnight

    /// The discriminating case: the helper and the analysis core's fixed-offset arithmetic disagree by
    /// an hour across a transition.
    ///
    /// The core's arithmetic is re-derived inline, verbatim per the scenario, because the incumbent
    /// lives in the app target and a package test cannot import it: floor to a local midnight using the
    /// zone's offset at the reference instant, then subtract whole 86,400-second days.
    func testResolvedStartDiffersFromFixedOffsetArithmeticAcrossATransition() {
        let zone = TimeZone(identifier: "America/New_York")!
        let reference = utc("2025-11-10T17:00:00Z")  // 12:00 local, inside standard time
        let helper = LocalDayWindows(timeZone: zone, referenceInstant: reference)

        let resolved = helper.start(of: date("2025-10-19"))

        let offset = TimeInterval(zone.secondsFromGMT(for: reference))
        let localSeconds = reference.timeIntervalSince1970 + offset
        let referenceMidnight = (localSeconds / 86_400).rounded(.down) * 86_400 - offset
        let fixedOffsetStart = Date(timeIntervalSince1970: referenceMidnight - 22 * 86_400)

        XCTAssertEqual(resolved, utc("2025-10-19T04:00:00Z"))
        XCTAssertEqual(fixedOffsetStart, utc("2025-10-19T05:00:00Z"))
        XCTAssertNotEqual(resolved, fixedOffsetStart)
    }

    /// Two reference instants on opposite sides of the zone's autumn transition give the same start.
    func testResultDoesNotDependOnTheReferenceInstant() {
        let before = windows("America/New_York", reference: utc("2025-10-15T12:00:00Z"))
        let after = windows("America/New_York", reference: utc("2025-12-15T12:00:00Z"))

        XCTAssertEqual(before.start(of: date("2025-10-19")), utc("2025-10-19T04:00:00Z"))
        XCTAssertEqual(after.start(of: date("2025-10-19")), utc("2025-10-19T04:00:00Z"))
    }

    /// A zone offset of 5 hours 45 minutes puts the start on its own local midnight, off the hour.
    func testDayWithFortyFiveMinuteOffsetStartsAtItsOwnLocalMidnight() {
        let helper = windows("Asia/Kathmandu")

        let start = helper.start(of: date("2025-06-15"))

        XCTAssertEqual(start, utc("2025-06-14T18:15:00Z"))
        XCTAssertEqual(helper.offsetSeconds(at: start!), 20_700)
        XCTAssertNotEqual(Int(start!.timeIntervalSince1970) % 3600, 0)
    }

    // MARK: - A day window lasts as long as the zone says and carries its own offset

    /// The spring-forward day is 23 hours long.
    func testSpringForwardDayIsTwentyThreeHours() {
        let window = windows("America/New_York").window(of: date("2025-03-09"))

        XCTAssertEqual(window?.duration, 23 * 3600)
    }

    /// The fall-back day is 25 hours long.
    func testFallBackDayIsTwentyFiveHours() {
        let window = windows("America/New_York").window(of: date("2025-11-02"))

        XCTAssertEqual(window?.duration, 25 * 3600)
    }

    /// A zone without daylight saving has 24-hour days.
    func testDayInZoneWithoutDaylightSavingIsTwentyFourHours() {
        let window = windows("Asia/Kolkata").window(of: date("2025-06-15"))

        XCTAssertEqual(window?.duration, 24 * 3600)
    }

    /// Consecutive windows meet exactly across a transition, leaving neither a gap nor an overlap.
    func testConsecutiveWindowsMeetExactly() throws {
        let helper = windows("America/New_York")

        let first = try XCTUnwrap(helper.window(of: date("2025-11-01")))
        let second = try XCTUnwrap(helper.window(of: date("2025-11-02")))
        let third = try XCTUnwrap(helper.window(of: date("2025-11-03")))

        XCTAssertEqual(first.nextStart, second.start)
        XCTAssertEqual(second.nextStart, third.start)
    }

    /// The window reports the offset in effect at its own start, not at some other moment of the day.
    func testWindowReportsOffsetInEffectAtItsStart() {
        let helper = windows("America/New_York")

        XCTAssertEqual(helper.window(of: date("2025-11-01"))?.utcOffsetSeconds, -14_400)
        XCTAssertEqual(helper.window(of: date("2025-11-03"))?.utcOffsetSeconds, -18_000)
    }

    // MARK: - The helper resolves the start of the local day containing an instant

    /// An instant inside the repeated local hour still resolves to that day's start.
    func testInstantInsideTwentyFiveHourDayResolvesToThatDaysStart() {
        let helper = windows("America/New_York")

        let start = helper.startOfDay(containing: utc("2025-11-02T05:30:00Z"))

        XCTAssertEqual(start, utc("2025-11-02T04:00:00Z"))
    }

    /// A start instant resolves to itself, for every fixture date that exists.
    func testContainingDayStartOfAStartInstantIsItself() {
        for (zone, day) in [("America/New_York", "2025-03-09"),
                            ("America/New_York", "2025-11-02"),
                            ("America/New_York", "2025-10-19"),
                            ("America/Santiago", "2025-09-07"),
                            ("America/Havana", "2025-11-02"),
                            ("Pacific/Apia", "2011-12-31"),
                            ("Asia/Kolkata", "2025-06-15"),
                            ("Asia/Kathmandu", "2025-06-15")] {
            let helper = windows(zone)
            let start = helper.start(of: date(day))
            XCTAssertNotNil(start, "\(zone) \(day) must have a start")
            if let start {
                XCTAssertEqual(helper.startOfDay(containing: start), start, "\(zone) \(day)")
            }
        }
    }

    // MARK: - An instant's day key names the window that contains it

    /// The key flips exactly at the window boundary and nowhere else.
    func testDayKeyChangesExactlyAtTheWindowBoundary() {
        let helper = windows("America/New_York")
        let start = helper.start(of: date("2025-11-02"))!

        XCTAssertEqual(helper.dayKey(for: start.addingTimeInterval(-1)), "2025-11-01")
        XCTAssertEqual(helper.dayKey(for: start.addingTimeInterval(1)), "2025-11-02")
    }

    /// The key holds for all 25 hours of the fall-back day, including the repeated local hour.
    func testDayKeyHoldsAcrossTheWholeOfATwentyFiveHourDay() {
        let helper = windows("America/New_York")
        let window = helper.window(of: date("2025-11-02"))!

        XCTAssertEqual(helper.dayKey(for: window.start), "2025-11-02")
        XCTAssertEqual(helper.dayKey(for: utc("2025-11-02T05:30:00Z")), "2025-11-02")
        XCTAssertEqual(helper.dayKey(for: window.nextStart.addingTimeInterval(-1)), "2025-11-02")
    }

    // MARK: - An ambiguous or missing local midnight resolves by a stated rule

    /// A date with no 00:00 starts at its first existing instant, its local 01:00.
    func testTransitionThatSkipsLocalMidnight() {
        let start = windows("America/Santiago").start(of: date("2025-09-07"))

        XCTAssertEqual(start, utc("2025-09-07T04:00:00Z"))
    }

    /// A date with two 00:00 starts at the earlier of them.
    func testTransitionThatRepeatsLocalMidnight() {
        let helper = windows("America/Havana")

        let start = helper.start(of: date("2025-11-02"))

        XCTAssertEqual(start, utc("2025-11-02T04:00:00Z"))
        XCTAssertEqual(helper.offsetSeconds(at: start!), -14_400)
        // The later of the two midnights, which the rule must not pick.
        XCTAssertEqual(helper.offsetSeconds(at: utc("2025-11-02T05:00:00Z")), -18_000)
    }

    // MARK: - A date that does not exist is skipped over

    /// A calendar date the zone skipped has no start at all.
    func testSkippedCalendarDateProducesNoStart() {
        XCTAssertNil(windows("Pacific/Apia").start(of: date("2011-12-30")))
    }

    /// The preceding date's window reaches over the skipped date to the next existing one.
    func testPrecedingDatesWindowReachesTheNextExistingDate() {
        let helper = windows("Pacific/Apia")

        let window = helper.window(of: date("2011-12-29"))

        XCTAssertEqual(window?.nextStart, helper.start(of: date("2011-12-31")))
        XCTAssertEqual(window?.duration, 24 * 3600)
    }

    // MARK: - A backward run yields consecutive existing dates with their own starts

    /// A run spanning the autumn transition is consecutive and each entry carries its own start.
    func testRunAcrossATransitionIsConsecutiveAndCorrectlyAnchored() {
        let helper = windows("America/New_York")

        let run = helper.backwardRun(endingAt: date("2025-11-10"), count: 21)

        XCTAssertEqual(run.count, 21)
        XCTAssertEqual(run.first?.date.key, "2025-10-21")
        XCTAssertEqual(run.last?.date.key, "2025-11-10")
        for (index, entry) in run.enumerated() {
            XCTAssertEqual(entry.date.daysSinceEpoch,
                           date("2025-10-21").daysSinceEpoch + index,
                           "run must be consecutive at \(entry.date.key)")
            XCTAssertEqual(entry.start, helper.start(of: entry.date), entry.date.key)
        }
    }

    /// A run containing a skipped date is shorter than requested and omits it.
    func testRunContainingASkippedDateIsShorterThanRequested() {
        let run = windows("Pacific/Apia").backwardRun(endingAt: date("2012-01-02"), count: 5)

        XCTAssertEqual(run.count, 4)
        XCTAssertEqual(run.first?.date.key, "2011-12-29")
        XCTAssertEqual(run.map(\.date.key), ["2011-12-29", "2011-12-31", "2012-01-01", "2012-01-02"])
    }

    /// A long run lands on the right calendar date, 3999 days before the anchor.
    func testLongRunReachesTheRightCalendarDate() {
        let run = windows("America/New_York").backwardRun(endingAt: date("2025-11-10"), count: 4000)

        XCTAssertEqual(run.count, 4000)
        XCTAssertEqual(run.first?.date.key, "2014-11-29")
        XCTAssertEqual(run.last?.date.key, "2025-11-10")
    }

    // MARK: - The sleep read window never extends into the future

    /// The current date's window stops at the reference instant instead of its next start.
    func testCurrentDatesWindowStopsAtTheReferenceInstant() {
        let helper = windows("America/New_York", reference: utc("2025-11-02T18:00:00Z"))

        let end = helper.sleepReadWindowEnd(of: date("2025-11-02"))

        XCTAssertEqual(end, utc("2025-11-02T18:00:00Z"))
        XCTAssertNotEqual(end, helper.window(of: date("2025-11-02"))?.nextStart)
    }

    /// A past 25-hour day reaches its own next start, 25 hours after it began.
    func testPastTwentyFiveHourDayReachesItsOwnNextStart() {
        let helper = windows("America/New_York", reference: utc("2025-12-15T12:00:00Z"))

        let end = helper.sleepReadWindowEnd(of: date("2025-11-02"))
        let window = helper.window(of: date("2025-11-02"))!

        XCTAssertEqual(end, window.nextStart)
        XCTAssertEqual(end?.timeIntervalSince(window.start), 25 * 3600)
    }

    // MARK: - The default zone and reference instant are named, not implied

    /// The default zone is the auto-updating current zone named in the design, not a snapshot of it.
    func testDefaultZoneIsThePlatformsTrackingDeviceZone() {
        XCTAssertEqual(LocalDayWindows.defaultTimeZone, TimeZone.autoupdatingCurrent)
        XCTAssertEqual(LocalDayWindows().timeZone, TimeZone.autoupdatingCurrent)
        XCTAssertEqual(LocalDayWindows(referenceInstant: Date()).timeZone, TimeZone.autoupdatingCurrent)
    }

    /// The default reference instant is the current `Date`, so it lies inside a bracket taken around
    /// the call.
    func testDefaultReferenceInstantIsThePlatformsCurrentInstant() {
        let before = Date()
        let accessor = LocalDayWindows.defaultReferenceInstant
        let helperDefault = LocalDayWindows().referenceInstant
        let after = Date()

        XCTAssertGreaterThanOrEqual(accessor, before)
        XCTAssertLessThanOrEqual(accessor, after)
        XCTAssertGreaterThanOrEqual(helperDefault, before)
        XCTAssertLessThanOrEqual(helperDefault, after)
    }

    // MARK: - Both platforms agree, proven by a committed oracle

    /// The committed oracle, loaded by a path derived from this file's own location.
    ///
    /// It fails rather than skips when the file is absent: an oracle nobody can find would otherwise
    /// let both platforms stay green while they disagree, which is the whole thing this file guards.
    private func loadOracle() throws -> [String: Any] {
        let relative = "android/app/src/test/resources/local_day_windows_oracle.json"
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                let parsed = try JSONSerialization.jsonObject(with: data)
                return try XCTUnwrap(parsed as? [String: Any], "the oracle must be a JSON object")
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("committed oracle \(relative) not found above \(#filePath) — this test must not pass by default")
        throw CocoaError(.fileNoSuchFile)
    }

    /// Every value in the committed oracle, re-derived by the helper and compared.
    ///
    /// The Kotlin twin asserts the same file, so a change on either side reddens one of the two suites.
    func testSwiftTestReadsTheSameCommittedFile() throws {
        let oracle = try loadOracle()

        let producedBy = try XCTUnwrap(oracle["producedBy"] as? [String: Any])
        XCTAssertFalse(try XCTUnwrap(producedBy["toolchain"] as? String).isEmpty)
        XCTAssertFalse(try XCTUnwrap(producedBy["timeZoneDataVersion"] as? String).isEmpty)

        let recorded = try XCTUnwrap(producedBy["timeZoneDataVersion"] as? String)
        let note = LocalDayWindows.timeZoneDataVersionNote(
            recorded: recorded, observed: LocalDayWindows.observedTimeZoneDataVersion)

        let starts = try XCTUnwrap(oracle["starts"] as? [[String: Any]])
        XCTAssertEqual(starts.count, 19, "oracle section starts")
        for record in starts {
            let helper = windows(try XCTUnwrap(record["zone"] as? String))
            let day = date(try XCTUnwrap(record["date"] as? String))
            let expected = record["start"] as? Int
            let context = "start \(helper.timeZone.identifier) \(day.key) — \(note)"
            XCTAssertEqual(helper.start(of: day).map { Int($0.timeIntervalSince1970) }, expected, context)
        }

        let windowRecords = try XCTUnwrap(oracle["windows"] as? [[String: Any]])
        XCTAssertEqual(windowRecords.count, 18, "oracle section windows")
        for record in windowRecords {
            let helper = windows(try XCTUnwrap(record["zone"] as? String))
            let day = date(try XCTUnwrap(record["date"] as? String))
            let window = try XCTUnwrap(helper.window(of: day))
            let context = "window \(helper.timeZone.identifier) \(day.key) — \(note)"
            XCTAssertEqual(Int(window.start.timeIntervalSince1970), record["start"] as? Int, context)
            XCTAssertEqual(Int(window.nextStart.timeIntervalSince1970), record["nextStart"] as? Int, context)
            XCTAssertEqual(window.utcOffsetSeconds, record["utcOffsetSeconds"] as? Int, context)
        }

        let containing = try XCTUnwrap(oracle["containingDayStarts"] as? [[String: Any]])
        XCTAssertEqual(containing.count, 8, "oracle section containingDayStarts")
        for record in containing {
            let helper = windows(try XCTUnwrap(record["zone"] as? String))
            let at = instant(try XCTUnwrap(record["instant"] as? Int))
            let context = "containing \(helper.timeZone.identifier) \(record["instant"] ?? "?") — \(note)"
            XCTAssertEqual(Int(helper.startOfDay(containing: at).timeIntervalSince1970),
                           record["start"] as? Int, context)
        }

        let keys = try XCTUnwrap(oracle["dayKeys"] as? [[String: Any]])
        XCTAssertEqual(keys.count, 11, "oracle section dayKeys")
        for record in keys {
            let helper = windows(try XCTUnwrap(record["zone"] as? String))
            let at = instant(try XCTUnwrap(record["instant"] as? Int))
            let context = "key \(helper.timeZone.identifier) \(record["instant"] ?? "?") — \(note)"
            XCTAssertEqual(helper.dayKey(for: at), record["key"] as? String, context)
        }

        let runs = try XCTUnwrap(oracle["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 4, "oracle section runs")
        for record in runs {
            let helper = windows(try XCTUnwrap(record["zone"] as? String))
            let anchor = date(try XCTUnwrap(record["endingAt"] as? String))
            let requested = try XCTUnwrap(record["requested"] as? Int)
            let run = helper.backwardRun(endingAt: anchor, count: requested)
            let context = "run \(helper.timeZone.identifier) \(anchor.key)/\(requested) — \(note)"
            XCTAssertEqual(run.count, record["size"] as? Int, context)
            for (edge, entry) in [("oldest", run.first), ("newest", run.last)] {
                let expected = try XCTUnwrap(record[edge] as? [String: Any], context)
                XCTAssertEqual(entry?.date.key, expected["date"] as? String, "\(edge) \(context)")
                XCTAssertEqual(entry.map { Int($0.start.timeIntervalSince1970) },
                               expected["start"] as? Int, "\(edge) \(context)")
            }
            // Short runs carry every entry; the 4000-day run carries its edges and its size only, so
            // that the committed file stays reviewable, and says so in `daysTruncated`.
            let days = try XCTUnwrap(record["days"] as? [[String: Any]], context)
            if try XCTUnwrap(record["daysTruncated"] as? Bool, context) {
                XCTAssertTrue(days.isEmpty, context)
            } else {
                XCTAssertEqual(days.count, run.count, context)
                for (entry, expected) in zip(run, days) {
                    XCTAssertEqual(entry.date.key, expected["date"] as? String, context)
                    XCTAssertEqual(Int(entry.start.timeIntervalSince1970), expected["start"] as? Int, context)
                }
            }
        }

        let sleepEnds = try XCTUnwrap(oracle["sleepWindowEnds"] as? [[String: Any]])
        XCTAssertEqual(sleepEnds.count, 5, "oracle section sleepWindowEnds")
        for record in sleepEnds {
            let reference = instant(try XCTUnwrap(record["referenceInstant"] as? Int))
            let helper = windows(try XCTUnwrap(record["zone"] as? String), reference: reference)
            let day = date(try XCTUnwrap(record["date"] as? String))
            let context = "sleep end \(helper.timeZone.identifier) \(day.key) — \(note)"
            XCTAssertEqual(helper.sleepReadWindowEnd(of: day).map { Int($0.timeIntervalSince1970) },
                           record["end"] as? Int, context)
        }
    }

    /// The mismatch note names the recorded version and the observed one, and says so plainly where the
    /// platform has no version of its own to report.
    func testMismatchNoteNamesBothDatabaseVersions() {
        let observed = LocalDayWindows.timeZoneDataVersionNote(recorded: "2025b", observed: "2025a")
        XCTAssertEqual(observed,
                       "time-zone database version: the oracle records 2025b; this platform observes 2025a.")

        let blind = LocalDayWindows.timeZoneDataVersionNote(recorded: "unavailable", observed: nil)
        XCTAssertEqual(blind,
                       "time-zone database version: the oracle records unavailable; "
                       + "this platform cannot observe its own time-zone database version.")
        XCTAssertTrue(blind.contains("cannot observe"))
        XCTAssertTrue(blind.contains("unavailable"))
    }
}
