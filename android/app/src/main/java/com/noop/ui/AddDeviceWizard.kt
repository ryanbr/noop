package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.PhonelinkErase
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.ExperimentalBrand
import com.noop.ble.OuraLiveSource
import com.noop.ble.StandardHrSource
import com.noop.ble.WhoopBleClient
import com.noop.ble.WhoopModel
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.data.WhoopLiveCapabilities
import com.noop.oura.OuraRingGen
import kotlinx.coroutines.launch

// MARK: - Add a device - guided, branching wizard (MW-4)
//
// Different bands pair COMPLETELY differently, so this wizard asks the device TYPE first, then gives
// type-specific prep guidance and runs the RIGHT scan/connect for that type:
//
//   • WHOOP 4.0 / WHOOP 5.0 (MG)  → the WHOOP present-scan ([AppViewModel.presentWhoopScan]) targeted at
//     the chosen family. Lists nearby straps from [AppViewModel.discoveredWhoops] (a present-only mode
//     that never auto-connects).
//   • Heart-rate strap (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) → its OWN isolated
//     [StandardHrSource] scanning the standard 0x180D HR service. Lists from its `discovered` flow.
//
// Registration goes through [AppViewModel.registerDevice] → DeviceRegistry; the SourceCoordinator reacts
// to the active-device change and connects (pinning the WHOOP / starting the strap source). The wizard
// never touches the BLE client directly - only the AppViewModel pass-throughs. WHOOP-FIRST: WHOOP is the
// primary band; the type list shows it first and a footer reiterates it. Renders cleanly with nothing
// nearby (the type picker, every prep step, and the searching/empty pick state all need no hardware).
// Faithful Kotlin twin of Strand/Screens/AddDeviceWizard.swift. US English throughout.

/** What the user is adding. Drives the prep copy AND which scan/register path runs. */
private enum class DeviceType {
    Whoop5MG, Whoop4, HrStrap, GymEquipment,
    // EXPERIMENTAL tier - best-effort, clean-room, can't be hardware-verified here. Each fails to an
    // honest message and never fabricates data.
    Amazfit, MiBand, Garmin, Oura;

    val isWhoop: Boolean get() = this == Whoop4 || this == Whoop5MG
    val whoopModel: WhoopModel?
        get() = when (this) {
            Whoop4 -> WhoopModel.WHOOP4
            Whoop5MG -> WhoopModel.WHOOP5_MG
            else -> null
        }

    /** True for the EXPERIMENTAL tier (shown under a clearly-labelled "Experimental" heading). */
    val isExperimental: Boolean get() = this == Amazfit || this == MiBand || this == Garmin || this == Oura

    /** The experimental-tier brand this type registers as, or null for the non-experimental types
     *  (WHOOP / generic strap / gym). Bridges the type picker to the [com.noop.data.DeviceBrandCatalog]
     *  facts (stored brand string, sourceKind, id prefix) so those are no longer hardcoded per branch. */
    val experimentalBrand: ExperimentalBrand?
        get() = when (this) {
            Amazfit -> ExperimentalBrand.AMAZFIT
            MiBand -> ExperimentalBrand.MI_BAND
            Garmin -> ExperimentalBrand.GARMIN
            Oura -> ExperimentalBrand.OURA
            else -> null
        }

    val title: String
        get() = when (this) {
            Whoop5MG -> "WHOOP 5.0 / MG"
            Whoop4 -> "WHOOP 4.0"
            HrStrap -> "Heart-rate strap"
            GymEquipment -> "Gym equipment"
            Amazfit -> "Amazfit / Zepp"
            MiBand -> "Xiaomi Mi Band"
            Garmin -> "Garmin watch"
            Oura -> "Oura ring"
        }
}

private enum class WizardStep { Type, Prep, Pick, Confirm }

/**
 * The Oura factory-reset-and-adopt sub-flow (section 2 of the onboarding UX spec). The Oura type does NOT
 * use the generic Prep/Pick/Confirm shape - it owns this step machine, entered from the type list:
 *   - [Gate]      What you get / what you lose + the irreversible red consent gate (or Advanced key field).
 *   - [Prep]      Factory-reset the ring in the Oura app first (single-owner warning).
 *   - [Pick]      Live scan + pick a ring; "still paired to Oura" rings list with a warning.
 *   - [Confirm]   Detected generation + per-gen capability checklist + the destructive "Take over" action.
 *   - [Adopting]  Honest key-install progress sub-states (no fake percent).
 *   - [Failed]    An honest dead-end when adoption fails, never a fabricated success.
 */
private enum class OuraStep { Gate, Prep, Pick, Confirm, Adopting, Failed }

