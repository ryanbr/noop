import SwiftUI
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore
// #174: the R22 card reads the flag COUNT off `Whoop5Config.enableR22Sequence` rather than restating it —
// the hardcoded "15" outlived the sequence growing to 16 and declared success a flag early.
import WhoopProtocol

/// Settings — profile (powers zones / calories / recovery), strap connection, and about.
/// Grouped cards on surface.raised with a two-column form feel.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Profile-photo picker selection (PhotosUI). Cleared back to nil once the bytes are loaded.
    @State private var avatarPickerItem: PhotosPickerItem?

    /// Custom background image (#custom-background). The store owns the decoded image + toggles; the
    /// picker selection + the file-importer flag are local UI state.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared
    @State private var backgroundPickerItem: PhotosPickerItem?
    @State private var showBackgroundFileImporter = false

    /// Backup & restore UI state.
    @State private var backupBusy = false
    @State private var backupAlertTitle = ""
    @State private var backupAlertMessage = ""
    @State private var showBackupAlert = false

    /// Opt-in WHOOP 5/MG protocol experiments (off by default). See [PuffinExperiment].
    @AppStorage(PuffinExperiment.defaultsKey) private var puffinExperiments = false

    /// Opt-in WHOOP 5/MG raw-frame capture to a file (off by default). See [PuffinFrameRecorder].
    @AppStorage(PuffinFrameRecorder.enabledKey) private var puffinCapture = false

    /// Opt-in WHOOP 5/MG "R22" deep-data unlock (off by default) — the one probe that writes a
    /// persistent feature flag to the strap. See [PuffinExperiment.deepDataKey]. (#174)
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false

    /// #174: set when the deep-data switch is turned OFF, so the app can OFFER to clear the flags on the
    /// strap instead of silently leaving them set. The switch alone has never written anything in either
    /// direction — it gates sends — so turning it off used to change nothing on the hardware while reading
    /// like an undo. Asking is the right shape rather than writing automatically: the strap may not be
    /// connected, and a write to bonded hardware is not something a toggle should do unannounced.
    @State private var confirmingDeepDataDisable = false

    /// Opt-in "Broadcast heart rate" (off by default) — makes the strap advertise its HR as a standard
    /// BLE sensor for Garmin/Zwift/gym kit. See [PuffinExperiment.broadcastHrKey]. (#181)
    @AppStorage(PuffinExperiment.broadcastHrKey) private var broadcastHrEnabled = false

    /// #891 opt-in: writes the device-config key `enable_raw_data_w_ecg` on an attested WHOOP MG. A
    /// persistent strap write, so it gets its own deliberate switch like #174 and #181.
    /// See [PuffinExperiment.ecgRawDataKey].
    @AppStorage(PuffinExperiment.ecgRawDataKey) private var ecgRawDataEnabled = false

    /// #103 opt-in: surfaces the WHOOP 5/MG `spo2_candidate_82` nightly mean in the Blood Oxygen tile
    /// as a "strap estimate (unverified)" fallback when no calibrated `spo2Pct` exists. Display-only —
    /// writes nothing to the strap. See [PuffinExperiment.spo2CandidateDisplayKey].
    @AppStorage(PuffinExperiment.spo2CandidateDisplayKey) private var spo2CandidateDisplayEnabled = false

    /// True when the connected strap has positively attested itself a WHOOP MG. The variant is published as
    /// its label string (`LiveState.whoop5Variant`); "MG" is `Whoop5Variant.mg.label`. nil / not-yet-
    /// identified / a plain 5.0 is not an MG.
    private var ecgVariantIsMG: Bool { live.whoop5Variant == Whoop5Variant.mg.label }

    /// The #891 ECG-gate buttons need the same encrypted bond the R22 writes do (a config write over the
    /// live-HR-only link silently fails, #269) AND a strap that has positively attested itself an MG. Not
    /// wear-gated: this stores a value, it does not start an on-wrist stream.
    private var ecgGateReady: Bool {
        #if os(macOS)
        return false
        #else
        return live.encryptedBond && ecgVariantIsMG
        #endif
    }

    /// The reason line under the #891 buttons. Each case names the ONE thing that is missing.
    private var ecgGateReason: String {
        #if os(macOS)
        return String(localized: "The ECG gate needs an iPhone or Android. A Mac can't form the encrypted bond a 5/MG requires.")
        #else
        if !live.encryptedBond {
            return String(localized: "Needs the full encrypted bond: close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry a config write).")
        }
        if !ecgVariantIsMG {
            // A nil / non-MG variant lands here too, and deliberately: an unattested strap is not an MG.
            return String(localized: "Waiting for your strap to identify itself as an MG. Only a WHOOP MG has ECG electrodes, so NOOP won't write this key to anything else.")
        }
        return String(localized: "One tap writes the key; NOOP then reads it back off the strap and reports the value it actually stores — the write's own \"success\" is not treated as proof.")
        #endif
    }

    /// Icon per read-back verdict. Only a confirmed read-back gets the success mark.
    private func ecgGateIcon(_ v: EcgRawDataGateReport.Verdict) -> String {
        switch v {
        case .confirmed: return "checkmark.seal.fill"
        case .unchanged: return "xmark.seal.fill"
        case .pending:   return "ellipsis"
        default:         return "questionmark.circle"
        }
    }

    /// Tint per read-back verdict. Anything that isn't a confirmed read-back is never shown as positive.
    private func ecgGateTint(_ v: EcgRawDataGateReport.Verdict) -> Color {
        switch v {
        case .confirmed: return StrandPalette.statusPositive
        case .unchanged: return StrandPalette.statusWarning
        default:         return StrandPalette.textSecondary
        }
    }

    /// WHOOP MG ECG ("Labrador") experiment. Unlocks the gated, user-initiated ECG probe on the Devices
    /// card. Default off; with it off the four ECG opcodes are dropped by the command allowlist, so no
    /// ECG byte can reach a strap. See [PuffinExperiment.ecgKey].
    @AppStorage(PuffinExperiment.ecgKey) private var ecgEnabled = false

    /// Opt-in "Continuous HRV capture" (off by default) — holds the dense realtime stream armed 24/7 so
    /// the strap banks beat-to-beat R-R for better overnight HRV/recovery/sleep, at a battery cost.
    /// See [PuffinExperiment.keepRealtimeForDataKey].
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false

    /// #927 "Overnight only" refinement of Continuous HRV capture (off by default): arm the stream only
    /// inside the nightly quiet-hours window instead of 24/7. Composed with the base toggle (base on +
    /// this off = ALWAYS, the pre-#927 behaviour); existing installs are pinned to OFF by
    /// `PuffinExperiment.migrateContinuousHrvOvernightDefault()` at launch, so they still see no change.
    ///
    /// The `@AppStorage` default MUST match `PuffinExperiment.continuousHrvOvernightOnlyEnabled` (#1008).
    /// They read the same key by different routes, so a mismatch shows the toggle OFF on a fresh install
    /// while capture is actually overnight-only — and a user "correcting" that would write an explicit
    /// false and get the 24/7 behaviour they were trying to avoid.
    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey) private var continuousHrvOvernightOnly = true

    // #477 Power saving (parity with Android). Battery-adaptive sync cadence + an HRV-pause sub-option.
    @AppStorage(PuffinExperiment.powerSavingKey) private var powerSavingEnabled = false
    @AppStorage(PuffinExperiment.powerSavingBatteryPctKey) private var powerSavingPct = 20
    /// Stored INVERTED so the default (absent = false) reads as "HRV pause on". The toggle shows `!this`.
    @AppStorage(PuffinExperiment.pauseHrvDisabledKey) private var pauseHrvDisabled = false

    /// "Experimental sleep staging (V2)" (ON by default, promoted after the 44-subject cross-subject
    /// benchmark). When on, detected nights are re-staged with `SleepStagerV2` (the transparent
    /// cardiorespiratory recipe) instead of the older V1 stager. Read at the staging call site in
    /// `Repository`. See [PuffinExperiment.experimentalSleepV2Key].
    @AppStorage(PuffinExperiment.experimentalSleepV2Key) private var experimentalSleepV2Enabled = true

    /// "Motion-aware wake refinement" (#364 follow-up, OFF by default). A post-pass over the already-staged
    /// hypnogram: reclassifies a scored WAKE segment to `light` when its per-minute step-tick cadence shows
    /// no locomotion and its per-minute gravity posture is stable outside a minority of isolated burst
    /// minutes. Self-gates on OBSERVED gravity + step density (#345) — a no-op on a sparse night (e.g.
    /// WHOOP 4.0) regardless of this switch. See [PuffinExperiment.motionAwareWakeKey].
    @AppStorage(PuffinExperiment.motionAwareWakeKey) private var motionAwareWakeEnabled = false

    // Imperial/Metric display preference (D#103). Stored data is always SI; this only changes how
    // distances/weights/heights/temperatures are SHOWN — and lets the profile fields below take
    // imperial entry. Temperature has a separate override so °C/°F can be picked independently.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    // Effort display scale (#268). Display-only — Effort stays stored 0–100, this only chooses whether
    // it's shown on NOOP's 0–100 axis or WHOOP's 0–21 Day Strain axis.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.trendChartStyleKey) private var trendChartStyleRaw = TrendChartStyle.line.rawValue
    @AppStorage(UnitPrefs.hrvWindowKey) private var hrvWindowRaw = HrvWindow.whole.rawValue
    // Live-HR Live Activity (Lock Screen + Dynamic Island), iOS only (#336). Default on.
    @AppStorage(UnitPrefs.liveActivityKey) private var liveActivityEnabled = true
    // Alternate app icon (iOS only) — false = Titanium (primary AppIcon), true = Blue Titanium
    // ("AppIcon-Navy"). Display-only preference; the live switch goes through setAlternateIconName.
    @AppStorage("appIcon.alt") private var useNavyIcon = false
    // Light/Dark/System theme. Read by both app roots' .preferredColorScheme; default follows the OS.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    // App-owned copy language. Apple binds a bundle localization at process launch, so this writes the
    // standard AppleLanguages override and takes effect after the user reopens NOOP.
    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.system.rawValue
    // Chart colour style: Titanium (brand) or Classic (throwback red→green). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue
    // Sleep tab stage-CHART shape: Classic per-stage rows, or the WHOOP-style stepped hypnogram Filled/Ribbon.
    @AppStorage(SleepChartStyle.storageKey) private var sleepChartStyleRaw = SleepChartStyle.classic.rawValue
    // Chrome accent colour (mint / WHOOP blue / custom). Chrome only — never the data colour worlds.
    @AppStorage(AccentColor.storageKey) private var accentRaw = AccentColor.mint.rawValue
    @AppStorage(AccentColor.customHexKey) private var accentCustomHex = AccentColor.defaultCustomHex
    // Day-cycle scene backdrop behind Today (#698). Default ON. Off swaps the scene for a plain dark
    // canvas. TodayView reads the same key to gate its SceneScreenBackground.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    // "Sky behind cards" (default ON): extend the day-cycle sky behind the whole Today scroll so
    // Card transparency reveals it under every card. User-toggleable below. Mirrors Kotlin NoopPrefs.skyBehindCards.
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    // Card-surface opacity percent (100 = solid). Reactive — moving the slider live-updates every card.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    // "Reduce motion in NOOP" (default OFF): pose every looping animation still and stop the decorative
    // tilt sensor, without needing system Low Power Mode or system Reduce Motion. Apple-only so far —
    // Android has no such toggle yet and its gate reads two signals, not three (#941).
    @AppStorage(QuietMotionPrefs.enabledKey) private var quietMotion = false
    // Hydration tracker (opt-in, MVP). Default OFF — when off the hydration dashboard card + detail are
    // hidden. Mirrors the Android pref so the toggle reads the same on both platforms.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false

    /// Opt-in "Auto-detect workouts" (default OFF). When ON, Today scans the last day or two of HR for a
    /// sustained-elevated window and offers — via a single dismissible card — to save it as a workout.
    /// Nothing is ever created automatically. Mirrors the Android `NoopPrefs.KEY_AUTO_DETECT_WORKOUTS`.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectWorkoutsEnabled = false

    /// "Journal reminder" (#627, default ON). When ON, Today shows the persistent journal widget
    /// (last-7-days strip + tap-through). Mirrors the Android `NoopPrefs.KEY_JOURNAL_REMINDER_ENABLED`.
    @AppStorage(PuffinExperiment.journalReminderKey) private var journalReminderEnabled = true

    /// Opt-in "Keep screen on during a workout" (default OFF, #703). When ON, the live-workout view
    /// holds the screen awake while a manual recording is running so you can glance at your live HR
    /// without the device dimming. The live-workout view reads this same key. The string is shared
    /// verbatim with the Android twin (SharedPreferences "workoutKeepScreenOn").
    @AppStorage("workoutKeepScreenOn") private var workoutKeepScreenOn = false

    /// The strap model the user last picked (same key the scan pickers write). Gates the WHOOP 4.0-only
    /// rename control in the strap card — renaming uses the Harvard command set, which a 5/MG doesn't share.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    /// Draft text for the strap-rename field (strap card). Empty placeholder; never pre-seeded so the
    /// current name stays visible separately above it.
    @State private var strapNameDraft = ""

    /// Whether to surface the WHOOP 5/MG-only probes (puffin/R22/broadcast-HR/frame-capture). Gated so a
    /// confident 4.0 owner never sees 5/MG controls that can't touch their strap (#22). The model
    /// preference DEFAULTS to whoop4, so we deliberately do NOT hide on the raw default alone — the same
    /// `"selectedWhoopModel"` key is rewritten to the family that actually advertised when a strap
    /// connects (BLEManager, PR#195), so a real 5/MG owner who never opened the model picker still flips
    /// this true the moment their strap is discovered. We hide the 5/MG block only when the user is
    /// confidently on a 4.0 (pref says whoop4 AND nothing 5/MG is connected). The always-on raw-CSV
    /// diagnostic stays visible on every model regardless.
    private var showFiveMGControls: Bool {
        selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue
    }

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    /// Raw-sensor CSV export (experimental diagnostic, #308/#276/#322). Holds the last-written file so
    /// macOS can "Reveal in Finder" after a share, mirroring the puffin-capture export.
    @State private var rawCsvBusy = false
    @State private var lastRawCsvURL: URL?

    /// #646/#651: the "Export raw + log" button's zip build now runs off the main actor, so a second tap
    /// mid-export would fire a second `exportPair` — two staged zips, two save panels / stacked share
    /// sheets (see the `present(activityItems:)` #455 comment). Same disable-while-busy guard as
    /// `rawCsvBusy` above.
    @State private var rawAndLogBusy = false

    /// Passive WHOOP 5/MG optical experiment: the picker writes local timestamp markers into the
    /// durable deep-buffer JSONL. It never calls a BLE write path.
    @State private var showOpticalPhasePicker = false
    @State private var opticalPhaseStatus = ""

    /// Confirm gate for the "Recalibrate Charge baseline" action (it re-learns the HRV anchor from tonight).
    @State private var showRecalibrateConfirm = false

    /// "What's New" changelog sheet, reachable any time from About.
    @State private var showWhatsNew = false

    /// "How your scores work" explainer sheet, reachable any time from About.
    @State private var showScoringGuide = false

    /// "How NOOP works" primer sheet (the four-section explainability primer), reachable any
    /// time from About — covers how sleep is sorted, how scores + calibration work, what
    /// recording means, and where the provenance badges come from.
    @State private var showHowNoopWorks = false

    /// "Set up Apple Watch" sheet: the honest watch onboarding flow (what it's great at, where
    /// it's lighter, then the Health permission request). Presented from the About page's primary
    /// action. iOS does the real HealthKit request; macOS reads as an iPhone-only step.
    @State private var showAppleWatchSetup = false

    /// Steps-estimate calibration sheet (WHOOP 4.0). Reached from the Profile card's "Steps estimate"
    /// tap-through; explains the estimate, shows the current fit + a recent estimated-vs-phone table,
    /// and offers a manual coefficient override. See [StepsCalibrationSheet].
    @State private var showStepsCalibration = false

    /// iOS environment-diagnostics sheet (device, iOS+build, Data Protection, background refresh,
    /// low-power, sideload + cert expiry). iOS-only; the macOS strap log already carries OS + version.
    @State private var showDiagnostics = false

    /// User-initiated GitHub release check behind the About "Check for updates" button.
    @StateObject private var updateChecker = UpdateChecker()
    @Environment(\.openURL) private var openURL

    /// Whether the "Advanced" disclosure (Recovery, Test Centre, experimental probes, Backup &
    /// restore) is expanded. Default FALSE so a first-run user lands on the handful of everyday
    /// sections (profile, units, appearance, strap, features) instead of the full wall of 11 cards
    /// (S3). Nothing is removed; every section below stays one tap away by expanding this group.
    /// Persisted so it remembers the user's choice; mirrors the Android `noop.settingsAdvancedOpen` key.
    @AppStorage(SettingsDisclosureDefaults.advancedOpenKey) private var advancedOpen = SettingsDisclosureDefaults.advancedOpenDefault

    var body: some View {
        ScreenScaffold(title: "Settings",
                       subtitle: "Your numbers, your strap, and how NOOP works. All on \(Platform.deviceNounPhrase).",
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends / Devices:
                       // a fixed, full-bleed time-of-day sky behind the scroll content (it does not scroll).
                       // Settings' own frosted cards sit on the dark canvas below the sky band, unchanged.
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                // Everyday sections stay expanded (S3): the ones a first-run user actually needs.
                profileCard.staggeredAppear(index: 0)
                unitsCard.staggeredAppear(index: 1)
                appearanceCard.staggeredAppear(index: 2)
                strapCard.staggeredAppear(index: 3)
                powerSavingCard.staggeredAppear(index: 4)
                streakCard.staggeredAppear(index: 5)
                featuresCard.staggeredAppear(index: 6)

                // Lower-frequency sections collapse behind a single default-closed disclosure so the
                // screen opens at ~6 sections instead of 11. Nothing is removed; every section here
                // (Recovery / advanced scoring, Test Centre, the experimental probes + raw-capture, and
                // Backup & restore) stays one tap away. Modelled on the Test Centre "Advanced" group.
                SettingsDisclosureGroup(
                    title: "Advanced",
                    subtitle: "Recovery, Test Centre, experimental probes, and backup. Tucked away to keep the everyday screen tidy.",
                    isExpanded: $advancedOpen
                ) {
                    recoveryCard
                    testCentreCard
                    experimentalCard
                    backupCard
                }
                .staggeredAppear(index: 6)

                // About stays expanded at the foot (version, links and the help sheets people return to).
                aboutCard.staggeredAppear(index: 7)
            }
        }
        .alert(backupAlertTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupAlertMessage)
        }
        .confirmationDialog("Recalibrate your Charge baseline?",
                            isPresented: $showRecalibrateConfirm, titleVisibility: .visible) {
            Button("Recalibrate") { recalibrateHrvBaseline() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restarts the roughly 4-night build-up for Charge and your HRV baseline. Your history stays. Use it if a bad first week, like wearing it while sick, set your baseline off.")
        }
        // #174: the switch going OFF is the moment to offer the undo. Declining leaves the flags set and
        // says so — which is still an improvement on the old behaviour, where the same tap silently left
        // them set with no indication either way.
        .confirmationDialog("Clear the R22 flags on your strap?",
                            isPresented: $confirmingDeepDataDisable, titleVisibility: .visible) {
            Button("Clear flags on strap") { model.ble.disableWhoop5DeepData() }
            Button("Just stop sending", role: .cancel) { }
        } message: {
            Text("Turning this switch off only stops NOOP sending the unlock. The flags it already wrote stay on the strap until something clears them. NOOP can write the off value to all 16 now and read each one back so you can see what the strap actually stores. Needs the strap connected and bonded.")
        }
        .confirmationDialog("Mark optical experiment phase",
                            isPresented: $showOpticalPhasePicker, titleVisibility: .visible) {
            ForEach(PuffinOpticalExperimentPhase.allCases, id: \.self) { phase in
                Button(phase.displayName) { markOpticalPhase(phase) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A marker starts the selected phase and ends the previous one. This only timestamps the local capture file; it sends nothing to the strap.")
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: { showWhatsNew = false })
        }
        .sheet(isPresented: $showScoringGuide) {
            ScoringGuideView(onClose: { showScoringGuide = false })
        }
        .sheet(isPresented: $showHowNoopWorks) {
            HowNoopWorksView(onClose: { showHowNoopWorks = false })
        }
        .sheet(isPresented: $showAppleWatchSetup) {
            AppleWatchSetupView(onClose: { showAppleWatchSetup = false })
        }
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: model.repo, onClose: { showStepsCalibration = false })
                .environmentObject(profile)
        }
        #if os(iOS)
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(onClose: { showDiagnostics = false })
        }
        #endif
    }

    // MARK: - Profile

    private var profileCard: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            blurb: "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate."
        ) {
            VStack(spacing: 0) {
                profilePhotoRow
                rowDivider
                FormRow(label: "Date of birth") {
                    HStack(spacing: 12) {
                        Text("\(profile.age)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 28, alignment: .trailing)
                        // #146: age is derived from the date of birth, so it advances on its own.
                        DatePicker("Date of birth",
                                   selection: $profile.dateOfBirth,
                                   in: ProfileStore.dateOfBirthRange,
                                   displayedComponents: .date)
                            .labelsHidden()
                            .tint(StrandPalette.accent)
                            .accessibilityLabel("Date of birth, age \(profile.age) years")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                        Text("Non-binary").tag("nonbinary")
                    }
                    .labelsHidden()
                    // #43: .menu, not .segmented + .fixedSize(). In FormRow's label(∞)+control HStack a
                    // segmented picker collapses WITHOUT .fixedSize() but OVERFLOWS the screen WITH it once
                    // the labels are long (German "Nicht-binär") or Text Size is enlarged — the oversized
                    // Settings screen users reported. A menu is a compact button that fits any label length.
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Sex")
                }
                rowDivider
                FormRow(label: "Weight") {
                    // Imperial mode steps in pounds and stores the kg equivalent; metric steps in kg.
                    if unitSystem == .imperial {
                        poundsField(weightKg: $profile.weightKg)
                    } else {
                        measureField(value: $profile.weightKg, unit: "kg",
                                     range: 30...250, step: 0.5, format: "%.1f",
                                     accessibility: String(localized: "Weight in kilograms"))
                    }
                }
                rowDivider
                FormRow(label: "Height") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        feetInchesField(heightCm: $profile.heightCm)
                    } else {
                        measureField(value: $profile.heightCm, unit: "cm",
                                     range: 120...230, step: 1, format: "%.0f",
                                     accessibility: String(localized: "Height in centimetres"))
                    }
                }
                rowDivider
                // Waist (optional). Unlike the rows above it, an empty waist is valid (0 = unset) —
                // it's the ONE measurement that ADDS the VO₂max estimate alongside Fitness Age. It does
                // NOT sharpen the Fitness Age itself (the body term cancels in the Nes model), so it sits
                // apart with an honest "adds your VO₂max estimate" note rather than implying it tunes the age.
                FormRow(label: "Waist (optional)") {
                    // Imperial mode steps in whole inches and stores the cm equivalent; metric steps in cm.
                    if unitSystem == .imperial {
                        waistInchesField(waistCm: $profile.waistCm)
                    } else {
                        waistCentimetresField(waistCm: $profile.waistCm)
                    }
                }
                Text("Optional: adds your VO₂max estimate. The Fitness Age itself doesn't need it. Measure around your middle, at the navel.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        hrMaxField
                        Text(profile.hrMaxOverride > 0
                             ? "Manual override"
                             : "Auto · \(profile.hrMax) bpm (Tanaka)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(profile.hrMaxOverride > 0
                                             ? StrandPalette.accent
                                             : StrandPalette.textTertiary)
                    }
                }
                rowDivider
                // Custom HR zones (#531, @kavemang): replace the conventional %HRmax bands with five
                // personalized inclusive BPM lower bounds. Off = the effective set stays conventional.
                FormRow(label: "Custom HR zones") {
                    Toggle("Custom HR zones", isOn: Binding(
                        get: { profile.hasCustomHRZones },
                        set: { profile.setCustomHRZonesEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Custom HR zones")
                }
                if profile.hasCustomHRZones {
                    Text("Set the BPM where each zone begins. Turn off to restore the default percentage-of-max zones.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(profile.hrZoneThresholds.indices, id: \.self) { index in
                        rowDivider
                        FormRow(label: "Zone \(index + 1) starts") {
                            hrZoneThresholdField(index: index)
                        }
                    }
                }
                rowDivider
                // Step calibration (#139/#132): daily steps = @57 counter ticks ÷ this divisor.
                // 1.0 = raw pass-through until the true 5/MG tick rate is known. The divisor goes
                // up to 30 because a 5/MG motion counter can overcount by ~24×; the stepper uses a
                // variable increment (fine near 1.0, coarse up top) so high values stay reachable.
                FormRow(label: "Step calibration") {
                    HStack(spacing: 10) {
                        Text(String(format: "%.1f", profile.stepTicksPerStep))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 44, alignment: .trailing)
                        Stepper("Step calibration") {
                            profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: true)
                        } onDecrement: {
                            profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: false)
                        }
                            .labelsHidden()
                            .accessibilityLabel("Step calibration, \(String(format: "%.1f", profile.stepTicksPerStep)) counter ticks per step")
                    }
                }
                Text("Counter ticks per step. Leave at 1.0 unless your steps run high. On a WHOOP 5/MG they can run very high (10× or more), so this goes up to 30. Walk a known 1,000 steps and divide NOOP's count by the real count to get your value.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                rowDivider
                // Tap-through to the WHOOP 4.0 steps-ESTIMATE calibration (a SEPARATE thing from the
                // 5/MG @57 counter divisor above): a 4.0 sends no step count, so NOOP estimates steps
                // from motion and calibrates that to the phone. The sheet explains it, shows the fit +
                // a recent estimated-vs-phone comparison, and offers a manual coefficient.
                Button {
                    showStepsCalibration = true
                } label: {
                    FormRow(label: "Steps estimate") {
                        HStack(spacing: 8) {
                            Text(stepsCalibrationSummary)
                                .font(StrandFont.footnote)
                                .foregroundStyle(profile.stepsManualCoefficient > 0
                                                 ? StrandPalette.accent : StrandPalette.textTertiary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel("Steps estimate calibration. \(stepsCalibrationSummary). Opens the calibration screen.")
                Text("For a WHOOP 4.0, which sends no step count: NOOP estimates steps from motion, calibrated to your phone. Tap to see how close it is and adjust it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Compact profile-photo control kept inside the Profile card so the optional avatar does not
    /// consume a second top-level settings section. PhotosUI works on both supported platforms.
    private var profilePhotoRow: some View {
        let hasAvatar = profile.hasAvatar
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space3) {
                ProfileAvatarView(
                    imageData: profile.avatarImageData,
                    size: NoopMetrics.profileAvatarDiameter
                )
                    .accessibilityLabel(hasAvatar ? "Your profile photo" : "No profile photo set")

                PhotosPicker(selection: $avatarPickerItem, matching: .images) {
                    Text(hasAvatar ? "Change photo" : "Choose photo")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))

                if hasAvatar {
                    Button {
                        profile.clearAvatar()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(NoopButtonStyle(.tertiary))
                    .accessibilityLabel("Remove photo")
                    .accessibilityHint("Reverts to the default profile icon")
                }
            }

            Text("Optional. Add a photo for your avatar. It stays on \(Platform.deviceNounPhrase) and is never uploaded.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Load the picked photo's bytes, then hand them to the store (which downscales + persists).
        // Clearing the selection afterwards lets the user re-pick the same photo if they want.
        .onChange(of: avatarPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data { profile.setAvatar(data) }
                    avatarPickerItem = nil
                }
            }
        }
    }

    /// One recent-background preset: a small cropped thumbnail (accent-ringed when active) over its
    /// fill-mode label. Tapping re-applies that image + scaling.
    @ViewBuilder
    private func backgroundRecentThumb(thumb: Image?, mode: BackgroundFillMode, active: Bool,
                                       action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let thumb { thumb.resizable().scaledToFill() } else { StrandPalette.surfaceInset }
                }
                .frame(width: 64, height: 64)
                .clipShape(shape)
                .overlay(shape.strokeBorder(active ? StrandPalette.accent : StrandPalette.hairline,
                                            lineWidth: active ? 2 : 1))
                Text(mode.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(active ? StrandPalette.accent : StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Custom background image controls (#custom-background): pick from Photos or Browse the files,
    /// choose the fill mode, and (once set) enable / remove. The store downscales + persists a
    /// device-local file — nothing here is uploaded (NOOP is offline), and it is left out of `.noopbak`.
    /// Wrapped in a layout-transparent `Group` so the picker `onChange` + the file importer can hang off
    /// the whole cluster while it still flows inside the appearance VStack.
    @ViewBuilder
    private var backgroundImageControls: some View {
        let hasImage = backgroundStore.hasImage
        Group {
            HStack(spacing: NoopMetrics.space2) {
                PhotosPicker(selection: $backgroundPickerItem, matching: .images) {
                    Text(hasImage ? "Replace from Photos" : "Choose from Photos")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))

                Button {
                    showBackgroundFileImporter = true
                } label: {
                    Text("Browse files")
                }
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
            }

            if hasImage {
                // Recent presets: tap a thumbnail to re-apply that image + the scaling it was last shown
                // with. The first (accent-ringed) one is the active background.
                if !backgroundStore.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                        HStack(spacing: 10) {
                            ForEach(backgroundStore.recents.indices, id: \.self) { index in
                                backgroundRecentThumb(
                                    thumb: backgroundStore.thumbnails.indices.contains(index)
                                        ? backgroundStore.thumbnails[index] : nil,
                                    mode: backgroundStore.recents[index].fillMode,
                                    active: index == 0,
                                    action: { backgroundStore.applyRecent(index) })
                            }
                        }
                    }
                }

                Toggle(isOn: $backgroundStore.enabled) {
                    Text("Show custom background")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)

                FormRow(label: "Scaling") {
                    Picker("Scaling", selection: Binding(
                        get: { backgroundStore.fillMode },
                        set: { backgroundStore.setFillMode($0) })) {
                        ForEach(BackgroundFillMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Background scaling")
                }

                Button {
                    backgroundStore.clearImage()
                } label: {
                    Text("Remove image")
                }
                .buttonStyle(NoopButtonStyle(.tertiary))
                .accessibilityHint("Removes the custom background and restores the day-cycle sky")
            }

            Text("Optional. Use your own photo behind every tab, in place of the day-cycle sky. It stays on \(Platform.deviceNounPhrase) and is never uploaded. Pair it with Transparent cards above to let it show through.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Load the picked photo's bytes, hand them to the store (which downscales + persists), then clear
        // the selection so the same photo can be re-picked. Mirrors the avatar row.
        .onChange(of: backgroundPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data { backgroundStore.setImage(from: data) }
                    backgroundPickerItem = nil
                }
            }
        }
        // "Browse files" — the system file browser. The picked URL is security-scoped (outside the
        // sandbox), so bracket the one-time read; we copy the bytes into our own file immediately.
        .fileImporter(isPresented: $showBackgroundFileImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { backgroundStore.setImage(from: data) }
        }
    }

    /// One-line state for the "Steps estimate" tap-through row: manual, the auto-fit confidence, or a
    /// not-yet-calibrated prompt — so the row reflects the current calibration without opening the sheet.
    private var stepsCalibrationSummary: String {
        if profile.stepsManualCoefficient > 0 { return String(localized: "Manual") }
        if profile.stepsCalibrationCoefficient > 0 {
            return String(localized: "Auto · \(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) confidence")
        }
        return String(localized: "Not calibrated")
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    private func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(String(format: format, value.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
        }
        .fixedSize()
    }

    /// Imperial weight entry: shows pounds, steps in 1-lb increments, and writes the kg equivalent back
    /// to the SI-stored profile. Range mirrors the metric 30…250 kg (≈66…551 lb).
    private func poundsField(weightKg: Binding<Double>) -> some View {
        let lb = Binding<Double>(
            get: { UnitFormatter.kgToPounds(weightKg.wrappedValue) },
            set: { weightKg.wrappedValue = $0 / UnitFormatter.poundsPerKilogram }
        )
        return HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(String(format: "%.0f", lb.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text("lb")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            Stepper("Weight in pounds", value: lb, in: 66...551, step: 1)
                .labelsHidden()
                .accessibilityLabel("Weight, \(Int(lb.wrappedValue.rounded())) pounds")
        }
        .fixedSize()
    }

    /// Imperial height entry: shows feet′ inches″, steps in whole inches, and writes the cm equivalent
    /// back to the SI-stored profile. Range mirrors the metric 120…230 cm (≈47…91 in).
    private func feetInchesField(heightCm: Binding<Double>) -> some View {
        let inches = Binding<Double>(
            get: { UnitFormatter.cmToInches(heightCm.wrappedValue).rounded() },
            set: { heightCm.wrappedValue = $0 * UnitFormatter.centimetersPerInch }
        )
        let parts = UnitFormatter.cmToFeetInches(heightCm.wrappedValue)
        return HStack(spacing: NoopMetrics.space2) {
            Text("\(parts.feet)′ \(parts.inches)″")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: NoopMetrics.formWideValueColumnWidth, alignment: .center)
            Stepper("Height in inches", value: inches, in: 47...91, step: 1)
                .labelsHidden()
                .accessibilityLabel("Height, \(parts.feet) feet \(parts.inches) inches")
        }
        .fixedSize()
    }

    /// Metric waist entry: 0 = unset (shows a muted "Not set" rather than a misleading 0 cm). Steps in
    /// 1-cm increments; the first increment from unset lands at a sensible 80 cm so the stepper doesn't
    /// crawl up from the range floor. Mirrors `measureField` but tolerant of the optional empty state.
    private func waistCentimetresField(waistCm: Binding<Double>) -> some View {
        let set = waistCm.wrappedValue > 0
        return HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(set ? String(format: "%.0f", waistCm.wrappedValue) : String(localized: "Not set"))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: NoopMetrics.formValueColumnWidth, alignment: .center)
                if set {
                    Text("cm")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                }
            }
            .fixedSize()
            Stepper("Waist in centimetres") {
                waistCm.wrappedValue = min(160, (set ? waistCm.wrappedValue : 79) + 1)
            } onDecrement: {
                // Stepping below the 60-cm floor clears it back to unset (optional).
                let next = waistCm.wrappedValue - 1
                waistCm.wrappedValue = next < 60 ? 0 : next
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(waistCm.wrappedValue.rounded())) centimetres" : "Waist not set")
        }
        .fixedSize()
    }

    /// Imperial waist entry: 0 = unset (muted "Not set"); otherwise shows whole inches and stores the cm
    /// equivalent — the same metric/imperial treatment as Height. First increment from unset lands near a
    /// sensible 31″. Range mirrors the metric 60…160 cm (≈24…63 in).
    private func waistInchesField(waistCm: Binding<Double>) -> some View {
        let set = waistCm.wrappedValue > 0
        let inches = set ? UnitFormatter.cmToInches(waistCm.wrappedValue).rounded() : 0
        return HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(set ? "\(Int(inches))" : "Not set")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(set ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(minWidth: NoopMetrics.formValueColumnWidth, alignment: .center)
                if set {
                    Text("in")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                }
            }
            .fixedSize()
            Stepper("Waist in inches") {
                let nextIn = (set ? inches : 30) + 1
                waistCm.wrappedValue = min(160, nextIn * UnitFormatter.centimetersPerInch)
            } onDecrement: {
                let nextIn = inches - 1
                // Stepping below the ~24″ floor clears it back to unset (optional).
                waistCm.wrappedValue = nextIn < 24 ? 0 : nextIn * UnitFormatter.centimetersPerInch
            }
                .labelsHidden()
                .accessibilityLabel(set ? "Waist, \(Int(inches)) inches" : "Waist not set")
        }
        .fixedSize()
    }

    /// HR-max override: 0 = auto. Shown as a compact tabular value with a stepper.
    private var hrMaxField: some View {
        HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "Auto")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(profile.hrMaxOverride > 0
                                     ? StrandPalette.textPrimary
                                     : StrandPalette.textTertiary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text("bpm")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            Stepper("Max heart rate override",
                    value: $profile.hrMaxOverride, in: 0...230, step: 1)
                .labelsHidden()
                .accessibilityLabel("Max heart rate override, \(profile.hrMaxOverride == 0 ? "automatic" : "\(profile.hrMaxOverride) bpm")")
        }
        .fixedSize()
    }

    /// One personalized zone lower bound (bpm), stepped neighbour-aware (see `Profile.stepHRZoneThreshold`)
    /// so the five bounds stay strictly increasing. Mirrors `hrMaxField`'s compact value + stepper layout.
    private func hrZoneThresholdField(index: Int) -> some View {
        let value = profile.hrZoneThresholds.indices.contains(index) ? profile.hrZoneThresholds[index] : 0
        return HStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text("\(value)")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: NoopMetrics.formValueColumnWidth, alignment: .center)
                Text("bpm")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
            }
            .fixedSize()
            Stepper("",
                    onIncrement: { profile.stepHRZoneThreshold(at: index, up: true) },
                    onDecrement: { profile.stepHRZoneThreshold(at: index, up: false) })
                .labelsHidden()
                .accessibilityLabel("Zone \(index + 1) starts at \(value) beats per minute")
        }
        .fixedSize()
    }

    // MARK: - Units

    /// Imperial/Metric display toggle + a separate temperature override. Display-only — nothing stored
    /// changes, NOOP keeps everything in SI and converts at the point of display.
    private var unitsCard: some View {
        SettingsSection(
            icon: "ruler",
            title: "Units",
            blurb: "Choose how distances, weights, heights, temperatures and Effort are shown. Your data is always stored the same way. This only changes the display."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Measurement system") {
                    Picker("Measurement system", selection: $unitSystemRaw) {
                        Text("Metric").tag(UnitSystem.metric.rawValue)
                        Text("Imperial").tag(UnitSystem.imperial.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Measurement system")
                }
                rowDivider
                FormRow(label: "Temperature") {
                    // Three-way: "Match" follows the system above; °C / °F pin it explicitly. Stored as
                    // an empty string ("match") or the TemperatureUnit raw value.
                    Picker("Temperature", selection: $temperatureRaw) {
                        Text("Match").tag("")
                        Text("°C").tag(TemperatureUnit.celsius.rawValue)
                        Text("°F").tag(TemperatureUnit.fahrenheit.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Temperature unit")
                }
                rowDivider
                // Effort scale (#268) — show NOOP's native 0–100 Effort or WHOOP's 0–21 Day Strain axis.
                // Display-only; the stored value never changes, so a flip just re-labels every Effort read-out.
                FormRow(label: "Effort scale") {
                    Picker("Effort scale", selection: $effortScaleRaw) {
                        Text("0-100").tag(EffortScale.hundred.rawValue)
                        Text("0-21").tag(EffortScale.whoop.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Effort scale")
                }
            }
        }
    }

    // MARK: - Appearance (Theme everywhere; alternate app icon iOS-only)

    /// Theme (System / Light / Dark) on every platform, plus the iOS app-icon choice. The Theme picker
    /// writes `AppearanceMode.storageKey`, which both app roots read via `.preferredColorScheme`; because
    /// every palette token is a dynamic `Color(light:dark:)`, the whole UI re-resolves on change.
    /// Day streak (#569): consecutive days with a Charge score, computed on-device from the merged
    /// daily metrics. A day qualifies when its `DailyMetric` has a `recovery` value. The math is the
    /// pure `StreakCalculator` (Swift/Kotlin twin).
    private var streakCard: some View {
        let days = model.repo.days
        let today = AnalyticsEngine.dayString(Int(Date().timeIntervalSince1970),
                                              offsetSec: TimeZone.current.secondsFromGMT())
        let s = StreakCalculator.streaks(dayKeys: days.map { $0.day },
                                         qualified: days.map { $0.recovery != nil },
                                         today: today)
        return NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Streak").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(s.current)")
                        .font(StrandFont.number(30))
                        .foregroundStyle(StrandPalette.accent)
                    Text(s.current == 1 ? "day in a row" : "days in a row")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(s.longest == 1 ? "Longest: 1 day" : "Longest: \(s.longest) days")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    /// Bridges the SwiftUI `ColorPicker` (a `Color`) to the persisted custom-accent hex string.
    private var customAccentBinding: Binding<Color> {
        Binding(
            get: { Color(hex: accentCustomHex) },
            set: { accentCustomHex = $0.noopAccentHex ?? AccentColor.defaultCustomHex }
        )
    }

    /// The Theme PRESET is derived from the four coordinated prefs (no stored value): reads which preset
    /// the live combination matches (or `.custom`), and on pick writes accent + chart + backdrop + opacity.
    private var themePresetBinding: Binding<ThemePreset> {
        Binding(
            get: {
                ThemePreset.matching(
                    accent: AccentColor.resolve(accentRaw),
                    chart: ChartStyle.resolve(chartStyleRaw),
                    backdrop: showDayCycleBackground,
                    cardOpacity: cardOpacityPercent)
            },
            set: { preset in
                guard let r = preset.recipe else { return }   // .custom → no-op
                accentRaw = r.accent.rawValue
                chartStyleRaw = r.chart.rawValue
                showDayCycleBackground = r.backdrop
                cardOpacityPercent = r.cardOpacity
            }
        )
    }

    private var appearanceCard: some View {
        SettingsSection(
            icon: "circle.lefthalf.filled",
            title: "Appearance",
            blurb: "Choose Light, Dark, or follow your system. Dark is the signature near-black; Light keeps the same clean look on a bright canvas."
        ) {
            VStack(spacing: 0) {
                // App-owned copy language. Apple binds a bundle localization at process launch, so this
                // takes effect after the user reopens NOOP (the note below says so). Sits above the theme
                // controls because it re-words everything under it.
                FormRow(label: "Language") {
                    Picker("Language", selection: $appLanguageRaw) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language == .system ? String(localized: "System default") : language.autonym)
                                .tag(language.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Language")
                    .onChangeCompat(of: appLanguageRaw) { AppLanguage.apply($0) }
                }
                Text("Language changes take effect after you reopen NOOP.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, NoopMetrics.space1)
                rowDivider
                // Theme presets — one-tap bundles coordinating accent + chart world + backdrop + card
                // opacity. Derived (no stored value): tweaking any control below flips this to Custom.
                FormRow(label: "Preset") {
                    Picker("Preset", selection: themePresetBinding) {
                        ForEach(ThemePreset.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Theme preset")
                }
                rowDivider
                FormRow(label: "Theme") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Theme")
                }
                rowDivider   // #79: the segmented rows sat flush against each other (missing separator)
                FormRow(label: "Chart colours") {
                    // Default = NOOP's clean metric ramps; Classic = the throwback red→amber→green
                    // readiness scale (cool→hot zones, green→red stress). Both schemes.
                    Picker("Chart colours", selection: $chartStyleRaw) {
                        ForEach(ChartStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Chart colours")
                }
                rowDivider
                FormRow(label: "Sleep chart") {
                    // Classic = the per-stage timeline rows (default). Filled/Ribbon = the WHOOP-style
                    // single stepped hypnogram, filled to the baseline or as a slim band. Display-only —
                    // same stages either way; falls back to Classic on a night with no timestamped segments.
                    Picker("Sleep chart", selection: $sleepChartStyleRaw) {
                        ForEach(SleepChartStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Sleep chart")
                }
                rowDivider
                // Chrome accent colour — the links/buttons/selection tint only. The recovery/strain/sleep
                // DATA colours follow "Chart colours" above, never this. Custom reveals a colour well.
                FormRow(label: "Accent") {
                    Picker("Accent", selection: $accentRaw) {
                        ForEach(AccentColor.allCases) { c in
                            Text(c.label).tag(c.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Accent colour")
                }
                if AccentColor.resolve(accentRaw) == .custom {
                    rowDivider
                    FormRow(label: "Custom colour") {
                        ColorPicker("Custom colour", selection: customAccentBinding, supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel("Custom accent colour")
                    }
                }
                rowDivider
                // Trend chart style (line vs bar). Display-only: flips the Trends tab's charts between the
                // gradient line + area and value-ramp bars. The plotted data is identical either way.
                FormRow(label: "Trend charts") {
                    Picker("Trend charts", selection: $trendChartStyleRaw) {
                        ForEach(TrendChartStyle.allCases) { style in
                            Text(style.label).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("Trend chart style")
                }
                #if os(iOS)
                rowDivider   // #79: separator before App icon (inside #if so macOS keeps a single divider)
                FormRow(label: "App icon") {
                    Picker("App icon", selection: $useNavyIcon) {
                        Text("Default").tag(false)
                        Text("Navy").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("App icon")
                    .onChangeCompat(of: useNavyIcon) { applyAppIcon($0) }
                }
                #endif

                rowDivider
                // MARK: Reduce motion in NOOP — pose every looping animation still and stop the tilt
                // sensor, WITHOUT requiring system Low Power Mode. Off by default; system Reduce Motion
                // and Low Power Mode already force the same behaviour, this is the third, in-app signal.
                Toggle(isOn: $quietMotion) {
                    Text("Reduce motion in NOOP")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Holds the liquid gauges, the sky and the tilt response still, and turns off the motion sensor that drives them. Saves battery. Low Power Mode and the system Reduce Motion setting already do this.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                rowDivider
                // MARK: Day-cycle background — the time-of-day scene behind Today (#698). On by default.
                // Off swaps it for the plain dark canvas for people who find the moving scene distracting.
                Toggle(isOn: $showDayCycleBackground) {
                    Text("Day-cycle background")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Shows a soft sunrise, day, dusk and night scene behind the Today screen. Turn it off for a plain dark canvas. Your cards stay exactly as readable.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // MARK: Sky behind cards — extend the day-cycle sky behind the WHOLE Today scroll so the
                // Card-transparency slider reveals it under every card (not just the hero). Opt-in, off by
                // default; pairs with Card transparency below.
                Toggle(isOn: $skyBehindCards) {
                    Text("Sky behind cards")
                        .font(StrandFont.subhead)
                        // Greyed when day-cycle is off — the sky it extends isn't drawn then (Android parity).
                        .foregroundStyle(showDayCycleBackground ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .disabled(!showDayCycleBackground)
                Text("Extends the sky behind the whole Today screen, so lowering Card transparency lets it show through every card. Needs the day-cycle background on.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // MARK: Transparent cards — a quick on/off over the SAME cardOpacityPercent (no separate
                // pref), so it stays in lock-step with the slider below. Off = solid (100%); on = a sensible
                // see-through default the slider then fine-tunes. Lets the custom background (or the sky)
                // show through the cards. `isOn` is derived from the opacity, so dragging to solid flips off.
                Toggle(isOn: Binding(
                    get: { cardOpacityPercent < 100 },
                    set: { on in cardOpacityPercent = on ? (cardOpacityPercent >= 100 ? 70 : cardOpacityPercent) : 100 }
                )) {
                    Text("Transparent cards")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Let the background show through every card. Tune how much just below.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // MARK: Card transparency — fade every frosted card's glass toward the background. Reactive
                // @AppStorage, so all cards (incl. the ones on this screen) update live as you drag. The
                // slider shows TRANSPARENCY (0 = solid, 100 = clear); we store the OPACITY percent.
                HStack {
                    Text("Card transparency")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("\(100 - cardOpacityPercent)%")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                }
                Slider(
                    value: Binding(
                        get: { Double(100 - cardOpacityPercent) },
                        set: { cardOpacityPercent = 100 - Int($0.rounded()) }
                    ),
                    in: 0...100, step: 1
                )
                .tint(StrandPalette.accent)
                Text("How see-through the cards (Heart Rate, Key Metrics, Recovery Vitals, …) are. Left = solid, right = clear.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                rowDivider
                backgroundImageControls
            }
        }
    }

    #if os(iOS)
    /// Apply the alternate-icon choice. Runs on the main actor (UIKit requirement) and tolerates the
    /// no-op cases (already-set, unsupported); on failure it surfaces the error and reverts the toggle
    /// so the control never disagrees with what's actually on the Home Screen.
    private func applyAppIcon(_ useNavy: Bool) {
        Task { @MainActor in
            let target = useNavy ? "AppIcon-Navy" : nil
            // No-op if iOS already shows the requested icon (avoids a needless system prompt).
            guard UIApplication.shared.supportsAlternateIcons,
                  UIApplication.shared.alternateIconName != target else { return }
            do {
                try await UIApplication.shared.setAlternateIconName(target)
            } catch {
                useNavyIcon = !useNavy
                backupAlertTitle = String(localized: "Couldn't change the app icon")
                backupAlertMessage = error.localizedDescription
                showBackupAlert = true
            }
        }
    }
    #endif

    // MARK: - Strap

    private var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Strap",
            blurb: "NOOP pairs directly with your WHOOP over Bluetooth: no WHOOP app, no cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatePill("\(strapStatusTitle)", tone: strapTone, pulsing: live.connected)
                    if let pct = live.batteryPct {
                        StatePill(live.charging == true
                                  ? "Battery \(Int(pct.rounded()))% · Charging"
                                  : "Battery \(Int(pct.rounded()))%",
                                  tone: batteryTone(pct), showsDot: false)
                    }
                    Spacer(minLength: 0)
                }
                Text(strapStatusDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Re-scan", systemImage: "arrow.clockwise", kind: .primary) {
                        model.scan()
                    }

                    NoopButton("Disconnect", systemImage: "xmark.circle", kind: .secondary) {
                        model.disconnect()
                    }
                    .disabled(!live.connected && !live.bonded)
                }

                rowDivider
                // MARK: Strap log — a Settings shortcut so people don't have to hunt for it on the Live
                // screen (#507: couldn't find it on Mac; #509: same on iPhone). Same text as the Live card.
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button("Copy") { PlatformPasteboard.copy(live.exportableLogText()) }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    Button("Save…") {
                        Task {
                            let extra = await DebugDataDiagnostics.dynamicLines(repo: model.repo)
                            FileExport.exportText(live.exportableLogText(extraHeaderLines: extra),
                                                  suggestedName: FileExport.timestampedName("noop-strap-log", ext: "txt"))
                        }
                    }
                    .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                }
                Text("Grab this when you report a bug. It tells me what the app saw. (The full live log is also on the Live screen.)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                // MARK: Continuous HRV capture — keep the dense beat-to-beat (R-R) stream armed 24/7.
                Toggle(isOn: $continuousHrvEnabled) {
                    Text("Continuous HRV capture")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: continuousHrvEnabled) { on in model.ble.setKeepRealtimeForData(on) }
                Text("Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery: your strap streams heart rate continuously while connected.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // #927 Overnight only: window-gate the continuous stream to the nightly quiet-hours
                // window. Re-pushing the UNCHANGED base preference just re-runs the BLE reconciler,
                // which re-derives the window gate and arms/disarms on the edge immediately.
                if continuousHrvEnabled {
                    Toggle(isOn: $continuousHrvOvernightOnly) {
                        Text("Overnight only")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)
                    .onChangeCompat(of: continuousHrvOvernightOnly) { _ in
                        model.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
                    }
                    Text("Runs the continuous HRV stream only during your quiet hours window (22:00–07:00 by default), roughly halving the battery cost. Daytime Stress readings will be sparser. Note: continuous background HRV capture (including daytime naps) is paused outside this window. For on-demand daytime HRV readings (including naps), use the \"Take an HRV reading\" button on the Live screen.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // HRV window (#141) — grouped with the other HRV settings (#155). Whole night (NOOP's
                // long-standing value) or DEEP sleep only (WHOOP-style, reads lower and more comparable to
                // WHOOP/Polar). Unlike the Effort scale this CHANGES the number, so a switch re-scores +
                // re-baselines (like a sleep edit).
                FormRow(label: "HRV window") {
                    Picker("HRV window", selection: $hrvWindowRaw) {
                        // #153: "Night" (not "Whole night") — a single short word so the two-segment
                        // control doesn't truncate once it sizes to the row (some locales' longer
                        // translations overflowed), matching the Temperature/Theme pickers above.
                        Text("Night").tag(HrvWindow.whole.rawValue)
                        Text("Deep sleep").tag(HrvWindow.deep.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel("HRV window")
                    .onChangeCompat(of: hrvWindowRaw) { _ in
                        // #201: the new window shifts every night's avgHrv, so the HRV baseline must reflect it
                        // too — but a plain re-score already achieves that. analyzeRecent re-scores the recent
                        // ~21 nights' avgHrv under the new window AND re-folds the HRV baseline from them in the
                        // same pass, and the baseline's 14-night-half-life EWMA is dominated by that fresh
                        // re-scored tail. So DON'T re-anchor the baseline epoch: doing so would drop all history
                        // and force a multi-night "calibrating" reset for someone who already has plenty of nights
                        // (that reset reading as "the setting is broken" was #195). A genuine cold-start user
                        // (<4 valid nights) still calibrates honestly; established users see the switch immediately.
                        Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                    }
                }
                Text("Whole night is NOOP's default measure; Deep sleep pools HRV over slow-wave sleep only, reading lower and matching WHOOP. Switching re-scores your recent nights over the new window and takes effect right away once you have a few nights of data.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // MARK: Strap name — rename the WHOOP 4.0's BLE advertising name (Harvard command set).
                if live.connected && selectedWhoopModelRaw == WhoopModel.whoop4.rawValue {
                    rowDivider
                    strapNameControl
                }

                #if os(iOS)
                rowDivider
                // MARK: Live Activity — show live HR on the Lock Screen + Dynamic Island (#336).
                Toggle(isOn: $liveActivityEnabled) {
                    Text("Live heart rate in Dynamic Island")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Shows your live heart rate on the Lock Screen and in the Dynamic Island while the strap is connected. Turn it off to keep your live HR out of the Dynamic Island. (Any one already showing clears within a moment.)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
        }
    }

    // MARK: - Power saving (#477)
    private var powerSavingCard: some View {
        SettingsSection(
            icon: "battery.25",
            title: "Power saving",
            blurb: "Ease the load on your strap when its battery is running low. The strap keeps banking data on its own, so nothing is lost — NOOP just talks to it less often to help it last until you can charge it."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $powerSavingEnabled) {
                    Text("Power saving mode")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: powerSavingEnabled) { _ in model.applyPowerSaving() }
                Text("Slows background strap-sync (every 45 min instead of 15) while your strap's battery is low. No data loss — the strap banks everything, so sync just batches into larger, less frequent pulls.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if powerSavingEnabled {
                    rowDivider
                    HStack {
                        Text("Kick in at (strap battery)")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(verbatim: "\(powerSavingPct)%")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    Slider(
                        value: Binding(get: { Double(powerSavingPct) }, set: { powerSavingPct = Int($0) }),
                        in: 10...30, step: 5,
                        onEditingChanged: { editing in if !editing { model.applyPowerSaving() } }
                    )
                    .tint(StrandPalette.accent)

                    rowDivider
                    // HRV pause: a sub-option, ON by default when the master is on (stored inverted).
                    Toggle(isOn: Binding(get: { !pauseHrvDisabled }, set: { pauseHrvDisabled = !$0 })) {
                        Text("Pause HRV capture")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)
                    .onChangeCompat(of: pauseHrvDisabled) { _ in model.applyPowerSaving() }
                    Text("While your strap's battery is low, stop the always-on background HRV stream — the biggest continuous drain on the strap. A Live screen still shows heart rate, and it re-arms automatically once the strap is charged.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Rename the WHOOP 4.0's BLE advertising name. Shows the current name (read back from firmware in
    /// the connect handshake → `LiveState.advertisingName`) and writes a new one via `renameStrap`. The
    /// strap reboots to apply, so the new name lands on the next connect. WHOOP 4.0 only (Harvard).
    @ViewBuilder private var strapNameControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strap name").strandOverline()
            Text("Current: \(live.advertisingName ?? "—")")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: NoopMetrics.space3) {
                TextField("New strap name", text: $strapNameDraft)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, NoopMetrics.space3)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .disableAutocorrection(true)
                    .accessibilityLabel("New strap name")
                NoopButton("Rename", systemImage: "pencil", kind: .primary) {
                    model.ble.renameStrap(strapNameDraft)
                }
                .disabled(strapNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status = live.renameStatus {
                Text(status)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Changes the Bluetooth name your WHOOP 4.0 advertises (what you see when pairing). The strap reboots to apply, so the new name appears the next time it connects. WHOOP 4.0 only.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Shares LiveState.connectionStatus* with the sidebar footer (RootView) so the two never drift (#266).
    private var strapStatusTitle: String { live.connectionStatusLabel }

    private var strapTone: StrandTone {
        if live.connectionStatusIsActive { return .positive }
        if live.connectionStatusIsIdle { return .warning }
        return .critical
    }

    private var strapStatusDetail: String {
        if live.bonded && live.connected {
            return String(localized: "Your strap is paired and sending data. Open Live for a real-time heart rate.")
        }
        if live.connected, let hint = live.pairingHint { return hint }
        if live.connected { return String(localized: "Connected. Finishing the secure pairing handshake…") }
        if live.bonded { return String(localized: "Previously paired but not currently connected. Re-scan to reconnect.") }
        return String(localized: "No strap connected. Put your WHOOP nearby and tap Re-scan to pair.")
    }

    private func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }

    // MARK: - Recovery (Charge baseline)

    /// Advanced recovery controls. The Recalibrate button re-anchors the whole Charge (recovery)
    /// baseline from tonight onward — the cure for a baseline poisoned by a bad first week (worn sick,
    /// or an early reading that anchored too high). It writes now (epoch SECONDS) to BOTH the
    /// `noop.hrvBaselineEpoch` and `noop.recoveryBaselineEpoch` settings the recovery engine reads, then
    /// kicks a recompute the same way the sleep-edit path does (analyzeRecent → refresh). History stays.
    private var recoveryCard: some View {
        SettingsSection(
            icon: "heart.text.square",
            title: "Recovery",
            blurb: "Your Charge score learns a personal baseline from your heart-rate variability, resting heart rate and more over time. If a bad first week set it off, you can re-learn it from tonight. Your history stays."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                NoopButton("Recalibrate Charge baseline", systemImage: "arrow.triangle.2.circlepath", kind: .secondary) {
                    showRecalibrateConfirm = true
                }

                Text("Restarts the roughly 4-night build-up for Charge and your HRV baseline from tonight. Use it if a bad first week set your baseline off. Your history stays.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Write the recalibration anchor and trigger a recompute. Re-anchors EVERY baseline that feeds
    /// Charge — HRV plus resting HR / respiration / skin temp — by writing now (epoch SECONDS) to both
    /// `noop.hrvBaselineEpoch` and `noop.recoveryBaselineEpoch` via the single cross-platform source of
    /// truth (`Baselines.recalibrateRecoveryBaselines`). No stored day is deleted; only the day the
    /// baselines re-learn from moves. Then re-score + refresh so the change is reflected without a
    /// relaunch (same path as a sleep edit), and Today honestly shows the building/calibrating state.
    private func recalibrateHrvBaseline() {
        Baselines.recalibrateRecoveryBaselines()
        Task {
            await model.intelligence.analyzeRecent()
            await model.repo.refresh()
        }
        backupAlertTitle = String(localized: "Charge baseline recalibrating")
        backupAlertMessage = String(localized: "NOOP will re-learn your baseline from tonight's data onward. Your history is kept, and it takes a few nights to settle.")
        showBackupAlert = true
    }

    // MARK: - Test Centre (the diagnostic home, #507/#509)

    /// A nav row into the Test Centre, the single home for the diagnostic, log and test controls (spec
    /// section 7). The strap log, recalibrate, scheduled export and experimental toggles also live there
    /// on the same bindings, so this is a faster door to the full set without growing this screen.
    private var testCentreCard: some View {
        SettingsSection(
            icon: "testtube.2",
            title: "Test Centre",
            blurb: "Turn on a test for the thing that's wrong, wear the strap, then tap Report. Your strap log, recalibrate, scheduled export and experimental probes all live here too."
        ) {
            NavigationLink(destination: TestCentreView()) {
                HStack {
                    Text("Open Test Centre")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel("Open Test Centre")
        }
    }

    // MARK: - Features (opt-in trackers)

    /// Opt-in, manual-first feature toggles (default OFF). Hydration tracking gates the water-log card on
    /// the Today dashboard and its detail screen — nothing is shown or stored until it's enabled.
    private var featuresCard: some View {
        SettingsSection(
            icon: "drop.fill",
            title: "Features",
            blurb: "Optional trackers, off by default. Turn them on to add their cards. Everything stays on \(Platform.deviceNounPhrase)."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
                Toggle(isOn: $hydrationEnabled) {
                    Text("Hydration tracking")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityHint("Adds a water-log card to your dashboard")

                Text("Adds a simple fluid log with a daily goal that adjusts to your effort. Tap to add a sip, cup or bottle and watch a progress ring fill. On \(Platform.deviceNounPhrase) only. Nothing is synced.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                Toggle(isOn: $autoDetectWorkoutsEnabled) {
                    Text("Auto-detect workouts")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityHint("Offers to save a workout when it spots sustained elevated heart rate")

                Text("After a sync, NOOP looks over your recent heart rate for a sustained, raised stretch that looks like exercise and offers to save it. It only ever suggests. Nothing is saved until you tap Save, and you can dismiss any suggestion. Deliberately conservative, so the odd workout may be missed. On \(Platform.deviceNounPhrase) only.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                Toggle(isOn: $journalReminderEnabled) {
                    Text("Journal reminder")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityHint("Show a Today card reminding you to log your journal")

                Text("Show a Today card reminding you to log your journal")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                Toggle(isOn: $workoutKeepScreenOn) {
                    Text("Keep screen on during a workout")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityHint("Stops the screen dimming while a workout is recording")

                Text("Holds the screen awake while you're recording a workout, so your live heart rate stays visible without the device dimming. Only applies during a recording. The screen sleeps normally the rest of the time. Leaving it on does use a bit more battery, and means your unlocked screen stays visible for the whole workout, so flip it off if that's a concern.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Backup & restore

    // MARK: - Experimental (WHOOP 5 / MG)

    /// Entry point used by `body`. The 5/MG probe card only renders for a 5/MG (see `showFiveMGControls`,
    /// #22); the raw-sensor CSV diagnostic is split into its own card so it stays available on every
    /// model — a 4.0 owner still needs the export to share decoded streams.
    @ViewBuilder private var experimentalCard: some View {
        liquidTodayCard
        liveSessionsCard
        if showFiveMGControls { fiveMGCard }
        sleepStagingCard
        rawSensorDiagnosticsCard
    }

    /// Opt-in liquid Today redesign (default ON in this build). Off falls back to the
    /// classic dashboard immediately, no rebuild. Same data either way.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true
    private var liquidTodayCard: some View {
        SettingsSection(
            icon: "drop.fill",
            title: "Experimental · Liquid Today",
            blurb: "A redesigned Today screen in the new liquid language: the scores as living liquid, a time-of-day sky, and a calmer layout. Same numbers, new look."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $liquidTodayEnabled) {
                    Text("Liquid Today (prototype)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Replaces the Today tab with the prototype redesign. Turn it off any time to return to the classic dashboard. Reads the same live data from your strap.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Live Sessions (beta) — the silent-guardian in-workout coach. Default ON (the entry itself is
    /// BETA-labelled on the Liquid Today); off removes the Start-session control entirely. Same key the
    /// Today entry reads (`LiveSessionPrefs.betaKey`).
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    private var liveSessionsCard: some View {
        SettingsSection(
            icon: "shield.lefthalf.filled",
            title: "Experimental · Live Sessions",
            blurb: "A one-tap guarded workout: the strap watches your heart rate against a band gated on today's Charge, and only ever buzzes to correct course. Silence means you're on track."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $liveSessionsBeta) {
                    Text("Live Sessions (beta)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Silence-first strap coaching during workouts.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Sleep staging engine. V2 (the transparent cardiorespiratory recipe) is the DEFAULT after a 44-subject
    /// cross-subject benchmark; model-agnostic — it works on WHOOP 4 and 5 — so it renders on every strap.
    /// Turning the toggle OFF falls back to the older V1 percentile-band stager; either way only future
    /// (and re-derived) nights are affected.
    private var sleepStagingCard: some View {
        SettingsSection(
            icon: "bed.double.fill",
            title: "Sleep staging",
            blurb: "How NOOP splits a night into light / deep / REM. The V2 recipe is the default; turn it off to fall back to the older V1 staging."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $experimentalSleepV2Enabled) {
                    Text("Sleep staging (V2)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("A transparent cardiorespiratory recipe that recovers deep and REM better than the older V1 staging, and is now the default. It only changes how already-detected nights are split into stages (detection and scores are unchanged); turn it off to fall back to V1. Takes effect on the next nights staged.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                // MARK: Motion-aware wake refinement (#364 follow-up) — default OFF.
                Toggle(isOn: $motionAwareWakeEnabled) {
                    Text("Motion-aware wake refinement")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Reviews each scored wake block for real evidence of getting up (walking cadence, a change in body position) instead of just a heart-rate rise. A wake block with no locomotion and a stable posture — a hot night, a brief turn-over — is folded back into light sleep; a real get-up is left alone. Self-checks how much motion detail your strap actually recorded and stays off on a night that's too sparse to trust (older WHOOP 4.0 firmware, mainly). Off by default; takes effect on the next nights staged.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The R22 "send enable sequence" button is structurally impossible on macOS — a Mac can't form the
    /// encrypted bond a 5/MG needs to accept the write (BLEManager forms a live-HR-only link there), so it
    /// stays disabled regardless of bond/wear state (#587). On iOS/Android it gates on the real bond + wear.
    private var deepDataButtonDisabled: Bool {
        #if os(macOS)
        return true
        #else
        return !live.encryptedBond || !live.worn
        #endif
    }

    /// The reason line under the R22 button. macOS gets an explicit "needs an iPhone/Android" message
    /// rather than the misleading "needs the full encrypted bond" one (a Mac can never get that bond).
    private var deepDataButtonReason: String {
        #if os(macOS)
        return String(localized: "Deep data (R22) needs an iPhone or Android. A Mac can't form the encrypted bond a 5/MG requires.")
        #else
        if !live.encryptedBond {
            return String(localized: "Needs the full encrypted bond: close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry the unlock).")
        }
        return live.worn
            ? String(localized: "Wear the strap, tap once, then let it sync and share your strap log.")
            : String(localized: "Put the strap on first. The deep stream is on-wrist only.")
        #endif
    }

    /// How many flags the enable sequence actually writes. Read from the sequence rather than restated, so
    /// the card cannot drift from it again — it said "15" for the whole life of the 16-flag sequence (#174).
    private var r22FlagCount: Int { Whoop5Config.enableR22Sequence.count }

    /// The disable button is gated like the enable one MINUS the wear check: the on-wrist requirement exists
    /// because the R22 *stream* is on-wrist gated, and nothing about clearing a stored flag needs the strap
    /// worn. Making a user strap it back on to turn a feature off would be the wrong trade.
    private var deepDataDisableButtonDisabled: Bool {
        #if os(macOS)
        return true
        #else
        return !live.encryptedBond || live.r22DisableReport == BLEManager.deviceConfigProbeWaiting
        #endif
    }

    /// The reason line under the disable button. Says what the run will do and, crucially, what it can and
    /// cannot establish — the off value is inferred from the sibling namespace, so the read-back is the
    /// evidence, and a cleared flag is still not the same as observed behaviour reverting.
    private var deepDataDisableButtonReason: String {
        #if os(macOS)
        return String(localized: "Turning deep data back off needs an iPhone or Android. A Mac can't form the encrypted bond a 5/MG requires.")
        #else
        if !live.encryptedBond {
            return String(localized: "Needs the full encrypted bond: close the official WHOOP app and pair the strap to NOOP first (a live-HR-only link can't carry the write).")
        }
        return String(localized: "Writes the off value to all 16 flags and reads each one back, so you see what the strap stores rather than just that it acked. The off value is inferred from the flag NOOP already turns off this way for Garmin broadcast — it has never been seen on an R22 flag, so NOOP tries one flag first and stops if the strap refuses it. Clearing the flags is not the same as watching the deep records stop: check that by syncing afterwards.")
        #endif
    }

    private var fiveMGCard: some View {
        SettingsSection(
            icon: "flask.fill",
            title: "Experimental · WHOOP 5 / MG",
            blurb: "Live heart rate already works on a WHOOP 5/MG strap. These probes go further and try to coax more out of it. They are guesses, off by default, and only ever touch a 5/MG strap. WHOOP 4.0 is never affected."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $puffinExperiments) {
                    Text("Try WHOOP 5/MG protocol probes")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("On a 5/MG connection NOOP will send a puffin realtime-stream request after the handshake, and log what comes back. If you have a 5/MG strap, turning this on and sharing your strap log helps map the protocol. No effect on WHOOP 4.0.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDivider

                // MARK: R22 deep-data unlock — the one probe that writes to the strap.
                Toggle(isOn: $deepDataEnabled) {
                    Text("Unlock WHOOP 5/MG deep data (R22)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                // #174: turning the switch OFF used to write nothing — it only hid the enable button, so the
                // strap kept every flag the enable sequence set while the UI implied it had been undone.
                // Now it offers the real undo. Turning it ON still writes nothing until the button is tapped.
                .onChangeCompat(of: deepDataEnabled) { on in if !on { confirmingDeepDataDisable = true } }
                Text("WHOOP 5/MG straps hand a fresh app only live heart rate. The official app switches on the deeper streams (high-rate HR + motion + history) by writing a set of feature flags, a sequence two independent projects have documented. With this on, the button below sends that exact sequence to your strap. Unlike everything else here it does write to the strap — and it is reversible: \u{201C}Turn deep data back off\u{201D} writes the off value to the same flags and then reads every one of them back, so you see what the strap actually stores rather than just that it acked. Experimental: it may do nothing on your firmware. iPhone/Android only. A Mac can't write to a 5/MG.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if deepDataEnabled {
                    NoopButton("Send enable sequence to strap", systemImage: "bolt.badge.automatic", kind: .primary) {
                        model.ble.enableWhoop5DeepData()
                    }
                    .disabled(deepDataButtonDisabled)
                    Text(deepDataButtonReason)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)

                    // #174: the undo. Offered whenever the flags may be set — which is any time the opt-in
                    // has been on, not only right after a send, because the flags persist across launches
                    // and the app has no record of what a previous install wrote.
                    NoopButton("Turn deep data back off", systemImage: "bolt.slash", kind: .secondary) {
                        model.ble.disableWhoop5DeepData()
                    }
                    .disabled(deepDataDisableButtonDisabled)
                    Text(deepDataDisableButtonReason)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)

                    // Live R22 telemetry (#174): proof of what the strap is doing right now.
                    // The threshold and the number are both driven off the sequence itself — they were
                    // hardcoded to 15 while the sequence carried 16, so the card declared success one flag
                    // early and named a count that had already drifted.
                    if live.r22FlagsAccepted > 0 {
                        Label(live.r22FlagsAccepted >= r22FlagCount
                              ? "Strap accepted all \(r22FlagCount) R22 flags"
                              : "Strap accepted \(live.r22FlagsAccepted)/\(r22FlagCount) R22 flags…",
                              systemImage: live.r22FlagsAccepted >= r22FlagCount ? "checkmark.seal.fill" : "ellipsis")
                            .font(StrandFont.caption)
                            .foregroundStyle(live.r22FlagsAccepted >= r22FlagCount ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                    }
                    if live.deepPacketsThisSession > 0 {
                        Label(live.deepPacketsThisSession == 1
                              ? "1 type-0x2F historical-offload frame seen outside our sync. These are history (e.g. another app pulling the strap's backlog), not a live R22 stream (#494)."
                              : "\(live.deepPacketsThisSession) type-0x2F historical-offload frames seen outside our sync. These are history (e.g. another app pulling the strap's backlog), not a live R22 stream (#494).",
                              systemImage: "clock.arrow.circlepath")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else if live.r22FlagsAccepted >= r22FlagCount {
                        Text("Flags accepted, but the enable sequence doesn't start a separate live stream. The deep records arrive as part of the normal history sync (#494).")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }

                }

                // #174: the disable run's per-key result. Shown verbatim because the interesting part is
                // the read-back table, not a green tick — a write that acked SUCCESS but did not move
                // the stored value renders here as "unchanged", which is the case worth seeing.
                //
                // OUTSIDE the `if deepDataEnabled` block on purpose. The commonest way to reach a disable
                // run is flipping the switch OFF and confirming, which means the pref is already false while
                // the run is walking its plan — so nesting this inside that block hid the progress line and
                // the whole read-back table for exactly the run a user is most likely to start. The report
                // is about what is on the STRAP, which outlives the app's opt-in: it stays legible (and
                // dismissable) whatever the switch says.
                if let report = live.r22DisableReport {
                    if report == BLEManager.deviceConfigProbeWaiting {
                        Label("Clearing R22 flags and reading each one back\u{2026}", systemImage: "ellipsis")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text(report)
                            .font(StrandFont.caption.monospaced())
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        NoopButton("Dismiss disable report", systemImage: "xmark", kind: .secondary) {
                            model.ble.clearR22DisableReport()
                        }
                    }
                }

                rowDivider

                // MARK: Broadcast HR — make the strap a standard BLE HR sensor (Garmin/Zwift/gym).
                Toggle(isOn: $broadcastHrEnabled) {
                    Text("Broadcast strap HR (Garmin/ANT)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: broadcastHrEnabled) { on in model.ble.setBroadcastHr(on) }
                Text("Makes your WHOOP 5.0/MG advertise its heart rate as a standard Bluetooth HR sensor, so a Garmin (Edge/watch), Zwift or gym equipment can use it during a workout. Applied on the next connection (and immediately if connected); writes the strap's whoop_live_hr_in_adv_ind_pkt flag. Reversible. iPhone-side only. A Mac can't write to a 5/MG.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // #573: leaving broadcast on keeps the strap radio advertising continuously, which drains
                // the strap faster — make that visible and persistent so it isn't left on by accident.
                if broadcastHrEnabled {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        Text("Broadcast HR is ON. Your strap is advertising its heart rate continuously, which keeps its radio hot and drains the battery faster. Turn it off when you're not using it with another device.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }

                // MARK: #103 SpO₂ strap estimate display — surface the @82 candidate as a fallback.
                Divider().overlay(StrandPalette.hairline)

                Toggle(isOn: $spo2CandidateDisplayEnabled) {
                    Text("Blood Oxygen: strap estimate (WHOOP 5/MG)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChangeCompat(of: spo2CandidateDisplayEnabled) { _ in
                    // Re-score immediately so the @82 candidate is computed and persisted on this
                    // toggle flip — without this the user waits up to 15 min for the next analyze
                    // loop, and the Blood Oxygen tile stays blank in the meantime. Same pattern as
                    // the HRV window toggle above (analyzeRecent → refresh).
                    Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
                }
                Text("Your WHOOP 5.0/MG sends a strap-computed SpO₂ percentage (the @82 candidate byte) every second. An 8-night independent validation tracked it at corr +0.99 against the WHOOP app, but two nights on the original test device moved the OPPOSITE direction — device/firmware variance is unresolved. Turning this on surfaces the nightly mean in the Blood Oxygen tile as \"strap estimate (unverified)\" when no calibrated import exists. It never feeds recovery or illness scoring. WHOOP 4.0 has no @82 stream, so this does nothing there.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // MARK: #891 ECG raw-data gate — the second device-config key this app may write, MG-only.
                Divider().overlay(StrandPalette.hairline)

                Toggle(isOn: $ecgRawDataEnabled) {
                    Text("ECG raw-data gate (WHOOP MG only)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Your strap listed its own device-config keys, and one of them is enable_raw_data_w_ecg. On an MG with no ECG subscription it reads '0' — while all three ECG commands answer SUCCESS and send no data at all (#891). This is the leading guess for what's holding ECG shut. Nobody knows whether flipping it actually produces ECG data: finding out is the point, and \"still nothing\" is a useful answer worth posting to #891.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if ecgRawDataEnabled {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        Text("This writes a setting that STAYS ON YOUR STRAP until you change it back — it isn't an app preference, and closing NOOP won't undo it. \"Turn gate off\" below writes '0' again, in one tap. Only this one key is ever written; the other six your strap listed are never touched.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)

                    NoopButton("Turn gate on (write '1')", systemImage: "waveform.path.ecg", kind: .primary) {
                        model.ble.setEcgRawDataGate(true)
                    }
                    .disabled(!ecgGateReady)
                    NoopButton("Turn gate off (write '0')", systemImage: "arrow.uturn.backward", kind: .secondary) {
                        model.ble.setEcgRawDataGate(false)
                    }
                    .disabled(!ecgGateReady)
                    Text(ecgGateReason)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The read-back — the ONLY thing reported as a result. The write's own ack is in the
                    // strap log for the record and is deliberately not surfaced as an outcome here.
                    if let report = live.ecgRawDataGate {
                        Label(report.summary, systemImage: ecgGateIcon(report.verdict))
                            .font(StrandFont.caption)
                            .foregroundStyle(ecgGateTint(report.verdict))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().overlay(StrandPalette.hairline)

                // MARK: WHOOP MG ECG (Labrador) — MG-only, writes ECG control commands. NOT medical.
                Toggle(isOn: $ecgEnabled) {
                    Text("WHOOP MG ECG capture (experimental)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                // Turning the switch off also tells the strap to stop, so a stream can't be left running
                // by a user who simply flips the toggle back. `ecgStopCapture` is deliberately reachable
                // with the opt-in already off (see BLEManager.ecgStopOverride). When the strap isn't a
                // connected MG the send can't happen — the Devices "Stop" control then stays offered via
                // `ecgMayBeRunning` so there is still a route once the link is back.
                // `reportsResult: false`: switching a setting off must not pop the Devices result sheet.
                .onChangeCompat(of: ecgEnabled) { on in if !on { model.ecgStopCapture(reportsResult: false) } }
                Text("The WHOOP MG has ECG electrodes in its clasp. This unlocks a gated, hand-run probe on the Devices screen that asks the strap to start its ECG subsystem and logs whatever comes back. MG only — a plain WHOOP 5.0 has no electrodes, and NOOP will refuse to send unless your strap identifies itself as an MG. Nobody has confirmed a strap honours these commands, so it may simply do nothing. Turn on “Record puffin frames to a file” below first if you want a complete byte-level capture to share.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if ecgEnabled {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        Text("NOOP is not a medical device and this is not an ECG test. Anything the strap reports here — including any heart-rhythm classification it happens to send — is unvalidated instrumentation for protocol research, not a measurement and not a diagnosis. Never use it to make a decision about your health. If you have symptoms or are worried about your heart, talk to a doctor.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }

                Toggle(isOn: $puffinCapture) {
                    Text("Record puffin frames to a file")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                Text("Saves every raw 5/MG frame (with a timestamp and the live heart rate) to a JSON file you can share to help map the biometric layout. This only records frames the strap already sent (it never writes to your strap), so it is safe to leave on. Export the file and attach it to a protocol-mapping issue.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if puffinCapture {
                    rowDivider
                    Text("Optical block experiment")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Mark the start of each physical phase while wearing or handling the strap. NOOP aligns the marker to the timestamp inside delayed history buffers, then the offline analyzer compares block activation, header bytes and raw ADC changes. It does not assume a wavelength or calculate SpO₂/BP.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: NoopMetrics.space3) {
                        NoopButton("Mark phase…", systemImage: "flag.fill", kind: .primary) {
                            showOpticalPhasePicker = true
                        }
                        NoopButton("Export experiment…", systemImage: "square.and.arrow.up", kind: .secondary) {
                            exportOpticalExperiment()
                        }
                        Spacer(minLength: 0)
                    }
                    if !opticalPhaseStatus.isEmpty {
                        Text(opticalPhaseStatus)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                if live.puffinCaptureCount > 0 {
                    Text(live.puffinCaptureCount == 1
                         ? "1 frame captured this session."
                         : "\(live.puffinCaptureCount) frames captured this session.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: NoopMetrics.space3) {
                        NoopButton("Export frames…", systemImage: "square.and.arrow.up", kind: .primary) {
                            exportPuffinCaptures()
                        }

                        #if os(macOS)
                        NoopButton("Reveal in Finder", systemImage: "folder", kind: .secondary) {
                            revealPuffinCaptures()
                        }
                        #endif
                        Spacer(minLength: 0)
                    }
                    // One-tap "matched pair" export (#510): hands a reporter BOTH the raw capture file
                    // and the strap log together (timestamped, same minute) so a protocol-mapping issue
                    // arrives with the frames AND the context that produced them.
                    Button {
                        exportRawAndLog()
                    } label: {
                        if rawAndLogBusy {
                            HStack(spacing: NoopMetrics.space1 + 2) {
                                ProgressView().controlSize(.small)
                                Text("Exporting…")
                            }
                        } else {
                            Label("Export raw + log", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(rawAndLogBusy)
                    Text("Saves the raw capture and the strap log together as a matched pair. Attach both to a protocol-mapping issue.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Diagnostics (every model)

    /// Raw-sensor CSV export — a read-only diagnostic over the decoded streams NOOP already stores
    /// (HR, R-R, motion, steps, PPG-HR, SpO₂, skin temp, resp, events). Split out of the 5/MG card so it
    /// stays visible on EVERY model (#22): a WHOOP 4.0 owner still needs this to share decoded data.
    private var rawSensorDiagnosticsCard: some View {
        SettingsSection(
            icon: "doc.text.magnifyingglass",
            title: "Diagnostics",
            blurb: "A read-only export of the decoded sensor streams NOOP already stores. Works on any strap. Nothing is written to your device, and nothing is uploaded."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                // MARK: Export raw sensor data (CSV) — a read-only diagnostic over the decoded streams
                // NOOP already stores (HR, R-R, motion, steps, PPG-HR, SpO₂, skin temp, resp, events).
                Button {
                    exportRawSensorCSV()
                } label: {
                    if rawCsvBusy {
                        HStack(spacing: NoopMetrics.space1 + 2) {
                            ProgressView().controlSize(.small)
                            Text("Exporting…")
                        }
                    } else {
                        Label("Export raw sensor data (CSV)", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(NoopButtonStyle(.secondary))
                .disabled(rawCsvBusy)

                #if os(macOS)
                if let url = lastRawCsvURL {
                    NoopButton("Reveal in Finder", systemImage: "folder", kind: .secondary) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                #endif

                Text("Dumps the last 24 hours of decoded per-sample sensor streams (heart rate, R-R, motion, steps, SpO₂, skin temperature, respiration, events) to a single CSV. All on \(Platform.deviceNounPhrase), nothing uploaded. Share it to help prototype and test sleep, activity and strength algorithms.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Export the last 24h of decoded sensor streams for the connected strap to a CSV, then save (macOS
    /// NSSavePanel) or share (iOS share sheet) — the same pattern as exportPuffinCaptures().
    ///
    /// The strap id comes from `repo.deviceId`, NOT `model.deviceId`. The latter is a hardcoded
    /// `let "my-whoop"`; the former is seeded with it and then re-pointed to the registry's active strap
    /// once the store opens (`adoptActiveDeviceId`). This read used the hardcoded one, so after a
    /// remove+re-add — which mints a fresh "whoop-<uuid>" that the Collector writes today's raw under —
    /// the CSV exported the legacy id's streams rather than the strap being worn, silently, in the file
    /// people attach to bug reports. That is #814 on the diagnostic path, and the Android twin of it.
    ///
    /// Read on the MainActor before the Task hop, as `LiveSessionRunner` does, rather than reaching into
    /// the actor-isolated repo from inside the task.
    private func exportRawSensorCSV() {
        rawCsvBusy = true
        let strapId = model.repo.deviceId
        Task {
            let since = Date().timeIntervalSince1970 - 24 * 60 * 60
            guard let store = await model.repo.storeHandle() else {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = String(localized: "Export failed")
                    backupAlertMessage = String(localized: "Couldn't open the local store.")
                    showBackupAlert = true
                }
                return
            }
            do {
                let url = try await store.exportRawCSV(deviceId: strapId, since: since)
                await MainActor.run {
                    rawCsvBusy = false
                    lastRawCsvURL = url
                    #if os(macOS)
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.commaSeparatedText]
                    panel.nameFieldStringValue = url.lastPathComponent
                    panel.canCreateDirectories = true
                    guard panel.runModal() == .OK, let dest = panel.url else { return }
                    let fm = FileManager.default
                    do {
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: url, to: dest)
                    } catch {
                        backupAlertTitle = String(localized: "Export failed")
                        backupAlertMessage = error.localizedDescription
                        showBackupAlert = true
                    }
                    #else
                    FileExport.exportFile(at: url)
                    #endif
                }
            } catch {
                await MainActor.run {
                    rawCsvBusy = false
                    backupAlertTitle = String(localized: "Export failed")
                    backupAlertMessage = error.localizedDescription
                    showBackupAlert = true
                }
            }
        }
    }

    /// Flush the in-flight capture, then copy it to a user-chosen location (save panel on macOS) or
    /// hand it to the system share sheet (iOS).
    private func exportPuffinCaptures() {
        Task { @MainActor in
            await model.ble.flushPuffinCaptures()
            guard let src = live.puffinCaptureURL else { return }
            // Suggest a friendly, timestamped name so a reporter saving several captures gets sortable,
            // non-colliding files (#510) — e.g. noop-raw-capture-260617-1042.json.
            let suggested = FileExport.timestampedName("noop-raw-capture", ext: "json")
            #if os(macOS)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = suggested
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
            } catch {
                backupAlertTitle = String(localized: "Export failed")
                backupAlertMessage = error.localizedDescription
                showBackupAlert = true
            }
            #else
            FileExport.exportFile(at: src, suggestedName: suggested)
            #endif
        }
    }

    private func markOpticalPhase(_ phase: PuffinOpticalExperimentPhase) {
        if model.ble.markWhoop5OpticalPhase(phase) {
            opticalPhaseStatus = String(localized: "Marked: \(phase.displayName)")
        } else {
            opticalPhaseStatus = String(localized: "Marker wasn't saved. Keep frame recording on and try again.")
        }
    }

    /// Export the durable JSONL used by the optical comparison CLI. Closing its append handle first
    /// makes the user-selected copy complete; logging reopens lazily on the next buffer or marker.
    private func exportOpticalExperiment() {
        guard let src = model.ble.whoop5OpticalExperimentURL() else {
            backupAlertTitle = String(localized: "Nothing to export")
            backupAlertMessage = String(localized: "No WHOOP 5/MG deep buffers or phase markers have been recorded yet.")
            showBackupAlert = true
            return
        }
        FileExport.exportFile(
            at: src,
            suggestedName: FileExport.timestampedName("noop-whoop5-optical-experiment", ext: "jsonl"))
    }

    /// One-tap matched-pair export (#510): export the raw puffin capture AND the strap log together,
    /// both stamped with the same `yyMMdd-HHmm` minute so they're obviously a pair. Reuses the existing
    /// export utilities — `FileExport.exportPair` shares both files in one iOS share sheet, and saves
    /// each via its own NSSavePanel on macOS (no new file plumbing).
    ///
    /// #646/#651: `exportPair` is now async (its file read + zip build run off the main actor), so this
    /// launches it in a `Task` — the button action itself stays synchronous from the caller's perspective.
    /// `rawAndLogBusy` disables the button for the duration: without it a second tap mid-export fires a
    /// second `exportPair` (two staged zips, two save panels / stacked share sheets).
    private func exportRawAndLog() {
        rawAndLogBusy = true
        Task { @MainActor in
            // `defer` so the flag is cleared on ANY exit (#961 follow-up), including cancellation. It
            // cleared correctly before, but only because `exportPair` is non-throwing — the guard should
            // not depend on that. Otherwise the button stays disabled behind a spinner that never stops.
            defer { rawAndLogBusy = false }
            // #652: `flushPuffinCaptures` is async now (encode+write moved off the main actor), so await
            // it here — the file must be current before we read `puffinCaptureURL` to export it.
            await model.ble.flushPuffinCaptures()
            guard let capture = live.puffinCaptureURL else {
                backupAlertTitle = String(localized: "Nothing to export")
                backupAlertMessage = String(localized: "No raw capture has been recorded yet this session.")
                showBackupAlert = true
                return
            }
            let stamp = FileExport.timestamp()
            await FileExport.exportPair(
                file: capture, fileSuggestedName: "noop-raw-capture-\(stamp).json",
                text: live.exportableLogText(), textSuggestedName: "noop-strap-log-\(stamp).txt")
        }
    }

    #if os(macOS)
    /// Flush, then reveal the capture file in Finder so the user can grab it directly.
    private func revealPuffinCaptures() {
        Task { @MainActor in
            await model.ble.flushPuffinCaptures()
            guard let url = live.puffinCaptureURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    #endif

    private var backupCard: some View {
        SettingsSection(
            icon: "externaldrive.fill",
            title: "Backup & restore",
            blurb: "Move all your NOOP data to another machine. Export saves everything (history, sleeps, workouts, settings) to a single file you can copy across; import replaces \(Platform.deviceNounPhrase)'s data with a backup."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                // Three labelled buttons must share a narrow iPhone row without wrapping mid-word
                // (the labels otherwise broke to one character per line). Equal width + shrink-to-fit
                // keeps each on a single line. On iPhone the SF Symbol icons were the main space-thief
                // (~90pt/button) and there's no room for them in a 3-up row, so we drop to icon-less
                // text there; macOS is wide enough to keep the icons. No trailing Spacer/ProgressView
                // inside this HStack — either would steal a share of the equal-width row. (#188)
                HStack(spacing: NoopMetrics.space3) {
                    Button {
                        runExport()
                    } label: {
                        backupButtonLabel(String(localized: "Export…"), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .disabled(backupBusy)

                    Button {
                        runImport()
                    } label: {
                        backupButtonLabel(String(localized: "Import…"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    .disabled(backupBusy)

                    Button {
                        runCsvExport()
                    } label: {
                        backupButtonLabel(String(localized: "Export CSV…"), systemImage: "tablecells")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
                    .disabled(backupBusy)
                }

                if backupBusy {
                    HStack(spacing: NoopMetrics.space2) {
                        ProgressView().controlSize(.small)
                        Text("Working…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("Importing overwrites everything currently on \(Platform.deviceNounPhrase). Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect. Export CSV writes a WHOOP-format zip of your days, sleeps, workouts and journal that re-imports into NOOP on Mac, iPhone, or Android. On-device computed rows are marked APPROXIMATE in its Source column; the full backup stays the lossless restore path.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // #644: .noopbak is a plain ZIP, not an encrypted container — anyone who gets the file
                // can open it in any archive tool. Say so plainly next to the Export button, rather than
                // let people assume the file itself is protected once it leaves the device (e.g. dropped
                // into a cloud-synced folder).
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("This is a plain, unencrypted archive — anyone who gets the file can open it with any zip tool. Store it somewhere you trust.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Reach the scheduled / folder-based Backup & Sync screen (back up to a chosen folder on
                // demand or about once a day, restore from a snapshot in that folder).
                NavigationLink {
                    BackupSyncView()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "externaldrive.fill.badge.icloud")
                            .accessibilityHidden(true)
                        Text("Backup & Sync to a folder…")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel("Open Backup and Sync to a folder")
            }
        }
    }

    // Equal-width, single-line label for the three Backup buttons. iPhone is too narrow to fit
    // an icon + text three-up, so it goes icon-less there; macOS keeps the SF Symbol. (#188)
    @ViewBuilder
    private func backupButtonLabel(_ title: String, systemImage: String) -> some View {
        // The NoopButtonStyle (fullWidth) owns the width + padding; the label just supplies the
        // content and the single-line shrink-to-fit so the 3-up iPhone row never wraps mid-word (#188).
        #if os(macOS)
        Label(title, systemImage: systemImage)
            .lineLimit(1).minimumScaleFactor(0.7)
        #else
        Text(title)
            .lineLimit(1).minimumScaleFactor(0.6)
        #endif
    }

    private func runExport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
    }

    private func runImport() {
        backupBusy = true
        Task {
            let result = await DataBackup.runImport()
            handleBackup(result)
        }
    }

    private func runCsvExport() {
        backupBusy = true
        Task {
            let result = await CsvExport.run(repo: model.repo)
            backupBusy = false
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                backupAlertTitle = String(localized: "CSV exported")
                backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent). The zip re-imports into NOOP (Data Sources → WHOOP Export) on any Mac, iPhone, or Android device.")
                showBackupAlert = true
            case .failure(let message):
                backupAlertTitle = String(localized: "Export problem")
                backupAlertMessage = message
                showBackupAlert = true
            }
        }
    }

    @MainActor
    private func handleBackup(_ result: DataBackup.BackupResult) {
        backupBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupAlertTitle = String(localized: "Backup exported")
            backupAlertMessage = String(localized: "Saved to \(url.lastPathComponent). Copy this file to your other \(Platform.deviceNoun) and use Import there to restore everything.")
            showBackupAlert = true
        case .imported:
            backupAlertTitle = String(localized: "Backup imported")
            backupAlertMessage = String(localized: "Your data has been restored. Quit and reopen NOOP for it to take effect.")
            showBackupAlert = true
        case .failure(let message):
            backupAlertTitle = String(localized: "Backup problem")
            backupAlertMessage = message
            showBackupAlert = true
        }
    }

    // MARK: - About

    /// The real marketing version straight from the bundle (CFBundleShortVersionString, set from
    /// project.yml MARKETING_VERSION), so the About pill can never go stale the way a hand-edited
    /// Swift constant can. Mirrors how Android's pill reads BuildConfig.VERSION_NAME. Falls back to
    /// the hand-maintained changelog version only if the Info.plist key is somehow missing.
    private var bundleVersionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppChangelog.currentVersion
    }

    private var aboutCard: some View {
        SettingsSection(
            icon: "info.circle.fill",
            title: "About",
            blurb: "NOOP: all your data, none of the cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("NOOP")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    StatePill("v\(bundleVersionString)", tone: .neutral, showsDot: false)
                    Spacer()
                    NoopButton("What's new", systemImage: "sparkles", kind: .secondary) {
                        showWhatsNew = true
                    }
                }

                // How NOOP works — the plain-English primer: how sleep is sorted, how scores +
                // calibration work, what recording means, and where the provenance badges come
                // from. The "?" entry point to the four-section explainability primer.
                Button {
                    showHowNoopWorks = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("How NOOP works")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Sleep sorting, scores, recording, and where your numbers come from.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel("How NOOP works")

                // How your scores work — the honest explainer for Charge / Effort / Rest and the
                // confidence labels. Always reachable here, mirroring the "What's new" affordance.
                Button {
                    showScoringGuide = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("How your scores work")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Charge, Effort and Rest (and how they differ from WHOOP).")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel("How your scores work")

                // About Apple Watch data: the honest capability/confidence page for running NOOP off
                // just an Apple Watch (what it's great at, where it's lighter than a strap, why recovery
                // calibrates, the SpO₂ caveat). Its primary action opens the watch setup + Health
                // permission flow. Renders the same on macOS and iOS (pure reference content); the setup
                // sheet itself does the iOS-only HealthKit request.
                NavigationLink {
                    AppleWatchAboutView(onStartSetup: { showAppleWatchSetup = true })
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "applewatch")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("About Apple Watch data")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Use NOOP with just an Apple Watch. What it's great at, and where it's lighter than a strap.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel("About Apple Watch data")

                // Storage (#590) — on-device space breakdown (database, leftover import Inbox, stranded
                // temp files) plus a one-tap clean-up. iOS is where "Documents & Data" can balloon after
                // an Apple Health import; it compiles + reads fine on macOS too, so the link is unconditional.
                NavigationLink {
                    StorageView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Storage")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Where NOOP's on-device space is going, and a one-tap clean-up.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel("Storage")

                #if os(iOS)
                // iOS reality & diagnostics — honest expectations for a sideloaded iPhone build, plus a
                // one-tap environment dump (device, iOS+build, Data Protection, background refresh,
                // low-power, sideload expiry) for bug reports. iOS-only; macOS doesn't have these gotchas.
                iosDiagnosticsRow
                iphoneExpectations
                #endif

                // Check for updates — a single, user-initiated read of GitHub's public releases API.
                // No background polling, no auto-update; sends nothing about you, just reads the version.
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Button {
                            // Compare the ACTUAL installed bundle version against GitHub's latest, not the
                            // hand-maintained AppChangelog.currentVersion (which drifts stale and told v7
                            // users they were behind, #697-adjacent). Mirrors Android's BuildConfig check.
                            updateChecker.check(currentVersion: bundleVersionString)
                        } label: {
                            if updateChecker.state == .checking {
                                HStack(spacing: NoopMetrics.space1 + 2) {
                                    ProgressView().controlSize(.small)
                                    Text("Checking…")
                                }
                            } else {
                                Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(updateChecker.state == .checking)

                        if case .upToDate(let v) = updateChecker.state {
                            Text("You're on the latest (\(v)).")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        } else if case .failed = updateChecker.state {
                            Text("Couldn't check. Try again.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.statusWarning)
                        }
                        Spacer()
                    }

                    // Update available: show what's new, with a download straight to the release.
                    if case .available(let v, let url, let notes) = updateChecker.state {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Version \(v) is available")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                NoopButton("Download", systemImage: "arrow.down.circle.fill", kind: .primary) {
                                    openURL(url)
                                }
                            }
                            if !notes.isEmpty {
                                ScrollView {
                                    Text(notes)
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 150)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(StrandPalette.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(StrandPalette.accent.opacity(0.3), lineWidth: 1)
                        )
                    }

                    Text("Checks the project's home (GitHub) for the latest version when you tap. Nothing else is sent.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                // Project home — NOOP's code, releases, issues and wiki live on GitHub.
                Link(destination: URL(string: "https://github.com/ryanbr/noop")!) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Project home & source")
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("GitHub: code, releases, issues and the wiki.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Project home and source code on GitHub")

                Text("A standalone companion for your WHOOP. Everything stays on this device: your history, your live stream, your numbers. Nothing is uploaded. NOOP is an independent, experimental project, not the WHOOP app.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Medical disclaimer
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
                )

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on").strandOverline()
                    attribution(repo: "johnmiddleton12/my-whoop", note: String(localized: "WHOOP 4.0 protocol"))
                    attribution(repo: "b-nnett/goose", note: String(localized: "WHOOP 5.0 protocol"))
                }

                Text("Open-source BLE reverse-engineering work. Thank you.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("· \(note)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - iOS reality & diagnostics (iOS-only)

    #if os(iOS)
    /// A tappable row (mirroring "How your scores work") that opens the environment-diagnostics sheet.
    private var iosDiagnosticsRow: some View {
        Button {
            showDiagnostics = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Diagnostics")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Device, iOS build, Data Protection and sideload status, for bug reports.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Diagnostics")
    }

    /// Calm, honest "what to expect running NOOP on iPhone" callout — sideloading reality, re-sign
    /// cadence, the unlock-after-reboot (#222) note, background-BLE limits, and beta-iOS caveat. Surfaces
    /// the live sideload-cert expiry when we can read it, with a gentle warning under ~3 days.
    private var iphoneExpectations: some View {
        let diag = IOSDiagnostics.capture()
        let expiry = diag.expiryDaysRemaining()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                Text("Using NOOP on iPhone")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }

            iphoneExpectationLine(String(localized: "This is a sideloaded build, installed outside the App Store. It needs re-signing periodically: roughly every 7 days on a free Apple ID, about a year on a paid developer account."))
            iphoneExpectationLine(String(localized: "After your iPhone reboots, unlock it once. Until you do, iOS keeps NOOP's files locked (Data Protection), so new history can't be written or synced."))
            iphoneExpectationLine(String(localized: "Background Bluetooth has OS limits: iOS may pause NOOP when it's not in the foreground, so keep it open while syncing a fresh strap."))
            iphoneExpectationLine(String(localized: "On a beta version of iOS, things can break that work on the release build."))

            if let days = expiry {
                let warning = days <= 3
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: warning ? "exclamationmark.triangle.fill" : "clock.badge.checkmark")
                        .font(.system(size: 13))
                        .foregroundStyle(warning ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    Text(expiryMessage(days))
                        .font(StrandFont.footnote)
                        .foregroundStyle(warning ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1)
        )
    }

    private func expiryMessage(_ days: Int) -> String {
        if days < 0 {
            let expired = -days
            return expired == 1
                ? String(localized: "This sideloaded build expired 1 day ago. Re-sign it to keep it running.")
                : String(localized: "This sideloaded build expired \(expired) days ago. Re-sign it to keep it running.")
        }
        return days == 1
            ? String(localized: "This sideloaded build expires in 1 day. Re-sign to keep it running.")
            : String(localized: "This sideloaded build expires in \(days) days. Re-sign to keep it running.")
    }

    private func iphoneExpectationLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    // MARK: - Shared bits

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - Advanced disclosure (S3)

/// The persisted defaults for the Settings "Advanced" disclosure. Pulled out so the one fact that must
/// never regress, that a fresh install lands COLLAPSED, is a single testable constant. The key matches
/// the Android `SettingsDisclosurePrefs.KEY` suffix so a backup/restore round-trip carries the choice.
enum SettingsDisclosureDefaults {
    static let advancedOpenKey = "settingsAdvancedOpen"
    static let advancedOpenDefault = false
}

/// A collapsible group that tucks the lower-frequency settings sections behind one tap. It is NOT a
/// section card itself (the cards it wraps keep their own `SettingsSection` chrome). It's just a
/// header row + a default-collapsed reveal, modelled on the Test Centre "Advanced" group. Nothing is
/// removed: collapsed simply means the wrapped sections aren't drawn until the row is tapped open.
/// A custom header (not SwiftUI's `DisclosureGroup`) is used so it matches NOOP's near-black
/// instrument look, which the system control's tint and inset don't.
private struct SettingsDisclosureGroup<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(subtitle)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the advanced settings sections")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - Section card

/// A grouped settings card: a "Settings" overline + icon + title header, an explanatory blurb,
/// then content. The surface stays neutral; accent blue is reserved for the icon and controls.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let blurb: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").strandOverline()
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: icon)
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

// MARK: - iOS diagnostics sheet

#if os(iOS)
/// A read-only environment dump for bug reports: device, iOS+build, Data Protection (#222),
/// background refresh, low-power, sideload + cert expiry — with a one-tap Copy.
private struct DiagnosticsSheet: View {
    let onClose: () -> Void

    /// Captured once at presentation; a snapshot, not a live monitor.
    private let lines: [String] = IOSDiagnostics.capture().summaryLines()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics").font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Attach this to a bug report.").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(20)

            Divider().overlay(StrandPalette.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        Text("No iOS diagnostics available.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(StrandFont.mono(12))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(20)
            }

            Divider().overlay(StrandPalette.hairline)

            HStack {
                Spacer()
                Button {
                    // UIPasteboard via the shared cross-platform wrapper.
                    PlatformPasteboard.copy(lines.joined(separator: "\n"))
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(minWidth: 120)
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(lines.isEmpty)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase)
    }
}
#endif

// MARK: - Steps estimate calibration

/// Small shared formatters for the steps-estimate calibration UI — kept apart from the sheet so the
/// Profile-card summary row and the sheet agree on the confidence wording. Mirrors the Android
/// `StepsCalibrationFormat` object.
enum StepsCalibrationFormat {
    /// A 0–1 confidence as Low / Medium / High — the honest read-out the sheet and the summary row share.
    /// Thirds: < 0.34 Low, < 0.67 Medium, else High. A manual coefficient is confidence 1.0 → "High".
    static func confidenceLabel(_ confidence: Double) -> String {
        switch confidence {
        case ..<0.34: return String(localized: "Low")
        case ..<0.67: return String(localized: "Medium")
        default:      return String(localized: "High")
        }
    }
}

/// One recent day's estimated-vs-phone steps comparison row, for the sheet's accuracy table.
private struct StepsComparisonRow: Identifiable {
    let day: String          // yyyy-MM-dd
    let estimated: Int
    let actual: Int
    var id: String { day }
    /// Signed error of the estimate against the phone count, as a percentage (estimate − actual) / actual.
    var errorPct: Double { actual > 0 ? Double(estimated - actual) / Double(actual) * 100 : 0 }
}

/// WHOOP 4.0 steps-ESTIMATE calibration — honest explainer + current fit + a recent estimated-vs-phone
/// table + a manual coefficient override with a live preview. Presented as a sheet from Settings →
/// Profile → "Steps estimate". Reads the SAME data the engine fits against (the computed `steps_est`
/// series and the phone's `steps`), never recomputing the headline. Mirrors Android `StepsCalibrationScreen`.
// Internal (not file-private) so the Today Steps tile can present the SAME calibration sheet directly
// when it's showing an ESTIMATE for a WHOOP 4.0 user — one shared entry point, no duplicated screen (H6).
struct StepsCalibrationSheet: View {
    let repo: Repository
    let onClose: () -> Void
    @EnvironmentObject var profile: ProfileStore

    /// Recent days that have BOTH an estimate and a real phone step count, newest first — the accuracy table.
    @State private var comparison: [StepsComparisonRow] = []
    /// A representative recent motion volume (median of recent days' motion), used so the manual-coefficient
    /// preview reflects a TYPICAL day. nil until loaded / no recent estimated day with a known motion.
    @State private var sampleMotion: Double?

    /// The draft manual coefficient the slider edits, committed to ProfileStore on release. 0 = auto-fit.
    @State private var draftManual: Double = 0
    @State private var didLoad = false

    /// #107: the sheet's guidance depends on the strap family. A WHOOP 4.0 streams motion automatically, so
    /// "let it sync" is right; a 5/MG only streams motion once the experimental deep-data unlock is on, so
    /// the 4.0 advice is futile there and the empty state must say so instead.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue
    @AppStorage(PuffinExperiment.deepDataKey) private var deepDataEnabled = false
    private var is5MG: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue }

    /// The coefficient the slider's max anchors to — generous headroom over whatever the auto-fit found so
    /// a manual nudge in either direction is reachable. Floor keeps the slider usable before any fit.
    private var sliderMax: Double {
        max(profile.stepsCalibrationCoefficient, profile.stepsManualCoefficient, 50) * 2
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    explainerCard
                    if didLoad && sampleMotion == nil { noMotionNote }
                    currentFitCard
                    comparisonCard
                    manualAdjustCard
                }
                .padding(20)
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .task { await loadIfNeeded() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STEPS ESTIMATE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Calibrate your steps").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(is5MG ? "WHOOP 5.0 / MG · motion → steps" : "WHOOP 4.0 · motion → steps").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done").frame(minWidth: 120)
            }
            .buttonStyle(NoopButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(NoopMetrics.space4)
    }

    // MARK: Cards

    /// The honest "it's an estimate, not a step counter" framing — reused verbatim from the engine doc.
    private var explainerCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("How this works", systemImage: "figure.walk.motion")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(is5MG
                     ? String(localized: "NOOP estimates your steps from your WHOOP's motion, calibrated to your phone's step count. It's an estimate, not a step counter — a WHOOP 5.0 / MG streams motion (not a step count) only with deep data on.")
                     : String(localized: "NOOP estimates your steps from your WHOOP's motion, calibrated to your phone's step count. It's an estimate, not a step counter. A WHOOP 4.0 doesn't transmit steps."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the days your phone also counted steps, NOOP learns how much your motion maps to steps, then applies that to the strap-only days. The more matching days it has, the more it trusts the estimate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown when the strap has banked NO motion yet (sampleMotion is nil) — the real reason a fresh
    /// WHOOP 4.0 shows zero steps (#37 bringiton321). Steps are built from the strap's synced motion
    /// history, so without a backfill there is nothing to estimate from — calibration can't help yet.
    ///
    /// #107: family-aware. A 4.0 streams motion automatically → "let it sync" is right. A 5/MG only streams
    /// motion once the experimental deep-data unlock is ON — so on a 5/MG the honest advice is "turn that on
    /// and reconnect", not "wait for a sync" (which never comes). Imports don't supply strap motion either.
    private var noMotionNote: some View {
        NoopCard(tint: StrandPalette.metricAmber) {
            VStack(alignment: .leading, spacing: 10) {
                Label("No motion synced yet", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(noMotionLead)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(noMotionAction)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The "why it's empty" line — a 5/MG needs the deep-data unlock before it streams motion at all.
    private var noMotionLead: String {
        if is5MG {
            return String(localized: "We're not seeing any motion from your WHOOP 5.0 / MG yet. Unlike a 4.0, a 5/MG only streams motion (and history) once the experimental deep-data unlock is on — so until then there's nothing to estimate steps from. Importing history from WHOOP or Apple Health doesn't provide the strap motion this needs.")
        }
        return String(localized: "We're not seeing any motion from your strap yet. Steps are estimated from your WHOOP's banked motion history, so your strap needs to sync that history before NOOP has anything to count.")
    }

    /// The "what to do" line — 5/MG points at the deep-data toggle (unless it's already on, then just sync).
    private var noMotionAction: String {
        if is5MG && !deepDataEnabled {
            return String(localized: "Turn on Settings → \u{201C}Unlock WHOOP 5/MG deep data (R22)\u{201D}, reconnect your strap, then open NOOP near it and let a day or two of motion sync. Your step estimate and the calibration below fill in once motion lands.")
        }
        if is5MG {
            return String(localized: "Deep data is on — open NOOP near your strap and let it sync its motion history (a full first-run sync can take a while). Once a day or two of motion lands, your step estimate and the calibration below fill in.")
        }
        return String(localized: "Open NOOP near your strap and let it catch up (a full history sync can take a while on first run). Once a day or two of motion lands, your step estimate and the calibration below will start to fill in.")
    }

    /// The current calibration read-out: coefficient, sample days, and a Low/Medium/High confidence —
    /// or, if nothing's fit yet and no manual value is set, an honest "what we still need" prompt.
    private var currentFitCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current calibration").strandOverline()
                if profile.stepsCalibrationCoefficient > 0 || profile.stepsManualCoefficient > 0 {
                    let coeff = profile.stepsManualCoefficient > 0
                        ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.1f", coeff))
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.accent)
                        Text("steps per motion unit")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if profile.stepsManualCoefficient > 0 {
                        statLine(String(localized: "Source"), String(localized: "Manual (you set this by hand)"))
                    } else {
                        statLine(String(localized: "Fitted from"),
                                 profile.stepsCalibrationSampleDays == 1
                                     ? String(localized: "1 day your phone also counted")
                                     : String(localized: "\(profile.stepsCalibrationSampleDays) days your phone also counted"))
                        statLine(String(localized: "Confidence"), "\(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) · \(Int((profile.stepsCalibrationConfidence * 100).rounded()))%")
                    }
                } else {
                    Text("Not calibrated yet")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    // #589: a concrete countdown instead of a vague "a few days". Headline comes straight
                    // from the engine's needsMoreDays state so the wording matches the Today steps tile.
                    // #693: drive `have` off `profile.stepsCalibrationSampleDays` — the value the engine
                    // persists for the not-yet-calibrated case (IntelligenceEngine.swift sets it to the
                    // usable-day `have`, the SAME source the Today tile reads). `usableMatchedDays` can't be
                    // used here: `loadIfNeeded` early-returns before computing it when coeff == 0 (no fit
                    // yet), so it would always read 0 and the card was stuck on "Need 3 more days".
                    Text(StepsEstimateEngine.CalibrationStatus
                        .needsMoreDays(have: profile.stepsCalibrationSampleDays,
                                       need: StepsEstimateEngine.minCalibrationDays)
                        .headline)
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.accent)
                    Text("These are the days where your phone also counted steps, so NOOP can learn how your motion maps to steps. Or set the coefficient manually below.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The accuracy table: recent days that have BOTH an estimate and a phone count, side by side, so the
    /// user can SEE how close the estimate runs. Empty until enough both-have days exist.
    private var comparisonCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Estimated vs your phone").strandOverline()
                if comparison.isEmpty {
                    Text("No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Column header.
                    HStack {
                        Text("Day").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Est.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Phone").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Δ").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    ForEach(comparison) { row in
                        HStack {
                            Text(Self.shortDay(row.day))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.grouped(row.estimated))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Self.grouped(row.actual))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(String(format: "%+.0f%%", row.errorPct))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(abs(row.errorPct) <= 15
                                                 ? StrandPalette.metricCyan : StrandPalette.statusWarning)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(Self.shortDay(row.day)): estimated \(row.estimated) steps, phone \(row.actual) steps, \(Int(row.errorPct.rounded())) percent difference")
                    }
                    Text("These days are excluded from the estimate (your phone's real count is shown instead). They're here only so you can judge the estimate's accuracy.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Manual override: a slider bound to a draft, committed on release, with a live preview of what a
    /// typical recent day would estimate at the chosen coefficient. 0 returns to auto-fit.
    private var manualAdjustCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adjust manually").strandOverline()
                Text("Override the automatic fit with your own steps-per-motion value. Useful if your phone has no step history to learn from, or the estimate runs consistently high or low. Set it back to auto by dragging to the far left.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draftManual > 0 ? String(format: "%.1f", draftManual) : String(localized: "Auto"))
                        .font(StrandFont.number(24))
                        .foregroundStyle(draftManual > 0 ? StrandPalette.accent : StrandPalette.textSecondary)
                    Text(draftManual > 0 ? "steps / motion unit" : "fit from your phone")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }

                Slider(value: $draftManual, in: 0...sliderMax, step: 0.5) {
                    Text("Manual steps coefficient")
                } minimumValueLabel: {
                    Text("Auto").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } maximumValueLabel: {
                    Text("High").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } onEditingChanged: { editing in
                    // Commit on release — snap a tiny drag back to 0 (auto) so "auto" is reachable.
                    if !editing { profile.stepsManualCoefficient = draftManual < 0.5 ? 0 : draftManual }
                }
                .tint(StrandPalette.accent)
                .accessibilityValue(draftManual > 0
                                    ? "\(String(format: "%.1f", draftManual)) steps per motion unit"
                                    : "Automatic")

                // Live preview: a typical recent day re-estimated at the draft coefficient.
                if let motion = sampleMotion {
                    let effective = draftManual > 0 ? draftManual : profile.stepsCalibrationCoefficient
                    if effective > 0 {
                        let preview = Int((motion * effective).rounded())
                        statLine(String(localized: "A typical recent day"),
                                 draftManual > 0
                                     ? String(localized: "≈ \(Self.grouped(preview)) steps at this setting")
                                     : String(localized: "≈ \(Self.grouped(preview)) steps (auto)"))
                    }
                }
                if draftManual > 0 {
                    Text("Takes effect on the next analytics pass (after the next sync).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// A small "label … value" line shared by the fit + preview cards.
    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 12)
            Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Data

    /// Build the comparison table + a typical-day motion, once. The engine stores `steps_est` ONLY for
    /// strap-only days (a phone-covered day uses the phone's real count), so an estimate and a phone count
    /// never co-exist in storage. To still SHOW "how close the estimate is", we reconstruct what the
    /// estimate WOULD have been on recent phone-covered days: read each day's motion volume the same way
    /// the engine does (gravity over [localMidnight, +24h)) and run the public `StepsEstimateEngine` with
    /// the live calibration. This reuses the engine, never invents a number, and needs no extra storage.
    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        draftManual = profile.stepsManualCoefficient

        // Effective calibration in force right now: a manual override wins, else the persisted auto-fit.
        let coeff = profile.stepsManualCoefficient > 0
            ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient

        // Phone reference steps from Apple Health daily rows (steps > 0 only), newest first.
        let appleRows = await repo.appleDailyRows()
        let phoneDays = appleRows
            .compactMap { row -> (day: String, steps: Int)? in
                guard let s = row.steps, s > 0 else { return nil }
                return (row.day, s)
            }
            .sorted { $0.day > $1.day }

        // Reconstruct the estimate for the most recent phone-covered days, motion-by-motion.
        guard coeff > 0, let store = await repo.storeHandle() else { return }
        let cal = StepsEstimateEngine.Calibration(coefficient: coeff,
                                                  sampleDays: profile.stepsCalibrationSampleDays,
                                                  confidence: profile.stepsCalibrationConfidence,
                                                  manual: profile.stepsManualCoefficient > 0)
        let dayParser = DateFormatter(); dayParser.locale = Locale(identifier: "en_US_POSIX"); dayParser.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        var rows: [StepsComparisonRow] = []
        var motions: [Double] = []
        for entry in phoneDays.prefix(10) {           // scan a few extra to fill 7 after motion gaps
            guard let dayDate = dayParser.date(from: entry.day) else { continue }
            let mid = Int(calendar.startOfDay(for: dayDate).timeIntervalSince1970)
            let grav = (try? await store.gravitySamples(deviceId: repo.deviceId, from: mid,
                                                        to: mid + 86_400 - 1, limit: 200_000)) ?? []
            let motion = StepsEstimateEngine.dayMotionIntensity(grav)
            guard motion > 0, let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
            motions.append(motion)
            rows.append(StepsComparisonRow(day: entry.day, estimated: est, actual: entry.steps))
            if rows.count >= 7 { break }
        }
        comparison = rows
        // #693: the "Need N more days…" countdown is now driven by `profile.stepsCalibrationSampleDays`
        // (the engine-persisted usable-day count, read directly in the card) — NOT a local match count
        // computed here. This scan reaches here ONLY when coeff > 0 (already calibrated), so a local count
        // would never reflect the not-yet-calibrated state the countdown describes. The rows still feed the
        // accuracy table (`comparison`) above.

        // Typical recent day's motion for the live preview = median of the motions we just measured.
        if !motions.isEmpty {
            let s = motions.sorted()
            sampleMotion = s[s.count / 2]
        }
    }

    // MARK: Formatting

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// "yyyy-MM-dd" → "EEE d MMM" for the table's day column.
    private static func shortDay(_ key: String) -> String {
        let inF = DateFormatter(); inF.locale = Locale(identifier: "en_US_POSIX"); inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: key) else { return key }
        let outF = DateFormatter(); outF.dateFormat = "EEE d MMM"
        return outF.string(from: d)
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        // iPhone-width (402pt) so the narrow Backup row stays in the preview's blast radius —
        // at 720 the three-up button row had slack and the truncation regression slipped through. (#188)
        .frame(width: 402, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif

// MARK: - Custom accent colour bridge

private extension Color {
    /// sRGB hex (`#RRGGBB`) for persisting a `ColorPicker` selection into `AccentColor.customHexKey`.
    /// Falls back to nil if the colour can't resolve to sRGB (the caller then keeps the default).
    var noopAccentHex: String? {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        #elseif os(macOS)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
