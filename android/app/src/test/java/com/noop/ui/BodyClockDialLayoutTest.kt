package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The body clock dial's radial bands may not overlap (#2350).
 *
 * The reported symptom was that the "your clock" arc read as radial hash marks running into the six-hour
 * ticks. Two separate causes: the arc was stroked at the SAME radius the ticks occupy, and its dashes were
 * shorter than the stroke was wide, so each one rendered as a stubby rectangle pointing outwards.
 *
 * Neither is catchable by compiling, and neither is visible in a unit test either. What IS checkable is the
 * arithmetic: given the named radii and widths, no two bands may share space, and a dash must be longer
 * than its stroke is wide. That is the part of "does this look right" a test can honestly own. Whether the
 * result READS well still needs eyes on a device.
 *
 * Twin of the Swift `BodyClockDialLayoutTests`, same numbers, since the two dials are drawn to one spec.
 */
class BodyClockDialLayoutTest {

    /** A band is the radial span a drawn element occupies, from the dial centre outwards. */
    private data class Band(val name: String, val from: Double, val to: Double)

    private val tunedRim = 90.0            // side/2 - 10 at the card's 200 dp height
    private val midnightTick = 6.0
    private val labelHeight = 11.0         // 10 sp numerals, generously rounded up
    private val referenceWidth = 7.0
    private val nightWidth = 9.0
    private val glyph = 12.0

    /** Mirrors `DialGeometry`: the offsets are a fraction of the radius, so the bands scale with it. */
    private fun bands(rim: Double = tunedRim): List<Band> {
        val k = rim / tunedRim
        return listOf(
            Band("ticks", rim - midnightTick * k, rim),
            Band("labels", (rim - 15 * k) - labelHeight * k / 2, (rim - 15 * k) + labelHeight * k / 2),
            Band("reference arc", (rim - 31 * k) - referenceWidth * k / 2, (rim - 31 * k) + referenceWidth * k / 2),
            Band("night arc", (rim - 45 * k) - nightWidth * k / 2, (rim - 45 * k) + nightWidth * k / 2),
            Band("bed glyph", (rim - 58 * k) - glyph * k / 2, (rim - 58 * k) + glyph * k / 2),
        )
    }

    /** Rims a real card can actually be handed, from a narrow split pane up to the tuned size. */
    private val rimsToCheck = listOf(15.0, 25.0, 40.0, 50.0, 70.0, 90.0)

    @Test fun noTwoBandsOverlapAtAnySize() {
        for (rim in rimsToCheck) {
            for ((outerBand, innerBand) in bands(rim).zipWithNext()) {
                val gap = outerBand.from - innerBand.to
                assertTrue(
                    "at rim $rim, ${innerBand.name} runs into ${outerBand.name}: gap is $gap",
                    gap > 0.0,
                )
            }
        }
    }

    /**
     * The innermost element must clear the centre AT EVERY SIZE, not only the tuned one.
     *
     * With fixed offsets the nesting depth stayed 58 dp however small the card got, so a narrow one drove
     * the bed through the centre and the night arc to a negative radius, which draws nothing here and is
     * undefined for the Swift `addArc`. Checking a single rim asserted the design was sound at one size
     * and said nothing about the range, which is the shape of test that lets this through.
     */
    @Test fun theInnermostBandClearsTheCentreAtAnySize() {
        for (rim in rimsToCheck) {
            val innermost = bands(rim).last()
            assertTrue(
                "at rim $rim, ${innermost.name} reaches the centre (from ${innermost.from})",
                innermost.from > 0.0,
            )
        }
    }

    /**
     * A dash shorter than the stroke is wide is not a dash, it is a hash mark pointing outwards. The first
     * attempt at this dial used a 3 dp dash under a 7 dp stroke; an earlier one used a round cap, which
     * adds width/2 of ink at EACH end of EVERY dash and closed the gaps entirely. The invariant that
     * survives both is simply that the dash must be the longer of the two.
     */
    @Test fun theReferenceDashIsLongerThanItIsWide() {
        val dashLength = 10.0
        assertTrue(
            "a $dashLength dp dash under a $referenceWidth dp stroke reads as a hash mark",
            dashLength > referenceWidth,
        )
    }

    /** The bed marks onset, so it must sit off the night arc rather than on top of the end it marks. */
    @Test fun theBedGlyphSitsOffTheNightArc() {
        for (rim in rimsToCheck) {
            val night = bands(rim).first { it.name == "night arc" }
            val bed = bands(rim).first { it.name == "bed glyph" }
            assertTrue("at rim $rim the bed overlaps the arc it marks", bed.to < night.from)
        }
    }

    /**
     * The numerals must be a FIXED size, not a scaling one.
     *
     * The band they sit in has 3.5 dp of clearance to the ticks, and the dial's radii do not scale with
     * the reader's font setting. A text STYLE (Swift `StrandFont.caption`) or an `sp` size would grow at
     * accessibility text sizes and run straight into the ticks, which is the collision this whole change
     * removes. Asserted as source on both platforms because a font choice has no unit seam.
     */
    @Test fun theHourNumeralsDoNotScaleWithTheFontSetting() {
        val src = cardSource()
        assertTrue(
            "dial numerals must be sized in dp; sp scales with the system font setting",
            src.contains("textSize = with(density) { 10.dp.toPx() }"),
        )
        // CODE only, for the reason the Swift twin records: a comment naming the thing it warns against
        // will trip an assertion that the thing is absent.
        val code = src.lines().filterNot { it.trimStart().startsWith("//") }
        assertFalse(
            "the sp import should be gone with its last use",
            code.any { it.contains("androidx.compose.ui.unit.sp") },
        )
    }

    private fun cardSource(): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/ui/BodyClockDialCard.kt")
            if (f.isFile) return f.readText()
            root = root.parentFile ?: root
        }
        throw IllegalStateException("BodyClockDialCard.kt not found")
    }
}
