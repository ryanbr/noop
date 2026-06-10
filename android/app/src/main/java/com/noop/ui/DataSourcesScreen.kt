package com.noop.ui

import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import com.noop.data.DataBackup
import com.noop.data.ImportSummary
import com.noop.ingest.AppleHealthImporter
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.HealthConnectWriter
import com.noop.ingest.WhoopCsvImporter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Data Sources — ports the macOS DataSourcesView (Strand/Screens/DataSourcesView.swift)
 * onto the locked Android component system (ScreenScaffold / NoopCard / StatePill /
 * Overline / NoopType / Palette).
 *
 * The macOS screen is built around "bring your history in once, then it's yours": three
 * source cards (WHOOP Export, Apple Health, Live BLE) plus on-device file import. On
 * Android the on-device store is a single Room/SQLite file, and the real, working
 * migration path is whole-store export/import via [DataBackup] (a SAF document the user
 * picks). So this screen keeps the macOS structure but maps each card to what Android
 * actually has:
 *
 *   - WHOOP data    — live counts of the cached "my-whoop" history, plus a working import
 *                     of a WHOOP .zip/.csv export (app.whoop.com → Data Management) via
 *                     [com.noop.ingest.WhoopCsvImporter].
 *   - Apple Health  — live counts of cached "apple-health" data, plus a working streaming
 *                     import of an Apple Health export.zip/export.xml via
 *                     [com.noop.ingest.AppleHealthImporter].
 *   - Health Connect— native Android import (steps/HR/HRV/sleep/SpO₂/weight/workouts) via
 *                     [com.noop.ingest.HealthConnectImporter], gated on runtime permission.
 *   - WHOOP Strap   — the live BLE bond/stream status, straight from the LiveState flow.
 *   - Backup        — Export / Import the whole on-device database through [DataBackup],
 *                     wired to ActivityResult document launchers.
 */
