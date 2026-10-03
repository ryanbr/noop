package com.noop.ui

import com.noop.R
import org.junit.Assert.assertNotNull
import org.xmlpull.v1.XmlPullParser
import java.io.File

/**
 * The English source of the app's string resources, read straight out of `values/strings.xml`.
 *
 * Helpers that return a string resource (so a screen can be translated) cannot be resolved on the JVM,
 * where [uiString] has no Application to go through. Tests that pin user-facing wording read the English
 * value instead: the same text a user on an English phone sees.
 */
internal object EnglishResources {

    private class Catalog(val strings: Map<String, String>, val plurals: Map<String, Map<String, String>>)

    private val catalog: Catalog by lazy {
        val userDir = File(System.getProperty("user.dir") ?: ".")
        // Gradle runs unit tests with the module dir (android/app) or the repo root as user.dir.
        val file = listOf(
            File(userDir, "src/main/res/values/strings.xml"),
            File(userDir, "android/app/src/main/res/values/strings.xml"),
            File(userDir, "app/src/main/res/values/strings.xml"),
        ).firstOrNull { it.exists() }
        assertNotNull(
            "values/strings.xml not found from user.dir=$userDir; a skip here would read as a pass",
            file,
        )
        val strings = HashMap<String, String>()
        val plurals = HashMap<String, HashMap<String, String>>()
        // kXML2 directly: android.jar's XmlPullParserFactory is a stub that throws on the JVM.
        val parser = Class.forName("org.kxml2.io.KXmlParser")
            .getDeclaredConstructor().newInstance() as XmlPullParser
        file!!.inputStream().use { input ->
            parser.setInput(input, "UTF-8")
            var pluralName: String? = null
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG) {
                    when (parser.name) {
                        "string" -> parser.getAttributeValue(null, "name")?.let { strings[it] = unescape(parser.nextText()) }
                        "plurals" -> pluralName = parser.getAttributeValue(null, "name")
                        "item" -> {
                            val quantity = parser.getAttributeValue(null, "quantity")
                            val name = pluralName
                            if (name != null && quantity != null) {
                                plurals.getOrPut(name) { HashMap() }[quantity] = unescape(parser.nextText())
                            }
                        }
                    }
                } else if (event == XmlPullParser.END_TAG && parser.name == "plurals") {
                    pluralName = null
                }
                event = parser.next()
            }
        }
        Catalog(strings, plurals)
    }

    private fun unescape(raw: String): String = raw.replace("\\'", "'").replace("\\\"", "\"")

    /** The English text behind a string resource id: its name via the generated R class, then its value. */
    fun text(id: Int): String {
        val name = R.string::class.java.fields.first { it.getInt(null) == id }.name
        return checkNotNull(catalog.strings[name]) { "no English value for $name" }
    }

    /** [text] with its `%1$s`-style arguments filled, as `getString(id, args)` would. */
    fun format(id: Int, vararg args: Any): String = String.format(text(id), *args)

    /** One English `<item quantity=...>` of a plurals resource id, e.g. `"one"` or `"other"`. */
    fun plural(id: Int, quantity: String): String {
        val name = R.plurals::class.java.fields.first { it.getInt(null) == id }.name
        val forms = checkNotNull(catalog.plurals[name]) { "no English plurals for $name" }
        return checkNotNull(forms[quantity]) { "no English \"$quantity\" form for $name" }
    }
}
