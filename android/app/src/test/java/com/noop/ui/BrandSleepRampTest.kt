package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

/**
 * Android twin of the Swift `BrandSleepRampTests`. The brand sleep ramps (#1290) shipped FLAT — one hex for
 * both schemes — because both source apps are dark-tuned. Measured against the card they are drawn on that
 * is fine in dark and broken in light: Oura `awake` cream is 1.28:1 on white, i.e. not drawn, and awake was
 * 64% of one real ring night's chart. These pin the properties that make the derived light variants
 * defensible, and the byte-identical hexes the parity rule requires.
 *
 * The trap worth remembering: clamping each band to 3:1 on its own drives Oura `rem` to #1E9EDD and `light`
 * to #239FD5 — 1.00:1 apart, two adjacent stages the same colour. A uniform per-ramp lightness scale is
 * used instead (Oura x0.575, Garmin x0.912).
 */
class BrandSleepRampTest {

    // Palette.surfaceRaised — the card the stepped hypnogram is drawn on.
    private val lightSurface = 0xFFFFFFFF
    private val darkSurface = 0xFF2A2C34

    private fun luminance(argb: Long): Double {
        fun lin(v: Double) = if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
        val r = ((argb shr 16) and 0xFF) / 255.0
        val g = ((argb shr 8) and 0xFF) / 255.0
        val b = (argb and 0xFF) / 255.0
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    private fun contrast(a: Long, b: Long): Double {
        val la = luminance(a)
        val lb = luminance(b)
        return (maxOf(la, lb) + 0.05) / (minOf(la, lb) + 0.05)
    }

    private val ramps = listOf(
        Triple("Oura/Ribbon", BrandSleepRamp.ouraLight, BrandSleepRamp.ouraDark),
        Triple("Garmin/Filled", BrandSleepRamp.garminLight, BrandSleepRamp.garminDark),
    )

    /** Sanity-check the metric before trusting anything built on it. */
    @Test
    fun contrastMetricMatchesKnownValues() {
        assertEquals(21.0, contrast(0xFFFFFFFF, 0xFF000000), 0.01)
        assertEquals(1.0, contrast(0xFFFFFFFF, 0xFFFFFFFF), 0.001)
        // The defect this change exists for, stated as a number.
        assertEquals(1.28, contrast(0xFFEAE3D3, 0xFFFFFFFF), 0.01)
    }

    /** THE ONE THAT MATTERS: every band is visible on the light card (3:1 = the WCAG non-text minimum). */
    @Test
    fun everyLightBandClearsThreeToOneOnTheLightCard() {
        for ((name, light, _) in ramps) {
            light.forEachIndexed { i, argb ->
                val c = contrast(argb, lightSurface)
                assertTrue("$name band $i is %.2f:1 on white — under the 3:1 minimum".format(c), c >= 3.0)
            }
        }
    }

    /**
     * The dark ramp is not changed here; pinned so a later light-mode tweak cannot quietly edit it. 2:1
     * rather than 3:1 because the shipped Oura `deep` is 2.02:1 on the dark card — pre-existing, and not
     * this change's business.
     */
    @Test
    fun darkRampIsUnchangedAndStillClearsTwoToOneOnTheDarkCard() {
        assertEquals(listOf(0xFFEAE3D3, 0xFF90D0F0, 0xFF40B0E0, 0xFF206080), BrandSleepRamp.ouraDark)
        assertEquals(listOf(0xFFF26FE8, 0xFFE22DD0, 0xFF4AA6F2, 0xFF2472D8), BrandSleepRamp.garminDark)
        for ((name, _, dark) in ramps) {
            dark.forEachIndexed { i, argb ->
                val c = contrast(argb, darkSurface)
                assertTrue("$name band $i is %.2f:1 on the dark card".format(c), c >= 2.0)
            }
        }
    }

    /** A ramp is an ORDERED scale — a uniform lightness scale is monotone, so the order must survive. */
    @Test
    fun lightVariantPreservesEachRampsOwnLuminanceOrder() {
        for ((name, light, dark) in ramps) {
            val darkOrder = dark.indices.sortedByDescending { luminance(dark[it]) }
            val lightOrder = light.indices.sortedByDescending { luminance(light[it]) }
            assertEquals("$name: the light variant reorders the ramp", darkOrder, lightOrder)
        }
    }

    /**
     * ...and the stages stay as separable from EACH OTHER as they already were — the property the naive
     * per-band clamp fails while still passing the 3:1 test. RELATIVE (no pair loses more than 30%) catches
     * a ramp squashed flat; ABSOLUTE (a pair distinguishable in dark stays distinguishable) catches one pair
     * collapsing while the rest looks healthy. The 1.20 floor is grandfathered against the SHIPPED dark
     * ramp, so pairs already luminance-close there (Garmin awake vs light, 1.02:1 — separated by hue, not
     * lightness) are not held to a bar the original never met.
     */
    @Test
    fun lightVariantDoesNotWorsenSeparationBetweenStages() {
        val collapseFloor = 1.20
        for ((name, light, dark) in ramps) {
            for (i in light.indices) {
                for (j in i + 1 until light.size) {
                    val d = contrast(dark[i], dark[j])
                    val l = contrast(light[i], light[j])
                    assertTrue("$name $i vs $j: separation drops %.2f -> %.2f".format(d, l), l / d >= 0.70)
                    if (d >= collapseFloor) {
                        assertTrue(
                            "$name $i vs $j: separable in dark (%.2f) collapses in light (%.2f)".format(d, l),
                            l >= collapseFloor,
                        )
                    }
                }
            }
        }
    }

    /** The trap, pinned as a value so it cannot be re-derived by accident. */
    @Test
    fun naivePerBandClampWouldCollapseTwoOuraStages() {
        assertEquals(1.00, contrast(0xFF1E9EDD, 0xFF239FD5), 0.02)
        assertTrue(contrast(BrandSleepRamp.OURA_REM_LIGHT, BrandSleepRamp.OURA_LIGHT_LIGHT) > 1.20)
    }

    /** The byte-identical contract with `StrandPalette.BrandSleepRamp` (Swift). */
    @Test
    fun lightHexesArePinnedForSwiftParity() {
        assertEquals(listOf(0xFFAD9153, 0xFF1A8AC2, 0xFF176B8E, 0xFF12374A), BrandSleepRamp.ouraLight)
        assertEquals(listOf(0xFFEF52E3, 0xFFD91EC7, 0xFF3099F0, 0xFF2168C5), BrandSleepRamp.garminLight)
    }
}