@Composable
fun DataSourcesScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val live by vm.live.collectAsStateWithLifecycle()
    val hcAutoSync by vm.hcAutoSync.collectAsStateWithLifecycle()
    val hcSyncHours by vm.hcSyncHours.collectAsStateWithLifecycle()
    val hcLastSync by vm.hcLastSync.collectAsStateWithLifecycle()
    val hcWriteback by vm.hcWriteback.collectAsStateWithLifecycle()

    // Cached-store counts, loaded once from the repo (newest data is fine to recount).
    var whoopDays by remember { mutableStateOf<Int?>(null) }
    var whoopWorkouts by remember { mutableStateOf<Int?>(null) }
    var whoopHasHr by remember { mutableStateOf(false) }
    var appleDays by remember { mutableStateOf<Int?>(null) }
    var appleWorkouts by remember { mutableStateOf<Int?>(null) }
    // Health Connect has its OWN source ("health-connect"), counted separately from an Apple Health
    // export so each card reflects its own data rather than both showing under Apple Health (issue #34).
    var hcDays by remember { mutableStateOf<Int?>(null) }
    var hcWorkouts by remember { mutableStateOf<Int?>(null) }

    LaunchedEffect(Unit) {
        val now = System.currentTimeMillis() / 1000
        whoopDays = vm.repo.days("my-whoop").size
        whoopWorkouts = vm.repo.workouts("my-whoop", 0L, now).size
        whoopHasHr = vm.repo.latestHrSampleTs("my-whoop") != null
        appleDays = vm.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        appleWorkouts = vm.repo.workouts("apple-health", 0L, now).size
        hcDays = vm.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31").size
        hcWorkouts = vm.repo.workouts("health-connect", 0L, now).size
    }

    // Whole-store backup: export to a user-created document; import from a picked one.
    var busy by remember { mutableStateOf(false) }
    var restartNeeded by remember { mutableStateOf(false) }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val message = withContext(Dispatchers.IO) {
                runCatching { DataBackup.exportTo(context, uri) }
                    .fold({ "Backup saved." }, { "Backup failed: ${it.message}" })
            }
            busy = false
            Toast.makeText(context, message, Toast.LENGTH_LONG).show()
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val result = withContext(Dispatchers.IO) { DataBackup.importFrom(context, uri) }
            busy = false
            when (result) {
                is DataBackup.ImportResult.NeedsRestart -> {
                    restartNeeded = true
                    Toast.makeText(
                        context,
                        "Imported. Fully close and reopen Strand to load it.",
                        Toast.LENGTH_LONG,
                    ).show()
                }
                is DataBackup.ImportResult.Failed ->
                    Toast.makeText(context, result.message, Toast.LENGTH_LONG).show()
            }
        }
    }

    suspend fun refreshCounts() {
        val nowS = System.currentTimeMillis() / 1000
        whoopDays = vm.repo.days("my-whoop").size
        whoopWorkouts = vm.repo.workouts("my-whoop", 0L, nowS).size
        whoopHasHr = vm.repo.latestHrSampleTs("my-whoop") != null
        appleDays = vm.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        appleWorkouts = vm.repo.workouts("apple-health", 0L, nowS).size
        hcDays = vm.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31").size
        hcWorkouts = vm.repo.workouts("health-connect", 0L, nowS).size
    }

    // Run an importer off the main thread, refresh the counts, then toast the result.
    fun runImport(block: suspend () -> ImportSummary) {
        busy = true
        scope.launch {
            val summary = withContext(Dispatchers.IO) {
                runCatching { block() }.getOrElse { ImportSummary.failure("Import", it.message ?: "failed") }
            }
            refreshCounts()
            busy = false
            Toast.makeText(context, summary.message, Toast.LENGTH_LONG).show()
        }
    }

    // SAF pickers — the importers auto-detect zip vs csv/xml from the file's content.
    val whoopImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { WhoopCsvImporter.importZip(context, uri, vm.repo) } }

    val appleImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { AppleHealthImporter.importExport(context, uri, vm.repo) } }

    // Health Connect permission request → import once granted.
    val hcPermissionLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        if (granted.containsAll(HealthConnectImporter.PERMISSIONS)) {
            runImport { HealthConnectImporter.import(context, vm.repo) }
        } else {
            Toast.makeText(context, "Health Connect access not granted.", Toast.LENGTH_LONG).show()
        }
    }

    val healthConnectAvailable = remember {
        HealthConnectImporter.sdkStatus(context) == HealthConnectClient.SDK_AVAILABLE
    }

    // Import directly if permissions already granted, otherwise request them first.
    fun startHealthConnect() {
        scope.launch {
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            if (granted.containsAll(HealthConnectImporter.PERMISSIONS)) {
                runImport { HealthConnectImporter.import(context, vm.repo) }
            } else {
                hcPermissionLauncher.launch(HealthConnectImporter.PERMISSIONS)
            }
        }
    }

    // Writeback (computed metrics → Health Connect): WRITE permissions, requested only when the
    // user opts in. Denial flips the toggle back off so the UI never claims it's writing.
    val hcWritePermissionLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        if (granted.containsAll(HealthConnectWriter.PERMISSIONS)) {
            vm.writebackHealthConnectNow()
        } else {
            vm.setHcWriteback(false)
            Toast.makeText(context, "Health Connect write access not granted.", Toast.LENGTH_LONG).show()
        }
    }

    // Write immediately if the write permissions are already granted, otherwise request them first.
    fun startWriteback() {
        scope.launch {
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            if (granted.containsAll(HealthConnectWriter.PERMISSIONS)) {
                vm.writebackHealthConnectNow()
            } else {
                // Also request exercise-session write perms so GPS workouts can write back too
                // (the metric-writeback gate above stays on PERMISSIONS; exercise writeback is
                // opt-in + non-fatal). v1.71.
                hcWritePermissionLauncher.launch(HealthConnectWriter.PERMISSIONS + HealthConnectWriter.EXERCISE_PERMISSIONS)
            }
        }
    }

    ScreenScaffold(
        title = "Data Sources",
        subtitle = "Everything stays on this phone. Bring your history in once, then it's yours.",
    ) {
        // --- WHOOP data (cached history) ---
        SourceCard(
            title = "WHOOP History",
            icon = Icons.Filled.MonitorHeart,
            subtitle = "Recovery, strain, sleep and workouts, stored locally. Import a full " +
                "WHOOP data export (.zip) from app.whoop.com → Data Management and it " +
                "backfills your whole history in about a minute. Working now on Android.",
        ) {
            StatePill(
                title = if (whoopHasHr) "Streaming locally" else "No samples yet",
                tone = if (whoopHasHr) StrandTone.Positive else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = whoopDays?.let { "$it days" } ?: "—",
                secondary = whoopWorkouts?.let { "$it workouts stored" } ?: "Counting…",
            )
            BackupButton(
                label = "Import WHOOP export (.zip)",
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { whoopImportLauncher.launch(arrayOf("*/*")) }
        }

        // --- Apple Health ---
        SourceCard(
            title = "Apple Health",
            icon = Icons.Filled.FavoriteBorder,
            subtitle = "Import HR, HRV, sleep, SpO₂ and steps from an Apple Health export. On " +
                "an iPhone: Health app → tap your photo → Export All Health Data, then " +
                "import the .zip here. Working now on Android.",
        ) {
            val hasApple = (appleDays ?: 0) > 0 || (appleWorkouts ?: 0) > 0
            StatePill(
                title = if (hasApple) "Imported" else "Nothing imported",
                tone = if (hasApple) StrandTone.Accent else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = appleDays?.let { "$it days" } ?: "—",
                secondary = appleWorkouts?.let { "$it workouts" } ?: "Counting…",
            )
            BackupButton(
                label = "Import Apple Health export…",
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { appleImportLauncher.launch(arrayOf("*/*")) }
        }

        // --- Health Connect (native Android health data) ---
        SourceCard(
            title = "Health Connect",
            icon = Icons.Filled.MonitorHeart,
            subtitle = "Pull steps, heart rate, HRV, sleep, SpO₂, weight and workouts straight from " +
                "Android's Health Connect — no file needed. On-device; it never overwrites richer " +
                "WHOOP data, and writes nothing unless you opt in to sharing back below.",
        ) {
            val hasHc = (hcDays ?: 0) > 0 || (hcWorkouts ?: 0) > 0
            if (hasHc) {
                StatePill(title = "Imported", tone = StrandTone.Accent, showsDot = true)
                CountLine(
                    primary = hcDays?.let { "$it days" } ?: "—",
                    secondary = hcWorkouts?.let { "$it workouts" } ?: "Counting…",
                )
            }
            if (healthConnectAvailable) {
                BackupButton(
                    label = "Import from Health Connect",
                    icon = Icons.Filled.FileUpload,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) { startHealthConnect() }

                // Auto-sync: pull new Health Connect data when you open NOOP, if it's been longer than
                // the chosen interval — no manual taps. On-open only (no background worker): it avoids a
                // sensitive background-health permission and is reliable, and opening the app is enough.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Auto-sync periodically", style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            "Re-pull new Health Connect data (e.g. Samsung Health → Health Connect) each " +
                                "time you open NOOP, if it's been longer than the interval below. " +
                                "Read-only; never overwrites strap data.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = hcAutoSync,
                        onCheckedChange = { on ->
                            vm.setHcAutoSync(on)
                            // Ensure permissions (and an immediate first sync) when turning it on.
                            if (on) startHealthConnect()
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Auto-sync Health Connect periodically"
                        },
                    )
                }
                if (hcAutoSync) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text("Every", style = NoopType.footnote, color = Palette.textSecondary)
                        SegmentedPillControl(
                            items = listOf(6, 12, 24),
                            selection = hcSyncHours,
                            label = { "${it}h" },
                            onSelect = { vm.setHcSyncHours(it) },
                        )
                    }
                    Text(
                        "Last sync: " + if (hcLastSync == 0L) "not yet"
                        else DateUtils.getRelativeTimeSpanString(hcLastSync).toString(),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }

                // Writeback: the inverse direction. Opt-in, default OFF, computed metrics only.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Share back to Health Connect", style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            "Write the nightly metrics NOOP computes from your strap (resting HR, " +
                                "HRV, SpO₂, respiratory rate) into Health Connect so other apps can " +
                                "use them. Only NOOP's own computed values — imported data is never " +
                                "echoed back.",
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                    Switch(
                        checked = hcWriteback,
                        onCheckedChange = { on ->
                            vm.setHcWriteback(on)
                            // Ensure write permissions (and an immediate first write) when turning on.
                            if (on) startWriteback()
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = Palette.surfaceBase,
                            checkedTrackColor = Palette.accent,
                            uncheckedThumbColor = Palette.textSecondary,
                            uncheckedTrackColor = Palette.surfaceInset,
                            uncheckedBorderColor = Palette.hairline,
                        ),
                        modifier = Modifier.semantics {
                            contentDescription = "Share computed metrics back to Health Connect"
                        },
                    )
                }
            } else {
                RoadmapNote("Health Connect isn't set up on this device — install it from Google Play, then return here to import.")
            }
        }

        // --- Live WHOOP strap over BLE ---
        SourceCard(
            title = "WHOOP Strap (Live BLE)",
            icon = Icons.Filled.Bluetooth,
            subtitle = "Pairs directly with your strap over Bluetooth — no WHOOP app, no cloud.",
        ) {
            val (label, tone) = when {
                live.bonded -> "Bonded — streaming." to StrandTone.Positive
                live.connected -> "Connected — pairing…" to StrandTone.Warning
                else -> "Not connected — open Live to pair." to StrandTone.Critical
            }
            StatePill(title = label, tone = tone, showsDot = true, pulsing = live.connected && !live.bonded)
        }

        // --- Whole-store backup (the real Android migration path) ---
        SourceCard(
            title = "Backup & Move",
            icon = Icons.Filled.FileDownload,
            subtitle = "Your whole history is one file on this phone. Export it to keep a copy " +
                "or move to a new phone, then import it there. Nothing leaves the device " +
                "except through the file you choose.",
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                BackupButton(
                    label = "Export…",
                    icon = Icons.Filled.FileDownload,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) { exportLauncher.launch("strand-backup.noopdb") }
                BackupButton(
                    label = "Import…",
                    icon = Icons.Filled.FileUpload,
                    enabled = !busy,
                    modifier = Modifier.weight(1f),
                ) { importLauncher.launch(arrayOf("*/*")) }
            }
            if (busy) {
                Text("Working…", style = NoopType.footnote, color = Palette.textTertiary)
            }
            if (restartNeeded) {
                Text(
                    "Import staged. Fully close and reopen Strand to load the new data.",
                    style = NoopType.subhead,
                    color = Palette.statusWarning,
                )
            }
        }
    }
}

// MARK: - Source card (mirrors the macOS private `card(...)` builder)

@Composable
private fun SourceCard(
    title: String,
    icon: ImageVector,
    subtitle: String,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 18.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(20.dp),
                )
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(subtitle, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

// MARK: - "N days · N workouts stored" footnote line (mirrors the macOS counts line)

@Composable
private fun CountLine(primary: String, secondary: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(primary, style = NoopType.captionNumber, color = Palette.textSecondary)
        Text("  ·  ", style = NoopType.footnote, color = Palette.textTertiary)
        Text(secondary, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

@Composable
private fun RoadmapNote(text: String) {
    Text(text, style = NoopType.footnote, color = Palette.textTertiary)
}

// MARK: - Backup action button (matches the accent fill used by CoachPrimaryButton)

@Composable
private fun BackupButton(
    label: String,
    icon: ImageVector,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    val tint = if (enabled) Palette.accent else Palette.accent.copy(alpha = Palette.disabledOpacity)
    Row(
        modifier = modifier
            .height(48.dp)
            .clip(shape)
            .background(Palette.accentMuted)
            .border(1.dp, tint.copy(alpha = 0.4f), shape)
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 14.dp)
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = NoopType.headline, color = tint)
    }
}
