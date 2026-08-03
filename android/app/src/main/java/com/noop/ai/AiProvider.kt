package com.noop.ai

/**
 * AI Coach providers. The user brings their own API key for one of these and the app
 * sends a compact text summary of their metrics + their question to the chosen provider.
 *
 * Provider names are the only branding shown — there is no app-author / model-vendor
 * branding beyond the provider name the user picks.
 *
 * Wire formats are encoded in [AiCoach]; this enum only carries the display name, the
 * default model, the curated list of selectable models, the chat HTTPS endpoint, and the
 * models-list endpoint used to fetch the provider's live catalogue.
 *
 * The [models] list is a sensible, curated starting point — the user can also fetch the
 * provider's live list (merged in at runtime) or type any model id via "Custom…", so the
 * app never has to ship an exhaustive or up-to-date catalogue.
 */
enum class AiProvider(
    val displayName: String,
    val defaultModel: String,
    val models: List<String>,
    val endpoint: String,
    val modelsEndpoint: String,
) {
    OPENAI(
        displayName = "OpenAI",
        defaultModel = "gpt-4o-mini",
        models = listOf(
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4.1-nano",
        ),
        endpoint = "https://api.openai.com/v1/chat/completions",
        modelsEndpoint = "https://api.openai.com/v1/models",
    ),
    ANTHROPIC(
        displayName = "Anthropic",
        defaultModel = "claude-sonnet-4-6",
        models = listOf(
            "claude-opus-4-8",
            "claude-sonnet-4-6",
            "claude-haiku-4-5-20251001",
            "claude-3-7-sonnet-latest",
            "claude-3-5-sonnet-latest",
            "claude-3-5-haiku-latest",
            "claude-3-opus-latest",
        ),
        endpoint = "https://api.anthropic.com/v1/messages",
        modelsEndpoint = "https://api.anthropic.com/v1/models",
    ),

    /**
     * Google Gemini (BYO key). NATIVE Google format — the byte-for-byte twin of the Swift
     * `GeminiClient` (`Strand/AI/Providers/Gemini.swift`): `x-goog-api-key` auth, a `system_instruction`
     * + `contents`/`parts` body, and `candidates[].content.parts[].text` replies. [endpoint] is the base
     * models URL; the per-call `/<model>:generateContent` suffix is appended in [AiCoach.callGemini]
     * (kept literal so the `:` is never percent-encoded).
     *
     * VERSION-CHURN-FREE (#400): the default + curated list use Google's stable `-latest` ALIASES, which
     * always resolve to the current stable model in each tier — so Gemini's rapid releases (2.5 → 3.x → …)
     * never need a code bump here. The dropdown itself is already version-agnostic: [AiCoach.fetchModels]
     * queries the live `/models` catalogue and [AiCoach.parseGeminiModels] keeps EVERY `gemini*` id, so a
     * user with a key sees whatever concrete versions Google currently serves and can pin one. Same list +
     * default as the Swift enum.
     */
    GEMINI(
        displayName = "Google Gemini",
        defaultModel = "gemini-flash-latest",
        models = listOf(
            "gemini-pro-latest",
            "gemini-flash-latest",
            "gemini-flash-lite-latest",
        ),
        endpoint = "https://generativelanguage.googleapis.com/v1beta/models",
        modelsEndpoint = "https://generativelanguage.googleapis.com/v1beta/models",
    ),

    /**
     * A generic OpenAI-compatible server the user points at — typically a LOCAL LLM such as
     * Ollama, LM Studio or llama.cpp (`http://localhost:11434/v1`), or any self-hosted gateway.
     * The endpoints here are placeholders: the real chat/models URLs are built at call time from
     * the user-set base URL (see [AiCoach] / [AiKeyStore.readCustomBaseUrl]). The API key is
     * optional — local servers usually need none.
     */
    CUSTOM(
        displayName = "Custom (OpenAI-compatible)",
        defaultModel = "",
        models = emptyList(),
        endpoint = "",
        modelsEndpoint = "",
    );

    companion object {
        /** Resolve a provider by its persisted [name], falling back to [OPENAI]. */
        fun fromName(name: String?): AiProvider =
            entries.firstOrNull { it.name == name } ?: OPENAI
    }
}

enum class CustomAiAuthHeader(val displayName: String) {
    BEARER("Bearer"),
    X_API_KEY("x-api-key");

    companion object {
        fun fromName(name: String?): CustomAiAuthHeader =
            entries.firstOrNull { it.name == name } ?: BEARER
    }
}