@Composable
fun AddDeviceWizard(
    viewModel: AppViewModel,
    onClose: () -> Unit,
    /** Routes to the non-destructive file-import lane (Data Sources). The Oura gate's "Keep the Oura app
     *  instead (import a file)" link and every honest Oura failure offer this, so the destructive takeover
     *  is never the only door. Defaults to a plain close so existing call sites keep compiling. */
    onUseFileImport: () -> Unit = onClose,
) {
    val scope = rememberCoroutineScope()

    var step by remember { mutableStateOf(WizardStep.Type) }
    var type by remember { mutableStateOf<DeviceType?>(null) }

    // --- Oura factory-reset-and-adopt sub-flow (the Oura type drives its own step machine; section 2 of
    // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md). Inert for every other device type. ---
    var ouraStep by remember { mutableStateOf(OuraStep.Gate) }
    /** The honest, irreversible "this disconnects the ring from Oura" box must be ticked to continue. */
    var ouraConsent by remember { mutableStateOf(false) }
    /** The Advanced (B-Alt) path: the user supplies their own 16-byte key and keeps the Oura app. */
    var ouraAdvanced by remember { mutableStateOf(false) }
    /** The pasted 32-hex-character ring key (Advanced path only). */
    var ouraKeyDraft by remember { mutableStateOf("") }
    /** The ring picked from the live scan, with its detected generation. */
    var pickedOura by remember { mutableStateOf<OuraLiveSource.DiscoveredRing?>(null) }
    /** The generation confirmed for the picked ring (best-effort detect, defaulted to gen3). */
    var ouraGen by remember { mutableStateOf(OuraRingGen.GEN3) }
    /** Final destructive-confirm alert before the key install. */
    var ouraConfirmAdopt by remember { mutableStateOf(false) }

    // The chosen strap, in whichever shape its path produces.
    var pickedWhoop by remember { mutableStateOf<WhoopBleClient.DiscoveredWhoop?>(null) }
    var pickedStrap by remember { mutableStateOf<StandardHrSource.DiscoveredStrap?>(null) }
    var pickedMachine by remember { mutableStateOf<com.noop.ble.FtmsSource.DiscoveredMachine?>(null) }
    var pickedHuami by remember { mutableStateOf<com.noop.ble.HuamiHrSource.DiscoveredDevice?>(null) }

    var nameDraft by remember { mutableStateOf("") }
    var askMakeActive by remember { mutableStateOf(false) }

    // Discovery-only HR source for the strap path (also Garmin Broadcast HR). Never persists, never
    // connects - we only read its `discovered` / `scanning` StateFlows while scanning. Created once.
    val hrScanner = remember { viewModel.makeStrapScanner() }
    // Discovery-only FTMS source for the gym-equipment path. Same throwaway contract.
    val ftmsScanner = remember { viewModel.makeFtmsScanner() }
    // Discovery-only EXPERIMENTAL Huami scanner (Amazfit / Zepp / Mi Band).
    val huamiScanner = remember { viewModel.makeHuamiScanner() }
    // Discovery-only EXPERIMENTAL Oura scanner: a throwaway, isolated [OuraLiveSource] (its OWN scanner +
    // GATT, never the WHOOP client; no-op persist/live, null key). The wizard reads only its `discovered` /
    // `scanning` flows; the SourceCoordinator owns the real connect once the adopted ring becomes active.
    val ouraScanner = remember { viewModel.makeOuraScanner() }

    fun startScan(t: DeviceType) {
        when {
            t.isWhoop -> viewModel.presentWhoopScan(t.whoopModel ?: WhoopModel.WHOOP4)
            t == DeviceType.GymEquipment -> ftmsScanner.scan()
            t == DeviceType.Amazfit || t == DeviceType.MiBand -> huamiScanner.scan()
            t == DeviceType.Oura -> ouraScanner.scan()
            else -> hrScanner.scan()   // HrStrap AND Garmin (Broadcast HR is the standard 0x180D path)
        }
    }

    fun stopAllScans() {
        viewModel.stopWhoopScan()
        hrScanner.stopScan()
        ftmsScanner.stopScan()
        huamiScanner.stopScan()
        ouraScanner.stop()
    }

    // Belt-and-braces: stop whichever scan is live whenever the wizard leaves composition.
    DisposableEffect(Unit) { onDispose { stopAllScans() } }

    fun goBack() {
        // The Oura type runs its own step machine; back walks that, falling out to the type list from Gate.
        if (type == DeviceType.Oura) {
            when (ouraStep) {
                // From the Advanced key field, back returns to the standard consent gate; from the standard
                // gate, back exits to the device-type list.
                OuraStep.Gate -> if (ouraAdvanced) { ouraAdvanced = false; ouraKeyDraft = "" }
                else { type = null; ouraConsent = false }
                OuraStep.Prep -> ouraStep = OuraStep.Gate
                // The standard path came from Prep (factory-reset step); the Advanced path came straight
                // from the Gate key field. Back returns to wherever the scan was launched from.
                OuraStep.Pick -> { ouraScanner.stop(); pickedOura = null; ouraStep = if (ouraAdvanced) OuraStep.Gate else OuraStep.Prep }
                OuraStep.Confirm -> {
                    // Re-enter the pick step and rescan so the user can choose a different ring.
                    ouraScanner.scan(); pickedOura = null; ouraStep = OuraStep.Pick
                }
                // Adopting / Failed have no meaningful back; return to the pick step to try again.
                OuraStep.Adopting, OuraStep.Failed -> { ouraScanner.scan(); pickedOura = null; ouraStep = OuraStep.Pick }
            }
            return
        }
        when (step) {
            WizardStep.Type -> Unit
            WizardStep.Prep -> step = WizardStep.Type
            WizardStep.Pick -> { stopAllScans(); step = WizardStep.Prep }
            WizardStep.Confirm -> {
                // Re-enter the pick step and restart its scan so the user can choose a different device.
                type?.let { startScan(it) }
                pickedWhoop = null; pickedStrap = null; pickedMachine = null; pickedHuami = null
                step = WizardStep.Pick
            }
        }
    }

    val confirmAdvertisedName = run {
        pickedWhoop?.let { return@run it.name?.takeIf { n -> n.isNotBlank() } ?: (type?.title ?: "Device") }
        pickedStrap?.let { return@run it.name }
        pickedMachine?.let { return@run it.name }
        pickedHuami?.let { return@run it.name }
        type?.title ?: "Device"
    }
    val confirmName = nameDraft.trim().ifEmpty { confirmAdvertisedName }
    val confirmBrand = when {
        type?.isWhoop == true -> "WHOOP"
        type == DeviceType.GymEquipment -> "Gym equipment"
        // Experimental non-Oura types (Amazfit / Mi Band / Garmin) take their stored brand string from the
        // catalog via the type->brand bridge. Oura confirms with its detected generation label elsewhere.
        type == DeviceType.Amazfit || type == DeviceType.MiBand || type == DeviceType.Garmin ->
            type!!.experimentalBrand!!.displayBrand
        pickedStrap != null -> brandGuess(pickedStrap!!.name)
        else -> "Heart-rate strap"
    }
    val confirmRssi = pickedWhoop?.rssi ?: pickedStrap?.rssi ?: pickedMachine?.rssi ?: pickedHuami?.rssi ?: -70

    fun finishAdd(makeActive: Boolean) {
        stopAllScans()
        val now = System.currentTimeMillis() / 1000
        val pw = pickedWhoop
        val ps = pickedStrap
        val pm = pickedMachine
        val ph = pickedHuami
        val isGarmin = type == DeviceType.Garmin
        val device: PairedDeviceRow? = when {
            pw != null && type?.whoopModel != null -> {
                // WHOOP: honest live capability set (no calibrated SpO₂ % — import-only; #548);
                // id namespaced by address; model "4.0" / "5.0 MG". Steps only on 5.0/MG.
                val wm = type!!.whoopModel!!
                val modelLabel = if (wm == WhoopModel.WHOOP4) "4.0" else "5.0 MG"
                PairedDeviceRow(
                    id = "whoop-${pw.address}",
                    brand = "WHOOP",
                    model = modelLabel,
                    nickname = confirmName,
                    peripheralId = pw.address,
                    sourceKind = SourceKind.liveBLE.name,
                    capabilities = WhoopLiveCapabilities.encoded(modelLabel),
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            ps != null -> {
                // Generic HR strap OR a Garmin broadcasting standard HR. Garmin's brand + id prefix come
                // from the catalog (via the type->brand bridge); it still stores `liveBLE` (its live HR IS
                // the standard 0x180D path). A non-Garmin strap keeps the advertised-name brand guess +
                // "strap" prefix. Both are HR + HRV.
                val garmin = if (isGarmin) ExperimentalBrand.GARMIN else null
                PairedDeviceRow(
                    id = "${garmin?.idPrefix ?: "strap"}-${ps.address}",
                    brand = garmin?.displayBrand ?: brandGuess(ps.name),
                    model = ps.name,
                    nickname = if (confirmName == ps.name) null else confirmName,
                    peripheralId = ps.address,
                    sourceKind = SourceKind.liveBLE.name,
                    capabilities = "hr,hrv",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            ph != null -> {
                // EXPERIMENTAL Amazfit / Zepp / Mi Band. Brand string, id prefix, and the "huami" routing
                // all come from the catalog via the type->brand bridge (was: `if (MiBand) "Mi Band" else …`).
                // HR only (the Huami custom characteristic carries no R-R).
                val brand = type?.experimentalBrand ?: ExperimentalBrand.AMAZFIT
                PairedDeviceRow(
                    id = "${brand.idPrefix}-${ph.address}",
                    brand = brand.displayBrand,
                    model = ph.name,
                    nickname = if (confirmName == ph.name) null else confirmName,
                    peripheralId = ph.address,
                    sourceKind = brand.sourceKind.name,
                    capabilities = "hr",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            pm != null -> {
                // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
                // live-workout path. sourceKind "ftms" routes the SourceCoordinator to the FtmsSource.
                PairedDeviceRow(
                    id = "ftms-${pm.address}",
                    brand = "Gym equipment",
                    model = pm.name,
                    nickname = if (confirmName == pm.name) null else confirmName,
                    peripheralId = pm.address,
                    sourceKind = SourceKind.ftms.name,
                    capabilities = "hr",
                    status = DeviceStatus.paired.name,
                    addedAt = now,
                    lastSeenAt = now,
                )
            }
            else -> null
        }
        if (device == null) { onClose(); return }
        scope.launch { viewModel.registerDevice(device, makeActive = makeActive) }
        onClose()
    }

    /**
     * Register an adopted (or Advanced-key) Oura ring. Builds the oura [PairedDeviceRow] - id
     * "oura-<address>", model = the picked generation's display name (the row recovers the gen via
     * OuraRingGen.from(model)), sourceKind "oura" (routes the SourceCoordinator to [OuraLiveSource]),
     * gen-filtered capabilities - then registers it active so the live source starts. The Advanced path
     * also stores the user-supplied 16-byte key in the encrypted key store under the SAME id so the live
     * source's authKey closure can read it. Mirrors the macOS finishAdd Oura branch.
     */
    /**
     * Register an adopted (or Advanced-key) Oura ring active. [closeAfter] controls whether the wizard
     * dismisses immediately:
     *   - Advanced-key path: true. The ring authenticates with the user's supplied key (no install), so
     *     there is no Adopting progress to watch; register and close.
     *   - Standard destructive adopt: false. We arm the one-shot adopt-intent, register active (the live
     *     source then runs the dangerous key install), and STAY on the Adopting step so the observed
     *     adoptPhase / needs-pairing can drive it to success (close) or a REACHABLE honest Failed. Without
     *     this the user was trapped on a fake "Installing NOOP's key" spinner that never resolved.
     */
    fun finishAddOura(closeAfter: Boolean) {
        stopAllScans()
        val ring = pickedOura ?: run { onClose(); return }
        val now = System.currentTimeMillis() / 1000
        // Brand string, id prefix, and the "oura" routing come from the catalog via the type->brand bridge.
        val oura = ExperimentalBrand.OURA
        val deviceId = "${oura.idPrefix}-${ring.address}"
        // Advanced (B-Alt): persist the pasted key BEFORE registering so the active source authenticates
        // with it WITHOUT a factory reset (the Oura app keeps working). This path NEVER arms adopt-intent,
        // so the live source never sends the dangerous install opcode.
        // Standard adopt: arm the one-shot adopt-intent BEFORE registering active, so the SourceCoordinator
        // consumes it when it builds the live source and the dangerous post-factory-reset key install is
        // reachable for exactly this one session (OURA_PROTOCOL.md s3.2). The user already passed the
        // irreversible-consent gate AND the second destructive "Take over" confirm to get here.
        if (ouraAdvanced) {
            val key = parseHexKey(ouraKeyDraft)
            if (key != null) viewModel.saveOuraInstallKey(deviceId, key)
        } else {
            viewModel.armOuraAdopt(deviceId)
        }
        val device = PairedDeviceRow(
            id = deviceId,
            brand = oura.displayBrand,
            model = ouraGen.displayName,
            nickname = nameDraft.trim().takeIf { it.isNotEmpty() && it != "Oura ring" },
            peripheralId = ring.address,
            sourceKind = oura.sourceKind.name,
            // Gen-filtered: the OuraMetric rawValues are byte-identical to the app-side Metric rawValues
            // (hr/hrv/spo2/skinTemp/sleep), so the joined string round-trips through the registry unchanged.
            capabilities = ouraGen.capabilities.joinToString(",") { it.raw },
            status = DeviceStatus.paired.name,
            addedAt = now,
            lastSeenAt = now,
        )
        // The takeover always makes the ring active (it is the user's new live source); no make-active
        // prompt - the destructive gate already committed to "this is now your device".
        scope.launch { viewModel.registerDevice(device, makeActive = true) }
        if (closeAfter) onClose()
    }

    // The live adopt-failure reason (the source's needs-pairing message). Collected here so the honest
    // Failed step can surface it instead of static copy, mirroring the Swift wizard's `model.ouraNeedsPairing`.
    // The Adopting->Failed observer (the LaunchedEffect below) reads the SAME value.
    val adoptNeedsPairing by viewModel.ouraNeedsPairing.collectAsStateWithLifecycle()

    AlertDialog(
        onDismissRequest = { stopAllScans(); onClose() },
        containerColor = Palette.surfaceOverlay,
        title = {
            // The Oura type drives its own titled step machine; otherwise the generic step titles apply.
            val isOura = type == DeviceType.Oura
            val hTitle = if (isOura) ouraHeaderTitle(ouraStep, ouraAdvanced) else headerTitle(step, type)
            val hSub = if (isOura) ouraHeaderSubtitle(ouraStep, ouraAdvanced) else headerSubtitle(step)
            // Back is offered on every step except the very first (the type list). The Adopting progress
            // step hides back so the user can't interrupt the key install mid-flight.
            val showBack = if (isOura) ouraStep != OuraStep.Adopting else step != WizardStep.Type
            Row(verticalAlignment = Alignment.Top) {
                if (showBack) {
                    IconButton(onClick = { goBack() }, modifier = Modifier.size(28.dp)) {
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                            contentDescription = uiString(R.string.l10n_add_device_wizard_back_b52b36b7),
                            tint = Palette.textSecondary,
                            modifier = Modifier.size(22.dp),
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                }
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(hTitle, style = NoopType.title2, color = Palette.textPrimary)
                    hSub?.let {
                        Text(it, style = NoopType.caption, color = Palette.textTertiary)
                    }
                }
                IconButton(onClick = { stopAllScans(); onClose() }, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = uiString(R.string.l10n_add_device_wizard_close_bbfa773e), tint = Palette.textTertiary, modifier = Modifier.size(20.dp))
                }
            }
        },
        text = {
            // Make the wizard body scrollable so no step is ever cut off under large font scaling or on
            // large/short displays (#897: the device-type list was taller than the dialog and the lower rows,
            // e.g. Oura, were unreachable). The AlertDialog text slot does not scroll its content on its own,
            // so we own the scroll here. Every step renders unchanged inside this scroll container.
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
            // The Oura type runs the factory-reset-and-adopt sub-flow (section 2 of the onboarding UX
            // spec), NOT the generic Prep/Pick/Confirm. Everything else keeps the generic 4-step shape.
            if (type == DeviceType.Oura) {
                OuraFlow(
                    ouraStep = ouraStep,
                    advanced = ouraAdvanced,
                    consent = ouraConsent,
                    keyDraft = ouraKeyDraft,
                    scanner = ouraScanner,
                    gen = ouraGen,
                    name = nameDraft,
                    // The live adopt-failure reason, so the honest Failed step shows it (Swift parity).
                    failureReason = adoptNeedsPairing,
                    onConsent = { ouraConsent = it },
                    onKeyDraft = { ouraKeyDraft = it },
                    onName = { nameDraft = it },
                    onContinue = { ouraStep = OuraStep.Prep },
                    onUseFileImport = { stopAllScans(); onUseFileImport() },
                    // Advanced (B-Alt): the Gate step renders the key field while advanced is set; from the
                    // key field the user scans straight through to the pick step (no factory-reset prep,
                    // because the supplied key authenticates without resetting the ring).
                    onAdvanced = { ouraAdvanced = true; ouraStep = OuraStep.Gate },
                    onScan = { ouraScanner.scan(); ouraStep = OuraStep.Pick },
                    onPick = { ring ->
                        pickedOura = ring
                        // Confirm the generation from the picked ring's best-effort detection, defaulting to
                        // gen3 (the verified-corpus generation) when the name carries no generation marker.
                        ouraGen = ring.detectedGen ?: OuraRingGen.GEN3
                        nameDraft = "Oura ring"
                        ouraScanner.stopScan()
                        ouraStep = OuraStep.Confirm
                    },
                    onRescan = { ouraScanner.scan() },
                    onAdopt = {
                        // The standard adopt is destructive (it installs NOOP's key on the ring), so it
                        // gates behind the final "Take over this ring?" alert. The Advanced key path is
                        // non-destructive (it authenticates with the user's own key, never resets the ring),
                        // so it connects straight through without the destructive confirm and closes (no
                        // install runs, so there is no Adopting progress to watch).
                        if (ouraAdvanced) finishAddOura(closeAfter = true)
                        else ouraConfirmAdopt = true
                    },
                    onTryAgain = { ouraScanner.scan(); pickedOura = null; ouraStep = OuraStep.Pick },
                )
            } else {
                when (step) {
                    WizardStep.Type -> TypeStep(onPick = { t ->
                        type = t; nameDraft = ""
                        // Oura enters its own step machine at the gate, not the generic prep step.
                        if (t == DeviceType.Oura) {
                            ouraStep = OuraStep.Gate; ouraConsent = false; ouraAdvanced = false; ouraKeyDraft = ""
                        } else {
                            step = WizardStep.Prep
                        }
                    })
                    WizardStep.Prep -> type?.let { t ->
                        PrepStep(t, onScan = { startScan(t); step = WizardStep.Pick })
                    }
                    WizardStep.Pick -> type?.let { t ->
                        when {
                            t.isWhoop -> WhoopPickStep(
                                viewModel = viewModel,
                                onSelect = { strap ->
                                    pickedWhoop = strap; pickedStrap = null; pickedMachine = null; pickedHuami = null
                                    nameDraft = strap.name?.takeIf { it.isNotBlank() } ?: t.title
                                    viewModel.stopWhoopScan()
                                    step = WizardStep.Confirm
                                },
                                onRescan = { viewModel.presentWhoopScan(t.whoopModel ?: WhoopModel.WHOOP4) },
                            )
                            t == DeviceType.GymEquipment -> FtmsPickStep(
                                scanner = ftmsScanner,
                                onSelect = { machine ->
                                    pickedMachine = machine
                                    pickedWhoop = null; pickedStrap = null; pickedHuami = null
                                    nameDraft = machine.name
                                    ftmsScanner.stopScan()
                                    step = WizardStep.Confirm
                                },
                                onRescan = { ftmsScanner.scan() },
                            )
                            t == DeviceType.Amazfit || t == DeviceType.MiBand -> HuamiPickStep(
                                scanner = huamiScanner,
                                onSelect = { dev ->
                                    pickedHuami = dev
                                    pickedWhoop = null; pickedStrap = null; pickedMachine = null
                                    nameDraft = dev.name
                                    huamiScanner.stopScan()
                                    step = WizardStep.Confirm
                                },
                                onRescan = { huamiScanner.scan() },
                            )
                            else -> HrPickStep(
                                // Heart-rate strap AND Garmin (Broadcast HR is the standard 0x180D path).
                                scanner = hrScanner,
                                onSelect = { strap ->
                                    pickedStrap = strap
                                    pickedWhoop = null; pickedMachine = null; pickedHuami = null
                                    nameDraft = strap.name
                                    hrScanner.stopScan()
                                    step = WizardStep.Confirm
                                },
                                onRescan = { hrScanner.scan() },
                            )
                        }
                    }
                    WizardStep.Confirm -> ConfirmStep(
                        advertisedName = confirmAdvertisedName,
                        brand = confirmBrand,
                        rssi = confirmRssi,
                        name = nameDraft,
                        onName = { nameDraft = it },
                        onAdd = { askMakeActive = true },
                    )
                }
            }
            }
        },
        confirmButton = {},
        dismissButton = {},
    )

    // After adding, offer to make the new device active.
    if (askMakeActive) {
        AlertDialog(
            onDismissRequest = { askMakeActive = false; finishAdd(makeActive = false) },
            containerColor = Palette.surfaceOverlay,
            title = { Text(uiString(R.string.l10n_add_device_wizard_make_this_your_active_device_b425485c), style = NoopType.title2, color = Palette.textPrimary) },
            text = {
                Text(
                    uiString(R.string.l10n_add_device_wizard_make_confirmname_your_active_device_now_90ceb73e, confirmName) +
                        "this any time.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = { askMakeActive = false; finishAdd(makeActive = true) }) {
                    Text(uiString(R.string.l10n_add_device_wizard_make_active_75690bb8), style = NoopType.body, color = Palette.accent)
                }
            },
            dismissButton = {
                TextButton(onClick = { askMakeActive = false; finishAdd(makeActive = false) }) {
                    Text(uiString(R.string.l10n_add_device_wizard_not_now_e4571490), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }

    // Final destructive confirm before the Oura key install (Step D's system alert). Tapping "Take over"
    // moves to the honest Adopting progress, then registers the ring. Mirrors the macOS adopt confirm.
    if (ouraConfirmAdopt) {
        AlertDialog(
            onDismissRequest = { ouraConfirmAdopt = false },
            containerColor = Palette.surfaceOverlay,
            title = { Text(uiString(R.string.l10n_add_device_wizard_take_over_this_ring_cc79ef5e), style = NoopType.title2, color = Palette.textPrimary) },
            text = {
                Text(
                    uiString(R.string.l10n_add_device_wizard_noop_will_install_its_own_key_d3f6321e),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    ouraConfirmAdopt = false
                    ouraStep = OuraStep.Adopting
                    // The honest key-install handshake runs in the live [OuraLiveSource] once the ring is
                    // active. Register it now (active) but DO NOT close: stay on Adopting so the observed
                    // adoptPhase / needs-pairing drives it to success (close) or a REACHABLE honest Failed.
                    finishAddOura(closeAfter = false)
                }) {
                    Text(uiString(R.string.l10n_add_device_wizard_take_over_2c7f5505), style = NoopType.body, color = Palette.statusCritical)
                }
            },
            dismissButton = {
                TextButton(onClick = { ouraConfirmAdopt = false }) {
                    Text(uiString(R.string.l10n_add_device_wizard_cancel_77dfd213), style = NoopType.body, color = Palette.textSecondary)
                }
            },
        )
    }

    // Drive the Adopting step to success (the active source reached streaming -> close) or to a REACHABLE
    // honest Failed step (the active source reported its adopt failed or announced needs-pairing). Only acts
    // while on the Adopting step, so a later steady-state needs-pairing on the device card never reopens this.
    // Mirrors the Swift wizard's onChange(of: model.ouraAdoptPhase) / ouraNeedsPairing observers; a
    // LaunchedEffect keeps the state write a side effect of the observed change, not a composition write.
    val adoptPhase by viewModel.ouraAdoptPhase.collectAsStateWithLifecycle()
    LaunchedEffect(type, ouraStep, adoptPhase, adoptNeedsPairing) {
        if (type != DeviceType.Oura || ouraStep != OuraStep.Adopting) return@LaunchedEffect
        when {
            adoptPhase == com.noop.ble.OuraLiveSource.AdoptPhase.Streaming -> { stopAllScans(); onClose() }
            adoptPhase == com.noop.ble.OuraLiveSource.AdoptPhase.Failed -> ouraStep = OuraStep.Failed
            // A needs-pairing message during Adopting is an honest failure too (covers the no-ack / ack!=OK
            // paths that surface via needsPairing rather than a phase flip alone).
            adoptNeedsPairing != null -> ouraStep = OuraStep.Failed
        }
    }
}

private fun headerTitle(step: WizardStep, type: DeviceType?): String = when (step) {
    WizardStep.Type -> "Add a device"
    WizardStep.Prep -> type?.title ?: "Add a device"
    WizardStep.Pick -> "Pick your device"
    WizardStep.Confirm -> "Name & confirm"
}

private fun headerSubtitle(step: WizardStep): String? = when (step) {
    WizardStep.Type -> "What are you adding?"
    WizardStep.Prep -> "Get it ready, then scan."
    WizardStep.Pick -> "Tap the one that's yours."
    WizardStep.Confirm -> null
}

// MARK: - Oura header titles (the adopt sub-flow's own steps)

private fun ouraHeaderTitle(step: OuraStep, advanced: Boolean): String = when (step) {
    OuraStep.Gate -> if (advanced) "Advanced: use your own key" else "Oura ring"
    OuraStep.Prep -> "Get your ring ready"
    OuraStep.Pick -> "Pick the ring"
    OuraStep.Confirm -> "Your ring"
    OuraStep.Adopting -> "Taking over your ring"
    OuraStep.Failed -> "Could not take over"
}

private fun ouraHeaderSubtitle(step: OuraStep, advanced: Boolean): String? = when (step) {
    OuraStep.Gate -> if (advanced) "Power users only." else "Take it over locally. Beta."
    OuraStep.Prep -> "Reset it in the Oura app first."
    OuraStep.Pick -> "Tap the one that's yours."
    OuraStep.Confirm -> null
    OuraStep.Adopting -> null
    OuraStep.Failed -> null
}

// MARK: - Step 1 - type picker

@Composable
private fun TypeStep(onPick: (DeviceType) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TypeRow(Icons.Filled.Watch, DeviceType.Whoop5MG.title, "Newer WHOOP band. Experimental in NOOP") {
            onPick(DeviceType.Whoop5MG)
        }
        TypeRow(Icons.Filled.Watch, DeviceType.Whoop4.title, "NOOP's primary, fully-supported band") {
            onPick(DeviceType.Whoop4)
        }
        TypeRow(Icons.Filled.FavoriteBorder, DeviceType.HrStrap.title, "Polar, Wahoo, Coospo, Garmin HRM, Amazfit Helio broadcast") {
            onPick(DeviceType.HrStrap)
        }
        TypeRow(Icons.AutoMirrored.Filled.DirectionsRun, DeviceType.GymEquipment.title, "Treadmill, indoor bike, rower or cross-trainer (Bluetooth FTMS)") {
            onPick(DeviceType.GymEquipment)
        }

        // EXPERIMENTAL tier - clearly labelled, opt-in, best-effort. Each is honest about what it can
        // actually read; none fabricates data.
        Overline("Experimental", modifier = Modifier.padding(top = 8.dp))
        ExperimentalTierNote()
        TypeRow(Icons.Filled.Circle, DeviceType.Oura.title, "Take over your ring locally. Beta. This replaces the Oura app.") {
            onPick(DeviceType.Oura)
        }
        TypeRow(Icons.Filled.GraphicEq, DeviceType.Amazfit.title, "Incl. Helio. Live heart rate where the band exposes it. Help us test.") {
            onPick(DeviceType.Amazfit)
        }
        TypeRow(Icons.Filled.GraphicEq, DeviceType.MiBand.title, "Live heart rate on bands that don't need pairing. Help us test.") {
            onPick(DeviceType.MiBand)
        }
        TypeRow(Icons.Filled.Watch, DeviceType.Garmin.title, "Uses the watch's Broadcast Heart Rate. We'll show you how.") {
            onPick(DeviceType.Garmin)
        }

        WhoopFirstNote()
    }
}

/** A shared "this tier is experimental" note shown on the type-list heading and every experimental prep
 *  step. Honest, US-neutral, no em-dashes. */
@Composable
private fun ExperimentalTierNote() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Palette.statusWarning.copy(alpha = 0.10f))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Science, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(18.dp))
        Text(
            uiString(R.string.l10n_add_device_wizard_experimental_best_effort_support_we_re_db288aa8),
            style = NoopType.footnote,
            color = Palette.statusWarning,
        )
    }
}

@Composable
private fun TypeRow(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .frostedCardSurface(cornerRadius = 14.dp)
            .clickable(onClick = onClick)
            .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_title_subtitle_8d9004e8, title, subtitle) }
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(28.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary)
            Text(subtitle, style = NoopType.caption, color = Palette.textTertiary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun WhoopFirstNote() {
    Row(
        modifier = Modifier.padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.FavoriteBorder, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(16.dp))
        Text(
            uiString(R.string.l10n_add_device_wizard_whoop_is_noop_s_primary_fully_ac6fa33b),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

/**
 * The one-phone pairing warning shown before pairing a WHOOP strap. A WHOOP band bonds to a single
 * device/app at a time, so connecting it to NOOP means it won't stream to the official WHOOP app at the
 * same time (and vice versa). Honest + reversible: re-pairing in the other app hands the strap back. No
 * em-dashes. Mirrors the iOS one-phone warning card so all platforms say the same thing.
 */
@Composable
private fun OnePhoneWarningCard() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Palette.statusWarning.copy(alpha = 0.10f))
            .padding(12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.PhonelinkErase,
            contentDescription = null,
            tint = Palette.statusWarning,
            modifier = Modifier.size(18.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                uiString(R.string.l10n_add_device_wizard_one_phone_at_a_time_cff4ff44),
                style = NoopType.headline,
                color = Palette.statusWarning,
            )
            Text(
                uiString(R.string.l10n_add_device_wizard_a_whoop_strap_bonds_to_a_d39bdf4a) +
                    "to the official WHOOP app, and the other way round. It's reversible: pair it in the " +
                    "other app whenever you want it back.",
                style = NoopType.footnote,
                color = Palette.statusWarning,
            )
        }
    }
}

// MARK: - Step 2 - type-specific prep + guidance

@Composable
private fun PrepStep(type: DeviceType, onScan: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                when {
                    type.isWhoop || type == DeviceType.Garmin -> Icons.Filled.Watch
                    type == DeviceType.GymEquipment -> Icons.AutoMirrored.Filled.DirectionsRun
                    type == DeviceType.Amazfit || type == DeviceType.MiBand -> Icons.Filled.GraphicEq
                    type == DeviceType.Oura -> Icons.Filled.FileDownload
                    else -> Icons.Filled.FavoriteBorder
                },
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(28.dp),
            )
            Text(type.title, style = NoopType.title2, color = Palette.textPrimary)
        }

        if (type == DeviceType.Whoop5MG) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Palette.statusWarning.copy(alpha = 0.10f))
                    .padding(12.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Filled.Science, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(18.dp))
                Text(
                    uiString(R.string.l10n_add_device_wizard_whoop_5_0_mg_support_is_e452e686),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                )
            }
        } else if (type.isExperimental) {
            ExperimentalTierNote()
        }

        // A WHOOP strap bonds to ONE phone/app at a time. Make the trade-off explicit BEFORE pairing so it
        // isn't a surprise, with the honest reassurance that it is reversible. Mirrors the iOS one-phone
        // pairing warning card. Shown for both WHOOP models (the constraint is the strap's, not the app's).
        if (type.isWhoop) {
            OnePhoneWarningCard()
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .frostedCardSurface(cornerRadius = 14.dp)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            prepInstructions(type).forEach { line ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                    Text("•", style = NoopType.body, color = Palette.accent)
                    Text(line, style = NoopType.body, color = Palette.textSecondary)
                }
            }
        }

        TextButton(
            onClick = onScan,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Palette.accent)
                .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_scan_for_type_title_be2c98fb, type.title) },
        ) {
            Text(uiString(R.string.l10n_add_device_wizard_scan_28cba55d), style = NoopType.headline, color = Palette.goldDeepText)
        }
    }
}

