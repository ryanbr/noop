import XCTest
@testable import Strand

/// #590 — the document-picker `asCopy:true` duplicate in `Documents/Inbox/` was never deleted, so each
/// Apple Health / WHOOP import left a permanent multi-GB copy behind (the runaway "Documents & Data"
/// growth). These pin: (1) the safety guard only ever targets OUR `Documents/Inbox/`, never a user file,
/// and (2) `ImportFile.cleanup()` reclaims the Inbox original alongside the temp copy.
final class ImportInboxCleanupTests: XCTestCase {

    private var inbox: URL!
    private var docs: URL!

    override func setUpWithError() throws {
        docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        try XCTSkipIf(docs == nil, "no Documents directory in this test environment")
        inbox = docs.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    private func makeFile(at url: URL, bytes: Int = 16) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    // MARK: - Guard: only OUR Inbox is ever a deletion target

    func testInboxFileIsRecognised() throws {
        let f = try makeFile(at: inbox.appendingPathComponent("export-\(UUID()).zip"))
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertTrue(AppModel.ImportFile.isInImportInbox(f))
    }

    func testFileOutsideInboxIsNotATarget() throws {
        // A user-chosen in-place file (macOS) or any path outside Documents/Inbox must be refused.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("user-picked-\(UUID()).zip")
        let f = try makeFile(at: outside)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertFalse(AppModel.ImportFile.isInImportInbox(f))

        // A sibling directory whose name merely PREFIXES "Inbox" must not match (the `/` boundary guard).
        let lookalike = docs.appendingPathComponent("InboxArchive/file.zip")
        let f2 = try makeFile(at: lookalike)
        defer { try? FileManager.default.removeItem(at: f2.deletingLastPathComponent()) }
        XCTAssertFalse(AppModel.ImportFile.isInImportInbox(f2))
    }

    // MARK: - cleanup() reclaims the Inbox original + the temp copy

    func testCleanupDeletesInboxOriginalAndTemp() throws {
        let inboxOriginal = try makeFile(at: inbox.appendingPathComponent("export-\(UUID()).zip"))
        let temp = try makeFile(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-import-\(UUID()).zip"))

        let file = AppModel.ImportFile(url: temp, temp: temp, inboxOriginal: inboxOriginal)
        file.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path), "temp copy must be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inboxOriginal.path),
                       "the Inbox asCopy duplicate must be removed (#590)")
    }

    func testCleanupLeavesAUserFileOutsideInboxUntouched() throws {
        // macOS reads the picked file in place (inboxOriginal nil); even if a caller passed a non-Inbox
        // URL, the guard must protect it.
        let userFile = try makeFile(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("user-data-\(UUID()).zip"))
        defer { try? FileManager.default.removeItem(at: userFile) }

        let file = AppModel.ImportFile(url: userFile, temp: nil, inboxOriginal: userFile)
        file.cleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path),
                      "a file outside Documents/Inbox must never be deleted by cleanup()")
    }

    func testPurgeRemovesStaleInboxDropsButKeepsFreshOnes() throws {
        // Both platforms assert, differently: on iOS the stale drop must go, off iOS `purgeImportInbox()`
        // is a no-op and BOTH drops must survive. The second is not a formality, because this test writes
        // into the real `Documents/Inbox` that the production function scans.
        let stale = try makeFile(at: inbox.appendingPathComponent("stale-\(UUID()).zip"))
        // Age it well past the 60 s in-flight guard.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: stale.path)
        let fresh = try makeFile(at: inbox.appendingPathComponent("fresh-\(UUID()).zip"))
        defer { try? FileManager.default.removeItem(at: fresh); try? FileManager.default.removeItem(at: stale) }

        AppModel.purgeImportInbox()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "a just-written (in-flight) Inbox drop must be left alone")
        #if os(iOS)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "a stale Inbox drop must be purged on launch (#590)")
        #else
        // StrandTests runs on the macOS scheme, so the branch above is the one we almost never execute.
        // Assert the OTHER half rather than compiling the interesting case away: `purgeImportInbox()` is
        // wholly `#if os(iOS)`, so off iOS the stale drop must SURVIVE. That makes the platform gate on
        // the production function a tested property instead of an assumed one — drop the `#if` there and
        // this run deletes a file out of the user's real Documents/Inbox, which is the accident worth
        // catching. Without it the macOS run only ever confirmed that a no-op left `fresh` alone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path),
                      "purgeImportInbox() is iOS-only; off iOS a stale Inbox drop must be left alone")
        #endif
    }
}
