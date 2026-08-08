import XCTest
@testable import Strand

/// #haptics (#1115): pins the preserve-existing migration for the in-session haptic toggles. `HapticPrefs`
/// is nonisolated + UserDefaults-injectable, so this needs no CoreBluetooth / @MainActor seam. Twin intent
/// of the Android `HapticPrefs.migrateIfNeeded` (same `noop.onboarded` signal, same default-off).
final class HapticPrefsMigrationTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "haptics-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    /// A FRESH install (not yet onboarded at first launch) stays OFF — the whole point of "default off".
    func testFreshInstallStaysOff() {
        let d = freshDefaults()
        HapticPrefs.migrateIfNeeded(d)
        for key in HapticPrefs.inSessionKeys {
            XCTAssertFalse(d.bool(forKey: key), "fresh install must leave \(key) off")
        }
    }

    /// An EXISTING install (already onboarded) fired these cues unconditionally, so the migration turns
    /// them ON — no silent regression on update.
    func testExistingInstallMigratesOn() {
        let d = freshDefaults()
        d.set(true, forKey: "noop.onboarded")
        HapticPrefs.migrateIfNeeded(d)
        for key in HapticPrefs.inSessionKeys {
            XCTAssertTrue(d.bool(forKey: key), "onboarded install must migrate \(key) on")
        }
    }

    /// The migration is ONE-TIME: after it runs, a user turning a cue OFF must not be flipped back ON by a
    /// later migration pass (the lazy safety-net call in `enabled` must be idempotent).
    func testMigrationIsOneTimeAndRespectsUserChoice() {
        let d = freshDefaults()
        d.set(true, forKey: "noop.onboarded")
        HapticPrefs.migrateIfNeeded(d)
        HapticPrefs.setEnabled(HapticPrefs.breathing, false, d)
        HapticPrefs.migrateIfNeeded(d)               // second pass (e.g. via enabled())
        XCTAssertFalse(HapticPrefs.enabled(HapticPrefs.breathing, d),
                       "a re-run migration must not override a user's off choice")
    }
}