/** Type-specific "get it ready" guidance - the point of the branching wizard. US English copy. */
private fun prepInstructions(type: DeviceType): List<String> = when (type) {
    DeviceType.Whoop4 -> listOf(
        "Put your WHOOP 4.0 on your wrist and make sure it's awake.",
        "Make sure it's NOT connected to the official WHOOP app right now.",
        "NOOP will look for it nearby.",
    )
    DeviceType.Whoop5MG -> listOf(
        "WHOOP 5.0 / MG bonds to one device at a time, so unpair it from the official WHOOP app first.",
        "Put the band into pairing mode, on your wrist and awake.",
        "NOOP will look for it nearby.",
    )
    DeviceType.HrStrap -> listOf(
        "Wake your strap. Put it on, or dampen the contacts.",
        "Make sure it isn't connected to another app (a bike computer, the brand's own app…).",
        "NOOP will look for it nearby.",
    )
    DeviceType.GymEquipment -> listOf(
        "Wake the machine. Start pedalling, walking or rowing so it powers on its Bluetooth.",
        "Make sure it isn't already connected to another app (Zwift, the gym's app, a bike computer…).",
        "NOOP looks for machines that broadcast the standard Bluetooth Fitness Machine service.",
    )
    DeviceType.Amazfit -> listOf(
        "Wake your Amazfit / Zepp band and make sure it isn't connected to the Zepp app right now.",
        "NOOP reads live heart rate when the band exposes it. Some bands need a pairing we can't do yet. If so, we'll say so honestly.",
        "Experimental: this is best-effort. If live doesn't work, you can export from Zepp and import the file.",
    )
    DeviceType.MiBand -> listOf(
        "Wake your Mi Band and make sure it isn't connected to the Mi Fitness / Zepp Life app right now.",
        "NOOP reads live heart rate on bands that don't require pairing. Newer bands need an auth handshake we can't do yet.",
        "Experimental: if your band needs pairing, we'll tell you honestly rather than show a fake reading.",
    )
    DeviceType.Garmin -> com.noop.ble.GarminBroadcast.broadcastHint
    // Oura runs the factory-reset-and-adopt prep inside OuraFlow (ouraPrepInstructions), so this generic
    // branch is unreached for Oura; kept for the exhaustive when.
    DeviceType.Oura -> ouraPrepInstructions
}

