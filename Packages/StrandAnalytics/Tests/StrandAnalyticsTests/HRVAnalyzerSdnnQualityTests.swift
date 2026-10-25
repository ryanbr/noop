import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HRVAnalyzerSdnnQualityTests: XCTestCase {
    private func sdnnQualityFixtureRows(offset: Int = 0) -> [RRInterval] {
        (0..<300).map { RRInterval(ts: offset + $0, rrMs: 1000 + ($0 % 4) * 10) }
    }

    func testCleanSegmentKeepsItsSampleSdnn() throws {
        let value = try XCTUnwrap(HRVAnalyzer.sdnnIndex(sdnnQualityFixtureRows()))
        XCTAssertEqual(value, 11.199020501841618, accuracy: 1e-12)
    }

    func testDuplicateDeliveriesCannotSupplyDailySdnn() {
        let duplicated = sdnnQualityFixtureRows().flatMap { [$0, $0] }
        XCTAssertNil(HRVAnalyzer.sdnnIndex(duplicated))
        // Actual Swift stdout is also pinned verbatim in HrvAnalyzerSdnnQualityTest. Compare the
        // Double bit patterns so a tolerance cannot conceal different stored values across platforms.
        let clean = sdnnQualityFixtureRows()
        let banked = clean.enumerated().map {
            RRInterval(ts: ($0.offset / 6) * 6, rrMs: $0.element.rrMs)
        }
        let badLater = sdnnQualityFixtureRows(offset: 300).flatMap { [$0, $0] }
        let cases: [(String, [RRInterval])] = [
            ("clean", clean), ("duplicate", duplicated), ("banked", banked),
            ("mixed", clean + badLater), ("offset", sdnnQualityFixtureRows(offset: 1_700_000_000)),
            ("reversed", Array(clean.reversed())), ("tooFew", Array(clean.prefix(19))), ("empty", [])
        ]
        let actual: String = cases.map { name, rows in
            let bits = HRVAnalyzer.sdnnIndex(rows).map { String($0.bitPattern, radix: 16) } ?? "nil"
            return "\(name)=\(bits)"
        }.joined(separator: "\n")
        XCTAssertEqual(actual, """
        clean=402665e603e54959
        duplicate=nil
        banked=nil
        mixed=402665e603e54959
        offset=402665e603e54959
        reversed=402665e603e54959
        tooFew=nil
        empty=nil
        """)
    }

    func testBankedIntervalsCannotSupplyDailySdnn() {
        let banked = sdnnQualityFixtureRows().enumerated().map {
            RRInterval(ts: ($0.offset / 6) * 6, rrMs: $0.element.rrMs)
        }
        XCTAssertNil(HRVAnalyzer.sdnnIndex(banked))
    }

    func testRefusedSegmentDoesNotDiscardCleanSegment() throws {
        let clean = sdnnQualityFixtureRows()
        let bad = sdnnQualityFixtureRows(offset: 300).flatMap { [$0, $0] }
        let value = try XCTUnwrap(HRVAnalyzer.sdnnIndex(clean + bad))
        XCTAssertEqual(value, 11.199020501841618, accuracy: 1e-12)
    }
}
