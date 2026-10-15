import Foundation
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

    func testIncompleteDeclaredEnergyRefusesWholeReading() {
        let heartRates: [[UInt8]] = [[72], [0x40, 1]]
        for (format, hr) in heartRates.enumerated() {
            for extraFlags: UInt8 in [0x00, 0x06, 0xe0, 0xe6, 0x10, 0x16, 0xf0, 0xf6] {
                for energy: [UInt8] in [[], [0xff]] {
                    let frame = [UInt8(format) | 0x08 | extraFlags] + hr + energy
                    XCTAssertNil(StandardHeartRate.parse(frame), "incomplete energy: \(frame)")
                }
            }
        }
    }

    func testIncompleteRrTailRefusesWholeReading() {
        let heartRates: [[UInt8]] = [[72], [0x40, 1]]
        for (format, hr) in heartRates.enumerated() {
            for energy: [UInt8] in [[], [0x34, 0x12]] {
                for extraFlags: UInt8 in [0x00, 0x06, 0xe0, 0xe6] {
                    for tail: [UInt8] in [[0xff], [0, 4, 0xff], [0, 4, 0xff, 0xff, 0xab]] {
                        let flags = UInt8(format) | 0x10 | extraFlags | (energy.isEmpty ? 0 : 0x08)
                        let frame = [flags] + hr + energy + tail
                        XCTAssertNil(StandardHeartRate.parse(frame), "incomplete R-R: \(frame)")
                    }
                }
            }
        }
    }

    func testCompleteReadingsMatchOriginalSwiftOracle() {
        let frames: [[UInt8]] = [
    [0x00, 72], [0x02, 0], [0x04, 220], [0x06, 255],
    [0x01, 0x00, 0x01], [0x07, 0xff, 0xff],
    [0x08, 72, 0, 0], [0x09, 0x40, 1, 0xff, 0xff],
    [0x10, 60], [0x11, 0x40, 1], [0x18, 65, 0xff, 0], [0x19, 0xff, 0xff, 0xff, 0xff],
    [0x10, 60, 0, 4], [0x16, 72, 0, 4], [0x18, 65, 0xff, 0, 0, 4],
    [0x19, 0x40, 1, 0x34, 0x12, 0, 4], [0x10, 58, 0, 2, 0, 4],
    [0x10, 72, 0, 0, 0x40, 0, 0xc0, 0, 0xff, 0xff],
    [0xe0, 72], [0xe0, 72, 0xff], [0xf0, 72, 0, 4], [0xf6, 72, 0, 2, 0, 4],
    [0xf9, 0x40, 1, 0, 0, 0, 4], [0xfe, 72, 0, 0, 0, 4],
    [0xff, 0x40, 1, 0, 0, 1, 0], [0x00, 72, 0xff, 0, 4], [0x01, 0x40, 1, 0xff]
]
        let expected = """
        0048|72|||unsupported
        0200|0|||unsupported
        04dc|220|||supported_not_detected
        06ff|255|||supported_detected
        010001|256|||unsupported
        07ffff|65535|||supported_detected
        08480000|72|||unsupported
        094001ffff|320|||unsupported
        103c|60|||unsupported
        114001|320|||unsupported
        1841ff00|65|||unsupported
        19ffffffff|65535|||unsupported
        103c0004|60|1000|1024|unsupported
        16480004|72|1000|1024|supported_detected
        1841ff000004|65|1000|1024|unsupported
        19400134120004|320|1000|1024|unsupported
        103a00020004|58|500,1000|512,1024|unsupported
        104800004000c000ffff|72|0,63,188,63999|0,64,192,65535|unsupported
        e048|72|||unsupported
        e048ff|72|||unsupported
        f0480004|72|1000|1024|unsupported
        f64800020004|72|500,1000|512,1024|supported_detected
        f9400100000004|320|1000|1024|unsupported
        fe4800000004|72|1000|1024|supported_detected
        ff400100000100|320|1|1|supported_detected
        0048ff0004|72|||unsupported
        014001ff|320|||unsupported
        """
        let actual = frames.map { data -> String in
            let hex = data.map { String(format: "%02x", $0) }.joined()
            guard let r = StandardHeartRate.parse(data) else { return "\(hex)|nil" }
            return "\(hex)|\(r.hr)|\(r.rr.map(String.init).joined(separator: ","))|\(r.rrRawTicks.map(String.init).joined(separator: ","))|\(r.contact.rawValue)"
        }.joined(separator: "\n")
        XCTAssertEqual(actual, expected)
    }
}
