import Foundation
import XCTest
@testable import Strand

private final class AICoachURLProtocolStub: URLProtocol {
    struct Stubbed { let status: Int; let body: Data }
    nonisolated(unsafe) static var response = Stubbed(status: 500, body: Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.response
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
}
