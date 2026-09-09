import XCTest
import WhoopStore
import WhoopProtocol
@testable import Strand

/// Pins the pure logic behind the #155 Shortcuts drop file (Documents/noop_sync.txt): the exact
/// `HR,HRV,Steps,yyyy-MM-dd HH:mm` line shape the reporter's pre-built Siri Shortcut parses (empty
/// fields keep their commas, 1-decimal HRV, LOCAL-zone timestamp), the 15-minute windowing, the
/// cumulative-u16 step delta math, and the advance-only-on-success watermark — a watermark that
/// moved past a failed write would silently drop that span from Apple Health forever.
final class ShortcutHealthExportTests: XCTestCase {

    /// A synthetic bucket whose extremes equal its mean.
    ///
    /// The export path reads only `bpm`, so a spread inside the bucket is not what these tests are
    /// about. Written once here rather than repeated at every call site, and deliberately NOT a default
    /// on `HRBucket` itself: production builds those from `MIN(bpm)`/`MAX(bpm)`, and a type-level default
    /// would let a real one silently claim its mean as its range, which is the bug #2032 was.
    private func flatBucket(ts: Int, bpm: Double) -> HRBucket {
        HRBucket(ts: ts, bpm: bpm, minBpm: bpm, maxBpm: bpm)
    }

    private let utc = TimeZone(secondsFromGMT: 0)!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var dir: URL!

    override func setUpWithError() throws {
        suiteName = "ShortcutHealthExportTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
    }

    private typealias Window = ShortcutHealthExport.Window

    private struct FakeReads: ShortcutExportReads {
        var hr: [HRBucket] = []
        var rr: [RRInterval] = []
        var steps: [StepSample] = []
        var error: Error? = nil
        struct Boom: Error {}

