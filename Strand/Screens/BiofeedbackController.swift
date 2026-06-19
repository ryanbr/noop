import Foundation
import Combine
import SwiftUI
import StrandAnalytics

// BiofeedbackController.swift — the live session controller for the three haptic-biofeedback layers
// (v5 "the strap that breathes you down"). It is the ONLY thing in the UI lane that walks the pure
// StrandAnalytics engines over time and fires the proven strap buzz path. The views (BreathingView's
// resonance + "Calm me" + stress-check-in surfaces) own *presentation*; this owns the *clock + the BLE
// send*, exactly the seam the spec asks for ("a DispatchQueue tick driving each BreathCue / the
// HapticClock asyncAfter pattern").
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (Architecture & files → Wiring).
//
// Buzz path (reused verbatim, hardware-confirmed): `AppModel.buzz(loops:)` → `send(.runHapticsPattern,
// payload: [2, loops, 0, 0, 0])` — the SAME call the Haptic Clock (`buzzTimeNow`) and the inactivity
// nudge use. We only schedule WHEN to fire it; the buzz itself is the shipped one.
//
// All work is @MainActor (it touches AppModel + drives @Published UI state). Everything is opt-in,
// user-stoppable, quiet-hours-aware (the engines own quiet-hours), and bounded by the engines' safety
// envelopes (HRDownPacer's floor/ramp, ResonanceEngine's honest "no lock" fallback).
@MainActor
final class BiofeedbackController: ObservableObject {

    // MARK: - Live session kind

    /// Which biofeedback flow is currently running (or none). Drives the views' "session live" chrome.
    enum SessionKind: Equatable {
        case none
        /// L1 resonance sweep — pacing one candidate of the "find my pace" flow.
        case resonanceSweep(bpm: Double, paceIndex: Int, paceCount: Int)
        /// L1 paced breathing at the locked (or chosen) resonance pace.
        case resonanceSession(bpm: Double)
        /// L2 "Calm me" below-HR metronome.
        case calmMe
    }

    // MARK: - Published session state (the views read these)

    /// The flow running right now (`.none` when idle). A manual L1/L2 session sets this; the L3 detector
    /// must never fire over a non-`.none` session (the spec's "never nudge over a manual session" rule).
    @Published private(set) var session: SessionKind = .none
    /// True while any biofeedback session is live — the single "is something running" flag.
    @Published private(set) var running = false
    /// The current paced breath phase, for the orb/phase word when the screen is on.
    @Published private(set) var phase: BreathPhase = .inhale
    /// Seconds elapsed in the current session (drives the timer chrome + the L2 ramp/timeout copy).
    @Published private(set) var elapsedSeconds: Int = 0

    // MARK: - L1 sweep progress

    /// Human label for the pace under test, e.g. "Testing 5.5 br/min…" — nil when not sweeping.
    @Published private(set) var sweepLabel: String? = nil
    /// 0…1 progress through the whole sweep (paces completed / total) — for a calm progress bar.
    @Published private(set) var sweepProgress: Double = 0
    /// The finished sweep result (locked pace + per-pace RSA curve), set when a sweep completes. nil until
    /// then; the result card reads this.
    @Published private(set) var lastSweep: ResonanceEngine.SweepResult? = nil

    // MARK: - L2 live readout

    /// Smoothed HR the metronome started from (`H₀`), for the "78 → settling" line. nil outside L2.
    @Published private(set) var calmStartHR: Int? = nil
    /// The latest target tempo the metronome settled on (bpm), for the live readout.
    @Published private(set) var calmTargetBpm: Double? = nil
    /// The honest L2 outcome line once the session ends ("HR settled 78 → 69 over 2:30" or the
    /// "held steady" path). nil while running / before any L2 ran.
    @Published private(set) var calmOutcome: String? = nil
    /// True when the just-finished L2 session did NOT settle the heart — the view offers L1 instead, no
    /// fabricated win.
    @Published private(set) var calmDidNotFall = false

    // MARK: - Dependencies

    private unowned let model: AppModel
    private let live: LiveState

    init(model: AppModel, live: LiveState) {
        self.model = model
        self.live = live
    }

    // MARK: - Shared session bookkeeping

    /// Pending scheduled buzz work-items so a stop() cancels every queued pulse (no buzz after the user
    /// taps stop). We schedule with `asyncAfter` carrying a `DispatchWorkItem`, exactly like the Haptic
    /// Clock walk but cancellable.
    private var pending: [DispatchWorkItem] = []
    private var secondTimer: AnyCancellable?
    /// A repeating driver for L2 (it recomputes the interval each pulse rather than a fixed cue list).
    private var calmTick: DispatchWorkItem?
    /// The sweep's live R-R subscription (L1) — held so stop() tears it down cleanly.
    private var sweepRRSub: AnyCancellable?

