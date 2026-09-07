import XCTest

/// Pins the widget cost counters. Twin of Android's `WidgetTelemetryTest`, minus the bitmap half,
/// which has no analogue here.
///
/// The Android side has had three defects in these counters and none of them were arithmetic: each
/// time a counter's NAME claimed more than its wiring delivered. So the cases below are written
/// against the questions the numbers are supposed to answer rather than against the sums.
final class WidgetTelemetryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        WidgetTelemetry.resetForTest()
    }

    /// The throttle is the whole reason a live-HR stream does not become a publish per tick, so the
    /// offered count has to include what it dropped. Reporting only what got through would make a
    /// broken throttle look like a quiet one.
    func testOfferedIncludesWhatTheThrottleDropped() {
        WidgetTelemetry.noteAdmitted(now: t0)
        for i in 0..<59 { WidgetTelemetry.noteGated(now: t0.addingTimeInterval(Double(i))) }
        let s = WidgetTelemetry.snapshot(now: t0.addingTimeInterval(60))
        XCTAssertEqual(s.admitted, 1)
        XCTAssertEqual(s.gated, 59)
        XCTAssertEqual(s.offered, 60)
        XCTAssertTrue(s.render().contains("0 reloaded / 1 admitted / 60 offered"), s.render())
    }

    /// Reloads, not publishes. A publish that declined the reload cost nothing and spent none of
    /// WidgetKit's budget, so counting it here would make the figure unable to fall when the dedup in
    /// `saveAndReloadIfChanged` did its job — the one thing that dedup is for.
    func testTheRateCountsReloadsNotPublishes() {
        WidgetTelemetry.noteAdmitted(now: t0)
        for m in 1...10 {
            let at = t0.addingTimeInterval(Double(m) * 60)
            WidgetTelemetry.noteAdmitted(now: at)
            if m > 5 { WidgetTelemetry.noteDeclined() } else { WidgetTelemetry.noteReloaded(now: at) }
        }
        let s = WidgetTelemetry.snapshot(now: t0.addingTimeInterval(660))
        XCTAssertEqual(s.admitted, 11)
        XCTAssertEqual(s.reloaded, 5)
        XCTAssertEqual(s.declined, 5)
        // Five reloads in a ten-minute steady window is 30/h, not the 60/h the publishes would claim.
        XCTAssertEqual(s.reloadsPerHour ?? 0, 30, accuracy: 0.001)
    }

    /// The startup burst must not be quoted as a rate. The snapshot's fields arrive one by one at
    /// launch and each publishes on the spot, so a launch produces activity the once-a-minute throttle
    /// had nothing to do with. An Android capture reported six in a hundred seconds as 215/h against a
    /// steady state of about sixty.
    func testAStartupBurstIsNotQuotedAsARate() {
        for offset in [0.0, 2, 5, 9, 30, 95] {
            WidgetTelemetry.noteAdmitted(now: t0.addingTimeInterval(offset))
            WidgetTelemetry.noteReloaded(now: t0.addingTimeInterval(offset))
        }
        let s = WidgetTelemetry.snapshot(now: t0.addingTimeInterval(100))
        XCTAssertEqual(s.admitted, 6)
        XCTAssertNil(s.reloadsPerHour, "a burst is not a rate")
        XCTAssertTrue(s.render().contains("steady"), s.render())
    }

    /// The withheld-rate message has to name the window it waits on. Phrasing it as a minimum UPTIME
    /// was wrong on Android: publishes can be sparse enough that the steady window opens late, so the
    /// line would sit twenty minutes in still claiming it needed six.
    func testAWithheldRateNamesTheSteadyWindow() {
        WidgetTelemetry.noteAdmitted(now: t0)
        WidgetTelemetry.noteAdmitted(now: t0.addingTimeInterval(19 * 60))
        let line = WidgetTelemetry.snapshot(now: t0.addingTimeInterval(20 * 60)).render()
        XCTAssertTrue(line.contains("over 20m"), line)
        XCTAssertTrue(line.contains("steady 1m of 5m"), line)
    }

    /// The absence of widget activity is itself an answer to a drain report, so it must be stated
    /// rather than rendered as an empty line.
    func testASessionWithNoPublishesSaysSo() {
        XCTAssertEqual(WidgetTelemetry.snapshot(now: t0).render(),
                       "Widgets:     no publishes this app session")
    }

    /// The rate is a diagnostics field read by eye and by grep, so it must not pick up a locale's
    /// decimal comma.
    func testTheRateFormatsWithADot() {
        WidgetTelemetry.noteAdmitted(now: t0)
        for m in 1...10 {
            let at = t0.addingTimeInterval(Double(m) * 60)
            WidgetTelemetry.noteAdmitted(now: at)
            WidgetTelemetry.noteReloaded(now: at)
        }
        let line = WidgetTelemetry.snapshot(now: t0.addingTimeInterval(660)).render()
        XCTAssertTrue(line.contains("60.0/h"), line)
        XCTAssertFalse(line.contains("60,0/h"), line)
    }

    /// The widget-removed export is half of the comparison the counters exist for, so a reload with
    /// nothing installed must not read as one. Android had exactly this bug; iOS never checks whether
    /// a widget is placed before calling `reloadAllTimelines`, so without this the figure would be
    /// just as blind here.
    func testAReloadWithNoWidgetInstalledIsNotCountedAsOne() {
        WidgetTelemetry.noteWidgetsInstalled(false)
        WidgetTelemetry.noteAdmitted(now: t0)
        for m in 1...10 {
            let at = t0.addingTimeInterval(Double(m) * 60)
            WidgetTelemetry.noteAdmitted(now: at)
            WidgetTelemetry.noteNoWidget()
        }
        let s = WidgetTelemetry.snapshot(now: t0.addingTimeInterval(660))
        XCTAssertEqual(s.admitted, 11)
        XCTAssertEqual(s.reloaded, 0)
        XCTAssertEqual(s.noWidget, 10)
        XCTAssertEqual(s.reloadsPerHour ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(s.render().contains("10 with no widget installed"), s.render())
    }

    /// Unknown must count as installed. Over-reporting reloads is the safe direction for a figure
    /// whose whole purpose is to show a cost: a wrong "nothing was spent" is the one answer that would
    /// end an investigation early.
    func testPresenceDefaultsToInstalledBeforeWidgetKitHasAnswered() {
        XCTAssertTrue(WidgetTelemetry.widgetsInstalled)
        WidgetTelemetry.noteWidgetsInstalled(false)
        XCTAssertFalse(WidgetTelemetry.widgetsInstalled)
        WidgetTelemetry.resetForTest()
        XCTAssertTrue(WidgetTelemetry.widgetsInstalled, "reset returns it to unknown, not to false")
    }
}
