import Foundation
import WhoopStore

/// Refresh only Charge cells whose existing 21-day baseline can include the selected night.
/// Uses persisted inputs and the same baseline/Recovery/Rest functions as the scorer; no detection.
public enum SleepRecalculationDependents {
    public static func updates(selectedDay: String, anchorDay: String, refreshBaseline: Bool, imported: [DailyMetric], computed: [DailyMetric],
                               sourceByDay: [String: String], importedSource: String,
                               hrvEpoch: Double, recoveryEpoch: Double) -> [SleepRecoveryUpdate] {
        guard let selected = Baselines.isoEpochDay(selectedDay), let anchor = Baselines.isoEpochDay(anchorDay),
              anchor >= selected, anchor - selected < ChargeBaselines.windowDays else { return [] }
        let resolved = ChargeBaselines.resolve(imported: imported, own: computed, anchorDay: anchorDay,
                                              hrvEpoch: hrvEpoch, recoveryEpoch: recoveryEpoch)
        let sourceDays = Set((imported + computed).filter { $0.day <= anchorDay }.map(\.day)).sorted()
        let respEpoch = max(recoveryEpoch, Baselines.deviceEraEpoch(
            sourceDays.map { (day: $0, sourceId: sourceByDay[$0] ?? importedSource) }))
        let respBase = Baselines.foldHistory(resolved.respHistory.values, dayKeys: resolved.respHistory.dayKeys,
                                             cfg: Baselines.respCfg, baselineEpoch: respEpoch)
        let skinCfg = Baselines.metricCfg["skin_temp"]!
        let skinHistory = ChargeBaselines.history(imported: [], own: computed.map { ($0.day, $0.skinTempC) },
            anchorDay: anchorDay, cfg: skinCfg, baselineEpoch: recoveryEpoch)
        let skinBase = Baselines.foldHistory(skinHistory.values, dayKeys: skinHistory.dayKeys,
                                             cfg: skinCfg, baselineEpoch: recoveryEpoch)
        var updates: [SleepRecoveryUpdate] = []
        for row in computed.sorted(by: { $0.day < $1.day }) {
            guard let day = Baselines.isoEpochDay(row.day), day <= anchor,
                  anchor - day < ChargeBaselines.windowDays,
                  refreshBaseline || row.day == selectedDay,
                  let hrv = row.avgHrv, let rhr = row.restingHr else { continue }
            let skinDev: Double?
            if let mean = row.skinTempC {
                skinDev = skinBase.usable ? (Baselines.deviation(mean, state: skinBase).delta * 100).rounded() / 100 : nil
            } else {
                skinDev = row.skinTempDevC // no raw mean: retain the legacy deviation
            }
            let restQuality = AnalyticsEngine.Rest.composite(daily: row).map { $0 / 100 } ?? row.efficiency
            let recovery = resolved.hrv.usable ? RecoveryScorer.recovery(
                hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
                hrvBaseline: resolved.hrv, rhrBaseline: resolved.restingHR.usable ? resolved.restingHR : nil,
                respBaseline: respBase.usable ? respBase : nil, sleepPerf: restQuality, skinTempDev: skinDev) : nil
            let update = SleepRecoveryUpdate(day: row.day, recovery: recovery, skinTempDevC: skinDev, sourceId: sourceByDay[row.day])
            if update.changes(row) { updates.append(update) }
        }
        return updates
    }
}
