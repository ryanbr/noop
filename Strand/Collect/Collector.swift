import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// The subset of WhoopStore the Collector needs. A protocol so tests can inject a spy
/// (WhoopStore is `final`). WhoopStore conforms via the extension below.
/// Not @MainActor — the WhoopStore actor's async methods satisfy the async requirements;
/// a @MainActor SpyStore in tests also conforms (async witnesses hop actors).
protocol StoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
}
extension WhoopStore: StoreWriting {}

/// Cadence: flush after this many buffered frames OR this many seconds since the last
/// flush — whichever first. Also flushed explicitly on disconnect/foreground.
struct CollectorPolicy {
    var maxFrames: Int
    var maxInterval: TimeInterval
    /// Defensive cap on the PRE-CLOCK buffer only (see `ingest`). Generous default —
    /// ~4096 frames at ~60 bytes/frame is ~240KB, far beyond the handful seen pre-clock
    /// normally. Custom init keeps `.init(maxFrames:maxInterval:)` call sites compiling.
    var maxPreClockFrames: Int
    init(maxFrames: Int, maxInterval: TimeInterval, maxPreClockFrames: Int = 4096) {
        self.maxFrames = maxFrames
        self.maxInterval = maxInterval
        self.maxPreClockFrames = maxPreClockFrames
    }
    static let `default` = CollectorPolicy(maxFrames: 64, maxInterval: 30, maxPreClockFrames: 4096)
}

/// Buffers complete (reassembled) frames and periodically persists them:
/// parse → extractStreams(clockRef) → store.insert (DECODED FIRST, durable) →
/// store.enqueueRawBatch (raw, transient outbox) → clear buffer.
/// Because decoded is committed before raw is queued, pruning raw never loses a metric.
@MainActor
final class Collector {
    private let store: StoreWriting
    /// Concrete store for prune + stats (the StoreWriting seam covers the hot insert/enqueue path;
    /// prune/stats are infrequent so a direct reference is clearer than widening the protocol).
    private let concreteStore: WhoopStore?
    /// Device id new samples persist under. MUTABLE so a WHOOP↔WHOOP switch (BLEManager.setActiveDeviceId)
    /// re-attributes the next flush/standard-HR persist immediately, rather than freezing the id captured
    /// at construction. Single-WHOOP never switches, so this stays "my-whoop" exactly as a `let` would have.
    var deviceId: String
    private let policy: CollectorPolicy
    /// Research toggle. When false (DEFAULT) no raw frames are persisted at all — the app is
    /// decoded-only. Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool
    private let now: () -> Int
    private let monotonic: () -> TimeInterval

    /// Set once the GET_CLOCK correlation lands (E1). Until then, frames buffer un-persisted.
    var clockRef: ClockRef?
    /// Strap family for the LIVE decode path. WHOOP 4.0 (default) parses the 4.0 envelope; 5/MG
    /// parses the puffin envelope (records sit at +4 offsets). Set by BLEManager.configureCollector‐
    /// Family alongside an identity clockRef — 5/MG live timestamps are already real-unix seconds.
    var family: DeviceFamily = .whoop4
    /// On-demand bounded raw-capture window. ORs into the raw-persist gate so a "capture
    /// activity sample" action can persist raw even when `enableRawCapture` is off. The window's
    /// monotonic deadline auto-expires so a missed stop callback can't leak raw forever.
    private var rawCapture = RawCaptureWindow()
    /// #47: buffer the (raw frame, pre-parsed) pair. The raw bytes are still needed for the raw-capture
    /// outbox; the parse is the one the BLE seam already did, so `flush` doesn't re-decode the batch.
    private var buffer: [(frame: [UInt8], parsed: ParsedFrame)] = []
    /// #1118: strap-log sink for the per-transport R-R census. Optional and defaulted to nil so the
    /// test fakes that construct a Collector are untouched; `BLEManager` wires its own `log`.
    private let log: ((String) -> Void)?
    /// #1635: rows ACCEPTED per stream, handed up so `BLEManager` can tally them per LINK and say which
    /// streams banked when it writes the link epitaph. The counts already exist — `StreamStore.insert`
    /// returns them and the standard-HR path already binds them for its own trace line — so this carries
    /// a measurement that was being discarded, rather than taking a new one.
    private let onBanked: ((BankedCounts) -> Void)?
    /// #1118: last emit of each LIVE census line, unix seconds; 0 = never. Rate-limited — see
    /// `RrEmissionStats.shouldEmitLiveCensus`.
    ///
    /// Lifetime DIVERGES from the Kotlin twin. These reset whenever `BLEManager.bootstrapStore()`
    /// rebuilds the Collector (a store rebuild after unlock, among other paths), so a log can carry an
    /// extra line after one of those. Android keeps its stamps on the process-wide `WhoopBleClient`
    /// singleton, which a device switch mutates rather than rebuilds, so they never reset there.
    /// Harmless either way — a rate-limit on a diagnostic, not a measurement — but a reader comparing
    /// two logs should not have to work out why one has more lines than the other.
    ///
    /// @MainActor isolation makes these safe without a lock; the Kotlin fields are deliberately
    /// unsynchronized instead, since a stale read there costs one duplicate line.
    private var lastStdRrCensusSec: Int = 0
    private var lastRealtimeRrCensusSec: Int = 0

