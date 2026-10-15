import XCTest
import WhoopStore
@testable import Strand

/// Lab Book value formatting. The expected lists are the same literals pinned in the Android twin's
/// `LabValueFormatTest`, so both platforms print the same string for every value.
final class LabBookFormatTests: XCTestCase {
    private let inputs: [Double] = [
        0.27, 1.020, 1.02, 140, 0, -0.0, -0.0001, 0.0004, 0.0005, 1.0005, 0.0625, 2.675, 12.5, 0.125,
        3.14159, 1234567.891, 5.2, 0.1, 0.30000000000000004, 99.9995, -3.25, 1e-7,
    ]

    /// A CSV import's `takenAt` is UTC noon, which is the next day from UTC+12. The caption names the stored
    /// day in every zone, as the history list does. Pins the process zone so a UTC runner catches it too.
    func testLastTakenNamesTheStoredDayInEveryZone() {
        let row = LabMarkerRow(id: "ldl-1", deviceId: "d", markerKey: "ldl", category: "blood_panel",
                               day: "2026-08-25", takenAt: LabBookFormat.noonEpoch("2026-08-25"),
                               value: 3.1, valueText: nil, unit: "mmol/L", source: "csv", note: nil,
                               referenceText: nil)
        inEachTimeZone(["Pacific/Honolulu", "UTC", "Pacific/Auckland", "Pacific/Kiritimati"]) { zone in
            let caption = LabBookFormat.lastTakenCaption(row)
            XCTAssertTrue(caption.hasSuffix("25 Aug 2026"), "\(zone): \(caption)")
        }
    }

    func testCustomMarkerKeepsItsOwnPrecision() {
        XCTAssertEqual(LabBookFormat.value(0.27, key: "custom_plateletcrit"), "0.27")
        XCTAssertEqual(LabBookFormat.value(1.020, key: "custom_urine_specific_gravity"), "1.02")
        XCTAssertEqual(LabBookFormat.value(140, key: "custom_platelets"), "140")
    }

    func testPlainIsPinned() {
        let expected = [
            "0.27", "1.02", "1.02", "140", "0", "0", "0", "0", "0.001", "1", "0.062", "2.675", "12.5", "0.125",
            "3.142", "1234567.891", "5.2", "0.1", "0.3", "99.999", "-3.25", "0",
        ]
        XCTAssertEqual(inputs.map(LabBookFormat.plain), expected)
        XCTAssertEqual(LabBookFormat.plain(.nan), "—")
        XCTAssertEqual(LabBookFormat.plain(.infinity), "—")
    }

    func testCatalogDecimalsArePinned() {
        // ferritin = 0 decimals, weight = 1, tsh = 2 (MarkerCatalog.builtIn).
        let expected0 = [
            "0", "1", "1", "140", "0", "0", "0", "0", "0", "1", "0", "3", "13", "0", "3", "1234568", "5", "0",
            "0", "100", "-3", "0",
        ]
        let expected1 = [
            "0.3", "1.0", "1.0", "140.0", "0.0", "-0.0", "-0.0", "0.0", "0.0", "1.0", "0.1", "2.7", "12.5", "0.1",
            "3.1", "1234567.9", "5.2", "0.1", "0.3", "100.0", "-3.2", "0.0",
        ]
        let expected2 = [
            "0.27", "1.02", "1.02", "140.00", "0.00", "-0.00", "-0.00", "0.00", "0.00", "1.00", "0.06", "2.67",
            "12.50", "0.12", "3.14", "1234567.89", "5.20", "0.10", "0.30", "100.00", "-3.25", "0.00",
        ]
        XCTAssertEqual(inputs.map { LabBookFormat.value($0, key: "ferritin") }, expected0)
        XCTAssertEqual(inputs.map { LabBookFormat.value($0, key: "weight") }, expected1)
        XCTAssertEqual(inputs.map { LabBookFormat.value($0, key: "tsh") }, expected2)
    }
}
