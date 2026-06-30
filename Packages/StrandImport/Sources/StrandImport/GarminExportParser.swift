import Foundation

// MARK: - Garmin Connect "Export Your Data" (GDPR) wellness parser
//
// The GDPR ZIP holds, under DI_CONNECT/DI_Connect_Wellness/, dated wellness JSON files. The FIT
// activity files in the same ZIP are wave-1's `ActivityFileImporter` lane; this lane reads the
// WELLNESS rollups only (documented GDPR export field names; NOOP's own clean parser):
//
//   *_sleepData.json   — array of nights: calendarDate, sleepStartTimestampGMT / sleepEndTimestampGMT
//                        (epoch MILLIS or ISO), deepSleepSeconds, lightSleepSeconds, remSleepSeconds,
//                        awakeSleepSeconds, unmeasurableSeconds, optional overallSleepScore /
//                        retro / sleepWindowConfirmationType.
//   *_UserBioMetricProfileData.json / daily summary — array of days carrying restingHeartRate,
//                        minHeartRate / maxHeartRate, steps / totalSteps, totalDistanceMeters,
//                        averageStressLevel, calendarDate.
//
// Garmin's GDPR JSON sometimes uses an `*InSeconds` health-API variant of the same field; we read
// both spellings. A field absent in the export stays nil (honest).

enum GarminExportParser {

    static func parse(_ files: [String: Data]) -> (days: [WearableDailyRow], sleeps: [WearableSleepSession]) {
        var byDay: [String: WearableDailyRow] = [:]
        var sleeps: [WearableSleepSession] = []
        func day(_ key: String) -> WearableDailyRow { byDay[key] ?? WearableDailyRow(day: key) }

        for (name, data) in files {
            let base = (name as NSString).lastPathComponent
            // A Garmin wellness file is usually a top-level array; some are { ... : [ ... ] }.
            let records = elements(data)

            if base.contains("sleepdata") || records.contains(where: { $0["deepSleepSeconds"] != nil || $0["sleepStartTimestampGMT"] != nil || $0["DeepSleepDurationInSeconds"] != nil }) {
                for s in records {
                    guard let session = sleepSession(s), let key = sleepDayKey(s, session) else { continue }
                    sleeps.append(session)
                    var row = day(key)
                    row.totalSleepMin = row.totalSleepMin ?? session.totalSleepMin
                    row.deepMin = row.deepMin ?? session.deepMin
                    row.lightMin = row.lightMin ?? session.lightMin
                    row.remMin = row.remMin ?? session.remMin
                    row.awakeMin = row.awakeMin ?? session.awakeMin
                    row.sleepScore = row.sleepScore ?? session.sleepScore
                    row.respRateBpm = row.respRateBpm ?? session.respRateBpm   // night resp → day rollup (#17)
                    if row.restingHr == nil { row.restingHr = session.lowestHr }
                    byDay[key] = row
                }
            } else {
                // A daily-summary file: fold RHR / steps / stress / distance per calendarDate.
                for d in records {
                    guard let key = WearableJSON.str(d, "calendarDate") ?? WearableJSON.str(d, "calendar_date") else { continue }
                    var row = day(key)
                    row.restingHr = WearableJSON.posInt(d, "restingHeartRate") ?? WearableJSON.posInt(d, "restingHeartRateInBeatsPerMinute") ?? row.restingHr
                    row.steps = WearableJSON.posInt(d, "totalSteps") ?? WearableJSON.posInt(d, "steps") ?? row.steps
                    row.distanceM = WearableJSON.posDbl(d, "totalDistanceMeters") ?? WearableJSON.posDbl(d, "totalDistanceInMeters") ?? row.distanceM
                    row.activeKcal = WearableJSON.posDbl(d, "activeKilocalories") ?? WearableJSON.posDbl(d, "activeCalories") ?? row.activeKcal
                    row.avgStress = WearableJSON.posInt(d, "averageStressLevel") ?? WearableJSON.posInt(d, "avgStressLevel") ?? row.avgStress
                    byDay[key] = row
                }
            }
        }
        return (Array(byDay.values), sleeps)
    }

