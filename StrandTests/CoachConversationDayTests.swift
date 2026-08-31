import XCTest
@testable import Strand

/// #1542 twin of `CoachConversationDayTest`. The Coach kept answering today's question inside
/// yesterday's conversation: `messages` outlives a night, so the assistant's own earlier turns state
/// yesterday's figures and the model stays consistent with them. The data was never stale —
/// `buildFullContext()` re-reads on every send — which is why it reads as "the coach only talks about my
/// imported data" rather than as stale numbers.
final class CoachConversationDayTests: XCTestCase {

    /// A fixed UTC calendar, so no case depends on the machine's zone or clock.
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Int {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        let date = utc.date(from: comps)!
        return AICoachEngine.localEpochDay(date, calendar: utc)
    }

    func testFreshSessionIsNeverStale() {
        // Nothing sent yet this session: there is no transcript to retire.
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: nil,
                                                         todayEpochDay: day(2026, 8, 22)))
    }

    func testSameDayKeepsTheConversation() {
        let today = day(2026, 8, 22)
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: today, todayEpochDay: today))
    }

    func testOvernightRetiresTheConversation() {
        // The reported case: last turn yesterday evening, next question this morning.
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: day(2026, 8, 21),
                                                         todayEpochDay: day(2026, 8, 21)))
        XCTAssertTrue(AICoachEngine.isStaleConversation(lastEpochDay: day(2026, 8, 21),
                                                        todayEpochDay: day(2026, 8, 22)))
    }

    func testLongGapRetiresTheConversation() {
        XCTAssertTrue(AICoachEngine.isStaleConversation(lastEpochDay: day(2026, 6, 11),
                                                        todayEpochDay: day(2026, 8, 22)))
    }

    /// Flying west, a timezone change or an NTP correction can move the local day BACKWARDS
    /// mid-conversation. That must not wipe a transcript the user is in the middle of, which is why the
    /// rule is strictly forward (`>`) and not `!=`. Relaxing it to `!=` fails this case and the year
    /// boundary below — the two that give the test teeth.
    func testClockMovingBackwardsKeepsTheConversation() {
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: day(2026, 8, 22),
                                                         todayEpochDay: day(2026, 8, 21)))
    }

    func testYearBoundaryIsJustAnotherDay() {
        XCTAssertTrue(AICoachEngine.isStaleConversation(lastEpochDay: day(2025, 12, 31),
                                                        todayEpochDay: day(2026, 1, 1)))
        XCTAssertFalse(AICoachEngine.isStaleConversation(lastEpochDay: day(2026, 1, 1),
                                                         todayEpochDay: day(2025, 12, 31)))
    }

    /// Swift-only, because Swift-only needs it: Kotlin gets its epoch day from `LocalDate`, while this
    /// side computes one. Counted with calendar day arithmetic rather than by dividing an interval by
    /// 86,400 — a day is not always 86,400 seconds. Across a DST spring-forward the count must still
    /// advance by exactly one, or a transcript would survive a night twice a year.
    func testLocalEpochDayAdvancesByOneAcrossADSTBoundary() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        var before = DateComponents()
        before.year = 2026; before.month = 3; before.day = 28; before.hour = 12
        var after = DateComponents()
        after.year = 2026; after.month = 3; after.day = 29; after.hour = 12   // clocks go forward
        let d0 = AICoachEngine.localEpochDay(london.date(from: before)!, calendar: london)
        let d1 = AICoachEngine.localEpochDay(london.date(from: after)!, calendar: london)
        XCTAssertEqual(d1 - d0, 1, "a 23-hour day must still be one day")
        XCTAssertTrue(AICoachEngine.isStaleConversation(lastEpochDay: d0, todayEpochDay: d1))
    }

    /// The symmetric DST case, and the one that actually threatens this implementation. `localEpochDay`
    /// counts whole days from the epoch INSTANT to a local midnight, so the count truncates — and on a
    /// 25-hour autumn day the extra hour is exactly the kind of slack that could make two local midnights
    /// land in the same whole-day bucket. If that happened, a transcript would survive a night once a
    /// year and the bug this whole change fixes would come back, seasonally.
    ///
    /// Spring-forward was tested first because it is the obvious one. It is not the dangerous one.
    func testLocalEpochDayAdvancesByOneAcrossTheAutumnFallBack() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        var before = DateComponents()
        before.year = 2026; before.month = 10; before.day = 24; before.hour = 12
        var after = DateComponents()
        after.year = 2026; after.month = 10; after.day = 25; after.hour = 12   // clocks go back
        let d0 = AICoachEngine.localEpochDay(london.date(from: before)!, calendar: london)
        let d1 = AICoachEngine.localEpochDay(london.date(from: after)!, calendar: london)
        XCTAssertEqual(d1 - d0, 1, "a 25-hour day must still be one day")
        XCTAssertTrue(AICoachEngine.isStaleConversation(lastEpochDay: d0, todayEpochDay: d1))
    }

    /// A zone far west of UTC, where the epoch instant itself falls on the PREVIOUS local day. The origin
    /// this counts from is not local midnight, so the arithmetic has to stay monotonic anyway — ordering
    /// is the only property the rule depends on.
    func testLocalEpochDayIsMonotonicWestOfUTC() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 21; comps.hour = 23; comps.minute = 30
        let lateEvening = la.date(from: comps)!
        let nextMorning = lateEvening.addingTimeInterval(3_600)   // 00:30 the next local day
        let d0 = AICoachEngine.localEpochDay(lateEvening, calendar: la)
        let d1 = AICoachEngine.localEpochDay(nextMorning, calendar: la)
        XCTAssertEqual(d1 - d0, 1, "crossing local midnight is one day, whatever the UTC offset")
        XCTAssertTrue(AICoachEngine.isStaleConversation(lastEpochDay: d0, todayEpochDay: d1))
        // And the hour before midnight is emphatically the same day.
        let earlier = lateEvening.addingTimeInterval(-3_600)
        XCTAssertEqual(AICoachEngine.localEpochDay(earlier, calendar: la), d0)
    }
}