/** The factory-reset prep checklist for the Oura adopt flow (Step B of the onboarding UX spec). No
 *  em-dashes; matches the iOS copy. */
private val ouraPrepInstructions: List<String> = listOf(
    "Open the official Oura app and remove this ring (Oura calls it \"factory reset\" or \"unpair and " +
        "reset\"). This wipes the ring's owner so NOOP can take it over.",
    "Keep the ring on the charger or on your finger so it stays awake.",
    "Make sure the Oura app is fully closed. A ring answers one owner at a time.",
    "When the ring is reset and waking, tap Scan below.",
)

// MARK: - Step 3 - pick from the live scan

@Composable
private fun WhoopPickStep(
    viewModel: AppViewModel,
    onSelect: (WhoopBleClient.DiscoveredWhoop) -> Unit,
    onRescan: () -> Unit,
) {
    val found by viewModel.discoveredWhoops.collectAsStateWithLifecycle()
    PickList(searching = true, isEmpty = found.isEmpty(), onRescan = onRescan) {
        found.sortedByDescending { it.rssi }.forEach { strap ->
            DiscoveredRow(
                name = strap.name?.takeIf { it.isNotBlank() } ?: "WHOOP",
                subtitle = "WHOOP",
                rssi = strap.rssi,
                onTap = { onSelect(strap) },
            )
        }
    }
}

