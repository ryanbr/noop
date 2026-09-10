package com.noop.ui

import kotlin.math.abs

/** The most transparent step. */
const val MIN_OPACITY_STEP = 1

/** Solid. */
const val MAX_OPACITY_STEP = 11

/**
 * The shipped 0.80, sitting at the exact CENTRE of the slider - five notches either side.
 *
 * Centred on purpose. The bar you already have is the reference point, so the useful question at the
 * slider is "more see-through than now, or less?", and that reads off a thumb that starts in the middle.
 * With the default at 6 of 8 it sat right of centre, which made "less transparent" look like a two-notch
 * afterthought next to a five-notch run the other way.
 */
const val DEFAULT_OPACITY_STEP = 6

/** Unscaled - the shipped bar. */
const val DEFAULT_SCALE = 1f

/** The offered sizes. A short fixed list, not a slider: these are the sizes worth having. */
val BOTTOM_BAR_SCALES: List<Float> = listOf(1f, 1.25f, 1.5f, 1.75f, 2f)

/**
 * The bar's glass alpha for an opacity step: 0.30 at step 1, the shipped 0.80 at the centre step 6, and
 * 1.00 at step 11.
 *
 * The two halves move at DIFFERENT rates, which is deliberate and is the only way to get all three of
 * the things being asked for at once. Centring 0.80 with an even rate would mean either giving up the
 * faint end (a symmetric range around 0.80 bottoms out at 0.60, less see-through than this already
 * offers) or pushing the solid end past 1.00, which does not exist. So the transparent half spends 0.10
 * a notch across a wide range, and the solid half spends 0.04 across a narrow one.
 *
 * A user does not perceive that asymmetry as unevenness. The thumb starts centred, five notches each
 * way, and each notch is a visible change in the direction they moved it - which is the whole contract.
 *
 * The floor is 0.30 rather than 0: a fully invisible bar would still take taps, so a user could hide the
 * navigation and then not find it again. 0.30 is faint enough to read as "nearly gone" while leaving the
 * capsule's rim visible.
 */
fun alphaForOpacityStep(step: Int): Float {
    val clamped = step.coerceIn(MIN_OPACITY_STEP, MAX_OPACITY_STEP)
    return if (clamped <= DEFAULT_OPACITY_STEP) {
        // 0.30 -> 0.80 across steps 1..6
        0.30f + (clamped - MIN_OPACITY_STEP) * 0.10f
    } else {
        // 0.80 -> 1.00 across steps 6..11
        0.80f + (clamped - DEFAULT_OPACITY_STEP) * 0.04f
    }
}

/**
 * The nearest offered scale to [value].
 *
 * Snaps rather than clamps so a stored value from a build with a DIFFERENT set of sizes - or a
 * hand-edited pref - lands on something offerable instead of a size the dropdown cannot show or leave.
 */
fun nearestScale(value: Float): Float =
    BOTTOM_BAR_SCALES.minByOrNull { abs(it - value) } ?: DEFAULT_SCALE

/** The dropdown's label for a scale, e.g. "1.25x". Not translated - it is a number and a multiplier. */
fun scaleLabel(value: Float): String =
    if (value == value.toInt().toFloat()) "${value.toInt()}x" else "${value}x"
