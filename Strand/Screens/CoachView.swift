import SwiftUI
import MarkdownUI
import StrandDesign

/// Coach — the one feature in NOOP that talks to the network.
///
/// It is strictly opt-in and bring-your-own-key: the user pastes their own OpenAI
/// or Anthropic API key (stored in the macOS Keychain by `AICoachEngine`), and only
/// a compact text summary of their metrics plus their question ever leaves the Mac.
/// Nothing is sent until a key is saved and a question asked.
///
/// This screen compiles against `AICoachEngine`'s public API (the macos-core agent's
/// contract): `hasKey`, `provider` / `provider.modelOptions`, `model`, `messages`,
/// `sending`, `errorText`, `setKey(_:)`, `clearKey()`, and `send(_:)`.
struct CoachView: View {
    @EnvironmentObject var coach: AICoachEngine

    /// Draft text in the composer (the question being typed).
    @State private var draft: String = ""
    /// Pending key text in the setup card (never persisted here — handed to `setKey`).
    @State private var keyDraft: String = ""
    /// Whether the model selector is in free-text "Custom…" mode.
    @State private var customModel: Bool = false
    /// The id typed in the "Custom…" field.
    @State private var customModelDraft: String = ""
    @FocusState private var composerFocused: Bool

    /// Sentinel tag for the "Custom…" entry in the model Picker.
    private let customModelTag = "__custom__"

    private let suggestions = [
        "How's my recovery trending?",
        "What should today's training look like?",
        "Analyse my sleep",
        "Why am I run down?",
    ]

    var body: some View {
        ScreenScaffold(title: "Coach",
                       subtitle: "Ask about your recovery, strain, sleep and workouts — grounded in your own numbers.") {
            if coach.isConfigured {
                connectedHeader
                consentBar
                transcript
                if let error = coach.errorText, !error.isEmpty {
                    errorBanner(error)
                }
                suggestionChips
                composer
                privacyFootnote
            } else {
                setupCard
            }
        }
        .toolbar {
            if coach.isConfigured {
                ToolbarItem {
                    Button(role: .destructive) {
                        coach.disconnect()
                        keyDraft = ""
                    } label: {
                        Label("Disconnect", systemImage: "gearshape")
                    }
                    .help("Forget the saved key and disconnect")
                    .accessibilityLabel("Disconnect provider")
                }
            }
        }
        .task(id: coach.dataConsent) { await coach.startBriefIfNeeded() }
    }

