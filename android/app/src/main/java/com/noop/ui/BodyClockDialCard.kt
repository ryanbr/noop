package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.CircadianEngine
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

// MARK: - 24 h body-clock dial (#1680)
//
// Two concentric arcs on one ring: the outer is where the body clock wanted the night, the inner is where
// it happened. Overlap is the whole message — the card exists so "was last night's timing right" is
// answerable at a glance, which the text-only BodyClockCard on the Health screen cannot do.
//
// VOCABULARY. The caption measures sleepWindowOffsetHours — the distance between the two ARCS DRAWN — and
// NOT offsetVsScheduleMinutes, which compares the clock to the wearer's habitual schedule and is what the
// Health card already reports. The two disagree exactly when someone keeps a consistent schedule that does
// not suit their clock, and that is the case this dial exists to show, so captioning it with the other
// number would contradict the picture.
//
// Nothing here computes a metric: the window, the offset and the chronotype all come from CircadianEngine,
// byte-identical with the Swift twin. Only the drawing is per-platform (visual parity, not pixel parity).

/**
 * The dial card. [actualBedHour] / [actualWakeHour] are the night's own clock hours (0..<24, fractional),
 * taken from the scored session by the caller. Twin of Apple `BodyClockDialCard`.
 */
@Composable
fun BodyClockDialCard(
    estimate: CircadianEngine.PhaseEstimate,
    actualBedHour: Double,
    actualWakeHour: Double,
) {
    val hue = Palette.restColor
    // The night's length, taken the long way round the clock when it crosses midnight.
    val durationHours = ((actualWakeHour - actualBedHour) % 24.0).let { if (it <= 0.0) it + 24.0 else it }
    // null exactly when the night's length is non-positive or a full day — the same input that makes
    // sweepHours wrap to 24 h and draw the actual arc as a complete ring. A full circle with no ideal arc
    // beside it would state something false about the night, so the card stands down. Mirrors Swift.
    val ideal = CircadianEngine.idealSleepWindow(estimate.tempMinHour, durationHours) ?: return
    val offsetHours = CircadianEngine.sleepWindowOffsetHours(estimate.tempMinHour, actualWakeHour)
    val alignment = alignmentText(offsetHours)
    val dialLabel = uiString(R.string.l10n_body_clock_dial_card_body_clock_dial_03cdbc31)

    NoopCard(tint = hue) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline(uiString(R.string.l10n_body_clock_dial_card_body_clock_b0b9b988))
                    Text(
                        uiString(R.string.l10n_body_clock_dial_card_last_night_against_your_clock_9183a37c),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }

            Canvas(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(170.dp)
                    .semantics { contentDescription = dialLabel },
            ) {
                val side = min(size.width, size.height)
                val centre = Offset(size.width / 2f, size.height / 2f)
                val outer = side / 2f - 10.dp.toPx()
                val inner = outer - 16.dp.toPx()

                // The bare ring, so an empty dial still reads as a clock rather than a broken chart.
                drawCircle(color = Palette.hairline, radius = outer, center = centre,
                    style = Stroke(width = 1.dp.toPx()))

                // Six-hourly ticks: enough to orient the eye, few enough not to compete with the arcs.
                var tick = 0.0
                while (tick < 24.0) {
                    val a = Math.toRadians(hourAngleDegrees(tick))
                    drawLine(
                        color = Palette.textTertiary.copy(alpha = 0.5f),
                        start = Offset(centre.x + (cos(a) * (outer - 4.dp.toPx())).toFloat(),
                            centre.y + (sin(a) * (outer - 4.dp.toPx())).toFloat()),
                        end = Offset(centre.x + (cos(a) * outer).toFloat(),
                            centre.y + (sin(a) * outer).toFloat()),
                        strokeWidth = 1.dp.toPx(),
                    )
                    tick += 6.0
                }

                fun arc(radius: Float, from: Double, to: Double, colour: androidx.compose.ui.graphics.Color, width: Float) {
                    drawArc(
                        color = colour,
                        startAngle = hourAngleDegrees(from).toFloat(),
                        sweepAngle = (sweepHours(from, to) / 24.0 * 360.0).toFloat(),
                        useCenter = false,
                        topLeft = Offset(centre.x - radius, centre.y - radius),
                        size = Size(radius * 2, radius * 2),
                        style = Stroke(width = width, cap = StrokeCap.Round),
                    )
                }

                if (ideal != null) {
                    arc(outer, ideal.bedHour, ideal.wakeHour, hue.copy(alpha = 0.35f), 8.dp.toPx())
                }
                arc(inner, actualBedHour, actualWakeHour, hue, 8.dp.toPx())
            }

            Text(alignment, style = NoopType.title2, color = Palette.textPrimary)

            CircadianEngine.chronotype(estimate)?.let { c ->
                Text(chronotypeText(c), style = NoopType.footnote, color = Palette.textTertiary)
            }
        }
    }
}

/** A unix second as a fractional LOCAL clock hour — the dial's only input beyond the phase estimate. */
internal fun localClockHour(ts: Long): Double {
    val c = java.util.Calendar.getInstance()
    c.timeInMillis = ts * 1000L
    return c.get(java.util.Calendar.HOUR_OF_DAY) + c.get(java.util.Calendar.MINUTE) / 60.0
}

/** Midnight at the top, clocking round to the right. Compose's zero angle is at 3 o'clock, hence the −90. */
internal fun hourAngleDegrees(hour: Double): Double = hour / 24.0 * 360.0 - 90.0

/** Sweep from [from] to [to] clockwise, always positive so an arc crossing midnight still draws. */
internal fun sweepHours(from: Double, to: Double): Double =
    ((to - from) % 24.0).let { if (it <= 0.0) it + 24.0 else it }

/**
 * Rounded to five minutes: the underlying phase is an activity fit, so a to-the-minute caption would imply
 * a precision the estimate does not carry.
 */
@Composable
private fun alignmentText(offsetHours: Double): String {
    val minutes = (offsetHours * 60 / 5).roundToInt() * 5
    if (kotlin.math.abs(minutes) < 30) return uiString(R.string.l10n_body_clock_dial_card_in_sync_with_your_body_clock_4b5181c8)
    val absMinutes = kotlin.math.abs(minutes)
    val amount = if (absMinutes >= 60) String.format(java.util.Locale.getDefault(), "%.1f h", absMinutes / 60.0) else "$absMinutes min"
    return if (minutes > 0) uiString(R.string.l10n_body_clock_dial_card_1_s_later_than_your_body_50b7d966, amount) else uiString(R.string.l10n_body_clock_dial_card_1_s_earlier_than_your_body_68877f50, amount)
}

@Composable
private fun chronotypeText(c: CircadianEngine.Chronotype): String = when (c) {
    CircadianEngine.Chronotype.MORNING -> uiString(R.string.l10n_body_clock_dial_card_morning_type_289dd7bf)
    CircadianEngine.Chronotype.INTERMEDIATE -> uiString(R.string.l10n_body_clock_dial_card_intermediate_type_a7b6b74c)
    CircadianEngine.Chronotype.EVENING -> uiString(R.string.l10n_body_clock_dial_card_evening_type_3e1ce111)
}
