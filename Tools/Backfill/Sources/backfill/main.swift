import Foundation
import StrandImport
import WhoopStore

// One-shot backfill: runs the (now-complete) import mapping against your export files
// directly into the app's on-device DB, so metricSeries / journal / workouts / body metrics
// populate WITHOUT the user re-importing. Mapping mirrors the app's WhoopImporter /
// AppleHealthImport (app target is the source of truth; duplicated here for this dev tool).

let home = FileManager.default.homeDirectoryForCurrentUser.path
let env = ProcessInfo.processInfo.environment
let dbPath = env["NOOP_DB_PATH"]
    ?? "\(home)/Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite"
func exportURL(from key: String) -> URL? {
    guard let path = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
}
let whoopExport = exportURL(from: "WHOOP_EXPORT_PATH")
let appleExport = exportURL(from: "APPLE_HEALTH_EXPORT_PATH")
let skipAppleHealth = env["SKIP_APPLE_HEALTH"] == "1"

func dayString(_ d: Date, tzOffsetMin: Int) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: tzOffsetMin * 60) ?? TimeZone(identifier: "UTC")!
    let c = cal.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}
func meanStd(_ a: [Double]) -> (Double, Double) {
    guard !a.isEmpty else { return (0, 1) }
    let m = a.reduce(0, +) / Double(a.count)
    let v = a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)
    return (m, max(v.squareRoot(), 0.0001))
}

let store = try await WhoopStore(path: dbPath)
print("opened \(dbPath)")

