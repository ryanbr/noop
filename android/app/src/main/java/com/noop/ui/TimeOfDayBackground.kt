package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.semantics.clearAndSetSemantics
import java.util.Calendar
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// MARK: - Time-of-Day Atmosphere (NOOP identity backdrop)
//
// Compose port of StrandDesign/TimeOfDayBackground.swift. A *whisper* behind content — never
// decoration, never a gaudy starfield. Apple-Weather restraint dialled WAY down: every atmosphere
// layer sits at alpha <= 0.16, painted OVER the WHOOP `surfaceBase` canvas so screens stay dark,
// flat and clean.
//
// HARD RULES honoured (standing):
//  - NO GLOW. No bloom, no blur halos, no neon. The sun/moon are plain filled circles at very low
//    opacity; stars are tiny crisp dots.
//  - TOKENS first (`Palette`). The only literal colours are the few subtle atmosphere tints the
//    spec calls for (warm peach lift, indigo wash, etc.) — kept deliberately faint.
//  - Reduce Motion pins every drifting element still (no looping translation).
//  - CPU-light: drift runs off ONE infinite transition phase; pinned to 0 under Reduce Motion.

// MARK: - Day part

/** The four atmospheric parts of the day. [current] derives one from the clock. */
enum class DayPart {
    Dawn, Day, Dusk, Night;

    companion object {
        /** Map an hour (0…23) to its day part: dawn 5–8, day 8–17, dusk 17–20, night 20–5. */
        fun current(hour: Int): DayPart {
            val h = ((hour % 24) + 24) % 24
            return when (h) {
                in 5 until 8 -> Dawn
                in 8 until 17 -> Day
                in 17 until 20 -> Dusk
                else -> Night
            }
        }

        /** The day part for *now*, from the system clock. */
        fun current(): DayPart =
            current(Calendar.getInstance().get(Calendar.HOUR_OF_DAY))
    }
}

// MARK: - Time-of-day background

/**
 * A full-bleed, very subtle atmosphere layer tuned per [dayPart], painted over the `surfaceBase`
 * canvas. Drop it behind any screen via `Modifier.timeOfDayBackground()`, or place this composable
 * directly in a Box behind content. Mirrors iOS `TimeOfDayBackground`.
 *
 * @param dayPart which part of the day to render.
 * @param animated whether drifting elements move (auto-disabled under Reduce Motion).
 */
@Composable
fun TimeOfDayBackground(
    dayPart: DayPart,
    modifier: Modifier = Modifier,
    animated: Boolean = true,
) {
    val phase = atmospherePhase(animated)
    val isLight = Palette.isLight
    val starColor = Palette.scenicStar
    val nightDeepen = if (isLight) Color(0x00000000) else Color(0xFF0D1014)

    // PERF (#scroll-jank): replaces the single phase-reading Canvas with a cached static wash + a thin
    // phase-reading drift layer (same split as the modifier form). Appearance-identical — same draw order.
    Box(
        modifier = modifier
            .fillMaxSize()
            .clearAndSetSemantics {} // decorative — invisible to TalkBack
            .drawWithCache {
                onDrawBehind {
                    drawAtmosphereStatic(dayPart, isLight, starColor, nightDeepen)
                }
            }
            .drawBehind {
                drawAtmosphereDrift(dayPart, isLight, phase)
            },
    )
}

/**
 * Place a subtle [TimeOfDayBackground] behind this content. Defaults to the current clock-derived
 * part with drift on (drift auto-disables under Reduce Motion). Mirrors iOS
 * `.timeOfDayBackground(_:animated:)`.
 *
 * ```
 * SomeScreen().timeOfDayBackground()           // auto, animated
 * SomeScreen().timeOfDayBackground(DayPart.Night)
 * ```
 */
@Composable
fun Modifier.timeOfDayBackground(
    dayPart: DayPart = DayPart.current(),
    animated: Boolean = true,
): Modifier {
    val phase = atmospherePhase(animated)
    val isLight = Palette.isLight
    val starColor = Palette.scenicStar
    val nightDeepen = if (isLight) Color(0x00000000) else Color(0xFF0D1014)
    return this
        // Static wash (deepen + gradients + sun/moon/stars) cached once — keyed on the implicit size +
        // the day part + scheme + star tone, NOT the drift phase, so the animation never re-rasterises it.
        .drawWithCache {
            onDrawBehind {
                drawAtmosphereStatic(dayPart, isLight, starColor, nightDeepen)
            }
        }
        // The drifting floaters over it — the only phase-reading draw.
        .drawBehind {
            drawAtmosphereDrift(dayPart, isLight, phase)
        }
}

