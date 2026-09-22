import XCTest
@testable import Strand

/// #2384: the `HR notify:` line, extracted so Android could be given a twin that cannot drift from it.
///
/// A reporter's WHOOP 5/MG banked `live hr=0 rr=0` on ten consecutive links while the historical offload
/// ran perfectly, and their Android log could not distinguish the strap never notifying on 0x2A37 from it
/// notifying with a reading the 30...220 value gate drops in silence. Those call for opposite fixes.
///
/// Twin of the Kotlin `StandardHrNotifyLineTest`.
final class StandardHrNotifyLineTests: XCTestCase {

    func testAUsableReadingSaysSoPlainly() {
        XCTAssertEqual(BLEManager.standardHrNotifyLine(hr: 62, rrCount: 2),
                       "HR notify: 62 bpm, rr=2")
    }

    func testAnUnusableReadingIsMarkedIgnored() {
        XCTAssertEqual(BLEManager.standardHrNotifyLine(hr: 0, rrCount: 0),
                       "HR notify: 0 bpm ignored, rr=0")
    }

    /// The marker must track the value gate exactly, or the line lies about what reached the store.
    func testTheIgnoredMarkerUsesTheSameRangeAsTheValueGate() {
        for hr in [30, 31, 219, 220] {
            XCTAssertFalse(BLEManager.standardHrNotifyLine(hr: hr, rrCount: 0).contains("ignored"),
                           "hr=\(hr) is inside the gate")
        }
        for hr in [0, 29, 221, 300] {
            XCTAssertTrue(BLEManager.standardHrNotifyLine(hr: hr, rrCount: 0).contains(" ignored"),
                          "hr=\(hr) is outside the gate")
        }
    }

    /// R-R rides the same line, because "HR arrived but carried no intervals" is its own diagnosis.
    func testTheIntervalCountRidesTheSameLine() {
        XCTAssertEqual(BLEManager.standardHrNotifyLine(hr: 58, rrCount: 0),
                       "HR notify: 58 bpm, rr=0")
    }
}
