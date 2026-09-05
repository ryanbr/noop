package com.noop.ui

import kotlin.math.abs

/** The most transparent step. */
const val MIN_OPACITY_STEP = 1

/** Solid. */
const val MAX_OPACITY_STEP = 8

/**
 * The step whose alpha is the SHIPPED 0.80, so an install that never opens this setting renders exactly
 * as it did before. Chosen by arithmetic rather than taste: the linear 0.30..1.00 mapping puts 0.80 on
 * step 6 precisely, which is why the range starts at 0.30 rather than a rounder number.
 */
const val DEFAULT_OPACITY_STEP = 6

/** Unscaled - the shipped bar. */
const val DEFAULT_SCALE = 1f

/** The offered sizes. A short fixed list, not a slider: these are the sizes worth having. */
val BOTTOM_BAR_SCALES: List<Float> = listOf(1f, 1.25f, 1.5f, 1.75f, 2f)

/**
 * The bar's glass alpha for an opacity step, linear from 0.30 (step 1) to 1.00 (step 8).
 *
 * The floor is 0.30 rather than 0: a fully invisible bar would still take taps, so a user could hide the
 * navigation and then not find it again. 0.30 is faint enough to read as "nearly gone" while leaving the
 * capsule's rim visible.
 */
fun alphaForOpacityStep(step: Int): Float {
    val clamped = step.coerceIn(MIN_OPACITY_STEP, MAX_OPACITY_STEP)
    return 0.30f + (clamped - MIN_OPACITY_STEP) * 0.10f
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
