import Foundation

// MARK: - Oura API v2 document parser (PURE / network-free)
//
// Takes already-fetched JSON `data[]` arrays (the OuraAPIClient does the I/O in the app target) and maps
// them to NOOP's normalized models. Reuses the SAME field semantics as OuraExportParser — the account export
// and the API share field names (bedtime_start, total_sleep_duration, …) — and adds the hypnogram +
// time-series the file export never carried. Crafted-input safe via WearableJSON.

public enum OuraApiParser {

    /// Parse `sleep` documents (detailed periods; multiple per day are possible). Returns one
    /// `OuraSleepPeriod` per usable period plus a per-day sleep rollup folded onto `WearableDailyRow`.
    public static func parseSleep(_ docs: [[String: Any]]) -> (periods: [OuraSleepPeriod], days: [WearableDailyRow]) {
        var periods: [OuraSleepPeriod] = []
        var byDay: [String: WearableDailyRow] = [:]
        // The (rank, totalSleepMin) of the session CURRENTLY backing each day's rollup. Oura does not
        // guarantee session order within `docs`, so a later, higher-priority session must still be able
        // to displace an earlier one that already claimed the day — see the fold below.
        var dayWinner: [String: (rank: Int, totalMin: Double)] = [:]

        for s in docs {
            guard let start = WhoopTime.parseISOWithOffset(WearableJSON.str(s, "bedtime_start")),
                  let end = WhoopTime.parseISOWithOffset(WearableJSON.str(s, "bedtime_end")),
                  end > start else { continue }

            // A `deleted` sleep period (Oura's `type` enum) is a night the user removed in the Oura
            // app — skip it entirely so it neither becomes a session nor competes for the day's
            // rollup, matching OuraExportParser's CSV-side rule (#862).
            if WearableJSON.str(s, "type")?.lowercased() == "deleted" { continue }

            // Durations are SECONDS in the API → minutes.
            func minutes(_ k: String) -> Double? { WearableJSON.posDbl(s, k).map { $0 / 60.0 } }

            // Stages: prefer the finer 30-sec hypnogram, else the 5-min; never synthesize one.
            let stages: [WearableSleepStageInterval]
            if let p30 = WearableJSON.str(s, "sleep_phase_30_sec"), !p30.isEmpty {
                stages = OuraHypnogram.decode(p30, start: start, epochSeconds: 30)
            } else if let p5 = WearableJSON.str(s, "sleep_phase_5_min"), !p5.isEmpty {
                stages = OuraHypnogram.decode(p5, start: start, epochSeconds: 300)
            } else {
                stages = []
            }

            let session = WearableSleepSession(
                start: start, end: end,
                deepMin: minutes("deep_sleep_duration"),
                lightMin: minutes("light_sleep_duration"),
                remMin: minutes("rem_sleep_duration"),
                awakeMin: minutes("awake_time"),
                totalSleepMin: minutes("total_sleep_duration"),
                // Oura's `efficiency` is a 0-100 integer percent. NOOP's own sleep pipeline
                // (StrandAnalytics) stores `efficiency` as a 0-1 FRACTION everywhere it's computed
                // (asleep ÷ in-bed — see AnalyticsEngine.swift / SleepStageTotals.swift) and both
                // sleepSession.efficiency and dailyMetric.efficiency are that same shared column, so
                // normalize to the fraction convention here, at the parse boundary, rather than
                // writing Oura's native percent straight through.
                efficiencyPct: WearableJSON.posDbl(s, "efficiency").map { $0 / 100.0 },
                avgHr: WearableJSON.posInt(s, "average_heart_rate"),
                lowestHr: WearableJSON.posInt(s, "lowest_heart_rate"),
                avgHrvMs: WearableJSON.posDbl(s, "average_hrv"),
                respRateBpm: WearableJSON.posDbl(s, "average_breath"),
                sleepScore: nil,                                // the night's reference score comes from daily_sleep
                stages: stages)

            let movement = WearableJSON.str(s, "movement_30_sec").map(OuraHypnogram.movement) ?? []
            let hr = sampleSeries(s["heart_rate"])
            periods.append(OuraSleepPeriod(session: session, movement30s: movement, hr: hr))

            // Fold the night onto its calendar day (Oura's "day" = the wake day). Oura can list MULTIPLE
            // sessions for one day — a short nap/fragment alongside the real night — and first-write-wins
            // let whichever the API happened to return first claim every daily field, including a fragment
            // beating the true night (audited across a real 24-month dataset: 36 days where a sub-30-min
            // fragment's near-zero totalSleepMin and skewed restingHr won over an adjacent 250-780 min main
            // sleep, producing daily "resting HR" spikes to 90+ bpm from wake-dominated micro-sessions).
            // Select the day's MAIN session instead: Oura marks the primary sleep `type == "long_sleep"`,
            // which always outranks any other type; among same-rank candidates, the longer
            // total_sleep_duration wins. The winner supplies every rollup field as a UNIT — fields are
            // never mixed across two different sessions on the same day.
            let key = WearableJSON.str(s, "day") ?? WearableExportImporter.dayString(end)
            let isLongSleep = WearableJSON.str(s, "type")?.lowercased() == "long_sleep"
            let candidate = (rank: isLongSleep ? 1 : 0, totalMin: session.totalSleepMin ?? 0)
            let incumbent = dayWinner[key]
            let winsDay = incumbent.map {
                candidate.rank > $0.rank || (candidate.rank == $0.rank && candidate.totalMin > $0.totalMin)
            } ?? true
            if winsDay {
                dayWinner[key] = candidate
                var row = byDay[key] ?? WearableDailyRow(day: key)
                row.totalSleepMin = session.totalSleepMin
                row.deepMin = session.deepMin
                row.lightMin = session.lightMin
                row.remMin = session.remMin
                row.awakeMin = session.awakeMin
                row.efficiencyPct = session.efficiencyPct
                row.avgHrvMs = session.avgHrvMs
                row.respRateBpm = session.respRateBpm
                row.restingHr = session.lowestHr
                byDay[key] = row
            }
        }
        return (periods, Array(byDay.values))
    }

    /// Decode an Oura `PublicSample` object ({interval, items:[Double?], timestamp}) into HR points.
    /// Non-finite / non-positive items are dropped (Oura uses null/0 for gaps).
    static func sampleSeries(_ any: Any?) -> [OuraHRPoint] {
        guard let obj = any as? [String: Any],
              let interval = WearableJSON.dbl(obj, "interval"), interval > 0,
              let items = obj["items"] as? [Any],
              let t0 = WhoopTime.parseISOWithOffset(WearableJSON.str(obj, "timestamp")) else { return [] }
        var out: [OuraHRPoint] = []
        for (i, item) in items.enumerated() {
            guard let v = (item as? Double) ?? (item as? NSNumber)?.doubleValue, v.isFinite, v > 0 else { continue }
            // Finite-but-huge `ts` or `bpm` (e.g. a crafted `interval`/item of 1e300) must never trap
            // Int(...); skip the sample instead, mirroring WearableJSON.int's -9e18...9e18 range guard.
            let ts = t0.timeIntervalSince1970 + Double(i) * interval
            guard ts.isFinite, ts >= -9e18, ts <= 9e18, v <= 9e18 else { continue }
            out.append(OuraHRPoint(ts: Int(ts), bpm: Int(v)))
        }
        return out
    }
}
