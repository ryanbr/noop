import Foundation

/// The `settings.json` payload inside a `.noopbak` backup (#1000).
///
/// A `.noopbak` is a ZIP whose first entry is the SQLite database. That round-trips every row, but the
/// user's profile (age / sex / weight / height / HR-max override) and display preferences live in
/// UserDefaults (SharedPreferences on Android), so a restore onto a fresh device silently reset them —
/// the "restore doesn't bring back settings/weight/height" half of #1000. This adds a SECOND, optional
/// ZIP entry — `settings.json`, a flat JSON object — carrying exactly one WHITELISTED set of keys.
///
/// The whitelist is the contract, defined once per platform and mirrored byte-for-byte by Android's
/// `BackupSettingsCodec` (same canonical key strings, same JSON kinds). Only stable, user-set,
/// non-device-specific values are allowed. NEVER add device ids, peripheral ids, tokens, sync cursors,
/// or anything anonymity-sensitive: backups get copied into cloud folders and attached to GitHub
/// issues, so this file must stay safe to share. Unknown keys in an incoming `settings.json` are
/// dropped on the floor; a backup with no `settings.json` (every pre-#1000 backup) is simply a
/// DB-only restore, exactly as before.
///
/// Pure JSON + UserDefaults mapping only — no ZIP code here. The container work stays in the app's
/// `DataBackup`; this lives in the package so the codec and the defaults round-trip are unit-testable
/// headlessly (`swift test --filter BackupSettingsTests`).
public enum BackupSettings {

    /// Canonical entry name inside the `.noopbak` ZIP. Matches the Android exporter byte-for-byte.
    public static let entryName = "settings.json"

    /// The JSON kind a whitelisted key must decode to. Anything else (wrong type, JSON bool posing
    /// as a number, nested objects) is dropped rather than guessed at.
    public enum Kind: Sendable {
        case int, double, string
    }

    /// THE whitelist — the only keys `settings.json` may carry, keyed by their CANONICAL
    /// (platform-neutral) names. Mirrored exactly by Android's `BackupSettingsCodec.WHITELIST`.
    ///
    /// Profile: the body metrics that power HR zones / calories / recovery baselines, plus the manual
    /// HR-max override (`profile.hrMax`, 0 = auto/Tanaka). Display: the metric/imperial system, the
    /// separate temperature override ("" = match the system), and the Effort axis (#268) — the three
    /// display prefs that exist with identical semantics on both platforms. Deliberately EXCLUDED:
    /// step calibration (per-strap, not per-person), the avatar blob (bulky, and not "settings"),
    /// steps-engine fitted outputs (derived), and every noop.* toggle that is device- or
    /// install-specific — INCLUDING the Today/Sleep section order, Key-Metrics and dashboard-card
    /// selections, which stay per-install.
    ///
    /// The ONE layout pref that IS carried is `today.hostedCards` (#today-hosted-cards): the Trends/Sleep
    /// cards the user chose to host in Today. Unlike section order, this is a deliberate composition the
    /// user built and expects to keep across a restore; it is a JSON `[String]` (rides the String kind).
    /// The hosted cards' POSITION (the `addedCards` section slot in `today.sectionOrder`) is not carried,
    /// so on restore the set + internal order return but the section sits at its default position.
    public static let whitelist: [String: Kind] = [
        "profile.age": .int,
        "profile.sex": .string,
        "profile.weightKg": .double,
        "profile.heightCm": .double,
        "profile.waistCm": .double,
        "profile.hrMax": .int,
        "profile.hrZoneThresholds": .string,
        "units.system": .string,
        "units.temperature": .string,
        "effort.scale": .string,
        "today.hostedCards": .string,
    ]

    /// Canonical JSON key → this platform's UserDefaults key. Identity everywhere except
    /// `profile.hrMax`, which UserDefaults stores as `profile.hrMaxOverride` (see `ProfileStore.K`).
    /// Android maps the same canonical keys onto its own SharedPreferences names.
    public static let appleDefaultsKey: [String: String] = [
        "profile.age": "profile.age",
        "profile.sex": "profile.sex",
        "profile.weightKg": "profile.weightKg",
        "profile.heightCm": "profile.heightCm",
        "profile.waistCm": "profile.waistCm",
        "profile.hrMax": "profile.hrMaxOverride",
        "profile.hrZoneThresholds": "profile.hrZoneThresholds",
        "units.system": "units.system",
        "units.temperature": "units.temperature",
        "effort.scale": "effort.scale",
        "today.hostedCards": "today.hostedCards",
    ]

