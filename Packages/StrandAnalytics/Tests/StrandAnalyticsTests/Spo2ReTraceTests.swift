import XCTest
@testable import StrandAnalytics

/// Pins the Connection-mode SpO2 reverse-engineering dump line (PR #945, reimplemented). The output must
/// be byte-identical to the Kotlin Spo2ReTraceTest vectors so a shared log correlates identically from
/// either platform. Log-only diagnostics: nothing here ever becomes a user-facing SpO2 number.
final class Spo2ReTraceTests: XCTestCase {

    func testRecordLinePinnedExactly() {
        let line = Spo2ReTrace.recordLine(frame: [0x00, 0x0f, 0xff, 0x10],
                                          version: 24, unix: 1_700_000_000,
                                          red: 512, ir: 480, skinRaw: 330)
        XCTAssertEqual(line,
                       "spo2re v=24 unix=1700000000 red=512 ir=480 skinRaw=330 len=4 raw=000fff10")
    }

    func testAbsentChannelsRenderNull() {
        // A record with no SpO2 channels mapped (e.g. a v25 motion record) must still dump in full -
        // proving "nothing banked" needs the negative case on the record itself.
        let line = Spo2ReTrace.recordLine(frame: [1, 2, 3], version: 25, unix: 42,
                                          red: nil, ir: nil, skinRaw: nil)
        XCTAssertEqual(line, "spo2re v=25 unix=42 red=null ir=null skinRaw=null len=3 raw=010203")
    }

    func testHexRendersUnsignedFullFrame() {
        // 0xFF must render "ff" (unsigned, two lowercase hex digits), and the FULL frame ships - the
        // unmapped tail bytes are exactly where a banked SpO2 would sit.
        let line = Spo2ReTrace.recordLine(frame: [0xff, 0x00, 0xab], version: nil, unix: nil,
                                          red: nil, ir: nil, skinRaw: nil)
        XCTAssertTrue(line.hasSuffix("raw=ff00ab"), line)
        XCTAssertTrue(line.contains("v=null"), line)
    }

    func testSampleCapBounded() {
        XCTAssertEqual(Spo2ReTrace.maxSamples, 12)
    }

    /// The per-layout cap is what stops one dominant layout spending the whole session budget, and it
    /// only does that if it is strictly smaller than the session cap.
    func testPerVersionCapIsBoundedAndSmallerThanTheSessionCap() {
        XCTAssertEqual(Spo2ReTrace.maxPerVersion, 3)
        XCTAssertLessThan(Spo2ReTrace.maxPerVersion, Spo2ReTrace.maxSamples)
    }

    /// The session cap has to leave room for more than one layout, or stratifying changes nothing:
    /// a 5/MG emits v18 alongside v20/v21/v26 and every one of them needs samples.
    func testSessionCapCoversSeveralDistinctLayouts() {
        XCTAssertGreaterThanOrEqual(Spo2ReTrace.maxSamples / Spo2ReTrace.maxPerVersion, 4)
    }
}
