package com.noop.ui

import com.noop.analytics.DaytimeBaselines
import com.noop.analytics.DaytimeStress
import com.noop.data.WhoopRepository
import java.time.LocalDate
import java.time.ZoneId

/**
 * The one foreground-surface resolver for daytime-stress scoring.
 *
 * Both Stress detail and Today's hosted Stress card call this funnel. When the personal lens is off,
 * it returns immediately without touching trailing history. When it is on, today's local day is
 * excluded and the previous 30 days are reduced one at a time into the same personal baseline.
 * Background widgets deliberately do not opt in: paying for 30 days of raw reads on an unprompted
 * periodic tick would make a display preference an always-on workload.
 */
internal suspend fun selectedDaytimeStressMode(
    repo: WhoopRepository,
    deviceId: String,
    todayLocalDay: LocalDate,
    zone: ZoneId,
    personalBaseline: Boolean,
): DaytimeStress.ScoringMode {
    if (!personalBaseline) return DaytimeStress.ScoringMode.DayRelative

    val baselineHistoryDays = 30
    val aggregates = ArrayList<DaytimeBaselines.DayAggregate>(baselineHistoryDays)
    // Oldest -> newest so the EWMA fold replays history in order. Reduce each day immediately: the
    // fold needs two Doubles per day, not 30 days of raw HR and R-R held in memory at once (#2107).
    for (back in baselineHistoryDays downTo 1) {
        val window = stressLocalDayWindow(todayLocalDay.minusDays(back.toLong()), zone)
        val dayHr = repo.hrSamplesUnion(
            deviceId,
            window.fromEpochSecond,
            window.toEpochSecondInclusive,
            limit = 200_000,
        )
        if (dayHr.isEmpty()) continue
        // The live baseline scores HR only while the RMSSD term is disabled. Reading up to
        // 200k R-R rows for each of 30 days cannot change its result and delays the card.
        val dayRr = if (DaytimeStress.daytimeRMSSDScoringEnabled) {
            repo.rrIntervalsUnion(
                deviceId,
                window.fromEpochSecond,
                window.toEpochSecondInclusive,
                limit = 200_000,
            )
        } else emptyList()
        aggregates.add(
            DaytimeBaselines.dayDaytimeAggregate(dayHr, dayRr, window.offsetSeconds.toLong()),
        )
    }
    return DaytimeBaselines.scoringModeFromAggregates(aggregates)
}
