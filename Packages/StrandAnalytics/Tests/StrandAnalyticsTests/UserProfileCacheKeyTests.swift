import XCTest
@testable import StrandAnalytics

/// `UserProfile.cacheKey` must move with every stored field, or the per-cycle load cache serves stale Effort
/// and calories after a profile edit. Twin of Kotlin `RescoreUnchangedInputsTest.everyProfileFieldMovesTheLoadKey`.
final class UserProfileCacheKeyTests: XCTestCase {
    func testEveryFieldMovesTheKey() {
        let base = UserProfile()
        var edits: [UserProfile] = []
        var p = base; p.weightKg = 71; edits.append(p)
        p = base; p.heightCm = 171; edits.append(p)
        p = base; p.age = 31; edits.append(p)
        p = base; p.sex = "male"; edits.append(p)
        p = base; p.stepTicksPerStep = 2; edits.append(p)
        for edit in edits { XCTAssertNotEqual(edit.cacheKey, base.cacheKey) }
        XCTAssertEqual(UserProfile().cacheKey, base.cacheKey)
    }
}
