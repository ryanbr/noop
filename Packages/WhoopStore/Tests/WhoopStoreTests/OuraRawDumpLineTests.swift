import XCTest
@testable import WhoopStore

/// The RAW-capture JSONL line encoder. Asserted verbatim so the format (and the contiguous lowercase hex) is
/// pinned for the offline re-framer.
final class OuraRawDumpLineTests: XCTestCase {

    func testEncodesFixedShapeVerbatim() {
        let line = OuraRawDumpLine.encode(
            deviceId: "oura-5C4C0BF8", utc: 1_783_400_728, iso: "2026-07-14T09:05:28Z",
            bytes: [0x50, 0x06, 0x01, 0x00, 0x02, 0x00, 0x17, 0x0a])
        XCTAssertEqual(line,
            "{\"schema\":1,\"deviceId\":\"oura-5C4C0BF8\",\"utc\":1783400728," +
            "\"iso\":\"2026-07-14T09:05:28Z\",\"hex\":\"500601000200170a\"}")
    }

    func testHexIsContiguousLowercaseZeroPadded() {
        let line = OuraRawDumpLine.encode(deviceId: "d", utc: 1, iso: "x", bytes: [0x00, 0xFF, 0x0A, 0xB3])
        XCTAssertTrue(line.hasSuffix("\"hex\":\"00ff0ab3\"}"))
    }

    func testEmptyBytesIsEmptyHex() {
        let line = OuraRawDumpLine.encode(deviceId: "d", utc: 1, iso: "x", bytes: [])
        XCTAssertTrue(line.hasSuffix("\"hex\":\"\"}"))
    }

    func testEachLineIsValidJSON() throws {
        let line = OuraRawDumpLine.encode(
            deviceId: "oura-ring", utc: 200, iso: "2026-07-14T00:00:00Z", bytes: [0x80, 0x0e, 0xab])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["hex"] as? String, "800eab")
        XCTAssertEqual(obj?["schema"] as? Int, OuraRawDumpLine.schema)
    }
}
