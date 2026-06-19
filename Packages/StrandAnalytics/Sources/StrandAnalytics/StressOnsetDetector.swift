import Foundation

// StressOnsetDetector.swift — the L3 closed-loop JITAI ("just-in-time adaptive intervention") detector.
// Generalises the math currently inline in `AppModel.evaluateStress()` into an EDGE-triggered,
// motion-gated, REPLAY-SAFE detector that decides — at the moment it matters — whether to offer a 60-s
// guided breathing cue. PURE + DB-free, carrying its OWN de-dup state exactly like
// `SedentaryDetector.evaluate`: the caller persists `nextState` and feeds it back, so a replayed window
// can't re-fire. No I/O / BLE here.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3).
//
// WHAT IT GENERALISES (from AppModel.evaluateStress): a rolling clean-R-R buffer → a SLOW RMSSD baseline
// (the shipped 0.98/0.02 EMA) + a resting-HR band gate (55–100 bpm) + a `rmssd < baseline × 0.6` drop +
// a once-per-15-min limiter + a single confirming buzz. What this engine ADDS, per spec:
//   1. A FAST short-window RMSSD (the latest beats) vs the slow baseline — "fast dropped below baseline".
//   2. EDGE trigger: fire ONCE on the fresh crossing (was-above → now-below), not every tick.
//   3. The EXERCISE GATE (the credibility line): suppress when HR is out of the resting band AND/OR recent
//      motion says "metabolic, not stress" (gravity activity above a threshold, the same `recentGravity`
//      source `SedentaryDetector` reads). A brisk walk's HRV dip must NOT fire a "you're stressed" cue.
//   4. Rate-limit + quiet hours + master toggle, and never while a manual Breathe/L1/L2 session runs.
//
// HONEST / NON-CLINICAL: "stress" is an autonomic PROXY (HRV-down vs the user's OWN baseline), never a
// diagnosis. The card the caller shows says "HRV dipped while you were still" — never "you are stressed".
// On fire: a single confirming buzz + a passive in-app card; NEVER a push notification unless the user
// opted into notifications (matches DaytimeStress's "passive suggestion, never a notification" stance).
//
// All `ts`/`nowSec` are wall-clock unix SECONDS. Outputs are APPROXIMATE, not medical advice.

public enum StressOnsetDetector {

    // MARK: - Tunables (evaluateStress parity + the new fast/gate pieces)

    /// Slow-baseline EMA weight on the prior value (the shipped 0.98). New RMSSD gets `1 − this`.
    public static let baselineEmaAlpha: Double = 0.98
    /// Fast RMSSD must drop below `baseline × this` to count as a dip (the shipped 0.6 threshold).
    public static let dropRatio: Double = 0.6
    /// Resting HR band — outside it the dip is treated as metabolic (workout), not stress (the shipped
    /// 55–100 bpm gate).
    public static let restingHRLow: Double = 55.0
    public static let restingHRHigh: Double = 100.0
    /// Beats in the FAST short window (the latest clean beats) used for the momentary RMSSD.
    public static let fastWindowBeats: Int = 60
    /// Minimum clean beats before either RMSSD is trusted (mirrors `HRVAnalyzer.minBeats`).
    public static let minBeats: Int = HRVAnalyzer.minBeats
    /// Rate limit — at most one fire per this many seconds (the shipped 900 s = 15 min).
    public static let minSecondsBetweenFires: Int = 900
    /// Recent smoothed wrist-motion (g) at/above this means "moving" → exercise gate suppresses the fire
    /// (reuses the `SedentaryDetector` move threshold so the two gates agree on what "moving" is).
    public static let motionGateG: Double = SedentaryDetector.defaultMoveThresholdG

    // MARK: - Config

    /// The L3 master/sub toggles + quiet-hours window, passed in as plain values so the engine stays pure.
    /// All default OFF / safe — manual-first ethos (the feature is opt-in per layer).
    public struct Config: Equatable, Sendable {
        /// Master "stress check-ins (haptic)" toggle (default OFF). Inert when off.
        public var enabled: Bool
        /// Auto-nudge sub-toggle (default OFF) — when off the detector still reports state but never fires.
        public var autoNudge: Bool
        /// Suppress fires during quiet hours.
        public var quietHoursEnabled: Bool
        /// Quiet-hours window, local minute-of-day [0,1440) (defaults 22:00 → 07:00).
        public var quietStartMinutes: Int
        public var quietEndMinutes: Int
        /// Buzz strength (loops) for the confirming buzz — one light pulse, like evaluateStress.
        public var buzzLoops: Int

