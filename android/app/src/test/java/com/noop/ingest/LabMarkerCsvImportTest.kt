package com.noop.ingest

import com.noop.analytics.LabMarkerCategory
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for the pure Lab Book markers CSV parse. Mirrors the Swift
 * LabMarkerCsvImportTests fixture-for-fixture so the twins stay byte-identical.
 */
class LabMarkerCsvImportTest {

    // MARK: - Happy path (the promised date, marker, value, unit shape)

    @Test fun happyPathMapsCatalogMarkers() {
        val csv = """
            date,marker,value,unit
            2026-05-01,ldl,3.1,mmol/L
            2026-05-01,Ferritin,80,µg/L
            2026-05-02,Vitamin D,72,nmol/L
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)

        assertEquals(3, result.importedReadings)
        assertEquals(0, result.skippedRows)
        assertEquals(3, result.distinctMarkers)
        assertEquals("2026-05-01", result.earliestDay)
        assertEquals("2026-05-02", result.latestDay)
        assertFalse(result.truncated)
        assertFalse(result.fileTooLarge)
        assertTrue(result.customMarkerKeys.isEmpty())

        val ldl = result.rows.first { it.markerKey == "ldl" }
        assertEquals(LabMarkerCategory.BLOOD_PANEL, ldl.category)
        assertEquals(3.1, ldl.value, 1e-9)
        assertEquals("mmol/L", ldl.unit)
        assertFalse(ldl.isCustomMarker)

        // Display-name matching ("Ferritin", "Vitamin D") folds onto catalog keys.
        assertTrue(result.rows.any { it.markerKey == "ferritin" && it.value == 80.0 })
        assertTrue(result.rows.any { it.markerKey == "vitamin_d" && it.value == 72.0 })
    }

    // MARK: - Header variants

    @Test fun headerVariantsResolve() {
        val csv = """
            Day,Test,Result,Units
            2026-05-01,LDL cholesterol,3.4,mmol/L
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(1, result.importedReadings)
        assertEquals("ldl", result.rows[0].markerKey)
        assertEquals(3.4, result.rows[0].value, 1e-9)
    }

    @Test fun semicolonDelimitedEuropeanFileWithDecimalCommas() {
        // A European spreadsheet export: ';' delimiter (CsvTable sniffs it) and a
        // decimal COMMA in the value. "5,2" must read as 5.2, never 52.
        val csv = """
            date;marker;value;unit
            2026-05-01;fasting glucose;5,2;mmol/L
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(1, result.importedReadings)
        assertEquals("fasting_glucose", result.rows[0].markerKey)
        assertEquals(5.2, result.rows[0].value, 1e-9)
    }

    @Test fun missingUnitColumnFallsBackToCatalogUnit() {
        val csv = """
            date,marker,value
            2026-05-01,ldl,3.1
            2026-05-01,My Own Marker,42
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals("mmol/L", result.rows.first { it.markerKey == "ldl" }.unit)
        // Custom markers have no catalog unit — empty, never invented.
        assertEquals("", result.rows.first { it.isCustomMarker }.unit)
    }

    // MARK: - No silent unit conversion (the non-clinical contract)

    @Test fun unitIsStoredVerbatimNeverConverted() {
        val csv = """
            date,marker,value,unit
            2026-05-01,ldl,120,mg/dL
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(120.0, result.rows[0].value, 1e-9)   // NOT divided by 38.67
        assertEquals("mg/dL", result.rows[0].unit)         // exactly as written
    }

    // MARK: - Custom marker fallback (same key the manual editor mints)

    @Test fun unknownMarkerImportsAsCustom() {
        val csv = """
            date,marker,value,unit
            2026-05-01,Magnesium,0.84,mmol/L
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(1, result.importedReadings)
        val row = result.rows[0]
        assertEquals("custom_magnesium", row.markerKey)    // MarkerUnits.slug parity
        assertEquals(LabMarkerCategory.OTHER, row.category)
        assertTrue(row.isCustomMarker)
        assertEquals(listOf("custom_magnesium"), result.customMarkerKeys)
    }

