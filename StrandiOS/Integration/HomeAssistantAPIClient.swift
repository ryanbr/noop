import Foundation

/// Small, injectable Home Assistant REST client. Kept separate from repository and Keychain access so
/// the exact requests used by iOS can be verified against a deterministic fake API.
struct HomeAssistantAPIClient {
    struct StateUpdate {
        let entityID: String
        let state: String
        let attributes: [String: Any]
    }

    enum APIError: LocalizedError, Equatable {
        case invalidURL
        case invalidEntityID
        case response(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid Home Assistant URL using http or https."
            case .invalidEntityID: return "NOOP generated an invalid Home Assistant entity ID."
            case .response(let code): return "Home Assistant returned HTTP \(code). Check the URL and token."
            case .invalidResponse: return "Home Assistant returned an unexpected response."
            }
        }
    }

    private let baseURL: String
    private let token: String
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(baseURL: String, token: String, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.baseURL = baseURL
        self.token = token
        if let send {
            self.send = send
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: configuration,
                                     delegate: HomeAssistantNoRedirectDelegate(),
                                     delegateQueue: nil)
            self.send = { try await session.data(for: $0) }
        }
    }

    static func isValidBaseURL(_ baseURL: String) -> Bool {
        apiURL(baseURL, path: "api/") != nil
    }

    func testConnection() async throws {
        guard let url = Self.apiURL(baseURL, path: "api/") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await perform(request)
    }

    func setState(_ update: StateUpdate) async throws {
        guard update.entityID.range(of: #"^(sensor|binary_sensor)\.[a-z0-9_]+$"#,
                                    options: .regularExpression) != nil else {
            throw APIError.invalidEntityID
        }
        guard let url = Self.apiURL(baseURL, path: "api/states/\(update.entityID)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "state": update.state,
            "attributes": update.attributes
        ])
        try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws {
        var request = request
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.response(http.statusCode) }
    }

    private static func apiURL(_ baseURL: String, path: String) -> URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([prefix, path].filter { !$0.isEmpty }.joined(separator: "/"))
        return components.url
    }
}

private final class HomeAssistantNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the long-lived token to a different host through a redirect.
        completionHandler(nil)
    }
}
