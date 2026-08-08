import XCTest
@testable import Strand

/// #haptics (#1115): pins the DEFAULT-ON behaviour of the in-session haptic toggles. `HapticPrefs` is
/// nonisolated + UserDefaults-injectable, so this needs no CoreBluetooth / @MainActor seam. Twin intent of
/// the Android `HapticPrefs` (`getBoolean(key, true)` — unset reads on).
final class HapticPrefsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "haptics-test-\(UUID().uuidString)")!
    }

    /// An UNSET key reads ON — a fresh install buzzes as the features always did (no migration needed).
    func testUnsetKeysDefaultOn() {
        let d = freshDefaults()
        for key in [HapticPrefs.breathing, HapticPrefs.intervals, HapticPrefs.liveSession, HapticPrefs.workout] {
            XCTAssertTrue(HapticPrefs.enabled(key, d), "\(key) must default on")
        }
    }

    /// Turning a cue OFF sticks and doesn't leak to the others.
    func testOptingOutSticks() {
        let d = freshDefaults()
        HapticPrefs.setEnabled(HapticPrefs.breathing, false, d)
        XCTAssertFalse(HapticPrefs.enabled(HapticPrefs.breathing, d))
        XCTAssertTrue(HapticPrefs.enabled(HapticPrefs.intervals, d), "opting out of one cue must not affect another")
    }

    /// Re-enabling after opting out reads on again.
    func testReEnableAfterOptOut() {
        let d = freshDefaults()
        HapticPrefs.setEnabled(HapticPrefs.workout, false, d)
        HapticPrefs.setEnabled(HapticPrefs.workout, true, d)
        XCTAssertTrue(HapticPrefs.enabled(HapticPrefs.workout, d))
    }
}
