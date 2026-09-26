package com.noop.ui

import com.noop.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.xmlpull.v1.XmlPullParser
import java.io.File

/**
 * Guards the Settings → Strap status detail copy, in particular that an in-flight scan takes
 * precedence over bonded/connected so the user gets "Searching…" feedback the moment Re-scan is
 * tapped (issue #1). The button's `enabled = !live.scanning` relies on the same scanning flag, so
 * a regression here is the visible half of "Re-scan does nothing".
 *
 * The helpers return string resources (so the screen can be translated), and [uiString] cannot resolve
 * them on the JVM. The wording checks therefore read the English source of each resource straight out of
 * `values/strings.xml`: the copy under test is the same text a user on an English phone sees.
 */
class StrapStatusDetailTest {

    private val english: Map<String, String> by lazy {
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
        val out = HashMap<String, String>()
        // kXML2 directly: android.jar's XmlPullParserFactory is a stub that throws on the JVM.
        val parser = Class.forName("org.kxml2.io.KXmlParser")
            .getDeclaredConstructor().newInstance() as XmlPullParser
        file!!.inputStream().use { input ->
            parser.setInput(input, "UTF-8")
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG && parser.name == "string") {
                    val name = parser.getAttributeValue(null, "name")
                    val value = parser.nextText().replace("\\'", "'")
                    if (name != null) out[name] = value
                }
                event = parser.next()
            }
        }
        out
    }

    /** The English text behind a resource id: its name via the generated R class, then its value. */
    private fun text(id: Int): String {
        val name = R.string::class.java.fields.first { it.getInt(null) == id }.name
        return checkNotNull(english[name]) { "no English value for $name" }
    }

    private fun detail(encryptedBond: Boolean, bonded: Boolean, connected: Boolean, scanning: Boolean) =
        text(strapStatusDetailRes(encryptedBond, bonded, connected, scanning))

    private fun title(encryptedBond: Boolean, bonded: Boolean, connected: Boolean) =
        text(strapStatusTitleRes(encryptedBond, bonded, connected))

    @Test
    fun scanning_takesPrecedence_overEveryOtherState() {
        // Even when already bonded + connected, an active scan must say "Searching…".
        assertTrue(
            detail(encryptedBond = true, bonded = true, connected = true, scanning = true)
                .startsWith("Searching for your WHOOP"),
        )
        assertTrue(
            detail(encryptedBond = false, bonded = false, connected = false, scanning = true)
                .startsWith("Searching for your WHOOP"),
        )
    }

    @Test
    fun nonScanning_branches_areUnchanged() {
        assertEquals(
            "Your strap is paired and sending data. Open Live for a real-time heart rate.",
            detail(encryptedBond = true, bonded = true, connected = true, scanning = false),
        )
        assertEquals(
            "Connected. Finishing the secure pairing handshake…",
            detail(encryptedBond = false, bonded = false, connected = true, scanning = false),
        )
        assertEquals(
            "Previously paired but not currently connected. Re-scan to reconnect.",
            detail(encryptedBond = true, bonded = true, connected = false, scanning = false),
        )
        assertEquals(
            "No strap connected. Put your WHOOP nearby and tap Re-scan to pair.",
            detail(encryptedBond = false, bonded = false, connected = false, scanning = false),
        )
    }

    @Test
    fun `a live-HR-only link is not described as paired`() {
        // #1635/#69: the 5/MG live-HR shortcut sets bonded without any encrypted pairing, and hello
        // suppression makes that the permanent state. Telling the user their strap "is paired" there
        // contradicts the Devices screen and the buzz/alarm rows on this same screen.
        val detail = detail(
            encryptedBond = false, bonded = true, connected = true, scanning = false,
        )
        assertFalse(detail.contains("is paired"))
        assertTrue(detail.contains("not fully paired"))

        // The consequences, not just the state. This line used to name only buzz, alarms and history
        // sync — but an unbonded strap also stops sending motion, skin temperature, SpO2 and
        // respiratory rate, which drops sleep onto the HR-only stager and blanks HRV + resting HR
        // (AnalyticsEngine gates both on `!hrOnly`). A field log showed a week of blank Recovery
        // Vitals while this line pointed at three features the user was not missing.
        assertTrue(detail.contains("motion"))
        // #1884 repinned the tail of this: naming HRV and resting HR as CONSEQUENCES stopped being true
        // when an HR-only night began reporting both. What survives is the reason they were named at all
        // — the strap stops sending motion, so sleep falls to the HR-only stager.
        assertTrue(detail.contains("staged from heart rate alone"))
        assertFalse(detail.contains("HRV and resting heart rate are unavailable"))
        // The original claim has to survive the rewrite.
        assertTrue(detail.contains("history sync"))

        assertEquals("Live HR (not fully paired)",
            title(encryptedBond = false, bonded = true, connected = true))
        assertEquals("Bonded · streaming",
            title(encryptedBond = true, bonded = true, connected = true))
    }

    @Test
    fun `only a real bond on a live link is a positive tone`() {
        assertEquals(StrandTone.Positive, strapTone(encryptedBond = true, bonded = true, connected = true))
        assertEquals(StrandTone.Warning, strapTone(encryptedBond = false, bonded = true, connected = true))
        assertEquals(StrandTone.Critical, strapTone(encryptedBond = false, bonded = false, connected = false))
    }
}
