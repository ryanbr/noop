import XCTest
@testable import Strand

final class AppLanguageTests: XCTestCase {
    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppLanguage.resolve("unsupported"), .system)
    }

    func testExplicitLanguageWritesAndSystemRemovesAppleOverride() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppLanguage.apply(AppLanguage.german.rawValue, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["de"])

        AppLanguage.apply(AppLanguage.system.rawValue, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "AppleLanguages"))
    }
}
