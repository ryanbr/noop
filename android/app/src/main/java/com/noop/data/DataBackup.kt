package com.noop.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.util.Log
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Whole-store EXPORT / IMPORT for device migration.
 *
 * NOOP keeps everything on-device in a single Room/SQLite file ([WhoopDatabase.DB_NAME]).
 * Moving to a new phone therefore means moving exactly that one file. There is no cloud,
 * no account, nothing leaves the device except through these two explicit, user-driven
 * file operations (a SAF document the user picks).
 *
 * Export: checkpoint the WAL into the main db file, then write a ZIP (the `.noopbak`
 * format) containing the SQLite file plus a small `settings.json` entry (#1000) with the
 * whitelisted profile/display settings (see [BackupSettingsCodec]), so a restore also
 * brings back weight/height/units and not just the rows. ZIP deflate typically reduces a
 * 100 MB+ SQLite backup to 10–20 MB — SQLite's page-aligned text data compresses very
 * well. The ZIP is a standard container: users can rename `.noopbak` → `.zip` and
 * extract the SQLite manually with any archive tool on any OS.
 *
 * Import: detect whether the picked file is a `.noopbak` ZIP (PK magic) or a legacy
 * plain `.sqlite` / `.noopdb` (SQLite magic) and handle both, so old backups keep
 * working. Validates the extracted/direct SQLite header, the backup's origin, AND its
 * structural integrity (`PRAGMA quick_check`, #1014) before touching the live DB.
 * Closes the live Room singleton, snapshots the current db, overwrites it with the
 * chosen one, drops the stale `-wal` / `-shm` sidecars, then re-verifies the landed
 * file and rolls back to the snapshot automatically if the copy tore (#1014). The
 * caller then instructs the user to restart the app so Room re-opens the new file fresh.
 */
object DataBackup {

    /** Entry name of the SQLite inside the `.noopbak` ZIP. */
    private const val ZIP_ENTRY_NAME = "noop-backup.sqlite"

    /** Entry name of the optional whitelisted-settings JSON (#1000). Matches the Apple exporter. */
    private const val SETTINGS_ENTRY_NAME = BackupSettingsCodec.ENTRY_NAME
    // #1410: a `manifest.json` entry recording which build produced this file (read only to classify, never
    // restored). Written LAST so older importers that stop at the first .sqlite entry are unaffected.
    private const val MANIFEST_ENTRY_NAME = BackupManifest.ENTRY_NAME

    private const val MAX_BACKUP_SQLITE_BYTES = 2_147_483_648L
    private const val MAX_BACKUP_SETTINGS_BYTES = 1_048_576L

    /** First 16 bytes of every SQLite 3 file: "SQLite format 3\0". */
    private val SQLITE_MAGIC: ByteArray =
        byteArrayOf(
            0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66,
            0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00,
        )

    /**
     * #1014 (write-side): cheaply confirm a JUST-WRITTEN `.noopbak` at [uri] is structurally intact — its
     * DB entry is present and begins with the SQLite magic header. A torn write (truncated ZIP / a
     * half-flushed SAF document on a full disk or flaky provider) otherwise leaves a `.noopbak` that
     * silently "restores" into an empty store, caught only by the import-side quick_check much later. Fail
     * HERE at write time instead. Twin of the Apple post-write check in `writeVerifiedBackupZip`.
     * Best-effort: any read/format error returns false (treated as not-intact).
     */
    fun isWrittenBackupIntact(context: Context, uri: Uri): Boolean = runCatching {
        context.contentResolver.openInputStream(uri)?.use { stream ->
            ZipInputStream(stream).use { zip ->
                var entry = zip.nextEntry
                while (entry != null) {
                    if (!entry.isDirectory && entry.name.substringAfterLast('/') == ZIP_ENTRY_NAME) {
                        val header = ByteArray(SQLITE_MAGIC.size)
                        var got = 0
                        while (got < header.size) {
                            val r = zip.read(header, got, header.size - got)
                            if (r < 0) break
                            got += r
                        }
                        return@runCatching got == header.size && header.contentEquals(SQLITE_MAGIC)
                    }
                    entry = zip.nextEntry
                }
                false
            }
        } ?: false
    }.getOrDefault(false)

    /** First 4 bytes of every ZIP file: "PK\x03\x04". */
    private val ZIP_MAGIC: ByteArray =
        byteArrayOf(0x50, 0x4B, 0x03, 0x04)

    /** Outcome of an [importFrom] call. On success the app must be restarted. */
    sealed interface ImportResult {
        /** The new database is in place; tell the user to relaunch NOOP. */
        data object NeedsRestart : ImportResult

        /** Import failed and the original database is untouched. */
        data class Failed(val message: String) : ImportResult
    }

    /**
     * Export the live database to [uri] as a compressed `.noopbak` (single-entry ZIP).
     *
     * Runs `PRAGMA wal_checkpoint(TRUNCATE)` first so the db file is fully consistent.
     * The ZIP uses deflate compression; typical reduction is 80–90% vs the raw SQLite.
     * Throws on failure so the caller can surface the message in a toast/snackbar.
     */
    @Throws(IOException::class)
    fun exportTo(context: Context, uri: Uri) {
        val appContext = context.applicationContext

        // Fold the WAL back into the main file so the snapshot is complete.
        val db = WhoopDatabase.get(appContext)
        db.query("PRAGMA wal_checkpoint(TRUNCATE)", null).use { cursor ->
            cursor.moveToFirst()
        }

        val dbFile = appContext.getDatabasePath(WhoopDatabase.DB_NAME)
        if (!dbFile.exists()) {
            throw IOException("No database to export yet.")
        }

        // #1014 defence-in-depth (export side): after the checkpoint the single file IS the whole
        // store — verify it BEFORE archiving. A backup of an already-corrupt database only fails
        // the import-side integrity gate months later, when the original data may be long gone;
        // failing loudly NOW is the honest move. Read-only probe, sits safely beside the open Room
        // connection (WAL allows concurrent readers). Twin of the Apple writeVerifiedBackupZip.
        sqliteQuickCheckFailure(dbFile)?.let { complaint ->
            throw IOException(
                "Couldn't export: the NOOP database failed its integrity check (SQLite reports: " +
                    "$complaint). A backup of it would not restore. Export the WHOOP-format CSV " +
                    "instead to save what's still readable."
            )
        }

        // #1000: the whitelisted profile/display settings ride along as a second entry so a restore
        // brings back weight/height/units, not just the rows. Null (nothing user-set) degrades to the
        // legacy single-entry ZIP. The DB entry stays FIRST — older importers stop at the first
        // `.sqlite` entry, so entry order is part of the cross-platform container contract.
        val settingsJson = BackupSettingsBridge.snapshotJson(appContext)
        // #1410: build provenance for this export — which build wrote the file.
        val manifestJson = BackupManifest.json(
            appVersion = com.noop.BuildConfig.VERSION_NAME,
            appBuild = com.noop.BuildConfig.VERSION_CODE.toString(),
            platform = "android",
            schemaVersion = WhoopDatabase.SCHEMA_VERSION,
            exportedAtMs = System.currentTimeMillis(),
        )

        val resolver = appContext.contentResolver
        val output = resolver.openOutputStream(uri)
            ?: throw IOException("Could not open the chosen file for writing.")
        output.use { out ->
            // #1014: copy the file while HOLDING Room's write transaction. In WAL mode the main
            // file is only rewritten by a checkpoint, and a checkpoint only runs on a commit — so
            // with the (single) write connection parked in an empty transaction for the duration
            // of the copy, no commit can land and the bytes we stream can't be torn mid-page by a
            // concurrent auto-checkpoint. Writers queue behind us and proceed after; readers are
            // unaffected. Anything committed after the checkpoint above lives in the new WAL and
            // is simply (consistently) absent from this snapshot, same as before.
            db.runInTransaction {
                ZipOutputStream(out).use { zip ->
                    zip.putNextEntry(ZipEntry(ZIP_ENTRY_NAME))
                    dbFile.inputStream().use { input -> input.copyTo(zip) }
                    zip.closeEntry()
                    if (settingsJson != null) {
                        zip.putNextEntry(ZipEntry(SETTINGS_ENTRY_NAME))
                        zip.write(settingsJson.toByteArray(Charsets.UTF_8))
                        zip.closeEntry()
                    }
                    zip.putNextEntry(ZipEntry(MANIFEST_ENTRY_NAME))
                    zip.write(manifestJson.toByteArray(Charsets.UTF_8))
                    zip.closeEntry()
                }
            }
        }
    }

    /**
     * Replace the live database with the backup at [uri].
     *
     * Accepts both the new `.noopbak` (ZIP) format and legacy plain `.sqlite`/`.noopdb`
     * files so older backups keep working after the format upgrade.
     *
     * On any error the current database is left exactly as it was. On success the caller
     * MUST instruct the user to fully restart the app.
     */
    fun importFrom(context: Context, uri: Uri): ImportResult {
        val appContext = context.applicationContext
        val resolver = appContext.contentResolver

        // 1. Peek at the first 16 bytes to distinguish ZIP from plain SQLite.
        val header = ByteArray(16)
        try {
            val read = resolver.openInputStream(uri)?.use { readFully(it, header) }
                ?: return ImportResult.Failed("Could not open the chosen file.")
            if (read < 4) return ImportResult.Failed("That file is not a NOOP backup.")
        } catch (e: IOException) {
            return ImportResult.Failed("Could not read the chosen file: ${e.message}")
        }

        // 2. If it's a ZIP (.noopbak), extract the SQLite entry to a temp file.
        //    If it's a plain SQLite (legacy), copy it to the same temp file.
        //    The container-staging step is factored into [stageBackupSqlite] (a pure file/stream
        //    function) so it can be exercised under real file I/O in unit tests without Room/Context.
        //    A `settings.json` entry (#1000) is staged alongside when present; the stale-delete first
        //    matters, or a leftover from an earlier import could masquerade as THIS backup's settings.
        val tempSqlite = File(appContext.cacheDir, "import-extract.sqlite")
        val tempSettings = File(appContext.cacheDir, "import-settings.json")
        tempSettings.delete()
        try {
            when (stageBackupSqlite(resolver.openInputStream(uri), header, tempSqlite, tempSettings)) {
                StageResult.OK -> Unit
                StageResult.CANNOT_OPEN -> return ImportResult.Failed("Could not open the chosen file.")
                StageResult.NO_DB_IN_ZIP -> {
                    tempSettings.delete()
                    return ImportResult.Failed("The backup archive doesn't contain a database file.")
                }
                StageResult.ENTRY_TOO_LARGE -> {
                    tempSqlite.delete()
                    tempSettings.delete()
                    return ImportResult.Failed("The backup archive is too large to restore safely.")
                }
                StageResult.NOT_A_BACKUP -> return ImportResult.Failed(
                    "That file is not a NOOP backup - it doesn't look like a .noopbak archive or a SQLite database."
                )
            }
        } catch (e: IOException) {
            tempSqlite.delete()
            tempSettings.delete()
            return ImportResult.Failed("Could not read the chosen file: ${e.message}")
        }

        // 3. Validate the extracted file is a real SQLite database (magic-byte check).
        if (!isValidSqliteHeader(tempSqlite)) {
            tempSqlite.delete()
            tempSettings.delete()
            return ImportResult.Failed("The backup archive doesn't contain a valid NOOP database.")
        }

        // 3b. Origin check (parity with the Apple side's GRDB-origin rejection). The SQLite magic
        //     passes for ANY SQLite file: a GRDB (Mac/iOS NOOP) backup or some other app's database
        //     would otherwise sail through and REPLACE the live Room store, stranding the user. Read
        //     the backup's table names READ-ONLY and reject anything that isn't a Room (this-app)
        //     backup but still holds real data. Empty/pre-migration files fall through to Room's
        //     open-time migrator, exactly as before.
        val backupTables = sqliteTableNames(tempSqlite)
        when (backupOriginOf(backupTables)) {
            BackupOrigin.MAC ->
                return rejectForeign(
                    tempSqlite,
                    tempSettings,
                    "This isn't a NOOP backup from this app. It looks like a backup from the Mac or " +
                        "iOS NOOP app (it carries that platform's migration bookkeeping). Restoring it here " +
                        "would strand your store. To move your history across platforms, export the " +
                        "WHOOP-format CSV on the other device (Settings → Export data) and import that here.",
                )
            BackupOrigin.UNKNOWN ->
                if (holdsData(backupTables)) {
                    return rejectForeign(
                        tempSqlite,
                        tempSettings,
                        "This isn't a NOOP backup from this app. It's missing the database bookkeeping a " +
                            "NOOP backup carries (it looks like another app's database). Restoring it would " +
                            "strand your store.",
                    )
                }
            BackupOrigin.ANDROID -> Unit // our own backup, proceed.
        }

        // 3c. #1014 defence-in-depth: gates 3 and 3b read only the FIRST pages of the file — the
        //     16-byte magic and sqlite_master both survive a backup that was truncated mid-upload or
        //     torn by a flaky drive/cloud client, and such a file then "restores" into a store that
        //     silently shows no data (the #1014 report; the #1000 settings code was exonerated, but
        //     the family needed armour). Run SQLite's own `PRAGMA quick_check` over the STAGED file,
        //     read-only, BEFORE the live DB is touched, and refuse the swap honestly. quick_check
        //     (not integrity_check) skips index-content verification so it stays fast on a 100 MB+
        //     library while still catching truncation and malformed pages. Twin of the Apple side's
        //     DatabaseIntegrity gate.
        sqliteQuickCheckFailure(tempSqlite)?.let { complaint ->
            tempSqlite.delete()
            tempSettings.delete()
            return ImportResult.Failed(
                "This backup file is damaged and can't be restored (SQLite reports: $complaint). " +
                    "Your current data is untouched. Try an earlier backup file."
            )
        }

        val dbFile = appContext.getDatabasePath(WhoopDatabase.DB_NAME)
        val walFile = File(dbFile.path + "-wal")
        val shmFile = File(dbFile.path + "-shm")
        val rollbackFile = File(dbFile.path + ".import-bak")

        // 4. Close the live Room singleton so the file handles are released.
        WhoopDatabase.close()

        // 5. Snapshot the current db so a failed copy can be rolled back.
        try {
            rollbackFile.delete()
            if (dbFile.exists()) dbFile.copyTo(rollbackFile, overwrite = true)
        } catch (e: IOException) {
            tempSqlite.delete()
            tempSettings.delete()
            return ImportResult.Failed("Could not back up the current data: ${e.message}")
        }

        // 6. Overwrite the db file with the extracted backup, then drop the stale sidecars.
        try {
            dbFile.parentFile?.mkdirs()
            tempSqlite.copyTo(dbFile, overwrite = true)
            walFile.delete()
            shmFile.delete()
        } catch (e: IOException) {
            runCatching { if (rollbackFile.exists()) rollbackFile.copyTo(dbFile, overwrite = true) }
            rollbackFile.delete()
            tempSqlite.delete()
            tempSettings.delete()
            return ImportResult.Failed("Import failed, your data is unchanged: ${e.message}")
        }

        // 6b. #1014 defence-in-depth, post-swap: re-verify the file that actually LANDED at the live
        //     path with a second read-only quick_check. The staged file was verified in 3c, but the
        //     copy itself can tear — disk-full mid-copy, a dying flash chip, the process killed at
        //     the wrong instant — and the next launch would meet a corrupt store (which, before the
        //     CorruptionPreservingOpenHelperFactory below, the platform would then silently DELETE).
        //     On failure, roll back to the `.import-bak` snapshot automatically and say so.
        sqliteQuickCheckFailure(dbFile)?.let { complaint ->
            tempSqlite.delete()
            tempSettings.delete()
            walFile.delete()
            shmFile.delete()
            val message: String
            if (rollbackFile.exists()) {
                if (runCatching { rollbackFile.copyTo(dbFile, overwrite = true) }.isSuccess) {
                    rollbackFile.delete()
                    message = "The backup failed its integrity check after the copy (SQLite reports: " +
                        "$complaint). Your previous data was rolled back automatically and is unchanged."
                } else {
                    // The roll-back copy itself failed: KEEP the snapshot on disk — it is now the
                    // only good copy of the user's data — and tell the user exactly where it is.
                    message = "The backup failed its integrity check after the copy (SQLite reports: " +
                        "$complaint), and rolling back also failed. Your previous data is preserved at " +
                        "${rollbackFile.name} next to the app's database."
                }
            } else {
                // Fresh install: nothing existed before the import, so removing the damaged file
                // returns to the exact pre-import (empty) state.
                dbFile.delete()
                message = "The backup failed its integrity check after the copy (SQLite reports: " +
                    "$complaint). There was no previous data to roll back."
            }
            return ImportResult.Failed(message)
        }

        // 7. #1000: re-apply the backup's whitelisted profile/display settings (weight, height, age,
        //    sex, HR-max override, unit prefs) — but only NOW, after the DB swap landed. Every failure
        //    path above returns without touching settings. Legacy single-entry backups staged no
        //    settings file and restore exactly as before; a malformed settings entry degrades to
        //    "fewer keys applied" inside the codec and can never fail the restore.
        if (tempSettings.exists()) {
            runCatching {
                BackupSettingsBridge.apply(appContext, tempSettings.readText(Charsets.UTF_8))
            }
            tempSettings.delete()
        }

        rollbackFile.delete()
        tempSqlite.delete()
        // #57 debug: record when a restore swapped the DB, so the export can correlate a restore with a
        // subsequent write stall (a restore that wasn't followed by a restart is exactly the #57 failure).
        runCatching {
            com.noop.ui.NoopPrefs.of(appContext).edit()
                .putLong("backup.lastRestoreAt", System.currentTimeMillis() / 1000L).apply()
        }
        return ImportResult.NeedsRestart
    }

    // ── Container staging (pure file/stream layer, unit-tested under real file I/O) ──────

    /** Outcome of [stageBackupSqlite]: the SQLite was staged, or why it wasn't. */
    enum class StageResult { OK, CANNOT_OPEN, NO_DB_IN_ZIP, NOT_A_BACKUP, ENTRY_TOO_LARGE }

    /**
     * Stage the SQLite payload of a backup into [dest], from an already-opened [input] stream whose
     * first bytes are [header]. Handles both the `.noopbak` ZIP (extract the `.sqlite` entry) and a
     * legacy plain SQLite (copy through). Closes [input]. Context-free + stream-driven so the unit
     * tests drive it with real `java.util.zip` archives and real files, exercising the exact extraction
     * the live import uses (no behaviour fork between test and production).
     *
     * When [settingsDest] is given, a `settings.json` entry (#1000) is ALSO staged there if the ZIP
     * carries one (either platform's exporter may have written it, in either entry order). Its absence
     * is not an error — every pre-#1000 backup is a single-entry ZIP — and it never affects the
     * returned [StageResult]: the DB is the payload that decides success.
     *
     * NOTE this does NOT validate the staged file's SQLite header or origin; [importFrom] does that
     * next, on the staged file. Keeping staging and validation separate keeps each pure-testable.
     */
    fun stageBackupSqlite(
        input: java.io.InputStream?,
        header: ByteArray,
        dest: File,
        settingsDest: File? = null,
    ): StageResult {
        if (input == null) return StageResult.CANNOT_OPEN
        input.use { stream ->
            when {
                header.startsWith(ZIP_MAGIC) -> {
                    var foundDb = false
                    var foundSettings = false
                    ZipInputStream(stream).use { zip ->
                        var entry = zip.nextEntry
                        while (entry != null) {
                            when {
                                !entry.isDirectory && !foundDb &&
                                    entry.name.substringAfterLast('/') == ZIP_ENTRY_NAME -> {
                                    FileOutputStream(dest).use { out ->
                                        if (!copyBounded(zip, out, MAX_BACKUP_SQLITE_BYTES)) {
                                            dest.delete()
                                            return StageResult.ENTRY_TOO_LARGE
                                        }
                                    }
                                    foundDb = true
                                }
                                !entry.isDirectory && !foundSettings && settingsDest != null &&
                                    entry.name.substringAfterLast('/') == SETTINGS_ENTRY_NAME -> {
                                    FileOutputStream(settingsDest).use { out ->
                                        if (!copyBounded(zip, out, MAX_BACKUP_SETTINGS_BYTES)) {
                                            settingsDest.delete()
                                            return StageResult.ENTRY_TOO_LARGE
                                        }
                                    }
                                    foundSettings = true
                                }
                            }
                            // Everything we could want is staged - stop reading the archive.
                            if (foundDb && (settingsDest == null || foundSettings)) break
                            entry = zip.nextEntry
                        }
                    }
                    return if (foundDb) StageResult.OK else StageResult.NO_DB_IN_ZIP
                }
                header.startsWith(SQLITE_MAGIC) -> {
                    FileOutputStream(dest).use { out ->
                        if (!copyBounded(stream, out, MAX_BACKUP_SQLITE_BYTES)) {
                            dest.delete()
                            return StageResult.ENTRY_TOO_LARGE
                        }
                    }
                    return StageResult.OK
                }
                else -> return StageResult.NOT_A_BACKUP
            }
        }
    }

    private fun copyBounded(input: java.io.InputStream, out: java.io.OutputStream, cap: Long): Boolean {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) return true
            if (total + read > cap) return false
            out.write(buffer, 0, read)
            total += read
        }
    }

    /** Write [dbFile]'s bytes into a deflate ZIP at [dest] (the `.noopbak` container), DB entry first,
     *  plus the optional `settings.json` entry (#1000) when [settingsJson] is non-null. Context-free
     *  twin of the stream the live [exportTo] writes, so tests round-trip a real archive of either
     *  shape (legacy single-entry when [settingsJson] is null). */
    @Throws(IOException::class)
    fun writeBackupZip(dbFile: File, dest: File, settingsJson: String? = null) {
        FileOutputStream(dest).use { out ->
            ZipOutputStream(out).use { zip ->
                zip.putNextEntry(ZipEntry(ZIP_ENTRY_NAME))
                dbFile.inputStream().use { input -> input.copyTo(zip) }
                zip.closeEntry()
                if (settingsJson != null) {
                    zip.putNextEntry(ZipEntry(SETTINGS_ENTRY_NAME))
                    zip.write(settingsJson.toByteArray(Charsets.UTF_8))
                    zip.closeEntry()
                }
            }
        }
    }

    /** True when [file] begins with the SQLite 3 magic. Pure; used by [importFrom] and the tests. */
    fun isValidSqliteHeader(file: File): Boolean {
        val buf = ByteArray(SQLITE_MAGIC.size)
        return runCatching {
            val read = file.inputStream().use { readFully(it, buf) }
            read >= SQLITE_MAGIC.size && buf.contentEquals(SQLITE_MAGIC)
        }.getOrDefault(false)
    }

    /** First [n] bytes of [file] (or fewer at EOF): the header peek the import does on the raw file. */
    fun peekHeader(file: File, n: Int = 16): ByteArray {
        val buf = ByteArray(n)
        val read = runCatching { file.inputStream().use { readFully(it, buf) } }.getOrDefault(0)
        return buf.copyOf(read)
    }

    /** Read up to [buffer].size bytes from [input], looping over short reads. Returns bytes read. */
    private fun readFully(input: java.io.InputStream, buffer: ByteArray): Int {
        var offset = 0
        while (offset < buffer.size) {
            val n = input.read(buffer, offset, buffer.size - offset)
            if (n < 0) break
            offset += n
        }
        return offset
    }

    /** True when [this] begins with every byte in [prefix]. */
    private fun ByteArray.startsWith(prefix: ByteArray): Boolean {
        if (size < prefix.size) return false
        return prefix.indices.all { this[it] == prefix[it] }
    }

    // ── Origin validation (parity with the Apple GRDB-origin rejection) ─────────

    /** Which platform produced a NOOP backup, judged by its migrator's bookkeeping table. */
    enum class BackupOrigin { MAC, ANDROID, UNKNOWN }

    /**
     * Pure classification over a backup's `sqlite_master` table names: Room (this app) writes
     * `room_master_table`; GRDB (the Mac/iOS app) writes `grdb_migrations`. `.UNKNOWN` (neither, an
     * empty or pre-migration file) falls through to the normal import path, where Room's open-time
     * migrator decides. Mirrors the Apple `DataBackup.backupOrigin(of:)` so both platforms agree
     * byte-for-byte on what a foreign backup is.
     *
     * This platform's marker wins on the (degenerate) both-present case: restoring our own store here
     * is the less destructive read.
     */
    fun backupOriginOf(tableNames: Set<String>): BackupOrigin {
        if (tableNames.contains("room_master_table")) return BackupOrigin.ANDROID
        if (tableNames.contains("grdb_migrations")) return BackupOrigin.MAC
        // Older Room layouts didn't carry `room_master_table`; treat the Room/AndroidX pairing of
        // `android_metadata` + `sqlite_sequence` as one of ours too (mirrors the Apple side, which
        // reads that same duo as Android).
        if (tableNames.contains("android_metadata") && tableNames.contains("sqlite_sequence")) {
            return BackupOrigin.ANDROID
        }
        return BackupOrigin.UNKNOWN
    }

    /**
     * Does this backup actually hold app data (vs an empty/fresh file)? True when it carries any
     * user-content table beyond the SQLite/Android housekeeping ones. An `.UNKNOWN` file with no
     * content is harmless to restore; one WITH content but no recognised bookkeeping is some other
     * app's database and is rejected.
     */
    fun holdsData(tableNames: Set<String>): Boolean {
        val housekeeping = setOf("android_metadata", "sqlite_sequence", "room_master_table", "grdb_migrations")
        return tableNames.any { it !in housekeeping && !it.startsWith("sqlite_") }
    }

    /** Every table name in [file], opened READ-ONLY so the probed file is never mutated. Empty on
     *  failure. Carries [PRESERVE_ON_CORRUPTION] (#1014): without an explicit handler the framework
     *  default would DELETE the staged file when the open reports SQLITE_NOTADB/CORRUPT. */
    private fun sqliteTableNames(file: File): Set<String> {
        val db = runCatching {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY, PRESERVE_ON_CORRUPTION)
        }.getOrNull() ?: return emptySet()
        return try {
            val names = LinkedHashSet<String>()
            db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'", null).use { c ->
                while (c.moveToNext()) c.getString(0)?.let(names::add)
            }
            names
        } catch (e: Exception) {
            emptySet()
        } finally {
            runCatching { db.close() }
        }
    }

    /** Delete the staged temp files and return a Failed result, keeping the live DB untouched. */
    private fun rejectForeign(tempSqlite: File, tempSettings: File, message: String): ImportResult {
        tempSqlite.delete()
        tempSettings.delete()
        return ImportResult.Failed(message)
    }

    // ── Integrity gate (#1014 defence-in-depth; twin of the Apple DatabaseIntegrity) ─────

    /**
     * Pure classification of the rows `PRAGMA quick_check` returned: null = healthy (the single
     * canonical "ok" row), otherwise the first complaint row VERBATIM — never a fabricated summary.
     * An EMPTY result set is a failure too: quick_check always answers, so silence means the query
     * was swallowed and the file must not be trusted. Mirrors the Apple side's
     * `DatabaseIntegrity.verdict(fromRows:)` byte-for-byte — the same golden vectors are pinned in
     * [DataBackupIntegrityTest] here and `DatabaseIntegrityTests` there, so both platforms agree on
     * what "healthy" means. Pure + public so the plain-JVM test can drive it without Robolectric.
     */
    fun quickCheckVerdict(rows: List<String>): String? {
        if (rows.size == 1 && rows[0].equals("ok", ignoreCase = true)) return null
        return rows.firstOrNull { !it.equals("ok", ignoreCase = true) }
            ?: "quick_check returned no verdict"
    }

    /**
     * A [android.database.DatabaseErrorHandler] that closes the handle and PRESERVES the file. The
     * framework default ([android.database.DefaultDatabaseErrorHandler]) DELETES the file it was
     * probing on SQLITE_CORRUPT/SQLITE_NOTADB — every `openDatabase` overload without an explicit
     * handler inherits that. For the integrity probes below that would be catastrophic: the export
     * probe opens the LIVE database, so a corrupt store would be silently destroyed by the very
     * check meant to protect it (#1014). Also used by the origin probe for the same reason.
     */
    private val PRESERVE_ON_CORRUPTION = android.database.DatabaseErrorHandler { dbObj ->
        runCatching { dbObj.close() }
    }

    /**
     * Run `PRAGMA quick_check(1)` on [file]. Returns null when the file is healthy, otherwise a
     * short human-readable complaint for the caller's honest failure message. `quick_check(1)`
     * stops at the first error, so a damaged 100 MB library still answers quickly.
     *
     * Opens READ-ONLY first (never mutates the probed file; sits safely beside an open Room
     * connection — WAL allows concurrent readers). If the read-only open itself fails, falls back
     * to a read-write open: pre-3.22 SQLite (API 26/27, minSdk 26) cannot read-only-open a
     * WAL-header file without an initialized `-shm`, which is exactly what a checkpointed staged
     * backup looks like — refusing those would break valid restores on Android 8.x. Every probed
     * file is ours to touch (the staged temp copy, the just-swapped live file, or the live store
     * the export is about to archive), and a read-write open only performs standard SQLite
     * recovery, never a content change. Both opens carry [PRESERVE_ON_CORRUPTION] so no probe can
     * ever delete what it probes.
     */
    private fun sqliteQuickCheckFailure(file: File): String? {
        val db = runCatching {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY, PRESERVE_ON_CORRUPTION)
        }.recoverCatching {
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE, PRESERVE_ON_CORRUPTION)
        }.getOrElse { return "could not open the database: ${it.message}" }
        return try {
            val rows = ArrayList<String>()
            db.rawQuery("PRAGMA quick_check(1)", null).use { c ->
                while (c.moveToNext()) c.getString(0)?.let(rows::add)
            }
            quickCheckVerdict(rows)
        } catch (e: Exception) {
            // The query failed outright (SQLITE_NOTADB on garbage behind a valid magic header,
            // a malformed page 1, …). That IS the verdict: the file is not a usable database.
            "quick_check failed: ${e.message}"
        } finally {
            runCatching { db.close() }
        }
    }
}

