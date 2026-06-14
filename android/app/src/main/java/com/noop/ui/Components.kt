package com.noop.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.foundation.Canvas
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

// MARK: - Locked component system (ported from StrandDesign/Components.swift + StrandCard.swift)
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference.

// MARK: - Frosted card surface (Bevel) + NoopCard
//
// The Bevel card surface: a dark blue-black fill (cardFillTop → cardFillBottom),
// rounded corners, a subtle DIAGONAL accent-gradient wash, a hairline rgba(255,255,
// 255,0.06) border and a soft shadow. `Modifier.frostedCardSurface(tint = …)` is the
// one place the look lives so NoopCard / ad-hoc surfaces all share it. Pass a domain
// tint (or null for the neutral brand-green wash).

/**
 * Paint the Bevel frosted-card surface (fill + diagonal accent wash + hairline border)
 * behind the content. [tint] colours the wash + border bias; null uses a near-neutral
 * brand-green wash. Drawn with `drawBehind` so the animation/recomposition of the card's
 * content never reaches this surface subtree. Mirrors StrandDesign's FrostedCardSurface.
 */
fun Modifier.frostedCardSurface(
    tint: Color? = null,
    cornerRadius: Dp = Metrics.cardRadius,
    washStrength: Float = 1f,
): Modifier = this.drawBehind {
    val wash = tint ?: Palette.accent
    val radiusPx = cornerRadius.toPx()
    val corner = androidx.compose.ui.geometry.CornerRadius(radiusPx, radiusPx)

    // 1) Dark blue-black vertical fill.
    drawRoundRect(
        brush = Brush.verticalGradient(
            colors = listOf(Palette.cardFillTop, Palette.cardFillBottom),
            startY = 0f, endY = size.height,
        ),
        cornerRadius = corner,
    )
    // 2) Subtle diagonal accent wash over the dark fill (top-leading → bottom-trailing).
    drawRoundRect(
        brush = Brush.linearGradient(
            colorStops = arrayOf(
                0.0f to wash.copy(alpha = 0.10f * washStrength),
                0.5f to wash.copy(alpha = 0.03f * washStrength),
                1.0f to Color.Transparent,
            ),
            start = Offset(0f, 0f),
            end = Offset(size.width, size.height),
        ),
        cornerRadius = corner,
    )
    // 3) Hairline border with a faint diagonal sheen + accent bias.
    drawRoundRect(
        brush = Brush.linearGradient(
            colorStops = arrayOf(
                0.0f to Color.White.copy(alpha = 0.08f),
                0.5f to Palette.hairline.copy(alpha = 0.9f),
                1.0f to wash.copy(alpha = 0.10f),
            ),
            start = Offset(0f, 0f),
            end = Offset(size.width, size.height),
        ),
        cornerRadius = corner,
        style = Stroke(width = 1.dp.toPx()),
    )
}

// MARK: - NoopCard — the one card surface (Bevel frosted card, 16dp radius)
//
// PUBLIC API is unchanged (modifier, padding, content); an optional [tint] was ADDED
// (defaulted null) so callers can opt into a per-domain accent wash without breaking
// existing call sites. Every existing NoopCard re-skins to the frosted Bevel surface.

@Composable
fun NoopCard(
    modifier: Modifier = Modifier,
    padding: Dp = Metrics.cardPadding,
    tint: Color? = null,
    content: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(Metrics.cardRadius)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .frostedCardSurface(tint = tint, cornerRadius = Metrics.cardRadius)
            .padding(padding),
    ) {
        content()
    }
}

// MARK: - DataPendingNote — the shared "what shows now vs what needs an import" banner
//
// A NoopCard with a leading AutoGraph glyph, a bold title and a body line. Every data
// screen drops one of these in its empty/partial state so the user always knows what is
// live now and what an import will backfill. Copy is passed verbatim by the call site.

