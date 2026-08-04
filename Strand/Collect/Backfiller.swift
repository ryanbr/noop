import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - BackfillStoreWriting protocol

/// The async subset the Backfiller needs. Plain async protocol (not @MainActor) so both the
/// real WhoopStore actor and a @MainActor SpyBackfillStore in tests can satisfy it.
protocol BackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
}

extension WhoopStore: BackfillStoreWriting {}

// MARK: - Backfiller

/// Historical-offload state machine (idle / backfilling).
///
/// Per-chunk local safe-trim invariant:
///   decode known → await insert (decoded durable) →
///   await enqueueRawBatch (raw durable) →
///   await setCursor(strap_trim) →
///   ackTrim (link-layer confirmed ack to strap)
///
/// A chunk is forgotten only after decoded AND raw are both locally durable AND the ack
/// (.withResponse) is link-layer confirmed. Never waits on the server.
@MainActor
final class Backfiller {
    /// (parsed frames, deviceClockRef, wallClockRef, sessionOldestUnix?, sessionNewestUnix?) → Streams.
    /// The trailing session-range markers are the strap's GET_DATA_RANGE oldest/newest for THIS sync
    /// (#547 session-relative gate); nil when the range isn't known yet (the absolute-only floor applies).
    typealias Extractor = ([ParsedFrame], Int, Int, Int?, Int?) -> Streams

