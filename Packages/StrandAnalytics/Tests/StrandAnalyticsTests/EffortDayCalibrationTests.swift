import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// #2438 step 0: the day's HRmax, where it came from, and what the day's heart rate actually reached.
///
/// The proposal turns on a comparison a log could not previously be read for — the yardstick a day was
/// scored against, against the one the day itself suggests — because `effort score` prints `provided`
/// for a manual override and for the Tanaka age formula alike.
///
/// These lines are contributed as evidence and then argued from, by people who cannot re-run the day
/// that produced them. A diagnostic that names the wrong branch is worse than none, which is why the
/// branch is pinned end to end here and not only as a string.
///
/// Byte-parity twin of Kotlin `EffortDayCalibrationTest`.
final class EffortDayCalibrationTests: XCTestCase {

    // MARK: the line

    /// The exact bytes. The string is compared between two contributors' logs — and between an iOS log
    /// and an Android one — so its shape is the contract, not an implementation detail.
    func testTheLineIsExactlyThis() {
        XCTAssertEqual(
            StrainScorer.dayCalibrationLine(day: "2026-09-25", hrmax: 195.0, hrmaxSource: "override",
                                            tanaka: 187.0, observedPeak: 178.0, restingHR: 52.0)
                + StrainScorer.sustainedPeakField(171.0),
            "effort calib day=2026-09-25 hrmax=195 src=override tanaka=187 peak=178 rhr=52 sustained=171")
    }

    /// An age-less profile has no formula value and a day with no heart rate has no peak. Both must say
    /// so: printing 0 would make "we never measured it" indistinguishable from a reading of zero, and
    /// this line exists to be subtracted from.
    func testMissingValuesRenderAsNilNotZero() {
        XCTAssertEqual(
            StrainScorer.dayCalibrationLine(day: "2026-09-25", hrmax: nil, hrmaxSource: "default",
                                            tanaka: nil, observedPeak: nil, restingHR: 60.0)
                + StrainScorer.sustainedPeakField(nil),
            "effort calib day=2026-09-25 hrmax=nil src=default tanaka=nil peak=nil rhr=60 sustained=nil")
    }

    /// The three source words are disjoint, and none of them is `effort score`'s `provided` — the whole
    /// point is that the word on this line resolves the one on that line.
    func testTheSourceWordsAreDisjointAndNotProvided() {
        let words = ["override", "tanaka", "default"]
        XCTAssertEqual(Set(words).count, words.count)
        XCTAssertFalse(words.contains("provided"))
    }

    // MARK: end to end, through the engine

    /// A manual override must read as `override`, with the formula value still printed beside it. That
    /// pair is the step-0 question in one line: an override of 195 on a profile Tanaka puts at 187 is a
    /// day scored 8 bpm higher than the formula would have.
    func testAnOverrideIsNamedAsOneAndStillPrintsTanaka() {
        let line = calibLine(age: 30, maxHROverride: 195, peakBpm: 178)
        XCTAssertEqual(line, "effort calib day=2026-09-25 hrmax=195 src=override tanaka=187 peak=178 rhr=60 sustained=178")
    }

    /// With no override the day runs on the formula, and `hrmax` and `tanaka` are then the same number.
    /// A reader seeing them agree knows no setting was in force without having to know the profile.
    func testNoOverrideIsNamedTanakaAndAgreesWithIt() {
        let line = calibLine(age: 30, maxHROverride: nil, peakBpm: 178)
        XCTAssertEqual(line, "effort calib day=2026-09-25 hrmax=187 src=tanaka tanaka=187 peak=178 rhr=60 sustained=178")
    }

    /// No age, no override: `strain` substitutes its own default internally, and the line reports THAT
    /// number rather than nil, because it is the yardstick the day was really scored against. `tanaka`
    /// is nil, since without an age there is no formula value, and that is the honest half.
    ///
    /// The nil version of this was the first draft, and it made the line contradict `effort score` about
    /// the same day: that line prints the substituted 190 while this one claimed there was no HRmax.
    func testAnAgelessProfileReportsTheSubstitutedDefault() {
        let line = calibLine(age: 0, maxHROverride: nil, peakBpm: 178)
        XCTAssertEqual(line, "effort calib day=2026-09-25 hrmax=190 src=default tanaka=nil peak=178 rhr=60 sustained=178")
    }

