import Foundation

// OuraDriver: the transport-agnostic protocol state machine (architecture plan s1). It holds NO BLE
// handle: the app's OuraLiveSource owns the CBCentralManager / BluetoothGatt and feeds the driver
// only bytes + transition events. This is what makes the protocol headless-testable (no CoreBluetooth,
// no android.bluetooth anywhere in this package).
//
// Two entry points:
//   - nextStep(after:) -> [OuraCommand]   : given the last transition, return the commands to write.
//   - ingest(record:) -> [OuraEvent]      : given a parsed TLV record, return decoded events.
//   - ingestLiveHRPush(body:) -> [OuraEvent] : given a 0x2F sub-op 0x28 push body, return live HR.
//
// The flow mirrors OURA_PROTOCOL.md s3 (auth) + s5 (live HR / fetch): scan -> connect -> notify ->
// auth (nonce, proof) -> enable live HR (gen-appropriate triplet) -> stream. RingGen swaps the
// command set, not the code path.
//
// Tier discipline: Tier-B decoders are present but gated behind `allowTierB` (default false). When
// false, a Tier-B tag decodes to nothing (the event is dropped), so Tier-B values can never feed
// scoring silently. Per the brief's TIER DISCIPLINE and OURA_PROTOCOL.md s7.3.

/// A transport-level transition the app reports to the driver to advance the flow. The driver answers
/// with the next batch of commands. This keeps all BLE specifics (CBPeripheral, GATT callbacks) in
/// the app and all protocol specifics here.
public enum OuraTransition: Equatable, Sendable {
    /// Service + characteristics discovered and notifications enabled on ...0003. Begin auth.
    case ready
    /// A 15-byte nonce arrived (from the GetAuthNonce response). Compute + submit the proof.
    case nonceReceived([UInt8])
    /// The auth handshake completed with this status. On success, begin enabling live HR.
    case authCompleted(OuraAuthStatus)
    /// A live-HR enable/subscribe ACK arrived; advance the triplet (or, when done, mark streaming).
    case enableAckReceived
    /// The app wants to fetch buffered history from this cursor (optional path).
    case startHistoryFetch(cursor: UInt32)
    /// The last GetEvents response advanced the cursor to this value; continue or stop.
    case historyCursorAdvanced(cursor: UInt32, moreData: Bool)
}

/// The driver's coarse phase, exposed for the app and tests to assert on.
public enum OuraDriverPhase: Equatable, Sendable {
    case idle
    case authenticating
    case enablingLiveHR
    case streaming
    case fetchingHistory
    case needsKeyInstall      // ring is in factory reset; honest pairing path (s3.5 status 0x02)
    case installingKey        // post-factory-reset key install in flight (s3.2); awaiting the 0x25 ack
    case authFailed(OuraAuthStatus)
    case stopped
}

public final class OuraDriver {
    public let ringGen: OuraRingGen
    /// The 16-byte application auth key (injected, never hardcoded). nil drives the honest
    /// needs-pairing path (the app surfaces "needsPairing" instead of faking data, Huami precedent).
    private let authKey: [UInt8]?
    /// When false (default), Tier-B (UNVERIFIED) tags decode to nothing so they can never feed scoring.
    public let allowTierB: Bool
    /// When false (default), the driver MUST NOT sequence a post-factory-reset key install: it stays at
    /// needsKeyInstall and writes nothing dangerous. Only an explicit opt-in adopt flow sets this true.
    /// Per OURA_PROTOCOL.md s3.2 (the 0x24 SetAuthKey is a DANGEROUS, one-time provisioning write).
    public let allowKeyInstall: Bool

    public private(set) var phase: OuraDriverPhase = .idle
    /// Tracks how many of the live-HR enable triplet ACKs have been seen.
    private var liveHREnableStep = 0
    /// The most recent ring time seen on any record, used to stamp live-HR pushes (which are not TLV
    /// records and carry no timestamp of their own).
    private var lastRingTimestamp: UInt32 = 0
    /// Ring-time -> UTC anchor (OURA_PROTOCOL.md s5.5): the ring's clock ticks at 100 ms/tick by default
    /// (burst-mode 1 ms/tick, s5.5, is NOT modeled in v1). Set from the ring's own 0x42 time-sync event
    /// (primary) or, only while no 0x42 has arrived yet THIS session, the coarser 1s-granularity 0x85 RTC
    /// beacon (secondary). nil until the first anchor event of this session: a record decoded before then
    /// has no computable UTC time, and `unixSeconds(forRingTimestamp:)` honestly returns nil rather than
    /// guessing. A stale anchor from a PREVIOUS session is never reused - the ring may have rebooted.
    private var anchorUtcMs: Int64?
    private var anchorRingTime: UInt32?
    /// The freshly-provisioned key the transport generated during an adopt flow (s3.2). Once set by
    /// beginKeyInstall it becomes the effective key for the post-install re-auth. nil otherwise.
    private var installedKey: [UInt8]?

