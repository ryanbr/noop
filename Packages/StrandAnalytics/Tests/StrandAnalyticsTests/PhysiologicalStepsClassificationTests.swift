import XCTest
@testable import StrandAnalytics

final class PhysiologicalStepsClassificationTests: XCTestCase {
    // Expected output comes from the standalone optimized Swift oracle, also pinned on Kotlin.
    func testClassificationOracle() {
        XCTAssertEqual(classificationOracle(), """
        -18000:NNNNNNNNNNNNNNNNNNNNNCNCNCNCNCNCNNNNNNNNNNNNNCCCCCCCCCCCCCCCCCCCCCCCNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN
        0:NNNNNNNNNNNNNNNNNNNNNCNCNCNCNCNCNNNNNNNNNNNNNCCCCCCCCCCCCCCCCCCCCCCCNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN
        46800:NNNNNNNNNNNNNNNNNNNNNCNCNCNCNCNCNNNNNNNNNNNNNCCCCCCCCCCCCCCCCCCCCCCCNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN
        early1945:M:1799100
        early1900:M:1796400
        overnight:M:1807200
        shift:M:1771200
        short:N:-
        floor:M:1796400
        nap:N:-
        explicit:M:1771200
        edited:M:1796400
        bridge:MM:1796400
        """)
    }

    func testConsecutiveEarlyBedtimesCreateDailyBoundaries() {
        var boundaries: [PhysiologicalSteps.CycleBoundary] = []
        for day in 20...22 {
            let onset = day * 86_400 + 19 * 3_600
            let classified = PhysiologicalSteps.classifyForCycle([
                .init(onset: onset, end: onset + 8 * 3_600, id: String(day))
            ], offsetSec: 0, habitualMidsleepSec: nil)
            for block in classified where block.kind == .mainSleep {
                boundaries.append(.init(sleepId: block.id, onset: block.effectiveOnset))
            }
        }
        let windows = PhysiologicalSteps.cycleWindows(boundaries, now: 23 * 86_400 + 19 * 3_600)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.map { $0.endExclusive - $0.onset }, [86_400, 86_400, 86_400])
    }

    private func classificationOracle() -> String {
        typealias Block = PhysiologicalSteps.SleepBlock
        var lines: [String] = []
        let base = 20 * 86_400
        for offset in [-18_000, 0, 46_800] {
            var signature = ""
            for minute in stride(from: 0, to: 1_440, by: 15) {
                let blocks = [
                    Block(onset: base + 3_600 - offset, end: base + 5 * 3_600 - offset, id: "N"),
                    Block(onset: base + minute * 60 - offset,
                          end: base + minute * 60 + 3 * 3_600 - offset, id: "C")
                ]
                let result = PhysiologicalSteps.classifyForCycle(blocks, offsetSec: offset,
                                                                 habitualMidsleepSec: 14 * 3_600)
                signature += result.filter { $0.kind == .mainSleep }.map(\.id).joined()
            }
            lines.append("\(offset):\(signature)")
        }
        let cases: [(String, [Block], Int?)] = [
            ("early1945", [Block(onset: base + 19 * 3_600 + 45 * 60, end: base + 28 * 3_600 + 15 * 60)], nil),
            ("early1900", [Block(onset: base + 19 * 3_600, end: base + 27 * 3_600 + 45 * 60)], nil),
            ("overnight", [Block(onset: base + 22 * 3_600, end: base + 30 * 3_600)], nil),
            ("shift", [Block(onset: base + 12 * 3_600, end: base + 20 * 3_600)], 16 * 3_600),
            ("short", [Block(onset: base + 19 * 3_600, end: base + 22 * 3_600 - 1)], nil),
            ("floor", [Block(onset: base + 19 * 3_600, end: base + 22 * 3_600)], nil),
            ("nap", [Block(onset: base + 19 * 3_600, end: base + 28 * 3_600, kind: .nap)], nil),
            ("explicit", [Block(onset: base + 12 * 3_600, end: base + 13 * 3_600, kind: .mainSleep)], nil),
            ("edited", [Block(onset: base + 20 * 3_600, end: base + 28 * 3_600,
                              editedOnset: base + 19 * 3_600)], nil),
            ("bridge", [Block(onset: base + 19 * 3_600, end: base + 21 * 3_600),
                        Block(onset: base + 21 * 3_600 + 30 * 60, end: base + 23 * 3_600)], nil)
        ]
        for (name, blocks, habitual) in cases {
            let result = PhysiologicalSteps.classifyForCycle(blocks, offsetSec: 0,
                                                             habitualMidsleepSec: habitual)
            let kinds = result.map { $0.kind == .mainSleep ? "M" : "N" }.joined()
            let onset = result.filter { $0.kind == .mainSleep }.map(\.effectiveOnset).min()
            lines.append("\(name):\(kinds):\(onset.map(String.init) ?? "-")")
        }
        return lines.joined(separator: "\n")
    }
}
