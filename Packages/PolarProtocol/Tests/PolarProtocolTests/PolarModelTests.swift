import XCTest
@testable import PolarProtocol

/// Polar model identification + PMD stream capabilities (`PolarModel`). Public-fact catalog; the
/// cross-platform contract mirrored by `com.noop.polar.PolarModel`.
final class PolarModelTests: XCTestCase {

    func testIdentifyFromAdvertisedName() {
        XCTAssertEqual(PolarModel.from(advertisedName: "Polar H10 A1B2C3D4"), .h10)
        XCTAssertEqual(PolarModel.from(advertisedName: "Polar H9 11223344"), .h9)
        XCTAssertEqual(PolarModel.from(advertisedName: "Polar OH1 55667788"), .oh1)
        // Verity Sense advertises "Polar Sense …", never "Verity".
        XCTAssertEqual(PolarModel.from(advertisedName: "Polar Sense 99AABBCC"), .veritySense)
        XCTAssertEqual(PolarModel.from(advertisedName: "polar h10 lowercase"), .h10)   // case-insensitive
    }

    func testUnknownAndNonPolarResolveToUnknown() {
        XCTAssertEqual(PolarModel.from(advertisedName: "Wahoo TICKR"), .unknown)
        XCTAssertEqual(PolarModel.from(advertisedName: "Polar Grit X"), .unknown)      // real, but no PMD catalog entry yet
        XCTAssertEqual(PolarModel.from(advertisedName: nil), .unknown)
        XCTAssertEqual(PolarModel.from(advertisedName: ""), .unknown)
    }

    func testPmdStreamsPerModel() {
        XCTAssertEqual(PolarModel.h10.pmdStreams, [.ecg, .acc])
        XCTAssertEqual(PolarModel.h9.pmdStreams, [])
        XCTAssertEqual(PolarModel.oh1.pmdStreams, [.ppg, .ppi, .acc])
        XCTAssertEqual(PolarModel.veritySense.pmdStreams, [.ppg, .ppi, .acc, .gyro])
        // OH1 has no gyroscope; Verity Sense does — the one place they diverge.
        XCTAssertFalse(PolarModel.oh1.pmdStreams.contains(.gyro))
        XCTAssertTrue(PolarModel.veritySense.pmdStreams.contains(.gyro))
    }

    func testHrvPmdStreamPicksPpiOnlyWhereExposed() {
        XCTAssertEqual(PolarModel.veritySense.hrvPmdStream, .ppi)
        XCTAssertEqual(PolarModel.oh1.hrvPmdStream, .ppi)
        // H10 / H9 carry R-R on the standard HR service — no PMD PPI stream, so nil (not a guess).
        XCTAssertNil(PolarModel.h10.hrvPmdStream)
        XCTAssertNil(PolarModel.h9.hrvPmdStream)
        XCTAssertNil(PolarModel.unknown.hrvPmdStream)
    }

    func testSerialContainingModelTokenDoesNotMisidentify() {
        // The matcher anchors on the model position, not a whole-name substring: an OH1 whose serial
        // happens to contain "h10" must stay an OH1 (a `contains` matcher wrongly returned .h10 here).
        XCTAssertEqual(PolarModel.from(advertisedName: "Polar OH1 H10ABCDE"), .oh1)
    }
}
