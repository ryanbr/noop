import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// A main night whose HRV the #1118 over-count gate REFUSED must not be replaced by the day's naps.
///
/// Field case: a ring night read 1.31 coverage, the gate made its HRV nil, and the day's HRV became the
/// mean of two 26-minute naps, which the baseline then folded as a full night. The three cases pin the
/// rule and its boundary: refused ⇒ naps excluded; merely unmeasured (no R-R at all) ⇒ #1884's fill-in
/// from the other sessions is unchanged; clean ⇒ pooled as before.
/// Byte-parity twin of Kotlin `AnalyticsEngineRefusedMainNightHrvTest`: same fixtures, same expected values.
final class AnalyticsEngineRefusedMainNightHrvTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2026-07-27"

    private var dayStart: Int { AnalyticsEngine.dayStartUtcSeconds(day) }
    private var nightStart: Int { dayStart - 4 * 3600 }            // 20:00 the evening before
    private var nightEnd: Int { nightStart + 600 * 60 }             // 06:00 on `day`
    private var napStart: Int { dayStart + 13 * 3600 }              // 13:00 on `day`
    private var napEnd: Int { napStart + 40 * 60 }                  // 13:40

    private func hr(_ start: Int, _ end: Int) -> [HRSample] {
        stride(from: start, to: end, by: 30).map { HRSample(ts: $0, bpm: 52 + ($0 / 300) % 4) }
    }

    /// One beat per second, alternating around 1000 ms by `swing`: coverage ~1.0, RMSSD = 2 * swing.
    /// The night uses 20 (RMSSD 40) and the nap 30 (RMSSD 60), so a pooled day and a nap-only day read
    /// differently.
    private func cleanRR(_ start: Int, _ end: Int, swing: Int) -> [RRInterval] {
        (start..<end).map { RRInterval(ts: $0, rrMs: ($0 - start) % 2 == 0 ? 1_000 - swing : 1_000 + swing) }
    }

    /// Two beats in every second (880 + 960 ms): ~1.84x the wall clock, refused by the gate, while its
    /// windows DO yield an RMSSD — the shape of a ring night scored from two beat channels at once.
    private func overCountedRR(_ start: Int, _ end: Int) -> [RRInterval] {
        (start..<end).flatMap { [RRInterval(ts: $0, rrMs: 880), RRInterval(ts: $0, rrMs: 960)] }
    }

    private func sessions() -> [SleepSession] {
        [SleepSession(start: nightStart, end: nightEnd, efficiency: 0.9,
                      stages: [StageSegment(start: nightStart, end: nightEnd, stage: "light")],
                      restingHR: nil, avgHRV: nil),
         SleepSession(start: napStart, end: napEnd, efficiency: 0.9,
                      stages: [StageSegment(start: napStart, end: napEnd, stage: "light")],
                      restingHR: nil, avgHRV: nil)]
    }

    private func analyze(nightRR: [RRInterval]) -> AnalyticsEngine.DayResult {
        AnalyticsEngine.analyzeDay(day: day, hr: hr(nightStart, nightEnd) + hr(napStart, napEnd),
                                   rr: nightRR + cleanRR(napStart, napEnd, swing: 30), profile: profile,
                                   providedSleep: sessions())
    }

    func testARefusedMainNightIsNotReplacedByTheNap() {
        let night = overCountedRR(nightStart, nightEnd)
        XCTAssertTrue(SleepStager.sessionHrvOverCounted(start: nightStart, end: nightEnd, rr: night),
                      "precondition: the gate refuses this night")
        XCTAssertNotNil(SleepStager.sessionAvgHRV(start: napStart, end: napEnd, rr: cleanRR(napStart, napEnd, swing: 30)),
                        "precondition: the nap on its own measures an HRV")
        XCTAssertNil(analyze(nightRR: night).daily.avgHrv,
                     "the day holds rather than reporting the nap as the night")
    }

    func testAMainNightWithNoRrStillFallsBackToTheNap() {
        let res = analyze(nightRR: [])
        XCTAssertEqual(res.daily.avgHrv ?? -1, 60, accuracy: 1e-9,
                       "not refused, only unmeasured: #1884's fill-in from the nap is unchanged")
    }

    func testACleanMainNightIsPooledWithTheNapAsBefore() {
        let res = analyze(nightRR: cleanRR(nightStart, nightEnd, swing: 20))
        // In-bed-weighted: (40 * 600 min + 60 * 40 min) / 640 min.
        XCTAssertEqual(res.daily.avgHrv ?? -1, 41.25, accuracy: 1e-9)
    }

    /// The helper is the gate: whatever it says, `sessionAvgHRV` does, on the same beats.
    func testTheHelperAgreesWithTheValueGate() {
        for rr in [overCountedRR(nightStart, nightEnd), cleanRR(nightStart, nightEnd, swing: 20)] {
            XCTAssertEqual(SleepStager.sessionHrvOverCounted(start: nightStart, end: nightEnd, rr: rr),
                           SleepStager.sessionAvgHRV(start: nightStart, end: nightEnd, rr: rr) == nil)
        }
    }
}
