import XCTest
@testable import WhoopStore

/// Pins the #1410 build-provenance JSON. The expected strings are byte-identical to the Kotlin twin
/// (`BackupProvenanceTest.kt`) for the same inputs — `.sortedKeys` compact JSON, numbers unquoted — so an
/// analyst reads one shape across platforms.
final class BackupProvenanceTests: XCTestCase {

    func test_manifest_json_is_sorted_and_parity_with_kotlin() {
        // Same inputs the Kotlin test uses (platform "android") → must produce the identical string.
        XCTAssertEqual(
            BackupManifest.json(appVersion: "10.1.1", appBuild: "221", platform: "android",
                                schemaVersion: 30, exportedAtMs: 1_723_900_000_000),
            #"{"appBuild":"221","appVersion":"10.1.1","exportedAt":1723900000000,"platform":"android","schemaVersion":30}"#
        )
    }

    func test_versionEvent_payload_is_sorted() {
        XCTAssertEqual(
            AppVersionEvent.payloadJson(from: "10.1.0", to: "10.1.1", schemaVersion: 30),
            #"{"from":"10.1.0","schemaVersion":30,"to":"10.1.1"}"#
        )
    }

    func test_shouldRecord_only_on_a_real_transition() {
        XCTAssertFalse(AppVersionEvent.shouldRecord(lastSeen: nil, current: "10.1.1"))   // first launch
        XCTAssertFalse(AppVersionEvent.shouldRecord(lastSeen: "", current: "10.1.1"))
        XCTAssertFalse(AppVersionEvent.shouldRecord(lastSeen: "10.1.1", current: "10.1.1")) // unchanged
        XCTAssertTrue(AppVersionEvent.shouldRecord(lastSeen: "10.1.0", current: "10.1.1"))  // transition
    }
}
