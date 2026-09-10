import Foundation
import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// A whole day whose only sleep is HR-only, driven through `analyzeDay` (#1884).
///
/// The ORACLE twin of the Kotlin `AnalyticsEngineHrOnlyDayTest`. The unit tests around this one check the
/// pieces — `SleepStagerHrOnlySessionsTests` that a session reports what it measured,
/// `HrOnlyPhysiologyIsolationTests` that the day's physiology set is chosen the way the design says.
/// Neither runs the whole function, and the gap between them is where #1884's own regression hid:
/// `sleepHrOnly` was derived from `physiologySessions.isEmpty`, which means "every session was HR-only"
/// ONLY while that set was an exclusion. Making it a preference means it can never be empty when
/// `matched` is not, so the flag would have been pinned to false forever.
///
/// Nothing pinned that derivation: every other `sleepHrOnly` test supplies the flag as an INPUT (the
/// carry, the coalesce, the migration, the note gate). This drives it as an OUTPUT.
final class AnalyticsEngineHrOnlyDayTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2026-07-27"

    /// The same field-shaped generator the session tests use — 16 h awake around 74 +/- 11 bpm, then 8 h
    /// asleep around 64 +/- 5 — anchored so the night runs 00:00-08:00 on `day`. NO gravity, which is what
    /// makes the night HR-only: an unbonded strap streams standard HR and R-R and banks no motion.
    private func streams() -> ([HRSample], [RRInterval]) {
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let t0 = dayStart - 16 * 3600
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for i in 0..<(16 * 3600) {
            let bpm = 74 + Int(sin(Double(i) / 500.0) * 11)
            hr.append(HRSample(ts: t0 + i, bpm: bpm))
            rr.append(RRInterval(ts: t0 + i, rrMs: 60000 / bpm))
        }
        for j in 0..<(8 * 3600) {
            let bpm = 64 + Int(sin(Double(j) / 900.0) * 5)
            hr.append(HRSample(ts: dayStart + j, bpm: bpm))
            rr.append(RRInterval(ts: dayStart + j, rrMs: 60000 / bpm))
        }
        return (hr, rr)
    }

    func testAllHrOnlyDayReportsMeasuredVitalsAndStillMarksItselfHrOnly() {
        let (hr, rr) = streams()
        // The production wiring: IntelligenceEngine stages the HR-only night and hands it to analyzeDay as
        // `providedSleep`. Driving it the same way is the point — the enrichment call site that used to
        // short-circuit on `hrOnly` only exists on this path.
        let provided = SleepStager.hrOnlySessions(hr: hr, rr: rr, resp: [])
        XCTAssertFalse(provided.isEmpty, "the HR-only spine must stage a night here")

        let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, profile: profile,
                                             providedSleep: provided)

        XCTAssertFalse(res.sleepSessions.isEmpty, "the staged night must reach the day's sessions")
        XCTAssertTrue(res.sleepSessions.allSatisfy { $0.hrOnly },
                      "every session must be HR-only — this day has no gravity at all")

        // #1884: measured, not discarded. Before the change both of these were nil by construction, which
        // is what left Charge with `nilScore reason=missingInput`.
        XCTAssertNotNil(res.daily.restingHr, "resting HR is HR-derived and must survive to the day row")
        XCTAssertNotNil(res.daily.avgHrv,
                        "the HRV measured over this night's windows must survive to the day row")

        // The regression guard. `sleepHrOnly` says "every session was staged from heart rate alone", and
        // that remains TRUE of this day — the change made the vitals available, not the staging better.
        XCTAssertEqual(res.daily.sleepHrOnly, true, "the day must still be marked HR-only")
    }
}