    // MARK: - Snapshot / apply (UserDefaults boundary)

    /// The whitelisted values currently SET in `defaults`, keyed canonically — the export-side
    /// snapshot. Keys the user never touched are omitted (not defaulted), so restoring this backup
    /// on another device only overwrites what was genuinely set here and leaves the rest of the
    /// target's settings alone.
    public static func snapshot(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for (canonical, kind) in whitelist {
            guard let storageKey = appleDefaultsKey[canonical],
                  let raw = defaults.object(forKey: storageKey),
                  let coerced = coerce(raw, to: kind) else { continue }
            out[canonical] = coerced
        }
        return out
    }

    /// Write the whitelisted `values` (canonical keys) into `defaults` under this platform's storage
    /// keys — the restore-side apply. Non-whitelisted keys and wrong-typed values are ignored. The
    /// caller decides WHEN (DataBackup applies only after a successful DB swap, never on a failed or
    /// rolled-back restore).
    public static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for (canonical, kind) in whitelist {
            guard let raw = values[canonical],
                  let coerced = coerce(raw, to: kind),
                  let storageKey = appleDefaultsKey[canonical] else { continue }
            defaults.set(coerced, forKey: storageKey)
        }
        // #146: the whitelist carries an Int `profile.age`, not a Date, so a restore can only bring an
        // age. Clear any stale `profile.dateOfBirth` on this device whenever an age is applied, so
        // `ProfileStore` re-derives the date of birth from the RESTORED age on next launch instead of a
        // pre-existing local DOB silently overriding the restore. (A restore forces a relaunch, so the
        // re-derivation always runs.) `dobDefaultsKey` is spelled out here rather than added to the
        // whitelist to keep the cross-platform JSON contract unchanged.
        if values["profile.age"] != nil {
            defaults.removeObject(forKey: dobDefaultsKey)
        }
    }

    /// UserDefaults key `ProfileStore` stores the #146 date of birth under. Not a whitelisted backup
    /// key (a Date can't ride the Int/Double/String JSON contract) — only cleared on restore so the
    /// restored Int age re-derives it. Must match `ProfileStore.K.dateOfBirth`.
    static let dobDefaultsKey = "profile.dateOfBirth"

    // MARK: - JSON codec

    /// Encode the whitelisted subset of `values` as the flat `settings.json` object. Returns nil when
    /// nothing whitelisted is present (the exporter then writes a DB-only backup — indistinguishable
    /// from a legacy one, which is exactly the right degrade). `.sortedKeys` keeps the output
    /// deterministic so identical settings always produce identical bytes.
    public static func encode(_ values: [String: Any]) -> Data? {
        var filtered: [String: Any] = [:]
        for (key, kind) in whitelist {
            guard let raw = values[key], let coerced = coerce(raw, to: kind) else { continue }
            filtered[key] = coerced
        }
        guard !filtered.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
    }

    /// Decode a `settings.json` payload down to its whitelisted, correctly-typed subset. Malformed
    /// JSON, a non-object root, unknown keys, and wrong-typed values all degrade to "fewer keys" —
    /// never an error, because a bad settings entry must not fail a restore whose DB half is fine.
    public static func decode(_ data: Data) -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (key, kind) in whitelist {
            guard let raw = obj[key], let coerced = coerce(raw, to: kind) else { continue }
            out[key] = coerced
        }
        return out
    }

    // MARK: - Coercion

    /// Coerce a JSON-decoded (or caller-supplied) value to the whitelist's declared kind, or nil if
    /// it can't represent one. JSON booleans arrive as `NSNumber` too, so they are explicitly refused
    /// for numeric kinds — `true` must never become age 1.
    private static func coerce(_ value: Any, to kind: Kind) -> Any? {
        switch kind {
        case .string:
            return value as? String
        case .int:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.intValue
        case .double:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.doubleValue
        }
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
        CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}
