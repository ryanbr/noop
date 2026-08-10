package com.noop.ingest

import com.noop.analytics.LabMarkerCategory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for the WHOOP biomarker export parser (#1220). Synthetic fixture with the same
 * structural quirks as a real export (quoted names with commas, packed value+unit, thousands
 * separators, "--"/"No Data Available" rows, US M/D/YY dates). Mirrors the Swift
 * WhoopBiomarkerExportParserTests fixture-for-fixture so the twins stay byte-identical.
 */
class WhoopBiomarkerExportParserTest {

    // A synthetic export (values invented) mirroring the real header + row shapes from the issue.
    private val fixture = """
        "Biomarker Name",Value,Status,"Recorded On Date"
        "1,5-Anhydroglucitol (1,5-AG)",--,"No Data Available",--
        Ferritin,"1,050 ng/mL",Optimal,7/2/26
        "Vitamin D","72 nmol/L",Sufficient,7/2/26
        LDL,"3.1 mmol/L","Out of Range",1/23/26
        Basophils,"70 cells/uL",Optimal,1/23/26
    """.trimIndent()

    // MARK: - Detection

    @Test fun matchesOnlyTheWhoopSignature() {
        assertTrue(WhoopBiomarkerExportParser.matches(fixture))
        // The generic (date,marker,value,unit) shape must NOT route to the vendor parser.
        assertFalse(WhoopBiomarkerExportParser.matches("date,marker,value,unit\n2026-05-01,ldl,3.1,mmol/L"))
        // A near-miss missing the Status column is not a WHOOP export.
        assertFalse(WhoopBiomarkerExportParser.matches("\"Biomarker Name\",Value,\"Recorded On Date\"\nFerritin,80,7/2/26"))
    }

    // MARK: - Happy path

    @Test fun parsesReadingsCountsNotMeasuredSeparately() {
        val result = WhoopBiomarkerExportParser.parse(fixture)
        assertEquals(4, result.importedReadings)   // ferritin, vitamin_d, ldl, basophils
        assertEquals(1, result.notMeasured)         // the "--" / "No Data Available" anhydroglucitol row
        assertEquals(0, result.skippedRows)         // nothing malformed
        assertEquals(4, result.distinctMarkers)
        assertEquals("2026-01-23", result.earliestDay)
        assertEquals("2026-07-02", result.latestDay)
        assertFalse(result.truncated)
        assertFalse(result.fileTooLarge)
        assertEquals(listOf("custom_basophils"), result.customMarkerKeys)
    }

    @Test fun keepsPackedUnitAndThousandsSeparator() {
        val rows = WhoopBiomarkerExportParser.parse(fixture).rows
        val ferritin = rows.first { it.markerKey == "ferritin" }
        assertEquals(1050.0, ferritin.value, 1e-9)       // "1,050" thousands separator stripped
        assertEquals("ng/mL", ferritin.unit)             // unit split out of the packed cell, verbatim
        assertEquals(LabMarkerCategory.BLOOD_PANEL, ferritin.category)
        assertFalse(ferritin.isCustomMarker)
        assertEquals("2026-07-02", ferritin.day)         // US M/D/YY (2-digit year) → ISO
    }

    @Test fun carriesStatusVerbatimIntoNoteAttributed() {
        val rows = WhoopBiomarkerExportParser.parse(fixture).rows
        assertEquals("WHOOP: Optimal", rows.first { it.markerKey == "ferritin" }.note)
        assertEquals("WHOOP: Sufficient", rows.first { it.markerKey == "vitamin_d" }.note)
        // A verdict is carried verbatim + attributed — NOOP never asserts it itself.
        assertEquals("WHOOP: Out of Range", rows.first { it.markerKey == "ldl" }.note)
    }

    @Test fun unknownMarkerBecomesCustomWithItsUnit() {
        val baso = WhoopBiomarkerExportParser.parse(fixture).rows.first { it.markerKey == "custom_basophils" }
        assertTrue(baso.isCustomMarker)
        assertEquals(LabMarkerCategory.OTHER, baso.category)
        assertEquals(70.0, baso.value, 1e-9)
        assertEquals("cells/uL", baso.unit)
        assertEquals("WHOOP: Optimal", baso.note)
    }

    // MARK: - Cell-level rules

    @Test fun isNoDataMatchesBothSentinels() {
        assertTrue(WhoopBiomarkerExportParser.isNoData("--"))
        assertTrue(WhoopBiomarkerExportParser.isNoData("No Data Available"))
        assertTrue(WhoopBiomarkerExportParser.isNoData("  no data available  "))
        assertFalse(WhoopBiomarkerExportParser.isNoData("Optimal"))
        assertFalse(WhoopBiomarkerExportParser.isNoData("70 cells/uL"))
    }

    @Test fun splitValueUnitHandlesPackedAndBare() {
        assertEquals(70.0 to "cells/uL", WhoopBiomarkerExportParser.splitValueUnit("70 cells/uL"))
        assertEquals(3490.0 to "cells/uL", WhoopBiomarkerExportParser.splitValueUnit("3,490 cells/uL"))
        assertEquals(33.0 to "U/L", WhoopBiomarkerExportParser.splitValueUnit("33 U/L"))
        assertEquals(70.0 to "", WhoopBiomarkerExportParser.splitValueUnit("70"))
        assertNull(WhoopBiomarkerExportParser.splitValueUnit("--"))
        assertNull(WhoopBiomarkerExportParser.splitValueUnit("negative"))
    }

    @Test fun whoopDayAcceptsTwoDigitUsDates() {
        assertEquals("2026-07-02", WhoopBiomarkerExportParser.whoopDay("7/2/26"))
        assertEquals("2026-01-23", WhoopBiomarkerExportParser.whoopDay("1/23/26"))
        assertEquals("2026-12-31", WhoopBiomarkerExportParser.whoopDay("12/31/26"))
        assertEquals("2026-06-15", WhoopBiomarkerExportParser.whoopDay("2026-06-15"))  // ISO still ok
        assertNull(WhoopBiomarkerExportParser.whoopDay("13/2/26"))   // month 13 is not a valid US date
        assertNull(WhoopBiomarkerExportParser.whoopDay("--"))
    }
}
