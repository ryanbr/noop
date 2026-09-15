import XCTest
import CryptoKit
@testable import Strand

/// A fetcher we fully control: hands back a temp file with chosen bytes, or throws.
private final class StubFetcher: ModelFileFetcher {
    var bytes: Data
    var error: Error?
    init(bytes: Data = Data([0x1, 0x2, 0x3]), error: Error? = nil) { self.bytes = bytes; self.error = error }
    func fetch(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        if let error { throw error }
        progress(0.5); progress(1.0)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gguf")
        try bytes.write(to: tmp)
        return tmp
    }
}

@MainActor
final class ModelDownloadManagerTests: XCTestCase {

    private func model(matching bytes: Data) -> BundledModel {
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let m = ModelCatalog.coach
        return BundledModel(id: "test-model", displayName: m.displayName, url: m.url,
                            sha256: hex, sizeBytes: Int64(bytes.count),
                            contextLength: m.contextLength, chatTemplate: m.chatTemplate)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: ModelStorage.directory())
        super.tearDown()
    }

    func testSuccessfulDownloadVerifiesAndBecomesReady() async {
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let m = model(matching: bytes)
        let mgr = ModelDownloadManager(model: m, fetcher: StubFetcher(bytes: bytes))
        await mgr.startDownloadAndWait()
        XCTAssertEqual(mgr.state, .ready)
        XCTAssertTrue(ModelStorage.isPresent(m))
    }

    func testChecksumMismatchFailsAndDeletesFile() async {
        let m = model(matching: Data([0x1]))                 // expects hash of [0x1]
        let mgr = ModelDownloadManager(model: m, fetcher: StubFetcher(bytes: Data([0x2]))) // delivers [0x2]
        await mgr.startDownloadAndWait()
        if case .failed = mgr.state {} else { XCTFail("expected .failed, got \(mgr.state)") }
        XCTAssertFalse(ModelStorage.isPresent(m))
    }

    func testFetchErrorBecomesFailed() async {
        let m = model(matching: Data([0x1]))
        let mgr = ModelDownloadManager(model: m,
            fetcher: StubFetcher(error: URLError(.notConnectedToInternet)))
        await mgr.startDownloadAndWait()
        if case .failed = mgr.state {} else { XCTFail("expected .failed") }
    }

    func testDeleteReturnsToAbsent() async {
        let bytes = Data([0xAB])
        let m = model(matching: bytes)
        let mgr = ModelDownloadManager(model: m, fetcher: StubFetcher(bytes: bytes))
        await mgr.startDownloadAndWait()
        mgr.deleteModel()
        XCTAssertEqual(mgr.state, .absent)
        XCTAssertFalse(ModelStorage.isPresent(m))
    }
}
