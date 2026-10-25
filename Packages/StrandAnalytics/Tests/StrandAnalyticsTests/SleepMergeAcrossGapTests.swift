import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Swift twin of `SleepMergeAcrossGapTest`.
///
/// `mergePeriods` absorbed a short run into its neighbour whatever the time between them. When
/// `buildRuns` had closed a run on a data gap, that moved the neighbour's edge across the whole gap. On a
/// real WHOOP 5.0 night, a few minutes of evening stillness before a charging gap of several hours were
/// folded into the night after it, the merged run was more than half HR gap, and the off-wrist backstop
/// dropped the night, including the hours that were worn.
final class SleepMergeAcrossGapTests: XCTestCase {

    private typealias P = SleepStager.Period

    /// `Period` is not Equatable, so runs are compared by stage and bounds.
    private func key(_ p: P) -> String { "\(p.stage) \(p.start)-\(p.end)" }

    // MARK: - mergePeriods

    /// A short run is not absorbed into a neighbour across a gap longer than `maxGapMin`. It joins the
    /// neighbour on its own side of the gap instead.
    func testAShortRunIsNotAbsorbedAcrossAGap() {
        let night = P(stage: "sleep", start: 8 * 3600, end: 13 * 3600)
        let out = SleepStager.mergePeriods([
            P(stage: "active", start: 0, end: 1800),
            P(stage: "sleep", start: 1801, end: 1801 + 8 * 60),
            night,
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].stage, "active")
        XCTAssertEqual(out[0].end, 1801 + 8 * 60, "the short run folds back into the run before the gap")
        XCTAssertEqual(key(out[1]), key(night), "the night's onset must not move back across the gap")
    }

    /// A short run with a gap on both sides is kept as it is.
    func testAShortRunIsolatedByGapsIsKept() {
        let short = P(stage: "sleep", start: 3 * 3600, end: 3 * 3600 + 8 * 60)
        let out = SleepStager.mergePeriods([
            P(stage: "active", start: 0, end: 1800),
            short,
            P(stage: "sleep", start: 8 * 3600, end: 13 * 3600),
        ])
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(key(out[1]), key(short))
    }

    /// A gap of exactly `maxGapMin` is not a data gap to `buildRuns`, so the merge still applies.
    func testAGapOfExactlyMaxGapStillMerges() {
        let gap = SleepStager.maxGapMin * 60
        let out = SleepStager.mergePeriods([
            P(stage: "sleep", start: 0, end: 600),
            P(stage: "sleep", start: 600 + gap, end: 600 + gap + 3600),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].start, 0)
    }

    /// Contiguous runs merge exactly as before: a short stir between two sleep runs is absorbed.
    func testContiguousRunsMergeAsBefore() {
        let out = SleepStager.mergePeriods([
            P(stage: "sleep", start: 0, end: 3600),
            P(stage: "active", start: 3601, end: 3601 + 300),
            P(stage: "sleep", start: 3902, end: 7200),
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].stage, "sleep")
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[0].end, 7200)
    }

    /// When only one neighbour is reachable, the short run joins that one.
    func testAShortRunJoinsTheReachableNeighbour() {
        let out = SleepStager.mergePeriods([
            P(stage: "sleep", start: 0, end: 3600),
            P(stage: "active", start: 3601, end: 3601 + 300),
            P(stage: "sleep", start: 3901 + 3 * 3600, end: 3901 + 6 * 3600),
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].end, 3901, "the short run folds back into the earlier run")
        XCTAssertEqual(out[1].start, 3901 + 3 * 3600, "the later run keeps its own onset")
    }

    /// A lone short run is still dropped, as before.
    func testALoneShortRunIsStillDropped() {
        XCTAssertTrue(SleepStager.mergePeriods([P(stage: "sleep", start: 0, end: 300)]).isEmpty)
    }

    // MARK: - end to end through detectSleep

    private let refMidnight = 1_749_513_600            // 2025-06-10 00:00:00 UTC
    private func at(_ min: Int) -> Int { refMidnight + min * 60 }

    private func stillG(_ fromMin: Int, _ toMin: Int) -> [GravitySample] {
        stride(from: at(fromMin), to: at(toMin), by: 60).map { GravitySample(ts: $0, x: 0, y: 0, z: 1.0) }
    }

    private func movingG(_ fromMin: Int, _ toMin: Int) -> [GravitySample] {
        stride(from: at(fromMin), to: at(toMin), by: 60).enumerated().map { i, t in
            i % 2 == 0 ? GravitySample(ts: t, x: 1.0, y: 0, z: 0)
                       : GravitySample(ts: t, x: 0, y: 1.0, z: 0)
        }
    }

    private func hr1Hz(_ fromMin: Int, _ toMin: Int, _ bpm: Int) -> [HRSample] {
        (at(fromMin) ..< at(toMin)).map { HRSample(ts: $0, bpm: bpm) }
    }

    /// The field shape: an active evening, a few still minutes, then no data at all for seven hours
    /// (the strap on its charger), then a worn five-hour night. Before the fix the still minutes were
    /// folded into the night, the run was mostly HR gap, and the off-wrist backstop dropped it.
    func testANightAfterAChargingGapIsKept() {
        // Minutes from midnight UTC on the day before: 17:00 active, 17:30 still, 17:38 gap.
        let evening = -7 * 60
        var grav = movingG(evening, evening + 30) + stillG(evening + 30, evening + 38)
        var hr = hr1Hz(evening, evening + 30, 90) + hr1Hz(evening + 30, evening + 38, 60)
        // 01:00 to 06:00 asleep, then 06:00 to 06:30 active.
        grav += stillG(60, 360) + movingG(360, 390)
        hr += hr1Hz(60, 360, 52) + hr1Hz(360, 390, 90)

        var lines: [String] = []
        let sessions = SleepStager.detectSleep(hr: hr, gravity: grav, traceSink: { lines.append($0) })

        XCTAssertEqual(sessions.count, 1, "the worn night must be kept.\n" + lines.joined(separator: "\n"))
        XCTAssertEqual(sessions.first?.start, at(60), "the night starts after the gap, not before it")
        XCTAssertFalse(lines.contains { $0.contains("gate=offWrist") },
                       "the off-wrist backstop must not see a run that spans the gap")
    }
}
