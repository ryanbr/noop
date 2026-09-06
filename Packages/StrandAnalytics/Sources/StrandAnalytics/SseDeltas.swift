import Foundation

// SseDeltas.swift — pure SSE delta parsing for AI provider streaming.
//
// The verifiable core of K1 (streaming): given one SSE `data:` payload, extract the text delta
// for the provider's wire shape. Pure + deterministic so it is unit-testable without a network,
// and byte-identical to the Android twin `com.noop.analytics.SseDeltas`. The streaming HTTP glue
// (URLSession.bytes / OkHttp source) is thin and calls into these pure functions per line.
//
// No network, no Foundation URL loading, no I/O — only JSONSerialization (Foundation core, available
// in the package test target on macOS + Linux). The anonymity / no-raw-egress posture is unchanged:
// streaming changes transport, not payload.

/// Pure SSE delta extraction for the three provider wire shapes the coach speaks.
/// Byte-twin of Android `com.noop.analytics.SseDeltas`.
public enum SseDeltas {

    /// The SSE stream terminator sent by OpenAI-compatible servers.
    public static let doneMarker = "[DONE]"

    // MARK: - SSE line splitting

    /// Strip the `data: ` prefix from one SSE line and return the raw payload, or nil for blank
    /// lines (event separators), comments (`: …`), or non-data fields (`event:`, `id:`, etc.).
    /// Pure; byte-twin of Android `dataPayload(fromLine:)`.
    public static func dataPayload(fromLine line: String) -> String? {
        // SSE lines are terminated by \n; the caller splits on \n. A trailing \r (CRLF streams)
        // must be stripped — Kotlin's trim() removes \r, so .whitespacesAndNewlines keeps parity.
        // A blank line is an event separator — no payload. A line starting with ":" is a comment.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix(":") { return nil }
        // "data:" or "data: " — strip the prefix, then one optional leading space (SSE spec: the
        // space after the colon is not part of the value).
        if trimmed.hasPrefix("data:") {
            var payload = String(trimmed.dropFirst("data:".count))
            if payload.hasPrefix(" ") { payload = String(payload.dropFirst()) }
            return payload
        }
        // Other SSE fields (event:, id:, retry:) are not data — skip.
        return nil
    }

    /// True when a data payload is the `[DONE]` terminator (OpenAI-compatible). Pure.
    public static func isDone(_ payload: String) -> Bool {
        payload.trimmingCharacters(in: .whitespacesAndNewlines) == doneMarker
    }

    // MARK: - Per-provider delta extraction

    /// Extract the text delta from an OpenAI-compatible SSE data payload.
    /// Shape: `{"choices":[{"delta":{"content":"hello"}}]}` → `"hello"`.
    /// Returns nil for a `[DONE]` line, a payload with no choices, or a non-content delta (e.g.
    /// the `role` delta on the first chunk). Pure; byte-twin of Android `openAiDelta`.
    public static func openAiDelta(_ payload: String) -> String? {
        if isDone(payload) { return nil }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        // Kotlin twin returns null for empty content (optString.takeIf { isNotEmpty() }), so
        // onDelta does not fire for OpenAI's usual first delta `"content": ""`. Returning ""
        // here would fire onDelta on Swift but not Kotlin — breaks K14 haptic parity.
        return content.isEmpty ? nil : content
    }

    /// Extract the text delta from a Gemini SSE data payload (`:streamGenerateContent?alt=sse`).
    /// Shape: `{"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}` → `"hello"`.
    /// Gemini streams full candidate objects per chunk; each may carry multiple parts. Returns nil
    /// for a chunk with no text parts (e.g. the final `finishReason` chunk). Pure; byte-twin of
    /// Android `geminiDelta`.
    public static func geminiDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    /// Extract the text delta from an Anthropic SSE data payload.
    /// Shape: `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}`
    /// → `"hello"`. Returns nil for non-text-delta events (`message_start`, `ping`, `message_stop`,
    /// `content_block_start`, etc.). Pure; byte-twin of Android `anthropicDelta`.
    public static func anthropicDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String,
              type == "content_block_delta",
              let delta = obj["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String,
              deltaType == "text_delta",
              let text = delta["text"] as? String else { return nil }
        // Kotlin twin returns null for empty text — parity with openAiDelta above.
        return text.isEmpty ? nil : text
    }

    // MARK: - Full-stream reassembly (test helper)

    /// Reassemble the full reply text from a complete SSE stream (all lines, in order) for the
    /// given provider shape. Pure; used by tests to assert the streamed text equals the non-streamed
    /// reply. Byte-twin of Android `reassemble`.
    public static func reassemble(lines: [String], provider: SseProvider) -> String {
        var out = ""
        for line in lines {
            guard let payload = dataPayload(fromLine: line) else { continue }
            let delta: String?
            switch provider {
            case .openAi, .custom:  delta = openAiDelta(payload)
            case .gemini:           delta = geminiDelta(payload)
            case .anthropic:        delta = anthropicDelta(payload)
            }
            if let d = delta { out += d }
        }
        return out
    }
}

/// The provider wire shape to use for delta extraction. `.custom` shares the OpenAI shape.
public enum SseProvider {
    case openAi, custom, gemini, anthropic
}
