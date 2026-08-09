package com.noop.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.xmlpull.v1.XmlPullParser
import java.io.File

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
}
