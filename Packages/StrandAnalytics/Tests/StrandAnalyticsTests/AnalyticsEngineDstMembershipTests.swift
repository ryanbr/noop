import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// #2694, the evidence #2517 asked for before any day-model decision: WHICH samples land in which day
/// when a flat 86,400-second window scores a 23- or 25-hour local day.
///
/// This characterises the CURRENT answer and is expected to change when the day policy does. Every
/// expectation is the shipped engine's own output, captured from the compiled Swift and pinned verbatim
/// on both platforms. Kotlin twin: `AnalyticsEngineDstMembershipTest`.
///
/// Distinct from its two neighbours, which is why it is its own file. `AnalyticsEngineDayBoundsTests`
/// pins the #996 integer-bounds equivalence, that the fast membership check matches the formatter it
/// replaced, and says nothing about transitions. `AnalyticsEngineDayWindowSkewTests` pins the day's
/// LENGTH on a transition. Neither says how many samples move, which is the question a policy decision
/// needs answered.
final class AnalyticsEngineDstMembershipTests: XCTestCase {

    /// One transition day, scored at one of the two offsets in effect around it.
    private struct Vector {
        let zone: String
        let day: String
        /// `.before` threads the offset in effect at the day's first instant, `.after` the one after the
        /// transition. A real pass captures ONE offset for the whole pass, so both are reachable
        /// depending on when the pass runs.
        let whichOffset: String
    }

    private let vectors: [Vector] = [
        Vector(zone: "America/New_York", day: "2025-03-09", whichOffset: "before"),
        Vector(zone: "America/New_York", day: "2025-03-09", whichOffset: "after"),
        Vector(zone: "America/New_York", day: "2025-11-02", whichOffset: "before"),
        Vector(zone: "America/New_York", day: "2025-11-02", whichOffset: "after"),
        Vector(zone: "Pacific/Auckland", day: "2026-09-27", whichOffset: "before"),
        Vector(zone: "Pacific/Auckland", day: "2026-09-27", whichOffset: "after"),
        Vector(zone: "Pacific/Auckland", day: "2027-04-04", whichOffset: "before"),
        Vector(zone: "Pacific/Auckland", day: "2027-04-04", whichOffset: "after"),
    ]

    /// What one vector measures. Integers only, so the two platforms can be held to the same line.
    private struct Measured {
        let offsetSec: Int
        /// Seconds in the real local day, from the zone rules.
        let realSeconds: Int
        /// Minute-spaced samples that fall inside the real local day.
        let realMinutes: Int
        /// Minute-spaced samples the SHIPPED membership rule attributes to this day key.
        let scoredMinutes: Int
        /// Real-day minutes the flat window leaves out, at the start and at the end.
        let missedAtStart: Int
        let missedAtEnd: Int
        /// Minutes from the neighbouring days the flat window pulls in, before and after.
        let pulledFromPrevious: Int
        let pulledFromNext: Int
        /// The step total `analyzeDay` actually returns for the day, which is the membership rule's
        /// effect on a real additive metric rather than a restatement of it.
        let scoredSteps: Int
        /// The total the REAL local day would have produced, over exactly the samples inside it.
        ///
        /// This comparison is the one the first version of this file did not make, and #2694 is what
        /// supplied it. Without it the scored total looks invariant, because it IS invariant across the
        /// two offsets; what it is not is correct.
        let realDaySteps: Int
    }

