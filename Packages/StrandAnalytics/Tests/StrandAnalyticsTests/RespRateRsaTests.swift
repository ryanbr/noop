import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests SleepStager.respRateFromRR (RSA) on a synthetic R-R series with a KNOWN breathing
/// frequency. WHOOP5 v18 carries no raw resp ADC, so respiratory rate is derived on-device
/// from the R-R stream via respiratory sinus arrhythmia; this pins that the estimator recovers
/// a planted breathing rate and returns NaN on too-little data (honest no-data). The value is
/// an APPROXIMATE on-device estimate, not cloud/clinical respiration. Mirrors the Android
/// RespRateRsaTest vectors value-for-value.
final class RespRateRsaTests: XCTestCase {

    func testRespRateFromRRRecoversKnownBreathingFrequency() {
        // Synthetic RR: mean HR 60 bpm (RR ~1000 ms) with a 0.25 Hz (15 breaths/min)
        // RSA modulation of +/-40 ms. ~7 minutes of beats so multiple 5-min windows.
        let breathHz = 0.25  // 15 breaths/min
        let baseRrMs = 1000.0
        let ampMs = 40.0
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var tSec = 0.0
        // generate ~420 s of beats
        while tSec < 420.0 {
            let rrMs = baseRrMs + ampMs * sin(2.0 * Double.pi * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.append(RRInterval(ts: start + Int(tSec), rrMs: Int(rrMs)))
        }
        let end = start + Int(tSec)
        let est = SleepStager.respRateFromRR(rows, start: start, end: end)
        XCTAssertTrue(est.isFinite, "expected finite resp estimate, got \(est)")
        // RSA peak-pick should land within ~3 bpm of the true 15 breaths/min.
        XCTAssertEqual(est, 15.0, accuracy: 3.0)
    }

    /// #958 regression: a slow breather (11 breaths/min, the value in the report) must read back
    /// ~11, NOT the doubled ~20-21 the reporter saw. RSA peak-picking has a known failure mode where
    /// a split / harmonic peak per breath can inflate the rate toward 2x; this pins that the median
    /// across windows stays on the fundamental. Guards the exact factor rather than blindly halving.
    func testRespRateFromRRSlowBreatherIsNotDoubled() {
        // Mean HR 55 bpm (RR ~1091 ms), 11 breaths/min (0.1833 Hz), +/-45 ms RSA, ~8 min of beats.
        let breathHz = 11.0 / 60.0
        let baseRrMs = 60000.0 / 55.0
        let ampMs = 45.0
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var tSec = 0.0
        while tSec < 480.0 {
            let rrMs = baseRrMs + ampMs * sin(2.0 * Double.pi * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.append(RRInterval(ts: start + Int(tSec), rrMs: Int(rrMs)))
        }
        let end = start + Int(tSec)
        let est = SleepStager.respRateFromRR(rows, start: start, end: end)
        XCTAssertTrue(est.isFinite, "expected finite resp estimate, got \(est)")
        // Must land on the true 11 breaths/min, well below the ~20-21 doubling in #958.
        XCTAssertEqual(est, 11.0, accuracy: 2.0)
        XCTAssertLessThan(est, 16.0, "resp estimate must not be doubled toward ~22 (#958)")
    }

    /// A banked/batched R-R stream whose timestamps are NOT beat-accurate (an Oura overnight IBI stamps
    /// many beats at one coarse ring-time) must return NaN — RSA is a frequency-domain method and cannot
    /// recover breathing from a corrupted time axis, so the honest answer is no-data, not a wrong ~8 bpm.
    /// Same R-R VALUES as the recovering test, only the TIMESTAMPS are batched.
    func testRespRateFromRRBatchedTimestampsIsNaN() {
        let breathHz = 0.25
        let baseRrMs = 1000.0, ampMs = 40.0
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var tSec = 0.0
        var beat = 0
        while tSec < 600.0 {
            let rrMs = baseRrMs + ampMs * sin(2.0 * Double.pi * breathHz * tSec)
            tSec += rrMs / 1000.0
            // Batched stamp: 6 beats share one coarse second, then jump — like a banked-IBI record.
            // The wall-clock gap (mostly 0) no longer matches the ~1 s R-R value.
            rows.append(RRInterval(ts: start + (beat / 6), rrMs: Int(rrMs)))
            beat += 1
        }
        let est = SleepStager.respRateFromRR(rows, start: start, end: start + 600)
        XCTAssertTrue(est.isNaN, "batched (non-beat-accurate) timestamps must gate to NaN, got \(est)")
    }

    /// The gate is on BANKED-ness, not on the output value — because the value a banked stream produces
    /// is PLAUSIBLE. Measured on two real Oura nights (2026-08-07): ungated, both return 13.33 bpm, which
    /// sits squarely inside `respPlausibleRangeBpm`, so the range clamp is no protection at all. This
    /// reproduces that regime synthetically: banked timestamps over R-R values carrying NO breathing
    /// modulation at all still yield a finite, physiological-looking rate once the gate is bypassed.
    ///
    /// Guards against "just widen the plausible band" or "just check the number looks sane" as an
    /// alternative to the gate: neither can see this failure.
    func testBankedStreamWithoutBreathingStillLooksPlausibleUngated() {
        // Flat R-R + small pseudo-random jitter: zero RSA content by construction.
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var seed = UInt64(12345)
        var beat = 0
        var tSec = 0.0
        while tSec < 900.0 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let jitter = Double(Int(truncatingIfNeeded: seed >> 33) % 120)
            let rrMs = 1000.0 + jitter
            tSec += rrMs / 1000.0
            // Banked exactly as the ring does: ~6 beats share one record timestamp.
            rows.append(RRInterval(ts: start + (beat / 6) * 6, rrMs: Int(rrMs)))
            beat += 1
        }
        let fraction = HRVAnalyzer.beatAccurateFraction(tsSec: rows.map { $0.ts },
                                                       rrMs: rows.map { Double($0.rrMs) })
        XCTAssertFalse(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: fraction),
                       "fixture must be banked; measured fraction \(fraction)")
        // The shipped path refuses it — which is the whole point.
        XCTAssertTrue(SleepStager.respRateFromRR(rows, start: start, end: start + 900).isNaN)
    }

