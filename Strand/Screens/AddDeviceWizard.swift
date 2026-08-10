import SwiftUI
import StrandDesign
import WhoopStore
import OuraProtocol

// MARK: - Add a device — guided, branching wizard
//
// Different bands pair COMPLETELY differently, so this wizard asks the device TYPE first, then gives
// type-specific prep guidance and runs the RIGHT scan/connect for that type:
//
//   • WHOOP 4.0 / WHOOP 5.0 (MG)  → BLEManager's present-scan (`scanForWhoops`), targeted at the
//     chosen WHOOP family via `model.presentWhoopScan(model:)`. Lists nearby straps from
//     `ble.discoveredWhoops` (a present-only mode that never auto-connects).
//   • Heart-rate strap (Polar / Wahoo / Coospo / Garmin HRM / Amazfit Helio broadcast) → its OWN
//     isolated `StandardHRSource` scanning the standard 0x180D HR service. Lists from `discovered`.
//
// Registration goes through `model.registerDevice(_:makeActive:)` → DeviceRegistry; the
// SourceCoordinator reacts to the active-device change and connects. The wizard never touches
// BLEManager directly — only the AppModel pass-throughs. WHOOP-FIRST: WHOOP is the primary band; the
// type list shows it first and a footer reiterates it. Renders cleanly with nothing nearby (the type
// picker, every prep step, and the searching/empty pick state all need no hardware).

