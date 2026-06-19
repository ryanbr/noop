import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests for the experimental, non-clinical RhythmScreener regularity engine.
///
/// All fixtures are SYNTHETIC and built from a deterministic integer LCG + integer-ms
/// R-R series (no trig, no platform-dependent floats), so the Kotlin twin
/// (`RhythmScreenerTest.kt`) reproduces byte-identical inputs and therefore identical
/// `RhythmRegularity` labels and rounded stats. This is the cross-platform parity gate.
///
/// No real patient data is ever used — synthetic only.
final class RhythmScreenerTests: XCTestCase {

    // MARK: - Deterministic synthetic fixtures (mirrored exactly in Kotlin)

    /// A tiny deterministic LCG (Numerical Recipes constants) over UInt32, so Swift and
    /// Kotlin produce the identical sequence. `next(mod:)` returns an Int in [0, mod).
    struct LCG {
        var state: UInt32
        init(_ seed: UInt32) { state = seed }
        mutating func nextU32() -> UInt32 {
            state = state &* 1664525 &+ 1013904223
            return state
        }
        /// Symmetric integer jitter in [-amp, +amp].
        mutating func jitter(_ amp: Int) -> Int {
            let span = 2 * amp + 1
            return Int(nextU32() % UInt32(span)) - amp
        }
    }

    /// Regular sinus: mean ~1000 ms (60 bpm) with smooth triangle-wave respiratory
    /// modulation (±30 ms) and tiny ±2 ms jitter. Tight, elongated comet → `.steady`.
    static func regularSinus(count: Int = 240) -> [Double] {
        var rng = LCG(1)
        var out: [Double] = []
        out.reserveCapacity(count)
        let period = 8
        for i in 0..<count {
            // Triangle wave in [-1, 1] over `period` beats (smooth, low turning rate).
            let phase = i % period
            let half = period / 2
            let tri = phase < half
                ? Double(phase) / Double(half)                 // 0 → 1
                : Double(period - phase) / Double(half)        // 1 → 0
            let rsa = (tri * 2.0 - 1.0) * 30.0                 // ±30 ms
            let v = 1000.0 + rsa + Double(rng.jitter(2))
            out.append(v.rounded())
        }
        return out
    }

