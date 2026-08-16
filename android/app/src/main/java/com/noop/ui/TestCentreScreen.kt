package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.BuildConfig
import com.noop.analytics.Baselines
import com.noop.analytics.HRVReadiness
import com.noop.analytics.ReadinessTier
import com.noop.ble.PuffinExperiment
import com.noop.ble.WhoopModel
import com.noop.data.DailyMetric
import com.noop.polar.PolarModel
import com.noop.testcentre.CaptureAccumulator
import com.noop.testcentre.CaptureKind
import com.noop.testcentre.DisplayPerformanceMonitor
import com.noop.testcentre.ReportReviewGate
import com.noop.testcentre.TestBundleAssembler
import com.noop.testcentre.TestCentre
import com.noop.testcentre.TestCentreLayout
import com.noop.testcentre.TestDomain
import com.noop.testcentre.TestMode
import com.noop.testcentre.TestModeRegistry
import com.noop.testcentre.TestReportFlow
import com.noop.testcentre.TestReportLink
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Settings -> Test Centre (spec section 7), the Android twin of TestCentreView. Four sections: domain
 * test modes (rendered from the registry projection), diagnostic tools, export and auto-export, and
 * advanced/experimental. A NEW file because SettingsScreen.kt (132 KB) cannot grow. Section 1 renders
 * from TestCentreLayout.visibleModes; sections 2 to 4 re-host the same strap-log / recalibrate /
 * scheduled-export / experimental controls on the same bindings the Settings cards use. No em-dash.
 */
