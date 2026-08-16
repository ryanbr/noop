import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SQLite3
import UniformTypeIdentifiers
import WhoopStore
import ZIPFoundation

/// Full-database EXPORT / IMPORT for device migration.
///
/// NOOP keeps everything in one SQLite file (`<AppSupport>/OpenWhoop/whoop.sqlite`, plus the
/// `-wal`/`-shm` WAL sidecars while the store is open). Export checkpoints the WAL (so the
/// single file is whole), then wraps the SQLite in a ZIP written as `.noopbak`, alongside a
/// small `settings.json` entry (#1000) carrying the whitelisted profile/display settings (see
/// `BackupSettings`) so a restore also brings back weight/height/units, not just the rows.
/// ZIP deflate typically cuts a 100 MB+ SQLite backup to 10–20 MB. The format is a standard
/// ZIP — users can rename `.noopbak` → `.zip` and extract the SQLite manually on any OS.
///
/// Import detects the format by magic bytes: ZIP (`PK\x03\x04`) or legacy plain SQLite. ZIP
/// backups are extracted to a temp dir, validated, then swapped in exactly like a plain import.
/// Old `.sqlite` / `.noopdb` backups keep working.
///
/// Sandbox-safe: relies on the `com.apple.security.files.user-selected.read-write` entitlement and
/// security-scoped access on the panel-returned URLs. Every path is best-effort — failures surface
/// as a `.failure` result and never crash.
enum DataBackup {
    private static let maxBackupSQLiteBytes: Int64 = 2_147_483_648
    private static let maxBackupSettingsBytes: Int64 = 1_048_576

    // MARK: - Result

    enum BackupResult {
        /// Export wrote the backup to `url`.
        case exported(URL)
        /// Import succeeded; a relaunch is required for it to take effect. `sidecar` is where the
        /// previous database was preserved, in case the user wants to roll back.
        case imported(sidecar: URL)
        /// The user dismissed the save/open panel — nothing happened, show nothing loud.
        case cancelled
        /// Something went wrong; `message` is user-facing.
        case failure(String)
    }

    // MARK: - Export

