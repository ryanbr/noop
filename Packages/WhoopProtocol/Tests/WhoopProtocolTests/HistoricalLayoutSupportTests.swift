import XCTest
@testable import WhoopProtocol

final class HistoricalLayoutSupportTests: XCTestCase {

    /// The regression guard the old form did not have. No layout the 5/MG decoder dispatches on may be
    /// called UNMAPPED, whatever field names its decode happens to produce. This is what #156 needed and
    /// did not get, so v25/v26 kept warning; and what v20 needed and did not get. Driven off the dispatch
    /// set itself, so a layout added there without a signature field cannot reintroduce the bug.
    func testNoMappedWhoop5LayoutIsEverCalledUnmapped() {
        for v in mappedWhoop5HistoricalVersions {
            XCTAssertNotEqual(
                historicalLayoutSupport(version: v, family: .whoop5, hasHeartRate: false,
                                        hasGravity: false, hasPpgWaveform: false),
                .unmapped,
                "layout v\(v) is in mappedWhoop5HistoricalVersions but reports as unmapped")
        }
    }

    /// v20 by name. It decodes, and it still cannot stage a night, and those are different sentences. The
    /// first version of this change suppressed the line entirely for v20, which would have dropped the
    /// true half and left a user with unstaged nights and nothing in the log saying why.
    func testTheOpticalLayoutDecodesButStillCannotStageANight() {
        XCTAssertTrue(mappedWhoop5HistoricalVersions.contains(20))
        XCTAssertEqual(
            historicalLayoutSupport(version: 20, family: .whoop5, hasHeartRate: false,
                                    hasGravity: false, hasPpgWaveform: false),
            .decodesWithoutNamedSignal)
    }

    /// A mapped layout that DOES carry a named signal is simply fine, and says nothing at all.
    func testAMappedLayoutCarryingASignalIsSupported() {
        for (hr, grav, ppg) in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertEqual(
                historicalLayoutSupport(version: 18, family: .whoop5, hasHeartRate: hr,
                                        hasGravity: grav, hasPpgWaveform: ppg),
                .supported)
        }
    }

    /// A version nothing dispatches on is unmapped, and a decoded field does not rescue it: on the 5/MG
    /// side the dispatch set is the authority, so a plausible-looking value under an unmapped version is
    /// exactly the "it holds by accident" case that set exists to refuse.
    func testAnUnknownWhoop5LayoutIsUnmappedWhateverItDecoded() {
        let unknown = (1...255).first { !mappedWhoop5HistoricalVersions.contains($0) }!
        XCTAssertEqual(
            historicalLayoutSupport(version: unknown, family: .whoop5, hasHeartRate: false,
                                    hasGravity: false, hasPpgWaveform: false), .unmapped)
        XCTAssertEqual(
            historicalLayoutSupport(version: unknown, family: .whoop5, hasHeartRate: true,
                                    hasGravity: true, hasPpgWaveform: true), .unmapped)
    }

    /// WHOOP 4.0 is judged by what it decoded, exactly as before: it has no dispatch set to ask, and every
    /// layout it maps emits one of the three names.
    func testWhoop4IsStillJudgedByWhatItDecoded() {
        XCTAssertEqual(
            historicalLayoutSupport(version: 19, family: .whoop4, hasHeartRate: false,
                                    hasGravity: false, hasPpgWaveform: false), .unmapped)
        for (hr, grav, ppg) in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertEqual(
                historicalLayoutSupport(version: 25, family: .whoop4, hasHeartRate: hr,
                                        hasGravity: grav, hasPpgWaveform: ppg), .supported)
        }
    }
}
