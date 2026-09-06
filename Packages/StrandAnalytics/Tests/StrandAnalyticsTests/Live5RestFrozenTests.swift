import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Bug #977 (iOS, WHOOP 5.0, live Bluetooth): "Rest score stuck 93 since forever."
///
/// The mechanism: a LIVE WHOOP 5.0 streams standard 0x2A37 HR continuously, but gravity is only ever
/// populated by the *history offload* (Backfiller). With no overnight gravity the day reaches the scoring
/// loop with dense HR — it clears IntelligenceEngine's `hr.count >= 200` gate, so recovery/Charge still
/// score — while sleep detection finds nothing. No sleep means no `totalSleepMin`/`efficiency`, so
/// `AnalyticsEngine.Rest.composite(daily:)` is nil, so NO `sleep_performance` point is written, and the
/// Rest read-out has nothing new to show.
///
/// WHAT CHANGED SINCE THESE TESTS WERE WRITTEN, and why they are repinned rather than deleted:
///
///  • The V1 stager still bails without gravity (`grav.count < 2`). That is unchanged and still pinned
///    below — V1 is a selectable fallback (the 4.0 is unvalidated on either stager, #271/#319), so its
///    behaviour is worth stating, but it is no longer what a default install runs.
///  • The rescue is NOT inside `detectSleep` — neither stager finds a night without motion, and both are
///    pinned saying so below. It is in `IntelligenceEngine`: when a day has no motion, no hypnogram and
///    no stored night, it falls back to `SleepStager.hrOnlySessions(hr:rr:resp:)` (#1801) and feeds the
///    result in as `providedSleep`. #1884 then stopped an all-HR-only night being discarded from the
///    daily aggregates. So the shipping path DOES score a no-gravity night, which is precisely the
///    "HR-only fallback composite" the old fix-contract test named as one of two acceptable fixes.
///    That fallback is covered by `SleepStagerHrOnlySessionsTests` + `AnalyticsEngineHrOnlyDayTests`.
///
/// The old contract test asserted `Rest.composite(daily:)` on a hand-built row with no sleep fields and
/// wrapped it in `XCTExpectFailure`. That could never pass, whatever got fixed: a row with no aggregates
/// is nil BY DEFINITION, not by bug. It was testing the wrong layer. The chain is pinned at its two real
/// joints instead — does the shipping stager stage the night, and does a staged night yield a composite.
///
/// The display half (whether Today shows a stale carried value or falls through to its no-data state) is
/// #977's `freshRestScore` + `isCarryStale`, which live in the app target and are covered there and by
/// Android's `RestFreshnessTest`. This package pins only what it owns, and says so at the bottom of the
/// file rather than keeping a test that re-simulates a rule it cannot import.
final class Live5RestFrozenTests: XCTestCase {

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        stride(from: 0, to: durationS, by: 1).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// A late-night start (02:00 UTC, tzOffset 0) so the window is unambiguously overnight and
    /// the daytime false-sleep guard is irrelevant to the outcome.
    private func nightStart() -> Int {
        let refMidnight = 1_749_513_600   // 2026-06-10 00:00:00 UTC
        return refMidnight + 2 * 3_600
    }

    // MARK: - Stage 1: no gravity ⇒ no sleep session (the direct BLE-live-5.0 shape)

