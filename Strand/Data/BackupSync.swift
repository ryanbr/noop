import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
import UniformTypeIdentifiers
#endif

/// Backup & Sync (folder destination) - the Apple twin of the Android `BackupSync`. Writes the full
/// `.noopbak` snapshot (the existing `DataBackup` format) into a user-chosen folder, on demand and as
/// an on-launch daily catch-up. Point that folder at a Google Drive / iCloud / Dropbox client and you
/// get automatic off-device backup with no in-app cloud account - NOOP only writes a local file; the
/// sync client does the upload.
///
/// `BackupSync` holds only the PURE, unit-tested filename / selection logic (no I/O, no state) so it is
/// byte-for-byte equivalent to the Android twin: same `noop-backup-YYYYMMDD-HHMMSS.noopbak` scheme,
/// same newest-first selection, same keep-N prune. The stateful folder I/O lives in `FolderBackup`.
enum BackupSync {

    /// The destinations this is built to support. Phase 1 ships `.folder`; a future Drive backend slots
    /// in behind the same UI/logic without changing the snapshot scheme.
    enum Destination { case folder /* , googleDrive */ }

    static let prefix = "noop-backup-"
    static let suffix = ".noopbak"

    // MARK: - Pure helpers (unit-tested; mirror Android BackupSync)

    /// Default staleness threshold (3 days). Auto-backup runs a DAILY on-launch catch-up, so a
    /// *successful* backup older than this means the catch-up isn't landing — a stale/permission-lost
    /// folder bookmark, or the app simply hasn't been launched in a while. Surfaced as a warning so a
    /// silently-failing auto-backup is visible instead of only discovered when a restore is needed.
    static let staleThresholdMs = 3 * 24 * 60 * 60 * 1000

    /// True when auto-backup should be flagged STALE: the last SUCCESSFUL backup is older than
    /// `thresholdMs`. `lastBackupMs == 0` (never backed up while auto is on) also counts as stale. Pure so
    /// it's unit-tested with literal ms; the caller supplies `nowMs` and gates on `autoEnabled`/folder.
    /// Twin of Android `BackupSync.isBackupStale`.
    static func isBackupStale(lastBackupMs: Int, nowMs: Int, thresholdMs: Int = staleThresholdMs) -> Bool {
        nowMs - lastBackupMs >= thresholdMs
    }

