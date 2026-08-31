import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The Effort score's funnel line — the trace `StrainScorer` had none of.
///
/// Twin of the Kotlin `EffortScoreFunnelTest`. The expected strings are the Kotlin ones: these two lines
/// exist so an Android and an Apple log of the same day compare directly, so asserting each side against
/// itself would prove only that each is self-consistent.
final class EffortScoreFunnelTests: XCTestCase {

    func testACalmDayReportsTheZeroItMeasured() {
        XCTAssertEqual(
            StrainScorer.scoreFunnelLine(day: "2026-08-31", hrSamples: 39339, enough: true,
                                         maxHR: 185.0, maxHRProvided: true, restingHR: 58.0,
                                         method: .edwards, trimp: 0.0, strain: 0.0),
            "effort score day=2026-08-31 hr=39339 enough=true hrMax=185.0(provided) rhr=58.0"
                + " reserve=127.0 method=edwards trimp=0.0 strain=0.0"
        )
    }

    /// The distinction the ring cannot show. A refusal and a genuine zero both render as "0"; only the
    /// line says which happened, and n/a is what makes the refusal legible.
    func testARefusalIsNotAZero() {
        XCTAssertEqual(
            StrainScorer.scoreFunnelLine(day: "2026-08-31", hrSamples: 12, enough: false,
                                         maxHR: 185.0, maxHRProvided: false, restingHR: 58.0,
                                         method: .edwards, trimp: nil, strain: nil),
            "effort score day=2026-08-31 hr=12 enough=false hrMax=185.0(default) rhr=58.0"
                + " reserve=127.0 method=edwards trimp=n/a strain=n/a"
        )
    }

    /// The hook must cost nothing when nobody is watching, and must not fire at view refresh rate: unlike
    /// the Kotlin twin this scorer is memoized because the Today view re-reads it on every live-HR tick.
    func testNoDiagSinkMeansNoLine() {
        let hr = (0..<5).map { HRSample(ts: 1_700_000_000 + $0 * 60, bpm: 60) }
        var emitted: [String] = []
        XCTAssertNil(StrainScorer.strain(hr))
        XCTAssertNil(StrainScorer.strain(hr, diag: { emitted.append($0) }, day: "2026-08-31"))
        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted[0].hasPrefix("effort score day=2026-08-31 "), emitted[0])
    }
}
