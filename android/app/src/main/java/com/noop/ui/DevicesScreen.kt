package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.lazy.items
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
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import com.noop.ble.WhoopBleClient
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.SourceCoordinator
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.protocol.RebootProbeVariant
import com.noop.testcentre.TestCentre
import com.noop.testcentre.TestDomain
import kotlinx.coroutines.launch

// MARK: - Devices
//
// Pair and manage the bands NOOP reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over [com.noop.data.DeviceRegistry] (the Phase 1A/1B data layer):
// every mutation goes through an [AppViewModel] registry op, and the [SourceCoordinator] (wired in
// NoopApplication) reacts to the active-device change — so this view never touches the BLE client or the
// WHOOP path directly. Faithful Kotlin twin of Strand/Screens/DevicesView.swift.
//
// The registry's reads are one-shot suspend (not a Flow), so the screen keeps the list in a remembered
// state and reloads it after every mutation via [reload].

// MARK: - Liquid hero tokens (the liquid Devices restyle)
//
// The ACTIVE device card is the screen's hero: it floats over the day-of-sky as a translucent near-black
// frosted card so the strap name + the live battery tube stay crisp on it. Same tokens as the liquid Today
// hero (heroFill = rgba(13,14,20,.80), radius 26, white@0.11 hairline). Those Today constants are private to
// TodayScreen, so the identical values are declared here. Mirrors the iOS liquid heroCard.
private val LIQUID_HERO_FILL: Color = Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val LIQUID_HERO_RADIUS: Dp = 26.dp

