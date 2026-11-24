package com.noop.ui

import com.noop.data.WhoopRepository

/**
 * The Rest score (0–100) per day, the series both Insights screens rank their "Rest" outcome on.
 *
 * Both used to pick `DailyMetric.efficiency` instead: a different metric (asleep ÷ in-bed, one input to
 * Rest) on a different scale (normally a 0–1 fraction), so a Rest effect read about "1%" against "1%" and
 * Apple's Insights, which ranks `sleep_performance`, could order the same journal differently.
 *
 * Resolved, not a bare imported read, so this is the score Today, Trends and Health show for the day: the
 * import wins, else the on-device composite, else the composite derived from the day's banked totals. A
 * day with no Rest is absent. It never falls back to efficiency.
 */
internal suspend fun insightsRestByDay(repo: WhoopRepository, activeStrapId: String): Map<String, Double> =
    repo.resolvedSeries(
        "sleep_performance", "my-whoop", "0000-00-00", "9999-99-99",
        strapDeviceId = activeStrapId,
    ).values.toMap()
