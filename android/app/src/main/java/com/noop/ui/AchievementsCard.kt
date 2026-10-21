package com.noop.ui

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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import com.noop.R
import com.noop.analytics.Achievements
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

// MARK: - Milestones card
//
// Milestones unlocked from the user's own daily history. The rules live in the pure analytics Achievements
// (Swift twin in StrandAnalytics); this file only formats and renders. Display-only.

/** A `yyyy-MM-dd` key as a medium localized date; the key itself if it does not parse. */
internal fun achievementDayText(day: String): String =
    runCatching { LocalDate.parse(day).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)) }
        .getOrDefault(day)

@Composable
private fun Achievements.Id.label(): String = when (this) {
    Achievements.Id.FIRST_SCORE -> uiString(R.string.l10n_achievement_first_score)
    Achievements.Id.STREAK_7 -> uiString(R.string.l10n_achievement_streak_7)
    Achievements.Id.STREAK_30 -> uiString(R.string.l10n_achievement_streak_30)
    Achievements.Id.SCORED_100 -> uiString(R.string.l10n_achievement_scored_100)
    Achievements.Id.CHARGE_90 -> uiString(R.string.l10n_achievement_charge_90)
    Achievements.Id.SLEEP_8H -> uiString(R.string.l10n_achievement_sleep_8h)
    Achievements.Id.EFFORT_18 -> uiString(R.string.l10n_achievement_effort_18)
    Achievements.Id.STEPS_10K -> uiString(R.string.l10n_achievement_steps_10k)
}

@Composable
internal fun AchievementsCard(achievements: List<Achievements.Achievement>) {
    val unlocked = achievements.count { it.unlockedDay != null }
    NoopCard(padding = Metrics.cardPadding, tint = Palette.gold) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
            Column {
                Overline(uiString(R.string.l10n_achievements_overline, unlocked, achievements.size))
                Text(uiString(R.string.l10n_achievements_title), style = NoopType.headline, color = Palette.textPrimary)
            }
            achievements.forEach { a ->
                val on = a.unlockedDay != null
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(Metrics.cornerPill))
                        .background(Palette.surfaceInset)
                        .padding(horizontal = Metrics.space14, vertical = Metrics.space8),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    Box(Modifier.size(Metrics.legendSwatch).clip(CircleShape).background(if (on) Palette.gold else Palette.textTertiary.copy(alpha = 0.2f)))
                    Text(
                        a.id.label(),
                        style = NoopType.subhead,
                        color = if (on) Palette.textPrimary else Palette.textTertiary,
                        modifier = Modifier.weight(1f),
                    )
                    if (a.isNew) Overline(uiString(R.string.l10n_achievements_new_badge), color = Palette.gold)
                    Text(
                        a.unlockedDay?.let { achievementDayText(it) } ?: uiString(R.string.l10n_achievements_locked),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }
            Text(uiString(R.string.l10n_achievements_footnote), style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}