/** The single 0…1 drift phase driving every floating shape. Pinned to 0 when not animated or under
 *  Reduce Motion, so the whole layer is static. One slow loop (~80s) so the system has near-zero work. */
@Composable
private fun atmospherePhase(animated: Boolean): Float {
    val renderStill = rememberPoseStill()
    if (!animated || renderStill) return 0f
    val transition = rememberInfiniteTransition(label = "atmosphere")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 80_000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = uiString(R.string.l10n_time_of_day_background_atmospherephase_5ce21300),
    )
    return phase
}

// MARK: - Drawing

// PERF (#scroll-jank): the atmosphere was ONE draw lambda reading the infinite drift [phase], so the
// WHOLE layer — the night-deepen rect, the per-part wash gradients AND the sun/moon/stars — was
// re-rasterised on every animation frame even though only the 2-3 floaters actually move. Split into a
// STATIC half (deepen + wash, phase-free → cached once via drawWithCache) and a phase-reading half (just
// the floaters). Pixel-identical: same draw order (deepen → wash → floaters), same shapes.

/** The STATIC atmosphere: base deepen → per-part wash (gradients + sun/moon/stars). Reads NO phase, so a
 *  drawWithCache layer holding this rasterises once and is never invalidated by the drift animation. */
private fun DrawScope.drawAtmosphereStatic(
    dayPart: DayPart,
    isLight: Boolean,
    starColor: Color,
    nightDeepen: Color,
) {
    val w = size.width
    val h = size.height

    // 1) Night sits a touch deeper than `surfaceBase` for depth (drawn by the screen behind us).
    if (dayPart == DayPart.Night && !isLight) {
        drawRect(color = nightDeepen.copy(alpha = 0.55f))
    }

    // 2) The per-part wash (gradients + sun/moon/stars). Static; cheap.
    when (dayPart) {
        DayPart.Dawn -> drawDawn(w, h, isLight)
        DayPart.Day -> drawDay(w, h, isLight)
        DayPart.Dusk -> drawDusk(w, h, isLight)
        DayPart.Night -> drawNight(w, h, isLight, starColor)
    }
}

/** The drifting layer: 2-3 slow soft shapes (clouds for day/dusk, orbs for night/dawn). Reads [phase] —
 *  this is the ONLY part that re-draws per animation frame; pinned at rest when phase == 0. */
private fun DrawScope.drawAtmosphereDrift(dayPart: DayPart, isLight: Boolean, phase: Float) {
    floatersFor(dayPart).forEach { drawFloater(it, phase, isLight) }
}

// Light-mode ceiling: knock atmosphere back further so it reads as warm paper, not colour.
private fun cap(isLight: Boolean, dark: Float, light: Float): Float = if (isLight) light else dark

// MARK: Dawn — cool indigo up top, faint warm peach lift low-centre, soft low sun disc.
private fun DrawScope.drawDawn(w: Float, h: Float, isLight: Boolean) {
    drawRect(
        brush = Brush.verticalGradient(
            colors = listOf(
                pick(isLight, "#A9B2D6", "#3A4470").copy(alpha = cap(isLight, 0.14f, 0.06f)),
                Color.Transparent,
            ),
            startY = 0f, endY = h * 0.5f,
        ),
    )
    drawRect(
        brush = Brush.radialGradient(
            colors = listOf(
                pick(isLight, "#F3C9A4", "#E8A56A").copy(alpha = cap(isLight, 0.12f, 0.05f)),
                Color.Transparent,
            ),
            center = Offset(w * 0.5f, h * 1.02f),
            radius = max(w, h) * 0.75f,
        ),
    )
    // The sun: a plain filled disc, very low opacity, NO glow.
    val r = min(w, h) * 0.11f
    drawCircle(
        color = pick(isLight, "#F4C98E", "#F0B968").copy(alpha = cap(isLight, 0.10f, 0.05f)),
        radius = r,
        center = Offset(w * 0.32f, h * 0.84f),
    )
}

