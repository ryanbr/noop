import XCTest
@testable import Strand

/// Feature-level parity guard for the Android and Apple raw-data collectors. The shared oracle lists
/// every user-visible/session-lifecycle capability and source markers on both implementations.
final class RawDataCollectorParityTests: XCTestCase {
    private struct Oracle: Decodable {
        let schemaVersion: Int
        let capabilities: [String: Capability]
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", capabilities }
    }
    private struct Capability: Decodable { let swift: [String]; let kotlin: [String] }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func oracleData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "raw_data_collector_parity",
                                                            withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testAppleSurfaceStillImplementsEveryDeclaredCapability() throws {
        let oracle = try JSONDecoder().decode(Oracle.self, from: oracleData())
        XCTAssertEqual(oracle.schemaVersion, 1)
        let paths = [
            "Strand/Collect/RawDataSessionStore.swift", "Strand/Collect/Collector.swift",
            "Strand/BLE/BLEManager.swift", "Strand/Screens/RawDataCollectorView.swift",
            "Strand/Collect/ImuSessionFileStore.swift",
            "Packages/WhoopStore/Sources/WhoopStore/Database.swift",
            "Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift",
            "Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift",
        ]
        let source = try paths.map { try String(contentsOf: repoRoot.appendingPathComponent($0)) }
            .joined(separator: "\n")
        for (name, capability) in oracle.capabilities {
            for marker in capability.swift {
                XCTAssertTrue(source.contains(marker), "Apple collector lost \(name) marker: \(marker)")
            }
        }
    }

    func testAndroidAndAppleOracleCopiesAreByteIdentical() throws {
        let android = repoRoot.appendingPathComponent("android/app/src/test/resources/raw_data_collector_parity.json")
        XCTAssertEqual(try oracleData(), try Data(contentsOf: android),
                       "Raw-data collector parity oracle copies must change together")
    }

    func testAppleKeepsTheOffSessionRealtimeImuFailSafe() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        XCTAssertTrue(source.contains("stopUnexpectedRealtimeImu(frame, isOffload: isOffload)"))
        XCTAssertTrue(source.contains("frame[8] == 43 || frame[8] == 51"))
        XCTAssertTrue(source.contains("send(.stopRawData, payload: [0x01]"))
        XCTAssertTrue(source.contains("send(.toggleIMUMode, payload: [0x01, 0x00]"))
    }

    /// The fail-safe must not act on a live MG ECG record (#2846). Type 43 is `REALTIME_RAW_DATA`, which
    /// an ECG capture also arrives under, so without this clause a capture draws a `stopRawData` +
    /// `toggleIMUMode` pair every 30 s for as long as generation runs.
    ///
    /// Asserted as source rather than behaviour because `stopUnexpectedRealtimeImu` is private to the
    /// manager and reaching it needs a live `CBCentralManager`. What the clause DECIDES is covered where
    /// it can be run: `Whoop5EcgTests` pins `r17FromFrame` accepting a well-formed R17 record and
    /// rejecting the wrong revision, the wrong type, a bad CRC and the IMU stream type.
    ///
    /// Scoped to the function's own text rather than to the file, because a whole-file `contains` is not
    /// the assertion this test's name makes: it passes while the clause sits in any of ten thousand other
    /// lines, including a comment, which is exactly how a guard gets moved out from under its own pin.
    /// The window is the signature to the fail-safe's log line, so it cannot be satisfied from outside.
    func testAppleExemptsALiveEcgRecordFromTheImuFailSafe() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent("Strand/BLE/BLEManager.swift"))
        let signature = try XCTUnwrap(source.range(of: "private func stopUnexpectedRealtimeImu"),
                                      "stopUnexpectedRealtimeImu not found")
        let logLine = try XCTUnwrap(source.range(of: "log(\"Raw IMU fail-safe:",
                                                 range: signature.upperBound..<source.endIndex),
                                    "the fail-safe's log line not found after its signature")
        let body = source[signature.lowerBound..<logLine.lowerBound]
        XCTAssertTrue(body.contains("Whoop5Ecg.r17FromFrame(frame) == nil"),
                      "the ECG exemption must sit INSIDE stopUnexpectedRealtimeImu, not merely in the file")
    }
}
