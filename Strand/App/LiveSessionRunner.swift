import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - LiveSessionRunner
//
// The transport half of Live Sessions (silent guardian): the pure `LiveSessionEngine` decides WHAT
// should happen; this object is the only place that touches a clock, the live HR stream, the strap
// buzz and the store. One 1 Hz timer feeds the engine `LiveState.heartRate` (or nil, so the engine
// can detect a quiet stream itself — no liveness guessing here), publishes each `Output` for the
// session screen, walks a cue's pulse list out through the EXISTING hardware buzz, and books the
// session into the `liveSession` table (once at start with endTs nil, once at end with the totals).
//
// Design contract: docs/superpowers/specs/2026-07-04-live-sessions-design.md. Session-scoped: the
// view owns one runner per presentation (@StateObject), so `start` runs once and a finished runner
// is never restarted.
//
// Honesty rules carried over from the engine:
//   • Nothing here invents a number — the published `Output` is the engine's, verbatim.
//   • A cue that can't be delivered cleanly is DROPPED, never queued: a late buzz is a wrong buzz.
//   • Ten minutes of continuous stale ends the session on its own — guarding a dead stream is a lie.

/// UserDefaults keys for the Live Sessions beta gate (the Settings toggle + the Today entry point).
enum LiveSessionPrefs {
    /// Master switch for the whole entry. Default ON — the feature is BETA-labelled in-UI instead of
    /// hidden; turning it off removes the Start-session control from the Liquid Today entirely.
    static let betaKey = "noop.liveSessionsBeta"
}

@MainActor
final class LiveSessionRunner: ObservableObject {

    /// Continuous stale time (seconds) after which the session ends itself — the strap is gone, and a
    /// "guarding" screen over no data would be a false promise.
    static let autoEndStaleSec = 600
    /// Where the guarded HR came from. v1 only coaches the strap's live feed (see `LiveSessionRow.hrSource`).
    static let hrSource = "whoop"

    // MARK: Published state (the session screen reads ONLY these — it never observes LiveState)

    /// The engine's latest verdict, verbatim — ring state, band, in-band time, smoothed bpm.
    @Published private(set) var output: LiveSessionEngine.Output?
    /// Cues actually delivered to the wrist this session (a skipped cue was never sent, so it isn't counted).
    @Published private(set) var pushCount = 0
    @Published private(set) var easeCount = 0
    /// Set exactly once, when the session ends (End tap or the stale auto-end) — the view presents the
    /// summary sheet off this.
    @Published private(set) var finalRow: LiveSessionRow?

    /// Session start (unix seconds) — the row's natural key.
    private(set) var startTs = 0
    /// Today's Charge as banked at start (nil = unknown; the engine used its conservative default curve).
    private(set) var chargeAtStart: Double?
    /// The recovery-gated band as computed at start (pre-drift) — drives the Charge sentence before the
    /// first tick lands an `Output`.
    private(set) var baseBand: LiveSessionEngine.Band?

    // MARK: Session wiring (held only while running)

    private var engine: LiveSessionEngine?
    private var timer: Timer?
    /// Sample-arrival tick (background survival) — see the comment where it's armed in `start`.
    private var hrSink: AnyCancellable?
    private var model: AppModel?
    private var repo: Repository?
    private var ble: BLEManager?

    /// Out-of-band accrual, mirroring exactly how the engine accrues `inBandSeconds`: per-tick dt
    /// clamped to `maxAccrualDtSec` so one long stall can't inflate a bucket, nothing accrues while stale.
    private var belowSec: Double = 0
    private var aboveSec: Double = 0
    private var lastTickTs = 0
    /// When the engine first reported .stale in the current quiet stretch (nil while readings flow).
    private var staleSinceTs: Int?
    /// The wall-clock moment the in-flight pulse walk finishes. A cue arriving before then is skipped
    /// outright (drop-tolerant): the pulses are already scheduled fire-and-forget, so overlapping walks
    /// would land on the wrist as one unreadable mush.
    private var hapticWalkUntil = Date.distantPast

    deinit { timer?.invalidate() }

    // MARK: - Start

