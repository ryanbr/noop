package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
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
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.PermissionController
import com.noop.data.DataBackup
import com.noop.data.DeviceStatus
import com.noop.data.ImportSummary
import com.noop.data.Metric
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.ingest.AppleHealthImporter
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.HealthConnectWriter
import com.noop.ingest.ActivityFileImporter
import com.noop.ingest.LiftingImporter
import com.noop.ingest.NutritionCsvImporter
import com.noop.ingest.XiaomiBandImporter
import com.noop.ingest.WhoopCsvImporter
import com.noop.ingest.WearableExportImporter
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
 *   - Nutrition CSV — daily calories / macros / body weight from a nutrition CSV
 *                     (MyFitnessPal, Cronometer, or any date+columns spreadsheet) via
 *                     [com.noop.ingest.NutritionCsvImporter], stored as metricSeries rows
 *                     under source "nutrition-csv".
 *   - WHOOP Strap   — the live BLE bond/stream status, straight from the LiveState flow.
 *   - Backup        — Export / Import the whole on-device database through [DataBackup],
 *                     wired to ActivityResult document launchers.
 */
@Composable
fun DataSourcesScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val live by vm.live.collectAsStateWithLifecycle()
    val hrBroadcast by vm.hrBroadcast.collectAsStateWithLifecycle()
    val hrBroadcastAdvertising by vm.hrBroadcastAdvertising.collectAsStateWithLifecycle()
    val hrBroadcastSubscribers by vm.hrBroadcastSubscribers.collectAsStateWithLifecycle()
    val hrBroadcastStatus by vm.hrBroadcastStatus.collectAsStateWithLifecycle()
    val hcAutoSync by vm.hcAutoSync.collectAsStateWithLifecycle()
    val hcSyncHours by vm.hcSyncHours.collectAsStateWithLifecycle()
    val hcLastSync by vm.hcLastSync.collectAsStateWithLifecycle()
    val hcWriteback by vm.hcWriteback.collectAsStateWithLifecycle()
    val hcWbStatus by vm.hcWritebackStatus.collectAsStateWithLifecycle()
    // A background (BLE-path) writeback updates prefs, not the VM's flow — re-read on entry so the
    // status line reflects the latest attempt whenever this screen is opened (#660).
    LaunchedEffect(Unit) { vm.refreshHcWritebackStatus() }

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
    // Nutrition CSV writes long-format metricSeries rows under its own source ("nutrition-csv"),
    // so its card counts days-with-calories and weigh-ins straight off that table.
    var nutritionDays by remember { mutableStateOf<Int?>(null) }
    var nutritionWeighIns by remember { mutableStateOf<Int?>(null) }
    // Imported lifting (Hevy / Liftosaur) writes workouts under its own source ("lifting").
    var liftingWorkouts by remember { mutableStateOf<Int?>(null) }
    // Imported workout files (GPX / TCX / FIT) write workouts under their own source ("activity-file").
    var activityFiles by remember { mutableStateOf<Int?>(null) }
    var xiaomiDays by remember { mutableStateOf<Int?>(null) }
    // Imported Oura / Fitbit / Garmin exports write daily metrics under their own per-brand source.
    var wearableDays by remember { mutableStateOf<Int?>(null) }

    // Count-badge refresh, shared by the initial load below and every importer's post-run refresh.
    // PERF: scalar SQL COUNTs (and one LIMIT-1 existence probe), NOT materialized row lists — the old
    // shape loaded every row of every source's history just to call `.size` on it, ~14 full-range
    // reads per screen visit. Workout counts are now exact (the row read was capped at DEFAULT_LIMIT).
    suspend fun refreshCounts() {
        val nowS = System.currentTimeMillis() / 1000
        whoopDays = vm.repo.daysCount("my-whoop")
        whoopWorkouts = vm.repo.workoutsCount("my-whoop", 0L, nowS)
        whoopHasHr = vm.repo.latestHrSampleTs("my-whoop") != null
        appleDays = vm.repo.appleDailyCount("apple-health", "0000-01-01", "9999-12-31")
        appleWorkouts = vm.repo.workoutsCount("apple-health", 0L, nowS)
        hcDays = vm.repo.appleDailyCount("health-connect", "0000-01-01", "9999-12-31")
        hcWorkouts = vm.repo.workoutsCount("health-connect", 0L, nowS)
        nutritionDays = vm.repo.metricSeriesKeyCount(NutritionCsvImporter.SOURCE_ID, "calories_in")
        nutritionWeighIns = vm.repo.metricSeriesKeyCount(NutritionCsvImporter.SOURCE_ID, "weight")
        liftingWorkouts = vm.repo.workoutsCount(LiftingImporter.SOURCE_ID, 0L, nowS)
        activityFiles = vm.repo.workoutsCount(ActivityFileImporter.SOURCE_ID, 0L, nowS)
        xiaomiDays = vm.repo.metricSeriesKeyCount(XiaomiBandImporter.DEFAULT_DEVICE_ID, "steps")
        wearableDays = WearableExportImporter.Brand.values().sumOf {
            vm.repo.metricSeriesKeyCount(it.sourceId, "rhr") +
                vm.repo.metricSeriesKeyCount(it.sourceId, "sleep_total_min")
        }
    }

    LaunchedEffect(Unit) { refreshCounts() }

    // Busy flag shared by every importer's Export/Import buttons.
    var busy by remember { mutableStateOf(false) }
    // ah-delete (#616): drives the "Remove Apple Health imported data" confirm dialog.
    var confirmDeleteApple by remember { mutableStateOf(false) }

    // Run an importer off the main thread, refresh the counts, then toast the result.
    fun runImport(block: suspend () -> ImportSummary) {
        busy = true
        scope.launch {
            val summary = withContext(Dispatchers.IO) {
                runCatching { block() }.getOrElse { ImportSummary.failure("Import", it.message ?: "failed") }
            }
            // Mirror the import into the SAME exported strap log the WHOOP path uses (issue #421 parity),
            // so a tester's file import is captured in a shared debug bundle. On success: brand label +
            // per-table COUNTS only (e.g. "dailyMetric=120, sleepSession=88"). On a zero-row/failed import:
            // the brand label + the human reason from the summary. Never a file name, a path, or any health
            // value. Prefixed "Import: " so it's distinguishable from WHOOP / generic-HR lines. The Swift
            // twin logs the same in DataSourcesView's import handlers.
            if (summary.totalRows > 0) {
                val countsText = summary.counts.entries.joinToString(", ") { "${it.key}=${it.value}" }
                vm.ble.externalLog("Import ${summary.source}: $countsText")
            } else {
                vm.ble.externalLog("Import ${summary.source} failed: ${summary.message}")
            }
            // Import & Data Ingest test mode (Test Centre): emit the parser / per-stage / day-delta trace,
            // tagged IMPORT, iff the mode is on. Gated zero-cost when off (one SharedPreferences bool read).
            // The numbers are the SAME per-table counts the summary carries (Room upserts are fire-and-forget,
            // so the persisted count equals the mapped count at this seam); emission changes nothing saved. No
            // file name, path, or health value is in any line. Twin of the macOS DataSourcesView handlers.
            emitImportTrace(context, vm, summary)
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

    val xiaomiImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { XiaomiBandImporter.importExport(context, uri, vm.repo) } }

    val nutritionImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { NutritionCsvImporter.importCsv(context, uri, vm.repo) } }

    // Lifting: imported workouts also need the Workouts list to reload (runImport only re-counts).
    val liftingImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) runImport {
            LiftingImporter.importExport(context, uri, vm.repo).also { vm.loadWorkouts() }
        }
    }

    // Oura / Fitbit / Garmin own-data export: daily metrics + sleep sessions under the brand's source.
    val wearableImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri -> if (uri != null) runImport { WearableExportImporter.importExport(context, uri, vm.repo) } }

    // Workout file (GPX / TCX / FIT): one imported activity → one workout; reload the Workouts list too.
    val activityFileImportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) runImport {
            ActivityFileImporter.importExport(context, uri, vm.repo).also { summary ->
                vm.loadWorkouts()
                // #137 (B1): on a SUCCESSFUL import, register `activity-file` as an `activityFile` device
                // so the per-day owner resolver can pick it as the day owner on a strap-less day (it
                // iterates the registry's paired devices — an unregistered source is invisible to it). The
                // distinct kind ranks it at priority 3 — below whole-day imports (2) — so a full-day WHOOP
                // import always wins a day it has HR for. status `paired`, NEVER `active` (makeActive =
                // false), so it can never displace the live strap; capability `hr` marks what the source
                // CAN provide (per-day presence is still gated by an actual HR read in the resolver).
                // Idempotent (OnConflict.REPLACE). Twin of the Swift DataSourcesView `model.registerDevice`
                // call. See ActivityFileImporter (A) for the matching per-sample HR persist.
                if (summary.totalRows > 0) {
                    val now = System.currentTimeMillis() / 1000
                    vm.registerDevice(
                        PairedDeviceRow(
                            id = ActivityFileImporter.SOURCE_ID,
                            brand = "Workout files",
                            model = "",
                            nickname = null,
                            peripheralId = null,
                            sourceKind = SourceKind.activityFile.name,
                            capabilities = Metric.hr.name,
                            status = DeviceStatus.paired.name,
                            addedAt = now,
                            lastSeenAt = now,
                        ),
                        makeActive = false,
                    )
                }
            }
        }
    }

    // Health Connect permission request → import once granted.
    val hcPermissionLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        if (granted.any { it in HealthConnectImporter.PERMISSIONS }) {
            runImport { HealthConnectImporter.import(context, vm.repo, ProfileStore.from(context).heightCm) }
        } else {
            Toast.makeText(context, "Health Connect access not granted.", Toast.LENGTH_LONG).show()
        }
    }

    val healthConnectAvailable = remember {
        HealthConnectImporter.sdkStatus(context) == HealthConnectClient.SDK_AVAILABLE
    }

    // "Broadcast heart rate": flip the toggle on only AFTER the BLUETOOTH_ADVERTISE (+ CONNECT) runtime
    // permission is granted on Android 12+ — otherwise advertising silently no-ops. On grant (or pre-12,
    // where it's install-time) the VM starts the HR peripheral.
    val requestAdvertise = rememberRequestAdvertise(onGranted = { vm.setHrBroadcast(true) })

    // Import directly if permissions already granted, otherwise request them first.
    fun startHealthConnect() {
        scope.launch {
            val granted = runCatching {
                HealthConnectImporter.client(context).permissionController.getGrantedPermissions()
            }.getOrDefault(emptySet())
            // `any` (not `all`) is deliberate — partial grants are supported (#150). But that alone
            // would never ASK about a permission added in an update, so a newly-read type would come
            // back empty forever (#949). Route through the request once when the set has grown.
            if (granted.any { it in HealthConnectImporter.PERMISSIONS } &&
                !HealthConnectImporter.hasUnaskedPermissions(context)
            ) {
                runImport { HealthConnectImporter.import(context, vm.repo, ProfileStore.from(context).heightCm) }
            } else {
                HealthConnectImporter.markPermissionsAsked(context)
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
            // Gate on vitals AND exercise perms so a user who enabled writeback before exercise
            // writeback shipped (vitals-only grant) still gets re-prompted for WRITE_EXERCISE/
            // WRITE_DISTANCE — otherwise their workouts silently never reach Health Connect (#412).
            if (granted.containsAll(HealthConnectWriter.PERMISSIONS + HealthConnectWriter.EXERCISE_PERMISSIONS)) {
                vm.writebackHealthConnectNow()
            } else {
                // Request vitals + exercise-session write perms together so GPS workouts can write
                // back too (the launcher-result handler stays keyed on the vital PERMISSIONS, so
                // exercise writeback is opt-in + non-fatal if the user declines it). v1.71 / #412.
                hcWritePermissionLauncher.launch(HealthConnectWriter.PERMISSIONS + HealthConnectWriter.EXERCISE_PERMISSIONS)
            }
        }
    }

    // PERF (#707): lazy scaffold — each SourceCard is an unconditional top-level child, so each becomes one
    // `item { }` in the same order. There are no standalone Spacers (the eager column relied on
    // `spacedBy(20.dp)`, which the LazyColumn reproduces), so spacing is byte-identical. Only the on-screen
    // cards now compose + get accessibility-walked on scroll — this list of 11 source cards is long. The
    // confirm dialogs below the scaffold are untouched.
    LazyScreenScaffold(
        title = uiString(R.string.l10n_data_sources_screen_data_sources_5e43d6bb),
        subtitle = "Everything stays on this phone. Bring your history in once, then it's yours.",
    ) {
        // --- WHOOP data (cached history) ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_whoop_history_db101974),
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
                label = uiString(R.string.l10n_data_sources_screen_import_whoop_export_zip_16f4176b),
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { whoopImportLauncher.launch(arrayOf("*/*")) }
        }
        }

        // --- Apple Health ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_apple_health_b19b87da),
            icon = Icons.Filled.FavoriteBorder,
            tint = Palette.metricCyan,
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
                label = uiString(R.string.l10n_data_sources_screen_import_apple_health_export_533fca27),
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                tint = Palette.metricCyan,
                modifier = Modifier.fillMaxWidth(),
            ) { appleImportLauncher.launch(arrayOf("*/*")) }
            // ah-delete (#616): a destructive "Remove imported data" action wired to
            // DeviceRegistry.deleteDeviceData("apple-health") (via vm.deletePairedDeviceData), mirroring
            // the Swift card. Shown only once there's something to remove; a confirm dialog gates it.
            if (hasApple) {
                BackupButton(
                    label = uiString(R.string.l10n_data_sources_screen_remove_imported_data_813e4695),
                    icon = Icons.Filled.DeleteOutline,
                    enabled = !busy,
                    tint = Palette.statusCritical,
                    modifier = Modifier.fillMaxWidth(),
                ) { confirmDeleteApple = true }
            }
        }
        }

        // --- Health Connect (native Android health data) ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_health_connect_be6bca3e),
            icon = Icons.Filled.MonitorHeart,
            subtitle = "Pull steps, heart rate, HRV, sleep, SpO₂, weight and workouts straight from " +
                "Android's Health Connect. No file needed. On-device; it never overwrites richer " +
                "WHOOP data, and writes nothing unless you opt in to sharing back below.",
        ) {
            val hasHc = (hcDays ?: 0) > 0 || (hcWorkouts ?: 0) > 0
            if (hasHc) {
                StatePill(title = uiString(R.string.l10n_data_sources_screen_imported_434eb26f), tone = StrandTone.Accent, showsDot = true)
                CountLine(
                    primary = hcDays?.let { "$it days" } ?: "—",
                    secondary = hcWorkouts?.let { "$it workouts" } ?: "Counting…",
                )
            }
            if (healthConnectAvailable) {
                BackupButton(
                    label = uiString(R.string.l10n_data_sources_screen_import_from_health_connect_35d55e21),
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
                        Text(uiString(R.string.l10n_data_sources_screen_auto_sync_periodically_5f3041e8), style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_data_sources_screen_re_pull_new_health_connect_data_3e9c3914) +
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
                            contentDescription = uiString(R.string.l10n_data_sources_screen_auto_sync_health_connect_periodically_6f3f4d92)
                        },
                    )
                }
                if (hcAutoSync) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(uiString(R.string.l10n_data_sources_screen_every_3560d90b), style = NoopType.footnote, color = Palette.textSecondary)
                        SegmentedPillControl(
                            items = listOf(6, 12, 24),
                            selection = hcSyncHours,
                            label = { "${it}h" },
                            onSelect = { vm.setHcSyncHours(it) },
                        )
                    }
                    Text(
                        uiString(R.string.l10n_data_sources_screen_last_sync_b793ffab) + if (hcLastSync == 0L) "not yet"
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
                        Text(uiString(R.string.l10n_data_sources_screen_share_back_to_health_connect_1d578f4a), style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_data_sources_screen_write_the_metrics_noop_computes_from_439940c2) +
                                "respiratory rate, heart rate, steps, active energy and sleep) into " +
                                "Health Connect so other apps can use them. Only NOOP's own values are " +
                                "shared. Imported data is never echoed back.",
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
                            contentDescription = uiString(R.string.l10n_data_sources_screen_share_computed_metrics_back_to_health_c11f5d70)
                        },
                    )
                }
                // #660: surface the last writeback OUTCOME so a silently-failing share (revoked
                // permission, provider error) is visible instead of a healthy-looking toggle. Only
                // while enabled and after at least one attempt (empty status = never tried).
                if (hcWriteback && hcWbStatus.code.isNotEmpty()) {
                    when (hcWbStatus.code) {
                        NoopPrefs.HC_WB_PERMISSION_DENIED -> Text(
                            uiString(R.string.l10n_data_sources_screen_sharing_paused_health_connect_permission_was_e8950315),
                            style = NoopType.footnote,
                            color = Palette.accent,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { startWriteback() },   // tap re-requests the WRITE permissions
                        )
                        NoopPrefs.HC_WB_REMOTE_ERROR -> Text(
                            uiString(R.string.l10n_data_sources_screen_last_share_didn_t_finish_noop_0d6c27f0),
                            style = NoopType.footnote,
                            color = Palette.accent,
                        )
                        else -> Text(   // HC_WB_OK
                            uiString(R.string.l10n_data_sources_screen_last_shared_6bf8389c) +
                                DateUtils.getRelativeTimeSpanString(hcWbStatus.atMs).toString(),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                }
            } else {
                RoadmapNote("Health Connect isn't set up on this device. Install it from Google Play, then return here to import.")
            }
        }
        }

        // --- Nutrition CSV (calories / macros / body weight) ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_nutrition_csv_1c1315d9),
            icon = Icons.Filled.Restaurant,
            tint = Palette.metricAmber,
            subtitle = "Import daily calories, protein, carbs, fat and body weight from a " +
                "nutrition CSV: a MyFitnessPal or Cronometer export, or any spreadsheet " +
                "with a date column plus those values. Meal-level rows are summed per day.",
        ) {
            val hasNutrition = (nutritionDays ?: 0) > 0 || (nutritionWeighIns ?: 0) > 0
            StatePill(
                title = if (hasNutrition) "Imported" else "Nothing imported",
                tone = if (hasNutrition) StrandTone.Accent else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = nutritionDays?.let { "$it days logged" } ?: "—",
                secondary = nutritionWeighIns?.let { "$it weigh-ins" } ?: "Counting…",
            )
            BackupButton(
                label = uiString(R.string.l10n_data_sources_screen_import_nutrition_csv_2c748273),
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { nutritionImportLauncher.launch(arrayOf("*/*")) }
        }
        }

        // --- Xiaomi Mi Band (Mi Fitness on-device DB) — #35 ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_xiaomi_mi_band_edeab3bc),
            icon = Icons.Filled.Watch,
            tint = Palette.metricPurple,
            subtitle = "Import a Mi Band / Smart Band 8, 9 or 10's full history (steps, heart rate, " +
                "resting HR, sleep stages, SpO₂, stress and sleep score) straight from the Mi Fitness " +
                "app's on-device database. Fully offline; no Xiaomi account or Bluetooth. Export the Mi " +
                "Fitness folder (or its .db / a .zip of it) from your phone and choose it here.",
        ) {
            val hasXiaomi = (xiaomiDays ?: 0) > 0
            StatePill(
                title = if (hasXiaomi) "Imported" else "Nothing imported",
                tone = if (hasXiaomi) StrandTone.Accent else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = xiaomiDays?.let { "$it days imported" } ?: "—",
                secondary = if (xiaomiDays == null) "Counting…" else "Mi Band / Smart Band 8 · 9 · 10",
            )
            BackupButton(
                label = uiString(R.string.l10n_data_sources_screen_import_mi_band_export_e587801c),
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { xiaomiImportLauncher.launch(arrayOf("*/*")) }
        }
        }

        // --- Lifting log (Hevy CSV / Liftosaur JSON) ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_lifting_log_hevy_liftosaur_11df48df),
            icon = Icons.Filled.FitnessCenter,
            tint = DomainTheme.Effort.color,
            subtitle = "Import your strength-training history from a Hevy CSV export or a Liftosaur " +
                "JSON export. Each workout becomes a Strength session with a training-volume " +
                "estimate (weight × reps). It's a volume figure, not a measured strain, so it never " +
                "changes your Effort.",
        ) {
            val hasLifting = (liftingWorkouts ?: 0) > 0
            StatePill(
                title = if (hasLifting) "Imported" else "Nothing imported",
                tone = if (hasLifting) StrandTone.Accent else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = liftingWorkouts?.let { "$it workouts" } ?: "—",
                secondary = "volume load shown per session",
            )
            BackupButton(
                label = uiString(R.string.l10n_data_sources_screen_import_lifting_log_8fac7b68),
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { liftingImportLauncher.launch(arrayOf("*/*")) }
        }
        }

        // --- Workout file (GPX / TCX / FIT) — any brand, on-device ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_workout_file_gpx_tcx_fit_5469c068),
            icon = Icons.Filled.Map,
            tint = Palette.metricAmber,
            subtitle = "Import a single exported workout file from any brand (Garmin, Coros, Suunto, " +
                "Wahoo, Polar, Strava, Apple) straight off your phone. GPS route, distance, heart rate " +
                "and calories come in where the file has them. Fully offline; nothing leaves your phone.",
        ) {
            val hasFiles = (activityFiles ?: 0) > 0
            StatePill(
                title = if (hasFiles) "Imported" else "Nothing imported",
                tone = if (hasFiles) StrandTone.Accent else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = activityFiles?.let { "$it workouts" } ?: "—",
                secondary = "GPX · TCX · FIT (one workout per file)",
            )
            BackupButton(
                label = uiString(R.string.l10n_data_sources_screen_import_workout_file_a3a28e06),
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { activityFileImportLauncher.launch(arrayOf("*/*")) }
        }
        }

        // --- Oura / Fitbit / Garmin own-data export — on-device ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_oura_fitbit_garmin_export_7b21682f),
            icon = Icons.Filled.Watch,
            tint = Palette.metricPurple,
            subtitle = "Import your own data export from Oura, Fitbit or Garmin: sleep, resting heart " +
                "rate, HRV, steps and more, where the export has them. Download it from the brand's app " +
                "(Oura: Account → Export Data; Fitbit: Google Takeout; Garmin: Export Your Data), then " +
                "choose the file here. Fully offline; nothing leaves your phone. Each brand's own " +
                "readiness or sleep score is kept for reference only. Your scores stay yours.",
        ) {
            val hasDays = (wearableDays ?: 0) > 0
            StatePill(
                title = if (hasDays) "Imported" else "Nothing imported",
                tone = if (hasDays) StrandTone.Accent else StrandTone.Neutral,
                showsDot = true,
            )
            CountLine(
                primary = wearableDays?.let { "$it day metrics" } ?: "—",
                secondary = "Oura JSON · Fitbit Takeout · Garmin GDPR (daily metrics + sleep)",
            )
            BackupButton(
                label = uiString(R.string.l10n_data_sources_screen_import_wearable_export_0545c430),
                icon = Icons.Filled.FileUpload,
                enabled = !busy,
                modifier = Modifier.fillMaxWidth(),
            ) { wearableImportLauncher.launch(arrayOf("*/*")) }
        }
        }

        // --- Broadcast heart rate (NOOP as a standard BLE HR peripheral) ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_broadcast_hr_from_this_phone_10e5605c),
            icon = Icons.Filled.MonitorHeart,
            tint = DomainTheme.Effort.color,
            subtitle = "Re-share your live strap heart rate over Bluetooth as a standard heart-rate " +
                "sensor, so a gym treadmill, bike, Zwift, Peloton or any fitness app nearby can read " +
                "it. Works on any WHOOP (4.0 or 5.0/MG) because your phone does the broadcasting. " +
                "Local Bluetooth only. Nothing leaves your phone. Off by default.",
        ) {
            if (hrBroadcast) {
                val (label, tone) =
                    if (hrBroadcastAdvertising) "Broadcasting" to StrandTone.Positive
                    else "Starting…" to StrandTone.Warning
                StatePill(title = label, tone = tone, showsDot = true, pulsing = !hrBroadcastAdvertising)
                CountLine(
                    primary = if (hrBroadcastAdvertising) "Standard HR sensor (0x180D)" else "—",
                    secondary = when {
                        hrBroadcastSubscribers > 0 ->
                            "$hrBroadcastSubscribers ${if (hrBroadcastSubscribers == 1) "device" else "devices"} reading"
                        live.heartRate != null -> "Sharing ${live.heartRate} bpm · waiting for a device"
                        else -> "No live heart rate yet · open Live to pair your strap"
                    },
                )
            } else {
                // Parity with the Swift card, which shows an explicit "Off" pill when the toggle is off
                // (DataSourcesView.broadcastHrCard: StatePill("Off", tone: .neutral, showsDot: false)).
                StatePill(title = uiString(R.string.l10n_data_sources_screen_off_e3de5ab0), tone = StrandTone.Neutral, showsDot = false)
            }
            hrBroadcastStatus?.let { note ->
                Text(note, style = NoopType.footnote, color = Palette.statusWarning)
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(uiString(R.string.l10n_data_sources_screen_broadcast_hr_from_this_phone_10e5605c), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_data_sources_screen_acts_as_a_standard_bluetooth_heart_f8d13439),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = hrBroadcast,
                    onCheckedChange = { on ->
                        // Turning ON requests BLUETOOTH_ADVERTISE first (the VM flips on once granted);
                        // turning OFF stops the peripheral immediately.
                        if (on) requestAdvertise() else vm.setHrBroadcast(false)
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = Palette.surfaceBase,
                        checkedTrackColor = Palette.accent,
                        uncheckedThumbColor = Palette.textSecondary,
                        uncheckedTrackColor = Palette.surfaceInset,
                        uncheckedBorderColor = Palette.hairline,
                    ),
                    modifier = Modifier.semantics {
                        contentDescription = uiString(R.string.l10n_data_sources_screen_broadcast_heart_rate_as_a_bluetooth_6a44fdb4)
                    },
                )
            }

            // #573: leaving broadcast on keeps the radio advertising continuously, which drains the
            // battery faster — make that visible and persistent so it isn't left on by accident. Mirrors
            // the Swift broadcast-HR warning (SettingsView).
            if (hrBroadcast) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics(mergeDescendants = true) {},
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Filled.SettingsInputAntenna,
                        contentDescription = null,
                        tint = Palette.statusWarning,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        uiString(R.string.l10n_data_sources_screen_broadcast_hr_is_on_your_strap_0ad5368a) +
                            "which keeps its radio hot and drains the battery faster. Turn it off when " +
                            "you're not using it with another device.",
                        style = NoopType.caption,
                        color = Palette.statusWarning,
                    )
                }
            }
        }
        }

        // --- Live WHOOP strap over BLE ---
        item {
        SourceCard(
            title = uiString(R.string.l10n_data_sources_screen_whoop_strap_live_ble_217f7df6),
            icon = Icons.Filled.Bluetooth,
            subtitle = "Pairs directly with your strap over Bluetooth: no WHOOP app, no cloud.",
        ) {
            val (label, tone) = when {
                live.bonded -> "Bonded, streaming." to StrandTone.Positive
                live.connected -> "Connected, pairing…" to StrandTone.Warning
                else -> "Not connected. Open Live to pair." to StrandTone.Critical
            }
            StatePill(title = label, tone = tone, showsDot = true, pulsing = live.connected && !live.bonded)
        }
        }

    }

    // ah-delete (#616): strongly-worded confirm before purging the "apple-health" source. On confirm,
    // deletes every Apple-Health-sourced row (deviceId-keyed tables) in one transaction via the registry,
    // re-counts so the card flips back to "Nothing imported", and toasts the result.
    if (confirmDeleteApple) {
        AlertDialog(
            onDismissRequest = { confirmDeleteApple = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(uiString(R.string.l10n_data_sources_screen_remove_apple_health_imported_data_5f878502), style = NoopType.title2, color = Palette.textPrimary)
            },
            text = {
                Text(
                    uiString(R.string.l10n_data_sources_screen_this_permanently_deletes_everything_imported_from_f42e760e),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmDeleteApple = false
                    busy = true
                    scope.launch {
                        runCatching {
                            withContext(Dispatchers.IO) { vm.deletePairedDeviceData("apple-health") }
                        }
                        vm.ble.externalLog("Import apple-health: imported data removed")
                        refreshCounts()
                        vm.loadWorkouts()
                        busy = false
                        Toast.makeText(context, "Removed Apple Health imported data.", Toast.LENGTH_LONG).show()
                    }
                }) {
                    Text(uiString(R.string.l10n_data_sources_screen_remove_e963907d), style = NoopType.body, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDeleteApple = false }) {
                    Text(uiString(R.string.l10n_data_sources_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

// MARK: - Source card (mirrors the macOS private `card(...)` builder)

@Composable
private fun SourceCard(
    title: String,
    icon: ImageVector,
    subtitle: String,
    tint: Color = Palette.accent,
    content: @Composable () -> Unit,
) {
    // A frosted, domain-tinted card: a tinted source glyph chip + title, the explainer line, then
    // the source's status pill + connect/import action(s). Replaces the old flat surface.
    NoopCard(padding = 18.dp, tint = tint) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(tint.copy(alpha = 0.14f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(16.dp),
                    )
                }
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
    tint: Color = Palette.accent,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    val ink = if (enabled) tint else tint.copy(alpha = Palette.disabledOpacity)
    Row(
        modifier = modifier
            .height(48.dp)
            .clip(shape)
            .background(tint.copy(alpha = 0.14f))
            .border(1.dp, ink.copy(alpha = 0.4f), shape)
            .let { if (enabled) it.clickable(onClick = onClick) else it }
            .padding(horizontal = 14.dp)
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = ink, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text(label, style = NoopType.headline, color = ink)
    }
}

/**
 * Emit the Import & Data Ingest test-mode trace for a finished import, tagged TestDomain.IMPORT, iff the
 * mode is on. Shared by the Data Sources + Onboarding import flows (both call runImport). Gated zero-cost
 * when off: one SharedPreferences bool read before any line is built. The lines are byte-aligned with the
 * macOS ImportTrace shapes (parser / per-stage / reject / day-delta), built from the ImportSummary the
 * importer already returned. Never a file name, a path, or any health value.
 *
 * HONESTY (the whole point of this mode, tied to the #601/#749/#754 "didn't save" cluster): unlike the
 * Swift store, which returns the summed SQLite changes from each upsert, Room's @Upsert reports no
 * store-write count at this layer. So Android does NOT claim "(all written)" / "(all days persisted)" - it
 * emits rowsIn / daysMapped with rowsOut / daysPersisted marked UNVERIFIED. A line never asserts a save it
 * cannot confirm. REJECTED counts (e.g. skippedSpans - scrubbed/damaged spans, the OPPOSITE of written)
 * are routed through the reject line, never a stage line, matching AppleHealthImport.swift.
 */
internal fun emitImportTrace(
    context: android.content.Context,
    vm: AppViewModel,
    summary: com.noop.data.ImportSummary,
) {
    if (!com.noop.testcentre.TestCentre.from(context).active(com.noop.testcentre.TestDomain.IMPORT)) return
    if (summary.totalRows <= 0) return   // a failed/empty import already logged its reason above
    val kind = com.noop.analytics.ImportTrace.kindWire(summary.source)
    vm.ble.externalLog(
        com.noop.analytics.ImportTrace.parserVersionLine(kind, importerVersion = 1),
        com.noop.testcentre.TestDomain.IMPORT,
    )
    // Reject keys are NOT writes: they are rows/spans the import dropped (the opposite of "written"), so
    // they must never become a stage line. skippedSpans is the only one an Android importer emits today.
    val skippedSpans = summary.counts["skippedSpans"] ?: 0
    for ((rawKey, count) in summary.counts) {
        if (rawKey == "skippedSpans") continue   // routed through the reject line below, not as a stage
        val category = com.noop.analytics.ImportTrace.categoryWire(summary.source, rawKey)
        // rowsOut is UNVERIFIED on Android (Room reports no store-write count); never claim "(all written)".
        vm.ble.externalLog(
            com.noop.analytics.ImportTrace.stageLineUnverified(category, rowsIn = count),
            com.noop.testcentre.TestDomain.IMPORT,
        )
    }
    // The reject line mirrors AppleHealthImport.swift: the app map drops nothing further here, so
    // droppedRows = 0; skippedSpans carries the tolerant-import scrubbed-span count (0 on non-Apple).
    vm.ble.externalLog(
        com.noop.analytics.ImportTrace.rejectLine(droppedRows = 0, skippedSpans = skippedSpans),
        com.noop.testcentre.TestDomain.IMPORT,
    )
    // Day delta: pick the source's day-keyed table (Apple -> appleDaily, WHOOP/others -> dailyMetric) so a
    // real Apple import reports the right day count, and label the stage with the Swift category vocabulary.
    val dayKey = if (summary.counts.containsKey("appleDaily")) "appleDaily" else "dailyMetric"
    val days = summary.counts[dayKey] ?: summary.counts["days"] ?: 0
    val dayCategory = com.noop.analytics.ImportTrace.categoryWire(summary.source, dayKey)
    vm.ble.externalLog(
        com.noop.analytics.ImportTrace.dayDeltaLineUnverified(dayCategory, daysMapped = days),
        com.noop.testcentre.TestDomain.IMPORT,
    )
}
