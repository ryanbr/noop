import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HRZonesTests: XCTestCase {

    func testTanakaMaxHR() {
        XCTAssertEqual(HRZones.tanakaMaxHR(age: 30), 187.0, accuracy: 1e-9)
        XCTAssertEqual(HRZones.tanakaMaxHR(age: 40), 180.0, accuracy: 1e-9)
    }

    func testZonesFromAge() {
        let zs = HRZones.zones(age: 30)
        XCTAssertEqual(zs.source, "tanaka")
        XCTAssertEqual(zs.maxHR, 187.0, accuracy: 1e-9)
        XCTAssertEqual(zs.zones.count, 5)
        // Zone 1 lower = 50% of 187 = 93.5; Zone 5 upper = 187.
        XCTAssertEqual(zs.zones[0].lower, 93.5, accuracy: 1e-9)
        XCTAssertEqual(zs.zones[4].upper, 187.0, accuracy: 1e-9)
    }

    func testManualOverride() {
        let zs = HRZones.zones(age: 30, maxHROverride: 200)
        XCTAssertEqual(zs.source, "manual")
        XCTAssertEqual(zs.maxHR, 200.0, accuracy: 1e-9)
        XCTAssertEqual(zs.zones[0].lower, 100.0, accuracy: 1e-9)  // 50% of 200
    }

    func testZonesPartitionContiguously() {
        // Each zone's upper edge must equal the next zone's lower edge (no gaps/overlap).
        let zs = HRZones.zones(maxHR: 200)
        for i in 0..<4 {
            XCTAssertEqual(zs.zones[i].upper, zs.zones[i + 1].lower, accuracy: 1e-9)
        }
    }

    func testZoneNumberForBPM() {
        let zs = HRZones.zones(maxHR: 200)  // edges: 100,120,140,160,180,200
        XCTAssertEqual(zs.zoneNumber(forBPM: 90), 0)    // below zone 1
        XCTAssertEqual(zs.zoneNumber(forBPM: 100), 1)   // zone 1 lower edge
        XCTAssertEqual(zs.zoneNumber(forBPM: 119), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 120), 2)
        XCTAssertEqual(zs.zoneNumber(forBPM: 150), 3)
        XCTAssertEqual(zs.zoneNumber(forBPM: 170), 4)
        XCTAssertEqual(zs.zoneNumber(forBPM: 185), 5)
        XCTAssertEqual(zs.zoneNumber(forBPM: 200), 5)   // top edge inclusive
        XCTAssertEqual(zs.zoneNumber(forBPM: 250), 5)   // above max still z5
    }

    func testCustomBPMBoundariesReplacePercentageEdges() {
        let zs = HRZones.zones(maxHR: 200, customLowerBounds: [95, 118, 142, 168, 184])
        XCTAssertEqual(zs.source, "custom")
        XCTAssertEqual(zs.zones.map(\.lower), [95, 118, 142, 168, 184])
        XCTAssertEqual(zs.zoneNumber(forBPM: 117), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 118), 2)
        XCTAssertEqual(zs.zoneNumber(forBPM: 167), 3)
        XCTAssertEqual(zs.zoneNumber(forBPM: 168), 4)
        XCTAssertEqual(zs.zoneNumber(forBPM: 184), 5)
        XCTAssertEqual(zs.zoneNumber(forBPM: 230), 5)
    }

    func testInvalidCustomBoundariesFallBackToDefaults() {
        let zs = HRZones.zones(maxHR: 200, customLowerBounds: [100, 120, 120, 160, 180])
        XCTAssertEqual(zs.source, "manual")
        XCTAssertEqual(zs.zones.map(\.lower), [100, 120, 140, 160, 180])
    }

    func testDefaultEditorBoundsPreserveIntegerClassification() {
        XCTAssertEqual(HRZones.defaultLowerBounds(maxHR: 187), [94, 113, 131, 150, 169])
    }

    func testTimeInZoneAccountsForAllTime() {
        let zs = HRZones.zones(maxHR: 200)  // edges 100/120/140/160/180/200
        // 1 Hz samples: 3 in z1 (110), 2 in z3 (150), 1 below (90).
        let hr = [
            HRSample(ts: 0, bpm: 110),
            HRSample(ts: 1, bpm: 110),
            HRSample(ts: 2, bpm: 110),
            HRSample(ts: 3, bpm: 150),
            HRSample(ts: 4, bpm: 150),
            HRSample(ts: 5, bpm: 90),
        ]
        let tiz = HRZones.timeInZone(hr, zoneSet: zs)
        // Each of the first 5 samples holds 1 s; tail (90 bpm) gets median gap (1 s).
        XCTAssertEqual(tiz.seconds(inZone: 1), 3.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.seconds(inZone: 3), 2.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.belowZone1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.seconds(inZone: 2), 0.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.total, 6.0, accuracy: 1e-9)
    }

    func testTimeInZoneEmpty() {
        let zs = HRZones.zones(maxHR: 200)
        let tiz = HRZones.timeInZone([], zoneSet: zs)
        XCTAssertEqual(tiz.total, 0.0)
    }

    func testTimeInZoneSortsDefensively() {
        let zs = HRZones.zones(maxHR: 200)
        // Out-of-order, evenly-spaced (1 s) input must sort then partition correctly:
        // ts 0,1,2 at 110 bpm (zone 1) → 3 s in zone 1 (each holds 1 s incl. the tail).
        let hr = [
            HRSample(ts: 2, bpm: 110),
            HRSample(ts: 0, bpm: 110),
            HRSample(ts: 1, bpm: 110),
        ]
        let tiz = HRZones.timeInZone(hr, zoneSet: zs)
        XCTAssertEqual(tiz.seconds(inZone: 1), 3.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.total, 3.0, accuracy: 1e-9)  // all time accounted for
    }

    func testTimeInZoneCapsHugePositiveGap() {
        let zs = HRZones.zones(maxHR: 200)
        // Three 1 Hz zone-1 samples (median gap 1 s), then one sample an HOUR later. The 3600 s
        // gap before the last sample must be capped at the median (1 s) — as the comment promises —
        // not credited in full, so one wear gap / sparse stretch can't blow up a bucket.
        let hr = [
            HRSample(ts: 0, bpm: 110),
            HRSample(ts: 1, bpm: 110),
            HRSample(ts: 2, bpm: 110),
            HRSample(ts: 3602, bpm: 110),
        ]
        let tiz = HRZones.timeInZone(hr, zoneSet: zs)
        XCTAssertLessThan(tiz.total, 10.0,
                          "a huge inter-sample gap must be capped at the median, not credited in full")
        XCTAssertEqual(tiz.seconds(inZone: 1), tiz.total, accuracy: 1e-9)  // all of it is zone 1
    }
}
