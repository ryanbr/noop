import XCTest
@testable import Strand

/// #1074: pins the two pure Custom-provider helpers that mirror Android `AiCoach.normalizeCustomBaseUrl`
/// and `AiCoach.emptyReplyMessage`. The user-facing strings and the URL normalisation must stay
/// byte-identical across platforms (the cross-platform parity contract). Pure logic — no network.
final class AICoachEmptyReplyAndUrlTests: XCTestCase {

    // MARK: - normalizeCustomBaseURL (parity with Android AiCoachCustomUrlTest)

    func testNormalizeLeavesBareBaseUntouched() {
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("https://api.deepseek.com"),
                       "https://api.deepseek.com")
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("https://api.deepseek.com/v1"),
                       "https://api.deepseek.com/v1")
    }

    func testNormalizeTrimsTrailingSlash() {
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("https://api.deepseek.com/v1/"),
                       "https://api.deepseek.com/v1")
    }

    func testNormalizeStripsChatCompletionsSuffix() {
        // A user who pastes the whole chat URL: the /models scan otherwise hit
        // .../chat/completions/models and silently returned nothing (#1074).
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("https://api.deepseek.com/v1/chat/completions"),
                       "https://api.deepseek.com/v1")
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("https://api.deepseek.com/chat/completions"),
                       "https://api.deepseek.com")
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("https://api.deepseek.com/v1/chat/completions/"),
                       "https://api.deepseek.com/v1")
    }

    func testNormalizeStripsBareCompletionsSuffix() {
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("http://192.168.1.10:11434/v1/completions"),
                       "http://192.168.1.10:11434/v1")
    }

    func testNormalizeLeavesLocalBaseUntouched() {
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("http://192.168.1.10:11434/v1"),
                       "http://192.168.1.10:11434/v1")
    }

    func testNormalizeTrimsWhitespace() {
        XCTAssertEqual(AIProvider.normalizeCustomBaseURL("  https://api.deepseek.com/v1  "),
                       "https://api.deepseek.com/v1")
    }

    // MARK: - emptyReplyError (parity with Android AiCoachEmptyReplyTest)

    func testEmptyReplySurfacesProviderErrorMessage() {
        // Some OpenAI-compatible servers return the real error INSIDE a 200 body.
        let json: [String: Any] = ["error": ["message": "Model does not exist"]]
        XCTAssertEqual(emptyReplyError(json).errorDescription,
                       "The provider returned an error: Model does not exist")
    }

    func testEmptyReplyFallsBackToModelHintWhenNoError() {
        let json: [String: Any] = ["choices": []]
        XCTAssertEqual(emptyReplyError(json).errorDescription,
                       "The provider returned an empty reply. If you set a custom model by hand, check "
                       + "that the model name is one the provider actually offers.")
    }

    func testEmptyReplyIgnoresBlankProviderMessage() {
        let json: [String: Any] = ["error": ["message": ""]]
        XCTAssertEqual(emptyReplyError(json).errorDescription,
                       "The provider returned an empty reply. If you set a custom model by hand, check "
                       + "that the model name is one the provider actually offers.")
    }

    // MARK: - parseChatContent wiring (Custom provider)

    func testCustomParseThrowsEmptyReplyErrorOnErrorBody() {
        let json: [String: Any] = ["error": ["message": "Insufficient balance"]]
        XCTAssertThrowsError(try CustomClient().parseChatContent(json)) { error in
            XCTAssertEqual((error as? AICoachError)?.errorDescription,
                           "The provider returned an error: Insufficient balance")
        }
    }

    func testCustomParseTreatsBlankContentAsEmptyReply() {
        // A present-but-empty content string is a truncated/empty reply, not a valid answer.
        let json: [String: Any] = [
            "choices": [["message": ["content": ""]]]
        ]
        XCTAssertThrowsError(try CustomClient().parseChatContent(json))
    }

    func testCustomParseTreatsWhitespaceOnlyContentAsEmptyReply() {
        // Content is trimmed before the empty-check (parity with Android's ?.trim()): a whitespace-only
        // reply is empty, not a valid answer.
        let json: [String: Any] = [
            "choices": [["message": ["content": "   \n  "]]]
        ]
        XCTAssertThrowsError(try CustomClient().parseChatContent(json))
    }

    func testCustomParseTrimsSurroundingWhitespace() {
        let json: [String: Any] = [
            "choices": [["message": ["content": "  Get more sleep.  \n"]]]
        ]
        XCTAssertEqual(try CustomClient().parseChatContent(json), "Get more sleep.")
    }
}
