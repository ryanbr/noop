import XCTest
@testable import Strand

final class TestBundleMetaTests: XCTestCase {

    private func sample() -> TestBundleMeta {
        TestBundleMeta(
            schema: 1,
            appVersion: "7.3.0",
            platform: "iOS",
            osVersion: "18.5",
            strapModel: "WHOOP 5.0",
            source: ["Live Bluetooth"],
            testProfile: "sleep",
            profileStartedAt: "2026-06-26T07:12:00Z",
            questionnaire: ["naps": "no"],
            build: .init(channel: "AltStore", signed: false),
            storage: .init(dbBytes: 1024, rows: ["sleep_sessions": 12], rawCaptureBytes: 2048,
                           rowBytes: ["sleep_sessions": 4096]),
            redaction: "v2",
            truncated: false)
    }

    func testEncodesSnakeCaseWireKeys() throws {
        let json = String(data: sample().encoded(), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"app_version\" : \"7.3.0\""))
        XCTAssertTrue(json.contains("\"os_version\" : \"18.5\""))
        XCTAssertTrue(json.contains("\"strap_model\" : \"WHOOP 5.0\""))
        XCTAssertTrue(json.contains("\"test_profile\" : \"sleep\""))
        XCTAssertTrue(json.contains("\"profile_started_at\" : \"2026-06-26T07:12:00Z\""))
    }

    func testEncodesBuildAndStorageBlocks() throws {
        let json = String(data: sample().encoded(), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"channel\" : \"AltStore\""))
        XCTAssertTrue(json.contains("\"signed\" : false"))
        XCTAssertTrue(json.contains("\"db_bytes\" : 1024"))
        XCTAssertTrue(json.contains("\"raw_capture_bytes\" : 2048"))
    }

    func testRedactionAndSchemaStamps() throws {
        let m = sample()
        XCTAssertEqual(m.schema, 1)
        XCTAssertEqual(m.redaction, "v2")
        XCTAssertFalse(m.truncated)
    }

    func testSortedKeysAreStableForParity() throws {
        // sortedKeys is required so the Swift and Kotlin bundles produce a byte-aligned ordering.
        let a = String(data: sample().encoded(), encoding: .utf8)!
        let b = String(data: sample().encoded(), encoding: .utf8)!
        XCTAssertEqual(a, b)
        XCTAssertLessThan(a.range(of: "\"app_version\"")!.lowerBound, a.range(of: "\"platform\"")!.lowerBound)
    }
}
