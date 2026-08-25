import XCTest
@testable import Strand

/// The readings table under a series-backed vital detail (task #8) — Swift twin of Android's
/// `VitalReadingsTableTest`. Pins the pure projection `vitalReadingRows` the MetricDetailView table
/// renders: rows and the "N readings" caption derive from the SAME windowed list (so their counts can't
/// disagree), rows are NEWEST-FIRST, each raw source id resolves through the shared
/// `TodayView.provenanceDisplayLabel` (strap → "WHOOP", Health Connect → "Health Connect", Apple Health →
/// "Apple Health", the "-noop" sibling → "On-device"), and each value reuses the model's own formatter +
/// unit. Blood Oxygen (SpO2) is the acceptance case.
final class VitalReadingsTableTests: XCTestCase {

    private let strap = Repository.whoopSource                  // "my-whoop"
    private let healthConnect = Repository.healthConnectSource  // "health-connect"
    private let appleHealth = Repository.appleHealthSource      // "apple-health"

    /// A fixed "now" long after the sample January-2026 readings, so none resolve as Today/Yesterday.
    private let now = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!

    /// Blood Oxygen: %-formatted, ascending readings from three different sources — a strap reading, a
    /// Health Connect import (e.g. a Galaxy Watch), and an Apple Health import.
    private func spo2Readings() -> [VitalReading] {
        [
            VitalReading(day: "2026-01-01", value: 96, source: strap),
            VitalReading(day: "2026-01-02", value: 95, source: healthConnect),
            VitalReading(day: "2026-01-03", value: 97, source: appleHealth),
        ]
    }
    private func spo2Format(_ v: Double) -> String { String(format: "%.0f", v) }

    func testRowCountEqualsReadingsCount() {
        let rows = vitalReadingRows(readings: spo2Readings(), unit: "%", strapDeviceId: strap,
                                    now: now, format: spo2Format)
        XCTAssertEqual(rows.count, spo2Readings().count)
    }

    func testRowsAreNewestFirst() {
        let rows = vitalReadingRows(readings: spo2Readings(), unit: "%", strapDeviceId: strap,
                                    now: now, format: spo2Format)
        // Ascending input (01 → 03) must render descending (03 → 01).
        XCTAssertEqual(rows.map(\.time), ["3 Jan", "2 Jan", "1 Jan"])
        XCTAssertEqual(rows.first?.value, "97 %")   // the newest reading leads
    }

    func testSourceLabelsResolvePerSample() {
        let rows = vitalReadingRows(readings: spo2Readings(), unit: "%", strapDeviceId: strap,
                                    now: now, format: spo2Format)
        // Newest-first, so: Apple Health (03), Health Connect (02), Whoop strap (01).
        XCTAssertEqual(rows.map(\.source), ["Apple Health", "Health Connect", "WHOOP"])
    }

    func testComputedStrapSiblingReadsOnDevice() {
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-01-04", value: 55, source: strap + "-noop")],
            unit: "yrs", strapDeviceId: strap, now: now, format: { String(format: "%.0f", $0) }
        )
        XCTAssertEqual(rows.first?.source, "On-device")
    }

    /// #103/queue-11a follow-up: a spo2 candidate-fallback row (see `spo2CandidateAttributionSource`)
    /// must resolve to "strap estimate (unverified)" — the SAME caption every other candidate-fallback
    /// surface uses — never a device name, which would misrepresent an unvalidated estimate as a
    /// calibrated reading.
    func testSpo2CandidateSourceReadsStrapEstimateUnverified() {
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-08-24", value: 97, source: spo2CandidateAttributionSource)],
            unit: "%", strapDeviceId: strap, now: now, format: spo2Format
        )
        XCTAssertEqual(rows.first?.source, "strap estimate (unverified)")
    }

    func testValueReusesModelFormatAndUnit() {
        // The row value is the model's own formatter applied to the reading, with the unit appended —
        // 41.7 ms formats (%.0f) to "42 ms".
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-01-01", value: 41.7, source: strap)],
            unit: "ms", strapDeviceId: strap, now: now, format: { String(format: "%.0f", $0) }
        )
        XCTAssertEqual(rows.first?.value, "42 ms")
    }

    func testUnitlessMetricLeavesNoTrailingSpace() {
        // Vitality has an empty unit; the value must not carry a dangling space.
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-01-01", value: 72, source: strap + "-noop")],
            unit: "", strapDeviceId: strap, now: now, format: { String(format: "%.0f", $0) }
        )
        XCTAssertEqual(rows.first?.value, "72")
    }
}
