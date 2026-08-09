import XCTest
@testable import Strand

final class AppLanguageTests: XCTestCase {
    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppLanguage.resolve("unsupported"), .system)
    }

    func testChineseCatalogTagIsSupported() {
        XCTAssertEqual(AppLanguage.resolve("zh"), .chinese)
        XCTAssertEqual(AppLanguage.chinese.autonym, "中文")
    }

    func testExplicitLanguageWritesAndSystemRemovesAppleOverride() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppLanguage.apply(AppLanguage.german.rawValue, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["de"])

        AppLanguage.apply(AppLanguage.system.rawValue, defaults: defaults)
        // Read the suite's OWN persisted domain, not object(forKey:): the latter falls through to
        // NSGlobalDomain, where a CI runner (and most devices) has AppleLanguages set to the system
        // language — so the app-override removal must be checked against this suite alone.
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
    }
}
