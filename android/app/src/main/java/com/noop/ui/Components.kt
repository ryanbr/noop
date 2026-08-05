package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.animation.core.RepeatMode
import androidx.compose.foundation.Canvas
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoGraph
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import android.content.Context
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
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

// MARK: - Frosted card surface (Titanium & Gold) + NoopCard
//
// The card surface: a deep-navy fill (cardFillTop → cardFillBottom), rounded corners, a
// very faint DIAGONAL accent-gradient wash and a flat 1px hairline border — NO shadow
// (Titanium & Gold cards sit flat on the navy field; depth comes from the hairline + fill,
// not a drop shadow). `Modifier.frostedCardSurface(tint = …)` is the one place the look
// lives so NoopCard / ad-hoc surfaces all share it. Pass a domain tint (or null for the
// neutral gold wash).

/**
 * Paint the frosted-card surface (navy fill + faint diagonal accent wash + flat hairline
 * border, no shadow) behind the content. [tint] colours the wash + border bias; null uses a
 * near-neutral gold wash. Drawn with `drawBehind` so the animation/recomposition of the card's
 * content never reaches this surface subtree. Mirrors StrandDesign's FrostedCardSurface.
 */
/** App-wide card-surface opacity (0f = fully see-through, 1f = solid), driven by the "Card transparency"
 *  setting. Reactive (a mutableState) so the Settings slider live-previews; initialised from NoopPrefs at
 *  app start via [init]. Only the card SURFACE (fill + border + wash) fades — the card's CONTENT is drawn
 *  above and stays fully readable over the background. */
object CardAppearance {
    var opacity by mutableStateOf(1f)
    fun init(context: Context) {
        opacity = (NoopPrefs.cardOpacityPercent(context) / 100f).coerceIn(0f, 1f)
    }
}

fun Modifier.frostedCardSurface(
    tint: Color? = null,
    cornerRadius: Dp = Metrics.cardRadius,
    washStrength: Float = 1f,
): Modifier = composed {
    // "Card transparency" setting: scale the whole glass surface (fill + border + wash) by the user's
    // opacity so cards fade toward the background. Reading the reactive value here makes the slider
    // live-preview. Content drawn above the surface is unaffected, so numbers/labels stay readable.
    val op = CardAppearance.opacity
    this
        // Elevation idiom: DARK is flat (the hairline + hue carry the edge). LIGHT raises the white card
        // off the warm-paper canvas with a soft drop shadow — the hairline alone is too faint on paper.
        .then(
            if (Palette.isLight)
                Modifier.shadow(elevation = (6f * op).dp, shape = RoundedCornerShape(cornerRadius), clip = false)
            else Modifier
        )
        .drawBehind {
            val radiusPx = cornerRadius.toPx()
            val corner = androidx.compose.ui.geometry.CornerRadius(radiusPx, radiusPx)
            val fill = Palette.surfaceRaised.copy(alpha = Palette.surfaceRaised.alpha * op)
            val border = Palette.hairline.copy(alpha = Palette.hairline.alpha * op)

            if (tint == null) {
                // NEUTRAL card (iOS FrostedCardSurface tint == nil): a FLAT raised surface — no vertical
                // bevel gradient, no accent wash, and a PLAIN hairline border (no accent bias).
                drawRoundRect(color = fill, cornerRadius = corner)
                drawRoundRect(color = border, cornerRadius = corner, style = Stroke(width = 1.dp.toPx()))
            } else {
                // TINTED card (iOS parity, 2026-06-23 "synthesis has the old blue style"): a FLAT raised
                // surface — the SAME WHOOP grey as the neutral card, NO navy bevel gradient — carrying only
                // a whisper of the domain tint as a diagonal hue wash so it stays in the grey family.
                // 1) Flat raised fill — identical to the neutral card.
                drawRoundRect(color = fill, cornerRadius = corner)
                // 2) Faint diagonal accent hue wash over the flat fill (matches iOS FrostedCardSurface ~0.05).
                drawRoundRect(
                    brush = Brush.linearGradient(
                        colorStops = arrayOf(
                            0.0f to tint.copy(alpha = 0.05f * washStrength * op),
                            0.5f to tint.copy(alpha = 0.015f * washStrength * op),
                            1.0f to Color.Transparent,
                        ),
                        start = Offset(0f, 0f),
                        end = Offset(size.width, size.height),
                    ),
                    cornerRadius = corner,
                )
                // 3) Plain 1px hairline (no accent bias) — matches the neutral card.
                drawRoundRect(color = border, cornerRadius = corner, style = Stroke(width = 1.dp.toPx()))
            }
        }
}

// MARK: - NoopCard — the one card surface (Titanium & Gold frosted card, 16dp radius)
//
// PUBLIC API is unchanged (modifier, padding, content); an optional [tint] was ADDED
// (defaulted null) so callers can opt into a per-domain accent wash without breaking
// existing call sites. Every existing NoopCard re-skins to the navy fill + flat hairline.

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
                uiString(R.string.l10n_components_chunks_chunks_pulled_cec186cf, chunks),
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
    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center,
    ) {
        // PERF (#scroll-jank): only spin up the infinite breathing transition when the dot ACTUALLY pulses.
        // The transition lived unconditionally here, so every static (non-pulsing) ConnectionDot — and there
        // are several on Today (each StatePill, source pill, etc.) — kept a running animation-clock
        // subscription invalidating the frame, for a halo that wasn't even drawn. Hoisting it into a child
        // that's composed only when `pulsing` means a still dot does zero per-frame work. Identical visuals.
        // ...and not at all under Reduce Motion or battery saver: the halo is decoration, and an
        // infinite transition per live dot is exactly the idle per-frame work battery saver asks an app
        // to stop. A still dot still reads as live — the colour carries that. (#909)
        val renderStill = rememberPoseStill()
        if (pulsing && !renderStill) {
            PulsingDotHalo(tone = tone, size = size)
        }
        Box(
            modifier = Modifier
                .size(size)
                .clip(CircleShape)
                .background(tone.color),
        )
    }
}

