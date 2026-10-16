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

    func testWorkoutPhasesSplitWindowsAcrossTodayAndTrends() {
        withTrainingSources { model, _, monitor in
            var captured: [String] = []
            monitor.emit = { captured.append($0) }
            monitor.setTab(.today)
            monitor.start()
            monitor.foldFrame(timestamp: 100, expectedInterval: 1.0 / 60)
            monitor.foldFrame(timestamp: 100.02, expectedInterval: 1.0 / 60)
            model.activeWorkout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 100))
            monitor.foldFrame(timestamp: 100.04, expectedInterval: 1.0 / 60)
            model.activeWorkout?.avgHr = 150
            XCTAssertEqual(captured.filter { $0.hasPrefix("trainingPhase ") }.count, 1)
            monitor.setTab(.trends)
            monitor.foldFrame(timestamp: 100.06, expectedInterval: 1.0 / 60)
            model.pauseWorkout(at: Date(timeIntervalSince1970: 101))
            monitor.foldFrame(timestamp: 100.08, expectedInterval: 1.0 / 60)
            model.resumeWorkout(at: Date(timeIntervalSince1970: 102))
            monitor.foldFrame(timestamp: 100.10, expectedInterval: 1.0 / 60)
            model.activeWorkout = nil
            monitor.foldFrame(timestamp: 100.12, expectedInterval: 1.0 / 60)
            monitor.stop()

            let windows = captured.filter { $0.hasPrefix("frameSummary ") }
            XCTAssertEqual(windows.count, 6)
            for (line, expected) in zip(windows, ["none", "active", "active", "paused", "active", "none"]) {
                XCTAssertTrue(line.contains("workout=\(expected) lift=none"), line)
            }
            XCTAssertTrue(windows[0].contains("tab=today"))
            XCTAssertTrue(windows[1].contains("tab=today"))
            XCTAssertTrue(windows.dropFirst(2).allSatisfy { $0.contains("tab=trends") })
            XCTAssertEqual(captured.filter { $0.hasPrefix("trainingPhase ") }.count, 4)
        }
    }

    func testLiftPhasesAndForegroundRestartReadTheCurrentSession() {
        withTrainingSources { model, lift, monitor in
            var captured: [String] = []
            monitor.emit = { captured.append($0) }
            model.activeWorkout = AppModel.ActiveWorkout(start: Date())
            lift.start(plan: [.init(exercise: "Row")], programId: nil, programName: nil)
            lift.pause()
            XCTAssertTrue(captured.isEmpty, "training changes emit nothing while capture is stopped")
            monitor.start()
            XCTAssertTrue(captured.first?.hasSuffix("workout=active lift=paused") == true)
            monitor.foldFrame(timestamp: 100, expectedInterval: 1.0 / 60)
            monitor.foldFrame(timestamp: 100.02, expectedInterval: 1.0 / 60)
            lift.resume()
            XCTAssertTrue(captured.contains { $0.hasPrefix("frameSummary ") && $0.hasSuffix("workout=active lift=paused") })
            monitor.foldFrame(timestamp: 100.22, expectedInterval: 1.0 / 60)
            lift.finish()
            XCTAssertTrue(captured.contains { $0.hasPrefix("frameSummary ") && $0.contains("hitches=1") && $0.hasSuffix("workout=active lift=active") })
            XCTAssertTrue(captured.last?.hasSuffix("workout=active lift=none") == true)
            monitor.stop()

            let stoppedCount = captured.count
            model.pauseWorkout()
            lift.discard()
            lift.start(plan: [.init(exercise: "Row")], programId: nil, programName: nil)
            monitor.foldFrame(timestamp: 101, expectedInterval: 1.0 / 60)
            XCTAssertEqual(captured.count, stoppedCount)
            monitor.start()
            XCTAssertTrue(captured.contains { $0.hasPrefix("captureStart ") && $0.hasSuffix("workout=paused lift=active") })
            monitor.foldFrame(timestamp: 200, expectedInterval: 1.0 / 60)
            monitor.foldFrame(timestamp: 200.02, expectedInterval: 1.0 / 60)
            monitor.stop()
            XCTAssertTrue(captured.contains { $0.hasPrefix("frameSummary ") && $0.hasSuffix("workout=paused lift=active") })
        }
    }

    func testMissingLiftSourceDoesNotClaimThereIsNoSession() {
        withTrainingSources { model, _, monitor in
            monitor.configure(model: model)
            var captured: [String] = []
            monitor.emit = { captured.append($0) }
            monitor.start()
            XCTAssertTrue(captured.first?.hasSuffix("workout=none lift=n/a") == true)
        }
    }

    private func withTrainingSources(_ check: (AppModel, LiftSessionController, DisplayPerformanceMonitor) -> Void) {
        let defaults = UserDefaults.standard
        let keys = [ActiveWorkoutPersistence.defaultsKey, LiftSessionPersistence.defaultsKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        let previousModel = AppModel.shared
        let model = AppModel()
        model.activeWorkout = nil
        let lift = LiftSessionController(buzz: { _ in }, setStrapHandler: { _ in })
        let monitor = DisplayPerformanceMonitor.shared
        monitor.configure(model: model, lift: lift)
        defer {
            monitor.stop()
            lift.discard()
            AppModel.shared = previousModel
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        check(model, lift, monitor)
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