    @Test fun customMarkerKeyCanonicalizesNfcAndNfdBeforeSlugging() {
        val expected = byteArrayOf(
            0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x5f, 0x63, 0x61, 0x66,
            0xc3.toByte(), 0xa9.toByte(), 0x5f, 0x6d, 0x61, 0x72, 0x6b, 0x65, 0x72,
        )
        assertArrayEquals(expected, LabMarkerCsvImport.customKey("Caf\u00e9 Marker").toByteArray())
        assertArrayEquals(expected, LabMarkerCsvImport.customKey("Cafe\u0301 Marker").toByteArray())
        assertEquals("custom_apo_b", LabMarkerCsvImport.customKey("Apo B"))
    }

    @Test fun canonicalEquivalentCustomMarkerRowsShareKeyAndLastRowWins() {
        val nfc = "Caf\u00e9 Marker"
        val nfd = "Cafe\u0301 Marker"
        val csv = """
            date,marker,value,unit
            2026-05-01,$nfc,1,mg/L
            2026-05-01,$nfd,2,mg/L
        """.trimIndent()
        val expected = byteArrayOf(
            0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x5f, 0x63, 0x61, 0x66,
            0xc3.toByte(), 0xa9.toByte(), 0x5f, 0x6d, 0x61, 0x72, 0x6b, 0x65, 0x72,
        )
        val result = LabMarkerCsvImport.parse(csv)

        assertEquals(1, result.importedReadings)
        assertEquals(1, result.distinctMarkers)
        assertEquals(1, result.rows.size)
        assertEquals(2.0, result.rows[0].value, 1e-9)
        assertArrayEquals(expected, result.rows[0].markerKey.toByteArray())
        assertEquals(1, result.customMarkerKeys.size)
        assertArrayEquals(expected, result.customMarkerKeys[0].toByteArray())
    }

    // MARK: - Blood pressure pairs (diastolic must never be dropped)

    @Test fun combinedBloodPressureSplitsIntoPair() {
        val csv = """
            date,marker,value,unit
            2026-05-01,Blood pressure,120/80,mmHg
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(2, result.importedReadings)
        val sys = result.rows.first { it.markerKey == "bp_systolic" }
        val dia = result.rows.first { it.markerKey == "bp_diastolic" }
        assertEquals(120.0, sys.value, 1e-9)
        assertEquals(80.0, dia.value, 1e-9)
        assertEquals(LabMarkerCategory.BLOOD_PRESSURE, sys.category)
        assertEquals("mmHg", sys.unit)
    }

    @Test fun explicitSystolicDiastolicRowsMap() {
        val csv = """
            date,marker,value,unit
            2026-05-01,Systolic,118,mmHg
            2026-05-01,Diastolic,76,mmHg
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(2, result.importedReadings)
        assertTrue(result.rows.any { it.markerKey == "bp_systolic" && it.value == 118.0 })
        assertTrue(result.rows.any { it.markerKey == "bp_diastolic" && it.value == 76.0 })
    }

    @Test fun combinedBpNameWithoutPairValueIsSkippedNotGuessed() {
        // "BP, 120" — there is no single marker to land a combined name on. Skip + count.
        val csv = """
            date,marker,value,unit
            2026-05-01,BP,120,mmHg
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(0, result.importedReadings)
        assertEquals(1, result.skippedRows)
    }

    // MARK: - Bad rows are reported, never fatal

    @Test fun badRowsAreSkippedAndCounted() {
        val csv = """
            date,marker,value,unit
            not-a-date,ldl,3.1,mmol/L
            2026-05-01,,3.1,mmol/L
            2026-05-01,ldl,positive,mmol/L
            2026-05-01,ldl,,mmol/L
            2026-05-02,ldl,3.0,mmol/L
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(1, result.importedReadings)   // the one good row still lands
        assertEquals(4, result.skippedRows)
        assertEquals("2026-05-02", result.rows[0].day)
    }

    @Test fun valueWithTrailingUnitTextParses() {
        val csv = """
            date,marker,value
            2026-05-01,ldl,3.2 mmol/L
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(3.2, result.rows[0].value, 1e-9)
    }

    // MARK: - Duplicate same-day rows: last write wins (projection parity)

    @Test fun duplicateSameDayLastRowWins() {
        val csv = """
            date,marker,value,unit
            2026-05-01,ldl,3.1,mmol/L
            2026-05-01,ldl,3.4,mmol/L
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(1, result.importedReadings)
        assertEquals(3.4, result.rows[0].value, 1e-9)   // the later row won
    }