/**
 * #1014 defence-in-depth: a Room open-helper factory whose ONLY behavioural change is corruption
 * handling. The platform DEFAULT — androidx.sqlite routes SQLITE_CORRUPT to
 * [SupportSQLiteOpenHelper.Callback.onCorruption], whose base implementation mirrors Android's
 * `DefaultDatabaseErrorHandler` — silently DELETES the corrupt database file. For NOOP that means
 * permanently destroying already-acked strap history the strap will never re-send, without the user
 * ever seeing a byte of it. Confirmed absent in this app before #1014: nothing overrode
 * onCorruption, so the delete-on-corruption default applied.
 *
 * The factory wraps the stock [FrameworkSQLiteOpenHelperFactory] and delegates every lifecycle
 * callback (configure/create/migrate/open) to Room's real callback UNCHANGED, so migrations behave
 * exactly as before. Only `onCorruption` is replaced: it logs loudly, closes the handle, and moves
 * the corrupt file aside to a TIMESTAMPED `.corrupt.<epochMillis>` quarantine (best-effort), keeping
 * the newest [MAX_CORRUPT_QUARANTINES] and pruning older ones so a crash loop can't multiply 100 MB
 * files (#661). It never silently discards the newest corrupt copy — repeated corruption preserves
 * the latest (most recovery-worthy) data, not just the first. The trade-off is deliberate and matches
 * [WhoopDatabase]'s no-destructive-fallback doctrine: the app may then fail to open the store (the
 * user sees an error instead of a silently empty app), but the corrupt file survives for
 * backup/recovery instead of vanishing.
 *
 * `allowDataLossOnRecovery` is pinned FALSE for the same reason: androidx's recovery path deletes
 * the file when an open fails, which is exactly the destruction this factory exists to prevent.
 */
