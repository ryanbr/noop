package com.noop.ui

import com.noop.R
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.Color
import android.view.HapticFeedbackConstants
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// MARK: - LiquidPrimitives (the liquid VIEW WRAPPERS + shared components)
//
// Compose port of the "// MARK: - Views" and "// MARK: - Shared liquid components" sections of
// Strand/Liquid/LiquidPrimitives.swift. The three signature @Composables — the circular vessel
// gauge, the horizontal tube, and the live heart-rate thread — each own a LiquidSim, step it from a
// per-frame clock, read the one shared tilt source (LiquidMotion), and hand off the actual pixels to
// the LiquidRender.* draw routines (LiquidRender.kt) drawn onto a Compose Canvas DrawScope.
//
// This is a 1:1 behavioural port of the SwiftUI wrappers:
//   • animated && !reduce-motion  → a per-frame `withFrameNanos` clock advances the sim + redraws
//                                    live; LiquidMotion is acquired on enter / released on leave;
//                                    a tap splashes + fires a light haptic.
//   • otherwise (static / reduce)  → the primitive draws ONCE with a POSED sim, no clock, no motion.
// The physics (LiquidSim / LiquidMotion / liquidSeconds) live in LiquidSim.kt in this same package;
// the renderers (LiquidRender.vessel / .tube / .thread) live in LiquidRender.kt. Reduce-motion is the
// app's existing `rememberReduceMotion()` (NoopMotion.kt — reads Settings.Global.ANIMATOR_DURATION_SCALE).
//
// iOS drove the clock from a TimelineView.animation Date via liquidSeconds(date); here — exactly as
// LiquidSky.kt already does — a from-zero `withFrameNanos` accumulator gives the same motion because
// only the sinusoid PHASE of `now` matters to the sim.step / render (the absolute epoch is irrelevant).

// MARK: - The heart-rate pink (LiquidThread's default tint)
//
// The mockup's #ff6b81 — the iOS LiquidThread default `Color(.sRGB, red: 1, green: 107/255, blue: 129/255)`.
// A fixed brand literal (NOT a theme token) on iOS, so it ports as-is: the HR thread reads the same coral
// pink on every platform and both schemes, matching LiquidThread's iOS default exactly.
val liquidHeartPink: Color = Color(red = 1f, green = 107f / 255f, blue = 129f / 255f, alpha = 1f)

// MARK: - LiquidVessel — a circular liquid gauge

/**
 * A circular liquid gauge. [value] is 0..1 (null = empty / no-data). Square (aspectRatio 1:1).
 *
 * When [animated] and Reduce Motion is off it runs a live 60fps-class `withFrameNanos` clock: each frame
 * it steps a remembered [LiquidSim] against the shared [LiquidMotion] tilt and the latest [value], then
 * draws via `LiquidRender.vessel`. LiquidMotion is acquired while on screen (ref-counted) and released on
 * leave. A tap splashes the liquid (`sim.splash(12)`) and fires a light haptic. Otherwise it poses ONCE
 * with `LiquidSim.posed(value)` — no clock, no motion — so the many small gauges cost nothing per frame.
 *
 * Mirrors the iOS `LiquidVessel` view.
 */
@Composable
fun LiquidVessel(
    value: Double?,
    tint: Color,
    animated: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val renderStill = rememberPoseStill()

    if (animated && !renderStill) {
        val view = LocalView.current
        // The mutable physics, remembered across recompositions so the slosh is continuous. Seeded at the
        // fill line (iOS `LiquidSim(target: value ?? 0)`); the target is re-supplied every frame in step().
        val sim = remember { LiquidSim(target = value ?: 0.0) }

        // One shared tilt source per visible liquid screen — acquire on enter, release on leave (iOS
        // .onAppear/.onDisappear). Keyed on the context so it re-runs if the composition's context changes.
        val context = LocalContext.current
        DisposableEffect(context) {
            LiquidMotion.shared.acquire(context)
            onDispose { LiquidMotion.shared.release() }
        }

        // Monotonic seconds clock (from-zero accumulator; only the sinusoid phase matters — same as
        // LiquidSky.kt). Drives sim.step + render.
        var seconds by remember { mutableDoubleStateOf(0.0) }
        LaunchedEffect(Unit) {
            var last = 0L
            while (true) {
                withFrameNanos { frame ->
                    if (last != 0L) seconds += (frame - last) / 1_000_000_000.0
                    last = frame
                }
            }
        }

        Canvas(
            modifier = modifier
                .aspectRatio(1f)
                .clickable(
                    indication = null,
                    interactionSource = remember { MutableInteractionSource() },
                ) {
                    sim.splash(12)
                    // A LIGHT tap impact, matching iOS `.sensoryFeedback(.impact(weight: .light))`. Compose's
                    // HapticFeedbackType on this BOM only offers LongPress (heavy) / TextHandleMove, so route a
                    // light KEYBOARD_TAP through the platform view — the closest available light-impact tick.
                    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                },
        ) {
            sim.step(now = seconds, tilt = LiquidMotion.shared.tilt, target = value ?: 0.0)
            with(LiquidRender) { vessel(size = size, sim = sim, now = seconds, tint = tint) }
        }
    } else {
        // One-shot, cached render — posed at the fill line, no clock, no motion acquire.
        val posed = remember(value) { LiquidSim.posed(value ?: 0.0) }
        Canvas(modifier = modifier.aspectRatio(1f)) {
            with(LiquidRender) { vessel(size = size, sim = posed, now = 0.0, tint = tint) }
        }
    }
}