    private func measure(_ vector: Vector) throws -> Measured {
        let zone = try XCTUnwrap(TimeZone(identifier: vector.zone), vector.zone)
        let helper = LocalDayWindows(timeZone: zone,
                                     referenceInstant: Date(timeIntervalSince1970: 3_000_000_000))
        let parts = vector.day.split(separator: "-").map { Int($0)! }
        let date = LocalCalendarDate(year: parts[0], month: parts[1], day: parts[2])
        let window = try XCTUnwrap(helper.window(of: date), "\(vector.zone) \(vector.day)")
        let realStart = Int(window.start.timeIntervalSince1970)
        let realEnd = Int(window.nextStart.timeIntervalSince1970)
        let offsetSec = vector.whichOffset == "before"
            ? zone.secondsFromGMT(for: window.start)
            : zone.secondsFromGMT(for: window.nextStart)

        // Minute-spaced samples across the real local day with two hours of spill either side, so a
        // window that reaches past a boundary has something to find there.
        let planted = Array(stride(from: realStart - 7_200, to: realEnd + 7_200, by: 60))
        let inRealDay = planted.filter { $0 >= realStart && $0 < realEnd }
        // The SHIPPED rule, exactly as the engine applies it.
        let scored = planted.filter { AnalyticsEngine.dayString($0, offsetSec: offsetSec) == vector.day }

        var counter = 1_000
        let daySteps: [StepSample] = planted.map { ts in
            counter += 7
            return StepSample(ts: ts, counter: counter & 0xFFFF)
        }
        let dayHr = planted.map { HRSample(ts: $0, bpm: 60) }
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
        let result = AnalyticsEngine.analyzeDay(day: vector.day, dayHr: dayHr, daySteps: daySteps,
                                                profile: profile, tzOffsetSeconds: offsetSec)

        let scoredSet = Set(scored)
        let realSet = Set(inRealDay)
        return Measured(
            offsetSec: offsetSec,
            realSeconds: realEnd - realStart,
            realMinutes: inRealDay.count,
            scoredMinutes: scored.count,
            missedAtStart: realSet.subtracting(scoredSet).filter { $0 < (scored.min() ?? realStart) }.count,
            missedAtEnd: realSet.subtracting(scoredSet).filter { $0 > (scored.max() ?? realEnd) }.count,
            pulledFromPrevious: scoredSet.subtracting(realSet).filter { $0 < realStart }.count,
            pulledFromNext: scoredSet.subtracting(realSet).filter { $0 >= realEnd }.count,
            scoredSteps: result.daily.steps ?? -1,
            realDaySteps: StepsCounter.stepsInWindow(daySteps.filter { realSet.contains($0.ts) }) ?? -1)
    }

    /// One line per vector, in the order above, captured from this compiled engine and pinned verbatim
    /// in the Kotlin twin too.
    ///
    /// THE SHAPE IS THE FINDING. A flat window always scores 1,440 minutes, so:
    ///   * a 23-hour day (1,380 real minutes) PULLS IN 60 minutes from a neighbour, the next day when
    ///     the pre-transition offset is threaded and the previous one when the post-transition offset is;
    ///   * a 25-hour day (1,500 real minutes) MISSES 60 minutes of its own, at the end or at the start
    ///     by the same rule.
    /// Which side the hour comes from or goes to depends only on which offset the pass captured, and a
    /// pass captures one offset for its whole run.
    ///
    /// Regenerate with `swift test --filter AnalyticsEngineDstMembershipTests` after setting
    /// `emitOracle` to true, and paste the ORACLE lines here and into the Kotlin twin. These
    /// expectations characterise TODAY's behaviour and must be replaced, not defended, when the day
    /// policy changes.
    private let expected: [String] = [
        "America/New_York 2025-03-09 offset=before(-18000) realS=82800 realMin=1380 scoredMin=1440 "
            + "missedStart=0 missedEnd=0 pulledPrev=0 pulledNext=60 steps=10073",
        "America/New_York 2025-03-09 offset=after(-14400) realS=82800 realMin=1380 scoredMin=1440 "
            + "missedStart=0 missedEnd=0 pulledPrev=60 pulledNext=0 steps=10073",
        "America/New_York 2025-11-02 offset=before(-14400) realS=90000 realMin=1500 scoredMin=1440 "
            + "missedStart=0 missedEnd=60 pulledPrev=0 pulledNext=0 steps=10073",
        "America/New_York 2025-11-02 offset=after(-18000) realS=90000 realMin=1500 scoredMin=1440 "
            + "missedStart=60 missedEnd=0 pulledPrev=0 pulledNext=0 steps=10073",
        "Pacific/Auckland 2026-09-27 offset=before(43200) realS=82800 realMin=1380 scoredMin=1440 "
            + "missedStart=0 missedEnd=0 pulledPrev=0 pulledNext=60 steps=10073",
        "Pacific/Auckland 2026-09-27 offset=after(46800) realS=82800 realMin=1380 scoredMin=1440 "
            + "missedStart=0 missedEnd=0 pulledPrev=60 pulledNext=0 steps=10073",
        "Pacific/Auckland 2027-04-04 offset=before(46800) realS=90000 realMin=1500 scoredMin=1440 "
            + "missedStart=0 missedEnd=60 pulledPrev=0 pulledNext=0 steps=10073",
        "Pacific/Auckland 2027-04-04 offset=after(43200) realS=90000 realMin=1500 scoredMin=1440 "
            + "missedStart=60 missedEnd=0 pulledPrev=0 pulledNext=0 steps=10073",
    ]