    // MARK: - Helpers

    /// Flatten a Garmin file into an array of record dicts, accepting a bare array, a single object, or
    /// a `{ key: [ ... ] }` wrapper (the GDPR files vary by category).
    private static func elements(_ data: Data) -> [[String: Any]] {
        if let arr = WearableJSON.array(data) { return arr.compactMap { $0 as? [String: Any] } }
        guard let obj = WearableJSON.object(data) else { return [] }
        // Wrapper: take the first array-of-objects value.
        for v in obj.values {
            if let arr = v as? [[String: Any]] { return arr }
        }
        // A single-record object.
        return [obj]
    }

    private static func sleepSession(_ s: [String: Any]) -> WearableSleepSession? {
        guard let start = instant(s, "sleepStartTimestampGMT", "StartTimeInSeconds"),
              let end = instant(s, "sleepEndTimestampGMT", "EndTimeInSeconds"),
              end > start else { return nil }

        func sec(_ a: String, _ b: String) -> Double? {
            (WearableJSON.posDbl(s, a) ?? WearableJSON.posDbl(s, b)).map { $0 / 60.0 }
        }
        let deep = sec("deepSleepSeconds", "DeepSleepDurationInSeconds")
        let light = sec("lightSleepSeconds", "LightSleepDurationInSeconds")
        let rem = sec("remSleepSeconds", "RemSleepInSeconds")
        let awake = sec("awakeSleepSeconds", "AwakeDurationInSeconds")
        let total = [deep, light, rem].compactMap { $0 }.reduce(0, +)

        return WearableSleepSession(
            start: start,
            end: end,
            deepMin: deep,
            lightMin: light,
            remMin: rem,
            awakeMin: awake,
            totalSleepMin: total > 0 ? total : nil,
            efficiencyPct: nil,
            avgHr: nil,
            lowestHr: WearableJSON.posInt(s, "restingHeartRate"),
            avgHrvMs: WearableJSON.posDbl(s, "avgOvernightHrv") ?? WearableJSON.posDbl(s, "averageHrvValue"),
            respRateBpm: WearableJSON.posDbl(s, "averageRespirationValue") ?? WearableJSON.posDbl(s, "averageRespiration"),
            sleepScore: WearableJSON.posInt(s, "overallSleepScore") ?? sleepScoreNested(s),
            stages: [])   // GDPR sleepData carries durations, not a per-segment timeline we trust to map
    }

    /// `overallSleepScore` is sometimes nested under `sleepScores.overall.value`.
    private static func sleepScoreNested(_ s: [String: Any]) -> Int? {
        guard let scores = s["sleepScores"] as? [String: Any],
              let overall = scores["overall"] as? [String: Any] else { return nil }
        return WearableJSON.posInt(overall, "value")
    }

    private static func sleepDayKey(_ s: [String: Any], _ session: WearableSleepSession) -> String? {
        WearableJSON.str(s, "calendarDate") ?? WearableExportImporter.dayString(session.end)
    }

    /// Parse a Garmin timestamp that may be epoch MILLISECONDS (number), epoch SECONDS, or an ISO
    /// string. `secKey` is the health-API "...InSeconds" alias.
    private static func instant(_ v: [String: Any], _ msKey: String, _ secKey: String) -> Date? {
        if let ms = WearableJSON.dbl(v, msKey) {
            // Heuristic: a value ≥ 1e11 is epoch-millis (≈ year 2001+); smaller is epoch-seconds.
            return Date(timeIntervalSince1970: ms >= 1e11 ? ms / 1000.0 : ms)
        }
        if let s = WearableJSON.str(v, msKey), let d = WhoopTime.parse(s, offsetMinutes: 0) { return d }
        if let secs = WearableJSON.dbl(v, secKey) { return Date(timeIntervalSince1970: secs) }
        return nil
    }
}