    /// Consecutive live-persist failures per transport, and when each last reported.
    ///
    /// Kept PER TRANSPORT because the standard 0x2A37 path and the puffin REALTIME_DATA path (#1118) fail
    /// independently — a shared counter would let one path's success reset the other's run and report a
    /// persistent failure as a string of first-failures. @MainActor isolation makes these safe without a
    /// lock; the Kotlin twin uses AtomicInteger because its two flushes can run concurrently on the io
    /// scope, and there the count is the load-bearing distinction between a transient and a run.
    private var stdInsertFailures = 0
    private var realtimeInsertFailures = 0
    private var lastStdInsertFailureLogMs: Int64 = 0
    private var lastRealtimeInsertFailureLogMs: Int64 = 0

    /// Standard 0x2A37 HR/RR/contact buffer — the reliable, always-on stream, recorded continuously
    /// (independent of the custom realtime stream or which screen is open).
    private var stdHR: [HRSample] = []
    private var stdRR: [RRInterval] = []
    private var stdContact: [WhoopEvent] = []
    /// Last contact state buffered, so only transitions are recorded. See `shouldRecordContact`.
    private var lastStdContact: StandardHRContact?
    private var batchStartedAt: TimeInterval
    var bufferedCount: Int { buffer.count }

    /// The per-stream accepted-row counts `StreamStore.insert` returns, named so the closure that carries
    /// them is readable at both ends.
    typealias BankedCounts = (hr: Int, rr: Int, events: Int, battery: Int,
                              spo2: Int, skinTemp: Int, resp: Int, gravity: Int)

    init(store: StoreWriting, deviceId: String,
         policy: CollectorPolicy = .default,
         enableRawCapture: Bool = false,
         log: ((String) -> Void)? = nil,
         onBanked: ((BankedCounts) -> Void)? = nil,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         monotonic: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.store = store; self.deviceId = deviceId; self.policy = policy
        self.enableRawCapture = enableRawCapture
        self.log = log
        self.onBanked = onBanked
        self.now = now; self.monotonic = monotonic
        self.batchStartedAt = monotonic()
        self.concreteStore = store as? WhoopStore
    }

