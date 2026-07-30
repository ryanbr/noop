import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import sleeppsg

/// The test that keeps this harness honest.
///
/// `V2Recipe` re-states `SleepStagerV2` with its constants exposed, because that is the only way to score a
/// variant of the recipe without rebuilding the app. The failure mode of every such port is silent drift:
/// someone changes a coefficient in `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift`,
/// nobody changes `RecipeConfig.shipped`, and the benchmark keeps printing confident numbers about a recipe
/// that no longer exists.
///
/// So equivalence is asserted here, in CI, on every PR — not verified once by reading the two files side by
/// side. Nothing in this file needs the PhysioNet dataset, a database, or any health data.
final class PortValidationTests: XCTestCase {

    /// Every epoch label, on every night in the corpus, from both paths.
    func testPortReproducesShippedStagerExactly() {
        let r = PortValidation.run()
        XCTAssertEqual(r.nights, 55, "corpus size changed — 48 randomised + 7 degenerate expected")
        XCTAssertEqual(r.randomNights, 48)
        XCTAssertEqual(r.degenerateNights, 7)
        XCTAssertGreaterThan(r.epochs, 10_000, "corpus too small to be evidence of anything")
        if !r.divergences.isEmpty {
            let detail = r.divergences.prefix(5)
                .map { "\($0.night) epoch \($0.epochIndex): shipped=\($0.shipped) port=\($0.port)" }
                .joined(separator: "; ")
            XCTFail("""
                RecipeConfig.shipped no longer reproduces SleepStagerV2 — \
                \(r.epochs - r.matchingEpochs) of \(r.epochs) epoch labels differ. \
                Update RecipeConfig.shipped to match the shipped file. First divergences: \(detail)
                """)
        }
        XCTAssertEqual(r.matchingEpochs, r.epochs)
    }

    /// The corpus must actually reach the branches it claims to. A degenerate case that silently produced
    /// no epochs would make the headline "identical on N epochs" true and meaningless.
    func testDegenerateNightsAreNonTrivial() {
        for n in PortValidation.degenerateNights() where n.name != "degenerate-no-coverage" {
            let segs = SleepStagerV2.stageSession(start: n.start, end: n.end, grav: n.grav,
                                                  hr: n.hr, rr: n.rr, resp: n.resp)
            XCTAssertFalse(segs.isEmpty, "\(n.name) staged to nothing")
            let labels = epochLabels(segs, start: n.start, end: n.end)
            XCTAssertGreaterThan(labels.count, 0, "\(n.name) produced no epochs")
        }
        // The no-coverage night is the one that MUST collapse to the single-segment fallback.
        let empty = PortValidation.degenerateNights().first { $0.name == "degenerate-no-coverage" }!
        let segs = SleepStagerV2.stageSession(start: empty.start, end: empty.end, grav: [],
                                              hr: [], rr: [], resp: [])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.stage, "light")
    }

    /// The corpus is regenerated from a fixed seed, so a divergence is always a code change and never a
    /// reroll. Compared on the GENERATED nights rather than on staged output: staging the corpus is the
    /// expensive part, and determinism is a property of the generator.
    func testCorpusIsDeterministic() {
        func signature(_ ns: [SyntheticNight]) -> [String] {
            ns.map { "\($0.name)|\($0.start)|\($0.end)|\($0.grav.count)|\($0.hr.count)|\($0.rr.count)|"
                + "\($0.hr.first?.bpm ?? -1)|\($0.hr.last?.bpm ?? -1)|\($0.rr.last?.rrMs ?? -1)" }
        }
        XCTAssertEqual(signature(PortValidation.corpus()), signature(PortValidation.corpus()))
        XCTAssertNotEqual(signature(PortValidation.corpus()), signature(PortValidation.corpus(seed: 12345)),
                          "a different seed must produce a different corpus")
    }

    /// Equivalence must hold on ANY corpus, not only the pinned one — otherwise the seed is load-bearing
    /// and the check is a coincidence. A small off-seed corpus makes that point without paying for a
    /// second full run.
    func testPortIsEquivalentOnAnUnpinnedCorpusToo() {
        let r = PortValidation.run(seed: 0xA11CE, randomNights: 6)
        XCTAssertGreaterThan(r.epochs, 500)
        XCTAssertEqual(r.matchingEpochs, r.epochs, "\(r.divergences.first.map(String.init(describing:)) ?? "")")
    }

    /// The randomised nights have to exercise the R-R / RSA path, which the PhysioNet dataset cannot:
    /// sleep-accel carries no beat-to-beat intervals, so without this the respiration term would be
    /// unvalidated in the port everywhere it matters.
    func testCorpusExercisesTheRespirationTerm() {
        let withRR = PortValidation.corpus().filter { !$0.rr.isEmpty }
        XCTAssertGreaterThan(withRR.count, 10, "too few nights carry R-R for the RSA term to be pinned")
        let n = withRR[0]
        let feats = V2Recipe.features(start: n.start, end: n.end,
                                      grav: n.grav.sorted { $0.ts < $1.ts },
                                      hr: n.hr.sorted { $0.ts < $1.ts },
                                      rr: n.rr.sortedByTsStable())
        XCTAssertTrue(feats.contains { $0.respReg != nil },
                      "no epoch produced a respiration-regularity value — the RSA term is never reached")
    }
}
