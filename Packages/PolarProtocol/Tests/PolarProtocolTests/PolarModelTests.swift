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

    // MARK: - Debug identification (Test Centre / strap-log diagnostics)

    func testIsPolarSeparatesPolarFromUnrecognisedAndForeign() {
        // A Polar device we can't name yet is still a Polar device (unlike `from`, which collapses both to
        // .unknown) — so the Polar-only diagnostics fire for it but never for a foreign strap.
        XCTAssertTrue(PolarModel.isPolar(advertisedName: "Polar H10 A1B2C3D4"))
        XCTAssertTrue(PolarModel.isPolar(advertisedName: "Polar Grit X"))       // real Polar, no catalog entry
        XCTAssertTrue(PolarModel.isPolar(advertisedName: "polar sense 99AA"))   // case-insensitive
        XCTAssertFalse(PolarModel.isPolar(advertisedName: "Wahoo TICKR"))
        XCTAssertFalse(PolarModel.isPolar(advertisedName: "Polaris X"))         // prefix must be "polar " + space
        XCTAssertFalse(PolarModel.isPolar(advertisedName: nil))
        XCTAssertFalse(PolarModel.isPolar(advertisedName: ""))
    }

    func testPmdDebugSummaryStatesStreamsAndHrvRoute() {
        // Chest strap: PMD ecg+acc (ordered by PMD type byte), HRV off the standard HR service.
        XCTAssertEqual(PolarModel.h10.pmdDebugSummary, "PMD ecg,acc; HRV via standard R-R")
        // HR-only strap: no PMD service at all, still HRV via standard R-R.
        XCTAssertEqual(PolarModel.h9.pmdDebugSummary, "no PMD service; HRV via standard R-R")
        // Optical bands: PPI is the HRV route; streams ordered by type byte (ppg,acc,ppi[,gyro]).
        XCTAssertEqual(PolarModel.oh1.pmdDebugSummary, "PMD ppg,acc,ppi; HRV via PMD PPI")
        XCTAssertEqual(PolarModel.veritySense.pmdDebugSummary, "PMD ppg,acc,ppi,gyro; HRV via PMD PPI")
        // Unrecognised Polar: probe rather than assume; R-R route is the safe default.
        XCTAssertEqual(PolarModel.unknown.pmdDebugSummary, "PMD unknown (probe); HRV via standard R-R")
    }

    func testDebugIdentificationAutoDetectsFromAnyName() {
        // The same helper works on a live scan name OR a stored PairedDevice.model, so a paired strap
        // auto-detects without a live connection.
        XCTAssertEqual(PolarModel.debugIdentification(advertisedName: "Polar H10 A1B2C3D4"),
                       "Polar H10 identified — PMD ecg,acc; HRV via standard R-R")
        XCTAssertEqual(PolarModel.debugIdentification(advertisedName: "Polar Sense 99AABBCC"),
                       "Polar Verity Sense identified — PMD ppg,acc,ppi,gyro; HRV via PMD PPI")
        // Unrecognised Polar still identifies (as a probe candidate) — that's the useful debug signal.
        XCTAssertEqual(PolarModel.debugIdentification(advertisedName: "Polar Grit X"),
                       "Polar (unrecognised model) identified — PMD unknown (probe); HRV via standard R-R")
        // Foreign / empty → nil, so the caller emits nothing at all.
        XCTAssertNil(PolarModel.debugIdentification(advertisedName: "Wahoo TICKR"))
        XCTAssertNil(PolarModel.debugIdentification(advertisedName: nil))
    }
}
