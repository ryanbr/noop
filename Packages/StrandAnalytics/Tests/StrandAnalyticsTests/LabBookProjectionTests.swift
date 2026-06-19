import XCTest
@testable import StrandAnalytics

/// Pure-logic tests for the Lab Book projection. The fixtures here are mirrored
/// byte-for-byte by the Android twin (LabBookProjectionTest.kt) so the same readings
/// produce identical daily projections and windowed pairs on both platforms.
final class LabBookProjectionTests: XCTestCase {

    private func r(_ key: String, _ day: String, _ value: Double, _ takenAt: Double) -> LabReading {
        LabReading(markerKey: key, day: day, value: value, takenAtEpoch: takenAt)
    }

    // MARK: - daily fold: latest-per-day

    func testProjectLatestPerDay() {
        // Two LDL readings the same day; later takenAt wins. A third on another day.
        let readings = [
            r("ldl", "2026-01-10", 3.4, 1_736_500_000),
            r("ldl", "2026-01-10", 3.0, 1_736_590_000),   // later same day
            r("ldl", "2026-03-10", 2.8, 1_741_600_000),
        ]
        let proj = LabBookProjection.project(readings, fold: .latest)
        XCTAssertEqual(proj, [
            ProjectedPoint(markerKey: "ldl", day: "2026-01-10", value: 3.0),
            ProjectedPoint(markerKey: "ldl", day: "2026-03-10", value: 2.8),
        ])
    }

    // MARK: - daily fold: mean-per-day

    func testProjectMeanPerDay() {
        let readings = [
            r("bp_systolic", "2026-02-01", 120, 1_738_400_000),
            r("bp_systolic", "2026-02-01", 130, 1_738_410_000),   // same day → mean 125
            r("bp_systolic", "2026-02-02", 118, 1_738_490_000),
        ]
        let proj = LabBookProjection.project(readings, fold: .mean)
        XCTAssertEqual(proj, [
            ProjectedPoint(markerKey: "bp_systolic", day: "2026-02-01", value: 125),
            ProjectedPoint(markerKey: "bp_systolic", day: "2026-02-02", value: 118),
        ])
    }

    // MARK: - deterministic ordering across markers

    func testProjectSortsByMarkerThenDay() {
        let readings = [
            r("hdl", "2026-03-10", 1.4, 3),
            r("ldl", "2026-01-10", 3.4, 1),
            r("hdl", "2026-01-10", 1.2, 2),
        ]
        let proj = LabBookProjection.project(readings, fold: .latest)
        XCTAssertEqual(proj.map { "\($0.markerKey)@\($0.day)" },
                       ["hdl@2026-01-10", "hdl@2026-03-10", "ldl@2026-01-10"])
    }

    // MARK: - BP pair: two distinct keys project independently

    func testBpPairProjectsTwoKeys() {
        let readings = [
            r(LabBookProjection.bpSystolicKey, "2026-02-01", 122, 1),
            r(LabBookProjection.bpDiastolicKey, "2026-02-01", 78, 1),
        ]
        let proj = LabBookProjection.project(readings, fold: .latest)
        XCTAssertEqual(proj, [
            ProjectedPoint(markerKey: "bp_diastolic", day: "2026-02-01", value: 78),
            ProjectedPoint(markerKey: "bp_systolic", day: "2026-02-01", value: 122),
        ])
    }

    // MARK: - windowed pairing (trailing 14d, inclusive of D)

