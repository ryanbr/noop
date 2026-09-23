import XCTest
@testable import OuraProtocol

/// `OuraSpO2Channel` is the one resolver that says what an SpO2 sample's number IS. It exists because
/// the strap log used to print a 0x77 perfusion magnitude and a 0x6F percentage under the same words,
/// on the same ring, minutes apart. These tests pin the two things that made that possible: the unit
/// tags the decoders actually stamp, and the resolver's disposition for each.
final class OuraSpO2ChannelTests: XCTestCase {

    // MARK: - The resolver itself

    func testPerfusionUnitResolvesToPerfusion() {
        XCTAssertEqual(OuraSpO2Channel.forUnit("dc_raw"), .perfusion)
        XCTAssertEqual(OuraSpO2Channel.perfusionUnit, "dc_raw")
    }

    func testPercentageUnitResolvesToPercentage() {
        XCTAssertEqual(OuraSpO2Channel.forUnit("raw"), .percentage)
    }

    /// Both known tags match EXACTLY; anything else is `.unknown`. Treating "not perfusion" as a
    /// percentage would print a case variant or a future tag's magnitude with a `%` on it — the defect
    /// this type exists to stop, in a new costume.
    func testUnknownUnitIsUnknownNotAPercentage() {
        XCTAssertEqual(OuraSpO2Channel.forUnit("raw_adc"), .unknown)
        XCTAssertEqual(OuraSpO2Channel.forUnit(""), .unknown)
        XCTAssertEqual(OuraSpO2Channel.forUnit("DC_RAW"), .unknown)   // case-sensitive, like the tag
        XCTAssertEqual(OuraSpO2Channel.forUnit("RAW"), .unknown)
        XCTAssertEqual(OuraSpO2Channel.percentageUnit, "raw")
    }

    /// An unknown channel names its tag and never carries a `%`.
    func testUnknownChannelLineHasNoPercentSign() {
        let line = OuraSpO2Channel.firstDecodedLogLine(value: 3, unit: "DC_RAW")
        XCTAssertEqual(line,
                       #"first SpO2 sample on an unrecognised channel (NOT known to be a percentage) decoded (last night) - 3 (channel "DC_RAW")"#)
        XCTAssertFalse(line.contains("%"), line)
    }

    func testSampleAccessorMatchesTheResolver() {
        let pct = OuraSpO2(ringTimestamp: 1, value: 93)
        let dc = OuraSpO2(ringTimestamp: 1, value: 101_144, unit: "dc_raw")
        XCTAssertEqual(pct.channel, .percentage)
        XCTAssertEqual(dc.channel, .perfusion)
    }

    // MARK: - The log line

    /// The exact strings a reader will see. Pinned here so a rename on THIS side is a failing test
    /// rather than a silent divergence from `OuraSpO2ChannelOracleTest`, whose literals are this
    /// function's own stdout. The two directions together are what stop either platform drifting.
    func testFirstDecodedLogLineText() {
        XCTAssertEqual(OuraSpO2Channel.firstDecodedLogLine(value: 93, unit: "raw"),
                       #"first SpO2 percentage decoded (last night) - 93 % (channel "raw")"#)
        XCTAssertEqual(OuraSpO2Channel.firstDecodedLogLine(value: 101_144, unit: "dc_raw"),
                       #"first SpO2 raw DC perfusion (NOT a percentage) decoded (last night) - 101144 (channel "dc_raw")"#)
    }

    /// A negative perfusion magnitude is real (the 0x77 accumulator goes below zero) and must not pick
    /// up a `%`. This is the original defect in its most misleading form: `-288 %`.
    func testNegativePerfusionNeverGetsAPercentSign() {
        let line = OuraSpO2Channel.firstDecodedLogLine(value: -288, unit: "dc_raw")
        XCTAssertFalse(line.contains("%"), line)
        XCTAssertTrue(line.contains("NOT a percentage"), line)
    }

    /// The percentage channel keeps its unit tag in the text, so a log still ties back to the decoder
    /// even though the words no longer repeat the tag.
    func testPercentageLineStillNamesItsUnitTag() {
        XCTAssertTrue(OuraSpO2Channel.firstDecodedLogLine(value: 95, unit: "raw").contains(#"channel "raw""#))
    }

    // MARK: - The decoders really do stamp those tags

    /// Without this the resolver could be right about strings nothing produces. 0x6F yields the
    /// percentage channel; 0x77 yields perfusion. Both are fed real-shaped bodies, not hand-set units.
    func testDecodedSpO2PerSampleIsThePercentageChannel() throws {
        let rec = OuraRecord(type: 0x6F, ringTimestamp: 100, payload: [0x00, 95, 96, 97])
        let out = try XCTUnwrap(OuraDecoders.decodeSpO2PerSample(rec))
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.channel == .percentage }, "0x6F must read as a percentage")
    }

    func testDecodedSpO2DCIsThePerfusionChannel() throws {
        // hasBase (bit 6) + a 24-bit LE base, then one sign-magnitude delta.
        let rec = OuraRecord(type: 0x77, ringTimestamp: 100,
                             payload: [0x40, 0x2C, 0xA0, 0x00, 0x05])
        let out = try XCTUnwrap(OuraDecoders.decodeSpO2DC(rec))
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0.channel == .perfusion }, "0x77 must read as perfusion")
        // And the magnitudes really are the three-orders-of-magnitude-apart kind that started this.
        XCTAssertGreaterThan(out[0].value, 100, "a perfusion base is not a percentage")
    }

    /// 0x7B carries a single BIG-endian value and takes the default unit, so it is a percentage too.
    func testDecodedSpO2StableIsThePercentageChannel() throws {
        let rec = OuraRecord(type: 0x7B, ringTimestamp: 100, payload: [0x00, 0x60])
        let s = try XCTUnwrap(OuraDecoders.decodeSpO2Stable(rec))
        XCTAssertEqual(s.channel, .percentage)
    }
}
