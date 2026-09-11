import Foundation
import GRDB

/// SQLite-level integrity verification for the backup/restore pipeline (#1014 defence-in-depth).
///
/// The `.noopbak` import already gates on the 16-byte SQLite magic and on the migrator's
/// bookkeeping table (`grdb_migrations` / `room_master_table`), but BOTH of those live in the first
/// pages of the file: a backup that was truncated mid-upload, torn by a dying SD card, or clipped by
/// a cloud-sync client still passes them — and then "restores" into a store that silently shows no
/// data, which is exactly the #1014 report (our #1000 settings code was exonerated; the file itself
/// was the suspect). The missing armour is SQLite's own verdict: `PRAGMA quick_check` walks the page
/// structure and catches malformed pages, truncation ("size is N pages but the header says M"), and
/// bad cell layouts. `quick_check` (not `integrity_check`) deliberately skips index-content
/// verification so it stays proportionate on a 100 MB+ library while still refusing every
/// structurally damaged file.
///
/// Lives in the package — not the app's `DataBackup` — for the same reason `BackupSettings` does:
/// the verdict is pure SQLite + string logic, so it is unit-testable headlessly
/// (`swift test --filter DatabaseIntegrityTests`) against real damaged files. The Android
/// `DataBackup.quickCheckVerdict` mirrors `verdict(fromRows:)` byte-for-byte on the same golden
/// vectors, so both platforms agree on what "healthy" means.
public enum DatabaseIntegrity {

    /// Run `PRAGMA quick_check(1)` over a READ-ONLY connection on the database at `path`.
    ///
    /// Returns `nil` when the file is healthy, otherwise SQLite's first complaint (or the open/query
    /// error) as a short human-readable string for the caller's honest failure message. Read-only by
    /// construction: the probed file — a staged backup, or the live store just after a swap — is
    /// never mutated, and a read-only connection can sit beside the app's open GRDB pool (WAL allows
    /// concurrent readers; a checkpointed backup file has no WAL at all).
    public static func quickCheckFailure(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return "no database file at that path"
        }
        func quickCheckRows(readonly: Bool) throws -> [String] {
            var config = Configuration()
            config.readonly = readonly
            let dbQueue = try DatabaseQueue(path: path, configuration: config)
            return try dbQueue.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check(1)") }
        }
        do {
            // Read-only first — never mutates the probed file, and sits safely beside the app's open pool.
            return verdict(fromRows: try quickCheckRows(readonly: true))
        } catch {
            // A checkpointed WAL backup keeps journal_mode=WAL in its header but ships WITHOUT its -wal/-shm
            // siblings, so a read-only open can't build the -shm and fails SQLITE_CANTOPEN (#18). Retry
            // read-write, which builds the -shm and reads it — the probed file is always ours (a staged temp
            // copy or the just-swapped file). Mirrors the Android probe's read-write fallback.
            do { return verdict(fromRows: try quickCheckRows(readonly: false)) }
            catch { return error.localizedDescription }
        }
    }

    /// Pure classification of the rows `PRAGMA quick_check` returned: `nil` = healthy (the single
    /// canonical `"ok"` row), otherwise the first complaint row verbatim — never a fabricated
    /// summary. An EMPTY result set is treated as a failure too: quick_check always answers, so
    /// silence means the query itself was swallowed and the file must not be trusted.
    /// Mirrored by Android's `DataBackup.quickCheckVerdict` on the same golden vectors.
    public static func verdict(fromRows rows: [String]) -> String? {
        if rows.count == 1, rows[0].lowercased() == "ok" { return nil }
        return rows.first { $0.lowercased() != "ok" } ?? "quick_check returned no verdict"
    }

    /// SQLite's banner line, which names the database being reported on and says nothing about what is
    /// wrong with it. quick_check emits it ahead of the real diagnosis, joined into the SAME row.
    private static func isBanner(_ line: String) -> Bool {
        line.hasPrefix("*** in database") && line.hasSuffix("***")
    }

    /// The part of a `verdict` worth showing a person, as one line.
    ///
    /// `verdict` is kept VERBATIM on purpose: it is the forensic value, and a reporter pasting it into
    /// an issue should paste what SQLite actually said rather than a summary of it. (It reaches no log
    /// today: the only copy is the one shown.) What SQLite says begins with a banner and a newline:
    ///
    ///     *** in database main ***
    ///     Page 5 is never used
    ///
    /// Rendered into a sentence, that spends the whole line on "*** in database main ***" and pushes the
    /// only informative half ("Page 5 is never used") out of sight. This drops the banner, joins what is
    /// left onto one line, and caps the length, so the detail a person sees is the diagnosis.
    ///
    /// Falls back to the raw verdict, newlines flattened, whenever stripping would leave nothing: a
    /// verdict made ENTIRELY of banner is still better shown than shown as an empty parenthesis.
    /// Mirrored by Android's `DataBackup.readableComplaint` on the same golden vectors.
    public static func readableComplaint(_ verdict: String, limit: Int = 140) -> String {
        let kept = verdict.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isBanner($0) }
        let joined = kept.isEmpty
            ? verdict.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            : kept.joined(separator: "; ")
        let cap = max(1, limit)
        guard joined.count > cap else { return joined }
        return String(joined.prefix(cap - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