@Composable
fun TestCentreScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val testCentre = remember { TestCentre.from(context) }
    // CAPTURE-D: a UI scope to emit the data-volume line off the toggle-on path (a store read, so it can't
    // run inline in the non-suspend onToggle).
    val scope = rememberCoroutineScope()

    // The strap model the Settings #22 gate reads, mirrored here so the 5/MG block shows for a 5/MG only.
    val live by vm.live.collectAsStateWithLifecycle()
    val selectedModelName = remember {
        NoopPrefs.of(context).getString("noop.selectedWhoopModel", null)
    }
    // Match the Settings `showFiveMGControls` gate exactly: pref OR a live-detected 5/MG this session, so a
    // 5/MG connected before its pref is written still sees the experimental block. (SettingsScreen.kt:346.)
    val is5MG = selectedModelName == WhoopModel.WHOOP5_MG.name || live.whoop5Detected

    // A report awaiting the mandatory review-before-share gate (spec section 12). Non-null shows the
    // review dialog; confirming runs TestReportFlow.run.
    var pendingReport by remember { mutableStateOf<PendingReport?>(null) }

    // #646/#651: TestReportFlow.run now awaits LogExport.exportBundle's off-main zip build instead of
    // blocking the caller, so a re-entrancy guard is needed on the dialog's Share button — without it a
    // fast double-tap before the dialog dismisses fires two zips / two chooser intents.
    var reportShareBusy by remember { mutableStateOf(false) }

    // The Display frame monitor follows the screen: if the Display mode was already on when the screen
    // appears, (re)start it; always tear it down when the screen leaves so no Choreographer callback
    // survives a navigation away. The mode flag stays on (the user's test is still active); the monitor
    // resumes next time this screen is shown. This keeps the perpetual-callback contract: a callback
    // exists only while the Test Centre is on screen with the Display mode on.
    DisposableEffect(Unit) {
        if (testCentre.active(TestDomain.DISPLAY)) {
            // CAPTURE-D (#797): wire the data-volume provider so the monitor can emit ONE `dataVolume` line
            // read STRAIGHT from the store (not the reactive caches), against the registry's active strap id.
            DisplayPerformanceMonitor.dataVolumeProvider = { vm.repo.dataVolumeSnapshot(vm.activeStrapId) }
            DisplayPerformanceMonitor.start(context) { line ->
                vm.ble.externalLog(line, TestDomain.DISPLAY)
            }
        }
        onDispose { DisplayPerformanceMonitor.stop() }
    }
    // CAPTURE-D: emit the data-volume line once when the Display mode is active on entry. Kept off the
    // (non-suspend) DisposableEffect: the read hits the store, so it runs from a coroutine.
    LaunchedEffect(Unit) {
        if (testCentre.active(TestDomain.DISPLAY)) DisplayPerformanceMonitor.emitDataVolume()
    }

    ScreenScaffold(
        title = uiString(R.string.l10n_test_centre_screen_test_centre_37b36828),
        subtitle = "Turn on a test for the thing that's wrong, wear the strap, then tap Report. Everything stays on this phone.",
    ) {
        // --- Section 1: Domain test modes ---
        SettingsSectionTC(
            icon = Icons.Filled.BugReport,
            title = uiString(R.string.l10n_test_centre_screen_test_modes_e21f1d3c),
            blurb = "Each test logs extra detail for one part of the app while you wear the strap, then bundles it for a bug report.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                TestCentreLayout.visibleModes(is5MG).forEach { mode ->
                    TestModeRow(
                        mode = mode,
                        active = testCentre.active(mode.domain),
                        startedAtSeconds = testCentre.startedAt(mode.domain),
                        // #965: the shareable strap log the report exports, so the row's "K of N" is the
                        // HONEST per-mode captured-day count (CaptureAccumulator), not an elapsed-clock proxy.
                        // Recomputes with `live` (collected above) so the count updates as new days land.
                        logText = vm.ble.exportLogText(),
                        onToggle = { on ->
                            if (on) testCentre.activate(mode.domain) else testCentre.deactivate(mode.domain)
                            // Display & Performance owns a live frame monitor. It must run ONLY while the
                            // mode is on: start it on toggle-on (wiring its sink to the redacting DISPLAY
                            // log), tear it down on toggle-off so no Choreographer callback survives.
                            // Zero-cost when off.
                            if (mode.domain == TestDomain.DISPLAY) {
                                if (on) {
                                    // CAPTURE-D (#797): wire the data-volume provider (store-read, active id),
                                    // start the monitor, then emit the upfront dataVolume line off a scope.
                                    DisplayPerformanceMonitor.dataVolumeProvider =
                                        { vm.repo.dataVolumeSnapshot(vm.activeStrapId) }
                                    DisplayPerformanceMonitor.start(context) { line ->
                                        vm.ble.externalLog(line, TestDomain.DISPLAY)
                                    }
                                    scope.launch { DisplayPerformanceMonitor.emitDataVolume() }
                                } else {
                                    DisplayPerformanceMonitor.stop()
                                }
                            }
                        },
                        onReport = {
                            // Launched (#1002): buildPending is now suspend (storage probe reads the store).
                            scope.launch { pendingReport = buildPending(context, mode, vm.ble.exportLogText(), vm) }
                        },
                    )
                }
            }
        }

        // --- Section 2: Diagnostic tools ---
        DiagnosticToolsCard(vm)

        // --- Section 3: Export and auto-export ---
        ExportCard(
            vm = vm,
            onReport = {
                // Launched (#1002): buildPending is now suspend (storage probe reads the store).
                scope.launch { pendingReport = buildPending(context, MASTER_REPORT_MODE, vm.ble.exportLogText(), vm) }
            },
        )

        // --- Section 4: Experimental algorithms ---
        ExperimentalAlgorithmsCard(vm)
    }

    pendingReport?.let { p ->
        ReportReviewDialog(
            previewText = p.gate.previewText,
            modeInactive = p.modeInactive,
            onCancel = { pendingReport = null },
            onShare = {
                // Guard against a fast double-tap firing TestReportFlow.run twice before the dialog
                // dismisses (#646/#651 — run() now awaits the off-main zip build instead of blocking).
                if (!reportShareBusy) {
                    reportShareBusy = true
                    p.gate.confirm()
                    scope.launch {
                        // try/finally: the flag must clear on any exit, not just the happy path (#961 follow-up).
                        try {
                            TestReportFlow.run(
                                context = context,
                                profile = p.profile,
                                title = p.title,
                                version = BuildConfig.VERSION_NAME,
                                platform = "Android",
                                osVersion = android.os.Build.VERSION.RELEASE ?: "?",
                                gate = p.gate,
                                entries = p.entries,
                            )
                        } finally {
                            reportShareBusy = false
                        }
                    }
                    pendingReport = null
                }
            },
        )
    }
}

