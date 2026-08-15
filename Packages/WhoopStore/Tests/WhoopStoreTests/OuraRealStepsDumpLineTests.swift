import XCTest
@testable import WhoopStore

final class OuraRealStepsDumpLineTests: XCTestCase {
    func testEncodeFixedKeyOrderAndValues() {
        let line = OuraRealStepsDumpLine.encode(
            deviceId: "oura-2H3B2405003655", tag: "0x7e", ringTs: 3_499_176, utc: 1_753_440_000,
            iso: "2026-07-30T09:09:01Z",
            fields: [222, 470, 188, 10, 99, 62, 16, 104, 202, 436, 152, 19, 101, 113])
        XCTAssertEqual(line,
            "{\"schema\":1,\"deviceId\":\"oura-2H3B2405003655\",\"tag\":\"0x7e\",\"ringTs\":3499176,"
          + "\"utc\":1753440000,\"iso\":\"2026-07-30T09:09:01Z\","
          + "\"fields\":[222,470,188,10,99,62,16,104,202,436,152,19,101,113]}")
    }

    func testEncodeEmptyFieldsIsValidJSON() throws {
        let line = OuraRealStepsDumpLine.encode(deviceId: "oura-x", tag: "0x7f", ringTs: 1, utc: 2,
                                                iso: "i", fields: [])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["schema"] as? Int, OuraRealStepsDumpLine.schema)
        XCTAssertEqual(obj?["tag"] as? String, "0x7f")
        XCTAssertEqual((obj?["fields"] as? [Any])?.count, 0)
    }
}
