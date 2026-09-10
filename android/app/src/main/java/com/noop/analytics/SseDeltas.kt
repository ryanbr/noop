package com.noop.analytics

import org.json.JSONArray
import org.json.JSONObject

// SseDeltas.kt — pure SSE delta parsing for AI provider streaming.
//
// The verifiable core of K1 (streaming): given one SSE `data:` payload, extract the text delta
// for the provider's wire shape. Pure + deterministic so it is unit-testable without a network,
// and byte-identical to the Swift twin `StrandAnalytics.SseDeltas`. The streaming HTTP glue
// (OkHttp source / URLSession.bytes) is thin and calls into these pure functions per line.
//
// No network, no I/O — only org.json (Android core). The anonymity / no-raw-egress posture is
// unchanged: streaming changes transport, not payload.

object SseDeltas {

    /** The SSE stream terminator sent by OpenAI-compatible servers. */
    const val DONE_MARKER = "[DONE]"

    // MARK: - SSE line splitting

    /** Strip the `data: ` prefix from one SSE line and return the raw payload, or null for blank
     *  lines (event separators), comments (`: …`), or non-data fields (`event:`, `id:`, etc.).
     *  Pure; byte-twin of Swift `dataPayload(fromLine:)`. */
    fun dataPayload(fromLine: String): String? {
        val trimmed = fromLine.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.startsWith(":")) return null
        if (trimmed.startsWith("data:")) {
            var payload = trimmed.substring("data:".length)
            if (payload.startsWith(" ")) payload = payload.substring(1)
            return payload
        }
        return null
    }

    /** True when a data payload is the `[DONE]` terminator (OpenAI-compatible). Pure. */
    fun isDone(payload: String): Boolean = payload.trim() == DONE_MARKER

    // MARK: - Per-provider delta extraction

    /** Extract the text delta from an OpenAI-compatible SSE data payload.
     *  Shape: `{"choices":[{"delta":{"content":"hello"}}]}` → `"hello"`.
     *  Returns null for a `[DONE]` line, a payload with no choices, or a non-content delta.
     *  Pure; byte-twin of Swift `openAiDelta`. */
    fun openAiDelta(payload: String): String? {
        if (isDone(payload)) return null
        return try {
            val obj = JSONObject(payload)
            val choices = obj.optJSONArray("choices") ?: return null
            val first = choices.optJSONObject(0) ?: return null
            val delta = first.optJSONObject("delta") ?: return null
            delta.optString("content").takeIf { it.isNotEmpty() }
        } catch (e: Exception) { null }
    }

    /** Extract the text delta from a Gemini SSE data payload (`:streamGenerateContent?alt=sse`).
     *  Shape: `{"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}` → `"hello"`.
     *  Pure; byte-twin of Swift `geminiDelta`. */
    fun geminiDelta(payload: String): String? {
        return try {
            val obj = JSONObject(payload)
            val candidates = obj.optJSONArray("candidates") ?: return null
            val first = candidates.optJSONObject(0) ?: return null
            val content = first.optJSONObject("content") ?: return null
            val parts = content.optJSONArray("parts") ?: return null
            val sb = StringBuilder()
            for (i in 0 until parts.length()) {
                val text = parts.optJSONObject(i)?.optString("text")
                if (!text.isNullOrEmpty()) sb.append(text)
            }
            sb.toString().takeIf { it.isNotEmpty() }
        } catch (e: Exception) { null }
    }

    /** Extract the text delta from an Anthropic SSE data payload.
     *  Shape: `{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}` → `"hello"`.
     *  Returns null for non-text-delta events. Pure; byte-twin of Swift `anthropicDelta`. */
    fun anthropicDelta(payload: String): String? {
        return try {
            val obj = JSONObject(payload)
            if (obj.optString("type") != "content_block_delta") return null
            val delta = obj.optJSONObject("delta") ?: return null
            if (delta.optString("type") != "text_delta") return null
            delta.optString("text").takeIf { it.isNotEmpty() }
        } catch (e: Exception) { null }
    }

    // MARK: - Full-stream reassembly (test helper)

    /** Reassemble the full reply text from a complete SSE stream (all lines, in order) for the
     *  given provider shape. Pure; used by tests to assert the streamed text equals the non-streamed
     *  reply. Byte-twin of Swift `reassemble`. */
    fun reassemble(lines: List<String>, provider: SseProvider): String {
        val sb = StringBuilder()
        for (line in lines) {
            val payload = SseDeltas.dataPayload(fromLine = line)
            if (payload == null) continue
            val delta: String? = if (provider == SseProvider.OPEN_AI || provider == SseProvider.CUSTOM) {
                SseDeltas.openAiDelta(payload)
            } else if (provider == SseProvider.GEMINI) {
                SseDeltas.geminiDelta(payload)
            } else {
                SseDeltas.anthropicDelta(payload)
            }
            if (delta != null) sb.append(delta)
        }
        return sb.toString()
    }
}

/** The provider wire shape to use for delta extraction. CUSTOM shares the OpenAI shape. */
enum class SseProvider { OPEN_AI, CUSTOM, GEMINI, ANTHROPIC }
