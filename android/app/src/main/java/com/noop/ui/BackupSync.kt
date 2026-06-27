package com.noop.ui

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.data.DataBackup
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * Backup & Sync (Phase 1 — folder destination). Writes the full `.noopbak` snapshot (the existing
 * [DataBackup] format) into a user-chosen folder (a SAF tree), on demand and on a daily schedule.
 * Point that folder at your Google Drive / iCloud / Dropbox desktop-sync client and you get automatic
 * off-device backup with no in-app cloud account, no OAuth, no secrets — NOOP only writes a local file;
 * your sync client does the upload.
 *
 * DESIGN: a future Google-Drive destination slots in behind [Destination] (this is the FolderDestination
 * leg). Snapshots are timestamped + immutable; "restore" REPLACES the local DB (it's a whole-DB snapshot,
 * not a record merge — newest-wins), matching DataBackup. The pure filename helpers are unit-tested.
 */
object BackupSync {

    /** The two backup destinations Phase 1 is built to support (Drive lands in Phase 2). */
    enum class Destination { FOLDER /* , GOOGLE_DRIVE */ }

    private const val PREFIX = "noop-backup-"
    private const val SUFFIX = ".noopbak"
    const val MIME = "application/octet-stream"

    // ── Pure helpers (unit-tested) ──────────────────────────────────────────

    private fun fmt() = java.text.SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    /** Canonical snapshot filename for an instant: `noop-backup-YYYYMMDD-HHMMSS.noopbak` (UTC). */
    fun snapshotName(epochMs: Long): String = PREFIX + fmt().format(java.util.Date(epochMs)) + SUFFIX

    /** The UTC instant encoded in a snapshot filename, or null if [name] is not one of ours. */
    fun snapshotTimeMs(name: String): Long? {
        if (!name.startsWith(PREFIX) || !name.endsWith(SUFFIX)) return null
        val stamp = name.substring(PREFIX.length, name.length - SUFFIX.length)
        return runCatching { fmt().parse(stamp)?.time }.getOrNull()
    }

    fun isSnapshot(name: String): Boolean = snapshotTimeMs(name) != null

    /** Newest snapshot by encoded time among [names] (non-snapshots ignored), or null if none. */
    fun latestSnapshot(names: List<String>): String? =
        names.filter(::isSnapshot).maxByOrNull { snapshotTimeMs(it)!! }

    /** Snapshots to DELETE to keep only the [keep] newest (oldest-first). Empty when within budget. */
    fun snapshotsToPrune(names: List<String>, keep: Int): List<String> {
        val snaps = names.filter(::isSnapshot).sortedByDescending { snapshotTimeMs(it)!! }
        return if (snaps.size <= keep) emptyList() else snaps.drop(keep)
    }

    // ── Folder destination I/O (SAF tree via DocumentsContract — no extra dep) ───

    /** Create + write one snapshot into the chosen [treeUri]; returns the new file Uri, or null on failure. */
    fun writeSnapshot(context: Context, treeUri: Uri, nowMs: Long = System.currentTimeMillis()): Uri? {
        val resolver = context.contentResolver
        val parentDoc = DocumentsContract.buildDocumentUriUsingTree(
            treeUri, DocumentsContract.getTreeDocumentId(treeUri),
        )
        val fileUri = runCatching {
            DocumentsContract.createDocument(resolver, parentDoc, MIME, snapshotName(nowMs))
        }.getOrNull() ?: return null
        return runCatching { DataBackup.exportTo(context, fileUri); fileUri }.getOrNull()
    }

    /** Run one backup into the persisted folder, prune to [BackupSyncPrefs.keepCount], stamp last-backup. */
    fun backupNow(context: Context): Boolean {
        val treeUri = BackupSyncPrefs.treeUri(context) ?: return false
        val written = writeSnapshot(context, treeUri) ?: return false
        BackupSyncPrefs.setLastBackupMs(context, System.currentTimeMillis())
        prune(context, treeUri)
        return written != Uri.EMPTY
    }

    /** Best-effort retention: delete snapshots beyond keepCount. Listing failures are ignored. */
    private fun prune(context: Context, treeUri: Uri) {
        val keep = BackupSyncPrefs.keepCount(context)
        val children = runCatching { listSnapshotDocs(context, treeUri) }.getOrDefault(emptyList())
        val toDelete = snapshotsToPrune(children.map { it.first }, keep).toSet()
        for ((name, docUri) in children) {
            if (name in toDelete) runCatching { DocumentsContract.deleteDocument(context.contentResolver, docUri) }
        }
    }

    /** (name, documentUri) for every snapshot in the tree, newest-first. */
    fun listSnapshotDocs(context: Context, treeUri: Uri): List<Pair<String, Uri>> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri, DocumentsContract.getTreeDocumentId(treeUri),
        )
        val out = ArrayList<Pair<String, Uri>>()
        context.contentResolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0); val name = c.getString(1) ?: continue
                if (isSnapshot(name)) out.add(name to DocumentsContract.buildDocumentUriUsingTree(treeUri, id))
            }
        }
        return out.sortedByDescending { snapshotTimeMs(it.first)!! }
    }

    // ── Scheduling (WorkManager — survives reboot/app-kill, mirrors DebugExportScheduler) ──

    private const val WORK = "noop-backup-sync"

    fun reschedule(context: Context) {
        val wm = WorkManager.getInstance(context.applicationContext)
        if (!BackupSyncPrefs.autoEnabled(context) || BackupSyncPrefs.treeUri(context) == null) {
            wm.cancelUniqueWork(WORK); return
        }
        val req = PeriodicWorkRequestBuilder<BackupSyncWorker>(1, TimeUnit.DAYS).build()
        wm.enqueueUniquePeriodicWork(WORK, ExistingPeriodicWorkPolicy.KEEP, req)
    }
}

class BackupSyncWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        if (!BackupSyncPrefs.autoEnabled(applicationContext)) return Result.success()
        return if (BackupSync.backupNow(applicationContext)) Result.success() else Result.retry()
    }
}

/** Small SharedPreferences-backed store for the folder destination + schedule state. */
object BackupSyncPrefs {
    private const val FILE = "backup_sync"
    private fun p(c: Context) = c.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun treeUri(c: Context): Uri? = p(c).getString("tree_uri", null)?.let(Uri::parse)
    fun setTreeUri(c: Context, uri: Uri?) = p(c).edit().apply {
        if (uri == null) remove("tree_uri") else putString("tree_uri", uri.toString())
    }.apply()

    fun autoEnabled(c: Context): Boolean = p(c).getBoolean("auto", false)
    fun setAutoEnabled(c: Context, on: Boolean) = p(c).edit().putBoolean("auto", on).apply()

    fun lastBackupMs(c: Context): Long = p(c).getLong("last_ms", 0L)
    fun setLastBackupMs(c: Context, ms: Long) = p(c).edit().putLong("last_ms", ms).apply()

    fun keepCount(c: Context): Int = p(c).getInt("keep", 10)
    fun setKeepCount(c: Context, n: Int) = p(c).edit().putInt("keep", n.coerceIn(1, 100)).apply()
}