@Composable
fun DevicesScreen(
    viewModel: AppViewModel,
    /** Routes to the non-destructive file-import lane (Data Sources). The Oura adopt wizard's "Keep the
     *  Oura app instead (import a file)" link and every honest Oura failure offer this. Defaults to a no-op
     *  so existing call sites keep compiling; AppRoot wires it to navigate to Data Sources. */
    onUseFileImport: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val live by viewModel.live.collectAsStateWithLifecycle()
    // #592 extended-battery probe result — non-null (incl. the " waiting" sentinel) shows the result dialog.
    val batteryProbeResult by viewModel.extendedBatteryProbe.collectAsStateWithLifecycle()
    // #690 body-location probe result — same non-null-shows-the-dialog contract.
    val bodyLocationProbeResult by viewModel.bodyLocationProbe.collectAsStateWithLifecycle()
    // #761: the read-only feature-flag ENUMERATION report (or the waiting sentinel while it walks).
    val featureFlagProbeResult by viewModel.featureFlagProbe.collectAsStateWithLifecycle()
    // #103: the read-only device-config READ report (or the waiting sentinel while the plan runs).
    val deviceConfigProbeResult by viewModel.deviceConfigProbe.collectAsStateWithLifecycle()

    // Liquid sky backdrop gate — the SAME "Day-cycle background" preference the liquid Today honours (#698,
    // default ON). Off falls back to the flat dark canvas, so the setting governs every liquid screen alike.
    val context = LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    // The current device list, reloaded after each registry op. Null while the first read is in flight.
    var devices by remember { mutableStateOf<List<PairedDeviceRow>?>(null) }
    fun reload() {
        scope.launch { devices = viewModel.pairedDevices() }
    }
    LaunchedEffect(Unit) { devices = viewModel.pairedDevices() }

    // Sheets / dialogs (mirror the Swift @State targets).
    var showAddWizard by remember { mutableStateOf(false) }
    var switchTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var renameTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var removeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var deleteDataTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var rebootTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    // WHOOP 4.0 reboot probe (Test Centre → Connection, 4.0 only) — the device whose probe sheet is open.
    var probeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var batteryProbeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var bodyLocationProbeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var featureFlagProbeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var deviceConfigProbeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    // After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    var pickNewActive by remember { mutableStateOf(false) }

    val all = devices.orEmpty()
    val activeDevices = all.filter { it.status != DeviceStatus.archived.name }
    val removedDevices = all.filter { it.status == DeviceStatus.archived.name }
    val currentActiveName =
        all.firstOrNull { it.status == DeviceStatus.active.name }?.let { displayName(it) }
            ?: "Your current strap"

    // PERF (#707): lazy scaffold — each device card is virtualized via `items(...)` (each was a direct
    // child of the eager `spacedBy(20.dp)` column, so the LazyColumn's matching spacing is identical) and
    // the static button/footer are single items. Only on-screen cards compose + are accessibility-walked.
    // Conditional rows use `if (cond) { item/items }` so a hidden section adds no row.
    LazyScreenScaffold(
        title = uiString(R.string.l10n_devices_screen_devices_df485c87),
        subtitle = "Pair and manage the bands NOOP reads from.",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles
        // into the flat canvas behind the top of the screen so the frosted device cards float over it. The
        // static sky (LiquidSkyStatic inside the helper) carries no per-frame cost on this scrolling list.
        // Gated on the same "Day-cycle background" setting as Today; off passes null for the plain canvas.
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        // #802: the re-pair guide belongs HERE too, not only on Live. A strap that connects but never
        // finishes bonding leaves the user on this screen — it is where you go to fix a device — while the
        // four steps that actually resolve it were rendered one tab away. The reporter in #802 filed an
        // issue with the guide already armed, because nothing on Devices said so. Same state, same strings
        // as LiveScreen; no new copy.
        live.reconnectGuide?.let { guide ->
            item {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Palette.surfaceRaised, RoundedCornerShape(12.dp))
                        .border(1.dp, Palette.statusWarning.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_live_screen_can_t_connect_your_strap_s_cf78be83),
                        style = NoopType.subhead,
                        color = Palette.textPrimary,
                    )
                    Text(guide, style = NoopType.footnote, color = Palette.textSecondary)
                }
            }
        }

        if (devices == null) {
            // The registry resolves a beat after launch. Show a calm pending note in that brief window.
            item {
            DataPendingNote(
                title = uiString(R.string.l10n_devices_screen_getting_your_devices_ready_bd391949),
                body = "NOOP is opening your on-device data. Your paired bands will appear here in a moment.",
            )
            }
            return@LazyScreenScaffold
        }

        items(activeDevices) { device ->
            DeviceCard(
                device = device,
                isActive = device.status == DeviceStatus.active.name,
                isLiveConnected = device.status == DeviceStatus.active.name && live.connected,
                // #221: a WHOOP 5/MG can be BLE-connected yet have its ENCRYPTED bond refused (the WHOOP
                // app, or a stale pairing, holds the single-app bond) — no HR/biometric data flows even
                // though the link is up, so "Active · Live" overstates it. pairingHint is set only once
                // that refusal is genuinely detected (#78), never during a normal connect, so this can't
                // false-alarm a working 4.0 (its pairingHint stays null) or a fresh 5/MG connect.
                bondRefused = device.status == DeviceStatus.active.name && live.connected && live.pairingHint != null,
                // The full #78 how-to-fix guidance, surfaced on the card itself when bondRefused so the
                // fix is self-service instead of buried in the strap log.
                pairingHint = if (device.status == DeviceStatus.active.name) live.pairingHint else null,
                // Reboot in flight + link currently down → "Reconnecting…" (#166).
                isReconnecting = device.status == DeviceStatus.active.name && live.rebootInProgress && !live.connected,
                // The live battery belongs to whichever device is ACTIVE + connected (WHOOP, a generic
                // strap, or an FTMS machine all funnel into live.batteryPct). null otherwise.
                liveBatteryPct = if (device.status == DeviceStatus.active.name && live.connected)
                    live.batteryPct?.let { Math.round(it).toInt() } else null,
                liveBatteryMv = if (device.status == DeviceStatus.active.name && live.connected)
                    live.batteryMv else null,
                // Firmware version for the ACTIVE strap. It's a STABLE property (NOOP can't change a strap's
                // firmware), so prefer the live handshake value but fall back to the last-known persisted
                // firmware (NoopPrefs, written on connect) when the live value is momentarily null — mid-
                // handshake, or a connection that hasn't re-read REPORT_VERSION_INFO yet this session. Without
                // this the "· FW x" blanks out while actively connected + syncing. The persisted fallback is
                // WHOOP-only: `noop.lastFirmware` is written solely from a WHOOP handshake, so a non-WHOOP
                // active device (Oura/FTMS) must NOT inherit it. Single-key, so on a multi-WHOOP install a
                // not-yet-connected active strap can briefly show the other strap's build until it republishes.
                liveFirmware = if (device.status == DeviceStatus.active.name)
                    (live.strapFirmware
                        ?: if (device.brand.equals("WHOOP", ignoreCase = true)) NoopPrefs.lastFirmware(context) else null)
                    else null,
                // Historical record layout from the current backfill, distinct from strap firmware.
                liveHistoryLayout = if (device.status == DeviceStatus.active.name && live.connected)
                    live.historyLayoutVersion else null,
                onMakeActive = { switchTarget = device },
                onRename = { renameTarget = device },
                onRemove = { removeTarget = device },
                // Manual connect and disconnect for the WHOOP. A short toast confirms the tap, since the link
                // state only changes a few seconds later.
                onConnect = if (device.brand.equals("WHOOP", ignoreCase = true)) {
                    { Toast.makeText(context, "Reconnecting…", Toast.LENGTH_SHORT).show(); viewModel.connect() }
                } else null,
                onDisconnect = if (device.brand.equals("WHOOP", ignoreCase = true)) {
                    { Toast.makeText(context, "Disconnecting", Toast.LENGTH_SHORT).show(); viewModel.disconnect() }
                } else null,
                // Restart is offered only for a live-connected WHOOP that is NOT a 4.0: the strap-log
                // analysis on #275 showed no safe frame reboots a 4.0 (empty bodies are ignored; any
                // non-empty body just wedges the BLE link for ~7s, sensor stays on), so a 4.0 Restart
                // button could never work. 5.0/MG reboot on the production frame. null otherwise.
                onReboot = if (device.status == DeviceStatus.active.name && live.connected &&
                    SourceCoordinator.isWhoop(device) && live.whoop5Detected
                ) { { rebootTarget = device } } else null,
                // 4.0 reboot probe: only offered when Test Centre → Connection is on AND the live strap is
                // a WHOOP 4.0 (a 5.0 already reboots on the production frame). null otherwise.
                onRebootProbe = if (device.status == DeviceStatus.active.name && live.connected &&
                    SourceCoordinator.isWhoop(device) && !live.whoop5Detected &&
                    TestCentre.from(context).active(TestDomain.CONNECTION)
                ) { { probeTarget = device } } else null,
                // #592 extended-battery opcode probe: read-only, BOTH families (the 4.0 is the
                // discriminating device, but a 5/MG capture is useful too). Same Test Centre →
                // Connection gate as the reboot probe.
                onBatteryProbe = if (device.status == DeviceStatus.active.name && live.connected &&
                    SourceCoordinator.isWhoop(device) &&
                    TestCentre.from(context).active(TestDomain.CONNECTION)
                ) { { batteryProbeTarget = device } } else null,
                // #690 body-location opcode probe: read-only, both families. Same Test Centre gate.
                onBodyLocationProbe = if (device.status == DeviceStatus.active.name && live.connected &&
                    SourceCoordinator.isWhoop(device) &&
                    TestCentre.from(context).active(TestDomain.CONNECTION)
                ) { { bodyLocationProbeTarget = device } } else null,
                // #761 feature-flag ENUMERATION probe: read-only (names only, nothing written), both
                // families. Same Test Centre gate.
                onFeatureFlagProbe = if (device.status == DeviceStatus.active.name && live.connected &&
                    SourceCoordinator.isWhoop(device) &&
                    TestCentre.from(context).active(TestDomain.CONNECTION)
                ) { { featureFlagProbeTarget = device } } else null,
                // Stop an offload already in flight. Offered ONLY while one is running on this strap —
                // not a Test Centre probe but an ordinary escape hatch, because until now a long drain
                // could only be ended by the timeout or walking out of range. Nothing is lost: unacked
                // records stay on the strap.
                onAbortSync = if (device.status == DeviceStatus.active.name && live.connected &&
                    WhoopBleClient.canAbortSync(live.backfilling) && SourceCoordinator.isWhoop(device)
                ) { { viewModel.abortBackfill() } } else null,
                // #103 device-config READ probe: read-only (asks for VALUES, writes none), both
                // families. Same Test Centre gate.
                onDeviceConfigProbe = if (device.status == DeviceStatus.active.name && live.connected &&
                    SourceCoordinator.isWhoop(device) &&
                    TestCentre.from(context).active(TestDomain.CONNECTION)
                ) { { deviceConfigProbeTarget = device } } else null,
            )
        }

        // Prominent "+ Add a device" button.
        item { AddDeviceButton(onClick = { showAddWizard = true }) }

        if (removedDevices.isNotEmpty()) {
            item { Overline("Removed", modifier = Modifier.padding(top = 4.dp)) }
            items(removedDevices) { device ->
                DeviceCard(
                    device = device,
                    isActive = false,
                    isLiveConnected = false,
                    dimmed = true,
                    onMakeActive = { switchTarget = device },
                    onRename = { renameTarget = device },
                    onRemove = null,
                    onReAdd = { switchTarget = device },
                    onDeleteData = { deleteDataTarget = device },
                )
            }
        }

        item { WhoopFirstFooter() }
    }

    // --- Add a device (guided, branching wizard: WHOOP family · HR strap · coming-soon rows) ---
    if (showAddWizard) {
        AddDeviceWizard(
            viewModel = viewModel,
            onClose = { showAddWizard = false; reload() },
            // The Oura gate's file-import links close the wizard and route to Data Sources, so the
            // non-destructive lane is always one tap away (it is never the only door).
            onUseFileImport = { showAddWizard = false; reload(); onUseFileImport() },
        )
    }

    // --- Switch confirm ---
    switchTarget?.let { device ->
        ConfirmDialog(
            title = uiString(R.string.l10n_devices_screen_make_this_your_active_strap_fea6bebd),
            message = "Make ${displayName(device)} your active strap? From now on it provides your live data. " +
                "$currentActiveName's history stays exactly as it is. Only new days come from ${displayName(device)}.",
            confirmLabel = "Make active",
            onConfirm = {
                scope.launch { viewModel.setActiveDevice(device.id); reload() }
                switchTarget = null
            },
            onDismiss = { switchTarget = null },
        )
    }

    // --- Rename ---
    renameTarget?.let { device ->
        RenameDialog(
            device = device,
            onSave = { name ->
                scope.launch { viewModel.renamePairedDevice(device.id, name); reload() }
                renameTarget = null
            },
            onDismiss = { renameTarget = null },
        )
    }

    // --- Remove confirm ---
    removeTarget?.let { device ->
        ConfirmDialog(
            title = uiString(R.string.l10n_devices_screen_remove_this_device_dd9dbda9),
            message = "Remove ${displayName(device)}? NOOP will stop connecting to it. Its recorded data is " +
                "kept and you can re-add it any time.",
            confirmLabel = "Remove",
            destructive = true,
            onConfirm = {
                val wasActive = device.status == DeviceStatus.active.name
                scope.launch {
                    viewModel.archivePairedDevice(device.id)
                    devices = viewModel.pairedDevices()
                    // If the removed device was active and other paired devices remain, prompt to pick a
                    // new active one (the registry's reload demotes the active row to paired).
                    if (wasActive && devices.orEmpty().any { it.status != DeviceStatus.archived.name }) {
                        pickNewActive = true
                    }
                }
                removeTarget = null
            },
            onDismiss = { removeTarget = null },
        )
    }

    // --- Restart strap confirm (#166) ---
    rebootTarget?.let { device ->
        ConfirmDialog(
            title = uiString(R.string.l10n_devices_screen_restart_this_strap_50fc481b),
            message = "Restart ${displayName(device)}? It disconnects for about 30 seconds while it " +
                "reboots, then reconnects on its own. Your recorded data is kept.",
            confirmLabel = "Restart",
            destructive = false,
            onConfirm = { viewModel.rebootStrap(); rebootTarget = null },
            onDismiss = { rebootTarget = null },
        )
    }

    // --- WHOOP 4.0 reboot probe (#235): only reachable with Test Centre → Connection on + a 4.0 connected.
    //     Tries each candidate frame one at a time so the strap log shows which one actually reboots. ---
    probeTarget?.let {
        RebootProbeDialog(
            onSend = { variant -> viewModel.rebootProbe(variant); probeTarget = null },
            onDismiss = { probeTarget = null },
        )
    }

    // --- #592 extended-battery opcode probe: read-only, dumps the strap's full raw reply to the log so a
    //     normal export settles the disputed GET_EXTENDED_BATTERY_INFO number (98 vs an APK decompile's 87). ---
    batteryProbeTarget?.let {
        BatteryInfoProbeDialog(
            onSend = { viewModel.probeExtendedBatteryInfo(); batteryProbeTarget = null },
            onDismiss = { batteryProbeTarget = null },
        )
    }

    // #592: the probe reply (or the " waiting" sentinel while in flight) — readable + copyable in place,
    // so a capture doesn't need a full strap-log export to read or share.
    batteryProbeResult?.let { result ->
        BatteryInfoProbeResultDialog(
            text = result,
            onDismiss = { viewModel.clearExtendedBatteryProbe() },
        )
    }
    // #690 body-location opcode probe: read-only send + full raw-response dump + decoded record.
    bodyLocationProbeTarget?.let {
        BodyLocationProbeDialog(
            onSend = { viewModel.probeBodyLocationAndStatus(); bodyLocationProbeTarget = null },
            onDismiss = { bodyLocationProbeTarget = null },
        )
    }
    bodyLocationProbeResult?.let { result ->
        BodyLocationProbeResultDialog(
            text = result,
            onDismiss = { viewModel.clearBodyLocationProbe() },
        )
    }
    // #761 feature-flag ENUMERATION probe: read-only key-name listing (117 then repeated 118); no value
    // is written to the strap.
    featureFlagProbeTarget?.let {
        FeatureFlagProbeDialog(
            onSend = { viewModel.probeFeatureFlags(); featureFlagProbeTarget = null },
            onDismiss = { featureFlagProbeTarget = null },
        )
    }
    featureFlagProbeResult?.let { result ->
        FeatureFlagProbeResultDialog(
            text = result,
            onDismiss = { viewModel.clearFeatureFlagProbe() },
        )
    }
    // #103 device-config READ probe: read-only VALUE reads (121/128); no value is written to the strap.
    deviceConfigProbeTarget?.let {
        DeviceConfigProbeDialog(
            onSend = { viewModel.probeDeviceConfigValues(); deviceConfigProbeTarget = null },
            onDismiss = { deviceConfigProbeTarget = null },
        )
    }
    deviceConfigProbeResult?.let { result ->
        DeviceConfigProbeResultDialog(
            text = result,
            onDismiss = { viewModel.clearDeviceConfigProbe() },
        )
    }

    // --- Second, strongly-worded delete-data confirm (from the Removed card's secondary control) ---
    deleteDataTarget?.let { device ->
        ConfirmDialog(
            title = uiString(R.string.l10n_devices_screen_delete_all_of_this_device_s_754cde90),
            message = "This permanently deletes all data recorded from ${displayName(device)}. This can't be undone.",
            confirmLabel = "Delete data",
            destructive = true,
            onConfirm = {
                scope.launch { viewModel.deletePairedDeviceData(device.id); reload() }
                deleteDataTarget = null
            },
            onDismiss = { deleteDataTarget = null },
        )
    }

    // --- After removing the active device, offer to pick a new active one (if any remain) ---
    if (pickNewActive) {
        PickActiveDialog(
            devices = activeDevices,
            onPick = { device ->
                scope.launch { viewModel.setActiveDevice(device.id); reload() }
                pickNewActive = false
            },
            onLeaveNone = { pickNewActive = false },
        )
    }
}

