import XCTest
@testable import Strand

/// Pins the resp diagnostic's nil-reason (#1331). Kotlin twin: `RespRateLogLineTest`.
///
/// The line exists because "rpm=nil" alone cost a cross-subsystem investigation to explain: on a WHOOP
/// 4.0 the RSA beat-accuracy gate empties the card on nearly every night, and nothing said so.
final class RespRateLogLineTests: XCTestCase {

    func testARealRateIsUnchangedAndCarriesNoReason() {
        XCTAssertEqual(
            IntelligenceEngine.respRateLogLine(day: "2026-08-11", respRateBpm: 16.0,
                                               beatAccurate: 0.52, rrIntegrity: "crossSecondOverCount"),
            "resp day=2026-08-11 rpm=16.0"
        )
    }

    func testNilBelowTheGateNamesTheGateThatRefusedIt() {
        XCTAssertEqual(
            IntelligenceEngine.respRateLogLine(day: "2026-08-26", respRateBpm: nil,
                                               beatAccurate: 0.45, rrIntegrity: "crossSecondOverCount"),
            "resp day=2026-08-26 rpm=nil beatAccurate=0.45<0.50 rrIntegrity=crossSecondOverCount"
            + " — RSA gate refused the R-R"
        )
    }

    func testNilAboveTheGateSaysTheCauseIsElsewhere() {
        // The estimator has four other NaN exits (beats, span, grid, window). Naming the gate here would
        // be wrong, so the line says only what it knows.
        XCTAssertEqual(
            IntelligenceEngine.respRateLogLine(day: "2026-08-26", respRateBpm: nil,
                                               beatAccurate: 0.83, rrIntegrity: "plausible"),
            "resp day=2026-08-26 rpm=nil beatAccurate=0.83>=0.50 rrIntegrity=plausible"
            + " — gate passed, cause is elsewhere"
        )
    }

    func testANightWithNoHRVBlockReadsExactlyAsItAlwaysDid() {
        XCTAssertEqual(
            IntelligenceEngine.respRateLogLine(day: "2026-08-26", respRateBpm: nil),
            "resp day=2026-08-26 rpm=nil"
        )
    }

    func testTheBoundaryItselfPasses() {
        // 0.50 is >= the gate, so it must NOT read as refused — an off-by-one here would blame the gate
        // for a night it actually admitted.
        XCTAssertEqual(
            IntelligenceEngine.respRateLogLine(day: "2026-08-26", respRateBpm: nil,
                                               beatAccurate: 0.50, rrIntegrity: "plausible"),
            "resp day=2026-08-26 rpm=nil beatAccurate=0.50>=0.50 rrIntegrity=plausible"
            + " — gate passed, cause is elsewhere"
        )
    }

    func testAnUnknownIntegrityIsLabelledRatherThanBlank() {
        XCTAssertEqual(
            IntelligenceEngine.respRateLogLine(day: "2026-08-26", respRateBpm: nil, beatAccurate: 0.45),
            "resp day=2026-08-26 rpm=nil beatAccurate=0.45<0.50 rrIntegrity=unknown"
            + " — RSA gate refused the R-R"
        )
    }

    func testANaNFractionReadsAsPassedMirroringTheGatesOwnNaNConvention() {
        // beatValuesAreTrustworthy is written as !(f < MIN) precisely so NaN lands on TRUE — "not
        // measured" must not be silently refused. This line uses the same `<` for the same reason.
        // Rewriting it as `f >= MIN` would read identically for every real number and flip NaN to
        // "refused", diverging from the gate it reports on.
        XCTAssertEqual(
            IntelligenceEngine.respRateLogLine(day: "2026-08-26", respRateBpm: nil,
                                               beatAccurate: Double.nan, rrIntegrity: "plausible"),
            "resp day=2026-08-26 rpm=nil beatAccurate=NaN>=0.50 rrIntegrity=plausible"
            + " — gate passed, cause is elsewhere"
        )
    }
}