@Composable
private fun HrPickStep(
    scanner: StandardHrSource,
    onSelect: (StandardHrSource.DiscoveredStrap) -> Unit,
    onRescan: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    PickList(searching = scanning, isEmpty = discovered.isEmpty(), onRescan = onRescan) {
        discovered.sortedByDescending { it.rssi }.forEach { strap ->
            DiscoveredRow(
                name = strap.name,
                subtitle = brandGuess(strap.name),
                rssi = strap.rssi,
                onTap = { onSelect(strap) },
            )
        }
    }
}

@Composable
private fun FtmsPickStep(
    scanner: com.noop.ble.FtmsSource,
    onSelect: (com.noop.ble.FtmsSource.DiscoveredMachine) -> Unit,
    onRescan: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    PickList(searching = scanning, isEmpty = discovered.isEmpty(), onRescan = onRescan) {
        discovered.sortedByDescending { it.rssi }.forEach { machine ->
            DiscoveredRow(
                name = machine.name,
                subtitle = "Gym equipment",
                rssi = machine.rssi,
                onTap = { onSelect(machine) },
            )
        }
    }
}

@Composable
private fun HuamiPickStep(
    scanner: com.noop.ble.HuamiHrSource,
    onSelect: (com.noop.ble.HuamiHrSource.DiscoveredDevice) -> Unit,
    onRescan: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    PickList(searching = scanning, isEmpty = discovered.isEmpty(), onRescan = onRescan) {
        discovered.sortedByDescending { it.rssi }.forEach { dev ->
            DiscoveredRow(
                name = dev.name,
                subtitle = "Experimental",
                rssi = dev.rssi,
                onTap = { onSelect(dev) },
            )
        }
    }
}