    /// Checkpoint the store and write the live database as a compressed `.noopbak` (single-entry
    /// ZIP) to a user-chosen file.
    ///
    /// - Parameter checkpoint: invoked first to flush the WAL into the main file. Pass
    ///   `repo.checkpointForBackup`. Must succeed — a failed checkpoint means committed pages still
    ///   live in the WAL and would be silently absent from the ZIP; we fail loudly rather than ship
    ///   a partial backup.
    @MainActor
    static func runExport(checkpoint: @escaping () async -> Bool) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet. Import or record some first."))
        }

        // Flush the WAL so the single .sqlite carries everything. Required for ZIP (no sidecar
        // fallback in a single-file archive).
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely export right now. Recent changes are still in the database's write-ahead log. Close any in-flight sync, then try again."))
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = String(localized: "Export NOOP backup")
        panel.prompt = String(localized: "Export")
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultBackupName()
        panel.allowedContentTypes = backupContentTypes()
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }

        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        do {
            // NSSavePanel already handled the "replace existing?" confirmation; clear the target.
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            // Reading the whole SQLite and DEFLATE-compressing it is multi-second on a big library
            // (and #1014 added a quick_check read of the whole file first); run it off the main
            // actor so the UI never beach-balls. Only file paths cross the hop.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            }.value
            return .exported(dest)
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        #else
        let fm = FileManager.default

        // Stage the compressed backup in temp, then hand it to the share sheet.
        let staged = fm.temporaryDirectory.appendingPathComponent(defaultBackupName())
        do {
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            // Off the main actor: same reason as the macOS branch (heavy read + DEFLATE). Only paths hop.
            try await Task.detached(priority: .utility) {
                try writeVerifiedBackupZip(dbURL: dbURL, to: staged, settingsJSON: currentSettingsJSON())
            }.value
        } catch {
            return .failure(String(localized: "Export failed: \(error.localizedDescription)"))
        }
        guard let dest = await DocumentPicker.export(staged) else { return .cancelled }
        return .exported(dest)
        #endif
    }

    /// #1014 defence-in-depth (export side): the export's failure when the LIVE database itself is
    /// damaged. Thrown by `writeVerifiedBackupZip`; `LocalizedError` so the existing
    /// "Export failed: \(error.localizedDescription)" surfaces the specific, honest message.
    private struct ExportIntegrityFailure: LocalizedError {
        let complaint: String
        var errorDescription: String? {
            String(localized: "the NOOP database failed its integrity check (SQLite reports: \(complaint)). A backup of it would not restore. Export the WHOOP-format CSV (Settings → Export data) to save what's still readable.")
        }
    }

    /// The freshly-written `.noopbak` failed a post-write structural check — its DB entry is missing or
    /// truncated, i.e. a torn write from a full disk / dying filesystem / flaky cloud sync mid-write.
    /// Thrown by `writeVerifiedBackupZip` so a bad backup fails at WRITE time, not silently — the old
    /// behaviour let a truncated file sit as a "successful" snapshot and only surface at restore (#1014).
    private struct BackupWriteIncomplete: LocalizedError {
        var errorDescription: String? {
            String(localized: "the backup file was written incompletely (its database entry is missing or truncated). Free up space or check the backup folder, then try again.")
        }
    }

    /// The production export path: verify, then archive. GRDB checkpoints the WAL first (the
    /// callers' `checkpoint()` guard), so at this point the single file IS the whole store — run a
    /// read-only `PRAGMA quick_check` over it BEFORE zipping (#1014). Archiving an already-corrupt
    /// database writes a `.noopbak` that only fails the import-side integrity gate months later,
    /// when the original data may be long gone; failing loudly NOW is the honest move. The read-only
    /// probe sits safely beside the app's open GRDB pool (WAL allows concurrent readers).
    /// `writeBackupForTesting` deliberately bypasses this so tests can build damaged containers.
    private static func writeVerifiedBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?) throws {
        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
            throw ExportIntegrityFailure(complaint: complaint)
        }
        try writeBackupZip(dbURL: dbURL, to: dest, settingsJSON: settingsJSON)
        // #1014 (write-side): the SOURCE is verified above, but the PRODUCED file can still be torn by a
        // full disk / dying filesystem / flaky cloud-sync mid-write, and such a truncated `.noopbak`
        // otherwise "restores" into an empty store — caught only by the import-side quick_check much later.
        // Re-open the file we just wrote (a cheap central-directory read, no extraction — and a torn file
        // has no valid trailing central directory, so it won't even open) and confirm its DB entry is
        // present and non-empty (a SQLite header alone is 100 bytes). Fail HERE if not, and don't leave a
        // corrupt file behind masquerading as a good snapshot. Twin of the Android post-write check.
        guard let written = try? Archive(url: dest, accessMode: .read),
              let dbEntry = written.first(where: { ($0.path as NSString).lastPathComponent == backupEntryName }),
              dbEntry.uncompressedSize >= 100 else {
            try? FileManager.default.removeItem(at: dest)
            throw BackupWriteIncomplete()
        }
    }

    /// Write the live SQLite at `dbURL` into a fresh deflate ZIP at `dest`: the DB under the canonical
    /// entry name `noop-backup.sqlite`, plus (#1000) an optional second entry `settings.json` carrying
    /// the whitelisted profile/display settings, so a restore brings back weight/height/units and not
    /// just the rows. Entry names, entry ORDER (DB first — older importers stop at the first `.sqlite`
    /// entry) and deflate compression match the Android exporter byte-for-byte at the container level,
    /// so a `.noopbak` produced on either platform imports on the other. `settingsJSON == nil` writes
    /// the legacy single-entry ZIP. Mirrors the `Archive` idiom in `WhoopCsvExporter`.
    private static func writeBackupZip(dbURL: URL, to dest: URL, settingsJSON: Data?) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        try archive.addEntry(with: backupEntryName, fileURL: dbURL, compressionMethod: .deflate)
        guard let settingsJSON else { return }
        // Stage the JSON through a temp file so the settings entry uses the exact same file-URL
        // addEntry idiom as the DB entry (one container code path, no provider-API variant to drift).
        let fm = FileManager.default
        let tmpJSON = fm.temporaryDirectory
            .appendingPathComponent("noop-settings-\(UUID().uuidString).json")
        try settingsJSON.write(to: tmpJSON)
        defer { try? fm.removeItem(at: tmpJSON) }
        try archive.addEntry(with: BackupSettings.entryName, fileURL: tmpJSON, compressionMethod: .deflate)
    }

    /// This device's whitelisted profile/display settings (see `BackupSettings.whitelist`) as the
    /// `settings.json` payload, or nil when nothing whitelisted was ever set (a fresh install then
    /// exports a legacy DB-only ZIP, which is the right degrade). UserDefaults is thread-safe, so
    /// the detached export tasks may call this off the main actor.
    private static func currentSettingsJSON() -> Data? {
        var values = BackupSettings.snapshot(from: .standard)
        // #1361: bridge the user's custom journal BEHAVIOURS into the whitelisted `journal.customBehaviors`
        // as a newline-joined name list (byte-identical to Android's `noop.journalCustomQuestions`). The
        // journal EFFECTS ride the DB backup, but the DEFINITIONS live only here. `JournalCatalogStore`
        // is @MainActor and this may run off it, so decode the items blob directly and take the custom
        // canonicals. Skipped when there are none.
        if let blob = UserDefaults.standard.data(forKey: JournalCatalogBackupKeys.items),
           let items = try? JSONDecoder().decode([JournalCatalogItem].self, from: blob) {
            let customs = items.filter(\.custom).map(\.canonical)
            if !customs.isEmpty { values["journal.customBehaviors"] = customs.joined(separator: "\n") }
        }
        return BackupSettings.encode(values)
    }

    /// (Backup & Sync) Write a `.noopbak` to a SPECIFIC `dest` URL with NO save panel: the folder /
    /// auto-backup path. Checkpoints the WAL (so the single `.sqlite` is whole) then writes the same
    /// deflate ZIP via the same `writeBackupZip` the interactive export uses, so folder / auto backups
    /// are byte-identical to a manual export. The CALLER owns any security-scoped access to `dest`
    /// (start/stop around this call). Never presents UI, so it is safe off the main actor.
    static func writeBackup(checkpoint: @escaping () async -> Bool, to dest: URL) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(String(localized: "There's no NOOP data to export yet."))
        }
        // Flush the WAL into the single file (same requirement as the interactive export: a single-file
        // ZIP has no sidecar fallback, so committed pages still in the WAL would otherwise be absent).
        guard await checkpoint() else {
            return .failure(String(localized: "Couldn't safely back up right now. Recent changes are still in the write-ahead log."))
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try writeVerifiedBackupZip(dbURL: dbURL, to: dest, settingsJSON: currentSettingsJSON())
            return .exported(dest)
        } catch {
            return .failure(String(localized: "Backup failed: \(error.localizedDescription)"))
        }
    }

    /// Test seam: write a `.noopbak` for an EXPLICIT source database (no checkpoint, no `StorePaths`),
    /// so a unit test can round-trip a throwaway SQLite through the exact ZIP container the app writes.
    /// `settings` (canonical `BackupSettings` keys) adds the `settings.json` entry; nil writes the
    /// legacy single-entry ZIP — tests cover both shapes. Not used by app code; production goes
    /// through `writeBackup(checkpoint:to:)`.
    static func writeBackupForTesting(databaseAt dbURL: URL, to dest: URL,
                                      settings: [String: Any]? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try writeBackupZip(dbURL: dbURL, to: dest,
                           settingsJSON: settings.flatMap { BackupSettings.encode($0) })
    }

    // MARK: - Import

    /// Pick a `.noopbak` (ZIP) or legacy `.sqlite` backup, validate it, snapshot the current DB
    /// to a side file, then copy the backup over the live database path (removing the `-wal`/`-shm`
    /// siblings). The store stays open, so the swapped-in file only takes effect after a relaunch —
    /// the caller informs the user.
    @MainActor
    static func runImport() async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import NOOP backup")
        panel.prompt = String(localized: "Import")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = backupContentTypes()

        guard panel.runModal() == .OK, let pickedSource = panel.url else { return .cancelled }

        let scoped = pickedSource.startAccessingSecurityScopedResource()
        defer { if scoped { pickedSource.stopAccessingSecurityScopedResource() } }
        #else
        // iOS: pick the backup through the system document picker (asCopy gives us a readable local
        // copy in our temp dir, so no security-scoped bookkeeping is needed).
        guard let pickedSource = await DocumentPicker.importFile(backupContentTypes()) else { return .cancelled }
        #endif

        // Hand the chosen file to the same hardened restore core the folder (Backup & Sync) path uses,
        // so the unzip / magic-byte / GRDB-origin / sidecar-snapshot / rollback logic lives in one place.
        // The restore does heavy synchronous file work (unzip, copy the whole DB, scan sqlite_master,
        // snapshot + rollback), which can run tens of seconds on a big library. Push it off the main
        // actor so the picker's UI thread stays live; the security-scoped access opened above (macOS)
        // stays valid because the surrounding function is still awaiting here. Only Sendable value
        // types (URL, String) cross the hop; the result hops back to main for handleBackup.
        return await Task.detached(priority: .utility) {
            restore(from: pickedSource, toDatabaseAt: dbPath)
        }.value
    }

    /// Restore a chosen backup file directly, with NO picker. The Backup & Sync folder flow calls this
    /// with a snapshot it already resolved from the user's backup folder (the caller owns any
    /// security-scoped access around the call). Runs against the live database path.
    ///
    /// Reuses the exact same hardened path as the picker import: ZIP extraction, SQLite magic-byte
    /// validation, GRDB-origin rejection (a foreign-but-valid SQLite is refused), a timestamped
    /// sidecar snapshot of the current store, and rollback-on-failure so a failed restore leaves the
    /// live database untouched.
    static func restore(from pickedSource: URL) -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(String(localized: "Couldn't locate the NOOP database. \(error.localizedDescription)")) }
        return restore(from: pickedSource, toDatabaseAt: dbPath)
    }

    /// The hardened restore core, with the destination database path injected so it is unit-testable
    /// against a throwaway DB (real file I/O, never the user's live store). Behaviour is identical to
    /// the previous `runImport` body; only the picker and path-resolution moved out to the callers.
    /// `settingsDefaults` is where a `settings.json` entry (#1000) is re-applied — injected for the
    /// same reason as `dbPath` (tests use a suite-scoped UserDefaults, never the runner's real domain).
    static func restore(from pickedSource: URL, toDatabaseAt dbPath: String,
                        settingsDefaults: UserDefaults = .standard) -> BackupResult {
        // If the picked file is a .noopbak ZIP, extract the SQLite entry to a temp dir first.
        // Legacy plain-SQLite files fall straight through. The extracted dir is cleaned up below.
        let fm = FileManager.default
        let source: URL
        let extractedDir: URL?

        if isZipFile(at: pickedSource) {
            let tmpExtract = fm.temporaryDirectory
                .appendingPathComponent("noop-import-\(UUID().uuidString)", isDirectory: true)
            do {
                if fm.fileExists(atPath: tmpExtract.path) { try fm.removeItem(at: tmpExtract) }
                try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)
                try extractBackupZip(at: pickedSource, into: tmpExtract)
            } catch {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "Couldn't open the backup archive: \(error.localizedDescription)"))
            }
            guard let sqliteEntry = (try? fm.contentsOfDirectory(
                at: tmpExtract, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "sqlite" }) else {
                try? fm.removeItem(at: tmpExtract)
                return .failure(String(localized: "The backup archive doesn't contain a database file."))
            }
            source = sqliteEntry
            extractedDir = tmpExtract
        } else {
            source = pickedSource
            extractedDir = nil
        }
        defer { if let d = extractedDir { try? fm.removeItem(at: d) } }

        // Validate: must be a real SQLite database (magic header "SQLite format 3\0").
        guard isSQLiteFile(at: source) else {
            return .failure(String(localized: "That file isn't a NOOP backup. It doesn't look like a SQLite database."))
        }

        // Reject any backup that isn't a clean GRDB (this-app) backup. The magic check passes for ANY
        // SQLite file, so an Android (Room) backup — or any other SQLite file that happens to carry our
        // table names without our `grdb_migrations` bookkeeping — would otherwise replace the live DB
        // and leave the migrator re-running v1 forever (`table "device" already exists`, #222). A valid
        // NOOP-Mac/iOS backup always carries `grdb_migrations`; reject everything else that holds data.
        let backupTables = sqliteTableNames(at: source)
        let origin = backupOrigin(of: backupTables)
        let holdsData = backupTables.contains("device") || backupTables.contains("hrSample")
        if origin == .android || (origin == .unknown && holdsData) {
            return .failure(String(localized: "This isn't a NOOP backup from this app. It's missing the migration bookkeeping a NOOP backup carries (it looks like an Android backup or another app's database), and restoring it would strand your store. To move your history across platforms, export the WHOOP-format CSV on the other device (Settings → Export data) and import that here, or import your original WHOOP / Apple Health export."))
        }

        // #1014 defence-in-depth: both gates above read only the FIRST pages of the file — the
        // 16-byte magic and sqlite_master both survive a backup that was truncated mid-upload or
        // torn by a flaky drive/cloud sync, and such a file then "restores" into a store that
        // silently shows no data (the #1014 report; the #1000 settings code was exonerated, the
        // family needed armour). Run SQLite's own `PRAGMA quick_check` over the STAGED file,
        // read-only, BEFORE anything touches the live database, and refuse the swap honestly.
        // One carve-out: a legacy plain-SQLite file still travelling with its -wal/-shm siblings
        // (an uncheckpointed manual copy) skips THIS gate — a read-only probe can't recover someone
        // else's WAL (shm rebuild needs write access) and would refuse spuriously. Those rare files
        // are still verified by the post-swap check below, which runs on the landed main file
        // BEFORE the sidecars are laid down and rolls back automatically on failure.
        let legacySidecarsPresent = extractedDir == nil
            && (fm.fileExists(atPath: source.path + "-wal") || fm.fileExists(atPath: source.path + "-shm"))
        if !legacySidecarsPresent,
           let complaint = DatabaseIntegrity.quickCheckFailure(atPath: source.path) {
            return .failure(String(localized: "This backup file is damaged and can't be restored (SQLite reports: \(complaint)). Your current data was left untouched. Try an earlier backup file."))
        }

        let dbURL = URL(fileURLWithPath: dbPath)

        do {
            // Snapshot the current DB (+ sidecars) to a timestamped side file so the user can roll back.
            var sidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoop-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                if fm.fileExists(atPath: sidecar.path) { try fm.removeItem(at: sidecar) }
                try fm.copyItem(at: dbURL, to: sidecar)
            } else {
                // Nothing to preserve (fresh install); report a placeholder so the message reads sensibly.
                sidecar = dbURL
            }

            // Remove the live DB and its WAL/SHM siblings, then drop the backup in.
            removeIfPresent(dbURL)
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))

            do {
                try fm.copyItem(at: source, to: dbURL)
            } catch {
                // The live DB was just removed and the replacement didn't land. Roll back to the
                // snapshot so a failed import leaves the user's data exactly as it was, instead of a
                // fresh-empty DB on relaunch (mirrors the Android rollback). Clear any partial-copy
                // leftover first — copyItem fails if the destination exists, which would otherwise
                // block the restore.
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    removeIfPresent(dbURL)
                    try? fm.copyItem(at: sidecar, to: dbURL)
                }
                return .failure(String(localized: "Import failed. Your existing data was kept. \(error.localizedDescription)"))
            }

            // #1014 defence-in-depth, post-swap: re-verify the file that actually LANDED at the
            // live path with a second read-only quick_check. The staged file was verified above,
            // but the copy itself can tear — disk-full mid-copy, a dying filesystem, the device
            // sleeping — and the next launch would meet a corrupt store. Runs BEFORE any legacy
            // sidecars are laid down: a bare main file is always read-only verifiable, and WAL
            // frames carry their own checksums (SQLite validates them on the first real open), so
            // the sidecars don't need this gate. On failure, roll back to the snapshot
            // AUTOMATICALLY and say so; the snapshot file is kept either way (same policy as a
            // successful import: the user can always reach the pre-import bytes).
            if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: dbURL.path) {
                removeIfPresent(dbURL)
                if sidecar != dbURL, fm.fileExists(atPath: sidecar.path) {
                    try? fm.copyItem(at: sidecar, to: dbURL)
                    return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint)). Your previous data was rolled back automatically and is unchanged."))
                }
                // Fresh install: there was no previous store to preserve, so removing the damaged
                // file (done above) restores the exact pre-import state — an empty slate.
                return .failure(String(localized: "Import failed its post-restore integrity check (SQLite reports: \(complaint)). The damaged file was removed; there was no previous data to roll back."))
            }

            // Restore sidecars only for legacy plain-SQLite backups whose WAL wasn't
            // checkpointed at export. ZIP imports are always checkpointed; no sidecars expected.
            // Deliberately AFTER the post-swap integrity check (see above) — this is best-effort
            // (`try?` inside) and can't throw, so the rollback semantics are unchanged.
            if extractedDir == nil {
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-wal")
                restoreSidecar(from: source, toMainPath: dbPath, suffix: "-shm")
            }

            // #1000: re-apply the backup's whitelisted profile/display settings (weight, height, age,
            // sex, HR-max override, unit prefs) — but only NOW, after the DB swap landed. A failed or
            // rolled-back restore returns above and never touches settings. Legacy single-entry ZIPs
            // and plain-SQLite backups have no `settings.json` (extractedDir nil / entry absent) and
            // restore exactly as before — no settings, no error. A malformed settings entry degrades
            // to "fewer keys applied" inside BackupSettings.decode; it can never fail the restore.
            if let extractedDir {
                let settingsURL = extractedDir.appendingPathComponent(BackupSettings.entryName)
                if let data = try? Data(contentsOf: settingsURL) {
                    let decoded = BackupSettings.decode(data)
                    BackupSettings.apply(decoded, to: settingsDefaults)
                    // #1361: restore custom journal behaviours. `JournalCatalogStore` is @MainActor and
                    // this runs off it, so write the restored names to the legacy `journal.customQuestions`
                    // array, clear any stale hidden list, and drop the v2 items blob — on the relaunch a
                    // restore forces, the store's init migrates those names into fresh v2 items (the same
                    // path a pre-v2 install takes). Only when the backup carried them.
                    if let joined = decoded["journal.customBehaviors"] as? String {
                        let names = joined.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                        settingsDefaults.set(names, forKey: JournalCatalogBackupKeys.legacyCustom)
                        settingsDefaults.set([String](), forKey: JournalCatalogBackupKeys.legacyHidden)
                        settingsDefaults.removeObject(forKey: JournalCatalogBackupKeys.items)
                    }
                }
            }
            // #57 debug: record when a restore swapped the DB, so the export can correlate a restore with a
            // later write stall (a restore not followed by a relaunch is the #57 failure).
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "backup.lastRestoreAt")
            return .imported(sidecar: sidecar)
        } catch {
            return .failure(String(localized: "Import failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Helpers

    /// Canonical entry name for the SQLite inside a `.noopbak` ZIP. Matches the Android exporter so
    /// a backup produced on either platform restores on the other.
    private static let backupEntryName = "noop-backup.sqlite"

    private enum BackupArchiveError: LocalizedError {
        case entryTooLarge(String)

        var errorDescription: String? {
            switch self {
            case .entryTooLarge(let name):
                return "\(name) is too large to restore safely."
            }
        }
    }

    /// "NOOP-backup-2026-06-07.noopbak"
    private static func defaultBackupName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "NOOP-backup-\(f.string(from: Date())).noopbak"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// Content types accepted by the export/import panels. Includes the new `.noopbak` (ZIP),
    /// generic ZIP, and legacy `.sqlite` / `.database` types so older backups keep working.
    private static func backupContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let noopbak = UTType(filenameExtension: "noopbak") { types.append(noopbak) }
        types.append(.zip)
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        types.append(.database)
        types.append(.data)
        return types
    }

    /// Which platform produced a NOOP backup, judged by its migrator's bookkeeping table.
    enum BackupOrigin: Equatable { case mac, android, unknown }

    /// Pure classification over a backup's `sqlite_master` table names: GRDB (this app) writes
    /// `grdb_migrations`, Room (the Android app) writes `room_master_table`. `.unknown` (neither —
    /// an empty or pre-migration file) falls through to the normal import path, where the
    /// open-time migrator decides. Mirrors the Android `DataBackup.backupOriginOf`.
    static func backupOrigin(of tableNames: Set<String>) -> BackupOrigin {
        // This platform's marker wins on the (degenerate) both-present case: restoring here is the
        // less destructive read.
        if tableNames.contains("grdb_migrations") { return .mac }
        if tableNames.contains("room_master_table") { return .android }
        // Older Room layouts didn't carry `room_master_table`; treat the Room/AndroidX duo of
        // `android_metadata` + an internal `sqlite_sequence` as an Android backup too.
        if tableNames.contains("android_metadata") && tableNames.contains("sqlite_sequence") {
            return .android
        }
        return .unknown
    }

    /// Every table name in a SQLite file, opened READ-ONLY through the system SQLite so the probed
    /// file is never mutated. Returns an empty set on any failure — the caller treats that as
    /// `.unknown` and falls through to the existing behaviour.
    private static func sqliteTableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: c))
            }
        }
        return names
    }

    /// Read the first 4 bytes and check for the ZIP PK magic (`PK\x03\x04`).
    private static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    /// Extract only the canonical entries from a `.noopbak` ZIP at `zipURL` into `destDir`.
    /// Unknown files are ignored, and each accepted entry is streamed through an uncompressed-size cap
    /// before it lands on disk.
    private static func extractBackupZip(at zipURL: URL, into destDir: URL) throws {
        let archive = try Archive(url: zipURL, accessMode: .read)
        for entry in archive where entry.type == .file {
            let name = (entry.path as NSString).lastPathComponent
            let limit: Int64
            switch name {
            case backupEntryName:
                limit = maxBackupSQLiteBytes
            case BackupSettings.entryName:
                limit = maxBackupSettingsBytes
            default:
                continue
            }
            let out = destDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            var written: Int64 = 0
            _ = try archive.extract(entry) { data in
                let next = written + Int64(data.count)
                guard next <= limit else {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: out)
                    throw BackupArchiveError.entryTooLarge(name)
                }
                try handle.write(contentsOf: data)
                written = next
            }
        }
    }

    /// Read the first 16 bytes and check for the SQLite magic header.
    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        // "SQLite format 3" + NUL terminator.
        let magic: [UInt8] = Array("SQLite format 3".utf8) + [0x00]
        return Array(head) == magic
    }

    private static func removeIfPresent(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    /// Copy a legacy backup's `<source><suffix>` sidecar next to the live DB if it exists, so an
    /// old plain-SQLite backup whose WAL wasn't checkpointed at export restores its committed pages
    /// (SQLite folds them in on open). Not called for ZIP imports (those are always checkpointed).
    private static func restoreSidecar(from source: URL, toMainPath dbPath: String, suffix: String) {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: source.path + suffix)
        guard fm.fileExists(atPath: src.path) else { return }
        let dst = URL(fileURLWithPath: dbPath + suffix)
        if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
        try? fm.copyItem(at: src, to: dst)
    }
}
