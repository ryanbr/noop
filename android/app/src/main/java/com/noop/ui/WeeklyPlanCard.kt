package com.noop.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.noop.R
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.WeeklyPlan
import com.noop.analytics.WeeklyPlanKind
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

// MARK: - Weekly plan card
//
// This week's progress toward the user's own sleep / Effort / steps goals. The counting rules live in the
// pure analytics WeeklyPlan (Swift twin in StrandAnalytics); this file only stores the user's goal
// day-counts, formats and renders. Display-only: nothing here feeds a score or a stored metric.

/** The user's days-per-week for each goal, in SharedPreferences "noop_weekly_plan" (key = Kind.raw).
 *  Same keys as the Apple `WeeklyPlanPrefs` (UserDefaults "weeklyPlan.<raw>Days"); not in .noopbak. */
internal object WeeklyPlanPrefs {
    private const val FILE = "noop_weekly_plan"
    private fun key(kind: WeeklyPlanKind) = "weeklyPlan.${kind.raw}Days"

    fun goals(context: Context): List<WeeklyPlan.Goal> {
        val p = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        return WeeklyPlan.defaultGoals().map { it.copy(targetDays = p.getInt(key(it.kind), it.targetDays).coerceIn(0, 7)) }
    }

    fun setDays(context: Context, kind: WeeklyPlanKind, days: Int) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit().putInt(key(kind), days.coerceIn(0, 7)).apply()
    }
}

@Composable
private fun WeeklyPlanKind.goalLabel(threshold: Double): String = when (this) {
    WeeklyPlanKind.SLEEP -> uiString(R.string.l10n_weekly_plan_goal_sleep, durationText(threshold))
    WeeklyPlanKind.EFFORT -> uiString(R.string.l10n_weekly_plan_goal_effort, String.format(Locale.getDefault(), "%.0f", threshold))
    WeeklyPlanKind.STEPS -> uiString(R.string.l10n_weekly_plan_goal_steps, String.format(Locale.getDefault(), "%,.0f", threshold))
}

@Composable
private fun WeeklyPlanKind.accent(): Color = when (this) {
    WeeklyPlanKind.SLEEP -> Palette.restColor
    WeeklyPlanKind.EFFORT, WeeklyPlanKind.STEPS -> Palette.effortColor
}

@Composable
internal fun WeeklyPlanCard(days: List<WeeklyPlan.Day>) {
    val context = LocalContext.current
    var goals by remember { mutableStateOf(WeeklyPlanPrefs.goals(context)) }
    val nowSec = System.currentTimeMillis() / 1000L
    val tz = java.util.TimeZone.getDefault().getOffset(nowSec * 1000L) / 1000L
    val week = WeeklyPlan.week(days, AnalyticsEngine.dayString(nowSec, tz), goals)
    NoopCard(padding = Metrics.cardPadding, tint = Palette.effortColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
            Column {
                Overline(uiString(R.string.l10n_weekly_plan_overline))
                Text(uiString(R.string.l10n_weekly_plan_title), style = NoopType.headline, color = Palette.textPrimary)
            }
            goals.forEach { goal ->
                val p = week?.progress?.firstOrNull { it.goal.kind == goal.kind }
                WeeklyGoalRow(goal, p, week?.todayIndex ?: 0) { newDays ->
                    WeeklyPlanPrefs.setDays(context, goal.kind, newDays)
                    goals = WeeklyPlanPrefs.goals(context)
                }
            }
            Text(uiString(R.string.l10n_weekly_plan_footnote), style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

@Composable
private fun WeeklyGoalRow(goal: WeeklyPlan.Goal, p: WeeklyPlan.Progress?, todayIndex: Int, onDays: (Int) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.space14))
            .background(Palette.surfaceInset)
            .padding(horizontal = Metrics.space14, vertical = Metrics.space8),
        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(goal.kind.goalLabel(goal.threshold), style = NoopType.subhead, color = goal.kind.accent())
                Text(
                    when {
                        goal.targetDays == 0 -> uiString(R.string.l10n_weekly_plan_status_off)
                        p == null -> ""
                        p.met -> uiString(R.string.l10n_weekly_plan_status_met, p.daysHit, goal.targetDays)
                        p.onTrack -> uiString(R.string.l10n_weekly_plan_status_on_track, p.daysHit, goal.targetDays)
                        else -> uiString(R.string.l10n_weekly_plan_status_behind, p.daysHit, goal.targetDays)
                    },
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            IconButton(onClick = { onDays(goal.targetDays - 1) }, enabled = goal.targetDays > 0) {
                Icon(Icons.Outlined.Remove, contentDescription = uiString(R.string.l10n_weekly_plan_fewer_days))
            }
            Text(goal.targetDays.toString(), style = NoopType.captionNumber, color = Palette.textPrimary)
            IconButton(onClick = { onDays(goal.targetDays + 1) }, enabled = goal.targetDays < 7) {
                Icon(Icons.Outlined.Add, contentDescription = uiString(R.string.l10n_weekly_plan_more_days))
            }
        }
        if (goal.targetDays > 0) {
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                DayOfWeek.entries.forEachIndexed { i, dow ->
                    val hit = p?.hitWeekdays?.contains(i) == true
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(
                            Modifier
                                .size(Metrics.legendSwatch)
                                .clip(CircleShape)
                                .background(
                                    when {
                                        hit -> goal.kind.accent()
                                        i <= todayIndex -> Palette.textTertiary.copy(alpha = 0.35f)
                                        else -> Palette.textTertiary.copy(alpha = 0.12f)
                                    },
                                ),
                        )
                        Text(dow.getDisplayName(TextStyle.NARROW, Locale.getDefault()), style = NoopType.footnote, color = Palette.textTertiary)
                    }
                }
            }
        }
    }
}
