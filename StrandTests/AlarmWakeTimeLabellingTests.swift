import XCTest
@testable import Strand

/// The Alarms screen carries two time pickers and only one of them wakes anybody.
///
/// The strap wake-alarm's "Wake at" arms the strap's firmware alarm. The wind-down card's picker is an
/// INPUT to the reminder's arithmetic: nudge = wake - sleep need - lead. Both were labelled "Wake time"
/// for VoiceOver, both sat on the same screen, and the two values are stored independently
/// (`behavior.smartAlarmMinutes` vs `windDown.wakeMinutes`) so they routinely disagree. A reporter asked
/// outright which of the two times would wake them, which is the question this screen must never provoke.
///
/// Source-asserted because SwiftUI labels have no unit seam, the same reason `PiiRedactionTests` reads
/// source. These pin the wording contract, not the layout.
final class AlarmWakeTimeLabellingTests: XCTestCase {

    /// No two accessibility labels on this screen may be the same word for different things. The exact
    /// failure: VoiceOver announced "Wake time" for the alarm and "Wake time" for the reminder input.
    func testTheTwoWakePickersDoNotShareAnAccessibilityLabel() throws {
        let src = try Self.alarmViewSource()
        let labels = Self.accessibilityLabels(in: src)
        XCTAssertFalse(labels.isEmpty, "no accessibilityLabel calls found, the scan is broken")
        let duplicates = Dictionary(grouping: labels, by: { $0 }).filter { $0.value.count > 1 }
        XCTAssertTrue(duplicates.isEmpty,
                      "these accessibility labels are used for more than one control: \(duplicates.keys.sorted())")
    }

    /// The bare phrase "Wake time" must not come back as a field label, on either card. It is the one
    /// wording that cannot distinguish the alarm from the reminder's input.
    func testNeitherPickerIsLabelledJustWakeTime() throws {
        let src = try Self.alarmViewSource()
        XCTAssertFalse(Self.accessibilityLabels(in: src).contains("Wake time"),
                       "\"Wake time\" is ambiguous on this screen: say whose wake time it is")
    }

    /// The wind-down field must say, in its own card, that it does not wake anyone. Without this the
    /// only disclaimer is "It's a suggestion, not an alarm" in tertiary footnote text above the toggle,
    /// several rows away from the picker people actually read.
    func testTheWindDownFieldSaysItDoesNotWakeYou() throws {
        let src = try Self.alarmViewSource()
        XCTAssertTrue(src.contains("This time does not wake you."),
                      "the wind-down wake field must disclaim waking, next to the field itself")
    }

    /// #1864 made the per-day overrides drive the STRAP ALARM as well as the nudge, but the copy still
    /// read as though they only moved the evening reminder, while the editor sat under the wind-down
    /// card. A day set there re-times the buzz on the wrist, and the screen has to say so.
    func testThePerDayCopySaysItMovesTheStrapAlarmToo() throws {
        let src = try Self.alarmViewSource()
        XCTAssertTrue(src.contains("These times move your strap alarm AND the evening reminder"),
                      "per-day overrides drive applySmartAlarm(), so the copy must name the strap alarm")
    }

    /// A day with no override of its own has no single fallback to show: the alarm falls back to its own
    /// time, the reminder to the usual wake time. The row can only display one number and displays the
    /// reminder's, so both have to be named underneath rather than one silently standing for both.
    func testUntouchedDaysNameBothFallbacks() throws {
        let src = try Self.alarmViewSource()
        XCTAssertTrue(src.contains("Days you leave alone keep your strap alarm at"),
                      "the untouched-day explainer must name the strap alarm's own fallback")
        XCTAssertTrue(src.contains("and time the reminder from"),
                      "the untouched-day explainer must name the reminder's fallback too")
    }

    /// The line naming what wakes you must resolve the NEXT fire, not print `smartAlarmMinutes`.
    ///
    /// The first draft of this very change printed the base time, which is wrong on exactly the days the
    /// reporter had changed: their Saturday override is 20:30 while the base is 10:00. A screen built to
    /// stop people misreading which time wakes them cannot itself state a time that will not.
    func testTheWakesYouLineResolvesTheNextFireRatherThanTheBaseTime() throws {
        let src = try Self.alarmViewSource()
        XCTAssertTrue(src.contains("AppModel.nextSmartAlarmDate("),
                      "the answer line must come from the same resolver applySmartAlarm arms the strap from")
        guard let range = src.range(of: "private var nextStrapAlarmLabel: String? {") else {
            return XCTFail("nextStrapAlarmLabel not found")
        }
        // Bounded at the property's own closing brace, not a character budget: a fixed prefix would run
        // on into the next declaration and scan code this test is not talking about.
        let after = src[range.upperBound...]
        let close = try XCTUnwrap(after.range(of: "\n    }"), "nextStrapAlarmLabel's closing brace not found")
        let body = String(after[..<close.lowerBound])
        XCTAssertTrue(body.contains("nextStrapAlarm()"),
                      "it must resolve through the funnel, which is what passes the per-day overrides in")
        XCTAssertFalse(body.contains("timeLabel("),
                       "timeLabel is 24-hour regardless of locale; this line uses a localised template")
    }