    // MARK: - Date variants

    @Test fun dateVariants() {
        val csv = """
            date,marker,value
            2026-05-01 08:30,ldl,3.1
            15/01/2026,hdl,1.4
            01/15/2026,triglycerides,1.1
            2026/6/1,crp,2.0
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(0, result.skippedRows)
        assertEquals("2026-05-01", result.rows.first { it.markerKey == "ldl" }.day)
        // 15 > 12 forces day-first.
        assertEquals("2026-01-15", result.rows.first { it.markerKey == "hdl" }.day)
        // Ambiguous 01/15 defaults to US month-first.
        assertEquals("2026-01-15", result.rows.first { it.markerKey == "triglycerides" }.day)
        assertEquals("2026-06-01", result.rows.first { it.markerKey == "crp" }.day)
    }

    @Test fun impossibleCalendarDatesAreRejected() {
        val csv = """
            date,marker,value
            2026-02-29,ldl,3.1
            2026-13-01,hdl,1.4
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(0, result.importedReadings)
        assertEquals(2, result.skippedRows)
    }

    // MARK: - Import-DoS bounds

    @Test fun rowCapTruncatesAndReports() {
        val csv = buildString {
            append("date,marker,value\n")
            for (i in 0 until 10) append("2026-05-0${i % 9 + 1},ldl,3.$i\n")
        }
        val result = LabMarkerCsvImport.parse(CsvTable.fromText(csv), maxRows = 4)
        assertTrue(result.truncated)
        assertEquals(6, result.skippedRows)         // the unread tail is reported
        assertTrue(result.importedReadings <= 4)
    }

    @Test fun oversizeFileIsRejectedOutright() {
        val oversize = ByteArray((LabMarkerCsvImport.MAX_BYTES + 1).toInt())
        val result = LabMarkerCsvImport.parse(oversize)
        assertTrue(result.fileTooLarge)
        assertEquals(0, result.importedReadings)
    }

    // MARK: - Empty / garbage input

    @Test fun emptyAndHeaderlessInput() {
        assertEquals(0, LabMarkerCsvImport.parse("").importedReadings)
        val garbage = LabMarkerCsvImport.parse("this is not\na csv at all")
        assertEquals(0, garbage.importedReadings)
        assertEquals(1, garbage.skippedRows)        // the one data line, reported
    }

    // MARK: - Helper grammar pins (byte-identical to the Swift twin)

    @Test fun parseValueGrammar() {
        assertEquals(3.1, LabMarkerCsvImport.parseValue("3.1")!!, 1e-9)
        assertEquals(5.2, LabMarkerCsvImport.parseValue("5,2")!!, 1e-9)     // decimal comma
        assertEquals(1234.0, LabMarkerCsvImport.parseValue("1,234")!!, 1e-9) // thousands group
        assertEquals(62.0, LabMarkerCsvImport.parseValue("62 ms")!!, 1e-9)  // stray unit
        assertNull(LabMarkerCsvImport.parseValue("120/80"))                  // pairs never parse here
        assertNull(LabMarkerCsvImport.parseValue("negative"))
        assertNull(LabMarkerCsvImport.parseValue(""))
    }

    /** Adversarial value grammar (the CSV-import edge finding), byte-identical to the Swift twin. A
     *  zero-integer-part decimal comma with exactly 3 decimals is a DECIMAL comma, never a thousands
     *  group ("0,500" is 0.5, not 500); non-finite tokens (NaN/Infinity spellings, 1e999 overflow) and
     *  the Java-only "5f"/"5d" literals are REJECTED so nothing non-finite or platform-specific lands. */
    @Test fun parseValueRejectsThousandGroupForZeroLedDecimalComma() {
        assertEquals(0.5, LabMarkerCsvImport.parseValue("0,500")!!, 1e-9)   // was 500 (1000x too large)
        assertEquals(0.95, LabMarkerCsvImport.parseValue("0,95")!!, 1e-9)
        assertEquals(1500.0, LabMarkerCsvImport.parseValue("1,500")!!, 1e-9) // genuine thousands group stays
        assertEquals(12345.0, LabMarkerCsvImport.parseValue("12,345")!!, 1e-9) // non-zero-led = thousands
    }

