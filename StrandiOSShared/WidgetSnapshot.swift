import Foundation

/// Small, Codable glance snapshot shared between the iOS app and its widget/Live-Activity extension
/// via an App Group. The app writes it; the widget reads it. Keeping it tiny avoids any cross-process
/// database access — the widget never opens SQLite.
public struct WidgetSnapshot: Codable, Equatable {
    public var recovery: Int?    // Charge (0–100)
    public var bpm: Int?
    public var batteryPct: Int?
    public var bonded: Bool
    public var updated: Date
    // Richer glance fields (#446). All OPTIONAL with nil defaults so a snapshot written by an OLDER app
    // build (which never encoded these keys) still decodes — Codable fills a missing optional with nil.
    public var effort: Int?      // Effort / strain on NOOP's 0–100 axis (ring fill is always this / 100)
    public var rest: Int?        // Rest (sleep_performance) score, 0–100
    public var hrv: Int?         // HRV (ms), whole-number for the glance
    public var restingHr: Int?   // Resting heart rate (bpm)
    // #313 Effort scale for the glance. Pre-formatted at publish time because the widget extension
    // cannot read the app's plain UserDefaults `effort.scale` key (it lives outside the App Group).
    // When nil (older snapshot), the widget falls back to whole-number `effort` on the 0–100 axis.
    public var effortDisplay: String?
    /// True when `effortDisplay` is on WHOOP's 0–21 axis; false/nil means 0–100. Accessibility only.
    public var effortWhoop: Bool?

    public init(recovery: Int?, bpm: Int?, batteryPct: Int?, bonded: Bool, updated: Date,
                effort: Int? = nil, rest: Int? = nil, hrv: Int? = nil, restingHr: Int? = nil,
                effortDisplay: String? = nil, effortWhoop: Bool? = nil) {
        self.recovery = recovery
        self.bpm = bpm
        self.batteryPct = batteryPct
        self.bonded = bonded
        self.updated = updated
        self.effort = effort
        self.rest = rest
        self.hrv = hrv
        self.restingHr = restingHr
        self.effortDisplay = effortDisplay
        self.effortWhoop = effortWhoop
    }

    /// App Group suite the app and widget both use. Injected from the `APP_GROUP_ID` build setting
    /// (see project.yml) via the `AppGroupIdentifier` Info.plist key, so the value lives in exactly
    /// one place rather than being duplicated here. Must match the `com.apple.security.application-groups`
    /// entitlement on both targets (which also reads `$(APP_GROUP_ID)`). If the entitlement is missing on
    /// either side, `UserDefaults(suiteName:)` returns nil and every consumer (PendingIntents,
    /// WidgetSnapshot.publish, Live Activity) silently no-ops — see `assertGroupProvisioned` for the
    /// debug-time canary. The fallback is the canonical upstream group and only applies if the Info.plist
    /// key is somehow absent (each process reads its OWN bundle, so the app and the widget extension
    /// each carry the key in their generated Info.plist).
    public static let suiteName: String = {
        resolveSuiteName(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }()
    public static let storageKey = "noop.widget.snapshot"

    /// Resolve the App Group the current signature actually grants.
    ///
    /// AltStore / SideStore must make every App Group unique to the user's signing team. During
    /// re-signing they append the team identifier to the group requested by the downloaded app and
    /// publish the resulting, provisioned identifiers in `ALTAppGroups` in each bundle's Info.plist.
    /// Reading only the build-time `AppGroupIdentifier` therefore points at an unprovisioned container
    /// in a sideloaded build, even though the host app and widget extension were both signed correctly.
    ///
    /// Normal Xcode builds don't carry `ALTAppGroups`, so they keep using `AppGroupIdentifier`.
    static func resolveSuiteName(infoDictionary: [String: Any]) -> String {
        let configured = (infoDictionary["AppGroupIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let altGroups = (infoDictionary["ALTAppGroups"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("group.") && !$0.isEmpty } ?? []

        if let configured, !configured.isEmpty,
           let provisioned = altGroups.first(where: {
               $0 == configured || $0.hasPrefix(configured + ".")
           }) {
            return provisioned
        }
        if altGroups.count == 1, let provisioned = altGroups.first {
            return provisioned
        }
        if let configured, !configured.isEmpty {
            return configured
        }
        return "group.com.noopapp.noop"
    }

    /// Debug-only canary: trips on the first run after a misprovisioning so the silent no-op gets
    /// caught immediately rather than masquerading as "widget shows nothing yet." Release builds do
    /// nothing — App Store apps can't crash on a missing entitlement.
    public static func assertGroupProvisioned() {
        assert(UserDefaults(suiteName: suiteName) != nil,
               "App Group '\(suiteName)' not provisioned on this target — check the entitlement.")
    }

    public static var placeholder: WidgetSnapshot {
        // Gallery / pre-publish stand-in: realistic Charge · Effort · Rest on the 0–100 axis so the
        // three-ring Home Screen layouts (and the large grid) preview with filled arcs, not dashes.
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: Date(),
                       effort: 38, rest: 81, hrv: 64, restingHr: 52,
                       effortDisplay: "38", effortWhoop: false)
    }

    /// Honest runtime state when the app has not published a readable snapshot yet. Unlike
    /// `placeholder`, this is user-visible and must never imply that sample data is real.
    static var unavailable: WidgetSnapshot {
        WidgetSnapshot(recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: .distantPast)
    }

    /// Read the last-published snapshot from the shared suite, if any.
    public static func load() -> WidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }

    /// Persist this snapshot into the shared suite.
    public func save() {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WidgetSnapshot.storageKey)
    }
}
