import SwiftUI
import StrandDesign

/// Coach settings, split out of `CoachView` so the coach screen is the conversation and nothing else
/// (#2243). Holds the surfaces that used to stack above the transcript: the data-sharing consent, the
/// two further opt-ins that depend on it, the editable coach instructions, and the morning brief.
///
/// Connection management (the provider pill, Clear conversation, Disconnect) deliberately stays on
/// `CoachView`. Disconnect is the only route back to the setup card, which is the only place a key can
/// be typed, and #2206 is the record of what happened the last time that control was put somewhere a
/// presentation did not render it. The Kotlin twin `CoachSettingsScreen` splits on the same line.
///
/// Presented as a sheet rather than pushed. CoachView appears in three places between the two
/// platforms (a macOS route, an iPhone tab root whose navigation bar is hidden, and an iPhone pillar
/// sheet), and a sheet is the one presentation that behaves the same in all three without depending on
/// an enclosing NavigationStack.
struct CoachSettingsView: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    /// Morning-brief settings, read from `CoachBriefScheduler` on init exactly as `CoachView` did
    /// before the split. This screen can now be the first to render them.
    @State private var briefEnabled: Bool = CoachBriefScheduler.isEnabled
    @State private var briefMinutes: Int = CoachBriefScheduler.timeMinutes
    @State private var briefGenerating = false
    @State private var briefStatus: String?

    /// The coach-instructions editor, collapsed until asked for.
    @State private var promptExpanded: Bool = false
    @State private var promptDraft: String = ""

    var body: some View {
        // Literals, not String(localized:): `title`/`subtitle` are LocalizedStringKey, which converts
        // from a string LITERAL only, so a String value does not type-check here. The catalog keys are
        // these exact English strings.
        //
        // Done goes in the scaffold's `trailing` slot rather than a .toolbar. ScreenScaffold is a bare
        // ScrollView with no NavigationStack, so a toolbar item presented in a sheet would render
        // nowhere, and a macOS sheet has no swipe-to-dismiss: that combination would leave this screen
        // with no way out. (#2206 is the same mistake in the other direction.)
        ScreenScaffold(title: "Coach settings",
                       subtitle: "What the coach may read, how it is told to answer, and when it writes to you.",
                       topBackground: liquidScaffoldSky(),
                       trailing: {
                           Button("Done") { dismiss() }
                               .buttonStyle(.plain)
                               .font(StrandFont.subhead)
                               .foregroundStyle(StrandPalette.accent)
                               .accessibilityLabel("Close coach settings")
                       }) {
            consentBar
            // v5: a SECOND opt-in, only meaningful once data access is on, folds a summary of the
            // new on-device signals (your strongest patterns + Lab Book) into the coach context.
            if coach.dataConsent { onDeviceSignalsBar }
            if coach.dataConsent && coach.provider == .gemini { multimodalChartBar }
            systemPromptBar
            morningBriefBar
        }
    }

    /// Explicit, revocable permission for the coach to read & send the user's data. Off by default.
    /// A frosted Charge-tinted card so it reads as part of the green Coach world, not a flat panel.
    private var consentBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.dataConsent ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(coach.dataConsent ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let the coach use my data")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    // The ON line NAMES what a session carries rather than saying "workouts" and
                    // leaving the reader to guess how much that is: the sport, how long, how far and how
                    // hard, per session. This toggle is the only place someone is asked to agree to it.
                    // Android says the same sentence (#2033).
                    Text(coach.dataConsent
                         ? "On: your charge, rest, HRV and workouts are sent to the provider, each workout with its sport, duration, distance and heart rate."
                         : "Off: the coach answers generally and sends none of your metrics.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.dataConsent)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach use my data")
            }
        }
    }

    /// The v5 second opt-in: include a SUMMARY of the new on-device signals (strongest n-of-1 patterns +
    /// Lab Book markers). Summary-only, never raw readings, so the no-raw-egress posture holds.
    private var onDeviceSignalsBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.includeOnDeviceSignals ? "checklist.checked" : "checklist")
                    .foregroundStyle(coach.includeOnDeviceSignals ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Also share my patterns & Lab Book")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.includeOnDeviceSignals
                         ? "On: a short summary of your strongest patterns and logged health numbers is added. Summaries only, never raw readings."
                         : "Off: only your core metrics are shared, not your patterns or Lab Book.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.includeOnDeviceSignals)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Also share my patterns and Lab Book with the coach")
            }
        }
    }

    /// K11: Third opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. Only shown when the provider is Gemini. OFF by default.
    private var multimodalChartBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.multimodalChartEnabled ? "photo.badge.checkmark" : "photo")
                    .foregroundStyle(coach.multimodalChartEnabled ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send chart image to Gemini")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.multimodalChartEnabled
                         ? "On: a chart snapshot of your trends is sent with each question. Gemini can analyze the visual."
                         : "Off: only text is sent. Enable to let Gemini see your charts.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.multimodalChartEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Send chart image to Gemini")
            }
        }
    }

    /// Editable system prompt, the instructions that frame the coach. Collapsed by default; expanding
    /// reveals a TextEditor bound to the engine (edits persist to UserDefaults and take effect on the
    /// next message) plus a Reset-to-default control.
    private var systemPromptBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: promptExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        promptExpanded.toggle()
                        if promptExpanded { promptDraft = coach.customSystemPrompt }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(coach.hasCustomSystemPrompt ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach instructions")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coach.hasCustomSystemPrompt
                                 ? "Customised. Your edited instructions frame every reply."
                                 : "Edit how the coach thinks and talks. Takes effect on your next message.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: promptExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(promptExpanded ? "Collapse coach instructions" : "Edit coach instructions")

                if promptExpanded {
                    TextEditor(text: $promptDraft)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140, maxHeight: 240)
                        .padding(8)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onChangeCompat(of: promptDraft) { newValue in
                            coach.customSystemPrompt = newValue
                        }
                        .accessibilityLabel("Coach instructions editor")

                    HStack {
                        Spacer()
                        Button {
                            coach.resetSystemPrompt()
                            promptDraft = coach.customSystemPrompt
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                                .font(StrandFont.footnote)
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(!coach.hasCustomSystemPrompt)
                        .accessibilityLabel("Reset coach instructions to default")
                    }
                }
            }
        }
    }

    /// K5: the scheduled morning-brief notification settings — enable toggle, time-of-day picker, and an
    /// explicit "Generate now" button. Mirrors the `ScheduledDebugExport` settings row shape (TestCentreView).
    private var morningBriefBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: briefEnabled ? "sunrise.fill" : "sunrise")
                        .foregroundStyle(briefEnabled ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Morning brief").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(briefEnabled
                             ? "A local notification with today's readiness + training plan, generated on-device each morning."
                             : "Off: nothing is generated or sent on a schedule.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $briefEnabled)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Morning brief")
                }
                .onChangeCompat(of: briefEnabled) { on in
                    CoachBriefScheduler.setEnabled(on, generateBrief: { await coach.generateBrief() }) { outcome in
                        if outcome == .denied {
                            briefEnabled = false
                            briefStatus = "Notifications are off for NOOP — enable them in Settings first."
                        }
                    }
                }

                if briefEnabled {
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Time").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: briefTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Morning brief time")
                    }
                    Text("At \(Platform.deviceNounPhrase == "Mac" ? "this time" : "or soon after"), NOOP will use your key to generate today's brief. Best-effort: \(Platform.deviceNounPhrase) decides exactly when a backgrounded app wakes.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButton(briefGenerating ? "Generating…" : "Generate now", systemImage: "sparkles", kind: .secondary) {
                        generateBriefNow()
                    }
                    .disabled(briefGenerating)
                    if let briefStatus {
                        Text(briefStatus).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var briefTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = briefMinutes / 60
                c.minute = briefMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                briefMinutes = m
                CoachBriefScheduler.setTimeMinutes(m, generateBrief: { await coach.generateBrief() })
            }
        )
    }

    private func generateBriefNow() {
        Task {
            briefGenerating = true
            briefStatus = nil
            defer { briefGenerating = false }
            let text = await CoachBriefScheduler.generateNow { await coach.generateBrief() }
            if let text {
                coach.appendGeneratedBrief(text)
            } else {
                briefStatus = "Couldn't generate a brief right now — check your key and data access."
            }
        }
    }
}