@Composable
fun DataPendingNote(title: String, body: String, modifier: Modifier = Modifier) {
    NoopCard(modifier = modifier, padding = 18.dp) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Filled.AutoGraph,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(20.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

// MARK: - SyncingHistoryNote — pulsing "history sync in progress" line (#77)
//
// Shown above a screen's empty state while the strap's historical offload runs, so a half-loaded
// screen ("No nights here yet") reads as in-progress rather than final. Shows the honest live
// signal — chunks pulled so far — never a percent (total pending is unknowable from the protocol,
// so a determinate bar would lie).

@Composable
fun SyncingHistoryNote(chunks: Int, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        StatePill("Syncing strap history…", tone = StrandTone.Accent, pulsing = true)
        if (chunks > 0) {
            Text(
                "$chunks chunks pulled",
                style = NoopType.footnote,
                color = Palette.textSecondary,
            )
        }
    }
}

// MARK: - Overline label (ALL-CAPS, semibold, +0.8 tracking, secondary)

@Composable
fun Overline(text: String, modifier: Modifier = Modifier, color: Color = Palette.textSecondary) {
    Text(
        text = text.uppercase(),
        style = NoopType.overline,
        color = color,
        modifier = modifier,
    )
}

// MARK: - Section header

@Composable
fun SectionHeader(
    title: String,
    overline: String? = null,
    trailing: String? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            if (overline != null) Overline(overline)
            Text(title, style = NoopType.title2, color = Palette.textPrimary)
        }
        if (trailing != null) {
            Text(trailing, style = NoopType.footnote, color = Palette.textSecondary)
        }
    }
}

// MARK: - StrandTone (ported from StrandDesign/StatePill.swift)

enum class StrandTone(val color: Color) {
    Neutral(Palette.textSecondary),
    Accent(Palette.accent),
    Positive(Palette.statusPositive),
    Warning(Palette.statusWarning),
    Critical(Palette.statusCritical),
}

// MARK: - ConnectionDot — tiny status dot with optional breathing pulse halo

