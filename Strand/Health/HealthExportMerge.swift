import Foundation
import WhoopStore

// MARK: - Apple Health export row precedence (#2264)
//
// The vitals write-back unions two sources for the same day: NOOP's COMPUTED dailies and any rows a
// WHOOP CSV import produced, with imported taking precedence to match the dashboard. That precedence is
// right, and the wholesale replacement it was written as is not.
//
// `WhoopImporter` never sets `avgSdnn` - a CSV carries no raw R-R to derive it from - so on any day an
// import covers, the replacement drops a computed SDNN that was already correct. The export then falls
// back to `avgHrv`, which for a strap row is RMSSD, and writes it under `heartRateVariabilitySDNN`.
//
// The result is a REGRESSION of data that was right: a re-scored night exports a correctly-labelled SDNN
// until an import lands on that day, after which the same night exports RMSSD under the SDNN label, with
// nothing in the series to say the metric changed. RMSSD and SDNN are different magnitudes, so this shows
// up as a step no physiology produced.

/// How a day's computed row and its imported row combine for the Apple Health export.
enum HealthExportMerge {

    /// The row to export for one day.
    ///
    /// Imported still wins field-for-field, preserving the existing precedence. The single departure is a
    /// field the importer CANNOT populate: where the imported row has no `avgSdnn` and the computed row
    /// does, the computed value is carried across rather than discarded.
    ///
    /// Deliberately narrow. Other fields the importer leaves unset (`spo2Red`, `spo2Ir`, `skinTempC`,
    /// `sleepHrOnly`, `activeKcalEst`) are NOT carried across, because the export does not read them: the
    /// write path uses `avgHrv`, `avgSdnn`, `restingHr`, `respRateBpm` and `spo2Pct` only. Widening this
    /// to a general field-wise merge would change what the dashboard's precedence means for rows this
    /// function never had a mandate over.
    static func merged(computed: DailyMetric?, imported: DailyMetric) -> DailyMetric {
        guard imported.avgSdnn == nil, let carried = computed?.avgSdnn else { return imported }
        return DailyMetric(
            day: imported.day,
            totalSleepMin: imported.totalSleepMin,
            efficiency: imported.efficiency,
            deepMin: imported.deepMin,
            remMin: imported.remMin,
            lightMin: imported.lightMin,
            disturbances: imported.disturbances,
            restingHr: imported.restingHr,
            avgHrv: imported.avgHrv,
            recovery: imported.recovery,
            strain: imported.strain,
            exerciseCount: imported.exerciseCount,
            spo2Pct: imported.spo2Pct,
            skinTempDevC: imported.skinTempDevC,
            respRateBpm: imported.respRateBpm,
            steps: imported.steps,
            activeKcalEst: imported.activeKcalEst,
            spo2Red: imported.spo2Red,
            spo2Ir: imported.spo2Ir,
            avgSdnn: carried,
            skinTempC: imported.skinTempC,
            sleepHrOnly: imported.sleepHrOnly
        )
    }
}