// MARK: - LiquidTube — a horizontal liquid tube

/**
 * A horizontal liquid tube filled to [frac] (0..1). Fixed [height] (default 14dp).
 *
 * When [animated] and Reduce Motion is off it runs a live `withFrameNanos` clock: each frame it steps a
 * remembered [LiquidSim] against the shared [LiquidMotion] tilt and [frac], then draws via
 * `LiquidRender.tube`; LiquidMotion is acquired on enter / released on leave. Otherwise it poses ONCE
 * with `LiquidSim.posed(frac)` — no clock, no motion — so the grid tubes / workout bars cost nothing per
 * frame. `frac` is clamped to 0..1 at the draw call, matching iOS.
 *
 * Mirrors the iOS `LiquidTube` view.
 */
@Composable
fun LiquidTube(
    frac: Double,
    tint: Color,
    height: Dp = 14.dp,
    animated: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val renderStill = rememberPoseStill()
    val clamped = frac.coerceIn(0.0, 1.0)

    if (animated && !renderStill) {
        // iOS seeds the tube sim at target 0 (`LiquidSim(target: 0)`) and lets step() chase `frac`.
        val sim = remember { LiquidSim(target = 0.0) }

        val context = LocalContext.current
        DisposableEffect(context) {
            LiquidMotion.shared.acquire(context)
            onDispose { LiquidMotion.shared.release() }
        }

        var seconds by remember { mutableDoubleStateOf(0.0) }
        LaunchedEffect(Unit) {
            var last = 0L
            while (true) {
                withFrameNanos { frame ->
                    if (last != 0L) seconds += (frame - last) / 1_000_000_000.0
                    last = frame
                }
            }
        }

        Canvas(modifier = modifier.height(height)) {
            sim.step(now = seconds, tilt = LiquidMotion.shared.tilt, target = frac)
            with(LiquidRender) { tube(size = size, sim = sim, now = seconds, frac = clamped, tint = tint) }
        }
    } else {
        val posed = remember(frac) { LiquidSim.posed(frac) }
        Canvas(modifier = modifier.height(height)) {
            with(LiquidRender) { tube(size = size, sim = posed, now = 0.0, frac = clamped, tint = tint) }
        }
    }
}

// MARK: - LiquidThread — the live heart-rate thread

/**
 * The live heart-rate thread. [bpm] is the recent series (any length ≥ 2; below that the renderer no-ops).
 * Fixed [height] (default 96dp). [tint] defaults to the liquid heart pink ([liquidHeartPink] = #ff6b81),
 * matching the iOS default.
 *
 * When [animated] and Reduce Motion is off it runs a live `withFrameNanos` clock so the travelling glint +
 * endpoint pulse flow (`LiquidRender.thread` reads `now` for the dash phase + pulse). The thread carries NO
 * LiquidSim and no tilt — it is a pure function of `bpm` + `now` — so there is nothing to acquire/release.
 * Otherwise it draws ONCE (no glint / pulse) — the static form used until the first data load settles.
 *
 * Mirrors the iOS `LiquidThread` view.
 */
