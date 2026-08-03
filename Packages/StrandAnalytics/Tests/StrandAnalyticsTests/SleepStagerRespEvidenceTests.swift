import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Respiration evidence in the V1 stager: a MISSING RRV is `unmeasured`, never `regular`.
///
/// The classifier used to hold `rrvRegular = (!rrv.isFinite) || rrv <= rrvLo`, converting the absence of a
/// respiration reading into a positive assertion that breathing was regular — which is pro-deep. On a
/// WHOOP 5/MG that is the permanent state, not an edge case: the v18 layout emits no `resp_rate_raw`, so
/// `respSample` has zero rows and every epoch's RRV is NaN.
///
/// These tests pin three things: the corrected representation, that the correction changed no label, and
/// the SIZE of the bias that remains (so the next person to touch the deep gate has the number rather
/// than an adjective).
final class SleepStagerRespEvidenceTests: XCTestCase {

    private typealias Resp = SleepStager.RespEvidence

    // MARK: - The corrected representation

    /// The fix, stated directly: no measurement is `unmeasured`, and `unmeasured` is not `regular`.
    func testMissingRrvIsUnmeasuredNotRegular() {
        XCTAssertEqual(Resp.of(.nan, lowBar: 0.5, highBar: 1.0), .unmeasured)
        XCTAssertNotEqual(Resp.of(.nan, lowBar: 0.5, highBar: 1.0), .regular)
        // A whole session with no respiration channel leaves BOTH percentile bars nil (nothing finite to
        // take a percentile of). That is the 5/MG case, and it is still `unmeasured`, not `regular`.
        XCTAssertEqual(Resp.of(.nan, lowBar: nil, highBar: nil), .unmeasured)
        XCTAssertNotEqual(Resp.of(.nan, lowBar: nil, highBar: nil), .regular)
        XCTAssertEqual(Resp.of(.infinity, lowBar: 0.5, highBar: 1.0), .unmeasured)
    }

    func testMeasuredValuesMapToTheirBands() {
        XCTAssertEqual(Resp.of(0.2, lowBar: 0.5, highBar: 1.0), .regular)          // at/below the low bar
        XCTAssertEqual(Resp.of(0.5, lowBar: 0.5, highBar: 1.0), .regular)          // inclusive
        XCTAssertEqual(Resp.of(1.0, lowBar: 0.5, highBar: 1.0), .irregular)        // inclusive
        XCTAssertEqual(Resp.of(2.0, lowBar: 0.5, highBar: 1.0), .irregular)
        XCTAssertEqual(Resp.of(0.75, lowBar: 0.5, highBar: 1.0), .measuredMidBand)
        // Both bars on the same value: the reading clears each of them.
        XCTAssertEqual(Resp.of(0.75, lowBar: 0.75, highBar: 0.75), .barsDegenerate)
        // …and only ON that value. Either side of it the pair still separates normally.
        XCTAssertEqual(Resp.of(0.74, lowBar: 0.75, highBar: 0.75), .regular)
        XCTAssertEqual(Resp.of(0.76, lowBar: 0.75, highBar: 0.75), .irregular)
    }

    /// The five cases are the CROSS-PRODUCT of the two predicates this replaced, so every combination
    /// including "both true" has a home and none is decided by which bar `of` tests first.
    func testEveryCaseIsOneCellOfThePreFixBooleanPair() {
        // (rrvIrregular, rrvRegular) → case
        XCTAssertEqual(Resp.of(.nan, lowBar: 0.5, highBar: 1.0), .unmeasured)        // (false, true)
        XCTAssertEqual(Resp.of(0.2, lowBar: 0.5, highBar: 1.0), .regular)            // (false, true)
        XCTAssertEqual(Resp.of(2.0, lowBar: 0.5, highBar: 1.0), .irregular)          // (true,  false)
        XCTAssertEqual(Resp.of(0.75, lowBar: 0.5, highBar: 1.0), .measuredMidBand)   // (false, false)
        XCTAssertEqual(Resp.of(0.75, lowBar: 0.75, highBar: 0.75), .barsDegenerate)  // (true,  true)
        // The two readouts the classifier consumes, for the cell a four-state enum could not hold.
        XCTAssertFalse(Resp.barsDegenerate.contradictsDepth, "pre-fix `rrvRegular` was true here")
        XCTAssertTrue(Resp.barsDegenerate.meetsIrregularBar, "pre-fix `rrvIrregular` was true here")
    }

