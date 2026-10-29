package com.noop.analytics

import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SleepRecalculationWindowTest {
    @Test fun savedManualWindowWinsOverDetectedOnsetWithAnotherKey() {
        val window = SleepRecalculationWindow.make("2021-06-15", ZoneId.of("UTC"), 1_800_000_000)!!
        val start = window.start - 3600
        val end = window.start + 6 * 3600
        val bed = window.start + 3600
        val wake = bed + 7200
        val manual = com.noop.data.SleepSession("fixture-noop", start - 30, wake,
            efficiency = 1.0, restingHr = 50, avgHrv = 10.0,
            stagesJSON = "[{\"start\":$bed,\"end\":$wake,\"stage\":\"deep\"}]",
            userEdited = true, startTsAdjusted = bed)
        val result = AnalyticsEngine.analyzeDay(window.day,
            hr = (start until end).map { com.noop.data.HrSample("fixture", it, 50) },
            gravity = (start until end).map { com.noop.data.GravitySample("fixture", it, 0.0, 0.0, 1.0) },
            profile = UserProfile(), sleepDayWindow = window, preservedSleep = listOf(manual))
        assertEquals(120.0, result.daily.totalSleepMin!!, 0.0)
        assertEquals(1, result.sleepSessions.size)
        assertEquals(bed, result.sleepSessions.first().start)
        assertEquals(wake, result.sleepSessions.first().end)
    }

    // Verbatim stdout from the production Swift window compiled standalone, including DST and a skipped date.
    @Test fun calendarWindowsMatchSwiftOracle() {
        val actual = listOf("UTC", "America/Chicago", "Asia/Kolkata", "Australia/Lord_Howe", "Pacific/Apia")
            .flatMap { zone ->
                listOf("2021-06-15", "2026-03-08", "2026-11-01", "2026-04-05", "2011-12-30").map { day ->
                    val w = SleepRecalculationWindow.make(day, ZoneId.of(zone), 1_800_000_000)
                    if (w == null) "$zone|$day|invalid"
                    else "$zone|$day|${w.start}|${w.end}|${w.offsetSeconds}|${w.readStart}"
                }
            }.joinToString("\n")
        val expected = """
            UTC|2021-06-15|1623715200|1623801600|0|1623607200
            UTC|2026-03-08|1772928000|1773014400|0|1772820000
            UTC|2026-11-01|1793491200|1793577600|0|1793383200
            UTC|2026-04-05|1775347200|1775433600|0|1775239200
            UTC|2011-12-30|1325203200|1325289600|0|1325095200
            America/Chicago|2021-06-15|1623733200|1623819600|-18000|1623625200
            America/Chicago|2026-03-08|1772949600|1773032400|-21600|1772841600
            America/Chicago|2026-11-01|1793509200|1793599200|-18000|1793401200
            America/Chicago|2026-04-05|1775365200|1775451600|-18000|1775257200
            America/Chicago|2011-12-30|1325224800|1325311200|-21600|1325116800
            Asia/Kolkata|2021-06-15|1623695400|1623781800|19800|1623587400
            Asia/Kolkata|2026-03-08|1772908200|1772994600|19800|1772800200
            Asia/Kolkata|2026-11-01|1793471400|1793557800|19800|1793363400
            Asia/Kolkata|2026-04-05|1775327400|1775413800|19800|1775219400
            Asia/Kolkata|2011-12-30|1325183400|1325269800|19800|1325075400
            Australia/Lord_Howe|2021-06-15|1623677400|1623763800|37800|1623569400
            Australia/Lord_Howe|2026-03-08|1772888400|1772974800|39600|1772780400
            Australia/Lord_Howe|2026-11-01|1793451600|1793538000|39600|1793343600
            Australia/Lord_Howe|2026-04-05|1775307600|1775395800|39600|1775199600
            Australia/Lord_Howe|2011-12-30|1325163600|1325250000|39600|1325055600
            Pacific/Apia|2021-06-15|1623668400|1623754800|46800|1623560400
            Pacific/Apia|2026-03-08|1772881200|1772967600|46800|1772773200
            Pacific/Apia|2026-11-01|1793444400|1793530800|46800|1793336400
            Pacific/Apia|2026-04-05|1775300400|1775386800|46800|1775192400
            Pacific/Apia|2011-12-30|invalid
        """.trimIndent()
        assertEquals(expected, actual)
    }

    @Test fun unfinishedAndInvalidDayNeverRollForward() {
        for (day in listOf("2026-02-30", "2026-13-01", "2026-1-01", "not-a-day")) {
            assertNull(SleepRecalculationWindow.make(day, ZoneId.of("UTC"), 1_800_000_000))
        }
        val w = SleepRecalculationWindow.make("2021-06-15", ZoneId.of("UTC"), 1_800_000_000)!!
        assertNull(SleepRecalculationWindow.make(w.day, ZoneId.of("UTC"), w.end - 1))
    }
}
