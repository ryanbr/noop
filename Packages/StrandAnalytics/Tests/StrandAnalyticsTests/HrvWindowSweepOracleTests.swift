import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The window sweep buckets exactly as the rescan it replaced.
///
/// `SleepStager.sessionHrvWindows` used to re-filter the whole R-R segment once per five-minute window. The
/// CONTRACT above it already guarantees ts-sorted input, so each window's beats are a contiguous run and one
/// advancing index does the same job: measured at 0.90 ms to 0.03 ms on a 27,879-beat night.
///
/// Cost is not the risk, output is. This function produces the HRV that lands in the daily row, the
/// sleep-session cache, the Health card and the baseline later nights are scored against, so the claim being
/// made is byte-identical behaviour and that is what gets tested. `naiveWindows` re-implements the ORIGINAL
/// bucketing straight from the rule, verified line by line against the pre-change source, then hands each
/// bucket to the SAME cleaning and RMSSD the production path uses.
///
/// Twin of Kotlin `HrvWindowSweepOracleTest`, same spread and same reference. This side matters more: Swift
/// is the reference implementation, and the GRDB link requirements mean this package cannot be run on a
/// plain Linux host, so without this the Swift half would rest on a throwaway check that ran once.
final class HrvWindowSweepOracleTests: XCTestCase {

    /// The bucketing exactly as it was before the sweep.
    private func naiveWindows(start: Int, end: Int, rr: [RRInterval],
                              stages: [StageSegment]) -> [SleepStager.HrvWindow] {
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return [] }
        let windowS = 5 * 60
        var out: [SleepStager.HrvWindow] = []
        var t = start
        repeat {
            let isFinal = t + windowS >= end
            let bucket = seg.filter { $0.ts >= t && (isFinal || $0.ts < t + windowS) }.map { Double($0.rrMs) }
            let cleaned = HRVAnalyzer.cleanRRGapAware(bucket)
            let rmssd: Double? = (cleaned.nn.count >= HRVAnalyzer.minBeats)
                ? HRVAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous) : nil
            let center = t + windowS / 2
            let stage = stages.first { center >= $0.start && center < $0.end }?.stage ?? "?"
            out.append(SleepStager.HrvWindow(startTs: t, stage: stage,
                                             cleanBeats: cleaned.nn.count, rmssd: rmssd))
            t += windowS
        } while t < end
        return out
    }

    /// `HrvWindow` is not `Equatable`, so the comparison is explicit rather than a whole-array assert.
    /// Every field is checked, including `rmssd`: comparing only `cleanBeats` would pass while the number
    /// the wearer actually sees moved.
    private func assertSame(_ a: [SleepStager.HrvWindow], _ b: [SleepStager.HrvWindow],
                            _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, "\(label): window count", file: file, line: line)
        for (k, (x, y)) in zip(a, b).enumerated() {
            XCTAssertEqual(x.startTs, y.startTs, "\(label) w\(k) startTs", file: file, line: line)
            XCTAssertEqual(x.stage, y.stage, "\(label) w\(k) stage", file: file, line: line)
            XCTAssertEqual(x.cleanBeats, y.cleanBeats, "\(label) w\(k) cleanBeats", file: file, line: line)
            switch (x.rmssd, y.rmssd) {
            case (nil, nil): break
            // EXACT, not a tolerance. Both sides run the same HRVAnalyzer over the same bucket, so identical
            // bucketing must give bit-identical doubles. A tolerance here would quietly accept a real
            // difference in the number that reaches the daily row.
            case let (l?, r?): XCTAssertEqual(l, r, "\(label) w\(k) rmssd", file: file, line: line)
            default: XCTFail("\(label) w\(k) rmssd nil-ness differs", file: file, line: line)
            }
        }
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testTheSweepProducesTheSameWindowsAsTheRescanAcrossEveryNightShape() {
        let start = 1_790_000_000
        var cases = 0
        for seed in [1, 2, 3, 5, 8, 13, 21, 34, 55, 89] as [UInt64] {
            var g = SplitMix(seed: seed)
            for durMin in [1, 4, 5, 6, 59, 60, 300, 480] {
                let end = start + durMin * 60
                var shapes: [(String, [RRInterval])] = []

                var dense: [RRInterval] = []
                var ts = start
                while ts <= end { dense.append(RRInterval(ts: ts, rrMs: 700 + Int(g.next() % 400))); ts += 1 }
                shapes.append(("dense", dense))

                var sparse: [RRInterval] = []
                ts = start
                while ts <= end { sparse.append(RRInterval(ts: ts, rrMs: 800)); ts += Int(g.next() % 900) + 1 }
                shapes.append(("sparse", sparse))

                var dup: [RRInterval] = []
                ts = start
                while ts <= end { for _ in 0..<3 { dup.append(RRInterval(ts: ts, rrMs: 750)) }; ts += 7 }
                shapes.append(("duplicate timestamps", dup))

                shapes.append(("all in the final window",
                               (max(start, end - 120)...end).map { RRInterval(ts: $0, rrMs: 900) }))
                shapes.append(("one beat on a boundary", [RRInterval(ts: start + 300, rrMs: 800)]))
                shapes.append(("empty", []))

                for (label, rr) in shapes {
                    cases += 1
                    assertSame(naiveWindows(start: start, end: end, rr: rr, stages: []),
                               SleepStager.sessionHrvWindows(start: start, end: end, rr: rr, stages: []),
                               "\(label), \(durMin)min, seed \(seed)")
                }
            }
        }
        XCTAssertEqual(cases, 480, "the spread must actually have run")
    }
}
