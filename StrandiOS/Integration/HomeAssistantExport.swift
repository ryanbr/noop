#if os(iOS)
import Foundation
import Security

/// User-owned, one-way publisher for the latest NOOP daily metrics and strap battery to Home Assistant.
/// The long-lived Home Assistant token stays in Keychain. Calls happen only after an explicit manual
/// export or while the user's default-off automatic-export switch is enabled.
enum HomeAssistantExport {
    static let enabledKey = "noop.homeAssistantExportEnabled"
    static let endpointKey = "noop.homeAssistantBaseURL"
    private static let keychainService = "ca.zenastra.noop.home-assistant"
    private static let keychainAccount = "long-lived-access-token"

    struct ResultSummary {
        let entitiesUpdated: Int
        let day: String?
    }

    enum ExportError: LocalizedError {
        case invalidURL
        case missingConfiguration
        case missingDailyData
        case response(Int)
        case invalidResponse
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid Home Assistant URL using http or https."
            case .missingConfiguration: return "Save the Home Assistant URL and access token first."
            case .missingDailyData: return "NOOP has no daily metrics to send yet. Sync your WHOOP strap first."
            case .response(let code): return "Home Assistant returned HTTP \(code). Check the URL and token."
            case .invalidResponse: return "Home Assistant returned an unexpected response."
            case .keychain(let status): return "iOS Keychain could not save the access token (\(status))."
            }
        }
    }

    static func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExportError.missingConfiguration }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let value: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, value as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = base
            value.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ExportError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw ExportError.keychain(updateStatus)
        }
    }

    static func hasToken() -> Bool { token() != nil }
    static func isValidBaseURL(_ baseURL: String) -> Bool { HomeAssistantAPIClient.isValidBaseURL(baseURL) }

    static func clearToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ] as CFDictionary)
    }

    static func testConnection(baseURL: String) async throws {
        guard let token = token() else { throw ExportError.missingConfiguration }
        let client = HomeAssistantAPIClient(baseURL: baseURL, token: token)
        do { try await client.testConnection() }
        catch HomeAssistantAPIClient.APIError.invalidURL { throw ExportError.invalidURL }
        catch { throw error }
    }

    @MainActor
    static func exportLatest(repository: Repository, baseURL: String) async throws -> ResultSummary {
        guard let token = token() else { throw ExportError.missingConfiguration }
        guard HomeAssistantAPIClient.isValidBaseURL(baseURL) else { throw ExportError.invalidURL }
        guard let day = repository.days.last else { throw ExportError.missingDailyData }

        let battery = await repository.latestBattery()
        let now = Int(Date().timeIntervalSince1970)
        let recentHR = await repository.hrSamples(deviceIds: repository.importedReadIds,
                                                   from: now - 300, to: now, limit: 100).last
        let entities = HomeAssistantPayload.states(day: day, recentHeartRate: recentHR?.bpm,
                                                   batterySoc: battery?.soc, charging: battery?.charging)
        guard !entities.isEmpty else { throw ExportError.missingDailyData }

        let client = HomeAssistantAPIClient(baseURL: baseURL, token: token)
        for entity in entities {
            do { try await client.setState(entity) }
            catch HomeAssistantAPIClient.APIError.invalidURL { throw ExportError.invalidURL }
            catch { throw error }
        }
        return ResultSummary(entitiesUpdated: entities.count, day: day.day)
    }

    private static func token() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
#endif