@Composable
fun ConnectionDot(
    tone: StrandTone = StrandTone.Positive,
    pulsing: Boolean = false,
    size: Dp = 9.dp,
    modifier: Modifier = Modifier,
) {
    val transition = rememberInfiniteTransition(label = "dot")
    val scale by transition.animateFloat(
        initialValue = 1.0f,
        targetValue = if (pulsing) 2.4f else 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(Motion.breathPeriodMs, easing = Motion.easeInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "dotScale",
    )
    val haloAlpha by transition.animateFloat(
        initialValue = 0.5f,
        targetValue = if (pulsing) 0.0f else 0.5f,
        animationSpec = infiniteRepeatable(
            animation = tween(Motion.breathPeriodMs, easing = Motion.easeInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "dotHalo",
    )
    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center,
    ) {
        if (pulsing) {
            Box(
                modifier = Modifier
                    .size(size)
                    .drawBehind {
                        drawCircleScaled(tone.color, scale, haloAlpha)
                    },
            )
        }
        Box(
            modifier = Modifier
                .size(size)
                .clip(CircleShape)
                .background(tone.color),
        )
    }
}

private fun DrawScope.drawCircleScaled(
    color: Color,
    scale: Float,
    alpha: Float,
) {
    drawCircle(color = color, radius = (size.minDimension / 2f) * scale, alpha = alpha)
}

// MARK: - StatePill — rounded pill with optional leading dot + tinted label

@Composable
fun StatePill(
    title: String,
    tone: StrandTone = StrandTone.Neutral,
    showsDot: Boolean = true,
    pulsing: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(50)
    Row(
        modifier = modifier
            .clip(shape)
            .background(tone.color.copy(alpha = 0.12f))
            .border(1.dp, tone.color.copy(alpha = 0.28f), shape)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = title },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (showsDot) ConnectionDot(tone = tone, pulsing = pulsing, size = 7.dp)
        Text(title, style = NoopType.overline.copy(letterSpacing = 0.4.sp), color = tone.color)
    }
}

// MARK: - SourceBadge

@Composable
fun SourceBadge(text: String, tint: Color = Palette.accent, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(50)
    Text(
        text = text.uppercase(),
        style = NoopType.overline.copy(fontSize = 10.sp, letterSpacing = 0.5.sp),
        color = tint,
        modifier = modifier
            .clip(shape)
            .background(tint.copy(alpha = 0.14f))
            .border(1.dp, tint.copy(alpha = 0.30f), shape)
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

// MARK: - TrendChip — a small tinted delta pill with a direction arrow.
//
// A compact trend pill: an up/down/flat arrow + the delta text, tinted to [color].
// Inferred direction comes from a leading +/− in the text (else flat). Sits in the
// corner of a StatTile or beside a metric value. Mirrors StrandDesign's TrendChip.

@Composable
fun TrendChip(text: String, color: Color = Palette.textTertiary, modifier: Modifier = Modifier) {
    val t = text.trim()
    val symbol = when {
        t.startsWith("+") || t.startsWith("▲") || t.lowercase().startsWith("up") -> "▲"
        t.startsWith("-") || t.startsWith("−") || t.startsWith("▼") || t.lowercase().startsWith("down") -> "▼"
        else -> "–"
    }
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(symbol, style = NoopType.captionNumber.copy(fontSize = 8.sp, fontWeight = FontWeight.Bold), color = color)
        Text(text, style = NoopType.captionNumber, color = color, maxLines = 1)
    }
}

// MARK: - StatTile — uniform fixed-height metric tile
//
// PUBLIC API unchanged (label, value, caption, accent, delta, deltaColor); an optional
// [tint] was ADDED (defaulted to the accent) so each tile reads as part of its colour
// world via a faint card wash. The delta now renders as a TrendChip.

@Composable
fun StatTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    accent: Color = Palette.textPrimary,
    delta: String? = null,
    deltaColor: Color = Palette.textTertiary,
    tint: Color? = null,
) {
    // Each tile borrows its accent as a faint card wash, so a metric reads as part of its
    // colour world while staying legible on the deep blue-black. Falls back to the accent.
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = 14.dp, tint = tint ?: accent) {
        Column {
            Overline(label)
            Spacer(Modifier.weight(1f))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    value,
                    style = NoopType.number(26f),
                    color = accent,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.weight(1f))
                if (delta != null) {
                    TrendChip(text = delta, color = deltaColor)
                }
            }
            if (caption != null) {
                Text(
                    caption, style = NoopType.footnote, color = Palette.textTertiary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
        }
    }
}

// MARK: - InsightCard
//
// PUBLIC API unchanged; an optional [tint] was ADDED (defaulted to the status colour)
// so the coaching card sits in the same colour world as the score it summarises.