// MARK: - Device card

/** One paired device as a [NoopCard]: name, brand·model, a capabilities line, a state pill, last-seen,
 *  and a per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries
 *  an "Active" pill. */
@Composable
private fun DeviceCard(
    device: PairedDeviceRow,
    isActive: Boolean,
    isLiveConnected: Boolean,
    /** #221: the active+connected strap is BLE-linked but its encrypted bond was refused (#78 state) — no
     *  HR/biometric data flows despite the link being up. Drives the "Connected · not paired" pill (which
     *  takes priority over "Active · Live") and the honest subtitle. False for every non-WHOOP source and
     *  for a normal connect. */
    bondRefused: Boolean = false,
    /** #221: the full #78 pairing-refusal guidance (bonded-elsewhere / pairing-mode / forget-device
     *  steps), shown on the card when [bondRefused] so the fix is self-service. null otherwise. */
    pairingHint: String? = null,
    /** The active strap's link dropped for a user-initiated reboot and NOOP is auto-reconnecting (#166).
     *  Drives the transient "Reconnecting…" pill; false for every non-reboot state. */
    isReconnecting: Boolean = false,
    dimmed: Boolean = false,
    /** The active+connected device's live battery percent (0–100) — surfaced the same way for WHOOP, a
     *  generic strap, or an FTMS machine. null when not active/connected or no battery was reported. */
    liveBatteryPct: Int? = null,
    liveBatteryMv: Int? = null,
    /** The active+connected strap's firmware version (from the connect handshake). null when not
     *  active/connected, or for a source that reports no firmware (e.g. a non-WHOOP strap). */
    liveFirmware: String? = null,
    /** The active+connected strap's observed banked-history record layout (`hist_version`). */
    liveHistoryLayout: Int? = null,
    onMakeActive: () -> Unit,
    onRename: () -> Unit,
    onRemove: (() -> Unit)?,
    onReAdd: (() -> Unit)? = null,
    onDeleteData: (() -> Unit)? = null,
    onConnect: (() -> Unit)? = null,
    onDisconnect: (() -> Unit)? = null,
    onReboot: (() -> Unit)? = null,
    // WHOOP 4.0 reboot probe (Test Centre → Connection, 4.0 only). Non-null only when the parent has
    // decided the probe applies (live-connected WHOOP 4.0 + Connection test mode on); null otherwise. (#235)
    onRebootProbe: (() -> Unit)? = null,
    // #592 extended-battery opcode probe (Test Centre → Connection, both WHOOP families). Read-only.
    onBatteryProbe: (() -> Unit)? = null,
    // #690 body-location opcode probe (Test Centre → Connection, both WHOOP families). Read-only.
    onBodyLocationProbe: (() -> Unit)? = null,
    /** #761 feature-flag ENUMERATION probe (Test Centre → Connection, both WHOOP families). Read-only:
     *  it reads the flag NAMES the strap's firmware knows and writes nothing. */
    onFeatureFlagProbe: (() -> Unit)? = null,
    onAbortSync: (() -> Unit)? = null,
    /** #103 device-config READ probe (Test Centre → Connection, both WHOOP families). Read-only: it asks
     *  the strap for a config key's VALUE and writes none. */
    onDeviceConfigProbe: (() -> Unit)? = null,
) {
    val profile = deviceProfile(device)
    // The per-device actions menu's open state is hoisted here so the WHOLE card is a tap target that opens
    // the same menu the trailing ⋮ button does — additive, non-destructive (the menu still gates every
    // action + confirm), and it gives the card a real `clickable` to drive `liquidPress`.
    var menuOpen by remember { mutableStateOf(false) }
    // liquidPress: the SAME interactionSource feeds the card's clickable and the press modifier, so the
    // whole card settles inward on press (the iOS LiquidPressStyle feel). Applied on the OUTER card so the
    // frosted surface + content scale/dim as one, matching the liquid Today cards.
    val interaction = remember { MutableInteractionSource() }
    val cardModifier = Modifier
        .alpha(if (dimmed) 0.6f else 1f)
        .liquidPress(interaction)
        .clickable(
            interactionSource = interaction,
            indication = null,
            onClickLabel = "Device actions for ${displayName(device)}",
        ) { menuOpen = true }

    // The ACTIVE device is the hero: the liquid translucent-black frosted card (rgba(13,14,20,.80), radius
    // 26, white@0.11 hairline) so it floats over the day-of-sky, matching the liquid Today hero. Every other
    // card (paired / removed) keeps the crisp neutral NoopCard frosted surface.
    val body: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    imageVector = deviceIcon(device),
                    contentDescription = null,
                    tint = if (isActive) Palette.accent else Palette.textSecondary,
                    modifier = Modifier.size(28.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(displayName(device), style = NoopType.headline, color = Palette.textPrimary)
                    Text(profile.displayModel, style = NoopType.subhead, color = Palette.textSecondary)
                }
                // Locally-adopted Oura is Beta: a non-dot Beta chip sits beside the usual state pill.
                if (device.sourceKind == SourceKind.oura.name) {
                    StatePill("Beta", tone = StrandTone.Warning, showsDot = false)
                    Spacer(Modifier.width(6.dp))
                }
                StatePill(device, isActive, isLiveConnected, bondRefused, isReconnecting)
            }

            // Honest local-takeover state row for an adopted Oura ring that is paired but not the
            // active+connected source right now. States the single-owner reality plainly (if the ring was
            // reset again or re-claimed in the Oura app, NOOP no longer owns it) without faking a live
            // reading. Suppressed for the active+connected ring and for removed rings. Mirrors the macOS
            // ouraLocalStateNote.
            if (device.sourceKind == SourceKind.oura.name && !isLiveConnected &&
                device.status == DeviceStatus.paired.name
            ) {
                OuraLocalStateNote()
            }

            // What this device CAPTURES — honest, per-model (not the generic stored set, which would
            // mislabel e.g. a "Blood oxygen" chip when no SpO₂ % ever comes off the strap).
            CapabilityInfoRow(Icons.Filled.FavoriteBorder, profile.captures)
            // What NOOP USES it for — the scores / screens this device drives.
            CapabilityInfoRow(Icons.Filled.Bolt, profile.powers)
            // Honest footnote: the "*" estimates + the SpO₂/steps caveats.
            if (profile.footnote.isNotEmpty()) {
                Text(profile.footnote, style = NoopType.footnote, color = Palette.textTertiary)
            }

            // #221: the full #78 pairing-refusal guidance, self-service right on the card instead of
            // buried in the strap log — only when the bond was genuinely refused.
            if (bondRefused && pairingHint != null) {
                Text(pairingHint, style = NoopType.footnote, color = Palette.statusWarning)
            }

            // Live battery as a small liquid TUBE — the active+connected device's reported % (WHOOP, a
            // generic strap or an FTMS machine all funnel into live.batteryPct). A genuine single-value
            // progress bar, so a static (posed) LiquidTube is exactly right; it replaces the "· Battery x%"
            // that used to sit in the text line below. The SAME `liveBatteryPct` binding drives it.
            if (liveBatteryPct != null) {
                BatteryTube(pct = liveBatteryPct)
            }

            // #592: strap pack voltage (mV → volts, 2dp) beside the percent, when the battery event has
            // reported it. Localized unit resource; purely additive, the percent tube is unchanged.
            val voltsSuffix = if (liveBatteryMv != null)
                " · " + stringResource(R.string.l10n_devices_screen_pack_voltage_9af3c3ff, liveBatteryMv / 1000.0)
            else ""
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    lastSeenLine(device, isLiveConnected, bondRefused) +
                        (liveFirmware?.let { " · FW $it" } ?: "") +
                        voltsSuffix +
                        (historyLayoutLine(liveHistoryLayout)?.let { " · $it" } ?: ""),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.weight(1f),
                )
                DeviceActionsMenu(
                    device = device,
                    isActive = isActive,
                    isLiveConnected = isLiveConnected,
                    open = menuOpen,
                    onOpenChange = { menuOpen = it },
                    onMakeActive = onMakeActive,
                    onRename = onRename,
                    onRemove = onRemove,
                    onReAdd = onReAdd,
                    onDeleteData = onDeleteData,
                    onConnect = onConnect,
                    onDisconnect = onDisconnect,
                    onReboot = onReboot,
                    onRebootProbe = onRebootProbe,
                    onBatteryProbe = onBatteryProbe,
                    onBodyLocationProbe = onBodyLocationProbe,
                    onFeatureFlagProbe = onFeatureFlagProbe,
                onAbortSync = onAbortSync,
                    onDeviceConfigProbe = onDeviceConfigProbe,
                )
            }
        }
    }

    if (isActive) {
        Box(
            modifier = cardModifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
                .background(LIQUID_HERO_FILL.copy(alpha = LIQUID_HERO_FILL.alpha * CardAppearance.opacity))
                .border(1.dp, Color.White.copy(alpha = 0.11f * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
                .padding(18.dp),
        ) {
            body()
        }
    } else {
        NoopCard(
            modifier = cardModifier,
            padding = 18.dp,
        ) {
            body()
        }
    }
}

/**
 * The active+connected device's live battery as a small liquid tube. A posed (static) [LiquidTube] fills to
 * the reported percent in the accent, with a leading "Battery" label + the trailing %, so the same figure
 * that used to read as "· Battery x%" in the meta line now reads as the liquid vessel the design calls for.
 */
@Composable
private fun BatteryTube(pct: Int) {
    val clamped = pct.coerceIn(0, 100)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_devices_screen_battery_clamped_2494c8c9, clamped) },
    ) {
        Text(uiString(R.string.l10n_devices_screen_battery_4a9be042), style = NoopType.footnote, color = Palette.textTertiary)
        LiquidTube(
            frac = clamped / 100.0,
            tint = Palette.accent,
            animated = false,
            modifier = Modifier.weight(1f),
        )
        Text(uiString(R.string.l10n_devices_screen_clamped_1f39cebb, clamped), style = NoopType.footnote, color = Palette.textSecondary)
    }
}