    /// A fresh UTC second-resolution formatter. Created per call so the type stays trivially `Sendable`
    /// and there is no shared mutable `DateFormatter` to data-race; the cost is irrelevant at this rate.
    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.isLenient = false
        return f
    }

    /// Canonical snapshot filename for an instant (ms since epoch): `noop-backup-YYYYMMDD-HHMMSS.noopbak` (UTC).
    static func snapshotName(_ epochMs: Int) -> String {
        prefix + stampFormatter().string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0)) + suffix
    }

    /// The UTC instant (ms) encoded in a snapshot filename, or nil if `name` is not one of ours.
    static func snapshotTimeMs(_ name: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        guard let d = stampFormatter().date(from: stamp) else { return nil }
        return Int((d.timeIntervalSince1970 * 1000.0).rounded())
    }

    static func isSnapshot(_ name: String) -> Bool { snapshotTimeMs(name) != nil }

    /// Any `.noopbak` file, whatever it's named. The RESTORE list uses this (not `isSnapshot`) so a
    /// hand-named backup like `noop-backup-2026-06-30.noopbak` still shows (#852). Case-insensitive on
    /// the extension so `.NOOPBAK` copied off another device still counts. Prune/latest stay strict on
    /// `isSnapshot`, so a non-canonical name is listed for restore but never auto-deleted.
    static func isBackupFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(suffix)
    }

    /// A `.noopbak` sitting in an iCloud Drive folder that hasn't been downloaded to THIS Mac/iPhone
    /// yet is listed by the filesystem under a placeholder name - a leading dot plus an `.icloud`
    /// suffix, e.g. `noop-backup-....noopbak` becomes `.noop-backup-....noopbak.icloud` - instead of
    /// its real name. Unresolved, that placeholder silently fails `isBackupFile` and the restore list
    /// shows nothing even though Finder shows the file (#278: cross-device restore via iCloud Drive,
    /// the workflow the folder-picker screen itself recommends). Returns the real name, or nil if
    /// `name` isn't a placeholder.
    static func iCloudPlaceholderRealName(_ name: String) -> String? {
        let iCloudSuffix = ".icloud"
        guard name.hasPrefix("."), name.hasSuffix(iCloudSuffix),
              name.count > 1 + iCloudSuffix.count else { return nil }
        return String(name.dropFirst().dropLast(iCloudSuffix.count))
    }

    /// Newest snapshot by encoded time (non-snapshots ignored), or nil.
    static func latestSnapshot(_ names: [String]) -> String? {
        names.filter(isSnapshot).max { (snapshotTimeMs($0) ?? 0) < (snapshotTimeMs($1) ?? 0) }
    }

    /// Snapshot names sorted newest-first (non-snapshots dropped). The folder restore list order.
    static func snapshotsNewestFirst(_ names: [String]) -> [String] {
        names.filter(isSnapshot).sorted { (snapshotTimeMs($0) ?? 0) > (snapshotTimeMs($1) ?? 0) }
    }

    /// Snapshots to DELETE to keep only the `keep` newest (oldest-first). Empty when within budget.
    /// Strict on purpose: only canonical snapshots are prune candidates, so a hand-named `.noopbak`
    /// in the folder is never auto-deleted.
    static func snapshotsToPrune(_ names: [String], keep: Int) -> [String] {
        let snaps = snapshotsNewestFirst(names)
        return snaps.count <= keep ? [] : Array(snaps.dropFirst(keep))
    }

    /// One restorable `.noopbak` for the folder picker: its filename and the ms used to order/label it.
    struct Restorable: Equatable {
        let name: String
        /// The instant we sort and display by: the canonical filename stamp when present, else the
        /// file's own modification date (passed in by the I/O layer). Never nil so the list is stable.
        let timeMs: Int
    }

    /// ALL `.noopbak` files (any name) ordered newest-first for the restore picker (#852). Canonical
    /// names use their embedded UTC stamp; the rest fall back to the file date `fileDateMs` gives for
    /// that name (0 when unknown). Non-`.noopbak` files are dropped. Pure, so it's unit-tested; the I/O
    /// layer supplies `fileDateMs` from the filesystem.
    static func restorablesNewestFirst(_ names: [String],
                                       fileDateMs: (String) -> Int) -> [Restorable] {
        names.filter(isBackupFile)
            .map { Restorable(name: $0, timeMs: snapshotTimeMs($0) ?? fileDateMs($0)) }
            // Newest-first, with a name tie-break so equal-time entries (two files sharing a date-only
            // name, or a provider that reports the same modified date) order deterministically and
            // identically to Kotlin's `compareByDescending { timeMs }.thenBy { name }`.
            .sorted { $0.timeMs != $1.timeMs ? $0.timeMs > $1.timeMs : $0.name < $1.name }
    }
}

/// The folder destination: a security-scoped bookmark of a user-chosen folder, plus write / list /
/// restore / prune and an on-launch daily catch-up.
///
/// Apple gives no reliable unattended background DB write (a whole-DB ZIP can be 100 MB+ and the OS
/// kills long background tasks), so the "schedule" is a deferred on-launch catch-up: if auto is ON and
/// a day has passed, the next foreground launch writes one snapshot - fully off the main thread, and
/// off the launch-critical path, so it never blocks startup (must-fix #4).
enum FolderBackup {
    private static let bookmarkKey = "backupSync.folderBookmark"
    private static let autoKey = "backupSync.auto"
    private static let lastKey = "backupSync.lastMs"
    private static let keepKey = "backupSync.keepCount"
    private static let internalKey = "backupSync.useInternalFolder"   // #52 picker-free fallback

    /// Default snapshots kept by prune: 7, i.e. a week of daily rollback points. (Mirrors the Android
    /// DEFAULT_KEEP; the Android keep-count is likewise user-adjustable.)
    static let defaultKeep = 7

    /// Retention choices offered by the Backup & Sync keep-count picker (mirrors Android KEEP_OPTIONS).
    static let keepOptions = [1, 3, 5, 7, 10, 14]

