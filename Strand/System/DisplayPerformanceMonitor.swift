import Foundation
import StrandAnalytics
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
import CoreVideo
#endif

// DisplayPerformanceMonitor.swift - the app-layer frame-time / hitch / memory monitor for the Display &
// Performance test mode (Test Centre).
//
// CRITICAL CONTRACT: this monitor is a PERFORMANCE tool that must not itself cost performance. It runs
// ONLY while the Display mode is active. start() is called when the mode toggles on (and on appear if it
// was already on); stop() is called when it toggles off. There is NO perpetual display link: when the
// mode is off, no CADisplayLink / CVDisplayLink exists, no frame callback fires, and zero `.display`
// lines are emitted. A test pins exactly that (DisplayPerformanceMonitorTests).
//
// The frame callback samples each frame's duration, counts hitches over a threshold, and emits a ROLLING
// SUMMARY line once per window of frames (not per frame), so the trace is bounded. Every emitted line
// rides LiveState.append(log:domain:.display), the single redacting sink. The screenshot + device-metrics
// readers live here too so the whole Display capture surface is one file.

/// Owns the live frame monitor for the Display mode. A single shared instance is started / stopped from
/// the Test Centre toggle and app lifecycle. `@MainActor` because it touches the display link, the key window, and the
/// LiveState sink, all of which are main-thread concerns.
@MainActor
final class DisplayPerformanceMonitor {

    static let shared = DisplayPerformanceMonitor()
    private init() {}

    /// A frame is a "hitch" when its duration exceeds this (ms). 16.7 ms is a 60 Hz frame; 33 ms is a
    /// dropped frame at 60 Hz / a slow frame at 120 Hz, a sensible "the user felt that" threshold.
    static let hitchThresholdMs: Double = 33

    /// Bound each window to 600 samples and normally emit every five seconds of foreground use.
    static let windowFrames = 600
    static let summaryIntervalMs: Double = 5_000

    /// The sink that writes a tagged `.display` line. Set by the screen to LiveState.append(log:domain:);
    /// nil leaves the monitor inert (e.g. before the screen wired it, or in a test with no LiveState).
    var emit: ((String) -> Void)?

    /// CAPTURE-D (#797): reads the on-device DATA VOLUME straight from the STORE (never via the Repository /
    /// @Published view-models) so import-driven lag shows its READ-SET, not just frame stats. Wired by the
    /// screen alongside `emit`; nil leaves the dataVolume line unemitted (e.g. a test with no store). Async
    /// because the store is an actor; `start()` fires it on a detached task and emits the one line on return.
    var dataVolumeProvider: (() async -> DataVolume?)?

    private var running = false
    private var foregroundActive = false
    enum Tab: String { case unknown, today, trends, sleep, coach, more }
    private var tab: Tab = .unknown
    private var dataVolumeTask: Task<Void, Never>?
    private var lastExpectedInterval: CFTimeInterval = 0
    private var windowElapsedMs: Double = 0
    private var windowExpectedMs: Double = 0
    private var windowLateCallbacks = 0
    private var lastCPUSeconds: Double?
    private var lastCPUUptime: Double = 0
    private var currentMemoryMB: Double?
    private lazy var performanceArchive: StrapLogArchive = {
        let directory = LiveState.archive.directory.appendingPathComponent("performance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return StrapLogArchive(directory: directory)
    }()
    private var captureStartedUptime: Double = 0
    private var syncActiveProvider: (() -> Bool)?

    // Frame-time accumulation for the current window.
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var windowDurationsMs: [Double] = []
    private var windowHitches = 0
    private var windowWorstMs: Double = 0

    /// Peak resident footprint (MB) seen since start(), emitted on stop() and periodically.
    private var memoryPeakMB: Double = 0

    #if os(iOS)
    private var displayLink: CADisplayLink?
    #endif
    #if os(macOS)
    private var cvLink: CVDisplayLink?
    #endif

    /// True only while a display link is live. The test asserts this is false when the mode is off.
    var isRunning: Bool { running }

    func configure(live: LiveState, repo: Repository) {
        emit = { [weak self, weak live] line in
            live?.append(log: line, domain: .display)
            // Keep long-running performance captures when verbose strap sync rotates the shared log.
            self?.performanceArchive.append(LiveState.redactPii("[display] " + line))
        }
        dataVolumeProvider = { [weak repo] in await repo?.dataVolumeSnapshot() }
        syncActiveProvider = { [weak live] in live?.backfilling == true || live?.historyPendingSync == true }
    }

    var performanceLogText: String { performanceArchive.exportText() }

    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        refreshActivation()
    }