// MARK: - Oura factory-reset-and-adopt flow (section 2 of the onboarding UX spec)
//
// Faithful Compose port of the macOS Oura adopt flow. The Oura type runs its OWN step machine
// (gate -> prep -> pick -> confirm -> adopting) plus the Advanced (B-Alt) key path. Every screen is
// honest: the destructive consent gate, the single-owner warning, the per-gen capability checklist (dash
// for not-available, * for an on-device estimate), and the honest progress sub-states. No em-dashes; the
// copy matches docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md exactly.

@Composable
private fun OuraFlow(
    ouraStep: OuraStep,
    advanced: Boolean,
    consent: Boolean,
    keyDraft: String,
    scanner: OuraLiveSource,
    gen: OuraRingGen,
    name: String,
    failureReason: String?,
    onConsent: (Boolean) -> Unit,
    onKeyDraft: (String) -> Unit,
    onName: (String) -> Unit,
    onContinue: () -> Unit,
    onUseFileImport: () -> Unit,
    onAdvanced: () -> Unit,
    onScan: () -> Unit,
    onPick: (OuraLiveSource.DiscoveredRing) -> Unit,
    onRescan: () -> Unit,
    onAdopt: () -> Unit,
    onTryAgain: () -> Unit,
) {
    when (ouraStep) {
        OuraStep.Gate -> if (advanced) OuraAdvancedKeyStep(keyDraft, onKeyDraft, onScan)
        else OuraGateStep(consent, onConsent, onContinue, onUseFileImport, onAdvanced)
        OuraStep.Prep -> OuraPrepStep(advanced, onScan)
        OuraStep.Pick -> OuraPickStep(scanner, onPick, onRescan)
        OuraStep.Confirm -> OuraConfirmStep(advanced, gen, name, onName, onAdopt)
        OuraStep.Adopting -> OuraAdoptingStep()
        OuraStep.Failed -> OuraFailedStep(failureReason, onTryAgain, onUseFileImport)
    }
}

// MARK: Step A - the honest gate ("This replaces Oura")

@Composable
private fun OuraGateStep(
    consent: Boolean,
    onConsent: (Boolean) -> Unit,
    onContinue: () -> Unit,
    onUseFileImport: () -> Unit,
    onAdvanced: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        // Beta banner (amber heads-up pattern).
        OuraAmberPanel(
            "Beta. Read this first.",
            "Local Oura support is new and we cannot test every ring here. It may not connect on your " +
                "ring, and it can change between updates. NOOP never makes up a number. If something does " +
                "not work, it will tell you plainly.",
        )

        // What you get / what you lose, two stacked sections on a frosted card.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .frostedCardSurface(cornerRadius = 14.dp)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Overline("What you get")
            OuraBulletList(
                listOf(
                    "Your ring talks to NOOP only, fully offline, no Oura account.",
                    "Live heart rate, and HRV when the ring can measure it.",
                    "Overnight sleep staging, resting heart rate, skin-temperature trend, motion and " +
                        "battery, read straight off the ring.",
                    "NOOP's own Charge, Effort and Rest, computed on your device from published methods.",
                ),
            )
            Overline("What you lose")
            OuraBulletList(
                listOf(
                    "The Oura app and your Oura account stop working with this ring. This is the point. " +
                        "You are replacing Oura.",
                    "Oura's own Readiness and Sleep scores. NOOP does not copy them. It computes its own.",
                    "Anything that needs Oura's cloud (web dashboard, Oura's coaching, shared circles).",
                    "Likely your Oura warranty and support, because the ring is no longer paired to Oura. " +
                        "Treat this as permanent.",
                ),
            )
        }

        // The irreversible consent line, styled critical (red), with a tap-to-tick checkbox.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Palette.statusCritical.copy(alpha = 0.10f))
                .clickable { onConsent(!consent) }
                .semantics {
                    contentDescription =
                        uiString(R.string.l10n_add_device_wizard_i_understand_this_disconnects_the_ring_ccbb3225)
                }
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                if (consent) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank,
                contentDescription = null,
                tint = Palette.statusCritical,
                modifier = Modifier.size(20.dp),
            )
            Text(
                uiString(R.string.l10n_add_device_wizard_i_understand_this_disconnects_the_ring_66bbb125),
                style = NoopType.footnote,
                color = Palette.statusCritical,
            )
        }

        // Primary continue (disabled until ticked).
        TextButton(
            onClick = onContinue,
            enabled = consent,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(if (consent) Palette.accent else Palette.surfaceInset)
                .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_continue_2e026239) },
        ) {
            Text(
                uiString(R.string.l10n_add_device_wizard_continue_2e026239),
                style = NoopType.headline,
                color = if (consent) Palette.goldDeepText else Palette.textTertiary,
            )
        }
        // Secondary: keep the Oura app (non-destructive file import) - always one tap away.
        TextButton(onClick = onUseFileImport, modifier = Modifier.fillMaxWidth()) {
            Text(uiString(R.string.l10n_add_device_wizard_keep_the_oura_app_instead_import_60d70411), style = NoopType.subhead, color = Palette.accent)
        }
        // Tertiary: Advanced power-user key path.
        TextButton(onClick = onAdvanced, modifier = Modifier.fillMaxWidth()) {
            Text(uiString(R.string.l10n_add_device_wizard_advanced_i_already_have_my_ring_e87b9b49), style = NoopType.footnote, color = Palette.accent)
        }
    }
}

