import XCTest
@testable import Strand

final class ProfileGreetingTests: XCTestCase {
    func testBlankPreferredNameOptsOut() {
        XCTAssertNil(ProfileStore.normalizedPreferredName(""))
        XCTAssertNil(ProfileStore.normalizedPreferredName("  \n "))
    }

    func testPreferredNameTrimsEdgesWithoutRewritingTheName() {
        XCTAssertEqual(ProfileStore.normalizedPreferredName("  Mary Jane  "), "Mary Jane")
    }

    func testPreferredNameIsBoundedForTheTodayHeader() {
        let longName = String(repeating: "A", count: ProfileStore.preferredNameMaxLength + 10)
        XCTAssertEqual(
            ProfileStore.normalizedPreferredName(longName)?.count,
            ProfileStore.preferredNameMaxLength
        )
    }
}
