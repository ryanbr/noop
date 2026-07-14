import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class DaytimeStressTests: XCTestCase {

    /// Fill one local hour-of-day with `n` 1 Hz HR samples at `bpm` (UTC, tz offset 0).
    private func hourHR(_ hour: Int, bpm: Int, n: Int = DaytimeStress.minHourHRSamples) -> [HRSample] {
        let base = hour * 3_600
        return (0..<n).map { HRSample(ts: base + $0, bpm: bpm) }
    }

    func testEmptyWhenNoHR() {
        XCTAssertEqual(DaytimeStress.analyze(hr: [], rr: []), .empty)
    }

    func testHourBelowGateIsUnscored() {
        // One waking hour with too few HR samples → present but unscored (honest gap).
        let hr = hourHR(9, bpm: 70, n: DaytimeStress.minHourHRSamples - 1)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.scored.isEmpty, "an under-gate hour must not be scored")
    }

    func testScoresMapOntoZeroToThree() {
        // Three calm hours + one tense hour (high HR). All scored values stay within 0…3.
        var hr: [HRSample] = []
        hr += hourHR(8, bpm: 62)
        hr += hourHR(9, bpm: 60)
        hr += hourHR(10, bpm: 61)
        hr += hourHR(11, bpm: 95)   // the spike
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.scored.isEmpty)
        for p in r.scored {
            let lvl = p.level!
            XCTAssertGreaterThanOrEqual(lvl, 0)
            XCTAssertLessThanOrEqual(lvl, 3)
        }
        // The high-HR hour must be the day's peak and read above the calm hours.
        XCTAssertEqual(r.peak?.hour, 11)
        let calm = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        XCTAssertGreaterThan(tense, calm)
    }

    func testNonWakingHoursAreExcluded() {
        // A 3 am hour (outside 06:00–22:00) is never placed on the waking timeline.
        let hr = hourHR(3, bpm: 80) + hourHR(9, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.hours.contains { $0.hour == 3 })
        XCTAssertTrue(r.hours.contains { $0.hour == 9 })
    }

    func testSustainedHighFlagsAfterThreeConsecutiveHighHours() {
        // A calm morning, then three increasingly tense afternoon hours that finish HIGH.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }   // calm baseline hours
        hr += hourHR(13, bpm: 120)
        hr += hourHR(14, bpm: 125)
        hr += hourHR(15, bpm: 130)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.sustainedHigh, "three trailing HIGH hours should flag sustained stress")
        XCTAssertGreaterThanOrEqual(r.sustainedRun, DaytimeStress.sustainedHours)
    }

    func testFlatDayDoesNotFlagSustained() {
        // Every hour at the same HR → no hour is meaningfully elevated, no flag.
        var hr: [HRSample] = []
        for h in 8...16 { hr += hourHR(h, bpm: 64) }
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.sustainedHigh)
        // A flat day sits around the baseline (≈1.5), not pinned high.
        if let mean = r.dayMean { XCTAssertLessThan(mean, DaytimeStress.highBandFloor) }
    }

    func testSleepHoursInTheWindowDoNotShiftTheWakingTimeline() {
        // Regression: the calm reference is built from the WAKING hours that are actually
        // scored, not the whole 24 h. The analysis window always starts at local midnight, so
        // the current day routinely carries several hours of sleep — the calmest, lowest-HR
        // stretch of the day. If those night hours leak into the reference they drag the "calm"
        // anchor far below every waking hour, inflating an ordinary calm day into sustained
        // high stress (tripping the passive Breathe nudge). So adding calm sleep hours to the
        // input must NOT change the waking timeline.
        let waking: [HRSample] = zip(6...17, [62, 64, 63, 65, 64, 63, 62, 64, 66, 63, 64, 65])
            .flatMap { hourHR($0.0, bpm: $0.1) }
        let sleep: [HRSample] = zip(0...5, [50, 51, 52, 51, 50, 53])
            .flatMap { hourHR($0.0, bpm: $0.1) }

        let wakingOnly = DaytimeStress.analyze(hr: waking, rr: [])
        let withSleep = DaytimeStress.analyze(hr: sleep + waking, rr: [])

        XCTAssertEqual(withSleep.sustainedHigh, wakingOnly.sustainedHigh,
            "sleep hours sharing the window must not change the sustained-high verdict")
        for h in 6...17 {
            guard let withLvl = withSleep.scored.first(where: { $0.hour == h })?.level,
                  let withoutLvl = wakingOnly.scored.first(where: { $0.hour == h })?.level else {
                XCTFail("waking hour \(h) should be scored in both runs"); continue
            }
            XCTAssertEqual(withLvl, withoutLvl, accuracy: 1e-9,
                "the night's sleep hours leaked into the daytime reference and shifted waking hour \(h)")
        }
        // The plain sanity check the bug violated: an ordinary calm day is not "sustained high".
        XCTAssertFalse(withSleep.sustainedHigh,
            "a calm desk day must not read as sustained high stress")
    }

    func testTimezoneOffsetShiftsWakingWindow() {
        // ts at UTC hour 4 with a +3 h offset lands at local hour 7 → inside waking hours.
        let hr = hourHR(4, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 3 * 3_600)
        XCTAssertTrue(r.hours.contains { $0.hour == 7 })
    }

    func testRMSSDLowersStressDirectionMatchesDailyScore() {
        // Same HR across hours; the hour with the LOWEST HRV (RMSSD) should read more
        // stressed — the same directionality as the daily score (HRV down = stress).
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [8, 9, 10, 11] { hr += hourHR(h, bpm: 65) }
        // High-variability (relaxed) hours vs one low-variability (tense) hour.
        rr += hourRRVariable(8, rrMs: 900, jitter: 40)
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)
        rr += hourRRVariable(10, rrMs: 900, jitter: 40)
        rr += hourRRVariable(11, rrMs: 900, jitter: 2)   // suppressed HRV
        let r = DaytimeStress.analyze(hr: hr, rr: rr)
        let relaxed = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        XCTAssertGreaterThan(tense, relaxed)
    }

    /// R-R for one hour with a controllable beat-to-beat jitter (drives RMSSD).
    private func hourRRVariable(_ hour: Int, rrMs: Int, jitter: Int, n: Int = 60) -> [RRInterval] {
        let base = hour * 3_600
        return (0..<n).map { RRInterval(ts: base + $0 * 50, rrMs: rrMs + ($0 % 2 == 0 ? jitter : -jitter)) }
    }

    // MARK: - Motion gate

    /// Gravity for one local hour. `activeFraction` of the records step far enough between
    /// consecutive samples to clear `WorkoutDetector.motionThreshold` (0.20 g L2); the rest hold
    /// still. The alternating ±step keeps every active record above the floor rather than only the
    /// first, so the produced active fraction matches `activeFraction` closely.
    private func hourGravity(_ hour: Int, activeFraction: Double, n: Int = 120) -> [GravitySample] {
        let base = hour * 3_600
        let activeCount = Int((Double(n) * activeFraction).rounded())
        return (0..<n).map { i in
            // 0.5 g of step per axis-pair is comfortably above the 0.20 walk floor when it alternates.
            let x = i < activeCount ? (i % 2 == 0 ? 0.5 : 0.0) : 0.0
            return GravitySample(ts: base + i * 30, x: x, y: 0, z: 1)
        }
    }

    func testEmptyGravityIsByteIdenticalToNoGravity() {
        // The degradation contract: with no motion channel NOTHING is masked and the read is
        // unchanged from the pre-gate behaviour.
        var hr: [HRSample] = []
        for h in [8, 9, 10, 11] { hr += hourHR(h, bpm: 60 + (h - 8) * 5) }
        let withoutGravity = DaytimeStress.analyze(hr: hr, rr: [])
        let withEmptyGravity = DaytimeStress.analyze(hr: hr, rr: [], gravity: [])
        XCTAssertEqual(withoutGravity, withEmptyGravity)
        XCTAssertEqual(withEmptyGravity.activityMaskedHours, 0)
        XCTAssertFalse(withEmptyGravity.hours.contains { $0.maskedForActivity })
    }

    func testAmbulatoryHourIsMaskedNotScored() {
        // Four hours; the 11:00 hour has an elevated HR AND is ambulatory. Without motion it scores
        // as the day's most "stressed" hour — the exact false positive the gate exists to remove.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 60) }
        hr += hourHR(11, bpm: 110)   // the walk

        let unGated = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertNotNil(unGated.scored.first { $0.hour == 11 }?.level,
            "precondition: without gravity the ambulatory hour is scored as stress")

        var gravity: [GravitySample] = []
        for h in [8, 9, 10] { gravity += hourGravity(h, activeFraction: 0.0) }
        gravity += hourGravity(11, activeFraction: 1.0)

        let gated = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        let masked = gated.hours.first { $0.hour == 11 }
        XCTAssertNotNil(masked)
        XCTAssertNil(masked?.level, "an ambulatory hour must not be scored")
        XCTAssertTrue(masked?.maskedForActivity ?? false,
            "the hour must report WHY it is unscored — masked, not noData")
        XCTAssertEqual(masked?.meanHR, 110, "the reading itself is still reported, only the score is withheld")
        XCTAssertEqual(gated.activityMaskedHours, 1)
    }

    func testStillHourIsStillScoredWhenGravityPresent() {
        // The gate must not swallow a genuinely sedentary day just because gravity was supplied.
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for h in [8, 9, 10, 11] {
            hr += hourHR(h, bpm: h == 11 ? 85 : 60)
            gravity += hourGravity(h, activeFraction: 0.0)
        }
        let r = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        XCTAssertEqual(r.activityMaskedHours, 0, "a still day must have nothing masked")
        XCTAssertNotNil(r.scored.first { $0.hour == 11 }?.level,
            "a stationary elevated-HR hour is exactly what the timeline SHOULD score")
    }

    func testLightMovementBelowFractionDoesNotMask() {
        // A stray reach or one trip to the kitchen (under activityMaskFraction) is not exertion.
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for h in [8, 9, 10, 11] {
            hr += hourHR(h, bpm: 60)
            gravity += hourGravity(h, activeFraction: h == 10 ? 0.10 : 0.0)
        }
        let r = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        XCTAssertEqual(r.activityMaskedHours, 0,
            "10 % ambulatory is below activityMaskFraction (0.30) and must not mask the hour")
    }

    func testPostActivityShadowMasksOnlyWhileHRStaysElevated() {
        // The hour AFTER exertion is masked while its HR is still above the calm reference by
        // postActivityShadowBPM, and scored normally once it has recovered.
        func day(followingBPM: Int) -> DaytimeStress.Result {
            var hr: [HRSample] = []
            var gravity: [GravitySample] = []
            for h in [8, 9, 10, 13] {                       // still hours, set the ~60 bpm calm anchor
                hr += hourHR(h, bpm: 60)
                gravity += hourGravity(h, activeFraction: 0.0)
            }
            hr += hourHR(11, bpm: 120)                      // 11:00 — the workout hour
            gravity += hourGravity(11, activeFraction: 1.0)
            hr += hourHR(12, bpm: followingBPM)             // 12:00 — the shadow hour, now still
            gravity += hourGravity(12, activeFraction: 0.0)
            return DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        }
        // Still elevated well above the ~60 bpm calm reference → masked.
        let hot = day(followingBPM: 100)
        XCTAssertTrue(hot.hours.first { $0.hour == 12 }?.maskedForActivity ?? false,
            "an unrecovered post-exercise hour must be masked, not read as stress")
        // Back at the calm reference → the shadow self-limits and the hour is scored.
        let recovered = day(followingBPM: 60)
        XCTAssertFalse(recovered.hours.first { $0.hour == 12 }?.maskedForActivity ?? true,
            "once HR is back at the calm reference the shadow must not keep masking")
    }

    func testMaskedHoursAreExcludedFromTheCalmReference() {
        // An exertion hour must not drag the day's calm anchor upward, which would depress every
        // other hour's score. Same still hours, with and without an added ambulatory hour.
        var stillHR: [HRSample] = []
        var stillGravity: [GravitySample] = []
        for h in [8, 9, 10, 13] {
            stillHR += hourHR(h, bpm: h == 13 ? 80 : 60)
            stillGravity += hourGravity(h, activeFraction: 0.0)
        }
        let withoutWorkout = DaytimeStress.analyze(hr: stillHR, rr: [], gravity: stillGravity)

        var withHR = stillHR, withGravity = stillGravity
        withHR += hourHR(11, bpm: 130)
        withGravity += hourGravity(11, activeFraction: 1.0)
        let withWorkout = DaytimeStress.analyze(hr: withHR, rr: [], gravity: withGravity)

        let before = withoutWorkout.scored.first { $0.hour == 13 }?.level
        let after = withWorkout.scored.first { $0.hour == 13 }?.level
        XCTAssertNotNil(before); XCTAssertNotNil(after)
        XCTAssertEqual(before!, after!, accuracy: 1e-9,
            "a masked exertion hour leaked into the calm reference and moved an unrelated hour's score")
    }

    func testDifferentGravityDoesNotReuseAMemoizedResult() {
        // The analyze memo is keyed on the streams; two identical hr/rr days with DIFFERENT motion
        // must not share a cached Result.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 60) }
        hr += hourHR(11, bpm: 110)

        var still: [GravitySample] = []
        var moving: [GravitySample] = []
        for h in [8, 9, 10] {
            still += hourGravity(h, activeFraction: 0.0)
            moving += hourGravity(h, activeFraction: 0.0)
        }
        still += hourGravity(11, activeFraction: 0.0)
        moving += hourGravity(11, activeFraction: 1.0)

        let a = DaytimeStress.analyze(hr: hr, rr: [], gravity: still)
        let b = DaytimeStress.analyze(hr: hr, rr: [], gravity: moving)
        XCTAssertEqual(a.activityMaskedHours, 0)
        XCTAssertEqual(b.activityMaskedHours, 1, "the memo key ignored gravity and returned a stale Result")
    }

    // MARK: - Additivity: the `mode` parameter is opt-in, day-relative stays the default

    func testDayRelativeDefaultIsByteIdenticalToExplicitMode() {
        // The additive `mode` parameter defaults to `.dayRelative`. Confirms the implicit call
        // (every pre-existing call site, unmodified) and the explicit `.dayRelative` case
        // produce a BYTE-IDENTICAL `Result` — every field, not just the pre-existing ones —
        // proving the new mode is purely additive and never a silent behaviour change.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }
        hr += hourHR(13, bpm: 120)
        hr += hourHR(14, bpm: 125)
        hr += hourHR(15, bpm: 130)
        var rr: [RRInterval] = []
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)
        rr += hourRRVariable(14, rrMs: 900, jitter: 5)

        let implicit = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 3_600)
        let explicit = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 3_600, mode: .dayRelative)
        XCTAssertEqual(implicit, explicit,
            "omitting `mode` must be byte-identical to passing `.dayRelative` explicitly")
    }

    func testHighStressMinutesCountsAllHighBandHoursNotJustTheTrailingRun() {
        // An isolated morning spike, then a calm run ending the day: sustainedHigh only cares
        // about the TRAILING run (and must be false here, since the day ends calm), but
        // highStressMinutes is a day-wide tally and must still count the earlier spike hour —
        // proving it is computed independently, not derived from sustainedRun.
        var hr: [HRSample] = []
        hr += hourHR(7, bpm: 130)   // isolated high spike
        hr += hourHR(8, bpm: 60)
        hr += hourHR(9, bpm: 60)
        hr += hourHR(10, bpm: 60)
        hr += hourHR(11, bpm: 60)   // trailing hour is calm -> NOT sustained
        let r = DaytimeStress.analyze(hr: hr, rr: [])

        XCTAssertFalse(r.sustainedHigh, "the trailing hour is calm, so sustained-high must not fire")
        let expectedHighHours = r.scored.filter { $0.level! >= DaytimeStress.highBandFloor }.count
        XCTAssertGreaterThan(expectedHighHours, 0, "the isolated morning spike should read as high band")
        XCTAssertEqual(r.highStressMinutes, expectedHighHours * (DaytimeStress.bucketSeconds / 60))
        XCTAssertFalse(r.hrOnlyFallback, "day-relative mode never sets the baseline-relative fallback flag")
    }

    // MARK: - Baseline-relative mode (Oura-style, vs a PERSONAL rolling baseline)
    //
    // Fixtures below use a 65 bpm personal HR baseline (matching the ~65 bpm pooled
    // 10th-percentile figure from the validated 26-day Oura-reference correlation — see
    // `DaytimeStress.baselineRelativeHighMarginBPM`) and elevations measured from it in terms of
    // that validated ~15 bpm margin, so the expected band crossings are exact, not approximate.

    func testMarginToSigmaLandsExactlyOnBand() {
        // The validated 15 bpm margin over baseline must land EXACTLY on highBandFloor (2.0) on
        // the shared squash curve — the core identity `.baselineRelative` scoring relies on.
        let sd = DaytimeStress.marginToSigma(marginBPM: DaytimeStress.baselineRelativeHighMarginBPM,
                                             atBand: DaytimeStress.highBandFloor)
        XCTAssertEqual(DaytimeStress.squash(DaytimeStress.baselineRelativeHighMarginBPM / sd),
                      DaytimeStress.highBandFloor, accuracy: 1e-9)
    }

    func testBaselineRelativeModeRecoversMultipleInjectedElevations() {
        // Personal daytime-HR baseline: 20 constant "days" at 65 bpm converges the EWMA center
        // to exactly 65 (spread is folded but NOT used for the HR high-band threshold — see
        // baselineRelativeHighMarginBPM).
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        XCTAssertEqual(hrBaseline.baseline, 65.0, accuracy: 1e-6)

        // FOUR distinct injected HR elevations across the SAME day's waking hours — the repo's
        // derived-signal rule (CLAUDE.md "validate against the artifact, not one match") requires
        // recovering MULTIPLE injected values, not a single high-vs-low pair. 65 (at baseline),
        // 72 (+7, mild), 80 (+15, exactly the validated margin), 95 (+30, well past it).
        let levels: [(hour: Int, bpm: Int)] = [(8, 65), (10, 72), (13, 80), (16, 95)]
        var hr: [HRSample] = []
        for (h, bpm) in levels { hr += hourHR(h, bpm: bpm) }

        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))
        let scores = levels.map { pair in r.scored.first { $0.hour == pair.hour }!.level! }

        // Strictly increasing with the injected elevation — all four levels recovered, in order.
        for i in 1..<scores.count {
            XCTAssertGreaterThan(scores[i], scores[i - 1],
                "hour \(levels[i].hour) (\(levels[i].bpm) bpm) should score higher than hour \(levels[i - 1].hour) (\(levels[i - 1].bpm) bpm)")
        }
        // The at-baseline hour reads at the 1.5 midpoint; +15 bpm (the validated margin) lands
        // exactly on highBandFloor; the most-elevated hour clears well past it.
        XCTAssertEqual(scores[0], 1.5, accuracy: 0.05)
        XCTAssertEqual(scores[2], DaytimeStress.highBandFloor, accuracy: 0.01,
            "the validated +15 bpm margin should land exactly on highBandFloor")
        XCTAssertGreaterThan(scores.last!, DaytimeStress.highBandFloor)
        XCTAssertTrue(r.hrOnlyFallback, "rmssd: nil must flag the HR-only fallback")
    }

    func testBaselineRelativeCalmDayAtPersonalBaselineReadsLowNotHigh() {
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in [8, 10, 13, 16] { hr += hourHR(h, bpm: 65) }   // every hour sits exactly at baseline
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        for p in r.scored {
            XCTAssertEqual(p.level!, 1.5, accuracy: 0.05,
                "a day flat at the personal baseline should read ~1.5, not elevated")
        }
        XCTAssertEqual(r.highStressMinutes, 0)
        XCTAssertFalse(r.sustainedHigh)
    }

    func testBaselineRelativeElevatedDayProducesHighStressMinutes() {
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in 8...16 { hr += hourHR(h, bpm: 95) }   // +30 bpm — twice the validated high-band margin
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        XCTAssertGreaterThan(r.highStressMinutes, 0)
        XCTAssertEqual(r.highStressMinutes,
                      r.scored.filter { $0.level! >= DaytimeStress.highBandFloor }.count * (DaytimeStress.bucketSeconds / 60))
        for p in r.scored { XCTAssertGreaterThanOrEqual(p.level!, DaytimeStress.highBandFloor) }
    }

    func testBaselineRelativeNilRMSSDFallsBackToHROnlyAndFlagsDegraded() {
        // An imported, Oura-era day: no personal RMSSD baseline exists yet (rmssd: nil) and no
        // R-R stream is available either. The read must still complete honestly, never crash.
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in [9, 14] { hr += hourHR(h, bpm: 80) }   // right at the validated +15 bpm margin
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        XCTAssertTrue(r.hrOnlyFallback)
        XCTAssertFalse(r.scored.isEmpty, "HR-only scoring must still produce a timeline")
        for p in r.scored { XCTAssertNotNil(p.level) }
    }

    func testBaselineRelativeUsesRMSSDBaselineWhenAvailable() {
        // Personal baselines: HR steady at 65 bpm, RMSSD steady at 40 ms (both spread-floored).
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        let rmssdBaseline = Baselines.foldHistory(Array(repeating: 40.0, count: 20), cfg: Baselines.daytimeRMSSDCfg)

        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [9, 14] { hr += hourHR(h, bpm: 65) }        // HR AT baseline in both hours — isolates RMSSD
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)        // normal variability
        rr += hourRRVariable(14, rrMs: 900, jitter: 2)        // suppressed HRV -> more stressed

        let r = DaytimeStress.analyze(hr: hr, rr: rr,
                                      mode: .baselineRelative(hr: hrBaseline, rmssd: rmssdBaseline))
        XCTAssertFalse(r.hrOnlyFallback, "an RMSSD baseline was supplied — no fallback")
        let normal = r.scored.first { $0.hour == 9 }!.level!
        let suppressed = r.scored.first { $0.hour == 14 }!.level!
        XCTAssertGreaterThan(suppressed, normal,
            "suppressed RMSSD vs. the personal baseline should read MORE stressed than normal variability")
    }
}