/** The breathing halo behind a LIVE [ConnectionDot]. Isolated so the infinite transition only exists while
 *  the dot is actually pulsing (a still dot creates no animation subscription — the scroll-jank fix). */
@Composable
private fun PulsingDotHalo(tone: StrandTone, size: Dp) {
    val transition = rememberInfiniteTransition(label = "dot")
    val scale by transition.animateFloat(
        initialValue = 1.0f,
        targetValue = 2.4f,
        animationSpec = infiniteRepeatable(
            animation = tween(Motion.breathPeriodMs, easing = Motion.easeInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = uiString(R.string.l10n_components_dotscale_5bc02101),
    )
    val haloAlpha by transition.animateFloat(
        initialValue = 0.5f,
        targetValue = 0.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(Motion.breathPeriodMs, easing = Motion.easeInOut),
            repeatMode = RepeatMode.Reverse,
        ),
        label = uiString(R.string.l10n_components_dothalo_3332546c),
    )
    Box(
        modifier = Modifier
            .size(size)
            .drawBehind {
                drawCircleScaled(tone.color, scale, haloAlpha)
            },
    )
}

private fun DrawScope.drawCircleScaled(
    color: Color,
    scale: Float,
    alpha: Float,
) {
    drawCircle(color = color, radius = (size.minDimension / 2f) * scale, alpha = alpha)
}

// MARK: - StatePill — rounded pill with optional leading dot + tinted label
//
// The status chip behind SOLID / BUILDING / CALIBRATING / LIVE. The tone owns the hue:
//   • SOLID       → StrandTone.Accent/Positive — gold dot + gold@.12 fill + gold@.32 border + gold text
//   • BUILDING    → StrandTone.Warning re-valued to blue #4A90E2 by the theme lane
//   • CALIBRATING → StrandTone.Neutral — slate #8A94A4 (textTertiary world)
//   • LIVE        → gold tone + pulsing=true → the ConnectionDot grows a breathing gold halo
// Fill .12 / border .32 / text full-strength matches the Titanium & Gold spec on every tone.

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
            .border(1.dp, tone.color.copy(alpha = 0.32f), shape)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = title },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (showsDot) ConnectionDot(tone = tone, pulsing = pulsing, size = 7.dp)
        // A pill is a single line: ellipsize a long title (e.g. a long custom model id) instead of
        // wrapping it, so it can't eat a whole Row and squeeze a sibling control to nothing (#1074).
        Text(
            title, style = NoopType.overline.copy(letterSpacing = 0.4.sp), color = tone.color,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

// MARK: - SourceBadge

@Composable
fun SourceBadge(text: String, tint: Color = Palette.accent, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(50)
    Box(
        // The pill itself. The label used to BE this node, with `heightIn` pinning it to 18.dp — and a
        // 10.sp line box is ~13.dp, so the ~5.dp of slack all fell below the text and pushed it upward.
        // SwiftUI's twin uses `.frame(height:)`, which centres by default, so the two platforms drew the
        // same badge differently. A Box that owns the height and centres its content matches iOS and
        // keeps the label centred at any font scale.
        modifier = modifier
            // Preserve the canonical compact height at the default font scale, but grow instead of clipping
            // when Android's font scaling makes the single-line label taller.
            .heightIn(min = Metrics.sourceBadgeHeight)
            .clip(shape)
            .background(tint.copy(alpha = 0.14f))
            .border(1.dp, tint.copy(alpha = 0.30f), shape)
            .padding(horizontal = Metrics.space8),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text.uppercase(),
            style = NoopType.overline.copy(fontSize = 10.sp, letterSpacing = 0.5.sp),
            color = tint,
            maxLines = 1,                      // #74: e.g. "ON-DEVICE" stays on one line, never wraps the hero
            overflow = TextOverflow.Ellipsis,
        )
    }
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
        // No sign → a plain magnitude (e.g. a workout's "874 kcal"), not a trend: show NO direction
        // glyph. Previously this fell to "–", whose leading dash read as a negative ("-874 kcal" — #41).
        else -> null
    }
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        if (symbol != null) Text(symbol, style = NoopType.captionNumber.copy(fontSize = 8.sp, fontWeight = FontWeight.Bold), color = color)
        // Ellipsize rather than overflow if a caller constrains the chip's width (e.g. the workout
        // tiles' compactDelta path) — keeps the pill inside its share of the row (#332).
        Text(text, style = NoopType.captionNumber, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: - StatTile — uniform fixed-height metric tile
//
// PUBLIC API unchanged (label, value, caption, accent, delta, deltaColor); an optional
// [tint] was ADDED (defaulted to the accent) so each tile reads as part of its colour
// world via a faint card wash. The delta now renders as a TrendChip.

// MARK: - AutoSizeValue — a single-line value that SHRINKS to fit instead of truncating
//
// Compose (BOM 2024.06) has no `TextAutoSize`, and the metric/workout tiles are narrow with a
// trailing sparkline or kcal chip — so a value like "1h 52m" or a tile number was ellipsizing to
// "1…" (#319/#332). This steps the font down (to a 0.6× floor, matching the Swift tile's
// minimumScaleFactor) until the text fits one line, then holds. Resets when the text/style changes.
@Composable
internal fun AutoSizeValue(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    minScale: Float = 0.6f,
) {
    var scale by remember(text, style) { mutableStateOf(1f) }
    Text(
        text = text,
        color = color,
        style = style,
        fontSize = style.fontSize * scale,
        maxLines = 1,
        softWrap = false,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier,
        onTextLayout = { result ->
            if (result.didOverflowWidth && scale > minScale) {
                scale = maxOf(minScale, scale - 0.08f)
            }
        },
    )
}

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
    // When true, the trailing delta chip yields width to the value instead of taking its full
    // intrinsic size. Used by narrow two-column tiles where a wide chip (e.g. "1234 kcal" or
    // "+10 vs base") would otherwise starve the reading column and clip its value. The default
    // keeps callers that have enough width exactly as they were.
    compactDelta: Boolean = false,
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
                // Value takes priority width and SHRINKS to fit (down to 0.6×) rather than
                // truncating to "1…", matching the Swift tile's minimumScaleFactor (#319/#332).
                // The chip keeps its intrinsic size at the end.
                AutoSizeValue(
                    value,
                    style = NoopType.number(26f),
                    color = accent,
                    modifier = Modifier.weight(1f),
                )
                if (delta != null) {
                    Spacer(Modifier.width(8.dp))
                    // In compact mode the chip shares the row's remaining space (fill = false, so it
                    // never grows past its content) — this guarantees the weighted value column keeps
                    // its half and the primary reading remains intact beside a wide chip (#332/#492).
                    TrendChip(
                        text = delta,
                        color = deltaColor,
                        modifier = if (compactDelta) Modifier.weight(1f, fill = false) else Modifier,
                    )
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
    // Opt-in compact mode for long option sets. The track fills its parent and gives each segment an
    // equal share instead of letting intrinsic label padding widen the surrounding card past the screen.
    // Defaulted so the shorter controls keep their existing sizing.
    adaptsToAvailableWidth: Boolean = false,
    // Per-segment availability (#943): a disabled segment stays VISIBLE (dimmed, not clickable) so the
    // control can teach that an option exists before it is usable, e.g. trend ranges that unlock as
    // history builds. Defaulted so every existing call site is untouched.
    enabled: (T) -> Boolean = { true },
) {
    val outerShape = RoundedCornerShape(50)
    val scrollsForLargeText = adaptsToAvailableWidth && LocalDensity.current.fontScale > 1f
    val usesEqualWidth = adaptsToAvailableWidth && !scrollsForLargeText
    val rangeScrollState = rememberScrollState()
    // The track is a fixed-height pill; the selected pill FILLS that height so its inset is EQUAL on
    // every side (container padding 4, pill horizontal padding only). The old compact pill inside a
    // taller row left more vertical margin than horizontal — it read as off-centre. Mirrors iOS's
    // SegmentedPillControl refresh (segment height 36, pill fills it for an even inset).
    Row(
        modifier = modifier
            .then(if (scrollsForLargeText) Modifier.horizontalScroll(rangeScrollState) else Modifier)
            .then(if (usesEqualWidth) Modifier.fillMaxWidth() else Modifier)
            .height(36.dp)
            .clip(outerShape)
            .background(Palette.surfaceInset)
            .border(1.dp, Palette.hairline, outerShape)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEach { item ->
            val selected = item == selection
            val itemEnabled = enabled(item)
            // Selected segment is SELECTION CHROME → follows the accent: a gold gradient + gold-deep ink
            // on dark; a flat blue accent + white ink on light (so light selection matches the blue
            // chrome, not gold). Unselected stays clear with tertiary text; disabled dims further.
            val pillShape = RoundedCornerShape(50)
            val pillBg = if (selected) {
                if (Palette.isLight) Modifier.background(Palette.accent, pillShape)
                else Modifier.background(Brush.linearGradient(*Palette.goldGradient.toTypedArray()), pillShape)
            } else {
                Modifier
            }
            Box(
                modifier = Modifier
                    // Fill the track height so the pill's inset is equal top/bottom/left/right.
                    .then(if (usesEqualWidth) Modifier.weight(1f) else Modifier)
                    .fillMaxHeight()
                    .clip(pillShape)
                    .then(pillBg)
                    .then(if (itemEnabled) Modifier.clickableNoRipple { onSelect(item) } else Modifier)
                    .padding(horizontal = if (usesEqualWidth) Metrics.space4 else 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = label(item),
                    style = NoopType.captionNumber,
                    maxLines = if (adaptsToAvailableWidth) 1 else Int.MAX_VALUE,
                    overflow = if (adaptsToAvailableWidth) TextOverflow.Ellipsis else TextOverflow.Clip,
                    color = when {
                        selected && Palette.isLight -> androidx.compose.ui.graphics.Color.White
                        selected -> Palette.goldDeepText
                        !itemEnabled -> Palette.textTertiary.copy(alpha = 0.45f)
                        else -> Palette.textTertiary
                    },
                )
            }
        }
    }
}

// MARK: - BevelGauge (NEW) — the layered ring gauge primitive
//
// The shared instrument behind RecoveryRing and StrainGauge: an open gauge with
//   • a soft frosted inner disc (subtle radial fill, hairline rim)
//   • a faint full-span track ring
//   • a gradient-stroked progress arc (sweep gradient over the domain ramp)
//   • a soft outer BLOOM whose intensity scales with the fill (breathing pulse)
//   • a GLOWING end-cap dot at the arc tip (coloured halo + white core)
//   • a centred big bold number with an optional wordmark / caption / state word
//
// It owns no domain logic — callers pass the fraction, the ramp stops, the tip colour
// and the centre read-out strings. RecoveryRing / StrainGauge keep their own public
// signatures and delegate here, so every screen re-skins without a call-site change.
//
// The geometry defaults to the Bevel 240° instrument (gap at the bottom). Three optional
// params (defaulted, so every existing call site is untouched) let the RecoveryRing brand
// glyph diverge: [startDeg]/[spanDeg] override the arc (it uses −90° / ~288° = open ~80%
// ring, clockwise), [coreDot] paints a SOLID gold core dot at the centre, and [wordmark]
// stamps a micro ALL-CAPS "NOOP" above the number. Mirrors StrandDesign/BevelGauge.swift.

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
    startDeg: Float = 150f,      // default: lower-left start of the 240° Bevel gauge
    spanDeg: Float = 240f,       // default: 240° open gauge, gap centered at bottom
    coreDot: Color? = null,      // RecoveryRing brand glyph: a solid core dot at the centre
    wordmark: String? = null,    // RecoveryRing brand glyph: micro ALL-CAPS mark above the number
) {
    val frac = fraction.toFloat().coerceIn(0f, 1f)

    val animatedFraction by animateFloatAsState(
        targetValue = frac,
        animationSpec = tween(Motion.durationSlow, easing = Motion.drawIn),
        label = uiString(R.string.l10n_components_ringfill_59cd4fb9),
    )
    // Outer bloom — a faint, STATIC glow. The breathing pulse is gone (matching iOS): it sits calm so
    // the ring reads flat/Material, not glowing. Strength tracks the iOS bloomOpacity (0.05 + 0.13·frac)
    // — a restrained additive halo, well down from the old (0.16 + 0.40·frac) pulse.
    val bloomOpacity = 0.05f + 0.13f * frac
    val sweep = Brush.sweepGradient(*stops.toTypedArray())

    Box(
        modifier = modifier.size(diameter),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(diameter)
                // PERF (#scroll-jank): the frosted inner disc + its hairline rim — and crucially the
                // radial-gradient disc Brush they need — are STATIC (they read neither the animated
                // fraction nor any scroll state) yet shared one drawBehind with the fraction-driven arc,
                // so they were re-issued every animation/scroll frame. Hoist JUST the disc + rim into
                // drawWithCache (keyed on the implicit size + lineWidth + the palette tones) so they
                // rasterise once and replay as a texture. The track stays in the per-frame layer because
                // the original z-order is disc → rim → BLOOM → track → fill arc → cap, i.e. the bloom (a
                // fraction-driven, per-frame layer) sits BETWEEN the rim and the track — caching the track
                // above the bloom would move it over the bloom and change the pixels. The remaining
                // per-frame layer is just the track + bloom + fill arc + cap + core (a handful of
                // drawArc/drawCircle calls), no longer the expensive radial disc. Pixel-identical.
                .drawWithCache {
                    val stroke = lineWidth.toPx()
                    val radius = (min(size.width, size.height) - stroke) / 2f
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val discRadius = (radius - stroke * 0.4f).coerceAtLeast(1f)
                    val discBrush = Brush.radialGradient(
                        colors = listOf(
                            Palette.surfaceInset.copy(alpha = 0f),
                            Palette.surfaceInset.copy(alpha = 0.55f),
                        ),
                        center = center,
                        radius = radius,
                    )
                    val rimStroke = Stroke(width = 1.dp.toPx())
                    onDrawBehind {
                        // Frosted inner disc behind the arc — a glassy "well".
                        drawCircle(brush = discBrush, radius = discRadius, center = center)
                        // Faint hairline rim around the inner disc (iOS innerDisc strokeBorder hairline 0.5).
                        drawCircle(
                            color = Palette.hairline.copy(alpha = 0.5f),
                            radius = discRadius,
                            center = center,
                            style = rimStroke,
                        )
                    }
                }
                // The per-frame layer: bloom + full-span track + fill arc + end cap + brand core, in the
                // ORIGINAL order. Drawn AFTER (over) the cached disc/rim. Reads animatedFraction so it
                // re-issues per frame, but it is only a few drawArc/drawCircle calls now.
                .drawBehind {
                    val stroke = lineWidth.toPx()
                    val radius = (min(size.width, size.height) - stroke) / 2f
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val topLeft = Offset(center.x - radius, center.y - radius)
                    val arcSize = Size(radius * 2f, radius * 2f)
                    val sweepStroke = Stroke(width = stroke, cap = StrokeCap.Round)

                    // Outer bloom — a soft, lower-opacity wide arc (drawn first, under the track).
                    // A glow only reads on the dark canvas; on the white light card it just smears the
                    // edge, so it's suppressed there (the deepened arc carries the ring on its own).
                    // Drawn at the restrained, static [bloomOpacity] (≈0.05–0.18) — crisp, not glowing.
                    if (animatedFraction > 0.001f && !Palette.isLight) {
                        drawArc(
                            brush = sweep,
                            startAngle = startDeg,
                            sweepAngle = spanDeg * animatedFraction,
                            useCenter = false,
                            topLeft = topLeft,
                            size = arcSize,
                            style = Stroke(width = stroke * 1.15f, cap = StrokeCap.Round),
                            alpha = bloomOpacity,
                        )
                    }

                    // Full-span track — the carved inset "well" the arc sits in (iOS: solid surfaceInset,
                    // full opacity, same round cap), not a faint hairline. Stays here (over the bloom,
                    // under the fill arc) to preserve the exact original z-order.
                    drawArc(
                        color = Palette.surfaceInset,
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

                        // Clean Material end-cap (iOS BevelGauge.endCap): a single small tipCore dot with a
                        // faint tip-coloured overlay — half the old size, no saturated full-colour disc and
                        // no hard white centre pip ("the dot" the maintainer flagged).
                        val tipAngle = Math.toRadians((startDeg + spanDeg * animatedFraction).toDouble())
                        val bead = Offset(
                            center.x + radius * cos(tipAngle).toFloat(),
                            center.y + radius * sin(tipAngle).toFloat(),
                        )
                        drawCircle(color = Palette.tipCore, radius = stroke * 0.35f, center = bead)
                        drawCircle(color = tipColor.copy(alpha = 0.35f), radius = stroke * 0.35f, center = bead)
                    }

                    // Brand glyph core: a small solid gold dot at the very centre — but ONLY in the
                    // glyph-only lock-up (logo / nav). When a number is shown the dot sits behind the
                    // digits and muddies them (community feedback at the v3 launch), so suppress it
                    // whenever showsLabel — leaving a clean ring + number + micro-NOOP wordmark.
                    if (coreDot != null && !showsLabel) {
                        drawCircle(color = coreDot, radius = stroke * 0.40f, center = center)
                    }
                },
        )

        if (showsLabel) {
            // Big bold number ≈ diameter * 0.30.
            val numberSp = diameter.value * 0.30f
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                // Micro ALL-CAPS NOOP wordmark above the number (RecoveryRing brand glyph).
                if (wordmark != null) {
                    Text(
                        text = wordmark.uppercase(),
                        style = NoopType.overline.copy(
                            fontSize = (numberSp * 0.16f).sp,
                            letterSpacing = (numberSp * 0.055f).sp,  // ≈ .34em wordmark tracking
                            fontWeight = FontWeight.Bold,
                        ),
                        color = Palette.gold,
                        modifier = Modifier.padding(bottom = 1.dp),
                    )
                }
                Text(
                    text = numberText,
                    style = NoopType.display(numberSp).copy(fontWeight = FontWeight.Bold),
                    color = Palette.textPrimary,
                )
                if (captionText != null) {
                    // Caption scales WITH the gauge (iOS: rounded(diameter*0.085, .medium)).
                    Text(
                        text = captionText,
                        style = NoopType.footnote.copy(
                            fontSize = (diameter.value * 0.085f).sp,
                            fontWeight = FontWeight.Medium,
                        ),
                        color = Palette.textTertiary,
                    )
                }
                if (stateText != null) {
                    // State word scales with the gauge so it never overflows the small three-up rings
                    // (#403): stateSize = min(11, diameter*0.085), with the overline tracking scaled to
                    // match. Pinned to the original 11pt on the large solo-hero rings (≥130dp).
                    val stateSize = minOf(11f, diameter.value * 0.085f)
                    Text(
                        text = stateText,
                        style = NoopType.overline.copy(
                            fontSize = stateSize.sp,
                            letterSpacing = (NoopType.overlineTracking * stateSize / 11f).sp,
                        ),
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

// MARK: - RecoveryRing (Titanium & Gold brand glyph) — THE signature Charge / Rest component
//
// PUBLIC API is unchanged (score, supporting, diameter, lineWidth, showsLabel); it now
// delegates its visuals to [BevelGauge]. An optional [valueFormat] was ADDED (defaulted)
// so the Rest hero can show "Rest 87" while Charge keeps the bare number — same shape as
// the macOS RecoveryRing.valueFormat. The state word + tip colour sample the recovery (gold)
// ramp. Unlike the Bevel 240° gauge it draws the BRAND GLYPH: an open ~80% ring starting at
// −90° (12 o'clock) clockwise, a solid gold centre core dot and a micro "NOOP" wordmark.

// MARK: - GlowRing — crisp WHOOP-style score ring (Compose parity with iOS StrandDesign.GlowRing, #23)
//
// A clean solid arc with round caps over a clearly-visible full-circle track, a bold centred number
// that counts up from 0, and a tight low-alpha glow hugging the arc. The arc springs in from 12
// o'clock and re-animates when the value changes (day nav). minSdk-safe (no RenderEffect blur).

/**
 * The centre-number text style for a ring of the given [diameter] — the house numeral at `diameter * 0.36`,
 * Bold. The ONE source of truth for a ring's centre number, shared by [GlowRing]'s live label and the
 * carried-value overlay on the Today hero so a carried Charge, a clean value and (at the headline size)
 * "No Data" read with one consistent size + weight. Mirrors iOS `GlowRing.centerFont(diameter:)`.
 */
fun glowRingCenterTextStyle(diameter: Dp, color: Color = Palette.textPrimary): TextStyle =
    TextStyle(fontWeight = FontWeight.Bold, fontSize = (diameter.value * 0.36f).sp, color = color)

@Composable
fun GlowRing(
    fraction: Float,
    value: Double,
    color: Color,
    diameter: Dp,
    lineWidth: Dp,
    modifier: Modifier = Modifier,
    showsLabel: Boolean = true,
    format: (Double) -> String = { it.toInt().toString() },
) {
    val target = fraction.coerceIn(0f, 1f)
    var started by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { started = true }
    val animFraction by animateFloatAsState(
        targetValue = if (started) target else 0f,
        animationSpec = spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow),
        label = uiString(R.string.l10n_components_glowring_fraction_5bcc7cd7),
    )
    val animValue by animateFloatAsState(
        targetValue = if (started) value.toFloat() else 0f,
        animationSpec = tween(durationMillis = 850, easing = FastOutSlowInEasing),
        label = uiString(R.string.l10n_components_glowring_value_ac0e87de),
    )
    val trackColor = Palette.textPrimary.copy(alpha = 0.10f)
    Box(modifier = modifier.size(diameter), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                // PERF (#scroll-jank): the full-circle TRACK is static (it reads no animation state), but
                // it shared one Canvas draw lambda with the fraction-driven arcs, so it was re-issued on
                // every animation/scroll frame. Hoist the track into drawWithCache — keyed on the implicit
                // size + the stroke + the track tone — so it rasterises ONCE and replays; only the glow +
                // crisp arc re-draw per frame (the drawBehind below). Pixel-identical: same circle geometry,
                // same round cap, same track-under-arc order.
                .drawWithCache {
                    val stroke = lineWidth.toPx()
                    val inset = stroke / 2f
                    val d = minOf(size.width, size.height)
                    val arcSize = Size(d - stroke, d - stroke)
                    val tl = Offset((size.width - d) / 2f + inset, (size.height - d) / 2f + inset)
                    val trackStroke = Stroke(width = stroke, cap = StrokeCap.Round)
                    onDrawBehind {
                        // Full-circle track so the arc reads as a fraction of a circle (like WHOOP).
                        drawArc(
                            color = trackColor, startAngle = 0f, sweepAngle = 360f, useCenter = false,
                            topLeft = tl, size = arcSize, style = trackStroke,
                        )
                    }
                }
                .drawBehind {
                    val stroke = lineWidth.toPx()
                    val inset = stroke / 2f
                    // Always draw a CIRCLE: size the arc off the smaller box dimension and centre it, so a
                    // non-square box (e.g. a hero ring the Row squeezes horizontally) never renders an ellipse.
                    val d = minOf(size.width, size.height)
                    val arcSize = Size(d - stroke, d - stroke)
                    val tl = Offset((size.width - d) / 2f + inset, (size.height - d) / 2f + inset)
                    val sweep = animFraction.coerceIn(0f, 1f) * 360f
                    // Only draw the arc (+ its glow) when there's ACTUAL progress. A near-zero round-capped
                    // arc renders as a full visible dot at 12 o'clock on Android's Canvas (unlike iOS's
                    // sub-pixel `trim`), which read as the unwanted "dot" on empty / No-Data / Calibrating
                    // rings the maintainer flagged. Below the threshold we show just the clean full-circle
                    // track — exactly like the iOS GlowRing's empty state.
                    if (animFraction > 0.001f) {
                        // Tight glow — a wider, low-alpha arc under the crisp one (minSdk-safe, no RenderEffect).
                        // Gated on the dark canvas only, mirroring iOS AdditiveBloom hiding on the light field
                        // (on white it just smears the edge); the crisp arc carries the ring on its own there.
                        if (!Palette.isLight) {
                            drawArc(
                                color = color.copy(alpha = 0.45f), startAngle = -90f, sweepAngle = sweep, useCenter = false,
                                topLeft = tl, size = arcSize, style = Stroke(width = stroke * 1.5f, cap = StrokeCap.Round),
                            )
                        }
                        // The crisp, solid arc — from 12 o'clock clockwise.
                        drawArc(
                            color = color, startAngle = -90f, sweepAngle = sweep, useCenter = false,
                            topLeft = tl, size = arcSize, style = Stroke(width = stroke, cap = StrokeCap.Round),
                        )
                    }
                },
        )
        if (showsLabel) {
            Text(
                text = format(animValue.toDouble()),
                style = glowRingCenterTextStyle(diameter),
                maxLines = 1,
            )
        }
    }
}

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
        // Brand-glyph geometry: open ~80% ring (288° of 360°), 12-o'clock start, clockwise,
        // plus the solid gold core dot + micro NOOP wordmark that mark the recovery hero.
        startDeg = -90f,
        spanDeg = 288f,
        coreDot = Palette.gold,
        wordmark = "NOOP",
        modifier = modifier,
    )
}

