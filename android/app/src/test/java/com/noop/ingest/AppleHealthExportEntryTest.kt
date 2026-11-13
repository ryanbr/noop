package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins which zip entry the Apple Health importer treats as the main `HealthData` document.
 *
 * A non-English iPhone names that file in the device language (`apple_health_export/导出.xml` on a
 * Chinese system) while the sibling `export_cda.xml` keeps its English name, so a check for
 * `export.xml` alone rejected every localised export.
 *
 * Twin: `ImportCoordinatorTests.testMainExportEntryRule` in `Packages/StrandImport` asserts the same
 * table against `AppleHealthExportLocator.isMainExportEntry`.
 */
class AppleHealthExportEntryTest {

    @Test
    fun mainExportEntryRule() {
        val cases = listOf(
            "export.xml" to true,
            "apple_health_export/export.xml" to true,
            "deep/nested/EXPORT.XML" to true,
            "apple_health_export/导出.xml" to true,
            "apple_health_export/экспорт.xml" to true,
            "Apple_Health_Export\\エクスポート.xml" to true,
            "apple_health_export/export_cda.xml" to false,
            "apple_health_export/导出_cda.xml" to false,
            "导出.xml" to false,
            "other/导出.xml" to false,
            "apple_health_export/workout-routes/route_1.gpx" to false,
            "apple_health_export/electrocardiograms/ecg_1.csv" to false,
            "apple_health_export/" to false,
            "" to false,
        )
        for ((path, expected) in cases) {
            assertEquals(path, expected, AppleHealthImporter.isMainExportEntry(path))
        }
    }
}
