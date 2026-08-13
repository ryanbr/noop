import SwiftUI
import StrandDesign
import StrandAnalytics   // ConnectionReadout - the #987 clock-latch / RTC-epoch readout parsers
import WhoopStore
import OuraProtocol
import WhoopProtocol   // Whoop5Ecg.WristSelection — the MG ECG wrist-selection step

// MARK: - Devices
//
// Pair and manage the bands NOOP reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over `DeviceRegistry` (the Phase 1A/1B data layer): every mutation
// goes through a registry op, and the `SourceCoordinator` (already wired in AppModel) reacts to the
// active-device change — so this view never touches BLEManager or the WHOOP path directly.
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    // PERF: this OUTER view does NOT observe `LiveState`. It only branches on `model.deviceRegistry`
    // becoming non-nil and hands off to `DevicesContent`, which owns its own `@EnvironmentObject live`
    // (the live battery / "Active · Live" badge live there). Observing `live` here would re-render the
    // whole screen on every ~1 Hz strap tick for no visible change — `live` is still in the environment
    // for `DevicesContent` and the Add-device wizard, so nothing downstream loses its live readout.

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "Pair and manage the bands NOOP reads from.",
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends: a fixed,
                       // full-bleed time-of-day sky behind the scroll content (it does not scroll).
                       topBackground: liquidScaffoldSky()) {
            if let registry = model.deviceRegistry {
                DevicesContent(registry: registry)
            } else {
                // The registry is built once the on-device store opens (a beat after launch). Show a
                // calm pending note rather than an empty screen in that brief window.
                DataPendingNote(
                    title: "Getting your devices ready",
                    message: "NOOP is opening your on-device data. Your paired bands will appear here in a moment.",
                    symbol: "badge.plus.radiowaves.right")
            }
        }
    }
}

// MARK: - Content (registry resolved)

/// The screen body once `DeviceRegistry` exists. Split out so it can observe the registry's
/// `@Published devices` / `activeDeviceId` directly — the parent only observes `model.deviceRegistry`
/// becoming non-nil.
private struct DevicesContent: View {
    @ObservedObject var registry: DeviceRegistry
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    // Sheets / alerts
    @State private var showAddWizard = false
    @State private var switchTarget: PairedDevice?
    @State private var renameTarget: PairedDevice?
    @State private var renameDraft = ""
    @State private var removeTarget: PairedDevice?
    @State private var deleteDataTarget: PairedDevice?
    @State private var forgetTarget: PairedDevice?
    @State private var rebootTarget: PairedDevice?
    /// WHOOP 4.0 reboot probe (Test Centre → Connection, 4.0 only) — the device whose probe sheet is open.
    @State private var probeTarget: PairedDevice?
    /// #592 extended-battery probe (Test Centre → Connection) — the device whose confirm dialog is open.
    @State private var batteryProbeTarget: PairedDevice?
    /// #690 body-location probe (Test Centre → Connection) — the device whose confirm dialog is open.
    @State private var bodyLocationProbeTarget: PairedDevice?
    /// #761 feature-flag enumeration probe (Test Centre → Connection) — the device whose dialog is open.
    @State private var featureFlagProbeTarget: PairedDevice?
    /// MG ECG (Labrador) probe — the device whose action dialog is open.
    @State private var ecgProbeTarget: PairedDevice?
    /// The SEPARATE wrist-selection confirm. Its own state (and its own dialog) because SELECT_WRIST is a
    /// persistent strap write and must never ride along inside a start flow.
    @State private var ecgWristTarget: PairedDevice?
    /// The Experimental ECG opt-in. Read here so the menu entry appears only once the user has opted in.
    @AppStorage(PuffinExperiment.ecgKey) private var ecgEnabled = false
    /// #103 device-config READ probe (Test Centre → Connection) — the device whose dialog is open.
    @State private var deviceConfigProbeTarget: PairedDevice?
    /// After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    @State private var pickNewActive = false

    private var activeDevices: [PairedDevice] { registry.devices.filter { $0.status != .archived } }
    private var removedDevices: [PairedDevice] { registry.devices.filter { $0.status == .archived } }
    /// I-1: `activeDevices` minus import sources (cloud/file) — the candidates actually eligible for
    /// "make active". An import source is a data partition, not a live device; offering it here would let
    /// activating it demote the live WHOOP driving BLE routing + day-owner priority 0.
    private var activatableDevices: [PairedDevice] { activeDevices.filter { !$0.isImportSource } }

    /// #987: the active+connected strap's clock state, from the SAME pure ConnectionReadout parsers the
    /// Test Centre Connection panel binds (one source of truth). nil (no row at all) until the WHOOP path
    /// has produced any clock signal - a routed frame, a clock correlation, or a data-range reply - so a
    /// generic HR strap or an idle card never shows a fabricated "waiting" state. One computation for
    /// both the line and the warning (the log scan is the cost worth paying once, not twice).
    private var strapClockState: (line: String, warning: String?)? {
        guard live.connected else { return nil }
        let deviceClock = ConnectionReadout.clockCorrelatedDevice(logLines: live.log)
        guard deviceClock != nil || live.strapRange != nil || live.lastFrameAtUnix != nil else { return nil }
        let latched = ConnectionReadout.clockLatchedLabel(deviceClockUnix: deviceClock,
                                                          strapNewestUnix: live.strapRange?.newestUnix)
        let frame = ConnectionReadout.lastFrameLabel(lastFrameUnix: live.lastFrameAtUnix,
                                                     nowUnix: Int(Date().timeIntervalSince1970))
        let warning = ConnectionReadout.rtcWarning(deviceClockUnix: deviceClock,
                                                   strapNewestUnix: live.strapRange?.newestUnix)
        return (String(localized: "Clock latched: \(latched) · last frame \(frame)"), warning)
    }

