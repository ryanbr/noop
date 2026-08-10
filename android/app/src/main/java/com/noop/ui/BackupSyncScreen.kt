package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.content.Intent
import android.net.Uri
import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.data.DataBackup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Backup & Sync (Phase 1 - folder). Apple mirror of `BackupSyncView`: pick a folder, turn on the
 * opt-in daily auto-backup, back up now, or restore. Snapshots are the existing `.noopbak` whole-DB
 * format ([DataBackup]). Point the folder at a Google Drive / Dropbox sync app for off-device backup
 * with no in-app cloud account.
 *
 * Must-fixes baked in here:
 *  1. Restore lists the snapshots in the CHOSEN folder (newest-first) and lets the user pick one,
 *     rather than re-prompting with an unrelated document picker. A tightened file fallback exists
 *     only for folders we can't enumerate / legacy files.
 *  2. An explicit in-app confirm dialog fires before any destructive restore call.
 *  3. The file-fallback picker is tightened off the all-files wildcard to the backup MIME types, and
 *     the live [DataBackup.importFrom] now also rejects a foreign-but-valid SQLite (Mac/GRDB or other-app DB).
 */
@Composable
fun BackupSyncScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var treeUri by remember { mutableStateOf(BackupSyncPrefs.treeUri(context)) }
    var auto by remember { mutableStateOf(BackupSyncPrefs.autoEnabled(context)) }
    var lastMs by remember { mutableStateOf(BackupSyncPrefs.lastBackupMs(context)) }
    var busy by remember { mutableStateOf(false) }
    // How many dated snapshots to keep; pruning deletes the oldest beyond this (BackupSync.snapshotsToPrune).
    var keep by remember { mutableStateOf(BackupSyncPrefs.keepCount(context)) }
    var keepMenu by remember { mutableStateOf(false) }
    // Time-of-day the daily backup runs (minutes since midnight); default 01:00, user-adjustable.
    var backupMinute by remember { mutableStateOf(BackupSyncPrefs.backupMinute(context)) }

    // Restore-from-folder sheet state: the listed snapshots, and the one pending confirmation.
    var snapshots by remember { mutableStateOf<List<BackupSync.SnapshotDoc>>(emptyList()) }
    var showSnapshotPicker by remember { mutableStateOf(false) }
    var pendingRestore by remember { mutableStateOf<Pair<String, Uri>?>(null) }

    // Runs the actual destructive restore for a chosen backup Uri, off the main thread.
    fun runRestore(uri: Uri) {
        busy = true
        scope.launch {
            val r = withContext(Dispatchers.IO) { DataBackup.importFrom(context, uri) }
            busy = false
            when (r) {
                is DataBackup.ImportResult.NeedsRestart -> {
                    // #57: the restore CLOSED and swapped the database file. The long-lived WhoopRepository +
                    // BLE client still hold a DAO on the OLD (now-closed) connection, so any strap sync would
                    // fail with "connection pool has been closed" — and, worse, empty/metadata history ENDs
                    // would still ack and trim the strap PAST records we can't store, discarding real history.
                    // Relaunching the process re-opens Room against the restored file. Do it automatically
                    // rather than trust the user to read a toast (which is exactly how #57 happened).
                    Toast.makeText(context, "Backup restored — restarting NOOP…", Toast.LENGTH_LONG).show()
                    // NonCancellable: this coroutine runs in the screen's scope, which is cancelled the
                    // instant the user navigates away. The restart is a data-safety guarantee (the DB is
                    // already swapped), so it must complete even if the composition leaves — otherwise the
                    // user could keep syncing into the closed DB, the very bug we're fixing.
                    withContext(NonCancellable) {
                        delay(800)   // let the toast render before the process dies
                        val ctx = context.applicationContext
                        ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
                            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                            ?.let { ctx.startActivity(it) }
                        Runtime.getRuntime().exit(0)
                    }
                }
                is DataBackup.ImportResult.Failed ->
                    Toast.makeText(context, r.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    val pickFolder = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
        BackupSyncPrefs.setTreeUri(context, uri)
        treeUri = uri
        runCatching { BackupSync.reschedule(context) }
    }

    // Must-fix #1 + #3: the FILE fallback is tightened to the backup MIME types (was `*/*`). Used only
    // when the chosen folder holds no snapshots, or to restore a one-off file from elsewhere. The chosen
    // file still passes through importFrom's full validation (magic + Room/GRDB-origin) and the same
    // confirm dialog before it overwrites anything.
    val pickRestoreFile = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        pendingRestore = "the selected file" to uri
    }

    LazyScreenScaffold(
        title = uiString(R.string.l10n_backup_sync_screen_backup_sync_81758ffa),
        subtitle = "Save a full backup to a folder you choose - point it at Google Drive / Dropbox for off-device sync.",
    ) {
        // 1 · Destination folder
        item {
            NoopCard(padding = 20.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(uiString(R.string.l10n_backup_sync_screen_backup_folder_2a33df93), style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        treeUri?.let { "Saving to: ${folderLabel(it)}" }
                            ?: "No folder chosen yet. Pick one your cloud app already syncs, or any local folder.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_tip_a_desktop_drive_dropbox_app_2eaff1e3) +
                            "folder a sync app (e.g. FolderSync / Autosync) keeps in your cloud.",
                        style = NoopType.caption, color = Palette.accent,
                    )
                    // #644: these .noopbak snapshots are a plain, unencrypted ZIP — pointing this folder
                    // at a cloud sync app (per the tip above) also uploads that readable file there.
                    // Say so plainly next to the folder picker, before anyone turns auto-backup on.
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Icon(
                            Icons.Filled.Warning,
                            contentDescription = null,
                            tint = Palette.statusWarning,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            uiString(R.string.l10n_backup_sync_screen_these_backups_are_unencrypted_too_if_53e70fe8),
                            style = NoopType.caption, color = Palette.statusWarning,
                        )
                    }
                    NoopButton(
                        text = if (treeUri == null) "Choose folder" else "Change folder",
                        leadingIcon = Icons.Filled.FolderOpen,
                        kind = NoopButtonKind.Secondary,
                        enabled = !busy,
                        onClick = { pickFolder.launch(null) },
                    )
                }
            }
        }

        // 2 · Auto-backup + back up now
        item {
            NoopCard(padding = 20.dp, tint = if (auto && treeUri != null) Palette.accent else null) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(uiString(R.string.l10n_backup_sync_screen_daily_auto_backup_e5627357), style = NoopType.body, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_backup_sync_screen_writes_a_fresh_dated_backup_to_bd964fc5) +
                                    "the latest $keep. Off by default - flip it on if you want it.",
                                style = NoopType.footnote, color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        Switch(
                            checked = auto,
                            enabled = treeUri != null && !busy,
                            onCheckedChange = {
                                auto = it
                                BackupSyncPrefs.setAutoEnabled(context, it)
                                runCatching { BackupSync.reschedule(context) }
                            },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Palette.surfaceBase,
                                checkedTrackColor = Palette.accent,
                                uncheckedThumbColor = Palette.textSecondary,
                                uncheckedTrackColor = Palette.surfaceInset,
                                uncheckedBorderColor = Palette.hairline,
                            ),
                        )
                    }
                    // Retention: how many dated snapshots to keep. Wired to the existing setKeepCount; the
                    // next backup (auto or "Back up now") prunes the oldest beyond this count.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(uiString(R.string.l10n_backup_sync_screen_keep_last_snapshots_cd5c9ea9), style = NoopType.body, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_backup_sync_screen_older_backups_beyond_this_many_are_00b7daa6) +
                                    "daily backups). For recovery: if data ever corrupts, grab the newest snapshot.",
                                style = NoopType.footnote, color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        Box {
                            TextButton(
                                enabled = treeUri != null && !busy,
                                onClick = { keepMenu = true },
                            ) {
                                Text(uiString(R.string.l10n_backup_sync_screen_keep_1addd33c, keep), style = NoopType.body, color = Palette.accent)
                            }
                            DropdownMenu(
                                expanded = keepMenu,
                                onDismissRequest = { keepMenu = false },
                            ) {
                                KEEP_OPTIONS.forEach { n ->
                                    DropdownMenuItem(
                                        text = {
                                            Text(
                                                uiString(R.string.l10n_backup_sync_screen_n_9e03569f, n),
                                                style = NoopType.body,
                                                color = if (n == keep) Palette.accent else Palette.textPrimary,
                                            )
                                        },
                                        onClick = {
                                            keep = n
                                            BackupSyncPrefs.setKeepCount(context, n)
                                            keepMenu = false
                                        },
                                    )
                                }
                            }
                        }
                    }
                    // Backup time-of-day. Picking a new time re-anchors the schedule immediately
                    // (BackupSync.applyTimeChange); WorkManager isn't exact so it's best-effort.
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(uiString(R.string.l10n_backup_sync_screen_backup_time_81557aaa), style = NoopType.body, color = Palette.textPrimary)
                            Text(
                                uiString(R.string.l10n_backup_sync_screen_roughly_when_the_daily_backup_runs_71de04e1),
                                style = NoopType.footnote, color = Palette.textTertiary,
                            )
                        }
                        Spacer(Modifier.width(16.dp))
                        TimeChip(
                            minutes = backupMinute,
                            accessibilityLabel = "Daily backup time",
                            onPicked = { m ->
                                backupMinute = m
                                BackupSyncPrefs.setBackupMinute(context, m)
                                runCatching { BackupSync.applyTimeChange(context) }
                            },
                        )
                    }
                    Text(
                        if (lastMs > 0L) {
                            "Last backup: ${DateUtils.getRelativeTimeSpanString(lastMs)}"
                        } else {
                            "No backup yet."
                        },
                        style = NoopType.caption, color = Palette.textTertiary,
                    )
                    // Auto is ON but the last SUCCESSFUL backup is stale — the daily catch-up isn't landing
                    // (a lost folder grant, or the app hasn't been opened in a while). backupNow only stamps
                    // lastMs on success, so this surfaces a silently-failing auto-backup instead of it being
                    // discovered only at restore.
                    if (auto && treeUri != null && lastMs > 0L &&
                        BackupSync.isBackupStale(lastMs, System.currentTimeMillis())
                    ) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Icon(
                                Icons.Filled.Warning,
                                contentDescription = null,
                                tint = Palette.statusWarning,
                                modifier = Modifier.size(16.dp),
                            )
                            Text(
                                uiString(R.string.l10n_backup_sync_screen_auto_backup_hasn_t_run_in_e3cd484e),
                                style = NoopType.caption, color = Palette.statusWarning,
                                // weight(1f) so the long warning wraps within the Row instead of overflowing
                                // the card on a narrow screen (parity with the iOS row's fixedSize wrap).
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                    NoopButton(
                        text = if (busy) "Working…" else "Back up now",
                        leadingIcon = Icons.Filled.CloudUpload,
                        fullWidth = true,
                        enabled = treeUri != null && !busy,
                        onClick = {
                            busy = true
                            scope.launch {
                                val ok = withContext(Dispatchers.IO) { BackupSync.backupNow(context) }
                                lastMs = BackupSyncPrefs.lastBackupMs(context)
                                busy = false
                                Toast.makeText(
                                    context,
                                    if (ok) {
                                        "Backed up to your folder."
                                    } else {
                                        "Backup failed - re-pick the folder and try again."
                                    },
                                    Toast.LENGTH_LONG,
                                ).show()
                            }
                        },
                    )
                }
            }
        }

        // 3 · Restore (must-fix #1: from the chosen folder, newest-first)
        item {
            NoopCard(padding = 20.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(uiString(R.string.l10n_backup_sync_screen_restore_3cbe6d6b), style = NoopType.headline, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_replace_this_device_s_data_with_b8679c51) +
                            "so back up first if unsure.",
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                    NoopButton(
                        text = uiString(R.string.l10n_backup_sync_screen_restore_from_a_backup_c28917c6),
                        leadingIcon = Icons.Filled.Restore,
                        kind = NoopButtonKind.Secondary,
                        enabled = !busy,
                        onClick = {
                            val tree = treeUri
                            if (tree == null) {
                                // No folder set: fall back to the tightened file picker.
                                pickRestoreFile.launch(RESTORE_MIME_TYPES)
                            } else {
                                scope.launch {
                                    val found = withContext(Dispatchers.IO) {
                                        runCatching { BackupSync.listSnapshotDocs(context, tree) }
                                            .getOrDefault(emptyList())
                                    }
                                    if (found.isEmpty()) {
                                        // Folder has no snapshots we wrote - point at a file instead.
                                        pickRestoreFile.launch(RESTORE_MIME_TYPES)
                                    } else {
                                        snapshots = found
                                        showSnapshotPicker = true
                                    }
                                }
                            }
                        },
                    )
                }
            }
        }
    }

    // Must-fix #1: the snapshot picker - the folder's backups, newest-first.
    if (showSnapshotPicker) {
        AlertDialog(
            onDismissRequest = { showSnapshotPicker = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(uiString(R.string.l10n_backup_sync_screen_choose_a_backup_2fbfb0d6), style = NoopType.title2, color = Palette.textPrimary)
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        uiString(R.string.l10n_backup_sync_screen_newest_first_restoring_replaces_this_device_97dbcd8b),
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                    snapshots.forEach { snap ->
                        // Label + confirmation come from the resolved timeMs carried through from
                        // listSnapshotDocs, so a hand-named / date-only backup still shows a friendly date
                        // (its file-modification date) instead of the raw filename - parity with Swift. Only
                        // when the date is genuinely unknown (timeMs == 0) do we fall back to the name.
                        val whenLabel = if (snap.timeMs > 0L) {
                            DateUtils.getRelativeTimeSpanString(snap.timeMs).toString()
                        } else {
                            snap.name
                        }
                        Text(
                            text = whenLabel,
                            style = NoopType.body,
                            color = Palette.textPrimary,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    showSnapshotPicker = false
                                    pendingRestore = if (snap.timeMs > 0L) {
                                        "the backup from $whenLabel"
                                    } else {
                                        snap.name
                                    } to snap.uri
                                }
                                .padding(vertical = 10.dp),
                        )
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { showSnapshotPicker = false }) {
                    Text(uiString(R.string.l10n_backup_sync_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }

    // Must-fix #2: explicit in-app confirm BEFORE any destructive restore call, on every restore path.
    pendingRestore?.let { (label, uri) ->
        AlertDialog(
            onDismissRequest = { pendingRestore = null },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(uiString(R.string.l10n_backup_sync_screen_replace_all_current_data_e9244799), style = NoopType.title2, color = Palette.textPrimary)
            },
            text = {
                Text(
                    uiString(R.string.l10n_backup_sync_screen_replace_all_current_data_with_label_b7799a16, label),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingRestore = null
                    runRestore(uri)
                }) {
                    Text(uiString(R.string.l10n_backup_sync_screen_replace_a7cf7b25), style = NoopType.body, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRestore = null }) {
                    Text(uiString(R.string.l10n_backup_sync_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

/**
 * Must-fix #3: the restore file fallback is tightened off the all-files wildcard to the backup
 * container MIME types: the .noopbak ZIP (octet-stream / zip) and a legacy plain SQLite. Anything that
 * slips through still meets importFrom's magic-byte + Room/GRDB-origin validation before it can touch
 * the live DB.
 */
/** Retention choices for the "Keep last snapshots" menu. Each snapshot is a dated .noopbak; the daily
 *  job keeps this many and prunes the oldest. Kept modest — a few days of rollback without hoarding. */
private val KEEP_OPTIONS = listOf(1, 3, 5, 7, 10, 14)

private val RESTORE_MIME_TYPES = arrayOf(
    "application/octet-stream",
    "application/zip",
    "application/x-sqlite3",
)

/** A short, human label for a SAF tree Uri (the part after the volume colon). */
private fun folderLabel(treeUri: Uri): String {
    val seg = treeUri.lastPathSegment ?: return "selected folder"
    return seg.substringAfterLast(':').ifBlank { seg }
}
