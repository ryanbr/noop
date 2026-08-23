package com.noop.ingest

import androidx.health.connect.client.records.Vo2MaxRecord
import com.noop.data.MetricSeriesRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * #1525: NOOP computes VO2 max weekly and persists it as the `vo2max_est` series, but nothing exported it
 * to Health Connect. Pins the mapping from those rows to records — the part that decides what a downstream
 * app like Google Health actually sees.
 */
class HealthConnectVo2MaxExportTest {

    private val zone: ZoneId = ZoneId.of("UTC")
    private val version = 1_700_000_000L

    private fun row(day: String, value: Double) =
        MetricSeriesRow(deviceId = "my-whoop-noop", day = day, key = "vo2max_est", value = value)

    private fun build(vararg rows: MetricSeriesRow) =
        HealthConnectWriter.buildVo2MaxRecords(rows.toList(), version, zone)

    /** The value reaches the wire unrounded, in the units the record names. */
    @Test
    fun carriesTheStoredValueInMlPerMinPerKg() {
        val r = build(row("2026-08-22", 47.3)).single() as Vo2MaxRecord
        assertEquals(47.3, r.vo2MillilitersPerMinuteKilogram, 1e-9)
    }

    /**
     * A stored 0 means the estimator declined that week. Exporting it would publish "VO2 max: 0" as a
     * fitness reading, which is worse than exporting nothing — the same honesty rule that keeps raw
     * red/IR counts from being written as SpO2.
     */
    @Test
    fun refusesZeroAndNegativeRatherThanPublishingThemAsAReading() {
        assertTrue(build(row("2026-08-22", 0.0)).isEmpty())
        assertTrue(build(row("2026-08-22", -1.0)).isEmpty())
    }

    /** An unparseable day is skipped without taking the rest of the batch with it. */
    @Test
    fun oneBadDayDoesNotDropTheGoodOnes() {
        val out = build(row("not-a-date", 44.0), row("2026-08-22", 44.0))
        assertEquals(1, out.size)
    }

    /**
     * Local noon on the series' own day, matching the daily records. The series is keyed to the week's
     * Saturday, so this is what pins a weekly value to a real instant rather than to "now".
     */
    @Test
    fun stampsLocalNoonOnTheSeriesDay() {
        val r = build(row("2026-08-22", 44.0)).single() as Vo2MaxRecord
        val expected = LocalDate.parse("2026-08-22").atTime(LocalTime.NOON).atZone(zone).toInstant()
        assertEquals(expected, r.time)
    }

    /**
     * OTHER, not HEART_RATE_RATIO: the stored value is whichever estimator ran — Nes when a waist is set,
     * the Uth HR-ratio formula otherwise — and the row does not record which, so the narrower label would
     * be true of only one of them.
     */
    @Test
    fun declaresTheGeneralMeasurementMethod() {
        val r = build(row("2026-08-22", 44.0)).single() as Vo2MaxRecord
        assertEquals(Vo2MaxRecord.MEASUREMENT_METHOD_OTHER, r.measurementMethod)
    }

    /** Keyed by day, so a re-export upserts the same week rather than duplicating it. */
    @Test
    fun keysTheRecordByDaySoReExportsUpsert() {
        val r = build(row("2026-08-22", 44.0)).single()
        assertEquals("noop-vo2max-2026-08-22", r.metadata.clientRecordId)
        assertEquals(version, r.metadata.clientRecordVersion)
    }
}
