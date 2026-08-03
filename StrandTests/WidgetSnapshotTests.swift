import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testAltStoreProvisionedGroupWinsOverBuildTimeIdentifier() {
        let configured = "group.com.noopapp.noop.staging"
        let remapped = configured + ".TEAM123456"

        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": configured,
                "ALTAppGroups": [remapped]
            ]),
            remapped
        )
    }

    func testXcodeBuildFallsBackToConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop"
            ]),
            "group.example.noop"
        )
    }

    func testUnrelatedAltStoreGroupsDoNotOverrideConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop",
                "ALTAppGroups": [
                    "group.example.first",
                    "group.example.second"
                ]
            ]),
            "group.example.noop"
        )
    }

    func testSingleProvisionedGroupIsUsableWithoutConfiguredIdentifier() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "ALTAppGroups": ["group.example.noop.TEAM123456"]
            ]),
            "group.example.noop.TEAM123456"
        )
    }

    func testRuntimeUnavailableSnapshotContainsNoDemoValues() {
        let snapshot = WidgetSnapshot.unavailable

        XCTAssertNil(snapshot.recovery)
        XCTAssertNil(snapshot.bpm)
        XCTAssertNil(snapshot.batteryPct)
        XCTAssertFalse(snapshot.bonded)
    }
}
