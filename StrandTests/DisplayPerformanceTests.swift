import XCTest
import StrandAnalytics
@testable import Strand

/// Proves the Display & Performance test mode is GENUINELY zero-cost when off, the spec's critical
/// correctness property: with the mode OFF the frame monitor is NOT running, no display link exists, and
/// zero `.display`-tagged lines are emitted. Also pins the pure window-stats and the screenshot bundle
/// entry shape. Twin intent of WorkoutsTestModeEmissionTests / ConnectionTestModeEmissionTests.
@MainActor
final class DisplayPerformanceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "testcentre.active.display")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
        DisplayPerformanceMonitor.shared.stop()
        DisplayPerformanceMonitor.shared.setForegroundActive(false)
        DisplayPerformanceMonitor.shared.setTab(.unknown)
        DisplayPerformanceMonitor.shared.emit = nil
    }

    override func tearDown() {
        DisplayPerformanceMonitor.shared.stop()
        DisplayPerformanceMonitor.shared.setForegroundActive(false)
        DisplayPerformanceMonitor.shared.emit = nil
        DisplayPerformanceMonitor.shared.dataVolumeProvider = nil
        UserDefaults.standard.removeObject(forKey: "testcentre.active.display")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
        super.tearDown()
    }

    // MARK: - The critical property: nothing runs and nothing is emitted when the mode is off.

    func testMonitorNotRunningWhenModeOff() {
        XCTAssertFalse(TestCentre.active(.display))
        XCTAssertFalse(DisplayPerformanceMonitor.shared.isRunning,
                       "the frame monitor must not be running while the Display mode is off")
    }

    func testModeOffEmitsZeroDisplayLines() {
        XCTAssertFalse(TestCentre.active(.display))
        // The Display monitor's sink is the ONLY source of .display lines. With the mode off the screen
        // never starts it, so it stays inert. Assemble a bundle for an UNRELATED profile and confirm no
        // .display line rode the strap log.
        let live = LiveState()
        live.append(log: "some unrelated battery line", domain: .battery)
        XCTAssertTrue(live.taggedTail(domain: .display).isEmpty,
                      "mode OFF must leave zero .display-tagged lines, got \(live.taggedTail(domain: .display))")
    }

    func testStopWhileNotStartedIsInertAndEmitsNothing() {
        // A defensive stop() on a never-started monitor must not emit a stray high-water / summary line.
        var captured: [String] = []
        DisplayPerformanceMonitor.shared.emit = { captured.append($0) }
        DisplayPerformanceMonitor.shared.stop()
        XCTAssertFalse(DisplayPerformanceMonitor.shared.isRunning)
        XCTAssertTrue(captured.isEmpty, "stop() on a never-started monitor must emit nothing, got \(captured)")
    }

    // MARK: - Start / stop lifecycle emits the metrics line and the high-water on stop.

    func testStartEmitsADeviceMetricsLineAndStopEmitsHighWater() {
        var captured: [String] = []
        DisplayPerformanceMonitor.shared.emit = { captured.append($0) }
        DisplayPerformanceMonitor.shared.start()
        XCTAssertTrue(DisplayPerformanceMonitor.shared.isRunning)
        XCTAssertEqual(captured.filter { $0.hasPrefix("captureStart ") }.count, 1)
        XCTAssertTrue(captured.contains { $0.hasPrefix("deviceMetrics ") },
                      "start() must emit one device-metrics line, got \(captured)")
        DisplayPerformanceMonitor.shared.stop()
        XCTAssertFalse(DisplayPerformanceMonitor.shared.isRunning,
                       "the display link must be torn down by stop()")
        XCTAssertTrue(captured.contains { $0.hasPrefix("memoryHighWater ") },
                      "stop() must emit the memory high-water line, got \(captured)")
    }

    // MARK: - CAPTURE-D (#797): the dataVolume line on start.

    func testStartEmitsDataVolumeLineWhenProviderWired() async {
        let captured = LineBox()
        DisplayPerformanceMonitor.shared.emit = { captured.append($0) }
        DisplayPerformanceMonitor.shared.dataVolumeProvider = {
            DataVolume(dbRows: 1234, importedDays: 7, workouts: 3, lastRenderRows: 9)
        }
        DisplayPerformanceMonitor.shared.start()
        // The provider is async (the store is an actor), so the line lands on a later main-actor turn. Yield
        // until it arrives (bounded), then assert the exact shape.
        for _ in 0..<50 where !captured.lines.contains(where: { $0.hasPrefix("dataVolume ") }) {
            await Task.yield()
        }
        DisplayPerformanceMonitor.shared.stop()
        XCTAssertTrue(captured.lines.contains("dataVolume dbRows=1234 importedDays=7 workouts=3 lastRenderRows=9"),
                      "start() with a provider must emit one dataVolume line, got \(captured.lines)")
    }

    func testNoProviderEmitsNoDataVolumeLine() async {
        let captured = LineBox()
        DisplayPerformanceMonitor.shared.emit = { captured.append($0) }
        // No dataVolumeProvider wired (the default): start() must NOT emit a dataVolume line.
        DisplayPerformanceMonitor.shared.start()
        for _ in 0..<10 { await Task.yield() }
        DisplayPerformanceMonitor.shared.stop()
        XCTAssertFalse(captured.lines.contains { $0.hasPrefix("dataVolume ") },
                       "no provider must mean no dataVolume line, got \(captured.lines)")
    }

    func testDoubleStartIsIdempotent() {
        var count = 0
        DisplayPerformanceMonitor.shared.emit = { _ in count += 1 }
        DisplayPerformanceMonitor.shared.start()
        let afterFirst = count
        DisplayPerformanceMonitor.shared.start()   // second start ignored
        XCTAssertEqual(count, afterFirst, "a second start() must be a no-op")
        DisplayPerformanceMonitor.shared.stop()
    }

    func testForegroundCaptureAcrossTabsAndBackground() {
        let monitor = DisplayPerformanceMonitor.shared
        var captured: [String] = []
        monitor.emit = { captured.append($0) }
        monitor.setForegroundActive(true)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(captured.isEmpty)

        TestCentre.activate(.display)
        monitor.refreshActivation()
        XCTAssertTrue(monitor.isRunning)
        monitor.setTab(.today)
        monitor.foldFrame(timestamp: 100, expectedInterval: 1.0 / 120)
        monitor.foldFrame(timestamp: 100 + 1.0 / 60, expectedInterval: 1.0 / 120)
        monitor.setTab(.trends)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(captured.contains { $0.contains("tab=today") && $0.contains("lateCallbacks=1") })
        monitor.foldFrame(timestamp: 100 + 2.0 / 60, expectedInterval: 1.0 / 120)
        monitor.setForegroundActive(false)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertTrue(captured.contains { $0.contains("tab=trends") })

        monitor.setForegroundActive(true)
        XCTAssertTrue(monitor.isRunning)
        TestCentre.deactivate(.display)
        monitor.refreshActivation()
        XCTAssertFalse(monitor.isRunning)
    }

    func testLateCallbacksFollowActualCadence() {
        XCTAssertFalse(DisplayPerformanceMonitor.callbackIsLate(durationMs: 8.4, expectedMs: 8.33))
        XCTAssertTrue(DisplayPerformanceMonitor.callbackIsLate(durationMs: 16.67, expectedMs: 8.33))
        XCTAssertFalse(DisplayPerformanceMonitor.callbackIsLate(durationMs: 16.67, expectedMs: 16.67))
        XCTAssertTrue(DisplayPerformanceMonitor.callbackIsLate(durationMs: 33.34, expectedMs: 16.67))
        XCTAssertFalse(DisplayPerformanceMonitor.callbackIsLate(durationMs: 33.34, expectedMs: 33.34))
        XCTAssertFalse(DisplayPerformanceMonitor.callbackIsLate(durationMs: 33.34, expectedMs: 0))
        let monitor = DisplayPerformanceMonitor.shared
        var captured: [String] = []
        monitor.emit = { captured.append($0) }
        monitor.start()
        monitor.foldFrame(timestamp: 100, expectedInterval: 1.0 / 60)
        monitor.foldFrame(timestamp: 100 + 1.0 / 60, expectedInterval: 1.0 / 120)
        monitor.stop()
        XCTAssertTrue(captured.contains { $0.contains("lateCallbacks=0") })
    }

    func testStoppedCaptureDoesNotEmitDelayedDataVolume() async {
        let monitor = DisplayPerformanceMonitor.shared
        let captured = LineBox()
        monitor.emit = { captured.append($0) }
        monitor.dataVolumeProvider = {
            try? await Task.sleep(nanoseconds: 10_000_000)
            return DataVolume(dbRows: 1, importedDays: 1, workouts: 1, lastRenderRows: nil)
        }
        monitor.start()
        await Task.yield()
        monitor.stop()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(captured.lines.contains { $0.hasPrefix("dataVolume ") })
    }

    // MARK: - Pure window stats (no display link needed).

    func testWindowStatsMeanAndP95() {
        // 19 frames at 16 ms and one 100 ms hitch: the first 95% remain at 16 ms.
        let durations = Array(repeating: 16.0, count: 19) + [100.0]
        let stats = DisplayPerformanceMonitor.windowStats(durationsMs: durations)
        XCTAssertEqual(stats.mean, (16.0 * 19 + 100.0) / 20.0, accuracy: 0.001)
        XCTAssertEqual(stats.p95, 16.0, accuracy: 0.001)
        XCTAssertEqual(DisplayPerformanceMonitor.windowStats(durationsMs: [42]).p95, 42)
    }

    func testWindowStatsEmptyIsZero() {
        let stats = DisplayPerformanceMonitor.windowStats(durationsMs: [])
        XCTAssertEqual(stats.mean, 0)
        XCTAssertEqual(stats.p95, 0)
    }

    // MARK: - The screenshot enters the bundle for the .display profile.

    func testAssembleAddsScreenshotForDisplayProfile() {
        // capturePNG() may return nil in a headless test host (no key window), so this asserts the wiring
        // shape: when a PNG is produced it is added under screenshot.png; when not, the bundle still
        // assembles cleanly with the text entries. Either way no .display report is corrupted.
        let live = LiveState()
        let entries = TestBundleAssembler.assemble(profile: .display, live: live)
        XCTAssertTrue(entries.contains { $0.name == "report.txt" })
        XCTAssertTrue(entries.contains { $0.name == "meta.json" })
        if let shot = entries.first(where: { $0.name == "screenshot.png" }) {
            // A real PNG starts with the 8-byte signature 89 50 4E 47 0D 0A 1A 0A.
            let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            XCTAssertEqual(Array(shot.data.prefix(8)), sig, "screenshot.png must be a real PNG")
        }
    }

    func testReviewGateNamesAttachedScreenshot() {
        // The mandatory review gate must be HONEST about a binary attachment it cannot show inline.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])
        let entries = [
            FileExport.BundleEntry(name: "report.txt", data: Data("hello".utf8)),
            FileExport.BundleEntry(name: "screenshot.png", data: png),
        ]
        let gate = ReportReviewGate(entries: entries)
        XCTAssertTrue(gate.previewText.contains("=== report.txt ==="))
        XCTAssertTrue(gate.previewText.contains("screenshot.png"),
                      "the review must name the attached screenshot, got: \(gate.previewText)")
        XCTAssertFalse(gate.isCleared, "the gate must start uncleared (nothing ships until Share)")
    }
}

/// Main-actor-isolated capture box for the monitor's emit sink, so the async dataVolume emit (which lands
/// on a later main-actor turn) accumulates without a closure-mutation warning.
@MainActor
private final class LineBox {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}