    /// Can we actually buzz the strap? L2/L3 are haptic-FIRST, so they are disabled (not faked) when the
    /// encrypted channel isn't up. L1 still runs visual-only (the orb + phase word carry it).
    var canBuzz: Bool { live.bonded && live.encryptedBond }

    private func fireBuzz(loops: Int) {
        guard canBuzz else { return }
        model.buzz(loops: UInt8(clamping: loops))
    }

    /// Schedule one cancellable buzz at `offsetMs` from now (the asyncAfter walk, cancellable on stop).
    private func scheduleBuzz(loops: Int, afterMs: Int) {
        let item = DispatchWorkItem { [weak self] in self?.fireBuzz(loops: loops) }
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(afterMs), execute: item)
    }

    private func startSecondTimer() {
        elapsedSeconds = 0
        secondTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.elapsedSeconds += 1 }
    }

    private func clearSchedule() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
        calmTick?.cancel()
        calmTick = nil
        secondTimer?.cancel()
        secondTimer = nil
        sweepRRSub?.cancel()
        sweepRRSub = nil
    }

    /// Stop whatever is running, cancel every queued pulse, restore auto-lock. Idempotent.
    func stop() {
        clearSchedule()
        ScreenIdle.keepAwake(false)
        running = false
        session = .none
        sweepLabel = nil
        phase = .inhale
    }

    // MARK: - L1: paced resonance breathing session

    /// Start a screen-off paced breathing session at `bpm` (the locked resonance pace, or a preset's bpm).
    /// Builds the deterministic `BreathPacer` cue list and walks it, firing the proven buzz per cue. The
    /// orb/phase word (driven off `phase`) follow the same schedule when the screen is on; screen-off, the
    /// felt buzz is the whole cue. Keep-awake is held for the hands-free session.
    func startResonanceSession(bpm: Double, cycles: Int) {
        stop()
        session = .resonanceSession(bpm: bpm)
        running = true
        ScreenIdle.keepAwake(true)
        startSecondTimer()
        walkCues(BreathPacer.schedule(bpm: bpm, cycles: cycles)) { [weak self] in
            self?.stop()
        }
    }

    /// Walk a `[BreathCue]` list: drive `phase` and fire the per-cue buzz at each offset, then call
    /// `onComplete` after the last cue's cycle finishes. Pure cue list in, scheduled side-effects out —
    /// the spec's "the existing asyncAfter walk drives it".
    private func walkCues(_ cues: [BreathCue], onComplete: @escaping () -> Void) {
        guard !cues.isEmpty else { onComplete(); return }
        for cue in cues {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.phase = cue.phase
                self.fireBuzz(loops: cue.loops)
            }
            pending.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(cue.offsetMs), execute: item)
        }
        // Schedule completion one cycle past the last cue's offset (the exhale fills the rest of the cycle).
        let lastOffset = cues.map(\.offsetMs).max() ?? 0
        let endItem = DispatchWorkItem { onComplete() }
        pending.append(endItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(lastOffset + 4_000), execute: endItem)
    }

    // MARK: - L1: the "find my pace" sweep

    /// Run the resonance sweep: pace each candidate for `secondsPerPace`, collecting clean R-R per pace,
    /// then score the whole thing with `ResonanceEngine.sweep` and publish the locked pace + RSA curve.
    /// `quick` picks the 3-pace ~7-min sweep; otherwise the full 6-pace ~13-min sweep.
    ///
    /// R-R is pulled off `LiveState.rr` (the reliable standard-profile feed) into a per-pace bucket while
    /// that pace is being paced; the engine cleans + scores. Honest by construction: a thin pace is left
    /// unscored, and < minScoredPaces → the engine returns the 5.5 fallback with `didLock == false`.
    func startSweep(quick: Bool, secondsPerPace: Int = 120) {
        stop()
        let paces = quick ? ResonanceEngine.quickSweepPaces : ResonanceEngine.fullSweepPaces
        running = true
        ScreenIdle.keepAwake(true)
        startSecondTimer()
        sweepProgress = 0
        lastSweep = nil

        var samples: [ResonanceEngine.PaceSample] = []

        func runPace(_ index: Int) {
            guard index < paces.count, running else {
                sweepRRSub?.cancel()
                sweepRRSub = nil
                finishSweep(samples)
                return
            }
            let bpm = paces[index]
            session = .resonanceSweep(bpm: bpm, paceIndex: index, paceCount: paces.count)
            sweepLabel = String(format: "Testing %.1f br/min…", bpm)

            // Collect this pace's R-R from the live feed for the pace's duration.
            let startTs = Int(Date().timeIntervalSince1970)
            var bucket: [ResonanceEngine.RrBeat] = []
            sweepRRSub?.cancel()
            sweepRRSub = live.$rr.sink { rr in
                let now = Int(Date().timeIntervalSince1970)
                for ms in rr where ms > 300 && ms < 2000 {  // plausible R-R (30–200 bpm)
                    bucket.append(ResonanceEngine.RrBeat(ts: now, rrMs: ms))
                }
            }

            // Pace it via the cue list for this pace's window.
            let cycles = max(1, Int((Double(secondsPerPace) * bpm / 60.0).rounded()))
            walkCues(BreathPacer.schedule(bpm: bpm, cycles: cycles)) { [weak self] in
                guard let self else { return }
                let endTs = Int(Date().timeIntervalSince1970)
                samples.append(ResonanceEngine.PaceSample(bpm: bpm, rr: bucket,
                                                          startTs: startTs, endTs: endTs))
                self.sweepProgress = Double(index + 1) / Double(paces.count)
                runPace(index + 1)
            }
        }

        func finishSweep(_ samples: [ResonanceEngine.PaceSample]) {
            let result = ResonanceEngine.sweep(samples)
            lastSweep = result
            // Persist the locked pace + date as plain prefs (no store table) so the Breathe screen + the
            // resonance pill can read it across relaunch. Honest: only persist a real lock; a fallback
            // leaves the user on the preset paces.
            if result.didLock {
                BiofeedbackPrefs.saveLockedPace(result.lockedBpm, date: Date())
            }
            stop()
        }

        runPace(0)
    }

    // MARK: - L2: "Calm me" below-HR metronome

    /// Start the L2 below-HR relaxation metronome from the current smoothed HR. Fires one light pulse per
    /// target beat at a tempo `HRDownPacer` keeps a bounded Δ below live HR, recomputing every step from
    /// the fresh smoothed HR so the cue TRAILS the heart down (never yanks it). Bounded by the pacer's
    /// floor + max-Δ + timeout; user-stoppable. Honest outcome on stop (settled vs held steady).
    func startCalmMe(config: HRDownPacer.Config = .default) {
        stop()
        guard canBuzz, let h0 = model.bpm, h0 >= 55, h0 <= 120 else {
            // Haptic-first: needs a bonded strap + a resting-band HR. Don't fake it.
            calmOutcome = "Couldn't start — needs a connected strap and a resting heart rate."
            calmDidNotFall = false
            return
        }
        session = .calmMe
        running = true
        calmStartHR = h0
        calmOutcome = nil
        calmDidNotFall = false
        ScreenIdle.keepAwake(true)
        startSecondTimer()
        scheduleCalmStep(config: config)
    }

    /// One L2 step: ask `HRDownPacer.next` for the interval (or a stop), fire a light pulse, and schedule
    /// the next step at that interval. Recomputes from the latest smoothed HR each time.
    private func scheduleCalmStep(config: HRDownPacer.Config) {
        guard running, case .calmMe = session else { return }
        let hr = Double(model.bpm ?? 0)
        let step = HRDownPacer.next(currentHR: hr, elapsed: Double(elapsedSeconds), config: config)

        if step.stop {
            finishCalm(reason: step.stopReason, config: config)
            return
        }
        calmTargetBpm = step.targetBpm
        fireBuzz(loops: 1)   // one light pulse per target beat — a felt metronome, not a shock

        let interval = step.intervalMs ?? 1_000
        let next = DispatchWorkItem { [weak self] in self?.scheduleCalmStep(config: config) }
        calmTick = next
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(interval), execute: next)
    }

    /// Bank the honest L2 outcome and stop. "Settled" → the heart reached the calm target; "timeout" →
    /// compare start vs current and say plainly whether it fell or held steady (no fabricated success).
    private func finishCalm(reason: HRDownPacer.StopReason?, config: HRDownPacer.Config) {
        let start = calmStartHR
        let end = model.bpm
        let dur = elapsedSeconds
        let mmss = String(format: "%d:%02d", dur / 60, dur % 60)

        switch reason {
        case .settled:
            if let s = start, let e = end {
                calmOutcome = "HR settled \(s) → \(e) over \(mmss)."
            } else {
                calmOutcome = "HR settled over \(mmss)."
            }
            calmDidNotFall = false
        case .timeout, .invalidHR, .none:
            if let s = start, let e = end, e < s {
                calmOutcome = "HR eased \(s) → \(e) over \(mmss)."
                calmDidNotFall = false
            } else if let s = start, let e = end {
                calmOutcome = "HR held steady (\(s) → \(e)) — try a paced breath instead."
                calmDidNotFall = true
            } else {
                calmOutcome = "Session ended — try a paced breath instead."
                calmDidNotFall = true
            }
        }
        stop()
    }
}