/**
 * The device card's state-pill label + tone, as a priority-ordered pure decision (#221): archived beats
 * everything; on the active card, reconnecting > bond-refused > live > plain active; a non-active card is
 * "Paired". Mirrors the Swift `DevicePillState.resolve` in DevicesView.swift exactly (see
 * `DevicePillStateTest` / the Swift `DevicePillStateTests`), so a future edit to either side can't
 * silently reorder "Connected · not paired" vs "Active · Live" without a test catching it.
 */
internal data class DevicePillState(
    val label: String,
    val tone: StrandTone,
    val pulsing: Boolean = false,
    val showsDot: Boolean = true,
)

internal fun devicePillState(
    isArchived: Boolean,
    isActive: Boolean,
    isReconnecting: Boolean,
    bondRefused: Boolean,
    isLiveConnected: Boolean,
): DevicePillState = when {
    isArchived -> DevicePillState("Removed", StrandTone.Neutral, showsDot = false)
    !isActive -> DevicePillState("Paired", StrandTone.Neutral)
    // Reboot window (#166): the user's Restart dropped the link and NOOP is auto-reconnecting. Show it
    // as intentional rather than a silent drop to "Active"; clears to "Active · Live" once the link is back.
    isReconnecting -> DevicePillState("Reconnecting…", StrandTone.Warning, pulsing = true)
    // #221: BLE-connected but the encrypted bond was refused — no data flows, so this must not read
    // as "Active · Live".
    bondRefused -> DevicePillState("Connected · not paired", StrandTone.Warning)
    isLiveConnected -> DevicePillState("Active · Live", StrandTone.Positive, pulsing = true)
    else -> DevicePillState("Active", StrandTone.Positive)
}

