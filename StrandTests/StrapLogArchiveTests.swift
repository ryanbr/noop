import XCTest
@testable import Strand

/// The strap log on disk (`StrapLogArchive`). What it must never do again is what the UserDefaults ring did:
/// lose the lines logged just before a restart, a run's head beyond 1,000 lines, and every run before the
/// last three — which on 21 Sep 2026 cost half an hour of a gym session's log.
final class StrapLogArchiveTests: XCTestCase {

    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrapLogArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A process of NOOP, started `seconds` after t0, writing into the same folder.
    private func process(at seconds: TimeInterval, budget: Int = StrapLogArchive.budgetBytes,
                         segment: Int = StrapLogArchive.segmentBytes) -> StrapLogArchive {
        StrapLogArchive(directory: directory, budgetBytes: budget, segmentBytes: segment,
                        now: t0.addingTimeInterval(seconds))
    }

    private func iso(_ seconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: t0.addingTimeInterval(seconds))
    }

    private func logFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
    }

    /// THE ONE THAT MATTERS: every line reaches disk as it is logged, so a process killed without warning
    /// (it is never closed here) leaves all of them for the next run's export — none held back for a batch.
    func testEveryLineSurvivesARestartWithoutAClose() {
        let killed = process(at: 0)
        for line in ["20:34:01 double-tap", "20:34:02 buzz", "20:34:03 cpu"] { killed.append(line) }

        let next = process(at: 10)
        XCTAssertEqual(next.exportText(), """
            ===== previous app session, 3 line(s), rolled at \(iso(10)) (this launch) =====
            20:34:01 double-tap
            20:34:02 buzz
            20:34:03 cpu
            ===== current app session =====

            """)
        next.append("20:34:12 restored")
        XCTAssertTrue(next.exportText().hasSuffix("===== current app session =====\n20:34:12 restored"))
    }

    /// Four restarts in half an hour keep every run, oldest first, each rolled at the start of the next —
    /// the ring kept only the last three.
    func testEveryRunIsKeptOldestFirstEachRolledAtTheNextStart() {
        for (i, start) in [0.0, 100, 200, 300].enumerated() {
            process(at: start).append("run \(i + 1)")
        }
        let text = process(at: 400).exportText()
        XCTAssertEqual(text, """
            ===== previous app session, 1 line(s), rolled at \(iso(100)) (this launch) =====
            run 1
            ===== previous app session, 1 line(s), rolled at \(iso(200)) (this launch) =====
            run 2
            ===== previous app session, 1 line(s), rolled at \(iso(300)) (this launch) =====
            run 3
            ===== previous app session, 1 line(s), rolled at \(iso(400)) (this launch) =====
            run 4
            ===== current app session =====

            """)
    }

    /// A run longer than a segment is split across files and exported whole, in order — the ring kept a
    /// run's last 1,000 lines, and the screen's buffer keeps 5,000.
    func testALongRunIsSplitIntoSegmentsAndExportedWhole() {
        let archive = process(at: 0, segment: 200)
        let lines = (1...100).map { String(format: "line %03d", $0) }
        for (i, line) in lines.enumerated() {
            archive.append(line)
            if i == 40 { _ = archive.exportText() }              // an export mid-run must not freeze the rest
        }
        XCTAssertGreaterThan(logFiles().count, 1, "the run spans several segments")
        XCTAssertEqual(archive.exportText(), lines.joined(separator: "\n"))
        XCTAssertEqual(process(at: 10).exportText(), """
            ===== previous app session, 100 line(s), rolled at \(iso(10)) (this launch) =====
            \(lines.joined(separator: "\n"))
            ===== current app session =====

            """)
    }

    /// Past the budget the oldest segments go first — never the newest lines — and a run that lost its head
    /// says so, so the missing lines do not read as silence.
    func testPastTheBudgetTheOldestGoFirstAndAClippedRunSaysSo() {
        let old = process(at: 0, budget: 1_000, segment: 200)
        for i in 1...60 { old.append(String(format: "old %02d", i)) }          // 420 bytes, 3 segments
        let recent = process(at: 100, budget: 1_000, segment: 200)
        for i in 1...120 { recent.append(String(format: "new %03d", i)) }     // 960 bytes, 5 segments

        let onDisk = logFiles().reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        XCTAssertLessThanOrEqual(onDisk, 1_000 + 200, "the budget, plus the segment being written")
        let text = process(at: 200, budget: 1_000, segment: 200).exportText()
        XCTAssertTrue(text.contains("new 120"), "the newest line is kept")
        XCTAssertFalse(text.contains("old 01"), "the oldest line is the first to go")
        XCTAssertTrue(text.contains("line(s), head clipped, rolled at"), text)
    }

    /// #1263: Report tapped right after a restart, before the new process has logged a line, still carries
    /// the run before it.
    func testAnExportBeforeTheFirstLineCarriesTheRunBefore() {
        process(at: 0).append("03:14 reconnect storm")
        let text = process(at: 60).exportText()
        XCTAssertTrue(text.contains("03:14 reconnect storm"))
        XCTAssertTrue(text.hasSuffix("===== current app session =====\n"))
    }

    /// Before the first unlock after a boot iOS refuses the files, and that is when a restart after a reboot is
    /// logged. Those lines stay in memory past a segment boundary (#2386 review: they used to vanish there) and
    /// reach disk the moment a file opens, so a later restart keeps them too.
    func testLinesThatCannotBeWrittenWaitAndReachDiskOnceStorageOpens() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let locked = process(at: 0, segment: 200)
        let early = (1...100).map { String(format: "locked %03d", $0) }          // 1,100 bytes: five segments
        for line in early { locked.append(line) }
        XCTAssertTrue(logFiles().isEmpty, "nothing can be written yet")
        XCTAssertEqual(locked.exportText(), early.joined(separator: "\n"))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let later = (1...64).map { String(format: "unlocked %02d", $0) }         // the next open attempt comes within 64
        for line in later { locked.append(line) }
        XCTAssertEqual(locked.exportText(), (early + later).joined(separator: "\n"))
        XCTAssertEqual(process(at: 10, segment: 200).exportText(), """
            ===== previous app session, 164 line(s), rolled at \(iso(10)) (this launch) =====
            \((early + later).joined(separator: "\n"))
            ===== current app session =====

            """)
    }

    /// While nothing can be written, memory holds the newest lines within the budget; once they reach disk the run
    /// says it lost its head.
    func testAnUnwrittenBacklogStaysWithinTheBudgetAndSaysItsHeadWasClipped() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let locked = process(at: 0, budget: 1_000, segment: 200)
        for i in 1...200 { locked.append(String(format: "locked %03d", i)) }     // 2,200 bytes
        let held = locked.exportText()
        XCTAssertLessThanOrEqual(held.utf8.count, 1_000)
        XCTAssertTrue(held.hasSuffix("locked 200"), "the newest line is kept")
        XCTAssertFalse(held.contains("locked 001"), "the oldest line is the first to go")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for i in 1...64 { locked.append(String(format: "open %02d", i)) }
        XCTAssertTrue(process(at: 10, budget: 1_000, segment: 200).exportText().contains("head clipped"))
    }

    func testNothingLoggedExportsNothing() {
        XCTAssertEqual(process(at: 0).exportText(), "")
    }

    /// The ring's lines are carried over once, ahead of every run, exactly as its export printed them.
    func testTheRingIsCarriedOverOnceAheadOfEveryRun() {
        let ring = StrapLogArchive.legacyRingLines(
            generations: [["===== previous app session, 1 line(s), rolled at 2026-09-20T10:00:00Z (this launch) =====",
                           "old run"]],
            tail: ["unrolled tail"], now: t0)
        XCTAssertEqual(ring, [
            "===== previous app session, 1 line(s), rolled at 2026-09-20T10:00:00Z (this launch) =====",
            "old run",
            "===== previous app session, 1 line(s), rolled at \(iso(0)) (this launch) =====",
            "unrolled tail",
        ])
        let first = process(at: 0)
        first.importLegacy(ring)
        first.append("first line on disk")
        let later = process(at: 50)
        later.importLegacy(["must not be written twice"])
        XCTAssertEqual(later.exportText(), (ring + [
            "===== previous app session, 1 line(s), rolled at \(iso(50)) (this launch) =====",
            "first line on disk",
            "===== current app session =====",
            "",
        ]).joined(separator: "\n"))
    }
}
