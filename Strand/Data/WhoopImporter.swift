import Foundation
import WhoopStore
import StrandImport

/// Maps a parsed Whoop CSV export into the on-device WhoopStore tables the UI reads
/// (dailyMetric + sleepSession), so importing lights up the full history immediately.
enum WhoopImporter {

    /// The WHOOP CSV mapping revision, stamped into the Import test-mode parser line. Bump when this
    /// importer's column->store mapping changes so a shared report's parser version is unambiguous.
    static let importerVersion = 1

    @discardableResult
    static func importExport(url: URL, into store: WhoopStore, deviceId: String,
                             trace: (@Sendable ([String]) -> Void)? = nil) async throws -> ImportSummary {
        let result = try ImportCoordinator().importWhoopExport(from: url)

        // physiological_cycles → DailyMetric (one row per sleep-to-sleep day)
        var metrics: [DailyMetric] = []
        for c in result.cycles {
            guard let day = cycleDay(wake: c.wakeOnset, end: c.cycleEnd, start: c.cycleStart,
                                     tzOffsetMin: c.tzOffsetMin) else { continue }
            metrics.append(DailyMetric(
                day: day,
                totalSleepMin: c.asleepDurationMin,
                // CSV "Sleep efficiency %" (0–100) → the store's native 0–1 fraction at the boundary.
                efficiency: WhoopExportImporter.fractionFromImportedEfficiencyPct(c.sleepEfficiencyPct),
                deepMin: c.deepSleepDurationMin,
                remMin: c.remDurationMin,
                lightMin: c.lightSleepDurationMin,
                disturbances: nil,
                restingHr: c.restingHeartRate.map { Int($0.rounded()) },
                avgHrv: c.hrvMs,
                recovery: c.recoveryScore,
                // WHOOP Day Strain (0–21) → NOOP's 0–100 Effort axis at the store boundary.
                strain: WhoopExportImporter.effortFromImportedDayStrain(c.dayStrain),
                exerciseCount: nil,
                spo2Pct: c.bloodOxygenPct,
                skinTempDevC: c.skinTempCelsius,   // NOTE: Whoop export gives absolute °C, not a baseline deviation
                respRateBpm: c.respiratoryRate))
        }

        // sleeps → CachedSleepSession (stage durations encoded as JSON; export has no per-epoch timeline)
        var sessions: [CachedSleepSession] = []
        for s in result.sleeps where !s.isNap {
            guard let onset = s.sleepOnset, let wake = s.wakeOnset else { continue }
            let stages: [String: Double] = [
                "light": s.lightSleepDurationMin ?? 0,
                "deep": s.deepSleepDurationMin ?? 0,
                "rem": s.remDurationMin ?? 0,
                "awake": s.awakeDurationMin ?? 0,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: stages))
                .flatMap { String(data: $0, encoding: .utf8) }
            sessions.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(wake.timeIntervalSince1970),
                efficiency: WhoopExportImporter.fractionFromImportedEfficiencyPct(s.sleepEfficiencyPct),
                restingHr: nil, avgHrv: nil, stagesJSON: json))
        }

        // Capture the rows the store ACTUALLY wrote (summed SQLite changes) so the Import test mode can
        // report mapped-vs-persisted per stage. Capturing the existing return value changes nothing about
        // what is saved; the calls, their order and their effect are identical with the trace on or off.
        let metricsWritten = try await store.upsertDailyMetrics(metrics, deviceId: deviceId)
        let sessionsWritten = try await store.upsertSleepSessions(sessions, deviceId: deviceId)

        // Generic metric series — every cycle field, keyed, for the explorer + correlations.
        var points: [MetricPoint] = []
        func add(_ day: String, _ key: String, _ v: Double?) {
            if let v { points.append(MetricPoint(day: day, key: key, value: v)) }
        }
        for c in result.cycles {
            guard let day = cycleDay(wake: c.wakeOnset, end: c.cycleEnd, start: c.cycleStart,
                                     tzOffsetMin: c.tzOffsetMin) else { continue }
            add(day, "recovery", c.recoveryScore);        add(day, "strain", WhoopExportImporter.effortFromImportedDayStrain(c.dayStrain))
            add(day, "rhr", c.restingHeartRate);          add(day, "hrv", c.hrvMs)
            add(day, "spo2", c.bloodOxygenPct);           add(day, "skin_temp", c.skinTempCelsius)
            add(day, "resp_rate", c.respiratoryRate);     add(day, "energy_kcal", c.energyKcal)
            add(day, "avg_hr", c.avgHeartRate);           add(day, "max_hr", c.maxHeartRate)
            add(day, "sleep_total_min", c.asleepDurationMin); add(day, "in_bed_min", c.inBedDurationMin)
            add(day, "sleep_deep_min", c.deepSleepDurationMin); add(day, "sleep_rem_min", c.remDurationMin)
            add(day, "sleep_light_min", c.lightSleepDurationMin); add(day, "awake_min", c.awakeDurationMin)
            add(day, "sleep_efficiency", c.sleepEfficiencyPct); add(day, "sleep_performance", c.sleepPerformancePct)
            add(day, "sleep_consistency", c.sleepConsistencyPct); add(day, "sleep_need_min", c.sleepNeedMin)
            add(day, "sleep_debt_min", c.sleepDebtMin)
            if let deep = c.deepSleepDurationMin, let rem = c.remDurationMin {
                add(day, "restorative_min", deep + rem)
                if let asleep = c.asleepDurationMin, asleep > 0 {
                    add(day, "restorative_pct", (deep + rem) / asleep * 100)
                }
            }
            if let asleep = c.asleepDurationMin, let need = c.sleepNeedMin, need > 0 {
                add(day, "hours_vs_needed_pct", asleep / need * 100)
            }
        }
        // Derived: a daily stress proxy from RHR (up) + HRV (down) vs the personal baseline.
        func meanStd(_ a: [Double]) -> (Double, Double) {
            guard !a.isEmpty else { return (0, 1) }
            let m = a.reduce(0, +) / Double(a.count)
            let v = a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)
            return (m, max(v.squareRoot(), 0.0001))
        }
        let (rm, rs) = meanStd(result.cycles.compactMap(\.restingHeartRate))
        let (hm, hs) = meanStd(result.cycles.compactMap(\.hrvMs))
        for c in result.cycles {
            guard let rhr = c.restingHeartRate, let hrv = c.hrvMs,
                  let day = cycleDay(wake: c.wakeOnset, end: c.cycleEnd, start: c.cycleStart,
                                     tzOffsetMin: c.tzOffsetMin) else { continue }
            let z = 0.6 * ((rhr - rm) / rs) - 0.6 * ((hrv - hm) / hs)
            add(day, "stress", max(0, min(3, 1.5 + z)))
        }
        // Derived: daily HR-zone minutes + strength-activity time from workouts.
        var zoneByDay: [String: [Double]] = [:]
        var strengthByDay: [String: Double] = [:]
        for w in result.workouts {
            guard let s = w.workoutStart, let e = w.workoutEnd else { continue }
            let day = dayString(s, tzOffsetMin: w.tzOffsetMin)
            let dur = e.timeIntervalSince(s) / 60.0
            let zp = [w.hrZone1Pct, w.hrZone2Pct, w.hrZone3Pct, w.hrZone4Pct, w.hrZone5Pct]
            var arr = zoneByDay[day] ?? [0, 0, 0, 0, 0]
            for i in 0..<5 { if let p = zp[i] { arr[i] += dur * p / 100.0 } }
            zoneByDay[day] = arr
            if let n = w.activityName?.lowercased(), n.contains("strength") || n.contains("weight") {
                strengthByDay[day, default: 0] += dur
            }
        }
        for (day, a) in zoneByDay {
            add(day, "hr_zone1_min", a[0]); add(day, "hr_zone2_min", a[1]); add(day, "hr_zone3_min", a[2])
            add(day, "hr_zone4_min", a[3]); add(day, "hr_zone5_min", a[4])
            add(day, "hr_zones13_min", a[0] + a[1] + a[2]); add(day, "hr_zones45_min", a[3] + a[4])
            add(day, "hr_zones_all_min", a.reduce(0, +))
        }
        for (day, m) in strengthByDay { add(day, "strength_min", m) }
        try await store.upsertMetricSeries(points, deviceId: deviceId)

        // Journal behaviours → correlation insights.
        // #136: journal_entries.csv keys only by cycle_start (the onset evening). Map each cycle's onset to
        // its WAKE day so an entry lands on the same day as the recovery/sleep it correlates against — the
        // day parseCycles and the native journal use. Keying off the onset put every entry one day early,
        // so it never matched its outcome and all historic days collapsed into "Without" (issue #136).
        var wakeDayByStart: [Int: String] = [:]
        for c in result.cycles {
            guard let start = c.cycleStart,
                  let wake = cycleDay(wake: c.wakeOnset, end: c.cycleEnd, start: c.cycleStart,
                                      tzOffsetMin: c.tzOffsetMin) else { continue }
            wakeDayByStart[Int(start.timeIntervalSince1970)] = wake
        }
        let journal: [JournalEntry] = result.journal.compactMap { j in
            guard let start = j.cycleStart, let q = j.question else { return nil }
            // Fall back to the onset day only when the cycle isn't in the export.
            let day = wakeDayByStart[Int(start.timeIntervalSince1970)]
                ?? dayString(start, tzOffsetMin: j.tzOffsetMin)
            return JournalEntry(day: day,
                                question: q,
                                answeredYes: (j.answer ?? "").lowercased() == "true",
                                notes: j.notes)
        }
        // #136: the wake-day fix moves an entry's day, so a naive re-import would leave the pre-fix
        // onset-keyed rows behind as duplicates. Atomically clear + re-write EXACTLY the day span we
        // import, so journal outside the imported range (e.g. from an earlier, wider export) is never
        // touched, and a crash mid-import can't drop the range. Same "re-import replaces this period"
        // semantics daily/sleep already have. Empty journal → nothing cleared, nothing written.
        if let lo = journal.map(\.day).min(), let hi = journal.map(\.day).max() {
            _ = try await store.replaceJournalRange(journal, deviceId: deviceId, from: lo, to: hi)
        }

        // Workouts.
        let workouts: [WorkoutRow] = result.workouts.compactMap { w in
            guard let s = w.workoutStart, let e = w.workoutEnd else { return nil }
            let zones = ["z1": w.hrZone1Pct, "z2": w.hrZone2Pct, "z3": w.hrZone3Pct,
                         "z4": w.hrZone4Pct, "z5": w.hrZone5Pct].compactMapValues { $0 }
            let zjson = (try? JSONSerialization.data(withJSONObject: zones))
                .flatMap { String(data: $0, encoding: .utf8) }
            return WorkoutRow(startTs: Int(s.timeIntervalSince1970), endTs: Int(e.timeIntervalSince1970),
                              sport: w.activityName ?? "Workout", source: "whoop",
                              durationS: e.timeIntervalSince(s), energyKcal: w.energyKcal,
                              avgHr: w.avgHeartRate.map { Int($0.rounded()) },
                              maxHr: w.maxHeartRate.map { Int($0.rounded()) },
                              strain: WhoopExportImporter.effortFromImportedDayStrain(w.activityStrain), distanceM: w.distanceMeters,
                              zonesJSON: zjson, notes: nil, steps: nil)
        }
        let workoutsWritten = try await store.upsertWorkouts(workouts, deviceId: deviceId)

        // Import & Data Ingest test mode (Test Centre): emit the per-stage / reject / day-delta trace iff
        // the mode is on. The caller passes a non-nil `trace` ONLY when TestCentre.active(.dataImport), so
        // nothing here runs when the mode is off (zero cost). The numbers are the SAME ones the import just
        // produced (parsed counts + the rows the store reported writing), so emitting them changes nothing
        // about what was saved. No raw cell value or file name is in any of these lines.
        if let trace {
            let c = result.summary.countsByCategory
            // Per-stage rowsIn is the rows actually HANDED to the store (after the app's mapping drops), so
            // rowsOut < rowsIn isolates the STORE-write delta - the day-owner-collision / "didn't save" tell
            // (#601 / #749) - rather than conflating it with the parser/map drop, which the reject line owns.
            // dailyMetric is keyed by (deviceId, day), so metrics.count == the mapped distinct days.
            let daysMapped = Set(metrics.map { $0.day }).count
            // Rows the PARSER produced but the app map then dropped (a cycle with no cycleStart, a non-nap
            // sleep with no onset/wake, a workout with no start/end): the genuine ingest reject count.
            let parsedCycles = c["cycles"] ?? 0
            let parsedSleeps = c["sleeps"] ?? 0
            let parsedWorkouts = c["workouts"] ?? 0
            let droppedInMap = max(0, parsedCycles - metrics.count)
                + max(0, parsedSleeps - sessions.count)
                + max(0, parsedWorkouts - workouts.count)
            let lines: [String] = [
                ImportTrace.parserVersionLine(sourceKind: .whoopExport, importerVersion: importerVersion),
                ImportTrace.stageLine(category: "cycles", rowsIn: metrics.count, rowsOut: metricsWritten),
                ImportTrace.stageLine(category: "sleeps", rowsIn: sessions.count, rowsOut: sessionsWritten),
                ImportTrace.stageLine(category: "workouts", rowsIn: workouts.count, rowsOut: workoutsWritten),
                // #1617: which metric COLUMNS the file carried. The stage lines above count ROWS, so an
                // export whose Blood Oxygen column is absent looks identical to one where it arrived — and
                // a card that stays empty after a clean import is then indistinguishable from a failed
                // write. Counted on the parsed rows, before any store write, so it says the same thing on
                // both platforms. Emitted between the stage and reject lines, matching the Kotlin order.
                ImportTrace.columnCoverageLine(stage: "cycles",
                                               rows: metrics.count,
                                               counts: importColumnCoverage(metrics)),
                ImportTrace.rejectLine(droppedRows: droppedInMap, skippedSpans: result.summary.skippedSpans),
                ImportTrace.dayDeltaLine(category: "cycles", daysMapped: daysMapped, daysPersisted: metricsWritten),
            ]
            trace(lines)
        }

        return result.summary
    }

    /// The NOOP day a WHOOP cycle belongs to: the local calendar day you WOKE. See
    /// `WhoopDayKeying.wakeDayKey` for the full rationale (WHOOP exports are onset-to-onset, so a
    /// cycle's start is the evening before; keying off it blanked Today for import-only users, v8.2.1).
    private static func cycleDay(wake: Date?, end: Date?, start: Date?, tzOffsetMin: Int) -> String? {
        WhoopDayKeying.wakeDayKey(wake: wake, end: end, start: start, tzOffsetMin: tzOffsetMin)
    }

    /// Local-calendar day string for the cycle's own UTC offset.
    private static func dayString(_ d: Date, tzOffsetMin: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: tzOffsetMin * 60) ?? TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
