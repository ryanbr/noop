import XCTest
import WhoopStore
@testable import Strand

/// Pins the source-aware vital-sign resolution (PR#261): the field-by-field daily merge, the per-metric
/// source precedence (imported WHOOP > NOOP-computed > Apple Health), skin temp's deliberate exclusion of
/// Apple, the provenance captions, and the "latest day that has a value" fallback. All pure — no store.
final class VitalSourceResolutionTests: XCTestCase {
    func testMergeDailyFillsOnlyMissingImportedFields() {
        let imported = daily(
            day: "2026-06-12",
            totalSleepMin: 420,
            recovery: nil,
            strain: 8.4,
            spo2Pct: 97,
            skinTempDevC: nil,
            steps: nil
        )
        let computed = daily(
            day: "2026-06-12",
            totalSleepMin: 390,
            recovery: 82,
            strain: 12.6,
            spo2Pct: 95,
            skinTempDevC: 0.3,
            steps: 9_240
        )

        let merged = Repository.mergeDaily(imported: [imported], computed: [computed])

        XCTAssertEqual(merged.count, 1)
        // Imported non-nil fields win…
        XCTAssertEqual(merged[0].totalSleepMin, 420)
        XCTAssertEqual(merged[0].strain, 8.4)
        XCTAssertEqual(merged[0].spo2Pct, 97)
        // …and computed fills only the fields the import left nil.
        XCTAssertEqual(merged[0].recovery, 82)
        XCTAssertEqual(merged[0].skinTempDevC, 0.3)
        XCTAssertEqual(merged[0].steps, 9_240)
    }

    func testActivityFileStepsFillMissingStepDaysOnly() {
        let base = [
            daily(day: "2026-06-14", recovery: 70, steps: nil),
            daily(day: "2026-06-15", steps: 9000),
        ]
        let activity = [
            daily(day: "2026-06-14", steps: 1175),
            daily(day: "2026-06-15", steps: 2222),
            daily(day: "2026-06-16", steps: 3333),
        ]

        let merged = Repository.mergeActivityFileSteps(into: base, activity)

        XCTAssertEqual(merged.first { $0.day == "2026-06-14" }?.steps, 1175)
        XCTAssertEqual(merged.first { $0.day == "2026-06-15" }?.steps, 9000)
        XCTAssertEqual(merged.first { $0.day == "2026-06-16" }?.steps, 3333)
    }

