import XCTest
@testable import WhoopStore

/// #2252: the ticks×10 defect (#2239) filed whole sessions in the past, and the store keeps no
/// ring-time, so nothing there can say which rows they were. The decoded sidecars keep both axes, so
/// the epoch each row implies (`utc - ringTs/10`) separates a mis-anchored session from an honest one.
///
/// Kotlin twin: `OuraRingEpochScanTest.kt`.
final class OuraRingEpochScanTests: XCTestCase {

    /// The ring really runs at 9.94 to 10.25 ticks per second, so a correctly anchored session's implied
    /// epoch DRIFTS as `ringTs/10` accumulates error. 2.5% over a fortnight is about eight hours.
    private func session(bootUnix: Int, startTicks: UInt32, count: Int,
                         tickRate: Double = 10.25, shiftSeconds: Int = 0) -> [(ringTs: UInt32, utc: Int)] {
        (0..<count).map { i in
            let rt = startTicks + UInt32(i * 3_000)
            return (rt, bootUnix + Int(Double(rt) / tickRate) - shiftSeconds)
        }
    }

    /// One boot stays one cluster even though dividing by 10 drifts hours across a fortnight. A tolerance
    /// tight enough to split it would report the ring's own tick rate as corruption.
    func testDriftWithinOneBootStaysOneCluster() {
        let rows = session(bootUnix: 1_789_000_000, startTicks: 3_000, count: 400)
        XCTAssertEqual(OuraRingEpochScan.cluster(rows).count, 1)
    }

    /// The #2239 shape: a session anchored as seconds×10 implies an epoch `0.9 × anchorTicks` earlier,
    /// which for that ring was 41.7 days. It must fall out as its OWN cluster, and its rows must be the
    /// ones filed in the past.
    func testAnX10AnchoredSessionSeparatesFromTheHonestOne() {
        let boot = 1_789_000_000
        let anchorTicks = 4_006_498
        let shift = Int(0.9 * Double(anchorTicks))
        let rows = session(bootUnix: boot, startTicks: 3_000, count: 300)
            + session(bootUnix: boot, startTicks: UInt32(anchorTicks), count: 50, shiftSeconds: shift)

        let clusters = OuraRingEpochScan.cluster(rows)

        XCTAssertEqual(clusters.count, 2, "one honest boot and one mis-anchored session")
        XCTAssertEqual(clusters[0].rows, 300, "newest epoch first: the honest session")
        XCTAssertEqual(clusters[1].rows, 50)
        let gap = clusters[0].epochUnix - clusters[1].epochUnix
        XCTAssertEqual(Double(gap) / 86_400, 41.7, accuracy: 0.5,
                       "the gap IS the defect's signature: 0.9 x anchorTicks seconds")
        XCTAssertLessThan(clusters[1].lastStoredUtc, clusters[0].firstStoredUtc,
                          "the mis-anchored rows are the ones filed in the past")
    }

    /// A healthy ring says nothing. An absent line is what keeps a healthy report byte-unchanged by this
    /// diagnostic existing, which is the reason to return nil rather than "clusters=1".
    func testAHealthyRingProducesNoLine() {
        let rows = session(bootUnix: 1_789_000_000, startTicks: 3_000, count: 50)
        XCTAssertNil(OuraRingEpochScan.summaryLine(OuraRingEpochScan.cluster(rows)))
        XCTAssertNil(OuraRingEpochScan.summaryLine([]))
    }