    /// The key the auth handshake should use: the freshly-installed key takes precedence over the
    /// injected one (so re-auth after a key install uses the new key). Per OURA_PROTOCOL.md s3.2.
    private var effectiveKey: [UInt8]? { installedKey ?? authKey }

    /// Wall-clock "now" in unix ms, used ONLY to reject a banked sample that converts to the future
    /// (#1073). Injectable so the gate is testable without touching the system clock; defaults to the
    /// real clock, so no ingest call site has to thread it.
    private let nowMsProvider: () -> Int64

    public init(ringGen: OuraRingGen, authKey: [UInt8]?, allowTierB: Bool = false,
                allowKeyInstall: Bool = false,
                nowMsProvider: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.ringGen = ringGen
        self.authKey = authKey
        self.allowTierB = allowTierB
        self.allowKeyInstall = allowKeyInstall
        self.nowMsProvider = nowMsProvider
    }

    // MARK: - Command flow

    /// Given the last transport transition, return the commands the app should write next. Pure: it
    /// only mutates the driver's own phase, never touches BLE. Per OURA_PROTOCOL.md s3 / s5.
    public func nextStep(after transition: OuraTransition) -> [OuraCommand] {
        switch transition {
        case .ready:
            // No app key -> we cannot authenticate; surface the honest pairing path (no faked data).
            guard effectiveKey != nil else {
                phase = .needsKeyInstall
                return []
            }
            phase = .authenticating
            // Enable notifications, then request the auth nonce. SyncTime can follow auth.
            return [OuraCommands.enableAllNotifications(),
                    OuraCommand(label: "get_nonce", bytes: OuraAuth.getAuthNonceCommand())]

        case .nonceReceived(let nonce):
            guard let key = effectiveKey else {
                phase = .needsKeyInstall
                return []
            }
            // Compute the proof and submit it. On any crypto error, fail honestly (no proof sent).
            guard let cmd = try? OuraAuth.authenticateCommand(nonce: nonce, key: key) else {
                phase = .authFailed(.authError)
                return []
            }
            return [OuraCommand(label: "submit_proof", bytes: cmd)]

        case .authCompleted(let status):
            switch status {
            case .success:
                phase = .enablingLiveHR
                liveHREnableStep = 0
                // Begin the live-HR enable triplet (gen-appropriate; gen3 verified, gen4/5 same path).
                return [OuraCommands.liveHREnableSequence()[0]]
            case .inFactoryReset:
                // Ring needs a key install first; this is an explicit, named provisioning step the app
                // drives, not the normal flow. Surface honestly.
                phase = .needsKeyInstall
                return []
            case .authError, .notOriginalDevice:
                phase = .authFailed(status)
                return []
            }

        case .enableAckReceived:
            guard phase == .enablingLiveHR else { return [] }
            liveHREnableStep += 1
            let seq = OuraCommands.liveHREnableSequence()
            if liveHREnableStep < seq.count {
                return [seq[liveHREnableStep]]
            }
            // All three ACKed: HR/IBI now streams as 0x2F sub-op 0x28 pushes.
            phase = .streaming
            return []

        case .startHistoryFetch(let cursor):
            phase = .fetchingHistory
            // Flush flash buffer first, then fetch up to 255 events from the cursor (s5.3).
            return [OuraCommands.flushBuffer(),
                    OuraCommands.getEvents(cursor: cursor, maxEvents: 255)]

        case .historyCursorAdvanced(let cursor, let moreData):
            guard moreData else {
                phase = .streaming
                return []
            }
            // Continuation fetch at the ADVANCED cursor (max seen ring-time + 1), same shape as the
            // initial request — open_oura `drain_events` re-issues `req_get_event(start, 255, -1)` every
            // batch. The old open_ring "ack-fetch" (max=0 at a non-advancing cursor) made the ring
            // RESTART serving from that cursor: the observed same-window re-serve loop (s5.3).
            return [OuraCommands.getEvents(cursor: cursor, maxEvents: 255)]
        }
    }