    /// The peak is the day's RAW maximum, not a percentile and not a trimmed one. The rule under
    /// discussion counts days whose peak crossed a threshold, so a single high minute has to reach the
    /// line — the two-different-days requirement is what absorbs an artefact, not a quiet formatter.
    func testASingleHighMinuteReachesThePeak() {
        let line = calibLine(age: 30, maxHROverride: nil, peakBpm: 178, spikeBpm: 201)
        XCTAssertTrue(line.contains(" peak=201 "), line)
    }

    /// The same day through the engine: the one-sample spike reaches `peak` and stays out of `sustained`,
    /// which still reports the ten-minute block. That gap is what the field exists to show.
    func testASingleHighMinuteStaysOutOfSustained() {
        let line = calibLine(age: 30, maxHROverride: nil, peakBpm: 178, spikeBpm: 201)
        XCTAssertTrue(line.contains(" peak=201 ") && line.hasSuffix(" sustained=178"), line)
    }

    // MARK: sustained peak

    private func run(_ bpms: [Int], every stepS: Int = 1, from start: Int = 1_790_294_400) -> [HRSample] {
        bpms.enumerated().map { HRSample(ts: start + $0.offset * stepS, bpm: $0.element) }
    }

    /// One sample, or four, at a high value is not held; five is.
    func testSustainedPeakNeedsFiveConsecutiveSamples() {
        let base = Array(repeating: 90, count: 8)
        XCTAssertEqual(StrainScorer.sustainedPeak(run(base + [200] + base)), 90)
        XCTAssertEqual(StrainScorer.sustainedPeak(run(base + [200, 200, 200, 200] + base)), 90)
        XCTAssertEqual(StrainScorer.sustainedPeak(run(base + [200, 200, 200, 200, 200] + base)), 200)
    }

    /// The minimum over the run, not the mean: a spike inside ordinary samples does not lift it.
    func testSustainedPeakIsTheMinimumOfTheRun() {
        XCTAssertEqual(StrainScorer.sustainedPeak(run([150, 150, 210, 150, 150])), 150)
    }

    /// The five samples must fit in 60 s: a span of exactly 60 counts, 61 does not.
    func testSustainedPeakWindowBoundary() {
        XCTAssertEqual(StrainScorer.sustainedPeak(run([170, 170, 170, 170, 170], every: 15)), 170)
        let wide = run([170, 170, 170, 170], every: 15) + [HRSample(ts: 1_790_294_400 + 61, bpm: 170)]
        XCTAssertNil(StrainScorer.sustainedPeak(wide))
    }

    /// A sparse day, such as a ring's five-minute cadence, and a day with fewer than five samples, read
    /// as nil: not measured, rather than a fallback to the raw peak.
    func testSustainedPeakIsNilWhenNotDenseEnough() {
        XCTAssertNil(StrainScorer.sustainedPeak(run([120, 130, 140, 150, 160, 170], every: 300)))
        XCTAssertNil(StrainScorer.sustainedPeak(run([180, 180, 180, 180])))
        XCTAssertNil(StrainScorer.sustainedPeak([]))
    }

    /// Input order does not matter.
    func testSustainedPeakIgnoresInputOrder() {
        let hr = run([100, 160, 161, 162, 163, 164, 100, 90])
        XCTAssertEqual(StrainScorer.sustainedPeak(hr), StrainScorer.sustainedPeak(hr.reversed()))
    }

