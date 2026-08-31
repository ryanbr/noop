import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #737: the per-pair sparse-bridge diagnostic must describe what `bridgeSparseSleep` ACTUALLY did, so a
/// "runsBefore == runsAfter" night finally says why. Every test pins the diagnostic against the real
/// bridge rather than asserting it in isolation.
final class SparseBridgeAttemptTests: XCTestCase {

    /// Sleep HR well under any plausible baseline, so `hrSleepBandAcross` is satisfied when we want it.
    private func sleepHR(from: Int, to: Int, bpm: Int = 50) -> [HRSample] {
        stride(from: from, through: to, by: 30).map { HRSample(ts: $0, bpm: bpm) }
    }

    private func sleep(_ start: Int, _ end: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "sleep", start: start, end: end)
    }
    private func active(_ start: Int, _ end: Int) -> SleepStager.Period {
        SleepStager.Period(stage: "active", start: start, end: end)
    }

    /// The invariant that makes the diagnostic trustworthy: the number of pairs it reports as bridged
    /// must equal the reduction in sleep-run count the REAL bridge produces.
    private func assertAgreesWithBridge(_ periods: [SleepStager.Period], hr: [HRSample],
                                        baseline: Double?, file: StaticString = #filePath, line: UInt = #line) {
        let attempts = SleepStager.bridgeSparseSleepTraced(periods, sparse: true, hr: hr, baseline: baseline).1
        let before = periods.filter { $0.stage == "sleep" }.count
        let after = SleepStager.bridgeSparseSleep(periods, sparse: true, hr: hr, baseline: baseline)
            .filter { $0.stage == "sleep" }.count
        XCTAssertEqual(attempts.filter { $0.bridged }.count, before - after,
                       "bridged-pair count must equal the real bridge's run reduction", file: file, line: line)
    }

    func testShortGapInSleepBandBridgesAndIsReported() {
        // Two sleep runs 10 min apart, HR asleep across the gap → bridged.
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000)]
        let hr = sleepHR(from: 0, to: 8_000)
        let a = SleepStager.bridgeSparseSleepTraced(periods, sparse: true, hr: hr, baseline: 70).1
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].gapMin, 10)
        XCTAssertTrue(a[0].bridged)
        XCTAssertEqual(a[0].reason, "bridged")
        assertAgreesWithBridge(periods, hr: hr, baseline: 70)
    }

    func testGapBeyondToleranceReportsGapTooLong() {
        // 120 min apart — over sparseBridgeGapMin (90), so the bridge declines and says so.
        let gap = (SleepStager.sparseBridgeGapMin + 30) * 60
        let periods = [sleep(0, 3_600), sleep(3_600 + gap, 3_600 + gap + 3_600)]
        let hr = sleepHR(from: 0, to: 3_600 + gap + 3_600)
        let a = SleepStager.bridgeSparseSleepTraced(periods, sparse: true, hr: hr, baseline: 70).1
        XCTAssertEqual(a.count, 1)
        XCTAssertFalse(a[0].bridged)
        XCTAssertEqual(a[0].reason, "gapTooLong")
        XCTAssertEqual(a[0].gapMin, SleepStager.sparseBridgeGapMin + 30)
        assertAgreesWithBridge(periods, hr: hr, baseline: 70)
    }

    func testAwakeHrAcrossGapReportsHrOutOfBand() {
        // Gap is short enough, but HR across it is clearly awake → the HR condition is what refused.
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000)]
        let hr = sleepHR(from: 0, to: 8_000, bpm: 110)
        let a = SleepStager.bridgeSparseSleepTraced(periods, sparse: true, hr: hr, baseline: 60).1
        XCTAssertEqual(a.count, 1)
        XCTAssertFalse(a[0].bridged)
        XCTAssertFalse(a[0].hrInSleepBand)
        XCTAssertEqual(a[0].reason, "hrOutOfBand")
        assertAgreesWithBridge(periods, hr: hr, baseline: 60)
    }

    /// REPINNED for #1657. This used to assert the opposite — "an intervening active run is never a
    /// considered pair" — which was true, and was the bug: the shape it describes is the reporter's
    /// bathroom break, and the bridge built to rescue fragmentation was structurally unable to reach it.
    /// A field trace then found the bridge merging nothing on 14 of 14 sparse nights for this reason.
    ///
    /// The test was correct when written and quietly became a guard on the wrong behaviour. Kept pointing
    /// at the same shape so the history reads straight.
    func testAShortActiveRunBetweenFragmentsIsNowConsideredAndBridged() {
        let periods = [sleep(0, 3_000), active(3_000, 3_300), sleep(3_300, 6_000)]
        let hr = sleepHR(from: 0, to: 6_000)
        let (out, a) = SleepStager.bridgeSparseSleepTraced(periods, sparse: true, hr: hr, baseline: 70)
        XCTAssertEqual(a.count, 1, "the pair is now considered")
        XCTAssertEqual(a.first?.reason, "bridged")
        XCTAssertEqual(a.first?.activeMin, 5)
        XCTAssertEqual(out.count, 1, "and the night is one run again")
        XCTAssertEqual(out.first?.end, 6_000)
    }

    func testNoOpWhenNotSparse() {
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000)]
        let hr = sleepHR(from: 0, to: 8_000)
        XCTAssertTrue(SleepStager.bridgeSparseSleepTraced(periods, sparse: false, hr: hr, baseline: 70).1.isEmpty,
                      "the dense 4.0 path is untouched, so there is nothing to explain")
    }

    /// A chain of three bridgeable runs must report two pairs and agree with the real bridge's collapse
    /// to one run — the case where a naive diagnostic (not re-walking the growing run) would drift.
    func testChainOfThreeReportsTwoPairsAndAgrees() {
        let periods = [sleep(0, 3_600), sleep(4_200, 8_000), sleep(8_600, 12_000)]
        let hr = sleepHR(from: 0, to: 12_000)
        let a = SleepStager.bridgeSparseSleepTraced(periods, sparse: true, hr: hr, baseline: 70).1
        XCTAssertEqual(a.count, 2)
        XCTAssertTrue(a.allSatisfy { $0.bridged })
        assertAgreesWithBridge(periods, hr: hr, baseline: 70)
    }
}
