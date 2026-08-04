import Foundation

// MARK: - Provider enum

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case gemini
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini:    return "Google Gemini"
        case .custom:    return "Custom (OpenAI-compatible)"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-6"
        case .gemini:    return "gemini-flash-latest"   // stable alias → current Flash, no version churn (#400)
        case .custom:    return ""   // the user picks the model their server serves
        }
    }

    /// Models offered in the picker. A "Custom…" path in the UI lets the user pick any id beyond
    /// these, and `refreshModels()` can merge the provider's live list.
    var modelOptions: [String] {
        switch self {
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"]
        case .anthropic:
            return [
                "claude-opus-4-8",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
                "claude-3-7-sonnet-latest",
                "claude-3-5-sonnet-latest",
                "claude-3-5-haiku-latest",
                "claude-3-opus-latest"
            ]
        case .gemini:
            // Stable `-latest` ALIASES, not pinned versions (#400): they always resolve to the current
            // stable model in each tier, so Gemini's rapid releases never need a code bump. `refreshModels()`
            // still merges the live `/models` catalogue, so a user with a key can pin a concrete version.
            return [
                "gemini-pro-latest",
                "gemini-flash-latest",
                "gemini-flash-lite-latest"
            ]
        case .custom:
            return []   // populated from the server's /models (refreshModels) or typed in
        }
    }

    var endpoint: URL {
        switch self {
        case .openAI:    return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .custom:    return AIProvider.customURL(path: "/chat/completions")
        }
    }

    var modelsEndpoint: URL {
        switch self {
        case .openAI:    return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        case .custom:    return AIProvider.customURL(path: "/models")
        }
    }

    var client: any AIProviderClient {
        switch self {
        case .openAI:    return OpenAIClient()
        case .anthropic: return AnthropicClient()
        case .gemini:    return GeminiClient()
        case .custom:    return CustomClient()
        }
    }

    // MARK: - Custom (OpenAI-compatible) base URL

    /// UserDefaults key for the Custom provider's base URL (e.g. a local LLM server such as Ollama /
    /// LM Studio / llama.cpp: `http://localhost:11434/v1`). `AICoachEngine` exposes it for editing.
    static let customBaseURLKey = "ai.customBaseURL"
    static let customAuthHeaderKey = "ai.customAuthHeader"

    /// The user-set Custom base URL, trimmed.
    static var customBaseURL: String {
        (UserDefaults.standard.string(forKey: customBaseURLKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var customAuthHeader: CustomAIAuthHeader {
        let raw = UserDefaults.standard.string(forKey: customAuthHeaderKey)
        return CustomAIAuthHeader(rawValue: raw ?? "") ?? .bearer
    }

    static func applyCustomAuthHeader(_ key: String, to request: inout URLRequest) {
        guard !key.isEmpty else { return }
        switch customAuthHeader {
        case .bearer:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .xAPIKey:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
    }

    /// Build a Custom endpoint by appending `path` to the user's base URL (trailing slashes tolerated).
    /// Falls back to a loopback placeholder when unset — the request then fails with a clear network
    /// error until the user sets a URL.
    static func customURL(path: String) -> URL {
        var base = customBaseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? URL(string: "http://localhost" + path)!
    }

    /// #321 gatekeeper for the Custom (local LLM) provider — the byte-parity twin of Android
    /// `AiCoach.guardCustomUrl` (#187), which Swift was previously missing. `https://` is always fine;
    /// plain `http://` is allowed ONLY to a private-network host (loopback / RFC-1918 / link-local /
    /// `*.local`), so a public cleartext endpoint can never egress. Throws `AICoachError.badCustomURL`
    /// with an actionable message on rejection. Called by `CustomClient.send` + `fetchModels`, i.e. on
    /// BOTH Custom network paths (mirrors Kotlin `customChatUrl` / `customModelsUrl`).
    static func guardCustomBaseURL() throws {
        let base = customBaseURL   // already trimmed / trailing-slash-stripped by the accessor
        guard let comps = URLComponents(string: base),
              let host = comps.host, !host.isEmpty,
              let scheme = comps.scheme?.lowercased(), !scheme.isEmpty else {
            throw AICoachError.badCustomURL(
                "That server URL isn't valid. Use http://<host>:<port> for a local server, or https://… for a remote one.")
        }
        if scheme == "https" { return }
        guard scheme == "http" else {
            throw AICoachError.badCustomURL(
                "Unsupported URL scheme \"\(scheme)\". Use http:// for a local server or https:// for a remote one.")
        }
        guard isPrivateLANOrLoopback(host) else {
            throw AICoachError.badCustomURL(
                "Plain http:// is only allowed to a local-network server (localhost, 10.x, 172.16-31.x, "
                + "192.168.x, 169.254.x, or a .local name). Use https:// to reach \"\(host)\".")
        }
    }

    /// True when `host` is on the device's own machine or its private LAN, so plain `http://` to it never
    /// crosses the public internet: loopback (localhost / 127.0.0.0/8 / ::1), RFC-1918 (10/8, 172.16/12,
    /// 192.168/16), link-local (169.254/16 / fe80::/10), fc00::/7 ULA, and any `*.local` mDNS name.
    /// Byte-identical decisions to Android `AiCoach.isPrivateLanOrLoopback`.
    static func isPrivateLANOrLoopback(_ host: String) -> Bool {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)   // match Kotlin String.trim()
        let h = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if h.isEmpty { return false }
        // Only apply the fc/fd/fe80 classification to a real IPv6 LITERAL (bracketed, or contains a colon),
        // so a public NAME like "fclient.evil.com" can't be mistaken for a ULA and allowed cleartext.
        let isIPv6Literal = raw.hasPrefix("[") || h.contains(":")
        if isIPv6Literal {
            if h == "::1" { return true }
            if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:") { return true }
            return false
        }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h.hasSuffix(".local") && h.count > ".local".count { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count != 4 { return false }
        let octets = parts.map { Int($0) ?? -1 }
        if octets.contains(where: { $0 < 0 || $0 > 255 }) { return false }
        let a = octets[0], b = octets[1]
        switch true {
        case a == 127: return true                       // 127.0.0.0/8 loopback
        case a == 10: return true                        // 10.0.0.0/8
        case a == 172 && (16...31).contains(b): return true  // 172.16.0.0/12
        case a == 192 && b == 168: return true           // 192.168.0.0/16
        case a == 169 && b == 254: return true           // 169.254.0.0/16 link-local
        default: return false
        }
    }
}

enum CustomAIAuthHeader: String, CaseIterable, Identifiable {
    case bearer
    case xAPIKey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bearer: return "Bearer"
        case .xAPIKey: return "x-api-key"
        }
    }
}

// MARK: - Provider protocol

protocol AIProviderClient {
    /// Send a chat turn and return the assistant reply text.
    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String

    /// Fetch the provider's live model list and return plain model ids.
    func fetchModels(key: String, session: URLSession) async throws -> [String]
}

// MARK: - Shared HTTP helpers

/// Execute a request, map HTTP status codes to `AICoachError`, return the decoded JSON object.
func performRequest(_ req: URLRequest, session: URLSession) async throws -> [String: Any] {
    let data: Data
    let response: URLResponse

    do {
        (data, response) = try await session.data(for: req)
    } catch {
        throw AICoachError.network(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
        throw AICoachError.network("no HTTP response")
    }

    switch http.statusCode {
    case 200...299:
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AICoachError.decode
        }

        return obj
    case 401, 403:
        throw AICoachError.badKey
    case 429:
        throw AICoachError.rateLimited
    default:
        throw AICoachError.server(http.statusCode, providerErrorMessage(from: data))
    }
}

/// Best-effort extraction of a human-readable message from a provider error body.
func providerErrorMessage(from data: Data) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

    if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
    if let msg = obj["message"] as? String { return msg }

    return ""
}
