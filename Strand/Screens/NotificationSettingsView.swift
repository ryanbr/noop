import SwiftUI
import AppKit
import StrandDesign

/// Notifications — choose which Mac apps tap your wrist, and how.
/// Real app icons via NSWorkspace; per-app on/off + buzz pattern; quiet hours.
struct NotificationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @StateObject private var store = NotificationSettingsStore()

    var body: some View {
        ScreenScaffold(title: "Notifications",
                       subtitle: "Buzz your strap when these apps notify you. Everything runs on \(Platform.deviceNounPhrase).") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                masterCard
                    .staggeredAppear(index: 0)
                // #926: on a 5/MG the buzz payload is a hardcoded 12-byte literal whose byte[11]
                // (overallLoop) is 0, so the caller's repeat count never reaches the wire — every
                // BuzzPattern produces the same buzz. The picker still offers all four because the choice
                // is stored per app and DOES apply to a WHOOP 4.0, so hiding it would lose a real setting.
                // Say so instead, the way SmartAlarmView handles its own 5/MG-unconfirmed case, rather
                // than leaving a control that silently does nothing.
                if model.whoop5Detected {
                    Text("Every pattern buzzes the same on a WHOOP 5/MG — the repeat count isn't sent to that strap. Your choice is saved and applies to a WHOOP 4.0.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .staggeredAppear(index: 0)
                }
                if store.activeCategories.isEmpty {
                    emptyAppsCard
                        .staggeredAppear(index: 1)
                } else {
                    ForEach(Array(store.activeCategories.enumerated()), id: \.element.id) { idx, cat in
                        categoryCard(cat, apps: store.apps(in: cat))
                            .staggeredAppear(index: idx + 1)
                    }
                }
                behaviourCard
                    .staggeredAppear(index: store.activeCategories.count + 1)
            }
        }
    }

    // MARK: - Master

    private var masterCard: some View {
        AlertSection(icon: "bell.badge.fill", title: String(localized: "Wrist alerts"),
                     blurb: String(localized: "When on, NOOP taps your wrist for the apps you pick below, so you can leave the \(Platform.deviceNoun) and still feel what matters.")) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Toggle(isOn: $store.masterEnabled) {
                    Text("Enable wrist alerts")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)

                HStack(spacing: 10) {
                    StatePill("\(strapPillTitle)", tone: strapPillTone, pulsing: live.connected)
                    StatePill(store.enabledCount == 1 ? "1 app on" : "\(store.enabledCount) apps on",
                              tone: store.enabledCount > 0 ? .positive : .neutral,
                              showsDot: false)
                    Spacer(minLength: 0)
                    Button {
                        model.buzz(loops: 2)
                    } label: {
                        Label("Test buzz", systemImage: "waveform.path")
                    }
                    .buttonStyle(NoopButtonStyle(.secondary))
                    .disabled(!live.bonded)
                    .help(live.bonded ? "Fire a test buzz now" : "Connect your strap to test")
                    .accessibilityHint(live.bonded ? "Fires a test buzz on your strap" : "Connect your strap to enable")
                }

                deliveryNote
            }
        }
    }

    private var deliveryNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(StrandPalette.accent)
                .font(.system(size: 13))
                .accessibilityHidden(true)
            Text("Wrist delivery isn't live yet. It needs a small on-device watcher (coming in an update) to read macOS notifications. Everything stays on this Mac. Your choices are saved now and will apply automatically once delivery ships.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(tint: StrandPalette.accent, cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(StrandPalette.accent.opacity(0.22), lineWidth: 1))
    }

    /// Strap status — mirrors SettingsView's three-state mapping so the pill, its tone and its
    /// pulse always agree (and never reads "connected" while the strap is offline).
    private var strapPillTitle: String {
        if live.connected { return String(localized: "Strap connected") }
        if live.bonded { return String(localized: "Strap idle") }          // paired but offline — won't deliver
        return String(localized: "Strap not connected")
    }
    private var strapPillTone: StrandTone {
        if live.connected { return .positive }
        if live.bonded { return .warning }
        return .critical
    }

    // MARK: - Category card

    private func categoryCard(_ cat: NotifCategory, apps: [NotifApp]) -> some View {
        AlertSection(icon: cat.symbol, title: cat.rawValue) {
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { idx, app in
                    appRow(app)
                    if idx < apps.count - 1 { rowDivider }
                }
            }
        }
        .opacity(store.masterEnabled ? 1 : StrandPalette.disabledOpacity)
        .disabled(!store.masterEnabled)
    }

    private var emptyAppsCard: some View {
        AlertSection(icon: "bell.slash",
                     title: String(localized: "No supported apps found"),
                     blurb: String(localized: "NOOP looks for known notification apps on \(Platform.deviceNounPhrase): Mail, Outlook, WhatsApp, Teams, Messages, Slack and similar. Install one and it'll appear here automatically.")) {
            EmptyView()
        }
    }

    private func appRow(_ app: NotifApp) -> some View {
        let enabled = store.isEnabled(app.id)
        return HStack(spacing: 12) {
            appIcon(app)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(enabled ? "Buzzes your wrist" : "Off")
                    .font(StrandFont.footnote)
                    .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
            }

            Spacer(minLength: 8)

            if enabled {
                patternMenu(app)
                testButton(app)
            }

            Toggle("", isOn: Binding(
                get: { store.isEnabled(app.id) },
                set: { store.setEnabled(app.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityLabel("\(app.name) wrist alerts")
        }
        .frame(minHeight: 42)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        // An enabled app reads as a selected row: a soft accentMuted wash behind it.
        .background(enabled ? StrandPalette.accentMuted : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func appIcon(_ app: NotifApp) -> some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(StrandPalette.surfaceInset)
                    .overlay(Image(systemName: app.fallbackSymbol)
                        .foregroundStyle(StrandPalette.textSecondary))
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func patternMenu(_ app: NotifApp) -> some View {
        Menu {
            ForEach(BuzzPattern.allCases) { p in
                Button {
                    store.setPattern(app.id, p)
                } label: {
                    if store.pattern(app.id) == p {
                        Label(p.label, systemImage: "checkmark")
                    } else {
                        Text(p.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path").font(.system(size: 11))
                Text(store.pattern(app.id).label).font(StrandFont.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(StrandPalette.surfaceInset, in: Capsule())
            .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the buzz pattern for \(app.name)")
    }

    private func testButton(_ app: NotifApp) -> some View {
        Button {
            model.buzz(loops: store.pattern(app.id).loops)
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 11))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
        .tint(StrandPalette.accent)
        .disabled(!live.bonded)
        .help(live.bonded ? "Test \(app.name) buzz" : "Connect your strap to test")
        .accessibilityLabel("Test \(app.name) buzz")
        .accessibilityHint(live.bonded ? "Fires a test buzz on your strap" : "Connect your strap to enable")
    }

    // MARK: - Behaviour

    private var behaviourCard: some View {
        AlertSection(icon: "slider.horizontal.3", title: String(localized: "Behaviour"),
                     blurb: String(localized: "Fine-tune when alerts reach your wrist.")) {
            VStack(spacing: 0) {
                FormToggleRow(label: String(localized: "Only buzz when worn"),
                              help: String(localized: "Skip alerts when the strap is off your wrist."),
                              isOn: $store.onlyWhenWorn)
                rowDivider
                FormToggleRow(label: String(localized: "Quiet hours"),
                              help: String(localized: "Mute wrist alerts overnight."),
                              isOn: $store.quietHoursEnabled)
                if store.quietHoursEnabled {
                    rowDivider
                    HStack(spacing: 12) {
                        Text("From")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        DatePicker("", selection: quietStartBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .accessibilityLabel("Quiet hours start")
                        Text("to")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                        DatePicker("", selection: quietEndBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .accessibilityLabel("Quiet hours end")
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 42)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Quiet-hours bindings

    private var quietStartBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: store.quietStartMinutes) },
                set: { store.quietStartMinutes = Self.minutes(from: $0) })
    }
    private var quietEndBinding: Binding<Date> {
        Binding(get: { Self.date(fromMinutes: store.quietEndMinutes) },
                set: { store.quietEndMinutes = Self.minutes(from: $0) })
    }
    private static func date(fromMinutes m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(from d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: - Shared

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - Section card (icon + title header, optional blurb, content)

private struct AlertSection<Content: View>: View {
    let icon: String
    let title: String
    var blurb: String? = nil
    /// The section overline ("Alerts" by default). Lets a section group itself in the Bevel idiom.
    var overline: String = String(localized: "Alerts")
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: 20, tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(overline)").strandOverline()
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: icon)
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                if let blurb {
                    Text(blurb)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
        }
    }
}

// MARK: - Label + help + switch row

private struct FormToggleRow: View {
    let label: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(help)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 42)
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Notifications") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    return NotificationSettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 760, height: 940)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