@Composable
private fun StatePill(
    device: PairedDeviceRow,
    isActive: Boolean,
    isLiveConnected: Boolean,
    bondRefused: Boolean = false,
    isReconnecting: Boolean = false,
) {
    val state = devicePillState(
        isArchived = device.status == DeviceStatus.archived.name,
        isActive = isActive,
        isReconnecting = isReconnecting,
        bondRefused = bondRefused,
        isLiveConnected = isLiveConnected,
    )
    StatePill(state.label, tone = state.tone, showsDot = state.showsDot, pulsing = state.pulsing)
}

@Composable
private fun DeviceActionsMenu(
    device: PairedDeviceRow,
    isActive: Boolean,
    isLiveConnected: Boolean,
    // Open state is hoisted to the DeviceCard so the whole card (not just this ⋮ button) can open the menu.
    open: Boolean,
    onOpenChange: (Boolean) -> Unit,
    onMakeActive: () -> Unit,
    onRename: () -> Unit,
    onRemove: (() -> Unit)?,
    onReAdd: (() -> Unit)?,
    onDeleteData: (() -> Unit)?,
    onConnect: (() -> Unit)? = null,
    onDisconnect: (() -> Unit)? = null,
    onReboot: (() -> Unit)? = null,
    onRebootProbe: (() -> Unit)? = null,
    onBatteryProbe: (() -> Unit)? = null,
    onBodyLocationProbe: (() -> Unit)? = null,
    /** #761 feature-flag ENUMERATION probe (Test Centre → Connection, both WHOOP families). Read-only:
     *  it reads the flag NAMES the strap's firmware knows and writes nothing. */
    onFeatureFlagProbe: (() -> Unit)? = null,
    onAbortSync: (() -> Unit)? = null,
    /** #103 device-config READ probe (Test Centre → Connection, both WHOOP families). Read-only: it asks
     *  the strap for a config key's VALUE and writes none. */
    onDeviceConfigProbe: (() -> Unit)? = null,
) {
    Box {
        IconButton(
            onClick = { onOpenChange(true) },
            modifier = Modifier
                .size(32.dp)
                .semantics { contentDescription = uiString(R.string.l10n_devices_screen_device_actions_for_displayname_device_160eb3de, displayName(device)) },
        ) {
            Icon(Icons.Filled.MoreVert, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(20.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { onOpenChange(false) }) {
            if (device.status == DeviceStatus.archived.name) {
                if (onReAdd != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_make_active_75690bb8), Icons.Filled.Bolt) { onOpenChange(false); onReAdd() }
                }
                MenuItem(uiString(R.string.l10n_devices_screen_rename_d3f4cb89), Icons.Filled.Edit) { onOpenChange(false); onRename() }
                if (onDeleteData != null) {
                    HorizontalDivider(color = Palette.hairline)
                    MenuItem(uiString(R.string.l10n_devices_screen_delete_this_device_s_data_3cae7a2a), Icons.Filled.Delete, destructive = true) {
                        onOpenChange(false); onDeleteData()
                    }
                }
            } else {
                // Manual connect and disconnect (WHOOP only; onConnect is null for other sources). Connect
                // runs the same direct path as the initial connect, so it recovers a link the automatic
                // reconnect left stuck. Shown first as the obvious recovery action.
                if (onConnect != null) {
                    if (isLiveConnected) {
                        MenuItem(uiString(R.string.l10n_devices_screen_disconnect_ed28e068), Icons.Filled.Close) { onOpenChange(false); onDisconnect?.invoke() }
                    } else {
                        MenuItem(uiString(R.string.l10n_devices_screen_reconnect_6988b16a), Icons.Filled.Refresh) { onOpenChange(false); onConnect() }
                    }
                    HorizontalDivider(color = Palette.hairline)
                }
                if (!isActive) {
                    MenuItem(uiString(R.string.l10n_devices_screen_make_active_75690bb8), Icons.Filled.Bolt) { onOpenChange(false); onMakeActive() }
                }
                MenuItem(uiString(R.string.l10n_devices_screen_rename_d3f4cb89), Icons.Filled.Edit) { onOpenChange(false); onRename() }
                // Restart the strap — only for the live-connected WHOOP (the reboot travels over the active
                // BLE link). Confirmation-gated by the parent. (#166)
                if (isLiveConnected && SourceCoordinator.isWhoop(device) && onReboot != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_restart_strap_c976cd6c), Icons.Filled.Refresh) { onOpenChange(false); onReboot() }
                }
                // 4.0 reboot probe (RE): only present when the parent passed a closure (Test Centre →
                // Connection on + a live WHOOP 4.0). Finds the real reboot frame the 4.0 accepts (#235).
                if (onRebootProbe != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_reboot_probe_4_0_re_828b3916), Icons.Filled.BugReport) { onOpenChange(false); onRebootProbe() }
                }
                // #592: read-only extended-battery opcode probe — settles the disputed GET_EXTENDED_
                // BATTERY_INFO number (98 vs an APK decompile's 87) from a strap-log export.
                if (onBatteryProbe != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_battery_info_probe_592_re_1dbd4c0f), Icons.Filled.BugReport) { onOpenChange(false); onBatteryProbe() }
                }
                // #690: read-only body-location opcode probe — decodes revision/location/confidence/status.
                if (onBodyLocationProbe != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_body_location_probe_690_re_7def8c39), Icons.Filled.BugReport) { onOpenChange(false); onBodyLocationProbe() }
                }
                // #761 feature-flag ENUMERATION probe (RE): read-only key-name listing, both families.
                if (onAbortSync != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_stop_sync_4a1f2b6e), Icons.Filled.StopCircle) { onOpenChange(false); onAbortSync() }
                }
                if (onFeatureFlagProbe != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_feature_flag_probe_761_re_21241d68), Icons.Filled.BugReport) { onOpenChange(false); onFeatureFlagProbe() }
                }
                // #103 device-config READ probe (RE): read-only VALUE reads, both families.
                if (onDeviceConfigProbe != null) {
                    MenuItem(uiString(R.string.l10n_devices_screen_device_config_read_probe_103_re_837f46de), Icons.Filled.BugReport) { onOpenChange(false); onDeviceConfigProbe() }
                }
                if (onRemove != null) {
                    HorizontalDivider(color = Palette.hairline)
                    MenuItem(uiString(R.string.l10n_devices_screen_remove_e963907d), Icons.Filled.RemoveCircleOutline, destructive = true) {
                        onOpenChange(false); onRemove()
                    }
                }
            }
        }
    }
}

