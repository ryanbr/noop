import XCTest
import GRDB
@testable import WhoopStore

/// #1014 defence-in-depth: real-file coverage for the `PRAGMA quick_check` integrity gate the
/// backup import/export pipeline runs. Not string logic — actual SQLite files on disk, including
/// deliberately damaged ones (truncated mid-file, garbage behind a valid magic header), because
/// those are precisely the files the magic-byte + origin gates wave through.
final class DatabaseIntegrityTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbintegrity-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// A real multi-page SQLite database (page 1 alone can't prove anything about truncation —
    /// sqlite_master lives there and survives losing the tail, which is the whole point of #1014).
    private func makeMultiPageDatabase(at url: URL) throws {
        let q = try DatabaseQueue(path: url.path)
        try q.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
            try db.execute(sql: "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY, blob TEXT NOT NULL)")
            let filler = String(repeating: "x", count: 200)
            for i in 0..<200 {
                try db.execute(sql: "INSERT INTO device (id, blob) VALUES (?, ?)",
                               arguments: ["row-\(i)", filler])
            }
        }
    }

    // MARK: - quickCheckFailure over real files

    func testHealthyDatabasePassesQuickCheck() throws {
        let db = tmp.appendingPathComponent("healthy.sqlite")
        try makeMultiPageDatabase(at: db)
        XCTAssertNil(DatabaseIntegrity.quickCheckFailure(atPath: db.path),
                     "A freshly written database must pass quick_check")
    }

    func testTruncatedDatabaseFailsQuickCheck() throws {
        // Build a multi-page DB, then chop it to its first page: the magic bytes AND sqlite_master
        // both still read fine (so the import's header + origin gates pass), but the pages the
        // header promises are gone. quick_check is the only gate that can see that.
        let db = tmp.appendingPathComponent("truncated.sqlite")
        try makeMultiPageDatabase(at: db)
        let fullSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: db.path))[.size] as? NSNumber
        ).int64Value
        XCTAssertGreaterThan(fullSize, 4096, "precondition: the fixture must span multiple pages")

        let handle = try FileHandle(forWritingTo: db)
        try handle.truncate(atOffset: 4096)
        try handle.close()

        XCTAssertNotNil(DatabaseIntegrity.quickCheckFailure(atPath: db.path),
                        "A truncated database must fail quick_check")
    }

    func testGarbageBehindValidMagicFailsQuickCheck() throws {
        // 16 valid magic bytes + junk: exactly what a torn download can look like. Passes the
        // header check, yields no readable sqlite_master (origin `.unknown`, holds no data), and
        // before #1014 would have sailed through to the swap.
        let db = tmp.appendingPathComponent("garbage.sqlite")
        var bytes = Data("SQLite format 3".utf8)
        bytes.append(0x00)
        bytes.append(Data(repeating: 0x5A, count: 8192))
        try bytes.write(to: db)

        XCTAssertNotNil(DatabaseIntegrity.quickCheckFailure(atPath: db.path),
                        "Garbage behind a valid magic header must fail quick_check")
    }

    func testMissingFileFailsQuickCheck() throws {
        let gone = tmp.appendingPathComponent("never-written.sqlite")
        XCTAssertNotNil(DatabaseIntegrity.quickCheckFailure(atPath: gone.path),
                        "A missing file can't be verified and must be refused")
    }

    // MARK: - verdict(fromRows:) golden vectors (mirrored by Android's quickCheckVerdict)

    func testVerdictGoldenVectors() {
        // Healthy: the single canonical "ok" row (SQLite emits it lowercase; accept any case).
        XCTAssertNil(DatabaseIntegrity.verdict(fromRows: ["ok"]))
        XCTAssertNil(DatabaseIntegrity.verdict(fromRows: ["OK"]))

        // A complaint row comes back verbatim — never a fabricated summary.
        XCTAssertEqual(
            DatabaseIntegrity.verdict(fromRows: ["*** in database main ***\nPage 5 is never used"]),
            "*** in database main ***\nPage 5 is never used"
        )
        XCTAssertEqual(DatabaseIntegrity.verdict(fromRows: ["row 12 missing from index sleepIdx"]),
                       "row 12 missing from index sleepIdx")

        // Silence is NOT health: quick_check always answers, so an empty result is a failure.
        XCTAssertEqual(DatabaseIntegrity.verdict(fromRows: []), "quick_check returned no verdict")

        // Multiple rows can never mean healthy, even if one of them says "ok".
        XCTAssertEqual(DatabaseIntegrity.verdict(fromRows: ["ok", "Page 9 is never used"]),
                       "Page 9 is never used")
    }

    /// Swift twin of the Kotlin `DataBackupIntegrityTest` readableComplaint cases: the verdict stays
    /// forensic and verbatim, this is the half a person is shown.
    func testReadableComplaintDropsTheBannerAndKeepsTheDiagnosis() {
        // The reported shape: ONE row carrying the banner, a newline, then the only informative half.
        XCTAssertEqual(
            DatabaseIntegrity.readableComplaint("*** in database main ***\nPage 5 is never used"),
            "Page 5 is never used"
        )
        // Captured from a REAL corrupted SQLite file (pages scribbled over, header left intact) rather
        // than invented: quick_check(1) answers with ONE row holding the banner, a newline, and the
        // diagnosis. The exact shape the reported Toast was truncating.
        XCTAssertEqual(
            DatabaseIntegrity.readableComplaint("*** in database main ***\nTree 2 page 7: btreeInitPage() returns error code 11"),
            "Tree 2 page 7: btreeInitPage() returns error code 11"
        )
        // An attached database names itself, so the match cannot be on "main" alone.
        XCTAssertEqual(
            DatabaseIntegrity.readableComplaint("*** in database temp ***\nPage 9 is never used"),
            "Page 9 is never used"
        )
        // Banner and nothing else: an empty parenthesis would be worse, so the raw verdict survives.
        XCTAssertEqual(
            DatabaseIntegrity.readableComplaint("*** in database main ***"),
            "*** in database main ***"
        )
        // No banner at all: already the diagnosis, passes through untouched.
        XCTAssertEqual(
            DatabaseIntegrity.readableComplaint("row 12 missing from index sleepIdx"),
            "row 12 missing from index sleepIdx"
        )
        XCTAssertEqual(
            DatabaseIntegrity.readableComplaint("*** in database main ***\nPage 5 is never used\nPage 9 is never used"),
            "Page 5 is never used; Page 9 is never used"
        )
        // A nonsense limit must not trap: prefix(-1) is a precondition failure, and a display helper is
        // the last place that should be able to crash a failure path.
        XCTAssertEqual(DatabaseIntegrity.readableComplaint("*** in database main ***\nPage 5", limit: 0).count, 1)
        XCTAssertEqual(DatabaseIntegrity.readableComplaint("*** in database main ***\nPage 5", limit: -5).count, 1)
        // Capped, because this rides inside a sentence that has to stay readable.
        let long = DatabaseIntegrity.readableComplaint("*** in database main ***\n" + String(repeating: "x", count: 500),
                                                      limit: 40)
        XCTAssertEqual(long.count, 40)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
    }
}