    func testAppleHealthCanFillBloodOxygenWhenStrapSourcesAreMissing() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 98), source: .appleHealth)
            ],
            temperatureUnit: .celsius,
            // Pin the clock: these fixtures are dated 2026-06-12, and the carry is staleness-bounded
            // (`Baselines.vitalCarryDays`). Left to default to the real `Date()`, they only passed
            // because the carry used to be unbounded — the very defect under test elsewhere. They are
            // about SOURCE PRECEDENCE, so the day must sit inside the window for the resolution to be
            // what is being asserted.
            now: localNoon(day: "2026-06-13")
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 98)
        XCTAssertEqual(spo2?.source, .appleHealth)
        XCTAssertTrue(spo2?.stateCaption.contains("Apple Health") == true)
    }

    func testWhoopBloodOxygenWinsOverAppleHealthForSameDay() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 96), source: .whoopImport),
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 99), source: .appleHealth)
            ],
            temperatureUnit: .celsius,
            // Pin the clock: these fixtures are dated 2026-06-12, and the carry is staleness-bounded
            // (`Baselines.vitalCarryDays`). Left to default to the real `Date()`, they only passed
            // because the carry used to be unbounded — the very defect under test elsewhere. They are
            // about SOURCE PRECEDENCE, so the day must sit inside the window for the resolution to be
            // what is being asserted.
            now: localNoon(day: "2026-06-13")
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 96)
        XCTAssertEqual(spo2?.source, .whoopImport)
    }

    func testAppleHealthDoesNotFillSkinTemperature() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", skinTempDevC: 34.2), source: .appleHealth)
            ],
            temperatureUnit: .celsius,
            // Pin the clock: these fixtures are dated 2026-06-12, and the carry is staleness-bounded
            // (`Baselines.vitalCarryDays`). Left to default to the real `Date()`, they only passed
            // because the carry used to be unbounded — the very defect under test elsewhere. They are
            // about SOURCE PRECEDENCE, so the day must sit inside the window for the resolution to be
            // what is being asserted.
            now: localNoon(day: "2026-06-13")
        )

        let skin = readings.first { $0.key == "skin" }
        XCTAssertNil(skin?.value)
        XCTAssertNil(skin?.source)
    }

    func testComputedSkinTemperatureShowsComputedCaption() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", skinTempDevC: 0.2), source: .noopComputed)
            ],
            temperatureUnit: .celsius,
            // Pin the clock: these fixtures are dated 2026-06-12, and the carry is staleness-bounded
            // (`Baselines.vitalCarryDays`). Left to default to the real `Date()`, they only passed
            // because the carry used to be unbounded — the very defect under test elsewhere. They are
            // about SOURCE PRECEDENCE, so the day must sit inside the window for the resolution to be
            // what is being asserted.
            now: localNoon(day: "2026-06-13")
        )

        let skin = readings.first { $0.key == "skin" }
        XCTAssertEqual(skin?.value, 0.2)
        XCTAssertEqual(skin?.source, .noopComputed)
        // #622/#1224: computed skin temp is a ±°C deviation from the personal baseline, so its caption
        // reads "vs baseline" rather than the generic "NOOP computed" other computed vitals get.
        XCTAssertTrue(skin?.stateCaption.contains("vs baseline") == true)
    }

    func testVitalsFallBackToLatestHistoricalDayWhenTodayHasNoValue() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-11", respRateBpm: 15.2), source: .whoopImport),
                SourcedDailyMetric(metric: daily(day: "2026-06-12", respRateBpm: 16.1), source: .noopComputed)
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-06-13")
        )

        let resp = readings.first { $0.key == "resp" }
        XCTAssertEqual(resp?.day, "2026-06-12")
        XCTAssertEqual(resp?.value, 16.1)
        XCTAssertEqual(resp?.source, .noopComputed)
        XCTAssertEqual(BodyVitalSigns.latestDayLabel(readings), BodyVitalReading.dayLabel("2026-06-12"))
    }

    // MARK: - #103 SpO₂ candidate @82 fallback

    /// When the toggle is ON and no calibrated `spo2Pct` exists, the Blood O₂ tile falls back to the
    /// `spo2_candidate` mean from metricSeries, labelled "strap estimate (unverified)".
    func testSpo2CandidateFallsBackWhenNoCalibratedSpo2Pct() {
        UserDefaults.standard.set(true, forKey: PuffinExperiment.spo2CandidateDisplayKey)
        defer { UserDefaults.standard.set(false, forKey: PuffinExperiment.spo2CandidateDisplayKey) }

        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: nil), source: .noopComputed)
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-06-13"),
            spo2CandidateByDay: ["2026-06-12": 96.0]
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 96.0)
        XCTAssertEqual(spo2?.source, .noopComputed)
        XCTAssertTrue(spo2?.missingCaption.contains("strap estimate") == true)
    }

    /// When the toggle is OFF, the candidate is never surfaced even if data exists.
    func testSpo2CandidateNotSurfacedWhenToggleOff() {
        UserDefaults.standard.set(false, forKey: PuffinExperiment.spo2CandidateDisplayKey)

        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: nil), source: .noopComputed)
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-06-13"),
            spo2CandidateByDay: ["2026-06-12": 96.0]
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertNil(spo2?.value)
        XCTAssertNil(spo2?.source)
    }

    /// A calibrated `spo2Pct` always wins over the candidate — the candidate is a fallback, not a
    /// replacement.
    func testCalibratedSpo2PctWinsOverCandidate() {
        UserDefaults.standard.set(true, forKey: PuffinExperiment.spo2CandidateDisplayKey)
        defer { UserDefaults.standard.set(false, forKey: PuffinExperiment.spo2CandidateDisplayKey) }

        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-06-12", spo2Pct: 98), source: .whoopImport)
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-06-13"),
            spo2CandidateByDay: ["2026-06-12": 95.0]
        )

        let spo2 = readings.first { $0.key == "spo2" }
        XCTAssertEqual(spo2?.value, 98)
        XCTAssertEqual(spo2?.source, .whoopImport)
        // The calibrated caption, NOT the "strap estimate" one.
        XCTAssertFalse(spo2?.missingCaption.contains("strap estimate") == true)
    }

    // MARK: - Carry staleness

    /// THE REPORTED REGRESSION, end to end through the real resolver. A WHOOP CSV import ending
    /// 2026-07-30 kept the Health tab's Resp Rate tile reading "15.6 rpm" on 2026-08-13 — 14 days on,
    /// under a section headed "Latest", while the live device wrote no respiratory rate at all. The
    /// tile must fall to its honest empty state instead of presenting a fortnight-old import as a
    /// current measurement.
    func testStaleImportedRespiratoryRateNoLongerCarries() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-07-28", respRateBpm: 16.0), source: .whoopImport),
                SourcedDailyMetric(metric: daily(day: "2026-07-29", respRateBpm: 16.2), source: .whoopImport),
                SourcedDailyMetric(metric: daily(day: "2026-07-30", respRateBpm: 15.6), source: .whoopImport)
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-08-13")
        )

        let resp = readings.first { $0.key == "resp" }
        XCTAssertNil(resp?.value)
        XCTAssertNil(resp?.day)
        XCTAssertNil(resp?.source)
        XCTAssertEqual(resp?.banding.band, .noData)
        // The trail is HISTORICAL and deliberately survives — only the headline claims to be current.
        XCTAssertEqual(resp?.sparkline?.count, 3)
    }

    /// The carry still does its job: one missed night must not blank a tile.
    func testRecentRespiratoryRateStillCarries() {
        let readings = BodyVitalSigns.readings(
            sourceRows: [
                SourcedDailyMetric(metric: daily(day: "2026-08-12", respRateBpm: 14.1), source: .noopComputed)
            ],
            temperatureUnit: .celsius,
            now: localNoon(day: "2026-08-13")
        )

        let resp = readings.first { $0.key == "resp" }
        XCTAssertEqual(resp?.value, 14.1)
        XCTAssertEqual(resp?.day, "2026-08-12")
    }

    // MARK: - Fixtures

    private func daily(
        day: String,
        totalSleepMin: Double? = nil,
        recovery: Double? = nil,
        strain: Double? = nil,
        spo2Pct: Double? = nil,
        skinTempDevC: Double? = nil,
        respRateBpm: Double? = nil,
        steps: Int? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: recovery,
            strain: strain,
            exerciseCount: nil,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: respRateBpm,
            steps: steps,
            activeKcalEst: nil
        )
    }

    private func localNoon(day: String) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: parts[0],
            month: parts[1],
            day: parts[2],
            hour: 12
        ))!
    }
}
