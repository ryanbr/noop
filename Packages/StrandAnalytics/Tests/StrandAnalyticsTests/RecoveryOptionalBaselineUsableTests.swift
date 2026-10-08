import XCTest
@testable import StrandAnalytics

/// Optional personal baselines obey the same eligibility contract as resting HR.
/// Kotlin twin: RecoveryOptionalBaselineUsableTest.
final class RecoveryOptionalBaselineUsableTests: XCTestCase {
    private func optionalBaselineFixture(_ mean: Double, _ spread: Double,
                                         _ status: BaselineStatus = .trusted) -> BaselineState {
        BaselineState(baseline: mean, spread: spread,
                      nValid: status == .calibrating ? 0 : (status == .provisional ? 6 : 14),
                      nightsSinceUpdate: status == .stale ? 20 : 0, status: status)
    }

    private var hrv: BaselineState { optionalBaselineFixture(50, 8) }
    private var rhr: BaselineState { optionalBaselineFixture(60, 4) }
    private let statuses: [BaselineStatus] = [.calibrating, .provisional, .trusted, .stale]
    private let respiratoryValues: [Double?] = [nil, 10, 14, 18, 22]
    private let effortValues: [Double?] = [nil, 0, 30, 60, 100]

    private func optionalChargeFixture(respBase: BaselineState?, effortBase: BaselineState? = nil,
                                       resp: Double? = 14, effort: Double? = 60) -> Double? {
        RecoveryScorer.recovery(hrv: 55, rhr: 58, resp: resp,
                                hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: respBase,
                                sleepPerf: 0.85, skinTempDev: 0.2, recoveryIndexSlope: -0.5,
                                effortBaseline: effortBase, priorDayEffort: effort)
    }

    func testUnusableRespirationScoresExactlyLikeAbsent() {
        let states = [Baselines.foldHistory([], cfg: Baselines.respCfg),
                      Baselines.foldHistory([0, 100], cfg: Baselines.respCfg),
                      optionalBaselineFixture(16, 2, .stale)]
        for base in states {
            XCTAssertFalse(base.usable)
            for value in respiratoryValues {
                XCTAssertEqual(optionalChargeFixture(respBase: base, resp: value)?.bitPattern,
                               optionalChargeFixture(respBase: nil, resp: value)?.bitPattern)
            }
        }
    }

    func testUnusableEffortScoresExactlyLikeAbsent() {
        let states = [Baselines.foldHistory([], cfg: Baselines.strainCfg),
                      Baselines.foldHistory([-1, 101], cfg: Baselines.strainCfg),
                      optionalBaselineFixture(45, 10, .stale)]
        for base in states {
            XCTAssertFalse(base.usable)
            for value in effortValues {
                XCTAssertEqual(optionalChargeFixture(respBase: nil, effortBase: base, effort: value)?.bitPattern,
                               optionalChargeFixture(respBase: nil, effort: value)?.bitPattern)
            }
        }
    }

    func testAllOptionalStateAndValuePairsMatchEligibleDriverContract() {
        let respStates: [BaselineState?] = [nil] + statuses.map { optionalBaselineFixture(16, 2, $0) }
        let effortStates: [BaselineState?] = [nil] + statuses.map { optionalBaselineFixture(45, 10, $0) }
        var cases = 0
        for respBase in respStates {
            for effortBase in effortStates {
                for resp in respiratoryValues {
                    for effort in effortValues {
                        // The status-free API is the original math, with only eligible personal states supplied.
                        let expected = RecoveryScorer.recovery(
                            hrv: 55, rhr: 58, resp: resp,
                            hrvBaseline: RecoveryScorer.DriverBaseline(hrv),
                            rhrBaseline: RecoveryScorer.DriverBaseline(rhr),
                            respBaseline: respBase.flatMap { $0.usable ? RecoveryScorer.DriverBaseline($0) : nil },
                            sleepPerf: 0.85, skinTempDev: 0.2, recoveryIndexSlope: -0.5,
                            effortBaseline: effortBase.flatMap { $0.usable ? RecoveryScorer.DriverBaseline($0) : nil },
                            priorDayEffort: effort)
                        XCTAssertEqual(optionalChargeFixture(respBase: respBase, effortBase: effortBase,
                                                              resp: resp, effort: effort)?.bitPattern,
                                       expected?.bitPattern)
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(cases, 625)
        XCTAssertNotEqual(optionalChargeFixture(respBase: nil)?.bitPattern,
                          optionalChargeFixture(respBase: optionalBaselineFixture(16, 2))?.bitPattern)
        XCTAssertNotEqual(optionalChargeFixture(respBase: nil)?.bitPattern,
                          optionalChargeFixture(respBase: nil, effortBase: optionalBaselineFixture(45, 10))?.bitPattern)
    }

    func testRespirationRowsUseExactlyTheEligibleBaseline() {
        for status in statuses {
            let base = optionalBaselineFixture(16, 2, status)
            for value in respiratoryValues {
                let actual = RecoveryScorer.chargeDrivers(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                let expected = RecoveryScorer.chargeDrivers(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base.usable ? base : nil,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                XCTAssertEqual(actual, expected)
                XCTAssertEqual(actual.contains { $0.label == "Respiratory rate" }, base.usable && value != nil)
                XCTAssertTrue(actual.contains { $0.label == "Heart rate variability" })
            }
        }
    }

    func testRespirationTraceUsesExactlyTheScoredTerms() {
        for status in statuses {
            let base = optionalBaselineFixture(16, 2, status)
            for value in respiratoryValues {
                let actual = RecoveryScorer.recoveryTrace(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                let expected = RecoveryScorer.recoveryTrace(hrv: 55, rhr: 58, resp: value,
                    hrvBaseline: hrv, rhrBaseline: rhr, respBaseline: base.usable ? base : nil,
                    sleepPerf: 0.85, skinTempDev: 0.2)
                XCTAssertEqual(actual.score?.bitPattern, expected.score?.bitPattern)
                XCTAssertEqual(actual.trace, expected.trace)
                XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge term resp ") }, base.usable && value != nil)
                XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge baseline resp ") }, base.usable)
                XCTAssertEqual(actual.trace.contains { $0.hasPrefix("charge nilTerm dropped=") && $0.contains("resp") },
                               !base.usable || value == nil)
            }
        }
    }

    func testDominantHrvColdStartStillRefusesEveryOptionalState() {
        for status in [BaselineStatus.calibrating, .stale] {
            let coldHrv = optionalBaselineFixture(50, 8, status)
            for optionalStatus in statuses {
                let base = optionalBaselineFixture(16, 2, optionalStatus)
                XCTAssertNil(RecoveryScorer.recovery(hrv: 55, rhr: 58, resp: 14,
                    hrvBaseline: coldHrv, rhrBaseline: rhr, respBaseline: base, sleepPerf: 0.85,
                    effortBaseline: optionalBaselineFixture(45, 10, optionalStatus), priorDayEffort: 60))
                XCTAssertTrue(RecoveryScorer.chargeDrivers(hrv: 55, rhr: 58, resp: 14,
                    hrvBaseline: coldHrv, rhrBaseline: rhr, respBaseline: base, sleepPerf: 0.85).isEmpty)
                let trace = RecoveryScorer.recoveryTrace(hrv: 55, rhr: 58, resp: 14,
                    hrvBaseline: coldHrv, rhrBaseline: rhr, respBaseline: base, sleepPerf: 0.85)
                XCTAssertNil(trace.score)
                XCTAssertEqual(trace.trace.count, 1)
                XCTAssertTrue(trace.trace.first?.contains("hrvBaselineNotUsable") ?? false)
            }
        }
    }
}