        func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket] {
            if let error { throw error }
            return hr
        }
        func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval] {
            if let error { throw error }
            return rr
        }
        func stepSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [StepSample] {
            if let error { throw error }
            return steps
        }
    }

    private func fileText() throws -> String {
        try String(contentsOf: dir.appendingPathComponent(ShortcutHealthExport.fileName), encoding: .utf8)
    }

    // MARK: - Line formatting

    func testLineAllFields() {
        let w = Window(start: 0, hr: 62, hrvMs: 45.27, steps: 120)
        XCTAssertEqual(ShortcutHealthExport.line(w, timeZone: utc), "62,45.3,120,1970-01-01 00:00")
    }

    // Empty fields MUST keep their commas — the Shortcut splits by comma and relies on fixed
    // column positions.
    func testEmptyFieldsKeepCommas() {
        XCTAssertEqual(ShortcutHealthExport.line(Window(start: 0, hrvMs: 45.27, steps: 120), timeZone: utc),
                       ",45.3,120,1970-01-01 00:00")
        XCTAssertEqual(ShortcutHealthExport.line(Window(start: 0, hr: 62, steps: 120), timeZone: utc),
                       "62,,120,1970-01-01 00:00")
        XCTAssertEqual(ShortcutHealthExport.line(Window(start: 0, hr: 62, hrvMs: 45.27), timeZone: utc),
                       "62,45.3,,1970-01-01 00:00")
        XCTAssertEqual(ShortcutHealthExport.line(Window(start: 0, hr: 62), timeZone: utc),
                       "62,,,1970-01-01 00:00")
    }

    // HRV always renders with exactly 1 decimal, even when whole.
    func testHRVOneDecimal() {
        XCTAssertEqual(ShortcutHealthExport.line(Window(start: 0, hrvMs: 33.0), timeZone: utc),
                       ",33.0,,1970-01-01 00:00")
    }

    // ISO date order, in the GIVEN zone — production passes the device-local zone, so the same
    // instant renders an hour later one zone east.
    func testTimestampUsesGivenZone() {
        XCTAssertEqual(ShortcutHealthExport.timestamp(900, timeZone: utc), "1970-01-01 00:15")
        XCTAssertEqual(ShortcutHealthExport.timestamp(900, timeZone: TimeZone(secondsFromGMT: 3600)!),
                       "1970-01-01 01:15")
    }

    // No header, no trailing newline (a trailing "\n" gives split-by-newline an empty last row).
    func testRenderJoinsWithoutHeaderOrTrailingNewline() {
        let text = ShortcutHealthExport.render(
            [Window(start: 0, hr: 60), Window(start: 900, hr: 61)], timeZone: utc)
        XCTAssertEqual(text, "60,,,1970-01-01 00:00\n61,,,1970-01-01 00:15")
        XCTAssertEqual(ShortcutHealthExport.render([], timeZone: utc), "")
    }

    // MARK: - 15-minute windowing

    func testAggregateBucketsHRIntoWindowsAscending() {
        // hrBuckets(900) keys are already the window starts; bpm means round half-up.
        let hr = [flatBucket(ts: 900, bpm: 61.5), flatBucket(ts: 0, bpm: 61.4)]
        let windows = ShortcutHealthExport.aggregate(hr: hr, rr: [], steps: [], end: 1800)
        XCTAssertEqual(windows, [Window(start: 0, hr: 61), Window(start: 900, hr: 62)])
    }

    // Only windows holding ≥1 value are emitted — an empty middle window produces NO line.
    func testAggregateSkipsEmptyWindows() {
        let hr = [flatBucket(ts: 0, bpm: 60), flatBucket(ts: 1800, bpm: 70)]
        let windows = ShortcutHealthExport.aggregate(hr: hr, rr: [], steps: [], end: 2700)
        XCTAssertEqual(windows.map(\.start), [0, 1800])
    }

    // Data at/after `end` (the still-open window) is excluded — it would otherwise be frozen
    // partial and never revisited once the watermark advances.
    func testAggregateExcludesOpenWindow() {
        let hr = [flatBucket(ts: 0, bpm: 60), flatBucket(ts: 900, bpm: 70)]
        let windows = ShortcutHealthExport.aggregate(hr: hr, rr: [], steps: [], end: 900)
        XCTAssertEqual(windows, [Window(start: 0, hr: 60)])
    }

    // RMSSD per window: 30 alternating 800/810 ms intervals → successive diffs all ±10 → RMSSD
    // exactly 10. All beats survive the range + Malik filters.
    func testAggregateRMSSDPerWindow() {
        let rr = (0..<30).map { RRInterval(ts: 10 + $0, rrMs: $0 % 2 == 0 ? 800 : 810) }
        let windows = ShortcutHealthExport.aggregate(hr: [], rr: rr, steps: [], end: 900)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, 0)
        XCTAssertEqual(windows[0].hrvMs ?? .nan, 10.0, accuracy: 1e-9)
    }

    // Below HRVAnalyzer.minBeats (20) clean intervals the window has no HRV — and with no other
    // values it is not emitted at all.
    func testAggregateInsufficientBeatsEmitNothing() {
        let rr = (0..<10).map { RRInterval(ts: 10 + $0, rrMs: 800) }
        XCTAssertTrue(ShortcutHealthExport.aggregate(hr: [], rr: rr, steps: [], end: 900).isEmpty)
    }

    // RR intervals split across two windows are analyzed per window, not pooled.
    func testAggregateRMSSDSplitsAcrossWindows() {
        let w0 = (0..<30).map { RRInterval(ts: 100 + $0, rrMs: $0 % 2 == 0 ? 800 : 810) }
        let w1 = (0..<30).map { RRInterval(ts: 1000 + $0, rrMs: $0 % 2 == 0 ? 900 : 920) }
        let windows = ShortcutHealthExport.aggregate(hr: [], rr: w0 + w1, steps: [], end: 1800)
        XCTAssertEqual(windows.map(\.start), [0, 900])
        XCTAssertEqual(windows[0].hrvMs ?? .nan, 10.0, accuracy: 1e-9)
        XCTAssertEqual(windows[1].hrvMs ?? .nan, 20.0, accuracy: 1e-9)
    }

    // MARK: - Step wrap math (the established @57 cumulative-u16 rules)

    func testStepWrapAddsU16Modulus() {
        // 65530 → 10 is a wrap: corrected delta = 10 - 65530 + 65536 = 16 steps.
        let steps = [StepSample(ts: 100, counter: 65_530), StepSample(ts: 200, counter: 10)]
        let windows = ShortcutHealthExport.aggregate(hr: [], rr: [], steps: steps, end: 900)
        XCTAssertEqual(windows, [Window(start: 0, steps: 16)])
    }

    func testStepResetDeltaDropped() {
        // +49900 in one step gap is a firmware reset artifact (> 30000), not steps.
        let steps = [StepSample(ts: 100, counter: 100), StepSample(ts: 200, counter: 50_000)]
        XCTAssertTrue(ShortcutHealthExport.aggregate(hr: [], rr: [], steps: steps, end: 900).isEmpty)
    }

    func testStepZeroDeltaIgnored() {
        let steps = [StepSample(ts: 100, counter: 500), StepSample(ts: 200, counter: 500)]
        XCTAssertTrue(ShortcutHealthExport.aggregate(hr: [], rr: [], steps: steps, end: 900).isEmpty)
    }

    // A delta lands in the window of the LATER sample — that's when the increment was observed.
    func testStepDeltaLandsInLaterSamplesWindow() {
        let steps = [StepSample(ts: 800, counter: 0), StepSample(ts: 1000, counter: 50),
                     StepSample(ts: 1100, counter: 80)]
        let windows = ShortcutHealthExport.aggregate(hr: [], rr: [], steps: steps, end: 1800)
        XCTAssertEqual(windows, [Window(start: 900, steps: 80)])
    }

    // MARK: - Coverage span

    func testCoverageSpanExcludesOpenWindow() {
        // now=2699 sits inside [1800, 2700) — that window is open, so coverage ends at 1800.
        let span = ShortcutHealthExport.coverageSpan(nowTs: 2699, watermark: 0)
        XCTAssertEqual(span.from, 0)
        XCTAssertEqual(span.end, 1800)
    }

    func testCoverageSpanStartsAtWatermark() {
        let span = ShortcutHealthExport.coverageSpan(nowTs: 1_000_000, watermark: 999_000)
        XCTAssertEqual(span.from, 999_000)
        XCTAssertEqual(span.end, 999_900)
    }

    func testCoverageSpanClampsToSevenDays() {
        // Stale watermark (or first run): never reach further back than 7 days.
        let now = 2_000_000_700
        let span = ShortcutHealthExport.coverageSpan(nowTs: now, watermark: 0)
        XCTAssertEqual(span.from, now - 7 * 86_400)
        XCTAssertEqual(span.end, (now / 900) * 900)
    }

    // MARK: - Export + watermark (advance only on success)

    func testExportWritesFileAndAdvancesWatermark() async throws {
        let source = FakeReads(hr: [flatBucket(ts: 0, bpm: 62)])
        let outcome = await ShortcutHealthExport.export(
            source: source, deviceId: "dev", now: Date(timeIntervalSince1970: 10_000),
            defaults: defaults, directory: dir, timeZone: utc)
        XCTAssertEqual(outcome, .written(lines: 1))
        XCTAssertEqual(try fileText(), "62,,,1970-01-01 00:00")
        XCTAssertEqual(defaults.integer(forKey: ShortcutHealthExport.watermarkKey), 9_900)
    }

    func testExportReadFailureLeavesWatermarkAndFile() async {
        let source = FakeReads(error: FakeReads.Boom())
        let outcome = await ShortcutHealthExport.export(
            source: source, deviceId: "dev", now: Date(timeIntervalSince1970: 10_000),
            defaults: defaults, directory: dir, timeZone: utc)
        guard case .failure = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        XCTAssertEqual(defaults.integer(forKey: ShortcutHealthExport.watermarkKey), 0)
        XCTAssertThrowsError(try fileText(), "no file may appear on a failed export")
    }

    func testExportWriteFailureLeavesWatermark() async {
        // Destination directory doesn't exist → the atomic write throws → watermark must not move.
        let missing = dir.appendingPathComponent("nope")
        let source = FakeReads(hr: [flatBucket(ts: 0, bpm: 62)])
        let outcome = await ShortcutHealthExport.export(
            source: source, deviceId: "dev", now: Date(timeIntervalSince1970: 10_000),
            defaults: defaults, directory: missing, timeZone: utc)
        guard case .failure = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        XCTAssertEqual(defaults.integer(forKey: ShortcutHealthExport.watermarkKey), 0)
    }

    func testExportNothingNewWhenWatermarkCoversNow() async throws {
        defaults.set(9_900, forKey: ShortcutHealthExport.watermarkKey)
        let outcome = await ShortcutHealthExport.export(
            source: FakeReads(hr: [flatBucket(ts: 0, bpm: 62)]), deviceId: "dev",
            now: Date(timeIntervalSince1970: 10_000),
            defaults: defaults, directory: dir, timeZone: utc)
        XCTAssertEqual(outcome, .nothingNew)
        XCTAssertEqual(defaults.integer(forKey: ShortcutHealthExport.watermarkKey), 9_900)
        // Nothing-new TRUNCATES (not skips): a stale file would be re-imported by the Shortcut's
        // every-app-close automation, duplicating rows into Apple Health (#167).
        XCTAssertEqual(try fileText(), "")
    }

    // The #167 duplication repro: rows exported → app closes again with no new complete window →
    // the file must be EMPTY, or the Shortcut re-imports the previous rows on every automation run.
    func testNothingNewTruncatesStaleFileSoShortcutCannotReimport() async throws {
        _ = await ShortcutHealthExport.export(
            source: FakeReads(hr: [flatBucket(ts: 0, bpm: 62)]), deviceId: "dev",
            now: Date(timeIntervalSince1970: 10_000),
            defaults: defaults, directory: dir, timeZone: utc)
        XCTAssertEqual(try fileText(), "62,,,1970-01-01 00:00")
        let second = await ShortcutHealthExport.export(
            source: FakeReads(hr: [flatBucket(ts: 0, bpm: 62)]), deviceId: "dev",
            now: Date(timeIntervalSince1970: 10_060),   // +60s — same 15-min window, nothing new
            defaults: defaults, directory: dir, timeZone: utc)
        XCTAssertEqual(second, .nothingNew)
        XCTAssertEqual(try fileText(), "", "stale rows must not survive a nothing-new export (#167)")
    }

    // Full-file REPLACE: the second export's file contains only the new span — never an append
    // (the Shortcut has no dedup; re-offered lines would be double-logged into Health).
    func testExportReplacesWholeFile() async throws {
        _ = await ShortcutHealthExport.export(
            source: FakeReads(hr: [flatBucket(ts: 0, bpm: 62)]), deviceId: "dev",
            now: Date(timeIntervalSince1970: 10_000),
            defaults: defaults, directory: dir, timeZone: utc)
        let outcome = await ShortcutHealthExport.export(
            source: FakeReads(hr: [flatBucket(ts: 9_900, bpm: 70)]), deviceId: "dev",
            now: Date(timeIntervalSince1970: 20_000),
            defaults: defaults, directory: dir, timeZone: utc)
        XCTAssertEqual(outcome, .written(lines: 1))
        XCTAssertEqual(try fileText(), "70,,,1970-01-01 02:45")
        XCTAssertEqual(defaults.integer(forKey: ShortcutHealthExport.watermarkKey), 19_800)
    }

    func testResetWatermark() {
        defaults.set(12_345, forKey: ShortcutHealthExport.watermarkKey)
        ShortcutHealthExport.resetWatermark(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: ShortcutHealthExport.watermarkKey), 0)
    }
}
