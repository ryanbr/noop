import XCTest
import WhoopProtocol
@testable import Strand

final class StandardHeartRateTests: XCTestCase {
    func testContactFlagsCoverAllCombinations() {
        let cases: [(flags: UInt8, expected: StandardHRContact)] = [
            (0x00, .unsupported),
            (0x02, .unsupported),
            (0x04, .supportedNotDetected),
            (0x06, .supportedDetected),
        ]

        for test in cases {
            XCTAssertEqual(
                StandardHRContact.fromMeasurementFlags(test.flags),
                test.expected,
                "flags 0x\(String(test.flags, radix: 16))"
            )
            let parsed = StandardHeartRate.parse([test.flags, 72])
            XCTAssertEqual(parsed?.contact, test.expected, "flags 0x\(String(test.flags, radix: 16))")
        }
    }

    func testContactFlagsDoNotChangeExistingHeartRateOrRRParsing() {
        let parsed = StandardHeartRate.parse([0x16, 72, 0x00, 0x04])
        XCTAssertEqual(parsed?.hr, 72)
        XCTAssertEqual(parsed?.rr, [1000])
        XCTAssertEqual(parsed?.rrRawTicks, [1024])
        XCTAssertEqual(parsed?.contact, .supportedDetected)
    }
}