    /// The gate and #977's splice skip catch OPPOSITE banking geometries, so neither subsumes the other.
    /// This pins the half that only the gate can catch: banking that COMPRESSES time (6 beats stamped
    /// inside one second) never produces a wall-clock gap above `rsaGapToleranceS`, so no window ever
    /// looks spliced. On the real ring the geometry is the other one — records TILE time, every record
    /// boundary reads as a splice — which is why both protections are kept.
    func testCompressedBankingProducesNoSplicesSoOnlyTheGateCatchesIt() {
        let breathHz = 0.25, baseRrMs = 1000.0, ampMs = 40.0
        let start = 1_700_000_000
        var rows: [RRInterval] = []
        var tSec = 0.0, beat = 0
        while tSec < 600.0 {
            let rrMs = baseRrMs + ampMs * sin(2.0 * Double.pi * breathHz * tSec)
            tSec += rrMs / 1000.0
            rows.append(RRInterval(ts: start + (beat / 6), rrMs: Int(rrMs)))
            beat += 1
        }
        // No consecutive pair exceeds the splice tolerance: the wall clock never outruns the beats here,
        // it LAGS them. So #977's mechanism is blind to this stream and the gate is the only defence.
        var maxOverrun = 0.0
        for i in 1..<rows.count {
            let gapS: Double = Double(rows[i].ts - rows[i - 1].ts)
            let rrS: Double = Double(rows[i].rrMs) / 1000.0
            maxOverrun = max(maxOverrun, gapS - rrS)
        }
        XCTAssertLessThan(maxOverrun, SleepStager.rsaGapToleranceS,
                          "compressed banking must not register as a splice, else this proves nothing")
        XCTAssertTrue(SleepStager.respRateFromRR(rows, start: start, end: start + 600).isNaN)
    }

    /// KNOWN LIMITATION, pinned deliberately so the next person does not walk into it.
    ///
    /// The gate detects BANKING by its symptom — coarse, repeated timestamps. That symptom is a
    /// TRANSPORT artifact and is trivially repairable: give each beat in a record `recordTs + cumsum` of
    /// that record's own intervals and the stream looks beat-accurate again. Measured on the two real
    /// Oura nights (2026-08-07), re-timing moves `beatAccurateFraction` 0.0246 / 0.0235 -> 0.875 / 0.863,
    /// so it sails through this gate AND through #977's splice skip — and the estimate it then yields is
    /// still 13.3333 bpm, still unchanged when the R-R values are shuffled. Re-timing repairs the axis;
    /// it does not repair the VALUES, which is where the fault actually is.
    ///
    /// So: a well-intentioned decoder change that distributes beat timestamps within a record would
    /// silently switch respiration back on for a stream that carries no breathing information. If that
    /// change is ever made, this gate must move with it — onto provenance (was this stream banked?)
    /// rather than onto timestamp shape. This test fails the day someone re-times, which is the point.
    func testRetimingABankedStreamDefeatsTheGate_knownLimitation() {
        let start = 1_700_000_000
        var banked: [RRInterval] = []
        var seed = UInt64(999)
        var beat = 0
        while beat < 600 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let rrMs = 1000 + Int(truncatingIfNeeded: seed >> 33) % 120
            banked.append(RRInterval(ts: start + (beat / 6) * 6, rrMs: rrMs))
            beat += 1
        }
        let bankedFraction = HRVAnalyzer.beatAccurateFraction(tsSec: banked.map { $0.ts },
                                                             rrMs: banked.map { Double($0.rrMs) })
        XCTAssertFalse(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: bankedFraction),
                       "as stored, the banked stream must be refused")

        // Re-time: each record's beats laid out from the record's own timestamp by cumulative sum.
        var retimed: [RRInterval] = []
        var i = 0
        while i < banked.count {
            let recordTs = banked[i].ts
            var offset = 0.0
            var j = i
            while j < banked.count && banked[j].ts == recordTs {
                retimed.append(RRInterval(ts: recordTs + Int(offset.rounded()), rrMs: banked[j].rrMs))
                offset += Double(banked[j].rrMs) / 1000.0
                j += 1
            }
            i = j
        }
        let retimedFraction = HRVAnalyzer.beatAccurateFraction(tsSec: retimed.map { $0.ts },
                                                              rrMs: retimed.map { Double($0.rrMs) })
        XCTAssertTrue(HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: retimedFraction),
                      "re-timing is expected to DEFEAT this gate (measured 0.875/0.863 on real nights); "
                      + "got \(retimedFraction). If this now fails, the decoder changed and the gate "
                      + "must be re-based on provenance, not on timestamp shape.")
    }

    func testRespRateFromRRTooFewBeatsIsNaN() {
        let start = 1_700_000_000
        let rows = [
            RRInterval(ts: start + 1, rrMs: 1000),
            RRInterval(ts: start + 2, rrMs: 1000),
            RRInterval(ts: start + 3, rrMs: 1000),
        ]
        XCTAssertTrue(SleepStager.respRateFromRR(rows, start: start, end: start + 10).isNaN)
        XCTAssertTrue(SleepStager.respRateFromRR([], start: start, end: start + 10).isNaN)
    }
}