/** A report staged for the mandatory review gate: the profile, its title, the already-redacted entries
 *  and the gate built over them. The Kotlin gate keeps its entries private, so we hold them here too to
 *  hand TestReportFlow.run the same list it reviews. [modeInactive] (#1002): the selected profile's test
 *  mode is not on at report time, so the bundle carries no capture for the very thing being reported -
 *  the review dialog warns off it (the #812 capture_check only grades ACTIVE modes, so it can't). */
private class PendingReport(
    val profile: TestDomain,
    val title: String,
    val entries: List<Pair<String, ByteArray>>,
    val gate: ReportReviewGate,
    val modeInactive: Boolean = false,
)

/** The "whole app" report profile for the section-3 manual Report button. MASTER is not a registry mode
 *  (it has no wear-and-capture flow), so the deep-link self-applies the test:all label via this. */
private val MASTER_REPORT_MODE = TestMode(
    domain = TestDomain.MASTER, title = uiString(R.string.l10n_test_centre_screen_bug_report_5a7ee5ac), blurb = "", icon = "ic_bug",
    priority = com.noop.testcentre.TestPriority.HIGH, captures = emptyList(),
    questionnaire = emptyList(), liveReadout = emptyList(),
    capture = com.noop.testcentre.CaptureKind.Toggle, includesScreenshot = false, requires5MG = false,
)

/** Assemble the redacted, capped bundle for a profile and wrap it in the review gate. Suspend (#1002):
 *  the storage probe reads the store, so the callers launch it on the UI scope; the dialog presents off
 *  the same `pendingReport` state a beat after the tap. */
private suspend fun buildPending(
    context: android.content.Context,
    mode: TestMode,
    logText: String,
    vm: AppViewModel,
): PendingReport {
    // #1002 REAL storage probe, replacing the Phase-1 zeros in meta.json:
    //  - db_bytes: the Room store's on-disk footprint (noop_whoop.db + its -wal/-shm sidecars);
    //  - rows: per-table row counts via the store (WhoopRepository.storageRowCounts);
    //  - raw_capture_bytes: the 5/MG frame-recorder JSONL on disk (both rotation generations).
    // Everything read, never guessed; when nothing was readable the probe stays null and meta keeps the
    // honest zeroed block. Mirrors the Swift TestCentreReport.storageProbe.
    val dbPath = context.getDatabasePath(com.noop.data.WhoopDatabase.DB_NAME)
    var dbBytes = 0L
    for (suffix in listOf("", "-wal", "-shm")) {
        val f = java.io.File(dbPath.path + suffix)
        if (f.exists()) dbBytes += f.length()
    }
    val rows = vm.repo.storageRowCounts()
    var rawBytes = 0L
    for (name in listOf(
        com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE,
        com.noop.ble.WhoopBleClient.WHOOP5_CAPTURE_FILE + ".1",
    )) {
        val f = java.io.File(context.filesDir, name)
        if (f.exists()) rawBytes += f.length()
    }
    val storage = if (dbBytes > 0L || rows.isNotEmpty() || rawBytes > 0L) {
        com.noop.testcentre.TestBundleMeta.Storage(
            dbBytes = dbBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
            rows = rows,
            rawCaptureBytes = rawBytes.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
        )
    } else {
        null
    }
    // #1002: the connected model - the scan/connect path persists the DETECTED family to this pref, so
    // it reflects the strap that actually linked; the display name matches the Swift wire value.
    val strapModel = NoopPrefs.of(context).getString("noop.selectedWhoopModel", null)
        ?.let { name -> runCatching { WhoopModel.valueOf(name).displayName }.getOrNull() }
    val entries = TestBundleAssembler.assemble(context, mode.domain, logText, storage, strapModel)
    val modeInactive = mode.domain != TestDomain.MASTER && !TestCentre.from(context).active(mode.domain)
    return PendingReport(mode.domain, mode.title, entries, ReportReviewGate(entries), modeInactive)
}

