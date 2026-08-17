import Foundation

/// Build provenance for exports (#1410): a `manifest.json` entry recording which build produced a
/// `.noopbak`, and an `APP_VERSION_CHANGED` event marking each in-app version transition so a SINGLE
/// export answers "what ran when" across the whole retention window. Pure JSON only — the ZIP container
/// and the event write live in the app layer; these are the byte-parity contract with Android.
///
/// Neither is telemetry: both are LOCAL metadata inside the user's own backup, nothing leaves the device.

/// The `manifest.json` entry inside a `.noopbak` — "which build produced this file" (#1410 tier 1).
/// Sibling to `BackupSettings`; not restored, read only to classify a file (helps #746 route by what a
/// file SAYS it is rather than probing tables).
public enum BackupManifest {
    /// Canonical entry name inside the `.noopbak` ZIP. Matches the Android exporter byte-for-byte.
    public static let entryName = "manifest.json"

    /// Deterministic (`.sortedKeys`) JSON: `appBuild`, `appVersion`, `exportedAt` (unix ms), `platform`
    /// ("apple"/"android"), `schemaVersion` (the DB's native schema integer for that platform). The twin
    /// of Android `BackupManifest.json`; keys + kinds identical, values platform-specific.
    public static func json(appVersion: String, appBuild: String, platform: String,
                            schemaVersion: Int, exportedAtMs: Int64) -> String {
        let obj: [String: Any] = [
            "appVersion": appVersion,
            "appBuild": appBuild,
            "platform": platform,
            "schemaVersion": schemaVersion,
            "exportedAt": exportedAtMs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The `APP_VERSION_CHANGED` event appended on an in-app version transition (#1410 tier 2). The one piece
/// no other means can reconstruct: a single export then answers "what ran when" retroactively.
public enum AppVersionEvent {
    /// The `event.kind` for a version transition. Rides the existing `event` table (`payloadJSON` string).
    public static let kind = "APP_VERSION_CHANGED"

    /// Record a transition only when a PRIOR version was seen AND it differs — a first launch (nil prior)
    /// records nothing (there is no transition), so the table never carries a spurious "from null" row.
    public static func shouldRecord(lastSeen: String?, current: String) -> Bool {
        guard let lastSeen, !lastSeen.isEmpty else { return false }
        return lastSeen != current
    }

    /// Deterministic (`.sortedKeys`) payload: `from`, `schemaVersion`, `to`. Twin of Android
    /// `AppVersionEvent.payloadJson`.
    public static func payloadJson(from: String, to: String, schemaVersion: Int) -> String {
        let obj: [String: Any] = ["from": from, "to": to, "schemaVersion": schemaVersion]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
