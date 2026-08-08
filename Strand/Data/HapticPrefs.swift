import Foundation

/// Per-event toggles for NOOP's IN-SESSION strap-haptic cues (#1115) — the byte-parity twin of the Android
/// `HapticPrefs` (same key strings, same default-on).
///
/// These cues are feedback to something the user explicitly started (Breathing pacer, Interval timer, Live
/// Session coach cues, workout start/end, biofeedback/resonance), so they DEFAULT ON (opt-out): a fresh
/// install buzzes as the features always did, and a user turns off any individual cue. (The AMBIENT cues —
/// inactivity / stress / calls — keep their own opt-in keys.) Nonisolated (plain `UserDefaults`) so any
/// actor can read a gate at a buzz site.
enum HapticPrefs {
    // `breathing` also covers the resonance / biofeedback session cues (parity with Android's Breathe path).
    // Double-tap is deliberately NOT here: it's already opt-in via the DoubleTapAction picker.
    static let breathing = "haptics.breathing"
    static let intervals = "haptics.intervals"
    static let liveSession = "haptics.liveSession"
    static let workout = "haptics.workout"

    /// Whether an in-session cue may fire. DEFAULT-ON: an UNSET key must read `true`. `UserDefaults.bool`
    /// returns `false` for a missing key, so read the object and default to `true` — matching the
    /// `@AppStorage(...) = true` bindings the settings UI uses (both resolve an unset key to on).
    static func enabled(_ key: String, _ d: UserDefaults = .standard) -> Bool {
        (d.object(forKey: key) as? Bool) ?? true
    }

    static func setEnabled(_ key: String, _ value: Bool, _ d: UserDefaults = .standard) {
        d.set(value, forKey: key)
    }
}
