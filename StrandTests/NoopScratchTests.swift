import XCTest
@testable import Strand

/// The temp sweep removes only what NOOP wrote, never a sibling it found (#2446).
///
/// The sweep used to take every item in the temporary directory whose name began `noop-`, on the
/// premise that "the temp dir is NOOP's private sandbox". That is true on iOS and false on the shipped
/// Mac build, which is ad-hoc signed with no entitlements and so is not sandboxed: its temporary
/// directory is the shared per-user one. The reporter lost a live `xcodebuild`'s derived data to it.
///
/// These run against an injected root rather than the real temporary directory, which is also the
/// reason the old sweep had no tests: it read `FileManager.default.temporaryDirectory` directly, so
/// there was no way to exercise it without deleting the tester's own files.
final class NoopScratchTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("noop-scratch-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    /// `age` seconds old, so the 60 s in-flight guard can be exercised both ways.
    @discardableResult
    private func make(_ name: String, directory: Bool = false, age: TimeInterval = 3600) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: directory)
        if directory {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("inner.txt"))
        } else {
            try Data("x".utf8).write(to: url)
        }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                             ofItemAtPath: url.path)
        return url
    }

    private func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    /// The reported case, verbatim: another program's `noop-*` items must survive the sweep.
    func testASiblingNoopItemThisAppDidNotWriteSurvives() throws {
        try make("noop-canary-a", directory: true)
        try make("noop-verify", directory: true)
        try make("noop-measure", directory: true)
        try make("canary-b-noop", directory: true)

        NoopScratch.purge(in: root)

        XCTAssertTrue(exists("noop-canary-a"), "#2446: a sibling NOOP never wrote was deleted")
        XCTAssertTrue(exists("noop-verify"), "#2446: the reporter's verification folder was deleted")
        XCTAssertTrue(exists("noop-measure"), "#2446: the reporter's measurement folder was deleted")
        XCTAssertTrue(exists("canary-b-noop"))
    }

    /// Everything inside the owned folder is NOOP's, so it goes without being matched by name.
    func testEverythingInsideTheOwnedFolderIsReclaimed() throws {
        let mine = NoopScratch.directory(in: root)
        for name in ["health-1.xml", "import-2", "anything-at-all.bin"] {
            let url = mine.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                 ofItemAtPath: url.path)
        }

        NoopScratch.purge(in: root)

        let left = try fm.contentsOfDirectory(at: mine, includingPropertiesForKeys: nil)
        XCTAssertEqual([], left.map(\.lastPathComponent))
    }

    /// The 60 s in-flight guard still protects a running import or export.
    func testAnInFlightFileInsideTheFolderIsKept() throws {
        let mine = NoopScratch.directory(in: root)
        let live = mine.appendingPathComponent("health-live.xml")
        try Data("x".utf8).write(to: live)   // just written, so inside the guard

        NoopScratch.purge(in: root)

        XCTAssertTrue(fm.fileExists(atPath: live.path), "a live import was pulled out from under itself")
    }

    /// Flat scratch an EARLIER build wrote is still reclaimed, so #590's multi-GB extraction does not
    /// become permanent once the folder is owned.
    func testLegacyFlatScratchThisAppWroteIsStillReclaimed() throws {
        try make("noop-health-\(UUID().uuidString).xml")
        try make("noop-import-\(UUID().uuidString)", directory: true)
        try make("noop-rhythm.csv")

        NoopScratch.purge(in: root)

        let left = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertEqual([], left, "legacy scratch this app wrote should still be reclaimed")
    }

    /// The legacy predicate must recognise only names this app actually staged in TEMP. The crash log
    /// and the scheduled raw capture live in caches and documents, so matching them here would start
    /// deleting in directories the sweep never owned.
    func testTheLegacyPredicateIsNarrow() {
        for mine in ["noop-health-x.xml", "noop-import-x", "noop-xiaomi-x", "noop-rhythm.csv",
                     "noop-export-2026-09-25.zip", "noop-strap-log-260617-1042.txt"] {
            XCTAssertTrue(NoopScratch.isLegacyFlatScratch(mine), "\(mine) should be reclaimed")
        }
        for theirs in ["noop-verify", "noop-measure", "noop-canary-a", "noop", "noop-",
                       "noop-last-crash.txt", "noop-raw-capture-260617.json"] {
            XCTAssertFalse(NoopScratch.isLegacyFlatScratch(theirs), "\(theirs) is not ours to delete")
        }
    }

    /// The three writers outside the app target must name the SAME folder this owns.
    ///
    /// `StrandImport` and `WhoopStore` cannot see `NoopScratch`, so they spell the folder themselves.
    /// Three independent spellings of one name is a drift waiting to happen, and a drift here is not
    /// cosmetic: a writer staging into a folder the sweep does not own leaks forever, and one staging
    /// into a folder it does not own hands its files to someone else's sweep.
    func testThePackageWritersSpellTheSameFolder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let expected = #"(Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".scratch""#
        for relative in [
            "Packages/StrandImport/Sources/StrandImport/AppleHealthImporter.swift",
            "Packages/StrandImport/Sources/StrandImport/XiaomiBandImporter.swift",
            "Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertTrue(source.contains(expected),
                          "\(relative) does not stage into the folder NoopScratch sweeps")
        }
        // And the app side is the same expression, so the tripwire above cannot pass while this drifts.
        XCTAssertEqual(NoopScratch.folderName,
                       (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".scratch")
    }

    /// The Storage screen must not attribute another program's disk to NOOP.
    func testSizeCountsOnlyWhatTheSweepWouldReclaim() throws {
        let mine = NoopScratch.directory(in: root)
        try Data(repeating: 0, count: 100).write(to: mine.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("noop-rhythm.csv"))
        try Data(repeating: 0, count: 5000).write(to: root.appendingPathComponent("noop-verify.log"))

        let counted = NoopScratch.sizeBytes(in: root) { url in
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if vals?.isDirectory == true {
                let inner = (try? self.fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                return inner.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            }
            return Int64(vals?.fileSize ?? 0)
        }

        XCTAssertEqual(110, counted, "the 5000-byte sibling is not NOOP's scratch")
    }
}
