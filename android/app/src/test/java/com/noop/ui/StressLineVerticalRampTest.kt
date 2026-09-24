package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the daytime stress line to a VERTICAL colour ramp, the way its iOS counterpart draws it (#2431).
 *
 * The line used `Brush.horizontalGradient`, borrowed from the hero PipBar and the totals bar. Those are
 * horizontal BARS, where length carries the value, so a ramp along x is correct for them. This is a line
 * chart whose value sits on y, so along x the ramp coloured by time of day: a calm 9pm hour drew amber
 * and a tense 7am one drew blue, and the screen's own 0-1 LOW / 1-2 MEDIUM / 2-3 HIGH legend said the
 * opposite. Strand/Screens/StressView.swift moved to a vertical ramp in #2053; this side never followed.
 *
 * A Canvas draw has no JVM-testable surface, so the invariant is pinned against the source the way
 * `GlowRingFlatArcTest` pins GlowRing's. The horizontal-count assertion is what carries this: it fails on
 * any re-added x-axis ramp, not only on one spelled the way the removed one was.
 */
class StressLineVerticalRampTest {

    private fun daytimeStressLineSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ui/StressScreen.kt")
            if (f.isFile) {
                val body = f.readText()
                    .substringAfter("private fun DaytimeStressLine(", "")
                    .substringBefore("private fun daytimeLineDescription(", "")
                check(body.isNotBlank()) { "DaytimeStressLine body not found - the anchors moved, fix this test" }
                return body
            }
            root = root.parentFile ?: root
        }
        error("StressScreen.kt not found - this test must not pass by default")
    }

    /** Strip comments, so prose describing the removed horizontal ramp cannot fail or hide a real one. */
    private fun code(): String =
        daytimeStressLineSource().lineSequence()
            .map { it.substringBefore("//") }
            .joinToString("\n")

    @Test
    fun `the line ramp runs down the chart, never across the day`() {
        val code = code()
        assertEquals(
            "the daytime stress line must not ramp along the x-axis: that colours by time of day, not by level",
            0,
            Regex("horizontalGradient").findAll(code).count(),
        )
        assertTrue(
            "the daytime stress line must ramp vertically, so y position carries the 0-3 level",
            code.contains("Brush.verticalGradient"),
        )
    }

    @Test
    fun `the ramp spans the plot band, not the whole canvas`() {
        val code = code()
        // Left at the canvas default the ramp runs 0..height, so both ends sit a pad out from the level
        // they claim and the legend under the chart still is not literally true.
        assertTrue(
            "the vertical ramp must start at the plot top (topPad), matching yForC's level 3",
            code.contains("startY = topPad"),
        )
        assertTrue(
            "the vertical ramp must end at yForC's own level-0 bound (topPad + usable), not at h - botPad",
            code.contains("endY = topPad + usable"),
        )
    }

    @Test
    fun `amber sits at the top of the chart, blue at the bottom`() {
        val code = code()
        // yForC puts level 3 at topPad and level 0 at the bottom, and StressRamp runs calm-first
        // (0.0 CALM blue -> 1.0 TENSE amber), so the stops have to be reversed to put amber on top.
        // Without this the ramp is vertical but upside down, which is a worse lie than the horizontal
        // one: it looks deliberate.
        // Sliced to the stop-building block, which sits just above the brush. Deliberately NOT sliced
        // on `startY`: that would tie this test to the one above, so dropping the plot band would fail
        // both and point the blame at the wrong invariant.
        val stopBuilder = code.substringAfter("val levelStops", "")
            .substringBefore("val gradient", "")
        assertTrue(
            "StressRamp runs calm-first, so the stops must reverse for amber to land at the top",
            stopBuilder.contains("reversed()"),
        )
        // The fractions have to survive. Reduced to a bare colour list Compose spaces them EVENLY,
        // which tracks `StressRamp.color` only while the stops sit at 0/0.5/1: reweight them and the
        // lone-hour dot silently parts company with the line again, which is this defect's own shape.
        assertTrue(
            "the stop fractions must be mirrored (1f - at), not dropped for an evenly spaced colour list",
            stopBuilder.contains("1f - at"),
        )
    }
}
