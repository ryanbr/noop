package com.noop.analytics

import com.noop.analytics.PersonalRecords.Day
import com.noop.analytics.PersonalRecordMetric as Metric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirrors StrandAnalyticsTests/PersonalRecordsTests.swift - same fixtures, same expected outputs. */
class PersonalRecordsTest {

    private val today = "2026-10-20"

    /** `n` consecutive days ending at [end], HRV from [hrv] by index. */
    private fun daysRun(n: Int, end: String, hrv: (Int) -> Double?): List<Day> {
        val endEpoch = Baselines.isoEpochDay(end)!!
        return (0 until n).map { i -> Day(day = keyFor(endEpoch - (n - 1) + i), hrvMs = hrv(i)) }
    }

    private fun keyFor(epoch: Int): String = java.time.LocalDate.ofEpochDay(epoch.toLong()).toString()

    private fun record(days: List<Day>, metric: Metric, today: String = this.today) =
        PersonalRecords.records(days, today).firstOrNull { it.metric == metric }

    @Test fun emptyHistoryHasNoRecords() = assertEquals(emptyList<PersonalRecords.Record>(), PersonalRecords.records(emptyList(), today))

    @Test fun highestHrvWinsAndKeepsPreviousBest() {
        val r = record(daysRun(5, "2026-10-01") { listOf(40.0, 55.0, 50.0, 70.0, 60.0)[it] }, Metric.HRV)!!
        assertEquals(70.0, r.value, 0.0)
        assertEquals("2026-09-30", r.day)
        assertEquals(55.0, r.previousBest!!, 0.0)
        assertEquals(5, r.samples)
        assertFalse(r.isNew)
    }

    @Test fun restingHrLowerIsBetter() {
        val days = listOf(
            Day("2026-10-01", restingHr = 52.0),
            Day("2026-10-02", restingHr = 47.0),
            Day("2026-10-03", restingHr = 49.0),
        )
        val r = record(days, Metric.RESTING_HR)!!
        assertEquals(47.0, r.value, 0.0)
        assertEquals("2026-10-02", r.day)
        assertEquals(52.0, r.previousBest!!, 0.0)
    }

    @Test fun tieKeepsEarliestDay() {
        val r = record(daysRun(3, "2026-10-01") { 60.0 }, Metric.HRV)!!
        assertEquals("2026-09-29", r.day)
        assertNull(r.previousBest)
    }

    @Test fun implausibleValuesAreIgnored() {
        val days = listOf(
            Day("2026-10-01", hrvMs = 400.0, sleepMin = 12.0, restingHr = 10.0),
            Day("2026-10-02", hrvMs = 65.0, sleepMin = 480.0, restingHr = 50.0),
        )
        assertEquals(65.0, record(days, Metric.HRV)!!.value, 0.0)
        assertEquals(480.0, record(days, Metric.SLEEP)!!.value, 0.0)
        assertEquals(50.0, record(days, Metric.RESTING_HR)!!.value, 0.0)
        assertEquals(1, record(days, Metric.HRV)!!.samples)
    }

    @Test fun efficiencyPercentReadsAsFraction() {
        val days = listOf(Day("2026-10-01", efficiency = 91.0), Day("2026-10-02", efficiency = 0.88))
        assertEquals(0.91, record(days, Metric.EFFICIENCY)!!.value, 1e-12)
    }

    @Test fun unorderedInputAndBadKeys() {
        val days = listOf(
            Day("2026-10-03", hrvMs = 50.0),
            Day("not-a-day", hrvMs = 99.0),
            Day("2026-10-01", hrvMs = 50.0),
            Day("2026-10-02", hrvMs = 45.0),
        )
        val r = record(days, Metric.HRV)!!
        assertEquals("2026-10-01", r.day)
        assertEquals(3, r.samples)
    }

    @Test fun newRecordNeedsRecentDayAndEnoughHistory() {
        // 20 days ending today, best on the last day: 19 prior values >= 14 -> new.
        val r = record(daysRun(20, today) { if (it == 19) 90.0 else 50.0 + it }, Metric.HRV)!!
        assertEquals(today, r.day)
        assertTrue(r.isNew)
        assertEquals(68.0, r.previousBest!!, 0.0)
    }

    @Test fun recordInFirstWeeksIsNotNew() {
        val r = record(daysRun(10, today) { 50.0 + it }, Metric.HRV)!!
        assertEquals(today, r.day)
        assertFalse(r.isNew)
    }

    @Test fun newWindowIsSevenDaysInclusive() {
        // Best set 6 days before today -> new; 7 days before -> not new.
        val six = record(daysRun(20, "2026-10-14") { if (it == 19) 90.0 else 50.0 }, Metric.HRV)!!
        assertTrue(six.isNew)
        val seven = record(daysRun(20, "2026-10-13") { if (it == 19) 90.0 else 50.0 }, Metric.HRV)!!
        assertFalse(seven.isNew)
    }

    @Test fun futureDayIsNeverNew() {
        val r = record(daysRun(20, "2026-10-22") { if (it == 19) 90.0 else 50.0 }, Metric.HRV)!!
        assertFalse(r.isNew)
    }

    @Test fun unparseableTodayMarksNothingNew() {
        val r = record(daysRun(20, today) { if (it == 19) 90.0 else 50.0 }, Metric.HRV, today = "bad")!!
        assertFalse(r.isNew)
    }

    @Test fun metricsWithoutValuesAreOmittedAndOrderIsStable() {
        val days = listOf(Day("2026-10-01", steps = 12_000.0, strain = 14.2, hrvMs = 61.0))
        assertEquals(
            listOf(Metric.HRV, Metric.STRAIN, Metric.STEPS),
            PersonalRecords.records(days, today).map { it.metric },
        )
    }
}