    /// Set true, run, paste the printed ORACLE lines into `expected` and the Kotlin twin, set back.
    private let emitOracle = false

    private func line(_ v: Vector, _ m: Measured) -> String {
        "\(v.zone) \(v.day) offset=\(v.whichOffset)(\(m.offsetSec)) "
            + "realS=\(m.realSeconds) realMin=\(m.realMinutes) scoredMin=\(m.scoredMinutes) "
            + "missedStart=\(m.missedAtStart) missedEnd=\(m.missedAtEnd) "
            + "pulledPrev=\(m.pulledFromPrevious) pulledNext=\(m.pulledFromNext) "
            + "steps=\(m.scoredSteps)"
    }

    func testTheFlatWindowsMembershipErrorIsPinnedAtEveryEdge() throws {
        var produced: [String] = []
        for v in vectors { produced.append(line(v, try measure(v))) }
        if emitOracle {
            print("ORACLE_BEGIN")
            for l in produced { print("ORACLE \(l)") }
            print("ORACLE_END")
        }
        XCTAssertEqual(produced, expected,
                       "the day model's membership moved; replace these expectations deliberately")
    }

    /// The scored total is INDEPENDENT of which offset the pass captured, and WRONG against the day it
    /// names. Both halves matter, and the first version of this test asserted only the first.
    ///
    /// CORRECTING WHAT THIS FILE ORIGINALLY CLAIMED. It asserted that the total is identical across all
    /// eight vectors, which is true, and concluded from that "the error is invisible in the size of what
    /// a day reports" and that nobody could have found it by reading step or calorie numbers. That
    /// conclusion was false and the omission that produced it was never comparing against the real local
    /// day at all. A flat window scores 1,440 minutes at either offset, so of course the two offsets
    /// agree; the true 23-hour day holds 1,380 of those minutes and the true 25-hour day 1,500, and the
    /// totals differ accordingly. @kavemang made exactly that comparison in #2694 and it is what
    /// disproved the claim.
    ///
    /// So the real shape is a SIGNED error with a direction: a short day over-reports, because the window
    /// reaches into a neighbour, and a long day under-reports, because the window stops short of its own
    /// end. That is visible in a day's numbers, and it is why #2694's vectors assert
    /// `scoredTicks != calendarTicks` rather than treating the totals as untouched.
    ///
    /// The recorded line in #2855 is still a log line rather than a field on the day, but for a narrower
    /// reason than originally given: the hour is misplaced rather than lost, so there is no single day
    /// whose number can be marked wrong without deciding where the hour belongs, which is the policy
    /// question #2517 settled by leaving it where it is.
    func testTheScoredTotalIsOffsetIndependentAndWrongAgainstTheRealDay() throws {
        var totals = Set<Int>()
        var scoredMinutes = Set<Int>()
        var realMinutes = Set<Int>()
        for v in vectors {
            let m = try measure(v)
            totals.insert(m.scoredSteps)
            scoredMinutes.insert(m.scoredMinutes)
            realMinutes.insert(m.realMinutes)

            // The half that was missing: the scored total against the day it claims to describe.
            XCTAssertNotEqual(m.scoredSteps, m.realDaySteps,
                              "\(v.zone) \(v.day) \(v.whichOffset): the fixture must expose the "
                                  + "discrepancy, or this vector proves nothing")
            if m.realMinutes < 1_440 {
                XCTAssertGreaterThan(m.scoredSteps, m.realDaySteps,
                                     "\(v.day): a 23-hour day OVER-reports, the window reaching into a "
                                         + "neighbour")
            } else {
                XCTAssertLessThan(m.scoredSteps, m.realDaySteps,
                                  "\(v.day): a 25-hour day UNDER-reports, the window stopping short of "
                                      + "its own end")
            }
        }
        XCTAssertEqual(scoredMinutes, [1_440], "a flat window always scores a flat 1,440 minutes")
        XCTAssertEqual(realMinutes, [1_380, 1_500], "the fixtures must cover both a short and a long day")
        XCTAssertEqual(totals.count, 1,
                       "the scored total is the same at either offset, because both score 1,440 minutes. "
                           + "That is offset-independence and NOT correctness: see the per-vector "
                           + "comparisons above.")
    }
}