// ───── Whoop ─────
if let whoopExport, FileManager.default.fileExists(atPath: whoopExport.path) {
    print("importing Whoop export from \(whoopExport.path)")
    let r = try ImportCoordinator().importWhoopExport(from: whoopExport)
    var metrics: [DailyMetric] = []
    for c in r.cycles {
        guard let s = c.cycleStart else { continue }
        metrics.append(DailyMetric(day: dayString(s, tzOffsetMin: c.tzOffsetMin),
            totalSleepMin: c.asleepDurationMin, efficiency: c.sleepEfficiencyPct,
            deepMin: c.deepSleepDurationMin, remMin: c.remDurationMin, lightMin: c.lightSleepDurationMin,
            disturbances: nil, restingHr: c.restingHeartRate.map { Int($0.rounded()) }, avgHrv: c.hrvMs,
            recovery: c.recoveryScore, strain: c.dayStrain, exerciseCount: nil,
            spo2Pct: c.bloodOxygenPct, skinTempDevC: c.skinTempCelsius, respRateBpm: c.respiratoryRate))
    }
    try await store.upsertDailyMetrics(metrics, deviceId: "my-whoop")

    var sessions: [CachedSleepSession] = []
    for sl in r.sleeps where !sl.isNap {
        guard let onset = sl.sleepOnset, let wake = sl.wakeOnset else { continue }
        // Annotated because the four sources are `Double?` and the `?? 0` fallbacks otherwise infer a
        // heterogeneous literal, which stopped this tool compiling at all. `[String: Double]` matches the
        // minute-dict shape `SleepStageTotals` already decodes.
        let stages: [String: Double] = [
            "light": sl.lightSleepDurationMin ?? 0, "deep": sl.deepSleepDurationMin ?? 0,
            "rem": sl.remDurationMin ?? 0, "awake": sl.awakeDurationMin ?? 0,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: stages)).flatMap { String(data: $0, encoding: .utf8) }
        sessions.append(CachedSleepSession(startTs: Int(onset.timeIntervalSince1970), endTs: Int(wake.timeIntervalSince1970),
            efficiency: sl.sleepEfficiencyPct, restingHr: nil, avgHrv: nil, stagesJSON: json))
    }
    try await store.upsertSleepSessions(sessions, deviceId: "my-whoop")

    var points: [MetricPoint] = []
    func add(_ day: String, _ k: String, _ v: Double?) { if let v { points.append(MetricPoint(day: day, key: k, value: v)) } }
    for c in r.cycles {
        guard let s = c.cycleStart else { continue }
        let day = dayString(s, tzOffsetMin: c.tzOffsetMin)
        add(day, "recovery", c.recoveryScore); add(day, "strain", c.dayStrain)
        add(day, "rhr", c.restingHeartRate); add(day, "hrv", c.hrvMs)
        add(day, "spo2", c.bloodOxygenPct); add(day, "skin_temp", c.skinTempCelsius)
        add(day, "resp_rate", c.respiratoryRate); add(day, "energy_kcal", c.energyKcal)
        add(day, "avg_hr", c.avgHeartRate); add(day, "max_hr", c.maxHeartRate)
        add(day, "sleep_total_min", c.asleepDurationMin); add(day, "in_bed_min", c.inBedDurationMin)
        add(day, "sleep_deep_min", c.deepSleepDurationMin); add(day, "sleep_rem_min", c.remDurationMin)
        add(day, "sleep_light_min", c.lightSleepDurationMin); add(day, "awake_min", c.awakeDurationMin)
        add(day, "sleep_efficiency", c.sleepEfficiencyPct); add(day, "sleep_performance", c.sleepPerformancePct)
        add(day, "sleep_consistency", c.sleepConsistencyPct); add(day, "sleep_need_min", c.sleepNeedMin)
        add(day, "sleep_debt_min", c.sleepDebtMin)
        if let deep = c.deepSleepDurationMin, let rem = c.remDurationMin {
            add(day, "restorative_min", deep + rem)
            if let a = c.asleepDurationMin, a > 0 { add(day, "restorative_pct", (deep + rem) / a * 100) }
        }
        if let a = c.asleepDurationMin, let need = c.sleepNeedMin, need > 0 { add(day, "hours_vs_needed_pct", a / need * 100) }
    }
    let (rm, rs) = meanStd(r.cycles.compactMap(\.restingHeartRate))
    let (hm, hs) = meanStd(r.cycles.compactMap(\.hrvMs))
    for c in r.cycles {
        guard let s = c.cycleStart, let rhr = c.restingHeartRate, let hrv = c.hrvMs else { continue }
        let z = 0.6 * ((rhr - rm) / rs) - 0.6 * ((hrv - hm) / hs)
        add(dayString(s, tzOffsetMin: c.tzOffsetMin), "stress", max(0, min(3, 1.5 + z)))
    }
    var zoneByDay: [String: [Double]] = [:]; var strengthByDay: [String: Double] = [:]
    for w in r.workouts {
        guard let s = w.workoutStart, let e = w.workoutEnd else { continue }
        let day = dayString(s, tzOffsetMin: w.tzOffsetMin); let dur = e.timeIntervalSince(s) / 60.0
        let zp = [w.hrZone1Pct, w.hrZone2Pct, w.hrZone3Pct, w.hrZone4Pct, w.hrZone5Pct]
        var arr = zoneByDay[day] ?? [0, 0, 0, 0, 0]
        for i in 0..<5 { if let p = zp[i] { arr[i] += dur * p / 100.0 } }
        zoneByDay[day] = arr
        if let n = w.activityName?.lowercased(), n.contains("strength") || n.contains("weight") { strengthByDay[day, default: 0] += dur }
    }
    for (day, a) in zoneByDay {
        add(day, "hr_zone1_min", a[0]); add(day, "hr_zone2_min", a[1]); add(day, "hr_zone3_min", a[2])
        add(day, "hr_zone4_min", a[3]); add(day, "hr_zone5_min", a[4])
        add(day, "hr_zones13_min", a[0] + a[1] + a[2]); add(day, "hr_zones45_min", a[3] + a[4]); add(day, "hr_zones_all_min", a.reduce(0, +))
    }
    for (day, m) in strengthByDay { add(day, "strength_min", m) }
    try await store.upsertMetricSeries(points, deviceId: "my-whoop")

    let journal = r.journal.compactMap { j -> JournalEntry? in
        guard let s = j.cycleStart, let q = j.question else { return nil }
        return JournalEntry(day: dayString(s, tzOffsetMin: j.tzOffsetMin), question: q,
                            answeredYes: (j.answer ?? "").lowercased() == "true", notes: j.notes)
    }
    try await store.upsertJournal(journal, deviceId: "my-whoop")

    let workouts = r.workouts.compactMap { w -> WorkoutRow? in
        guard let s = w.workoutStart, let e = w.workoutEnd else { return nil }
        let zones = ["z1": w.hrZone1Pct, "z2": w.hrZone2Pct, "z3": w.hrZone3Pct, "z4": w.hrZone4Pct, "z5": w.hrZone5Pct].compactMapValues { $0 }
        let zjson = (try? JSONSerialization.data(withJSONObject: zones)).flatMap { String(data: $0, encoding: .utf8) }
        return WorkoutRow(startTs: Int(s.timeIntervalSince1970), endTs: Int(e.timeIntervalSince1970),
            sport: w.activityName ?? "Workout", source: "whoop", durationS: e.timeIntervalSince(s),
            energyKcal: w.energyKcal, avgHr: w.avgHeartRate.map { Int($0.rounded()) },
            maxHr: w.maxHeartRate.map { Int($0.rounded()) }, strain: w.activityStrain,
            distanceM: w.distanceMeters, zonesJSON: zjson, notes: nil, steps: nil)
    }
    try await store.upsertWorkouts(workouts, deviceId: "my-whoop")
    print("Whoop: \(metrics.count) days · \(points.count) metric points · \(journal.count) journal · \(workouts.count) workouts")
} else if let whoopExport {
    print("Whoop export not found at \(whoopExport.path)")
} else {
    print("WHOOP_EXPORT_PATH not set; skipping Whoop import")
}