    /// Re-engage live HR (daytime-HR auto-reverts after ~20 s; the app calls this every ~15 s while a
    /// live session is open). Per OURA_PROTOCOL.md s5.7. Returns the enable+subscribe commands.
    public func reengageLiveHRCommands() -> [OuraCommand] {
        [OuraCommands.liveHREnable(), OuraCommands.liveHRSubscribe()]
    }

    // MARK: - Post-factory-reset key install (adopt flow, s3.2)

    /// Begin the one-time post-factory-reset key install (OURA_PROTOCOL.md s3.2). The transport in the
    /// adopt flow generates a fresh 16-byte key, persists it, and calls this to obtain the dangerous
    /// `24 10 <key>` write; once the ring replies `25 01 00` the transport calls keyInstallAcknowledged
    /// to drive re-auth.
    ///
    /// SAFETY GATE: this only sequences an install when phase == needsKeyInstall AND allowKeyInstall is
    /// true. When allowKeyInstall is false it stays at needsKeyInstall and returns no commands, so the
    /// dangerous 0x24 write is never emitted outside an explicit opt-in adopt flow. Returns nil (and
    /// leaves phase unchanged) when not gated on, the key length is wrong, or the command cannot build.
    public func beginKeyInstall(key: [UInt8]) -> OuraCommand? {
        guard allowKeyInstall, phase == .needsKeyInstall else { return nil }
        guard let cmd = try? OuraDangerousCommands.installKey(key) else { return nil }
        installedKey = key                 // re-auth after the ack must use the freshly-provisioned key
        phase = .installingKey
        return cmd
    }

    /// Handle the ring's 0x25 SetAuthKey ack (`25 01 00`, s3.2) by driving re-auth with the freshly
    /// installed key: transition installingKey -> authenticating and return the same enable+nonce
    /// commands the ready path uses. Returns [] (phase unchanged) when not in installingKey or when no
    /// installed key is present, so a stray ack cannot advance the flow.
    public func keyInstallAcknowledged() -> [OuraCommand] {
        guard phase == .installingKey, installedKey != nil else { return [] }
        phase = .authenticating
        return [OuraCommands.enableAllNotifications(),
                OuraCommand(label: "get_nonce", bytes: OuraAuth.getAuthNonceCommand())]
    }

    /// Stop: reset the flow so a fresh session re-runs auth (the app key is session-scoped, s3.1).
    public func stop() {
        phase = .stopped
        liveHREnableStep = 0
        lastRingTimestamp = 0
        installedKey = nil
        anchorUtcMs = nil
        anchorRingTime = nil
    }

    // MARK: - Ring-time -> UTC anchor (s5.5)

    /// Convert a record's ring-clock timestamp to unix seconds using the current session's anchor
    /// (OURA_PROTOCOL.md s5.5). Returns nil when no anchor has arrived yet this session, so the caller
    /// can honestly fall back (e.g. to wall-clock arrival time) instead of guessing.
    public func unixSeconds(forRingTimestamp rt: UInt32) -> Int? {
        guard let anchorUtcMs, let anchorRingTime else { return nil }
        let deltaTicks = Int64(rt) - Int64(anchorRingTime)
        let ms = anchorUtcMs + deltaTicks * 100   // default 100 ms/tick (s5.5); bounded input, no overflow
        // #968: a corrupt/misaligned ring timestamp (seen on a full cursor=0 history dump) can convert to
        // an implausible epoch; return nil so the caller falls back to arrival time instead of banking it.
        //
        // #1073: a banked SAMPLE is always in the past, so its upper bound is "now", NOT the 2020-2035
        // anchor window. That window is the right screen for ADOPTING a clock anchor and far too generous
        // for a sample — a corrupt ring timestamp that converts years ahead (measured on a live ring:
        // ~1,600 R-R beats stamped 2026→2034, and still accruing) passed it cleanly and got filed into a
        // future day, invisible to the night it belongs to. Gate a sample at `now + skew tolerance`
        // (minutes, absorbing ring-clock skew + anchor rounding) and keep the 2020 lower bound (the #968
        // 1970 guard). The 2020-2035 window stays in `plausibleAnchorMs`, for anchor adoption only.
        let seconds = ms / 1000
        let nowSeconds = nowMsProvider() / 1000
        guard seconds >= Self.minPlausibleEpochSeconds,
              seconds <= nowSeconds + Self.sampleFutureToleranceSeconds else { return nil }
        return Int(seconds)
    }

