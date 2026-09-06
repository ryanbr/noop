import XCTest
@testable import StrandImport

final class WhoopExportImporterTests: XCTestCase {

    // MARK: - Header normalization

    func testHeaderNormalization() {
        XCTAssertEqual(HeaderNorm.normalize("Heart rate variability (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Recovery score %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("In bed duration (min)"), "in_bed_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("  Cycle start time  "), "cycle_start_time")
        XCTAssertEqual(HeaderNorm.normalize("HR Zone 1 %"), "hr_zone_1_pct")
    }

    // MARK: - BOM stripping

    func testBOMIsStripped() {
        let raw = Fixtures.data("physiological_cycles.csv")
        // Confirm the fixture actually carries a UTF-8 BOM.
        XCTAssertGreaterThanOrEqual(raw.count, 3)
        XCTAssertEqual(Array(raw.prefix(3)), [0xEF, 0xBB, 0xBF])

        let table = CSVTable(data: raw)
        // After stripping, the first header must normalize to cycle_start_time,
        // not "\u{FEFF}cycle_start_time".
        XCTAssertTrue(table.normalizedHeaders.contains("cycle_start_time"))
        XCTAssertFalse(table.normalizedHeaders.first?.contains("\u{FEFF}") ?? false)
    }

    // MARK: - Timezone parsing

    func testTimezoneOffsetParsing() {
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC+01:00"), 60)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC-05:00"), -300)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("+02:30"), 150)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC"), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("Z"), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes(nil), 0)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC+0530"), 330)
    }

    func testTimestampParsedInGivenOffsetToUTC() {
        // 06:30 at UTC+01:00 == 05:30 UTC.
        let d = WhoopTime.parse("2024-01-02 06:30:00", offsetMinutes: 60)
        XCTAssertEqual(d, Fixtures.utc(2024, 1, 2, 5, 30, 0))

        // 00:05 at UTC-05:00 == 05:05 UTC.
        let d2 = WhoopTime.parse("2024-01-03 00:05:00", offsetMinutes: -300)
        XCTAssertEqual(d2, Fixtures.utc(2024, 1, 3, 5, 5, 0))
    }

    // MARK: - physiological_cycles.csv

    func testCyclesParseToExpectedValues() throws {
        let table = CSVTable(data: Fixtures.data("physiological_cycles.csv"))
        let rows = WhoopExportImporter().parseCycles(table)

        XCTAssertEqual(rows.count, 2)
        let r0 = rows[0]

        // Cycle start: 2024-01-02 06:30:00 at UTC+01:00 -> 05:30 UTC.
        XCTAssertEqual(r0.cycleStart, Fixtures.utc(2024, 1, 2, 5, 30, 0))
        XCTAssertEqual(r0.tzOffsetMin, 60)
        XCTAssertEqual(r0.recoveryScore, 72)
        XCTAssertEqual(r0.restingHeartRate, 52)
        XCTAssertEqual(r0.hrvMs, 68.4)
        XCTAssertEqual(r0.skinTempCelsius, 33.1)
        XCTAssertEqual(r0.bloodOxygenPct, 96.0)
        XCTAssertEqual(r0.dayStrain, 12.5)
        XCTAssertEqual(r0.energyKcal, 2450)        // "(cal)" treated as kcal, not converted
        XCTAssertEqual(r0.maxHeartRate, 165)
        XCTAssertEqual(r0.avgHeartRate, 68)
        XCTAssertEqual(r0.sleepPerformancePct, 85)
        XCTAssertEqual(r0.respiratoryRate, 14.2)
        XCTAssertEqual(r0.asleepDurationMin, 420)   // kept in minutes
        XCTAssertEqual(r0.inBedDurationMin, 455)
        XCTAssertEqual(r0.lightSleepDurationMin, 210)
        XCTAssertEqual(r0.deepSleepDurationMin, 95)
        XCTAssertEqual(r0.remDurationMin, 115)
        XCTAssertEqual(r0.awakeDurationMin, 35)
        XCTAssertEqual(r0.sleepEfficiencyPct, 92.3)
        XCTAssertEqual(r0.sleepConsistencyPct, 88.0)
        XCTAssertEqual(r0.sleepNeedMin, 480)
        XCTAssertEqual(r0.sleepDebtMin, 60)

        // Sleep onset 2024-01-01 23:15 at +01:00 -> 22:15 UTC.
        XCTAssertEqual(r0.sleepOnset, Fixtures.utc(2024, 1, 1, 22, 15, 0))

        // Second row uses a negative offset.
        let r1 = rows[1]
        XCTAssertEqual(r1.tzOffsetMin, -300)
        XCTAssertEqual(r1.cycleStart, Fixtures.utc(2024, 1, 3, 11, 29, 0)) // 06:29 -05:00
        XCTAssertEqual(r1.recoveryScore, 55)
    }

    // MARK: - #1849: Fahrenheit skin-temp import

    /// A Fahrenheit WHOOP export ships `skin_temp_f` instead of `skin_temp_celsius`. The
    /// importer must convert the °F value to °C on the way in — NOT store it unconverted
    /// (92.3 °F stored as 92.3 in a °C column reads as a lethal fever and poisons the
    /// baseline). 91.58 °F = 33.1 °C, the same value the Celsius fixture carries.
    func testFahrenheitSkinTempIsConvertedToCelsius() throws {
        let table = CSVTable(data: Fixtures.data("physiological_cycles_fahrenheit.csv"))
        let rows = WhoopExportImporter().parseCycles(table)

        XCTAssertEqual(rows.count, 1)
        let r0 = try XCTUnwrap(rows.first)
        // 91.58 °F → (91.58 − 32) × 5/9 = 33.1 °C — the same stored value the Celsius
        // fixture produces, so a Fahrenheit import lands byte-identical to a Celsius one.
        XCTAssertEqual(r0.skinTempCelsius ?? -999, 33.1, accuracy: 0.001,
                       "a Fahrenheit skin_temp_f must be converted to °C on import, not stored as-is")
    }

    /// A Celsius export (the canonical form) is unaffected — `skin_temp_celsius` is read
    /// directly and no conversion is applied. This is the regression guard: the fix must
    /// not change the Celsius path.
    func testCelsiusSkinTempIsUnchanged() throws {
        let table = CSVTable(data: Fixtures.data("physiological_cycles.csv"))
        let rows = WhoopExportImporter().parseCycles(table)

        let r0 = try XCTUnwrap(rows.first)
        XCTAssertEqual(r0.skinTempCelsius ?? -999, 33.1, accuracy: 0.001,
                       "a Celsius skin_temp_celsius must pass through unchanged")
    }

    // MARK: - workouts.csv WITHOUT GPS columns

    func testWorkoutsWithoutGPSColumnsStillParse() throws {
        let table = CSVTable(data: Fixtures.data("workouts.csv"))
        let rows = WhoopExportImporter().parseWorkouts(table)

        XCTAssertEqual(rows.count, 2)
        let w0 = rows[0]
        XCTAssertEqual(w0.activityName, "Running")
        XCTAssertEqual(w0.activityStrain, 11.2)
        XCTAssertEqual(w0.energyKcal, 540)
        XCTAssertEqual(w0.maxHeartRate, 182)
        XCTAssertEqual(w0.avgHeartRate, 158)
        XCTAssertEqual(w0.hrZone3Pct, 40.0)
        XCTAssertEqual(w0.workoutStart, Fixtures.utc(2024, 1, 2, 17, 0, 0)) // +00:00

        // GPS / distance / altitude columns are absent → nil, not an error.
        XCTAssertNil(w0.distanceMeters)
        XCTAssertNil(w0.altitudeGainMeters)
        XCTAssertNil(w0.altitudeChangeMeters)
    }

    // MARK: - workouts.csv WITH GPS columns (synthetic, in-memory)

    func testWorkoutsWithGPSColumnsParse() throws {
        let csv = """
        Workout start time,Cycle timezone,Activity name,Distance (meters),Altitude gain (meters),Altitude change (meters)
        2024-02-01 09:00:00,UTC+00:00,Cycling,15230.5,210.0,-5.0
        """
        let rows = WhoopExportImporter().parseWorkouts(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].activityName, "Cycling")
        XCTAssertEqual(rows[0].distanceMeters, 15230.5)
        XCTAssertEqual(rows[0].altitudeGainMeters, 210.0)
        XCTAssertEqual(rows[0].altitudeChangeMeters, -5.0)
    }

    // MARK: - sleeps.csv with Nap column

    func testSleepsNapColumn() throws {
        let table = CSVTable(data: Fixtures.data("sleeps.csv"))
        let rows = WhoopExportImporter().parseSleeps(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].isNap, false)
        XCTAssertEqual(rows[1].isNap, true)
        XCTAssertEqual(rows[0].sleepPerformancePct, 85)
        // Nap row has blank optional cells -> nil, not crash.
        XCTAssertNil(rows[1].sleepPerformancePct)
        XCTAssertEqual(rows[1].asleepDurationMin, 25)
    }

    // MARK: - journal_entries.csv

    func testJournalPivot() throws {
        let table = CSVTable(data: Fixtures.data("journal_entries.csv"))
        let rows = WhoopExportImporter().parseJournal(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].question, "Did you drink any alcohol?")
        XCTAssertEqual(rows[0].answer, "false")
        XCTAssertNil(rows[0].notes)
        XCTAssertEqual(rows[1].question, "Did you have any caffeine?")
        XCTAssertEqual(rows[1].answer, "true")
        XCTAssertEqual(rows[1].notes, "One coffee in the morning")
    }

    /// REGRESSION (#631): a REAL WHOOP export names this column "Answered yes" (-> answered_yes), not
    /// the "Answered yes/no" (-> answered_yes_no) NOOP's own exporter writes -- and above's fixture
    /// happens to use. Header and TRUE/FALSE casing lifted verbatim from a reporter's actual
    /// `journal_entries.csv`. Before this fix none of the old candidate keys ever matched a real
    /// export, so every answer silently read false ("Without" in Insights) regardless of what the
    /// account actually answered.
    func testJournalReadsRealWhoopAnsweredYesHeader() throws {
        let csv = """
        Cycle start time,Cycle end time,Cycle timezone,Question text,Answered yes,Notes
        2025-09-14 23:16:59,2025-09-15 23:08:01,UTC+02:00,Have any alcoholic drinks?,TRUE,
        2025-09-14 23:16:59,2025-09-15 23:08:01,UTC+02:00,Experienced a migraine?,FALSE,
        """
        let table = CSVTable(data: Data(csv.utf8))
        let rows = WhoopExportImporter().parseJournal(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].answer, "TRUE")
        XCTAssertEqual(rows[1].answer, "FALSE")
    }

    // MARK: - Folder import end to end

    func testImportFromFolder() throws {
        // The Resources directory itself is a folder containing all the CSVs.
        let folder = Fixtures.url("physiological_cycles.csv").deletingLastPathComponent()
        let result = try WhoopExportImporter().import(from: folder)

        XCTAssertEqual(result.cycles.count, 2)
        XCTAssertEqual(result.sleeps.count, 2)
        XCTAssertEqual(result.workouts.count, 2)
        XCTAssertEqual(result.journal.count, 2)

        XCTAssertEqual(result.summary.sourceKind, .whoopExport)
        XCTAssertEqual(result.summary.recordCount, 8)
        XCTAssertEqual(result.summary.countsByCategory["cycles"], 2)
        XCTAssertEqual(result.summary.countsByCategory["workouts"], 2)
        XCTAssertNotNil(result.summary.earliest)
        XCTAssertNotNil(result.summary.latest)
        XCTAssertLessThanOrEqual(result.summary.earliest!, result.summary.latest!)
    }

    // MARK: - Robustness: extra/unknown columns, reordered headers

    func testExtraAndReorderedColumnsTolerated() throws {
        let csv = """
        Some Future Column,Cycle timezone,Recovery score %,Cycle start time,Another Unknown
        hello,UTC+00:00,80,2024-03-01 06:00:00,world
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - CSV quoting

    func testQuotedFieldsWithCommasAndQuotes() {
        let csv = "a,b,c\n\"hello, world\",\"she said \"\"hi\"\"\",plain\n"
        let table = CSVTable(text: csv)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0]["a"], "hello, world")
        XCTAssertEqual(table.rows[0]["b"], "she said \"hi\"")
        XCTAssertEqual(table.rows[0]["c"], "plain")
    }

    // MARK: - Localized (German) column headers — issue #3

    func testGermanHeaderNormalizationAliases() {
        // Diacritic-folded German headers map onto the canonical English keys.
        XCTAssertEqual(HeaderNorm.normalize("Erholungswert %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Ruheherzfrequenz (Schläge pro Minute)"), "resting_heart_rate_bpm")
        XCTAssertEqual(HeaderNorm.normalize("Herzfrequenzvariabilität (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Schlafbeständigkeit %"), "sleep_consistency_pct")
        XCTAssertEqual(HeaderNorm.normalize("Name der Aktivität"), "activity_name")
        XCTAssertEqual(HeaderNorm.normalize("HF-Zone 3 %"), "hr_zone_3_pct")
        // English headers are unaffected by the folding + alias.
        XCTAssertEqual(HeaderNorm.normalize("Recovery score %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Cycle start time"), "cycle_start_time")
    }

    func testGermanCyclesValuesParse() throws {
        // A real German physiologische_zyklen.csv header row + one data row: values must come through.
        let csv = """
        Startzeit des Zyklus,Endzeit des Zyklus,Zeitzone des Zyklus,Erholungswert %,Ruheherzfrequenz (Schläge pro Minute),Herzfrequenzvariabilität (ms),Tagesbelastung,Durchschnittliche HF (Schläge pro Minute)
        2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,12.5,61
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].restingHeartRate, 52)
        XCTAssertEqual(rows[0].hrvMs, 95)
        XCTAssertEqual(rows[0].dayStrain, 12.5)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - Localized (Spanish) column headers — issue #76

    func testSpanishHeaderNormalizationAliases() {
        // Diacritic-folded Spanish headers map onto the canonical English keys.
        XCTAssertEqual(HeaderNorm.normalize("Puntuación de recuperación (%)"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Frecuencia cardíaca en reposo (lpm)"), "resting_heart_rate_bpm")
        XCTAssertEqual(HeaderNorm.normalize("Variabilidad de la frecuencia cardíaca (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Temp. cutánea (grados centígrados)"), "skin_temp_celsius")
        XCTAssertEqual(HeaderNorm.normalize("Tempo despierto/a (min)"), "awake_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("Regularidad del sueño %"), "sleep_consistency_pct")
        XCTAssertEqual(HeaderNorm.normalize("Siesta"), "nap")
    }

    func testSpanishCyclesValuesParse() throws {
        // The EXACT physiological_cycles.csv header from a real Spanish export (issue #76) + one data row.
        let csv = """
        Hora de inicio del ciclo,Hora de finalización del ciclo,Zona horaria del ciclo,Puntuación de recuperación (%),Frecuencia cardíaca en reposo (lpm),Variabilidad de la frecuencia cardíaca (ms),Temp. cutánea (grados centígrados),Oxígeno en sangre %,Esfuerzo del día,Energía quemada (cal),FC máx. (lpm),FC promedio (lpm),Inicio del sueño,Inicio de la vigilia,Calificación del sueño (%),Frecuencia respiratoria (rpm),Duración del sueño (min),Tiempo en la cama (min),Duración de sueño ligero (min),Duración de sueño profundo (SWS) (min),Duración de sueño REM (min),Tempo despierto/a (min),Sueño necesario (min),Deuda de sueño (min),Eficiencia del sueño %,Regularidad del sueño %
        2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,33.5,96,12.5,2000,150,61,2024-03-01 23:00:00,2024-03-02 06:30:00,90,14,420,450,200,120,100,30,480,60,93,85
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].restingHeartRate, 52)
        XCTAssertEqual(rows[0].hrvMs, 95)
        XCTAssertEqual(rows[0].dayStrain, 12.5)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - Localized (French) column headers — issue #79

    func testFrenchHeaderNormalizationAliases() {
        // Diacritic-folded French headers map onto the canonical English keys.
        XCTAssertEqual(HeaderNorm.normalize("Score de récupération %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Variabilité de la fréquence cardiaque (ms)"), "heart_rate_variability_ms")
        XCTAssertEqual(HeaderNorm.normalize("Durée du sommeil paradoxal (min)"), "rem_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("Régularité du sommeil %"), "sleep_consistency_pct")
        XCTAssertEqual(HeaderNorm.normalize("Sieste"), "nap")
        // The apostrophe folds to "_" — BOTH the straight (') and the curly (’) variant must map.
        XCTAssertEqual(HeaderNorm.normalize("Niveau d'oxygène %"), "blood_oxygen_pct")
        XCTAssertEqual(HeaderNorm.normalize("Niveau d’oxygène %"), "blood_oxygen_pct")
        XCTAssertEqual(HeaderNorm.normalize("Temps d'éveil (min)"), "awake_duration_min")
        // The workout zone headers carry a NON-BREAKING SPACE before % — it folds to "_" too.
        XCTAssertEqual(HeaderNorm.normalize("Zone FC 1\u{00A0}%"), "hr_zone_1_pct")
        XCTAssertEqual(HeaderNorm.normalize("Nom de l'activité"), "activity_name")
    }

    func testFrenchCyclesValuesParse() throws {
        // The EXACT physiological_cycles.csv header from a real French export (issue #79) + one data row.
        let csv = """
        Heure de début du cycle,Heure de fin du cycle,Fuseau horaire du cycle,Score de récupération %,Fréquence cardiaque au repos (bpm),Variabilité de la fréquence cardiaque (ms),Température cutanée (Celsius),Niveau d'oxygène %,Effort du jour,Dépense énergétique (cal.),FC max. (bpm),FC moyenne (bpm),Premiers signes de sommeil,Premiers signes de réveil,Performance Sommeil %,Fréquence respiratoire (tr/min),Durée du sommeil (min),Temps passé au lit (min),Durée du sommeil léger (min),Durée du sommeil profond (min),Durée du sommeil paradoxal (min),Temps d'éveil (min),Besoins en sommeil (min),Dette de sommeil (min),Efficacité du sommeil %,Régularité du sommeil %
        2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,33.5,96,12.5,2000,150,61,2024-03-01 23:00:00,2024-03-02 06:30:00,90,14,420,450,200,120,100,30,480,60,93,85
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].restingHeartRate, 52)
        XCTAssertEqual(rows[0].hrvMs, 95)
        XCTAssertEqual(rows[0].dayStrain, 12.5)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }

    // MARK: - Localized (Brazilian Portuguese) column headers (issue #692)

    func testPortugueseHeaderNormalizationAliases() {
        // Diacritic-folded pt-BR headers land on the canonical English keys.
        XCTAssertEqual(HeaderNorm.normalize("Pontuação de recuperação %"), "recovery_score_pct")
        XCTAssertEqual(HeaderNorm.normalize("Frequência cardíaca em repouso (bpm)"), "resting_heart_rate_bpm")
        XCTAssertEqual(HeaderNorm.normalize("Variabilidade da frequência cardíaca (ms)"), "heart_rate_variability_ms")
        // The leading "%" in "% de oxigênio no sangue" becomes "pct" at the front, then folds.
        XCTAssertEqual(HeaderNorm.normalize("% de oxigênio no sangue"), "blood_oxygen_pct")
        XCTAssertEqual(HeaderNorm.normalize("Duração profundo (Sono) (min)"), "deep_sws_duration_min")
        XCTAssertEqual(HeaderNorm.normalize("Consistência do sono %"), "sleep_consistency_pct")
        XCTAssertEqual(HeaderNorm.normalize("Nome da atividade"), "activity_name")
        XCTAssertEqual(HeaderNorm.normalize("Zona 3 de FC %"), "hr_zone_3_pct")
        XCTAssertEqual(HeaderNorm.normalize("Sesta"), "nap")
        // "FC máx." shares the French alias and must still resolve (it is not duplicated for pt-BR).
        XCTAssertEqual(HeaderNorm.normalize("FC máx. (bpm)"), "max_hr_bpm")
        XCTAssertEqual(HeaderNorm.normalize("FC média (bpm)"), "average_hr_bpm")
    }

    func testPortugueseCyclesValuesParse() throws {
        // The exact ciclos_fisiológicos.csv header from a real pt-BR export + one data row.
        let csv = """
        Hora de início do ciclo,Hora de fim do ciclo,Fuso horário do ciclo,Pontuação de recuperação %,Frequência cardíaca em repouso (bpm),Variabilidade da frequência cardíaca (ms),Temp. da pele (celsius),% de oxigênio no sangue,Esforço diário,Energia queimada (cal),FC máx. (bpm),FC média (bpm),Início do sono,Início da vigília,Desempenho do sono %,Frequência respiratória (rpm),Duração do sono (min),Duração na cama (min),Duração do sono leve (min),Duração profundo (Sono) (min),Duração REM (min),Duração de vigília (min),Necessidade de sono (min),Débito de sono (min),Eficácia do sono %,Consistência do sono %
        2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,33.5,96,12.5,2000,150,61,2024-03-01 23:00:00,2024-03-02 06:30:00,90,14,420,450,200,120,100,30,480,60,93,85
        """
        let rows = WhoopExportImporter().parseCycles(CSVTable(text: csv))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].recoveryScore, 80)
        XCTAssertEqual(rows[0].restingHeartRate, 52)
        XCTAssertEqual(rows[0].hrvMs, 95)
        XCTAssertEqual(rows[0].dayStrain, 12.5)
        XCTAssertEqual(rows[0].cycleStart, Fixtures.utc(2024, 3, 1, 6, 0, 0))
    }
}
