import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// Backup & Sync (Phase 1 — folder destination), the Apple mirror of the Android `BackupSync`.
/// Writes the full `.noopbak` snapshot (existing `DataBackup` format) into a user-chosen folder, on
/// demand and as an on-launch catch-up. Point that folder at a Google Drive / iCloud / Dropbox client
/// for automatic off-device backup with no in-app cloud account — NOOP only writes a local file.
///
/// Built behind `Destination` so a Phase-2 Google Drive backend slots in behind the same UI/logic.
/// The pure filename/selection helpers are unit-tested byte-for-byte against the Android twin.
enum BackupSync {

    enum Destination { case folder /* , googleDrive */ }

    static let prefix = "noop-backup-"
    static let suffix = ".noopbak"

    // ── Pure helpers (unit-tested; mirror Android BackupSync) ────────────────

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.isLenient = false
        return f
    }()

    /// Canonical snapshot filename for an instant (ms since epoch): `noop-backup-YYYYMMDD-HHMMSS.noopbak` (UTC).
    static func snapshotName(_ epochMs: Int) -> String {
        prefix + stampFormatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0)) + suffix
    }

    /// The UTC instant (ms) encoded in a snapshot filename, or nil if not one of ours.
    static func snapshotTimeMs(_ name: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let d = stampFormatter.date(from: stamp) else { return nil }
        return Int((d.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func isSnapshot(_ name: String) -> Bool { snapshotTimeMs(name) != nil }

    /// Newest snapshot by encoded time (non-snapshots ignored), or nil.
    static func latestSnapshot(_ names: [String]) -> String? {
        names.filter(isSnapshot).max { (snapshotTimeMs($0) ?? 0) < (snapshotTimeMs($1) ?? 0) }
    }

    /// Snapshots to DELETE to keep only the `keep` newest (oldest-first). Empty when within budget.
    static func snapshotsToPrune(_ names: [String], keep: Int) -> [String] {
        let snaps = names.filter(isSnapshot).sorted { (snapshotTimeMs($0) ?? 0) > (snapshotTimeMs($1) ?? 0) }
        return snaps.count <= keep ? [] : Array(snaps.dropFirst(keep))
    }
}

/// The folder destination: security-scoped bookmark of a user-chosen folder + write/restore + an
/// on-launch catch-up (Apple sandbox/background limits make a daily catch-up the pragmatic schedule —
/// macOS already relies on foreground for scheduled exports; iOS backs up on next foreground).
@MainActor
enum FolderBackup {
    private static let bookmarkKey = "backupSync.folderBookmark"
    private static let autoKey = "backupSync.auto"
    private static let lastKey = "backupSync.lastMs"
    static let keepCount = 10
    private static let dayMs = 24 * 60 * 60 * 1000

    static var autoEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
    static var lastBackupMs: Int { UserDefaults.standard.integer(forKey: lastKey) }
    static var hasFolder: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    static func folderLabel() -> String? { resolveFolder()?.lastPathComponent }

    private static func bookmarkOptions() -> URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func saveFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: bookmarkOptions(), includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    /// Write one snapshot into the bookmarked folder; returns true on success.
    static func backupNow(checkpoint: @escaping () async -> Bool) async -> Bool {
        guard let folder = resolveFolder() else { return false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
        let dest = folder.appendingPathComponent(BackupSync.snapshotName(nowMs))
        guard case .exported = await DataBackup.writeBackup(checkpoint: checkpoint, to: dest) else { return false }
        UserDefaults.standard.set(nowMs, forKey: lastKey)
        prune(in: folder)
        return true
    }

    private static func prune(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let toDelete = Set(BackupSync.snapshotsToPrune(names, keep: keepCount))
        for name in names where toDelete.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// On-launch catch-up: if auto is on, a folder is set, and it's been ≥ a day, back up.
    static func catchUpIfDue(checkpoint: @escaping () async -> Bool) async {
        guard autoEnabled, hasFolder else { return }
        if Int(Date().timeIntervalSince1970 * 1000.0) - lastBackupMs >= dayMs {
            _ = await backupNow(checkpoint: checkpoint)
        }
    }

    // ── Folder picker ────────────────────────────────────────────────────────
    #if os(macOS)
    /// Present an NSOpenPanel to choose a directory; persists the bookmark. Returns the chosen URL.
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder for NOOP backups (e.g. a Google Drive / iCloud folder)."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        saveFolder(url)
        return url
    }
    #else
    /// Present a folder picker (UIDocumentPicker) and persist the bookmark.
    static func pickFolder() async -> URL? {
        let url = await DocumentPicker.pickFolder()
        if let url { saveFolder(url) }
        return url
    }
    #endif
}
