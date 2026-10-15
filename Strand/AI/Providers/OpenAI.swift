import Foundation
import StrandAnalytics

/// Shared Chat Completions body for regular and streaming requests, including reasoning models.
func openAIChatBody(model: String, messages: [[String: Any]], stream: Bool) -> [String: Any] {
    var body: [String: Any] = ["model": model, "messages": messages, "max_completion_tokens": 4096]
    if (model.hasPrefix("gpt-4") || model.hasPrefix("gpt-3.5") || model.hasPrefix("gpt-audio")),
       !model.contains("-search") { body["temperature"] = 0.6 }
    if stream { body["stream"] = true }
    return body
}

/// Exclude models whose endpoints or output formats this text-chat client cannot handle.
func isOpenAIChatModel(_ id: String) -> Bool {
    let reasoning = id.hasPrefix("o") && id.dropFirst().first.map { ("0"..."9").contains($0) } == true
    let gpt = id.hasPrefix("gpt")
    let specialized = ["gpt-image", "-pro", "-codex", "-deep-research", "-instruct", "-realtime", "-transcribe", "-tts"]
    return (gpt || reasoning) && !specialized.contains(where: id.contains)
}

struct OpenAIClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        let req = try chatRequest(key: key, model: model, wire: wire, stream: false)
        let json = try await performRequest(req, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw emptyReplyError(json)
        }
        return content
    }

    /// Stream the same parameters as `send`, with `stream: true` added.
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

        let req = try chatRequest(key: key, model: model, wire: wire, stream: true)

        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.openAiDelta(payload) {
                onDelta(delta)
            }
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.openAI.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Unwrap the `/models` body into candidates for this client's Chat Completions endpoint.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for row in list {
            guard let raw = row["id"] as? String else { continue }
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isOpenAIChatModel(id), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    // MARK: Private

    private func chatRequest(
        key: String,
        model: String,
        wire: [[String: Any]],
        stream: Bool
    ) throws -> URLRequest {
        var req = URLRequest(url: AIProvider.openAI.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: openAIChatBody(model: model, messages: wire, stream: stream))
        return req
    }
}
