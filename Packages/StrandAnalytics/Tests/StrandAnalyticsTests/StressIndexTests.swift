import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class StressIndexTests: XCTestCase {

    // MARK: - Golden value (hand-computed histogram)

    func testGoldenStressIndexHandComputed() {
        // 22 beats (ms) that all survive range + Malik ectopic cleaning. In seconds the cleaned series spans
        // [0.70, 0.86] (MxDMn = 0.16), bins at 0.05 s into 4 bins with counts [3, 5, 13, 1]: the modal bin is
        // index 2 (count 13), centre Mo = 0.70 + 2.5*0.05 = 0.825 s, AMo = 13/22 = 59.0909...%, so
        //   SI = AMo / (2*Mo*MxDMn) = 59.0909.. / (2*0.825*0.16) = 223.829201101928...
        let rr: [Double] = [700, 720, 740, 760, 780, 800, 820, 840, 860, 800, 800,
                            800, 800, 820, 780, 800, 810, 790, 800, 800, 805, 795]
        let comp = StressIndex.components(rawRR: rr)
        XCTAssertNotNil(comp)
        XCTAssertEqual(comp!.mxDMnSec, 0.16, accuracy: 1e-9)
        XCTAssertEqual(comp!.moSec, 0.825, accuracy: 1e-9)
        XCTAssertEqual(comp!.aMoPercent, 59.09090909090909, accuracy: 1e-9)
        XCTAssertEqual(comp!.si, 223.82920110192836, accuracy: 1e-9)
        XCTAssertEqual(StressIndex.stressIndex(rawRR: rr)!, 223.82920110192836, accuracy: 1e-9)
    }

    // MARK: - Monotonicity: a tighter histogram (more rigid rhythm) raises SI

    func testTighterHistogramRaisesSI() {
        // A broad, flexible rhythm (wide spread) vs a rigid one (tightly clustered). SI must be higher for
        // the rigid series: tall narrow peak + small range both push SI up.
        let broad: [Double] = (0..<30).map { 700.0 + Double($0 % 11) * 18.0 }   // spread ~700..880
        let rigid: [Double] = (0..<30).map { i in i % 6 == 0 ? 810.0 : 800.0 }  // nearly all 800
        let siBroad = StressIndex.stressIndex(rawRR: broad)
        let siRigid = StressIndex.stressIndex(rawRR: rigid)
        XCTAssertNotNil(siBroad)
        XCTAssertNotNil(siRigid)
        XCTAssertGreaterThan(siRigid!, siBroad!, "a rigid, tightly-clustered rhythm has a higher Stress Index")
    }

    // MARK: - Honest gates

    func testTooFewBeatsReturnsNil() {
        let rr = Array(repeating: 800.0, count: StressIndex.minBeats - 1)
        XCTAssertNil(StressIndex.stressIndex(rawRR: rr))
    }

    func testDegenerateRangeReturnsNil() {
        // All-equal beats: MxDMn == 0 → SI undefined → nil (never Infinity).
        let rr = Array(repeating: 800.0, count: 30)
        XCTAssertNil(StressIndex.stressIndex(rawRR: rr))
    }

    func testRRIntervalOverloadMatchesRaw() {
        let raw: [Double] = [700, 720, 740, 760, 780, 800, 820, 840, 860, 800, 800,
                             800, 800, 820, 780, 800, 810, 790, 800, 800, 805, 795]
        let rr = raw.enumerated().map { RRInterval(ts: 1000 + $0.offset, rrMs: Int($0.element)) }
        XCTAssertEqual(StressIndex.stressIndex(rr: rr)!, StressIndex.stressIndex(rawRR: raw)!, accuracy: 1e-9)
    }

    func testMostlyRejectedSpotCaptureReturnsNil() {
        // A varied 22-beat capture that alone yields a reading, padded with out-of-range (>2000 ms) beats
        // so >35% are rejected — too noisy to label as stress (#585 spot-honesty gate).
        let valid: [Double] = [700, 720, 740, 760, 780, 800, 820, 840, 860, 800, 800,
                               800, 800, 820, 780, 800, 810, 790, 800, 800, 805, 795]
        XCTAssertNotNil(StressIndex.components(rawRR: valid), "baseline: the valid beats alone yield a reading")
        XCTAssertNil(StressIndex.components(rawRR: valid + Array(repeating: 2500, count: 14)), "39% rejected (14/36) is too noisy")
        XCTAssertNotNil(StressIndex.components(rawRR: valid + Array(repeating: 2500, count: 7)), "24% rejected (7/29) still reads")
    }
}
