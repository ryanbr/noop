import SwiftUI
import StrandDesign

/// The compact Coach launcher opened from the optional Today card (#1862).
///
/// Coach is otherwise reachable only through More/Insights, which makes it easy to miss and means
/// leaving Today to try it. This is the shortcut — and deliberately ONLY a shortcut.
///
/// It owns no send, stream, error or consent surface of its own. Picking a suggestion or submitting the
/// composer hands the question to `AICoachEngine.pendingPrompt` and routes to `CoachView`, which already
/// has all of that. A second chat UI would drift from the first, and the issue explicitly defers the
/// persistent-workspace redesign (threads, retention, backup policy) to a follow-up.
///
/// NO PROVIDER REQUEST IS MADE BY OPENING THIS. Everything shown is local: `isConfigured` reads the
/// stored key, and the prompts are static copy. The first network call still happens where it always
/// did — inside `AICoachEngine.send`, after an explicit user action.
struct CoachLauncherSheet: View {
    @EnvironmentObject var coach: AICoachEngine
    @EnvironmentObject var router: NavRouter
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if coach.isConfigured {
                        configured
                    } else {
                        unconfigured
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text("Coach"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    // MARK: Configured — suggestions + a compact composer

    @ViewBuilder
    private var configured: some View {
        Text("Ask about your charge, effort, rest and workouts, grounded in your own numbers.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)

        // Deliberately no "Try asking" heading: the line above already frames the list, and a new
        // literal would be the only string in this card needing translation into ten locales. The whole
        // launcher reuses copy the Coach screen already ships.

        ForEach(CoachPrompts.suggestions, id: \.self) { prompt in
            Button { hand(off: prompt) } label: {
                Text(prompt)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Suggested prompt: \(prompt)"))
        }

        HStack(spacing: 8) {
            TextField("Ask your coach…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius))
                .onSubmit { submitDraft() }
            Button {
                submitDraft()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(trimmedDraft.isEmpty)
            .accessibilityLabel(Text("Send"))
        }
        .padding(.top, 4)
    }

    // MARK: Not configured — explain the opt-in and route to the existing setup

    @ViewBuilder
    private var unconfigured: some View {
        // The SAME explanation the Coach screen shows, so the bring-your-own-key model is described
        // once. The button routes to that screen, which stays the only place a key is entered.
        Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)

        Button {
            dismiss()
            router.openCoach()
        } label: {
            Text("Connect a provider")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Handoff

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitDraft() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        hand(off: text)
    }

    /// Dismiss, park the question, and open Coach. Deliberately NOT `coach.send` from here: the launcher
    /// never performs a provider request, so a user who opens this sheet and changes their mind has cost
    /// nothing and sent nothing.
    private func hand(off prompt: String) {
        coach.pendingPrompt = prompt
        draft = ""
        dismiss()
        router.openCoach()
    }
}