@Composable
fun InsightCard(
    category: String,
    status: String,
    detail: String,
    modifier: Modifier = Modifier,
    statusColor: Color = Palette.accent,
    tint: Color? = null,
) {
    NoopCard(modifier = modifier, padding = 18.dp, tint = tint ?: statusColor) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Overline(category)
            Text(status, style = NoopType.title1, color = statusColor)
            Text(detail, style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}

// MARK: - SegmentedPillControl — the ONE segmented control

@Composable
fun <T> SegmentedPillControl(
    items: List<T>,
    selection: T,
    label: (T) -> String,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val outerShape = RoundedCornerShape(50)
    Row(
        modifier = modifier
            .clip(outerShape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, outerShape)
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        items.forEach { item ->
            val selected = item == selection
            // Selected segment fills with the brand-green gradient (accentHover → accent) and a
            // soft green glow, mirroring StrandDesign's SegmentedPillControl; unselected stays clear.
            val pillShape = RoundedCornerShape(50)
            val pillBg = if (selected) {
                Modifier.background(
                    Brush.verticalGradient(listOf(Palette.accentHover, Palette.accent)),
                    pillShape,
                )
            } else {
                Modifier
            }
            Text(
                text = label(item),
                style = NoopType.captionNumber,
                color = if (selected) Palette.surfaceBase else Palette.textSecondary,
                modifier = Modifier
                    .clip(pillShape)
                    .then(pillBg)
                    .clickableNoRipple { onSelect(item) }
                    .padding(horizontal = 11.dp, vertical = 6.dp),
            )
        }
    }
}

// MARK: - BevelGauge (NEW) — the layered ring gauge primitive
//
// The shared instrument behind RecoveryRing and StrainGauge: a 240° open gauge with
//   • a soft frosted inner disc (subtle radial fill, hairline rim)
//   • a faint full-span track ring
//   • a gradient-stroked progress arc (sweep gradient over the domain ramp)
//   • a soft outer BLOOM whose intensity scales with the fill (breathing pulse)
//   • a GLOWING end-cap dot at the arc tip (coloured halo + white core)
//   • a centred big rounded-bold number with an optional caption + state word
//
// It owns no domain logic — callers pass the fraction, the ramp stops, the tip colour
// and the centre read-out strings. RecoveryRing / StrainGauge keep their own public
// signatures and delegate here, so every screen re-skins without a call-site change.
// Mirrors StrandDesign/BevelGauge.swift.

@Composable
fun BevelGauge(
    fraction: Double,
    stops: List<Pair<Float, Color>>,
    tipColor: Color,
    numberText: String,
    modifier: Modifier = Modifier,
    captionText: String? = null,
    stateText: String? = null,
    supporting: String? = null,
    diameter: Dp = 200.dp,
    lineWidth: Dp = 16.dp,
    showsLabel: Boolean = true,
) {
    val frac = fraction.toFloat().coerceIn(0f, 1f)
    val startDeg = 150f          // lower-left
    val spanDeg = 240f           // 240° open gauge, gap centered at bottom

    val animatedFraction by animateFloatAsState(
        targetValue = frac,
        animationSpec = tween(Motion.durationSlow, easing = Motion.drawIn),
        label = "ringFill",
    )
    val breathe = rememberInfiniteTransition(label = "bloom")
    val bloomPulse by breathe.animateFloat(
        initialValue = 0.78f, targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            tween(Motion.breathPeriodMs, easing = Motion.easeInOut), RepeatMode.Reverse,
        ),
        label = "bloomPulse",
    )
    val bloomOpacity = (0.16f + 0.40f * frac) * bloomPulse
    val sweep = Brush.sweepGradient(*stops.toTypedArray())

    Box(
        modifier = modifier.size(diameter),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(diameter)
                .drawBehind {
                    val stroke = lineWidth.toPx()
                    val radius = (min(size.width, size.height) - stroke) / 2f
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val topLeft = Offset(center.x - radius, center.y - radius)
                    val arcSize = Size(radius * 2f, radius * 2f)
                    val sweepStroke = Stroke(width = stroke, cap = StrokeCap.Round)

                    // Frosted inner disc behind the arc — a glassy "well".
                    drawCircle(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                Palette.surfaceInset.copy(alpha = 0f),
                                Palette.surfaceInset.copy(alpha = 0.55f),
                            ),
                            center = center,
                            radius = radius,
                        ),
                        radius = (radius - stroke * 0.4f).coerceAtLeast(1f),
                        center = center,
                    )

                    // Outer bloom — a soft, lower-opacity wide arc (drawn first, under the track).
                    if (animatedFraction > 0.001f) {
                        drawArc(
                            brush = sweep,
                            startAngle = startDeg,
                            sweepAngle = spanDeg * animatedFraction,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = Stroke(width = stroke * 1.7f, cap = StrokeCap.Round),
                            alpha = bloomOpacity,
                        )
                    }

                    // Faint full-span track.
                    drawArc(
                        color = Palette.hairline.copy(alpha = 0.6f),
                        startAngle = startDeg,
                        sweepAngle = spanDeg,
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = sweepStroke,
                    )

                    // Filled gradient arc.
                    if (animatedFraction > 0.001f) {
                        drawArc(
                            brush = sweep,
                            startAngle = startDeg,
                            sweepAngle = spanDeg * animatedFraction,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = sweepStroke,
                        )

                        // Glowing end-cap dot at the arc tip: coloured halo + white core.
                        val tipAngle = Math.toRadians((startDeg + spanDeg * animatedFraction).toDouble())
                        val bead = Offset(
                            center.x + radius * cos(tipAngle).toFloat(),
                            center.y + radius * sin(tipAngle).toFloat(),
                        )
                        drawCircle(color = tipColor.copy(alpha = 0.35f), radius = stroke * 1.3f, center = bead)
                        drawCircle(color = tipColor.copy(alpha = 0.7f), radius = stroke * 0.85f, center = bead)
                        drawCircle(color = Color.White, radius = stroke * 0.33f, center = bead)
                    }
                },
        )

        if (showsLabel) {
            // Big rounded-bold number ≈ diameter * 0.30.
            val numberSp = diameter.value * 0.30f
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    text = numberText,
                    style = NoopType.display(numberSp).copy(fontWeight = FontWeight.Bold),
                    color = Palette.textPrimary,
                )
                if (captionText != null) {
                    Text(
                        text = captionText,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                if (stateText != null) {
                    Text(
                        text = stateText,
                        style = NoopType.overline,
                        color = tipColor,
                        modifier = Modifier.padding(top = 2.dp),
                    )
                }
                if (supporting != null) {
                    Text(
                        text = supporting,
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }
}

// MARK: - RecoveryRing (Bevel layered gauge) — THE signature Charge / Rest component
//
// PUBLIC API is unchanged (score, supporting, diameter, lineWidth, showsLabel); it now
// delegates its visuals to [BevelGauge]. An optional [valueFormat] was ADDED (defaulted)
// so the Rest hero can show "Rest 87" while Charge keeps the bare number — same shape as
// the macOS RecoveryRing.valueFormat. The state word + tip colour sample the recovery ramp.

@Composable
fun RecoveryRing(
    score: Double,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    diameter: Dp = 240.dp,
    lineWidth: Dp = 16.dp,
    showsLabel: Boolean = true,
    valueFormat: ((Double) -> String)? = null,
) {
    BevelGauge(
        fraction = score / 100.0,
        stops = Palette.recoveryStops,
        tipColor = Palette.recoveryColor(score),
        numberText = valueFormat?.invoke(score) ?: score.toInt().toString(),
        stateText = Palette.recoveryState(score),
        supporting = supporting,
        diameter = diameter,
        lineWidth = lineWidth,
        showsLabel = showsLabel,
        modifier = modifier,
    )
}

// MARK: - StrainGauge (NEW) — the Effort hero gauge on the 0–21 scale
//
// The Effort sibling of RecoveryRing: a [BevelGauge] over the amber strain ramp, with
// the centre number on WHOOP's 0–21 axis and an "of 21" caption. The arc fills to
// strain/21. Mirrors StrandDesign's StrainGauge so the hero row reads as three matched
// instruments (Charge green · Effort amber · Rest indigo).

@Composable
fun StrainGauge(
    strain: Double,
    modifier: Modifier = Modifier,
    diameter: Dp = 240.dp,
    lineWidth: Dp = 16.dp,
    showsLabel: Boolean = true,
) {
    val clamped = strain.coerceIn(0.0, 21.0)
    BevelGauge(
        fraction = clamped / 21.0,
        stops = Palette.strainStops,
        tipColor = Palette.strainColor((clamped / 21.0) * 100.0),
        numberText = if (clamped % 1.0 == 0.0) clamped.toInt().toString() else String.format(java.util.Locale.US, "%.1f", clamped),
        captionText = "of 21",
        diameter = diameter,
        lineWidth = lineWidth,
        showsLabel = showsLabel,
        modifier = modifier,
    )
}

// MARK: - ScenicHeroBackground (NEW) — premium hero backdrop
//
// A Canvas-drawn radial deep blue-black gradient (warm-lit center → near-black edge)
// sprinkled with a faint DETERMINISTIC starfield, optionally tinted toward a domain's
// glow, with a bottom fade so content sits cleanly over it. Deterministic (fixed star
// positions) so it never flickers; decorative, so hidden from accessibility by the
// caller's container. Mirrors StrandDesign's ScenicHeroBackground.

@Composable
fun ScenicHeroBackground(
    modifier: Modifier = Modifier,
    domain: DomainTheme? = null,
    starCount: Int = 40,
    fadesToBase: Boolean = true,
) {
    Box(modifier = modifier.semantics { contentDescription = "" }) {
        Canvas(modifier = Modifier.matchParentSize()) {
            val w = size.width
            val h = size.height
            if (w <= 0f || h <= 0f) return@Canvas

            // Radial deep blue-black: lit center → near-black edge.
            drawRect(
                brush = Brush.radialGradient(
                    colors = listOf(Palette.scenicCenter, Palette.scenicEdge),
                    center = Offset(w * 0.5f, h * 0.36f),
                    radius = maxOf(w, h) * 0.95f,
                ),
            )

            // A soft domain-tinted bloom near the top, if a world is named.
            if (domain != null) {
                drawRect(
                    brush = Brush.radialGradient(
                        colors = listOf(domain.glow.copy(alpha = 0.18f), Color.Transparent),
                        center = Offset(w * 0.5f, h * 0.30f),
                        radius = maxOf(w, h) * 0.6f,
                    ),
                )
            }

            // Deterministic starfield — fixed positions/sizes so it can't flicker.
            val wi = maxOf(1, w.toInt())
            val topBand = maxOf(1, (h * 0.55f).toInt())
            for (i in 0 until starCount) {
                val x = ((i * 73 + 31) % wi).toFloat()
                val y = (18 + ((i * 41) % topBand)).toFloat()
                val r = if (i % 9 == 0) 1.3f else 0.7f
                val alpha = if (i % 5 == 0) 0.34f else 0.18f
                drawCircle(
                    color = Palette.scenicStar.copy(alpha = alpha),
                    radius = r,
                    center = Offset(x, y),
                )
            }

            // Bottom fade so a hero number / card reads cleanly over the field.
            if (fadesToBase) {
                drawRect(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            Color.Transparent,
                            Palette.scenicEdge.copy(alpha = 0.72f),
                            Palette.scenicEdge,
                        ),
                        startY = h * 0.5f,
                        endY = h,
                    ),
                )
            }
        }
    }
}