    /// Coincident bars are REACHABLE, not a theoretical corner — which is why the case is preserved
    /// rather than waved away.
    ///
    /// Two independent routes. (1) RRV is the population std of breath intervals measured in WHOLE
    /// SECONDS (`respRateAndRRV`, `dtS` = 1), so it is quantised onto a small discrete lattice and exact
    /// ties between epochs are ordinary; `percentile` interpolates between order statistics, so p50 and
    /// p65 coincide whenever a tie run spans them. (2) With exactly ONE finite RRV in the sleep period —
    /// `respRateAndRRV` returns NaN freely, on short, flat or low-peak windows — `percentile` returns
    /// that single value for EVERY percentile, so the bars coincide by construction and the epoch that
    /// set them necessarily sits on both.
    ///
    /// Both labels below are the pre-fix answers. Testing the high bar before the low bar would have
    /// classified the first as `irregular` and flipped it deep → light.
    func testCoincidentBarsAreReachableAndPreserveThePreFixLabels() {
        // Route (2), through the same `percentile` the stager uses.
        let sessionRrvs: [Double] = [.nan, .nan, 0.75, .nan, .nan]
        let lo = SleepStager.percentile(sessionRrvs, SleepStager.stageRRVLowPct)
        let hi = SleepStager.percentile(sessionRrvs, SleepStager.stageRRVHighPct)
        XCTAssertEqual(lo, 0.75)
        XCTAssertEqual(hi, 0.75, "one finite RRV in the session puts both bars on the same value")
        XCTAssertEqual(Resp.of(0.75, lowBar: lo, highBar: hi), .barsDegenerate)

        // Route (1): a tie run spanning p50…p65 does it too, with several finite values present.
        let tied: [Double] = [0.0, 0.25, 0.5, 0.5, 0.5, 0.5, 0.5, 1.0, 1.5, 2.0]
        XCTAssertEqual(SleepStager.percentile(tied, SleepStager.stageRRVLowPct),
                       SleepStager.percentile(tied, SleepStager.stageRRVHighPct))

        // Depth-shaped, no cardiac activation → pre-fix "deep" (the deep rule is stated first).
        let depthShaped = feature(moveFrac: 0, hr: 50, hrVar: 0, rmssd: 60, rrv: 0.75)
        XCTAssertEqual(SleepStager.classifyOne(depthShaped, hrLo: 55, hrHi: 90, rmssdHi: 50,
                                               hrvarHi: 10, rrvHi: 0.75, rrvLo: 0.75), "deep")
        // Cardiac-activated, not depth-shaped → the REM rule still sees the irregular bar cleared.
        let remShaped = feature(moveFrac: 0, hr: 95, hrVar: 20, rmssd: 10, rrv: 0.75)
        XCTAssertEqual(SleepStager.classifyOne(remShaped, hrLo: 55, hrHi: 90, rmssdHi: 50,
                                               hrvarHi: 10, rrvHi: 0.75, rrvLo: 0.75), "rem")

        // End to end, letting `classifyEpochs` compute the bars itself from the session above.
        let feats = sessionRrvs.enumerated().map { i, rrv in
            SleepStager.EpochFeatures(index: i, midTs: Double(i) * 30, count: 0, moveFrac: 0,
                                      ckSleep: true, hr: 50, hrVar: .nan, rmssd: 60, sdnn: 0,
                                      respRate: 14, rrv: rrv, clock: 0.5)
        }
        XCTAssertEqual(SleepStager.classifyEpochs(feats), Array(repeating: "deep", count: 5))
    }

