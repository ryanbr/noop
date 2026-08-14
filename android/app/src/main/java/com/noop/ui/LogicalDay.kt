package com.noop.ui

import com.noop.analytics.Baselines
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * The "logical day" key the dashboard treats as Today.
 *
 * A naive `LocalDate.now()` rolls the moment the clock passes midnight, so between 00:00 and the
 * morning the dashboard would look up a brand-new calendar day that has no banked row yet and blank
 * out — even though the user is still in the same wear/sleep cycle as the previous evening (#144).
 *
 * The logical day rolls at [rolloverHour] (04:00 LOCAL) instead: it is the calendar date of
 * `now - rolloverHour hours`, so the small hours after midnight still resolve to the PRIOR calendar
 * date's row. This is a PRESENTATION-layer remap only — used purely to pick which stored row is
 * "Today" and to anchor the Today HR-trend window. Stored row keys are never rewritten (they stay
 * keyed on their own true calendar date), so the blast radius is deliberately tiny. An explicit
 * date label stays visible under the header so the remap is always honest.
 *
 * Pure + injectable so [LogicalDayTest] can pin the boundaries:
 *  - 23:59 → same calendar day (still the evening's logical day)
 *  - 01:00 → previous calendar day (the night still belongs to yesterday)
 *  - 04:01 → the new calendar day (a fresh logical day has begun)
 */
internal fun logicalDay(
    now: ZonedDateTime,
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): LocalDate = now.minusHours(rolloverHour.toLong()).toLocalDate()

/** Convenience overload for the live call sites: the logical day for the current instant in [zone]. */
internal fun logicalDayNow(
    zone: ZoneId = ZoneId.systemDefault(),
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): LocalDate = logicalDay(ZonedDateTime.now(zone), rolloverHour)

/** ISO `yyyy-MM-dd` key for the current logical day — matches how [DailyMetric.day] is stored. */
internal fun logicalDayKeyNow(
    zone: ZoneId = ZoneId.systemDefault(),
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): String = logicalDayNow(zone, rolloverHour).toString()

/**
 * Start-of-logical-day as an epoch second in [zone] — the anchor for the Today HR-trend window so it
 * spans from the logical day's 00:00 (its real calendar midnight) rather than restarting at the new
 * calendar midnight while we're still showing yesterday's logical day in the small hours. (#144)
 */
internal fun logicalDayStartEpochSecond(
    now: ZonedDateTime,
    zone: ZoneId = now.zone,
    rolloverHour: Int = LOGICAL_DAY_ROLLOVER_HOUR,
): Long = logicalDay(now, rolloverHour).atStartOfDay(zone).toEpochSecond()

/**
 * Pure resolver behind the dashboard's "today" row (#304), extracted so the boundary is testable
 * without a live clock. Prefer the LOCAL-calendar-day row when it differs from the logical day AND has a
 * banked night (totalSleepMin != null) — the non-UTC pre-04:00 case, where the just-finished night is
 * banked under the new local calendar day while [logicalKey] still points at yesterday. Otherwise fall
 * back to the logical-day row, preserving the #144 anti-blank guard (never blank when a night isn't
 * banked yet). [localKey] == [logicalKey] (the common daytime case) collapses to the plain logical
 * lookup. Mirrors Swift Repository.resolveToday.
 */
internal fun resolveTodayRow(days: List<DailyMetric>, logicalKey: String, localKey: String): DailyMetric? {
    if (localKey != logicalKey) {
        days.lastOrNull { it.day == localKey && it.totalSleepMin != null }?.let { return it }
    }
    return days.lastOrNull { it.day == logicalKey }
}

/**
 * #911: the SINGLE anchor the home-screen widget push resolves the row it describes through, from BOTH
 * producers (the in-app republish in AppViewModel AND the background-service producer in
 * WhoopConnectionService), so the two can never drift apart. Pure + testable without a live clock.
 *
 * It is exactly what the dashboard does: resolve today's row ([resolveTodayRow], which carries the #304
 * pre-04:00 local-day carve-out and the #144 anti-blank guard), then use that row when it's scored, else
 * carry over the freshest STRICTLY-PRIOR scored day for the recovery-derived fields. Anchoring on today's
 * row (not "the newest row with any recovery score") is what fixes the rollover drift: the new logical
 * day exists but isn't scored yet, so a naive `days.lastOrNull { recovery != null }` kept pointing at
 * yesterday's scored row while Today had already moved on. The `it.day < anchorKey` bound ([anchorKey] =
 * today's own key) mirrors [lastScoredRecoveryDay] + its #547 future-day guard, so a stale or stray
 * future-dated scored row can never re-surface AS today. Mirrors Swift Repository.widgetAnchor.
 */
internal fun widgetAnchorRow(days: List<DailyMetric>, logicalKey: String, localKey: String): DailyMetric? {
    val todayRow = resolveTodayRow(days, logicalKey, localKey)
    if (todayRow?.recovery != null) return todayRow
    val anchorKey = todayRow?.day ?: logicalKey
    return days.lastOrNull { it.recovery != null && it.day < anchorKey }
}

/**
 * The freshest STRICTLY-PRIOR row that carries a real overnight VITAL (HRV / resting-HR / respiratory),
 * regardless of whether that night was recovery-scored. This is the carry-over the overnight-vitals
 * read-outs use, kept SEPARATE from [widgetAnchorRow] / [lastScoredRecoveryDay] (which are recovery-gated).
 *
 * HRV / resting-HR / respiratory exist independently of a recovery score: a post-update re-analysis can
 * null last night's recovery while PRESERVING its real avgHrv/restingHr. A recovery-gated whole-row carry
 * then skips that night and surfaces an OLDER scored day's numbers (or "No Data" if the older row lacks
 * the vital), which is wrong. Selecting the last row with ANY of the three vitals, bounded strictly before
 * [todayKey], keeps last night's OWN vitals in view. Pure + testable; days is oldest→newest. The
 * `it.day < todayKey` bound mirrors [widgetAnchorRow]'s future-day guard, so a stray future-dated row (a
 * bad strap clock) can never surface. Mirrors Swift Repository.lastVitalsDay.
 */
internal fun lastVitalsRow(days: List<DailyMetric>, todayKey: String): DailyMetric? =
    days.lastOrNull { (it.avgHrv != null || it.restingHr != null || it.respRateBpm != null) && it.day < todayKey }

/**
 * PER-FIELD twin of [lastVitalsRow] for SpO₂: the freshest strictly-prior row with a non-null [DailyMetric.spo2Pct].
 * [lastVitalsRow]'s predicate only checks HRV/resting-HR/respiratory, so it can select a row whose spo2Pct is
 * null (the on-device engine writes spo2Pct = null; only imported rows carry it) while an OLDER imported row
 * has a real reading. Resolving SpO₂ per field keeps the Blood Oxygen card honest instead of "No Data".
 * Same `it.day < todayKey` future-clock guard. Mirrors Swift `DailyMetric.lastSpo2Day` / `lastSkinTempDay`.
 */
internal fun lastSpo2Row(days: List<DailyMetric>, todayKey: String): DailyMetric? =
    days.lastOrNull { it.spo2Pct != null && it.day < todayKey }

/** PER-FIELD twin of [lastVitalsRow] for skin temperature deviation. See [lastSpo2Row]. */
internal fun lastSkinTempRow(days: List<DailyMetric>, todayKey: String): DailyMetric? =
    days.lastOrNull { it.skinTempDevC != null && it.day < todayKey }

/** PER-FIELD twin of [lastVitalsRow] for respiratory rate. [lastVitalsRow]'s predicate is satisfied by a
 *  row that has HRV/resting-HR but a null respRateBpm — respiratory needs a longer clean sleep R-R segment
 *  than HRV, so a night can carry HRV yet no breaths/min, leaving the Respiratory card "No Data" while an
 *  older row holds a real reading. Resolving it per field keeps the card honest. See [lastSpo2Row]. */
internal fun lastRespRow(days: List<DailyMetric>, todayKey: String): DailyMetric? {
    // STALENESS-BOUNDED, unlike lastSpo2Row/lastSkinTempRow. SpO₂/skin-temp are sparse/imported, so
    // last-known-of-any-age is the expected reading. Respiratory is NIGHTLY, so a weeks-old value shown as
    // the current card number is the "Respiratory 15.6 a fortnight later, no date beside it" bug
    // Baselines.vitalCarryDays exists to prevent (see freshestCarried). Carry only within that window;
    // past it the card honestly shows "No Data" (respiratory has genuinely stopped, not just hiccuped).
    val newest = days.lastOrNull { it.respRateBpm != null && it.day < todayKey } ?: return null
    return if (newest.day >= Baselines.cutoffKey(todayKey)) newest else null
}

/** 04:00 local — the hour the logical day rolls. Between midnight and this hour, Today stays put. */
internal const val LOGICAL_DAY_ROLLOVER_HOUR: Int = 4

/** Exposed for symmetry / call-site readability (start of the rollover window). */
internal val LOGICAL_DAY_ROLLOVER_TIME: LocalTime = LocalTime.of(LOGICAL_DAY_ROLLOVER_HOUR, 0)
