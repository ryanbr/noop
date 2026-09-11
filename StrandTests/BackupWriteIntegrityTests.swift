import XCTest
import ZIPFoundation
@testable import Strand

/// The WRITE side of #1014: what an export checks about the file it just produced.
///
/// `writeVerifiedBackupZip` has re-opened every `.noopbak` it writes since #1014 and refused to leave a
/// torn one behind, and until now nothing tested that it does. These are those tests, driven against
/// hand-built archives through the extracted `DataBackup.verifyWrittenBackup(at:)`.
///
/// Twin of the Android `DataBackupWriteIntegrityTest`. The two platforms answer the same question by
/// different means, which is the point worth pinning: opening a ZIPFoundation `Archive` parses the
/// central directory and so fails on a torn file for free, whereas Android's `ZipInputStream` walks
/// local headers front to back and cannot see truncation at all, and has to look for the end record
/// itself.
final class BackupWriteIntegrityTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-write-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A body that will not deflate away, so the archive has a realistic size to truncate.
    private func incompressible(_ n: Int) -> Data {
        Data((0..<n).map { _ in UInt8.random(in: 0...255) })
    }

    /// A `.noopbak` with a plausible database entry, written the way an export writes one.
    private func makeBackup(dbBody: Data? = nil) throws -> URL {
        let db = tmp.appendingPathComponent("source.sqlite")
        var bytes = Data("SQLite format 3".utf8)
        bytes.append(0x00)
        bytes.append(incompressible(8_192))
        try (dbBody ?? bytes).write(to: db)
        let dest = tmp.appendingPathComponent("good.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: db, to: dest)
        return dest
    }

    func testAWholeBackupIsIntact() throws {
        XCTAssertEqual(DataBackup.verifyWrittenBackup(at: try makeBackup()), .intact)
    }

    /// The shape the check exists for: a write cut short by a full disk or a dropped upload. The index
    /// a ZIP keeps at its END goes with it, so the archive will not open at all.
    func testATruncatedBackupIsNotIntact() throws {
        let backup = try makeBackup()
        let whole = try Data(contentsOf: backup)
        XCTAssertGreaterThan(whole.count, 600, "precondition: enough bytes that a third is a real cut")
        try whole.prefix(whole.count / 3).write(to: backup)
        XCTAssertEqual(DataBackup.verifyWrittenBackup(at: backup), .torn)
    }

    /// Even one byte short: the central directory no longer adds up, so the archive does not open.
    func testABackupMissingItsLastByteIsNotIntact() throws {
        let backup = try makeBackup()
        let whole = try Data(contentsOf: backup)
        try whole.prefix(whole.count - 1).write(to: backup)
        XCTAssertEqual(DataBackup.verifyWrittenBackup(at: backup), .torn)
    }

    /// A perfectly valid archive that simply does not carry a database. The container is fine; the
    /// contents are not what a restore needs, and calling it a good backup would be the same lie.
    func testAnArchiveWithoutTheDatabaseEntryIsNotIntact() throws {
        let dest = tmp.appendingPathComponent("no-db.noopbak")
        let archive = try Archive(url: dest, accessMode: .create)
        let payload = tmp.appendingPathComponent("settings.json")
        try Data("{}".utf8).write(to: payload)
        try archive.addEntry(with: "settings.json", fileURL: payload, compressionMethod: .deflate)
        XCTAssertEqual(DataBackup.verifyWrittenBackup(at: dest), .torn)
    }

    /// Shorter than SQLite's own file header, so it cannot be a database whatever else it looks like.
    /// Guards the size floor specifically: the entry IS present and IS named correctly here.
    func testADatabaseEntryBelowTheHeaderSizeIsNotIntact() throws {
        let dest = tmp.appendingPathComponent("tiny.noopbak")
        let archive = try Archive(url: dest, accessMode: .create)
        let payload = tmp.appendingPathComponent("tiny.sqlite")
        try Data("SQLite format 3\u{0}".utf8).write(to: payload)
        XCTAssertLessThan(16, Int(DataBackup.minimumBackupEntryBytes),
                          "precondition: the magic alone is shorter than the floor, so this tests the floor")
        try archive.addEntry(with: "noop-backup.sqlite", fileURL: payload, compressionMethod: .deflate)
        XCTAssertEqual(DataBackup.verifyWrittenBackup(at: dest), .torn)
    }

    /// Never an archive at all: answered with a verdict rather than thrown, which is the contract.
    func testSomethingThatIsNotAnArchiveIsNotIntact() throws {
        let junk = tmp.appendingPathComponent("junk.noopbak")
        // Readable, so we DID look; it simply is not an archive. That is a torn verdict, not an
        // unverifiable one, and the distinction decides whether the caller deletes it.
        try Data(repeating: 0x41, count: 4_096).write(to: junk)
        XCTAssertEqual(DataBackup.verifyWrittenBackup(at: junk), .torn)
    }

    /// The distinction the verdict exists for, and the Swift twin of the Android verdict-table test.
    ///
    /// A file we cannot read tells us NOTHING about its contents, and the caller's answer to `torn` is to
    /// delete. Before this the check returned a plain Bool, so a transient read failure and a genuinely
    /// cut-short archive were the same answer, and the destructive one.
    func testAFileThatCannotBeReadIsUnverifiableRatherThanTorn() {
        XCTAssertEqual(DataBackup.verifyWrittenBackup(at: tmp.appendingPathComponent("absent.noopbak")),
                       .unverifiable)
    }

    /// The convenience wrapper keeps agreeing with the verdict it delegates to.
    func testTheBooleanWrapperTracksTheVerdict() throws {
        let good = try makeBackup()
        XCTAssertTrue(DataBackup.writtenBackupIsIntact(at: good))
        XCTAssertFalse(DataBackup.writtenBackupIsIntact(at: tmp.appendingPathComponent("absent.noopbak")))
    }
}