    /// Explicit, revocable permission for the coach to read & send the user's data. Off by default.
    private var consentBar: some View {
        HStack(spacing: 10) {
            Image(systemName: coach.dataConsent ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(coach.dataConsent ? StrandPalette.accent : StrandPalette.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Let the coach use my data")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(coach.dataConsent
                     ? "On — your recovery, sleep, HRV and workouts are shared with the provider for tailored coaching."
                     : "Off — the coach answers generally and sends none of your metrics.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $coach.dataConsent)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                .accessibilityLabel("Let the coach use my data")
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    // MARK: - Setup (no key yet)

    private var setupCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Connect a provider")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the macOS Keychain and never leaves your Mac except as the request you make.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Provider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").strandOverline()
                    Picker("Provider", selection: $coach.provider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Provider")
                }

                // Server URL (Custom / local LLM only)
                if coach.provider == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL").strandOverline()
                        TextField("http://localhost:11434/v1", text: $coach.customBaseURL)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .disableAutocorrection(true)
                            .accessibilityLabel("Server URL")
                        Text("Any OpenAI-compatible server — Ollama, LM Studio, llama.cpp, or your own gateway. Stays on your network; nothing leaves your Mac.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Model
                modelSelector

                // Key
                VStack(alignment: .leading, spacing: 6) {
                    Text(coach.provider == .custom ? "API key (optional)" : "API key").strandOverline()
                    SecureField(coach.provider == .custom
                                ? "Only if your server requires one"
                                : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onSubmit { coach.provider == .custom ? connectCustom() : saveKey() }
                        .accessibilityLabel("API key")
                }

                HStack {
                    if coach.provider == .custom {
                        Button(action: connectCustom) {
                            Text("Connect").frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)
                        .disabled(coach.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button(action: saveKey) {
                            Text("Save key").frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Spacer()
                }

                Divider().overlay(StrandPalette.hairline)
                privacyFootnote
            }
        }
    }

    /// Model selector: a Picker over `coach.availableModels` with a free-text "Custom…" path and a
    /// "Refresh models" button that fetches the provider's live list.
    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").strandOverline()
                Spacer()
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                        .font(StrandFont.footnote)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .disabled(!coach.hasKey)
                .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
                .accessibilityLabel("Refresh models from provider")
            }

            Picker("Model", selection: modelPickerSelection) {
                ForEach(coach.availableModels, id: \.self) { m in
                    Text(m).tag(m)
                }
                Divider()
                Text("Custom…").tag(customModelTag)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Model")

            if customModel {
                HStack(spacing: 8) {
                    TextField("Enter a model id", text: $customModelDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                        .onSubmit(applyCustomModel)
                        .accessibilityLabel("Custom model id")

                    Button("Use", action: applyCustomModel)
                        .buttonStyle(.bordered)
                        .tint(StrandPalette.accent)
                        .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Use custom model")
                }
            }
        }
    }

    /// Bridges the model Picker to `coach.model`, with a "Custom…" sentinel that opens the free-text
    /// field instead of selecting a real id.
    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { customModel ? customModelTag : coach.model },
            set: { newValue in
                if newValue == customModelTag {
                    customModel = true
                    if customModelDraft.isEmpty { customModelDraft = coach.model }
                } else {
                    customModel = false
                    coach.model = newValue
                }
            }
        )
    }

    private func applyCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setCustomModel(trimmed)
        customModel = false
    }

    // MARK: - Connected state

    private var connectedHeader: some View {
        HStack(spacing: 10) {
            StatePill("\(coach.provider.displayName) · \(coach.model)", tone: .accent, showsDot: true)
            Spacer()
            if coach.sending {
                StatePill("Thinking", tone: .accent, pulsing: true)
            }
        }
    }

    private var transcript: some View {
        StrandCard(padding: 16) {
            if coach.messages.isEmpty {
                emptyTranscript
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(coach.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if coach.sending {
                                typingIndicator.id("typing")
                            }
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220, maxHeight: 460)
                    .onChange(of: coach.messages.count) { _ in
                        scrollToEnd(proxy)
                    }
                    .onChange(of: coach.sending) { _ in
                        scrollToEnd(proxy)
                    }
                }
            }
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask your first question")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Coach reads a summary of your last two weeks plus 30-day averages and recent workouts, then answers in plain language. Try a suggestion below.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            // LLM replies arrive as Markdown (bold, lists, headings, tables) —
            // rendered with the chat-bubble-sized Strand theme. User bubbles stay
            // verbatim `Text` so typed `*`/`#` never turn into surprise formatting.
            HStack {
                Markdown(message.text)
                    .markdownTheme(.strand)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.surfaceOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 48)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coach said: \(message.text)")
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Coach is thinking…")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(StrandPalette.surfaceOverlay, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityLabel("Coach is thinking")
    }

    private func errorBanner(_ message: String) -> some View {
        StrandCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusCritical)
                    .accessibilityHidden(true)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(coach.sending)
                    .accessibilityLabel("Suggested prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(composerFocused ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
                .onSubmit { send(draft) }
                .accessibilityLabel("Question")

            Button {
                send(draft)
            } label: {
                if coach.sending {
                    ProgressView().controlSize(.small)
                        .frame(width: 44, height: 36)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 36)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .disabled(coach.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
    }

    private var privacyFootnote: some View {
        Label {
            Text(coach.provider == .custom
                 ? "Coach talks only to the server URL you set — point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Nothing is sent until you ask."
                 : "This is the only feature that leaves your Mac — it sends a summary of your metrics to \(coach.provider.displayName) using your own key. Nothing is sent until you ask.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyDraft = ""
    }

    /// Commit the Custom (local) provider: save an optional key, then connect on the entered URL.
    private func connectCustom() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            coach.setKey(trimmed)
            keyDraft = ""
        }
        coach.connectCustom()
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        Task { await coach.send(trimmed) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(StrandMotion.fade) {
            if coach.sending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = coach.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