    /// Resolve the 0x13 SyncTime-response device timestamp into ring TICKS, or nil when no unambiguous
    /// reading exists. ringverse BLE.md labels the field "seconds" but the ring's record clock runs in
    /// 100 ms ticks, so both readings are tried: the raw value (already ticks) and value×10 (seconds→
    /// ticks). The ring's clock at connect must sit shortly AFTER where the last drain ended, so a
    /// candidate is plausible iff it falls in `[historyCursor, historyCursor + 7 days]`; exactly one
    /// must fit (ambiguity or a fresh/reset cursor → nil → the caller logs raw instead of guessing).
    /// Pure and testable; the honest-data invariant is "no anchor beats a wrong anchor".
    public static func syncTimeAnchorCandidate(responseValue: UInt32, historyCursor: UInt32) -> UInt32? {
        guard historyCursor > 0 else { return nil }
        let lower = Int64(historyCursor)
        let upper = lower + 6_048_000   // 7 days of 100 ms ticks
        let readings = [Int64(responseValue), Int64(responseValue) * 10]
        let fits = readings.filter { $0 >= lower && $0 <= upper && $0 <= Int64(UInt32.max) }
        guard fits.count == 1 else { return nil }
        return UInt32(fits[0])
    }

    /// Adopt a ring-time→UTC anchor from the 0x13 SyncTime response pair (`rt` = the ring's clock counter
    /// in ticks when it processed our SyncTime, `unixSeconds` = host wall-clock at receipt). Same
    /// plausibility gate as the 0x42/0x85 paths; returns whether the anchor was set. The freshest
    /// possible pair, so it overwrites any earlier anchor (an in-log 0x42 from the same clock domain
    /// yields the same mapping anyway).
    public func adoptSyncTimeAnchor(ringTimestamp rt: UInt32, unixSeconds: Int64) -> Bool {
        guard let ms = Self.plausibleAnchorMs(fromEpochSeconds: unixSeconds) else { return false }
        anchorUtcMs = ms
        anchorRingTime = rt
        return true
    }

    /// Bounds for a plausible anchor epoch (unix seconds): 2020-01-01 to 2035-01-01. A decoded 0x42/0x85
    /// value outside this range is a corrupt/misaligned record (seen on real hardware: a full cursor=0
    /// history dump hit one deep in the backlog) and is never trusted as an anchor (honest-data invariant).
    /// This gate ALSO bounds the input to the seconds->ms `* 1000` conversion so it can never overflow
    /// Int64 (a naive multiply on a near-Int64.max raw value traps).
    private static let minPlausibleEpochSeconds: Int64 = 1_577_836_800
    private static let maxPlausibleEpochSeconds: Int64 = 2_051_222_400

    /// Skew allowance on the sample-side "must not be in the future" gate (#1073): a sample converting up
    /// to this many seconds past `now` is still accepted, absorbing ring-clock skew and the anchor's own
    /// rounding. Minutes, not the anchor window's years — a sample banked further ahead than this is
    /// corrupt by construction. Applies ONLY to `unixSeconds(forRingTimestamp:)`, never anchor adoption.
    private static let sampleFutureToleranceSeconds: Int64 = 300

    private static func plausibleAnchorMs(fromEpochSeconds seconds: Int64) -> Int64? {
        guard seconds >= minPlausibleEpochSeconds, seconds <= maxPlausibleEpochSeconds else { return nil }
        return seconds * 1000   // safe: bounded input, cannot overflow
    }

    /// True when `seconds` falls inside the anchor plausibility window (2020-01-01 .. 2035-01-01), i.e. the
    /// `.timeSync` / `.rtcBeacon` ingest would accept it. A record whose epoch is outside this is silently
    /// ignored so a garbage value can't anchor history to ~1970. Exposed READ-ONLY so OuraLiveSource can log
    /// WHY an anchor was rejected (#91) without duplicating the bounds or reaching into anchor state. Pure.
    public static func isPlausibleAnchorEpoch(_ seconds: Int64) -> Bool {
        plausibleAnchorMs(fromEpochSeconds: seconds) != nil
    }

