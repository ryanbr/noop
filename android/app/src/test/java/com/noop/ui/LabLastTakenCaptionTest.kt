package com.noop.ui

import com.noop.data.LabMarkerRow
import com.noop.inEachTimeZone
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A CSV import's `takenAt` is UTC noon, which is the next day from UTC+12. The Lab Book "last taken"
 * caption names the stored day in every zone, as the history list does. Pins the default zone so a UTC
 * runner catches it too. Twin of Swift `LabBookFormatTests.testLastTakenNamesTheStoredDayInEveryZone`.
 */
class LabLastTakenCaptionTest {

    private val row = LabMarkerRow(
        id = "ldl-1", deviceId = "d", markerKey = "ldl", category = "blood_panel",
        day = "2026-08-25", takenAt = 1_787_659_200L, // 2026-08-25T12:00:00Z
        value = 3.1, unit = "mmol/L", source = "csv",
    )

    @Test fun namesTheStoredDayInEveryZone() {
        inEachTimeZone(listOf("Pacific/Honolulu", "UTC", "Pacific/Auckland", "Pacific/Kiritimati")) { zone ->
            assertEquals(zone, "last taken 25 Aug 2026", lastTakenCaption(row))
        }
    }

    @Test fun noRowSaysSo() {
        assertEquals("no readings yet", lastTakenCaption(null))
    }
}
