package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [GlowRing] to a FLAT arc, the way its iOS twin draws it (#2407).
 *
 * The iOS `StrandDesign.GlowRing` dropped the additive bloom in the Design Reset ("NO glow. A flat,
 * crisp solid arc only"); this Compose twin, ported days earlier, kept a stand-in for the bloom and
 * never followed. Android has no RenderEffect blur at minSdk 26, so the stand-in was a HARD-edged arc
 * at 1.5x the stroke and alpha 0.45 under the crisp one: it spilled a quarter-stroke past the track on
 * both sides and a quarter past each round cap, which on the gold Charge hero read as a misaligned
 * double edge rather than a glow.
 *
 * A Canvas draw has no JVM-testable surface, so the invariant is pinned against the source the way
 * `StalledLinkDiagnosticsTest` pins the client's. The count assertion is what carries this: it fails on
 * any re-added halo pass, not just on one spelled the way the removed one was.
 */
class GlowRingFlatArcTest {

    private fun glowRingSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ui/Components.kt")
            if (f.isFile) {
                val src = f.readText()
                val body = src.substringAfter("fun GlowRing(", "")
                    .substringBefore("\n@Composable\nfun RecoveryRing(", "")
                check(body.isNotBlank()) { "GlowRing body not found — the anchors moved, fix this test" }
                return body
            }
            root = root.parentFile ?: root
        }
        error("Components.kt not found — this test must not pass by default")
    }

    /** Strip comments, so prose describing the removed bloom can't fail the test (or hide a real one). */
    private fun code(): String =
        glowRingSource().lineSequence()
            .map { it.substringBefore("//") }
            .joinToString("\n")

    /**
     * Three arcs, and only three: the full-circle track, the optional target-range band, and the crisp
     * value arc. A fourth is a halo coming back.
     */
    @Test
    fun `GlowRing draws exactly three arcs`() {
        assertEquals(
            "GlowRing must draw the track, the target band and the crisp value arc — nothing else",
            3,
            Regex("drawArc\\(").findAll(code()).count(),
        )
    }

    /** The bloom's fill: the domain colour faded. The track and target band use palette tones, never this. */
    @Test
    fun `GlowRing never fades the domain colour`() {
        assertFalse(
            "a faded copy of the arc colour is a bloom pass; iOS draws the arc at full opacity only",
            code().contains("color.copy(alpha"),
        )
    }

    /**
     * The bloom's width: WIDER than the ring stroke, which is how it spilled past the track. Narrower
     * multiples are legitimate (the target-range band rides its own inset track at 0.6 stroke), so the
     * bar is 1.0, not "no multiplier at all".
     */
    @Test
    fun `no arc is drawn wider than the ring stroke`() {
        val widths = Regex("width = stroke \\* ([0-9.]+)f").findAll(code())
            .map { it.groupValues[1].toFloat() }
            .toList()
        widths.forEach {
            assertTrue(
                "an arc stroked at $it x the ring stroke is a bloom pass (the removed one was 1.5f)",
                it < 1f,
            )
        }
        assertTrue(
            "the crisp value arc must still be stroked at the plain lineWidth",
            code().contains("style = Stroke(width = stroke, cap = StrokeCap.Round)"),
        )
    }
}
