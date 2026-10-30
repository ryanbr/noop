import Foundation
import StrandAnalytics

/// OpenRouter (BYO key) — an OpenAI-compatible gateway in front of many vendors' models. Speaks the
/// same `chat/completions` wire format as `OpenAIClient` (Bearer auth, `choices[0].message.content`,
/// SSE deltas via `SseDeltas.openAiDelta`), so only the endpoints and the model-list parser differ.
/// Model ids are namespaced (`vendor/model`, optionally a `:free` variant), which is why the parser
/// keeps every non-empty id instead of OpenAI's `gpt*`/`o*` filter.
struct OpenRouterClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Same standard-params-first contract as OpenAI: a reasoning model behind the gateway may
        // reject `temperature`/`max_tokens`, so a 400 naming either retries with the modern shape.
        do {
            return try await chat(key: key, model: model, wire: wire, modernParams: false, session: session)
        } catch let AICoachError.server(code, detail) where code == 400 {
            let d = detail.lowercased()
            if d.contains("max_completion_tokens") || d.contains("max_tokens")
                || d.contains("temperature") || d.contains("unsupported") {
                return try await chat(key: key, model: model, wire: wire, modernParams: true, session: session)
            }
            throw AICoachError.server(code, detail)
        }
    }

    /// K1: Stream via `stream: true`; SSE parsing via `SseDeltas.openAiDelta`. The modern-params
    /// retry on 400 is not streamed (rare path), matching the OpenAI client.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        let body: [String: Any] = [
            "model": model,
            "messages": wire,
            "temperature": 0.6,
            "max_tokens": 4096,
            "stream": true
        ]

        var req = URLRequest(url: AIProvider.openRouter.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.openAiDelta(payload) {
                onDelta(delta)
            }
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.openRouter.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into every non-empty `data[].id`. OpenRouter namespaces ids
    /// (`anthropic/claude-sonnet-4.5`, `deepseek/deepseek-chat-v3.1:free`), so unlike OpenAI there is
    /// no useful prefix filter — dropping any of them would hide a model the user paid for. No
    /// network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }

    // MARK: Private

    /// `modernParams`: use `max_completion_tokens`, drop `temperature` — for gateways fronting
    /// reasoning models.
    private func chat(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": wire]
        // 4096 is a cap, not a target (#1074); matches the other OpenAI-compatible legs.
        if modernParams {
            body["max_completion_tokens"] = 4096
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 4096
        }

        var req = URLRequest(url: AIProvider.openRouter.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the gateway's real error if the 200 body has one
        }
        return content
    }
}
