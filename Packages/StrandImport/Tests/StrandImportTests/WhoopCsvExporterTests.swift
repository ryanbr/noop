import XCTest
import WhoopStore
@testable import StrandImport

/// THE round-trip contract: serialize with WhoopCsvExporter, re-parse with the REAL
/// WhoopExportImporter, assert field-level equality. Mirrors the Android WhoopCsvExporterTest so
/// the exported zip is re-importable by NOOP on either platform. `@testable` is needed because the
/// importer's `parse*` helpers and CSVTable are internal.
final class WhoopCsvExporterTests: XCTestCase {

    func testCyclesRoundTripThroughRealImporter() throws {
        // efficiency is stored as the native 0-1 fraction; the exporter lifts it onto the CSV's % scale.
        let day = DailyMetric(day: "2026-06-01", totalSleepMin: 420, efficiency: 0.923, deepMin: 95,
                              remMin: 115, lightMin: 210, disturbances: nil, restingHr: 52,
                              avgHrv: 68.4, recovery: 72, strain: 12.5, exerciseCount: nil,
                              spo2Pct: 96.0, skinTempDevC: 33.1, respRateBpm: 14.2)
        let series = ["2026-06-01": ["sleep_performance": 85.0, "sleep_consistency": 88.0,
                                     "sleep_need_min": 480.0, "sleep_debt_min": 60.0,
                                     "awake_min": 35.0, "in_bed_min": 455.0,
                                     "energy_kcal": 2450.0, "avg_hr": 68.0, "max_hr": 165.0]]
        let csv = WhoopCsvExporter.cyclesCSV(days: [day], series: series,
                                             sourceByDay: ["2026-06-01": "import"])
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r.recoveryScore, 72)
        XCTAssertEqual(r.restingHeartRate, 52)
        XCTAssertEqual(r.hrvMs, 68.4)
        XCTAssertEqual(r.skinTempCelsius, 33.1)
        XCTAssertEqual(r.bloodOxygenPct, 96.0)
        // The CSV "Day Strain" column is WHOOP's 0–21 scale, so our 0–100 Effort (12.5) is written
        // down-converted (12.5 ÷ (100/21) = 2.625). Re-import scales it back up at the store boundary.
        XCTAssertEqual(try XCTUnwrap(r.dayStrain), 2.625, accuracy: 1e-6)
        XCTAssertEqual(r.energyKcal, 2450)
        XCTAssertEqual(r.sleepPerformancePct, 85)
        XCTAssertEqual(r.respiratoryRate, 14.2)
        XCTAssertEqual(r.asleepDurationMin, 420)
        XCTAssertEqual(r.inBedDurationMin, 455)
        XCTAssertEqual(r.lightSleepDurationMin, 210)
        XCTAssertEqual(r.deepSleepDurationMin, 95)
        XCTAssertEqual(r.remDurationMin, 115)
        XCTAssertEqual(r.awakeDurationMin, 35)
        XCTAssertEqual(r.sleepEfficiencyPct, 92.3)
        XCTAssertEqual(r.sleepConsistencyPct, 88)
        XCTAssertEqual(r.sleepNeedMin, 480)
        XCTAssertEqual(r.sleepDebtMin, 60)
        // Day attribution survives: cycleStart parsed at UTC+00:00 maps back to 2026-06-01 00:00Z.
        XCTAssertEqual(r.tzOffsetMin, 0)
        XCTAssertEqual(r.cycleStart, Date(timeIntervalSince1970: 1_780_272_000))
    }

    func testWorkoutSportWithCommaQuoteNewlineSurvives() throws {
        let w = WorkoutRow(startTs: 1_750_000_000, endTs: 1_750_003_600,
                           sport: "Run, \"tempo\"\nintervals", source: "whoop",
                           durationS: 3600, energyKcal: 540, avgHr: 158, maxHr: 182,
                           strain: 11.2, distanceM: 8000,
                           zonesJSON: #"{"z1":5.0,"z2":20.0,"z3":40.0,"z4":30.0,"z5":5.0}"#,
                           notes: nil, steps: nil)
        let csv = WhoopCsvExporter.workoutsCSV([w], sourceLabel: { _ in "import" })
        let back = WhoopExportImporter().parseWorkouts(CSVTable(text: csv))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].activityName, "Run, \"tempo\"\nintervals")
        // Workout strain is also written on WHOOP's 0–21 scale (11.2 ÷ (100/21) = 2.352); re-import
        // scales back up at the store boundary.
        XCTAssertEqual(try XCTUnwrap(back[0].activityStrain), 2.352, accuracy: 1e-6)
        XCTAssertEqual(back[0].energyKcal, 540)
        XCTAssertEqual(back[0].avgHeartRate, 158)
        XCTAssertEqual(back[0].maxHeartRate, 182)
        XCTAssertEqual(back[0].hrZone3Pct, 40)
        XCTAssertEqual(back[0].distanceMeters, 8000)
        XCTAssertEqual(back[0].workoutStart, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(back[0].workoutEnd, Date(timeIntervalSince1970: 1_750_003_600))
    }

    func testSleepsRoundTripAllStageShapes() {
        // macOS-import minutes dict, Android [{stage,min}], and the stager's segment array.
        let dictNight = CachedSleepSession(startTs: 1_750_000_000, endTs: 1_750_027_300,
                                           efficiency: 0.923, restingHr: nil, avgHrv: nil,
                                           stagesJSON: #"{"light":210,"deep":95,"rem":115,"awake":35}"#)
        let arrayNight = CachedSleepSession(startTs: 1_760_000_000, endTs: 1_760_025_500,
                                            efficiency: 0.9, restingHr: nil, avgHrv: nil,
                                            stagesJSON: #"[{"stage":"light","min":200.0},{"stage":"deep","min":80.0}]"#)
        let segNight = CachedSleepSession(startTs: 2_000_000_000, endTs: 2_000_007_200,
                                          efficiency: nil, restingHr: nil, avgHrv: nil,
                                          stagesJSON: #"[{"start":2000000000,"end":2000003600,"stage":"light"},{"start":2000003600,"end":2000007200,"stage":"deep"}]"#)
        let csv = WhoopCsvExporter.sleepsCSV([dictNight, arrayNight, segNight], cycleStart: { _ in "" })
        let back = WhoopExportImporter().parseSleeps(CSVTable(text: csv)).sorted {
            ($0.sleepOnset ?? .distantPast) < ($1.sleepOnset ?? .distantPast)
        }
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0].lightSleepDurationMin, 210)
        XCTAssertEqual(back[0].deepSleepDurationMin, 95)
        XCTAssertEqual(back[0].remDurationMin, 115)
        XCTAssertEqual(back[0].awakeDurationMin, 35)
        XCTAssertEqual(back[0].asleepDurationMin, 420)
        XCTAssertEqual(back[0].isNap, false)
        XCTAssertEqual(back[1].lightSleepDurationMin, 200)
        XCTAssertEqual(back[1].deepSleepDurationMin, 80)
        XCTAssertEqual(back[2].lightSleepDurationMin, 60)
        XCTAssertEqual(back[2].deepSleepDurationMin, 60)
        XCTAssertEqual(back[2].wakeOnset, Date(timeIntervalSince1970: 2_000_007_200))
    }

    func testJournalRoundTripIncludingFalseAnswers() {
        let rows = [
            JournalEntry(day: "2026-06-01", question: "Any alcohol?", answeredYes: false, notes: nil),
            JournalEntry(day: "2026-06-01", question: "Caffeine, after 4pm?", answeredYes: true,
                         notes: "one, big \"mug\""),
        ]
        let csv = WhoopCsvExporter.journalCSV(rows)
        let back = WhoopExportImporter().parseJournal(CSVTable(text: csv)).sorted {
            ($0.question ?? "") < ($1.question ?? "")
        }
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back[0].question, "Any alcohol?")
        XCTAssertEqual(back[0].answer, "false")
        XCTAssertEqual(back[1].question, "Caffeine, after 4pm?")
        XCTAssertEqual(back[1].answer, "true")
        XCTAssertEqual(back[1].notes, "one, big \"mug\"")
    }

    func testEfficiencyPctFractionPairIsLosslessAndNilSafe() {
        // Store fraction → CSV % → store fraction round-trips exactly; nil passes through both ways.
        XCTAssertEqual(WhoopExportImporter.whoopEfficiencyPctFromFraction(0.923) ?? -1, 92.3, accuracy: 1e-9)
        XCTAssertEqual(WhoopExportImporter.fractionFromImportedEfficiencyPct(92.3) ?? -1, 0.923, accuracy: 1e-9)
        let roundTripped = WhoopExportImporter.fractionFromImportedEfficiencyPct(
            WhoopExportImporter.whoopEfficiencyPctFromFraction(0.6569))
        XCTAssertEqual(roundTripped ?? -1, 0.6569, accuracy: 1e-9)
        XCTAssertNil(WhoopExportImporter.whoopEfficiencyPctFromFraction(nil))
        XCTAssertNil(WhoopExportImporter.fractionFromImportedEfficiencyPct(nil))
    }

    func testNumbersAreLocaleProof() {
        XCTAssertEqual(WhoopCsvExporter.num(72.0), "72")
        XCTAssertEqual(WhoopCsvExporter.num(68.4), "68.4")
        XCTAssertEqual(WhoopCsvExporter.num(nil as Double?), "")
        XCTAssertFalse(WhoopCsvExporter.num(12345.678).contains(","))
    }

    func testZipArchiveRoundTripsThroughFullImporter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zipURL = dir.appendingPathComponent("noop-export.zip")

        let day = DailyMetric(day: "2026-06-01", totalSleepMin: 420, efficiency: 0.923, deepMin: 95,
                              remMin: 115, lightMin: 210, disturbances: 35, restingHr: 52,
                              avgHrv: 68.4, recovery: 72, strain: 12.5, exerciseCount: nil,
                              spo2Pct: 96.0, skinTempDevC: 33.1, respRateBpm: 14.2)
        let entries: [(name: String, data: Data)] = [
            ("physiological_cycles.csv", Data(WhoopCsvExporter.cyclesCSV(days: [day], series: [:]).utf8)),
            ("sleeps.csv", Data(WhoopCsvExporter.sleepsCSV([], cycleStart: { _ in "" }).utf8)),
            ("workouts.csv", Data(WhoopCsvExporter.workoutsCSV([]).utf8)),
            ("journal_entries.csv", Data(WhoopCsvExporter.journalCSV([]).utf8)),
            // Sidecar + Source column must be ignored by the importer (it reads only the 4 CSVs).
            ("noop_metric_series.json", Data("[]".utf8)),
        ]
        try WhoopCsvExporter.writeArchive(entries: entries, to: zipURL)

        let result = try WhoopExportImporter().`import`(from: zipURL)
        XCTAssertEqual(result.cycles.count, 1)
        XCTAssertEqual(result.cycles[0].recoveryScore, 72)
        XCTAssertEqual(result.sleeps.count, 0)
        XCTAssertEqual(result.workouts.count, 0)
        XCTAssertEqual(result.journal.count, 0)
    }
}