    private let store: BackfillStoreWriting
    /// Device id offloaded chunks persist under. MUTABLE so a WHOOP↔WHOOP switch
    /// (BLEManager.setActiveDeviceId) re-attributes the next finishChunk persist immediately, rather
    /// than freezing the id captured at construction. Single-WHOOP never switches, so this stays
    /// "my-whoop" exactly as a `let` would have.
    var deviceId: String
    /// Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (= first u32
    /// of end_data, used for the `strap_trim` cursor) and the 8-byte `end_data` (= the raw
    /// HISTORY_END metadata.data[10:18]) that the high-freq-sync ack form requires verbatim.
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) -> Void
    private let extract: Extractor
    /// Research toggle. When false (DEFAULT) no raw frames are persisted — the chunk's
    /// decoded streams are still durable and the trim is still acked (decoded is the product of
    /// record). Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool

    /// The clock reference set by BLEManager when GET_CLOCK confirms (required for decoding).
    var clockRef: ClockRef?

    /// #547 SESSION-RELATIVE gate: the strap's own GET_DATA_RANGE oldest/newest banked-record markers for
    /// the CURRENT offload, set by BLEManager when the range reply lands. A record dated months outside this
    /// window is wandering-clock pollution even if it clears the absolute 2023-11 floor, so the ingest gate
    /// rejects it. nil (both) until the range is known — the gate then falls back to the absolute floor only,
    /// so behaviour is unchanged on the no-range / replay paths. Reset in `begin`.
    var sessionOldestUnix: Int?
    var sessionNewestUnix: Int?

    /// True while a historical offload session is active.
    private(set) var isBackfilling = false

    /// Buffered data frames for the current open chunk (between START and END).
    private var chunk: [[UInt8]] = []
    /// Whether a START has been received and we're accumulating a chunk.
    private var chunkOpen = false
    /// Strap family for the current offload, set at begin(). Drives family-aware frame parsing (WHOOP 5/MG
    /// records sit at +4 offsets vs WHOOP 4.0) and the end_data slice the ack needs. Captured at begin()
    /// rather than init so it's correct even if the Backfiller was constructed before the strap was known.
    private var family: DeviceFamily = .whoop4

    /// Diagnostic sink (strap log). Surfaces historical records whose firmware layout we can't decode.
    private let log: ((String) -> Void)?
    /// Versions already reported this session, so the diagnostic logs each once (no spam).
    private var loggedUnmappedVersions: Set<Int> = []

    /// Per-session persistence tally — the success-side observability the log forensics flagged as the
    /// blind spot (#150): we logged FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't
    /// tell a banking strap from a broken one. Reset at begin(); read by BLEManager at session end to emit
    /// "persisted N rows (M with motion) across K night(s)". Nights are day-keys (ts / 86400).
    private(set) var sessionRowsPersisted = 0
    /// #42: set by `begin` when this session continues an auto-continue burst (#364) that already banked
    /// rows in an earlier session, so a trim=0xFFFFFFFF END here reads as "caught up", not "no history".
    /// Without it the fresh session's `sessionRowsPersisted` is 0 and the scary "charge to 100%" line
    /// false-fires on the empty tail of a sync that just offloaded real records.
    private(set) var continuedAfterRows = false
    /// #57: set true the moment ANY chunk's persist (decoded rows / reject archive / raw enqueue / trim
    /// cursor) fails this session. While set, `finishChunk` must NOT ack — not even a subsequent EMPTY END,
    /// which skips the insert and would otherwise advance the strap's trim PAST the held records-carrying
    /// chunks, freeing history we never stored. The offload stalls safely (strap keeps everything past the
    /// last GOOD ack); a fresh session (`begin`) clears it. Twin of the Android guard. Exposed read-only so
    /// the client can surface a "history isn't persisting" signal in the debug export (#57).
    private(set) var persistStalled = false
    private(set) var sessionMotionRows = 0
    /// #727: skin-temp samples banked this session. WHOOP 4.0 carries skin temp (and the raw SpO2 channel)
    /// ONLY in its full DSP sleep records; a strap banking HR/RR-only records reports 0 here even on a
    /// healthy-looking sync, so surfacing it makes "skin temp never appears" reports self-diagnosing.
    private(set) var sessionSkinTempRows = 0
    private(set) var sessionNightKeys: Set<Int> = []
    var sessionNights: Int { sessionNightKeys.count }

    /// #67 diag: the clock reference the offload ACTUALLY decoded with, captured on the first chunk of the
    /// session. Surfaces whether the stale-RTC timestamp correction (FIX #72's `correctedWall`) could even
    /// engage. `sessionUsedIdentityRef` = no clock correlation had landed when the first chunk decoded, so
    /// that decode fell back to an identity
    /// ref (device==wall==now) → clock offset 0 → correction OFF. On a strap whose RTC has reset, that
    /// silently stores the strap's stale (years-old) timestamps verbatim, so the night lands off the recent
    /// timeline and reads as "missed sleep". Paired with the persisted-nights DATE RANGE below, one strap
    /// log now shows both WHERE the rows landed and WHY. Reset in begin(). Log-only.
    private(set) var sessionClockDevice: Int?
    private(set) var sessionClockWall: Int?
    private(set) var sessionUsedIdentityRef = false
    /// Logged once per session when the strap reports trim=0xFFFFFFFF — the "no valid flash cursor"
    /// sentinel: it has no banked history to offload (a clock/charge state, not a decode bug).
    private var loggedNoCursor = false
    /// #773: logged once per session the first time a HISTORY_END's own timestamp is dated implausibly far
    /// in the FUTURE (a corrupt strap RTC). Distinct from #547's per-record drop tally: this fires on the
    /// chunk metadata's own clock, the earliest visible tell that the strap's RTC is bogus. Reset in begin().
    private var loggedFutureRtc = false

    /// #547: running count of historical records DROPPED this session for an implausible own-timestamp
    /// (a bad-clock strap — far-past / bogus-2027 / future-dated). Tallied across chunks and surfaced once
    /// at a session boundary so a clock-broken strap is visible in the strap log (observability only — the
    /// ingest gate already kept the garbage rows out of the DB).
    private(set) var sessionDroppedImplausible = 0

    /// #891 diagnostic: packet types this session's offload carried that the decoder has no rows for,
    /// folded across chunks. Each type is logged the FIRST time it appears — a 30k-record offload must not
    /// emit 30k lines — and the running total is what a later line can report. See
    /// `Streams.unhandledPacketTypes` for why this is not derivable from anything already logged: an
    /// unmapped type is dropped by the decoder AND excluded from the reject archive, so today it is
    /// invisible and the sync reports clean.
    private(set) var sessionUnhandledPacketTypes: [String: Int] = [:]

    /// #520 diagnostic: `dynamic_acceleration` folded across every chunk of this session, logged once at
    /// the session boundary. Session-scoped rather than per-chunk because a chunk is an arbitrary slice of
    /// an offload — a still-fraction only means something over a whole night's worth of records.
    private(set) var sessionDynAccel = Streams.DynAccelDiag()

    /// The trim cursor of the LAST chunk this Backfiller acked (durably persisted + confirmed to the
    /// strap). Survives across sessions on the same connection so the auto-continue gate (#364) can ask
    /// "did the offload actually advance the strap's trim this session?" — the spin-detector signal that
    /// stops it re-kicking forever when the cursor is frozen. nil until the first ack. NOT reset in
    /// `begin()` (it's a cross-session high-water mark, not a per-session tally).
    private(set) var lastAckedTrim: UInt32?

    /// Distinct historical layout versions logged this session. Unlike `loggedUnmappedVersions` (which
    /// only fires for layouts NOOP can't decode), this surfaces the layout on a HEALTHY sync too, so a
    /// shared strap log always reveals what the strap emits (v18/v24/v25/v26). Mirrors the Android
    /// Backfiller (PR #241, ryanbr); reset per session in `begin`.
    private var loggedLayoutVersions: Set<Int> = []

    /// SpO2 RE dump (PR #945, reimplemented): how many full-record dumps this session emitted, bounded by
    /// `Spo2ReTrace.maxSamples`. Session-scoped so the cap spans chunks; reset per session in `begin`.
    private var spo2Dumped = 0

    /// Durably archives undecodable record frames BEFORE the trim ack (#77 / #91). Returns true once
    /// the bytes are safe (written OR cap-reached — either way the chunk may be acked) and false on a
    /// genuine write failure, in which case `finishChunk` holds the cursor/ack so the strap re-sends.
    /// nil in non-production inits (tests/preview) → archiving is skipped and acks proceed as before.
    private let rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)?
    /// Per-chunk outcome hook (#77 family): (didDecodeSensorRows, wasConsoleOnly). Lets BLEManager
    /// tally a session so a COMPLETED-but-empty offload (all console, no sensor records) can tell the
    /// user their strap isn't banking, without false-positiving a normal caught-up sync.
    private let onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)?

    /// Connection & Sync test mode (Test Centre): the cheap gate + tagged sink for the .connection
    /// diagnostic lines (offload progress / firmware layout / trim sentinel). `connectionActive` is one
    /// UserDefaults bool read; we ALWAYS check it BEFORE building any connection line, so the Backfiller
    /// pays nothing when the mode is off. `connectionLog` appends the already-built line tagged .connection.
    /// Both default inert (always-off / nil) so tests + non-prod inits get the byte-identical untraced path.
    private let connectionActive: () -> Bool
    private let connectionLog: ((String) -> Void)?
    /// UNIVERSAL clock-drift wiring (RTC cluster): banks the strap's historical record-layout version
    /// (hist_version) onto LiveState so the export assembler's universal clock-drift line is firmware-aware
    /// on EVERY export, not only in Connection mode. Called UNCONDITIONALLY (it is observability, not gated)
    /// once per distinct layout this session. Default nil (inert) so tests / non-prod inits are untouched.
    private let firmwareLayout: ((Int) -> Void)?

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) -> Void,
         enableRawCapture: Bool = false,
         log: ((String) -> Void)? = nil,
         rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) -> Bool)? = nil,
         onChunk: ((_ decoded: Bool, _ console: Bool) -> Void)? = nil,
         connectionActive: @escaping () -> Bool = { false },
         connectionLog: ((String) -> Void)? = nil,
         firmwareLayout: ((Int) -> Void)? = nil,
         // The default (prod) Extractor reads the opt-in HR-from-PPG sub-lag interpolation flag (Test Centre →
         // Experimental algorithms) at decode time and threads it into the pure decoder, so the pure package
         // never reaches for UserDefaults. Default OFF = byte-identical to today. Tests inject their own seam.
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2,
                                                                    sessionOldestUnix: $3, sessionNewestUnix: $4,
                                                                    subLagInterp: PuffinExperiment.ppgHrSubLagInterpEnabled) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        self.enableRawCapture = enableRawCapture
        self.log = log
        self.rejectedSink = rejectedSink
        self.onChunk = onChunk
        self.connectionActive = connectionActive
        self.connectionLog = connectionLog
        self.firmwareLayout = firmwareLayout
        self.extract = extract
    }

    /// Emit one Connection & Sync test-mode line iff the mode is on. The cheap `connectionActive()` gate is
    /// checked BEFORE `build()` runs, so the line string is never constructed when the mode is off (the
    /// @autoclosure defers it). Diagnostic only - it never changes the offload path.
    private func emitConnection(_ build: @autoclosure () -> String) {
        guard connectionActive(), let connectionLog else { return }
        connectionLog(build())
    }

    /// Called by BLEManager when the strap signals a historical offload is beginning.
    /// chunkOpen starts TRUE: the high-freq-sync biometric replay streams records immediately and
    /// sends one HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
    func begin(family: DeviceFamily, continuedAfterRows: Bool = false) {
        self.family = family
        self.continuedAfterRows = continuedAfterRows
        isBackfilling = true
        persistStalled = false   // #57: fresh session starts un-stalled
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
        sessionRowsPersisted = 0
        sessionMotionRows = 0
        sessionSkinTempRows = 0
        sessionNightKeys.removeAll(keepingCapacity: true)
        sessionClockDevice = nil          // #67: re-capture the decode clock ref for this session
        sessionClockWall = nil
        sessionUsedIdentityRef = false
        loggedNoCursor = false
        loggedFutureRtc = false
        sessionDroppedImplausible = 0
        sessionUnhandledPacketTypes = [:]   // #891: a second offload must re-log its first sighting
        sessionDynAccel = Streams.DynAccelDiag()
        loggedLayoutVersions.removeAll(keepingCapacity: true)
        spo2Dumped = 0
        // #547: the range markers belong to a connection's GET_DATA_RANGE, which BLEManager re-sets per
        // connect; clear them here so a fresh session never reuses a previous strap's window. BLEManager
        // re-publishes them as soon as the range reply arrives.
        sessionOldestUnix = nil
        sessionNewestUnix = nil
    }

    /// Feed one raw BLE frame into the state machine. May trigger async store operations.
    func ingest(_ frame: [UInt8]) async {
        switch classifyHistoricalMeta(parseFrame(frame, family: family)) {
        case .start:
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8], family: DeviceFamily) -> [UInt8]? {
        // metadata.data begins at frame[7] (WHOOP4) / frame[11] (WHOOP5, the +4 puffin envelope); the
        // ack's end_data = data[10:18] → frame[17:25] (WHOOP4) or frame[21:29] (WHOOP5). The WHOOP5 slice
        // is verified on a real HISTORY_END (trim=112193 = frame[21..25]) in Whoop5HistoricalTests.
        let start = family == .whoop5 ? 21 : 17
        guard frame.count >= start + 8 else { return nil }
        return Array(frame[start..<(start + 8)])
    }

    /// Pure per-chunk persistence tally (#150). `rows` = biometric rows actually inserted (HR, R-R, SpO2,
    /// skin-temp, resp, gravity — battery/events are housekeeping, not biometric history). `motion` =
    /// gravity rows (the sleep-critical signal). `nights` = the distinct day-keys (ts / 86400) the chunk's
    /// records covered. Summed across a session by finishChunk to drive the success summary line.
    nonisolated static func chunkTally(
        counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int),
        timestamps: [Int]
    ) -> (rows: Int, motion: Int, nights: Set<Int>) {
        let rows = counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity
        return (rows, counts.gravity, Set(timestamps.map { $0 / 86400 }))
    }

    /// The one-line session success summary (#150) — the success-side log that never existed. Returns nil
    /// when nothing persisted (so a console-only / caught-up session stays quiet and the existing
    /// empty-banking diagnostics speak instead).
    nonisolated static func sessionSummaryLine(rows: Int, motion: Int, skinTemp: Int, nights: Int) -> String? {
        guard rows > 0 else { return nil }
        return "Backfill: session persisted \(rows) rows (\(motion) with motion, \(skinTemp) skin-temp) across \(nights) night(s)."
    }

    /// #67 diag: the persisted-nights DATE RANGE plus the offload's effective clock state — the two facts
    /// the summary above omits. `nightKeys` are UTC day-keys (ts / 86400); their min/max are the day(s) the
    /// rows LANDED on. When those days sit years in the past while the clock ref reads ~now (an identity
    /// fallback, or an in-sync ref on a strap that banked stale), the night is misdated off the recent
    /// timeline — the "missed sleep" signature (#67). Returns nil when nothing landed. Log-only, pure.
    nonisolated static func sessionClockDiagLine(nightKeys: Set<Int>,
                                                 device: Int?, wall: Int?, usedIdentityRef: Bool) -> String? {
        guard let lo = nightKeys.min(), let hi = nightKeys.max() else { return nil }
        let day: (Int) -> String = { key in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")   // fixed Gregorian yyyy — not the device calendar
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date(timeIntervalSince1970: Double(key) * 86_400))
        }
        let range = lo == hi ? day(lo) : "\(day(lo))…\(day(hi))"
        var line = "Backfill: rows landed on \(range)"
        if let device, let wall {
            let offset = wall - device
            let days = offset / 86_400
            if usedIdentityRef {
                line += " · clock ref: IDENTITY fallback (no clock correlation at decode) - stale-record correction OFF"
            } else if abs(offset) > 86_400 {
                line += " · strap clock \(days >= 0 ? "\(days)d behind" : "\(-days)d ahead") wall - correction engaged"
            } else {
                line += " · clock ref in sync"
            }
        }
        return line
    }

    /// The trim=0xFFFFFFFF sentinel line (#783). 0xFFFFFFFF means two different things depending on whether
    /// THIS run already banked rows. On the first end of a fresh offload it's the "no valid flash cursor"
    /// state (no banked history, a clock/charge problem). But the #364 auto-continuation re-kicks
    /// SEND_HISTORICAL after a run that DID persist rows, and the next end then carries 0xFFFFFFFF to mean
    /// "caught up, nothing left past the last trim", NOT "no history". Emitting the alarming "fully charge
    /// it" line there falsely scared users whose strap had just synced fine. So pick by `rowsPersisted`:
    /// > 0 gives a neutral caught-up line; 0 gives the genuine no-history guidance. Pure so a fixture pins both.
    nonisolated static func noCursorLine(rowsPersisted: Int, continuedAfterRows: Bool = false) -> String {
        if rowsPersisted > 0 {
            return "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up after persisting \(rowsPersisted) row(s) this run. Nothing more to offload."
        }
        // #42: the empty tail of an auto-continue burst (#364) that banked rows in an EARLIER session. The
        // strap synced fine — this pass just confirms we're caught up — so DON'T false-alarm "no banked
        // history / charge to 100%".
        if continuedAfterRows {
            return "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up; the strap handed over its banked history earlier this sync. Nothing more to offload."
        }
        return "Backfill: strap reported no flash cursor (trim=0xFFFFFFFF) - it has no banked history to offload. This is a clock/charge state on the strap, not a decode problem; fully charge it and reconnect so it starts banking."
    }

    /// #773: how far ahead of the wall clock a HISTORY_END's own timestamp may sit before we call the strap
    /// RTC corrupt. The strap RTC and the phone normally agree within seconds; a genuine offload is always
    /// dated in the PAST (it's banked history). A timestamp dated days into the FUTURE can only be a corrupt
    /// strap clock. Generous (1 day) so ordinary skew or a timezone confusion never trips it.
    nonisolated static let futureRtcToleranceSeconds = 86_400

    /// #773: is this HISTORY_END timestamp an implausible FUTURE date (a corrupt strap RTC)? `endUnix` and
    /// `wallNowUnix` are unix seconds in the same wall domain. Pure so a fixture pins the boundary.
    nonisolated static func isCorruptFutureRtc(endUnix: Int, wallNowUnix: Int) -> Bool {
        endUnix > wallNowUnix + futureRtcToleranceSeconds
    }

    /// #773: the recovery-hint line for a corrupt future-dated strap RTC. Names the cause plainly (the
    /// strap's clock, not a NOOP bug) and gives the fix (charge + reconnect re-syncs the RTC). Byte-identical
    /// to the Android twin. No em-dash (project rule).
    nonisolated static func futureRtcLine(endUnix: Int, wallNowUnix: Int) -> String {
        let aheadDays = max(0, (endUnix - wallNowUnix)) / 86_400
        return "Backfill: the strap reported a record dated about \(aheadDays) day(s) in the FUTURE - its clock (RTC) is corrupt, not a NOOP problem. Those records can't be filed onto the right day. Fully charge the strap to 100% and reconnect so it re-syncs its clock; if it persists, forget and re-pair the strap."
    }

    /// Commit one HISTORY_END chunk: (persist decoded → enqueueRaw when present) → setCursor → ackTrim.
    /// Early-returns on any throw to preserve the safe-trim invariant.
    ///
    /// CRITICAL: high-freq-sync sends ONE HISTORY_START then REPEATED HISTORY_ENDs (a chunk-close
    /// every ~50 records). So we must ack EVERY end and keep accumulating afterwards — NOT close
    /// the chunk after the first. We snapshot+clear the accumulated frames but leave `chunkOpen`
    /// TRUE so the records following this END become the next chunk. An END with no accumulated
    /// records is still acked (it advances the strap's trim) — that's how the offload progresses.
    /// `endFrame` carries the 8-byte `end_data` the ack requires.
    /// The pure decode result of one offload chunk, produced OFF the main actor (see finishChunk).
    private struct DecodedChunk {
        let parsed: [ParsedFrame]
        let decoded: Streams
        let rejected: [[UInt8]]
    }

    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Backfiller.endData(from: endFrame, family: family) else { return }

        // #773: corrupt future-RTC detection. A HISTORY_END carries the strap's own clock; a genuine offload
        // is always PAST-dated (it's banked history), so an end dated days into the future can only be a
        // corrupt strap RTC. Surface it ONCE per session with a recovery hint so the cause (the strap clock,
        // not a NOOP bug) is named and the fix (charge + reconnect re-syncs the RTC) is given. Observability
        // only - the ack still proceeds and the #547 ingest gate already keeps the bad-dated rows out of the
        // DB. The 0xFFFFFFFF sentinel above is a different state (it isn't a real date), so skip it here.
        if trim != 0xFFFFFFFF, !loggedFutureRtc {
            let wallNow = Int(Date().timeIntervalSince1970)
            if Backfiller.isCorruptFutureRtc(endUnix: Int(unix), wallNowUnix: wallNow) {
                loggedFutureRtc = true
                log?(Backfiller.futureRtcLine(endUnix: Int(unix), wallNowUnix: wallNow))
            }
        }

        let frames = chunk
        chunk.removeAll(keepingCapacity: true)   // next records accumulate into the next chunk

        if !frames.isEmpty {
            // type-47 HISTORICAL_DATA carries its OWN real-unix timestamp — extractHistoricalStreams
            // ignores the clock offset for it — so the historical offload does NOT need GET_CLOCK.
            // If the (device,wall) correlation isn't established yet (e.g. GET_CLOCK silent), fall back
            // to an identity ref (device==wall==now): the offset math becomes a no-op, type-47 still
            // decodes to correct wall time, and we can persist + ack + upload. The correlation is only
            // truly required to map REALTIME (type-40/43) device-epoch timestamps, never in a hist chunk.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()
            // #67 diag: remember the ref (and whether it was the identity fallback) for the session summary,
            // so a strap log shows whether stale-RTC correction could engage. Captured on the first chunk.
            if sessionClockDevice == nil {
                sessionClockDevice = ref.device
                sessionClockWall = ref.wall
                sessionUsedIdentityRef = (clockRef == nil)
            }
            // PERF (2026-07-03): the heavy decode — parseFrame ×N, extractHistoricalStreams, and the
            // reject-classifier's SECOND full parse — runs OFF the main actor so a long history offload no
            // longer freezes the UI (was ~54K parseFrame calls on main for a 27K-row import). Pure functions
            // only; every @Published write, the store insert, and the ack/cursor sequence below stay on the
            // main actor in the SAME order, so the persist→archive→cursor→ack trim-safety is untouched.
            let fam = family
            let dev = ref.device, wall = ref.wall
            let oldest = sessionOldestUnix, newest = sessionNewestUnix
            let extractFn = extract   // keep the injected Extractor seam (tests override it); prod == extractHistoricalStreams
            let d = await Task.detached(priority: .utility) { () -> DecodedChunk in
                let parsed = frames.map { parseFrame($0, family: fam) }
                let decoded = extractFn(parsed, dev, wall, oldest, newest)
                let rejected = rejectedHistoricalRecords(frames, family: fam)
                return DecodedChunk(parsed: parsed, decoded: decoded, rejected: rejected)
            }.value
            let parsed = d.parsed
            // Observability (PR #241): log which layout this strap emits on a HEALTHY sync too — the
            // unmapped-version path below only fires for layouts NOOP can't decode, so a normal log
            // never revealed v18/v24/v25/v26. Once per distinct layout this session.
            if let v = parsed.lazy.compactMap({ $0.parsed["hist_version"]?.intValue }).first,
               loggedLayoutVersions.insert(v).inserted {
                log?("Backfill: historical records use layout v\(v)")
                // UNIVERSAL clock-drift: bank the layout so the export's universal clock-drift line is
                // firmware-aware on every export (not only Connection mode). Unconditional observability.
                firmwareLayout?(v)
                // Connection test mode: the firmware layout as a compact tagged line. A layout that decoded
                // a signature field (heart_rate / gravity_x / ppg_waveform) is decodable; otherwise the
                // unmapped-version path below fires too. Gated zero-cost.
                emitConnection({
                    let decodable = parsed.contains {
                        $0.parsed["heart_rate"] != nil || $0.parsed["gravity_x"] != nil
                            || $0.parsed["ppg_waveform"] != nil
                    }
                    return ConnectionTrace.firmwareLine(version: v, decodable: decodable)
                }())
            }
            // SpO2 RE dump (PR #945, reimplemented): while the Connection test mode is on, dump a few FULL
            // historical records + their mapped raw SpO2 channels so an offline pass can tell whether the
            // strap banks a COMPUTED SpO2 (a byte tracking the WHOOP app's nightly %) vs only the raw
            // red/IR ADC we already decode. Log-only and bounded per session across chunks (`spo2Dumped`,
            // reset in begin); zero-cost when the mode is off (one Bool short-circuit). Only genuine
            // historical records (a decoded `unix`) spend the sample budget - the strap's type-50 console
            // frames carry no record bytes to correlate. Records dump whether or not they carry SpO2
            // channels, so "nothing banked" is provable too. Never a user-facing number (never-fabricate;
            // the #194 lesson). Twin of the Android Backfiller emit.
            if spo2Dumped < Spo2ReTrace.maxSamples, connectionActive(), let connectionLog {
                for (raw, p) in zip(frames, parsed) where spo2Dumped < Spo2ReTrace.maxSamples {
                    guard let unix = p.parsed["unix"]?.intValue else { continue }
                    connectionLog(Spo2ReTrace.recordLine(
                        frame: raw,
                        version: p.parsed["hist_version"]?.intValue,
                        unix: unix,
                        red: p.parsed["spo2_red"]?.intValue,
                        ir: p.parsed["spo2_ir"]?.intValue,
                        skinRaw: p.parsed["skin_temp_raw"]?.intValue))
                    spo2Dumped += 1
                }
            }
            // Diagnostic (#30): a historical record whose firmware version we don't have a field map for
            // bails out of decode entirely — no HR, no R-R, no GRAVITY — so sleep (which is gravity/
            // motion-driven) can never be computed from it, even though the offload "completes". Surface
            // each unmapped version once so the user's strap log reveals what their firmware emits.
            // "Decoded nothing" must cover every mapped layout's signature field: v18 emits heart_rate,
            // v25 emits gravity_x (no per-second HR — it's PPG-derived), v26 emits ppg_waveform (no HR
            // either) — checking heart_rate alone false-flagged v25/v26 as unmapped (#156, sudden-break).
            for p in parsed {
                guard let v = p.parsed["hist_version"]?.intValue,
                      p.parsed["heart_rate"] == nil,
                      p.parsed["gravity_x"] == nil,
                      p.parsed["ppg_waveform"] == nil,
                      !loggedUnmappedVersions.contains(v) else { continue }
                loggedUnmappedVersions.insert(v)
                log?("Historical records use firmware layout v\(v), which NOOP doesn't decode yet — no motion data, so sleep can't be computed from the strap. Please report this (issue #30).")
            }
            let decoded = d.decoded
            // #520: accumulate the motion-magnitude diagnostic across the session; logged once at the
            // session boundary by BLEManager, never per chunk. Merge logic lives in WhoopProtocol so it is
            // covered by swift-packages CI — this app-target file is not.
            sessionDynAccel.merge(decoded.dynAccel)
            // #547: surface a bad-clock strap. extractHistoricalStreams DROPPED any record whose own unix
            // timestamp was implausible (far-past / bogus-2027 / future-dated) before it could pollute the
            // DB. Log it (once it's accrued at least one this session, on the first chunk that sees it) so
            // the user's strap log explains why a clock-broken strap banks fewer rows than expected — this
            // is the strap's clock, not a NOOP decode bug. Observability only; the gate already did the work.
            if decoded.droppedImplausible > 0 {
                let wasZero = sessionDroppedImplausible == 0
                sessionDroppedImplausible += decoded.droppedImplausible
                if wasZero {
                    // #324: append the epoch SPAN of the dropped block + how far off it sits, so the strap log
                    // shows WHETHER the whole banked range is future-dated (safe to fast-forward-discard) or
                    // just a slice. `droppedImplausibleOldestTs/NewestTs` are the records' OWN dated values
                    // (the strap's wrong clock), captured by the #547 gate as it dropped them.
                    let span = BadClockDiagnostics.droppedSpanClause(
                        oldest: decoded.droppedImplausibleOldestTs,
                        newest: decoded.droppedImplausibleNewestTs,
                        now: Int(Date().timeIntervalSince1970))
                    log?("Backfill: dropped record(s) with an implausible timestamp (trim=\(trim))\(span) — the strap's clock is wrong (records dated far in the past or future), so those samples were skipped rather than misfiled onto the wrong day. Fully charge and reconnect the strap so its clock re-syncs.")
                }
            }
            // #324: the strap RTC-state events (RTC_LOST / BOOT / SET_RTC) the #547 gate dropped for a bad
            // own-timestamp — the GROUND TRUTH that the clock reset. Sparse (not per-record), so log each as
            // it appears; the bad `rawTs` is the future/past base the RTC jumped to.
            let nowForRtc = Int(Date().timeIntervalSince1970)
            for ev in decoded.droppedRtcEvents {
                log?("Backfill: strap reported \(ev.kind) with an implausible own-timestamp \(BadClockDiagnostics.isoDay(ev.rawTs)) (\(BadClockDiagnostics.hoursOffset(ev.rawTs, now: nowForRtc)) vs now) — the strap's RTC reset to a wrong base (#324/#928); this is the ground-truth cause of the future-dated banking, not a NOOP decode bug.")
            }
            // #891: packet types this chunk carried that the decoder has no case for. Logged the first
            // time each type appears so a long offload stays readable. This is the only place such a
            // record becomes visible: `default:` drops it and `rejectedHistoricalRecords` archives only
            // type-47, so without this line an offload full of an unmapped type reports a clean sync.
            for (typeName, n) in decoded.unhandledPacketTypes.sorted(by: { $0.key < $1.key }) {
                let firstSighting = sessionUnhandledPacketTypes[typeName] == nil
                sessionUnhandledPacketTypes[typeName, default: 0] += n
                if firstSighting {
                    log?("Backfill: the strap sent \(n) record(s) of packet type \(typeName), which this " +
                         "decoder has no rows for — they are being dropped. If \(typeName) is not a name " +
                         "you recognise, this is a firmware record type NOOP has never mapped: please " +
                         "report it on #891 with the strap model and firmware build.")
                }
            }
            // Diagnostic (#77): the AGGREGATE silent-loss case — frames arrived but produced no rows at
            // all (CRC fail / unmapped layout / out-of-range timestamp), so this chunk persists nothing
            // yet still acks below and the strap trims past it. The per-version log above only catches
            // unmapped layouts; this catches CRC drops too. Observability only — behaviour unchanged
            // (not acking would wedge the offload on a re-send loop). Surfaces in the user's strap log.
            // Classify FIRST: separate genuinely-undecodable SENSOR records from the strap's own
            // type-50 console/diagnostic frames, which decode to 0 rows by design and are NOT a loss
            // (the "rejected frames" red herring users kept reporting — #77/#120). Drives both the
            // log wording below and the archive guard further down.
            let rejected = d.rejected
            // Tally this chunk's outcome so a completed-but-empty session is distinguishable from a
            // caught-up one (#77 family): did it decode sensor rows, and was it console-only?
            onChunk?(!decoded.isEmpty, decoded.isEmpty && rejected.isEmpty)
            // A chunk that produced no rows AND held no genuine rejects was pure console output — say
            // so calmly so it doesn't read as data loss (the "rejected frames" red herring, #77/#120).
            if decoded.isEmpty && rejected.isEmpty {
                log?("Backfill: \(frames.count) frame(s) this chunk carried no sensor records (strap console/diagnostic output) — normal, nothing to persist (trim=\(trim)).")
            }
            // Log + hex-sample the GENUINE rejects whenever there are any — INCLUDING a partially-decoded
            // chunk (some good rows alongside CRC-failed / unmapped records), which used to archive those
            // raw bytes with no log line at all (only the all-empty case was observable). (ryanbr, PR #123)
            if !rejected.isEmpty {
                log?("Backfill: \(rejected.count) undecodable sensor record(s) of \(frames.count) frame(s) (trim=\(trim)) — archiving raw bytes before ack (CRC/unmapped layout).")
                // #91 / #30: dump a hex sample of the genuine rejects so an unmapped firmware's record
                // layout can be mapped from a user's strap log. Dump the FULL frame (not a 64-byte
                // prefix — v25/v26 records run ~84 B and the truncated tail is exactly where the
                // unmapped motion/HR fields sit), and sample a few more so one log carries enough
                // records to triangulate offsets. These only ever fire for unmapped firmware.
                for (i, f) in rejected.prefix(8).enumerated() {
                    let hex = f.map { String(format: "%02x", $0) }.joined()
                    log?("Backfill: rejected frame[\(i)] \(f.count)B: \(hex)")
                }
            }
            // Commit the decoded rows FIRST (durable). Doing this before the reject archive means a
            // rare insert failure — which returns and re-sends the whole chunk next session — can't
            // leave duplicate lines in the append-only reject archive.
            let counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
            do { counts = try await store.insert(decoded, deviceId: deviceId) } catch {
                // Diag (#601): the decoded rows couldn't be written — this is the "history stalls but live HR
                // works" class. We return WITHOUT acking so the strap keeps this chunk and re-sends it next
                // session (no data loss), but a silent return left a strap log with no trace of the stall.
                log?("Backfill: failed to persist decoded rows (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk; history won't advance until the write succeeds.")
                persistStalled = true   // #57: stall ALL further acks so an empty END can't advance past this
                return
            }
            // Success-side observability (#150): tally what actually persisted so the session can emit
            // "persisted N rows (M with motion) across K night(s)" — the win-rate signal a log never had.
            let tally = Backfiller.chunkTally(counts: counts, timestamps: decoded.gravity.map(\.ts) + decoded.hr.map(\.ts))
            sessionRowsPersisted += tally.rows
            sessionMotionRows += tally.motion
            sessionSkinTempRows += counts.skinTemp
            sessionNightKeys.formUnion(tally.nights)

            // Connection test mode: per-chunk offload PROGRESS (running session totals), so a report shows
            // the offload advancing rather than only its final outcome. Gated zero-cost.
            emitConnection("offload progress trim=\(trim) chunkRows=\(tally.rows) "
                + "sessionRows=\(sessionRowsPersisted) sessionMotion=\(sessionMotionRows) nights=\(sessionNights)")

            // #77 / #91: any genuinely-undecodable type-47 record in this chunk must be ARCHIVED
            // before we ack — the ack frees the strap's copy, so the archive is the only remaining
            // copy of an unmapped firmware's records. A genuine archive write FAILURE aborts the
            // chunk (no setCursor, no ack) so the strap re-sends it next session — no data loss
            // either way. (A full archive is reported as success by the sink; we still ack.)
            if !rejected.isEmpty, let rejectedSink {
                guard rejectedSink(rejected, trim, family) else {
                    log?("Backfill: rejected-frame archive failed (trim=\(trim)) — holding ack so the strap re-sends.")
                    persistStalled = true   // #57
                    return
                }
            }

            // RAW: only persisted when the research toggle is ON. Default OFF → decoded-only; the
            // chunk is still durably committed (decoded) so the trim is safe to advance + ack.
            if enableRawCapture {
                let meta = RawBatchMeta(
                    batchId: "hist-\(deviceId)-\(trim)",
                    deviceId: deviceId,
                    clockRef: ref,
                    capturedAt: Int(Date().timeIntervalSince1970),
                    startTs: ref.wall,
                    endTs: ref.wall,
                    frameCount: frames.count,
                    byteSize: frames.reduce(0) { $0 + $1.count })
                do { try await store.enqueueRawBatch(meta, frames: frames) } catch {
                    // Diag (#601): raw-capture is ON and the raw batch couldn't be enqueued. Hold the ack
                    // (return) so the strap re-sends — the research toggle's contract is that raw is durable
                    // before the trim advances. Surface it so a stalled offload with raw-capture on is visible.
                    log?("Backfill: failed to enqueue raw batch (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk; raw capture must be durable before the trim advances.")
                    persistStalled = true   // #57
                    return
                }
            }
        }

        // #150 / #783 / #1: trim=0xFFFFFFFF is the strap's "no valid flash cursor" sentinel. Its MEANING
        // depends on whether this run already banked anything. On the FIRST end of a fresh offload it means
        // "no banked history" (a clock/charge state). But the auto-continuation (#364) re-kicks
        // SEND_HISTORICAL after a run that DID persist rows, and the very next end then carries 0xFFFFFFFF
        // to mean "you are caught up, nothing left past the last trim", NOT "no history". Emitting the scary
        // "fully charge it" line there was wrong and alarmed users whose strap had just synced fine (#783).
        // We gate this AFTER the persist block (#1): a bad-clock/flash strap can emit records on the SAME
        // 0xFFFFFFFF END, so `sessionRowsPersisted` must already include THIS end's own rows before the
        // pick, otherwise a records-bearing no-cursor END false-alarms "no banked history". So gate on
        // `sessionRowsPersisted == 0` HERE: if rows landed (this run or this END), log the neutral caught-up
        // line; a genuinely empty session (0 rows) still gets the real no-history guidance. Logs once per
        // session (loggedNoCursor) and the ack still proceeds below.
        if trim == 0xFFFFFFFF, !loggedNoCursor {
            loggedNoCursor = true
            log?(Backfiller.noCursorLine(rowsPersisted: sessionRowsPersisted, continuedAfterRows: continuedAfterRows))
            // Connection test mode: the no-cursor sentinel as a compact tagged line (gated zero-cost).
            emitConnection(ConnectionTrace.noCursorLine())
        }

        // #57: if an EARLIER chunk this session failed to persist, do NOT advance the cursor or ack — not
        // even for this (possibly empty/metadata) END. An empty END skips the insert and never throws;
        // acking it would trim the strap PAST the held records-carrying chunks, freeing history we never
        // stored. Stall the whole offload until a fresh session with a working store re-offers everything
        // past the last GOOD ack. Twin of the Android guard.
        if persistStalled {
            log?("Backfill: persist stalled earlier this session — NOT acking trim=\(trim) so the strap can't trim past un-stored history. Reconnect once the store is healthy (#57).")
            return
        }

        do { try await store.setCursor("strap_trim", Int(trim)) } catch {
            // Diag (#601): decoded (and raw, if on) are durable but the strap_trim cursor write failed. We
            // return WITHOUT acking — acking now would let the strap trim past records the cursor hasn't
            // recorded, so on reconnect the offload could replay or skip. Holding the ack keeps it safe; the
            // strap re-offers this chunk next session. A silent return here was a prime "history won't advance"
            // suspect with nothing in the log to confirm it.
            log?("Backfill: failed to write strap_trim cursor (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk; history won't advance until the cursor write succeeds.")
            persistStalled = true   // #57
            return
        }

        ackTrim(trim, endData)
        lastAckedTrim = trim   // #364: record the advanced cursor for the auto-continue spin-detector
    }

    /// Called when a backfill watchdog timer fires (strap went silent mid-offload).
    /// Clears state without acking — the chunk was never durably committed.
    func timeoutFired() {
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }
}
