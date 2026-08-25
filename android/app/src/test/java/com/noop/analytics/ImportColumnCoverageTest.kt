package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Pins the import column-coverage line. Swift twin: `ImportColumnCoverageTests`. The two must emit
 * byte-identical strings, so the expectations are written out in full.
 */
class ImportColumnCoverageTest {

    @Test
    fun `calls out the absent column`() {
        assertEquals(
            "import columns stage=cycles rows=58 recovery=58 rhr=58 hrv=58 skin_temp=58 spo2=0 strain=58" +
                " — ABSENT: spo2",
            ImportTrace.columnCoverageLine(
                "cycles", 58,
                listOf(
                    "recovery" to 58, "rhr" to 58, "hrv" to 58, "skin_temp" to 58,
                    "spo2" to 0, "strain" to 58,
                ),
            ),
        )
    }

    @Test
    fun `healthy import has no absent clause`() {
        assertEquals(
            "import columns stage=cycles rows=2 recovery=2 spo2=2",
            ImportTrace.columnCoverageLine("cycles", 2, listOf("recovery" to 2, "spo2" to 2)),
        )
    }

    @Test
    fun `every absent column is listed in parser order`() {
        assertEquals(
            "import columns stage=cycles rows=9 spo2=0 recovery=9 skin_temp=0 — ABSENT: spo2, skin_temp",
            ImportTrace.columnCoverageLine(
                "cycles", 9, listOf("spo2" to 0, "recovery" to 9, "skin_temp" to 0),
            ),
        )
    }

    @Test
    fun `a partially populated column is not absent`() {
        // 1-of-58 is a real signal (a sparse column), and materially different from "never present".
        val line = ImportTrace.columnCoverageLine("cycles", 58, listOf("spo2" to 1))
        assertEquals("import columns stage=cycles rows=58 spo2=1", line)
        assertFalse(line.contains("ABSENT"))
    }

    @Test
    fun `the label order is the cross-platform contract`() {
        // The order is part of the emitted string. If this changes, the Swift twin must change with it, in
        // the same position — the two lines would otherwise silently stop matching.
        assertEquals(
            listOf("recovery", "rhr", "hrv", "skin_temp", "spo2", "strain", "resp"),
            com.noop.ingest.IMPORT_COLUMN_LABELS,
        )
    }

    @Test
    fun `coverage emits the labels in contract order`() {
        assertEquals(
            com.noop.ingest.IMPORT_COLUMN_LABELS,
            com.noop.ingest.importColumnCoverage(emptyList()).map { it.first },
        )
    }

    @Test
    fun `an empty counts list does not trail a space`() {
        // Unreachable through the app today, but the formatter is shared and a trailing space would
        // survive into anything that later parses these logs.
        assertEquals(
            "import columns stage=cycles rows=0",
            ImportTrace.columnCoverageLine("cycles", 0, emptyList()),
        )
    }
}