    /// AFib-like: mean ~1000 ms but heavy independent ±180 ms beat-to-beat jitter (high
    /// scatter, low autocorrelation, choppy turning). Diffuse round cloud → `.varied`.
    static func afibLike(count: Int = 240) -> [Double] {
        var rng = LCG(7)
        var out: [Double] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let v = 1000.0 + Double(rng.jitter(180))
            // Keep inside the [300,2000] range so none are range-dropped.
            out.append(min(1900.0, max(400.0, v)).rounded())
        }
        return out
    }

    /// Isolated ectopy: mostly steady sinus with sparse single short-long couplets (a
    /// "skipped beat": one ~650 ms then one ~1350 ms), otherwise tight. → `.occasionalEctopy`.
    static func isolatedEctopy(count: Int = 240) -> [Double] {
        var base = regularSinus(count: count)
        // Insert a couplet every ~40 beats (a handful across the window).
        var i = 20
        while i + 1 < count {
            base[i] = 650
            base[i + 1] = 1350
            i += 40
        }
        return base
    }

    // MARK: - Window-level classification

    func testRegularSinusReadsSteady() {
        let rr = Self.regularSinus()
        let input = RhythmScreener.WindowInput(rrMs: rr, motionStill: true, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .steady)
        XCTAssertEqual(r.nBeats, rr.count)
        XCTAssertNotNil(r.sd1)
        XCTAssertNotNil(r.sd2)
        // A steady comet has SD1 well below SD2 (ratio below the round-out threshold).
        XCTAssertLessThan(r.sd1sd2!, RhythmScreener.tauRatio)
        XCTAssertEqual(r.poincare.count, rr.count - 1)
        XCTAssertEqual(r.confidence, .solid)   // 240 ≥ solidBeats(200)
    }

    func testAfibLikeReadsVaried() {
        let rr = Self.afibLike()
        let input = RhythmScreener.WindowInput(rrMs: rr, motionStill: true, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .varied)
        // Diffuse cloud: ratio at/above the round-out threshold.
        XCTAssertGreaterThanOrEqual(r.sd1sd2!, RhythmScreener.tauRatio)
        XCTAssertGreaterThanOrEqual(r.normRmssd!, RhythmScreener.tauNRmssd)
    }

    func testIsolatedEctopyReadsOccasional() {
        let rr = Self.isolatedEctopy()
        let input = RhythmScreener.WindowInput(rrMs: rr, motionStill: true, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .occasionalEctopy)
        XCTAssertNotEqual(r.label, .varied, "isolated ectopy must NOT read as varied")
        XCTAssertGreaterThan(r.ectopicFraction!, 0)
    }

    // MARK: - Gates

    func testMotionContaminatedIsUnreadable() {
        // Even a varied-looking series is discarded when motion isn't still.
        let rr = Self.afibLike()
        let input = RhythmScreener.WindowInput(rrMs: rr, motionStill: false, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .unreadable, "motion gate must win")
        XCTAssertNil(r.sd1)
        XCTAssertTrue(r.poincare.isEmpty)
    }

    func testSparseWindowIsUnreadableCalibrating() {
        // Below windowMinBeats(60) → unreadable, calibrating confidence.
        let rr = Array(repeating: 1000.0, count: 40)
        let input = RhythmScreener.WindowInput(rrMs: rr, motionStill: true, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .unreadable)
        XCTAssertEqual(r.confidence, .calibrating)
        XCTAssertEqual(r.nBeats, 40)
    }

    func testOutOfRestingBandIsUnreadable() {
        // Dense, clean, still — but a 150 bpm mean HR is outside the resting band.
        let rr = Self.regularSinus()
        let input = RhythmScreener.WindowInput(rrMs: rr, motionStill: true, meanHR: 150)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .unreadable)
    }

    // MARK: - Cross-source agreement (optional PPG IBI channel)

    func testPpgDisagreementSuppressesAgreement() {
        // R-R path varied, PPG IBI path steady → no agreement.
        let rrVaried = Self.afibLike()
        let ppgSteady = Self.regularSinus()
        let input = RhythmScreener.WindowInput(rrMs: rrVaried, ppgIBIms: ppgSteady,
                                               motionStill: true, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .varied)            // R-R path still labels the window
        XCTAssertFalse(r.agreedAcrossSources)        // but the channels disagree
    }

    func testPpgAgreementWhenBothSteady() {
        let rr = Self.regularSinus()
        let ppg = Self.regularSinus()
        let input = RhythmScreener.WindowInput(rrMs: rr, ppgIBIms: ppg,
                                               motionStill: true, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertEqual(r.label, .steady)
        XCTAssertTrue(r.agreedAcrossSources)
    }

    func testNoPpgChannelMeansNoAgreement() {
        let rr = Self.regularSinus()
        let input = RhythmScreener.WindowInput(rrMs: rr, motionStill: true, meanHR: 60)
        let r = RhythmScreener.screenWindow(input)
        XCTAssertFalse(r.agreedAcrossSources, "no PPG channel → agreement is false")
    }

    // MARK: - Property / identity tests

    func testSD1IsRmssdOverRootTwo() {
        let nn = Self.regularSinus()
        let clean = HRVAnalyzer.rangeFilter(nn)
        let rmssd = HRVAnalyzer.rmssdRaw(clean)!
        let stats = RhythmScreener.computeStats(clean)
        XCTAssertEqual(stats.sd1!, rmssd / 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testEctopicFractionReusesRejectEctopic() {
        let nn = Self.isolatedEctopy()
        let clean = HRVAnalyzer.rangeFilter(nn)
        let kept = HRVAnalyzer.rejectEctopic(clean)
        let expected = Double(clean.count - kept.count) / Double(clean.count)
        XCTAssertEqual(RhythmScreener.ectopicFraction(clean), expected, accuracy: 1e-12)
    }

    func testTurningPointRateOfMonotonicIsZero() {
        // A strictly increasing series has no turning points.
        let mono = (0..<10).map { 800.0 + Double($0) }
        XCTAssertEqual(RhythmScreener.turningPointRate(mono)!, 0.0, accuracy: 1e-12)
    }

    func testTurningPointRateOfZigzagIsMax() {
        // A perfect zigzag turns at every interior point → rate 1.0, normalised to 1.5.
        let zig = (0..<11).map { $0 % 2 == 0 ? 800.0 : 900.0 }
        XCTAssertEqual(RhythmScreener.turningPointRate(zig)!, 1.0 / (2.0 / 3.0), accuracy: 1e-12)
    }

    func testRRIntervalConvenienceInitComputesMeanHR() {
        // 1000 ms intervals → 60 bpm computed from the cleaned series.
        let rows = (0..<120).map { RRInterval(ts: $0, rrMs: 1000) }
        let input = RhythmScreener.WindowInput(rr: rows, motionStill: true)
        XCTAssertEqual(input.meanHR, 60.0, accuracy: 1e-9)
        XCTAssertEqual(input.ts.count, 120)
    }

    // MARK: - Night aggregation (descriptive only — no verdict)

    func testNightSummaryCountsAndRecurrence() {
        let steady = RhythmScreener.screenWindow(
            .init(rrMs: Self.regularSinus(), motionStill: true, meanHR: 60))
        let varied = RhythmScreener.screenWindow(
            .init(rrMs: Self.afibLike(), motionStill: true, meanHR: 60))
        let unreadable = RhythmScreener.screenWindow(
            .init(rrMs: Array(repeating: 1000.0, count: 10), motionStill: true, meanHR: 60))

        // 3 varied windows → meets nightMinVariedWindows → recurred, overall varied.
        let many = [varied, varied, varied, steady, unreadable]
        let s = RhythmScreener.summarizeNight(many)
        XCTAssertEqual(s.readableWindows, 4)         // unreadable excluded
        XCTAssertEqual(s.variedWindows, 3)
        XCTAssertEqual(s.steadyWindows, 1)
        XCTAssertTrue(s.variationRecurred)
        XCTAssertEqual(s.overall, .varied)
    }

    func testSingleVariedBlipDoesNotRecur() {
        let steady = RhythmScreener.screenWindow(
            .init(rrMs: Self.regularSinus(), motionStill: true, meanHR: 60))
        let varied = RhythmScreener.screenWindow(
            .init(rrMs: Self.afibLike(), motionStill: true, meanHR: 60))
        // One varied blip among steady windows → NOT recurring (the false-positive guard).
        let s = RhythmScreener.summarizeNight([steady, steady, varied, steady])
        XCTAssertFalse(s.variationRecurred)
        XCTAssertNotEqual(s.overall, .varied)
    }

    func testEmptyNightIsUnreadable() {
        let s = RhythmScreener.summarizeNight([])
        XCTAssertEqual(s.overall, .unreadable)
        XCTAssertEqual(s.readableWindows, 0)
    }

    // MARK: - Non-clinical copy guard

    func testNoLabelRawStringNamesACondition() {
        // The enum raw strings must never name a condition or imply diagnosis.
        let banned = ["afib", "fibrillation", "arrhythmia", "diagnos", "ecg", "ekg",
                      "clinician", "disease", "cardiac", "alert"]
        for label in [RhythmRegularity.steady, .occasionalEctopy, .varied, .unreadable] {
            let raw = label.rawValue.lowercased()
            for term in banned {
                XCTAssertFalse(raw.contains(term),
                               "label raw '\(raw)' must not contain banned term '\(term)'")
            }
        }
    }
}
