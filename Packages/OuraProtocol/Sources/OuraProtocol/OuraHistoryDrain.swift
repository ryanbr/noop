import Foundation

/// Pure, testable decision core for the Oura history drain + durable resume cursor (#91 / #291).
///
/// Extracted from `OuraLiveSource` so the drain guards and cursor logic — which silently regressed once
/// already when the Oura BLE stack was refactored (#291: "lost when refactoring") — are pinned by unit
/// tests instead of only on-device observation. This owns ONLY the per-drain counters and the decisions;
/// the caller (`OuraLiveSource`) keeps all I/O — anchor resolution, persistence, logging, and the actual
/// `historyCursorAdvanced` emit.
///
/// The `0x11` history summary carries no cursor — only `bytes_left` (a remaining-byte count) and a
/// `moreData` flag. A healthy drain runs until `bytes_left == 0`; the resume cursor commits from the
/// newest STORED sample's ring-time at drain end. Byte counts are never persisted.
public struct OuraHistoryDrain: Sendable, Equatable {
    /// A ring-time above this is corrupt (~1.6 years of ticks) and must not set the resume cursor, or the
    /// next session would seek into nonsense. Bounds the cursor at the source.
    public static let maxPlausibleResumeTicks: UInt32 = 500_000_000
    /// `bytes_left` not shrinking for this many straight summaries = the ring is looping; stop.
    public static let maxStallSummaries = 3
    /// A healthy full pull finishes in ~1-2 min; past this something upstream is wrong — stop, keep the
    /// banked progress, and let the periodic re-fetch try again later.
    public static let maxDrainSeconds: TimeInterval = 300
    /// The ring's clock tick rate (OURA_PROTOCOL.md s5.5: 100 ms/tick by default). Used only by
    /// `anchorsAreContinuous` below, never by ring-time -> UTC conversion (that stays in `OuraDriver`).
    public static let ringTicksPerSecond: Double = 10
    /// Ordinary jitter tolerance for `anchorsAreContinuous` (#2097): how far the ring's clock may appear
    /// to fall behind wall-clock across a gap before it counts as a real power-cycle pause rather than
    /// anchor-receipt latency noise (BLE round-trip variance on the two receipt timestamps). A genuine
    /// power-cycle pause is measured in minutes (13m41s observed on one dead-battery reboot) — nowhere
    /// close to this margin, so it stays generous without risking a false "continuous" read.
    public static let anchorContinuityMaxPauseSeconds: Double = 20
    /// Minimum wall-clock gap `anchorsAreContinuous` will judge; below this the check declines rather
    /// than guessing. 10 s, not the original 30: the test above is an ABSOLUTE margin
    /// (`anchorContinuityMaxPauseSeconds`, 20 s), not a rate, so a few seconds of receipt-latency noise
    /// inside a 10 s gap still leaves most of that margin — and a genuine power-cycle pause is minutes,
    /// which cannot hide inside a short gap either (it shows up as the wall gap itself). The 30 s floor
    /// declined on a real 27 s reconnect (2026-09-12, 268 ticks / 27 s = 9.93/s, ring clock plainly
    /// continuous) and the old full re-pull fired — a fast relaunch-and-reconnect is the cheapest way
    /// to produce a stale replay, so it is the case the floor must not exclude (#2097).
    public static let anchorContinuityMinGapSeconds: Double = 10

    private var minBytesLeftSeen: UInt32 = .max
    private var stallCount = 0
    /// Newest STORED ring-time seen this drain — the value the resume cursor commits to at drain end.
    public private(set) var maxStoredRingTime: UInt32 = 0
    /// Newest ring-time SEEN this drain across ALL history records (anchored or not) — the in-session
    /// continuation cursor's source. Kept separate from [maxStoredRingTime]: the continuation cursor may
    /// advance on unanchored records (they were served, so the ring must not re-serve them this session),
    /// while the DURABLE cursor still only commits from anchored, stored samples.
    public private(set) var maxSeenRingTime: UInt32 = 0
    /// History records seen since the last GetEvents request — open_oura's `batch_events` progress test.
    public private(set) var eventsSinceLastRequest: UInt32 = 0
    /// A real stored sample older than where we sought this fetch: the ring's clock reset (or it ignored
    /// the seek), so the persisted cursor is stale → full pull next connect.
    public private(set) var sawPreResumeData = false

    public init() {}

    /// Reset the per-drain state at the start of a fetch. Mirrors `OuraLiveSource`'s fetch-start reset.
    public mutating func reset() {
        minBytesLeftSeen = .max
        stallCount = 0
        maxStoredRingTime = 0
        maxSeenRingTime = 0
        eventsSinceLastRequest = 0
        sawPreResumeData = false
    }

    /// Fold in one history summary; returns whether the drain should CONTINUE.
    ///
    /// `moreData == false` (`bytes_left == 0`) always completes. Otherwise two backstops force-stop a
    /// misbehaving ring while keeping banked progress: the STALL guard (`bytes_left` must shrink across
    /// summaries — [maxStallSummaries] flat reads means it's looping) and the DEADLINE guard
    /// (`elapsedSeconds` past [maxDrainSeconds]). `elapsedSeconds` is the caller's wall clock since the
    /// drain started, or `0` when no drain-start is set (matching the old `let started = …` guard).
    public mutating func onSummary(bytesLeft: UInt32, moreData: Bool, elapsedSeconds: TimeInterval) -> Bool {
        guard moreData else { return false }
        if bytesLeft < minBytesLeftSeen {
            minBytesLeftSeen = bytesLeft
            stallCount = 0
        } else {
            stallCount += 1
            if stallCount >= Self.maxStallSummaries { return false }
        }
        if elapsedSeconds > Self.maxDrainSeconds { return false }
        return true
    }