    // MARK: - Record ingest (decode)

    /// Decode one parsed TLV inner record into zero or more events. A malformed/short record (or an
    /// unknown tag) yields []. Tier-B tags yield [] unless allowTierB is set. Per OURA_PROTOCOL.md s6.
    public func ingest(record: OuraRecord) -> [OuraEvent] {
        lastRingTimestamp = record.ringTimestamp
        guard let tag = OuraEventTag(rawValue: record.type) else {
            // Unknown tag: decode to nothing, never a guessed value (honest-data invariant).
            return []
        }
        // Tier-B gate: when not explicitly allowed, drop the event so it cannot feed scoring.
        if tag.tier == .tierB && !allowTierB {
            return []
        }
        switch tag {
        // --- Tier A: HR / IBI ---
        case .ibiAmplitude:
            return (OuraDecoders.decodeIBIAmplitude(record) ?? []).map { OuraEvent.ibi($0) }
        case .greenIbiQuality:
            return (OuraDecoders.decodeGreenIBIQuality(record) ?? []).map { OuraEvent.ibi($0) }
        case .spo2IbiAmplitude:
            return (OuraDecoders.decodeSpO2IBI(record) ?? []).map { OuraEvent.ibi($0) }
        case .ibi:
            // The bare 0x44 IBI tag shares the bit-packed layout family; route through the same decoder,
            // but stamp its OWN channel — same layout is not the same tag, and a stored beat that cannot
            // name which of the two produced it cannot answer whether they duplicate each other (#1071
            // follow-up). Read identically to 0x60; this is a label, not a filter.
            return (OuraDecoders.decodeIBIAmplitude(record, channel: .ibiBare) ?? []).map { OuraEvent.ibi($0) }

        // --- Tier A: HRV ---
        case .hrvRmssd:
            return (OuraDecoders.decodeHRV(record) ?? []).map { OuraEvent.hrv($0) }

        // --- Tier A: SpO2 ---
        case .spo2PerSample:
            return (OuraDecoders.decodeSpO2PerSample(record) ?? []).map { OuraEvent.spo2($0) }
        case .spo2Stable:
            if let s = OuraDecoders.decodeSpO2Stable(record) { return [.spo2(s)] }
            return []
        case .spo2Dc:
            return (OuraDecoders.decodeSpO2DC(record) ?? []).map { OuraEvent.spo2($0) }

        // --- Tier A: Temperature ---
        case .temp:
            return (OuraDecoders.decodeTemp(record) ?? []).map { OuraEvent.temp($0) }
        case .tempPeriod:
            if let t = OuraDecoders.decodeTempPeriod(record) { return [.temp(t)] }
            return []
        case .sleepTemp:
            return (OuraDecoders.decodeSleepTemp(record) ?? []).map { OuraEvent.temp($0) }

        // --- Tier A: Motion ---
        case .motionPeriod:
            return (OuraDecoders.decodeMotionPeriod(record) ?? []).map { OuraEvent.motion($0) }
        case .motion:
            // 0x47 motion_events: the ring's averaged accel vector (orientation + avg x/y/z ×8 +
            // high_intensity), the same shape as a WHOOP 4.0 gravity sample. open_oura `decode_motion`,
            // OURA_PROTOCOL.md s6.13. Tier-A.
            return OuraDecoders.decodeMotionEvents(record).map { [OuraEvent.motionEvent($0)] } ?? []

        // --- Tier A: Sleep phase (2-bit codes are verified) ---
        // 0x4B/0x4E/0x5A are the three hypnogram aliases (open_oura decode_sleep_phases); 0x4B was
        // previously misfiled as a Tier-B sleep summary. Same validated layout, one decoder.
        case .sleepPhaseB, .sleepPhase, .sleepPhaseAlt:
            return (OuraDecoders.decodeSleepPhase(record) ?? []).map { OuraEvent.sleepPhase($0) }

        // --- Tier A: Lifecycle / state / time ---
        case .timeSync:
            // Primary UTC anchor (s5.5): always wins over a secondary RTC-beacon anchor already set.
            guard let ts = OuraDecoders.decodeTimeSync(record) else { return [] }
            // UNIT CORRECTION (s6.11): the 0x42 wire value is unix SECONDS, not ms. OURA_PROTOCOL.md s6.11
            // cited it as ms from an unverified write-up; treating it as ms anchored history-fetched samples
            // to ~1970. The decoder stays a faithful byte-level parse of the documented layout (OuraTimeSync.
            // epochMs still names what the doc claims); the seconds->ms conversion lives here.
            // CRASH-SAFETY (s6.11): a full cursor=0 history dump can hit a 0x42 record with an implausible
            // raw value (a misaligned/corrupt record deep in the backlog); a naive `* 1000` overflows Int64
            // and traps. plausibleAnchorMs bounds-checks BEFORE multiplying, so an implausible value is
            // safely ignored (honest: never anchors to a garbage time) instead of crashing.
            if let ms = Self.plausibleAnchorMs(fromEpochSeconds: ts.epochMs) {
                anchorUtcMs = ms
                anchorRingTime = ts.ringTimestamp
            }
            return [.timeSync(ts)]
        case .rtcBeacon:
            // Secondary UTC anchor (s5.5, 1s granularity): only fills in while no 0x42 anchor exists yet
            // this session, so a coarser beacon never overrides the primary time-sync anchor.
            guard let r = OuraDecoders.decodeRtcBeacon(record) else { return [] }
            if anchorUtcMs == nil, let ms = Self.plausibleAnchorMs(fromEpochSeconds: Int64(r.unixSeconds)) {
                anchorUtcMs = ms
                anchorRingTime = r.ringTimestamp
            }
            return [.rtcBeacon(r)]
        case .stateChange, .wearEvent:
            if let s = OuraDecoders.decodeState(record) { return [.state(s)] }
            return []
        case .debugText:
            if let t = OuraDecoders.decodeDebugText(record) {
                return [.debugText(ringTimestamp: record.ringTimestamp, text: t)]
            }
            return []
        case .ringStart:
            // 0x41 ring_start_ind: a lifecycle marker (the app uses it to invalidate the UTC anchor on
            // rt regression). It carries no biometric value, so emit nothing here. Per OURA_PROTOCOL.md
            // s5.5 / s6.15. The app observes ring-start via the record stream directly.
            return []

        // --- Tier B (only reached when allowTierB == true; otherwise dropped above) ---
        case .greenIbiAmp:
            // #287: 0x71 green_ibi_and_amp. Demoted from Tier A: the 0x60 decoder it used reads 6 ABSOLUTE
            // IBIs, but §6.2 documents 0x71 as 5 IBI DELTAS + 6 amplitudes with a [2:0] shift, so that
            // decode fabricated a phantom R-R and corrupted HRV. With no captured 0x71 fixture we cannot
            // write a verified decoder yet, so emit the raw bytes for inspection (never folded into scoring)
            // rather than a guessed IBI. Gated above unless allowTierB. Promote once a real 0x71 sample lands.
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "green_ibi_amp"))]
        case .sleepSummary1, .sleepSummaryC, .sleepSummaryD, .sleepSummaryE, .sleepSummaryF:
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "sleep_summary"))]
        case .activityInfo:
            // Split out of the raw-bytes .tierB wrapper: this ONE activity tag has a plausible decode
            // formula (Decoders.decodeActivityInfo, third-party [oura-rs], PR #960 investigation). Still
            // Tier B - only reached behind allowTierB (gated above), and OuraStreamMapping never folds
            // .activityInfo into a durable stream. 0x51/0x52 summaries stay raw below.
            guard let info = OuraDecoders.decodeActivityInfo(record) else { return [] }
            return [.activityInfo(info)]
        case .activitySummary1, .activitySummary2:
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "activity"))]
        case .realSteps1, .realSteps2:
            // Split out of the raw-bytes .tierB wrapper, same as .activityInfo: this tag pair now has a
            // cited third-party unpack formula (Decoders.decodeRealStepsFields, [oura-rs]). Still Tier B
            // - only reached behind allowTierB (gated above), and OuraStreamMapping never folds
            // .realStepsFields into a durable stream. Applies the SAME 14-field unpack to both 0x7E and
            // 0x7F bodies (the formula is generic over any 14-byte body; NOOP's own investigation found
            // the movement-correlated fields present in both).
            guard let fields = OuraDecoders.decodeRealStepsFields(record) else { return [] }
            return [.realStepsFields(fields)]
        case .sleepPeriodInfo:
            // Split out of the raw-bytes .tierB wrapper, same as .activityInfo: this tag has a cited
            // third-party layout ([open_ring]) whose field NAMES are what our own §6.12 was missing, and
            // whose declared invariants our captures uphold. Still Tier B - only reached behind
            // allowTierB (gated above). ONE field of it is durable: OuraStreamMapping maps `breathsPerMin`
            // to a respSample row under the ring's OWN deviceId, shown on the respiration track. It is NOT
            // scored: `dailyMetric.respRateBpm` is untouched (it stays the RSA estimate), and
            // `OuraRespScale.forScoring` refuses the ring's rows at EVERY scoring read — staging included,
            // because that path reads the stream as a ~1 Hz raw ADC waveform and a per-window rate is the
            // wrong shape for a peak detector. `averageHrBpm` and every other field
            // stay diagnostic-only - in particular the HR must not join the beat-derived series at a
            // different cadence.
            guard let info = OuraDecoders.decodeSleepPeriodInfo(record) else { return [] }
            return [.sleepPeriodInfo(info)]
        case .spo2Smoothed:
            return [.tierB(OuraTierBSummary(tag: record.type, ringTimestamp: record.ringTimestamp,
                                            rawPayload: record.payload, kind: "spo2_smoothed"))]
        }
    }

    /// Convenience: ingest a whole notification value by reassembling records and decoding each. The
    /// caller passes a fresh notification value; the supplied reassembler buffers partial trailing
    /// bytes across calls. Per OURA_PROTOCOL.md s2.4.
    public func ingest(notification value: [UInt8], reassembler: OuraReassembler) -> [OuraEvent] {
        var out: [OuraEvent] = []
        for rec in reassembler.feed(value) {
            out.append(contentsOf: ingest(record: rec))
        }
        return out
    }

    /// Decode a live-HR push (0x2F sub-op 0x28). The body is the bytes AFTER `2f 0f 28`; the push is
    /// not a TLV record, so it is stamped with the last seen ring time. Per OURA_PROTOCOL.md s5.6.
    public func ingestLiveHRPush(body: [UInt8]) -> [OuraEvent] {
        guard let hr = OuraDecoders.decodeLiveHRPush(body, ringTimestamp: lastRingTimestamp) else {
            return []
        }
        // The push also carries the IBI; surface both so HRV analytics see the R-R.
        return [.hr(hr), .ibi(OuraIBI(ringTimestamp: lastRingTimestamp, ibiMs: hr.ibiMs))]
    }

    /// Route a parsed secure sub-frame: extract the auth nonce / status, or a live-HR push body, so
    /// the app does not need to know the 0x2F sub-op map. Returns the matching transition or push
    /// events. Per OURA_PROTOCOL.md s4.2 / s5.6.
    public func handleSecureFrame(_ frame: OuraSecureFrame) -> SecureRouting {
        if let nonce = OuraAuth.nonce(from: frame) {
            return .nonce(nonce)
        }
        if let status = OuraAuth.authStatus(from: frame) {
            return .authStatus(status)
        }
        // Sub-op 0x28 carries the live-HR push samples (s5.6). subBody is everything after the subop.
        if frame.subop == 0x28 {
            return .liveHRPush(frame.subBody)
        }
        // Live-HR enable ACKs advance the triplet (s5.6): 0x21 is the dhr_read feature-read ACK from
        // step 1 (`2f 06 21 02 01 11 02 00`), 0x23 acks the enable write (step 2), 0x27 acks the
        // subscribe write (step 3). All three must be recognised or the sequencer stalls at step 0.
        if frame.subop == 0x21 {
            // A 0x21 is a feature-status read reply. The daytime-HR read (feature 0x02) is step 1 of the
            // live-HR triplet and MUST advance it; a diagnostic read (SpO2 0x04 / real_steps 0x0b) instead
            // surfaces the ring's own feature report so a capture can confirm the server-flag gate.
            if let st = OuraDecoders.decodeFeatureStatus(frame.subBody),
               st.feature != Int(OuraCommands.featureDaytimeHR) {
                return .featureStatus(st)
            }
            return .enableAck
        }
        if frame.subop == 0x23 || frame.subop == 0x27 {
            return .enableAck
        }
        return .unhandled
    }

    /// What handleSecureFrame resolved a 0x2F sub-frame to.
    public enum SecureRouting: Equatable {
        case nonce([UInt8])
        case authStatus(OuraAuthStatus)
        case liveHRPush([UInt8])
        case enableAck
        case featureStatus(OuraFeatureStatus)
        case unhandled
    }
}
