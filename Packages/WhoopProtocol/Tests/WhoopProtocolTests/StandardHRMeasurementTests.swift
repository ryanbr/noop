import XCTest
@testable import WhoopProtocol

final class StandardHRMeasurementTests: XCTestCase {
    func testCompleteFieldVerdictMatchesSwiftOracleForEveryFlagAndLength() {
        // Verbatim production Swift stdout, independently checked against the SIG layout table.
        let oracle = """
        00|00111111111111111111111111111111111111111111111111111111111111111
        01|00011111111111111111111111111111111111111111111111111111111111111
        08|00001111111111111111111111111111111111111111111111111111111111111
        09|00000111111111111111111111111111111111111111111111111111111111111
        10|00101010101010101010101010101010101010101010101010101010101010101
        11|00010101010101010101010101010101010101010101010101010101010101010
        18|00001010101010101010101010101010101010101010101010101010101010101
        19|00000101010101010101010101010101010101010101010101010101010101010
        """
        var masks: [UInt8: [Character]] = [:]
        for row in oracle.split(separator: "\n") {
            let columns = row.split(separator: "|")
            guard let keyText = columns.first, let key = UInt8(keyText, radix: 16),
                  let bits = columns.last else { XCTFail("invalid oracle row"); continue }
            XCTAssertEqual(bits.count, 65)
            masks[key] = Array(bits)
        }
        for flags in UInt8.min...UInt8.max {
            guard let bits = masks[flags & 0x19] else { XCTFail("missing oracle mask"); continue }
            for (length, bit) in bits.enumerated() {
                var bytes = [UInt8](repeating: 0, count: length)
                if !bytes.isEmpty { bytes[0] = flags }
                XCTAssertEqual(StandardHRMeasurement.hasCompleteFields(bytes), bit == "1",
                               "flags=\(flags), length=\(length)")
            }
        }
    }
}