// MARK: Step B-Alt - Advanced: import a 16-byte key (keep the Oura app)

@Composable
private fun OuraAdvancedKeyStep(
    keyDraft: String,
    onKeyDraft: (String) -> Unit,
    onScan: () -> Unit,
) {
    val parsed = parseHexKey(keyDraft)
    val showError = keyDraft.isNotBlank() && parsed == null
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        OuraAmberPanel(
            "For power users.",
            "If you extracted your ring's 16-byte key from a previous Oura setup, NOOP can talk to the " +
                "ring with that key WITHOUT resetting it, so the Oura app keeps working too. NOOP does not " +
                "extract keys for you and cannot help you find one. If you do not know what this means, go " +
                "back and use the standard setup or file import.",
        )
        Overline("Ring key (32 hex characters)")
        OutlinedTextField(
            value = keyDraft,
            onValueChange = { onKeyDraft(it) },
            singleLine = true,
            isError = showError,
            placeholder = { Text(uiString(R.string.l10n_add_device_wizard_0123456789abcdef0123456789abcdef_b1775a78), style = NoopType.body, color = Palette.textTertiary) },
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = KeyboardType.Ascii),
            visualTransformation = VisualTransformation.None,
            colors = wizardFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_ring_key_32_hex_characters_28cb7e4a) },
        )
        if (showError) {
            Text(uiString(R.string.l10n_add_device_wizard_that_is_not_a_32_character_d42ca20d), style = NoopType.footnote, color = Palette.statusCritical)
        }
        Text(
            uiString(R.string.l10n_add_device_wizard_noop_stores_this_key_only_on_eae4e63f),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        TextButton(
            onClick = onScan,
            enabled = parsed != null,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(if (parsed != null) Palette.accent else Palette.surfaceInset)
                .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_scan_for_your_ring_e92b3a3b) },
        ) {
            Text(
                uiString(R.string.l10n_add_device_wizard_scan_for_your_ring_e92b3a3b),
                style = NoopType.headline,
                color = if (parsed != null) Palette.goldDeepText else Palette.textTertiary,
            )
        }
    }
}

// MARK: Step B - Prep: factory-reset in the Oura app

@Composable
private fun OuraPrepStep(advanced: Boolean, onScan: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .frostedCardSurface(cornerRadius = 14.dp)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ouraPrepInstructions.forEach { line ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                    Icon(Icons.Filled.Check, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                    Text(line, style = NoopType.body, color = Palette.textSecondary)
                }
            }
        }
        // The single-owner warning (only meaningful for the destructive adopt path; the Advanced key path
        // does not reset the ring, so it skips the "force-quit Oura" framing).
        if (!advanced) {
            OuraAmberPanel(
                "A ring talks to one owner at a time.",
                "If the Oura app is still running it will hold the ring and adoption will fail. Force-quit " +
                    "Oura, then scan.",
            )
        }
        TextButton(
            onClick = onScan,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(Palette.accent)
                .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_scan_for_your_ring_e92b3a3b) },
        ) {
            Text(uiString(R.string.l10n_add_device_wizard_scan_for_your_ring_e92b3a3b), style = NoopType.headline, color = Palette.goldDeepText)
        }
    }
}

// MARK: Step C - Pick the ring (live scan)

@Composable
private fun OuraPickStep(
    scanner: OuraLiveSource,
    onPick: (OuraLiveSource.DiscoveredRing) -> Unit,
    onRescan: () -> Unit,
) {
    val discovered by scanner.discovered.collectAsStateWithLifecycle()
    val scanning by scanner.scanning.collectAsStateWithLifecycle()
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatePill(
                if (scanning) "Searching…" else "Idle",
                tone = if (scanning) StrandTone.Accent else StrandTone.Neutral,
                pulsing = scanning,
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onRescan) {
                Text(uiString(R.string.l10n_add_device_wizard_rescan_84661f6a), style = NoopType.subhead, color = Palette.accent)
            }
        }
        if (discovered.isEmpty()) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .frostedCardSurface(cornerRadius = 14.dp)
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(color = Palette.accent, modifier = Modifier.size(22.dp))
                Text(uiString(R.string.l10n_add_device_wizard_searching_1a6a5ba8), style = NoopType.body, color = Palette.textPrimary)
                Text(
                    uiString(R.string.l10n_add_device_wizard_not_showing_up_make_sure_you_60a8a61b),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                discovered.sortedByDescending { it.rssi }.forEach { ring ->
                    DiscoveredRow(
                        name = ring.name,
                        // Subtitle = the detected generation (best-effort); "Oura ring" when undetected.
                        subtitle = ring.detectedGen?.displayName ?: "Oura ring",
                        rssi = ring.rssi,
                        onTap = { onPick(ring) },
                    )
                }
            }
        }
    }
}

// MARK: Step D - Detect generation + confirm + the destructive adopt action

@Composable
private fun OuraConfirmStep(
    advanced: Boolean,
    gen: OuraRingGen,
    name: String,
    onName: (String) -> Unit,
    onAdopt: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        // The identified ring: gen name + per-gen capability checklist + a Beta pill.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .frostedCardSurface(cornerRadius = 14.dp)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Filled.Circle, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(24.dp))
                Text(gen.displayName, style = NoopType.headline, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                StatePill("Beta", tone = StrandTone.Warning, showsDot = false)
            }
            // Per-gen capability checklist: tick for supported, dash for not-available, * for an estimate.
            ouraCapabilityRows(gen).forEach { (mark, label) ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                    Text(mark, style = NoopType.caption, color = Palette.textTertiary, modifier = Modifier.width(14.dp))
                    Text(label, style = NoopType.caption, color = Palette.textSecondary)
                }
            }
            Text(
                uiString(R.string.l10n_add_device_wizard_beta_is_an_on_device_estimate_128563e0) +
                    "are a raw motion count, and HRV needs you to be still. No Oura Readiness or SpO2 " +
                    "percentage comes off the ring (import an Oura file for those).",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }

        Overline("Name")
        OutlinedTextField(
            value = name,
            onValueChange = onName,
            singleLine = true,
            placeholder = { Text(uiString(R.string.l10n_add_device_wizard_oura_ring_e3431536), style = NoopType.body, color = Palette.textTertiary) },
            colors = wizardFieldColors(),
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_device_name_79d7a157) },
        )

        // The adopt action. The destructive (key-install) path is red; the Advanced key path is not
        // destructive (it does not reset the ring), so it reads as a plain accent connect.
        if (advanced) {
            TextButton(
                onClick = onAdopt,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Palette.accent)
                    .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_connect_to_this_ring_02b9442b) },
            ) {
                Text(uiString(R.string.l10n_add_device_wizard_connect_to_this_ring_02b9442b), style = NoopType.headline, color = Palette.goldDeepText)
            }
            Text(
                uiString(R.string.l10n_add_device_wizard_both_noop_and_the_oura_app_4f219db3),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        } else {
            TextButton(
                onClick = onAdopt,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(Palette.statusCritical.copy(alpha = 0.16f))
                    .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_take_over_this_ring_f199dc22) },
            ) {
                Text(uiString(R.string.l10n_add_device_wizard_take_over_this_ring_f199dc22), style = NoopType.headline, color = Palette.statusCritical)
            }
        }
    }
}