// MARK: Day — cleanest of the four: a barely-there cool top-light only.
@Suppress("UNUSED_PARAMETER") // `w` kept for signature symmetry with drawNight(w, h, isLight)
private fun DrawScope.drawDay(w: Float, h: Float, isLight: Boolean) {
    drawRect(
        brush = Brush.verticalGradient(
            colors = listOf(
                pick(isLight, "#BFD0E2", "#4C5E78").copy(alpha = cap(isLight, 0.08f, 0.04f)),
                Color.Transparent,
            ),
            startY = 0f, endY = h * 0.55f,
        ),
    )
}

// MARK: Dusk — cool violet wash up top, faint warm amber lift low.
private fun DrawScope.drawDusk(w: Float, h: Float, isLight: Boolean) {
    drawRect(
        brush = Brush.verticalGradient(
            colors = listOf(
                pick(isLight, "#B6A6CE", "#4A3E66").copy(alpha = cap(isLight, 0.14f, 0.06f)),
                Color.Transparent,
            ),
            startY = 0f, endY = h * 0.5f,
        ),
    )
    drawRect(
        brush = Brush.radialGradient(
            colors = listOf(
                pick(isLight, "#EBB084", "#E0913E").copy(alpha = cap(isLight, 0.13f, 0.05f)),
                Color.Transparent,
            ),
            center = Offset(w * 0.5f, h * 1.04f),
            radius = max(w, h) * 0.8f,
        ),
    )
}

// MARK: Night — a few tiny crisp stars + a faint crescent moon. Light mode hides the stars.
private fun DrawScope.drawNight(w: Float, h: Float, isLight: Boolean, starColor: Color) {
    drawRect(
        brush = Brush.verticalGradient(
            colors = listOf(
                pick(isLight, "#9FA8C8", "#2C3458").copy(alpha = cap(isLight, 0.10f, 0.05f)),
                Color.Transparent,
            ),
            startY = 0f, endY = h * 0.5f,
        ),
    )

    // <=7 deterministic tiny stars. Crisp dots, r <= 1, opacity 0.06–0.12. Light mode hides them.
    if (!isLight) {
        nightStars.forEach { s ->
            drawCircle(
                color = starColor.copy(alpha = s.o),
                radius = s.r,
                center = Offset(w * s.x, h * s.y),
            )
        }
    }

    // Crescent moon: a disc with an offset disc carved out (even-odd fill). Low opacity, no glow.
    val moonD = min(w, h) * 0.13f
    val cx = w * 0.78f
    val cy = h * 0.18f
    val moonRect = androidx.compose.ui.geometry.Rect(
        offset = Offset(cx - moonD / 2f, cy - moonD / 2f),
        size = Size(moonD, moonD),
    )
    val crescent = Path().apply {
        fillType = PathFillType.EvenOdd
        addOval(moonRect)
        val inset = moonD * 0.26f
        addOval(
            androidx.compose.ui.geometry.Rect(
                offset = Offset(moonRect.left + inset * 1.15f, moonRect.top - inset * 0.55f),
                size = Size(moonD, moonD),
            ),
        )
    }
    drawPath(
        path = crescent,
        color = pick(isLight, "#C9CEDC", "#C8CFD8").copy(alpha = cap(isLight, 0.12f, 0.05f)),
        style = Fill,
    )
}

/** Deterministic star field: fixed positions (0…1), tiny radius, restrained opacity. */
private data class Star(val x: Float, val y: Float, val r: Float, val o: Float)

private val nightStars = listOf(
    Star(0.14f, 0.12f, 0.9f, 0.10f),
    Star(0.27f, 0.30f, 0.7f, 0.07f),
    Star(0.46f, 0.09f, 1.0f, 0.12f),
    Star(0.61f, 0.24f, 0.8f, 0.09f),
    Star(0.83f, 0.34f, 0.7f, 0.06f),
    Star(0.36f, 0.46f, 0.8f, 0.08f),
    Star(0.90f, 0.10f, 0.9f, 0.11f),
)

// MARK: - Floating layer (2–3 huge, soft, low-opacity drifting shapes)

