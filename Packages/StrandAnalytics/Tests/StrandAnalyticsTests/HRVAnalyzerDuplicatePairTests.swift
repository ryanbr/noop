import XCTest
@testable import StrandAnalytics

/// #1505: measure how the two copies of a duplicated second COMPARE, not merely that there are two.
///
/// A WHOOP 5 emits the beat train live over `0x2A37` — spec-fixed 1/1024-second units, converted on the way
/// in — and again inside its v18 historical record, stored as read. If those are the same beat in two
/// units, a second written by two deliveries holds values 1024/1000 apart. If they are genuinely two beats,
/// the ratios scatter across normal beat-to-beat variability.
///
/// The field pair that raised the question, from #1451, is `-1s[872#0, 893#0]` — and 893 × 1000/1024 =
/// 872.07. That single pair cannot decide anything: 21 ms is also an ordinary difference between
/// consecutive beats. These pin that the measurement reports the distribution honestly in both directions,
/// so a night's worth of pairs can answer what one pair cannot.
///
/// Twin of Kotlin `DuplicatePairRatioTest`.
final class HRVAnalyzerDuplicatePairTests: XCTestCase {

    private let t0 = 1_780_000_000

    private func run(_ rows: [(Int, Double, Int?)]) -> String {
        HRVAnalyzer.duplicatePairRatios(
            tsSec: rows.map { $0.0 }, rrMs: rows.map { $0.1 }, ords: rows.map { $0.2 })
    }

    private func field(_ out: String, _ key: String) -> Int? {
        guard let r = out.range(of: "\(key)=") else { return nil }
        return Int(out[r.upperBound...].prefix { $0.isNumber })
    }

    /// The real #1451 pair: two deliveries, one second, values exactly the 1024/1000 ratio apart.
    func testTheFieldPairIsCountedAsATickSignature() {
        let out = run([(t0, 872.0, 0), (t0, 893.0, 0)])
        XCTAssertEqual(field(out, "n"), 1, out)
        XCTAssertEqual(field(out, "tick"), 1, out)
        XCTAssertEqual(field(out, "other"), 0, out)
        XCTAssertEqual(field(out, "medPPT"), 1024, out)
    }

    /// The honesty requirement: an ordinary pair of DIFFERENT beats must not read as a unit mismatch.
    func testAnOrdinaryBeatToBeatDifferenceIsNotATickSignature() {
        let out = run([(t0, 872.0, 0), (t0, 940.0, 0)])
        XCTAssertEqual(field(out, "tick"), 0, out)
        XCTAssertEqual(field(out, "other"), 1, out)
    }

    /// Two deliveries that stored the SAME number are exact duplicates, a different finding again.
    func testAnExactDuplicateIsCountedSeparately() {
        let out = run([(t0, 872.0, 0), (t0, 872.0, 0)])
        XCTAssertEqual(field(out, "same"), 1, out)
        XCTAssertEqual(field(out, "tick"), 0, out)
    }

    /// Two CONSECUTIVE beats from one record's array read `ord` 0 then 1 and must be excluded — they are
    /// one delivery, so comparing them measures physiology rather than transports.
    func testConsecutiveBeatsFromOneDeliveryAreExcluded() {
        XCTAssertEqual(run([(t0, 872.0, 0), (t0, 893.0, 1)]), "rr dupPairs n=0")
    }

    /// A second carrying more than two rows is ambiguous about which copy pairs with which — skip it.
    func testSecondsWithMoreThanTwoRowsAreSkipped() {
        XCTAssertEqual(run([(t0, 872.0, 0), (t0, 893.0, 0), (t0, 880.0, 0)]), "rr dupPairs n=0")
    }

    /// Rows with no `ord` (written before the column was surfaced) can't be attributed to a delivery.
    func testRowsWithoutAnOrdAreIgnored() {
        XCTAssertEqual(run([(t0, 872.0, nil), (t0, 893.0, nil)]), "rr dupPairs n=0")
    }

    /// The shape that would actually settle #1505: many pairs, all clustering at the ratio.
    func testAPopulationOfTickPairsReportsATightSpread() {
        var rows: [(Int, Double, Int?)] = []
        for i in 0 ..< 10 {
            let live = 850.0 + Double(i) * 7
            rows.append((t0 + i, live, 0))
            rows.append((t0 + i, live * 1024.0 / 1000.0, 0))   // the same beat, unconverted
        }
        let out = run(rows)
        XCTAssertEqual(field(out, "n"), 10, out)
        XCTAssertEqual(field(out, "tick"), 10, out)
    }

    /// ...and a population of genuinely different beats must NOT read as a cluster.
    func testAPopulationOfRealBeatsDoesNotReadAsTicks() {
        let second = [910.0, 845.0, 990.0, 870.0, 935.0, 820.0, 960.0, 885.0, 1015.0, 830.0]
        var rows: [(Int, Double, Int?)] = []
        for i in 0 ..< 10 {
            rows.append((t0 + i, 900.0, 0))
            rows.append((t0 + i, second[i], 0))
        }
        let out = run(rows)
        XCTAssertEqual(field(out, "n"), 10, out)
        XCTAssertLessThanOrEqual(field(out, "tick") ?? 99, 2, out)
    }

    /// Parity: the Kotlin twin must produce the SAME string for the same input, so a capture read on either
    /// platform is comparable. Pinned by value here and in `DuplicatePairRatioTest`.
    func testOutputStringIsPinnedForParity() {
        XCTAssertEqual(run([(t0, 872.0, 0), (t0, 893.0, 0)]),
                       "rr dupPairs n=1 same=0 tick=1 other=0 medPPT=1024 spread=1024-1024")
    }
}