    func refreshActivation() {
        if foregroundActive && TestCentre.active(.display) && emit != nil { start() }
        else { stop() }
    }

    func setTab(_ value: Tab) {
        guard value != tab else { return }
        flushWindow()
        tab = value
    }

    // MARK: - Lifecycle (the ONLY place a display link is created / destroyed)

    /// Start the monitor: create the platform display link and begin sampling. Idempotent (a second
    /// start is ignored). Emits one device-metrics line immediately so the report always has the layout
    /// environment even if the user reports before a frame window completes.
    func start() {
        guard !running else { return }
        running = true
        resetWindow()
        lastFrameTimestamp = 0
        lastExpectedInterval = 0
        lastCPUSeconds = Self.cpuSeconds()
        lastCPUUptime = ProcessInfo.processInfo.systemUptime
        captureStartedUptime = lastCPUUptime
        memoryPeakMB = 0
        currentMemoryMB = nil
        sampleMemory()
        emit?("captureStart version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        emitDeviceMetrics()
        emitDataVolume()

        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #endif
        #if os(macOS)
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            // The CVDisplayLink callback fires on a private CV thread; hop to the main actor to fold the
            // sample in, so all monitor state stays main-isolated like the iOS path.
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, inNow, outputTime, _, _ in
                let nowSeconds = Double(inNow.pointee.hostTime) / Double(machTimebaseHz())
                let output = outputTime.pointee
                let interval = output.videoTimeScale > 0
                    ? Double(output.videoRefreshPeriod) / Double(output.videoTimeScale) : 0
                Task { @MainActor in self?.foldFrame(timestamp: nowSeconds, expectedInterval: interval) }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            cvLink = link
        }
        #endif
    }

    /// Stop the monitor: tear the display link DOWN (so nothing keeps firing), flush a final partial
    /// window if it holds any samples, and emit the memory high-water. After this no callback fires and
    /// no `.display` line is emitted until the next start(). Idempotent.
    func stop() {
        guard running else { return }
        running = false
        dataVolumeTask?.cancel()
        dataVolumeTask = nil

        #if os(iOS)
        displayLink?.invalidate()
        displayLink = nil
        #endif
        #if os(macOS)
        if let link = cvLink {
            CVDisplayLinkStop(link)
        }
        cvLink = nil
        #endif

        // Flush whatever the last partial window holds, then the high-water mark.
        flushWindow()
        emit?(DisplayTrace.memoryHighWaterLine(peakMB: memoryPeakMB))
    }

    // MARK: - Frame sampling

    #if os(iOS)
    @objc private func onFrame(_ link: CADisplayLink) {
        foldFrame(timestamp: link.timestamp, expectedInterval: link.targetTimestamp - link.timestamp)
    }
    #endif

    /// Fold one frame timestamp into the current window. The first frame seeds the previous-timestamp and
    /// is not counted (no duration yet). Once a window fills (`windowFrames`), it flushes a summary and
    /// resets. Pure arithmetic plus the periodic emit; no allocation per frame beyond the bounded buffer.
    func foldFrame(timestamp: CFTimeInterval, expectedInterval: CFTimeInterval) {
        guard running else { return }
        defer {
            lastFrameTimestamp = timestamp
            lastExpectedInterval = expectedInterval
        }
        guard lastFrameTimestamp > 0 else { return }   // seed frame, no duration yet
        let durationMs = (timestamp - lastFrameTimestamp) * 1000.0
        guard durationMs > 0, durationMs < 5_000 else { return }  // ignore a backgrounding gap
        windowDurationsMs.append(durationMs)
        windowElapsedMs += durationMs
        // Use the slower adjacent cadence so an adaptive refresh-rate change is not counted as a stall.
        let expectedMs = max(expectedInterval, lastExpectedInterval) * 1000
        windowExpectedMs += expectedMs
        if Self.callbackIsLate(durationMs: durationMs, expectedMs: expectedMs) { windowLateCallbacks += 1 }
        if durationMs > Self.hitchThresholdMs { windowHitches += 1 }
        if durationMs > windowWorstMs { windowWorstMs = durationMs }
        if windowElapsedMs >= Self.summaryIntervalMs || windowDurationsMs.count >= Self.windowFrames {
            flushWindow()
        }
    }

