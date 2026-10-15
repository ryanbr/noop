import Foundation
import XCTest
@testable import Strand

private final class AICoachURLProtocolStub: URLProtocol {
    struct Stubbed { let status: Int; let body: Data }
    nonisolated(unsafe) static var response = Stubbed(status: 500, body: Data())
    nonisolated(unsafe) static var queue: [Stubbed] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requestURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.requestURLs.append(request.url!)
        let stub = Self.queue.isEmpty ? Self.response : Self.queue.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session(status: Int, body: String) -> URLSession {
        response = Stubbed(status: status, body: Data(body.utf8))
        queue = []
        requestCount = 0
        requestURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AICoachURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

/// HTTP 429 keeps its stable explanation while surfacing any actionable detail the provider sent.
final class AICoachRateLimitTests: XCTestCase {
    private let request = URLRequest(url: URL(string: "https://provider.invalid/coach")!)
    private let base = "The provider is rate-limiting requests right now. Wait a moment and try again."

    func testRegularRequestIncludesNestedProviderMessage() async {
        let session = AICoachURLProtocolStub.session(
            status: 429,
            body: #"{"error":{"message":"Daily request quota exhausted"}}"#
        )

        do {
            _ = try await performRequest(request, session: session)
            XCTFail("expected rateLimited")
        } catch let error as AICoachError {
            XCTAssertEqual(error.errorDescription, base + " (Daily request quota exhausted)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStreamingRequestIncludesTopLevelProviderMessage() async {
        let session = AICoachURLProtocolStub.session(
            status: 429,
            body: #"{"message":"Tokens per minute exceeded"}"#
        )

        do {
            try await performStreamingRequest(request, session: session) { _ in
                XCTFail("an error response must not emit a stream delta")
            }
            XCTFail("expected rateLimited")
        } catch let error as AICoachError {
            XCTAssertEqual(error.errorDescription, base + " (Tokens per minute exceeded)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testMissingProviderMessageKeepsExistingCopy() {
        XCTAssertEqual(AICoachError.rateLimited("").errorDescription, base)
    }

    func testStreamingErrorInsideSuccessfulHttpResponseIsSurfaced() async {
        let session = AICoachURLProtocolStub.session(
            status: 200,
            body: "data: {\"choices\":[{\"delta\":{\"content\":\"Hallo\"}}],\"error\":null}\n\n"
                + "data: {\"error\":{\"message\":\"Generation failed\"}}\n\n"
        )
        defer { session.invalidateAndCancel() }
        var partial = ""
        do {
            try await OpenAIClient().stream(
                key: "test-key", model: "gpt-5.4", systemPrompt: "Coach",
                messages: [(.user, "Hallo")], session: session
            ) { partial += $0 }
            XCTFail("expected the provider's streaming error")
        } catch let error as AICoachError {
            XCTAssertEqual(error.errorDescription, "The provider returned an error: Generation failed")
            XCTAssertEqual(partial, "Hallo")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCustomParameterRetryWorksForRegularAndStreamingReplies() async throws {
        let previousURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey)
        UserDefaults.standard.set("https://provider.invalid/v1", forKey: AIProvider.customBaseURLKey)
        defer {
            if let previousURL {
                UserDefaults.standard.set(previousURL, forKey: AIProvider.customBaseURLKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AIProvider.customBaseURLKey)
            }
        }
        for stream in [false, true] {
            let session = AICoachURLProtocolStub.session(status: 500, body: "{}")
            defer { session.invalidateAndCancel() }
            AICoachURLProtocolStub.queue = [
                .init(status: 400, body: Data(#"{"error":{"message":"Use max_completion_tokens instead of max_tokens"}}"#.utf8)),
                .init(status: 200, body: Data(#"{"choices":[{"message":{"content":"Hallo"}}]}"#.utf8))
            ]
            var reply = ""
            if stream {
                try await CustomClient().stream(
                    key: "test-key", model: "gpt-5.4", systemPrompt: "Coach",
                    messages: [(.user, "Hallo")], session: session
                ) { reply += $0 }
            } else {
                reply = try await CustomClient().send(
                    key: "test-key", model: "gpt-5.4", systemPrompt: "Coach",
                    messages: [(.user, "Hallo")], session: session
                )
            }
            XCTAssertEqual(reply, "Hallo")
            XCTAssertEqual(AICoachURLProtocolStub.requestCount, 2)
        }
    }

    func testAnthropicReadsTextAfterThinkingAndAcrossBlocks() async throws {
        let session = AICoachURLProtocolStub.session(
            status: 200,
            body: #"{"content":[{"type":"thinking","thinking":"Summary"},{"type":"text","text":"Hallo "},{"type":"tool_use","name":"ignored"},{"type":"text","text":"Welt"}]}"#
        )
        defer { session.invalidateAndCancel() }
        let reply = try await AnthropicClient().send(
            key: "test-key", model: "claude-sonnet-5-5", systemPrompt: "Coach",
            messages: [(.user, "Hallo")], session: session
        )
        XCTAssertEqual(reply, "Hallo Welt")
    }

    func testGeminiRegularAndStreamingPreserveAllTextParts() async throws {
        let json = #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"Reasoning summary"},{"text":"Hallo "},{"thought":false,"text":"Welt"}]}}]}"#
        for stream in [false, true] {
            let session = AICoachURLProtocolStub.session(status: 200, body: stream ? "data: \(json)\n\n" : json)
            defer { session.invalidateAndCancel() }
            var reply = ""
            if stream {
                try await GeminiClient().stream(
                    key: "test-key", model: "gemini-flash-latest", systemPrompt: "Coach",
                    messages: [(.user, "Hallo")], session: session
                ) { reply += $0 }
            } else {
                reply = try await GeminiClient().send(
                    key: "test-key", model: "gemini-flash-latest", systemPrompt: "Coach",
                    messages: [(.user, "Hallo")], session: session
                )
            }
            XCTAssertEqual(reply, "Reasoning summaryHallo Welt")
        }
    }

    func testModelFetchReadsFollowingPagesAndDeduplicates() async throws {
        let cases: [(AIProvider, [String], String, [String])] = [
            (.anthropic, [
                #"{"data":[{"id":"claude-sonnet-4-6"}],"has_more":true,"last_id":"claude-sonnet-4-6"}"#,
                #"{"data":[{"id":"claude-sonnet-4-6"},{"id":"claude-sonnet-5-5"}],"has_more":false}"#
            ], "after_id", ["claude-sonnet-4-6", "claude-sonnet-5-5"]),
            (.gemini, [
                #"{"models":[{"name":"models/gemini-3-pro"}],"nextPageToken":"next +/="}"#,
                #"{"models":[{"name":"models/gemini-3-pro"},{"name":"models/gemini-3-flash"}]}"#
            ], "pageToken", ["gemini-3-pro", "gemini-3-flash"])
        ]
        for (provider, pages, parameter, expected) in cases {
            let session = AICoachURLProtocolStub.session(status: 500, body: "{}")
            defer { session.invalidateAndCancel() }
            AICoachURLProtocolStub.queue = pages.map { .init(status: 200, body: Data($0.utf8)) }
            let ids = try await provider.client.fetchModels(key: "test-key", session: session)
            XCTAssertEqual(ids, expected)
            XCTAssertEqual(AICoachURLProtocolStub.requestCount, 2)
            let url = try XCTUnwrap(AICoachURLProtocolStub.requestURLs.last)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first?.name, parameter)
            XCTAssertEqual(items?.first?.value, provider == .gemini ? "next +/=" : "claude-sonnet-4-6")
        }
    }

    func testModelFetchStopsOnRepeatedCursor() async throws {
        let page = #"{"models":[{"name":"models/gemini-3-pro"}],"nextPageToken":"same"}"#
        let session = AICoachURLProtocolStub.session(status: 200, body: page)
        defer { session.invalidateAndCancel() }
        let ids = try await GeminiClient().fetchModels(key: "test-key", session: session)
        XCTAssertEqual(ids, ["gemini-3-pro"])
        XCTAssertEqual(AICoachURLProtocolStub.requestCount, 2)
    }
}
