#if os(iOS)
import Foundation
import MetricKit

/// Writes the reports iOS hands NOOP through MetricKit into the strap log, one line each (`MetricKitLine`).
///
/// Costs nothing between reports: registering is one call at launch, iOS gathers the numbers itself, and it
/// delivers a metric payload about once a day and a diagnostic payload after a crash, hang or exception. No timer,
/// no file, no network: the lines stay in the strap log.
final class MetricKitLog: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitLog()

    private weak var live: LiveState?

    @MainActor
    func attach(to live: LiveState) {
        self.live = live
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let lines = payloads.map { MetricKitLine.day(Self.day(from: $0)) }
        post(lines)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        post(payloads.flatMap(Self.lines(from:)))
    }

    private func post(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let live = self?.live else { return }
            for line in lines { live.append(log: line) }
        }
    }

    private static func day(from p: MXMetricPayload) -> MetricKitLine.Day {
        var day = MetricKitLine.Day(begin: p.timeStampBegin, end: p.timeStampEnd,
                                    appVersion: p.latestApplicationVersion)
        day.foreground = p.applicationTimeMetrics?.cumulativeForegroundTime.converted(to: .seconds).value
        day.background = p.applicationTimeMetrics?.cumulativeBackgroundTime.converted(to: .seconds).value
        day.cpu = p.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value
        day.peakMemoryBytes = p.memoryMetrics?.peakMemoryUsage.converted(to: .bytes).value
        day.diskWriteBytes = p.diskIOMetrics?.cumulativeLogicalWrites.converted(to: .bytes).value
        if let histogram = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
            var hangs = 0
            let buckets = histogram.bucketEnumerator
            while let bucket = buckets.nextObject() as? MXHistogramBucket<UnitDuration> { hangs += bucket.bucketCount }
            day.hangs = hangs
        }
        if let exits = p.applicationExitMetrics {
            let fg = exits.foregroundExitData, bg = exits.backgroundExitData
            day.exits = [
                .init(reason: "normal", count: fg.cumulativeNormalAppExitCount + bg.cumulativeNormalAppExitCount),
                .init(reason: "CPU limit", count: bg.cumulativeCPUResourceLimitExitCount),
                .init(reason: "memory limit", count: fg.cumulativeMemoryResourceLimitExitCount
                        + bg.cumulativeMemoryResourceLimitExitCount),
                .init(reason: "memory pressure", count: bg.cumulativeMemoryPressureExitCount),
                .init(reason: "watchdog", count: fg.cumulativeAppWatchdogExitCount + bg.cumulativeAppWatchdogExitCount),
                .init(reason: "background task timeout", count: bg.cumulativeBackgroundTaskAssertionTimeoutExitCount),
                .init(reason: "locked file", count: bg.cumulativeSuspendedWithLockedFileExitCount),
                .init(reason: "crash", count: fg.cumulativeBadAccessExitCount + bg.cumulativeBadAccessExitCount
                        + fg.cumulativeIllegalInstructionExitCount + bg.cumulativeIllegalInstructionExitCount
                        + fg.cumulativeAbnormalExitCount + bg.cumulativeAbnormalExitCount),
            ]
        }
        return day
    }

    private static func lines(from p: MXDiagnosticPayload) -> [String] {
        let version = p.crashDiagnostics?.first?.applicationVersion
            ?? p.hangDiagnostics?.first?.applicationVersion
            ?? p.cpuExceptionDiagnostics?.first?.applicationVersion
            ?? p.diskWriteExceptionDiagnostics?.first?.applicationVersion
            ?? "?"
        let at = p.timeStampEnd
        func line(_ kind: String, _ detail: String) -> String {
            MetricKitLine.diagnostic(kind, appVersion: version, at: at, detail: detail)
        }
        var out: [String] = []
        for c in p.crashDiagnostics ?? [] {
            var bits: [String] = []
            if let t = c.exceptionType { bits.append("exception type \(t)") }
            if let s = c.signal { bits.append("signal \(s)") }
            if let r = c.terminationReason, !r.isEmpty { bits.append(r) }
            out.append(line("crash", bits.isEmpty ? "no detail" : bits.joined(separator: ", ")))
        }
        for h in p.hangDiagnostics ?? [] {
            out.append(line("hang", MetricKitLine.duration(h.hangDuration.converted(to: .seconds).value)))
        }
        for c in p.cpuExceptionDiagnostics ?? [] {
            out.append(line("CPU exception", "\(MetricKitLine.duration(c.totalCPUTime.converted(to: .seconds).value)) "
                + "of CPU in \(MetricKitLine.duration(c.totalSampledTime.converted(to: .seconds).value))"))
        }
        for d in p.diskWriteExceptionDiagnostics ?? [] {
            out.append(line("disk-write exception",
                            MetricKitLine.bytes(d.totalWritesCaused.converted(to: .bytes).value)))
        }
        for l in p.appLaunchDiagnostics ?? [] {
            out.append(line("slow launch", MetricKitLine.duration(l.launchDuration.converted(to: .seconds).value)))
        }
        return out
    }
}
#endif
