import Foundation

/// Per-event toggles for NOOP's IN-SESSION strap-haptic cues (#1115 offshoot) — the byte-parity twin of
/// the Android `HapticPrefs` (same key strings, same default-off, same preserve-existing migration), so a
/// `.noopbak` restore reads identically on either OS.
///
/// Every key is DEFAULT-OFF (opt-in). A one-time migration turns them ON for an EXISTING install (already
/// onboarded) so an update doesn't silence a feature mid-use, and leaves a fresh install OFF. Ambient cues
/// (inactivity / smart-alarm / stress / zone coaching) keep their OWN existing keys and are not duplicated
/// here. Nonisolated (plain `UserDefaults`) so any actor can read a gate at a buzz site.
enum HapticPrefs {
    // In-session cue keys (Group B). `breathing` also covers the resonance / biofeedback session cues
    // (parity with Android, where those run through the Breathe path). Double-tap is deliberately NOT here:
    // it's already opt-in via the DoubleTapAction picker (a second default-off gate would kill a configured
    // action).
    static let breathing = "haptics.breathing"
    static let intervals = "haptics.intervals"
    static let liveSession = "haptics.liveSession"
    static let workout = "haptics.workout"

    /// All in-session keys, in display order — drives both the migration and the settings section.
    static let inSessionKeys = [breathing, intervals, liveSession, workout]

    private static let migratedV1Key = "haptics.migratedV1"
    private static let onboardedKey = "noop.onboarded"

    /// Whether an in-session cue may fire. Runs the one-time migration as a safety net; the authoritative
    /// run is at app launch (see `migrateIfNeeded`).
    static func enabled(_ key: String, _ d: UserDefaults = .standard) -> Bool {
        migrateIfNeeded(d)
        return d.bool(forKey: key)
    }

    static func setEnabled(_ key: String, _ value: Bool, _ d: UserDefaults = .standard) {
        d.set(value, forKey: key)
    }

    /// One-time preserve-existing migration — twin of Android `HapticPrefs.migrateIfNeeded`. MUST run at
    /// app launch, BEFORE this session's onboarding: `noop.onboarded` is the "has run a prior version"
    /// proxy, and reading it at launch is what keeps a fresh install (not yet onboarded on its first
    /// launch) OFF — a read after the user onboards would wrongly see onboarded=true and migrate a
    /// brand-new user ON. Idempotent.
    static func migrateIfNeeded(_ d: UserDefaults = .standard) {
        if d.bool(forKey: migratedV1Key) { return }
        let establishedInstall = d.bool(forKey: onboardedKey)
        if establishedInstall { for k in inSessionKeys { d.set(true, forKey: k) } }
        d.set(true, forKey: migratedV1Key)
    }
}
