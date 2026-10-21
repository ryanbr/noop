package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import com.noop.R
import com.noop.analytics.ClockFormat
import com.noop.analytics.SleepPlan
import com.noop.analytics.SleepPlannerGoal
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

// MARK: - Sleep planner card
//
// Tonight's sleep target at three goals (70 / 85 / 100 % of tonight's need), the time in bed each one
// takes at the user's typical efficiency, and the bedtime that implies for the next wake. The arithmetic
// lives in the pure analytics SleepPlanner (Swift twin in StrandAnalytics); this file only resolves the
// wake time and renders. Display-only: nothing here feeds a score or a stored value.

/** Where the planner's wake time came from, so the card can say so instead of hiding it. */
internal enum class PlannerWakeSource { ALARM, LAST_NIGHT, DEFAULT }

/**
 * The wake the plan is built for. The armed smart alarm wins (its per-day target for the NEXT morning,
 * resolved through [SmartAlarmStore.targetFor] so this card and the Alarms screen read one value); else
 * last night's wake; else 07:00. [nextMorningDow] is the `Calendar.DAY_OF_WEEK` of the coming morning.
 */
internal fun plannerWake(
    alarmEnabled: Boolean,
    alarmTargetFor: (Int) -> Int,
    nextMorningDow: Int,
    lastWakeMinuteOfDay: Int?,
): Pair<Int, PlannerWakeSource> = when {
    alarmEnabled -> alarmTargetFor(nextMorningDow) to PlannerWakeSource.ALARM
    lastWakeMinuteOfDay != null -> lastWakeMinuteOfDay to PlannerWakeSource.LAST_NIGHT
    else -> DEFAULT_PLANNER_WAKE to PlannerWakeSource.DEFAULT
}

internal const val DEFAULT_PLANNER_WAKE = 7 * 60

/** The coming morning's day of week: today before noon, tomorrow from noon on. */
internal fun nextMorningDayOfWeek(now: Calendar): Int {
    val c = now.clone() as Calendar
    if (c.get(Calendar.HOUR_OF_DAY) >= 12) c.add(Calendar.DAY_OF_YEAR, 1)
    return c.get(Calendar.DAY_OF_WEEK)
}

/** A minute of day in the shared clock pattern ([ClockFormat.hourMinutePattern], #1821). */
internal fun plannerClock(minuteOfDay: Int, is24h: Boolean): String {
    val c = Calendar.getInstance().apply {
        set(Calendar.HOUR_OF_DAY, minuteOfDay / 60)
        set(Calendar.MINUTE, minuteOfDay % 60)
    }
    return SimpleDateFormat(ClockFormat.hourMinutePattern(is24h), Locale.getDefault()).format(c.time)
}

@Composable
internal fun SleepPlannerCard(plan: SleepPlan?, wake: Pair<Int, PlannerWakeSource>, is24h: Boolean) {
    NoopCard(padding = Metrics.cardPadding, tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
            Column {
                Overline(uiString(R.string.l10n_sleep_planner_overline_tonight))
                Text(uiString(R.string.l10n_sleep_planner_title), style = NoopType.headline, color = Palette.textPrimary)
            }
            if (plan == null) {
                Text(uiString(R.string.l10n_sleep_planner_needs_three_nights), style = NoopType.footnote, color = Palette.textSecondary)
                return@Column
            }

            // Need breakdown: base + debt − naps = tonight.
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf(
                    uiString(R.string.l10n_sleep_planner_base_need) to durationText(plan.baseNeedMin.toDouble()),
                    uiString(R.string.l10n_sleep_planner_debt) to "+" + durationText(plan.debtMin.toDouble()),
                    uiString(R.string.l10n_sleep_planner_naps) to "−" + durationText(plan.napCreditMin.toDouble()),
                    uiString(R.string.l10n_sleep_planner_tonight_need) to durationText(plan.tonightNeedMin.toDouble()),
                ).forEach { (label, value) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(label, color = Palette.textTertiary)
                        Text(value, style = NoopType.captionNumber, color = Palette.textPrimary)
                    }
                }
            }

            SleepHairline()
            val wakeText = plannerClock(wake.first, is24h)
            Text(
                when (wake.second) {
                    PlannerWakeSource.ALARM -> uiString(R.string.l10n_sleep_planner_wake_from_alarm, wakeText)
                    PlannerWakeSource.LAST_NIGHT -> uiString(R.string.l10n_sleep_planner_wake_from_last_night, wakeText)
                    PlannerWakeSource.DEFAULT -> uiString(R.string.l10n_sleep_planner_wake_default, wakeText)
                },
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )

            plan.tiers.forEach { tier ->
                val (label, color) = when (tier.goal) {
                    SleepPlannerGoal.MINIMUM -> uiString(R.string.l10n_sleep_planner_goal_minimum) to Palette.restDeep
                    SleepPlannerGoal.SOLID -> uiString(R.string.l10n_sleep_planner_goal_solid) to Palette.restColor
                    SleepPlannerGoal.FULL -> uiString(R.string.l10n_sleep_planner_goal_full) to Palette.restBright
                }
                PlannerTierRow(
                    label = label,
                    percent = (tier.goal.fraction * 100).toInt(),
                    accent = color,
                    sleep = durationText(tier.sleepTargetMin.toDouble()),
                    inBed = durationText(tier.timeInBedMin.toDouble()),
                    bedtime = plannerClock(tier.bedtimeMinuteOfDay, is24h),
                )
            }

            Text(
                if (plan.efficiencyUsed < 1.0) {
                    uiString(R.string.l10n_sleep_planner_footnote_efficiency, (plan.efficiencyUsed * 100).toInt())
                } else {
                    uiString(R.string.l10n_sleep_planner_footnote_no_efficiency)
                },
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun PlannerTierRow(label: String, percent: Int, accent: Color, sleep: String, inBed: String, bedtime: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cornerPill))
            .background(Palette.surfaceInset)
            .padding(horizontal = Metrics.space14, vertical = Metrics.space8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(label, style = NoopType.headline, color = accent)
            Text(
                uiString(R.string.l10n_sleep_planner_tier_detail, percent, sleep, inBed),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
        Column(horizontalAlignment = Alignment.End) {
            Overline(uiString(R.string.l10n_sleep_planner_bed_by), color = Palette.textTertiary)
            Text(bedtime, style = NoopType.chartValue, color = Palette.textPrimary)
        }
    }
}
