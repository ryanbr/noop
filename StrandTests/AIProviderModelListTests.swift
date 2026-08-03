import XCTest
@testable import Strand

/// Pins each provider client's pure model-list parser. Each provider returns a differently-shaped
/// "list models" body; the parser unwraps the right envelope, strips Gemini's "models/" id prefix,
/// and applies the per-provider relevance filter (chat-capable gemini-* only). Pure logic — no
/// network — so the wire-shape contracts stay covered without hitting a live API.
final class AIProviderModelListTests: XCTestCase {

    // MARK: - Gemini

    func testGeminiStripsModelsPrefixAndKeepsChatModels() {
        // Real shape: {"models":[{"name":"models/gemini-..."}]}. Non-chat ids (embeddings, AQA)
        // and non-gemini ids must be filtered out; the "models/" prefix must be stripped.
        let body: [String: Any] = [
            "models": [
                ["name": "models/gemini-2.5-pro"],
                ["name": "models/gemini-2.5-flash"],
                ["name": "models/gemini-embedding-001"],   // embeddings — drop
                ["name": "models/aqa"],                     // AQA — drop
                ["name": "models/text-embedding-004"],      // not gemini-* — drop
                ["name": "models/imagen-3.0-generate-002"]  // not gemini-* — drop
            ]
        ]
        let ids = GeminiClient().parseModels(body)
        XCTAssertEqual(ids, ["gemini-2.5-pro", "gemini-2.5-flash"])
    }

    func testGeminiToleratesNameWithoutModelsPrefix() {
        // Defensive: an id that already lacks the "models/" prefix is still accepted as-is.
        let body: [String: Any] = ["models": [["name": "gemini-2.0-flash"]]]
        XCTAssertEqual(GeminiClient().parseModels(body), ["gemini-2.0-flash"])
    }

    func testGeminiDropsEmptyAndMalformedRows() {
        let body: [String: Any] = [
            "models": [
                ["name": ""],                 // empty — drop
                ["id": "gemini-2.5-flash"],   // wrong key for gemini — drop
                ["name": "models/gemini-2.5-flash-lite"]
            ]
        ]
        XCTAssertEqual(GeminiClient().parseModels(body), ["gemini-2.5-flash-lite"])
    }

    func testGeminiWrongEnvelopeKeyYieldsEmpty() {
        // Gemini reads "models", not "data" — an OpenAI-shaped body must parse to nothing.
        let body: [String: Any] = ["data": [["id": "gemini-2.5-flash"]]]
        XCTAssertTrue(GeminiClient().parseModels(body).isEmpty)
    }

    // MARK: - existing providers unchanged

    func testOpenAIFiltersToGptAndOFamilies() {
        let body: [String: Any] = [
            "data": [
                ["id": "gpt-4o"],
                ["id": "o3-mini"],
                ["id": "text-embedding-3-large"], // not gpt/o — drop
                ["id": ""]                         // empty — drop
            ]
        ]
        XCTAssertEqual(OpenAIClient().parseModels(body), ["gpt-4o", "o3-mini"])
    }

    func testAnthropicKeepsAllNonEmptyIds() {
        let body: [String: Any] = [
            "data": [
                ["id": "claude-sonnet-4-6"],
                ["id": "claude-opus-4-8"],
                ["id": ""] // empty — drop
            ]
        ]
        XCTAssertEqual(AnthropicClient().parseModels(body), ["claude-sonnet-4-6", "claude-opus-4-8"])
    }

    // MARK: - Custom (OpenAI-compatible / local LLM)

    func testCustomKeepsAllNonEmptyIdsUnfiltered() {
        // A local server (Ollama / LM Studio) names models freely — none start with gpt/o, so unlike
        // OpenAI the Custom parser must keep them all (dropping only empties).
        let body: [String: Any] = [
            "data": [
                ["id": "llama3.1:8b"],
                ["id": "qwen2.5-coder"],
                ["id": "phi4"],
                ["id": ""] // empty — drop
            ]
        ]
        XCTAssertEqual(CustomClient().parseModels(body),
                       ["llama3.1:8b", "qwen2.5-coder", "phi4"])
    }

    func testCustomWrongEnvelopeKeyYieldsEmpty() {
        // Custom reads the OpenAI "data" envelope — a Gemini-shaped body parses to nothing.
        let body: [String: Any] = ["models": [["name": "models/llama3.1"]]]
        XCTAssertTrue(CustomClient().parseModels(body).isEmpty)
    }

    func testCustomKeepsGatewayCatalogModels() {
        let body: [String: Any] = [
            "service": "Gateway",
            "catalog": [
                ["tool": "OpenAI", "models": ["gpt-5", "gpt-5.5"]],
                ["tool": "Other", "models": ["claude-sonnet-4-6@default", "gpt-5"]]
            ]
        ]
        XCTAssertEqual(CustomClient().parseModels(body),
                       ["gpt-5", "gpt-5.5", "claude-sonnet-4-6@default"])
    }
}
