import XCTest
import StrandAnalytics
@testable import Strand

/// BUNDLE ROBUSTNESS (Lane 1, task 3): the raw-capture, the crash log and the Display screenshot reliably
/// attach to the export bundle and EVERY text entry is run through redaction. Plus the universal
/// clock-drift line and the assembler's active-domain view. The full @MainActor assemble() reaches into
/// Bundle.main / DisplayScreenshot / UserDefaults, so these drive the pure gather helpers and the redaction
/// invariant directly (the path that actually composes the shipped bytes).
final class TestBundleRobustnessTests: XCTestCase {

    // MARK: - raw-capture / crash gather

    func testFileEntryReadsAnExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("noop-raw-\(UUID()).jsonl")
        let body = "{\"console\":\"connected to WHOOP 4C1594026\"}"
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = TestBundleAssembler.fileEntry(at: tmp, name: "raw-capture.jsonl")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.name, "raw-capture.jsonl")
    }

    func testFileEntryReturnsNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID())")
        XCTAssertNil(TestBundleAssembler.fileEntry(at: missing, name: "raw-capture.jsonl"))
    }

    func testRawCaptureAndCrashAreRedactedThroughTheWholeBundlePass() {
        // A serial embedded in raw-capture console text AND in a crash log must both be scrubbed by the
        // single whole-bundle redact pass the assembler applies to every text entry.
        let raw = FileExport.BundleEntry(name: "raw-capture.jsonl",
                                         data: Data("{\"c\":\"WHOOP 4C1594026 ok\"}".utf8))
        let crash = FileExport.BundleEntry(name: "last-crash.txt",
                                           data: Data("Fatal: peer WHOOP 5A9988776 lost".utf8))
        let report = FileExport.BundleEntry(name: "report.txt", data: Data("clean".utf8))
        let scrubbed = TestBundleAssembler.redactEntries([report, raw, crash])
        let rawText = String(data: scrubbed.first { $0.name == "raw-capture.jsonl" }!.data, encoding: .utf8)!
        let crashText = String(data: scrubbed.first { $0.name == "last-crash.txt" }!.data, encoding: .utf8)!
        XCTAssertFalse(rawText.contains("4C1594026"))
        XCTAssertFalse(crashText.contains("5A9988776"))
        XCTAssertTrue(rawText.contains("WHOOP <serial>"))
        XCTAssertTrue(crashText.contains("WHOOP <serial>"))
    }

    func testCrashLogURLLivesInCaches() {
        let url = TestBundleAssembler.crashLogURL()
        XCTAssertEqual(url?.lastPathComponent, "noop-last-crash.txt")
        XCTAssertTrue(url?.path.contains("Caches") ?? false, "crash log must live in the caches dir (not iCloud)")
    }

    // MARK: - universal clock-drift

    func testUniversalClockDriftLineFromSnapshot() {
        let wall = 1782604800
        let range = LiveState.StrapRange(newestUnix: wall + 3_600, oldestUnix: wall - 86_400, firmwareLayout: 26)
        let line = TestBundleAssembler.universalClockDriftLine(range: range, now: wall)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("FUTURE-DATED"))
        XCTAssertTrue(line!.contains("firmware=v26"))
    }

    func testUniversalClockDriftNilWhenNoRange() {
        XCTAssertNil(TestBundleAssembler.universalClockDriftLine(range: nil, now: 1782604800))
    }

    func testUniversalClockDriftNilForFirmwareOnlySnapshot() {
        // A firmware-only snapshot (newest==0, no real window) must not synthesise a bogus 1970 line.
        let range = LiveState.StrapRange(newestUnix: 0, oldestUnix: nil, firmwareLayout: 25)
        XCTAssertNil(TestBundleAssembler.universalClockDriftLine(range: range, now: 1782604800))
    }

    // MARK: - active-domain view

    @MainActor
    func testActiveDomainsIncludesUniversalOnlyWhenAModeIsOn() {
        // Isolate UserDefaults so the suite doesn't depend on ambient Test Centre state.
        let defaults = UserDefaults.standard
        let keys = TestDomain.allCases.map { "testcentre.active.\($0.id)" }
        let prior = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let key = "testcentre.active.sleep"

        defaults.set(false, forKey: key)
        XCTAssertFalse(TestBundleAssembler.activeDomains().contains(.universal),
                       "no mode on => universal not graded")

        defaults.set(true, forKey: key)
        let active = TestBundleAssembler.activeDomains()
        XCTAssertTrue(active.contains(.sleep))
        XCTAssertTrue(active.contains(.universal), "any mode on => universal rides the export")
    }
}
