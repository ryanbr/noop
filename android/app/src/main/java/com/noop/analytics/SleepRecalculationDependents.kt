package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.SleepRecoveryUpdate

/** Refresh only stored Charge cells whose existing 21-day baseline can include the selected night. */
object SleepRecalculationDependents {
    /** Swift twin: `SleepRecalculationDependents.updates`. */
    fun updates(selectedDay: String, anchorDay: String, refreshBaseline: Boolean, imported: List<DailyMetric>, computed: List<DailyMetric>,
                sourceByDay: Map<String, String>, importedSource: String,
                hrvEpoch: Double, recoveryEpoch: Double): List<SleepRecoveryUpdate> {
        val selected = Baselines.isoEpochDay(selectedDay) ?: return emptyList()
        val anchor = Baselines.isoEpochDay(anchorDay) ?: return emptyList()
        if (anchor < selected || anchor - selected >= ChargeBaselines.windowDays) return emptyList()
        val resolved = ChargeBaselines.resolve(imported, computed, anchorDay, hrvEpoch, recoveryEpoch)
        val sourceDays = (imported + computed).filter { it.day <= anchorDay }.map { it.day }.distinct().sorted()
        val respEpoch = maxOf(recoveryEpoch, Baselines.deviceEraEpoch(
            sourceDays.map { it to (sourceByDay[it] ?: importedSource) }))
        val respBase = Baselines.foldHistory(resolved.respHistory.values, resolved.respHistory.dayKeys,
            Baselines.respCfg, respEpoch)
        val skinCfg = Baselines.metricCfg.getValue("skin_temp")
        val skinHistory = ChargeBaselines.history(emptyList(), computed.map { it.day to it.skinTempC },
            anchorDay, skinCfg, recoveryEpoch)
        val skinBase = Baselines.foldHistory(skinHistory.values, skinHistory.dayKeys, skinCfg, recoveryEpoch)
        return computed.sortedBy { it.day }.mapNotNull { row ->
            val day = Baselines.isoEpochDay(row.day) ?: return@mapNotNull null
            if (day > anchor || anchor - day >= ChargeBaselines.windowDays || (!refreshBaseline && row.day != selectedDay)) return@mapNotNull null
            val hrv = row.avgHrv ?: return@mapNotNull null
            val rhr = row.restingHr ?: return@mapNotNull null
            val skinDev = row.skinTempC?.let { mean ->
                if (!skinBase.usable) null else {
                    val scaled = Baselines.deviation(mean, skinBase).delta * 100.0
                    (if (scaled >= 0) Math.floor(scaled + 0.5) else Math.ceil(scaled - 0.5)) / 100.0
                }
            } ?: if (row.skinTempC == null) row.skinTempDevC else null
            val restQuality = RestScorer.restFromDaily(row)?.let { it / 100.0 } ?: row.efficiency
            val recovery = if (resolved.hrv.usable) RecoveryScorer.recovery(
                hrv = hrv, rhr = rhr.toDouble(), resp = row.respRateBpm,
                hrvBaseline = resolved.hrv, rhrBaseline = resolved.restingHR.takeIf { it.usable },
                respBaseline = respBase.takeIf { it.usable }, sleepPerf = restQuality, skinTempDev = skinDev,
            ) else null
            SleepRecoveryUpdate(row.day, recovery, skinDev, sourceByDay[row.day]).takeIf { it.changes(row) }
        }
    }
}
