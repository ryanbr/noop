import SwiftUI
import StrandDesign

/// Automations — turn the strap's physical inputs (double-tap, wrist on/off) and live biometrics
/// into actions (Shortcuts, and Mac-only screen lock) and haptic coaching. All on-device.
struct AutomationsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var behavior: BehaviorStore
    @EnvironmentObject var live: LiveState
    /// Deep-link into the experimental Rhythm visualization (it self-gates on its own consent).
    @EnvironmentObject var router: NavRouter

    /// v5 cycle-awareness opt-in (default OFF — the most sensitive health category, manual-first).
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleAwareness = false
    /// v5 Rhythm experimental gate (the screen still shows its own consent clickwrap when opened).
    @AppStorage(RhythmConsent.enabledKey) private var rhythmEnabled = false
    /// Inactivity reminder (#419) — UI-local store, persisted in UserDefaults. The buzz itself fires
    /// from the BLE offload path (BLEManager.maybeBuzzInactivity → the shipped SedentaryDetector); this
    /// screen only edits the prefs the engine reads.
    @StateObject private var inactivity = InactivityPrefs()

    var body: some View {
        ScreenScaffold(title: "Automations",
                       subtitle: "Make the strap do things — tap to act, walk away to lock, train by feel.") {
            doubleTapCard
            wearCard
            coachingCard
            alarmCard
            inactivityCard
            illnessCard
            healthInsightsCard
            batteryCard
        }
    }

    // MARK: - Double tap

    private var doubleTapCard: some View {
        Section2(icon: "hand.tap.fill", title: "Double-tap",
                 blurb: "Double-tap the strap to trigger an action on \(Platform.deviceNounPhrase). (The strap exposes a single double-tap gesture.)",
                 active: behavior.doubleTapAction != .none) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("When I double-tap").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Picker("", selection: $behavior.doubleTapAction) {
                        ForEach(doubleTapOptions) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if behavior.doubleTapAction == .runShortcut {
                    shortcutField("Shortcut name", text: $behavior.doubleTapShortcut)
                }
                HStack {
                    Button {
                        model.runMacAction(behavior.doubleTapAction, shortcut: behavior.doubleTapShortcut)
                    } label: { Label("Test action", systemImage: "play.fill") }
                    .buttonStyle(.bordered).tint(StrandPalette.accent)
                    .disabled(behavior.doubleTapAction == .none)
                    Spacer()
                    StatePill(live.bonded ? "Strap bonded" : "Strap not connected",
                              tone: live.bonded ? .positive : .warning, showsDot: true)
                }
                if !model.moments.isEmpty {
                    rowDivider
                    momentsView
                }
            }
        }
    }

    private var momentsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent moments").strandOverline()
                Spacer()
                Button("Clear") {
                    model.moments.removeAll()
                    UserDefaults.standard.removeObject(forKey: "moments")
                }
                .buttonStyle(.plain).font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
            }
            ForEach(Array(model.moments.suffix(5).reversed().enumerated()), id: \.offset) { _, d in
                Text(Self.momentFormatter.string(from: d))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
    private static let momentFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        // Keep the "EEE d MMM ·" layout but honor the device's 12-/24-hour clock (#337): the "j"
        // template resolves to a 12-hour pattern (contains "a") only where the user prefers it.
        let uses24h = !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H").contains("a")
        f.dateFormat = "EEE d MMM · " + (uses24h ? "HH:mm" : "h:mm a")
        return f
    }()

    // MARK: - Wear & presence

    private var wearCard: some View {
        Section2(icon: "figure.walk.motion", title: "Wear & presence",
                 blurb: wearBlurb,
                 active: wearActive) {
            VStack(spacing: 0) {
                #if os(macOS)
                ToggleRow(label: "Lock the Mac when I take the strap off",
                          help: "Fires the moment the strap leaves your wrist.",
                          isOn: $behavior.autoLockOnWristOff)
                rowDivider
                #endif
                shortcutFieldRow("Run a Shortcut when taken off",
                                 help: "Presence automation — set a Focus, pause media, set away…",
                                 text: $behavior.wristOffShortcut)
                rowDivider
                shortcutFieldRow("Run a Shortcut when put back on",
                                 help: "Reverse the above when you return.",
                                 text: $behavior.wristOnShortcut)
            }
        }
    }

    // MARK: - Coaching

    private var coachingCard: some View {
        Section2(icon: "bolt.heart.fill", title: "Haptic coaching",
                 blurb: "Train by feel — the strap buzzes so you don't have to watch a screen.",
                 active: behavior.zoneCoaching || behavior.stressNudge || behavior.stressCheckIn) {
            VStack(spacing: 0) {
                ToggleRow(label: "HR-zone coaching",
                          help: "Buzz when you hit your top zone (ease off) and again when you recover. Uses your max HR from Settings.",
                          isOn: $behavior.zoneCoaching)
                rowDivider
                ToggleRow(label: "Resting stress nudge (experimental)",
                          help: "A gentle buzz when your HRV drops while your heart rate is calm — a cue to take a paced breath. Rate-limited to once every 15 minutes; off by default.",
                          isOn: $behavior.stressNudge)
                rowDivider
                // v5 L3 closed-loop check-in (master + sub toggles). Default OFF, manual-first. The keys
                // mirror BiofeedbackPrefs, which the central detector (AppModel.evaluateStress) reads.
                ToggleRow(label: "Stress check-ins (haptic)",
                          help: "When a fresh, non-exercise HRV dip is detected while you're still, NOOP offers a one-minute guided breath — a single confirming buzz and a dismissible card. Never an alarm, never a diagnosis.",
                          isOn: $behavior.stressCheckIn)
                if behavior.stressCheckIn {
                    rowDivider
                    ToggleRow(label: "Auto-nudge",
                              help: "Let the check-in fire on its own. Off keeps it manual — you start a breath from Breathe yourself.",
                              isOn: $behavior.stressAutoNudge)
                    rowDivider
                    ToggleRow(label: "Respect quiet hours",
                              help: "Suppress auto-nudges overnight (10pm–7am).",
                              isOn: $behavior.stressQuietHours)
                    rowDivider
                    ToggleRow(label: "Use my resonance pace",
                              help: "Breathe at the pace your last \u{201C}find my pace\u{201D} sweep locked in, if you have one — otherwise a calm 5.5 breaths/min.",
                              isOn: $behavior.stressUseResonancePace)
                }
            }
        }
    }

    // MARK: - Smart alarm

    private var alarmCard: some View {
        Section2(icon: "alarm.fill", title: "Smart alarm",
                 blurb: "Wake to a buzz from the strap's own firmware alarm. Experimental — a strap-driven wake hasn't been verified firing yet on WHOOP 4.0 or 5/MG, so keep a backup alarm.",
                 active: behavior.smartAlarmEnabled) {
            VStack(spacing: 0) {
                ToggleRow(label: "Enable smart alarm", help: "Arms the strap to buzz at your wake time.",
                          isOn: $behavior.smartAlarmEnabled)
                if behavior.smartAlarmEnabled {
                    rowDivider
                    HStack {
                        Text("Wake at").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: alarmTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden().datePickerStyle(.compact)
                    }
                    .frame(minHeight: 42).padding(.vertical, 4)
                }
                if behavior.smartAlarmEnabled {
                    Text("Experimental. NOOP arms the strap's own alarm and the strap acknowledges it, but a strap-driven wake-up hasn't been verified firing from a report yet — on WHOOP 4.0 or 5/MG — so please keep a backup alarm on your phone for now. We're confirming the exact firmware buzz pattern before we call this proven.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            .onChangeCompat(of: behavior.smartAlarmEnabled) { _ in model.applySmartAlarm() }
            .onChangeCompat(of: behavior.smartAlarmMinutes) { _ in model.applySmartAlarm() }
        }
    }

    // MARK: - Inactivity reminder (#419)

    private var inactivityCard: some View {
        Section2(icon: "timer", title: "Inactivity reminder",
                 blurb: "A gentle wrist buzz when you've been sitting too long — a nudge to get up and move. Inferred from the strap's motion on each history sync, so it lags real time by a sync or two.",
                 active: inactivity.enabled) {
            VStack(spacing: 0) {
                ToggleRow(label: "Enable inactivity reminder",
                          help: "Buzzes after you've been sitting past your threshold.",
                          isOn: $inactivity.enabled)
                if inactivity.enabled {
                    if !notifMasterOn {
                        Text("Notifications are off, so this can't buzz yet — turn on the master switch in Notifications to let it through.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    rowDivider
                    stepperRow(label: "Sitting for", help: "Minutes seated before the first nudge.",
                               value: $inactivity.thresholdMinutes, suffix: "min", range: 15...120, step: 15)
                    rowDivider
                    stepperRow(label: "Re-nudge every", help: "If you're still seated, buzz again this often.",
                               value: $inactivity.reNudgeMinutes, suffix: "min", range: 15...120, step: 15)
                    rowDivider
                    stepperRow(label: "Buzz strength", help: "How strong the buzz is.",
                               value: $inactivity.buzzLoops, suffix: "×", range: 1...4, step: 1)
                    rowDivider
                    // Reuses the shared notification only-when-worn gate (notif.onlyWhenWorn).
                    ToggleRow(label: "Only when worn",
                              help: "Don't buzz when the strap is off your wrist.",
                              isOn: onlyWhenWornBinding)
                    rowDivider
                    ToggleRow(label: "Only during active hours",
                              help: "Only nudge during your active hours.",
                              isOn: $inactivity.activeHoursEnabled)
                    if inactivity.activeHoursEnabled {
                        rowDivider
                        HStack(spacing: 12) {
                            Text("From").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            DatePicker("", selection: activeStartBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden().datePickerStyle(.compact)
                                .accessibilityLabel("Active hours start")
                            Text("to").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                            DatePicker("", selection: activeEndBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden().datePickerStyle(.compact)
                                .accessibilityLabel("Active hours end")
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 42).padding(.vertical, 4)
                    }
                }
            }
        }
    }

    /// The reused global notification master (notif.masterEnabled, default OFF) — drives the inert-feature
    /// warning so enabling the reminder while master is off isn't silently a no-op.
    private var notifMasterOn: Bool {
        UserDefaults.standard.object(forKey: "notif.masterEnabled") as? Bool ?? false
    }
    /// The reused only-when-worn gate (notif.onlyWhenWorn, default ON) — the SAME key the notifications
    /// screen and the engine read, so the two screens stay in sync.
    private var onlyWhenWornBinding: Binding<Bool> {
        Binding(get: { UserDefaults.standard.object(forKey: "notif.onlyWhenWorn") as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: "notif.onlyWhenWorn") })
    }
    private var activeStartBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeStartMinutes) },
                set: { inactivity.activeStartMinutes = Self.minutes(from: $0) })
    }
    private var activeEndBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: inactivity.activeEndMinutes) },
                set: { inactivity.activeEndMinutes = Self.minutes(from: $0) })
    }

    /// A label/help row with a native −[value]+ stepper, clamped to `range` and moved by `step`.
    private func stepperRow(label: String, help: String, value: Binding<Int>,
                            suffix: String, range: ClosedRange<Int>, step: Int) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("\(value.wrappedValue) \(suffix)")
                .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            Stepper("", value: value, in: range, step: step).labelsHidden()
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }

    // MARK: - Illness early-warning

    private var illnessCard: some View {
        Section2(icon: "waveform.path.ecg", title: "Illness early-warning",
                 blurb: "Watches your resting HR, HRV, skin temperature and respiration against your own 28-day baseline. On-device and approximate — informational only, not a diagnosis.",
                 active: behavior.illnessWatch) {
            ToggleRow(label: "Watch for early-illness signs",
                      help: "Needs at least 14 days of history. When two or more signals drift together you get a banner on the dashboard and a notification — at most once a day.",
                      isOn: $behavior.illnessWatch)
                .onChangeCompat(of: behavior.illnessWatch) { _ in
                    model.reevaluateIllness()
                    if behavior.illnessWatch { IllnessNotifier.requestAuthorization() }
                }
        }
    }

    // MARK: - Health insights (v5: cycle awareness opt-in · experimental Rhythm)

    private var healthInsightsCard: some View {
        Section2(icon: "thermometer.medium", title: "Health insights",
                 blurb: "Optional, on-device reads from your nightly signals. Each is off by default — for awareness only, never a diagnosis.",
                 active: cycleAwareness || rhythmEnabled) {
            VStack(spacing: 0) {
                ToggleRow(label: "Cycle awareness",
                          help: "Reads a coarse menstrual-cycle phase from your nightly skin temperature, entirely on \(Platform.deviceNounPhrase). Awareness only — not contraception, not a fertility predictor, not a medical service. The card appears in Health.",
                          isOn: $cycleAwareness)
                    .onChangeCompat(of: cycleAwareness) { on in
                        model.cycleAwarenessEnabled = on
                        Task { await model.refreshV5Signals() }
                    }
                rowDivider
                ToggleRow(label: "Rhythm visualization (experimental)",
                          help: "An experimental picture of your beat-to-beat heart timing. Not an ECG and not a diagnosis. You'll read and accept an experimental note before it shows anything.",
                          isOn: $rhythmEnabled)
                if rhythmEnabled {
                    rowDivider
                    HStack {
                        Text("Open Rhythm").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Button {
                            router.openRhythm()
                        } label: { Label("Open", systemImage: "waveform.path") }
                        .buttonStyle(.bordered).tint(StrandPalette.accent)
                    }
                    .frame(minHeight: 42).padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Strap battery alerts

    private var batteryCard: some View {
        Section2(icon: "battery.25", title: "Battery alerts",
                 blurb: "Get a notification when the strap battery runs low (15%) so you can top it up before tonight, and when it finishes charging.",
                 active: behavior.batteryAlerts) {
            ToggleRow(label: "Notify on low and full battery",
                      help: "A reminder to recharge before bed when the strap drops to 15%, and a heads-up when it reaches 100% — each at most once per charge cycle.",
                      isOn: $behavior.batteryAlerts)
                .onChangeCompat(of: behavior.batteryAlerts) { on in
                    if on { BatteryNotifier.requestAuthorization() }
                }
        }
    }

    // MARK: - Helpers

    /// Double-tap actions offered in the picker. The "Lock the Mac" action can't work on iPhone
    /// (a third-party app can't lock iOS), so it's dropped there.
    private var doubleTapOptions: [MacActionKind] {
        #if os(iOS)
        MacActionKind.allCases.filter { $0 != .lockScreen }
        #else
        MacActionKind.allCases
        #endif
    }

    /// Wear & presence blurb. macOS mentions the auto-lock affordance (and the Apple-Watch unlock
    /// caveat); iOS, where that toggle is hidden, describes the Shortcut-driven presence reactions.
    /// Wear & presence is "active" when any of its reactions are configured: a wrist-on/off Shortcut,
    /// or (macOS) the auto-lock toggle. Presentation-only — drives the card's accent state.
    private var wearActive: Bool {
        let shortcuts = !behavior.wristOffShortcut.isEmpty || !behavior.wristOnShortcut.isEmpty
        #if os(macOS)
        return shortcuts || behavior.autoLockOnWristOff
        #else
        return shortcuts
        #endif
    }

    private var wearBlurb: String {
        #if os(macOS)
        "React when the strap comes off or goes on. Note: macOS reserves true auto-UNLOCK for Apple Watch — this can lock, not unlock."
        #else
        "React when the strap comes off or goes on — run a Shortcut to set a Focus, pause media, mark yourself away."
        #endif
    }

    private var alarmTimeBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: behavior.smartAlarmMinutes) },
                set: { behavior.smartAlarmMinutes = Self.minutes(from: $0) })
    }
    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func shortcutField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(StrandFont.body)
            .frame(maxWidth: 320)
    }

    private func shortcutFieldRow(_ label: String, help: String, text: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            shortcutField("Shortcut name", text: text)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }

    private var rowDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.vertical, 4)
    }
}

// MARK: - Local section + row (mirrors the settings idiom)

private struct Section2<Content: View>: View {
    let icon: String; let title: String; var blurb: String? = nil
    /// When this automation is enabled the card carries a brighter brand-green wash; otherwise a
    /// faint one — so an active automation reads at a glance. Presentation-only.
    var active: Bool = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        StrandCard(padding: 20, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Automation").strandOverline()
                        if active {
                            Text("ON").font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .foregroundStyle(active ? StrandPalette.accent : StrandPalette.textSecondary)
                            .accessibilityHidden(true)
                        Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                if let blurb {
                    Text(blurb).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
    }
}

private struct ToggleRow: View {
    let label: String; let help: String; @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42).padding(.vertical, 4)
    }
}
