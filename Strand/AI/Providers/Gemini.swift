import Foundation

struct GeminiClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var contents: [[String: Any]] = []
        for m in messages {
            contents.append([
                "role": m.role == .assistant ? "model" : "user",
                "parts": [["text": m.content]]
            ])
        }

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            // Gemini 2.5 counts THINKING tokens against maxOutputTokens; the other providers'
            // visible-reply cap (900) starves thinking models into empty replies (finishReason
            // MAX_TOKENS, no text parts). 4096 leaves room for both — the system prompt keeps the
            // visible reply short.
            "generationConfig": ["temperature": 0.6, "maxOutputTokens": 4096]
        ]

        // Built via URL(string:): appendingPathComponent percent-encodes the ":" in
        // ":generateContent" on some Foundation versions and the API rejects %3A.
        guard let url = URL(string: "\(AIProvider.gemini.endpoint.absoluteString)/\(model):generateContent") else {
            throw AICoachError.network("invalid model id")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        // Reply text can span several parts; join them (thinking models may emit more than one).
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw AICoachError.decode
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AICoachError.decode }
        return text
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.gemini.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap Gemini's `{"models":[{"name":"models/…"}]}` — strip the prefix, keep chat-capable
    /// gemini-* only (drop embeddings/AQA). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            guard id.hasPrefix("gemini"),
                  !id.contains("embedding"), !id.contains("aqa") else { return nil }
            return id
        }
    }
}
