import Foundation
import ZIPFoundation

/// Parses a Whoop data export (CSV bundle) into normalized Swift models.
///
/// The parser is header-name-driven and tolerant: columns are matched by
/// normalized header name (not position), every column is optional, UTF-8 BOMs
/// are stripped, and missing files / columns degrade gracefully. The schema is
/// identical across Whoop 4 / 5 / MG, so a single parser covers all three.
///
/// Input may be a folder (possibly nested or renamed) or a `.zip`. CSVs are
/// located **by filename**, case-insensitively, anywhere in the tree.
public struct WhoopExportImporter {

    /// Aggregate ceiling on the bytes held in RAM across ALL retained CSVs from one import. The per-entry
    /// cap (`maxEntryBytes`) bounds a single file, but NOT the sum of the retained set — this backstops a
    /// crafted export from accumulating unbounded `Data` in the result dict. A real Whoop bundle is a few
    /// MB, so 1 GB never trips in practice. Injectable so tests can exercise the budget with tiny inputs.
    let maxTotalBytes: Int

    public init(maxTotalBytes: Int = 1 << 30) { self.maxTotalBytes = maxTotalBytes }

    // MARK: - Strain → Effort rescale (Charge/Effort/Rest redesign, 2026-06-12)

    /// WHOOP reports "Day Strain" on its own 0–21 logarithmic scale. NOOP's "Effort" score lives on a
    /// 0–100 scale (StrainScorer.maxStrain = 100), so an imported Day Strain must be rescaled by
    /// 100/21 before it is written into the `strain` metric series / `DailyMetric.strain`, otherwise
    /// imported history would sit a fifth as high as live-computed Effort.
    ///
    /// This is applied at the WRITE boundary (WhoopImporter → store) — NOT at parse time — so the
    /// verbatim parsed value (`WhoopCycleRow.dayStrain`) and the CSV round-trip contract are preserved.
    /// Keep this factor byte-identical to the Android importer (WhoopCsvImporter.kt).
    public static let dayStrainToEffortScale = 100.0 / 21.0

    /// Rescale an imported WHOOP Day Strain (0–21) onto NOOP's 0–100 Effort axis. `nil` passes through.
    public static func effortFromImportedDayStrain(_ dayStrain: Double?) -> Double? {
        guard let dayStrain else { return nil }
        return dayStrain * dayStrainToEffortScale
    }

    /// Inverse: convert NOOP's internal 0–100 Effort back onto WHOOP's 0–21 Day Strain scale for a
    /// WHOOP-format CSV export. Keeps the CSV genuinely WHOOP-compatible AND makes a NOOP export →
    /// NOOP import round-trip lossless (export ÷scale, then import ×scale restores the value).
    public static func whoopDayStrainFromEffort(_ effort: Double?) -> Double? {
        guard let effort else { return nil }
        return effort / dayStrainToEffortScale
    }

    /// WHOOP CSVs carry "Sleep efficiency %" on a 0–100 scale; NOOP's `efficiency` columns store the
    /// 0–1 fraction the native pipeline writes (`AnalyticsEngine`: actual-sleep ÷ in-bed). Convert at
    /// the WRITE boundary (WhoopImporter → store), NOT at parse time, so the verbatim parsed value
    /// (`sleepEfficiencyPct`) and the CSV round-trip contract are preserved — the same shape as the
    /// Day Strain ⇄ Effort pair above. Keep byte-identical to the Android importer (WhoopCsvImporter.kt).
    public static func fractionFromImportedEfficiencyPct(_ pct: Double?) -> Double? {
        guard let pct else { return nil }
        return pct / 100.0
    }

    /// Inverse: the stored 0–1 fraction back onto the CSV's 0–100 "Sleep efficiency %" column, so an
    /// exported CSV is WHOOP-compatible and a NOOP export → NOOP import round-trip is lossless to
    /// 4 decimal places of a percent (1e-6 of the fraction). The rounding matters: `num()` prints
    /// shortest-round-trip Doubles, and a raw `fraction * 100` carries FP dust (0.923 × 100 =
    /// 92.30000000000001) straight into the CSV cell.
    public static func whoopEfficiencyPctFromFraction(_ fraction: Double?) -> Double? {
        guard let fraction else { return nil }
        return (fraction * 100.0 * 10_000).rounded() / 10_000
    }