    /// Light storage summary for the UI. nil if there's no concrete store or the read throws.
    func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        guard let s = concreteStore else { return nil }
        return try? await s.storageStats()
    }

    /// Decoded history rows in a stable long-form CSV for arbitrary user-selected export windows.
    func historySensorsCSV(from: Int, to: Int) async -> Data {
        guard let store = concreteStore, from <= to else { return Data("stream,unix_s,v1,v2,v3,v4\n".utf8) }
        let limit = min(max(to - from + 1, 1) * 4, 1_000_000)
        async let hr = try? store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let battery = try? store.batterySamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let spo2 = try? store.spo2Samples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let temp = try? store.skinTempSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let steps = try? store.stepSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let resp = try? store.respSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let gravity = try? store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)
        var lines = ["stream,unix_s,v1,v2,v3,v4"]
        lines += await (hr ?? []).map { "heart_rate,\($0.ts),\($0.bpm),,," }
        lines += await (battery ?? []).map { "battery,\($0.ts),\($0.soc.map { String($0) } ?? ""),\($0.mv.map { String($0) } ?? ""),," }
        lines += await (spo2 ?? []).map { "spo2_raw,\($0.ts),\($0.red),\($0.ir),," }
        lines += await (temp ?? []).map { "skin_temp_raw,\($0.ts),\($0.raw),\($0.aux1Raw.map { String($0) } ?? ""),\($0.aux2Raw.map { String($0) } ?? "")," }
        lines += await (steps ?? []).map { "steps,\($0.ts),\($0.counter),\($0.activityClass.map { String($0) } ?? ""),," }
        lines += await (resp ?? []).map { "resp_raw,\($0.ts),\($0.raw),,," }
        lines += await (gravity ?? []).map { "gravity,\($0.ts),\($0.x),\($0.y),\($0.z),\($0.dynAccel.map { String($0) } ?? "")" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Max persisted HR sample ts (the biometric "data frontier" for the stuck-strap watchdog).
    /// nil if there's no concrete store or nothing persisted yet. Mirrors storageStats().
    func latestHRSampleTs() async -> Int? {
        guard let s = concreteStore else { return nil }
        return try? await s.latestHRSampleTs(deviceId: deviceId)
    }

    /// Recent gravity samples for the inactivity reminder (#419): the strap's motion over `[from, to]`,
    /// the input to the shipped `SedentaryDetector`. Empty if there's no concrete store or the read
    /// throws. Mirrors latestHRSampleTs() — the BLE offload hook reads gravity through the Collector
    /// because the Collector owns the concrete store.
    func recentGravity(from: Int, to: Int, limit: Int = 100_000) async -> [GravitySample] {
        guard let s = concreteStore else { return [] }
        return (try? await s.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Apply the raw-retention policy. Returns rows pruned (0 if no concrete store).
    @discardableResult
    func prune() async -> Int {
        guard let s = concreteStore else { return 0 }
        return (try? await s.pruneRaw(now: now(),
                                keepWindowSeconds: PrunePolicy.keepWindowSeconds,
                                maxUnsyncedBytes: PrunePolicy.maxUnsyncedBytes)) ?? 0
    }

    /// Parse-then-buffer shim (#47). Kept for callers/tests that pass raw bytes; the live seam calls
    /// `ingest(frame:parsed:)` with the parse it already did.
    func ingest(_ frame: [UInt8]) {
        ingest(frame: frame, parsed: parseFrame(frame, family: family))
    }

    /// Buffer one complete frame + its pre-parsed decode (synchronous: preserves delegate arrival order).
    /// Auto-flushes via a detached Task when the cadence threshold is hit (flush is async). (#47)
    func ingest(frame: [UInt8], parsed: ParsedFrame) {
        #if DEBUG
        assert(parsed == parseFrame(frame, family: family),
               "Collector.ingest: threaded ParsedFrame != fresh parse (#47 parse-once invariant)")
        #endif
        recordGroundTruthImu(frame)
        buffer.append((frame, parsed))
        // Pre-clock only: bound memory if GET_CLOCK never lands while data keeps flowing.
        // Drop OLDEST beyond the cap (keep most recent). Post-clock this branch is skipped —
        // the cadence flush below bounds the buffer instead.
        if clockRef == nil && buffer.count > policy.maxPreClockFrames {
            buffer.removeFirst(buffer.count - policy.maxPreClockFrames)
        }
        guard clockRef != nil else { return }   // can't correlate ts yet → keep buffering
        if buffer.count >= policy.maxFrames || (monotonic() - batchStartedAt) >= policy.maxInterval {
            Task { @MainActor in await self.flush() }
        }
    }


    /// Persist + queue everything buffered. No-op when empty or before a clock ref exists.
    /// Buffer is snapshotted and cleared SYNCHRONOUSLY before the first await so that any
    /// concurrent ingest() calls during persistence accumulate into the NEXT batch cleanly.
    func flush() async {
        guard let ref = clockRef, !buffer.isEmpty else { return }
        // SNAPSHOT + CLEAR before any await: decoded-before-raw ordering AND the
        // buffer-snapshot-before-await invariant are both satisfied here.
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        let frames = batch.map(\.frame)         // still needed for the raw-capture outbox
        let parsed = batch.map(\.parsed)        // #47: the seam already decoded these — don't re-parse
        let streams = extractStreams(parsed, deviceClockRef: ref.device, wallClockRef: ref.wall)
        // #1118: the SECOND live transport. `flushStandardHR` stamps a beat at the second it arrived over
        // 0x2A37; this one stamps it from the strap's own record clock. The same beat reaching both lands
        // on two different seconds, which no same-second de-dup can collapse — the signature every
        // affected night prints as `crossSecondOverCount`.
        if !streams.rr.isEmpty {
            let nowSec = now()
            if RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: lastRealtimeRrCensusSec, nowSec: nowSec) {
                lastRealtimeRrCensusSec = nowSec
                let census = RrEmissionStats.compute(streams.rr.map { (ts: $0.ts, rrMs: $0.rrMs) })
                log?(RrEmissionStats.logLine(path: "live-realtime", offered: streams.rr.count,
                                             inserted: nil, census))
            }
        }
        do {
            let inserted = try await store.insert(streams, deviceId: deviceId)   // DECODED FIRST (durable)
            realtimeInsertFailures = 0
            onBanked?(inserted)
        } catch {
            // Re-buffer at the front so these frames (and their parses) are retried on the next cadence.
            buffer.insert(contentsOf: batch, at: 0)
            // Swallowing this made the census above read like success: a store rejecting everything still
            // reported what was OFFERED, with nothing to say none of it landed.
            realtimeInsertFailures += 1
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: lastRealtimeInsertFailureLogMs,
                                                            nowMs: nowMs) {
                lastRealtimeInsertFailureLogMs = nowMs
                log?(LivePersistTrace.liveInsertFailedLine(
                    transport: "live-realtime", errorName: String(describing: type(of: error)),
                    message: error.localizedDescription, hrFrames: streams.hr.count,
                    rrFrames: streams.rr.count, consecutiveFailures: realtimeInsertFailures))
            }
            return
        }
        // Reset only after a successful insert so the interval trigger keeps firing if
        // inserts fail (batchStartedAt must NOT advance on a failed drain).
        batchStartedAt = monotonic()
        // RAW SECOND (transient outbox), only when the research toggle is ON. Default OFF →
        // decoded-only, no raw is stored. Failure is non-fatal — decoded is already durable.
        guard enableRawCapture || rawCapture.isActive(at: monotonic()) else { return }
        let wall = now()
        let tsValues = streams.hr.map(\.ts) + streams.rr.map(\.ts)
            + streams.events.map(\.ts) + streams.battery.map(\.ts)
        let meta = RawBatchMeta(
            batchId: UUID().uuidString, deviceId: deviceId, clockRef: ref, capturedAt: wall,
            startTs: tsValues.min() ?? wall, endTs: tsValues.max() ?? wall,
            frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count })
        try? await store.enqueueRawBatch(meta, frames: frames)
    }

    // MARK: - Standard 0x2A37 HR/RR (continuous recording)

    /// Buffer one standard Heart-Rate-Measurement reading. No clock correlation needed —
    /// these carry a wall-clock `ts` directly. Auto-flushes ~every 30 readings (~30s).
    func ingestStandardHR(hr: Int, rr: [Int], contact: StandardHRContact? = nil, at ts: Int) {
        let acceptedHR = (30...220).contains(hr) ? 1 : 0
        let acceptedRR = rr.filter { (250...3000).contains($0) }
        if acceptedHR == 1 { stdHR.append(HRSample(ts: ts, bpm: hr)) }
        stdRR.append(contentsOf: acceptedRR.map { RRInterval(ts: ts, rrMs: $0) })
        // Only the CHANGES. Advanced here rather than at flush because the event travels in the buffer
        // until it persists: a failed insert re-inserts it at the front, so nothing has to be unwound.
        if let contact, StandardHRMapping.shouldRecordContact(previous: lastStdContact, current: contact) {
            lastStdContact = contact
            stdContact.append(contentsOf: StandardHRMapping.samples(
                fromHR: hr, rr: [], contact: contact, at: ts
            ).events)
        }
        log?(LivePersistTrace.standardHRHostReceivedLine(
            hostUnixSeconds: ts,
            acceptedHRRows: acceptedHR, acceptedRRRows: acceptedRR.count,
            rejectedHRRows: 1 - acceptedHR, rejectedRRRows: rr.count - acceptedRR.count,
            pendingHRRows: stdHR.count, pendingRRRows: stdRR.count))
        if stdHR.count + stdRR.count + stdContact.count >= 30 {
            Task { @MainActor in await self.flushStandardHR(reason: .cadence) }
        }
    }

    /// Persist the buffered standard HR/RR/contact. Re-buffers on failure so nothing is lost.
    func flushStandardHR(reason: LivePersistTrace.StandardHRFlushReason = .explicit) async {
        guard !stdHR.isEmpty || !stdRR.isEmpty || !stdContact.isEmpty else { return }
        let hr = stdHR, rr = stdRR, contact = stdContact
        stdHR.removeAll(keepingCapacity: true)
        stdRR.removeAll(keepingCapacity: true)
        stdContact.removeAll(keepingCapacity: true)
        log?(LivePersistTrace.standardHRFlushAttemptLine(
            reason: reason, offeredHRRows: hr.count, offeredRRRows: rr.count))
        // #1118: census this batch BEFORE it is stored, exactly as the historical path does, so a strap
        // log carries one `ratioRep` per transport. If each transport reports ~1.0 while the stored night
        // reads 2.77, the over-count is the UNION of the transports and no single decoder is at fault —
        // which is the question this instrumentation exists to settle.
        if !rr.isEmpty {
            let nowSec = now()
            if RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: lastStdRrCensusSec, nowSec: nowSec) {
                lastStdRrCensusSec = nowSec
                let census = RrEmissionStats.compute(rr.map { (ts: $0.ts, rrMs: $0.rrMs) })
                // `inserted` is NIL, not echoed from `offered`: the store's conflict key decides that and
                // this census runs before the insert. The line renders `inserted=n/a`.
                log?(RrEmissionStats.logLine(path: "live-standard", offered: rr.count,
                                             inserted: nil, census))
            }
        }
        do {
            let inserted = try await store.insert(Streams(hr: hr, rr: rr, events: contact), deviceId: deviceId)
            stdInsertFailures = 0
            onBanked?(inserted)
            log?(LivePersistTrace.standardHRFlushSucceededLine(
                reason: reason, offeredHRRows: hr.count, offeredRRRows: rr.count,
                insertedHRRows: inserted.hr, insertedRRRows: inserted.rr))
        } catch {
            stdHR.insert(contentsOf: hr, at: 0)
            stdRR.insert(contentsOf: rr, at: 0)
            stdContact.insert(contentsOf: contact, at: 0)
            stdInsertFailures += 1
            log?(LivePersistTrace.standardHRRebufferedForRetryLine(
                reason: reason, attemptedHRRows: hr.count, attemptedRRRows: rr.count,
                pendingHRRows: stdHR.count, pendingRRRows: stdRR.count,
                consecutiveFailures: stdInsertFailures))
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: lastStdInsertFailureLogMs,
                                                            nowMs: nowMs) {
                lastStdInsertFailureLogMs = nowMs
                log?(LivePersistTrace.liveInsertFailedLine(
                    transport: "live-standard", errorName: String(describing: type(of: error)),
                    message: error.localizedDescription, hrFrames: hr.count, rrFrames: rr.count,
                    consecutiveFailures: stdInsertFailures))
            }
        }
    }

    // MARK: - On-demand raw capture

    /// Open a bounded raw-capture window so the next flushes persist raw even with the global
    /// research toggle off. Auto-expires at the (clamped) monotonic deadline.
    func beginRawCapture(seconds: TimeInterval) {
        rawCapture.open(at: monotonic(), duration: seconds)
    }

    private func recordGroundTruthImu(_ frame: [UInt8]) {
        _ = ImuSessionFileStore.shared.append(deviceId: deviceId, frame: frame,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1_000))
    }

    /// Flush WHILE the window is still active so the just-captured frames get persisted as raw,
    /// THEN close the window.
    func endRawCapture() async {
        await flush()
        rawCapture.close()
    }
}