// ───── Apple Health ─────
if !skipAppleHealth, let appleExport, FileManager.default.fileExists(atPath: appleExport.path) {
    print("parsing Apple Health (large — ~90s)…")
    let res = try ImportCoordinator().importAppleHealth(from: appleExport)
    let daily = AppleHealthAggregator.aggregate(res)
    let rows = daily.map { d in AppleDaily(day: d.day, steps: d.steps.map { Int($0) },
        activeKcal: d.activeKcal, basalKcal: d.basalKcal, vo2max: d.vo2max,
        avgHr: d.avgHr.map { Int($0.rounded()) }, maxHr: d.maxHr.map { Int($0.rounded()) },
        walkingHr: d.walkingHr.map { Int($0.rounded()) }, weightKg: d.weightKg) }
    try await store.upsertAppleDaily(rows, deviceId: "apple-health")
    let dm = daily.map { d in DailyMetric(day: d.day, totalSleepMin: d.asleepMin, efficiency: nil,
        deepMin: d.deepMin, remMin: d.remMin, lightMin: d.coreMin, disturbances: nil,
        restingHr: d.restingHr.map { Int($0.rounded()) }, avgHrv: d.hrvSDNN, recovery: nil, strain: nil,
        exerciseCount: nil, spo2Pct: d.spo2Pct, skinTempDevC: nil, respRateBpm: d.respRate) }
    try await store.upsertDailyMetrics(dm, deviceId: "apple-health")
    let pts = AppleHealthAggregator.metricPoints(daily).map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
    try await store.upsertMetricSeries(pts, deviceId: "apple-health")
    print("Apple: \(daily.count) days · \(pts.count) metric points")
} else if skipAppleHealth {
    print("Apple Health skipped")
} else if let appleExport {
    print("Apple export not found at \(appleExport.path)")
} else {
    print("APPLE_HEALTH_EXPORT_PATH not set; skipping Apple Health import")
}

print("DONE")