struct AddDeviceWizard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    let onClose: () -> Void

    // MARK: Flow

    /// What the user is adding. Drives the prep copy AND which scan/register path runs.
    enum DeviceType: Identifiable, Hashable {
        case whoop5mg
        case whoop4
        case hrStrap
        case gymEquipment
        // EXPERIMENTAL tier — best-effort, clean-room, can't be hardware-verified here. Each fails to an
        // honest message and never fabricates data.
        case amazfit       // Amazfit / Zepp incl. Helio (Huami custom or standard HR)
        case miBand        // Xiaomi Mi Band (Huami; no-auth live HR path, honest message if auth needed)
        case garmin        // Garmin watch (standard Broadcast HR path + an enable hint)
        case oura          // Oura ring (factory-reset-and-adopt: NOOP installs its own key, becomes owner)
        var id: Self { self }

        var isWhoop: Bool { self == .whoop4 || self == .whoop5mg }
        var whoopModel: WhoopModel? {
            switch self {
            case .whoop4:   return .whoop4
            case .whoop5mg: return .whoop5mg
            default:        return nil
            }
        }

        /// True for the EXPERIMENTAL tier (shown under a clearly-labelled "Experimental" heading).
        var isExperimental: Bool {
            switch self {
            case .amazfit, .miBand, .garmin, .oura: return true
            default:                                return false
            }
        }

        /// The experimental-tier brand this type registers as, or nil for the non-experimental types
        /// (WHOOP / generic strap / gym). Bridges the wizard's type picker to the `DeviceBrandCatalog`
        /// facts (stored brand string, `sourceKind`, id prefix) so those are no longer hardcoded per branch.
        var experimentalBrand: ExperimentalBrand? {
            switch self {
            case .amazfit: return .amazfit
            case .miBand:  return .miBand
            case .garmin:  return .garmin
            case .oura:    return .oura
            default:       return nil
            }
        }
    }

    enum Step { case type, prep, pick, confirm }

    /// The Oura factory-reset-and-adopt sub-flow's own step machine (section 2 of the onboarding UX spec).
    /// The Oura type does NOT use the generic prep/pick/confirm shape: it owns this machine, entered from the
    /// type list. PARITY: byte-for-byte the same step set + copy as the Android `OuraStep`.
    ///   - gate     What you get / what you lose + the irreversible red consent gate (or the Advanced key field).
    ///   - prep     Factory-reset the ring in the Oura app first (single-owner warning).
    ///   - pick     Live scan + pick a ring; an unreset ring surfaces honestly.
    ///   - confirm  Detected generation + per-gen capability checklist + the SECOND destructive "Take over" gate.
    ///   - adopting Honest key-install progress (no fake percent), driven by the live source's adopt phase.
    ///   - failed   An honest dead-end when adoption fails, with the file-import + Advanced-key fallbacks.
    enum OuraStep { case gate, prep, pick, confirm, adopting, failed }

    @State private var step: Step = .type
    @State private var type: DeviceType?
    /// The Oura sub-flow step (only meaningful while `type == .oura`). Reset to `.gate` on each Oura entry.
    @State private var ouraStep: OuraStep = .gate
    /// The destructive "Take over this ring?" confirm alert (the SECOND irreversible gate, after the consent
    /// tick). Mirrors the Android `ouraConfirmAdopt`. Only the standard adopt path raises it; the Advanced
    /// key path is non-destructive and skips it.
    @State private var ouraConfirmAdopt = false

    // The chosen strap, in whichever shape its path produces.
    /// A WHOOP picked from `discoveredWhoops` (uuid / advertised name / rssi).
    @State private var pickedWhoop: (uuid: String, name: String, rssi: Int)?
    /// A generic HR strap picked from the StandardHRSource scan.
    @State private var pickedStrap: StandardHRSource.DiscoveredStrap?
    /// An FTMS gym machine picked from the FTMSSource scan.
    @State private var pickedMachine: FTMSSource.DiscoveredMachine?
    /// An EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band) picked from the HuamiHRSource scan.
    @State private var pickedHuami: HuamiHRSource.DiscoveredDevice?
    /// An EXPERIMENTAL Oura ring picked from the OuraLiveSource scan, plus its detected generation
    /// (best-effort from the advertised name; the user confirms by picking). The `gen` here defaults to
    /// `.gen3` when the scan couldn't guess one, so the registered command set is always usable.
    @State private var pickedOura: (ring: OuraLiveSource.DiscoveredRing, gen: OuraRingGen)?

    @State private var nameDraft = ""
    /// After registering, ask whether to make the new device active.
    @State private var askMakeActive = false

    /// The mandatory irreversible-consent gate (Oura factory-reset-and-adopt). The user must tick this
    /// before the wizard will scan, because adoption installs NOOP's key and the Oura app stops working
    /// with the ring. Mirrors the spec's red `statusCritical` gate. Reset whenever the type changes.
    @State private var ouraConsented = false
    /// The Advanced "I already have my ring's key" power-user path: when true, the prep step swaps to a
    /// hex-key field and we authenticate with the supplied key WITHOUT a factory reset (the Oura app keeps
    /// working). Off by default; only the small Advanced link on the gate turns it on.
    @State private var ouraAdvancedKeyMode = false
    /// The 32-hex-character ring key typed on the Advanced path. Validated to 16 bytes before scan.
    @State private var ouraKeyDraft = ""

    /// Discovery-only HR source for the strap path. Never persists (no-op closure) and is never asked
    /// to `connect` — we only read its `@Published discovered` / `scanning` while scanning. Built once.
    @StateObject private var hrScanner: StandardHRSource
    /// Discovery-only FTMS source for the gym-equipment path. `feedsLive: false` so it never writes
    /// LiveState; we only read its `discovered` / `scanning` while scanning. Built once.
    @StateObject private var ftmsScanner: FTMSSource
    /// Discovery-only EXPERIMENTAL Huami scanner (Amazfit / Zepp / Mi Band). `feedsLive: false`, never
    /// persists; the wizard only reads its `discovered` / `scanning`. Built once.
    @StateObject private var huamiScanner: HuamiHRSource
    /// Discovery-only EXPERIMENTAL Oura scanner. A real `OuraLiveSource` built in discovery-only mode
    /// (`feedsLive: false`, deviceId "scan-preview", no-op persist, no install key), so the wizard only reads
    /// its `@Published discovered` / `scanning` / `needsPairing` while scanning. The chosen ring is adopted
    /// for real on `finishAdd`, where the registered `PairedDevice` carries the ring generation. Built once.
    @StateObject private var ouraScanner: OuraLiveSource

    /// - Parameter startAt: DEBUG-only deep-link into a specific (type, step) so a seeded simulator build
    ///   can screenshot one wizard step deterministically (e.g. the Oura onboarding gate) without tapping
    ///   through. nil in production: the wizard starts on the type list. Pre-seeds the `@State` so the first
    ///   render is already on that step.
    init(live: LiveState, onClose: @escaping () -> Void,
         startAt: (type: DeviceType, step: Step)? = nil) {
        self.onClose = onClose
        if let startAt {
            _type = State(initialValue: startAt.type)
            _step = State(initialValue: startAt.step)
        }
        // Route each throwaway scanner's diagnostics into the SAME exported strap log the active source
        // path uses (issue #421 parity), so a tester's wizard scan, including the Oura discovery scan and
        // any honest needs-pairing outcome, is captured in a shared debug bundle. The sources already
        // self-prefix their lines ("HR-strap: " / "FTMS: " / "Huami: " / "Oura: "); we add the same
        // "[HH:mm:ss]" stamp AppModel's `straplog` uses so wizard lines read identically. Each source is
        // @MainActor and only calls this from the main actor, so the forward into @MainActor LiveState is
        // safe. Privacy-safe: statuses / service UUIDs / counts only, never a device address.
        let wizardLog: (String) -> Void = { line in
            MainActor.assumeIsolated {
                live.append(log: "[\(AppModel.logTimeFormatter.string(from: Date()))] \(line)")
            }
        }
        _hrScanner = StateObject(wrappedValue: StandardHRSource(
            live: live, deviceId: "scan-preview", persist: { _ in }, log: wizardLog))
        _ftmsScanner = StateObject(wrappedValue: FTMSSource(live: live, log: wizardLog, feedsLive: false))
        _huamiScanner = StateObject(wrappedValue: HuamiHRSource(
            live: live, deviceId: "scan-preview", log: wizardLog, feedsLive: false))
        // Discovery-only Oura source: gen defaults to gen3 for the scan-preview command clamp (the real
        // gen is fixed once the user picks), no install key (we never auth during discovery), and
        // `feedsLive: false` so it never writes LiveState or persists. Same shared strap-log sink (#421).
        _ouraScanner = StateObject(wrappedValue: OuraLiveSource(
            live: live, deviceId: "scan-preview", ringGen: .gen3, authKey: { nil },
            persist: { _ in }, log: wizardLog, feedsLive: false))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    if type == .oura {
                        // The Oura type runs its OWN step machine (gate -> prep -> pick -> confirm ->
                        // adopting/failed), NOT the generic prep/pick/confirm. Parity with the Android flow.
                        ouraFlow
                    } else {
                        switch step {
                        case .type:    typeStep
                        case .prep:    prepStep
                        case .pick:    pickStep
                        case .confirm: confirmStep
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase)
        // Stop whichever scan is live whenever the sheet goes away (belt-and-braces alongside the
        // per-transition stops below) so neither central keeps scanning after dismiss.
        .onDisappear { stopAllScans() }
        // After adding, offer to make the new device active (generic non-Oura paths only).
        .alert("Make this your active device?",
               isPresented: $askMakeActive) {
            Button("Not now", role: .cancel) { finishAdd(makeActive: false) }
            Button("Make active") { finishAdd(makeActive: true) }
        } message: {
            Text("Make \(confirmName) your active device now? It will provide your live data. You can change this any time.")
        }
        // The SECOND irreversible gate (after the consent tick): the destructive "Take over this ring?"
        // confirm. Tapping Take over grants adopt consent + registers the ring active (the live source then
        // runs the one-time key install), and moves the wizard to its honest Adopting step. Cancel returns.
        .alert("Take over this ring?", isPresented: $ouraConfirmAdopt) {
            Button("Cancel", role: .cancel) { }
            Button("Take over", role: .destructive) { commitOuraAdopt() }
        } message: {
            Text("NOOP will install its own key on the ring and become its owner. The Oura app will no longer control this ring. This is intended and it cannot be undone from NOOP.")
        }
        // Drive the Adopting step to success (the live source reached streaming -> close the wizard) or to a
        // REACHABLE honest Failed step (the live source announced needs-pairing). Only acts while Adopting,
        // so a later steady-state needs-pairing on the device card never reopens this.
        .onChange(of: model.ouraAdoptPhase) { phase in
            guard type == .oura, ouraStep == .adopting else { return }
            switch phase {
            case .streaming:        stopAllScans(); onClose()   // adoption complete: the ring is the live source now
            case .failed:           ouraStep = .failed
            case .idle, .installingKey: break
            }
        }
        .onChange(of: model.ouraNeedsPairing) { msg in
            // A needs-pairing message during the Adopting step is an honest failure too (covers the no-ack /
            // ack!=OK paths that surface via needsPairing rather than a phase flip alone).
            guard type == .oura, ouraStep == .adopting, msg != nil else { return }
            ouraStep = .failed
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Back is offered on every step except the very first (the type list), AND, on the Oura adopt
            // flow, except the Adopting progress (no meaningful back while a key install is in flight). This
            // re-enables back/cancel everywhere else so the user is never trapped on the Failed state.
            if showBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let sub = headerSubtitle {
                    Text(sub).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            Button(action: { stopAllScans(); onClose() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    /// Back is shown on every step except the very first (the type list) and, on the Oura adopt flow, the
    /// Adopting progress (no back while a key install is in flight). Parity with the Android `showBack`.
    private var showBack: Bool {
        if type == .oura { return ouraStep != .adopting }
        return step != .type
    }

    private var headerTitle: LocalizedStringKey {
        if type == .oura {
            switch ouraStep {
            case .gate:     return ouraAdvancedKeyMode ? "Advanced: use your own key" : "Oura ring"
            case .prep:     return "Get your ring ready"
            case .pick:     return "Pick the ring"
            case .confirm:  return "Your ring"
            case .adopting: return "Taking over your ring"
            case .failed:   return "Could not take over"
            }
        }
        switch step {
        case .type:    return "Add a device"
        case .prep:    return LocalizedStringKey(type.map(typeTitle) ?? String(localized: "Add a device"))
        case .pick:    return "Pick your device"
        case .confirm: return "Name & confirm"
        }
    }

    private var headerSubtitle: LocalizedStringKey? {
        if type == .oura {
            switch ouraStep {
            case .gate:    return ouraAdvancedKeyMode ? "Power users only." : "Take it over locally. Beta."
            case .prep:    return "Reset it in the Oura app first."
            case .pick:    return "Tap the one that's yours."
            case .confirm, .adopting, .failed: return nil
            }
        }
        switch step {
        case .type:    return "What are you adding?"
        case .prep:    return "Get it ready, then scan."
        case .pick:    return "Tap the one that's yours."
        case .confirm: return nil
        }
    }

    // MARK: Step 1 — type picker

    @ViewBuilder private var typeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            typeRow(.whoop5mg, icon: "applewatch.side.right",
                    title: "WHOOP 5.0 / MG",
                    subtitle: String(localized: "Newer WHOOP band, experimental in NOOP"))
            typeRow(.whoop4, icon: "applewatch.side.right",
                    title: "WHOOP 4.0",
                    subtitle: String(localized: "NOOP's primary, fully-supported band"))
            typeRow(.hrStrap, icon: "heart.circle",
                    title: String(localized: "Heart-rate strap"),
                    subtitle: String(localized: "Polar, Wahoo, Coospo, Garmin HRM, Amazfit Helio broadcast"))
            typeRow(.gymEquipment, icon: "figure.run.treadmill",
                    title: String(localized: "Gym equipment"),
                    subtitle: String(localized: "Treadmill, indoor bike, rower or cross-trainer (Bluetooth FTMS)"))

            // EXPERIMENTAL tier — clearly labelled, opt-in, best-effort. Each is honest about what it can
            // actually read; none fabricates data.
            Text("Experimental").strandOverline().padding(.top, 8)
            experimentalTierNote
            typeRow(.oura, icon: "circle.circle",
                    title: String(localized: "Oura ring"),
                    subtitle: String(localized: "Take over your ring locally. Beta. This replaces the Oura app."))
            typeRow(.amazfit, icon: "waveform.path.ecg.rectangle",
                    title: "Amazfit / Zepp",
                    subtitle: String(localized: "Incl. Helio. Live heart rate where the band exposes it. Help us test."))
            typeRow(.miBand, icon: "waveform.path.ecg",
                    title: "Xiaomi Mi Band",
                    subtitle: String(localized: "Live heart rate on bands that don't need pairing. Help us test."))
            typeRow(.garmin, icon: "applewatch",
                    title: String(localized: "Garmin watch"),
                    subtitle: String(localized: "Uses the watch's Broadcast Heart Rate. We'll show you how."))

            whoopFirstNote
        }
    }

    private func typeRow(_ t: DeviceType, icon: String, title: String, subtitle: String) -> some View {
        Button {
            type = t
            nameDraft = ""
            // The Oura factory-reset-and-adopt gate is destructive, so every fresh entry into the Oura flow
            // re-requires the irreversible-consent tick and clears any stale Advanced-key / adopt state, and
            // enters the Oura sub-flow at its gate rather than the generic prep step.
            if t == .oura {
                ouraConsented = false
                ouraAdvancedKeyMode = false
                ouraKeyDraft = ""
                ouraConfirmAdopt = false
                pickedOura = nil
                ouraStep = .gate
            } else {
                step = .prep
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    // MARK: Step 2 — type-specific prep + guidance

    @ViewBuilder private var prepStep: some View {
        if let type, type != .oura {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: typeIcon(type))
                        .font(.system(size: 30))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(typeTitle(type)).font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }

                if type == .whoop5mg {
                    experimentalNote
                } else if type.isExperimental {
                    experimentalTierNote
                }

                // A6 , the one-phone-at-a-time WHOOP warning, surfaced as an amber card BEFORE the user
                // scans so the most common pairing failure (the official app still holding the link) is
                // pre-empted, not discovered after a failed scan. WHOOP-only: the single-link constraint
                // is specific to the WHOOP band's bonding, not the generic HR / FTMS paths.
                if type.isWhoop {
                    singleConnectionWarning
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(prepInstructions(type).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                            Text(line)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frostedCardSurface(cornerRadius: 14)

                Button {
                    startScan(for: type)
                    step = .pick
                } label: {
                    Label("Scan", systemImage: "dot.radiowaves.left.and.right")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .accessibilityLabel("Scan for \(typeTitle(type))")
            }
        }
    }

    /// Type-specific "get it ready" guidance — the point of the branching wizard.
    private func prepInstructions(_ t: DeviceType) -> [String] {
        switch t {
        case .whoop4:
            return [
                String(localized: "Put your WHOOP 4.0 on your wrist and make sure it's awake."),
                String(localized: "Make sure it's NOT connected to the official WHOOP app right now."),
                String(localized: "NOOP will look for it nearby."),
            ]
        case .whoop5mg:
            return [
                String(localized: "WHOOP 5.0 / MG bonds to one device at a time. Unpair it from the official WHOOP app first."),
                String(localized: "Put the band into pairing mode, on your wrist and awake."),
                String(localized: "NOOP will look for it nearby."),
            ]
        case .hrStrap:
            return [
                String(localized: "Wake your strap. Put it on, or dampen the contacts."),
                String(localized: "Make sure it isn't connected to another app (a bike computer, the brand's own app…)."),
                String(localized: "NOOP will look for it nearby."),
            ]
        case .gymEquipment:
            return [
                String(localized: "Wake the machine. Start pedalling, walking or rowing so it powers on its Bluetooth."),
                String(localized: "Make sure it isn't already connected to another app (Zwift, the gym's app, a bike computer…)."),
                String(localized: "NOOP looks for machines that broadcast the standard Bluetooth Fitness Machine service."),
            ]
        case .amazfit:
            return [
                String(localized: "Wake your Amazfit / Zepp band and make sure it isn't connected to the Zepp app right now."),
                String(localized: "NOOP reads live heart rate when the band exposes it. Some bands need a pairing we can't do yet. If so, we'll say so honestly."),
                String(localized: "Experimental: this is best-effort. If live doesn't work, you can export from Zepp and import the file."),
            ]
        case .miBand:
            return [
                String(localized: "Wake your Mi Band and make sure it isn't connected to the Mi Fitness / Zepp Life app right now."),
                String(localized: "NOOP reads live heart rate on bands that don't require pairing. Newer bands need an auth handshake we can't do yet."),
                String(localized: "Experimental: if your band needs pairing, we'll tell you honestly rather than show a fake reading."),
            ]
        case .garmin:
            return GarminBroadcast.broadcastHint
        case .oura:
            // The factory-reset-and-adopt checklist, shown only AFTER the irreversible-consent gate. NOOP
            // installs its own key on a reset ring and becomes its sole owner (clean-room facts, see
            // docs/OURA_PROTOCOL.md s3 on the install-key + reset-clears-owner model).
            return [
                String(localized: "Open the official Oura app and remove this ring (Oura calls it \"factory reset\" or \"unpair and reset\"). This wipes the ring's owner so NOOP can take it over."),
                String(localized: "Keep the ring on the charger or on your finger so it stays awake."),
                String(localized: "Make sure the Oura app is fully closed. A ring answers one owner at a time."),
                String(localized: "When the ring is reset and waking, tap Scan below."),
            ]
        }
    }

    // MARK: Step 2 (Oura) - destructive factory-reset-and-adopt sub-flow

    /// The Oura adopt sub-flow, routed by `ouraStep`. Faithful parity with the Android `OuraFlow`:
    ///   - gate     irreversible-consent gate ("This replaces Oura") OR the Advanced key field.
    ///   - prep     factory-reset checklist + single-owner warning + Scan.
    ///   - pick     live scan + pick a ring (honest needs-pairing fallback).
    ///   - confirm  detected generation + per-gen capability checklist + the SECOND destructive "Take over".
    ///   - adopting honest key-install progress (no fake percent).
    ///   - failed   honest dead-end with Try again + Use file import.
    /// All copy is honest, US-neutral, no em-dashes (spec docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md).
    @ViewBuilder private var ouraFlow: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The header icon + Beta pill ride above the gate / prep faces only; the later faces carry their
            // own card chrome (matching the Android per-step composition).
            if ouraStep == .gate || ouraStep == .prep {
                HStack(spacing: 14) {
                    Image(systemName: "circle.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Oura ring").font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    StatePill("Beta", tone: .warning, showsDot: false)
                }
            }

            switch ouraStep {
            case .gate:     if ouraAdvancedKeyMode { ouraAdvancedKeyFace } else { ouraConsentGateFace }
            case .prep:     ouraResetChecklistFace
            case .pick:     ouraPickFace
            case .confirm:  ouraConfirmFace
            case .adopting: ouraAdoptingFace
            case .failed:   ouraFailedFace
            }
        }
    }

    /// Face 1, the honest gate. Beta banner, a two-column "what you get / what you lose" card, the red
    /// irreversible line with a mandatory checkbox, then Continue (disabled until ticked) plus the two
    /// always-available escape lanes (file import, Advanced key).
    @ViewBuilder private var ouraConsentGateFace: some View {
        ouraBetaBanner

        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What you get").strandOverline()
                    ouraBullet(String(localized: "Your ring talks to NOOP only, fully offline, no Oura account."))
                    ouraBullet(String(localized: "Live heart rate, and HRV when the ring can measure it."))
                    ouraBullet(String(localized: "Overnight sleep staging, resting heart rate, skin-temperature trend, motion and battery, read straight off the ring."))
                    ouraBullet(String(localized: "NOOP's own Charge, Effort and Rest, computed on your device from published methods."))
                }
                Divider().overlay(StrandPalette.hairline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("What you lose").strandOverline()
                    ouraBullet(String(localized: "The Oura app and your Oura account stop working with this ring. This is the point. You are replacing Oura."))
                    ouraBullet(String(localized: "Oura's own Readiness and Sleep scores. NOOP does not copy them. It computes its own."))
                    ouraBullet(String(localized: "Anything that needs Oura's cloud (web dashboard, Oura's coaching, shared circles)."))
                    ouraBullet(String(localized: "Likely your Oura warranty and support, because the ring is no longer paired to Oura. Treat this as permanent."))
                }
            }
        }

        // The irreversible line, styled critical (red), with the mandatory tick.
        Button {
            ouraConsented.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ouraConsented ? "checkmark.square.fill" : "square")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .accessibilityHidden(true)
                Text("I understand this disconnects the ring from Oura and that NOOP cannot undo it for me. To go back to Oura I would factory-reset the ring again and set it up in the Oura app.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.statusCritical.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("I understand this disconnects the ring from Oura and that NOOP cannot undo it for me.")
        .accessibilityAddTraits(ouraConsented ? [.isSelected] : [])

        // Primary: continue to the reset checklist. Disabled until the box is ticked.
        Button {
            ouraStep = .prep   // tick confirmed: advance to the factory-reset checklist face
        } label: {
            Label("Continue", systemImage: "arrow.right")
                .font(StrandFont.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(StrandPalette.accent)
        .disabled(!ouraConsented)
        .accessibilityHint("Continue to get your ring ready")

        // Secondary: keep the Oura app, import a file instead (non-destructive, always one tap away).
        Button("Keep the Oura app instead (import a file)") {
            stopAllScans()
            onClose()   // routes to the existing Data Sources / file-import lane
        }
        .font(StrandFont.subhead)
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.accent)
        .accessibilityLabel("Keep the Oura app instead, import a file")

        // Tertiary: Advanced power-user key path (no reset, Oura app keeps working).
        Button("Advanced: I already have my ring's key") {
            ouraAdvancedKeyMode = true
        }
        .font(StrandFont.footnote)
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.accent)
        .accessibilityLabel("Advanced. I already have my ring's key.")
    }

    /// Face 2, the factory-reset checklist + the single-owner amber warning + Scan. Reached after the
    /// consent box is ticked.
    @ViewBuilder private var ouraResetChecklistFace: some View {
        Text("Reset it in the Oura app first, then scan.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)

        // One-owner heads-up, amber (mirrors the WHOOP single-connection warning).
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("A ring talks to one owner at a time.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If the Oura app is still running it will hold the ring and adoption will fail. Force-quit Oura, then scan.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(prepInstructions(.oura).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface(cornerRadius: 14)

        Button {
            startScan(for: .oura)
            ouraStep = .pick
        } label: {
            Label("Scan for your ring", systemImage: "dot.radiowaves.left.and.right")
                .font(StrandFont.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(StrandPalette.accent)
        .accessibilityLabel("Scan for your Oura ring")
    }

    /// Face 3, the Advanced "use your own key" power-user path. Authenticates with a supplied 16-byte key
    /// WITHOUT a factory reset, so the Oura app keeps working too. Validates 32 hex chars before Scan.
    @ViewBuilder private var ouraAdvancedKeyFace: some View {
        Text("Power users only.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text("If you extracted your ring's 16-byte key from a previous Oura setup, NOOP can talk to the ring with that key without resetting it, so the Oura app keeps working too. NOOP does not extract keys for you and cannot help you find one. If you do not know what this means, go back and use the standard setup or file import.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        Text("Ring key (32 hex characters)").strandOverline()
        TextField("0123456789abcdef0123456789abcdef", text: $ouraKeyDraft)
            .textFieldStyle(.plain)
            .font(StrandFont.body.monospaced())
            .foregroundStyle(StrandPalette.textPrimary)
            .autocorrectionDisabled(true)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(12)
            .background(StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Ring key, 32 hexadecimal characters")
        if !ouraKeyDraft.isEmpty && ouraKeyBytes == nil {
            Text("That is not a 32-character hex key.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusCritical)
        }
        Text("NOOP stores this key only on this device, in the same place it stores your paired bands.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

        Button {
            startScan(for: .oura)
            ouraStep = .pick
        } label: {
            Label("Scan for your ring", systemImage: "dot.radiowaves.left.and.right")
                .font(StrandFont.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(StrandPalette.accent)
        .disabled(ouraKeyBytes == nil)
        .accessibilityLabel("Scan for your Oura ring")

        Button("Back to standard setup") {
            ouraAdvancedKeyMode = false
            ouraKeyDraft = ""
        }
        .font(StrandFont.footnote)
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.accent)
    }

    // MARK: Step 3 (Oura) - pick the ring

    /// The Oura pick face. Observes the discovery-only `OuraLiveSource`; selecting a ring confirms its
    /// best-effort generation and advances to the capability/confirm face. An honest needs-pairing fallback
    /// (the ring is still Oura-owned / not reset) routes to file import. Mirrors the Android `OuraPickStep`.
    @ViewBuilder private var ouraPickFace: some View {
        OuraPickList(scanner: ouraScanner,
                     onSelect: { ring in
                         let gen = ring.detectedGen ?? .gen3
                         pickedOura = (ring: ring, gen: gen)
                         clearOtherPicks(except: .oura)
                         nameDraft = String(localized: "Oura ring")
                         ouraScanner.stopScan()
                         ouraStep = .confirm
                     },
                     onRescan: { ouraScanner.scan() },
                     onUseImport: {
                         ouraScanner.stop()
                         onClose()   // honest non-destructive fallback: head to file import
                     })
    }

    // MARK: Step 4 (Oura) - confirm: detected gen + per-gen capability checklist + the SECOND gate

    /// The Oura confirm face: the identified ring (gen name + Beta pill), the per-gen capability checklist
    /// (tick / * estimate / dash not-available), a name field, then the adopt action. On the standard adopt
    /// path the action is the red "Take over this ring" (which raises the SECOND irreversible confirm); on the
    /// non-destructive Advanced-key path it is a plain "Connect to this ring" that registers without a key
    /// install. Mirrors the Android `OuraConfirmStep`.
    @ViewBuilder private var ouraConfirmFace: some View {
        let gen = pickedOura?.gen ?? .gen3
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(gen.displayName).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    StatePill("Beta", tone: .warning, showsDot: false)
                }
                ForEach(Array(ouraCapabilityRows(for: gen).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.mark)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 14, alignment: .leading)
                        Text(row.label)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, steps are a raw motion count, and HRV needs you to be still. No Oura Readiness or SpO2 percentage comes off the ring (import an Oura file for those).")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 14)

            Text("Name").strandOverline()
            TextField("Oura ring", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(12)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Device name")

            if ouraAdvancedKeyMode {
                // Non-destructive: the user's own key authenticates without resetting the ring, so this reads
                // as a plain accent connect and skips the destructive confirm.
                Button {
                    finishAdvancedOura()
                } label: {
                    Text("Connect to this ring")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .accessibilityLabel("Connect to this ring")
                Text("Both NOOP and the Oura app can use a ring you own by key, but only one can hold the Bluetooth link at a time.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Destructive (key install): raise the SECOND irreversible "Take over this ring?" confirm.
                Button {
                    ouraConfirmAdopt = true
                } label: {
                    Text("Take over this ring")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.statusCritical)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(StrandPalette.statusCritical.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take over this ring")
            }
        }
    }

    // MARK: Step 5 (Oura) - adopting: honest key-install progress (no fake percent)

    /// The Adopting face: an honest "Installing NOOP's key" progress card shown ONLY while a real key install
    /// is in flight (the standard adopt path; the Advanced path never lands here). Driven to success/Failed by
    /// the live source's `adoptPhase` (see the body `.onChange`). Mirrors the Android `OuraAdoptingStep`.
    @ViewBuilder private var ouraAdoptingFace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView().tint(StrandPalette.accent)
                Text("Taking over your ring")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Text("Installing NOOP's key and confirming the ring answers only to NOOP. Keep the ring close and do not open the Oura app.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface(cornerRadius: 14)
    }

    // MARK: Step 5 (Oura, failure) - honest dead-end, never a fabricated success

    /// The Failed face: an honest dead-end with the live source's needs-pairing message (when present) and the
    /// two reachable fallbacks (Try again -> back to pick; Use file import -> close to Data Sources). Re-enables
    /// the user's exits so they are never trapped. Mirrors the Android `OuraFailedStep`.
    @ViewBuilder private var ouraFailedFace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("We could not take over this ring.")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(model.ouraNeedsPairing ?? "The most common cause is the ring was not fully reset in the Oura app, or the Oura app is still running. Reset the ring again, force-quit Oura, then try once more. If it keeps failing, your ring may be a generation NOOP cannot adopt yet. The ring is not bricked: re-pair it in the Oura app to recover it. You can still use file import.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    pickedOura = nil
                    ouraScanner.scan()
                    ouraStep = .pick
                } label: {
                    Text("Try again")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .accessibilityLabel("Try again")

                Button {
                    ouraScanner.stop()
                    onClose()   // honest non-destructive fallback: head to file import
                } label: {
                    Text("Use file import")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use file import")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface(cornerRadius: 14)
    }

    /// The per-generation capability checklist (section 3 of the onboarding UX spec). Each row is a (mark,
    /// label): a tick for decoded-and-used, * for a best-effort on-device estimate, a dash for
    /// not-available-off-the-ring. gen3/gen4 are the verified path; gen5's live HR + firmware reads are
    /// least proven so they read as estimates. PARITY: the marks match the Android `ouraCapabilityRows`
    /// exactly. No Oura Readiness/Sleep score or absolute SpO2 % ever comes off the ring.
    private func ouraCapabilityRows(for gen: OuraRingGen) -> [(mark: String, label: String)] {
        let live = (gen == .gen5) ? "*" : "✓"   // newer rings: live HR is best-effort
        let firm = (gen == .gen5) ? "*" : "✓"   // resting HR / sleep / battery
        return [
            (live, String(localized: "Live heart rate")),
            ("*", "HRV (rMSSD)"),
            (firm, String(localized: "Resting heart rate")),
            (firm, String(localized: "Sleep staging")),
            ("*", String(localized: "Skin-temperature trend")),
            ("*", String(localized: "Steps / motion")),
            (firm, String(localized: "Battery")),
            ("-", String(localized: "Blood oxygen (SpO2 %)")),
            ("-", String(localized: "Oura Readiness / Sleep score")),
        ]
    }

    /// The shared Oura Beta heads-up banner (amber), reused at the top of the consent gate.
    private var ouraBetaBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Beta. Read this first.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusWarning)
                Text("Local Oura support is new and we cannot test every ring here. It may not connect on your ring, and it can change between updates. NOOP never makes up a number. If something does not work, it will tell you plainly.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// One "·"-free bullet line for the get/lose columns.
    private func ouraBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The Advanced key field parsed into 16 raw bytes, or nil when it is not exactly 32 hex characters.
    /// Used to gate the Advanced Scan button and to seed the install-key store on adoption.
    private var ouraKeyBytes: Data? {
        let hex = ouraKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == OuraKeyStore.keyLength * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(OuraKeyStore.keyLength)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }

    /// SF Symbol for a device type — used on the prep step header.
    private func typeIcon(_ t: DeviceType) -> String {
        switch t {
        case .whoop4, .whoop5mg: return "applewatch.side.right"
        case .hrStrap:           return "heart.circle"
        case .gymEquipment:      return "figure.run.treadmill"
        case .amazfit:           return "waveform.path.ecg.rectangle"
        case .miBand:            return "waveform.path.ecg"
        case .garmin:            return "applewatch"
        case .oura:              return "circle.circle"
        }
    }

    // MARK: Step 3 — pick from the live scan

    @ViewBuilder private var pickStep: some View {
        if let type {
            if type.isWhoop {
                // Observe BLEManager directly so the list updates as `discoveredWhoops` grows. The
                // subview holds the @ObservedObject; the wizard owns selection + scan lifecycle.
                WhoopPickList(ble: model.ble) { strap in
                    pickedWhoop = strap
                    pickedStrap = nil
                    pickedMachine = nil
                    pickedHuami = nil
                    nameDraft = strap.name.isEmpty ? typeTitle(type) : strap.name
                    model.stopWhoopScan()
                    step = .confirm
                } onRescan: {
                    model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
                }
            } else if type == .gymEquipment {
                FTMSPickList(scanner: ftmsScanner) { machine in
                    pickedMachine = machine
                    clearOtherPicks(except: .gymEquipment)
                    nameDraft = machine.name
                    ftmsScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    ftmsScanner.scan()
                }
            } else if type == .amazfit || type == .miBand {
                // EXPERIMENTAL Huami pick list (Amazfit / Zepp / Mi Band).
                HuamiPickList(scanner: huamiScanner) { dev in
                    pickedHuami = dev
                    clearOtherPicks(except: type)
                    nameDraft = dev.name
                    huamiScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    huamiScanner.scan()
                }
            } else {
                // Heart-rate strap AND Garmin (Broadcast HR is the standard 0x180D path).
                HRPickList(scanner: hrScanner) { strap in
                    pickedStrap = strap
                    clearOtherPicks(except: type ?? .hrStrap)
                    nameDraft = strap.name
                    hrScanner.stopScan()
                    step = .confirm
                } onRescan: {
                    hrScanner.scan()
                }
            }
        }
    }

    /// Clear every "picked" selection except the one for `keep`'s path, so re-entering the pick step or
    /// switching device types never leaves a stale pick of another shape.
    private func clearOtherPicks(except keep: DeviceType) {
        if keep.isWhoop == false { pickedWhoop = nil }
        switch keep {
        case .hrStrap, .garmin:    pickedHuami = nil; pickedMachine = nil; pickedOura = nil
        case .gymEquipment:        pickedStrap = nil; pickedHuami = nil; pickedOura = nil
        case .amazfit, .miBand:    pickedStrap = nil; pickedMachine = nil; pickedOura = nil
        case .oura:                pickedStrap = nil; pickedMachine = nil; pickedHuami = nil
        default:                   pickedStrap = nil; pickedMachine = nil; pickedHuami = nil; pickedOura = nil
        }
    }

    // MARK: Step 4 — name + confirm

    @ViewBuilder private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SignalBars(rssi: confirmRSSI)
                VStack(alignment: .leading, spacing: 2) {
                    Text(confirmAdvertisedName).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(confirmBrand).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)

            Text("Name").strandOverline()
            TextField("Device name", text: $nameDraft)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(12)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("Device name")

            Button("Add") { askMakeActive = true }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .frame(maxWidth: .infinity)
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 4)
        }
    }

    // MARK: Confirm-step derived values

    private var confirmName: String {
        let n = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? confirmAdvertisedName : n
    }
    private var confirmAdvertisedName: String {
        if let pickedWhoop { return pickedWhoop.name.isEmpty ? (type.map(typeTitle) ?? String(localized: "Device")) : pickedWhoop.name }
        if let pickedStrap { return pickedStrap.name }
        if let pickedMachine { return pickedMachine.name }
        if let pickedHuami { return pickedHuami.name }
        if let pickedOura { return pickedOura.ring.name }
        return type.map(typeTitle) ?? String(localized: "Device")
    }
    private var confirmBrand: String {
        if type?.isWhoop == true { return "WHOOP" }
        if type == .gymEquipment { return String(localized: "Gym equipment") }
        // Experimental non-Oura types (Amazfit / Mi Band / Garmin) take their stored brand string straight
        // from the catalog via the type→brand bridge. Oura falls through to its detected-generation label.
        if let brand = type?.experimentalBrand, brand != .oura { return brand.displayBrand }
        // Oura confirms with the detected generation name + a Beta marker so the user sees what NOOP
        // identified before adopting (the gen is best-effort from the scan, fixed by this pick).
        if let pickedOura { return String(localized: "\(pickedOura.gen.displayName) · Beta") }
        if let pickedStrap { return brandGuess(from: pickedStrap.name) }
        return String(localized: "Heart-rate strap")
    }
    private var confirmRSSI: Int {
        pickedWhoop?.rssi ?? pickedStrap?.rssi ?? pickedMachine?.rssi ?? pickedHuami?.rssi ?? pickedOura?.ring.rssi ?? -70
    }

    // MARK: Actions

    private func goBack() {
        // The Oura type walks its own step machine; back falls out to the type list from the gate.
        if type == .oura {
            ouraGoBack()
            return
        }
        switch step {
        case .type:    break
        case .prep:    step = .type
        case .pick:    stopAllScans(); step = .prep
        case .confirm:
            // Re-enter the pick step and restart its scan so the user can choose a different device.
            if let type { startScan(for: type) }
            pickedWhoop = nil; pickedStrap = nil; pickedMachine = nil; pickedHuami = nil; pickedOura = nil
            step = .pick
        }
    }

    /// Back inside the Oura adopt sub-flow. Adopting has no meaningful back (a key install is in flight, and
    /// `showBack` already hides it there); from Failed, back returns to the pick step to try again, so the
    /// user is never trapped. Mirrors the Android `ouraGoBack`.
    private func ouraGoBack() {
        switch ouraStep {
        case .gate:
            // From the Advanced key field, back returns to the standard consent gate; from the standard gate,
            // back exits to the device-type list.
            if ouraAdvancedKeyMode {
                ouraAdvancedKeyMode = false
                ouraKeyDraft = ""
            } else {
                type = nil
                ouraConsented = false
            }
        case .prep:
            ouraStep = .gate
        case .pick:
            ouraScanner.stop()
            pickedOura = nil
            ouraStep = ouraAdvancedKeyMode ? .gate : .prep
        case .confirm:
            ouraScanner.scan()
            pickedOura = nil
            ouraStep = .pick
        case .adopting, .failed:
            ouraScanner.scan()
            pickedOura = nil
            ouraStep = .pick
        }
    }

    private func startScan(for type: DeviceType) {
        switch type {
        case .whoop4, .whoop5mg: model.presentWhoopScan(model: type.whoopModel ?? .whoop4)
        case .gymEquipment:      ftmsScanner.scan()
        case .amazfit, .miBand:  huamiScanner.scan()
        case .oura:              ouraScanner.scan()
        // Heart-rate strap AND Garmin both use the standard 0x180D scanner (Garmin Broadcast HR).
        case .hrStrap, .garmin:  hrScanner.scan()
        }
    }

    private func stopAllScans() {
        model.stopWhoopScan()
        hrScanner.stopScan()
        ftmsScanner.stopScan()
        huamiScanner.stopScan()
        ouraScanner.stop()
    }

    /// Build the right `PairedDevice` for the chosen path, register it, optionally activate, then close.
    private func finishAdd(makeActive: Bool) {
        stopAllScans()
        let now = Int(Date().timeIntervalSince1970)
        let name = confirmName
        let device: PairedDevice

        if let pickedWhoop, let type, let wm = type.whoopModel {
            // WHOOP: honest live capability set (no calibrated SpO₂ % — import-only; #548);
            // id namespaced by uuid; model "4.0" / "5.0 MG". Steps only on 5.0/MG.
            let modelLabel = (wm == .whoop4) ? "4.0" : "5.0 MG"
            device = PairedDevice(
                id: "whoop-\(pickedWhoop.uuid)",
                brand: "WHOOP",
                model: modelLabel,
                nickname: name,
                peripheralId: pickedWhoop.uuid,
                sourceKind: .liveBLE,
                capabilities: WhoopLiveCapabilities.metrics(forModel: modelLabel),
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedStrap {
            // Generic HR strap OR a Garmin broadcasting standard HR. Garmin's brand + id prefix come from
            // the catalog (via the type→brand bridge); it still stores `.liveBLE` (its live HR IS the
            // standard 0x180D path). A non-Garmin strap keeps the advertised-name brand guess + "strap"
            // prefix. Both are HR + HRV.
            let garmin = (type == .garmin) ? ExperimentalBrand.garmin : nil
            device = PairedDevice(
                id: "\(garmin?.idPrefix ?? "strap")-\(pickedStrap.id.uuidString)",
                brand: garmin?.displayBrand ?? brandGuess(from: pickedStrap.name),
                model: pickedStrap.name,
                nickname: name == pickedStrap.name ? nil : name,
                peripheralId: pickedStrap.id.uuidString,
                sourceKind: .liveBLE,
                capabilities: [.hr, .hrv],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedHuami {
            // EXPERIMENTAL Amazfit / Zepp / Mi Band. Brand string, id prefix, and the `.huami` routing all
            // come from the catalog via the type→brand bridge (was: `(type == .miBand) ? "Mi Band" : …`).
            // HR only (the Huami custom characteristic carries no R-R).
            let brand = type?.experimentalBrand ?? .amazfit
            device = PairedDevice(
                id: "\(brand.idPrefix)-\(pickedHuami.id.uuidString)",
                brand: brand.displayBrand,
                model: pickedHuami.name,
                nickname: name == pickedHuami.name ? nil : name,
                peripheralId: pickedHuami.id.uuidString,
                sourceKind: brand.sourceKind,
                capabilities: [.hr],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else if let pickedMachine {
            // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
            // live-workout path. sourceKind `.ftms` routes the SourceCoordinator to the FTMSSource.
            device = PairedDevice(
                id: "ftms-\(pickedMachine.id.uuidString)",
                brand: "Gym equipment",
                model: pickedMachine.name,
                nickname: name == pickedMachine.name ? nil : name,
                peripheralId: pickedMachine.id.uuidString,
                sourceKind: .ftms,
                capabilities: [.hr],
                status: .paired,
                addedAt: now, lastSeenAt: now)
        } else {
            // The Oura type commits through its own `commitOuraAdopt` / `finishAdvancedOura`, never here.
            onClose(); return
        }

        model.registerDevice(device, makeActive: makeActive)
        onClose()
    }

    // MARK: Oura commit (the two Oura paths, NOT the generic finishAdd)

    /// Build the `.oura` `PairedDevice` for the picked ring. sourceKind `.oura` routes the SourceCoordinator
    /// to the OuraLiveSource (its OWN central, never the WHOOP path). The generation rides `model`
    /// (OuraRingGen.from(model:) recovers it), and the capability set is gen-filtered. NOOP computes its own
    /// Charge/Rest from the ring's raw signals; it never reads Oura's encrypted readiness/sleep scores, and a
    /// signal it can't read stays "-" (honest-data invariant). Returns nil when no ring is picked.
    private func buildOuraDevice() -> PairedDevice? {
        guard let pickedOura else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let gen = pickedOura.gen
        let uuid = pickedOura.ring.id.uuidString
        let name = confirmName
        // Brand string, id prefix, and the `.oura` routing come from the catalog via the type→brand bridge.
        let oura = ExperimentalBrand.oura
        return PairedDevice(
            id: "\(oura.idPrefix)-\(uuid)",
            brand: oura.displayBrand,
            model: gen.displayName,
            nickname: name == String(localized: "Oura ring") ? nil : name,
            peripheralId: uuid,
            sourceKind: oura.sourceKind,
            capabilities: ouraCapabilities(for: gen),
            status: .paired,
            addedAt: now, lastSeenAt: now)
    }

    /// COMMIT the standard destructive adopt: reached ONLY from the "Take over" confirm (the SECOND
    /// irreversible gate, after the consent tick). It grants the coordinator adopt consent for THIS ring and
    /// registers it active; the live source then runs the one-time key install (s3.2). The wizard moves to its
    /// honest Adopting step, which the live source's adopt phase drives to success (close) or Failed. NO key is
    /// stored here: the live install persists NOOP's freshly-generated key only on an OK `0x25` ack.
    private func commitOuraAdopt() {
        guard let device = buildOuraDevice() else { onClose(); return }
        stopAllScans()
        ouraStep = .adopting
        model.adoptOuraRing(device)   // grants adopt consent + registers active; never prompts make-active
    }

    /// COMMIT the non-destructive Advanced-key path: persist the user-supplied 16-byte key, register the ring
    /// active (it authenticates with that key, no reset, no install), then close. This path NEVER installs a
    /// key and NEVER passes through the Adopting/Take-over gates. Validates the key first (the Scan button was
    /// already gated on a valid key, so this is belt-and-braces).
    private func finishAdvancedOura() {
        guard let device = buildOuraDevice(), let key = ouraKeyBytes else { onClose(); return }
        stopAllScans()
        OuraKeyStore.save(key, deviceId: device.id)
        // The user supplied their own key; this is their new live source. Register active (no adopt consent,
        // so the live source can NEVER install a key on this path).
        model.registerDevice(device, makeActive: true)
        onClose()
    }

    /// Map the protocol package's per-gen `OuraMetric` set onto the app's `Metric` set for registration.
    /// Gen3+ all expose the same dictionary, so this is currently uniform, but it is gen-filtered so a
    /// future gen-specific gate is a one-line change (per OURA_PROTOCOL.md s7.2). SpO2 registers as the
    /// `.spo2` capability for the RAW ADC signal only; NO absolute SpO2 percentage is ever claimed.
    private func ouraCapabilities(for gen: OuraRingGen) -> Set<Metric> {
        var caps: Set<Metric> = []
        for m in gen.capabilities {
            switch m {
            case .hr:       caps.insert(.hr)
            case .hrv:      caps.insert(.hrv)
            case .spo2:     caps.insert(.spo2)
            case .skinTemp: caps.insert(.skinTemp)
            case .sleep:    caps.insert(.sleep)
            }
        }
        return caps
    }

    // MARK: Copy / helpers

    private func typeTitle(_ t: DeviceType) -> String {
        switch t {
        case .whoop5mg:     return "WHOOP 5.0 / MG"
        case .whoop4:       return "WHOOP 4.0"
        case .hrStrap:      return String(localized: "Heart-rate strap")
        case .gymEquipment: return String(localized: "Gym equipment")
        case .amazfit:      return "Amazfit / Zepp"
        case .miBand:       return "Xiaomi Mi Band"
        case .garmin:       return String(localized: "Garmin watch")
        case .oura:         return String(localized: "Oura ring")
        }
    }

    /// A shared "this tier is experimental" note shown on the type list heading and every experimental
    /// prep step. Honest, US-neutral, no em-dashes.
    private var experimentalTierNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text("Experimental, best-effort support. We're still testing these, so they might not connect on every device. They never make up data, and they'll tell you honestly when live isn't possible.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var experimentalNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flask")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            Text("WHOOP 5.0 / MG support is newer and still experimental in NOOP.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A6 , the amber "one phone at a time" warning shown before a WHOOP scan. A failed pairing is most
    /// often the official WHOOP app still holding the band's single BLE link; saying so up front (with the
    /// concrete fix) is the honest, frustration-saving move. Amber `statusWarning` matches the existing
    /// experimental-note treatment so it reads as "heads-up", not "error".
    private var singleConnectionWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your WHOOP only talks to one phone at a time.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Force-quit the official WHOOP app first, or pairing may fail.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heads-up. Your WHOOP only talks to one phone at a time. Force-quit the official WHOOP app first, or pairing may fail.")
    }

    private var whoopFirstNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("WHOOP is NOOP's primary, fully-supported band. Other heart-rate straps stream live heart rate and HRV, but not WHOOP's deeper sleep and recovery data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    /// Best-effort brand from the advertised name; neutral fallback for unknown straps. Delegates to the
    /// pure `DeviceBrandCatalog` (single source of truth), so the token table lives once.
    private func brandGuess(from name: String) -> String {
        DeviceBrandCatalog.spec(forAdvertisedName: name)?.brand ?? String(localized: "Heart-rate strap")
    }
}

// MARK: - WHOOP pick list (observes BLEManager's present-scan)

/// The WHOOP family pick step. Holds `@ObservedObject ble` so the list re-renders as the present-scan
/// surfaces straps in `discoveredWhoops`. Pure UI — selection + scan lifecycle live in the wizard.
private struct WhoopPickList: View {
    @ObservedObject var ble: BLEManager
    let onSelect: ((uuid: String, name: String, rssi: Int)) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: true, onRescan: onRescan)
            let found = ble.discoveredWhoops.sorted { $0.rssi > $1.rssi }
            if found.isEmpty {
                SearchingCard(whoopHint: true)
            } else {
                ForEach(found, id: \.uuid) { strap in
                    DiscoveredRow(name: strap.name.isEmpty ? "WHOOP" : strap.name,
                                  subtitle: "WHOOP",
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }
}

// MARK: - HR strap pick list (observes its own StandardHRSource)

private struct HRPickList: View {
    @ObservedObject var scanner: StandardHRSource
    let onSelect: (StandardHRSource.DiscoveredStrap) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { strap in
                    DiscoveredRow(name: strap.name,
                                  subtitle: brandGuess(from: strap.name),
                                  rssi: strap.rssi) {
                        onSelect(strap)
                    }
                }
            }
        }
    }

    private func brandGuess(from name: String) -> String {
        DeviceBrandCatalog.spec(forAdvertisedName: name)?.brand ?? String(localized: "Heart-rate strap")
    }
}

// MARK: - FTMS gym-equipment pick list (observes its own FTMSSource)

private struct FTMSPickList: View {
    @ObservedObject var scanner: FTMSSource
    let onSelect: (FTMSSource.DiscoveredMachine) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { machine in
                    DiscoveredRow(name: machine.name,
                                  subtitle: String(localized: "Gym equipment"),
                                  rssi: machine.rssi) {
                        onSelect(machine)
                    }
                }
            }
        }
    }
}

// MARK: - Huami experimental pick list (Amazfit / Zepp / Mi Band)

private struct HuamiPickList: View {
    @ObservedObject var scanner: HuamiHRSource
    let onSelect: (HuamiHRSource.DiscoveredDevice) -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if scanner.discovered.isEmpty {
                SearchingCard()
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { dev in
                    DiscoveredRow(name: dev.name, subtitle: String(localized: "Experimental"), rssi: dev.rssi) {
                        onSelect(dev)
                    }
                }
            }
        }
    }
}

// MARK: - Oura experimental pick list (real live scan → adopt, honest needs-pairing fallback)

/// The Oura ring pick step. Observes the discovery-only `OuraLiveSource` and lists found rings as real
/// `DiscoveredRow`s (like `HuamiPickList`). Selecting a ring proceeds to confirm + adopt rather than
/// dead-ending. When the source reports `needsPairing` (the ring is still owned by Oura, was not reset, or
/// the key was rejected), the honest message + a "Use file import" fallback replaces the list, so the
/// non-destructive lane is always one tap away (spec docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md).
private struct OuraPickList: View {
    @ObservedObject var scanner: OuraLiveSource
    let onSelect: (OuraLiveSource.DiscoveredRing) -> Void
    let onRescan: () -> Void
    /// Tapped when the user takes the honest non-destructive fallback and heads to file import.
    let onUseImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ScanStatusBar(searching: scanner.scanning, onRescan: onRescan)
            if let msg = scanner.needsPairing {
                // Honest needs-pairing state: the ring won't answer (still Oura-owned / not reset). Never a
                // fabricated reading: point at the file-import lane instead.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        Text(msg)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Use file import") { onUseImport() }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)
                        .accessibilityLabel("Use file import for Oura")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frostedCardSurface(cornerRadius: 14)
            } else if scanner.discovered.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SearchingCard()
                    Text("Not showing up? Make sure you reset the ring in the Oura app and force-quit it, then tap Rescan. A ring still owned by Oura will not list here.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(scanner.discovered.sorted { $0.rssi > $1.rssi }) { ring in
                    DiscoveredRow(name: ring.name,
                                  subtitle: String(localized: "\(ring.detectedGen?.displayName ?? String(localized: "Oura ring")) · Beta"),
                                  rssi: ring.rssi) {
                        onSelect(ring)
                    }
                }
            }
        }
    }
}

// MARK: - Shared pick-step pieces

private struct ScanStatusBar: View {
    let searching: Bool
    let onRescan: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            StatePill(searching ? "Searching…" : "Idle",
                      tone: searching ? .accent : .neutral,
                      pulsing: searching)
            Spacer()
            Button("Rescan", action: onRescan)
                .font(StrandFont.subhead)
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
        }
    }
}

private struct SearchingCard: View {
    /// A6 , honest phase copy. WHOOP scans add the single-link reminder under the generic line, since a
    /// stuck scan there is almost always the official app still holding the band. Defaults off so the HR /
    /// FTMS / Huami / Oura pick lists keep their existing copy unchanged.
    var whoopHint: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView().tint(StrandPalette.accent)
            Text("Searching…")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Make sure it's awake and not connected elsewhere.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if whoopHint {
                Text("Not showing up? The official WHOOP app may still be holding it. Force-quit that app, then tap Rescan.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .frostedCardSurface(cornerRadius: 14)
    }
}

private struct DiscoveredRow: View {
    let name: String
    let subtitle: String
    let rssi: Int
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                SignalBars(rssi: rssi)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), signal \(SignalBars.level(for: rssi)) of 4")
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Add device wizard") {
    let model = AppModel()
    return AddDeviceWizard(live: model.live, onClose: {})
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
