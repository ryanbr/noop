import Foundation
import StrandAnalytics

// BiofeedbackPrefs.swift — the small, on-device pref surface for the haptic-biofeedback pillar:
// the locked resonance pace + its date (L1), and the "stress check-ins (haptic)" master/sub toggles
// + the replay-safe StressOnsetDetector state (L3). UserDefaults-backed, single-user, no store table —
// the same lightweight pattern Breathe's `@AppStorage("breathe.lastOutcome")` and `InactivityPrefs` use.
//
// Nothing here leaves the device (the spec's "resonance pace + outcomes are local prefs"). The toggles
// default OFF / safe (manual-first ethos). A Settings toggle group (Wave 3) writes the same keys; this
// type is the single reader/writer so the engine config stays consistent.
enum BiofeedbackPrefs {

    private static let d = UserDefaults.standard

    private enum K {
        static let lockedPace   = "biofeedback.resonanceBpm"
        static let lockedDate   = "biofeedback.resonanceLockedAt"
        // L3 stress check-in (haptic) toggles.
        static let checkInOn    = "biofeedback.stressCheckIn"          // master
        static let autoNudge    = "biofeedback.stressAutoNudge"        // sub
        static let quietHours   = "biofeedback.stressQuietHours"       // sub
        static let useResonance = "biofeedback.stressUseResonancePace" // sub
        static let quietStart   = "biofeedback.stressQuietStartMin"
        static let quietEnd     = "biofeedback.stressQuietEndMin"
        // Replay-safe detector state (carried verbatim between evaluations).
        static let stBaseline   = "biofeedback.stOnsetBaseline"
        static let stWasBelow   = "biofeedback.stOnsetWasBelow"
        static let stLastFire   = "biofeedback.stOnsetLastFire"
    }

    // MARK: - L1 locked resonance pace

    /// The user's locked resonance pace (br/min), or nil if they've never locked one.
    static var lockedPace: Double? {
        let v = d.double(forKey: K.lockedPace)
        return v > 0 ? v : nil
    }

    /// When the locked pace was measured — shown dated on the result card ("locked 19 Jun"); the pace
    /// drifts, so we never claim it's permanent.
    static var lockedPaceDate: Date? {
        let t = d.double(forKey: K.lockedDate)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func saveLockedPace(_ bpm: Double, date: Date) {
        d.set(bpm, forKey: K.lockedPace)
        d.set(date.timeIntervalSince1970, forKey: K.lockedDate)
    }

    static func clearLockedPace() {
        d.removeObject(forKey: K.lockedPace)
        d.removeObject(forKey: K.lockedDate)
    }

    // MARK: - L3 toggles → engine Config

    static var checkInEnabled: Bool {
        get { d.object(forKey: K.checkInOn) as? Bool ?? false }
        set { d.set(newValue, forKey: K.checkInOn) }
    }
    static var autoNudge: Bool {
        get { d.object(forKey: K.autoNudge) as? Bool ?? false }
        set { d.set(newValue, forKey: K.autoNudge) }
    }
    static var quietHoursEnabled: Bool {
        get { d.object(forKey: K.quietHours) as? Bool ?? true }
        set { d.set(newValue, forKey: K.quietHours) }
    }
    static var useResonancePace: Bool {
        get { d.object(forKey: K.useResonance) as? Bool ?? true }
        set { d.set(newValue, forKey: K.useResonance) }
    }
    static var quietStartMinutes: Int {
        get { d.object(forKey: K.quietStart) as? Int ?? 22 * 60 }
        set { d.set(newValue, forKey: K.quietStart) }
    }
    static var quietEndMinutes: Int {
        get { d.object(forKey: K.quietEnd) as? Int ?? 7 * 60 }
        set { d.set(newValue, forKey: K.quietEnd) }
    }

    /// Build the engine config from the persisted toggles, so the central L3 hook (Wave 3, in BLEManager's
    /// existing evaluateStress call-site) reads one consistent config.
    static func stressConfig() -> StressOnsetDetector.Config {
        StressOnsetDetector.Config(
            enabled: checkInEnabled,
            autoNudge: autoNudge,
            quietHoursEnabled: quietHoursEnabled,
            quietStartMinutes: quietStartMinutes,
            quietEndMinutes: quietEndMinutes,
            buzzLoops: 1)
    }

    // MARK: - L3 replay-safe state

    static func loadStressState() -> StressOnsetDetector.State {
        StressOnsetDetector.State(
            baselineRMSSD: d.double(forKey: K.stBaseline),
            wasBelow: d.bool(forKey: K.stWasBelow),
            lastFireAt: d.integer(forKey: K.stLastFire))
    }

    static func saveStressState(_ s: StressOnsetDetector.State) {
        d.set(s.baselineRMSSD, forKey: K.stBaseline)
        d.set(s.wasBelow, forKey: K.stWasBelow)
        d.set(s.lastFireAt, forKey: K.stLastFire)
    }
}
