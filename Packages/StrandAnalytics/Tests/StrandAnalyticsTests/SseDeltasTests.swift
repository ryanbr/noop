import XCTest
@testable import StrandAnalytics

/// Byte-identity pin for the SSE delta parser. The same SSE lines MUST produce the same text as
/// the Android twin `com.noop.analytics.SseDeltasTest`. Cross-platform parity is the contract.
final class SseDeltasTests: XCTestCase {

    // MARK: - SSE line splitting

    func testStripsDataPrefix() {
        XCTAssertEqual(SseDeltas.dataPayload(fromLine: "data: {\"hello\":1}"), "{\"hello\":1}")
    }

    func testStripsDataPrefixNoSpace() {
        XCTAssertEqual(SseDeltas.dataPayload(fromLine: "data:{\"hello\":1}"), "{\"hello\":1}")
    }

    func testBlankLineReturnsNil() {
        XCTAssertNil(SseDeltas.dataPayload(fromLine: ""))
        XCTAssertNil(SseDeltas.dataPayload(fromLine: "   "))
    }

    func testCommentLineReturnsNil() {
        XCTAssertNil(SseDeltas.dataPayload(fromLine: ": keep-alive"))
    }

    func testNonDataFieldReturnsNil() {
        XCTAssertNil(SseDeltas.dataPayload(fromLine: "event: content_block_delta"))
        XCTAssertNil(SseDeltas.dataPayload(fromLine: "id: 12345"))
        XCTAssertNil(SseDeltas.dataPayload(fromLine: "retry: 1000"))
    }

    func testIsDone() {
        XCTAssertTrue(SseDeltas.isDone("[DONE]"))
        XCTAssertTrue(SseDeltas.isDone(" [DONE] "))
        XCTAssertFalse(SseDeltas.isDone("{\"choices\":[]}"))
    }

    // MARK: - CRLF parity (Kotlin trim() strips \r; Swift .whitespaces does not)

    func testIsDoneStripsCRLF() {
        // A CRLF stream leaves a trailing \r after \n-splitting. Kotlin's trim() removes it;
        // Swift must use .whitespacesAndNewlines to match, or isDone returns false on iOS.
        XCTAssertTrue(SseDeltas.isDone("[DONE]\r"))
        XCTAssertTrue(SseDeltas.isDone("[DONE]\r\n"))
    }

    func testDataPayloadStripsCRLF() {
        XCTAssertEqual(SseDeltas.dataPayload(fromLine: "data: {\"hello\":1}\r"), "{\"hello\":1}")
    }

    // MARK: - OpenAI delta

    func testOpenAiContentDelta() {
        let payload = #"{"choices":[{"index":0,"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(SseDeltas.openAiDelta(payload), "Hello")
    }

    func testOpenAiRoleDeltaReturnsNil() {
        // The first chunk often carries only the role, no content.
        let payload = #"{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#
        XCTAssertNil(SseDeltas.openAiDelta(payload))
    }

    func testOpenAiDoneReturnsNil() {
        XCTAssertNil(SseDeltas.openAiDelta("[DONE]"))
    }

