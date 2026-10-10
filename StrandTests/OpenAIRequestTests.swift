import Foundation
import XCTest
@testable import Strand

final class OpenAIRequestTests: XCTestCase {
    func testRegularAndStreamingBodiesUseReasoningCompatibleParameters() throws {
        let messages: [[String: Any]] = [["role": "user", "content": "Hallo"]]
        for model in ["gpt-5.4", "gpt-5-mini", "gpt-4.1", "o3"] {
            for stream in [false, true] {
                let body = openAIChatBody(model: model, messages: messages, stream: stream)
                XCTAssertEqual(body["model"] as? String, model)
                XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
                XCTAssertNil(body["max_tokens"])
                XCTAssertEqual(body["temperature"] as? Double, model == "gpt-4.1" ? 0.6 : nil)
                XCTAssertEqual(body["stream"] as? Bool, stream ? true : nil)
                let wire = try JSONSerialization.data(withJSONObject: body)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: wire) as? [String: Any])
                XCTAssertEqual((decoded["messages"] as? [[String: String]])?.first?["content"], "Hallo")
            }
        }
    }

    func testGPT54IsAvailableWithoutRefreshingModels() {
        XCTAssertTrue(AIProvider.openAI.modelOptions.contains("gpt-5.4"))
        XCTAssertTrue(AIProvider.openAI.modelOptions.contains("gpt-5.4-mini"))
        XCTAssertEqual(AIProvider.openAI.defaultModel, "gpt-5-mini")
        let original = ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini", "o3", "o4-mini"]
        XCTAssertTrue(original.allSatisfy(AIProvider.openAI.modelOptions.contains))
    }

    func testGeminiBodyPreservesExistingTemperatureAndOutputCap() throws {
        let body = geminiRequestBody(systemPrompt: "Coach", contents: [["role": "user", "parts": [["text": "Hallo"]]]])
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 4096)
        XCTAssertEqual(config["temperature"] as? Double, 0.6)
    }

    func testModelFilterMatchesAndroidOracleCases() {
        let expected = """
        gpt-5.4|true
        gpt-4o|true
        o3-mini|true
        gpt-5.4-pro|false
        gpt-5.4-pro-2026-03-05|false
        omni-moderation-latest|false
        o|false
        o４|false
        text-embedding-3-large|false
        gpt-image-1|false
        gpt-5.3-codex|false
        o3-deep-research|false
        gpt-4o-realtime-preview|false
        gpt-4o-mini-transcribe|false
        gpt-3.5-turbo-instruct|false
        gpt-4o-mini-search-preview|true
        gpt-4o-mini-tts|false
        gpt-4o-audio-preview|true
        gpt-audio|true
        """
        let actual: String = expected.split(separator: "\n").map { line -> String in
            let model = String(line.split(separator: "|")[0])
            return "\(model)|\(isOpenAIChatModel(model))"
        }.joined(separator: "\n")
        XCTAssertEqual(actual, expected)
    }
}
