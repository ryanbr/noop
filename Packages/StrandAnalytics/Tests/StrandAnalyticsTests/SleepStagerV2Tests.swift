import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Basic coverage for `SleepStagerV2` (V7 Pillar 3b, reimplemented from @sunny-noop's recipe) — the recipe
/// that stages a normal user's nights, since `PuffinExperiment.experimentalSleepV2Enabled` is default ON
/// (#277 promoted it over V1; #351 extended it to every strap family). These assert the drop-in CONTRACT —
/// same `stageSession` signature + return shape as V1, segments that tile `[start, end]` with canonical
/// stage labels — and a couple of recipe invariants.
/// They are NOT a fidelity claim against any reference: the cross-subject evidence behind the promotion is
/// a 44-subject leave-one-subject-out benchmark, and these unit tests do not re-measure it.
final class SleepStagerV2Tests: XCTestCase {

    // MARK: - fixtures

    /// A still gravity stream (constant orientation) at 1 Hz — the quiescent sleep floor.
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    /// A low, slowly-varying HR stream at 1 Hz (sleep-band HR).
    private func sleepHR(start: Int, durationS: Int, base: Int = 52) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: base + ($0 / 60) % 3) }
    }

    /// A regular R-R stream at ~1 Hz (steady ~1000 ms beats with a small respiratory sinus oscillation).
    private func regularRR(start: Int, durationS: Int) -> [RRInterval] {
        (0..<durationS).map { i -> RRInterval in
            let rsa = Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0))  // ~0.25 Hz breathing
            return RRInterval(ts: start + i, rrMs: 1000 + rsa)
        }
    }

    // MARK: - drop-in contract

    func testStagesTileTheWholeSpanContiguously() {
        let start = 1_700_000_000
        let dur = 90 * 60  // 90 min
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur,
            grav: stillGravity(start: start, durationS: dur),
            hr: sleepHR(start: start, durationS: dur),
            rr: regularRR(start: start, durationS: dur),
            resp: [])

        XCTAssertFalse(segs.isEmpty, "a covered window must produce at least one segment")
        // First segment starts exactly at `start`, last ends exactly at `end`, and segments are contiguous.
        XCTAssertEqual(segs.first?.start, start)
        XCTAssertEqual(segs.last?.end, start + dur)
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].start, segs[i - 1].end, "segments must tile with no gap/overlap")
            XCTAssertGreaterThan(segs[i].end, segs[i].start, "each segment is non-empty")
        }
    }

    func testOnlyCanonicalStageLabels() {
        let start = 1_700_000_000
        let dur = 80 * 60
        let segs = SleepStagerV2.stageSession(
            start: start, end: start + dur,
            grav: stillGravity(start: start, durationS: dur),
            hr: sleepHR(start: start, durationS: dur),
            rr: regularRR(start: start, durationS: dur),
            resp: [])
        // V2 emits only the same 4 labels V1's StageSegment uses — "awake" is renamed to "wake".
        let allowed: Set<String> = ["wake", "light", "deep", "rem"]
        for s in segs {
            XCTAssertTrue(allowed.contains(s.stage), "unexpected stage label \(s.stage)")
        }
    }

    /// Degenerate input (too little gravity to grid) must fall back to a single "light" block spanning the
    /// window — exactly the shape V1's `stageSession` returns in the same case, so callers/encoders are safe.
    func testDegenerateInputFallsBackToSingleLightBlock() {
        let start = 1_700_000_000
        let end = start + 3_600
        let segs = SleepStagerV2.stageSession(
            start: start, end: end,
            grav: [GravitySample(ts: start, x: 0, y: 0, z: 1.0)],  // one sample → no epochs
            hr: [], rr: [], resp: [])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.stage, "light")
        XCTAssertEqual(segs.first?.start, start)
        XCTAssertEqual(segs.first?.end, end)
    }

    func testEmptyWindowReturnsLightFallback() {
        // end <= start → features() is empty → the single-segment fallback.
        let segs = SleepStagerV2.stageSession(start: 100, end: 100, grav: [], hr: [], rr: [], resp: [])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs.first?.stage, "light")
    }

    // MARK: - recipe invariants

    /// The cycle prior concentrates deep early in the night and suppresses REM near sleep onset.
    func testCyclePriorShapesDeepAndRem() {
        let early = SleepStagerV2.cyclePrior(0.05, 3.0)
        let late = SleepStagerV2.cyclePrior(0.90, 400.0)
        XCTAssertGreaterThan(early["deep"]!, late["deep"]!, "deep prior is higher early in the night")
        XCTAssertLessThan(early["rem"]!, late["rem"]!, "REM prior is suppressed early, rising toward morning")
        XCTAssertEqual(early["light"]!, 0.0)
        XCTAssertEqual(early["awake"]!, 0.0)
    }

    // MARK: - #930: the REM-latency guard is measured in MINUTES, not as a fraction of the session

    /// THE point of #930, and the assertion the previous shape could not even express: a 10-hour night and a
    /// 3-hour fragment must receive the SAME REM-latency guard at the same minute after sleep onset.
    ///
    /// Under the replaced `c < 0.12` step the two disagree by construction — 30 min into a 10 h night is
    /// `c = 0.05` (suppressed by the full 3.0) while 30 min into a 3 h fragment is `c = 0.167` (not suppressed
    /// at all), so the identical physiological instant got opposite treatment purely because of how long the
    /// wearer stayed in bed. The guard is isolated from the `1.0 * c` REM ramp (which is CORRECTLY a fraction
    /// of the session and legitimately differs between the two) by subtracting the ramp back out.
    func testRemLatencyGuardIsIdenticalAcrossSessionLengths() {
        let longNight = 10.0 * 60.0   // 600 min
        let fragment = 3.0 * 60.0     // 180 min
        for minutes in stride(from: 0.0, through: 180.0, by: 2.5) {
            let cLong = minutes / longNight, cShort = minutes / fragment
            // Strip the fraction-of-session REM ramp; what remains is the latency guard alone.
            let guardLong = 1.0 * cLong - SleepStagerV2.cyclePrior(cLong, minutes)["rem"]!
            let guardShort = 1.0 * cShort - SleepStagerV2.cyclePrior(cShort, minutes)["rem"]!
            XCTAssertEqual(guardLong, guardShort, accuracy: 1e-12,
                           "guard at \(minutes) min must not depend on session length "
                           + "(10 h gave \(guardLong), 3 h gave \(guardShort))")
            XCTAssertEqual(guardLong, SleepStagerV2.remLatencyGuard(minutes), accuracy: 1e-12)
        }
    }

    /// Shape of the guard: full strength at onset, linear decay, exactly zero at and past `remLatencyMinutes`,
    /// and clamped (never stronger than at onset) for the pre-onset epochs a mis-placed window start produces.
    func testRemLatencyGuardShapeAndClamp() {
        let k = SleepStagerV2.remLatencyPenalty, m0 = SleepStagerV2.remLatencyMinutes
        XCTAssertEqual(SleepStagerV2.remLatencyGuard(0.0), k, accuracy: 1e-12, "full penalty at onset")
        XCTAssertEqual(SleepStagerV2.remLatencyGuard(m0 / 2), k / 2, accuracy: 1e-12, "linear halfway")
        XCTAssertEqual(SleepStagerV2.remLatencyGuard(m0), 0.0, accuracy: 1e-12, "spent at M0")
        XCTAssertEqual(SleepStagerV2.remLatencyGuard(m0 + 500), 0.0, accuracy: 1e-12, "never negative later")
        // #271 can place the window start hours before real onset; the guard must stay bounded there.
        XCTAssertEqual(SleepStagerV2.remLatencyGuard(-240.0), k, accuracy: 1e-12, "clamped pre-onset")
        XCTAssertEqual(SleepStagerV2.remLatencyGuard(.infinity), 0.0, accuracy: 1e-12,
                       "the disabled-guard sentinel pass 1 uses must contribute nothing")
        // Monotone non-increasing across the ramp.
        var prev = Double.infinity
        for m in stride(from: -60.0, through: 120.0, by: 1.0) {
            let g = SleepStagerV2.remLatencyGuard(m)
            XCTAssertLessThanOrEqual(g, prev + 1e-12, "guard must never increase with elapsed time")
            prev = g
        }
    }

    /// The 5-minute sustained-sleep onset rule (10 epochs on the 30 s grid), measured against PSG onset on
    /// sleep-accel at bias −3.8 min / MAE 7.4 min. A shorter sleep run must NOT establish onset.
    func testSustainedSleepOnsetRule() {
        let wake = [String](repeating: "awake", count: 6)
        // 9 epochs of sleep (4.5 min) is one short of the rule and must not count.
        let brief = wake + [String](repeating: "light", count: 9) + wake
        XCTAssertNil(SleepStagerV2.sustainedSleepOnset(brief))
        // 10 epochs (5 min) does, and onset is the FIRST epoch of the run, not the tenth.
        let sustained = wake + [String](repeating: "light", count: 10) + wake
        XCTAssertEqual(SleepStagerV2.sustainedSleepOnset(sustained), 6)
        // A brief run before a sustained one must not be mistaken for onset; the counter resets on wake.
        let both = wake + [String](repeating: "rem", count: 4) + ["awake"]
            + [String](repeating: "deep", count: 12)
        XCTAssertEqual(SleepStagerV2.sustainedSleepOnset(both), 11)
        XCTAssertNil(SleepStagerV2.sustainedSleepOnset([]), "an empty night has no onset")
        XCTAssertNil(SleepStagerV2.sustainedSleepOnset(wake), "an all-wake window has no onset")
    }

    /// End-to-end: the same physiological night truncated to a shorter in-bed window must not shift where the
    /// REM guard stops applying. Both windows start at the same instant and share byte-identical streams, so
    /// any difference in the first ~60 min of the hypnogram would be the session-length dependence #930 is
    /// about. (Epochs after the shorter window's end are not compared — they genuinely see different
    /// per-night z-scores, which is the recipe working as designed.)
    func testGuardRegionDoesNotDependOnHowLongTheWearerStayedInBed() {
        let start = 1_749_517_200
        let longDur = 10 * 60 * 60
        let shortDur = 3 * 60 * 60
        let grav = stillGravity(start: start, durationS: longDur)
        let hr = sleepHR(start: start, durationS: longDur)
        let rr = regularRR(start: start, durationS: longDur)

        func labels(_ dur: Int) -> [String] {
            let segs = SleepStagerV2.stageSession(start: start, end: start + dur,
                                                  grav: grav, hr: hr, rr: rr, resp: [])
            var out: [String] = []
            for t in stride(from: start, to: start + dur, by: 30) {
                out.append(segs.first(where: { $0.start <= t && t < $0.end })?.stage ?? "wake")
            }
            return out
        }
        let long = labels(longDur), short = labels(shortDur)
        // Over the first hour — the whole span the guard touches — neither window may call REM, because the
        // guard reaches the SAME 60 minutes past onset in both. Under `c < 0.12` the 10 h window was guarded
        // for 72 min and the 3 h window for only 21.6 min, so the two could not agree here by construction.
        let guardEpochs = Int(SleepStagerV2.remLatencyMinutes * 60 / 30)
        for i in 0..<guardEpochs {
            XCTAssertEqual(long[i], short[i],
                           "epoch \(i) (minute \(Double(i) * 0.5)) differs: 10 h night says \(long[i]), "
                           + "3 h fragment says \(short[i]) — the guard must not scale with session length")
        }
    }

    /// Viterbi over a single epoch returns the highest-emission stage (uniform start, no transitions).
    func testViterbiSingleEpochPicksMaxEmission() {
        let path = SleepStagerV2.viterbi([["deep": 0.1, "rem": 0.1, "light": 5.0, "awake": 0.1]])
        XCTAssertEqual(path, ["light"])
    }

    // MARK: - 7.0.0: the V2 flag drives the NORMAL detected-night staging path

    /// A regular R-R stream at ~1 Hz (steady ~1000 ms beats with a small respiratory sinus oscillation),
    /// long enough for the V2 recipe to express both early deep and later REM across the night.
    private func regularRRLong(start: Int, durationS: Int) -> [RRInterval] {
        (0..<durationS).map { i -> RRInterval in
            let rsa = Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0))  // ~0.25 Hz breathing
            return RRInterval(ts: start + i, rrMs: 1000 + rsa)
        }
    }

    /// 7.0.0 regression: the "Experimental sleep staging (V2)" toggle must affect a NORMAL detected
    /// night — not only the userEdited self-heal restage. With the flag ON, `detectSleep` stages the
    /// accepted window with V2 (deep + REM present); with the flag OFF it returns the EXACT V1 result, so
    /// the byte-identical default (and the frozen-golden tests) is preserved.
    func testDetectSleepThreadsV2FlagIntoNormalNight() {
        // A 3 h still overnight window (anchored at 01:00 UTC → center ~02:30, clear of the daytime
        // guard band at the default tzOffset=0) with sleep-band HR + a regular R-R stream.
        let start = 1_749_517_200            // 2026-06-10 01:00:00 UTC
        let dur = 3 * 60 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = sleepHR(start: start, durationS: dur)
        let rr = regularRRLong(start: start, durationS: dur)

        // Flag OFF (the default) — V1 path.
        let v1Sessions = SleepStager.detectSleep(hr: hr, rr: rr, gravity: grav)
        XCTAssertEqual(v1Sessions.count, 1, "the still night must be detected")
        let v1 = v1Sessions[0]
        // The detected window's stages MUST equal a direct V1 stageSession over the same span (proof the
        // default path is byte-identical and untouched by the new parameter).
        let v1Direct = SleepStager.stageSession(start: v1.start, end: v1.end,
                                                grav: grav, hr: hr, rr: rr, resp: [])
        XCTAssertEqual(v1.stages.map { [$0.start, $0.end] }, v1Direct.map { [$0.start, $0.end] },
                       "flag OFF must reproduce the exact V1 hypnogram boundaries")
        XCTAssertEqual(v1.stages.map { $0.stage }, v1Direct.map { $0.stage },
                       "flag OFF must reproduce the exact V1 hypnogram labels")

        // Flag ON — the SAME detected window must now be staged by V2.
        let v2Sessions = SleepStager.detectSleep(hr: hr, rr: rr, gravity: grav, useSleepStagerV2: true)
        XCTAssertEqual(v2Sessions.count, 1, "detection is unchanged by the staging flag")
        let v2 = v2Sessions[0]
        // Same accepted window (detection is identical — only staging differs).
        XCTAssertEqual(v2.start, v1.start)
        XCTAssertEqual(v2.end, v1.end)
        // The hypnogram is V2's: it matches a direct V2 stageSession over the accepted span, and (proof
        // the flag actually flipped the engine) it expresses both deep and REM.
        let v2Direct = SleepStagerV2.stageSession(start: v2.start, end: v2.end,
                                                  grav: grav, hr: hr, rr: rr, resp: [])
        XCTAssertEqual(v2.stages.map { $0.stage }, v2Direct.map { $0.stage },
                       "flag ON must produce the V2 hypnogram")
        let v2Stages = Set(v2.stages.map { $0.stage })
        XCTAssertTrue(v2Stages.contains("deep"), "V2 night should express deep")
        XCTAssertTrue(v2Stages.contains("rem"), "V2 night should express REM")
    }

    // MARK: - #277: lock the V2 recipe shape + parity (golden) and the tuned deep-boundary values (directly)

    /// Fixed integer "breathing" wave — no float rounding, so Swift + Kotlin build byte-identical samples
    /// (Kotlin `roundToInt` is half-up, Swift `.rounded()` is half-away-from-zero; integers avoid the gap).
    private func rsaWave(_ ph: Int, _ i: Int) -> Int {
        let amp = [12, 60, 30, 20][ph]
        return [0, amp, 0, -amp][i % 4]
    }

    /// Byte-parity twin of Kotlin `SleepStagerV2Test.frozenGoldenHypnogramPinsTheRecipeShapeAndParity`. A
    /// crafted 4-phase night must reproduce this EXACT hypnogram. This locks the recipe's END-TO-END behaviour
    /// and, asserting the SAME sequence from byte-identical input as the Kotlin twin, proves the full staging
    /// path stays Swift↔Kotlin parity-identical (the whole Viterbi path). It catches GROSS regressions; it is
    /// deliberately NOT the guard for the exact #277 tuned VALUES (on this stark input reverting them doesn't
    /// move a boundary) — those are pinned in `testTunedDeepBoundaryConstantsArePinned`. Integer-only /
    /// fixed-literal input so both languages build identical samples. Regenerate deliberately if retuned.
    func testFrozenGoldenHypnogram() {
        let start = 1_749_517_200
        let phase = 90 * 60
        let dur = phase * 4
        var grav: [GravitySample] = []
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for i in 0..<dur {
            let ts = start + i
            let ph = i / phase
            let restless = ph == 3 && (i % 20) < 6
            grav.append(restless ? GravitySample(ts: ts, x: 0.2, y: 0.15, z: 0.96)
                                  : GravitySample(ts: ts, x: 0, y: 0, z: 1.0))
            let bpm: Int
            switch ph {
            case 0: bpm = 50
            case 1: bpm = 54 + [0, 1, 2, 3, 2, 1][(i / 20) % 6]
            case 2: bpm = 56 + ((i / 60) % 4)
            default: bpm = 66 + ((i / 30) % 6)
            }
            hr.append(HRSample(ts: ts, bpm: bpm))
            rr.append(RRInterval(ts: ts, rrMs: (60_000 / bpm) + rsaWave(ph, i)))
        }
        let segs = SleepStagerV2.stageSession(start: start, end: start + dur, grav: grav, hr: hr, rr: rr, resp: [])
        let golden: [(Int, Int, String)] = [
            (0, 5070, "deep"), (5070, 5310, "light"), (5310, 5550, "rem"),
            (5550, 10740, "light"), (10740, 16290, "rem"), (16290, 21600, "wake")]
        XCTAssertEqual(segs.count, golden.count, "segment count")
        for k in 0..<min(segs.count, golden.count) {
            XCTAssertEqual(segs[k].start, start + golden[k].0, "seg \(k) start")
            XCTAssertEqual(segs[k].end, start + golden[k].1, "seg \(k) end")
            XCTAssertEqual(segs[k].stage, golden[k].2, "seg \(k) stage")
        }
    }

    /// Directly pin the #277 deep-boundary tune — the reliable guard the end-to-end golden can't be (a golden
    /// is only sensitive where the input sits near a decision boundary). Asserts the exact tuned VALUES and
    /// their Swift↔Kotlin equality (twin: `SleepStagerV2Test.tunedDeepBoundaryConstantsArePinned`), so a
    /// fat-finger or a one-sided edit to deepGateThresh / the deep transition row fails immediately. The
    /// row-sum invariant catches a renormalisation typo in the hand-edited matrix. (The inline deep EMISSION
    /// weights aren't named constants, so they stay guarded only at the gross level by the golden.)
    func testTunedDeepBoundaryConstantsArePinned() {
        XCTAssertEqual(SleepStagerV2.deepGateThresh, 0.25)
        XCTAssertEqual(SleepStagerV2.transition["deep"]!,
                       ["deep": 0.86, "rem": 0.007, "light": 0.126, "awake": 0.007])
        for (from, row) in SleepStagerV2.transition {
            XCTAssertEqual(row.values.reduce(0, +), 1.0, accuracy: 1e-9, "transition row '\(from)' must sum to 1.0")
        }
    }

    /// Pin the AWAKE transition row directly, for the same reason the deep row is pinned: the end-to-end
    /// golden is only sensitive where its own input sits near a decision boundary, and it does NOT move when
    /// this row changes — so without this assertion the row is effectively unguarded. Twin:
    /// `SleepStagerV2Test.wakeRowForbidsDirectDescentIntoDeepOrRem`.
    ///
    /// The zeros are the physiological claim: sleep onset descends through N1/N2, so wake never transitions
    /// straight into N3 or REM. They are also why `viterbi` floors the log at 1e-9 — asserted here so the two
    /// can never drift apart and reintroduce ln(0) = -inf.
    func testWakeRowForbidsDirectDescentIntoDeepOrRem() {
        XCTAssertEqual(SleepStagerV2.transition["awake"]!,
                       ["deep": 0.0, "rem": 0.0, "light": 0.10, "awake": 0.90])
        // A zeroed entry must reach the lattice as a large finite penalty, never -inf.
        let lp = log(max(SleepStagerV2.transition["awake"]!["deep"]!, 1e-9))
        XCTAssertTrue(lp.isFinite, "a zeroed transition must not produce a non-finite log-weight")
    }
}
