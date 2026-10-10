import Foundation
import StrandAnalytics

struct AnthropicClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Anthropic: system prompt is a top-level field, not a message role.
        let body: [String: Any] = [
            "model": model,
            // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
            // reply complete (a cap, not a target — the system prompt keeps it short). Matches the others.
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": wire
        ]

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        let text = Self.replyText(json)
        guard !text.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        return text
    }

    /// Thinking and tool blocks may precede or separate the visible text blocks.
    static func replyText(_ json: [String: Any]) -> String {
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { block -> String? in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// K1: Stream via `stream: true`. Anthropic SSE uses typed events; we extract `content_block_delta`
    /// with `text_delta` via `SseDeltas.anthropicDelta`. Byte-parity pin in
    /// `SseDeltasTests.anthropicReassembleMatchesFullReply`.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = []
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": wire,
            "stream": true
        ]

        var req = URLRequest(url: AIProvider.anthropic.endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.anthropicDelta(payload) {
                onDelta(delta)
            }
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var url = URLComponents(url: AIProvider.anthropic.modelsEndpoint, resolvingAgainstBaseURL: false)!
            if let cursor { url.queryItems = [URLQueryItem(name: "after_id", value: cursor)] }
            var req = URLRequest(url: url.url!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let json = try await performRequest(req, session: session)
            for id in parseModels(json) where !ids.contains(id) { ids.append(id) }
            cursor = json["has_more"] as? Bool == true ? json["last_id"] as? String : nil
        } while cursor.map { !$0.isEmpty && seenCursors.insert($0).inserted } == true
        return ids
    }

    /// Pure: unwrap the `/models` body into ids (Anthropic keeps all non-empty). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for row in list {
            guard let raw = row["id"] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}
