import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Locks the analyzeDay hot-path optimization (#996): the integer UTC-bounds membership check that replaced
/// the per-sample `dayString(ts, offsetSec:) == day` DateFormatter must be BYTE-IDENTICAL to it. If the two
/// ever diverge, samples get attributed to the wrong calendar day (wrong step / calorie / Effort totals), so
/// this sweeps timestamps densely across BOTH midnight edges at a range of fixed offsets — including the
/// FRACTIONAL ones (+5:30 Kolkata, +5:45 Kathmandu, −9:30 Marquesas, −3:30 Newfoundland) the whole-hour
/// Kotlin sweep leaves uncovered — and asserts the two agree at every point. Mirrors the Android
/// `AnalyticsEngineDayBoundsTest` (same anchor, same prime step, superset of its offsets) so the
/// cross-platform golden vectors stay in lockstep.
final class AnalyticsEngineDayBoundsTests: XCTestCase {

    // MARK: - Membership equivalence sweep

    func testIntegerBoundsMatchDayStringAcrossMidnightAndOffsets() {
        let anchor = 1_700_000_000  // 2023-11-14T22:13:20Z
        // UTC, the whole-hour extremes NOOP actually threads (±12/13/14 h are the real-world edges),
        // AND the fractional offsets the lane's timezone table carries (#996 review swept these too).
        let offsets = [0,
                       -4 * 3600, 5 * 3600, 13 * 3600, -12 * 3600, 14 * 3600,
                       5 * 3600 + 1800,   // +5:30 Kolkata
                       5 * 3600 + 2700,   // +5:45 Kathmandu
                       -(9 * 3600 + 1800), // −9:30 Marquesas
                       -(3 * 3600 + 1800)] // −3:30 Newfoundland
        for off in offsets {
            let day = AnalyticsEngine.dayString(anchor, offsetSec: off)
            let start = AnalyticsEngine.dayStartUtcSeconds(day)
            // ±28 h around the anchor at a prime step, so both midnight edges of `day` are crossed densely
            // and never in phase with the day grid.
            var ts = anchor - 100_800
            while ts < anchor + 100_800 {
                let viaFormatter = AnalyticsEngine.dayString(ts, offsetSec: off) == day
                let viaBounds = (ts + off) >= start && (ts + off) < start + 86_400
                XCTAssertEqual(viaFormatter, viaBounds, "ts=\(ts) off=\(off)")
                ts += 97
            }
        }
    }

    func testExactMidnightEdgesAtFractionalOffset() {
        // The two boundary seconds are where an off-by-one would hide: the local-midnight second is IN
        // the day, the next local-midnight second is OUT. +5:30 so a whole-hour bug can't pass by luck.
        let off = 5 * 3600 + 1800
        let day = "2021-06-15"
        let start = AnalyticsEngine.dayStartUtcSeconds(day)   // 2021-06-15T00:00:00Z = 1623715200
        XCTAssertEqual(start, 1_623_715_200)
        let localMidnightUtcTs = start - off                  // wall-clock 00:00 +05:30 as a UTC instant
        for (probe, expected) in [(localMidnightUtcTs, true),          // first second of the local day
                                  (localMidnightUtcTs - 1, false),     // last second of the day before
                                  (localMidnightUtcTs + 86_399, true), // last second of the local day
                                  (localMidnightUtcTs + 86_400, false)] {  // first second of the next
            XCTAssertEqual(AnalyticsEngine.dayString(probe, offsetSec: off) == day, expected, "probe=\(probe)")
            XCTAssertEqual((probe + off) >= start && (probe + off) < start + 86_400, expected, "probe=\(probe)")
        }
    }

    // MARK: - dayStartUtcSeconds

    func testDayStartUtcSecondsIsUtcMidnight() {
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("1970-01-01"), 0)
        // 1_700_000_000 is 2023-11-14T22:13:20Z, so that day's UTC midnight is 80_000 s earlier.
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("2023-11-14"), 1_699_920_000)
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("2021-06-15"), 1_623_715_200)
    }

    func testDayStartUtcSecondsRoundTripsThroughDayString() {
        // dayString(dayStartUtcSeconds(day)) == day for a spread of days (incl. a leap-year Feb 29).
        for day in ["1970-01-01", "2021-06-15", "2023-11-14", "2024-02-29", "2026-12-31"] {
            XCTAssertEqual(AnalyticsEngine.dayString(AnalyticsEngine.dayStartUtcSeconds(day)), day)
        }
    }

    func testMalformedDayFallsBackToEmptyEpochWindowNotATrap() {
        // Nil-tolerant failure mode (#996 review): a malformed `day` degrades to 0 — an empty 1970 window
        // no real sample matches — on BOTH platforms (Kotlin runCatching → 0), never a crash. Unreachable
        // in practice (`day` always comes from dayString), locked so the parity can't silently drift.
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("not-a-day"), 0)
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds(""), 0)
    }

    // MARK: - Byte-identity pin: same inputs → same DailyMetric numbers

    /// The optimization's whole contract: analyzeDay over FULL streams (which the tsInDay bounds check must
    /// trim to the day) produces the IDENTICAL DailyMetric as analyzeDay over streams PRE-trimmed with the
    /// old formatter compare. Runs at a fractional offset with spill samples planted on both sides of the
    /// local day, so any membership divergence changes the step/kcal/Effort numbers and fails Equatable.
    func testAnalyzeDayByteIdenticalToFormatterPrefilteredStreams() {
        for off in [5 * 3600 + 1800, -(9 * 3600 + 1800)] {   // +5:30 and −9:30
            let day = "2021-06-15"
            let localMid = AnalyticsEngine.dayStartUtcSeconds(day) - off
            // Full calendar-day HR every 10 s with ±2 h spill into the neighbour days; varying bpm so a
            // wrongly-included/excluded sample shifts the calorie/Effort sums, not just the count.
            let dayHr = stride(from: localMid - 7_200, to: localMid + 86_400 + 7_200, by: 10)
                .map { HRSample(ts: $0, bpm: 60 + ($0 / 10) % 40) }
            // Cumulative @57 counter every minute (+7/min) with the same spill; the spill deltas must be
            // excluded from the day total by BOTH filters identically.
            var counter = 100
            let daySteps: [StepSample] = stride(from: localMid - 7_200,
                                                to: localMid + 86_400 + 7_200, by: 60).map { ts in
                counter += 7
                return StepSample(ts: ts, counter: counter & 0xFFFF)
            }
            let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

            let full = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr, daySteps: daySteps,
                                                  profile: profile, tzOffsetSeconds: off)
            // The OLD path, byte for byte: pre-trim each stream with the formatter compare.
            let preHr = dayHr.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            let preSteps = daySteps.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            XCTAssertLessThan(preHr.count, dayHr.count, "fixture must actually spill outside the day")
            let pre = AnalyticsEngine.analyzeDay(day: day, dayHr: preHr, daySteps: preSteps,
                                                 profile: profile, tzOffsetSeconds: off)

            XCTAssertEqual(full.daily, pre.daily, "off=\(off)")
            XCTAssertNotNil(full.daily.steps)          // the pin is vacuous if the day computed nothing
            XCTAssertNotNil(full.daily.activeKcalEst)
        }
    }

    // #2517 asks for evidence before choosing a zone-aware scoring/history policy. These vectors
    // deliberately characterize the current BUG, not the desired calendar-day behavior. Replace
    // the expected output when that policy changes; do not treat fixed 24-hour scoring as a promise.
    func testTransitionDayScoringCharacterization() throws {
        let cases = [("Pacific/Auckland", "2026-09-27", 23),
                     ("Pacific/Auckland", "2026-04-05", 25),
                     ("America/New_York", "2026-03-08", 23),
                     ("America/New_York", "2026-11-01", 25)]
        var lines: [String] = []
        for (zone, day, hours) in cases {
            let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = day.split(separator: "-").compactMap { Int($0) }
            let startDate = try XCTUnwrap(calendar.date(from: DateComponents(
                year: parts[0], month: parts[1], day: parts[2])))
            let endDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: startDate))
            let start = Int(startDate.timeIntervalSince1970)
            let end = Int(endDate.timeIntervalSince1970)
            XCTAssertEqual(end - start, hours * 3600)
            // Ten counter ticks per minute, with two hours of spill at BOTH calendar edges.
            // The counter never wraps and every delta is plausible, isolating membership from math.
            let samples = stride(from: start - 7200, to: end + 7200, by: 60).enumerated()
                .map { StepSample(ts: $0.element, counter: 100 + $0.offset * 10) }
            let calendarSamples = samples.filter { $0.ts >= start && $0.ts < end }
            let calendarTicks = try XCTUnwrap(StepsCounter.stepsInWindow(calendarSamples))
            XCTAssertEqual(calendarTicks, (hours * 60 - 1) * 10)
            for (name, date) in [("before", startDate), ("after", endDate)] {
                let offset = timeZone.secondsFromGMT(for: date)
                let members = samples.filter { AnalyticsEngine.dayString($0.ts, offsetSec: offset) == day }
                let first = try XCTUnwrap(members.first).ts
                let last = try XCTUnwrap(members.last).ts
                let scored = AnalyticsEngine.analyzeDay(day: day, daySteps: samples,
                    profile: UserProfile(), tzOffsetSeconds: offset)
                let scoredTicks = try XCTUnwrap(scored.daily.steps)
                XCTAssertEqual(scoredTicks, StepsCounter.stepsInWindow(members))
                XCTAssertNotEqual(scoredTicks, calendarTicks, "fixture must expose the DST discrepancy")
                lines.append("\(zone) \(day) \(name) offset=\(offset) hours=\(hours) " +
                    "firstDelta=\(first - start) endDelta=\(last + 60 - end) " +
                    "calendarTicks=\(calendarTicks) scoredTicks=\(scoredTicks)")
            }
        }
        // Verbatim output from the production Swift analyzeDay run; Kotlin pins the same block.
        XCTAssertEqual(lines.joined(separator: "\n"), """
        Pacific/Auckland 2026-09-27 before offset=43200 hours=23 firstDelta=0 endDelta=3600 calendarTicks=13790 scoredTicks=14390
        Pacific/Auckland 2026-09-27 after offset=46800 hours=23 firstDelta=-3600 endDelta=0 calendarTicks=13790 scoredTicks=14390
        Pacific/Auckland 2026-04-05 before offset=46800 hours=25 firstDelta=0 endDelta=-3600 calendarTicks=14990 scoredTicks=14390
        Pacific/Auckland 2026-04-05 after offset=43200 hours=25 firstDelta=3600 endDelta=0 calendarTicks=14990 scoredTicks=14390
        America/New_York 2026-03-08 before offset=-18000 hours=23 firstDelta=0 endDelta=3600 calendarTicks=13790 scoredTicks=14390
        America/New_York 2026-03-08 after offset=-14400 hours=23 firstDelta=-3600 endDelta=0 calendarTicks=13790 scoredTicks=14390
        America/New_York 2026-11-01 before offset=-14400 hours=25 firstDelta=0 endDelta=-3600 calendarTicks=14990 scoredTicks=14390
        America/New_York 2026-11-01 after offset=-18000 hours=25 firstDelta=3600 endDelta=0 calendarTicks=14990 scoredTicks=14390
        """)
    }

}
