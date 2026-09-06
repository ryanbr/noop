import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #1943 measure-only: the line must describe the partition `sessionRestingHR` actually uses, and must
/// stay silent unless an artefact gate would MOVE the floor. Byte-parity twin of Kotlin
/// `RhrBinGateDiagnosticTest`.
final class RhrBinGateDiagnosticTests: XCTestCase {

    private func hr(_ start: Int, _ count: Int, _ bpm: Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    /// A dense, ordinary night: every bin well-populated, so the gate would change nothing. Silent.
    func testAWellPopulatedNightSaysNothing() {
        let start = 1_000, end = 1_000 + 1800
        XCTAssertNil(SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(start, end)],
                                                   hr: hr(start, 1800, 60), shippedFloor: 60))
    }

    /// A one-sample bin that WINS the floor is the whole point: it must be reported, and named.
    func testAThinWinningBinIsReportedWithWhatTheGateWouldDo() {
        let start = 1_000, end = 1_000 + 1800
        let samples = hr(start, 1500, 60) + [HRSample(ts: start + 1700, bpm: 38)]
        let line = SleepStager.rhrBinGateLogLine(day: "2026-01-01", sessions: [(start, end)],
                                                 hr: samples, shippedFloor: 38)
        XCTAssertNotNil(line, "a thin winning bin must be reported")
        XCTAssertTrue(line!.contains("thin=1"), line!)
        XCTAssertTrue(line!.contains("winnerN=1"), line!)
        XCTAssertTrue(line!.contains("wouldChange=true"), line!)
        XCTAssertTrue(line!.contains("gated=60"), line!)
    }

    /// A thin bin that cannot win the floor is silent: a thin FINAL bin is structural on most spans.
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
                                                 hr: samples, shippedFloor: 38)
        XCTAssertNotNil(line)
        XCTAssertFalse(line!.contains("17000000"), line!)
    }

    /// The load-bearing invariant: the line must judge the SAME partition `sessionRestingHR` ships.
    /// Every other case hands the floor in as a literal, so none would notice the two binnings drifting.
    /// Here the shipped floor comes FROM `sessionRestingHR`, and a mismatch surfaces as a spurious
    /// `wouldChange`. The 1801 span is deliberate: its final bin holds two samples, structurally thin.
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
