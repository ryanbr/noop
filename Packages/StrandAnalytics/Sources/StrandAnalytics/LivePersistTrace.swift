import Foundation

/// Maps the app's persistence-relevant lifecycle edges onto the reason carried through Collector logs.
/// The app and tests call this same seam, so lifecycle routing is exercised without UIKit on Linux.
public enum StandardHRLifecycleFlush {
    public enum Event {
        case background
        case termination
    }

    public static func run(
        event: Event,
        flush: (LivePersistTrace.StandardHRFlushReason) async -> Void
    ) async {
        switch event {
        case .background:
            await flush(.background)
        case .termination:
            await flush(.termination)
        }
    }
}

/// A live HR/R-R batch failed to persist and was re-buffered.
///
/// `Collector` re-queues the frames and swallows the error, so a store rejecting every insert produces a
/// log full of `rr emit … offered=N` and no indication that none of it landed. That is the worst shape a
/// diagnostic gap can take: the instrumentation that exists reads like success.
///
/// Twin of the Kotlin `liveInsertFailedLine` in `com.noop.ble.StalledLinkDiagnostics`, so an Android and
/// an Apple log of the same failure compare directly. Rendered strings match for ASCII (store errors).
/// The 200-character bound is not a Unicode-identical truncation: Kotlin `take(200)` counts UTF-16 code
/// units and Swift `prefix(200)` counts grapheme clusters. Store error descriptions are ASCII, which is
/// the load-bearing case. The Kotlin side lives beside its caller in the BLE package; this one lives here
/// because `Collector` is app-target Swift with no default CI, and the package is where the other
/// emitted-line builders (`Spo2ReTrace`, `SleepStager+Trace`, `ConnectionReadout`) already sit and get tested.
public enum LivePersistTrace {

    public enum StandardHRFlushReason: String {
        case cadence
        case disconnect
        case background
        case termination
        case explicit
    }

    /// Bounded standard-HR transport-state diagnostics. These lines describe host observation and
    /// buffer/persistence state only; they carry no physiological measurements and make no claim
    /// about sensor-origin time or unobserved loss.
    public static func standardHRHostReceivedLine(
        hostUnixSeconds: Int,
        acceptedHRRows: Int, acceptedRRRows: Int,
        rejectedHRRows: Int, rejectedRRRows: Int,
        pendingHRRows: Int, pendingRRRows: Int
    ) -> String {
        "standard-hr transport host-received hostUnixSec=\(hostUnixSeconds)"
            + " acceptedHRRows=\(acceptedHRRows) acceptedRRRows=\(acceptedRRRows)"
            + " rejectedHRRows=\(rejectedHRRows) rejectedRRRows=\(rejectedRRRows)"
            + " pendingHRRows=\(pendingHRRows) pendingRRRows=\(pendingRRRows)"
    }

    /// The host-received line above, summarised: what a strap log carries about this transport when no
    /// Test Centre mode is on.
    ///
    /// WHY. `standardHRHostReceivedLine` is written for EVERY standard-HR sample, which a streaming strap
    /// produces once a second. In one 75-minute gym session on 22 Sep 2026 that was 3,009 of the log's 5,704
    /// lines — 52.8% of everything the log had to say about that session — and a 5/MG export in the #2386
    /// review had the same shape, half its transport lines crowding out the rest. Since #2386 the log is kept
    /// on disk within 2 MB, so this ratio now decides how much history a bug report carries: about three
    /// hours of a streaming strap, where a summarised stream carries a day.
    ///
    /// What the line exists for is kept. A sample the host REFUSED — an HR outside 30…220, an R-R outside
    /// 250…3000 ms — is still written the moment it happens: that is the rare event, and it costs nothing
    /// while nothing is wrong. The routine ones are counted and rendered once a window as a line that says
    /// how many arrived, over how long, the widest gap between two of them (a stall a reader used to have to
    /// find by eye), what was accepted and refused, and what is still pending. Full per-sample detail comes
    /// back while the Test Centre's HRV or Connection mode is on, which is what those modes are for: gate the
    /// per-sample readout behind the domain, leave the rare-event evidence always on (`AGENTS.md`).
    ///
    /// Twin of the Kotlin `StandardHrHostReceivedTrace` (`com.noop.ble`), line for line: same window, same
    /// rules, same rendered text.
    public struct StandardHRHostReceivedTrace: Sendable {

        /// One host-received observation: the same fields the per-sample line renders.
        public struct Sample: Sendable, Equatable {
            public var hostUnixSeconds: Int
            public var acceptedHRRows: Int
            public var acceptedRRRows: Int
            public var rejectedHRRows: Int
            public var rejectedRRRows: Int
            public var pendingHRRows: Int
            public var pendingRRRows: Int