        public init(enabled: Bool = false,
                    autoNudge: Bool = false,
                    quietHoursEnabled: Bool = false,
                    quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                    quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                    buzzLoops: Int = 1) {
            self.enabled = enabled
            self.autoNudge = autoNudge
            self.quietHoursEnabled = quietHoursEnabled
            self.quietStartMinutes = quietStartMinutes
            self.quietEndMinutes = quietEndMinutes
            self.buzzLoops = buzzLoops
        }
    }

    // MARK: - State (de-dup / EMA carry — persisted verbatim, replay-safe)

    /// The persisted state the detector carries between evaluations (restart-safe). The caller stores this
    /// verbatim and feeds the prior value back in, exactly like `SedentaryState`. A fresh user starts from
    /// `.initial`. Carries the slow EMA baseline (so it survives relaunch), the edge state (was the fast
    /// RMSSD below the threshold on the previous tick?), and the rate-limit clock.
    public struct State: Equatable, Sendable {
        /// Slow RMSSD baseline (EMA), ms. 0 = uninitialised (seeds from the first trusted fast RMSSD).
        public var baselineRMSSD: Double
        /// Whether the fast RMSSD was BELOW the drop threshold on the previous evaluation — drives the
        /// EDGE (we fire only on a fresh above→below crossing, not every tick it stays below).
        public var wasBelow: Bool
        /// Unix-seconds of the last fire (0 = never) — the rate limiter.
        public var lastFireAt: Int

        public init(baselineRMSSD: Double = 0, wasBelow: Bool = false, lastFireAt: Int = 0) {
            self.baselineRMSSD = baselineRMSSD
            self.wasBelow = wasBelow
            self.lastFireAt = lastFireAt
        }

        /// Cold-start state (no baseline, not below, never fired).
        public static let initial = State()
    }

    // MARK: - Decision

    /// Why the detector did / didn't nudge — drives logs and the honest card copy.
    public enum Reason: String, Equatable, Sendable {
        /// A fresh non-metabolic HRV dip — offer a minute to breathe.
        case onset
        /// Disabled / auto-nudge off.
        case disabled
        /// Too few clean beats to judge honestly.
        case insufficientData
        /// Fast RMSSD is at/above the threshold — no dip.
        case noDip
        /// The dip isn't a fresh edge (already below last tick).
        case notAnEdge
        /// Suppressed by the exercise gate (HR out of band and/or recent motion = metabolic, not stress).
        case exerciseGated
        /// Inside the rate-limit window or quiet hours, or a manual session is running.
        case suppressed
    }

    /// The decision returned each evaluation: whether to nudge, why, and the next state to persist. Mirrors
    /// `SedentaryDecision`: the caller acts on `shouldNudge` and stores `nextState` (always advanced) so a
    /// replayed window can't re-fire.
    public struct Decision: Equatable, Sendable {
        /// True if the app should offer the breathing cue now (single confirming buzz + passive card).
        public let shouldNudge: Bool
        /// Why (whether or not it nudged).
        public let reason: Reason
        /// Buzz loops to play when `shouldNudge` (the confirming buzz).
        public let buzzLoops: Int
        /// The fast short-window RMSSD this tick (ms), or nil when insufficient — for logs / the card.
        public let fastRMSSD: Double?
        /// The slow baseline RMSSD this tick (ms), or nil when uninitialised.
        public let baselineRMSSD: Double?
        /// The state to persist for the next evaluation (always carries the advanced EMA / edge / clock).
        public let nextState: State

        public init(shouldNudge: Bool, reason: Reason, buzzLoops: Int,
                    fastRMSSD: Double?, baselineRMSSD: Double?, nextState: State) {
            self.shouldNudge = shouldNudge; self.reason = reason; self.buzzLoops = buzzLoops
            self.fastRMSSD = fastRMSSD; self.baselineRMSSD = baselineRMSSD; self.nextState = nextState
        }
    }

    // MARK: - The detector

