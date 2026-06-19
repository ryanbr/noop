import XCTest
@testable import StrandAnalytics

final class CyclePhaseEngineTests: XCTestCase {

    /// Build a synthetic biphasic series of `cycles` repeats of a `cycleLen`-day cycle, oldest→newest.
    /// Follicular nights sit near 0; luteal nights (the back `lutealLen` days of each cycle) are elevated.
    /// tempZ leads, rhrZ ↑ and hrvZ ↓ corroborate (note hrvZ is the RAW HRV z, which the engine negates).
    private func biphasic(cycles: Int, cycleLen: Int = 28, lutealLen: Int = 12,
                          start: String = "2026-01-01") -> [CyclePhaseEngine.Night] {
        var nights: [CyclePhaseEngine.Night] = []
        var idx = 0
        for _ in 0..<cycles {
            for dayInCycle in 0..<cycleLen {
                let day = CyclePhaseEngine.shiftDay(start, by: idx)!
                let luteal = dayInCycle >= (cycleLen - lutealLen)
                let tempZ = luteal ? 1.4 : -0.2
                let rhrZ = luteal ? 1.0 : -0.1
                let hrvZ = luteal ? -1.0 : 0.1     // HRV DROPS in luteal (negative z)
                nights.append(.init(day: day, tempZ: tempZ, rhrZ: rhrZ, hrvZ: hrvZ))
                idx += 1
            }
        }
        return nights
    }

    // MARK: - Biphasic series classifies correctly

    func testLutealNightClassifiesLuteal() {
        // End the series deep inside a luteal run.
        let nights = biphasic(cycles: 3)
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        XCTAssertEqual(r.phase, .luteal)
        XCTAssertNotEqual(r.confidence, .learning)
        XCTAssertFalse(r.shiftMarkers.isEmpty)
    }

    func testFollicularNightClassifiesFollicular() {
        // 3 full cycles (luteal ends each) + a short follicular run, so the LAST night is follicular.
        var nights = biphasic(cycles: 3)
        let startNext = CyclePhaseEngine.shiftDay(nights.last!.day, by: 1)!
        for i in 0..<8 {                          // 8 follicular nights past the last luteal
            let day = CyclePhaseEngine.shiftDay(startNext, by: i)!
            nights.append(.init(day: day, tempZ: -0.2, rhrZ: -0.1, hrvZ: 0.1))
        }
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        XCTAssertEqual(r.phase, .follicular)
    }

    func testDetectsPlausibleCycleLength() {
        let nights = biphasic(cycles: 4, cycleLen: 28)
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        XCTAssertNotNil(r.cycleLengthDays)
        if let len = r.cycleLengthDays {
            XCTAssertTrue((CyclePhaseEngine.minCycleDays...CyclePhaseEngine.maxCycleDays).contains(len))
            XCTAssertEqual(len, 28, accuracy: 2)
        }
        XCTAssertEqual(r.confidence, .solid)
    }

    func testCycleDayEstimateIsARangeNotAPoint() {
        let nights = biphasic(cycles: 3)
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        XCTAssertNotNil(r.cycleDayLow)
        XCTAssertNotNil(r.cycleDayHigh)
        if let lo = r.cycleDayLow, let hi = r.cycleDayHigh {
            XCTAssertLessThan(lo, hi)          // a genuine range, never a single confident day
        }
    }

    // MARK: - Next-period output is a WINDOW, never a single date

    func testNextPeriodIsAWindow() {
        let nights = biphasic(cycles: 4)
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        if let w = r.nextPeriodWindow {
            XCTAssertLessThanOrEqual(w.earliestDay, w.latestDay)
            XCTAssertNotEqual(w.earliestDay, w.latestDay)   // a range, not a hard date
        }
    }

    // MARK: - Flat / irregular → "no clear pattern", never a fabricated phase

