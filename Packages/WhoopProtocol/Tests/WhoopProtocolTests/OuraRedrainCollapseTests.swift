import XCTest
@testable import WhoopProtocol

/// A ring record served twice is recognised by the record it came in, not by its timestamps (#2456).
///
/// History is re-served whenever it is refetched: after a link drops mid-drain, and also after a night
/// has already drained, which no resume cursor prevents. Each connection anchors on its own SyncTime, so
/// the second copy lands a second or two off the first, misses the row key, and is stored again. The
/// night's coverage then rises above 1 and its HRV is refused.
final class OuraRedrainCollapseTests: XCTestCase {

    /// One banked 0x60 record: six intervals stamped on a single second.
    private func record(_ ts: Int, _ rr: [Int], channel: RRSourceChannel = .ibiAmplitude) -> [RRInterval] {
        rr.enumerated().map { RRInterval(ts: ts, rrMs: $1, srcChannel: channel, ord: $0, seq: 0) }
    }

    private let six = [531, 570, 751, 904, 1000, 1002]

    func testARecordServedAgainOneSecondLaterIsCollapsed() {
        let beats = record(1_790_223_482, six) + record(1_790_223_483, six)
        let kept = OuraRedrainCollapse.withoutRedrainedRuns(beats)
        XCTAssertEqual(6, kept.count)
        XCTAssertEqual(Array(repeating: 1_790_223_482, count: 6), kept.map(\.ts))
    }

    /// The report's shape: the drop lands two seconds out, not one.
    func testTwoSecondsOutIsAlsoCollapsed() {
        let beats = record(100, six) + record(102, six)
        XCTAssertEqual(6, OuraRedrainCollapse.withoutRedrainedRuns(beats).count)
    }

    /// Beyond the window the run is a different record, not a copy.
    func testAnIdenticalRunFurtherOutIsKept() {
        let beats = record(100, six) + record(105, six)
        XCTAssertEqual(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).count)
    }

    /// Compared against the last run KEPT, so three copies collapse to one and not to two.
    func testARecordServedThreeTimesCollapsesToOne() {
        let beats = record(100, six) + record(101, six) + record(102, six)
        let kept = OuraRedrainCollapse.withoutRedrainedRuns(beats)
        XCTAssertEqual(6, kept.count)
        XCTAssertEqual(Array(repeating: 100, count: 6), kept.map(\.ts))
    }

    /// #163: equal successive beats are physiological. A run CONTAINING them still collapses as a run,
    /// but nothing about equal neighbours alone causes a drop.
    func testEqualSuccessiveBeatsAreNotThemselvesADuplicate() {
        let flat = record(100, [800, 800, 800, 800, 800, 800])
        XCTAssertEqual(6, OuraRedrainCollapse.withoutRedrainedRuns(flat).count)
    }

    /// A short coincidental repeat is left alone: on a clean night 2.5% of beats already have an equal
    /// neighbour a second away, so single beats and pairs are not evidence of a re-serve.
    func testShortCoincidentalRepeatsAreKept() {
        let beats = record(100, [820, 830]) + record(101, [820, 830])
        XCTAssertEqual(4, OuraRedrainCollapse.withoutRedrainedRuns(beats).count)
    }

    /// WHOOP transports are never touched; this is an Oura re-serve.
    func testWhoopChannelsAreUntouched() {
        let beats = record(100, six, channel: .whoop5Realtime) + record(101, six, channel: .whoop5Realtime)
        XCTAssertEqual(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).count)
    }

    /// Two channels reporting the same values are two measurements, not one served twice.
    func testTheSameRunOnADifferentChannelIsIndependent() {
        let beats = record(100, six, channel: .ibiAmplitude) + record(101, six, channel: .greenQuality)
        XCTAssertEqual(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).count)
    }

    /// Untagged rows carry no channel, so nothing identifies them as a ring record.
    func testUntaggedRowsAreKept() {
        let beats = (0..<6).map { RRInterval(ts: 100, rrMs: six[$0], srcChannel: nil, ord: $0, seq: 0) }
            + (0..<6).map { RRInterval(ts: 101, rrMs: six[$0], srcChannel: nil, ord: $0, seq: 0) }
        XCTAssertEqual(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).count)
    }

    /// A different ORDER is a different record, even with the same values.
    func testAReorderedRunIsNotACopy() {
        let beats = record(100, six) + record(101, six.reversed())
        XCTAssertEqual(12, OuraRedrainCollapse.withoutRedrainedRuns(beats).count)
    }

    /// Nothing is reordered or rewritten; only whole duplicate runs go.
    func testOrderAndContentOfKeptBeatsAreUnchanged() {
        let first = record(100, six)
        let other = record(101, [611, 640, 655, 690, 700, 710])
        let beats = first + other + record(102, six.map { $0 })
        let kept = OuraRedrainCollapse.withoutRedrainedRuns(beats)
        XCTAssertEqual(first + other, kept)
    }

    /// A night with nothing re-served is returned unchanged, so the collapse costs nothing normally.
    func testACleanNightIsUnchanged() {
        var beats: [RRInterval] = []
        for second in 0..<600 {
            beats += record(1_000 + second, (0..<6).map { 700 + (second * 7 + $0 * 13) % 400 })
        }
        XCTAssertEqual(beats, OuraRedrainCollapse.withoutRedrainedRuns(beats))
    }
}