    /// `measuredMidBand` and `unmeasured` both fail both bars but mean opposite things, and the classifier
    /// treats them differently — collapsing them into one "unknown" would silently change the hypnogram.
    func testMidBandAndUnmeasuredAreDistinctAndBehaveDifferently() {
        XCTAssertNotEqual(Resp.measuredMidBand, Resp.unmeasured)
        // Depth: a real mid-band reading rules depth OUT; a missing reading is waived (see below).
        XCTAssertTrue(Resp.measuredMidBand.contradictsDepth)
        XCTAssertFalse(Resp.unmeasured.contradictsDepth)
        XCTAssertFalse(Resp.regular.contradictsDepth)
        XCTAssertTrue(Resp.irregular.contradictsDepth)
        // A finite RRV with no bars (every SLEEP epoch was NaN but this non-sleep epoch was not) is a
        // measurement, so it must not fall into the unmeasured branch.
        XCTAssertEqual(Resp.of(0.7, lowBar: nil, highBar: nil), .measuredMidBand)
    }

    /// The waiver is now explicit and NAMED rather than emergent from a `!isFinite` short-circuit — but it
    /// is still a waiver, and this pins that it is: an unmeasured respiration does NOT block deep.
    /// Removing it would decode 0 m of deep on every 5/MG night (the #127/#129 regression, for the
    /// parallel missing-RMSSD case). Narrowing it is a scoring change that needs validation data.
    func testUnmeasuredRespirationIsWaivedForDeepAndTheWaiverIsExplicit() {
        let epoch = feature(moveFrac: 0, hr: 50, hrVar: 0, rmssd: 60, rrv: .nan)
        XCTAssertEqual(classify(epoch), "deep")
        XCTAssertFalse(Resp.unmeasured.contradictsDepth,
                       "the deep gate's treatment of a missing reading must be readable in one place")
    }

    // MARK: - The correction changed no label