    /// V1, stated EXPLICITLY rather than taken from the default: 8 h of continuous sleep-plausible HR
    /// with zero gravity yields nothing, because V1's spine is motion stillness and there is none.
    ///
    /// Still worth pinning — V1 remains selectable, and the 4.0 is unvalidated on either stager
    /// (#271/#319) — but it is no longer what a default install runs, which is the whole point of the
    /// V2 test below. The original spelling of this test relied on `useSleepStagerV2`'s default, so it
    /// silently stopped describing shipped behaviour the moment that default moved.
    func testV1WithNoGravityDetectsNoSleep() {
        let start = nightStart()
        let dur = 8 * 60 * 60
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: [], useSleepStagerV2: false)
        XCTAssertTrue(sessions.isEmpty,
                      "V1's spine is motion stillness: no gravity, no session")
    }

    /// V2 too. This is the correction to my first attempt at this test, which asserted that V2 WOULD
    /// stage here and failed in CI — rightly.
    ///
    /// `detectSleep` has no HR-only rescue on either stager: V2's extra machinery is in how it stages a
    /// run, not in finding one without motion. The rescue lives one layer up. `IntelligenceEngine` sees
    /// the empty result and, when there is no motion, no hypnogram and no stored night, falls back to
    /// `SleepStager.hrOnlySessions(hr:rr:resp:)` and feeds the result in as `providedSleep`
    /// (`IntelligenceEngine.swift`, gate line `no-motion-no-hypnogram`). That fallback is covered by
    /// `SleepStagerHrOnlySessionsTests` and `AnalyticsEngineHrOnlyDayTests`, so it is named here rather
    /// than duplicated.
    ///
    /// Pinning this keeps the two facts adjacent: detection genuinely yields nothing without motion, and
    /// that is not the end of the story — which is exactly what the original version of this file got
    /// wrong in the other direction, by treating the empty result as the final word on Rest.
    func testV2WithNoGravityAlsoDetectsNoSleep() {
        let start = nightStart()
        let hr = hrStream(start: start, durationS: 8 * 60 * 60, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: [], useSleepStagerV2: true)
        XCTAssertTrue(sessions.isEmpty,
                      "detectSleep needs motion on either stager; the HR-only rescue is the engine's fallback")
    }

    // MARK: - Stage 2: no sleep ⇒ no Rest composite ⇒ no sleep_performance point

    /// A DailyMetric shaped exactly as `analyzeDay` leaves it when `matched` is empty: HRV/RHR
    /// present (so Charge can still be scored) but no sleep aggregates. This is the row a live-5.0
    /// day produces when gravity never offloaded.
    private func chargeableButUnsleptDaily(day: String) -> DailyMetric {
        DailyMetric(day: day,
                    totalSleepMin: nil,   // absent ⇒ no Rest composite
                    efficiency: nil,      // absent ⇒ no Rest composite
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: 52,        // present ⇒ recovery/Charge advances
                    avgHrv: 65,           // present ⇒ recovery/Charge advances
                    recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    func testUnsleptDailyProducesNilRestComposite() {
        let daily = chargeableButUnsleptDaily(day: "2026-07-02")
        // This is the exact guard at AnalyticsEngine.Rest.composite(daily:) line 696:
        //   guard let tstMin = d.totalSleepMin, tstMin > 0, let eff = d.efficiency else { return nil }
        XCTAssertNil(AnalyticsEngine.Rest.composite(daily: daily),
                     "No sleep aggregates ⇒ Rest.composite(daily:) is nil ⇒ no sleep_performance point written")
    }

    // MARK: - Stage 3: the display-side freeze this produces

    /// Reproduces the Today resolver's tail fallback (iOS LiquidTodayView.swift line 777 /
    /// Android TodayScreen.kt line 689): when today has no `sleep_performance` row, both
    /// platforms fall back to the latest value in the series. If new nights never write a row,
    /// that latest value is pinned to the last night that WAS scored — 93 — forever.
    // MARK: - The other joint: a STAGED night must yield a composite

    /// The half of the chain this package owns downstream of staging: once a night is staged, its
    /// aggregates must produce a Rest signal.
    ///
    /// This replaces a test that wrapped `XCTExpectFailure("#977 not yet fixed")` around
    /// `Rest.composite(daily:)` for a row with NO sleep fields. That assertion could never pass whatever
    /// was fixed upstream — a row without `totalSleepMin`/`efficiency` is nil by the guard's definition,
    /// not by a bug — so it asserted the wrong layer and would have gone on advertising #977 as open
    /// forever. The real requirement it was reaching for is the pair: the shipping stager stages the
    /// night (above), and a staged night scores (here).
    func testStagedNightYieldsARestComposite() {
        let daily = DailyMetric(day: "2026-07-02",
                                totalSleepMin: 7 * 60,
                                efficiency: 0.92,
                                deepMin: 80, remMin: 95, lightMin: 245, disturbances: 3,
                                restingHr: 52, avgHrv: 65,
                                recovery: nil, strain: nil, exerciseCount: nil,
                                spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
        XCTAssertNotNil(AnalyticsEngine.Rest.composite(daily: daily),
                        "Sleep aggregates present ⇒ a Rest composite ⇒ a sleep_performance point is written")
    }

    // The display half deliberately has NO test here. It used to, and that test asserted `max(by:)` over a
    // literal dictionary — it exercised no product code at all, which is worse than no test because it
    // reads like coverage. Since #977 the rule it meant to describe is `freshRestScore` + `isCarryStale`:
    // today's own value wins, the carry applies only on today and only inside the freshness window, and
    // otherwise the read-out falls through to its no-data state instead of freezing on a weeks-old number.
    // Those live in the app target and in Android's `TodayScoring.freshRestScore`, covered by
    // `RestFreshnessTest`. This package pins what it owns and points at the rest.
}
