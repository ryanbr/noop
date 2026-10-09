import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// Oracle: unchanged Swift SleepStager at 8e94d559, compiled with the same fixtures. Kotlin twin:
// RhrOnePassTest. Includes closed endpoints, unordered duplicates, gaps and custom diagnostic gates.
final class RhrOnePassTests: XCTestCase {
    func testFloorsAndDiagnosticsMatchOriginalSwiftOracle() {
        let actual: String = rhrOnePassFixtures().map { name, start, end, rows, minN, minBpm in
            let floor = SleepStager.sessionRestingHR(start: start, end: end, hr: rows)
            let line = SleepStager.rhrBinGateLogLine(day: "synthetic", sessions: [(start, end)], hr: rows,
                                                  shippedFloor: floor ?? 0,
                                                  minBinSamples: minN, minPlausibleBpm: minBpm)
            return "\(name)|\(floor.map(String.init) ?? "nil")|\(line ?? "nil")"
        }.joined(separator: "\n")
        let expected: String = """
        empty|nil|nil
        reversed-span|nil|nil
        zero-span|58|nil
        aligned-end|60|nil
        next-aligned-end|40|nil
        negative-times|40|nil
        implausible|60|rhr bins day=synthetic bins=2 thin=0 implausible=1 winnerN=300 ungated=20 gated=60 shipped=60 gateMoved=true
        unsorted-duplicates|60|rhr bins day=synthetic bins=2 thin=0 implausible=1 winnerN=301 ungated=20 gated=60 shipped=60 gateMoved=true
        thin|60|rhr bins day=synthetic bins=2 thin=1 implausible=0 winnerN=1 ungated=30 gated=60 shipped=60 gateMoved=true
        custom-gate|30|nil
        round-half|60|nil
        tie-count|60|rhr bins day=synthetic bins=3 thin=2 implausible=0 winnerN=1 ungated=30 gated=60 shipped=60 gateMoved=true
        """
        XCTAssertEqual(actual, expected)
    }

    func testUnorderedDuplicateAndOverlappingSessionSweepMatchesOriginalSwiftDigest() {
        var digest: UInt32 = 2166136261
        for i in 0..<768 {
            for byte in rhrOnePassSweepRow(i).utf8 { digest = (digest ^ UInt32(byte)) &* 16777619 }
        }
        // Verbatim stdout of the unchanged Swift oracle over all 768 complete floor/diagnostic strings.
        XCTAssertEqual(String(format: "sweep768|%08x", digest), "sweep768|a9770363")
    }

    func testSparseLongSpanKeepsOnlyOccupiedBinsAndClosesItsEndpoint() {
        let end = 30 * 365 * 86400
        let rows = [HRSample(ts: end, bpm: 40), HRSample(ts: 0, bpm: 80),
                    HRSample(ts: end - 1, bpm: 60), HRSample(ts: end + 1, bpm: 1)]
        let bins = SleepStager.restingHRBins(start: 0, end: end, hr: rows)
        XCTAssertEqual(bins.map { $0.sum }, [80, 100])
        XCTAssertEqual(bins.map { $0.count }, [1, 2])
        XCTAssertEqual(SleepStager.sessionRestingHR(start: 0, end: end, hr: rows), 50)
    }
}

private func rhrOnePassFixtures() -> [(String, Int, Int, [HRSample], Int, Double)] {
    let rows = (0..<600).map { HRSample(ts: 1_000 + $0, bpm: $0 < 300 ? 60 : 20) }
    return [
        ("empty", 0, 600, [], 5, 25),
        ("reversed-span", 600, 0, [HRSample(ts: 300, bpm: 50)], 5, 25),
        ("zero-span", 1000, 1000, [HRSample(ts: 1000, bpm: 58)], 5, 25),
        ("aligned-end", 0, 300, [HRSample(ts: 0, bpm: 80), HRSample(ts: 300, bpm: 40)], 5, 25),
        ("next-aligned-end", 0, 600, [HRSample(ts: 0, bpm: 80), HRSample(ts: 300, bpm: 60), HRSample(ts: 600, bpm: 20)], 5, 25),
        ("negative-times", -600, 0, [HRSample(ts: -601, bpm: 0), HRSample(ts: -600, bpm: 80), HRSample(ts: -300, bpm: 60), HRSample(ts: 0, bpm: 20), HRSample(ts: 1, bpm: 0)], 5, 25),
        ("implausible", 1000, 1600, rows, 5, 25),
        ("unsorted-duplicates", 1000, 1600, Array(rows.reversed()) + [HRSample(ts: 1000, bpm: 60), HRSample(ts: 1600, bpm: 20)], 5, 25),
        ("thin", 1000, 1900, rows.filter { $0.ts < 1300 } + [HRSample(ts: 1800, bpm: 30)], 5, 25),
        ("custom-gate", 0, 600, (0..<7).map { HRSample(ts: $0, bpm: 30) } + (0..<8).map { HRSample(ts: 300 + $0, bpm: 60) }, 8, 35),
        ("round-half", 0, 301, [HRSample(ts: 0, bpm: 60), HRSample(ts: 300, bpm: 60), HRSample(ts: 301, bpm: 61)], 5, 25),
        ("tie-count", 0, 900, [HRSample(ts: 0, bpm: 30), HRSample(ts: 300, bpm: 30), HRSample(ts: 301, bpm: 30)] + (0..<5).map { HRSample(ts: 600 + $0, bpm: 60) }, 5, 25)
    ]
}
private func rhrOnePassSweepRow(_ i: Int) -> String {
    let spans = [-1, 0, 1, 299, 300, 301, 599, 600, 601, 899, 900, 1201]
    let start = (i % 3 - 1) * 1000, end = start + spans[i % spans.count]
    var rows = (0..<(i % 83)).map { j in
        HRSample(ts: start + ((j * 137 + i * 17) % 1800) - 300, bpm: (j * 31 + i * 7) % 121)
    }
    rows += [HRSample(ts: start, bpm: 60), HRSample(ts: end, bpm: 20), HRSample(ts: end, bpm: 20)]
    if i % 2 == 0 { rows.reverse() }
    let floor = SleepStager.sessionRestingHR(start: start, end: end, hr: rows)
    let line = SleepStager.rhrBinGateLogLine(day: "synthetic", sessions: [(start, end), (start + 300, end + 300)],
                                          hr: rows, shippedFloor: floor ?? 0,
                                          minBinSamples: 1 + i % 9, minPlausibleBpm: Double(20 + i % 20))
    return "\(i)|\(floor.map(String.init) ?? "nil")|\(line ?? "nil")\n"
}