    /// The strap alarm card must disclose that per-day overrides re-time it.
    ///
    /// Those overrides are edited under the wind-down card, so this card can read "10:00" during a week
    /// whose Saturday fires at 20:30, and checking your alarm is the one thing someone opens this card to
    /// do. The disclosure is gated on an override existing, so it stays absent for the common case.
    func testTheAlarmCardDisclosesPerDayOverrides() throws {
        let src = try Self.alarmViewSource()
        XCTAssertTrue(src.contains("Some days have a time of their own"),
                      "the alarm card must say when a per-day time will override the picker above it")
        XCTAssertTrue(src.contains("if !overrides.isEmpty, let next = nextStrapAlarmLabel {"),
                      "the disclosure must be gated on an override existing, and name the real next fire")
    }

    /// No countdown, and no hero alarm figure, for an alarm that will not arm.
    ///
    /// A WHOOP 5/MG arms its firmware alarm only with Experimental on, and on macOS there is no fallback
    /// either: `scheduleSmartAlarmBackupNotification` is `#if os(iOS)` with no `#else`, so in that state
    /// nothing happens at the chosen time at all. "Alarm in 18 hours" sitting above the card's own line
    /// admitting the strap is NOT armed is the #864 honesty bug reappearing one row from its fix. Both
    /// readouts share one gate so neither can be added back without the other.
    func testNoCountdownOrHeroAlarmWhenTheStrapWillNotArm() throws {
        let src = try Self.alarmViewSource()
        XCTAssertTrue(src.contains("private var strapAlarmWillArm: Bool {"),
                      "the arm condition must be named once, not spelled out at each call site")
        // Every readout resolves through one funnel, and the funnel carries the gate. Counting gated call
        // sites was the weaker test and it passed while `nextStrapAlarmLabel` went ungated: it resolved
        // the alarm by itself, so the wind-down card still promised a buzz a 5/MG would never give.
        XCTAssertEqual(src.components(separatedBy: "AppModel.nextSmartAlarmDate(").count - 1, 1,
                       "exactly one resolver call: every alarm readout must come through nextStrapAlarm")
        guard let funnel = src.range(of: "private func nextStrapAlarm(from now: Date = Date()) -> Date? {") else {
            return XCTFail("nextStrapAlarm funnel not found")
        }
        let after = src[funnel.upperBound...]
        let close = try XCTUnwrap(after.range(of: "\n    }"), "nextStrapAlarm's closing brace not found")
        let body = String(after[..<close.lowerBound])
        XCTAssertTrue(body.contains("guard behavior.smartAlarmEnabled, strapAlarmWillArm else"),
                      "the funnel is where the gate belongs, so no readout can skip it")
    }

    /// The hero is the first figure on the screen and it must not call the reminder's input "Wake".
    ///
    /// It sat above both cards, in the largest type on the page, labelling `wakeMinutes` as "Wake". A
    /// reader looking for their alarm met that number first, which is where the reported confusion starts.
    func testTheHeroDoesNotCallTheReminderInputWake() throws {
        let src = try Self.alarmViewSource()
        XCTAssertFalse(src.contains("heroTime(label: \"Wake\","),
                       "the hero's wake figure is the wind-down input, so it cannot be labelled \"Wake\"")
        XCTAssertTrue(src.contains("heroTime(label: \"Usual wake\","),
                      "name it for what it is")
    }

    /// The alarm may join the hero row, but never on the arrow.
    ///
    /// The arrow is an arithmetic pair: the nudge is DERIVED from the usual wake time. The alarm is not
    /// part of that derivation, so chaining it would claim the nudge is timed for the alarm, which is the
    /// one thing this screen must stop implying.
    func testTheHeroShowsTheAlarmSeparatelyFromTheDerivedPair() throws {
        let src = try Self.alarmViewSource()
        XCTAssertFalse(src.contains("heroTime(label: \"Alarm\""),
                       "the alarm is the countdown block, not a third figure repeating its own time")
        // Both lines must read the SAME clock. `nextSmartAlarmDate` returns the next strictly-future
        // fire, so a countdown on `tick.date` beside a stamp on its own `Date()` can straddle the fire
        // moment and print "less than a minute" above tomorrow's date.
        XCTAssertTrue(try Self.windowHeroBody(in: src).contains("nextStrapAlarmStamp(from: tick.date)"),
                      "the stamp must resolve from the tick the countdown used, not its own Date()")
        let body = try Self.windowHeroBody(in: src)
        let arrows = body.components(separatedBy: "systemName: \"arrow.right\"").count - 1
        XCTAssertEqual(arrows, 1, "exactly one arrow: it joins the derived pair, and the alarm is not in it")
    }