class CorruptionPreservingOpenHelperFactory(
    private val delegate: SupportSQLiteOpenHelper.Factory = FrameworkSQLiteOpenHelperFactory(),
) : SupportSQLiteOpenHelper.Factory {

    override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
        val preserving = SupportSQLiteOpenHelper.Configuration.builder(configuration.context)
            .name(configuration.name)
            .callback(PreservingCallback(configuration.callback))
            .noBackupDirectory(configuration.useNoBackupDirectory)
            .allowDataLossOnRecovery(false)
            .build()
        return delegate.create(preserving)
    }

    /** Delegates everything to Room's callback except the destructive corruption default. */
    private class PreservingCallback(
        private val roomCallback: SupportSQLiteOpenHelper.Callback,
    ) : SupportSQLiteOpenHelper.Callback(roomCallback.version) {
        override fun onConfigure(db: SupportSQLiteDatabase) = roomCallback.onConfigure(db)
        override fun onCreate(db: SupportSQLiteDatabase) = roomCallback.onCreate(db)
        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) =
            roomCallback.onUpgrade(db, oldVersion, newVersion)
        override fun onDowngrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) =
            roomCallback.onDowngrade(db, oldVersion, newVersion)
        override fun onOpen(db: SupportSQLiteDatabase) = roomCallback.onOpen(db)

        override fun onCorruption(db: SupportSQLiteDatabase) {
            // Do NOT call super — the base implementation DELETES the file outright (non-resendable strap
            // history gone without a trace). Instead QUARANTINE the corrupt file aside and let the store
            // recreate a fresh one, so the app OPENS instead of crash-looping on every launch. #1014
            // (wanxorg): 8.2.0 preserved the file but left it in place, so the very next open re-hit the
            // same corruption and the app crashed on startup until a reinstall. Moving the original out of
            // the way keeps the crash-recovery the platform default gives (next open finds no file → clean
            // rebuild) WITHOUT the silent data loss — the corrupt copy stays as `*.corrupt` for recovery.
            val path = runCatching { db.path }.getOrNull()
            Log.e(
                "WhoopDatabase",
                "SQLite reported corruption in $path — quarantining it to *.corrupt.<epoch> and recreating " +
                    "a fresh store. The corrupt copy is kept; restore from a backup to get your data back.",
            )
            runCatching { db.close() }
            if (path != null && path != ":memory:") {
                val original = File(path)
                if (original.exists()) {
                    // #661: quarantine under a TIMESTAMPED name and keep the newest few, instead of a
                    // single fixed `.corrupt` slot. The old single-slot logic kept the FIRST corrupt copy
                    // and deleted every later one — but a later corruption is a rebuilt store that has
                    // banked new non-resendable strap history since, so the copy it dropped was the most
                    // recovery-worthy. Keeping the newest N caps disk (a crash loop can't multiply files)
                    // AND preserves the latest data plus a couple of priors for diagnosing a recurring
                    // corruption path.
                    val dir = original.parentFile
                    val dbName = original.name
                    val existing = dir?.listFiles()?.map { it.name }
                        ?.filter {
                            it.startsWith("$dbName.corrupt.") &&
                                it.substringAfterLast(".corrupt.").toLongOrNull() != null
                        } ?: emptyList()
                    val plan = planCorruptQuarantine(dbName, existing, System.currentTimeMillis())
                    val preserved = File(dir, plan.quarantineName)
                    // Move (not copy) so the original is gone and the next open rebuilds clean; fall back
                    // to copy+delete if rename fails (e.g. across a storage boundary).
                    if (!runCatching { original.renameTo(preserved) }.getOrDefault(false)) {
                        // Cross-storage rename fallback. Copy best-effort (overwrite=true so a same-
                        // millisecond re-entry of the same corrupt lineage still lands), then drop the
                        // original EITHER WAY: leaving a corrupt file on the live path re-hits corruption
                        // and crash-loops the app on every launch (#1014). Preservation is best-effort.
                        runCatching { original.copyTo(preserved, overwrite = true) }
                        runCatching { original.delete() }
                    }
                    // Move the WAL/SHM sidecars ALONGSIDE the quarantine rather than deleting them: the WAL
                    // can hold the most recent un-checkpointed writes (the newest strap data). The move
                    // still clears the live path, so the fresh rebuild can't inherit a stale write-ahead log.
                    moveSidecarBesideQuarantine("$path-wal", "${preserved.path}-wal")
                    moveSidecarBesideQuarantine("$path-shm", "${preserved.path}-shm")
                    // Prune the oldest quarantines beyond the cap (+ their moved sidecars).
                    plan.evict.forEach { name ->
                        val stale = File(dir, name)
                        runCatching { stale.delete() }
                        runCatching { File("${stale.path}-wal").delete() }
                        runCatching { File("${stale.path}-shm").delete() }
                    }
                } else {
                    // No original to quarantine — clear any orphan sidecars so the fresh rebuild is clean.
                    runCatching { File("$path-wal").delete() }
                    runCatching { File("$path-shm").delete() }
                }
            }
        }
    }
}

