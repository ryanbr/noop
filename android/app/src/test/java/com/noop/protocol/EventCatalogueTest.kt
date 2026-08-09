package com.noop.protocol

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Holds [EventNumber] in lockstep with the shared schema
 * (`Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`), which iOS reads directly
 * at runtime.
 *
 * Android used to name only 13 of the 58 events, so every other event rendered as a bare `0x44(68)` in an
 * Android strap log while iOS named it. #791 was filed partly on the strength of an "uncatalogued" event
 * that iOS already knew. A label divergence breaks the cross-platform contract as surely as a value
 * divergence, and it stays invisible until someone is reading a log.
 *
 * This reads the schema rather than restating it, on purpose. The bug being fixed is precisely "the schema
 * grew and Android did not follow", so a test carrying its own copy of the catalogue would pass straight
 * through a recurrence — it could only catch a deletion or a renumber.
 *
 * The lockstep check `Assume`-skips when the Swift tree is absent, following [DecoderOracleTest]'s
 * convention, so it is a drift guard for a full checkout and not a hard gate everywhere. The targeted checks
 * below never skip, so the #791 events and the revived RTC diagnostic stay pinned either way.
 */
class EventCatalogueTest {

    /**
     * Locates the schema the same way [DecoderOracleTest.oracleCopiesAreIdentical] locates the Swift oracle
     * copy — `user.dir` is the module dir or the repo root depending on how the runner was launched — and
     * skips gracefully by the same convention if the Swift tree is not present.
     */
    @Test
    fun everyEventInTheSharedSchemaIsNamedOnAndroid() {
        val rel = "Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json"
        val userDir = File(System.getProperty("user.dir") ?: ".")
        val schemaFile = listOf(File(userDir, rel), File(userDir, "../../$rel")).firstOrNull { it.exists() }
        org.junit.Assume.assumeTrue(
            "shared schema not found from user.dir=$userDir — skipping the catalogue lockstep check",
            schemaFile != null,
        )
        val events = JSONObject(schemaFile!!.readText()).getJSONObject("enums").getJSONObject("EventNumber")
        val schema = events.keys().asSequence().associate { it.toInt() to events.getString(it) }
        assertTrue("EventNumber block parsed empty", schema.isNotEmpty())

        val kotlin = EventNumber.entries.associate { it.rawValue to it.name }
        assertEquals("Android is missing events the schema names", emptySet<Int>(), schema.keys - kotlin.keys)
        assertEquals("Android names events the schema does not", emptySet<Int>(), kotlin.keys - schema.keys)
        for ((raw, name) in schema) {
            assertEquals("event $raw", name, kotlin[raw])
        }
    }

    /** A copy-paste renumber would otherwise shadow an event silently. */
    @Test
    fun rawValuesAreUnique() {
        assertEquals(
            EventNumber.entries.size,
            EventNumber.entries.map { it.rawValue }.toSet().size,
        )
    }

    /** The events from #791 that an Android reporter could not previously name. */
    @Test
    fun theEventsThatMatterForAndroidBugReportsAreNamed() {
        assertEquals("EXTENDED_BATTERY_INFORMATION", EventNumber.fromRaw(63)?.name)  // untested battery path
        assertEquals("RTC_LOST", EventNumber.fromRaw(13)?.name)                      // scrambled RTC
        assertEquals("SET_RTC", EventNumber.fromRaw(16)?.name)                       // SET_CLOCK not sticking
        assertEquals("BOOT", EventNumber.fromRaw(15)?.name)                          // brownout/reboot
        assertEquals("BOOT_REPORT", EventNumber.fromRaw(30)?.name)
        assertEquals("BLE_SYSTEM_RESET", EventNumber.fromRaw(43)?.name)
    }

    /**
     * The behavioural bug the missing names caused, not just the cosmetic one.
     *
     * `DroppedRtcEvent.isRtcStateKind` matches the event LABEL by prefix, and the label is built from this
     * enum (`"NAME(raw)"`, pinned by [FramingTest]). While events 13/15/16/30 were unnamed on Android their
     * labels were `0x0D(13)` and friends, which match nothing — so the #324 dropped-RTC diagnostic was dead
     * code on Android even though it mirrors Swift and iOS has captured it since #324
     * (`HistoricalTimestampGateTests` pins the very string asserted below). That is the diagnostic which
     * explains a future-dated strap, exactly the symptom reported in #791.
     */
    @Test
    fun rtcStateDiagnosticCanNowActuallyFire() {
        // The exact label the Swift twin's test asserts.
        assertTrue(DroppedRtcEvent.isRtcStateKind("RTC_LOST(13)"))
        assertTrue(DroppedRtcEvent.isRtcStateKind("BOOT(15)"))
        assertTrue(DroppedRtcEvent.isRtcStateKind("SET_RTC(16)"))
        assertTrue(DroppedRtcEvent.isRtcStateKind("BOOT_REPORT(30)"))

        // What Android produced before, and why the diagnostic never fired there.
        assertFalse(DroppedRtcEvent.isRtcStateKind("0x0D(13)"))
        // Still correctly excluded: not an RTC-state event.
        assertFalse(DroppedRtcEvent.isRtcStateKind("BATTERY_LEVEL(3)"))
        assertFalse(DroppedRtcEvent.isRtcStateKind("0x44(68)"))
    }

    /**
     * An unnamed number must stay unnamed. Event 68 (`0x44`) was observed on a real WHOOP 4.0 in #791 and is
     * unknown to both platforms; inventing a name — or borrowing one from `CommandNumber`, where 68 is a
     * different thing entirely — would put a fiction in the log, which is worse than a hex code.
     */
    @Test
    fun unknownEventsAreNotGivenInventedNames() {
        assertNull(EventNumber.fromRaw(68))
        assertNull(EventNumber.fromRaw(48))
        assertNull(EventNumber.fromRaw(123))
        assertNull(EventNumber.fromRaw(255))
    }
}
