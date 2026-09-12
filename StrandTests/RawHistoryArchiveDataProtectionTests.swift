import XCTest
@testable import Strand
import WhoopProtocol

/// #649: the reject archive lives outside `OpenWhoop`'s protected App Support tree
/// (`StorePaths.defaultDatabasePath()`, #222) and did not inherit that store's Data Protection
/// downgrade. On iOS, files default to `NSFileProtectionComplete` — cryptographically UNREADABLE while
/// the device is locked. `BLEManager.archiveRejectedFrames` writes here to durably bank a frame BEFORE
/// acking the strap's historical-data trim; a write that throws because the phone is locked trips the
/// `.failed` path and holds the ack, so the strap re-sends the same chunk in a loop. This test asserts
/// the fix: after a successful `archive(...)` write, the directory AND the file carry the same
/// `completeUntilFirstUserAuthentication` protection class `StorePaths` sets on the main SQLite store.
///
/// iOS-only: the code under test is itself `#if os(iOS)`-gated (mirroring `StorePaths.swift`, since
/// `FileProtectionType`/`.protectionKey` are only meaningfully enforced under iOS's Data Protection
/// entitlement). `StrandTests` runs on the macOS scheme (see `project.yml`), so this assertion can't
/// execute there today — it skips cleanly on macOS and is ready for the first iOS-capable test run.
final class RawHistoryArchiveDataProtectionTests: XCTestCase {

    private func tmpDir(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-protect-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    func testArchiveDirectoryAndFileGetDataProtectionAfterWrite() throws {
        #if os(iOS)
        let dir = tmpDir("protect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir)

        let frame: [UInt8] = [0xAA, 0x01, 0x00, 0x00, 47, 18] + [UInt8](repeating: 0, count: 24)
        let result = archive.archive([frame], trim: 1, family: .whoop4)
        guard case .written = result else {
            return XCTFail("expected a successful write, got \(result)")
        }

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual(dirAttrs[.protectionKey] as? FileProtectionType,
                        .completeUntilFirstUserAuthentication,
                        "archive directory must not default to NSFileProtectionComplete (#649)")

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: archive.fileURL.path)
        XCTAssertEqual(fileAttrs[.protectionKey] as? FileProtectionType,
                        .completeUntilFirstUserAuthentication,
                        "archive file must not default to NSFileProtectionComplete (#649)")
        #else
        throw XCTSkip("File Data Protection is iOS-only; StrandTests runs on the macOS scheme.")
        #endif
    }
}
