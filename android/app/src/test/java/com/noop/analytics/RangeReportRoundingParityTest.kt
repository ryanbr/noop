package com.noop.analytics

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The report's one-decimal formatter, pinned to Swift.
 *
 * The Android page rounded with `roundToInt` (ties toward +∞) while the Swift page used `.rounded()`
 * (half away from zero). Positive values agreed, so it went unnoticed; every NEGATIVE tie did not.
 * Skin temp is the report's only signed metric, so a stored −0.25 Δ°C printed −0.3 on iOS and −0.2 on
 * Android, and −0.05 printed −0.1 against a sign-losing 0.0 — one platform saying "below baseline"
 * where the other said "at baseline", in a document users compare side by side.
 *
 * The expectations are the VERBATIM stdout of the Swift formatter compiled standalone:
 *
 *     func round1Text(_ x: Double) -> String { String(format: "%.1f", (x * 10).rounded() / 10) }
 */
class RangeReportRoundingParityTest {

    /** Byte-for-byte what `TrendsReportRenderer.round1` does (it is private; this mirrors it). */
    private fun round1Text(x: Double): String =
        String.format(Locale.US, "%.1f", RangeReportEngine.round1(x))

    @Test
    fun negativeTiesRoundAwayFromZeroLikeSwift() {
        assertEquals("-0.3", round1Text(-0.25))
        assertEquals("-0.4", round1Text(-0.35))
        assertEquals("-0.5", round1Text(-0.45))
        assertEquals("-0.2", round1Text(-0.15))
        assertEquals("-0.1", round1Text(-0.05))
        assertEquals("-0.8", round1Text(-0.75))
    }

    @Test
    fun positiveTiesAreUnchanged() {
        assertEquals("0.3", round1Text(0.25))
        assertEquals("0.4", round1Text(0.35))
        assertEquals("0.8", round1Text(0.75))
    }

    @Test
    fun ordinaryValuesAreUnaffected() {
        assertEquals("0.9", round1Text(0.9359999999999999))   // the reporter's 0.52 °C in °F
        assertEquals("12.4", round1Text(12.389999999999999))  // 59 Effort on the 0–21 axis
        assertEquals("-0.4", round1Text(-0.36))
        assertEquals("0.0", round1Text(0.0))
    }
}