    /// #802: same shape and copy as `LiveView.reconnectGuideBanner`. Duplicated rather than hoisted
    /// because the two live in different view files with no shared banner container today; the STRING is
    /// shared, which is the part that must not drift.
    private func repairGuideBanner(_ guide: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Can't connect: your strap's pairing was reset")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(guide)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.space3)
        .background(NoopPanelSurface(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnect help: \(guide)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            // #802: the re-pair guide belongs HERE too, not only on Live. A strap that connects but never
            // finishes bonding leaves the user on this screen — it is where you go to fix a device — while
            // the four steps that resolve it were rendered one tab away. The reporter in #802 filed an issue
            // with the guide already armed, because nothing on Devices said so. Same state and same string
            // as LiveView's banner; no new copy.
            if let guide = live.reconnectGuide { repairGuideBanner(guide) }
            DeviceSyncStatusCard()
            // UPPERCASE overline section header, matching the liquid Today. Counts the paired bands so the
            // multi-WHOOP reality reads at a glance.
            sectionHead("YOUR BANDS", trailing: activeDevices.count == 1
                        ? String(localized: "1 paired")
                        : String(localized: "\(activeDevices.count) paired"))
            // #1300: a prominent switcher to flip which strap is active — the "switch, don't combine"
            // option for a user with two straps (e.g. a 4.0 + a 5/MG). Shown only with 2+ straps, so it
            // auto-collapses when one is forgotten. Reuses the existing active-strap confirmation.
            if activeDevices.count > 1 { strapSwitcher }
            ForEach(Array(activeDevices.enumerated()), id: \.element.id) { idx, device in
                // Shared read-only probe gate (Test Centre → Connection + a live WHOOP), hoisted so the two
                // probe closures below don't each re-inline a 4-term && chain — which tips the iOS Swift
                // type-checker over its budget ("unable to type-check this expression in reasonable time").
                let probeGate = device.status == .active && live.connected
                    && SourceCoordinator.isWhoop(device) && TestCentre.active(.connection)
                // The ECG probe WRITES to the strap, so it carries two gates the read-only probes don't:
                // the Experimental opt-in, and a strap that has positively attested itself a WHOOP MG
                // (a plain 5.0 has no electrodes; `.unknown` is not MG).
                //
                // `|| model.ecgMayBeRunning` keeps the entry — and therefore Stop — reachable after the
                // opt-in has been switched off mid-session. Turning a feature off must not remove the
                // only control that turns the STRAP off; the MG gate still applies either way.
                let ecgGate = probeGate && (ecgEnabled || model.ecgMayBeRunning) && model.isWhoop5MG
                DeviceCard(
                    device: device,
                    isActive: device.status == .active,
                    isLiveConnected: device.status == .active && live.connected,
                    // #221: a WHOOP 5/MG can be BLE-connected yet have its ENCRYPTED bond refused (the
                    // WHOOP app, or a stale iOS pairing, holds the single-app bond) — no HR/biometric data
                    // flows even though the link is up, so "Active · Live" overstates it. pairingHint is
                    // set only once that refusal is genuinely detected (#78), never during a normal
                    // connect, so this can't false-alarm a working 4.0 (its pairingHint stays nil) or a
                    // fresh 5/MG connect.
                    bondRefused: device.status == .active && live.connected && live.pairingHint != nil,
                    // The full #78 how-to-fix guidance, surfaced on the card itself when bondRefused so
                    // the fix is self-service instead of buried in the strap log.
                    pairingHint: device.status == .active ? live.pairingHint : nil,
                    // Reboot in flight + link currently down → "Reconnecting…" (#166).
                    isReconnecting: device.status == .active && live.rebootInProgress && !live.connected,
                    // The live battery belongs to whichever device is ACTIVE + connected (the WHOOP, a
                    // generic strap, or an FTMS machine all funnel into live.batteryPct). nil otherwise.
                    liveBatteryPct: (device.status == .active && live.connected) ? live.batteryPct.map { Int($0.rounded()) } : nil,
                    liveBatteryMv: (device.status == .active && live.connected) ? live.batteryMv : nil,
                    // Firmware version for the ACTIVE strap. It's a STABLE property (NOOP can't change a
                    // strap's firmware), so prefer the live handshake value but fall back to the last-known
                    // persisted firmware (written on connect in FrameRouter) when the live value is momentarily
                    // nil — mid-handshake, or a connection that hasn't re-read GET_HELLO/REPORT_VERSION_INFO
                    // yet this session. Without this the "· FW x" blanks out while actively connected. The
                    // persisted fallback is WHOOP-only: "noop.lastFirmware" is written solely from a WHOOP
                    // handshake, so a non-WHOOP active device (Oura) must NOT inherit it. Single last-connected-
                    // strap key, so a not-yet-connected active strap can briefly show the other strap's build on
                    // a multi-WHOOP install until it republishes. Twin of Android.
                    liveFirmware: device.status == .active
                        ? (live.strapFirmware
                            ?? (SourceCoordinator.isWhoop(device) ? UserDefaults.standard.string(forKey: "noop.lastFirmware") : nil))
                        : nil,
                    // Historical record layout (v24/v25 on WHOOP 4.0) observed from this connection's
                    // backfill. Distinct from the strap firmware build shown as FW.
                    liveHistoryLayout: (device.status == .active && live.connected) ? live.strapRange?.firmwareLayout : nil,
                    // #987: clock latch + frame freshness + the 1970/71 RTC warning, active card only.
                    liveClockLine: device.status == .active ? strapClockState?.line : nil,
                    liveClockWarning: device.status == .active ? strapClockState?.warning : nil,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: { removeTarget = device },
                    // Restart is offered only for a live-connected WHOOP that is NOT a 4.0: the strap-log
                    // analysis on #275 showed no safe frame reboots a 4.0 (empty bodies are ignored; any
                    // non-empty body just wedges the BLE link for ~7s, sensor stays on), so a 4.0 Restart
                    // button could never work. 5.0/MG reboot on the production frame. nil otherwise.
                    onReboot: (device.status == .active && live.connected
                               && SourceCoordinator.isWhoop(device)
                               && !model.ble.isWhoop4) ? { rebootTarget = device } : nil,
                    // 4.0 reboot probe: only offered when Test Centre → Connection is on AND the live
                    // strap is a WHOOP 4.0 (a 5.0 already reboots on the production frame). nil otherwise.
                    onRebootProbe: (device.status == .active && live.connected
                                    && SourceCoordinator.isWhoop(device)
                                    && model.ble.isWhoop4
                                    && TestCentre.active(.connection)) ? { probeTarget = device } : nil,
                    // #592 extended-battery probe: read-only, BOTH families (the 4.0 is discriminating).
                    // Same Test Centre → Connection gate as the reboot probe, minus the 4.0-only clause.
                    onExtendedBatteryProbe: probeGate ? { batteryProbeTarget = device } : nil,
                    // #690 body-location probe: read-only, both families. Same Test Centre → Connection gate.
                    onBodyLocationProbe: probeGate ? { bodyLocationProbeTarget = device } : nil,
                    // #761 feature-flag ENUMERATION probe: read-only (names only, nothing written), both
                    // families. Same Test Centre → Connection gate.
                    onFeatureFlagProbe: probeGate ? { featureFlagProbeTarget = device } : nil,
                    // Stop an offload already in flight. Offered ONLY while one is running on this
                    // strap — not a Test Centre probe but an ordinary escape hatch, because until now
                    // a long drain could only be ended by the 15-minute timeout or walking out of
                    // range. Nothing is lost: unacked records stay on the strap.
                    onAbortSync: (device.status == .active && live.connected && live.backfilling
                                  && SourceCoordinator.isWhoop(device))
                        ? { model.ble.abortBackfill() } : nil,
                    // MG ECG probe: the Test Centre gate PLUS the Experimental ECG opt-in PLUS a
                    // positively-identified MG. `ecgGate` is hoisted for the same type-checker reason as
                    // `probeGate`; BLEManager gates the sends again, so the UI gate is defence in depth,
                    // never the only thing standing between a 5.0 and an ECG command.
                    onEcgProbe: ecgGate ? { ecgProbeTarget = device } : nil,
                    // #103 device-config READ probe: read-only (asks for VALUES, writes none), both
                    // families. Same Test Centre → Connection gate.
                    onDeviceConfigProbe: probeGate ? { deviceConfigProbeTarget = device } : nil)
                    .staggeredAppear(index: idx)
            }

            addButton
                .staggeredAppear(index: activeDevices.count)

            if !removedDevices.isEmpty { removedSection }

            whoopFirstFooter
        }
        // Add a device — guided, branching wizard (asks the device TYPE first, then runs the right
        // scan/register path: WHOOP present-scan for WHOOP families, StandardHRSource for HR straps).
        .sheet(isPresented: $showAddWizard) {
            AddDeviceWizard(live: live) { showAddWizard = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        // Switch confirm
        .alert("Make this your active strap?",
               isPresented: Binding(get: { switchTarget != nil },
                                    set: { if !$0 { switchTarget = nil } }),
               presenting: switchTarget) { device in
            Button("Cancel", role: .cancel) { switchTarget = nil }
            Button("Make active") {
                registry.setActive(device.id)
                switchTarget = nil
            }
        } message: { device in
            Text("Make \(device.displayName) your active strap? From now on it provides your live data. \(currentActiveName)'s history stays exactly as it is. Only new days come from \(device.displayName).")
        }
        // Rename
        .alert("Rename device",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { device in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                registry.rename(device.id, to: renameDraft)
                renameTarget = nil
            }
        } message: { device in
            Text("Give \(device.brand) \(device.model) a name you'll recognise.")
        }
        // Remove confirm
        .alert("Remove this device?",
               isPresented: Binding(get: { removeTarget != nil },
                                    set: { if !$0 { removeTarget = nil } }),
               presenting: removeTarget) { device in
            Button("Cancel", role: .cancel) { removeTarget = nil }
            Button("Remove", role: .destructive) { confirmRemove(device) }
        } message: { device in
            Text("Remove \(device.displayName)? NOOP will stop connecting to it. Its recorded data is kept and you can re-add it any time.")
        }
        // Restart strap confirm (#166)
        .alert("Restart this strap?",
               isPresented: Binding(get: { rebootTarget != nil },
                                    set: { if !$0 { rebootTarget = nil } }),
               presenting: rebootTarget) { _ in
            Button("Cancel", role: .cancel) { rebootTarget = nil }
            Button("Restart") { model.rebootStrap(); rebootTarget = nil }
        } message: { device in
            Text("Restart \(device.displayName)? It disconnects for about 30 seconds while it reboots, then reconnects on its own. Your recorded data is kept.")
        }
        // WHOOP 4.0 reboot probe (#235): only reachable with Test Centre → Connection on and a 4.0 connected.
        // Tries each candidate frame one at a time so the strap log shows which one actually reboots.
        .confirmationDialog("WHOOP 4.0 reboot probe",
                            isPresented: Binding(get: { probeTarget != nil },
                                                 set: { if !$0 { probeTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: probeTarget) { _ in
            ForEach(RebootProbeVariant.allCases, id: \.self) { variant in
                Button(variant.menuLabel) { model.rebootProbe(variant); probeTarget = nil }
            }
            Button("Cancel", role: .cancel) { probeTarget = nil }
        } message: { _ in
            Text("The WHOOP 4.0 reboot frame isn't confirmed — a normal Restart is ignored (#235). Send each candidate and watch BOTH the strap log and the strap itself. “no disconnect within 12s” means the strap ignored the frame. A “link dropped” line means the frame reached the strap — but a dropped link alone isn't a reboot: a real reboot also switches the strap's sensor light off for a few seconds, so if the light stayed on it was just a dropped connection, not a reboot. Non-destructive — your data is kept. Please share the log so we can pin the real frame.")
        }
        // #592 extended-battery opcode probe: read-only, dumps the strap's full raw reply so a capture
        // settles the disputed GET_EXTENDED_BATTERY_INFO number (98 vs an APK decompile's 87).
        .confirmationDialog("Battery-info probe (#592 RE)",
                            isPresented: Binding(get: { batteryProbeTarget != nil },
                                                 set: { if !$0 { batteryProbeTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: batteryProbeTarget) { _ in
            Button("Send probe (read-only)") { model.probeExtendedBatteryInfo(); batteryProbeTarget = nil }
            Button("Cancel", role: .cancel) { batteryProbeTarget = nil }
        } message: { _ in
            Text("Two independent protocol tables disagree on the extended-battery opcode (98 vs 87). This sends the curated read-only 98 and shows the strap's full raw reply. A battery-style payload confirms 98 on your firmware; a short stub means it stays ambiguous. Nothing is written to the strap.")
        }
        // #592 probe result: the strap's reply (or a "waiting…" state), readable + copyable in place.
        .sheet(isPresented: Binding(get: { live.extendedBatteryProbe != nil },
                                    set: { if !$0 { model.clearExtendedBatteryProbe() } })) {
            ExtendedBatteryProbeResultView(
                text: live.extendedBatteryProbe ?? "",
                onClose: { model.clearExtendedBatteryProbe() })
        }
        // #690 body-location probe (confirm + result), isolated into a ViewModifier so its two heavy
        // dialog modifiers type-check in their OWN scope — the DevicesView dialog chain is already near the
        // iOS Swift type-checker's budget, and inlining a 6th/7th modifier here tips it over ("unable to
        // type-check in reasonable time"). macOS tolerates the inline form; iOS's type-inference is stricter.
        .modifier(BodyLocationProbeSheets(target: $bodyLocationProbeTarget))
        // #761 feature-flag enumeration probe (confirm + result) — same ViewModifier isolation.
        .modifier(FeatureFlagProbeSheets(target: $featureFlagProbeTarget))
        // MG ECG probe (actions + the separate wrist confirm + result), isolated into its own
        // ViewModifier for the same iOS type-checker reason as the #690 block above.
        .modifier(EcgProbeSheets(target: $ecgProbeTarget, wristTarget: $ecgWristTarget))
        // #103 device-config READ probe (confirm + result) — same ViewModifier isolation.
        .modifier(DeviceConfigProbeSheets(target: $deviceConfigProbeTarget))
        // Second, strongly-worded delete-data confirm (reached from the Remove card's secondary control)
        .alert("Delete all of this device's data?",
               isPresented: Binding(get: { deleteDataTarget != nil },
                                    set: { if !$0 { deleteDataTarget = nil } }),
               presenting: deleteDataTarget) { device in
            Button("Cancel", role: .cancel) { deleteDataTarget = nil }
            Button("Delete data", role: .destructive) {
                // Route the heavy 16+-table delete through the WhoopStore actor (off the main thread) so a
                // large device dataset can't freeze the UI. Resolve the store handle inside the Task, then
                // await the delete; the registry reloads the (now-emptied) list on completion.
                let deviceId = device.id
                Task {
                    guard let store = await model.repo.storeHandle() else { return }
                    await registry.deleteDeviceData(deviceId, store: store)
                }
                deleteDataTarget = nil
            }
        } message: { device in
            Text("This permanently deletes all data recorded from \(device.displayName). This can't be undone.")
        }
        // Hard-delete confirm (reached from a REMOVED card's ⋮ menu): purge the registry entry itself,
        // not just its data — the only way to get a duplicate/stale strap out of the list for good (#1193).
        // Isolated into its own ViewModifier for the same iOS type-checker-budget reason as the probe
        // sheets above (the dialog chain is already near the limit; a 6th/7th inline modifier tips it over).
        .modifier(ForgetDeviceSheet(registry: registry, target: $forgetTarget))
        // After removing the active device, offer to pick a new active one (if any remain).
        .confirmationDialog("Pick a new active strap",
                            isPresented: $pickNewActive,
                            titleVisibility: .visible) {
            // I-1: import sources (Oura cloud import, file imports) are excluded — they're data
            // partitions, not live devices, and must never be offered as an active-strap candidate.
            ForEach(activatableDevices) { device in
                Button(device.displayName) { registry.setActive(device.id) }
            }
            Button("Leave none active", role: .cancel) { }
        } message: {
            Text("You removed your active strap. Choose which paired band provides your live data, or leave none active and pair one later.")
        }
    }

    // MARK: Pieces

    private var addButton: some View {
        NoopButton("Add a device", systemImage: "plus", kind: .primary, fullWidth: true) {
            showAddWizard = true
        }
        .accessibilityLabel("Add a device")
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            sectionHead("REMOVED", trailing: String(localized: "Data kept"))
            ForEach(removedDevices) { device in
                DeviceCard(
                    device: device,
                    isActive: false,
                    isLiveConnected: false,
                    dimmed: true,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: nil,
                    onReAdd: { registry.setActive(device.id) },
                    onDeleteData: { deleteDataTarget = device },
                    onForget: { forgetTarget = device })
            }
        }
    }

    private var whoopFirstFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps are an early, in-development addition: they stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// UPPERCASE overline section header with tracking + a muted trailing note, matching the liquid Today's
    /// `sectionHead`. Keeps every page's section chrome identical.
    /// #1300: a compact segmented switcher over the paired straps. The active one is highlighted; tapping
    /// another opens the SAME "Make active?" confirmation the per-card action uses (no accidental switch,
    /// history preserved). Switching-not-combining: scores stay single-owner-per-day, this just picks the
    /// owner. Collapses automatically when only one strap remains (the caller gates on count > 1).
    private var strapSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(activeDevices, id: \.id) { device in
                let isActive = device.status == .active
                Button { if !isActive { switchTarget = device } } label: {
                    Text(device.displayName)
                        .font(StrandFont.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isActive ? StrandPalette.accent.opacity(0.18) : Color.clear,
                                    in: Capsule(style: .continuous))
                        .overlay(Capsule(style: .continuous).strokeBorder(
                            isActive ? StrandPalette.accent.opacity(0.45) : StrandPalette.hairline, lineWidth: 1))
                        .foregroundStyle(isActive ? StrandPalette.accent : StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isActive)
            }
        }
        .padding(.horizontal, 2)
    }

    private func sectionHead(_ title: LocalizedStringKey, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(trailing).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Logic

    private var currentActiveName: String {
        registry.devices.first(where: { $0.status == .active })?.displayName ?? String(localized: "Your current strap")
    }

    /// Archive the device, then — if it was the active one and other non-archived devices remain —
    /// prompt for a new active device. The active row is demoted to `.paired` by the registry's reload,
    /// so the dialog's choices come from the still-paired devices.
    private func confirmRemove(_ device: PairedDevice) {
        let wasActive = device.status == .active
        // #78: actually RELEASE the BLE link, not just archive the registry row — otherwise NOOP keeps
        // re-grabbing the strap (reconnect timer + targeted-connect pin + iOS state restoration), holding
        // it connected so it can never enter pairing mode to be re-paired.
        model.ble.forgetDevice(device.peripheralId)
        registry.archive(device.id)
        removeTarget = nil
        if wasActive {
            // Other ACTIVATABLE devices left → ask which becomes active; otherwise (none left, or only
            // import sources remain) no active device remains and there's nothing to offer (I-1).
            if !activatableDevices.isEmpty {
                pickNewActive = true
            }
        }
    }
}

// MARK: - Strap-history sync card

/// The sync status formerly shown as a compact control in the Today header. Devices is the natural home
/// for this device-level state, and the full card gives the status enough room to read without crowding
/// Today's primary actions. This remains display-only and resolves through the existing shared state.
private struct DeviceSyncStatusCard: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        switch SyncChipState.resolve(live: live) {
        case .syncing(let chunks):
            statusCard(
                systemImage: "arrow.triangle.2.circlepath",
                detail: chunks > 0
                    ? String(localized: "Syncing… \(chunks) chunks")
                    : String(localized: "Syncing…"),
                tint: StrandPalette.accent,
                accessibility: String(localized: "Syncing strap history, \(chunks) chunks")
            )
        case .synced(let agoText):
            statusCard(
                systemImage: "checkmark.circle.fill",
                detail: String(localized: "Synced \(agoText) ago"),
                tint: StrandPalette.statusPositive,
                accessibility: String(localized: "Strap history synced \(agoText) ago")
            )
        case .experimentalLive:
            statusCard(
                systemImage: "checkmark.circle.fill",
                detail: String(localized: "Connected; strap history sync is experimental on this strap"),
                tint: StrandPalette.textSecondary,
                accessibility: String(localized: "Connected; strap history sync is experimental on this strap")
            )
        case .hidden:
            EmptyView()
        }
    }

    private func statusCard(
        systemImage: String,
        detail: String,
        tint: Color,
        accessibility: String
    ) -> some View {
        NoopCard(tint: tint) {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Strap history")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(detail)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibility))
    }
}

// MARK: - Device card pill state (pure, testable)

/// The device card's state-pill label/tone/pulsing, as a priority-ordered pure decision (#221): archived
/// beats everything; on the active card, reconnecting > bond-refused > live > plain active; a non-active
/// card is "Paired". Mirrors the Kotlin `devicePillState` in DevicesScreen.kt exactly (see
/// `DevicePillStateTests` / the Kotlin `DevicePillStateTest`), so a future edit to either side can't
/// silently reorder "Connected · not paired" vs "Active · Live" without a test catching it.
struct DevicePillState: Equatable {
    let label: String
    let tone: StrandTone
    var pulsing: Bool = false
    var showsDot: Bool = true

    static func resolve(isArchived: Bool, isActive: Bool, isReconnecting: Bool,
                         bondRefused: Bool, isLiveConnected: Bool) -> DevicePillState {
        if isArchived { return DevicePillState(label: "Removed", tone: .neutral, showsDot: false) }
        guard isActive else { return DevicePillState(label: "Paired", tone: .neutral) }
        if isReconnecting { return DevicePillState(label: "Reconnecting…", tone: .warning, pulsing: true) }
        if bondRefused { return DevicePillState(label: "Connected · not paired", tone: .warning) }
        if isLiveConnected { return DevicePillState(label: "Active · Live", tone: .positive, pulsing: true) }
        return DevicePillState(label: "Active", tone: .positive)
    }
}

// MARK: - Device card

/// One paired device as a card: name, brand/model, capabilities line, a state pill, last-seen, and a
/// per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries an "Active" pill.
private struct DeviceCard: View {
    let device: PairedDevice
    let isActive: Bool
    let isLiveConnected: Bool
    /// #221: the active+connected strap is BLE-linked but its encrypted bond was refused (#78 state) —
    /// no HR/biometric data flows despite the link being up. Drives the "Connected · not paired" pill
    /// (which takes priority over "Active · Live") and the honest subtitle/footnote. False for every
    /// non-WHOOP source and for a normal connect.
    var bondRefused: Bool = false
    /// #221: the full #78 pairing-refusal guidance (bonded-elsewhere / pairing-mode / Forget This Device
    /// steps), shown on the card when `bondRefused` so the fix is self-service. nil otherwise.
    var pairingHint: String? = nil
    /// The active strap's link dropped for a user-initiated reboot and NOOP is auto-reconnecting (#166).
    /// Drives the transient "Reconnecting…" pill; false for every non-reboot state.
    var isReconnecting: Bool = false
    /// The active+connected device's live battery percent (0–100), surfaced on the card the same way
    /// for WHOOP, a generic strap, or an FTMS machine. nil when not the active/connected device or
    /// the source hasn't reported a battery (e.g. a strap/machine without the 0x180F service).
    var liveBatteryPct: Int? = nil
    /// #592: strap pack voltage (mV) for the active+connected strap; nil otherwise. Shown beside the percent.
    var liveBatteryMv: Int? = nil
    /// The active+connected strap's firmware version (from the connect handshake). nil when not the
    /// active/connected device, or for a source that reports no firmware (e.g. a non-WHOOP strap).
    var liveFirmware: String? = nil
    /// The active+connected strap's observed banked-history record layout (`hist_version`).
    var liveHistoryLayout: Int? = nil
    /// #987: the active+connected strap's clock-state line ("Clock latched: yes · last frame 12s ago"),
    /// nil for every other card. Built by the parent off the same pure ConnectionReadout parsers the
    /// Test Centre Connection panel binds, so the two readouts can never disagree.
    var liveClockLine: String? = nil
    /// #987: the plain-words warning when the strap RTC reads ~1970/71 (never set, so it banks no
    /// history) - the single most common "no history" root cause, surfaced where the user looks first.
    var liveClockWarning: String? = nil
    var dimmed: Bool = false
    var onMakeActive: () -> Void
    var onRename: () -> Void
    var onRemove: (() -> Void)?
    /// Restart the strap (WHOOP-only, connected-only; confirmation-gated by the parent). nil for a
    /// non-WHOOP source or a device that isn't the live-connected one. (#166)
    var onReboot: (() -> Void)? = nil
    /// WHOOP 4.0 reboot probe (Test Centre → Connection, 4.0 only). Non-nil only when the parent has
    /// decided the probe applies (live-connected WHOOP 4.0 + Connection test mode on); nil otherwise. (#235)
    var onRebootProbe: (() -> Void)? = nil
    /// #592 extended-battery opcode probe (Test Centre → Connection, both WHOOP families). Read-only.
    var onExtendedBatteryProbe: (() -> Void)? = nil
    var onBodyLocationProbe: (() -> Void)? = nil
    /// #761 feature-flag ENUMERATION probe (Test Centre → Connection, both WHOOP families). Read-only:
    /// it reads the flag NAMES the strap's firmware knows and writes nothing.
    var onFeatureFlagProbe: (() -> Void)? = nil
    var onAbortSync: (() -> Void)? = nil
    /// WHOOP MG ECG (Labrador) probe. Non-nil only for an MG with the Experimental ECG opt-in on.
    var onEcgProbe: (() -> Void)? = nil
    /// #103 device-config READ probe (Test Centre → Connection, both WHOOP families). Read-only: it asks
    /// the strap for a config key's VALUE and writes none.
    var onDeviceConfigProbe: (() -> Void)? = nil
    /// Removed-section affordances (re-add as active / delete its data / forget it entirely).
    var onReAdd: (() -> Void)? = nil
    var onDeleteData: (() -> Void)? = nil
    /// Hard-delete: purge the registry entry itself (and its data), so a duplicate/stale strap can be
    /// removed from the list for good rather than lingering in "Removed" forever (#1193). Archived-only.
    var onForget: (() -> Void)? = nil

    /// The card's visible content. The required `body` wraps this in the whole-card liquid press button +
    /// the ⋮ menu overlay.
    private var cardContent: some View {
        StrandCard(padding: 18, tint: isActive ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .top, spacing: NoopMetrics.space3) {
                    Image(systemName: icon)
                        .font(StrandFont.title2)
                        .foregroundStyle(isActive ? StrandPalette.accent : StrandPalette.textSecondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.displayName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(profile.displayModel)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    // Locally-adopted Oura is Beta: a non-dot Beta chip sits beside the usual state pill.
                    if device.sourceKind == .oura {
                        StatePill("Beta", tone: .warning, showsDot: false)
                    }
                    statePill
                }

                // Honest local-takeover state row for an adopted Oura ring that is paired but not the
                // active+connected source right now. States the single-owner reality plainly (if the ring
                // was reset again or re-claimed in the Oura app, NOOP no longer owns it) without faking a
                // live reading. Suppressed for the active+connected ring and for removed rings.
                if device.sourceKind == .oura && !isLiveConnected && device.status == .paired {
                    ouraLocalStateNote
                }

                // What this device CAPTURES — honest, per-model (not the generic stored set, which would
                // mislabel e.g. a "Blood oxygen" chip when no SpO₂ % ever comes off the strap).
                capabilityRow(symbol: "waveform.path.ecg", text: profile.captures,
                              tint: StrandPalette.textSecondary)
                // What NOOP USES it for — the scores/screens this device drives.
                capabilityRow(symbol: "bolt.fill", text: profile.powers,
                              tint: StrandPalette.textSecondary)
                // Honest footnote: the "*" estimates + the SpO₂/steps caveats.
                if !profile.footnote.isEmpty {
                    Text(profile.footnote)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // #221: the full #78 pairing-refusal guidance, self-service right on the card instead of
                // buried in the strap log — only when the bond was genuinely refused.
                if bondRefused, let hint = pairingHint {
                    Text(hint)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(hint)
                }

                // Live battery for the active+connected device, shown as a liquid tube that fills to the
                // charge — same surface for WHOOP / strap / FTMS. The tube reads the charge band's colour.
                if let pct = liveBatteryPct {
                    batteryTube(pct)
                }

                // #987: strap clock state for the active+connected strap - "clock latched" + frame
                // freshness, with the plain amber 1970/71 warning when the RTC was never set (the strap
                // banks no history in that state, which otherwise looks like a NOOP sync bug).
                if let clockLine = liveClockLine {
                    Text(clockLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityLabel(clockLine)
                }
                if let warning = liveClockWarning {
                    Text(warning)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(warning)
                }

                HStack(spacing: 6) {
                    Text(lastSeenLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    // Firmware version for the active+connected strap, read on connect.
                    if let fw = liveFirmware {
                        Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Text("FW \(fw)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityLabel("Firmware version \(fw)")
                    }
                    // #592: strap pack voltage beside the percent, when the battery event has reported it.
                    if let mv = liveBatteryMv {
                        Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Text("\(Double(mv) / 1000.0, specifier: "%.2f") V")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityLabel("Battery voltage \(Double(mv) / 1000.0, specifier: "%.2f") volts")
                    }
                    if let layout = liveHistoryLayout {
                        Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Text("v\(layout) history")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .accessibilityLabel("Historical record layout v\(layout)")
                    }
                    // The whole-card tap hint sits on the left; the ⋮ menu is a bottom-trailing overlay above
                    // the press button (so its own taps win). No hint on the active card (no make-active),
                    // nor on a removed card whose re-add is menu-only.
                    if let hint = primaryActionHint {
                        Text("·").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        Text(hint)
                            .font(StrandFont.overlineScaled(10)).tracking(1.0)
                            .foregroundStyle(StrandPalette.accent)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 44)   // leave room for the ⋮ menu overlay at the bottom-trailing
                }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    /// The whole-card liquid press wrapper: tapping the card performs its PRIMARY action (make active for a
    /// paired band, re-add for a removed one), with the settle-in `LiquidPressStyle`. The ⋮ menu is layered
    /// on top as an overlay so it captures its own taps; cards with no primary action (the active one, or a
    /// removed one whose re-add is menu-only) fall back to a plain container so nothing taps by accident.
    var body: some View {
        Group {
            if let action = primaryAction {
                Button(action: action) { cardContent }
                    .buttonStyle(LiquidPressStyle())
            } else {
                cardContent
            }
        }
        .overlay(alignment: .bottomTrailing) {
            actionsMenu
                .padding(18)
        }
    }

    /// The card's primary tap action, or nil when there isn't one. A paired-but-not-active band → make it
    /// active; a removed band → re-add it as active. The active band and any card without those callbacks
    /// have no whole-card tap (their controls live entirely in the ⋮ menu). I-1: an import source (Oura
    /// cloud import, file imports) never offers activation — it's a data partition, not a live device;
    /// making it "active" would demote whatever live device drives BLE routing + day-owner priority 0.
    private var primaryAction: (() -> Void)? {
        if device.isImportSource { return nil }
        if device.status == .archived { return onReAdd }
        if !isActive { return onMakeActive }
        return nil
    }

    /// Short accent hint mirroring the primary tap, shown in the footer row. nil when the card has no
    /// whole-card action (active band / menu-only removed band / I-1 import source).
    private var primaryActionHint: String? {
        if device.isImportSource { return nil }
        if device.status == .archived { return onReAdd == nil ? nil : String(localized: "Make active") }
        if !isActive { return String(localized: "Make active") }
        return nil
    }

    /// The live battery as a liquid tube (fills to the charge, coloured by band) with a trailing percent.
    /// Static-posed so it costs nothing per frame — one of many small liquid elements on the screen.
    private func batteryTube(_ pct: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: batterySymbol(pct))
                .font(StrandFont.caption)
                .foregroundStyle(batteryTint(pct))
                .frame(width: 18)
                .accessibilityHidden(true)
            LiquidTube(frac: Double(pct) / 100, tint: batteryTint(pct), height: 8, animated: false)
            Text("\(pct)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(pct) percent")
    }

    /// The charge-band colour for the battery tube/icon (mirrors the menu-bar battery buckets).
    private func batteryTint(_ pct: Int) -> Color {
        pct < 15 ? StrandPalette.statusCritical : pct < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }

    /// The pure `DevicePillState.resolve` priority (#221): reboot's "Reconnecting…" beats a bond refusal's
    /// "Connected · not paired", which beats "Active · Live" — pinned by `DevicePillStateTests` instead of
    /// only verified visually.
    private var pillState: DevicePillState {
        DevicePillState.resolve(isArchived: device.status == .archived, isActive: isActive,
                                 isReconnecting: isReconnecting, bondRefused: bondRefused,
                                 isLiveConnected: isLiveConnected)
    }

    private var statePill: some View {
        let state = pillState
        return StatePill(LocalizedStringKey(state.label), tone: state.tone,
                          showsDot: state.showsDot, pulsing: state.pulsing)
    }

    private var actionsMenu: some View {
        Menu {
            if device.status == .archived {
                // I-1: a removed import source (e.g. Oura cloud import, archived on Disconnect) never
                // offers "Make active" reactivation — it's a data partition, not a live device.
                if let onReAdd, !device.isImportSource {
                    Button { onReAdd() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onDeleteData {
                    Divider()
                    Button(role: .destructive) { onDeleteData() } label: {
                        Label("Delete this device's data…", systemImage: "trash")
                    }
                }
                // Purge the registry entry itself — the only way to get a duplicate/stale strap out of
                // the "Removed" list for good (#1193). Below "Delete data" as the stronger, final action.
                if let onForget {
                    Button(role: .destructive) { onForget() } label: {
                        Label("Forget device…", systemImage: "trash.slash")
                    }
                }
            } else {
                if !isActive && !device.isImportSource {
                    Button { onMakeActive() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                // Restart the strap — only for the live-connected WHOOP (the reboot travels over the active
                // BLE link). Confirmation-gated by the parent. (#166)
                if isLiveConnected, SourceCoordinator.isWhoop(device), let onReboot {
                    Button { onReboot() } label: { Label("Restart strap…", systemImage: "arrow.clockwise") }
                }
                // Stop a sync that is part-way through. Present only while this strap is actually
                // offloading; the parent owns that condition.
                if let onAbortSync {
                    Button { onAbortSync() } label: { Label("Stop sync", systemImage: "stop.circle") }
                }
                // 4.0 reboot probe (RE): only present when the parent passed a closure (Test Centre →
                // Connection on + a live WHOOP 4.0). Finds the real reboot frame the 4.0 accepts (#235).
                if let onRebootProbe {
                    Button { onRebootProbe() } label: { Label("Reboot probe (4.0 RE)…", systemImage: "ladybug") }
                }
                // #592 extended-battery opcode probe (RE): read-only, both families. Test Centre → Connection.
                if let onExtendedBatteryProbe {
                    Button { onExtendedBatteryProbe() } label: { Label("Battery-info probe (#592 RE)…", systemImage: "ladybug") }
                }
                // #690 body-location opcode probe (RE): read-only, both families. Test Centre → Connection.
                if let onBodyLocationProbe {
                    Button { onBodyLocationProbe() } label: { Label("Body-location probe (#690 RE)…", systemImage: "ladybug") }
                }
                // #761 feature-flag ENUMERATION probe (RE): read-only key-name listing, both families.
                // Test Centre → Connection.
                if let onFeatureFlagProbe {
                    Button { onFeatureFlagProbe() } label: { Label("Feature-flag probe (#761 RE)…", systemImage: "ladybug") }
                }
                // WHOOP MG ECG (Labrador) probe: WRITES ECG control commands, so unlike the read-only
                // probes above the parent only passes a closure when the Experimental ECG opt-in is on
                // AND the strap has identified itself as an MG.
                if let onEcgProbe {
                    Button { onEcgProbe() } label: { Label("ECG capture (MG, experimental)…", systemImage: "waveform.path.ecg") }
                }
                // #103 device-config READ probe (RE): read-only VALUE reads, both families.
                // Test Centre → Connection.
                if let onDeviceConfigProbe {
                    Button { onDeviceConfigProbe() } label: { Label("Device-config read probe (#103 RE)…", systemImage: "ladybug") }
                }
                if let onRemove {
                    Divider()
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Device actions for \(device.displayName)")
    }

    /// SF Symbol for the device: WHOOP keeps the band glyph; an FTMS machine reads as gym equipment;
    /// an Apple Watch reads as a watch; generic straps read as a heart-rate strap.
    private var icon: String {
        if device.sourceKind == .ftms { return "figure.run.treadmill" }
        if device.sourceKind == .huami { return "waveform.path.ecg.rectangle" }
        if device.sourceKind == .liveAppleWatch { return "applewatch" }
        if device.sourceKind == .oura { return "circle.circle" }
        return SourceCoordinator.isWhoop(device) ? "applewatch.side.right" : "heart.circle"
    }

    /// The honest, per-model capability + function summary for this device's card.
    private var profile: DeviceCapabilityProfile { .make(for: device) }

    /// One icon-prefixed info row (captures / powers), matching the card's caption style.
    private func capabilityRow(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastSeenLine: String {
        if device.status == .archived { return String(localized: "Removed · data kept") }
        // No "tap ⋯" pointer here (#221 review) — the full how-to-fix guidance is already inline on the
        // card just below, so pointing at the menu would send the user looking for help that's already
        // on screen.
        if bondRefused { return String(localized: "Connected, but not paired") }
        if isLiveConnected { return String(localized: "Connected now") }
        return String(localized: "Last seen \(relativeAgo(TimeInterval(device.lastSeenAt)))")
    }

    /// Honest paired-but-not-connected note for a locally-adopted Oura ring. Amber heads-up, no fabricated
    /// reading: re-states the single-owner reality so the user understands why a re-reset / Oura re-claim
    /// would break NOOP's ownership.
    private var ouraLocalStateNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("Paired locally. NOOP owns this ring while it holds the key. If you reset it again or set it up in the Oura app, NOOP no longer owns it and you would re-add it to take it over.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A battery SF Symbol matching the charge band (mirrors the menu-bar battery glyph buckets).
    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
}

// MARK: - Capability profile

/// Honest, per-model summary of what a device captures and what NOOP uses it for — shown on its card.
///
/// Derived from brand/model/sourceKind, NOT from the stored capability `Set`. The stored set is generic
/// across WHOOP models (it would render an identical "Heart rate · HRV · Blood oxygen · Skin temp · …"
/// line for a 4.0 and a 5/MG alike) and it mislabels: no SpO₂ **percentage** ever comes off any WHOOP
/// strap (raw red/IR only — a real % exists only from a WHOOP CSV / Apple Health import), skin temp is a
/// nightly ±°C sleep deviation rather than a live reading, steps are 5/MG-only and a raw motion count,
/// and Charge/Effort/Rest are NOOP-derived scores. Verdicts are source-verified against the decode +
/// scoring paths (the device-capability audit). `*` in a label = an on-device estimate, not a raw sensor.
struct DeviceCapabilityProfile {
    let displayModel: String   // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    let captures: String       // "·"-joined honest capture labels for THIS model
    let powers: String         // the NOOP scores / screens this device drives
    let footnote: String       // one short honest caveat line ("*" estimates + the SpO₂/steps notes)

    static func make(for d: PairedDevice) -> DeviceCapabilityProfile {
        // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
        // live-workout path. Honest — we surface the machine's metrics + HR live; the session is
        // Effort-scored only when the machine actually reports heart rate.
        if d.sourceKind == .ftms {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "Gym equipment (FTMS)"),
                captures: String(localized: "Speed · Cadence · Power · Distance · Energy · Heart rate (if the machine sends it)"),
                powers: String(localized: "Records a live machine workout, Effort-scored from HR when the machine reports it"),
                footnote: String(localized: "Live machine data over Bluetooth FTMS. No sleep, recovery, skin temp or SpO₂. Effort needs the machine's heart rate; without it the session logs the machine metrics only."))
        }
        // EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band): best-effort live HR only, honest about it.
        if d.sourceKind == .huami {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "\(d.brand) (experimental)"),
                captures: String(localized: "Heart rate (live, best-effort)"),
                powers: String(localized: "Powers the live console + Effort. No Charge, Rest or Sleep"),
                footnote: String(localized: "Experimental: live heart rate where the band exposes it. Some bands need a pairing we can't do yet. NOOP will say so honestly and never show a made-up number. No sleep, recovery, skin temp, SpO₂ or steps."))
        }
        // EXPERIMENTAL locally-adopted Oura ring (gen 3/4/5). The gen is carried on `model` ("Oura Ring
        // 3/4/5") and recovered with OuraRingGen.from(model:). NOOP reads the ring's OWN raw signals + open
        // HRV/sleep-phase tags and computes its own Charge/Effort/Rest; it NEVER reads Oura's encrypted
        // Readiness/Sleep scores, and claims NO absolute SpO₂ %. Estimates carry "*"; a signal it can't read
        // stays "-". Per-gen copy and the canonical Beta caveat (spec
        // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md s3/s4).
        if d.sourceKind == .oura {
            let gen = OuraRingGen.from(model: d.model)
            // gen3/4 are verified-shape; gen5 ("newer") carries the least-proven caveat.
            let newer = (gen == .gen5)
            let captures = newer
                ? String(localized: "Heart rate* · HRV* · Sleep* · Resting HR* · Skin temp* · Battery*")
                : String(localized: "Heart rate · HRV* · Sleep · Resting HR · Skin temp* · Battery")
            let powers = newer
                ? String(localized: "Powers Effort now; Charge and Rest once enough nights and decode are confirmed")
                : String(localized: "Powers Charge, Effort, Rest and Sleep")
            return DeviceCapabilityProfile(
                displayModel: String(localized: "\(gen.displayName) (Beta)"),
                captures: captures,
                powers: powers,
                footnote: String(localized: "Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, and HRV needs you to be still. No Oura Readiness or SpO₂ percentage comes off the ring (import an Oura file for those)."))
        }
        // Apple Watch (live HealthKit source). UNLIKE the WHOOP/strap branches, the watch's stored
        // capability `Set` is already the honest per-model trim (AppleWatchDevice only adds a metric
        // once real data for it arrives), so we read the labels straight off it. An older watch with
        // no SpO₂/wrist-temp samples simply won't list them. Recovery is the calibrating-by-design
        // score (~a week of nights), so the footnote sets that expectation rather than over-promising.
        if d.sourceKind == .liveAppleWatch {
            let labels: [(Metric, String)] = [
                (.hr, String(localized: "Heart rate")), (.hrv, "HRV"), (.sleep, String(localized: "Sleep")),
                (.steps, String(localized: "Steps")), (.spo2, String(localized: "Blood oxygen")), (.skinTemp, String(localized: "Wrist temp")),
            ]
            let captures = labels.filter { d.capabilities.contains($0.0) }.map { $0.1 }.joined(separator: " · ")
            return DeviceCapabilityProfile(
                displayModel: "Apple Watch",
                captures: captures.isEmpty ? String(localized: "Calibrating, no data yet") : captures,
                powers: String(localized: "Powers Rest, Effort, Fitness Age and steps, plus Charge once recovery calibrates"),
                footnote: String(localized: "Computed live from your Apple Watch via Health. Recovery needs about a week of nights to calibrate, and every watch-derived score is labelled with its confidence. Only the metrics your watch actually records are listed above."))
        }
        // Generic heart-rate strap: live HR + R-R only; drives the live console + Effort, nothing nightly.
        // (Same WHOOP test as SourceCoordinator.isWhoop, inlined so this stays nonisolated.)
        let isWhoop = d.id == "my-whoop" || d.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        guard isWhoop else {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "Heart-rate strap"),
                captures: String(localized: "Heart rate · HRV (live)* · Strain"),
                powers: String(localized: "Powers the live console + Effort. No Charge, Rest or Sleep"),
                footnote: String(localized: "Live HR + R-R only · no sleep, recovery, skin temp, SpO₂, steps or battery (those are WHOOP-only)."))
        }
        let whoopPowers = String(localized: "Powers Charge, Effort, Rest, Sleep + Health Monitor")
        let model = d.model.lowercased()
        // WHOOP 5.0 / MG — adds a (raw) step count the 4.0 can't read over BLE.
        if model.contains("5") || model.contains("mg") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 5.0 / MG",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Steps* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation, steps are a raw motion count (#78). No SpO₂ % off the strap; import a WHOOP CSV for a real %."))
        }
        // WHOOP 4.0 — NOOP's primary band; no steps over BLE.
        if model.contains("4") {
            return DeviceCapabilityProfile(
                displayModel: "WHOOP 4.0",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation (firmware-dependent); no steps over BLE on a 4.0. No SpO₂ % off the strap; import a WHOOP CSV for a real %."))
        }
        // Legacy / unknown WHOOP (the seeded device, model just "WHOOP") — show only the common-to-all set.
        return DeviceCapabilityProfile(
            displayModel: "WHOOP",
            captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
            powers: whoopPowers,
            footnote: String(localized: "Exact model unknown. Shows what every WHOOP can do. * on-device estimate · no SpO₂ % off the strap (import a WHOOP CSV for that)."))
    }
}

// MARK: - Signal indicator

/// A four-bar Wi-Fi-style signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is
/// stronger. Buckets are coarse on purpose — a precise dBm readout would be noise to the user.
/// Internal (not private) so the Add-a-device wizard reuses the same indicator.
struct SignalBars: View {
    let rssi: Int

    static func level(for rssi: Int) -> Int {
        switch rssi {
        case (-55)...:    return 4   // very strong
        case (-67)...:    return 3
        case (-80)...:    return 2
        case (-90)...:    return 1
        default:          return 0
        }
    }

    var body: some View {
        let level = Self.level(for: rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < level ? StrandPalette.accent : StrandPalette.hairlineStrong)
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .frame(width: 22, height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - #592 extended-battery probe result

/// The #592 probe reply (raw hex + payload triage + capture diff), or a "waiting…" state while in flight.
/// Read-only; the text is selectable and a Copy button puts it on the clipboard so a capture pastes into
/// the issue without a full strap-log export. Twin of the Android BatteryInfoProbeResultDialog.
private struct ExtendedBatteryProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.extendedBatteryProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Battery-info probe result (#592)")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if waiting {
                Text("Waiting for the strap's reply…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting {
                    Button("Copy") { PlatformPasteboard.copy(text) }
                }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(NoopChromeSurface())
    }
}

/// The hard-delete ("Forget device") confirm for an archived row (#1193). Isolated into its own
/// ViewModifier — like the probe sheets below — so this extra dialog doesn't push the DevicesContent
/// body over the iOS Swift type-checker budget. `registry` is threaded in (it's an `@ObservedObject`
/// param on `DevicesContent`, not an environment object).
private struct ForgetDeviceSheet: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var registry: DeviceRegistry
    @Binding var target: PairedDevice?

    func body(content: Content) -> some View {
        content
            .alert("Forget this device?",
                   isPresented: Binding(get: { target != nil },
                                        set: { if !$0 { target = nil } }),
                   presenting: target) { device in
                Button("Cancel", role: .cancel) { target = nil }
                Button("Forget device", role: .destructive) {
                    // Same off-main routing as delete-data: the sample wipe runs on the WhoopStore actor,
                    // then the registry row is removed and the list reloads. Resolve the store handle
                    // inside the Task so the main thread never blocks on it.
                    let deviceId = device.id
                    Task {
                        guard let store = await model.repo.storeHandle() else { return }
                        await registry.forget(deviceId, store: store)
                    }
                    target = nil
                }
            } message: { _ in
                Text("NOOP removes this device from your list and deletes its recorded data here. You can re-pair the strap to pull its recent history back.")
            }
    }
}

/// #690: the body-location probe's confirm + result dialogs as one ViewModifier, so they're type-checked
/// in isolation instead of extending the DevicesView `.confirmationDialog`/`.sheet` chain (which is already
/// near the iOS Swift type-checker's budget). `model`/`live` auto-inject from the parent's environment.
private struct BodyLocationProbeSheets: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var target: PairedDevice?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Body-location probe (#690 RE)",
                                isPresented: Binding(get: { target != nil },
                                                     set: { if !$0 { target = nil } }),
                                titleVisibility: .visible,
                                presenting: target) { _ in
                Button("Send probe (read-only)") { model.probeBodyLocationAndStatus(); target = nil }
                Button("Cancel", role: .cancel) { target = nil }
            } message: { _ in
                Text("Sends the read-only GET_BODY_LOCATION_AND_STATUS (0x54) and shows the strap's full raw reply, decoding the body-location record (revision / location / confidence / status) on WHOOP 4.0. Nothing is written to the strap, and it never changes wear detection or scoring.")
            }
            .sheet(isPresented: Binding(get: { live.bodyLocationProbe != nil },
                                        set: { if !$0 { model.clearBodyLocationProbe() } })) {
                BodyLocationProbeResultView(
                    text: live.bodyLocationProbe ?? "",
                    onClose: { model.clearBodyLocationProbe() })
            }
    }
}

/// The #690 body-location probe reply (raw hex + decoded record + capture diff), or a "waiting…" state
/// while in flight. Read-only; selectable text + a Copy button. Twin of the Android BodyLocationProbe
/// result dialog and structurally identical to ExtendedBatteryProbeResultView.
private struct BodyLocationProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.bodyLocationProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Body-location probe result (#690)")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if waiting {
                Text("Waiting for the strap's reply…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting {
                    Button("Copy") { PlatformPasteboard.copy(text) }
                }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(NoopChromeSurface())
    }
}

/// #761: the READ-ONLY feature-flag enumeration probe's confirm + result dialogs, isolated into a
/// ViewModifier for the same reason `BodyLocationProbeSheets` is — keeping the DevicesView
/// `.confirmationDialog`/`.sheet` chain inside the iOS Swift type-checker's budget.
private struct FeatureFlagProbeSheets: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var target: PairedDevice?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Feature-flag probe (#761 RE)",
                                isPresented: Binding(get: { target != nil },
                                                     set: { if !$0 { target = nil } }),
                                titleVisibility: .visible,
                                presenting: target) { _ in
                Button("Send probe (read-only)") { model.probeFeatureFlags(); target = nil }
                Button("Cancel", role: .cancel) { target = nil }
            } message: { _ in
                Text("Asks the strap to list the feature-flag NAMES its own firmware knows: START_FF_KEY_EXCHANGE (0x75) then SEND_NEXT_FF (0x76) until the strap says it's done. Read-only — no flag value is written, and the SET commands are never sent from this probe. The list is shown here and written to the strap log.")
            }
            .sheet(isPresented: Binding(get: { live.featureFlagProbe != nil },
                                        set: { if !$0 { model.clearFeatureFlagProbe() } })) {
                FeatureFlagProbeResultView(
                    text: live.featureFlagProbe ?? "",
                    onClose: { model.clearFeatureFlagProbe() })
            }
    }
}

// MARK: - WHOOP MG ECG (Labrador) probe

/// The MG ECG probe's dialogs as one ViewModifier — the action sheet, the SEPARATE wrist confirm, and
/// the result sheet — isolated for the same iOS type-checker reason as `BodyLocationProbeSheets`.
///
/// The wrist selection is deliberately a second, independent confirmation rather than a button inside
/// the start flow: `SELECT_WRIST` writes strap state that survives a disconnect, and the right/left
/// mapping is inferred from the client enum's order rather than confirmed on hardware. A persistent
/// write nobody has verified is exactly the kind of thing that should cost a deliberate extra tap.
private struct EcgProbeSheets: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var target: PairedDevice?
    @Binding var wristTarget: PairedDevice?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("WHOOP MG ECG capture (experimental)",
                                isPresented: Binding(get: { target != nil },
                                                     set: { if !$0 { target = nil } }),
                                titleVisibility: .visible,
                                presenting: target) { device in
                Button("Start ECG capture") { model.ecgStartCapture(); target = nil }
                Button("Stop ECG capture") { model.ecgStopCapture(); target = nil }
                Button("Set which wrist you wear it on…") { target = nil; wristTarget = device }
                Button("Cancel", role: .cancel) { target = nil }
            } message: { _ in
                Text("NOOP is not a medical device and this is not an ECG test. It asks your MG to start its ECG subsystem and logs whatever comes back — unvalidated instrumentation for protocol research, never a measurement or a diagnosis, including any heart-rhythm classification the strap happens to send. Don't use it to make a health decision; see a doctor if you have symptoms.\n\nHold the two indents on the clasp with the fingers of your other hand for the whole capture. The MG measures across your wrist AND that clasp, so until you hold it the circuit is open, the strap has nothing to record, and you would see zero packets whatever the firmware did.\n\nNobody has confirmed a strap honours these commands, so the likely outcome is that nothing happens. Everything here is reversible: “Stop” turns the streams back off. Results land in the strap log.")
            }
            // Wrist selection: its own step, with its own confirmation and its own warning.
            //
            // A SHEET rather than a second confirmationDialog for two reasons: presenting one dialog from
            // another in the same runloop tick races (the first is still dismissing, and the second can be
            // dropped), and a dialog's message truncates on iOS — while the persistence warning here is
            // the whole point of the step and has to be readable in full.
            .sheet(isPresented: Binding(get: { wristTarget != nil },
                                        set: { if !$0 { wristTarget = nil } })) {
                EcgWristSheet(onPick: { wrist in model.ecgSelectWrist(wrist); wristTarget = nil },
                              onCancel: { wristTarget = nil })
            }
            .sheet(isPresented: Binding(get: { live.ecgProbe != nil },
                                        set: { if !$0 { model.clearEcgProbe() } })) {
                EcgProbeResultView(text: live.ecgProbe ?? "",
                                   onClose: { model.clearEcgProbe() })
            }
    }
}

/// The #761 enumeration report (the strap's own flag-name list + the exchange trace), or a "waiting…"
/// state while the walk runs. Selectable text + a Copy button, structurally identical to the #592/#690
/// result views. Twin of the Android feature-flag probe result dialog.
private struct FeatureFlagProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.featureFlagProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Feature-flag probe result (#761)")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if waiting {
                // Reuses the #592/#690 waiting copy — the walk sends one 118 per reply, so at any moment
                // it is waiting on exactly one strap reply, and the catalog keeps a single translation.
                Text("Waiting for the strap's reply…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting {
                    Button("Copy") { PlatformPasteboard.copy(text) }
                }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(NoopChromeSurface())
    }
}

/// The wrist-selection step: the one ECG command that writes strap state outliving the session, so it
/// gets its own screen, its own warning, and its own confirmation rather than a button inside the start
/// flow. The copy names both caveats plainly — that the value persists on the strap, and that the
/// left/right mapping is read off the order in WHOOP's own app rather than verified on hardware.
private struct EcgWristSheet: View {
    let onPick: (Whoop5Ecg.WristSelection) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which wrist do you wear it on?")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("This one is different from the other ECG controls: it is a setting written to the strap, and it stays there after you disconnect until you change it again.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
            Text("It is also not fully confirmed. Which value means “left” and which means “right” is read off the order they appear in WHOOP's own app, not verified on a strap — so it may set the opposite wrist. You can send it again with the other choice at any time, and it changes nothing about your recorded data.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space3) {
                Button("Left wrist") { onPick(.left) }
                Button("Right wrist") { onPick(.right) }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 220)
        .background(NoopChromeSurface())
    }
}

/// The MG ECG probe's report (verdict + per-command outcomes + candidate packet lines), or a "waiting…"
/// state while the listen window is open. Read-only, selectable, copyable — structurally identical to
/// `BodyLocationProbeResultView`, with the non-medical framing pinned above the text so it is read first.
private struct EcgProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.ecgProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ECG capture probe result")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Unvalidated instrumentation, not a medical measurement and not a diagnosis.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
            if waiting {
                Text("Listening for the strap's reply…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting {
                    Button("Copy") { PlatformPasteboard.copy(text) }
                }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(NoopChromeSurface())
    }
}

/// #103: the READ-ONLY device-config read probe's confirm + result dialogs, isolated into a
/// ViewModifier for the same reason `FeatureFlagProbeSheets` is — keeping the DevicesView
/// `.confirmationDialog`/`.sheet` chain inside the iOS Swift type-checker's budget.
private struct DeviceConfigProbeSheets: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var target: PairedDevice?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Device-config read probe (#103 RE)",
                                isPresented: Binding(get: { target != nil },
                                                     set: { if !$0 { target = nil } }),
                                titleVisibility: .visible,
                                presenting: target) { _ in
                Button("Send probe (read-only)") { model.probeDeviceConfigValues(); target = nil }
                Button("Cancel", role: .cancel) { target = nil }
            } message: { _ in
                Text("Asks the strap for config VALUES: GET_DEVICE_CONFIG_VALUE (0x79) and GET_FF_VALUE (0x80), one key per round-trip. Both commands may simply not exist in this firmware — finding that out is the point. Read-only — no value is written, and the SET commands are never sent from this probe. The result is shown here and written to the strap log.")
            }
            .sheet(isPresented: Binding(get: { live.deviceConfigProbe != nil },
                                        set: { if !$0 { model.clearDeviceConfigProbe() } })) {
                DeviceConfigProbeResultView(
                    text: live.deviceConfigProbe ?? "",
                    onClose: { model.clearDeviceConfigProbe() })
            }
    }
}

/// The #103 read report (per-verb verdict, the values read, the exchange transcript), or a "waiting…"
/// state while the plan runs. Selectable text + a Copy button, structurally identical to the #592/#690/
/// #761 result views. Twin of the Android device-config probe result dialog.
private struct DeviceConfigProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.deviceConfigProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Device-config read probe result (#103)")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if waiting {
                // Reuses the #592/#690/#761 waiting copy — the plan sends one read per reply, so at any
                // moment it is waiting on exactly one strap reply, and the catalog keeps one translation.
                Text("Waiting for the strap's reply…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting {
                    Button("Copy") { PlatformPasteboard.copy(text) }
                }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(NoopChromeSurface())
    }
}

// MARK: - Capability catalog (DEBUG render harness)

#if DEBUG
/// DEBUG-only: one DeviceCard per capability-profile kind so the honest per-model display can be
/// screenshotted deterministically (`--demo-screen devicescatalog`). Same file as `DeviceCard` /
/// `DeviceCapabilityProfile` so it can reach them. Stripped from Release.
struct DeviceCardCatalog: View {
    private static let whoopCaps: Set<Metric> = [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad]