@Composable
private fun TestModeRow(
    mode: TestMode,
    active: Boolean,
    startedAtSeconds: Long?,
    logText: String,
    onToggle: (Boolean) -> Unit,
    onReport: () -> Unit,
) {
    var on by remember { mutableStateOf(active) }
    val elapsed = startedAtSeconds?.let { (System.currentTimeMillis() / 1000.0) - it }
    // #965: HONEST per-mode captured-day count for a guided row (distinct days THIS mode produced its own
    // trace on), read from the same log the report exports, so each active mode accumulates its OWN count
    // instead of every guided row sharing one elapsed number. null for a toggle mode (no "K of N") / when off.
    val capturedUnits: Int? =
        if (on && mode.capture is CaptureKind.Guided) {
            CaptureAccumulator.capturedDays(
                domain = mode.domain,
                reportText = logText,
                tzOffsetSeconds =
                    (java.util.TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000).toLong(),
            )
        } else {
            null
        }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(mode.title, style = NoopType.body, color = Palette.textPrimary)
                Text(
                    TestCentreLayout.statusText(mode, on, elapsed, capturedUnits),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
            }
            Switch(
                checked = on,
                onCheckedChange = { on = it; onToggle(it) },
                colors = settingsSwitchColors(),
            )
        }
        Text(mode.blurb, style = NoopType.footnote, color = Palette.textTertiary)
        Row {
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onReport) {
                Text(uiString(R.string.l10n_test_centre_screen_report_ee45c303), color = Palette.accent, style = NoopType.body)
            }
        }
    }
}