    /// Parity oracle. 48 generated days (a 64-bit LCG, so the Kotlin test builds the same ones), with
    /// duplicate seconds, reversed input and gaps from dense to sparse. The expected literal is the
    /// stdout of this implementation compiled on its own; `EffortDayCalibrationTest` pins the same one.
    func testSustainedPeakParityOracle() {
        var state: UInt64 = 2438
        func next(_ m: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % m
        }
        var out: [String] = []
        for c in 0 ..< 48 {
            let n = next(40)
            let maxGap = [2, 8, 20, 40][c % 4]
            var ts = 1_790_294_400
            var hr: [HRSample] = []
            for _ in 0 ..< n {
                ts += next(maxGap)
                hr.append(HRSample(ts: ts, bpm: 60 + next(140)))
            }
            if c % 3 == 0 { hr.reverse() }
            out.append(StrainScorer.sustainedPeak(hr).map { String(Int($0)) } ?? "nil")
        }
        XCTAssertEqual(out.joined(separator: ","),
                       "77,97,148,97,nil,90,113,69,87,147,109,nil,nil,115,102,112,89,88,130,87,114,128,75,nil,119,103,144,nil,123,124,82,119,136,62,161,nil,nil,79,nil,90,102,163,130,133,79,146,87,nil")
    }

    /// The two lines must agree about the day. `effort calib` reads the branch at the call site and
    /// `effort score` reads the HRmax that actually reached the scorer, by two different routes — so
    /// they can disagree, and a contributor reading one against the other would be reading a fiction.
    /// `src` maps onto the score line's coarser word: override and tanaka are both `provided` there.
    func testTheCalibAndScoreLinesAgreeAboutTheSameDay() {
        let cases: [(age: Double, override: Double?, src: String, word: String)] = [
            (30, 195, "override", "provided"),
            (30, nil, "tanaka", "provided"),
            (0, nil, "default", "default"),
        ]
        for c in cases {
            var emitted: [String] = []
            _ = AnalyticsEngine.analyzeDay(day: "2026-09-25", strainDiag: { emitted.append($0) },
                                           hr: dayHR(peakBpm: 178), profile: UserProfile(age: c.age),
                                           maxHROverride: c.override)
            let calib = emitted.first { $0.hasPrefix("effort calib ") } ?? ""
            let score = emitted.first { $0.hasPrefix("effort score ") } ?? ""
            XCTAssertTrue(calib.contains(" src=" + c.src + " "), calib)
            XCTAssertTrue(score.contains("(" + c.word + ")"), score)
            // hrmax=187 on the calib line and hrMax=187.0 on the score line are the same number written
            // to different precisions, so compare the value rather than the text.
            // No exception for the age-less case: the two lines report the same number there too, which
            // is the whole invariant. Carving that case out was what hid the contradiction.
            let calibMax = field(calib, "hrmax=")
            let scoreMax = String(field(score, "hrMax=").prefix(while: { $0 != "(" }))
            XCTAssertEqual(Double(calibMax) ?? -1, Double(scoreMax) ?? -2, accuracy: 1e-9,
                           calib + " | " + score)
        }
    }

    /// Value of `key=` up to the next space.
    private func field(_ line: String, _ key: String) -> String {
        guard let r = line.range(of: key) else { return "" }
        let rest = line[r.upperBound...]
        return String(rest.prefix(while: { $0 != " " }))
    }

    // MARK: fixture

    /// A day whose heart rate is flat at 60 with a ten-minute block at `peakBpm`, plus one optional
    /// single-sample spike. 1 Hz across an hour, which clears the scorer's density gate.
    private func dayHR(peakBpm: Int, spikeBpm: Int? = nil) -> [HRSample] {
        let base = 1_790_294_400   // 2026-09-25T00:00:00Z
        var out = (0 ..< 3600).map { i in
            HRSample(ts: base + i, bpm: (i >= 600 && i < 1200) ? peakBpm : 60)
        }
        if let spikeBpm { out.append(HRSample(ts: base + 3600, bpm: spikeBpm)) }
        return out
    }

    private func calibLine(age: Double, maxHROverride: Double?, peakBpm: Int,
                           spikeBpm: Int? = nil) -> String {
        var emitted: [String] = []
        _ = AnalyticsEngine.analyzeDay(day: "2026-09-25", strainDiag: { emitted.append($0) },
                                       hr: dayHR(peakBpm: peakBpm, spikeBpm: spikeBpm),
                                       profile: UserProfile(age: age),
                                       maxHROverride: maxHROverride)
        let calib = emitted.filter { $0.hasPrefix("effort calib ") }
        XCTAssertEqual(calib.count, 1, "exactly one calibration line per scored day: \(emitted)")
        return calib.first ?? ""
    }
}
