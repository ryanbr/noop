import XCTest
@testable import StrandAnalytics

/// The day-owner probe short-circuits: it asks candidates in priority order and stops at the first with
/// data, instead of probing every candidate and then selecting. That is only safe while it agrees with
/// `DayOwnerResolver.resolve` on every input, so this asserts the agreement exhaustively rather than
/// leaving it to the argument in the comment. Mirrored by the Kotlin
/// `DayOwnerResolverEquivalenceTest`.
///
/// The saving is one query per candidate per day. On the 60-day steps-calibration window with two straps
/// that is 120 probes a pass, and the active strap usually answers on the first.
final class DayOwnerResolverEquivalenceTests: XCTestCase {

    /// The short-circuit, over a pre-computed data map so it can be compared exhaustively.
    private func shortCircuit(_ candidates: [(id: String, priority: Int)],
                              _ hasData: [String: Bool]) -> String? {
        candidates.sorted { $0.priority < $1.priority }.first { hasData[$0.id] == true }?.id
    }

    /// Every data pattern over a three-candidate set with distinct priorities. If the two ever disagree
    /// the failure names the case.
    func testTheShortCircuitAgreesWithTheResolverOnEveryCombination() {
        let ids: [(id: String, priority: Int)] = [("active", 0), ("second", 1), ("import", 2)]
        for mask in 0..<8 {
            var hasData: [String: Bool] = [:]
            for (i, c) in ids.enumerated() { hasData[c.id] = (mask >> i) & 1 == 1 }
            let viaResolver = DayOwnerResolver.resolve(
                day: "2026-09-09", lockedOwner: nil,
                candidates: ids.map {
                    DayOwnerResolver.Candidate(deviceId: $0.id, priority: $0.priority,
                                               hasData: hasData[$0.id]!)
                })
            XCTAssertEqual(viaResolver, shortCircuit(ids, hasData), "data mask \(mask)")
        }
    }

    /// Priority, not list order, decides, which is why the probe sorts before it walks.
    func testListOrderDoesNotDecide() {
        let reversed: [(id: String, priority: Int)] = [("import", 2), ("second", 1), ("active", 0)]
        let hasData = ["active": true, "second": true, "import": true]
        XCTAssertEqual(shortCircuit(reversed, hasData), "active")
    }

    /// Nobody with data yields nobody, so the caller falls back to its own id rather than guessing.
    func testNoCandidateWithDataResolvesToNothing() {
        XCTAssertNil(shortCircuit([("active", 0), ("second", 1)],
                                  ["active": false, "second": false]))
    }
}