    /// Evaluate the live window and decide whether to fire a JITAI nudge.
    ///
    /// - `rrBuffer`: the rolling clean-able R-R buffer (rrMs, newest LAST). The fast RMSSD is taken over
    ///   the latest `fastWindowBeats` clean beats; the slow baseline EMA absorbs each trusted fast value.
    /// - `currentHR`: latest smoothed live HR (bpm), or nil if unknown (then the HR half of the gate can't
    ///   pass and we treat HR as out-of-band — conservative).
    /// - `recentMotionG`: recent smoothed wrist-motion (g) from `collector.recentGravity`, or nil if no
    ///   recent gravity (then the motion half of the gate is inconclusive — see below).
    /// - `sessionActive`: true if a manual Breathe/L1/L2 session is already running (never nudge over it).
    /// - `state`: the prior persisted state; `nowSec` / `tzOffsetSec` passed IN (never read a clock).
    ///
    /// The EXERCISE GATE suppresses when EITHER signal says metabolic: HR outside [55,100], OR recent
    /// motion at/above `motionGateG`. A missing HR is treated as out-of-band (can't confirm resting);
    /// missing motion alone does NOT gate (HR-band can carry it — gravity is offloaded and lags, spec Q3),
    /// so the resting-HR band is the real-time gate and motion is a secondary confirm when present.
    public static func evaluate(rrBuffer: [Int],
                                currentHR: Double?,
                                recentMotionG: Double?,
                                sessionActive: Bool,
                                state: State,
                                config: Config,
                                nowSec: Int,
                                tzOffsetSec: Int) -> Decision {

        // 1) Master gates: off / auto-nudge off → never nudge, state untouched.
        if !config.enabled || !config.autoNudge {
            return Decision(shouldNudge: false, reason: .disabled, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 2) Fast RMSSD over the latest clean beats. Clean first (range + Malik), then take the tail.
        let cleanAll = HRVAnalyzer.cleanRR(rrBuffer.map { Double($0) })
        let fastWindow = cleanAll.count > fastWindowBeats
            ? Array(cleanAll.suffix(fastWindowBeats))
            : cleanAll
        guard fastWindow.count >= minBeats, let fast = HRVAnalyzer.rmssdRaw(fastWindow), fast > 0 else {
            // Not enough signal — report, don't guess. Edge state is preserved (no crossing observed).
            return Decision(shouldNudge: false, reason: .insufficientData, buzzLoops: config.buzzLoops,
                            fastRMSSD: nil, baselineRMSSD: state.baselineRMSSD > 0 ? state.baselineRMSSD : nil,
                            nextState: state)
        }

        // 3) Advance the slow baseline EMA (seed on first trusted value), exactly like evaluateStress.
        var next = state
        next.baselineRMSSD = state.baselineRMSSD == 0
            ? fast
            : state.baselineRMSSD * baselineEmaAlpha + fast * (1.0 - baselineEmaAlpha)
        let baseline = next.baselineRMSSD

        // 4) Is the fast RMSSD below the drop threshold? (the dip test)
        let threshold = baseline * dropRatio
        let isBelow = fast < threshold
        // The edge: a FRESH crossing (above on the previous tick → below now). Always record the new
        // below-state so the NEXT tick can edge-detect, regardless of whether we fire.
        let isEdge = isBelow && !state.wasBelow
        next.wasBelow = isBelow

        func decide(_ nudge: Bool, _ reason: Reason) -> Decision {
            Decision(shouldNudge: nudge, reason: reason, buzzLoops: config.buzzLoops,
                     fastRMSSD: fast, baselineRMSSD: baseline, nextState: next)
        }

        if !isBelow { return decide(false, .noDip) }
        if !isEdge { return decide(false, .notAnEdge) }

        // 5) Exercise gate (the credibility line). HR out of the resting band (or unknown) → metabolic.
        //    Recent motion at/above the gate → metabolic. Either suppresses.
        let hrInBand: Bool = {
            guard let hr = currentHR else { return false }   // unknown HR can't confirm resting → gate
            return hr >= restingHRLow && hr <= restingHRHigh
        }()
        let moving: Bool = {
            guard let m = recentMotionG else { return false } // no recent gravity → motion inconclusive
            return m >= motionGateG
        }()
        if !hrInBand || moving { return decide(false, .exerciseGated) }

        // 6) Suppressors: a manual session is running, the rate limit, or quiet hours.
        if sessionActive { return decide(false, .suppressed) }
        if state.lastFireAt != 0 && (nowSec - state.lastFireAt) < minSecondsBetweenFires {
            return decide(false, .suppressed)
        }
        if config.quietHoursEnabled {
            let mod = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
            if SedentaryDetector.windowContains(mod, startMin: config.quietStartMinutes,
                                                endMin: config.quietEndMinutes) {
                return decide(false, .suppressed)
            }
        }

        // 7) Fire — a fresh, non-metabolic HRV dip while still. Stamp the rate-limit clock.
        next.lastFireAt = nowSec
        return decide(true, .onset)
    }
}
