import XCTest
@testable import Strand

final class OnDeviceCoachErrorTests: XCTestCase {
    func testNewErrorCasesHaveMessages() {
        let cases: [AICoachError] = [
            .modelNotDownloaded,
            .modelLoadFailed("boom"),
            .generationFailed("mid-stream"),
            .deviceUnsupported
        ]
        for e in cases {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty, "\(e) has empty description")
        }
    }
}

final class ModelCatalogTests: XCTestCase {
    func testCoachModelIsWellFormed() {
        let m = ModelCatalog.coach
        XCTAssertFalse(m.id.isEmpty)
        XCTAssertFalse(m.displayName.isEmpty)
        XCTAssertEqual(m.url.scheme, "https")
        XCTAssertEqual(m.sha256.count, 64, "SHA-256 hex must be 64 chars")
        XCTAssertTrue(m.sha256.allSatisfy { $0.isHexDigit })
        XCTAssertGreaterThan(m.sizeBytes, 0)
        XCTAssertEqual(m.contextLength, 4096)
        XCTAssertFalse(m.chatTemplate.isEmpty)
    }

    func testDeviceGateBoundary() {
        let sixGB: UInt64 = 6 * 1024 * 1024 * 1024
        XCTAssertFalse(ModelCatalog.deviceMeetsRequirements(physicalMemory: sixGB - 1))
        XCTAssertTrue(ModelCatalog.deviceMeetsRequirements(physicalMemory: sixGB))
        XCTAssertTrue(ModelCatalog.deviceMeetsRequirements(physicalMemory: 8 * 1024 * 1024 * 1024))
    }

    func testStorageFileURLUsesModelId() {
        let url = ModelStorage.fileURL(for: ModelCatalog.coach)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".gguf"))
        XCTAssertTrue(url.lastPathComponent.contains(ModelCatalog.coach.id))
    }
}