@Composable
private fun DiagnosticToolsCard(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showRecalibrate by remember { mutableStateOf(false) }
    // "Debug logging" moved here from Settings: dev-only, mirrors the strap log to logcat over adb.
    var debugLogging by remember { mutableStateOf(NoopPrefs.debugLogging(context)) }
    // #polar-debug: the model NOOP auto-detects for a PAIRED Polar strap, from its stored advertised name
    // (no live connection needed). null when no Polar strap is paired → the whole toggle stays hidden, so a
    // non-Polar user never sees Polar debug. Loaded once from the registry.
    var polarIdentity by remember { mutableStateOf<String?>(null) }
    var polarDebugLogging by remember { mutableStateOf(NoopPrefs.polarDebugLogging(context)) }
    LaunchedEffect(Unit) {
        val name = runCatching { vm.pairedDevices() }.getOrDefault(emptyList())
            .firstOrNull { PolarModel.isPolar(it.model) }?.model
        polarIdentity = PolarModel.debugIdentification(name)
    }
    var detailedCapture by remember { mutableStateOf(NoopPrefs.detailedCapture(context)) }
    var captureShareBusy by remember { mutableStateOf(false) }
    // #646/#651: LogExport.shareStrapLog's file write now runs on Dispatchers.IO instead of blocking the
    // caller, so nothing else stops a second tap mid-share. Same disable-while-busy + spinner shape as
    // Settings' backupBusy pattern — this screen has its own local flag, this button being a separate
    // instance from the Settings "Share strap log" button.
    var strapLogBusy by remember { mutableStateOf(false) }
    SettingsSectionTC(
        icon = Icons.Filled.Info,
        title = uiString(R.string.l10n_test_centre_screen_diagnostic_tools_04ba4d3f),
        blurb = "Your strap log, a Charge recalibrate, and the device environment. Nothing leaves the phone unless you share it.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Strap log, the same exportLogText share the Settings Diagnostics button uses.
            NoopButton(
                text = uiString(R.string.l10n_test_centre_screen_share_strap_log_for_bug_reports_b9802500),
                leadingIcon = Icons.Filled.Upload,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !strapLogBusy,
                onClick = {
                    strapLogBusy = true
                    scope.launch {
                        // try/finally: the flag must clear on any exit, not just the happy path (#961 follow-up).
                        try {
                            LogExport.shareStrapLog(context, vm.ble.exportLogText())
                        } finally {
                            strapLogBusy = false
                        }
                    }
                },
            )
            if (strapLogBusy) {
                NoopBusyRow()
            }
            // Recalibrate Charge baseline, the same Baselines.recalibrateRecoveryBaselines call.
            NoopButton(
                text = uiString(R.string.l10n_test_centre_screen_recalibrate_charge_baseline_52a05a26),
                leadingIcon = Icons.Filled.Autorenew,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = { showRecalibrate = true },
            )
            // Debug logging (moved here from Settings): mirror the strap log to logcat for adb
            // development. Dev-only, off by default; the in-app log and "Share strap log" above work either way.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(uiString(R.string.l10n_test_centre_screen_debug_logging_daaa7d74), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_test_centre_screen_also_write_the_strap_log_to_655b55b2),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = debugLogging,
                    onCheckedChange = { debugLogging = it; vm.setDebugLogging(it) },
                    colors = settingsSwitchColors(),
                )
            }
            // #polar-debug: only shown when a Polar strap is paired (polarIdentity != null). The subtitle is
            // the model auto-detected from the paired record; the toggle also writes it to the strap log on
            // each connect. Off by default. Diagnostic-only — nothing gates behaviour on it.
            polarIdentity?.let { identity ->
                ToggleRowTC(
                    title = "Polar debug logging",
                    description = "$identity.\nLogs this identification to the strap log on each connect, " +
                        "so a Polar bug report shows the model NOOP resolved your strap to.",
                    checked = polarDebugLogging,
                    onCheckedChange = { polarDebugLogging = it; vm.setPolarDebugLogging(it) },
                )
            }
            // #1121 Detailed capture: an adb-like rolling on-device log, no computer needed. Off by default.
            ToggleRowTC(
                title = "Detailed capture to file",
                description = "Continuously append the strap log to a rolling on-device file (≤8 MB, one " +
                    "previous generation kept) so a long-running issue — battery drain, an overnight " +
                    "offload — is captured for hours instead of the ~50 minutes the in-memory share holds. " +
                    "Keeps going if the app is killed and resumes on next launch. The file stays on the " +
                    "phone unless you share it below.",
                checked = detailedCapture,
                onCheckedChange = { detailedCapture = it; vm.setDetailedCapture(it) },
            )
            if (detailedCapture) {
                Text(
                    "Capturing… reproduce the issue, then share the log below.",
                    style = NoopType.footnote,
                    color = Palette.accent,
                )
            }
            NoopButton(
                text = "Share captured log",
                leadingIcon = Icons.Filled.Upload,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                enabled = !captureShareBusy,
                onClick = {
                    captureShareBusy = true
                    scope.launch {
                        try {
                            LogExport.shareCaptureLog(context)
                        } finally {
                            captureShareBusy = false
                        }
                    }
                },
            )
            if (captureShareBusy) {
                NoopBusyRow()
            }
        }
    }
    if (showRecalibrate) {
        AlertDialog(
            onDismissRequest = { showRecalibrate = false },
            containerColor = Palette.surfaceOverlay,
            title = { Text(uiString(R.string.l10n_test_centre_screen_recalibrate_your_charge_baseline_018e3846), style = NoopType.title2, color = Palette.textPrimary) },
            text = {
                Text(
                    uiString(R.string.l10n_test_centre_screen_this_restarts_the_roughly_4_night_33cce377),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val nowSeconds = System.currentTimeMillis() / 1000L
                    val editor = NoopPrefs.of(context).edit()
                    Baselines.recalibrateRecoveryBaselines(editor, nowSeconds)
                    editor.apply()
                    showRecalibrate = false
                    vm.syncNow()
                }) { Text(uiString(R.string.l10n_test_centre_screen_recalibrate_aaa989ea), style = NoopType.body, color = Palette.accent) }
            },
            dismissButton = {
                TextButton(onClick = { showRecalibrate = false }) {
                    Text(uiString(R.string.l10n_test_centre_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

@Composable
@Suppress("UNUSED_PARAMETER")
private fun ExportCard(vm: AppViewModel, onReport: () -> Unit) {
    val context = LocalContext.current
    val settings = remember { DebugExportSettings.from(context) }
    var enabled by remember { mutableStateOf(settings.enabled) }
    var minutes by remember { mutableStateOf(settings.timeMinutes) }
    // Retention (#642): how many scheduled-export generations to keep before the next write prunes
    // older ones. Same shape as BackupSyncScreen's keep-count dropdown.
    var keep by remember { mutableStateOf(settings.keepCount) }
    var keepMenu by remember { mutableStateOf(false) }
    var showClearConfirm by remember { mutableStateOf(false) }
    SettingsSectionTC(
        icon = Icons.Filled.Upload,
        title = uiString(R.string.l10n_test_centre_screen_export_f3e4fadb),
        blurb = "Report a bug with your log, or have NOOP drop a daily copy into its export folder.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            NoopButton(
                text = uiString(R.string.l10n_test_centre_screen_report_a_bug_with_my_log_5101ee49),
                leadingIcon = Icons.Filled.BugReport,
                kind = NoopButtonKind.Primary,
                fullWidth = true,
                onClick = onReport,
            )
            // Daily auto-export, the same DebugExportSettings writes the Settings card uses.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(uiString(R.string.l10n_test_centre_screen_daily_auto_export_02ed9f75), style = NoopType.subhead, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_test_centre_screen_android_runs_this_via_workmanager_doze_875e499e),
                        style = NoopType.footnote, color = Palette.textTertiary,
                    )
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = {
                        enabled = it
                        settings.enabled = it
                        DebugExportScheduler.reschedule(context)
                    },
                    colors = settingsSwitchColors(),
                )
            }
            if (enabled) {
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(uiString(R.string.l10n_test_centre_screen_export_time_2ca90c2e), style = NoopType.subhead, color = Palette.textPrimary)
                    }
                    TimeChip(
                        minutes = minutes,
                        accessibilityLabel = "Daily export time",
                        onPicked = {
                            minutes = it
                            settings.timeMinutes = it
                            DebugExportScheduler.applyTimeChange(context)
                        },
                    )
                }
                // Retention: how many scheduled exports to keep. Wired to DebugExportSettings.keepCount;
                // the next scheduled write prunes the oldest generations beyond this count (#642).
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(uiString(R.string.l10n_test_centre_screen_keep_last_exports_44bc65f5), style = NoopType.subhead, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_test_centre_screen_older_scheduled_exports_beyond_this_c75723fc),
                            style = NoopType.footnote, color = Palette.textTertiary,
                        )
                    }
                    Box {
                        TextButton(onClick = { keepMenu = true }) {
                            Text(uiString(R.string.l10n_backup_sync_screen_keep_1addd33c, keep), style = NoopType.body, color = Palette.accent)
                        }
                        DropdownMenu(expanded = keepMenu, onDismissRequest = { keepMenu = false }) {
                            EXPORT_KEEP_OPTIONS.forEach { n ->
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
                                        settings.keepCount = n
                                        keepMenu = false
                                    },
                                )
                            }
                        }
                    }
                }
            }
            // Manual clear (#642): always available, even with the toggle off, since files written
            // while it was on can outlive that toggle flip.
            NoopButton(
                text = uiString(R.string.l10n_test_centre_screen_clear_scheduled_exports_54123329),
                leadingIcon = Icons.Filled.DeleteOutline,
                kind = NoopButtonKind.Secondary,
                fullWidth = true,
                onClick = { showClearConfirm = true },
            )
        }
    }
    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            containerColor = Palette.surfaceOverlay,
            title = {
                Text(
                    uiString(R.string.l10n_test_centre_screen_clear_scheduled_exports_36e93dd0),
                    style = NoopType.title2, color = Palette.textPrimary,
                )
            },
            text = {
                Text(
                    uiString(R.string.l10n_test_centre_screen_this_deletes_every_scheduled_strap_ea52c535),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    LogExport.clearScheduledExports(context)
                    showClearConfirm = false
                }) { Text(uiString(R.string.l10n_lab_book_screen_clear_719ea396), style = NoopType.body, color = Palette.statusCritical) }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirm = false }) {
                    Text(uiString(R.string.l10n_test_centre_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }
}

/** Retention choices for the scheduled-debug-export keep-count dropdown (#642). These are lightweight
 *  text/JSONL files, not a whole-DB snapshot, so the range skews longer than BackupSyncScreen's
 *  KEEP_OPTIONS. */
private val EXPORT_KEEP_OPTIONS = listOf(3, 7, 14, 30, 60)

/**
 * Test Centre → Experimental algorithms. The single home for OPT-IN, off-by-default, non-clinical research
 * variants that swap which model computes a metric (never detection, never a stored WHOOP value). Each toggle
 * writes the SAME [PuffinExperiment] key its Swift twin reads, so the platforms stay in lockstep. Hosts the
 * HR-from-PPG sub-lag interpolation variant and the read-only HRV-readiness (Plews/Altini) tier readout.
 * Twin of the Swift TestCentreView experimentalAlgorithmsCard.
 */
@Composable
private fun ExperimentalAlgorithmsCard(vm: AppViewModel) {
    val context = LocalContext.current
    val puffin = remember { PuffinExperiment.from(context) }
    var ppgHrSubLag by remember { mutableStateOf(puffin.ppgHrSubLagInterp) }
    var hrvReadiness by remember { mutableStateOf(puffin.hrvReadiness) }
    // The SAME nightly HRV series the recovery UI reads (repo-merged DailyMetric.avgHrv, oldest-first), fed
    // into the pure HRVReadiness engine ONLY to render the toggle's own reading inline below — the default
    // Charge ring / analyzeDay path is never touched, and this feeds no downstream gate.
    val recentDays by vm.recentDays.collectAsStateWithLifecycle()
    SettingsSectionTC(
        icon = Icons.Filled.Science,
        title = uiString(R.string.l10n_test_centre_screen_experimental_algorithms_e09581e2),
        blurb = "Research-grade alternatives / precision tweaks. Opt-in, off by default, non-clinical.",
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            ToggleRowTC(
                title = uiString(R.string.l10n_test_centre_screen_hr_from_ppg_sub_lag_interpolation_a3ed1536),
                description = "When NOOP reconstructs heart rate from the WHOOP 5/MG v26 optical waveform (the " +
                    "seconds the strap stored no HR), refine the autocorrelation peak with a parabolic sub-lag " +
                    "fit so the estimate is not quantized to roughly 16 bpm steps near a high HR. It only fills " +
                    "seconds the strap never reported; it never overrides a stored HR. 5/MG only, off by default.",
                checked = ppgHrSubLag,
                onCheckedChange = { ppgHrSubLag = it; puffin.ppgHrSubLagInterp = it },
            )
            ToggleRowTC(
                title = uiString(R.string.l10n_test_centre_screen_hrv_readiness_plews_altini_bce6578f),
                description = "A read-only Plews/Altini smallest-worthwhile-change reading of your nightly HRV: " +
                    "it shows whether your 7-night HRV baseline sits above, inside, or below your personal " +
                    "normal band. It changes nothing else - the Charge ring is identical whether this is on or " +
                    "off. This is rough / early testing, not yet validated against varying real data (n=1).",
                checked = hrvReadiness,
                onCheckedChange = { hrvReadiness = it; puffin.hrvReadiness = it },
            )
            // The toggle's OWN effect, shown in place: when on, the live Plews/Altini reading. Nothing renders
            // when off, so the flag off is zero behaviour change and feeds no downstream gate.
            if (hrvReadiness) HrvReadinessReadoutTC(recentDays)
        }
    }
}

