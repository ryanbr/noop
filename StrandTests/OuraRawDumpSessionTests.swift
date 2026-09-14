import XCTest
@testable import Strand

/// The raw Oura sidecar is scoped to ONE capture session (option 1 of the 2026-08-09 sidecar decision),
/// and completed sessions are kept in a numbered generation ring (the 2026-08-10 follow-up).
///
/// These pin two properties, each bought with a lost night of raw evidence:
///   * the live file is never rolled part-way through a session — a 25 MB threshold fired mid-drain at
///     07:06:58 on 2026-08-09 and carried 71 of the night's 75 `0x5D` records out of the export;
///   * a session boundary does not evict a real capture — one-deep retention lost the 2026-08-10 night
///     because the app relaunched twice after wake (07:45, 08:17), filling both slots with sessions of
///     87 KB and 44 KB.
final class OuraRawDumpSessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oura-raw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func live() -> URL { dir.appendingPathComponent("oura-raw-ring1.jsonl") }
    private func previous() -> URL { generation(1) }
    private func generation(_ index: Int) -> URL {
        dir.appendingPathComponent("oura-raw-ring1.jsonl.\(index)")
    }
    private func lines(_ url: URL) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    }

    /// A session big enough to be worth a generation slot (>= `minRolledBytes`), tagged so it can be
    /// identified after rolling. `repeat` is load-bearing: a fresh `OuraRawDump` has not resolved its file
    /// yet, so before the FIRST record the live file still holds the previous session — a leading size
    /// check would see it already "full" and write nothing at all.
    private func writeSubstantialSession(tag: UInt8) {
        let dump = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        let payload = [tag] + [UInt8](repeating: 0x00, count: 512)
        repeat { dump.record(bytes: payload) } while size(live()) < OuraRawDump.minRolledBytes
    }

    /// The `hex` field of a file's first record. Read the FIELD, never the whole line: the line also carries
    /// a unix `utc` and an ISO stamp, and a substring search for a tag like "22" hits those constantly.
    private func firstHex(_ url: URL) -> String? {
        guard let line = lines(url).first,
              let range = line.range(of: "\"hex\":\"") else { return nil }
        return line[range.upperBound...].prefix(while: { $0 != "\"" }).description
    }

    func testOneSessionKeepsEveryRecordInTheLiveFile() {
        let dump = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        for i in 0..<500 { dump.record(bytes: [0x5D, UInt8(i % 256), 0x01, 0x02]) }
        // The whole session is in ONE file, and nothing was rolled aside part-way through.
        XCTAssertEqual(lines(live()).count, 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous().path))
    }

    func testANewSessionRollsThePreviousOneAsideAndStartsEmpty() {
        writeSubstantialSession(tag: 0xAA)
        let rolledLineCount = lines(live()).count
        XCTAssertGreaterThan(rolledLineCount, 0)

        // A new object is a new session (one is built per OuraLiveSource).
        let second = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        second.record(bytes: [0xBB])

        XCTAssertEqual(lines(live()).count, 1, "the live file is THIS session only")
        XCTAssertEqual(lines(previous()).count, rolledLineCount, "the previous session is retained as .1")
        XCTAssertTrue(lines(live())[0].contains("bb"), "the live file holds the new session's bytes")
        XCTAssertEqual(firstHex(previous())?.prefix(2), "aa")
    }

    /// THE 2026-08-10 REGRESSION TEST. Two ordinary post-wake app relaunches must not be able to reach back
    /// and destroy the night: with one-deep retention this is exactly what happened.
    func testAnOvernightSessionSurvivesTwoRestartsAfterWake() {
        writeSubstantialSession(tag: 0x11)                   // "the night"
        writeSubstantialSession(tag: 0x22)                   // 07:45 relaunch
        writeSubstantialSession(tag: 0x33)                   // 08:17 relaunch
        let export = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        export.record(bytes: [0xFF])                         // the session the export is taken during

        XCTAssertEqual(firstHex(live()), "ff")
        XCTAssertEqual(firstHex(generation(1))?.prefix(2), "33")
        XCTAssertEqual(firstHex(generation(2))?.prefix(2), "22")
        XCTAssertEqual(firstHex(generation(3))?.prefix(2), "11", "the night is still on disk")
    }

    func testTheGenerationRingIsBoundedAtRetainedGenerations() {
        for _ in 0..<(OuraRawDump.retainedGenerations + 4) { writeSubstantialSession(tag: 0x55) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let ours = files.filter { $0.hasPrefix("oura-raw-ring1.jsonl") }
        XCTAssertEqual(ours.count, OuraRawDump.retainedGenerations + 1,
                       "the live file plus exactly \(OuraRawDump.retainedGenerations) generations")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: generation(OuraRawDump.retainedGenerations + 1).path))
    }

    /// The rule that makes the ring worth having: a connect that captured essentially nothing is DELETED,
    /// not rolled, so a burst of trivial reconnect sessions cannot flush a real capture out of the ring.
    func testATrivialSessionIsDiscardedRatherThanSpendingAGeneration() {
        writeSubstantialSession(tag: 0xAA)                   // the capture worth keeping

        for _ in 0..<4 {                                     // four near-empty sessions
            let tiny = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
            tiny.record(bytes: [0xBB])
        }
        let final = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        final.record(bytes: [0xCC])

        XCTAssertEqual(firstHex(live()), "cc")
        XCTAssertEqual(firstHex(previous())?.prefix(2), "aa",
                       "the real session is still .1 — no trivial session took a slot")
        XCTAssertFalse(FileManager.default.fileExists(atPath: generation(2).path))
    }

    func testAnEmptyLeftoverIsReusedRatherThanSpendingARetainedGeneration() {
        // Build the state a killed session leaves behind: `.1` holds a REAL session, and the live file was
        // created but never written to (0 bytes). Rolling that empty file would push the real capture down
        // the ring for nothing.
        writeSubstantialSession(tag: 0xAA)
        let sessionB = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        sessionB.record(bytes: [0xBB])                       // rolls A aside
        XCTAssertEqual(firstHex(previous())?.prefix(2), "aa")
        FileManager.default.createFile(atPath: live().path, contents: Data())  // B left nothing behind

        let sessionC = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        sessionC.record(bytes: [0xCC])

        XCTAssertEqual(lines(live()).count, 1)
        XCTAssertTrue(lines(live())[0].contains("cc"))
        XCTAssertEqual(firstHex(previous())?.prefix(2), "aa",
                       "the real previous session survived an empty leftover")
    }

    func testASessionThatReceivesNothingTouchesNoFilesAtAll() {
        let sessionA = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        sessionA.record(bytes: [0xAA])
        // A source that comes up and never gets a record never resolves, so it cannot roll anything.
        let silent = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        silent.record(bytes: [])                             // empty input is a no-op
        XCTAssertEqual(lines(live()).count, 1)
        XCTAssertTrue(lines(live())[0].contains("aa"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous().path))
    }

    func testCeilingStopsAppendingAndNeverRollsMidSession() {
        let dump = OuraRawDump(deviceId: "ring1", log: { _ in }, directory: dir)
        // One record is far under the ceiling, so drive the counter with a payload sized to cross it.
        let big = [UInt8](repeating: 0xEE, count: 64 * 1024)
        for _ in 0..<(OuraRawDump.maxSessionBytes / (128 * 1024) + 8) { dump.record(bytes: big) }

        let size = (try? FileManager.default.attributesOfItem(atPath: live().path))?[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(size, OuraRawDump.maxSessionBytes, "the ceiling bounds the session")
        XCTAssertGreaterThan(size, 0)
        // The critical property: hitting the ceiling must NOT roll the file, or we recreate the 2026-08-09
        // bug at a different threshold.
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous().path))
    }
}
