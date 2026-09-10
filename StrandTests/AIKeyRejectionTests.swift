import XCTest
@testable import Strand

/// The coach shows the chat as soon as ANY key is stored, and a wrong key is still a stored key, so a
/// rejection is the one failure whose repair the wearer cannot reach on their own. The view opens a key
/// field on exactly this classification, which makes it load-bearing rather than cosmetic: widen it and
/// a rate limit starts demanding a new key, narrow it and the trap comes back.
///
/// The same table is asserted in Kotlin `AiKeyRejectionTest`, so the two platforms cannot start
/// disagreeing about which failures are the wearer's to fix. Pure logic, no network.
final class AIKeyRejectionTests: XCTestCase {

    func testIsKeyRejection() {
        let cases: [(Int, Bool)] = [
            // Unauthorized and Forbidden are the two the providers use for a bad or revoked key.
            (401, true),
            (403, true),
            // Success is not a failure at all.
            (200, false),
            // The request's problem, not the key's: a model that does not exist reaches here.
            (400, false),
            // Payment and quota read like an account problem, and a new key does not answer either.
            (402, false),
            (404, false),
            (408, false),
            (429, false),
            // The provider's problem. Retyping a key would send the wearer chasing the wrong thing.
            (500, false),
            (502, false),
            (503, false),
            (599, false),
            // Nothing outside the range gets a free pass either.
            (0, false),
            (-1, false),
        ]
        for (status, want) in cases {
            XCTAssertEqual(AICoachError.isKeyRejection(status), want, "HTTP \(status)")
        }
    }
}
