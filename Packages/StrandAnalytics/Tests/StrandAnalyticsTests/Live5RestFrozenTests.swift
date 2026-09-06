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
///  • V2 (`PuffinExperiment.experimentalSleepV2Enabled`, which defaults to ON) has an HR-only spine:
///    `hrOnlySleepRuns` supplies what gravity stillness normally would. #1801 added it and #1884 stopped
///    an all-HR-only night being discarded from the daily aggregates. So the shipping path CAN stage a
///    no-gravity night, which is precisely the "HR-only fallback composite" the old fix-contract test
///    named as one of two acceptable fixes.
///
/// The old contract test asserted `Rest.composite(daily:)` on a hand-built row with no sleep fields and
/// wrapped it in `XCTExpectFailure`. That could never pass, whatever got fixed: a row with no aggregates
/// is nil BY DEFINITION, not by bug. It was testing the wrong layer. The chain is pinned at its two real
/// joints instead — does the shipping stager stage the night, and does a staged night yield a composite.
///
/// The display half (whether Today shows a stale carried value or falls through to its no-data state) is
/// #977's `freshRestScore` + `isCarryStale`, which live in the app target and are covered there and by
/// Android's `RestFreshnessTest`. This package pins only what it owns.
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

    /// The shipping path (V2 defaults ON). Same night, same absence of gravity — this is the case #977
    /// froze on, and the one #1801's HR-only spine exists to stage.
    ///
    /// This test is the probe that tells the two hypotheses apart. If it passes, a live 5.0 whose gravity
    /// never offloaded now stages its night from HR alone, gets sleep aggregates, and Rest advances — the
    /// frozen state is closed and the old `XCTExpectFailure` was vouching for a fixed bug. If it fails,
    /// the gap is real and this is where it lives.
    func testV2WithNoGravityStagesTheNightFromHrAlone() {
        let start = nightStart()
        let dur = 8 * 60 * 60
        let hr = hrStream(start: start, durationS: dur, bpm: 50)
        let sessions = SleepStager.detectSleep(hr: hr, gravity: [], useSleepStagerV2: true)
        XCTAssertFalse(sessions.isEmpty,
                       "V2 has an HR-only spine (hrOnlySleepRuns); a dense sleep-plausible night must stage")
        XCTAssertTrue(sessions.allSatisfy { $0.hrOnly },
                      "staged without gravity ⇒ every session must carry hrOnly, so consumers can weigh it")
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

    /// When no point is written, the SERIES tail is the last night that scored. That is a fact about the
    /// series and it is unchanged — but it is no longer the same statement as "Today shows 93 forever",
    /// which is what this test used to assert.
    ///
    /// #977 put `freshRestScore` + `isCarryStale` in front of the display: today's own value wins, else
    /// the carry is used ONLY on today and ONLY inside the freshness window, else the read-out falls
    /// through to its no-data state rather than freezing on a weeks-old number. Those live in the app
    /// target (and Android's `TodayScoring.freshRestScore`, covered by `RestFreshnessTest`), so this
    /// package pins the series semantics and names where the gate is tested instead of re-simulating a
    /// display rule it cannot import.
    func testSeriesTailIsTheLastScoredNightWhenNoPointIsWritten() {
        let restByDay: [String: Double] = [
            "2026-06-25": 88,
            "2026-06-26": 91,
            "2026-06-27": 93,   // the last night that staged and scored
        ]
        let seriesTail = restByDay.max(by: { $0.key < $1.key })?.value
        XCTAssertEqual(seriesTail, 93, "the tail is the newest scored night, not the newest day")
        // Later days ran and advanced Charge but wrote no sleep_performance row, so the tail does not move.
        for day in ["2026-06-28", "2026-06-29", "2026-06-30"] {
            XCTAssertNil(restByDay[day], "\(day) wrote no Rest point, so it contributes nothing to the tail")
        }
    }
}