    private static func dev(_ id: String, _ brand: String, _ model: String,
                            _ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: model, nickname: nil, peripheralId: nil,
                     sourceKind: .liveBLE, capabilities: caps, status: .paired,
                     addedAt: 0, lastSeenAt: 0)
    }

    private static func watch(_ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch", nickname: nil,
                     peripheralId: nil, sourceKind: .liveAppleWatch, capabilities: caps,
                     status: .paired, addedAt: 0, lastSeenAt: 0)
    }

    /// A locally-adopted Oura ring (sourceKind `.oura`), built with mock data so the honest per-gen Beta
    /// card renders deterministically WITHOUT a ring. `model` carries the gen ("Oura Ring 3/4/5").
    static func oura(_ model: String, status: DeviceStatus = .paired) -> PairedDevice {
        PairedDevice(id: "oura-demo-\(model)", brand: "Oura", model: model, nickname: nil,
                     peripheralId: "00000000-0000-0000-0000-0000000000aa", sourceKind: .oura,
                     capabilities: WhoopLiveCapabilities.metrics(forModel: "4.0"),
                     status: status, addedAt: 0, lastSeenAt: 0)
    }

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "What each band captures (and what NOOP uses it for).",
                       topBackground: liquidScaffoldSky()) {
            VStack(spacing: NoopMetrics.gap) {
                DeviceCard(device: Self.dev("whoop-4d", "WHOOP", "4.0", Self.whoopCaps),
                           isActive: true, isLiveConnected: true,
                           onMakeActive: {}, onRename: {}, onRemove: nil)
                DeviceCard(device: Self.dev("whoop-5d", "WHOOP", "5.0 MG",
                                            Self.whoopCaps.union([.steps])),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // #221: a WHOOP 5/MG that's BLE-connected but whose encrypted bond was refused (#78) — no
                // data flows despite the link being up. Renders the "Connected · not paired" pill + the
                // self-service pairing guidance so this can be verified WITHOUT reproducing the bond
                // refusal on real hardware.
                DeviceCard(device: Self.dev("whoop-5-refused", "WHOOP", "5.0 MG",
                                            Self.whoopCaps.union([.steps])),
                           isActive: true, isLiveConnected: true, bondRefused: true,
                           pairingHint: "NOOP can see your strap but it's refusing to pair - it's likely still bonded to the official WHOOP app, or your phone is holding an old pairing. To fix it: (1) fully close the WHOOP app, (2) on a 5.0/MG, tap the band repeatedly until the LEDs flash blue (pairing mode), (3) if your strap is listed under iPhone Settings → Bluetooth, tap it and choose Forget This Device, then reconnect in NOOP.",
                           onMakeActive: {}, onRename: {}, onRemove: {})
                DeviceCard(device: Self.dev("strap-d", "Polar", "H10", [.hr, .hrv]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Apple Watch, with an older-model trimmed set (no SpO₂ / wrist temp) so the honest
                // capability read renders deterministically alongside the straps.
                DeviceCard(device: Self.watch([.hr, .hrv, .sleep, .steps]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Locally-adopted Oura ring (Beta): per-gen honest capability copy + the Beta chip + the
                // paired-but-not-connected local-state note, all without a ring on-wrist.
                DeviceCard(device: Self.oura("Oura Ring 3"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}

/// DEBUG-only: just the locally-adopted Oura device card, active + connected, so `--demo-screen ouradevice`
/// can screenshot the Beta Oura card (battery + "Active · Live") WITHOUT a ring. Same file as `DeviceCard`
/// so it can reach it. Stripped from Release.
struct OuraDeviceDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "A locally-adopted Oura ring, in beta.",
                       topBackground: liquidScaffoldSky()) {
            VStack(spacing: NoopMetrics.gap) {
                // Active + connected so the card shows "Active · Live" + a live battery readout.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 3"),
                           isActive: true, isLiveConnected: true, liveBatteryPct: 71,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // A second, paired-but-not-connected gen-4 ring so the honest local-state note + per-gen
                // copy render in the same shot.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 4"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}

/// DEBUG-only: just the WHOOP 5/MG bond-refused card, so `--demo-screen bondrefused` can screenshot the
/// "Connected · not paired" pill + the self-service #78 pairing guidance (#221) WITHOUT reproducing the
/// bond refusal on real hardware. Same file as `DeviceCard` so it can reach it. Stripped from Release.
struct BondRefusedDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "A WHOOP 5/MG whose encrypted bond was refused (#78).",
                       topBackground: liquidScaffoldSky()) {
            DeviceCard(device: PairedDevice(id: "whoop-5-refused-solo", brand: "WHOOP", model: "5.0 MG",
                                            nickname: nil, peripheralId: nil, sourceKind: .liveBLE,
                                            capabilities: WhoopLiveCapabilities.metrics(forModel: "5.0 MG"),
                                            status: .active, addedAt: 0, lastSeenAt: 0),
                       isActive: true, isLiveConnected: true, bondRefused: true,
                       pairingHint: "NOOP can see your strap but it's refusing to pair - it's likely still bonded to the official WHOOP app, or your phone is holding an old pairing. To fix it: (1) fully close the WHOOP app, (2) on a 5.0/MG, tap the band repeatedly until the LEDs flash blue (pairing mode), (3) if your strap is listed under iPhone Settings → Bluetooth, tap it and choose Forget This Device, then reconnect in NOOP.",
                       onMakeActive: {}, onRename: {}, onRemove: {})
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
#Preview("Devices") {
    let model = AppModel()
    return DevicesView()
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
