package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The strap log is the artifact people attach to public issues, and the crash it carries is the one
 * text in it that never passed through the live log sink's scrub. These pin that it is redacted on
 * the way out, and that a device with no crash still ships no section rather than an empty heading.
 */
class LogExportCrashSectionTest {

    @Test fun aCrashNamingAStrapShipsWithItsMacMasked() {
        val raw = "when: now\njava.lang.IllegalStateException: no device FD:12:34:56:78:9A"
        val section = LogExport.crashSection(raw)
        assertFalse("a full BLE address must not reach a shared log", section.contains("FD:12:34:56:78:9A"))
        assertTrue("masked in the same shape as the rest of the export", section.contains("••"))
        assertTrue("and the section is still labelled for whoever reads it", section.contains("Last crash:"))
    }

    @Test fun noCrashMeansNoSection() {
        assertEquals("never fabricate a heading for a crash that did not happen", "", LogExport.crashSection(null))
    }

    /**
     * The case from the field: a 25-day-old record under a much newer header. Read twice in one week
     * as a fresh crash, because nothing connected the record's build to the log's.
     */
    @Test fun aCrashFromAnOlderBuildSaysSo() {
        val raw = "when:   Sun Aug 30 02:26:57 GMT+12:00 2026\n" +
            "app:    10.6.1-staging (382) · com.noop.whoop.staging\n" +
            "java.lang.IllegalStateException: Room cannot verify the data integrity."
        val section = LogExport.crashSection(raw, runningVersionCode = 534)
        assertTrue("the note must name the crash's own build", section.contains("from build 382"))
        assertTrue("and the build that wrote the log", section.contains("(534)"))
        assertTrue("above the record, not after it",
            section.indexOf("NOTE:") < section.indexOf("java.lang.IllegalStateException"))
    }

    /** A crash from the running build is the alarming kind, and must NOT be softened by a note. */
    @Test fun aCrashFromThisBuildGetsNoNote() {
        val raw = "when:   now\napp:    11.8.0-staging (534) · com.noop.whoop.staging\nboom"
        val section = LogExport.crashSection(raw, runningVersionCode = 534)
        assertFalse("a crash from this very build must read as current", section.contains("NOTE:"))
    }

    /** An unreadable record is left alone: a wrong build number would be worse than none. */
    @Test fun aRecordWithNoAppLineIsNotGuessedAt() {
        val raw = "when:   now\nboom with no app line"
        assertEquals(null, LogExport.crashVersionCode(raw))
        assertFalse(LogExport.crashSection(raw, runningVersionCode = 534).contains("NOTE:"))
    }

    /** The version code is the one in parentheses on the `app:` line, not any other number near it. */
    @Test fun theVersionCodeComesFromTheAppLine() {
        val raw = "when:   Sun Aug 30 02:26:57 GMT+12:00 2026\n" +
            "app:    10.6.1-staging (382) · com.noop.whoop.staging\n" +
            "os:     Android 16 (API 36)"
        assertEquals(382, LogExport.crashVersionCode(raw))
    }
}