            public init(hostUnixSeconds: Int, acceptedHRRows: Int, acceptedRRRows: Int,
                        rejectedHRRows: Int, rejectedRRRows: Int,
                        pendingHRRows: Int, pendingRRRows: Int) {
                self.hostUnixSeconds = hostUnixSeconds
                self.acceptedHRRows = acceptedHRRows
                self.acceptedRRRows = acceptedRRRows
                self.rejectedHRRows = rejectedHRRows
                self.rejectedRRRows = rejectedRRRows
                self.pendingHRRows = pendingHRRows
                self.pendingRRRows = pendingRRRows
            }
        }

        private var firstSecond: Int?
        private var lastSecond = 0
        private var samples = 0
        private var acceptedHR = 0
        private var acceptedRR = 0
        private var rejectedHR = 0
        private var rejectedRR = 0
        private var pendingHR = 0
        private var pendingRR = 0
        private var widestGap = 0

        public init() {}

        /// The lines to write for this sample, in the order they should appear: a finished window's summary
        /// first, because it describes the samples before this one.
        ///
        /// Twin of the Kotlin `StandardHrHostReceivedTrace.record`.
        public mutating func record(_ sample: Sample, detailed: Bool) -> [String] {
            var lines: [String] = []
            if let first = firstSecond,
               // 60 s: a window long enough to turn a streaming hour into 60 lines, short enough that a stall
               // still shows in one of them. The Kotlin twin uses the same literal; a named constant here
               // would pair with the unrelated `windowSeconds` the ledger already tracks.
               sample.hostUnixSeconds - first >= 60 || sample.hostUnixSeconds < first {
                // A clock that went backwards ends the window too: a span is only honest within one clock.
                if let summary = summaryLine() { lines.append(summary) }
                let previousLast = lastSecond
                let forwards = sample.hostUnixSeconds >= previousLast
                reset()
                // #2405: the gap that CROSSED this boundary is the one worth reporting, and it used to be
                // the one gap that could not be. A stall of a minute or more forces this roll on the next
                // sample, so it fell between two windows and appeared in neither, leaving `gapMaxSec` able
                // to describe only stalls shorter than the window — the opposite of what it is read for.
                //
                // It is seeded into the NEW window rather than added to the summary just emitted: that
                // summary describes the samples BEFORE the gap, and this window is the one the gap opens.
                // So the line reads "since the previous summary, the widest gap was this". Not seeded
                // across a backwards clock (no honest span) nor across `close()`, where a disconnect or a
                // termination already accounts for the silence and a stall would be double-reported.
                if forwards { widestGap = sample.hostUnixSeconds - previousLast }
            }
            if firstSecond == nil {
                firstSecond = sample.hostUnixSeconds
            } else {
                widestGap = max(widestGap, sample.hostUnixSeconds - lastSecond)
            }
            lastSecond = sample.hostUnixSeconds
            samples += 1
            acceptedHR += sample.acceptedHRRows
            acceptedRR += sample.acceptedRRRows
            rejectedHR += sample.rejectedHRRows
            rejectedRR += sample.rejectedRRRows
            pendingHR = sample.pendingHRRows
            pendingRR = sample.pendingRRRows
            if detailed || sample.rejectedHRRows > 0 || sample.rejectedRRRows > 0 {
                lines.append(standardHRHostReceivedLine(
                    hostUnixSeconds: sample.hostUnixSeconds,
                    acceptedHRRows: sample.acceptedHRRows, acceptedRRRows: sample.acceptedRRRows,
                    rejectedHRRows: sample.rejectedHRRows, rejectedRRRows: sample.rejectedRRRows,
                    pendingHRRows: sample.pendingHRRows, pendingRRRows: sample.pendingRRRows))
            }
            return lines
        }

        /// The window so far, for a disconnect, a background flush or a termination: the last minute of a
        /// session is exactly the part a report is taken for, and it must not leave with the process.
        ///
        /// Twin of the Kotlin `StandardHrHostReceivedTrace.close`.
        public mutating func close() -> [String] {
            guard let summary = summaryLine() else { return [] }
            reset()
            return [summary]
        }

        /// Twin of the Kotlin `StandardHrHostReceivedTrace.summaryLine`.
        private func summaryLine() -> String? {
            guard let first = firstSecond, samples > 0 else { return nil }
            return "standard-hr transport host-received summary"
                + " windowSec=\(lastSecond - first) samples=\(samples) gapMaxSec=\(widestGap)"
                + " acceptedHRRows=\(acceptedHR) acceptedRRRows=\(acceptedRR)"
                + " rejectedHRRows=\(rejectedHR) rejectedRRRows=\(rejectedRR)"
                + " pendingHRRows=\(pendingHR) pendingRRRows=\(pendingRR)"
        }