    /// The line carries the gap, the row counts and the stored span, which is what a reader needs to tell
    /// a mis-anchored session from a restart without this code deciding for them.
    func testTheLineCarriesTheGapAndTheStoredSpan() {
        let boot = 1_789_000_000
        let anchorTicks = 4_006_498
        let rows = session(bootUnix: boot, startTicks: 3_000, count: 300)
            + session(bootUnix: boot, startTicks: UInt32(anchorTicks), count: 50,
                      shiftSeconds: Int(0.9 * Double(anchorTicks)))

        let line = OuraRingEpochScan.summaryLine(OuraRingEpochScan.cluster(rows))

        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("ouraRingEpoch clusters=2 "), line!)
        XCTAssertTrue(line!.contains("rows=300"), line!)
        XCTAssertTrue(line!.contains("rows=50"), line!)
        // "41." rather than "41.7": each cluster's epoch is its MEDIAN, and the two runs drift by
        // different amounts, so the printed decimal moves. The numeric gap is pinned to 0.9 x anchorTicks
        // with a tolerance in `testAnX10AnchoredSessionSeparatesFromTheHonestOne`; this asserts the line
        // CARRIES it, not that the formatter rounds a particular way.
        XCTAssertTrue(line!.contains("gapDays=41."), "the ticks x10 signature: \(line!)")
        XCTAssertTrue(line!.contains("stored="), line!)
    }

    /// A row with no ring-time cannot imply an epoch. Including it would invent one at its stored `utc`
    /// and manufacture a cluster out of nothing.
    func testUnanchoredRowsAreDroppedRatherThanGivenAnEpoch() {
        XCTAssertTrue(OuraRingEpochScan.cluster([(0, 1_789_000_000), (0, 1_789_000_060)]).isEmpty)
        let mixed: [(ringTs: UInt32, utc: Int)] = [(0, 1_789_000_000), (3_000, 1_789_000_300)]
        XCTAssertEqual(OuraRingEpochScan.cluster(mixed).map(\.rows), [1])
    }

    /// Two clusters sharing a median epoch must come back in the SAME order on both platforms. Swift's
    /// `sorted(by:)` is not stable and Kotlin's `sortedByDescending` is, so ordering on the epoch alone
    /// would let the two disagree about which cluster `summaryLine` calls "newest".
    func testClustersWithTheSameEpochAreOrderedDeterministically() {
        // Two runs far enough apart to be separate clusters, contrived to share a median epoch.
        var rows: [(ringTs: UInt32, utc: Int)] = []
        let epoch = 1_789_000_000
        for i in 0..<5 { rows.append((UInt32(3_000 + i * 60), epoch + (3_000 + i * 60) / 10)) }
        for i in 0..<3 { rows.append((UInt32(9_000_000 + i * 60), epoch + (9_000_000 + i * 60) / 10)) }

        let once = OuraRingEpochScan.cluster(rows)
        let again = OuraRingEpochScan.cluster(rows.reversed())

        XCTAssertEqual(once, again, "order in must not change order out")
        if once.count > 1 {
            XCTAssertGreaterThanOrEqual(once[0].rows, once[1].rows,
                                        "an epoch tie breaks on row count, identically on both platforms")
        }
    }

    func testEmptyInputYieldsNoClusters() {
        XCTAssertTrue(OuraRingEpochScan.cluster([]).isEmpty)
    }

    /// Order in, order out: the sidecars are appended per connection and may be concatenated in any
    /// order, so the result must depend on the values rather than on how they arrived.
    func testResultDoesNotDependOnInputOrder() {
        let boot = 1_789_000_000
        let rows = session(bootUnix: boot, startTicks: 3_000, count: 40)
            + session(bootUnix: boot, startTicks: 4_006_498, count: 20, shiftSeconds: 3_605_848)
        XCTAssertEqual(OuraRingEpochScan.cluster(rows), OuraRingEpochScan.cluster(rows.reversed()))
    }

    /// The gap that closes a cluster is measured against the PREVIOUS row, not the run's first, so a long
    /// steady drift stays one cluster while a genuine jump splits.
    func testASteadyDriftPastToleranceStillClustersAsOne() {
        // Each step is an hour of implied-epoch drift: well inside the six-hour gap, far past it in total.
        // Hoisted rather than written inline: the one-line form exceeds the type-checker's budget.
        var rows: [(ringTs: UInt32, utc: Int)] = []
        let boot = 1_789_000_000
        for i in 0..<12 {
            let ticks: Int = 3_000 + i * 3_000
            let driftSeconds: Int = i * 3_600
            let utc: Int = boot + ticks / 10 + driftSeconds
            rows.append((UInt32(ticks), utc))
        }
        XCTAssertEqual(OuraRingEpochScan.cluster(rows).count, 1)
    }
}