    /// How many latest snapshots to keep; older ones are pruned (oldest-first). User-adjustable via the
    /// picker; unset reads back as [defaultKeep]. Clamped to a sane 1...100.
    static var keepCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: keepKey)   // 0 when never set
            return v == 0 ? defaultKeep : min(max(v, 1), 100)
        }
        set { UserDefaults.standard.set(min(max(newValue, 1), 100), forKey: keepKey) }
    }
    private static let dayMs = 24 * 60 * 60 * 1000

    // MARK: - Persisted state

    /// Auto-backup defaults OFF (manual-first; must-fix #4 + #6). The user turns it on in the screen.
    static var autoEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    static var lastBackupMs: Int { UserDefaults.standard.integer(forKey: lastKey) }
    static var hasFolder: Bool { useInternalFolder || UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    /// #52: on some iOS 26 builds the system folder picker's "Open" button never enables/fires, so users
    /// can't choose an external folder at all (three reports, works for one). This opt-in falls back to
    /// NOOP's OWN Documents/Backups folder — already exposed in Files (UIFileSharingEnabled +
    /// LSSupportsOpeningDocumentsInPlace) under "On My iPhone → NOOP" — so Backup & Sync works with zero
    /// dependence on the picker. No security-scoped bookmark is involved (the folder is inside our own
    /// sandbox), so `resolveFolder`/`saveFolder`'s scoped-access brackets simply no-op for it. The user
    /// can drag that folder into iCloud Drive to read backups on the Mac; a first-class iCloud container
    /// is a separate, larger change. An explicit external pick (`saveFolder`) turns this back off.
    static var useInternalFolder: Bool {
        get { UserDefaults.standard.bool(forKey: internalKey) }
        set { UserDefaults.standard.set(newValue, forKey: internalKey) }
    }

    /// Opt into backing up inside NOOP's own Files-visible folder (see `useInternalFolder`). Returns the
    /// folder URL so the caller can refresh its label. iOS-only in practice; harmless elsewhere.
    @discardableResult
    static func useNoopFolder() -> URL? {
        useInternalFolder = true
        return internalFolderURL()
    }

    /// NOOP's own Files-visible backup folder: `<sandbox>/Documents/Backups`, created on first use.
    /// Returns nil only if Documents can't be located (never in practice).
    private static func internalFolderURL() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A short, human label for the chosen folder, or nil if none chosen. The internal fallback gets a
    /// friendly name instead of the raw "Backups" path component.
    static func folderLabel() -> String? {
        if useInternalFolder { return String(localized: "NOOP (in Files)") }
        return resolveFolder()?.lastPathComponent
    }

    // MARK: - Security-scoped bookmark

    private static func bookmarkCreationOptions() -> URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static func resolveFolder() -> URL? {
        if useInternalFolder { return internalFolderURL() }   // #52: no bookmark — our own sandbox folder
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        let url = try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale)
        // A stale bookmark still resolves; refresh it opportunistically so it keeps working next launch.
        if stale, let url { saveFolder(url) }
        return url
    }

    /// Persist a security-scoped bookmark for `url`. Brackets the bookmark creation in a scoped-access
    /// pair on macOS (required to mint a `.withSecurityScope` bookmark for a sandbox-granted folder).
    static func saveFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try? url.bookmarkData(options: bookmarkCreationOptions(),
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            useInternalFolder = false   // #52: an explicit external pick overrides the internal fallback
        }
        // #52 instrumentation: record whether scoped access opened and whether the bookmark actually
        // minted, so a debug export can tell a folder that failed to persist HERE apart from a picker
        // that never returned a URL at all. Cheap UserDefaults writes; see DebugDataDiagnostics.
        let d = UserDefaults.standard
        d.set(scoped, forKey: "backupPicker.lastScopedOpen")
        d.set(data != nil, forKey: "backupPicker.lastBookmarkOk")
    }

    // MARK: - Backup / prune

    /// Write one snapshot into the bookmarked folder, stamp the last-backup time, then prune to keepN.
    /// Returns true on success. Runs the whole-DB ZIP off the caller's thread; never touches UI.
    @discardableResult
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

    /// Best-effort retention: delete snapshots beyond `keepCount`. Listing failures are ignored, and
    /// non-snapshot files in the folder are never touched (only files matching the backup scheme).
    private static func prune(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let toDelete = Set(BackupSync.snapshotsToPrune(names, keep: keepCount))
        for name in names where toDelete.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// On-launch catch-up: if auto is on, a folder is set, and it's been at least a day since the last
    /// backup, write one. Gated entirely on the toggle being ON (must-fix #4). The caller MUST invoke
    /// this off the launch-critical path; it does no UI work and is safe to run after the first refresh.
    static func catchUpIfDue(checkpoint: @escaping () async -> Bool) async {
        guard autoEnabled, hasFolder else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
        guard nowMs - lastBackupMs >= dayMs else { return }
        await backupNow(checkpoint: checkpoint)
    }

    /// Diagnostic-only snapshot of the restore list's health: the chosen folder's name, its raw entry
    /// count, and how many of those resolve into recognized `.noopbak` snapshots. Nil when no folder is
    /// chosen. Lets a "restore shows no files" report (#278) distinguish a genuinely empty folder from a
    /// resolution problem (e.g. undownloaded iCloud placeholders, see `iCloudPlaceholderRealName`)
    /// without needing a live repro. Used by `DebugDataDiagnostics`.
    static func restoreListHealth() -> (isICloud: Bool, rawEntries: Int, snapshots: Int)? {
        guard let folder = resolveFolder() else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let raw = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count ?? 0
        // Report iCloud-vs-local (the actual #278 triage signal — undownloaded placeholders live in the
        // iCloud container) WITHOUT the folder's user-chosen name, which redactPii can't scrub and the
        // iOS twin never exposes. The iCloud ubiquity container path contains "Mobile Documents".
        let isICloud = folder.path.contains("Mobile Documents")
        return (isICloud, raw, listSnapshots().count)
    }

    // MARK: - Restore from the configured folder (must-fix #1)

    /// One restorable snapshot in the chosen folder: its display name + a friendly absolute-time line.
    struct Snapshot: Identifiable, Hashable {
        let name: String
        let timeMs: Int
        var id: String { name }
    }

    /// List the backups in the user's chosen folder, NEWEST FIRST - the source for the restore picker
    /// (must-fix #1: restore from the configured folder, never a generic re-prompt). Lists ANY `.noopbak`
    /// file, not just canonically-named ones (#852): a hand-named backup like
    /// `noop-backup-2026-06-30.noopbak` still shows. Canonical names sort/label by their embedded stamp;
    /// the rest by the file's own modification date. Content is validated on restore, so a bad file here
    /// is caught then. Returns an empty list if no folder is chosen or the folder can't be read.
    static func listSnapshots() -> [Snapshot] {
        guard let folder = resolveFolder() else { return [] }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let rawNames = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // #278: a `.noopbak` iCloud hasn't downloaded to this Mac/iPhone yet is listed under a
        // placeholder name; resolve it back to its real name so it still shows in the restore list
        // (see `BackupSync.iCloudPlaceholderRealName`). `restore(snapshotNamed:)` resolves the same
        // way and kicks off the download if the user picks one that's still a placeholder on disk.
        let names = rawNames.map { BackupSync.iCloudPlaceholderRealName($0) ?? $0 }
        let fileDateMs: (String) -> Int = { name in
            let onDisk = rawNames.contains(name) ? name : ("." + name + ".icloud")
            let url = folder.appendingPathComponent(onDisk)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified else { return 0 }
            return Int((modified.timeIntervalSince1970 * 1000.0).rounded())
        }
        return BackupSync.restorablesNewestFirst(names, fileDateMs: fileDateMs)
            .map { Snapshot(name: $0.name, timeMs: $0.timeMs) }
    }

    /// Restore a snapshot the user picked FROM THE CONFIGURED FOLDER. Resolves the bookmark, brackets
    /// security-scoped access, and hands the concrete file to `DataBackup.restore(from:)` - so every
    /// hardened safety (magic-byte + GRDB-origin validation, sidecar snapshot, rollback) still applies.
    /// The destructive confirmation is the screen's responsibility (must-fix #2); this is the final
    /// step it calls only AFTER the user confirms.
    static func restore(snapshotNamed name: String) -> DataBackup.BackupResult {
        guard let folder = resolveFolder() else {
            return .failure("Couldn't open your backup folder - re-pick it and try again.")
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let source = folder.appendingPathComponent(name)
        var wasPlaceholder = false
        if !FileManager.default.fileExists(atPath: source.path) {
            // #278: `name` came from the (already de-placeholdered) restore list, so if it's not on
            // disk under its real name it may still be an undownloaded iCloud placeholder. Kick off
            // the download and give it a short window to land - this runs off the main thread (the
            // screen calls `restore` from a detached Task), so blocking here doesn't freeze the UI.
            let placeholder = folder.appendingPathComponent("." + name + ".icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) {
                wasPlaceholder = true
                try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
                let deadline = Date().addingTimeInterval(15)
                while !FileManager.default.fileExists(atPath: source.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .failure(wasPlaceholder
                ? "That backup is still downloading from iCloud - wait a moment and try again."
                : "That backup is no longer in your folder.")
        }
        return DataBackup.restore(from: source)
    }

    // MARK: - Folder picker

    #if os(macOS)
    /// Present an `NSOpenPanel` to choose a directory; persists the bookmark. Returns the chosen URL.
    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for NOOP backups (for example a Google Drive or iCloud folder).")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        saveFolder(url)
        return url
    }
    #else
    /// Present a folder picker (`UIDocumentPicker`) and persist the bookmark. Returns the chosen URL.
    /// Starts in the previously-chosen folder when one resolves (else the picker falls back to our
    /// Documents) — part of the #1000a "Select button never enables" mitigation; see
    /// `DocumentPicker.pickFolder`.
    @MainActor
    static func pickFolder() async -> URL? {
        let url = await DocumentPicker.pickFolder(startingAt: resolveFolder())
        if let url { saveFolder(url) }
        return url
    }
    #endif
}
