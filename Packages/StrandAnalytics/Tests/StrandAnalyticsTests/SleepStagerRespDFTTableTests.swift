import XCTest
@testable import StrandAnalytics

/// `SleepStagerV2.respRegularity` reads its twiddle factors from a per-night table (`RespDFT`) instead of
/// evaluating `cos`/`sin` for every epoch. The stage labels hang on this value, so the table must be a pure
/// speed change: the reference below is the function as it was, and the two must return the SAME Double —
/// not a close one — for every window, including the nil cases, with one table reused across windows the way
/// a night reuses it. Mirrors the Kotlin `SleepStagerRespDftTableTest`.
final class SleepStagerRespDFTTableTests: XCTestCase {

    /// The function before the table, verbatim.
    private func respRegularityBeforeTable(_ beats: [(Double, Double)]) -> Double? {
        if beats.count < 12 { return nil }
        let t0 = beats.first!.0, tN = beats.last!.0
        if tN <= t0 { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9))
        if n < 16 { return nil }
        var y = [Double](repeating: 0, count: n)
        var seg = 0
        for i in 0..<n {
            let t = t0 + 0.25 * Double(i)
            while seg < beats.count - 2 && beats[seg + 1].0 < t { seg += 1 }
            let ta = beats[seg].0, tb = beats[seg + 1].0
            let va = beats[seg].1, vb = beats[seg + 1].1
            y[i] = tb <= ta ? va : va + min(max((t - ta) / (tb - ta), 0), 1) * (vb - va)
        }
        let mean = y.reduce(0, +) / Double(n)
        for i in 0..<n { y[i] -= mean }
        let kLo = Int(ceil(0.15 * 0.25 * Double(n)))
        let kHi = Int(floor(0.40 * 0.25 * Double(n)))
        if kHi < kLo || kLo < 0 { return nil }
        var maxP = 0.0, sumP = 0.0
        for k in kLo...kHi {
            var re = 0.0, im = 0.0
            let w = -2.0 * Double.pi * Double(k) / Double(n)
            for j in 0..<n { let a = w * Double(j); re += y[j] * cos(a); im += y[j] * sin(a) }
            let p = re * re + im * im
            sumP += p
            if p > maxP { maxP = p }
        }
        if sumP == 0 { return nil }
        return maxP / sumP
    }

    /// A beat window as `features()` builds one: whole-second times over `[e-90, e+120)`, several beats a second
    /// or none, values clamped to 300…2000 ms, sorted by time then value.
    private func windowForTest(_ rng: inout SplitMixForDFTTest, span: Int, density: Int) -> [(Double, Double)] {
        var beats: [(Double, Double)] = []
        for s in 0..<span where Int(rng.next() % 100) < density {
            for _ in 0..<(1 + Int(rng.next() % 2)) {
                let breathing = 60.0 * sin(Double(s) * 2 * .pi / Double(3 + rng.next() % 4))
                let v = 650.0 + breathing + Double(rng.next() % 400) - 200
                beats.append((Double(1_790_000_000 + s), min(max(v, 300), 2000)))
            }
        }
        beats.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return beats
    }

    func testTheTableReturnsTheSameValueAsRecomputingEveryFactor() {
        var rng = SplitMixForDFTTest(seed: 0x57A6E)
        var dft: [Int: SleepStagerV2.RespDFT] = [:]
        var compared = 0, nonNil = 0
        for _ in 0..<3_000 {
            // Mostly full-width windows (as mid-night), some short or sparse ones (session edges, dropout).
            let span = rng.next() % 5 == 0 ? 2 + Int(rng.next() % 208) : 205 + Int(rng.next() % 5)
            let beats = windowForTest(&rng, span: span, density: 30 + Int(rng.next() % 71))
            let before = respRegularityBeforeTable(beats)
            let now = SleepStagerV2.respRegularity(beats, dft: &dft)
            XCTAssertEqual(now?.bitPattern, before?.bitPattern, "window of \(beats.count) beats over \(span) s")
            compared += 1
            if before != nil { nonNil += 1 }
        }
        XCTAssertEqual(compared, 3_000)
        XCTAssertGreaterThan(nonNil, 2_000, "most windows must reach the transform, or equality proves little")
        XCTAssertGreaterThan(dft.count, 3, "several grid lengths must share the table")
    }

    /// A fresh table and a warm one give the same answer: what a window returns cannot depend on which
    /// windows came before it in the night.
    func testTheAnswerDoesNotDependOnWhatTheTableHeldBefore() {
        var rng = SplitMixForDFTTest(seed: 0xD1F7)
        var warm: [Int: SleepStagerV2.RespDFT] = [:]
        for _ in 0..<200 {
            let beats = windowForTest(&rng, span: 200 + Int(rng.next() % 10), density: 80)
            var cold: [Int: SleepStagerV2.RespDFT] = [:]
            let fromWarm = SleepStagerV2.respRegularity(beats, dft: &warm)
            let fromCold = SleepStagerV2.respRegularity(beats, dft: &cold)
            XCTAssertEqual(fromWarm?.bitPattern, fromCold?.bitPattern)
        }
    }
}

/// Deterministic, so a failure names a reproducible window.
struct SplitMixForDFTTest {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