    // Recognised CSV filenames (lowercased).
    private static let cyclesName  = "physiological_cycles.csv"
    private static let sleepsName  = "sleeps.csv"
    private static let workoutsName = "workouts.csv"
    private static let journalName = "journal_entries.csv"

    /// Map a known localized WHOOP export filename to its canonical English name. WHOOP localizes
    /// the CSV filenames in non-English exports (issue #3): a German export ships Schlaf.csv,
    /// Trainings.csv, physiologische_zyklen.csv, and logbuch_eintraege.csv.
    private static func localizedAlias(_ base: String) -> String? {
        switch base {
        case "physiologische_zyklen.csv": return cyclesName   // German (app.whoop.com → Daten exportieren)
        case "schlaf.csv":                return sleepsName
        case "trainings.csv":             return workoutsName
        case "logbuch_eintraege.csv":     return journalName
        // Spanish (issue #76): physiological_cycles.csv keeps its English name, but sleep/workouts are
        // renamed. Folded + unfolded variants since the filename is lowercased but not diacritic-folded.
        case "sueño.csv", "sueno.csv":    return sleepsName
        case "entrenamientos.csv":        return workoutsName
        // French (issue #79): physiological_cycles.csv keeps its English name; sleep/workouts renamed.
        case "sommeil.csv":               return sleepsName
        case "entrainements.csv", "entraînements.csv": return workoutsName
        // Brazilian Portuguese (issue #692): unlike es/fr, WHOOP localizes ALL FOUR filenames here,
        // cycles included. Names taken from a real pt-BR export. Folded + unfolded variants because the
        // filename is lowercased but not diacritic-folded; header sniffing is the backstop if it mojibakes.
        case "ciclos_fisiológicos.csv", "ciclos_fisiologicos.csv": return cyclesName
        case "sonos.csv":                 return sleepsName
        case "treinos.csv":               return workoutsName
        case "entradas_diário.csv", "entradas_diario.csv": return journalName
        default:                          return nil
        }
    }

    /// Classify a CSV by its header columns when the filename is unrecognised. Covers any language
    /// whose column headers stay English even when the filenames are translated.
    private static func sniffKind(_ data: Data) -> String? {
        let h = Set(CSVTable(data: data).normalizedHeaders)
        if h.contains("activity_name") || h.contains("workout_start_time") { return workoutsName }
        if h.contains("question_text") || h.contains("answered_yes_no") || h.contains("question") { return journalName }
        if h.contains("nap") && (h.contains("sleep_onset") || h.contains("wake_onset")) { return sleepsName }
        if h.contains("cycle_start_time") || h.contains("recovery_score_pct") || h.contains("day_strain") { return cyclesName }
        if h.contains("sleep_onset") || h.contains("asleep_duration_min") { return sleepsName }
        return nil
    }

    /// Canonical key for a candidate CSV: exact English name, then a localized alias, then content.
    private static func canonicalKey(base: String, data: Data) -> String? {
        let wanted: Set<String> = [cyclesName, sleepsName, workoutsName, journalName]
        if wanted.contains(base) { return base }
        if let a = localizedAlias(base) { return a }
        return sniffKind(data)
    }

    // MARK: - Public entry point

    /// Import from a folder or a `.zip` URL, returning all normalized rows plus
    /// a summary.
    public func `import`(from url: URL) throws -> WhoopImportResult {
        let csvData = try loadCSVData(from: url)

        var cycles: [WhoopCycleRow] = []
        var sleeps: [WhoopSleepRow] = []
        var workouts: [WhoopWorkoutRow] = []
        var journal: [WhoopJournalRow] = []

        if let data = csvData[Self.cyclesName] {
            cycles = parseCycles(CSVTable(data: data))
        }
        if let data = csvData[Self.sleepsName] {
            sleeps = parseSleeps(CSVTable(data: data))
        }
        if let data = csvData[Self.workoutsName] {
            workouts = parseWorkouts(CSVTable(data: data))
        }
        if let data = csvData[Self.journalName] {
            journal = parseJournal(CSVTable(data: data))
        }

        let summary = makeSummary(cycles: cycles, sleeps: sleeps, workouts: workouts, journal: journal)
        return WhoopImportResult(
            cycles: cycles, sleeps: sleeps, workouts: workouts, journal: journal, summary: summary
        )
    }