    /// Record a STORED history sample's ring-time toward the resume cursor. Call ONLY where a sample
    /// resolved a REAL anchored time (never a wall-clock fallback). Ignores corrupt (over-ceiling) times,
    /// and flags a reboot when a real sample predates `resumeCursorAtFetchStart` (0 = full pull, no floor).
    public mutating func noteStoredRingTime(_ rt: UInt32, resumeCursorAtFetchStart: UInt32) {
        guard rt <= Self.maxPlausibleResumeTicks else { return }
        if rt > maxStoredRingTime { maxStoredRingTime = rt }
        if resumeCursorAtFetchStart > 0, rt < resumeCursorAtFetchStart { sawPreResumeData = true }
    }

    /// Record ANY history record's ring-time toward the in-session continuation cursor (anchored or not),
    /// and count it toward the batch-progress test. Ignores corrupt (over-ceiling) times. Call once per
    /// decoded history record that carries an envelope ring-time.
    public mutating func noteSeenRingTime(_ rt: UInt32) {
        guard rt <= Self.maxPlausibleResumeTicks else { return }
        if rt > maxSeenRingTime { maxSeenRingTime = rt }
        eventsSinceLastRequest &+= 1
    }

    /// The cursor for the NEXT in-session GetEvents request, or nil to stop (open_oura `drain_events`:
    /// `progressed = batch_events > 0 && next > start; if !progressed break`). Re-sending a non-advancing
    /// cursor makes the ring RESTART serving from it — the observed 5x same-window re-serve loop — so a
    /// flat batch ends the drain instead of retrying. On advance, the batch counter re-arms for the next
    /// request's progress test.
    public mutating func continuationCursor(lastRequestCursor: UInt32) -> UInt32? {
        guard eventsSinceLastRequest > 0 else { return nil }
        let next = maxSeenRingTime &+ 1
        guard next > lastRequestCursor else { return nil }
        eventsSinceLastRequest = 0
        return next
    }

    /// The cursor to persist at drain end, given the current cursor and whether `maxStoredRingTime`
    /// resolves under the CURRENT anchor. A reboot (`sawPreResumeData`) resets to 0 (honest full pull next
    /// connect) UNLESS `anchorConfirmsContinuity` says the ring's own clock never paused (#2097) — in
    /// that case the stale replay came from something other than a power-cycle (observed: a second BLE
    /// client serving the ring in between), so it is treated like ordinary stale data: discarded, cursor
    /// left to the same forward-only-if-resolving rule as any other drain. Otherwise the cursor advances
    /// to `maxStoredRingTime` only if it moved forward AND resolves; unchanged in every other case.
    public func resumeCursorAtDrainEnd(currentCursor: UInt32, resolvesUnderAnchor: Bool,
                                        anchorConfirmsContinuity: Bool = false) -> UInt32 {
        if sawPreResumeData, !anchorConfirmsContinuity { return 0 }
        if maxStoredRingTime > currentCursor, resolvesUnderAnchor { return maxStoredRingTime }
        return currentCursor
    }

    /// Whether two `0x13 SyncTime` anchors observed across a connect-to-connect gap are consistent with
    /// the ring's clock having ticked continuously the whole time — i.e. NOT a genuine power-cycle (#2097).
    ///
    /// `OuraHistoryDrain.sawPreResumeData` alone cannot tell a real ring reboot from a second BLE client
    /// (e.g. the Oura app) having served the ring in between and left NOOP's resume cursor looking stale:
    /// both produce the identical "a stored sample is older than where we sought" signature. But a real
    /// power-cycle does not reset the ring's free-running tick counter toward zero — it PAUSES it while
    /// the ring is off (measured: a dead-battery reboot lost 13m41s of ticks against wall-clock, bracketed
    /// by two sub-second no-charge controls) — so comparing elapsed ring-ticks against elapsed wall-clock
    /// across the gap distinguishes the two: continuous ticking means nothing paused the ring's clock.
    ///
    /// Declines to judge (returns `false`, the safe default that keeps today's "treat as reboot"
    /// behavior) when the gap is too short to measure meaningfully, or when `current` somehow precedes
    /// `previous` in ring-ticks (never observed; not a continuity claim either way).
    public static func anchorsAreContinuous(previous: (ringTicks: UInt32, unixSeconds: Int64),
                                             current: (ringTicks: UInt32, unixSeconds: Int64)) -> Bool {
        let wallDelta = Double(current.unixSeconds - previous.unixSeconds)
        guard wallDelta >= anchorContinuityMinGapSeconds, current.ringTicks >= previous.ringTicks else {
            return false
        }
        let ringSeconds = Double(current.ringTicks - previous.ringTicks) / ringTicksPerSecond
        let fellBehindBy = wallDelta - ringSeconds
        return fellBehindBy <= anchorContinuityMaxPauseSeconds
    }

    /// Sanitize a cursor loaded from persistence: a value above the plausibility ceiling is pre-fix
    /// garbage and must reset to a full pull.
    public static func sanitizeLoadedCursor(_ persisted: UInt32) -> UInt32 {
        persisted <= maxPlausibleResumeTicks ? persisted : 0
    }
}
