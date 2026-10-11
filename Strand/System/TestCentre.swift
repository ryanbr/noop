import Foundation
import StrandAnalytics

/// The Test Centre orchestration surface: per-domain activation, a SINGLE consolidated prefs namespace,
/// preserving legacy experimental settings in their original namespaces (spec section 10).
/// `active(_:)` is the zero-cost gate engines check before
/// emitting a tagged line, so an emitter on the GATT/analytics queue pays one Bool read when a mode is
/// off. The Kotlin twin is TestCentre.kt, backed by a single "noop_testcentre" SharedPreferences file.
public enum TestCentre {

    // Single namespace for new Test Centre flags; legacy keys keep their original names.
    private static let activePrefix = "testcentre.active."          // + domain.id  -> Bool
    private static let startedPrefix = "testcentre.startedAt."      // + domain.id  -> Double (unix)
    private static let guidedTargetPrefix = "testcentre.target."    // + domain.id  -> Int (nights/days)
    private static let answersPrefix = "testcentre.answers."        // + domain.id  -> [String:String] (Data)

    private static let master = TestDomain.master

    /// The zero-cost gate. `if TestCentre.active(.sleep) { live.append(log:domain:) }`. `nonisolated`
    /// plus a single Bool read so an emitter on any actor pays almost nothing when the mode is off.
    public nonisolated static func active(_ d: TestDomain) -> Bool {
        if d == .universal { return anyActive }      // universal rides whatever mode is on
        if UserDefaults.standard.bool(forKey: activePrefix + master.id) { return true }  // master = all on
        return UserDefaults.standard.bool(forKey: activePrefix + d.id)
    }

    /// True when ANY non-universal mode is on (drives the "testing on" banner plus the universal traces).
    public nonisolated static var anyActive: Bool {
        TestDomain.allCases.contains {
            $0 != .universal && UserDefaults.standard.bool(forKey: activePrefix + $0.id)
        }
    }

    @MainActor public static func activate(_ d: TestDomain) {
        UserDefaults.standard.set(true, forKey: activePrefix + d.id)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: startedPrefix + d.id)
    }

    @MainActor public static func deactivate(_ d: TestDomain) {
        UserDefaults.standard.set(false, forKey: activePrefix + d.id)
    }

    public static func startedAt(_ d: TestDomain) -> Date? {
        let t = UserDefaults.standard.double(forKey: startedPrefix + d.id)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The guided capture target (nights for Sleep, days for Battery), 0 when unset. Read-through of
    /// the single namespace; the guided flow (Group E/F) writes it via `setGuidedTarget`.
    public static func guidedTarget(_ d: TestDomain) -> Int {
        UserDefaults.standard.integer(forKey: guidedTargetPrefix + d.id)
    }

    @MainActor public static func setGuidedTarget(_ count: Int, for d: TestDomain) {
        UserDefaults.standard.set(count, forKey: guidedTargetPrefix + d.id)
    }

    public static func answers(_ d: TestDomain) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: answersPrefix + d.id),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    // MARK: - All-time drained-rows tally (#990)

    /// Key for the ALL-TIME drained (persisted) row counter. Sits in the testcentre.* namespace because
    /// the Connection readout is its consumer, but it accrues UNCONDITIONALLY (the Backfiller's session
    /// summary is not test-mode gated), so it answers "has this install ever drained anything" across
    /// sessions - the #990 ask: the per-session counter resets on every reconnect, so a strap stuck in a
    /// pull-restart loop looked like it never progressed even when rows were landing.
    private static let cumulativeDrainedKey = "testcentre.cumulativeDrainedRows"

    /// Fold one session's drained rows into the persisted all-time tally. Called from the LiveState log
    /// sink when the Backfiller's "session persisted N rows" summary lands (the single emit point), so
    /// no BLE-path code needs a new seam. `nonisolated` - a UserDefaults read-modify-write only.
    public nonisolated static func noteDrainedRows(_ rows: Int) {
        guard rows > 0 else { return }
        let d = UserDefaults.standard
        d.set(d.integer(forKey: cumulativeDrainedKey) + rows, forKey: cumulativeDrainedKey)
    }

    /// The all-time drained-rows tally (0 before anything ever drained). The Connection readout shows it
    /// beside the per-session count (#990).
    public nonisolated static func cumulativeDrainedRows() -> Int {
        UserDefaults.standard.integer(forKey: cumulativeDrainedKey)
    }

}