@Composable
fun LiquidThread(
    bpm: List<Double>,
    tint: Color = liquidHeartPink,
    height: Dp = 96.dp,
    animated: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val renderStill = rememberPoseStill()

    if (animated && !renderStill) {
        var seconds by remember { mutableDoubleStateOf(0.0) }
        LaunchedEffect(Unit) {
            var last = 0L
            while (true) {
                withFrameNanos { frame ->
                    if (last != 0L) seconds += (frame - last) / 1_000_000_000.0
                    last = frame
                }
            }
        }
        Canvas(modifier = modifier.height(height)) {
            with(LiquidRender) { thread(size = size, values = bpm, now = seconds, tint = tint) }
        }
    } else {
        // One-shot render (no travelling glint / pulse) — `now = 0`.
        Canvas(modifier = modifier.height(height)) {
            with(LiquidRender) { thread(size = size, values = bpm, now = 0.0, tint = tint) }
        }
    }
}

// MARK: - Shared liquid components (cross-platform: used by the Today AND the other liquid screens)

// MARK: - liquidPress — the tappable-liquid-card press response
//
// The Compose equivalent of the iOS `LiquidPressStyle` ButtonStyle. Compose has no ButtonStyle, so the
// idiomatic form is an InteractionSource-driven Modifier: a card wires its own `clickable`
// interactionSource into `Modifier.liquidPress(interactionSource)`, and while pressed it settles inward to
// 0.975 scale + dims to 0.86 alpha over a 160ms easeOut — cheap (a graphicsLayer transform), so it's free
// on static cards and makes every tap feel physical. Same numbers as the iOS style
// (scaleEffect 0.975 / opacity 0.86 / .easeOut(duration: 0.16)).

/**
 * Apply the "this liquid card was pressed" response, driven by the caller's [interactionSource]. Pass the
 * SAME `interactionSource` you gave the element's `clickable`, e.g.:
 *
 * ```
 * val interaction = remember { MutableInteractionSource() }
 * NoopCard(
 *     modifier = Modifier
 *         .clickable(interactionSource = interaction, indication = null) { onTap() }
 *         .liquidPress(interaction),
 * ) { ... }
 * ```
 *
 * While pressed the content settles to 0.975 scale + 0.86 alpha over a 160ms easeOut; on release it springs
 * back. Cheap (a `graphicsLayer` scale/alpha), so it's free on otherwise-static cards. Mirrors the iOS
 * `LiquidPressStyle` ButtonStyle. Honours Reduce Motion (snaps to the pressed/idle state with no easing).
 */
fun Modifier.liquidPress(interactionSource: InteractionSource): Modifier = composed {
    val reduced = rememberReduceMotion()
    val pressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) 0.975f else 1f,
        animationSpec = if (reduced) tween(0) else tween(durationMillis = 160, easing = Motion.easeOut),
        label = uiString(R.string.l10n_liquid_primitives_liquidpressscale_7520ddb3),
    )
    val alpha by animateFloatAsState(
        targetValue = if (pressed) 0.86f else 1f,
        animationSpec = if (reduced) tween(0) else tween(durationMillis = 160, easing = Motion.easeOut),
        label = uiString(R.string.l10n_liquid_primitives_liquidpressalpha_2c4048a8),
    )
    this.graphicsLayer {
        scaleX = scale
        scaleY = scale
        this.alpha = alpha
    }
}

// MARK: - CountUpNumber — a bare numeric count-up (wraps the app's CountUpText)
//
// The iOS `CountUpNumber` is a tiny Animatable value that rolls an integer to its target inside a
// `withAnimation` block. The Android app ALREADY has `CountUpText` (NoopMotion.kt) — the same count-up
// behaviour, Reduce-Motion-aware — so this is a thin wrapper over it (NOT a re-implementation), formatting
// the rolled value as a plain rounded integer with monospaced/tabular figures. Reach for `CountUpText`
// directly when you need a custom format/units; use this only when a bare integer count-up is wanted.

/**
 * A bare integer count-up — the shown number rolls smoothly to [value] whenever it changes (and on first
 * appear). A thin wrapper over the app's [CountUpText] (NoopMotion.kt); it does NOT duplicate the count-up
 * logic. Renders the rounded integer in [style] / [color] (defaults to `NoopType.number(26f)`, tabular, and
 * `Palette.textPrimary`), matching the iOS `CountUpNumber(value:font:)` monospaced-digit numeral. Honours
 * Reduce Motion (via CountUpText).
 */
@Composable
fun CountUpNumber(
    value: Double,
    modifier: Modifier = Modifier,
    style: TextStyle = NoopType.number(26f),
    color: Color = Palette.textPrimary,
) {
    CountUpText(
        value = value,
        format = { "${Math.round(it)}" },
        style = style,
        color = color,
        modifier = modifier,
    )
}
