package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.rememberVectorPainter
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
    // One hue for both arcs, told apart by dash and weight rather than by a second colour. Two blues
    // competed with the background image; a single legible one plus a dashed, lighter reference does not.
    val hue = Palette.restLine
    // The night's length, taken the long way round the clock when it crosses midnight.
    val durationHours = ((actualWakeHour - actualBedHour) % 24.0).let { if (it <= 0.0) it + 24.0 else it }
    // null exactly when the night's length is non-positive or a full day — the same input that makes
    // sweepHours wrap to 24 h and draw the actual arc as a complete ring. A full circle with no ideal arc
    // beside it would state something false about the night, so the card stands down. Mirrors Swift.
    val ideal = CircadianEngine.idealSleepWindow(estimate.tempMinHour, durationHours) ?: return
    val offsetHours = CircadianEngine.sleepWindowOffsetHours(estimate.tempMinHour, actualWakeHour)
    val alignment = alignmentText(offsetHours)
    // Resolved outside the Canvas: rememberVectorPainter is a composable and cannot be called in a
    // DrawScope.
    val bedPainter = rememberVectorPainter(Icons.Filled.Bedtime)
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

                // A full-circle TRACK under the night arc, the same idiom RecoveryRing uses: a faint
                // surfaceInset band with the live arc drawn on top. A one-dp hairline left the dial
                // reading as a thin wireframe against a busy background; a real track gives the ring
                // presence and makes the highlighted segment obvious as a portion of a whole day.
                drawCircle(color = Palette.surfaceInset, radius = inner, center = centre,
                    style = Stroke(width = 9.dp.toPx(), cap = StrokeCap.Round))
                // A hairline at the reference radius so the dashed arc still has a circle to belong to.
                drawCircle(color = Palette.hairline, radius = outer, center = centre,
                    style = Stroke(width = 1.dp.toPx()))

                // Six-hourly ticks, with MIDNIGHT drawn longer and brighter. Four identical marks at 90
                // degrees orient nothing — the ring is symmetric under rotation as far as they are
                // concerned, so a reader cannot tell midnight from noon and the arcs become unplaceable.
                // One distinguished mark anchors the whole dial, and does it without text, which keeps
                // the card free of a 12-versus-24-hour clock-format question.
                var tick = 0.0
                while (tick < 24.0) {
                    val isMidnight = tick == 0.0
                    val a = Math.toRadians(hourAngleDegrees(tick))
                    val len = if (isMidnight) 9.dp.toPx() else 4.dp.toPx()
                    drawLine(
                        color = if (isMidnight) Palette.textSecondary else Palette.textTertiary.copy(alpha = 0.5f),
                        start = Offset(centre.x + (cos(a) * (outer - len)).toFloat(),
                            centre.y + (sin(a) * (outer - len)).toFloat()),
                        end = Offset(centre.x + (cos(a) * outer).toFloat(),
                            centre.y + (sin(a) * outer).toFloat()),
                        strokeWidth = if (isMidnight) 1.5.dp.toPx() else 1.dp.toPx(),
                    )
                    tick += 6.0
                }

                fun arc(
                    radius: Float,
                    from: Double,
                    to: Double,
                    colour: androidx.compose.ui.graphics.Color,
                    width: Float,
                    dashed: Boolean,
                ) {
                    drawArc(
                        color = colour,
                        startAngle = hourAngleDegrees(from).toFloat(),
                        sweepAngle = (sweepHours(from, to) / 24.0 * 360.0).toFloat(),
                        useCenter = false,
                        topLeft = Offset(centre.x - radius, centre.y - radius),
                        size = Size(radius * 2, radius * 2),
                        // BUTT caps on the dashed arc, ROUND on the solid one. A round cap adds
                        // width/2 at EACH end of EVERY dash, so at a 7 dp stroke a [2, 7] dash renders
                        // as 9 dp of ink with a 0 dp gap — a line that looks solid while claiming to be
                        // dashed, which is the one outcome this change must not produce. With butt caps
                        // the numbers mean what they say.
                        style = Stroke(
                            width = width,
                            cap = if (dashed) StrokeCap.Butt else StrokeCap.Round,
                            pathEffect = if (dashed) {
                                PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 5.dp.toPx()))
                            } else {
                                null
                            },
                        ),
                    )
                }

                // The two arcs differ by PATTERN as well as tint. Opacity alone was the first cut and it
                // does not survive the card being translucent over a custom background image — the
                // reference arc washed out to near-invisible on a real device, which loses the comparison
                // the card exists for. A dash also reads without relying on colour at all.
                if (ideal != null) {
                    arc(outer, ideal.bedHour, ideal.wakeHour,
                        hue.copy(alpha = 0.55f), 7.dp.toPx(), dashed = true)
                }
                arc(inner, actualBedHour, actualWakeHour, hue, 9.dp.toPx(), dashed = false)

                // A marker at sleep ONSET. Without it the night arc has two indistinguishable ends and
                // the reader has to work out which way round the day runs before the picture means
                // anything — it turns "somewhere in this band" into "it started here". Sits on the arc
                // it marks, so it moves with the night rather than needing its own placement rule.
                val onset = Math.toRadians(hourAngleDegrees(actualBedHour))
                val glyph = 14.dp.toPx()
                translate(
                    left = centre.x + (cos(onset) * inner).toFloat() - glyph / 2f,
                    top = centre.y + (sin(onset) * inner).toFloat() - glyph / 2f,
                ) {
                    with(bedPainter) {
                        draw(Size(glyph, glyph), colorFilter = ColorFilter.tint(hue))
                    }
                }
            }

            DialLegend(hue)

            Text(alignment, style = NoopType.title2, color = Palette.textPrimary)

            CircadianEngine.chronotype(estimate)?.let { c ->
                Text(chronotypeText(c), style = NoopType.footnote, color = Palette.textTertiary)
            }
        }
    }
}

/**
 * Which arc is which. Without this the card shows two bands and no way to tell them apart — "outer means
 * ideal" is an arbitrary choice, not something a reader can infer. The swatches are drawn with the SAME
 * stroke style as the arcs so the mapping cannot drift apart from the drawing. Twin of Apple `legend`.
 */
@Composable
private fun DialLegend(hue: androidx.compose.ui.graphics.Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        LegendItem(hue, dashed = false, label = uiString(R.string.l10n_body_clock_dial_card_last_night_6eaba4dd))
        Spacer(Modifier.width(14.dp))
        LegendItem(hue.copy(alpha = 0.55f), dashed = true, label = uiString(R.string.l10n_body_clock_dial_card_your_clock_1b91f5ee))
    }
}

@Composable
private fun LegendItem(colour: androidx.compose.ui.graphics.Color, dashed: Boolean, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Canvas(modifier = Modifier.size(width = 18.dp, height = 4.dp)) {
            drawLine(
                color = colour,
                start = Offset(0f, size.height / 2f),
                end = Offset(size.width, size.height / 2f),
                strokeWidth = 3.dp.toPx(),
                cap = if (dashed) StrokeCap.Butt else StrokeCap.Round,
                pathEffect = if (dashed) {
                    PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 3.dp.toPx()))
                } else {
                    null
                },
            )
        }
        Spacer(Modifier.width(5.dp))
        Text(label, style = NoopType.footnote, color = Palette.textTertiary)
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
