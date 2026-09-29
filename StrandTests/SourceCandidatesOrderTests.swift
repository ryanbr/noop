import XCTest
@testable import Strand

/// Resolver precedence must match the documented order: imported WHOOP > NOOP-computed > Apple.
/// Before the fix, the strap-preferred candidate list tried the ACTIVE strap's computed sibling
/// before the CANONICAL "my-whoop" import, so after a device re-add (active id != canonical) the
/// new strap's computed estimates shadowed richer imported history. Swift twin of the
/// ryanbr/noop#240 precedence fix.
@MainActor
final class SourceCandidatesOrderTests: XCTestCase {

    func testWeightHistoryUsesManualThenImportedSources() {
        let candidates = Repository.sourceCandidates(forKey: "weight", preferredSource: "apple-health",
                                                      actualWhoopSource: "whoop-4A0B")
        XCTAssertEqual(candidates.map(\.source), ["noop-weight", "apple-health", "health-connect"])
    }

    func testReAddedDeviceCanonicalImportOutranksComputedSiblings() {
        let cs = Repository.sourceCandidates(forKey: "rhr", preferredSource: "my-whoop",
                                             actualWhoopSource: "whoop-4A0B")
        XCTAssertEqual(cs.map(\.source),
                       ["whoop-4A0B", "my-whoop", "whoop-4A0B-noop", "my-whoop-noop", "apple-health"],
                       "canonical import must be tried before ANY computed sibling")
    }

    func testActiveStrapStillWinsFirst() {
        let cs = Repository.sourceCandidates(forKey: "rhr", preferredSource: "my-whoop",
                                             actualWhoopSource: "whoop-4A0B")
        XCTAssertEqual(cs.first?.source, "whoop-4A0B", "live/measured strap rows keep top precedence")
    }

    func testSingleDeviceInstallOrderUnchanged() {
        // active == canonical: `uniqued` collapses the pairs; path stays byte-identical to pre-fix.
        let cs = Repository.sourceCandidates(forKey: "rhr", preferredSource: "my-whoop",
                                             actualWhoopSource: "my-whoop")
        XCTAssertEqual(cs.map(\.source), ["my-whoop", "my-whoop-noop", "apple-health"])
    }

    func testAppleFallbackKeepsCompatibleKeyMapping() {
        let cs = Repository.sourceCandidates(forKey: "rhr", preferredSource: "my-whoop",
                                             actualWhoopSource: "whoop-4A0B")
        XCTAssertEqual(cs.last, MetricSourceCandidate(source: "apple-health", key: "resting_hr"))
    }

    func testNonVitalKeyHasNoAppleFallback() {
        let cs = Repository.sourceCandidates(forKey: "recovery", preferredSource: "my-whoop",
                                             actualWhoopSource: "whoop-4A0B")
        XCTAssertFalse(cs.contains { $0.source == "apple-health" },
                       "no declared Apple equivalent , no cross-source fallback")
    }
}
