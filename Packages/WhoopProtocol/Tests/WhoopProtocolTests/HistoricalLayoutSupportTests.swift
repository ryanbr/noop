import XCTest
@testable import WhoopProtocol

final class HistoricalLayoutSupportTests: XCTestCase {

    /// The regression guard the old form did not have. Every layout the 5/MG decoder dispatches on must be
    /// reported as MAPPED, whatever field names its decode happens to produce. This is what #156 needed and
    /// did not get, so v25/v26 kept warning; and what v20 needed and did not get, so the optical record has
    /// warned ever since it was mapped. Driven off the dispatch set itself, so a layout added there without
    /// a signature field cannot reintroduce the bug.
    func testEveryMappedWhoop5LayoutIsReportedAsDecodable() {
        for v in mappedWhoop5HistoricalVersions {
            XCTAssertFalse(
                historicalLayoutIsUnmapped(version: v, family: .whoop5, hasHeartRate: false,
                                           hasGravity: false, hasPpgWaveform: false),
                "layout v\(v) is in mappedWhoop5HistoricalVersions but reports as undecodable")
        }
    }

    /// v20 by name, because it is the one this change is about: the 5/MG optical record decodes to block
    /// counts and per-block headers, never to heart rate, gravity or a PPG waveform.
    func testTheOpticalLayoutIsNotReportedAsUndecodableForCarryingNoNamedSignal() {
        XCTAssertTrue(mappedWhoop5HistoricalVersions.contains(20))
        XCTAssertFalse(historicalLayoutIsUnmapped(version: 20, family: .whoop5, hasHeartRate: false,
                                                  hasGravity: false, hasPpgWaveform: false))
    }

    /// A version nothing dispatches on is still reported, which is the whole point of the warning.
    func testAnUnknownWhoop5LayoutIsStillReported() {
        let unknown = (1...255).first { !mappedWhoop5HistoricalVersions.contains($0) }!
        XCTAssertTrue(historicalLayoutIsUnmapped(version: unknown, family: .whoop5, hasHeartRate: false,
                                                 hasGravity: false, hasPpgWaveform: false))
        // ...and a decoded field does NOT rescue it on the 5/MG side. The dispatch set is the authority
        // there, so a record that decoded a plausible-looking value under an unmapped version is exactly
        // the "it holds by accident" case the set exists to refuse.
        XCTAssertTrue(historicalLayoutIsUnmapped(version: unknown, family: .whoop5, hasHeartRate: true,
                                                 hasGravity: true, hasPpgWaveform: true))
    }

    /// WHOOP 4.0 keeps the field test: any one of the three names means the layout decoded something.
    func testWhoop4IsJudgedByWhatItDecoded() {
        XCTAssertTrue(historicalLayoutIsUnmapped(version: 19, family: .whoop4, hasHeartRate: false,
                                                 hasGravity: false, hasPpgWaveform: false))
        for (hr, grav, ppg) in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertFalse(historicalLayoutIsUnmapped(version: 25, family: .whoop4, hasHeartRate: hr,
                                                      hasGravity: grav, hasPpgWaveform: ppg))
        }
    }

    // MARK: - offloadFrontier

    /// The safety claim: the consumed marker can only ever CLOSE a gap. Whichever of the two is later wins,
    /// so a strap with genuine backlog keeps its gap and a strap whose tail merely failed to decode loses it.
    func testTheFrontierTakesTheLaterOfTheTwoAndNeverGoesBackwards() {
        XCTAssertEqual(offloadFrontier(rowFrontier: 1_000, consumedTo: 2_000), 2_000)
        XCTAssertEqual(offloadFrontier(rowFrontier: 2_000, consumedTo: 1_000), 2_000)
        XCTAssertEqual(offloadFrontier(rowFrontier: 2_000, consumedTo: 2_000), 2_000)
    }

    /// Either half absent is the other half's answer, and both absent is still "unknown" rather than a
    /// fabricated zero. A zero frontier against a real `strapNewest` would read as an enormous backlog.
    func testAnAbsentHalfDoesNotBecomeZero() {
        XCTAssertEqual(offloadFrontier(rowFrontier: nil, consumedTo: 1_700_000_000), 1_700_000_000)
        XCTAssertEqual(offloadFrontier(rowFrontier: 1_700_000_000, consumedTo: nil), 1_700_000_000)
        XCTAssertNil(offloadFrontier(rowFrontier: nil, consumedTo: nil))
    }
}
