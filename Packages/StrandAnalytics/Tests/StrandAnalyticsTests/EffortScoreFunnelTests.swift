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
                + " reserve=127.0 method=edwards trimp=0.0 strain=0.0 zones=n/a"
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
                + " reserve=127.0 method=edwards trimp=n/a strain=n/a zones=n/a"
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

    // MARK: - Per-zone minutes (#2438)

    /// Sample series whose bpm values straddle every Edwards threshold from BOTH sides, one minute apart
    /// so each reading is credited exactly one minute. The expected list is shared with the Kotlin twin.
    private static let zoneProbe: [Int] = [60, 60, 60, 119, 120, 131, 132, 143, 144, 155, 156, 167, 168]

    private func probeSamples() -> [HRSample] {
        Self.zoneProbe.enumerated().map { HRSample(ts: 1_700_000_000 + $0.offset * 60, bpm: $0.element) }
    }

    /// Every threshold pinned from both sides: 119 against 120, 131 against 132, and so on. A shift of one
    /// zone in either direction moves at least two buckets, and an off-by-one in the index would empty z0.
    func testZoneMinutesBucketsEveryBoundaryFromBothSides() {
        let hr = probeSamples()
        let durations = StrainScorer.sampleDurationsMinutes(hr)
        XCTAssertEqual(StrainScorer.zoneMinutes(hr, restingHR: 60, hrReserve: 120, durations: durations),
                       [4.0, 2.0, 2.0, 2.0, 2.0, 1.0])
    }

    /// The buckets partition exactly the duration TRIMP integrates over, so a reader can check the two
    /// against each other. Credited time, not wall-clock wear: dropouts are clamped before they get here.
    func testZoneMinutesPartitionTheCreditedDuration() {
        let hr = probeSamples()
        let durations = StrainScorer.sampleDurationsMinutes(hr)
        let zones = StrainScorer.zoneMinutes(hr, restingHR: 60, hrReserve: 120, durations: durations)
        XCTAssertEqual(zones.reduce(0, +), durations.reduce(0, +), accuracy: 1e-9)
    }

    /// z0 is the whole point: Edwards scores sub-50 %HRR time as zero, so a day spent entirely below
    /// zone 1 has TRIMP 0 and is indistinguishable from an unworn day in every line NOOP emitted before.
    func testTimeBelowZoneOneIsVisibleEvenThoughItScoresZero() {
        let hr = (0..<10).map { HRSample(ts: 1_700_000_000 + $0 * 60, bpm: 70) }
        let durations = StrainScorer.sampleDurationsMinutes(hr)
        let zones = StrainScorer.zoneMinutes(hr, restingHR: 60, hrReserve: 120, durations: durations)
        XCTAssertEqual(StrainScorer.edwardsTRIMP(hr, restingHR: 60, hrReserve: 120, durations: durations), 0.0)
        XCTAssertEqual(zones[0], 10.0)
        XCTAssertEqual(Array(zones[1...]), [0.0, 0.0, 0.0, 0.0, 0.0])
    }

    /// The rendered field, byte for byte against the Kotlin twin.
    func testTheLineCarriesSixZoneFields() {
        let line = StrainScorer.scoreFunnelLine(day: "2026-08-31", hrSamples: 13, enough: true,
                                                maxHR: 180.0, maxHRProvided: true, restingHR: 60.0,
                                                method: .edwards, trimp: 26.0, strain: 40.0,
                                                zoneMinutes: [4.0, 2.0, 2.0, 2.0, 2.0, 1.0])
        XCTAssertEqual(
            line,
            "effort score day=2026-08-31 hr=13 enough=true hrMax=180.0(provided) rhr=60.0"
                + " reserve=120.0 method=edwards trimp=26.0 strain=40.0"
                + " z0=4.0 z1=2.0 z2=2.0 z3=2.0 z4=2.0 z5=1.0"
        )
    }

    /// A malformed list is refused rather than rendered short. Six zeros would read as a real day spent
    /// entirely below zone 1, which is a measurement this line must never invent.
    func testAWrongLengthListRendersAsNotAvailable() {
        let line = StrainScorer.scoreFunnelLine(day: "2026-08-31", hrSamples: 13, enough: true,
                                                maxHR: 180.0, maxHRProvided: true, restingHR: 60.0,
                                                method: .edwards, trimp: 26.0, strain: 40.0,
                                                zoneMinutes: [1.0, 2.0])
        XCTAssertTrue(line.hasSuffix(" zones=n/a"), line)
    }
}