// MARK: - StrainGauge (NEW) — the Effort hero gauge
//
// The Effort sibling of RecoveryRing: a [BevelGauge] over the amber strain ramp. The arc fills to
// strain/outOf, with an "of N" caption naming the scale max. `outOf` is the maximum of the scale the
// passed [strain] is ON (default 21, WHOOP's Day-Strain axis). The Effort hero passes the value already
// converted to the user's selected display scale (#313) plus its matching max (100 or 21) and an optional
// [valueText] override for the centre numeral, so the arc, number and caption all read on one scale rather
// than being hardcoded to 0–21. Stays scale-agnostic — the caller owns the conversion (EffortScale is an
// app concern). Mirrors StrandDesign's StrainGauge so the hero row reads as three matched instruments
// (Charge gold · Effort amber · Rest blue).

@Composable
fun StrainGauge(
    strain: Double,
    modifier: Modifier = Modifier,
    outOf: Double = 21.0,
    valueText: String? = null,
    diameter: Dp = 240.dp,
    lineWidth: Dp = 16.dp,
    showsLabel: Boolean = true,
) {
    val clamped = strain.coerceIn(0.0, outOf)
    val fraction = if (outOf > 0) clamped / outOf else 0.0
    BevelGauge(
        fraction = fraction,
        stops = Palette.strainStops,
        // Tip tint sampled by the fill FRACTION so it spans the full ember→amber ramp identically on the
        // 0–100 and 0–21 display scales (a maxed gauge reaches the bright-amber peak, not a stuck ember).
        tipColor = Palette.effortTint(fraction),
        numberText = valueText
            ?: if (clamped % 1.0 == 0.0) clamped.toInt().toString() else String.format(java.util.Locale.US, "%.1f", clamped),
        captionText = "of ${outOf.toInt()}",
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
                        colors = listOf(domain.glow.copy(alpha = 0.06f), Color.Transparent),
                        center = Offset(w * 0.5f, h * 0.30f),
                        radius = maxOf(w, h) * 0.6f,
                    ),
                )
            }

            // Deterministic starfield — fixed positions/sizes so it can't flicker. A night-sky field
            // only belongs on the dark hero; on the warm-paper light field it reads as dirt, so it's
            // suppressed there (the radial + domain bloom carry the light hero alone).
            if (!Palette.isLight) {
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
    title: String?,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
    // Top inset above the content. Defaults to the standard 28dp screen padding; a screen that
    // supplies its own compact header (Today, title = null) can pass a smaller value to tighten the
    // gap above its first element — Compose forbids negative padding, so this is how iOS's
    // `.padding(top: -16)` tightening is expressed.
    topPadding: Dp = 28.dp,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    // Optional full-bleed view drawn behind the scroll content at the TOP of the screen (e.g. Today's
    // day-cycle scene). Defaults to null so other screens stay on the flat canvas; null draws nothing.
    // Mirrors the iOS ScreenScaffold `topBackground` slot — the scene is a SCREEN-level backdrop the
    // cards float OVER, not a card-clipped hero atmosphere.
    topBackground: (@Composable () -> Unit)? = null,
    // When true, the [topBackground] fills the WHOLE viewport instead of the top band — the
    // "sky behind cards" mode, identical to [LazyScreenScaffold]'s flag. The band container's
    // status-bar offset would otherwise shift a full-height backdrop up and leave the bottom of
    // the screen on plain canvas (the "sky doesn't reach the lower cards" report on the vital
    // details). Defaulted, so every existing caller is byte-for-byte untouched.
    fullBleedBackground: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    // The scrolling content column. Its OUTER modifier differs by path: with no topBackground it is the
    // original root Column (the caller's `modifier` + an opaque-canvas background — byte-for-byte the old
    // layout); with a topBackground the canvas + scene paint in the wrapping Box's background (below) and
    // the column stays TRANSPARENT so the scene shows through behind the scroll content. Pulled out so the
    // two paths share one body.
    val columnModifier: Modifier =
        if (topBackground == null) {
            modifier.fillMaxWidth().background(Palette.surfaceBase)
        } else {
            Modifier.fillMaxWidth()
        }
    val column: @Composable () -> Unit = {
        Column(
            modifier = columnModifier
                .verticalScroll(rememberScrollState())
                .padding(start = 28.dp, end = 28.dp, top = topPadding, bottom = 28.dp),
            // #765: one shared inter-card spacing token (was a bare `20.dp`), so the eager + lazy scaffolds
            // and every screen through them keep the SAME uniform gap between top-level cards.
            verticalArrangement = Arrangement.spacedBy(Metrics.screenRowSpacing),
        ) {
            // Compact top bar: an optional LEADING action (e.g. the Today profile avatar, mirroring iOS's
            // avatar-leading header), the screen title/subtitle, then an optional trailing action (e.g. the
            // Support heart on Today). Mirrors the iOS ScreenScaffold slots from the WHOOP redesign (#23).
            // When BOTH title and subtitle are null the large-title header block is omitted entirely, so a
            // screen can supply its own custom header in `content` (iOS Today's compact top bar) — mirroring
            // the iOS ScreenScaffold which only renders the header `if title != nil || subtitle != nil`.
            if (title != null || subtitle != null) {
                Row(verticalAlignment = Alignment.Top) {
                    if (leading != null) {
                        leading()
                        Spacer(Modifier.width(12.dp))
                    }
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        if (title != null) {
                            Text(title, style = NoopType.title1, color = Palette.textPrimary)
                        }
                        if (subtitle != null) {
                            Text(subtitle, style = NoopType.subhead, color = Palette.textSecondary)
                        }
                    }
                    if (trailing != null) trailing()
                }
            }
            content()
        }
    }

    if (topBackground == null) {
        // Unchanged path: the column IS the root, with the caller's `modifier` + opaque canvas background
        // applied to it directly — byte-for-byte the previous layout (no wrapping Box).
        column()
    } else {
        // Scene-backed path (Today): the wrapping Box paints the flat canvas, then the SCREEN-level scene
        // backdrop over it, anchored to the TOP and bled UP behind the status bar so it reads as a
        // full-bleed scenic header; the (transparent) scroll content floats OVER both. Mirrors the iOS
        // scaffold's `.background(alignment: .top){ ZStack { surfaceBase; topBackground }.ignoresSafeArea() }`.
        // Pull the scene up by the status-bar inset (the Scaffold already pushed this content below the
        // bar), so the scene bleeds behind the status bar rather than starting under it.
        val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        Box(modifier = modifier.fillMaxSize().background(Palette.surfaceBase)) {
            Box(
                modifier = (
                    if (fullBleedBackground) {
                        // Sky-behind-cards: the backdrop fills the whole viewport (no band offset), so
                        // the transparent content scrolls OVER a full-height sky. Identical to the lazy
                        // twin's fullBleedBackground container.
                        Modifier.fillMaxSize()
                    } else {
                        Modifier
                            .fillMaxWidth()
                            .align(Alignment.TopCenter)
                            .offset(y = -statusBarTop)
                    }
                    )
                    // PERF (#scroll-jank): promote the static scene backdrop to its OWN compositing layer so
                    // its gradient + bitmap rasterise ONCE into a render node and are reused as a texture on
                    // every scroll frame, instead of the parent re-issuing the scene's `drawBehind` draw each
                    // time the (sibling) scroll column composites over it. The backdrop reads no scroll state
                    // and never moves, so an empty `graphicsLayer {}` is purely an isolation hint —
                    // appearance-identical. Mirrors keeping the iOS scene as a static screen-level backdrop.
                    .graphicsLayer { },
            ) {
                topBackground()
            }
            column()
        }
    }
}

