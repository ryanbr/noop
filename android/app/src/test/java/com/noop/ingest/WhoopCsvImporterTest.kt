package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Pins the WHOOP export-import day-keying: a physiological cycle AND the sleeps.csv fold both belong
 * to the local WAKE day.
 *
 * WHOOP exports are onset-to-onset, so a cycle's cycle_start_time is the EVENING you fell asleep
 * (identical to that cycle's sleep_onset), while the recovery/strain it carries are what you read the
 * next morning. parseCycles + parseCycleSeries key off wake_onset (then cycle_end = the next onset, on
 * the same wake day, then the start); parseSleeps folds off wake_onset too. So the cycle row and the
 * sleep row share a day and mergeDaily collapses them into ONE daily row. Keying off the onset put
 * every night's scores a day early, which blanked Today for import-only users and split the night
 * across two daily rows (import day-shift, v8.2.1).
 */
class WhoopCsvImporterTest {

    private val device = "my-whoop"

    private fun sleepParse(csv: String): WhoopCsvImporter.SleepParse =
        WhoopCsvImporter.parseSleeps(CsvTable.fromData(csv.trimIndent().toByteArray()), device)

    private fun cycles(csv: String) =
        WhoopCsvImporter.parseCycles(CsvTable.fromData(csv.trimIndent().toByteArray()), device)

    /**
     * A main sleep that begins 2024-01-01 23:15 and ends 2024-01-02 06:30 at UTC+01:00 must fold
     * onto the WAKE day 2024-01-02 (not the onset day 2024-01-01), and MERGE with the cycle row —
     * also keyed off the wake day — into a single daily row.
     */
    @Test
    fun mainSleepFoldsToWakeDayAndMergesWithCycleRow() {
        val sleeps = sleepParse(
            """
            Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Asleep duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min)
            2024-01-01 22:10:00,UTC+01:00,2024-01-01 23:15:00,2024-01-02 06:30:00,false,420,210,90,120
            """
        )

        // The folded daily row is attributed to the WAKE day, not the onset evening.
        assertEquals(1, sleeps.daily.size)
        val sleepDay = sleeps.daily.single()
        assertEquals("2024-01-02", sleepDay.day)
        assertEquals(420.0, sleepDay.totalSleepMin!!, 1e-9)

        // The physiological_cycles row for the same night (onset-to-onset: starts the prior evening,
        // ends the next) is keyed off wake_onset = the wake day, matching the sleep fold.
        val cycleRows = cycles(
            """
            Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Day strain,Wake onset
            2024-01-01 22:10:00,2024-01-02 22:30:00,UTC+01:00,66,52,8.4,2024-01-02 06:30:00
            """
        )
        assertEquals(1, cycleRows.size)
        assertEquals("2024-01-02", cycleRows.single().day)

        // mergeDaily collapses the cycle + sleep rows for 2024-01-02 into ONE daily row that carries
        // both the cycle fields (recovery / RHR) and the sleep architecture (total / deep / REM).
        val merged = WhoopCsvImporter.mergeDaily(cycleRows, sleeps.daily)
        assertEquals("the night must not be split across two daily rows", 1, merged.size)
        val day = merged.single()
        assertEquals("2024-01-02", day.day)
        assertEquals(66.0, day.recovery!!, 1e-9)          // from the cycle row
        assertEquals(52, day.restingHr)                   // from the cycle row
        assertEquals(420.0, day.totalSleepMin!!, 1e-9)    // from the sleep row
        assertEquals(90.0, day.deepMin!!, 1e-9)           // from the sleep row
        assertEquals(120.0, day.remMin!!, 1e-9)           // from the sleep row
    }

    /** Naps are excluded from the daily fold entirely (no spurious daily row). */
    @Test
    fun napsAreNotFoldedIntoDaily() {
        val sleeps = sleepParse(
            """
            Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Asleep duration (min)
            2024-01-02 06:30:00,UTC+01:00,2024-01-02 13:00:00,2024-01-02 13:45:00,true,45
            """
        )
        assertEquals(0, sleeps.daily.size)
        // The nap still produces a SleepSession (keyed off its own onset).
        assertEquals(1, sleeps.sessions.size)
        assertNotNull(sleeps.sessions.single())
    }

    /** When wake_onset is missing, the sleep fold falls back to cycle_start, then sleep onset. */
    @Test
    fun missingWakeOnsetFallsBackToCycleStart() {
        val sleeps = sleepParse(
            """
            Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Asleep duration (min)
            2024-01-02 06:30:00,UTC+01:00,2024-01-01 23:15:00,,false,420
            """
        )
        assertEquals(1, sleeps.daily.size)
        // wake_onset absent → fall back to cycle_start (2024-01-02 here).
        assertEquals("2024-01-02", sleeps.daily.single().day)
    }

    /**
     * REGRESSION (v8.2.1): a REALISTIC onset-to-onset physiological_cycles row — cycle_start on the
     * prior evening, wake the next morning — keys its DailyMetric to the WAKE day, not the onset day.
     * Keying off cycle_start put the newest night a day early, so a fresh import with no live strap had
     * no row under "today" and the Today screen blanked. Fails on the old cycle_start keying.
     */
    @Test
    fun cyclesKeyRealOnsetToOnsetRowToWakeDay() {
        val rows = cycles(
            """
            Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Day strain,Sleep onset,Wake onset
            2026-06-05 22:37:00,2026-06-06 22:40:00,UTC+01:00,73,47,8.1,2026-06-05 22:37:00,2026-06-06 07:22:00
            """
        )
        assertEquals(1, rows.size)
        // The recovery you READ on the 6th, not the evening of the 5th you fell asleep.
        assertEquals("2026-06-06", rows.single().day)
    }

    // --- #1849: a Fahrenheit WHOOP export ships skin_temp_f, not skin_temp_celsius -------------

    /**
     * A Fahrenheit export ships `skin_temp_f` instead of `skin_temp_celsius`. The importer must
     * convert the °F value to °C on the way in — NOT store it unconverted (92.3 °F stored as 92.3
     * in a °C column reads as a lethal fever and poisons the baseline). 91.58 °F = 33.1 °C.
     * Byte-identical with the Swift twin (WhoopExportImporterTests.testFahrenheitSkinTempIsConvertedToCelsius).
     */
    @Test
    fun fahrenheitSkinTempIsConvertedToCelsius() {
        val rows = cycles(
            """
            Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (f),Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min)
            2024-01-02 06:30:00,2024-01-03 06:29:00,UTC+01:00,72,52,68.4,91.58,96.0,12.5,2450,165,68,2024-01-01 23:15:00,2024-01-02 06:30:00,85,14.2,420,455,210,95,115,35,92.3,88.0,480,60
            """
        )
        assertEquals(1, rows.size)
        // 91.58 °F → (91.58 − 32) × 5/9 = 33.1 °C — the same stored value a Celsius import produces.
        assertEquals(33.1, rows.single().skinTempDevC!!, 1e-3)
    }

    /**
     * A Celsius export (the canonical form) is unaffected — `skin_temp_celsius` is read directly
     * and no conversion is applied. Regression guard: the fix must not change the Celsius path.
     */
    @Test
    fun celsiusSkinTempIsUnchanged() {
        val rows = cycles(
            """
            Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep efficiency %,Sleep consistency %,Sleep need (min),Sleep debt (min)
            2024-01-02 06:30:00,2024-01-03 06:29:00,UTC+01:00,72,52,68.4,33.1,96.0,12.5,2450,165,68,2024-01-01 23:15:00,2024-01-02 06:30:00,85,14.2,420,455,210,95,115,35,92.3,88.0,480,60
            """
        )
        assertEquals(1, rows.size)
        assertEquals(33.1, rows.single().skinTempDevC!!, 1e-3)
    }

    // --- #136: imported journal keys to the WAKE day, not the onset evening -------------------

    private fun journalWakeMap(csv: String): Map<Long, String> =
        WhoopCsvImporter.journalWakeDayMap(CsvTable.fromData(csv.trimIndent().toByteArray()))

    private fun journal(csv: String, wake: Map<Long, String>) =
        WhoopCsvImporter.parseJournal(CsvTable.fromData(csv.trimIndent().toByteArray()), device, wake)

    /**
     * A journal entry is keyed in the export only by cycle_start (the onset evening), but it must land on
     * the cycle's WAKE day — the day parseCycles and the native journal use — so it correlates against the
     * recovery/sleep it belongs to. Onset 2026-06-05 evening, wake 2026-06-06 → the entry belongs to the
     * 6th. Keying off the onset put it a day early and it never matched its outcome (all days read
     * "Without" in Insights).
     */
    @Test
    fun importedJournalKeysToWakeDayNotOnset() {
        val wake = journalWakeMap(
            """
            Cycle start time,Cycle end time,Cycle timezone,Wake onset
            2026-06-05 22:37:00,2026-06-06 22:40:00,UTC+01:00,2026-06-06 07:22:00
            """
        )
        val entries = journal(
            """
            Cycle start time,Cycle timezone,Question text,Answered yes/no,Notes
            2026-06-05 22:37:00,UTC+01:00,Any alcohol?,true,
            """,
            wake,
        )
        assertEquals(1, entries.size)
        val e = entries.single()
        assertEquals("2026-06-06", e.day)   // wake day, not the 2026-06-05 onset evening
        assertEquals(true, e.answeredYes)
        assertEquals("Any alcohol?", e.question)
    }

    /** Fallback: with the cycle absent from the export (empty map), the entry keys to the onset day —
     *  the prior behaviour, so a journal-only export still stores something rather than dropping it. */
    @Test
    fun importedJournalFallsBackToOnsetDayWhenCycleMissing() {
        val entries = journal(
            """
            Cycle start time,Cycle timezone,Question text,Answered yes/no
            2026-06-05 22:37:00,UTC+01:00,Any alcohol?,true
            """,
            emptyMap(),
        )
        assertEquals("2026-06-05", entries.single().day)
    }

    /**
     * REGRESSION (#631): a REAL WHOOP export names this column "Answered yes" (-> answered_yes), not
     * the "Answered yes/no" (-> answered_yes_no) NOOP's own exporter writes. Header and TRUE/FALSE
     * casing lifted verbatim from a reporter's actual `journal_entries.csv`. Before this fix none of
     * the old candidate keys ever matched a real export, so every answer silently read false
     * ("Without" in Insights) regardless of what the account actually answered.
     */
    @Test
    fun importedJournalReadsRealWhoopAnsweredYesHeader() {
        val entries = journal(
            """
            Cycle start time,Cycle end time,Cycle timezone,Question text,Answered yes,Notes
            2025-09-14 23:16:59,2025-09-15 23:08:01,UTC+02:00,Have any alcoholic drinks?,TRUE,
            2025-09-14 23:16:59,2025-09-15 23:08:01,UTC+02:00,Experienced a migraine?,FALSE,
            """,
            emptyMap(),
        )
        assertEquals(2, entries.size)
        assertEquals(true, entries[0].answeredYes)
        assertEquals(false, entries[1].answeredYes)
    }

    // --- Localized (Brazilian Portuguese) headers, issue #692 ---------------------------------

    /** Diacritic-folded pt-BR headers land on the canonical English keys (parity with Swift). */
    @Test
    fun portugueseHeaderAliasesNormalize() {
        assertEquals("recovery_score_pct", HeaderNorm.normalize("Pontuação de recuperação %"))
        assertEquals("resting_heart_rate_bpm", HeaderNorm.normalize("Frequência cardíaca em repouso (bpm)"))
        assertEquals("heart_rate_variability_ms", HeaderNorm.normalize("Variabilidade da frequência cardíaca (ms)"))
        // The leading "%" in "% de oxigênio no sangue" becomes "pct" at the front, then folds.
        assertEquals("blood_oxygen_pct", HeaderNorm.normalize("% de oxigênio no sangue"))
        assertEquals("deep_sws_duration_min", HeaderNorm.normalize("Duração profundo (Sono) (min)"))
        assertEquals("activity_name", HeaderNorm.normalize("Nome da atividade"))
        assertEquals("hr_zone_3_pct", HeaderNorm.normalize("Zona 3 de FC %"))
        assertEquals("nap", HeaderNorm.normalize("Sesta"))
        // "FC máx." shares the French alias and must still resolve (it is not duplicated for pt-BR).
        assertEquals("max_hr_bpm", HeaderNorm.normalize("FC máx. (bpm)"))
        assertEquals("average_hr_bpm", HeaderNorm.normalize("FC média (bpm)"))
    }

    /** A real ciclos_fisiológicos.csv header + one data row: values flow through the pt-BR aliases. */
    @Test
    fun portugueseCyclesValuesParse() {
        val rows = cycles(
            """
            Hora de início do ciclo,Hora de fim do ciclo,Fuso horário do ciclo,Pontuação de recuperação %,Frequência cardíaca em repouso (bpm),Variabilidade da frequência cardíaca (ms),Temp. da pele (celsius),% de oxigênio no sangue,Esforço diário,Energia queimada (cal),FC máx. (bpm),FC média (bpm),Início do sono,Início da vigília,Desempenho do sono %,Frequência respiratória (rpm),Duração do sono (min),Duração na cama (min),Duração do sono leve (min),Duração profundo (Sono) (min),Duração REM (min),Duração de vigília (min),Necessidade de sono (min),Débito de sono (min),Eficácia do sono %,Consistência do sono %
            2024-03-01 06:00:00,2024-03-02 06:00:00,UTC+00:00,80,52,95,33.5,96,12.5,2000,150,61,2024-03-01 23:00:00,2024-03-02 06:30:00,90,14,420,450,200,120,100,30,480,60,93,85
            """
        )
        assertEquals(1, rows.size)
        val r = rows.single()
        assertEquals(80.0, r.recovery!!, 1e-9)
        assertEquals(52, r.restingHr)
        assertEquals(95.0, r.avgHrv!!, 1e-9)
        // Keyed off wake_onset (Início da vigília 2024-03-02 06:30) = the wake day, not the onset day.
        assertEquals("2024-03-02", r.day)
        // Day Strain 12.5 is rescaled onto NOOP's 0–100 Effort axis (×100/21).
        assertEquals(12.5 * (100.0 / 21.0), r.strain!!, 1e-9)
    }
}