/**
 * Inline, opt-in HRV-readiness readout. Renders directly under the "HRV readiness (Plews/Altini)" toggle when
 * the flag is on, so the toggle's own effect is visible in place. Reads the SAME repo-merged nightly
 * [DailyMetric.avgHrv] series (oldest-first) the recovery UI has and runs it through the pure [HRVReadiness]
 * engine — it never touches the default Charge ring or analyzeDay. Below [HRVReadiness.MIN_NIGHTS] valid
 * nights it shows the honest calibrating count instead of a fabricated tier. Twin of the Swift
 * `hrvReadinessReadout`.
 */
@Composable
private fun HrvReadinessReadoutTC(days: List<DailyMetric>) {
    // Memoize the pure evaluate + valid-night count against the day-list identity so it only recomputes when
    // the series actually changes (not on every recomposition).
    val (result, validCount) = remember(days) {
        val cfg = Baselines.hrvCfg
        val series = days.map { it.avgHrv }
        val valid = series.count { v -> v != null && v >= cfg.minVal && v <= cfg.maxVal }
        HRVReadiness.evaluate(series) to valid
    }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (result != null) {
            val (word, color) = when (result.tier) {
                ReadinessTier.PRIMED -> "primed" to Palette.statusPositive
                ReadinessTier.NORMAL -> "normal" to Palette.textPrimary
                ReadinessTier.SUPPRESSED -> "suppressed" to Palette.statusWarning
            }
            Text(uiString(R.string.l10n_test_centre_screen_hrv_readiness_experimental_word_a471930e, word), style = NoopType.subhead, color = color)
            val base = result.baseline7Ms.roundToInt()
            val lo = result.normalLowMs.roundToInt()
            val hi = result.normalHighMs.roundToInt()
            val watch = if (result.overreachingWatch) ", overreaching watch" else ""
            Text(
                uiString(R.string.l10n_test_centre_screen_7_night_baseline_base_ms_normal_43d9cfa6, base, lo, hi, watch),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        } else {
            Text(uiString(R.string.l10n_test_centre_screen_hrv_readiness_experimental_924f61bc), style = NoopType.subhead, color = Palette.textTertiary)
            Text(
                uiString(R.string.l10n_test_centre_screen_calibrating_validcount_hrvreadiness_min_nights_nights_c5b21706, validCount, HRVReadiness.MIN_NIGHTS),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

/** A titled toggle + caption row for the Experimental algorithms card (same NoopType/Palette tokens + switch
 *  colours as the other Test Centre rows). Local to Test Centre so it never reaches into SettingsScreen. */
@Composable
private fun ToggleRowTC(
    title: String,
    description: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(title, style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                colors = settingsSwitchColors(),
            )
        }
        Text(description, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

@Composable
private fun ReportReviewDialog(
    previewText: String,
    modeInactive: Boolean,
    onCancel: () -> Unit,
    onShare: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onCancel,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_test_centre_screen_review_before_sharing_d7050383), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column {
                if (modeInactive) {
                    // #1002: the selected profile's test mode is off, so this bundle carries no capture
                    // for the very thing being reported. Warn plainly, with the fix, BEFORE the user
                    // ships a report a maintainer can't act on. Twin of the Swift review-sheet warning.
                    Text(
                        uiString(R.string.l10n_test_centre_screen_heads_up_this_test_mode_is_8b82ed69) +
                            "useful report, turn the mode on, reproduce the problem while wearing the " +
                            "strap, then report again.",
                        style = NoopType.footnote, color = Palette.statusWarning,
                        modifier = Modifier.padding(bottom = 8.dp),
                    )
                }
                Text(
                    uiString(R.string.l10n_test_centre_screen_this_is_exactly_what_your_report_77278bdd),
                    style = NoopType.subhead, color = Palette.textSecondary,
                )
                Text(
                    previewText.ifBlank { "(nothing to share yet)" },
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier
                        .padding(top = 8.dp)
                        .heightIn(max = 320.dp)
                        .verticalScroll(rememberScrollState()),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onShare) { Text(uiString(R.string.l10n_test_centre_screen_share_09ca55ca), style = NoopType.body, color = Palette.accent) }
        },
        dismissButton = {
            TextButton(onClick = onCancel) { Text(uiString(R.string.l10n_test_centre_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary) }
        },
    )
}

// MARK: - Local section + toggle wrappers (Test Centre owns its own so it never reaches into the private
// SettingsScreen.kt helpers; same NoopCard idiom).

@Composable
private fun SettingsSectionTC(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    blurb: String,
    content: @Composable () -> Unit,
) {
    NoopCard(padding = 20.dp, tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline("Test Centre")
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    androidx.compose.material3.Icon(
                        icon, contentDescription = null, tint = Palette.accent,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(title, style = NoopType.title2, color = Palette.textPrimary)
                }
            }
            Text(blurb, style = NoopType.subhead, color = Palette.textSecondary)
            content()
        }
    }
}

@Composable
private fun settingsSwitchColors() = SwitchDefaults.colors(
    checkedThumbColor = Palette.surfaceBase,
    checkedTrackColor = Palette.accent,
    uncheckedThumbColor = Palette.textSecondary,
    uncheckedTrackColor = Palette.surfaceInset,
    uncheckedBorderColor = Palette.hairline,
)
