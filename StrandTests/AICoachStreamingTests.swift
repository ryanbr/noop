import XCTest
import Foundation
@testable import Strand

/// A client whose send() returns a canned string, to prove the default stream() yields it as one chunk.
private struct OneShotClient: AIProviderClient {
    let reply: String
    func send(key: String, model: String, systemPrompt: String,
              messages: [(role: ChatMessage.Role, content: String)], session: URLSession) async throws -> String {
        reply
    }
    func fetchModels(key: String, session: URLSession) async throws -> [String] { [] }
}

final class StreamingAdapterTests: XCTestCase {
    func testDefaultStreamYieldsWholeReplyAsOneChunk() async throws {
        let client = OneShotClient(reply: "Hello world")
        var chunks: [String] = []
        for try await c in client.stream(key: "", model: "m", systemPrompt: "s",
                                         messages: [(.user, "hi")], session: .shared) {
            chunks.append(c)
        }
        XCTAssertEqual(chunks, ["Hello world"])
    }
}

@MainActor
final class SendStreamingTests: XCTestCase {
    func testStreamingAccumulatesChunksIntoOneAssistantMessage() async {
        let engine = AICoachEngine(repo: Repository(deviceId: "test-aicoach-streaming"))
        engine.provider = .custom
        #if DEBUG
        engine.streamOverride = { _ in
            AsyncThrowingStream { c in
                c.yield("He"); c.yield("llo"); c.finish()
            }
        }
        #endif
        await engine.sendStreaming("hi")
        XCTAssertEqual(engine.messages.last?.role, .assistant)
        XCTAssertEqual(engine.messages.last?.text, "Hello")
        XCTAssertFalse(engine.sending)
    }
}
