import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - AI Coach (the one networked feature — strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat — no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question — only a short text summary of your metrics goes to the provider you pick."

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
    static func save(_ key: String, owner: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return }
        guard let data = trimmed.data(using: .utf8) else { return }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
        UserDefaults.standard.set(owner, forKey: ownerKey)
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

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "Add your own API key first to use the coach."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited:
            return "The provider is rate-limiting requests right now. Wait a moment and try again."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
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
    @Published var sending = false
    @Published var errorText: String?
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
    /// default — until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals — your strongest n-of-1
    /// correlations and your Lab Book markers — into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings — the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"

    /// The system prompt that frames every request. Anonymous — frames the assistant only as a coach.
    private let systemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0–100, effort 0–100, rest 0–100, \
    HRV, resting heart rate) and recent workouts. Charge is the daily recovery/readiness score, effort \
    is the daily cardiovascular load score, and rest is the nightly sleep-quality score. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67–100 = green light to build/push, higher effort is fine; \
    34–66 = maintain, quality over volume, keep it controlled; 0–33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating — like a coach who knows them.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor — never diagnose; suggest a professional for genuine health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans, ### headings only when structure genuinely helps, and a \
    small table only for a week-ahead plan. No code blocks.
    """

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
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
    }

    // MARK: Key management

    /// True when a key is present in the Keychain.
    var hasKey: Bool { AIKeyStore.read() != nil }

    /// True once the coach can actually send: a stored key for the cloud providers, or — for the
    /// Custom (local) provider — a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured" — the caller surfaces `.noKey`.
    private var resolvedKey: String? {
        if let k = AIKeyStore.read() {
            // Only send the stored key to the provider it was SAVED for — never Bearer one provider's
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
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error.
    func setKey(_ key: String) {
        AIKeyStore.save(key, owner: provider.rawValue)
        errorText = nil
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // Pull the user's ACTUAL current models from the provider so the picker is never stale.
        Task { await refreshModels() }
    }

    /// Forget the stored key.
    func clearKey() {
        AIKeyStore.clear()
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

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        guard let key = resolvedKey else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        errorText = nil

        do {
            let ids = try await provider.client.fetchModels(key: key, session: session)
            guard !ids.isEmpty else {
                errorText = AICoachError.decode.errorDescription
                return
            }

            // Merge: keep the built-in options on top, append any newly-discovered ids (sorted), and
            // preserve a current custom selection if it isn't otherwise present.
            let builtin = provider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            return
        }
    }

    // MARK: Sending

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        guard let key = resolvedKey else { errorText = AICoachError.noKey.errorDescription; return }

        errorText = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        sending = true
        defer { sending = false }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        let context = dataConsent ? await buildFullContext() : noConsentNote
        let wire = wireMessages(context: context)

        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(ChatMessage(role: .assistant, text: clean.isEmpty ? "(no reply)" : clean))
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens — readiness + a training
    /// prescription + one recovery tip — without the user typing. Requires a key + data consent.
    func startBriefIfNeeded() async {
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false }

        let context = await buildFullContext()
        let instruction = """
        Based on the data above, give me TODAY'S coaching brief in three short parts: \
        (1) my readiness in one line, citing charge, HRV and rest; \
        (2) exactly what training to do today and what to avoid; \
        (3) one specific thing to improve my charge. Be punchy and motivating.
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [(.user, context + "\n\n---\n\n" + instruction)]
        do {
            let reply = try await callProvider(key: key, messages: wire)
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                messages.append(ChatMessage(role: .assistant, text: "Today's brief\n\n" + clean))
            }
        } catch let e as AICoachError {
            errorText = e.errorDescription
        } catch {
            errorText = AICoachError.network(error.localizedDescription).errorDescription
        }
    }

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    func buildFullContext() async -> String {
        var ctx = buildContext()
        ctx += "\n\n" + (await recentWorkoutsBlock())
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty { ctx += "\n\n" + block }
        }
        return ctx
    }

    /// A SUMMARY-ONLY block of the new on-device signals — the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        var byBehaviour: [String: Set<String>] = [:]
        for e in entries where e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, outcomeByDay: outcomeByDay, outcome: "Charge")
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

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent `maxHistoryMessages`, dropping the middle. Sending the whole growing history crowds out the
    /// reply on small-context local servers (Ollama defaults to a 2048-token window — the Custom
    /// provider's main use case) and balloons token cost/latency on cloud providers. (parity with Android)
    private static let maxHistoryMessages = 10
    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        return [messages[firstUser]] + Array(messages[recentStart...])
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
        lines.append("Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), HRV(ms), RHR(bpm):")
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
        // Additional vitals when present (#124 — the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     + ", active energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat — kept separate so `buildContext()` stays synchronous per the spec.
    func recentWorkoutsBlock(limit: Int = 6) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM { parts.append("\(String(format: "%.1f", dist / 1000)) km") }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    private func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
        parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
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
