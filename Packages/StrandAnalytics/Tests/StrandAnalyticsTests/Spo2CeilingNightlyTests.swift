import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Queue 11a — the Oura twin of `Spo2CandidateNightlyTests`: nightly ceiling@100 mean of the ring's own
/// decoded `0x6F` SpO2 (`spo2Sample.red`), the starting candidate transform for the Blood Oxygen tile's
/// Oura fallback. Pins the ceiling (per-sample, before averaging), the contamination floor gate, and the
/// session-window filter — the three things that make this an honest "strap estimate," not raw wire.
final class Spo2CeilingNightlyTests: XCTestCase {

    private func session(_ start: Int, _ durSec: Int) -> SleepSession {
        SleepSession(start: start, end: start + durSec, efficiency: 0.9,
                     stages: [], restingHR: 50, avgHRV: 60)
    }

    private func spo2(_ ts: Int, _ red: Int) -> SpO2Sample { SpO2Sample(ts: ts, red: red, ir: 0, unit: "raw") }

    func testMeanAndSampleCountOverTheSession() {
        let r = AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)], spo2: [spo2(1100, 94), spo2(1200, 96), spo2(1300, 95)])
        XCTAssertEqual(r?.mean, 95)
        XCTAssertEqual(r?.samples, 3)
    }

    /// The whole point of "ceiling@100": a sample above 100 counts as 100, not itself — so a night with a
    /// real overshoot doesn't drag the mean above the physical ceiling the way the raw wire mean does
    /// (OURA_PROTOCOL.md §6.5.0.1's documented positive bias).
    func testSamplesAboveOneHundredAreCeilingedBeforeAveraging() {
        let r = AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)], spo2: [spo2(1100, 104), spo2(1200, 100)])
        XCTAssertEqual(r?.mean, 100, "both readings ceiling to 100, not (104+100)/2=102")
    }

    /// Mis-scaled `dc_raw`/perfusion-channel contamination (-1016 … 11,709,098, OURA_PROTOCOL.md §6.5.0.1)
    /// must not drag the mean down — the ceiling alone only guards the TOP of the range, so the floor gate
    /// is load-bearing here, unlike the WHOOP @82 path (whose decoder already only ever emits 70...100).
    func testContaminatedOutOfRangeSamplesAreExcluded() {
        let r = AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)],
            spo2: [spo2(1100, 96), spo2(1150, -1016), spo2(1200, 11_709_098), spo2(1300, 98)])
        XCTAssertEqual(r?.mean, 97, "only the two plausible readings may count")
        XCTAssertEqual(r?.samples, 2)
    }

    func testDaytimeSamplesOutsideTheSessionAreExcluded() {
        let r = AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)], spo2: [spo2(500, 99), spo2(1100, 94), spo2(5000, 88)])
        XCTAssertEqual(r?.samples, 1)
        XCTAssertEqual(r?.mean, 94)
    }

    func testNilWhenNothingPlausibleFallsInsideASession() {
        XCTAssertNil(AnalyticsEngine.nightlySpo2CeilingMean([session(1000, 600)], spo2: [spo2(1100, -1016)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CeilingMean([session(1000, 600)], spo2: [spo2(9999, 95)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CeilingMean([], spo2: [spo2(1100, 95)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CeilingMean([session(1000, 600)], spo2: []))
    }

    /// Found 2026-08-24 comparing a live-persisted row against the Oura app: `sum / kept` on two `Int`s
    /// truncates toward zero, so a true 97.97 shipped as 97 — a spurious miss against an app-displayed
    /// 98% the precise mean would have round-matched. Three samples averaging 97.666... must round to
    /// 98, not floor to 97.
    func testMeanRoundsRatherThanFloors() {
        let r = AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)], spo2: [spo2(1100, 98), spo2(1200, 98), spo2(1300, 97)])
        XCTAssertEqual(r?.mean, 98, "97.666... must round to 98, not floor to 97")
    }

    /// The plausibility floor/ceiling are inclusive, matching `spo2SingleChannelPlausible` (50...110)
    /// exactly — the same bounds `Repository.spo2SingleChannelPlausible` derives from this constant.
    func testPlausibleRangeBoundariesAreInclusive() {
        XCTAssertEqual(AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)], spo2: [spo2(1100, 50), spo2(1200, 110)])?.samples, 2)
        XCTAssertNil(AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)], spo2: [spo2(1100, 49)]))
        XCTAssertNil(AnalyticsEngine.nightlySpo2CeilingMean(
            [session(1000, 600)], spo2: [spo2(1100, 111)]))
    }
}
