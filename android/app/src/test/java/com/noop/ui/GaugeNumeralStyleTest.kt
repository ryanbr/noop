package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gauge numeral weight preference (#2346).
 *
 * A reporter found the Today gauges "too much in your face". Bold display numerals are the deliberate
 * house style on BOTH platforms, so this is a preference rather than a defect: `BOLD` stays the default
 * and nothing moves for anyone who does not ask.
 *
 * Only the WEIGHT is offered. The size is pinned to the iOS 96-to-26 ratio at the call site, and moving
 * one platform alone would break an alignment that was chosen on purpose.
 */
class GaugeNumeralStyleTest {

    @Test fun theDefaultIsBoldSoNothingMovesWithoutAsking() {
        assertEquals(GaugeNumeralStyle.BOLD, GaugeNumeralStyle.fromStorage(null))
        assertEquals(GaugeNumeralStyle.BOLD, GaugeNumeralStyle.fromStorage("nonsense"))
    }

    /** Storage values are persisted, so they are a contract and cannot be renamed casually. */
    @Test fun storageValuesRoundTrip() {
        for (style in GaugeNumeralStyle.entries) {
            assertEquals(style, GaugeNumeralStyle.fromStorage(style.storageValue))
        }
        assertEquals("bold", GaugeNumeralStyle.BOLD.storageValue)
        assertEquals("soft", GaugeNumeralStyle.SOFT.storageValue)
    }

    /**
     * The gauge numeral must read the preference, and only the weight may depend on it.
     *
     * Source-asserted because the call site is a Composable over an animated vessel with no unit seam.
     * The second half matters as much as the first: a size that followed a preference would break the
     * cross-platform ratio the comment above it records.
     */
    @Test fun theGaugeNumeralFollowsThePreferenceButItsSizeDoesNot() {
        val src = todaySource()
        val start = src.indexOf("val numberSp = ")
        if (start < 0) throw AssertionError("the gauge numeral sizing was not found")
        val body = src.substring(start, src.indexOf("\n        }", start))
        assertTrue(
            "the numeral weight must follow AppearancePrefs:\n$body",
            body.contains("AppearancePrefs.gaugeNumerals == GaugeNumeralStyle.SOFT"),
        )
        assertTrue(
            "SOFT must fall back to the NoopType.number default weight",
            body.contains("FontWeight.SemiBold"),
        )
        assertTrue(
            "the size stays the iOS-matched ratio, not a preference",
            body.contains("(diameter.value * 0.27f).coerceIn(20f, 30f)"),
        )
        // CODE only. This passed by luck: the comment above the call site happens not to spell
        // "GaugeNumeralStyle", and would have failed the assertion if it did. The same shape bit
        // `BodyClockDialLayoutTests` an hour earlier, where prose describing a rule tripped the rule.
        val sizingCode = body.substringBefore("style = NoopType.number(")
            .lines().filterNot { it.trimStart().startsWith("//") }
        assertFalse(
            "the SIZE must not depend on the preference; only the weight may",
            sizingCode.any { it.contains("GaugeNumeralStyle") },
        )
    }

    /**
     * The preference stays OUT of the backup whitelist, like the theme mode it sits beside.
     *
     * `.noopbak` is a byte-identical cross-platform contract carrying profile, units and anything that
     * changes a NUMBER. A display choice is device-local and means nothing restored onto another device,
     * so adding it would widen that contract for no gain.
     */
    @Test fun thePreferenceIsNotInTheBackupWhitelist() {
        val backup = backupSource()
        assertFalse(
            "appearance.gaugeNumerals must not join the .noopbak contract",
            backup.contains("appearance.gaugeNumerals"),
        )
        assertFalse(
            "and its sibling theme preference is not in it either, which is the precedent",
            backup.contains("theme.appearance"),
        )
    }

    private fun todaySource(): String = read("android/app/src/main/java/com/noop/ui/TodayScreen.kt")
    private fun backupSource(): String = read("android/app/src/main/java/com/noop/data/BackupSettings.kt")

    private fun read(relative: String): String {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        repeat(4) {
            val f = java.io.File(root, relative)
            if (f.isFile) return f.readText()
            root = root.parentFile ?: root
        }
        throw IllegalStateException("$relative not found from ${System.getProperty("user.dir")}")
    }
}