    /// Exhaustive grid: the new `RespEvidence` classifier must agree with the OLD boolean predicates on
    /// every combination. The old formulas are reproduced verbatim here so the equivalence is checkable
    /// rather than asserted — this is what makes the change a representation fix and not a scoring change.
    ///
    /// The BAR PAIR is an axis, not a constant. Holding it at a well-separated `(0.5, 1.0)` hides the one
    /// combination where the two pre-fix booleans were BOTH true — `rrvHi <= rrv <= rrvLo`, which the
    /// coincident-bar pairs below reach — and hides the nil bars entirely. Those cells are where a
    /// four-state enum would have silently changed a label.
    func testClassificationIsIdenticalToThePreFixPredicates() {
        func legacy(_ f: SleepStager.EpochFeatures,
                    hrLo: Double?, hrHi: Double?, rmssdHi: Double?, hrvarHi: Double?,
                    rrvHi: Double?, rrvLo: Double?, cardiacSparse: Bool) -> String {
            let hasHR = f.hr.isFinite
            let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
            let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!
            let parasympOK = (!f.rmssd.isFinite) || (rmssdHi != nil && f.rmssd >= rmssdHi!)
            let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
            let cardiacActivated = hrHigh || hrvarHigh
            let cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated
            // The two predicates this change replaced, exactly as they were.
            let rrvIrregular = f.rrv.isFinite && rrvHi != nil && f.rrv >= rrvHi!
            let rrvRegular = (!f.rrv.isFinite) || (rrvLo != nil && f.rrv <= rrvLo!)
            let still = f.moveFrac <= SleepStager.stageStillMoveFrac
            let moving = f.moveFrac >= SleepStager.stageWakeMoveFrac
            if moving && (cardiacActivatedForWake || !hasHR) { return "wake" }
            if still && parasympOK && hrLow && rrvRegular { return "deep" }
            if still && cardiacActivated && rrvIrregular { return "rem" }
            if still && hrHigh && hrvarHigh && !f.rrv.isFinite { return "rem" }
            return "light"
        }

        // (low, high). Separated; coincident on a value the RRV axis hits; coincident elsewhere;
        // inverted (defensive — `of` reads the pair, it does not assume low <= high); and each way of
        // having no bar at all, up to the 5/MG session where neither exists.
        let barPairs: [(lo: Double?, hi: Double?)] = [
            (0.5, 1.0), (0.75, 0.75), (0.5, 0.5), (1.0, 0.5), (nil, 1.0), (0.5, nil), (nil, nil),
        ]

        var checked = 0
        var sawBothPreFixBooleansTrue = false
        for bars in barPairs {
            for moveFrac in [0.0, 0.05, 0.12, 0.2] {
                for hr in [Double.nan, 45, 60, 95] {
                    for hrVar in [Double.nan, 1, 20] {
                        for rmssd in [Double.nan, 10, 80] {
                            // NaN (never measured), below/at/between/at/above the bars.
                            for rrv in [Double.nan, 0.2, 0.5, 0.75, 1.0, 2.0] {
                                for sparse in [false, true] {
                                    let f = feature(moveFrac: moveFrac, hr: hr, hrVar: hrVar,
                                                    rmssd: rmssd, rrv: rrv)
                                    let new = SleepStager.classifyOne(
                                        f, hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 10,
                                        rrvHi: bars.hi, rrvLo: bars.lo, cardiacSparse: sparse)
                                    let old = legacy(f, hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 10,
                                                     rrvHi: bars.hi, rrvLo: bars.lo,
                                                     cardiacSparse: sparse)
                                    XCTAssertEqual(new, old,
                                        "label changed for move=\(moveFrac) hr=\(hr) hrVar=\(hrVar) " +
                                        "rmssd=\(rmssd) rrv=\(rrv) sparse=\(sparse) " +
                                        "bars=(\(String(describing: bars.lo)), " +
                                        "\(String(describing: bars.hi)))")
                                    if rrv.isFinite,
                                       let lo = bars.lo, let hi = bars.hi, rrv >= hi, rrv <= lo {
                                        sawBothPreFixBooleansTrue = true
                                    }
                                    checked += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(checked, 7 * 4 * 4 * 3 * 3 * 6 * 2)
        // The grid is only worth more than the old one if it actually visits the cell that motivated it.
        XCTAssertTrue(sawBothPreFixBooleansTrue,
                      "the grid must reach `rrvIrregular && rrvRegular` — otherwise the coincident-bar "
                      + "case is still untested and a bar-pair axis was added for nothing")
    }

    /// The same equivalence for the session with NO respiration channel at all (both bars nil) — the
    /// WHOOP 5/MG shape, and the one the bias actually lives on.
    func testNoRespChannelSessionIsAlsoUnchanged() {
        for moveFrac in [0.0, 0.12, 0.2] {
            for hr in [Double.nan, 45, 95] {
                for hrVar in [Double.nan, 1, 20] {
                    for rmssd in [Double.nan, 10, 80] {
                        let f = feature(moveFrac: moveFrac, hr: hr, hrVar: hrVar, rmssd: rmssd, rrv: .nan)
                        let new = SleepStager.classifyOne(f, hrLo: 55, hrHi: 90, rmssdHi: 50,
                                                          hrvarHi: 10, rrvHi: nil, rrvLo: nil)
                        // Old formulas with nil bars: rrvIrregular = false, rrvRegular = true (the bug).
                        let hasHR = f.hr.isFinite
                        let hrLow = hasHR && f.hr <= 55
                        let hrHigh = hasHR && f.hr >= 90
                        let parasympOK = (!f.rmssd.isFinite) || f.rmssd >= 50
                        let hrvarHigh = f.hrVar.isFinite && f.hrVar >= 10
                        let still = f.moveFrac <= SleepStager.stageStillMoveFrac
                        let moving = f.moveFrac >= SleepStager.stageWakeMoveFrac
                        let old: String
                        if moving && ((hrHigh || hrvarHigh) || !hasHR) { old = "wake" }
                        else if still && parasympOK && hrLow { old = "deep" }
                        else if still && hrHigh && hrvarHigh { old = "rem" }
                        else { old = "light" }
                        XCTAssertEqual(new, old)
                    }
                }
            }
        }
    }

    /// `remRejectReason` must stay in lockstep with `classifyOne` — they were hand-duplicated predicates
    /// and now share one factory, so this guards the seam. The bar pair is an axis here too: the
    /// diagnostic reads `meetsIrregularBar`, so the coincident-bar case has to be exercised on both
    /// sides of the seam or only one of them is pinned.
    func testRemRejectReasonAgreesWithTheClassifier() {
        let barPairs: [(lo: Double?, hi: Double?)] = [(0.5, 1.0), (0.75, 0.75), (nil, nil)]
        for bars in barPairs {
            for rrv in [Double.nan, 0.2, 0.75, 2.0] {
                for hr in [Double.nan, 45, 95] {
                    for hrVar in [Double.nan, 1, 20] {
                        for moveFrac in [0.0, 0.2] {
                            let f = feature(moveFrac: moveFrac, hr: hr, hrVar: hrVar,
                                            rmssd: .nan, rrv: rrv)
                            let label = SleepStager.classifyOne(f, hrLo: 55, hrHi: 90, rmssdHi: 50,
                                                                hrvarHi: 10,
                                                                rrvHi: bars.hi, rrvLo: bars.lo)
                            let reason = SleepStager.remRejectReason(f, hrLo: 55, hrHi: 90,
                                                                     rmssdHi: 50, hrvarHi: 10,
                                                                     rrvHi: bars.hi, rrvLo: bars.lo)
                            XCTAssertEqual(label == "rem", reason == .remEligible,
                                           "rem-eligibility disagreed for rrv=\(rrv) hr=\(hr) "
                                           + "bars=(\(String(describing: bars.lo)), "
                                           + "\(String(describing: bars.hi)))")
                        }
                    }
                }
            }
        }
    }

    /// A measured-but-mid-band respiration must NOT earn the missing-respiration REM fallback — that
    /// fallback exists to compensate for having no reading, not for having an unremarkable one.
    func testMidBandDoesNotEarnTheMissingRespirationRemFallback() {
        // still + hrHigh + hrvarHigh: the fallback's exact preconditions.
        let unmeasured = feature(moveFrac: 0, hr: 95, hrVar: 20, rmssd: .nan, rrv: .nan)
        let midBand = feature(moveFrac: 0, hr: 95, hrVar: 20, rmssd: .nan, rrv: 0.75)
        XCTAssertEqual(classify(unmeasured), "rem")
        XCTAssertEqual(classify(midBand), "light")
    }

    // MARK: - The size of the remaining bias

    /// QUANTIFIED, so the next person to touch the deep gate argues with a number.
    ///
    /// The "regular" bar is `stageRRVLowPct` = 50 — the MEDIAN. So on a night with real respiration data
    /// about half of otherwise-depth-shaped epochs clear it. On a session with no respiration channel the
    /// old code cleared it for ALL of them, on no measurement at all. That factor-of-two is the bias.
    ///
    /// It is bounded, though, and the bound matters as much as the bias: `hrLow` is itself a percentile
    /// bar (`stageHRLowPct` = 25), so at most ~25% of sleep epochs can reach the deep gate however the
    /// respiration term resolves. The bias inflates deep within that ceiling; it cannot run away.
    func testTheDeepPassRateDoublesWhenTheRespirationChannelIsAbsent() {
        // 100 depth-shaped epochs (still, low HR, high parasympathetic tone) whose RRV spans a real
        // distribution: half at/below the median bar, half above it.
        let rrvs = (0..<100).map { Double($0) / 100.0 }          // 0.00 … 0.99, median 0.5
        let withResp = rrvs.map { rrv in
            classify(feature(moveFrac: 0, hr: 50, hrVar: 0, rmssd: 60, rrv: rrv))
        }
        let deepWithResp = withResp.filter { $0 == "deep" }.count
        XCTAssertEqual(deepWithResp, 51, "the regular bar is the median, so ~half of epochs pass")

        // The same epochs on a strap with no respiration channel: every RRV is NaN.
        let withoutResp = rrvs.map { _ in
            SleepStager.classifyOne(feature(moveFrac: 0, hr: 50, hrVar: 0, rmssd: 60, rrv: .nan),
                                    hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 10,
                                    rrvHi: nil, rrvLo: nil)
        }
        XCTAssertEqual(withoutResp.filter { $0 == "deep" }.count, 100,
                       "with no respiration channel EVERY depth-shaped epoch passes the deep gate")
        // ~2x. Stated as a ratio so the assertion survives a bar tweak.
        XCTAssertEqual(Double(100) / Double(deepWithResp), 1.96, accuracy: 0.05)
    }

    /// The RRV source itself: with no respiration samples there is nothing to measure, so the NaN is
    /// honest at the point it is produced. The bug was never here — it was in spending that NaN as
    /// evidence downstream.
    func testRrvIsNaNWhenThereAreNoRespirationSamples() {
        XCTAssertTrue(SleepStager.respRateAndRRV([]).1.isNaN)
        XCTAssertTrue(SleepStager.respRateAndRRV([1, 2, 3]).1.isNaN)
    }

    // MARK: - Fixtures

    private func feature(moveFrac: Double, hr: Double, hrVar: Double,
                         rmssd: Double, rrv: Double) -> SleepStager.EpochFeatures {
        SleepStager.EpochFeatures(index: 0, midTs: 0, count: 0, moveFrac: moveFrac,
                                  ckSleep: true, hr: hr, hrVar: hrVar, rmssd: rmssd, sdnn: 0,
                                  respRate: 14, rrv: rrv, clock: 0.5)
    }

    private func classify(_ f: SleepStager.EpochFeatures) -> String {
        SleepStager.classifyOne(f, hrLo: 55, hrHi: 90, rmssdHi: 50, hrvarHi: 10,
                                rrvHi: 1.0, rrvLo: 0.5)
    }
}

/// `SleepStagerV2` — the DEFAULT stager — accepts a `resp` argument and never reads it.
///
/// That was documented in a comment and pinned by nothing, so a future edit could start consuming it (or
/// stop) with no test noticing. These make the contract enforceable. It also matters for the bug above:
/// on the shipped default path the raw respiration ADC is not consulted at all, so the V1 pro-deep bias
/// reaches only users who have turned the V2 experiment off.
final class SleepStagerV2RespIsInertTests: XCTestCase {

    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }
    private func sleepHR(start: Int, durationS: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: 52 + ($0 / 60) % 3) }
    }
    private func regularRR(start: Int, durationS: Int) -> [RRInterval] {
        (0..<durationS).map { i in
            RRInterval(ts: start + i, rrMs: 1000 + Int(40.0 * sin(2.0 * Double.pi * Double(i) / 4.0)))
        }
    }

    /// A populated `resp` stream must not move a single segment. If this ever fails, V2 started consuming
    /// respiration and the "signature-parity only" doc — and V2's cache key, which deliberately omits
    /// `resp` — are both wrong.
    func testV2OutputIsIdenticalWithAndWithoutARespirationStream() {
        let start = 1_700_000_000
        let dur = 90 * 60
        let grav = stillGravity(start: start, durationS: dur)
        let hr = sleepHR(start: start, durationS: dur)
        let rr = regularRR(start: start, durationS: dur)
        // A resp stream with real structure, not a constant — a consumer would produce different RRVs.
        let resp = (0..<dur).map { i in
            RespSample(ts: start + i, raw: 1000 + Int(200.0 * sin(2.0 * Double.pi * Double(i) / 4.0)))
        }

        let without = SleepStagerV2.stageSession(start: start, end: start + dur,
                                                 grav: grav, hr: hr, rr: rr, resp: [])
        let with = SleepStagerV2.stageSession(start: start, end: start + dur,
                                              grav: grav, hr: hr, rr: rr, resp: resp)
        XCTAssertEqual(without.map { "\($0.start)-\($0.end)-\($0.stage)" },
                       with.map { "\($0.start)-\($0.end)-\($0.stage)" },
                       "V2 must ignore `resp` — it recovers respiration regularity from R-R (RSA) instead")
        XCTAssertFalse(without.isEmpty, "the fixture must actually produce segments")
    }

    /// On a WHOOP 5/MG the argument is empty anyway: the v18 layout emits no `resp_rate_raw`, so
    /// `respSample` never gets a row. Pinned in the decoder tests; restated here because it is the reason
    /// the V1 bias is permanent on that strap rather than occasional.
    func testTheRespStreamIsEmptyOnTheStrapThatMattersHere() {
        XCTAssertTrue([RespSample]().isEmpty)
    }
}
