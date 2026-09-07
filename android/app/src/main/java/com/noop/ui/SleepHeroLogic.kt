package com.noop.ui

import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.SleepSession

/** A short Rest state word for the hero gauge — same banding the synthesis hero uses. */
internal fun sleepScoreWord(score: Double): String = when {
    score < 50.0 -> "Poor"
    score < 70.0 -> "Fair"
    score < 85.0 -> "Good"
    else -> "Optimal"
}

/**
 * Short night-relative label ("Last night" / "1 night ago" / "N nights ago") for the ◀/▶-navigated
 * night. Shared by the Rest hero overline and the hypnogram nav header so both name the SAME night
 * the hero's score is resolved for. Mirrors iOS SleepView.nightRelativeLabel.
 */
internal fun nightRelativeLabel(offset: Int): String = when (offset) {
    0 -> "Last night"
    1 -> "1 night ago"
    else -> "$offset nights ago"
}

/**
 * How many nights back the carousel night at [offset] is FROM TODAY.
 * The ◀/▶ carousel steps by RECORDED night ([navDays], newest-first), so a night with no data (strap
 * off-body) is a gap the flat index can't see — labelling by index makes two nights either side of a
 * skipped night read as consecutive and desyncs the "N nights ago" labels (#1311). This restores the
 * true calendar distance from each night's local wake-day (the same key navDays is grouped by), so the
 * label — and the Rest value it names — line up with the night actually shown. Falls back to the raw
 * index if a day can't be read. 0 = last night.
 *
 * Measured from TODAY, not from the newest recorded night. Anchoring on the newest record made offset 0
 * always land on zero, so the hero read "Last night" over a night that could be days old: a reporter
 * whose newest night was Saturday saw it titled "Last night" on Monday and read it as bad processing,
 * which is what sent that investigation into the sleep stager instead of into this label. The stager
 * question was real and separate; this line was simply lying about which night it was showing.
 *
 * [today] is injected for deterministic tests and defaults to the logical day.
 */
internal fun calendarNightsAgo(
    navDays: List<List<SleepSession>>, offset: Int, zone: java.util.TimeZone,
    today: java.time.LocalDate = logicalDayNow(zone.toZoneId()),
): Int {
    if (offset < 0 || offset >= navDays.size) return offset
    val shownTs = navDays[offset].firstOrNull()?.endTs ?: return offset
    val z = zone.toZoneId()
    // The shown night keeps its CALENDAR wake-date, because that is the key navDays groups by
    // (`localDayString(endTs)`). Rolling this side too would let two distinct carousel entries collapse
    // onto one label: a night ending 07:00 and the next ending 02:00 are separate groups but the same
    // logical day, and both would print the same "nights ago".
    //
    // Only TODAY is rolled, which is what the small hours need: at 02:00 the night that ended
    // yesterday morning is still "Last night", because the logical day has not turned over yet.
    val shown = java.time.Instant.ofEpochSecond(shownTs).atZone(z).toLocalDate()
    val d = java.time.temporal.ChronoUnit.DAYS.between(shown, today).toInt()
    // A NEGATIVE distance is normal here, not just the clock-skew guard it looks like: between waking
    // before 04:00 and the roll, the night's calendar date is already tomorrow relative to the logical
    // day. Wake at 02:00 and check the tab at 03:00 and `shown` is the 7th while `today` is still the
    // 6th. Falling back to the offset is the RIGHT answer for that (offset 0 is "Last night", which it
    // is), so this branch carries a real case and must not be narrowed to an error path.
    return if (d >= 0) d else offset
}

/**
 * The sleep-performance score (0–100) for a SPECIFIC navigated night: the imported WHOOP figure for
 * that night's wake-day when the export carried one, else the resolved Rest composite for that day.
 * Mirrors the per-day transform in [buildSleepModel]'s `performance` series (and iOS
 * SleepView.performanceScore), keyed by [HeroNight.dayKey], so a navigated past night reads ITS OWN
 * score rather than the full-history latest. Null when there is no navigated night or that day has
 * no score.
 */
internal fun heroPerformanceScore(
    night: HeroNight?, days: List<DailyMetric>, imported: ImportedSleepSeries,
): Double? {
    val wakeDay = night?.dayKey ?: return null
    imported.performance[wakeDay]?.let { return it }
    val daily = days.lastOrNull { it.day == wakeDay } ?: return null
    return RestScorer.restFromDaily(daily)
}

/**
 * Whether a SPECIFIC night's sleep-performance score is WHOOP's own imported figure, an Oura
 * ring-provided figure, or NOOP's on-device approximation — so the hero is honest about provenance, like
 * Today's badges. Keyed by the night's wake-day (matching [heroPerformanceScore]) so a navigated night's
 * badge tracks ITS OWN score's provenance, not last night's. WHOOP import wins first; only a night
 * surfaced under a live Oura strap reads "Oura". Mirrors the macOS SleepView.heroSource.
 */
internal fun restHeroSource(
    imported: ImportedSleepSeries, wakeDay: String?, activeIsOura: Boolean = false,
): String = when {
    wakeDay != null && imported.performance[wakeDay] != null -> "Whoop"
    activeIsOura -> "Oura"
    else -> "On-device"
}