        /// Twin of the Kotlin `StandardHrHostReceivedTrace.reset`.
        private mutating func reset() {
            firstSecond = nil
            lastSecond = 0
            samples = 0
            acceptedHR = 0; acceptedRR = 0
            rejectedHR = 0; rejectedRR = 0
            pendingHR = 0; pendingRR = 0
            widestGap = 0
        }
    }

    public static func standardHRFlushAttemptLine(
        reason: StandardHRFlushReason, offeredHRRows: Int, offeredRRRows: Int
    ) -> String {
        "standard-hr transport flush-attempt reason=\(reason.rawValue)"
            + " offeredHRRows=\(offeredHRRows) offeredRRRows=\(offeredRRRows)"
    }

    public static func standardHRFlushSucceededLine(
        reason: StandardHRFlushReason, offeredHRRows: Int, offeredRRRows: Int,
        insertedHRRows: Int, insertedRRRows: Int
    ) -> String {
        "standard-hr transport flush-succeeded reason=\(reason.rawValue)"
            + " offeredHRRows=\(offeredHRRows) offeredRRRows=\(offeredRRRows)"
            + " insertedHRRows=\(insertedHRRows) insertedRRRows=\(insertedRRRows)"
    }

    public static func standardHRRebufferedForRetryLine(
        reason: StandardHRFlushReason, attemptedHRRows: Int, attemptedRRRows: Int,
        pendingHRRows: Int, pendingRRRows: Int, consecutiveFailures: Int
    ) -> String {
        "standard-hr transport rebuffered-for-retry reason=\(reason.rawValue)"
            + " attemptedHRRows=\(attemptedHRRows) attemptedRRRows=\(attemptedRRRows)"
            + " pendingHRRows=\(pendingHRRows) pendingRRRows=\(pendingRRRows)"
            + " consecutiveFailures=\(consecutiveFailures)"
    }

    /// - Parameters:
    ///   - transport: which live path failed. There are TWO — the standard 0x2A37 reading and the puffin
    ///     REALTIME_DATA batch (#1118) — and they fail independently. A line that did not say which would
    ///     leave a reader unable to tell one dead transport from a dead store, the first fork in the
    ///     diagnosis.
    ///   - errorName: the error's type name. Spelled `throwableName` in the Kotlin twin; the rendered
    ///     line is identical.
    ///   - consecutiveFailures: matters more than any single error. One failure is the transient the
    ///     re-buffer exists to absorb; a climbing count is a store that will never accept these rows, and
    ///     only the count separates them.
    public static func liveInsertFailedLine(
        transport: String,
        errorName: String,
        message: String?,
        hrFrames: Int,
        rrFrames: Int,
        consecutiveFailures: Int
    ) -> String {
        // Bounded like the Kotlin `take(200)`: a full error description can be enormous, and the useful
        // cases (a full disk, a corrupted database, a schema mismatch) are distinguished well inside it.
        // ASCII-only twin: `take` is UTF-16 code units, `prefix` is grapheme clusters.
        let detail = message.flatMap { m -> String? in
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : ": " + String(m.prefix(200))
        } ?? ""
        let run = consecutiveFailures >= 2
            ? " \(consecutiveFailures) consecutive failures — these rows are not landing and the re-buffer is"
                + " not recovering them."
            : " Re-buffered for the next cadence."
        return "Live persist FAILED on \(transport) — \(errorName)\(detail) (hr=\(hrFrames) rr=\(rrFrames))."
            + run
    }

    /// Rate limit for ``liveInsertFailedLine(transport:errorName:message:hrFrames:rrFrames:consecutiveFailures:)``.
    ///
    /// The live cadence is seconds, so an unconditional log would bury the rest of the capture under a
    /// failure it has already reported. The gap is deliberately long: this line establishes THAT inserts
    /// are failing and roughly for how long, which one line a minute answers as well as sixty.
    ///
    /// A zero `lastEmitMs` must emit — the first failure is the one most worth having. A BACKWARDS clock
    /// emits too: wall time can step back, and comparing only forwards would strand `lastEmitMs` in the
    /// future and silence the line until real time caught up. Byte-identical rule to the Kotlin twin.
    public static func shouldEmitLiveInsertFailure(
        lastEmitMs: Int64,
        nowMs: Int64,
        minGapMs: Int64 = 60_000
    ) -> Bool {
        lastEmitMs <= 0 || nowMs < lastEmitMs || nowMs - lastEmitMs >= minGapMs
    }
}
