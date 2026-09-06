import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - AI Coach (the one networked feature, strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat, no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question - only a short text summary of your metrics goes to the provider you pick."

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API key. Uses a generic-password item under a fixed
/// service so the key never lands in UserDefaults, a plist, or on disk in the clear.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// UserDefaults key recording which provider the stored API key belongs to, so one provider's key
    /// is never sent to another provider's endpoint (above all the arbitrary user-typed Custom URL).
    private static let ownerKey = "ai.keyProvider"

    /// The provider the stored key was saved for, or nil for a legacy key saved before this tracking.
    static var ownerProvider: String? { UserDefaults.standard.string(forKey: ownerKey) }

    /// Store (or replace) the API key for `owner`. Empty/whitespace input is treated as a clear.
    /// Returns true once the key is in the Keychain (or was cleared); false if the Keychain write
    /// failed, in which case the owner marker is left untouched so it never points at a key that
    /// isn't actually stored (#872). The live `read()`/`hasKey` gating already reads the real
    /// Keychain, so this is defensive tidying of the discarded write result, not a behaviour change.
    @discardableResult
    static func save(_ key: String, owner: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(owner, forKey: ownerKey)
        return true
    }

    /// Read the stored API key, or nil if none is set.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Remove any stored API key.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
enum AICoachError: LocalizedError {
    case noKey
    case emptyQuestion
    case badKey
    case rateLimited
    case server(Int, String)
    case network(String)
    case decode
    case emptyReply(String)   // #1074: verbatim provider-error / empty-reply text (byte-parity with Android emptyReplyMessage)
    case keySaveFailed
    case badCustomURL(String)

    var errorDescription: String? {
        switch self {
        case .badCustomURL(let message):
            return message
        case .noKey:
            return "Add your own API key first to use the coach."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited:
            return "The provider is rate-limiting requests right now. Wait a moment and try again."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        case .emptyReply(let message):
            return message
        }
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    @Published var messages: [ChatMessage] = []

    /// Local day the current transcript was last written on; nil while it is empty. Drives the day
    /// boundary in `send` — see `isStaleConversation`. Kotlin twin: `CoachViewModel.conversationDay`.
    private var conversationDay: Int?
    @Published var sending = false
    @Published var errorText: String?

    /// #1862: a question handed over by the Today Coach launcher sheet, for `CoachView` to send on appear.
    ///
    /// The launcher owns no send, stream, error or consent surface of its own — duplicating those is how a
    /// second chat UI drifts from the first. It collects a question and hands it here; the Coach screen,
    /// which already has all of that, consumes it exactly once and clears it. Nil is the normal state, and
    /// setting it performs NO network work by itself.
    @Published var pendingPrompt: String?
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default, until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    @Published var customAuthHeader: CustomAIAuthHeader {
        didSet { UserDefaults.standard.set(customAuthHeader.rawValue, forKey: AIProvider.customAuthHeaderKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }

    /// K11: THIRD opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. OFF by default and gated behind `dataConsent` too. Only active when the provider is
    /// Gemini (the only provider with multimodal support in the app). When on, the Coach composer
    /// shows an "Attach chart" toggle; the rendered chart is sent as inline_data to Gemini.
    @Published var multimodalChartEnabled: Bool {
        didSet { UserDefaults.standard.set(multimodalChartEnabled, forKey: Self.multimodalChartKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    private static let multimodalChartKey = "ai.multimodalChartEnabled"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    sleep duration and its deep/REM/light breakdown, sleep efficiency, HRV, resting heart rate) and \
    recent workouts. Charge is the daily recovery/readiness score, effort is the daily cardiovascular \
    load score, and rest is the nightly sleep-quality score. A dash in the data means that value was \
    NOT MEASURED that day — say so rather than treating it as a zero. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67-100 = green light to build/push, higher effort is fine; \
    34-66 = maintain, quality over volume, keep it controlled; 0-33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating - like a coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor - never diagnose; suggest a professional for genuine health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans, ### headings only when structure genuinely helps, and a \
    small table only for a week-ahead plan. No code blocks.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSystemPrompt
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// Contextual suggestion chips for the composer, derived from today's bands via `CoachSuggestions`.
    /// Reads only on-device `repo.days`; pure, byte-identical to the Android twin. Returns the stable
    /// generic fallback when there is no usable data for today.
    var suggestions: [String] { CoachSuggestions.suggestions(for: repo.days.last, recent: repo.days) }

    /// K7: Follow-up suggestion chips shown after each assistant reply. These are generic
    /// conversational follow-ups (not data-derived) so the user can dig deeper without typing.
    /// Byte-identical to the Android twin's `followUpSuggestions`.
    static let followUpSuggestions: [String] = [
        "Tell me more about that",
        "What should I do next?",
        "How does today compare to this week?",
        "Give me a specific action plan",
    ]

    /// K12: Rough token estimate for the next send, based on the current draft + context size.
    /// Uses the standard ~4 chars/token heuristic. This is an estimate only — actual token counts
    /// vary by tokenizer. Returns nil when the engine isn't configured (no context to estimate).
    func estimatedTokens(forDraft draft: String) -> Int? {
        guard isConfigured else { return nil }
        // Estimate the context size: system prompt + data context (rough — we don't build the
        // full context here to avoid a DB read on every keystroke). Use the last known context
        // size or a reasonable default.
        let systemPromptTokens = systemPrompt.count / 4
        // The data context is typically ~2000-4000 chars depending on the user's data.
        // Use a conservative estimate of 3000 chars (750 tokens) when consent is on.
        let contextTokens = dataConsent ? 750 : 50
        // History tokens: sum of all message texts in the windowed history.
        let historyTokens = windowedMessages().reduce(0) { $0 + $1.text.count / 4 }
        let draftTokens = draft.count / 4
        return systemPromptTokens + contextTokens + historyTokens + draftTokens
    }

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    init(repo: Repository, session: URLSession = .shared) {
        self.repo = repo
        self.session = session

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customAuthHeader = AIProvider.customAuthHeader
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
        self.multimodalChartEnabled = UserDefaults.standard.bool(forKey: Self.multimodalChartKey)
    }

    // MARK: Key management

    /// True when a key is present in the Keychain.
    var hasKey: Bool { AIKeyStore.read() != nil }

    /// True once the coach can actually send: a stored key for the cloud providers, or, for the
    /// Custom (local) provider, a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`.
    private var resolvedKey: String? {
        if let k = AIKeyStore.read() {
            // Only send the stored key to the provider it was SAVED for, never Bearer one provider's
            // key (e.g. a cloud OpenAI/Anthropic secret) to another provider's endpoint, above all the
            // arbitrary user-typed Custom URL. A legacy key with no recorded owner is assumed to belong
            // to a cloud provider, so it is never auto-sent to Custom.
            let owner = AIKeyStore.ownerProvider
            if owner == provider.rawValue { return k }
            if owner == nil && provider != .custom { return k }
        }
        return provider == .custom ? "" : nil
    }

    /// Commit the Custom (local) provider once the user has entered a server URL. Optionally stores a
    /// key first if they pasted one. Pulls the server's live model list so the picker isn't empty.
    func connectCustom() {
        let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        errorText = nil
        customConnected = true
        // Pull the server's model list; if the user hasn't picked one yet, default to the first.
        Task {
            await refreshModels()
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = availableModels.first {
                model = first
            }
        }
    }

    /// Disconnect entirely: forget any stored key and un-commit the Custom provider. The base URL is
    /// kept so reconnecting pre-fills it.
    func disconnect() {
        AIKeyStore.clear()
        customConnected = false
        // Retire the transcript with the connection. Kotlin has done this since the method existed
        // (CoachViewModel.disconnect) and this side never did, so returning to the setup screen on Apple
        // left the whole conversation sitting behind it — including whatever the user had told a coach
        // they were in the middle of disconnecting from.
        messages = []
        conversationDay = nil
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error. If the Keychain write fails the
    /// key is NOT saved, so surface that to the UI instead of silently proceeding (#872).
    func setKey(_ key: String) {
        guard AIKeyStore.save(key, owner: provider.rawValue) else {
            errorText = AICoachError.keySaveFailed.errorDescription
            objectWillChange.send()
            return
        }
        errorText = nil
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET
        // egresses to the provider the MOMENT a key is saved (IP + request timing + key-validity) — before
        // any send, in an app that is zero-network by default. The picker shows the curated models; the LIVE
        // list is pulled only when the user taps Refresh (an explicit action that is its own consent) or
        // sends. Local Custom servers still refresh on Connect.
    }

    /// Forget the stored key.
    func clearKey() {
        AIKeyStore.clear()
        // Same reasoning as `disconnect`: clearing the key returns the user to the setup screen, and
        // Kotlin empties the transcript when it does. Leaving it meant a "clear my key" on Apple removed
        // the credential and kept the conversation.
        messages = []
        conversationDay = nil
        objectWillChange.send()
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Test seam (DEBUG only): lets a test stand in for the live `fetchModels` network call so it can
    /// control timing and which provider's ids come back. Production never sets this, so the real path
    /// below is byte-identical in release builds.
    #if DEBUG
    var fetchModelsOverride: ((_ provider: AIProvider, _ key: String) async throws -> [String])?
    #endif

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        guard let key = resolvedKey else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        errorText = nil

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                errorText = AICoachError.decode.errorDescription
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
        } catch {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            return
        }
    }

    // MARK: Sending

    /// Hard rolling cap on the STORED transcript. The network payload is separately windowed by
    /// `windowedMessages()` (`maxHistoryMessages`); this bounds the in-memory `messages` array — and the
    /// SwiftUI transcript rendered from it — so a long-lived session can't grow it without bound. `coach`
    /// is a single app-lifetime instance on `AppModel`, so before this an active chat grew `messages`
    /// until the process was killed: the "gets laggy the longer the app runs, reopening fixes it, feels
    /// like RAM" report. Cap >> the wire window, so it never changes what's sent. (parity with Android)
    private static let maxStoredMessages = 40
    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxStoredMessages {
            messages.removeFirst(messages.count - Self.maxStoredMessages)
        }
    }

    // MARK: - K2: persisted conversation history

    /// Guards `loadPersistedMessagesIfNeeded()` so it only ever runs once per app launch, even if the
    /// Coach screen's `.task` re-fires (e.g. a tab re-select).
    private var didLoadPersistedMessages = false

    /// Load the conversation persisted by a PRIOR launch (PRD-K2), so relaunching doesn't lose it.
    /// Called from the Coach screen's `.task` (mirroring `startBriefIfNeeded`) rather than `init`,
    /// which is synchronous and runs for every screen the app builds, not just Coach. Best-effort: a
    /// store failure just leaves the transcript empty, matching pre-K2 behaviour — never crashes.
    func loadPersistedMessagesIfNeeded() async {
        guard !didLoadPersistedMessages else { return }
        didLoadPersistedMessages = true
        guard messages.isEmpty, let store = await repo.storeHandle() else { return }
        guard let rows = try? await store.coachMessages(), !rows.isEmpty else { return }
        messages = rows
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { ChatMessage(id: UUID(uuidString: $0.id) ?? UUID(),
                                role: ChatMessage.Role(rawValue: $0.role) ?? .user,
                                text: $0.text) }
    }

    /// Replace the ENTIRE persisted conversation with the current in-memory `messages`. Called once
    /// per completed send/brief (not per streamed chunk) so a streamed reply's several in-place text
    /// mutations don't hammer the store. Fire-and-forget; a store failure never blocks the UI — the
    /// in-memory transcript (what the user sees) is unaffected either way.
    private func persistMessages() {
        let snapshot = messages
        let providerId = provider.rawValue
        Task {
            guard let store = await repo.storeHandle() else { return }
            let rows = snapshot.enumerated().map { index, m in
                CoachMessageRow(id: m.id.uuidString, role: m.role.rawValue, text: m.text,
                                 provider: providerId, createdAt: Int(Date().timeIntervalSince1970),
                                 orderIndex: index)
            }
            try? await store.replaceCoachMessages(rows)
        }
    }

    /// The Coach toolbar's "Clear conversation" action: wipes both the in-memory transcript and the
    /// persisted table. Fire-and-forget on the store side; the in-memory clear is immediate.
    func clearConversation() {
        messages = []
        droppedSummary = nil      // K13: reset the summary cache on clear
        droppedSummaryKey = []
        Task { try? await repo.storeHandle()?.clearCoachMessages() }
    }

    /// K5: surface a brief generated by the SCHEDULED morning-brief notification as the first Coach
    /// message, with no network call — called once when the app opens via a tap on that notification.
    /// No-op if a conversation already exists, so it never duplicates into an active chat.
    func surfaceScheduledBrief(_ text: String) {
        guard messages.isEmpty else { return }
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        persistMessages()
    }

    /// K5: append an explicitly-generated brief (the Coach settings "Generate now" button) as a new
    /// assistant message, unconditionally — unlike `surfaceScheduledBrief`, this always appends so a
    /// mid-conversation tap still shows the fresh brief.
    func appendGeneratedBrief(_ text: String) {
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        persistMessages()
    }

    /// K11: An optional chart image (base64-encoded PNG) to send with the next user message.
    /// Set by the composer's "Attach chart" toggle when multimodal is enabled and the provider
    /// is Gemini. Consumed (cleared) on the next send. nil when no image is attached.
    @Published var pendingChartImage: String?

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        // A transcript from an earlier local day is retired before the new turn is appended (#1542,
        // Kotlin twin merged first). `messages` outlives a night — the engine is held for the app's
        // lifetime — so without this the coach answers TODAY's question inside YESTERDAY's
        // conversation. The DATA was never stale: buildFullContext() re-reads on every send. It is the
        // assistant's own earlier turns stating yesterday's figures, and the model staying consistent
        // with them, which reads as "the coach only talks about my imported data" after a night of
        // fresh strap data.
        //
        // Placed AFTER the guards on purpose: a send that never happens must not wipe a transcript.
        let today = Self.localEpochDay()
        if Self.isStaleConversation(lastEpochDay: conversationDay, todayEpochDay: today) {
            messages = []
        }
        conversationDay = today

        errorText = nil
        appendMessage(ChatMessage(role: .user, text: trimmed))
        sending = true
        // K2: persist once the turn is fully settled (success, mid-stream error, or empty-stream
        // removal) — not per streamed chunk, so a long reply doesn't hammer the store.
        defer { sending = false; persistMessages() }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let context = dataConsent ? await buildFullContext() : noConsentNote
        // K13: if the conversation overflows the sliding window, summarize the dropped middle so
        // the model retains context continuity. Best-effort; failure degrades to the old gap.
        await summarizeDroppedMiddleIfNeeded(key: key)
        var wire = wireMessages(context: context)

        // K11: If a chart image is pending and the provider is Gemini, attach it to the last
        // user turn as inline_data. Non-Gemini providers can't accept images, so the image is
        // silently dropped (the text question still goes through). Cleared after consumption.
        let imageBase64 = pendingChartImage
        pendingChartImage = nil

        // K1: Stream the reply. Append a placeholder assistant message, then mutate its text as
        // chunks arrive by replacing the last element in `messages`. The transcript re-renders on
        // each update (SwiftUI binds to `messages`). On error mid-stream, keep the partial text and
        // append a "(stream interrupted)" marker — never a crash.
        let placeholder = ChatMessage(role: .assistant, text: "")
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire, inlineImage: imageBase64) { delta in
                accumulated += delta
                // Replace the last message's text with the accumulated stream so far.
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        id: placeholder.id, role: .assistant, text: accumulated
                    )
                }
            }
            // Finalize: trim whitespace. If the stream produced nothing, show "(no reply)".
            let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: clean.isEmpty ? "(no reply)" : clean
                )
            }
        } catch let e as AICoachError {
            // Mid-stream error: keep the partial text + an interrupted marker (PRD K1 acceptance).
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                // No text received at all — remove the empty placeholder.
                messages.remove(at: lastIdx)
            }
            errorText = e.errorDescription
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages.remove(at: lastIdx)
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    /// K1: streams the brief the same way `send` does.
    func startBriefIfNeeded() async {
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false; persistMessages() }

        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]

        let prefix = "Today's brief\n\n"
        let placeholder = ChatMessage(role: .assistant, text: prefix)
        appendMessage(placeholder)
        var accumulated = ""

        do {
            try await streamProvider(key: key, messages: wire) { delta in
                accumulated += delta
                if let lastIdx = self.messages.indices.last,
                   self.messages[lastIdx].role == .assistant {
                    self.messages[lastIdx] = ChatMessage(
                        id: placeholder.id, role: .assistant, text: prefix + accumulated
                    )
                }
            }
            let clean = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(id: placeholder.id, role: .assistant, text: prefix + clean)
            }
        } catch let e as AICoachError {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = e.errorDescription
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// K5: The brief instruction shared by the interactive `startBriefIfNeeded()` (streamed into the
    /// chat) and the headless `generateBrief()` below (used by the scheduled morning-brief notification).
    /// Kept in one place so the two paths never drift.
    private static let briefInstruction = """
    Based on the data above, give me TODAY'S coaching brief in three short parts: \
    (1) my readiness in one line, citing charge, HRV and rest; \
    (2) exactly what training to do today and what to avoid; \
    (3) one specific thing to improve my charge. Be punchy and motivating.
    """

    /// K5: Generate today's coaching brief WITHOUT touching the visible chat transcript. Used by the
    /// scheduled morning-brief notification (`CoachBriefScheduler`), which can run with no Coach screen
    /// open and must never append to (or duplicate into) `messages`. Non-streaming (a background/BGTask
    /// context has no UI to stream into). Returns nil when not configured/consented, on any network
    /// failure, or when the reply is empty — the caller treats nil as "brief unavailable"; never throws.
    func generateBrief() async -> String? {
        guard isConfigured, dataConsent, let key = resolvedKey else { return nil }
        let context = await buildFullContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]
        guard let reply = try? await callProvider(key: key, messages: wire) else { return nil }
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    func buildFullContext() async -> String {
        var ctx = buildContext()
        ctx += "\n\n" + (await recentWorkoutsBlock())
        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Gated here under `dataConsent` (the caller only reaches buildFullContext()
        // with consent on), so it rides the SAME consent + text-only channel as the HRV/RHR summary, a
        // derived number, never raw R-R egress. Omitted when there aren't enough clean beats yet.
        if let line = await stressIndexLine() { ctx += "\n\n" + line }
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { ctx += "\n\n" + block }
        }
        return ctx
    }

    /// One derived stress line for the coach context: the Baevsky Stress Index over TODAY's R-R, read
    /// via the same device-aware repository R-R union as `StressView`,
    /// then summarised to a single number with `StressIndex.stressIndex(rr:)`. Returns nil when the
    /// store is unavailable or there are too few clean beats (the histogram needs >= 20), so the line is
    /// simply absent, never a fabricated value. Summary-only: the raw R-R never leaves the device.
    func stressIndexLine() async -> String? {
        let cal = Calendar.current
        let from = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        guard let si = StressIndex.stressIndex(rr: rr) else { return nil }
        return Self.stressIndexSummary(si: si)
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index over today's R-R; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controls: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controls[e.question, default: []].insert(e.day) }
        }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, controls: controls,
                                           outcomeByDay: outcomeByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(3)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
        }

        // 2. Lab Book markers roll-up (count + latest of a few, never the full history).
        if let store = await repo.storeHandle() {
            var markerSummaries: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                let byKey = Dictionary(grouping: rows, by: { $0.markerKey })
                for (key, kRows) in byKey {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key)) \(latest.unit)" } ?? latest.valueText ?? "—"
                    markerSummaries.append("\(name) \(value)")
                }
            }
            if !markerSummaries.isEmpty {
                lines.append("")
                lines.append("LAB BOOK (the user's own logged health numbers — not medical advice; do not interpret as clinical findings):")
                lines.append("  " + markerSummaries.prefix(8).joined(separator: ", "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Dispatch to the user's chosen provider client.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        try await provider.client.send(
            key: key,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            session: session
        )
    }

    /// K1: Dispatch to the user's chosen provider client's streaming method. The default
    /// `AIProviderClient.stream` falls back to `send` + a single delta, so providers without
    /// streaming still work. K11: when an inline image is present, dispatches to
    /// `streamWithImage` instead (Gemini overrides it; others ignore the image).
    private func streamProvider(key: String,
                                messages: [(role: ChatMessage.Role, content: String)],
                                inlineImage: String? = nil,
                                onDelta: (String) -> Void) async throws {
        try await provider.client.streamWithImage(
            key: key,
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            inlineImage: inlineImage,
            session: session,
            onDelta: onDelta
        )
    }

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent `maxHistoryMessages`, dropping the middle. Sending the whole growing history crowds out the
    /// reply on small-context local servers (Ollama defaults to a 2048-token window, the Custom
    /// provider's main use case) and balloons token cost/latency on cloud providers. (parity with Android)
    /// True when a transcript last written on `lastEpochDay` should be retired before a question asked
    /// on `todayEpochDay` — i.e. the conversation crossed into a new local day.
    ///
    /// STRICTLY forward (`>`, never `!=`): a clock that moves BACKWARDS — the user flying west, a
    /// timezone change, an NTP correction — must not wipe a conversation they are in the middle of.
    /// Only real elapsed days retire a transcript. A nil `lastEpochDay` (nothing sent yet) is never
    /// stale. Kotlin twin: `CoachViewModel.isStaleConversation`.
    ///
    /// `nonisolated` because it is a pure function of its arguments. AICoachEngine is @MainActor, so
    /// without this the rule inherits that isolation and cannot be called from a synchronous test —
    /// which is exactly how the first attempt at this twin failed to compile. Isolating a function
    /// that touches no state buys nothing and costs its testability.
    nonisolated static func isStaleConversation(lastEpochDay: Int?, todayEpochDay: Int) -> Bool {
        guard let lastEpochDay else { return false }
        return todayEpochDay > lastEpochDay
    }

    /// Days since the epoch in the LOCAL calendar — the twin of Kotlin's `LocalDate.now().toEpochDay()`.
    ///
    /// Counted with calendar day arithmetic from `startOfDay`, not by dividing an interval by 86,400:
    /// a day is not always 86,400 seconds (DST), and the rule only needs a value that increments
    /// exactly once per local midnight and orders correctly. Injectable so the tests never depend on
    /// the machine's clock or zone.
    nonisolated static func localEpochDay(_ date: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let epoch = Date(timeIntervalSince1970: 0)
        return calendar.dateComponents([.day], from: epoch, to: start).day ?? 0
    }

    ///
    /// K13: when the middle is dropped, a one-line summary of the dropped turns is prepended to the
    /// first user turn so the model retains context continuity (instead of seeing a gap). The summary
    /// is generated via the same provider, with a short prompt; on failure it degrades to the old
    /// behaviour (no summary, just the windowed set).
    private static let maxHistoryMessages = 10
    /// K13: the cached summary of the dropped middle, regenerated when the dropped set changes.
    private var droppedSummary: String?
    private var droppedSummaryKey: [String] = []

    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        // K13: inject the summary of the dropped middle by prepending it to the first user turn,
        // so the model sees continuity instead of a gap. We don't use a separate system message
        // because the Role enum only has .user/.assistant (providers map those to API roles).
        var windowed = [messages[firstUser]]
        if let summary = droppedSummary {
            let first = windowed[0]
            windowed[0] = ChatMessage(id: first.id, role: first.role, text: "\(summary)\n\n---\n\n\(first.text)")
        }
        windowed.append(contentsOf: messages[recentStart...])
        return windowed
    }

    /// K13: When the conversation overflows the sliding window, summarize the dropped middle turns
    /// into a single system message. Called before each send when the window would drop messages.
    /// Best-effort: on any failure, leaves `droppedSummary` nil (the old gap behaviour).
    private func summarizeDroppedMiddleIfNeeded(key: String) async {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return }
        let recentStart = messages.count - Self.maxHistoryMessages
        guard firstUser < recentStart else { return }

        // The dropped middle is messages[firstUser+1 ..< recentStart]. Cache on its identity so we
        // don't re-summarize the same set on every send.
        let dropped = Array(messages[(firstUser + 1)..<recentStart])
        let keySignature = dropped.map { "\($0.role.rawValue):\($0.text)" }
        guard droppedSummaryKey != keySignature else { return }
        droppedSummaryKey = keySignature

        // Build a compact transcript of the dropped turns for the summarizer.
        let transcript = dropped.map { m in
            "\(m.role == .user ? "User" : "Coach"): \(m.text)"
        }.joined(separator: "\n")

        let summaryPrompt = """
        Summarize the following conversation in 2-3 sentences, preserving the key advice and \
        any specific numbers or recommendations. This summary will be shown to you as context \
        for the ongoing conversation.\n\n\(transcript)
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [
            (.user, "You are a concise summarizer. Summarize the conversation in 2-3 sentences.\n\n\(summaryPrompt)"),
        ]
        if let summary = try? await callProvider(key: key, messages: wire) {
            droppedSummary = "Summary of earlier conversation: \(summary.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        for m in windowedMessages() {
            if m.role == .user && !contextInjected {
                contextInjected = true
                out.append((.user, context + "\n\n---\n\nQuestion: " + m.text))
            } else {
                out.append((m.role, m.text))
            }
        }
        return out
    }

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        guard !days.isEmpty else {
            return """
            USER BIOMETRIC SUMMARY:
            No wearable data is available yet. Acknowledge this and give general, encouraging guidance \
            while inviting the user to sync their device so future advice can reference real numbers.
            """
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        lines.append("")
        lines.append("Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), "
                     + "deep/REM/light(h), eff(%), HRV(ms), RHR(bpm). A dash means NOT MEASURED, not zero:")
        for d in recent {
            lines.append("  " + dayLine(d))
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  charge: \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        let bodySystem = UnitSystem(
            rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let distanceSystem = UnitPrefs.resolveDistance(
            system: bodySystem,
            override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM {
                parts.append(UnitFormatter.distanceFromMeters(dist, system: distanceSystem))
            }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    /// `internal`, not private, so `AICoachSleepContextTests` can assert the emitted line directly.
    /// Swift's `buildContext()` takes no arguments (it reads the repo), unlike the Kotlin twin which is
    /// handed the day list — so without this the formatter has no seam and the Swift half of a change
    /// with fifteen Kotlin tests would ship untested.
    func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
        parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        // The stage breakdown and efficiency, which the coach could not see at all: a user asked why it
        // said it had no access to sleep stages, and it was answering honestly — `rest 7.8h` was every
        // word it got about a night. These four sit on the SAME DailyMetric the line already reads, so
        // nothing new is plumbed; they were simply never included. (#124 widened this context once
        // before, for the same reason.)
        //
        // Always emitted, "—" when absent, like every other field here. A night with no staging then
        // says so rather than going quiet, which matters more than line length: the alternative — only
        // appending stages when present — gives the model a schema that changes shape between days and
        // invites it to read a missing field as a zero.
        parts.append("deep " + hoursOrDash(d.deepMin))
        parts.append("REM " + hoursOrDash(d.remMin))
        parts.append("light " + hoursOrDash(d.lightMin))
        parts.append("eff " + efficiencyPercentOrDash(d.efficiency))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
    }

    /// Minutes as "1.4h", or "—" when the night has no value. Matches the `rest` field's format so a
    /// stage total and the total it is part of read on the same scale.
    private func hoursOrDash(_ minutes: Double?) -> String {
        minutes.map { String(format: "%.1fh", $0 / 60) } ?? "—"
    }

    /// Efficiency as a percentage, NORMALISING the stored value first.
    ///
    /// `DailyMetric.efficiency` is not reliably a 0–1 fraction: it "arrives as % on some import paths",
    /// which `SleepView` and `StagesCard` each guard against inline with this same `> 1.5` test. A bare
    /// `* 100` would therefore hand the coach "eff 9400%" for an imported night — and a model given a
    /// nonsense number reasons about it confidently rather than ignoring it.
    ///
    /// 1.5 rather than 1.0 because a genuine fraction can exceed 1.0 only by floating-point noise, while
    /// a genuine percentage is 30–100 and nowhere near the threshold. Android's two copies of this guard
    /// split at 1.0 instead, which is a pre-existing divergence and not this change's to settle.
    func efficiencyPercentOrDash(_ raw: Double?) -> String {
        guard var e = raw, e > 0 else { return "—" }
        if e > 1.5 { e /= 100 }
        guard e > 0, e <= 1 else { return "—" }
        return "\(Int((e * 100).rounded()))%"
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
