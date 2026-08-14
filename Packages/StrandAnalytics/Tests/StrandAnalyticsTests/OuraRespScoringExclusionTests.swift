import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The 0x6A `breath` channel is a per-window RATE stored in `respSample` under the ring's own deviceId
/// — the same table that otherwise holds a WHOOP's ~1 Hz raw ADC waveform. It is INSTRUMENTATION: it is
/// stored and it is plotted, and NOTHING scores from it. Two separate refusals, pinned here:
///   * the STAGER must never see it — a peak detector run over a rate series is a shape error, and this
///     one would be wrong even for a value nobody doubts;
///   * the night's `dailyMetric.respRateBpm` must never be derived from it — that is the scored slot
///     (recovery's resp term, `IllnessSignalEngine`), and CLAUDE.md's #194 rule keeps a channel already
///     at its vendor ceiling out of it.
/// Plus the control that keeps the first refusal from being vacuous.
final class OuraRespScoringExclusionTests: XCTestCase {

    private let ring = "oura-2H3B2405003655"
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    // MARK: - fixtures

    /// A still 1 Hz gravity stream — the quiescent sleep floor, enough for the stager to stage.
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    private func sleepingHR(start: Int, durationS: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 600) % 4) }
    }

    private func regularRR(start: Int, durationS: Int) -> [RRInterval] {
        (0..<durationS).map { i -> RRInterval in
            RRInterval(ts: start + i, rrMs: 1_150 + Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0)))
        }
    }

    /// What a real night of 0x6A looks like once persisted: one row per ~296 s window, milli-bpm,
    /// values drifting over the observed 13–16 bpm band.
    private func ringRespRows(start: Int, durationS: Int) -> [RespSample] {
        stride(from: 0, to: durationS, by: 296).map { i -> RespSample in
            let byte = 112 + (i / 296) % 12                       // 14.000 … 15.375 bpm, in 0.125 steps
            return RespSample(ts: start + i, raw: byte * 125, unit: OuraRespScale.unitTag)
        }
    }

    // MARK: - The refusal

    /// The guarantee, stated where the stager can see it: the rows never arrive.
    func testRingRespirationNeverReachesTheStager() {
        let start = 1_754_000_000
        let rows = ringRespRows(start: start, durationS: 8 * 3_600)
        XCTAssertFalse(rows.isEmpty, "fixture sanity: a night of 0x6A is ~100 rows")
        XCTAssertTrue(OuraRespScale.forScoring(rows, deviceId: ring).isEmpty)
    }

    /// …and that refusing them is a NO-OP on today's firmware, which is what makes this change safe to
    /// land: `respRateAndRRV` needs ≥8 samples in its rolling 5-minute window, and a ~296 s cadence
    /// never supplies more than two, so every epoch's RRV is NaN either way. Staging is bit-identical
    /// with the rows and without them.
    ///
    /// This is exactly why the refusal is written by PROVENANCE rather than left to the cadence: the day
    /// a decoder expands one record into per-second rows, or the record period changes, this assertion
    /// stops being free — and `forScoring` is already the place that keeps the outcome the same.
    func testTodaysCadenceWouldNotHaveMovedStagingEitherWay() {
        let start = 1_754_000_000
        let dur = 8 * 3_600
        let grav = stillGravity(start: start, durationS: dur)
        let hr = sleepingHR(start: start, durationS: dur)
        let rr = regularRR(start: start, durationS: dur)
        let rows = ringRespRows(start: start, durationS: dur)

        let without = SleepStager.stageSession(start: start, end: start + dur,
                                               grav: grav, hr: hr, rr: rr, resp: [])
        let with = SleepStager.stageSession(start: start, end: start + dur,
                                            grav: grav, hr: hr, rr: rr, resp: rows)
        XCTAssertFalse(without.isEmpty, "fixture sanity: the night must actually stage")
        XCTAssertEqual(with.map(\.start), without.map(\.start))
        XCTAssertEqual(with.map(\.end), without.map(\.end))
        XCTAssertEqual(with.map(\.stage), without.map(\.stage))
    }

    /// A 1 Hz stream of the SAME numbers does move the stager — the control that proves the test above
    /// is measuring the cadence and not simply a stager that ignores `resp`. If this one ever stops
    /// failing to match, the invariance above has become vacuous.
    func testAOneHertzStreamOfTheSameValuesWouldMoveStaging() {
        let start = 1_754_000_000
        let dur = 8 * 3_600
        let grav = stillGravity(start: start, durationS: dur)
        let hr = sleepingHR(start: start, durationS: dur)
        let rr = regularRR(start: start, durationS: dur)
        // A plausible raw-ADC-shaped waveform at 1 Hz: what the stager's peak detector is built for.
        let dense = (0..<dur).map { i -> RespSample in
            RespSample(ts: start + i, raw: 1_000 + Int(200.0 * sin(2.0 * Double.pi * Double(i) / 4.0)))
        }
        let without = SleepStager.stageSession(start: start, end: start + dur,
                                               grav: grav, hr: hr, rr: rr, resp: [])
        let withDense = SleepStager.stageSession(start: start, end: start + dur,
                                                 grav: grav, hr: hr, rr: rr, resp: dense)
        XCTAssertNotEqual(withDense.map(\.stage), without.map(\.stage),
                          "a dense resp stream must reach the stager — otherwise the invariance test proves nothing")
    }

    // MARK: - The scored slot

    /// The second refusal, at the level that matters to a user: a ring night's `dailyMetric.respRateBpm`
    /// is NOT the ring's measured rate. `analyzeDay` has no door the rows can arrive through — they are
    /// passed here verbatim as `resp`, the worst case in which a caller forgot `forScoring`, and the
    /// day's respiration value is still byte-identical to the day with no rows at all.
    ///
    /// This is the regression guard on the disposition, not on the decode. The decode is good (the
    /// ring computes the value; see `OuraSleepPeriodInfo`); what it is not is a candidate for the slot
    /// that feeds recovery and `IllnessSignalEngine` on the strength of a signal already sitting at the
    /// r = +0.680 ceiling any Oura-derived rate has against WHOOP. If this test ever fails, a vendor
    /// preference has been reintroduced into `analyzeDay` and needs its own evidence and review.
    func testARingNightsScoredRespRateIsNotTheRingsMeasuredRate() {
        let day = "2026-08-16"
        let sleepStart = AnalyticsEngine.dayStartUtcSeconds(day) - 4 * 3_600
        let dur = 8 * 3_600
        let hr = stride(from: sleepStart, to: sleepStart + dur, by: 30)
            .map { HRSample(ts: $0, bpm: 52 + ($0 / 300) % 4) }
        var i = 0
        let rr = stride(from: sleepStart, to: sleepStart + dur, by: 2).map { ts -> RRInterval in
            defer { i += 1 }
            return RRInterval(ts: ts, rrMs: 1_080 + (i % 6) * 8)
        }
        // A ring night stages from the ring's OWN hypnogram (#804 Fix A): no gravity, one provided
        // session — the exact shape the persisted 0x6A rows show up on.
        var t = sleepStart
        let stages = [(20, "wake"), (200, "light"), (60, "deep"), (120, "rem"), (80, "light"),
                      (480 - 20 - 200 - 60 - 120 - 80, "wake")].map { mins, stage -> StageSegment in
            let s = StageSegment(start: t, end: t + mins * 60, stage: stage); t += mins * 60; return s
        }
        let provided = [SleepSession(start: sleepStart, end: sleepStart + dur, efficiency: 0.75,
                                     stages: stages, restingHR: nil, avgHRV: nil)]
        let rows = ringRespRows(start: sleepStart, durationS: dur)
        let ringMedian = HRVAnalyzer.median(rows.map { OuraRespScale.breathsPerMin(raw: $0.raw) })

        let withRows = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: rows,
                                                  profile: profile, providedSleep: provided)
        let without = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr,
                                                 profile: profile, providedSleep: provided)
        XCTAssertNotEqual(withRows.daily.respRateBpm ?? -1, ringMedian, accuracy: 1e-9,
                          "the ring's measured rate must never become the night's scored respRateBpm")
        XCTAssertEqual(withRows.daily, without.daily,
                       "persisting 0x6A must leave every scored field of the day untouched")
    }
}
