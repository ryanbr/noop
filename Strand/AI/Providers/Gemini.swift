import Foundation
import StrandAnalytics

/// Native Gemini body, preserving the existing sampling value and output cap.
func geminiRequestBody(systemPrompt: String, contents: [[String: Any]]) -> [String: Any] {
    [
        "system_instruction": ["parts": [["text": systemPrompt]]],
        "contents": contents,
        "generationConfig": ["temperature": 0.6, "maxOutputTokens": 4096] as [String: Any]
    ]
}

struct GeminiClient: AIProviderClient {

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        let contents = GeminiClient.buildContents(from: messages)
        let body = geminiRequestBody(systemPrompt: systemPrompt, contents: contents)

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
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw emptyReplyError(json)
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw emptyReplyError(json) }   // #1074: friendlier empty-reply hint
        return text
    }

    /// K11: Build Gemini "contents" array from wire messages. Extracted so the multimodal path
    /// (which appends an `inline_data` image part to the last user turn) can reuse it.
    static func buildContents(from messages: [(role: ChatMessage.Role, content: String)]) -> [[String: Any]] {
        var contents: [[String: Any]] = []
        for m in messages {
            contents.append([
                "role": m.role == .assistant ? "model" : "user",
                "parts": [["text": m.content]]
            ])
        }
        return contents
    }

    /// K11: Append a base64-encoded image to the last user turn's parts (Gemini multimodal).
    /// The image is sent as an `inline_data` part alongside the existing text part.
    static func appendImage(_ base64: String, mimeType: String, to contents: inout [[String: Any]]) {
        guard let lastUserIdx = contents.lastIndex(where: { ($0["role"] as? String) == "user" }) else { return }
        var parts = contents[lastUserIdx]["parts"] as? [[String: Any]] ?? []
        parts.append(["inline_data": ["mime_type": mimeType, "data": base64]])
        contents[lastUserIdx]["parts"] = parts
    }

    /// K1: Stream via `:streamGenerateContent?alt=sse`. Same body as `send`, different endpoint +
    /// SSE parsing. The concatenated deltas are byte-identical to `send`'s return (parity pin in
    /// `SseDeltasTests.geminiReassembleMatchesFullReply`).
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        try await streamWithImage(key: key, model: model, systemPrompt: systemPrompt,
                                  messages: messages, inlineImage: nil, session: session, onDelta: onDelta)
    }

    /// K11: Stream with an optional inline image (base64 PNG). Appends the image as
    /// `inline_data` to the last user turn's parts, then streams as normal.
    func streamWithImage(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        inlineImage: String?,
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var contents = GeminiClient.buildContents(from: messages)
        if let image = inlineImage {
            GeminiClient.appendImage(image, mimeType: "image/png", to: &contents)
        }

        let body = geminiRequestBody(systemPrompt: systemPrompt, contents: contents)

        guard let url = URL(string: "\(AIProvider.gemini.endpoint.absoluteString)/\(model):streamGenerateContent?alt=sse") else {
            throw AICoachError.network("invalid model id")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.geminiDelta(payload) {
                onDelta(delta)
            }
        }
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var url = URLComponents(url: AIProvider.gemini.modelsEndpoint, resolvingAgainstBaseURL: false)!
            if let cursor { url.queryItems = [URLQueryItem(name: "pageToken", value: cursor)] }
            var req = URLRequest(url: url.url!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let json = try await performRequest(req, session: session)
            for id in parseModels(json) where !ids.contains(id) { ids.append(id) }
            cursor = json["nextPageToken"] as? String
        } while cursor.map { !$0.isEmpty && seenCursors.insert($0).inserted } == true
        return ids
    }

    /// Pure: unwrap Gemini's `{"models":[{"name":"models/…"}]}` — strip the prefix, keep chat-capable
    /// text generation models only, using supportedGenerationMethods when supplied.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["models"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for row in list {
            guard let raw = row["name"] as? String else { continue }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            guard id.hasPrefix("gemini"),
                  !["embedding", "aqa", "-tts", "-live", "native-audio"].contains(where: id.contains) else { continue }
            if let methods = row["supportedGenerationMethods"] as? [String],
               !methods.contains("generateContent") { continue }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}