    /// Emit the rolling summary for the just-completed window and reset for the next one. No-op when the
    /// window is empty (nothing to summarise), so a stop() with no frames does not emit a zero line.
    private func flushWindow() {
        guard !windowDurationsMs.isEmpty else { return }
        sampleMemory()
        let stats = DisplayPerformanceMonitor.windowStats(durationsMs: windowDurationsMs)
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = Self.cpuSeconds()
        let cpuLabel: String
        if let cpu, let previousCPU = lastCPUSeconds, now > lastCPUUptime {
            cpuLabel = String(format: "%.1f%%", max(0, cpu - previousCPU) / (now - lastCPUUptime) * 100)
        } else { cpuLabel = "n/a" }
        lastCPUSeconds = cpu
        lastCPUUptime = now
        emit?(DisplayTrace.frameSummaryLine(
            frames: windowDurationsMs.count,
            meanMs: stats.mean, p95Ms: stats.p95,
            hitches: windowHitches, worstMs: windowWorstMs,
            hitchThresholdMs: Self.hitchThresholdMs)
            + String(format: " elapsed=%.1fs tab=%@ cadence=%.1fms lateCallbacks=%d cpu=%@ memory=%@ thermal=%d lowPower=%@ sync=%@",
                     now - captureStartedUptime, tab.rawValue,
                     windowExpectedMs / Double(windowDurationsMs.count), windowLateCallbacks,
                     cpuLabel, currentMemoryMB.map { String(format: "%.1fMB", $0) } ?? "n/a",
                     ProcessInfo.processInfo.thermalState.rawValue,
                     ProcessInfo.processInfo.isLowPowerModeEnabled ? "true" : "false",
                     syncActiveProvider.map { $0() ? "true" : "false" } ?? "n/a"))
        resetWindow()
    }

    private func resetWindow() {
        windowDurationsMs.removeAll(keepingCapacity: true)
        windowHitches = 0
        windowWorstMs = 0
        windowElapsedMs = 0
        windowExpectedMs = 0
        windowLateCallbacks = 0
    }

    // ponytail: callback timing cannot identify GPU/render stalls; use Instruments for attribution.
    static func callbackIsLate(durationMs: Double, expectedMs: Double) -> Bool {
        expectedMs > 0 && durationMs > expectedMs * 1.5
    }

    private static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Pure window stats: mean and p95 of the frame durations. Static and side-effect-free so a fixture
    /// can pin the exact summary numbers without a live display link.
    static func windowStats(durationsMs: [Double]) -> (mean: Double, p95: Double) {
        guard !durationsMs.isEmpty else { return (0, 0) }
        let mean = durationsMs.reduce(0, +) / Double(durationsMs.count)
        let sorted = durationsMs.sorted()
        // Nearest rank is one-based; subtract one before indexing the sorted samples.
        let idx = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        let p95 = sorted[min(idx, sorted.count - 1)]
        return (mean, p95)
    }

    // MARK: - Memory high-water

    /// Sample the current resident footprint and raise the high-water mark. Reads phys_footprint via
    /// task_info (the same number Xcode's memory gauge shows); a read failure leaves the mark unchanged
    /// rather than fabricating a value.
    private func sampleMemory() {
        if let mb = Self.residentFootprintMB() {
            currentMemoryMB = mb
            memoryPeakMB = max(memoryPeakMB, mb)
        }
    }

    /// Current resident footprint in MB via `task_info(TASK_VM_INFO).phys_footprint`, or nil on a read
    /// failure. The Apple-recommended "real memory" figure for a process.
    static func residentFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    // MARK: - Device metrics (read live, formatted by the pure DisplayTrace)

    /// Read the live display metrics and emit the device-metrics line. Public so the screen can re-emit
    /// on a trait / orientation change while the mode is on.
    func emitDeviceMetrics() {
        emit?(DisplayTrace.deviceMetricsLine(Self.readMetrics()))
    }

    /// CAPTURE-D (#797): read the on-device DATA VOLUME from the store (via `dataVolumeProvider`) and emit
    /// ONE `dataVolume` line, so an import-driven-lag report shows the read-set the screens render over, not
    /// only frame stats. The provider is async (the store is an actor), so this fires a detached task and
    /// emits the line on the main actor on return. No provider wired (e.g. a test without a store) → no
    /// line, exactly as before. Side-effect-only; never touches the frame monitor.
    private func emitDataVolume() {
        guard let dataVolumeProvider, emit != nil else { return }
        dataVolumeTask = Task { [weak self] in
            let volume = await dataVolumeProvider()
            await MainActor.run {
                guard let self, self.running, !Task.isCancelled, let volume else { return }
                self.emit?(DisplayTrace.dataVolumeLine(volume))
            }
        }
    }