    // MARK: - Locate + load CSVs

    /// Return `[lowercasedFilename: rawData]` for every recognised CSV in the
    /// folder or zip at `url`.
    private func loadCSVData(from url: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { throw ImportError.fileNotFound(url.path) }

        if isDir.boolValue {
            return try loadFromFolder(url)
        }

        // A file — treat as zip if it has a zip extension or opens as an archive.
        if url.pathExtension.lowercased() == "zip" {
            return try loadFromZip(url)
        }
        // Try as a zip anyway; if that fails, it's not a supported input.
        if let z = try? loadFromZip(url) { return z }
        throw ImportError.notAZipOrFolder(url.path)
    }

    private func loadFromFolder(_ folder: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var result: [String: Data] = [:]
        var total = 0

        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.fileNotFound(folder.path)
        }

        for case let fileURL as URL in enumerator {
            let base = fileURL.lastPathComponent.lowercased()
            guard base.hasSuffix(".csv") else { continue }   // skip GPX/ECG/etc.
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.maxEntryBytes { continue }   // refuse an implausibly large CSV
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            // Route by English name, localized filename alias, then header content (issue #3).
            if let key = Self.canonicalKey(base: base, data: data), result[key] == nil {
                if total + data.count > maxTotalBytes { break }   // aggregate RAM ceiling across retained CSVs
                result[key] = data
                total += data.count
            }
        }
        return result
    }

    /// Per-CSV uncompressed ceiling. Real Whoop CSV bundles are a few MB; this guards against a
    /// zip-bomb where a tiny entry inflates to many GB and OOM-kills the app.
    private static let maxEntryBytes = 256 << 20   // 256 MB

    private func loadFromZip(_ zipURL: URL) throws -> [String: Data] {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ImportError.notAZipOrFolder(zipURL.path)
        }

        var result: [String: Data] = [:]
        var total = 0

        for entry in archive {
            guard entry.type == .file else { continue }
            let base = (entry.path as NSString).lastPathComponent.lowercased()
            guard base.hasSuffix(".csv") else { continue }   // skip GPX/ECG/etc.
            // Reject entries whose declared uncompressed size is implausible (zip-bomb guard)...
            let declared = Int(exactly: entry.uncompressedSize) ?? Int.max
            if declared > Self.maxEntryBytes { continue }
            var buffer = Data()
            var written = 0
            do {
                // extract() verifies CRC32 (skipCRC32 defaults to false) and throws on a
                // mismatch/truncation; the running budget also stops a lying ZIP64 header mid-stream.
                _ = try archive.extract(entry) { chunk in
                    written += chunk.count
                    if written > Self.maxEntryBytes { throw CancellationError() }
                    buffer.append(chunk)
                }
            } catch {
                // Corrupt / truncated / oversized entry: skip rather than import partial data.
                continue
            }
            guard !buffer.isEmpty else { continue }
            // Route by English name, localized filename alias, then header content (issue #3).
            if let key = Self.canonicalKey(base: base, data: buffer), result[key] == nil {
                if total + buffer.count > maxTotalBytes { break }   // aggregate RAM ceiling across retained CSVs
                result[key] = buffer
                total += buffer.count
            }
        }
        return result
    }

    // MARK: - physiological_cycles.csv

    func parseCycles(_ table: CSVTable) -> [WhoopCycleRow] {
        var out: [WhoopCycleRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopCycleRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.cycleEnd   = WhoopTime.parse(row.cell("cycle_end_time"), offsetMinutes: tz)

            // Skip rows with no usable timestamp at all.
            if r.cycleStart == nil && r.cycleEnd == nil { continue }

            r.recoveryScore    = row.double("recovery_score_pct")
            r.restingHeartRate = row.double("resting_heart_rate_bpm", "resting_heart_rate")
            r.hrvMs            = row.double("heart_rate_variability_ms", "heart_rate_variability_rmssd_ms")
            // #1849: a Fahrenheit WHOOP export ships `skin_temp_f`, NOT `skin_temp_celsius`. Treating
            // the two as aliases stored the °F value unconverted (92.3 °F → 92.3 in a °C column),
            // which read as a lethal fever and poisoned the baseline. Read each as its OWN key and
            // convert the Fahrenheit value on the way in. `skin_temp_celsius` wins when both are
            // present (a Celsius export is the canonical form).
            if let c = row.double("skin_temp_celsius") {
                r.skinTempCelsius = c
            } else if let f = row.double("skin_temp_f") {
                r.skinTempCelsius = (f - 32.0) * 5.0 / 9.0
            }
            r.bloodOxygenPct   = row.double("blood_oxygen_pct", "blood_oxygen_pct_pct")
            r.dayStrain        = row.double("day_strain")
            r.energyKcal       = row.double("energy_burned_cal")  // CSV "(cal)" == kcal
            r.avgHeartRate     = row.double("average_hr_bpm", "average_heart_rate_bpm")
            r.maxHeartRate     = row.double("max_hr_bpm", "max_heart_rate_bpm")

            r.sleepOnset = WhoopTime.parse(row.cell("sleep_onset"), offsetMinutes: tz)
            r.wakeOnset  = WhoopTime.parse(row.cell("wake_onset"), offsetMinutes: tz)

            r.sleepPerformancePct = row.double("sleep_performance_pct")
            r.respiratoryRate     = row.double("respiratory_rate_rpm", "respiratory_rate")
            r.asleepDurationMin   = row.double("asleep_duration_min")
            r.inBedDurationMin    = row.double("in_bed_duration_min")
            r.lightSleepDurationMin = row.double("light_sleep_duration_min")
            r.deepSleepDurationMin  = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            r.remDurationMin        = row.double("rem_duration_min")
            r.awakeDurationMin      = row.double("awake_duration_min")
            r.sleepEfficiencyPct    = row.double("sleep_efficiency_pct")
            r.sleepConsistencyPct   = row.double("sleep_consistency_pct")
            r.sleepNeedMin          = row.double("sleep_need_min")
            r.sleepDebtMin          = row.double("sleep_debt_min")

            out.append(r)
        }
        return out
    }

    // MARK: - sleeps.csv

    func parseSleeps(_ table: CSVTable) -> [WhoopSleepRow] {
        var out: [WhoopSleepRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopSleepRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.sleepOnset = WhoopTime.parse(row.cell("sleep_onset"), offsetMinutes: tz)
            r.wakeOnset  = WhoopTime.parse(row.cell("wake_onset"), offsetMinutes: tz)

            if r.cycleStart == nil && r.sleepOnset == nil && r.wakeOnset == nil { continue }

            r.isNap = row.bool("nap") ?? false

            r.sleepPerformancePct = row.double("sleep_performance_pct")
            r.respiratoryRate     = row.double("respiratory_rate_rpm", "respiratory_rate")
            r.asleepDurationMin   = row.double("asleep_duration_min")
            r.inBedDurationMin    = row.double("in_bed_duration_min")
            r.lightSleepDurationMin = row.double("light_sleep_duration_min")
            r.deepSleepDurationMin  = row.double("deep_sws_duration_min", "deep_sleep_duration_min")
            r.remDurationMin        = row.double("rem_duration_min")
            r.awakeDurationMin      = row.double("awake_duration_min")
            r.sleepEfficiencyPct    = row.double("sleep_efficiency_pct")
            r.sleepConsistencyPct   = row.double("sleep_consistency_pct")
            r.sleepNeedMin          = row.double("sleep_need_min")
            r.sleepDebtMin          = row.double("sleep_debt_min")

            out.append(r)
        }
        return out
    }

    // MARK: - workouts.csv

    func parseWorkouts(_ table: CSVTable) -> [WhoopWorkoutRow] {
        var out: [WhoopWorkoutRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopWorkoutRow()
            r.tzOffsetMin = tz
            r.cycleStart   = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.workoutStart = WhoopTime.parse(row.cell("workout_start_time"), offsetMinutes: tz)
            r.workoutEnd   = WhoopTime.parse(row.cell("workout_end_time"), offsetMinutes: tz)

            if r.workoutStart == nil && r.workoutEnd == nil && r.cycleStart == nil { continue }

            r.activityName   = row.cell("activity_name")
            // Parsed VERBATIM (WHOOP's 0–21 scale) to preserve the CSV round-trip contract; the
            // 0–21→0–100 Effort rescale is applied at the store-write (WhoopImporter), like day_strain.
            r.activityStrain = row.double("activity_strain")
            r.energyKcal     = row.double("energy_burned_cal")  // CSV "(cal)" == kcal
            r.avgHeartRate   = row.double("average_hr_bpm", "average_heart_rate_bpm")
            r.maxHeartRate   = row.double("max_hr_bpm", "max_heart_rate_bpm")

            r.hrZone1Pct = row.double("hr_zone_1_pct", "zone_1_pct", "hr_zone_1_pct_pct")
            r.hrZone2Pct = row.double("hr_zone_2_pct", "zone_2_pct", "hr_zone_2_pct_pct")
            r.hrZone3Pct = row.double("hr_zone_3_pct", "zone_3_pct", "hr_zone_3_pct_pct")
            r.hrZone4Pct = row.double("hr_zone_4_pct", "zone_4_pct", "hr_zone_4_pct_pct")
            r.hrZone5Pct = row.double("hr_zone_5_pct", "zone_5_pct", "hr_zone_5_pct_pct")

            // Optional GPS / distance / altitude columns.
            r.distanceMeters       = row.double("distance_meters", "distance_meter")
            r.altitudeGainMeters   = row.double("altitude_gain_meters", "altitude_gain_meter")
            r.altitudeChangeMeters = row.double("altitude_change_meters", "altitude_change_meter")

            out.append(r)
        }
        return out
    }

    // MARK: - journal_entries.csv

    func parseJournal(_ table: CSVTable) -> [WhoopJournalRow] {
        var out: [WhoopJournalRow] = []
        out.reserveCapacity(table.rows.count)
        for row in table.rows {
            let tz = WhoopTime.tzOffsetMinutes(row.cell("cycle_timezone"))

            var r = WhoopJournalRow()
            r.tzOffsetMin = tz
            r.cycleStart = WhoopTime.parse(row.cell("cycle_start_time"), offsetMinutes: tz)
            r.question = row.cell("question_text", "question")
            // #631: the REAL WHOOP export header is "Answered yes" (-> answered_yes), not the
            // "Answered yes/no" NOOP's own exporter writes (-> answered_yes_no). Every real WHOOP
            // journal import silently zeroed out to "without" because neither of the old keys ever
            // matched, regardless of the account's actual answers.
            r.answer   = row.cell("answered_yes", "answered_yes_no", "answer", "answer_text")
            r.notes    = row.cell("notes")

            // A journal row is only meaningful if it has a question.
            if r.question == nil && r.answer == nil && r.notes == nil { continue }
            out.append(r)
        }
        return out
    }

    // MARK: - Summary

    private func makeSummary(
        cycles: [WhoopCycleRow],
        sleeps: [WhoopSleepRow],
        workouts: [WhoopWorkoutRow],
        journal: [WhoopJournalRow]
    ) -> ImportSummary {
        var dates: [Date] = []
        dates.append(contentsOf: cycles.compactMap { $0.cycleStart })
        dates.append(contentsOf: sleeps.compactMap { $0.sleepOnset ?? $0.cycleStart })
        dates.append(contentsOf: workouts.compactMap { $0.workoutStart ?? $0.cycleStart })
        dates.append(contentsOf: journal.compactMap { $0.cycleStart })

        let count = cycles.count + sleeps.count + workouts.count + journal.count
        return ImportSummary(
            sourceKind: .whoopExport,
            recordCount: count,
            earliest: dates.min(),
            latest: dates.max(),
            countsByCategory: [
                "cycles": cycles.count,
                "sleeps": sleeps.count,
                "workouts": workouts.count,
                "journal": journal.count,
            ]
        )
    }
}
