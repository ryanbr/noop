package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.xmlpull.v1.XmlPullParser
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * #694 — smoke test for the German (de) string-resource pass. Parses the default English
 * `values/strings.xml` and the `values-de/strings.xml` off the source tree and pins the contract
 * the localization layer must keep:
 *
 *  - every nav / action string the app externalized has a German translation (no missing key falls
 *    back to English silently);
 *  - no German value is blank (an empty <string> renders as nothing on screen);
 *  - the German nav labels are actually translated where they should be (a spot-check on a few terms
 *    that MUST differ from English, so the file can't be an accidental English copy);
 *  - the app_name brand is deliberately NOT re-declared in German (it stays the single English value).
 *
 * Runs on the plain JVM (no Robolectric) via the real XmlPullParser already on the test classpath
 * (net.sf.kxml2), locating the res files relative to the Gradle `user.dir` exactly like
 * DecoderOracleTest does. Skips (rather than fails) if the tree layout can't be found, so it never
 * blocks an out-of-tree runner.
 */
class GermanLocalizationTest {

    private fun resFile(rel: String): File? {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        // Gradle runs unit tests with the module dir (android/app) or the repo root as user.dir.
        return listOf(
            File(userDir, "src/main/res/$rel"),
            File(userDir, "android/app/src/main/res/$rel"),
            File(userDir, "app/src/main/res/$rel"),
        ).firstOrNull { it.exists() }
    }

    /** Parse a strings.xml into name -> value (translatable string elements only). */
    private fun parseStrings(file: File): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        // Construct kXML2's KXmlParser directly (the testImplementation dep). We avoid
        // XmlPullParserFactory.newInstance() because android.jar ships a *stub* factory whose
        // newInstance() throws "Stub!" on the JVM unit-test classpath (see AppleHealthImporterToleranceTest).
        val parser = Class.forName("org.kxml2.io.KXmlParser")
            .getDeclaredConstructor().newInstance() as XmlPullParser
        file.inputStream().use { input ->
            parser.setInput(input, "UTF-8")
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG && parser.name == "string") {
                    val name = parser.getAttributeValue(null, "name")
                    val value = parser.nextText()
                    if (name != null) out[name] = value
                }
                event = parser.next()
            }
        }
        return out
    }

    private fun parseVariants(file: File): Map<String, Map<String, String>> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val out = linkedMapOf<String, Map<String, String>>()
        val strings = document.getElementsByTagName("string")
        for (index in 0 until strings.length) {
            val element = strings.item(index)
            val name = element.attributes.getNamedItem("name")?.nodeValue ?: continue
            out[name] = mapOf("other" to element.textContent)
        }
        val plurals = document.getElementsByTagName("plurals")
        for (index in 0 until plurals.length) {
            val element = plurals.item(index)
            val name = element.attributes.getNamedItem("name")?.nodeValue ?: continue
            val variants = linkedMapOf<String, String>()
            val children = element.childNodes
            for (childIndex in 0 until children.length) {
                val child = children.item(childIndex)
                if (child.nodeName != "item") continue
                val quantity = child.attributes.getNamedItem("quantity")?.nodeValue ?: continue
                variants[quantity] = child.textContent
            }
            out[name] = variants
        }
        return out
    }

    @Test
    fun germanResourcesResolveForEveryLocalizedKey() {
        val enFile = resFile("values/strings.xml")
        val deFile = resFile("values-de/strings.xml")
        assumeTrue(
            "strings.xml not found from user.dir=${System.getProperty("user.dir")}, skipping",
            enFile != null && deFile != null,
        )
        val en = parseStrings(enFile!!)
        val de = parseStrings(deFile!!)

        // The keys the app externalized (nav + more-group + quick actions) MUST all be translated.
        // widget_* is UI copy too; app_name is the brand and is intentionally English-only.
        val mustTranslate = en.keys.filter { it != "app_name" }
        val missing = mustTranslate.filter { it !in de }
        assertTrue("German is missing translations for: $missing", missing.isEmpty())

        // No German value may be blank (an empty <string> shows as nothing on screen).
        val blank = de.filterValues { it.isBlank() }.keys
        assertTrue("German has blank values for: $blank", blank.isEmpty())

        // app_name is NOT re-declared in German — it stays the one English brand value.
        assertFalse("app_name must not be redeclared in values-de", "app_name" in de)
    }

    @Test
    fun germanNavLabelsAreActuallyTranslated() {
        val enFile = resFile("values/strings.xml")
        val deFile = resFile("values-de/strings.xml")
        assumeTrue("strings.xml not found, skipping", enFile != null && deFile != null)
        val en = parseStrings(enFile!!)
        val de = parseStrings(deFile!!)

        // A spot-check on terms that MUST differ from English, so a stray English copy can't pass.
        val differs = mapOf(
            "nav_today" to "Heute",
            "nav_sleep" to "Schlaf",
            "nav_settings" to "Einstellungen",
            "nav_more" to "Mehr",
            "nav_health" to "Gesundheit",
        )
        for ((key, expected) in differs) {
            assertTrue("$key present in en", key in en)
            assertTrue(
                "$key should be German ($expected), was '${de[key]}'",
                de[key] == expected && de[key] != en[key],
            )
        }
    }

    @Test
    fun germanTodayVocabularyAndCompleteExplanationStayReviewed() {
        val enFile = resFile("values/strings.xml")
        val deFile = resFile("values-de/strings.xml")
        assumeTrue("strings.xml not found, skipping", enFile != null && deFile != null)
        val en = parseStrings(enFile!!)
        val de = parseStrings(deFile!!)

        val expected = mapOf(
            "today_section_hero" to "Energie / Belastung / Erholung",
            "today_section_synthesis" to "Zusammenfassung",
            "today_section_key_metrics" to "Wichtige Messwerte",
            "today_section_live_session" to "Training starten",
            "l10n_today_screen_detailed_tiles_0801721b" to "Detaillierte Kacheln",
            "l10n_today_screen_rest_b79e5f48" to "Erholung",
            "l10n_today_screen_recovery_ea924f72" to "Erholung",
            "today_recovery_carried" to "Erholung · %1\$s",
            "today_card_coupled_subtitle" to "Erholung, Belastung und Schlaf auf einen Blick",
            "today_pending_scores_body" to "Deine Live-Herzfrequenz kommt bereits vom Strap. Erholung, Belastung und Schlaf werden in den nächsten Nächten aufgebaut und mit deinem Basiswert genauer. Für den vollständigen Verlauf kannst du deinen WHOOP-Export unter „Datenquellen“ importieren; er wird in etwa einer Minute ergänzt.",
            "today_training_read_explanation" to "Eine Trainingseinschätzung, unabhängig von deinem Energiewert.",
            "l10n_today_screen_sync_chip_syncing_desc_bfc290e7" to "Verlaufssynchronisierung des Straps läuft, %1\$d Datenblöcke",
            "l10n_today_screen_squarer_tiles_with_a_trend_graph_3c297dec" to "Größere Kacheln mit einem Trenddiagramm unter dem Balken.",
        )
        expected.forEach { (key, value) -> assertEquals("unexpected German Today copy for $key", value, de[key]) }

        val explanation = de.getValue("today_recovery_vitals_explanation")
        assertTrue(explanation.startsWith("Basiswerte werden über 14 Tage"))
        assertTrue(explanation.endsWith("keine medizinische Beratung."))
        assertEquals(
            placeholders(en.getValue("today_recovery_vitals_explanation")),
            placeholders(explanation),
        )

        val todaySource = resFile("../java/com/noop/ui/TodayScreen.kt")?.readText().orEmpty()
        assertTrue("Today must use the complete localized explanation", "R.string.today_recovery_vitals_explanation" in todaySource)
        assertFalse("English explanation fragment must not be composed in Kotlin", "signal against a typical adult range" in todaySource)
    }

    @Test
    fun germanTodayPlaceholdersAndPluralsMatchEnglish() {
        val enFile = resFile("values/strings.xml")
        val deFile = resFile("values-de/strings.xml")
        assumeTrue("strings.xml not found, skipping", enFile != null && deFile != null)
        val en = parseVariants(enFile!!).filterKeys { it.startsWith("today_") }
        val de = parseVariants(deFile!!)

        en.forEach { (key, englishVariants) ->
            val germanVariants = de[key] ?: error("German Today resource missing: $key")
            assertEquals("plural quantities differ for $key", englishVariants.keys, germanVariants.keys)
            englishVariants.forEach { (quantity, english) ->
                assertEquals(
                    "placeholders differ for $key/$quantity",
                    placeholders(english),
                    placeholders(germanVariants.getValue(quantity)),
                )
            }
        }
    }

    private fun placeholders(value: String): List<String> =
        Regex("%(?:\\d+\\$)?[sdf]").findAll(value).map { it.value.replace(Regex("\\d+\\$"), "") }.sorted().toList()
}