    /// Read the current display environment into the pure DisplayMetrics carrier. iOS reads the key
    /// window's trait collection + safe-area insets + UIScreen; macOS reads the key NSWindow / NSScreen
    /// and degrades the iOS-only metrics (size class, Dynamic Type) to nil.
    static func readMetrics() -> DisplayMetrics {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.keyWindow ?? scene?.windows.first
        let traits = window?.traitCollection ?? UITraitCollection.current
        let insets = window?.safeAreaInsets ?? .zero
        let bounds = window?.bounds.size ?? scene?.screen.bounds.size ?? .zero
        let scale = scene?.screen.scale ?? UIScreen.main.scale
        let portrait = (scene?.interfaceOrientation.isPortrait) ?? (bounds.height >= bounds.width)
        return DisplayMetrics(
            horizontalSizeClass: sizeClassName(traits.horizontalSizeClass),
            verticalSizeClass: sizeClassName(traits.verticalSizeClass),
            widthPt: Double(bounds.width), heightPt: Double(bounds.height), scale: Double(scale),
            safeTop: Double(insets.top), safeBottom: Double(insets.bottom),
            safeLeading: Double(insets.left), safeTrailing: Double(insets.right),
            dynamicType: contentSizeName(traits.preferredContentSizeCategory),
            orientation: portrait ? "portrait" : "landscape",
            theme: traits.userInterfaceStyle == .dark ? "dark" : "light")
        #elseif os(macOS)
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        let screen = window?.screen ?? NSScreen.main
        let size = window?.frame.size ?? screen?.frame.size ?? .zero
        let scale = screen?.backingScaleFactor ?? 0
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return DisplayMetrics(
            horizontalSizeClass: nil, verticalSizeClass: nil,   // macOS has no size class
            widthPt: Double(size.width), heightPt: Double(size.height), scale: Double(scale),
            safeTop: 0, safeBottom: 0, safeLeading: 0, safeTrailing: 0,   // no notch insets on macOS
            dynamicType: nil,                                  // no Dynamic Type on macOS
            orientation: size.height >= size.width ? "portrait" : "landscape",
            theme: dark ? "dark" : "light")
        #else
        return DisplayMetrics(
            horizontalSizeClass: nil, verticalSizeClass: nil,
            widthPt: 0, heightPt: 0, scale: 0,
            safeTop: 0, safeBottom: 0, safeLeading: 0, safeTrailing: 0,
            dynamicType: nil, orientation: "unknown", theme: "light")
        #endif
    }

    #if os(iOS)
    private static func sizeClassName(_ c: UIUserInterfaceSizeClass) -> String? {
        switch c {
        case .compact: return "compact"
        case .regular: return "regular"
        default: return nil
        }
    }

    /// Short Dynamic Type label from the content-size category ("L" / "XXL" / "AX3"). The accessibility
    /// sizes map to "AX1"..."AX5", the standard sizes to their short forms, so the line is compact.
    private static func contentSizeName(_ c: UIContentSizeCategory) -> String {
        switch c {
        case .extraSmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        case .extraExtraLarge: return "XXL"
        case .extraExtraExtraLarge: return "XXXL"
        case .accessibilityMedium: return "AX1"
        case .accessibilityLarge: return "AX2"
        case .accessibilityExtraLarge: return "AX3"
        case .accessibilityExtraExtraLarge: return "AX4"
        case .accessibilityExtraExtraExtraLarge: return "AX5"
        default: return "L"
        }
    }
    #endif
}

#if os(macOS)
/// The mach timebase, cached, so the CVDisplayLink host-time (mach ticks) converts to seconds. Pure read
/// of the timebase info; the ratio is constant for the process lifetime.
private func machTimebaseHz() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    // hostTime is in mach ticks; ticks * (numer/denom) = nanoseconds. ticks-per-second = 1e9 * denom/numer.
    guard info.numer != 0 else { return 1_000_000_000 }
    return UInt64(1_000_000_000) * UInt64(info.denom) / UInt64(info.numer)
}
#endif