// MARK: - ScreenScaffold (ported from Strand/Screens/ScreenScaffold.swift)
//
// Standard scrollable screen container: a title + optional subtitle header over the
// dark surface, then a left-aligned content column with 28dp screen padding.

@Composable
fun ScreenScaffold(
    title: String,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Palette.surfaceBase)
            .verticalScroll(rememberScrollState())
            .padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = NoopType.title1, color = Palette.textPrimary)
            if (subtitle != null) {
                Text(subtitle, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
        content()
    }
}

// MARK: - Stepper field (Compose has no Stepper — tabular value + round −/+ buttons)
//
// The canonical profile editor used by both Settings and onboarding. Reuse this
// rather than forking sliders or bespoke button sizes, so every numeric profile
// field reads and behaves identically across the app.

@Composable
fun StepperField(
    value: String,
    accessibility: String,
    unit: String? = null,
    valueColor: Color = Palette.textPrimary,
    onMinus: () -> Unit,
    onPlus: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics { contentDescription = accessibility },
    ) {
        Text(
            value,
            style = NoopType.bodyNumber,
            color = valueColor,
            modifier = Modifier.widthIn(min = 44.dp),
        )
        if (unit != null) {
            Text(unit, style = NoopType.caption, color = Palette.textTertiary)
        }
        StepperButton(symbol = "−", onClick = onMinus, label = "Decrease $accessibility")
        StepperButton(symbol = "+", onClick = onPlus, label = "Increase $accessibility")
    }
}

@Composable
fun StepperButton(symbol: String, onClick: () -> Unit, label: String) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = NoopType.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
    }
}

// MARK: - Small interaction helper (clickable without ripple, for pill segments)

@Composable
private fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier =
    this.clickable(
        indication = null,
        interactionSource = remember { MutableInteractionSource() },
        onClick = onClick,
    )