    func testWindowedPairTrailingMean() {
        // One marker reading on 2026-01-15. Wearable RHR spread over the prior fortnight.
        // Window = 3 days for an easy hand check: [2026-01-13, 14, 15].
        let marker = [(day: "2026-01-15", value: 3.1)]
        let wearable = [
            (day: "2026-01-10", value: 60.0),  // OUTSIDE the 3-day window
            (day: "2026-01-13", value: 50.0),
            (day: "2026-01-14", value: 52.0),
            (day: "2026-01-15", value: 54.0),
        ]
        let pairs = LabBookProjection.pairMarkerToWearable(marker: marker, wearable: wearable, windowDays: 3)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].day, "2026-01-15")
        XCTAssertEqual(pairs[0].markerValue, 3.1, accuracy: 1e-9)
        XCTAssertEqual(pairs[0].wearableMean, (50.0 + 52.0 + 54.0) / 3.0, accuracy: 1e-9)  // 52.0
        XCTAssertEqual(pairs[0].wearableN, 3)
    }

    func testWindowedPairDropsNoCoverageDay() {
        // Marker on a day with NO wearable point inside the trailing window → dropped.
        let marker = [
            (day: "2026-01-15", value: 3.1),   // covered
            (day: "2026-06-01", value: 2.9),   // no wearable anywhere near → dropped
        ]
        let wearable = [
            (day: "2026-01-14", value: 52.0),
            (day: "2026-01-15", value: 54.0),
        ]
        let pairs = LabBookProjection.pairMarkerToWearable(marker: marker, wearable: wearable, windowDays: 14)
        XCTAssertEqual(pairs.map { $0.day }, ["2026-01-15"], "no-coverage reading dropped")
    }

    func testWindowedPairWindowWidths() {
        // Same data, widths 7/14/30 give different trailing means.
        let marker = [(day: "2026-02-01", value: 100.0)]
        let wearable = [
            (day: "2026-01-05", value: 10.0),  // 27 days back → only in width 30
            (day: "2026-01-20", value: 20.0),  // 12 days back → in 14 and 30
            (day: "2026-01-29", value: 30.0),  //  3 days back → in 7, 14, 30
            (day: "2026-02-01", value: 40.0),  //  same day    → all widths
        ]
        let w7 = LabBookProjection.pairMarkerToWearable(marker: marker, wearable: wearable, windowDays: 7)
        XCTAssertEqual(w7[0].wearableMean, (30.0 + 40.0) / 2.0, accuracy: 1e-9)   // 35
        XCTAssertEqual(w7[0].wearableN, 2)

        let w14 = LabBookProjection.pairMarkerToWearable(marker: marker, wearable: wearable, windowDays: 14)
        XCTAssertEqual(w14[0].wearableMean, (20.0 + 30.0 + 40.0) / 3.0, accuracy: 1e-9)  // 30
        XCTAssertEqual(w14[0].wearableN, 3)

        let w30 = LabBookProjection.pairMarkerToWearable(marker: marker, wearable: wearable, windowDays: 30)
        XCTAssertEqual(w30[0].wearableMean, (10.0 + 20.0 + 30.0 + 40.0) / 4.0, accuracy: 1e-9)  // 25
        XCTAssertEqual(w30[0].wearableN, 4)
    }

    // MARK: - pairs feed CorrelationEngine.pearson unchanged

    func testCorrelationInputFeedsPearson() {
        // Four marker readings, each paired to a same-day wearable value (window 1).
        // x = marker, y = wearable. Perfect positive line y = 10x → r = 1.
        let marker = [
            (day: "2026-01-01", value: 1.0),
            (day: "2026-01-08", value: 2.0),
            (day: "2026-01-15", value: 3.0),
            (day: "2026-01-22", value: 4.0),
        ]
        let wearable = [
            (day: "2026-01-01", value: 10.0),
            (day: "2026-01-08", value: 20.0),
            (day: "2026-01-15", value: 30.0),
            (day: "2026-01-22", value: 40.0),
        ]
        let pairs = LabBookProjection.pairMarkerToWearable(marker: marker, wearable: wearable, windowDays: 1)
        XCTAssertEqual(pairs.count, 4)
        let corr = CorrelationEngine.pearson(LabBookProjection.correlationInput(pairs))
        XCTAssertNotNil(corr)
        XCTAssertEqual(corr!.n, 4)
        XCTAssertEqual(corr!.r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(corr!.slope, 10.0, accuracy: 1e-9)
    }
}