    /// The countdown must tick and must resolve the same next fire as everything else on the card.
    ///
    /// Computed once at view build it would freeze at whatever it read when the screen opened, which is
    /// the one failure mode a countdown has. It is also override-aware for the same reason the rest of
    /// this screen is: on a day with its own time, "in 18 hours" has to count to THAT time.
    func testTheCountdownTicksAndHonoursOverrides() throws {
        let src = try Self.alarmViewSource()
        XCTAssertTrue(src.contains("TimelineView(.periodic(from: .now, by: 60))"),
                      "the countdown must re-render on a clock, not freeze at the time the screen opened")
        XCTAssertEqual(src.components(separatedBy: "TimelineView(.periodic(from: .now, by: 60))").count - 1, 1,
                       "exactly one live countdown: two start the \"which one is real\" question again")
        XCTAssertTrue(try Self.windowHeroBody(in: src).contains("strapAlarmCountdown(from: tick.date)"),
                      "the countdown belongs in the hero, where a glance lands, not six rows into a card")
        guard let range = src.range(of: "private func strapAlarmCountdown(from now: Date) -> String? {") else {
            return XCTFail("strapAlarmCountdown not found")
        }
        let after = src[range.upperBound...]
        let close = try XCTUnwrap(after.range(of: "\n    }"), "strapAlarmCountdown's closing brace not found")
        let body = String(after[..<close.lowerBound])
        XCTAssertTrue(body.contains("nextStrapAlarm(from: now)"),
                      "the countdown must resolve from the ticking date, through the gated funnel")
        XCTAssertTrue(body.contains("AppLanguage.activeLocale"),
                      "unit words follow the in-app language, like every other formatter in the app")
    }

    /// Both formatted lines on this card must follow the app language rather than the device's.
    func testFormattersUseTheInAppLocale() throws {
        let src = try Self.alarmViewSource()
        XCTAssertFalse(src.contains("formatter.locale = .current"),
                       "a reader running NOOP in German on an English device must get German words")
    }

    /// `nextSmartAlarmDate` is the contract this screen's answer leans on: an override for a weekday wins
    /// over the base time. Pinned here as behaviour, not just as a call site, so the answer stays true.
    func testAnOverrideDayWinsOverTheBaseAlarmTime() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // Wednesday 2026-09-16, 09:00 UTC. Base alarm 10:00 daily, Saturday overridden to 20:30.
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 9)))
        let next = try XCTUnwrap(AppModel.nextSmartAlarmDate(minutes: 10 * 60,
                                                             weekdays: [7],
                                                             overrides: [7: 20 * 60 + 30],
                                                             from: now,
                                                             calendar: cal))
        let parts = cal.dateComponents([.weekday, .hour, .minute], from: next)
        XCTAssertEqual(parts.weekday, 7, "Saturday is the only enabled day")
        XCTAssertEqual(parts.hour, 20)
        XCTAssertEqual(parts.minute, 30, "the override, not the 10:00 base, is what the strap is armed with")
    }

    // MARK: - Source access

    /// Every string passed to `.accessibilityLabel("…")` in the file. Literal-only on purpose: an
    /// interpolated label (the weekday rows) cannot collide as a fixed word.
    private static func accessibilityLabels(in src: String) -> [String] {
        var out: [String] = []
        var rest = Substring(src)
        while let hit = rest.range(of: ".accessibilityLabel(\"") {
            let after = rest[hit.upperBound...]
            guard let close = after.range(of: "\"") else { break }
            let literal = String(after[..<close.lowerBound])
            if !literal.contains("\\(") { out.append(literal) }
            rest = after[close.upperBound...]
        }
        return out
    }

    /// The body of `windowHero`, bounded at its own closing brace.
    ///
    /// The brace is matched at four-space indent, which is the property's own level. Every brace nested
    /// inside it sits deeper, so this cannot stop early on a closure.
    private static func windowHeroBody(in src: String) throws -> String {
        guard let start = src.range(of: "private var windowHero: some View {") else {
            throw SourceNotReachable(path: "windowHero not found in SmartAlarmView.swift")
        }
        let after = src[start.upperBound...]
        guard let end = after.range(of: "\n    }") else {
            throw SourceNotReachable(path: "windowHero's closing brace not found")
        }
        return String(after[..<end.lowerBound])
    }

    /// Raised when the source this test reads cannot be located. A named error rather than `XCTSkip`
    /// ON PURPOSE: a skip is a GREEN test, so an unreachable file would turn this into an assertion that
    /// silently checks nothing.
    private struct SourceNotReachable: Error, CustomStringConvertible {
        let path: String
        var description: String { "SmartAlarmView.swift not reachable from \(path)" }
    }

    private static func alarmViewSource(file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("Strand/Screens/SmartAlarmView.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw SourceNotReachable(path: "\(file)")
    }
}