// MARK: - LazyScreenScaffold
//
// A lazy twin of [ScreenScaffold] for screens whose content ends in a long list. The
// eager [ScreenScaffold] above builds every child up-front; with an 800+ day imported
// history that froze the app (and tripped Android's "close unresponsive app?" prompt)
// when Intelligence "ALL" was tapped (#345). LazyColumn builds only the rows on screen.
//
// The content slot is a [LazyListScope] (item { } / items(...)) rather than a ColumnScope,
// so callers stay explicit about what is a one-off header vs the lazily-built list — and
// every existing ScreenScaffold caller is untouched. The header, 28dp screen padding and
// the shared Metrics.screenRowSpacing inter-item gap match ScreenScaffold so the two read identically.

@Composable
fun LazyScreenScaffold(
    title: String?,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
    // Mirrors ScreenScaffold: a screen with a scene-backed header (Today-style) can tighten the gap
    // above its first row, and supply leading/trailing header actions + a screen-level scene backdrop.
    // All defaulted, so the existing flat callers (Intelligence) are byte-for-byte untouched.
    topPadding: Dp = 28.dp,
    // The inter-row vertical spacing between top-level items. Defaults to the shared `screenRowSpacing`
    // (20dp) so every existing caller is byte-for-byte untouched; the liquid Today passes a tighter value
    // to match the iOS Today's compact `VStack(spacing: 12)` section rhythm (the maintainer's "iOS is
    // tighter/slicker" note). Scoped per-scaffold so no other screen's rhythm shifts.
    rowSpacing: Dp = Metrics.screenRowSpacing,
    leading: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    // Optional full-bleed scene drawn behind the scroll content at the TOP of the screen — the SAME slot
    // contract as ScreenScaffold.topBackground. Null draws nothing (the flat-canvas path). When supplied,
    // the scene paints in the wrapping Box (promoted to its own compositing layer) and the LazyColumn is
    // transparent so the scene shows through behind the rows. Mirrors the iOS scaffold's topBackground.
    topBackground: (@Composable () -> Unit)? = null,
    // When true, the [topBackground] fills the WHOLE scaffold (viewport) instead of the top band — the
    // "sky behind cards" mode, so a full-height backdrop shows behind every scrolling row.
    fullBleedBackground: Boolean = false,
    // #today-layout: the list state, hoisted so a caller can read item positions / scroll programmatically
    // (Today's hold-to-drag section reorder needs layoutInfo + scrollBy). Defaulted, so every existing
    // caller is byte-for-byte untouched.
    listState: LazyListState = rememberLazyListState(),
    content: LazyListScope.() -> Unit,
) {
    // The header row: optional leading action, the title/subtitle, optional trailing action. Omitted
    // entirely when both title and subtitle are null (a screen supplying its own custom header). Matches
    // ScreenScaffold's header block so the eager + lazy scaffolds read identically.
    val header: (@Composable () -> Unit)? =
        if (title != null || subtitle != null || leading != null || trailing != null) {
            {
                Row(verticalAlignment = Alignment.Top) {
                    if (leading != null) {
                        leading()
                        Spacer(Modifier.width(12.dp))
                    }
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        if (title != null) {
                            Text(title, style = NoopType.title1, color = Palette.textPrimary)
                        }
                        if (subtitle != null) {
                            Text(subtitle, style = NoopType.subhead, color = Palette.textSecondary)
                        }
                    }
                    if (trailing != null) trailing()
                }
            }
        } else {
            null
        }

    // The lazy list itself. Its background + the contentPadding differ by path so the scene-backed list
    // is transparent (scene shows through) while keeping the SAME 28dp screen inset + shared row spacing as
    // the eager ScreenScaffold. The top inset honours [topPadding] (so a custom-header screen can tighten
    // the gap above the first row, exactly like ScreenScaffold's `padding(top = topPadding)`).
    val listModifier: Modifier =
        if (topBackground == null) {
            modifier.fillMaxWidth().background(Palette.surfaceBase)
        } else {
            Modifier.fillMaxWidth()
        }
    val list: @Composable () -> Unit = {
        LazyColumn(
            modifier = listModifier,
            state = listState,
            contentPadding = PaddingValues(start = 28.dp, top = topPadding, end = 28.dp, bottom = 28.dp),
            // #765: the shared inter-card spacing token by default (Today/Explore + the eager screens share
            // one uniform card rhythm); a caller may pass a tighter [rowSpacing] (the liquid Today does, for
            // the iOS-compact section rhythm).
            verticalArrangement = Arrangement.spacedBy(rowSpacing),
        ) {
            if (header != null) {
                item { header() }
            }
            content()
        }
    }

    if (topBackground == null) {
        list()
    } else {
        // Scene-backed path: the wrapping Box paints the flat canvas + the screen-level scene backdrop
        // (anchored TOP, bled up behind the status bar), and the transparent LazyColumn floats over both.
        // Identical scene treatment to ScreenScaffold — including promoting the static backdrop to its own
        // compositing layer (an empty graphicsLayer {}) so the scene rasterises once and replays as a
        // texture on every scroll frame instead of being re-issued under the scrolling rows.
        val statusBarTop = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
        Box(modifier = modifier.fillMaxSize().background(Palette.surfaceBase)) {
            Box(
                modifier = (
                    if (fullBleedBackground) {
                        // Sky-behind-cards: the backdrop fills the whole viewport (covers under the status
                        // bar already), so the transparent rows scroll OVER a full-height sky.
                        Modifier.fillMaxSize()
                    } else {
                        // Default: a top-anchored band bled up behind the status bar.
                        Modifier.fillMaxWidth().align(Alignment.TopCenter).offset(y = -statusBarTop)
                    }
                    ).graphicsLayer { },
            ) {
                topBackground()
            }
            list()
        }
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
        StepperButton(symbol = "−", onClick = onMinus, label = uiString(R.string.l10n_components_decrease_accessibility_df5f1511, accessibility))
        StepperButton(symbol = "+", onClick = onPlus, label = uiString(R.string.l10n_components_increase_accessibility_0949c0e9, accessibility))
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
