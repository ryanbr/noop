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
}