/** #661: at most this many `.corrupt.<epoch>` quarantines survive (newest kept), bounding disk on a
 *  repeated-corruption crash loop while preserving the latest copies for recovery/diagnosis. */
internal const val MAX_CORRUPT_QUARANTINES = 3

internal data class CorruptQuarantinePlan(
    val quarantineName: String,
    val evict: List<String>,
)

/**
 * #661: name the new corrupt-DB quarantine (`<dbName>.corrupt.<epochMillis>`) and decide which OLD
 * quarantines to evict so at most [keep] survive (newest by embedded epoch). Pure / filesystem-free so
 * it is unit-tested directly. [existing] must already be filtered to `<dbName>.corrupt.<digits>` names.
 * The just-created quarantine is never evicted, even if [keep] is 0.
 */
internal fun planCorruptQuarantine(
    dbName: String,
    existing: List<String>,
    nowMillis: Long,
    keep: Int = MAX_CORRUPT_QUARANTINES,
): CorruptQuarantinePlan {
    val quarantineName = "$dbName.corrupt.$nowMillis"
    fun epochOf(name: String): Long = name.substringAfterLast(".corrupt.").toLongOrNull() ?: 0L
    val evict = (existing + quarantineName)
        .distinct()
        .sortedByDescending { epochOf(it) }
        .drop(keep.coerceAtLeast(0))
        .filter { it != quarantineName }
    return CorruptQuarantinePlan(quarantineName, evict)
}

/** Best-effort move of a WAL/SHM sidecar next to its quarantined DB (rename, else copy+delete). */
private fun moveSidecarBesideQuarantine(fromPath: String, toPath: String) {
    val src = File(fromPath)
    if (!src.exists()) return
    val dst = File(toPath)
    if (!runCatching { src.renameTo(dst) }.getOrDefault(false)) {
        // Best-effort preserve, then ALWAYS clear the live sidecar: a stale WAL left on the live path
        // can be applied to the freshly-rebuilt DB (WAL identity is salt-based only), re-injecting
        // corrupt pages. Keeping the rebuild clean wins over preserving an un-movable sidecar.
        runCatching { src.copyTo(dst, overwrite = true) }
        runCatching { src.delete() }
    }
}
