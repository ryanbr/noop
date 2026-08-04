package com.noop.ui

import com.noop.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The Blood O₂ tile must distinguish "the sensor recorded nothing" from "the sensor recorded, but the
 * calibrated % comes from an import".
 *
 * A WHOOP 4.0 banks raw red/IR ADC counts and NOT a percentage — the schema says so at the field
 * (`raw ADC; SpO2 % computed server-side`) — so `spo2Pct` is import-only by design and the raw tile shows
 * the counts instead. When both tiles render together the old wording contradicted itself: an empty
 * "No SpO₂ import or Health value" sitting beside a Raw SpO₂ tile displaying a live number, which reads
 * as a broken strap rather than a missing import. That is a real user report, not a hypothetical.
 *
 * `vitalsFor` resolves strings through `NoopApplication`, so it cannot run in a JVM unit test at all;
 * [spo2MissingCaptionRes] exists to make the BRANCH testable without the resource lookup.
 */
class Spo2MissingCaptionTest {

    @Test
    fun rawCountsPresentGetsTheImportWording() {
        assertEquals(
            R.string.l10n_health_screen_raw_counts_only_needs_an_import_d0e33552,
            spo2MissingCaptionRes(hasRawSpo2 = true),
        )
    }

    @Test
    fun nothingDecodedKeepsTheOriginalWording() {
        assertEquals(
            R.string.l10n_health_screen_no_spo_import_or_health_value_408f8c55,
            spo2MissingCaptionRes(hasRawSpo2 = false),
        )
    }

    /** The whole point is that the two states read differently. */
    @Test
    fun theTwoEmptyStatesAreNotTheSameString() {
        assertNotEquals(spo2MissingCaptionRes(true), spo2MissingCaptionRes(false))
    }

    // --- cross-platform wording parity ---

    private fun repoRoot(): File {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val candidates = listOf(userDir, File(userDir, ".."), File(userDir, "../.."))
        val found = candidates.firstOrNull { File(it, "Strand/Resources/Localizable.xcstrings").isFile }
        assertNotNull(
            "repo root not found from user.dir=$userDir — this guard cannot run, and a skip reads as a " +
                "pass. Add this host's working dir rather than letting it slide.",
            found,
        )
        return found!!
    }

    /**
     * Both captions must carry the SAME English text on both platforms.
     *
     * `Vital.missingCaption` is documented as the "Kotlin twin of `BodyVitalReading.missingCaption`
     * (VitalSignsSummary.swift) — same wording", and nothing enforced it: Apple wrapped these in
     * `String(localized:)` while Android used raw Kotlin literals, so the two could drift silently and
     * a German phone got English on exactly one platform. Reading both catalogues is the only check
     * available here, since the Swift side is app-target and no CI job compiles it.
     */
    @Test
    fun bothCaptionsMatchTheSwiftCatalogueWordForWord() {
        val root = repoRoot()
        val androidXml = File(root, "android/app/src/main/res/values/strings.xml").readText()
        val xcstrings = File(root, "Strand/Resources/Localizable.xcstrings").readText()

        val expected = mapOf(
            "l10n_health_screen_no_spo_import_or_health_value_408f8c55" to "No SpO₂ import or Health value",
            "l10n_health_screen_raw_counts_only_needs_an_import_d0e33552" to "Raw counts only — needs an import",
        )
        for ((key, en) in expected) {
            assertTrue(
                "Android is missing $key -> \"$en\"",
                androidXml.contains("<string name=\"$key\">$en</string>"),
            )
            assertTrue(
                "the Swift catalogue has no entry for \"$en\" — the twin captions have drifted apart",
                xcstrings.contains("\"$en\""),
            )
        }
    }

    /**
     * The new caption must be translated everywhere the one it sits beside is, or the fix lands as English
     * for precisely the non-English users who hit the confusing version. (The report behind this was a
     * German screenshot.)
     */
    @Test
    fun theNewCaptionIsTranslatedInEveryLocaleTheSiblingIs() {
        val root = File(repoRoot(), "android/app/src/main/res")
        val locales = root.listFiles { f: File -> f.isDirectory && f.name.startsWith("values-") }
            ?.filterNot { it.name.matches(Regex("values-(night|v\\d+|land|sw\\d+.*)")) }
            ?.filter { File(it, "strings.xml").isFile }
            ?: emptyList()
        assertTrue("no locale dirs found — the census is looking in the wrong place", locales.isNotEmpty())

        val missing = locales.filterNot {
            File(it, "strings.xml").readText()
                .contains("l10n_health_screen_raw_counts_only_needs_an_import_d0e33552")
        }.map { it.name }
        assertEquals("these locales have the sibling caption but not the new one: $missing", emptyList<String>(), missing)
    }
}