    func testOpenAiEmptyChoicesReturnsNil() {
        XCTAssertNil(SseDeltas.openAiDelta(#"{"choices":[]}"#))
    }

    func testOpenAiMalformedReturnsNil() {
        XCTAssertNil(SseDeltas.openAiDelta("not json"))
    }

    func testOpenAiEmptyContentReturnsNil() {
        // OpenAI's usual first delta carries `"content": ""`. Kotlin returns null (optString +
        // takeIf { isNotEmpty() }); Swift must match so onDelta doesn't fire on one platform only
        // (K14 haptics hang off delta arrival).
        let payload = #"{"choices":[{"index":0,"delta":{"content":""}}]}"#
        XCTAssertNil(SseDeltas.openAiDelta(payload))
    }

    // MARK: - Gemini delta

    func testGeminiTextDelta() {
        let payload = #"{"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}"#
        XCTAssertEqual(SseDeltas.geminiDelta(payload), "Hello")
    }

    func testGeminiMultiPartDelta() {
        let payload = #"{"candidates":[{"content":{"parts":[{"text":"Hello "},{"text":"world"}]}}]}"#
        XCTAssertEqual(SseDeltas.geminiDelta(payload), "Hello world")
    }

    func testGeminiFinishReasonChunkReturnsNil() {
        let payload = #"{"candidates":[{"content":{"parts":[]},"finishReason":"STOP"}]}"#
        XCTAssertNil(SseDeltas.geminiDelta(payload))
    }

    func testGeminiMalformedReturnsNil() {
        XCTAssertNil(SseDeltas.geminiDelta("not json"))
    }

    // MARK: - Anthropic delta

    func testAnthropicTextDelta() {
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(SseDeltas.anthropicDelta(payload), "Hello")
    }

    func testAnthropicMessageStartReturnsNil() {
        let payload = #"{"type":"message_start","message":{"id":"msg_1"}}"#
        XCTAssertNil(SseDeltas.anthropicDelta(payload))
    }

    func testAnthropicPingReturnsNil() {
        let payload = #"{"type":"ping"}"#
        XCTAssertNil(SseDeltas.anthropicDelta(payload))
    }

    func testAnthropicContentBlockStartReturnsNil() {
        let payload = #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
        XCTAssertNil(SseDeltas.anthropicDelta(payload))
    }

    func testAnthropicMessageStopReturnsNil() {
        let payload = #"{"type":"message_stop"}"#
        XCTAssertNil(SseDeltas.anthropicDelta(payload))
    }

    func testAnthropicMalformedReturnsNil() {
        XCTAssertNil(SseDeltas.anthropicDelta("not json"))
    }

    func testAnthropicEmptyTextReturnsNil() {
        // Parity with Kotlin: empty text → null, not "" (same reason as OpenAI empty content).
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}"#
        XCTAssertNil(SseDeltas.anthropicDelta(payload))
    }

    // MARK: - Full-stream reassembly (the parity pin: streamed == non-streamed)

    func testOpenAiReassembleMatchesFullReply() {
        // A realistic 3-chunk OpenAI stream for the reply "Hello, world!".
        let lines = [
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}",
            "",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}",
            "",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\", world!\"}}]}",
            "",
            "data: {\"choices\":[{\"index\":0,\"finish_reason\":\"stop\"}]}",
            "",
            "data: [DONE]",
            "",
        ]
        let reassembled = SseDeltas.reassemble(lines: lines, provider: .openAi)
        // The non-streamed reply would be "Hello, world!" (the full content from choices[0].message.content).
        XCTAssertEqual(reassembled, "Hello, world!")
    }

    func testGeminiReassembleMatchesFullReply() {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Recovery\"}]}}]}",
            "",
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\" is \"}]}}]}",
            "",
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"good.\"}]},\"finishReason\":\"STOP\"}]}",
            "",
        ]
        XCTAssertEqual(SseDeltas.reassemble(lines: lines, provider: .gemini), "Recovery is good.")
    }

    func testAnthropicReassembleMatchesFullReply() {
        let lines = [
            "event: message_start",
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}",
            "",
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Sleep\"}}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" well.\"}}",
            "",
            "event: content_block_stop",
            "data: {\"type\":\"content_block_stop\",\"index\":0}",
            "",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
            "",
        ]
        XCTAssertEqual(SseDeltas.reassemble(lines: lines, provider: .anthropic), "Sleep well.")
    }

    func testCustomSharesOpenAiShape() {
        let lines = [
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hi\"}}]}",
            "",
            "data: [DONE]",
            "",
        ]
        XCTAssertEqual(SseDeltas.reassemble(lines: lines, provider: .custom), "Hi")
    }

    // MARK: - Empty / edge cases

    func testEmptyStreamReassemblesToEmpty() {
        XCTAssertEqual(SseDeltas.reassemble(lines: [], provider: .openAi), "")
    }

    func testOnlyDoneReassemblesToEmpty() {
        XCTAssertEqual(SseDeltas.reassemble(lines: ["data: [DONE]", ""], provider: .openAi), "")
    }

    func testIgnoresCommentLines() {
        let lines = [
            ": keep-alive",
            "",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}",
            "",
            "data: [DONE]",
            "",
        ]
        XCTAssertEqual(SseDeltas.reassemble(lines: lines, provider: .openAi), "ok")
    }
}