    func testFlatSeriesYieldsUnknownNotAPhase() {
        // No elevation anywhere → no onset → unknown, with shiftMarkers empty.
        var nights: [CyclePhaseEngine.Night] = []
        for i in 0..<60 {
            let day = CyclePhaseEngine.shiftDay("2026-01-01", by: i)!
            nights.append(.init(day: day, tempZ: 0.05, rhrZ: 0.0, hrvZ: 0.0))
        }
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        XCTAssertEqual(r.phase, .unknown)
        XCTAssertNil(r.cycleLengthDays)
        XCTAssertNil(r.nextPeriodWindow)
    }

    // MARK: - Gates: < 1.5 cycles, untrusted baseline → learning

    func testInsufficientDataIsLearning() {
        let nights = biphasic(cycles: 1, cycleLen: 28)   // 28 < 42 nights
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true)
        XCTAssertEqual(r.phase, .learning)
        XCTAssertEqual(r.confidence, .learning)
    }

    func testUnusableBaselineIsLearning() {
        let nights = biphasic(cycles: 3)
        let r = CyclePhaseEngine.classify(nights, baselineUsable: false)
        XCTAssertEqual(r.phase, .learning)
    }

    // MARK: - Logged-period mode: agrees, and a mistimed log is flagged

    func testLoggedPeriodMistimedIsFlagged() {
        // Anchor a logged "period start" implausibly far before the latest night (> max cycle).
        let nights = biphasic(cycles: 3)
        let lastDay = nights.last!.day
        let badStart = CyclePhaseEngine.shiftDay(lastDay, by: -50)!
        let r = CyclePhaseEngine.classify(nights, baselineUsable: true, loggedPeriodStarts: [badStart])
        XCTAssertTrue(r.note.lowercased().contains("logged"))
    }

    // MARK: - No fertility / contraception language anywhere (banned strings)

    func testNoFertilityOrContraceptionLanguage() {
        let banned = ["fertile", "fertility", "safe day", "safe days", "ovulation prediction",
                      "contracept", "conceive", "conception", "pregnan"]
        // Exercise multiple phases + the awareness line.
        let series: [[CyclePhaseEngine.Night]] = [
            biphasic(cycles: 3),
            Array(biphasic(cycles: 3).dropLast(6)),
            (0..<60).map { CyclePhaseEngine.Night(day: CyclePhaseEngine.shiftDay("2026-01-01", by: $0)!,
                                                  tempZ: 0.05, rhrZ: 0, hrvZ: 0) },
        ]
        for nights in series {
            let note = CyclePhaseEngine.classify(nights, baselineUsable: true).note.lowercased()
            for b in banned { XCTAssertFalse(note.contains(b), "note contained banned term \(b): \(note)") }
        }
        let awareness = CyclePhaseEngine.awarenessLine.lowercased()
        for b in banned {
            // The awareness line legitimately contains "contraception" via "not contraception"; allow only that.
            if b == "contracept" { continue }
            XCTAssertFalse(awareness.contains(b))
        }
        XCTAssertTrue(CyclePhaseEngine.awarenessLine.contains("not contraception"))
    }

    // MARK: - Fusion math

    func testFusedIndexNegatesHRVAndRenormalises() {
        // Temp-only night: index == tempZ exactly (renormalised over the single present weight).
        XCTAssertEqual(CyclePhaseEngine.fusedIndex(tempZ: 1.5, rhrZ: nil, hrvZ: nil)!, 1.5, accuracy: 1e-9)
        // All three present: (0.6·1 + 0.2·1 + 0.2·(−(−1))) / 1.0 = 1.0
        XCTAssertEqual(CyclePhaseEngine.fusedIndex(tempZ: 1, rhrZ: 1, hrvZ: -1)!, 1.0, accuracy: 1e-9)
        // No signal → nil.
        XCTAssertNil(CyclePhaseEngine.fusedIndex(tempZ: nil, rhrZ: nil, hrvZ: nil))
    }
}