// MARK: Step E - Adopting (key install) progress

@Composable
private fun OuraAdoptingStep() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .frostedCardSurface(cornerRadius = 14.dp)
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(color = Palette.accent, modifier = Modifier.size(22.dp))
            Text(uiString(R.string.l10n_add_device_wizard_taking_over_your_ring_b64a3852), style = NoopType.headline, color = Palette.textPrimary)
        }
        Text(
            uiString(R.string.l10n_add_device_wizard_installing_noop_s_key_and_confirming_aab5cf61),
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )
    }
}

// MARK: Step E (failure) - honest dead-end, never a fabricated success

@Composable
private fun OuraFailedStep(reason: String?, onTryAgain: () -> Unit, onUseFileImport: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .frostedCardSurface(cornerRadius = 14.dp)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(uiString(R.string.l10n_add_device_wizard_we_could_not_take_over_this_fec1ce93), style = NoopType.headline, color = Palette.textPrimary)
        // Surface the live adopt-failure reason when the source reported one; otherwise the static help.
        // Mirrors the Swift wizard's `model.ouraNeedsPairing ?? <static fallback>`.
        Text(
            reason ?: "The most common cause is the ring was not fully reset in the Oura app, or the Oura " +
                "app is still running. Reset the ring again, force-quit Oura, then try once more. If it keeps " +
                "failing, your ring may be a generation NOOP cannot adopt yet. You can still use file import.",
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )
        // Honest recovery reassurance (Swift parity): a failed adopt never bricks the ring.
        Text(
            uiString(R.string.l10n_add_device_wizard_the_ring_is_not_bricked_to_5efd1b3d) +
                "up in the Oura app.",
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(
                onClick = onTryAgain,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Palette.accent),
            ) {
                Text(uiString(R.string.l10n_add_device_wizard_try_again_042c862e), style = NoopType.headline, color = Palette.goldDeepText)
            }
            TextButton(
                onClick = onUseFileImport,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Palette.surfaceInset),
            ) {
                Text(uiString(R.string.l10n_add_device_wizard_use_file_import_0e092cb4), style = NoopType.headline, color = Palette.accent)
            }
        }
    }
}

// MARK: - Oura shared pieces

/** An amber heads-up panel (the experimental-note / single-owner-warning treatment): bold lead line +
 *  body, statusWarning at 0.10 fill. No em-dashes. */
@Composable
private fun OuraAmberPanel(title: String, body: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Palette.statusWarning.copy(alpha = 0.10f))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(16.dp))
            Text(title, style = NoopType.subhead, color = Palette.statusWarning)
        }
        Text(body, style = NoopType.footnote, color = Palette.statusWarning)
    }
}

/** A simple bulleted list used in the gate's "what you get / lose" sections. */
@Composable
private fun OuraBulletList(lines: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        lines.forEach { line ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                Text("•", style = NoopType.body, color = Palette.accent)
                Text(line, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

/**
 * The per-generation capability checklist (section 3 of the onboarding UX spec). Each row is a (mark,
 * label) pair: a tick for decoded-and-used, * for a best-effort on-device estimate, and a dash for
 * not-available-off-the-ring. Gen3/Ring4 are the verified path; the newer (gen4-family / gen5) variant
 * carries the same set with the extra caveat that decoding is least proven. Mirrors the macOS capability
 * matrix; no Oura Readiness/Sleep score or absolute SpO2 % ever comes off the ring.
 */
private fun ouraCapabilityRows(gen: OuraRingGen): List<Pair<String, String>> {
    val live = if (gen == OuraRingGen.GEN5) "*" else "✓"   // newer rings: live HR is best-effort
    val firm = if (gen == OuraRingGen.GEN5) "*" else "✓"   // resting HR / sleep / battery
    return listOf(
        live to "Live heart rate",
        "*" to "HRV (rMSSD)",
        firm to "Resting heart rate",
        firm to "Sleep staging",
        "*" to "Skin-temperature trend",
        "*" to "Steps / motion",
        firm to "Battery",
        "-" to "Blood oxygen (SpO2 %)",
        "-" to "Oura Readiness / Sleep score",
    )
}

/**
 * Parse a 32-hex-character ring key string into 16 unsigned bytes (0..255), or null when it is not exactly
 * 32 hex chars. Whitespace is ignored so a pasted key with stray spaces still validates. Shared by the
 * Advanced gate's validation and finishAddOura's key store write. Mirrors the macOS 16-byte/32-hex check.
 */
private fun parseHexKey(input: String): IntArray? {
    val hex = input.filterNot { it.isWhitespace() }
    if (hex.length != 32) return null
    if (!hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
    return IntArray(16) { i -> hex.substring(i * 2, i * 2 + 2).toInt(16) }
}

/** Shared pick-step shell: a searching status bar + a Rescan button, then either the searching card
 *  (while [isEmpty]) or the caller's discovered [rows]. Mirrors the iOS pick step's ScanStatusBar +
 *  SearchingCard. */
@Composable
private fun PickList(
    searching: Boolean,
    isEmpty: Boolean,
    onRescan: () -> Unit,
    rows: @Composable () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatePill(
                if (searching) "Searching…" else "Idle",
                tone = if (searching) StrandTone.Accent else StrandTone.Neutral,
                pulsing = searching,
            )
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onRescan) {
                Text(uiString(R.string.l10n_add_device_wizard_rescan_84661f6a), style = NoopType.subhead, color = Palette.accent)
            }
        }
        if (isEmpty) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .frostedCardSurface(cornerRadius = 14.dp)
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(color = Palette.accent, modifier = Modifier.size(22.dp))
                Text(uiString(R.string.l10n_add_device_wizard_searching_1a6a5ba8), style = NoopType.body, color = Palette.textPrimary)
                Text(
                    uiString(R.string.l10n_add_device_wizard_make_sure_it_s_awake_and_8c40e59f),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) { rows() }
        }
    }
}

@Composable
private fun DiscoveredRow(name: String, subtitle: String, rssi: Int, onTap: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .frostedCardSurface(cornerRadius = 12.dp)
            .clickable(onClick = onTap)
            .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_name_signal_signalbars_level_rssi_of_6aa514f6, name, SignalBars.level(rssi)) }
            .padding(14.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SignalBars(rssi)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, style = NoopType.body, color = Palette.textPrimary)
            Text(subtitle, style = NoopType.caption, color = Palette.textTertiary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(18.dp),
        )
    }
}

// MARK: - Step 4 - name + confirm

@Composable
private fun ConfirmStep(
    advertisedName: String,
    brand: String,
    rssi: Int,
    name: String,
    onName: (String) -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .frostedCardSurface(cornerRadius = 12.dp)
                .padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SignalBars(rssi)
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(advertisedName, style = NoopType.headline, color = Palette.textPrimary)
                Text(brand, style = NoopType.caption, color = Palette.textTertiary)
            }
        }

        Overline("Name")
        OutlinedTextField(
            value = name,
            onValueChange = onName,
            singleLine = true,
            placeholder = { Text(uiString(R.string.l10n_add_device_wizard_device_name_79d7a157), style = NoopType.body, color = Palette.textTertiary) },
            colors = wizardFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = uiString(R.string.l10n_add_device_wizard_device_name_79d7a157) },
        )

        TextButton(
            onClick = onAdd,
            enabled = name.trim().isNotEmpty(),
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(if (name.trim().isNotEmpty()) Palette.accent else Palette.surfaceInset),
        ) {
            Text(
                uiString(R.string.l10n_add_device_wizard_add_61cc55aa),
                style = NoopType.headline,
                color = if (name.trim().isNotEmpty()) Palette.goldDeepText else Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun wizardFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)