@Composable
private fun MenuItem(
    label: String,
    icon: ImageVector,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val color = if (destructive) Palette.statusCritical else Palette.textPrimary
    DropdownMenuItem(
        text = { Text(label, style = NoopType.body, color = color) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp)) },
        onClick = onClick,
    )
}

@Composable
private fun AddDeviceButton(onClick: () -> Unit) {
    // Routed through the unified NoopButton (Design Reset) so the add affordance is the crisp
    // filled-accent-blue / white-label primary the iOS DevicesView uses (`NoopButton(... kind: .primary,
    // fullWidth: true)`) — no hand-rolled gold-text fill, no glow.
    NoopButton(
        text = uiString(R.string.l10n_devices_screen_add_a_device_f90866b8),
        leadingIcon = Icons.Filled.Add,
        kind = NoopButtonKind.Primary,
        fullWidth = true,
        modifier = Modifier
            .padding(top = 4.dp)
            .semantics { contentDescription = uiString(R.string.l10n_devices_screen_add_a_device_f90866b8) },
        onClick = onClick,
    )
}

@Composable
private fun WhoopFirstFooter() {
    Row(
        modifier = Modifier.padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.FavoriteBorder,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            uiString(R.string.l10n_devices_screen_whoop_is_noop_s_primary_fully_1c9e67fd) +
                "in-development addition: they stream live heart rate and HRV, but not WHOOP's deeper " +
                "sleep and recovery data.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Shared dialogs

@Composable
private fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    cancelLabel: String = "Cancel",
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(title, style = NoopType.title2, color = Palette.textPrimary) },
        text = { Text(message, style = NoopType.subhead, color = Palette.textSecondary) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(
                    confirmLabel,
                    style = NoopType.body,
                    color = if (destructive) Palette.statusCritical else Palette.accent,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(cancelLabel, style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** WHOOP 4.0 reboot probe (#235): a candidate list, one button per unconfirmed reboot frame. Gated to
 *  Test Centre → Connection + a live 4.0 at the call site. Twin of the macOS DevicesView confirmationDialog. */
@Composable
private fun RebootProbeDialog(
    onSend: (RebootProbeVariant) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_whoop_4_0_reboot_probe_b51fb50f), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    uiString(R.string.l10n_devices_screen_the_whoop_4_0_reboot_frame_690a8ff2) +
                        "Send each candidate and watch BOTH the strap log and the strap itself. " +
                        "“no disconnect within 12s” means the strap ignored the frame. A “link dropped” line " +
                        "means the frame reached the strap — but a dropped link alone isn't a reboot: a real " +
                        "reboot also switches the strap's sensor light off for a few seconds, so if the light " +
                        "stayed on it was just a dropped connection, not a reboot. Non-destructive — your data " +
                        "is kept. Please share the log so we can pin the real frame.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                RebootProbeVariant.entries.forEach { variant ->
                    TextButton(onClick = { onSend(variant) }, modifier = Modifier.fillMaxWidth()) {
                        Text(
                            variant.menuLabel,
                            style = NoopType.body,
                            color = Palette.accent,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #592 extended-battery opcode probe: a single read-only send + a full raw-response dump to the strap
 *  log. Settles whether GET_EXTENDED_BATTERY_INFO is 98 (this table) or 87 (an independent APK decompile)
 *  from a normal strap-log export. Gated to Test Centre → Connection + a live WHOOP at the call site. */
@Composable
private fun BatteryInfoProbeDialog(
    onSend: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_battery_info_probe_592_re_1dbd4c0f), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Text(
                uiString(R.string.l10n_devices_screen_battery_probe_explainer_2858bb6a),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        },
        confirmButton = {
            TextButton(onClick = onSend) {
                Text(uiString(R.string.l10n_devices_screen_send_probe_read_only_36b318bc), style = NoopType.body, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #592 probe result: shows the raw hex + payload triage from the strap's reply (or a "waiting…" line
 *  while in flight), with a Copy button so the capture can be pasted into the issue without exporting the
 *  whole strap log. Read-only; dismiss clears the result. */
@Composable
private fun BatteryInfoProbeResultDialog(
    text: String,
    onDismiss: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    val waiting = text == WhoopBleClient.WAITING_EXTENDED_BATTERY_PROBE
    val shown = if (waiting) uiString(R.string.l10n_devices_screen_waiting_for_the_straps_reply_5a06e7ac) else text
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_battery_info_probe_result_592_b97c0bb8), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                SelectionContainer {
                    Text(shown, style = if (waiting) NoopType.subhead else NoopType.mono, color = Palette.textSecondary)
                }
            }
        },
        confirmButton = {
            if (!waiting) {
                TextButton(onClick = { clipboard.setText(AnnotatedString(text)) }) {
                    Text(uiString(R.string.l10n_devices_screen_copy_af74f7c5), style = NoopType.body, color = Palette.accent)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_close_bbfa773e), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #690 body-location opcode probe: a single read-only send + a full raw-response dump + decoded record.
 *  Gated to Test Centre → Connection + a live WHOOP at the call site. */
@Composable
private fun BodyLocationProbeDialog(
    onSend: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_body_location_probe_690_re_7def8c39), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Text(
                uiString(R.string.l10n_devices_screen_body_location_probe_explainer_a9363239),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        },
        confirmButton = {
            TextButton(onClick = onSend) {
                Text(uiString(R.string.l10n_devices_screen_send_probe_read_only_36b318bc), style = NoopType.body, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #690 probe result: raw hex + decoded body-location record (or a "waiting…" state), with a Copy button.
 *  Read-only; dismiss clears the result. Twin of the Swift BodyLocationProbeResultView. */
@Composable
private fun BodyLocationProbeResultDialog(
    text: String,
    onDismiss: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    val waiting = text == WhoopBleClient.WAITING_BODY_LOCATION_PROBE
    val shown = if (waiting) uiString(R.string.l10n_devices_screen_waiting_for_the_straps_reply_5a06e7ac) else text
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_body_location_probe_result_690_60c5ee79), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                SelectionContainer {
                    Text(shown, style = if (waiting) NoopType.subhead else NoopType.mono, color = Palette.textSecondary)
                }
            }
        },
        confirmButton = {
            if (!waiting) {
                TextButton(onClick = { clipboard.setText(AnnotatedString(text)) }) {
                    Text(uiString(R.string.l10n_devices_screen_copy_af74f7c5), style = NoopType.body, color = Palette.accent)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_close_bbfa773e), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #761 feature-flag ENUMERATION probe: a read-only walk of the strap's own flag-name list (117 then
 *  repeated 118). Nothing is written to the strap. Gated to Test Centre → Connection + a live WHOOP at
 *  the call site. Twin of the Swift FeatureFlagProbeSheets confirm dialog. */
@Composable
private fun FeatureFlagProbeDialog(
    onSend: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_feature_flag_probe_761_re_21241d68), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Text(
                uiString(R.string.l10n_devices_screen_feature_flag_probe_explainer_58eec30f),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        },
        confirmButton = {
            TextButton(onClick = onSend) {
                Text(uiString(R.string.l10n_devices_screen_send_probe_read_only_36b318bc), style = NoopType.body, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #761 probe result: the strap's own flag-name list + the exchange trace (or a "waiting…" state), with
 *  a Copy button. Read-only; dismiss clears the result. Twin of the Swift FeatureFlagProbeResultView. */
@Composable
private fun FeatureFlagProbeResultDialog(
    text: String,
    onDismiss: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    val waiting = text == WhoopBleClient.WAITING_FEATURE_FLAG_PROBE
    val shown = if (waiting) uiString(R.string.l10n_devices_screen_waiting_for_the_straps_reply_5a06e7ac) else text
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_feature_flag_probe_result_761_c50ef4d4), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                SelectionContainer {
                    Text(shown, style = if (waiting) NoopType.subhead else NoopType.mono, color = Palette.textSecondary)
                }
            }
        },
        confirmButton = {
            if (!waiting) {
                TextButton(onClick = { clipboard.setText(AnnotatedString(text)) }) {
                    Text(uiString(R.string.l10n_devices_screen_copy_af74f7c5), style = NoopType.body, color = Palette.accent)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_close_bbfa773e), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #103 device-config READ probe: a read-only walk that asks the strap for config VALUES (121/128), one
 *  key per round-trip. Nothing is written to the strap. Gated to Test Centre → Connection + a live WHOOP
 *  at the call site. Twin of the Swift DeviceConfigProbeSheets confirm dialog. */
@Composable
private fun DeviceConfigProbeDialog(
    onSend: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_device_config_read_probe_103_re_837f46de), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Text(
                uiString(R.string.l10n_devices_screen_device_config_probe_explainer_dd23169f),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        },
        confirmButton = {
            TextButton(onClick = onSend) {
                Text(uiString(R.string.l10n_devices_screen_send_probe_read_only_36b318bc), style = NoopType.body, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

/** #103 probe result: the per-verb verdict, the values read, and the exchange transcript (or a
 *  "waiting…" state), with a Copy button. Read-only; dismiss clears the result. Twin of the Swift
 *  DeviceConfigProbeResultView. */
@Composable
private fun DeviceConfigProbeResultDialog(
    text: String,
    onDismiss: () -> Unit,
) {
    val clipboard = LocalClipboardManager.current
    val waiting = text == WhoopBleClient.WAITING_DEVICE_CONFIG_PROBE
    val shown = if (waiting) uiString(R.string.l10n_devices_screen_waiting_for_the_straps_reply_5a06e7ac) else text
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_device_config_read_probe_result_103_67d02ec9), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                SelectionContainer {
                    Text(shown, style = if (waiting) NoopType.subhead else NoopType.mono, color = Palette.textSecondary)
                }
            }
        },
        confirmButton = {
            if (!waiting) {
                TextButton(onClick = { clipboard.setText(AnnotatedString(text)) }) {
                    Text(uiString(R.string.l10n_devices_screen_copy_af74f7c5), style = NoopType.body, color = Palette.accent)
                }
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_close_bbfa773e), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun RenameDialog(
    device: PairedDeviceRow,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember { mutableStateOf(device.nickname ?: displayName(device)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_rename_device_ee233604), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    uiString(R.string.l10n_devices_screen_give_device_brand_device_model_a_7a15585c, device.brand, device.model),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    placeholder = { Text(uiString(R.string.l10n_devices_screen_name_709a2322), style = NoopType.body, color = Palette.textTertiary) },
                    colors = devicesFieldColors(),
                    modifier = Modifier.fillMaxWidth().semantics { contentDescription = uiString(R.string.l10n_devices_screen_device_name_79d7a157) },
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(draft) }) {
                Text(uiString(R.string.l10n_devices_screen_save_efc007a3), style = NoopType.body, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(uiString(R.string.l10n_devices_screen_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun PickActiveDialog(
    devices: List<PairedDeviceRow>,
    onPick: (PairedDeviceRow) -> Unit,
    onLeaveNone: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onLeaveNone,
        containerColor = Palette.surfaceOverlay,
        title = { Text(uiString(R.string.l10n_devices_screen_pick_a_new_active_strap_edd73542), style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    uiString(R.string.l10n_devices_screen_you_removed_your_active_strap_choose_2ac91d48),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Spacer(Modifier.height(4.dp))
                devices.forEach { device ->
                    Text(
                        displayName(device),
                        style = NoopType.body,
                        color = Palette.accent,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { onPick(device) }
                            .padding(vertical = 10.dp),
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onLeaveNone) {
                Text(uiString(R.string.l10n_devices_screen_leave_none_active_b5c858cb), style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

// MARK: - Signal indicator
//
// A four-bar signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is stronger. Buckets
// are coarse on purpose — a precise dBm readout would be noise to the user. Mirrors the Swift SignalBars.

@Composable
internal fun SignalBars(rssi: Int) {
    val level = SignalBars.level(rssi)
    Row(
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.height(18.dp),
    ) {
        for (i in 0 until 4) {
            Box(
                modifier = Modifier
                    .width(3.dp)
                    .height((6 + i * 3).dp)
                    .clip(RoundedCornerShape(1.dp))
                    .background(if (i < level) Palette.accent else Palette.hairlineStrong),
            )
        }
    }
}

internal object SignalBars {
    /** RSSI (negative dBm) → 0..4 signal level, coarse buckets. Matches the Swift SignalBars.level. */
    fun level(rssi: Int): Int = when {
        rssi >= -55 -> 4
        rssi >= -67 -> 3
        rssi >= -80 -> 2
        rssi >= -90 -> 1
        else -> 0
    }
}

// MARK: - Field colours

@Composable
private fun devicesFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

// MARK: - Presentation helpers (mirror the Swift PairedDevice computed props)

/**
 * Collapsed display name (mirrors Swift `PairedDevice.displayName`): the nickname if present, else the
 * model if it already contains the brand (so the seeded WHOOP/WHOOP reads "WHOOP", not "WHOOP WHOOP"),
 * else "brand model".
 */
internal fun displayName(device: PairedDeviceRow): String {
    device.nickname?.takeIf { it.isNotBlank() }?.let { return it }
    return if (device.model.contains(device.brand, ignoreCase = true)) device.model
    else "${device.brand} ${device.model}"
}

/** SF-Symbol-equivalent icon: WHOOP keeps the band glyph; an FTMS machine reads as gym equipment;
 *  generic straps read as a heart-rate strap. */
private fun deviceIcon(device: PairedDeviceRow): ImageVector = when {
    device.sourceKind == SourceKind.ftms.name -> Icons.AutoMirrored.Filled.DirectionsRun
    device.sourceKind == SourceKind.huami.name -> Icons.Filled.GraphicEq
    device.sourceKind == SourceKind.oura.name -> Icons.Filled.Circle
    SourceCoordinator.isWhoop(device) -> Icons.Filled.Watch
    else -> Icons.Filled.FavoriteBorder
}

/**
 * Honest, per-model capability + function summary for a device card — mirrors the Swift
 * `DeviceCapabilityProfile`. Derived from brand/model, NOT the generic stored capability set (which
 * would render an identical line for a 4.0 and a 5/MG and mislabel "Blood oxygen" when no SpO₂ % ever
 * comes off any WHOOP strap — raw red/IR only; a real % is import-only). "*" in a label = an on-device
 * estimate, not a raw sensor. Source-verified against the decode + scoring paths (capability audit).
 */
private data class DeviceCapabilityProfile(
    val displayModel: String,  // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    val captures: String,      // "·"-joined honest capture labels for THIS model
    val powers: String,        // the NOOP scores / screens this device drives
    val footnote: String,      // one short honest caveat line ("*" estimates + the SpO₂/steps notes)
)

private fun deviceProfile(device: PairedDeviceRow): DeviceCapabilityProfile {
    // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
    // live-workout path. Effort-scored only when the machine actually reports heart rate.
    if (device.sourceKind == SourceKind.ftms.name) {
        return DeviceCapabilityProfile(
            displayModel = "Gym equipment (FTMS)",
            captures = "Speed · Cadence · Power · Distance · Energy · Heart rate (if the machine sends it)",
            powers = "Records a live machine workout, Effort-scored from HR when the machine reports it",
            footnote = "Live machine data over Bluetooth FTMS. No sleep, recovery, skin temp or SpO₂. " +
                "Effort needs the machine's heart rate; without it the session logs the machine metrics only.",
        )
    }
    // EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band): best-effort live HR only, honest about it.
    if (device.sourceKind == SourceKind.huami.name) {
        return DeviceCapabilityProfile(
            displayModel = "${device.brand} (experimental)",
            captures = "Heart rate (live, best-effort)",
            powers = "Powers the live console + Effort. No Charge, Rest or Sleep",
            footnote = "Experimental: live heart rate where the band exposes it. Some bands need a pairing " +
                "we can't do yet. NOOP will say so honestly and never show a made-up number. No sleep, " +
                "recovery, skin temp, SpO₂ or steps.",
        )
    }
    // EXPERIMENTAL locally-adopted Oura ring (gen 3/4/5). The gen is carried on `model` ("Oura Ring
    // 3/4/5") and recovered with OuraRingGen.from(model). NOOP reads the ring's OWN raw signals + open
    // HRV/sleep-phase tags and computes its own Charge/Effort/Rest; it NEVER reads Oura's encrypted
    // Readiness/Sleep scores, and claims NO absolute SpO₂ %. Estimates carry "*"; a signal it can't read
    // stays "-". Per-gen copy + the canonical Beta caveat (spec
    // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md s3/s4). Mirrors the macOS Oura branch.
    if (device.sourceKind == SourceKind.oura.name) {
        val gen = com.noop.oura.OuraRingGen.from(device.model)
        // gen3/4 are verified-shape; gen5 ("newer") carries the least-proven caveat.
        val newer = gen == com.noop.oura.OuraRingGen.GEN5
        val captures = if (newer)
            "Heart rate* · HRV* · Sleep* · Resting HR* · Skin temp* · Battery*"
        else
            "Heart rate · HRV* · Sleep · Resting HR · Skin temp* · Battery"
        val powers = if (newer)
            "Powers Effort now; Charge and Rest once enough nights and decode are confirmed"
        else
            "Powers Charge, Effort, Rest and Sleep"
        return DeviceCapabilityProfile(
            displayModel = "${gen.displayName} (Beta)",
            captures = captures,
            powers = powers,
            footnote = "Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, " +
                "and HRV needs you to be still. No Oura Readiness or SpO₂ " +
                "percentage comes off the ring (import an Oura file for those).",
        )
    }
    // Generic heart-rate strap: live HR + R-R only; drives the live console + Effort, nothing nightly.
    if (!SourceCoordinator.isWhoop(device)) {
        return DeviceCapabilityProfile(
            displayModel = "Heart-rate strap",
            captures = "Heart rate · HRV (live)* · Strain",
            powers = "Powers the live console + Effort. No Charge, Rest or Sleep",
            footnote = "Live HR + R-R only · no sleep, recovery, skin temp, SpO₂, steps or battery " +
                "(those are WHOOP-only).",
        )
    }
    val whoopPowers = "Powers Charge, Effort, Rest, Sleep + Health Monitor"
    val model = device.model.lowercase()
    // WHOOP 5.0 / MG — adds a (raw) step count the 4.0 can't read over BLE.
    if (model.contains("5") || model.contains("mg")) {
        return DeviceCapabilityProfile(
            displayModel = "WHOOP 5.0 / MG",
            captures = "Heart rate · HRV · Skin temp* · Resp rate* · Steps* · Sleep · Strain · Battery",
            powers = whoopPowers,
            footnote = "* on-device estimate: skin temp is a nightly ±°C deviation, steps are a raw " +
                "motion count (#78). No SpO₂ % off the strap; import a WHOOP CSV for a real %.",
        )
    }
    // WHOOP 4.0 — NOOP's primary band; no steps over BLE.
    if (model.contains("4")) {
        return DeviceCapabilityProfile(
            displayModel = "WHOOP 4.0",
            captures = "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery",
            powers = whoopPowers,
            footnote = "* on-device estimate: skin temp is a nightly ±°C deviation (firmware-dependent); " +
                "no steps over BLE on a 4.0. No SpO₂ % off the strap; import a WHOOP CSV for a real %.",
        )
    }
    // Legacy / unknown WHOOP (the seeded device, model just "WHOOP") — show only the common-to-all set.
    return DeviceCapabilityProfile(
        displayModel = "WHOOP",
        captures = "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery",
        powers = whoopPowers,
        footnote = "Exact model unknown. Shows what every WHOOP can do. * on-device estimate · " +
            "no SpO₂ % off the strap (import a WHOOP CSV for that).",
    )
}

/** One icon-prefixed info row (captures / powers) for a device card, matching the caption style. */
@Composable
private fun CapabilityInfoRow(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(14.dp))
        Text(text, style = NoopType.caption, color = Palette.textSecondary)
    }
}

/**
 * Honest paired-but-not-connected note for a locally-adopted Oura ring (Beta). Amber heads-up, no
 * fabricated reading: re-states the single-owner reality so the user understands why a re-reset or an Oura
 * re-claim would break NOOP's ownership. Mirrors the macOS DeviceCard.ouraLocalStateNote (no em-dashes).
 */
@Composable
private fun OuraLocalStateNote() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Info, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(14.dp))
        Text(
            uiString(R.string.l10n_devices_screen_paired_locally_noop_owns_this_ring_30c16190),
            style = NoopType.caption,
            color = Palette.statusWarning,
        )
    }
}

private fun lastSeenLine(device: PairedDeviceRow, isLiveConnected: Boolean, bondRefused: Boolean = false): String = when {
    device.status == DeviceStatus.archived.name -> "Removed · data kept"
    // No "tap ⋯" pointer here (#221 review) — the full how-to-fix guidance is already inline on the card
    // just below, so pointing at the menu would send the user looking for help that's already on screen.
    bondRefused -> "Connected, but not paired"
    isLiveConnected -> "Connected now"
    else -> "Last seen ${relativeAgo(device.lastSeenAt)}"
}

internal fun historyLayoutLine(version: Int?): String? =
    version?.let { "v$it history" }

/** Best-effort brand from the advertised name. Falls back to a neutral label. Mirrors Swift brandGuess.
 *  Delegates to the pure [com.noop.data.DeviceBrandCatalog] (single source of truth) so the token table
 *  lives once. */
internal fun brandGuess(name: String): String =
    com.noop.data.DeviceBrandCatalog.specForAdvertisedName(name)?.brand ?: "Heart-rate strap"