/** One drifting atmosphere shape. All values are fractions of the view size so it scales freely. */
private data class Floater(
    val isCloud: Boolean,  // cloud → wide ellipse; orb → round disc
    val tintLight: String,
    val tintDark: String,
    val baseX: Float,      // resting centre, fraction of width
    val baseY: Float,      // resting centre, fraction of height
    val scale: Float,      // diameter as a fraction of max(w,h) — huge by design
    val travel: Float,     // horizontal sweep amplitude, fraction of width
    val offset: Float,     // phase offset so shapes don't move in lockstep
    val opacity: Float,    // <= 0.06 — atmosphere, never a blob
)

/** A single soft drifting blob — a very large, very low-opacity rounded shape. */
private fun DrawScope.drawFloater(s: Floater, phase: Float, isLight: Boolean) {
    val w = size.width
    val h = size.height
    // Slow looping horizontal drift: a gentle sine eases it at the edges. phase pinned at 0 → at rest.
    val dx = sin((phase + s.offset) * 2f * PI.toFloat()) * w * s.travel
    val dim = max(w, h) * s.scale
    val cx = w * s.baseX + dx
    val cy = h * s.baseY
    val tint = pick(isLight, s.tintLight, s.tintDark)
    val alpha = s.opacity * if (isLight) 0.55f else 1f // even fainter in light mode
    // Dark: a faint additive lift off the near-black canvas (flat fill, never a halo). Light: plain
    // blending so pale tints don't blow out the warm-paper surface.
    val blend = if (isLight) BlendMode.SrcOver else BlendMode.Plus

    if (s.isCloud) {
        // Wide soft ellipse (height 0.62 of width).
        val rect = androidx.compose.ui.geometry.Rect(
            offset = Offset(cx - dim / 2f, cy - dim * 0.62f / 2f),
            size = Size(dim, dim * 0.62f),
        )
        val path = Path().apply { addOval(rect) }
        drawPath(path = path, color = tint.copy(alpha = alpha), blendMode = blend)
    } else {
        drawCircle(color = tint.copy(alpha = alpha), radius = dim / 2f, center = Offset(cx, cy), blendMode = blend)
    }
}

/** The 2–3 shapes for this part. Clouds suit day/dusk; orbs suit night/dawn. */
private fun floatersFor(dayPart: DayPart): List<Floater> = when (dayPart) {
    DayPart.Day -> listOf(
        Floater(true, "#C9D4E2", "#7C8AA8", 0.30f, 0.30f, 1.20f, 0.10f, 0.0f, 0.05f),
        Floater(true, "#C9D4E2", "#7C8AA8", 0.72f, 0.52f, 1.00f, 0.08f, 0.4f, 0.04f),
    )
    DayPart.Dusk -> listOf(
        Floater(true, "#D6BEA8", "#8A6E78", 0.40f, 0.70f, 1.35f, 0.09f, 0.1f, 0.06f),
        Floater(true, "#D6BEA8", "#8A6E78", 0.74f, 0.40f, 1.05f, 0.07f, 0.5f, 0.04f),
    )
    DayPart.Dawn -> listOf(
        Floater(false, "#E8C9A4", "#6E7AA0", 0.30f, 0.78f, 0.95f, 0.07f, 0.0f, 0.06f),
        Floater(true, "#E8C9A4", "#6E7AA0", 0.66f, 0.38f, 1.10f, 0.06f, 0.5f, 0.04f),
    )
    DayPart.Night -> listOf(
        Floater(false, "#B6C0D6", "#3E4A74", 0.28f, 0.62f, 1.05f, 0.06f, 0.0f, 0.05f),
        Floater(false, "#B6C0D6", "#3E4A74", 0.70f, 0.36f, 0.85f, 0.05f, 0.45f, 0.04f),
        Floater(false, "#B6C0D6", "#3E4A74", 0.52f, 0.86f, 0.70f, 0.05f, 0.8f, 0.03f),
    )
}

// MARK: - Hex helpers

/** Pick the light or dark hex per scheme, parse to a Color. Mirrors iOS `Color(light:dark:)`. */
private fun pick(isLight: Boolean, lightHex: String, darkHex: String): Color =
    hexColor(if (isLight) lightHex else darkHex)

/** Parse a "#RRGGBB" string to an opaque Color. */
private fun hexColor(hex: String): Color {
    val clean = hex.removePrefix("#")
    val r = clean.substring(0, 2).toInt(16)
    val g = clean.substring(2, 4).toInt(16)
    val b = clean.substring(4, 6).toInt(16)
    return Color(red = r, green = g, blue = b, alpha = 255)
}