    /// Begin guarding. Builds the engine config from today's banked numbers (resting HR falls back to
    /// the most recent night that recorded one; Charge may honestly be nil), arms the realtime HR
    /// stream (ref-counted in AppModel, balanced by `end()`), banks the in-progress row, and starts
    /// the 1 Hz tick. No-op if already running or already ended.
    func start(model: AppModel, repo: Repository, ble: BLEManager, profile: ProfileStore) {
        guard timer == nil, finalRow == nil else { return }
        self.model = model
        self.repo = repo
        self.ble = ble

        // Resting HR: today's own, else the most recent banked night's. The engine needs *a* baseline
        // to place the band, so a never-slept-yet install gets a deliberately ordinary 60 — the band it
        // yields is conservative, and the first banked night replaces it for every later session.
        let resting = repo.today?.restingHr
            ?? repo.days.last(where: { $0.restingHr != nil })?.restingHr
            ?? 60
        chargeAtStart = repo.today?.recovery
        let config = LiveSessionEngine.Config(restingHR: Double(resting),
                                              hrMax: Double(profile.hrMax),
                                              charge: chargeAtStart)
        let band = LiveSessionEngine.band(config: config)
        baseBand = band

        let now = Int(Date().timeIntervalSince1970)
        startTs = now
        lastTickTs = now
        engine = LiveSessionEngine(config: config, startTs: now)

        // Arm the live feed for the session (a WHOOP 5/MG only streams HR while armed, #681).
        model.startRealtimeHR()

        // Bank the in-progress row immediately (endTs nil) — a mid-session crash still leaves a record.
        persist(row(endTs: nil, band: band))

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // Pocket-the-phone survival: a suspended app stops firing Timers, but CoreBluetooth keeps
        // delivering HR notifies in the background (the same path that feeds the Live Activity), and each
        // one updates `live.heartRate`. Ticking on sample arrival too means coaching keeps pace with the
        // stream when only BLE callbacks are waking us; in the foreground the extra tick is a harmless
        // same-second engine update. Staleness still needs the Timer (no samples = no sink fires), which
        // resumes the moment the app does — the engine then reads the gap honestly as stale.
        hrSink = model.live.$heartRate.sink { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - End

    /// Stop guarding: kill the timer, release the realtime HR arm, bank the final totals, publish the
    /// row for the summary sheet. Safe against the End-tap / auto-end race — the second call is a no-op
    /// returning the already-final row.
    @discardableResult
    func end() -> LiveSessionRow? {
        guard timer != nil else { return finalRow }
        timer?.invalidate()
        timer = nil
        hrSink?.cancel()
        hrSink = nil
        model?.stopRealtimeHR()

        // Prefer the engine's live band (it may have drifted its ceiling on a strong day) over the base.
        let final = row(endTs: Int(Date().timeIntervalSince1970), band: output?.band ?? baseBand
                        ?? LiveSessionEngine.Band(floorBpm: 0, ceilingBpm: 0, floorPctHRR: 0, ceilingPctHRR: 0))
        persist(final)
        finalRow = final

        engine = nil
        model = nil
        ble = nil
        repo = nil
        return final
    }

    // MARK: - Tick (1 Hz)

    private func tick() {
        guard timer != nil else { return }
        let now = Int(Date().timeIntervalSince1970)
        // The engine takes the live reading if one is current, or nil as a plain time tick — staleness
        // is ITS call (never-fabricate: no reading is forwarded as exactly that, not held or guessed).
        guard let out = engine?.update(now: now, bpm: model?.live.heartRate) else { return }

        // Mirror the engine's clamped accrual for the two out-of-band buckets (it only accrues in-band
        // itself). Same rules: dt clamped to maxAccrualDtSec, nothing accrues on a stale tick.
        let dt = Double(min(max(now - lastTickTs, 0), LiveSessionEngine.maxAccrualDtSec))
        if out.status != .stale {
            switch out.position {
            case .below:  belowSec += dt
            case .above:  aboveSec += dt
            case .inBand: break   // the engine's own inBandSeconds carries this bucket
            }
        }
        lastTickTs = now

        // Stale watchdog: ten continuous minutes without a reading ends the session honestly.
        if out.status == .stale {
            if staleSinceTs == nil { staleSinceTs = now }
            if let since = staleSinceTs, now - since >= Self.autoEndStaleSec {
                output = out
                end()
                return
            }
        } else {
            staleSinceTs = nil
        }

        if let cue = out.cue { fire(cue) }
        output = out
    }

    // MARK: - Cue → wrist

    /// Walk a cue's pulse list out through the strap, exactly the way the Haptic Clock does: each pulse
    /// becomes the hardware-confirmed notification buzz (send() remaps to the 5/MG maverick body),
    /// weighted by `isLong` (long = the heavier 2-loop buzz, short = 1). Drop-tolerant: if a walk is
    /// still in flight, this cue is SKIPPED — never queued, never retried — because a delayed correction
    /// corrects nothing. (In practice the engine's 50 s cooldown makes an overlap near-impossible; this
    /// guard covers the push-after-ease edge.) Only a delivered cue is counted.
    private func fire(_ cue: LiveSessionEngine.Cue) {
        let nowDate = Date()
        guard nowDate >= hapticWalkUntil, let ble else { return }

        let signal: LiveSessionHaptics.Signal = (cue == .pushNudge) ? .push : .easeOff
        let pulses = LiveSessionHaptics.pulses(for: signal)
        guard !pulses.isEmpty else { return }

        var offsetMs = 0
        // #haptics (#1115): Live Session coach cues are opt-in (default-off, migrated-on for existing
        // installs). Gate ONLY the wrist output — the cue still counts toward the session's push/ease stats
        // and saved row (below), so turning the buzzes off doesn't erase the coaching record. Matches
        // Android, where the gate lives in the buzz closure, downstream of the count.
        if HapticPrefs.enabled(HapticPrefs.liveSession) {
            for pulse in pulses {
                let loops = pulse.isLong ? 2 : 1
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak ble] in
                    ble?.send(.runHapticsPattern, payload: [2, UInt8(clamping: loops), 0, 0, 0])
                }
                offsetMs += pulse.durationMs + pulse.gapMs
            }
        }
        hapticWalkUntil = nowDate.addingTimeInterval(Double(offsetMs) / 1000)

        switch cue {
        case .pushNudge: pushCount += 1
        case .easeOff:   easeCount += 1
        }
    }

    // MARK: - Persistence

    private func row(endTs: Int?, band: LiveSessionEngine.Band) -> LiveSessionRow {
        LiveSessionRow(startTs: startTs, endTs: endTs, chargeAtStart: chargeAtStart,
                       floorBpm: band.floorBpm, ceilingBpm: band.ceilingBpm,
                       inBandSec: output?.inBandSeconds ?? 0, belowSec: belowSec, aboveSec: aboveSec,
                       pushCount: pushCount, easeCount: easeCount, hrSource: Self.hrSource)
    }

    /// Idempotent upsert on (deviceId, startTs) — the start write and the end write land on one row.
    private func persist(_ row: LiveSessionRow) {
        guard let repo else { return }
        let deviceId = repo.deviceId
        Task {
            guard let store = await repo.storeHandle() else { return }
            _ = try? await store.upsertLiveSession(row, deviceId: deviceId)
        }
    }
}
