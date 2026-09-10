import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #1943 conformance check: the line reports when the gate MOVED the floor by comparing the UNGATED
/// floor (the old rule: min over every non-empty bin) against the shipped one (which IS the gated
/// floor). The line fires when the gate excluded the bin that would otherwise have won — which is
/// the frequency and magnitude the measure-only diagnostic was meant to learn. Byte-parity twin of
/// Kotlin `RhrBinGateDiagnosticTest`.
final class RhrBinGateDiagnosticTests: XCTestCase {

    private func hr(_ start: Int, _ count: Int, _ bpm: Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// A dense, ordinary night: every bin well-populated, so the gate moves nothing. Silent.
    func testAWellPopulatedNightSaysNothing() {
        let start = 1_000, end = 1_000 + 1800
        XCTAssertNil(SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(start, end)],
                                                   hr: hr(start, 1800, 60), shippedFloor: 60))
    }

    /// A one-sample bin that WINS under the old rule is the whole point: the gate excludes it, so
    /// the ungated floor (38) differs from the shipped/gated floor (60), and the line fires.
    func testAThinWinningBinIsReportedAsGateMoved() {
        let start = 1_000, end = 1_000 + 1800
        let samples = hr(start, 1500, 60) + [HRSample(ts: start + 1700, bpm: 38)]
        // shippedFloor is 60 — the gated floor that sessionRestingHR now ships.
        let line = SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(start, end)],
                                                 hr: samples, shippedFloor: 60)
        XCTAssertNotNil(line, "a thin winning bin must be reported")
        XCTAssertTrue(line!.contains("thin=1"), line!)
        XCTAssertTrue(line!.contains("winnerN=1"), line!)
        XCTAssertTrue(line!.contains("ungated=38"), line!)
        XCTAssertTrue(line!.contains("gated=60"), line!)
        XCTAssertTrue(line!.contains("shipped=60"), line!)
        XCTAssertTrue(line!.contains("gateMoved=true"), line!)
    }

    /// A thin bin that cannot win the floor even under the old rule is silent: the ungated floor
    /// matches the shipped one, so the gate moved nothing.
    func testAThinBinThatCannotWinTheFloorIsSilent() {
        let start = 1_000, end = 1_000 + 1800
        let samples = hr(start, 1500, 60) + [HRSample(ts: start + 1700, bpm: 90)]
        XCTAssertNil(SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(start, end)],
                                                   hr: samples, shippedFloor: 60))
    }

    /// No sleep sessions, or no samples inside them, is not a finding.
    func testNothingToMeasureIsSilent() {
        XCTAssertNil(SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [],
                                                   hr: hr(1_000, 100, 60), shippedFloor: 60))
        XCTAssertNil(SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(9_000, 9_900)],
                                                   hr: hr(1_000, 100, 60), shippedFloor: 60))
    }

    /// It carries counts and bpm only: no timestamps, so a shared strap log gains no new identifiers.
    func testTheLineCarriesNoTimestamps() {
        let start = 1_700_000_000, end = 1_700_000_000 + 1800
        let samples = hr(start, 1500, 60) + [HRSample(ts: start + 1700, bpm: 38)]
        let line = SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(start, end)],
                                                 hr: samples, shippedFloor: 60)
        XCTAssertNotNil(line)
        XCTAssertFalse(line!.contains("17000000"), line!)
    }

    /// The load-bearing invariant: the line must judge the SAME partition `sessionRestingHR` ships.
    /// Here the shipped floor comes FROM `sessionRestingHR`, and the gate agrees, so the ungated
    /// floor matches the shipped one and the line stays silent. The 1801 span is deliberate: its
    /// final bin holds two samples, structurally thin.
    func testTheDiagnosticJudgesTheSamePartitionSessionRestingHRShips() {
        let start = 1_000
        for spanS in [1800, 1801, 1500, 300, 299] {
            let end = start + spanS
            let samples = (0..<spanS).map {
                HRSample(ts: start + $0, bpm: (600...899).contains($0) ? 55 : 65)
            }
            let shipped = SleepStager.sessionRestingHR(start: start, end: end, hr: samples)
            XCTAssertNotNil(shipped, "precondition: a floor exists for span \(spanS)")
            XCTAssertNil(
                SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(start, end)],
                                              hr: samples, shippedFloor: shipped!),
                "span \(spanS): the gate must agree with sessionRestingHR, so the line stays silent")
        }
    }
}