    @Test fun parseValueRejectsNonFiniteAndJavaOnlyTokens() {
        assertNull(LabMarkerCsvImport.parseValue("nan"))
        assertNull(LabMarkerCsvImport.parseValue("NaN"))
        assertNull(LabMarkerCsvImport.parseValue("Infinity"))
        assertNull(LabMarkerCsvImport.parseValue("-Infinity"))
        assertNull(LabMarkerCsvImport.parseValue("1e999"))                   // overflows to +Inf
        assertNull(LabMarkerCsvImport.parseValue("5f"))                      // Java float literal, Swift rejects
        assertNull(LabMarkerCsvImport.parseValue("5d"))                      // Java double literal, Swift rejects
    }

    @Test fun customKeyMirrorsManualEditorSlug() {
        assertEquals("custom_magnesium", LabMarkerCsvImport.customKey("Magnesium"))
        assertEquals("custom_apo_b", LabMarkerCsvImport.customKey("Apo B"))
        assertEquals("", LabMarkerCsvImport.customKey("  ???  "))
    }

    /**
     * A white-cell differential lists each cell type as a count AND a percentage. Both used to
     * slug to `custom_lymph`, so on the same day the "%" row overwrote the count row.
     */
    @Test fun percentRowDoesNotOverwriteCountRow() {
        val csv = """
            date,marker,value,unit
            2026-05-01,LYMPH,1.9,10^9/L
            2026-05-01,LYMPH %,31.2,%
            2026-05-01,BASO,0.03,10^9/L
            2026-05-01,BASO %,0.5,%
        """.trimIndent()
        val result = LabMarkerCsvImport.parse(csv)
        assertEquals(4, result.importedReadings)
        assertEquals(
            listOf("custom_baso", "custom_baso_pct", "custom_lymph", "custom_lymph_pct"),
            result.customMarkerKeys,
        )
        assertEquals(1.9, result.rows.first { it.markerKey == "custom_lymph" }.value, 1e-9)
        assertEquals(31.2, result.rows.first { it.markerKey == "custom_lymph_pct" }.value, 1e-9)
    }

    /**
     * Expected literals are the verbatim stdout of Swift `LabMarkerCsvImport.customKey` compiled
     * standalone over [names] (the Swift suite pins the same list). The Unicode numeric cases
     * guard the Android/Swift category boundary from #2351.
     */
    @Test fun customKeyIsPinned() {
        val names = listOf(
            "LYMPH", "LYMPH %", "LYMPH%", "Lymph (%)", "BASO", "BASO %", "% Neutrophils", "NEUT  %", "a%%b", "%", "Apo B", "Magnesium", "  ???  ", "A - B", "Vitamin D (25-OH)", "Caf\u00e9 Marker", "Cafe\u0301 Marker", "MCHC g/dL", "HbA1c (IFCC)", "eGFR mL/min/1.73m²", "Factor Ⅻ", "Vitamin B₁₂", "①%", "½ dose", "³", "2", "𐄇",
        )
        val expected = listOf(
            "custom_lymph", "custom_lymph_pct", "custom_lymph_pct", "custom_lymph_pct", "custom_baso", "custom_baso_pct", "custom_pct_neutrophils", "custom_neut_pct", "custom_a_pctpct_b", "custom_pct", "custom_apo_b", "custom_magnesium", "", "custom_a__b", "custom_vitamin_d_25_oh", "custom_café_marker", "custom_café_marker", "custom_mchc_g_dl", "custom_hba1c_ifcc", "custom_egfr_ml_min_1_73m²", "custom_factor_ⅻ", "custom_vitamin_b₁₂", "custom_①_pct", "custom_½_dose", "custom_³", "custom_2", "custom_𐄇",
        )
        assertEquals(expected, names.map { LabMarkerCsvImport.customKey(it) })
    }
}
