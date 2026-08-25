package com.noop.ui

import com.noop.R
import com.noop.data.WhoopRepository
import java.time.LocalDate
import java.util.Locale
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The readings table under a series-backed vital detail (task #8). Pins the pure projection
 * [vitalReadingRows] the VitalDetailScreen table renders: rows and the "N readings" header derive from the
 * SAME windowed list (so their counts can't disagree), rows are NEWEST-FIRST, each raw source id resolves
 * through the shared [provenanceDisplayLabel] (strap → "Whoop", Health Connect → "Health Connect", Apple
 * Health → "Apple Health", the "-noop" sibling → "On-device"), and each value reuses the model's own
 * formatter + unit. Blood Oxygen (SpO2) is the acceptance case.
 */
class VitalReadingsTableTest {

    private val strap = WhoopRepository.WHOOP_SOURCE            // "my-whoop"
    private val healthConnect = WhoopRepository.HEALTH_CONNECT_SOURCE  // "health-connect"
    private val appleHealth = WhoopRepository.APPLE_HEALTH_SOURCE      // "apple-health"

    // Blood Oxygen: %-formatted, ascending readings from three different sources — a strap reading, a
    // Health Connect import (e.g. a Galaxy Watch), and an Apple Health import.
    private val spo2Readings = listOf(
        VitalReading("2026-01-01", 96.0, strap),
        VitalReading("2026-01-02", 95.0, healthConnect),
        VitalReading("2026-01-03", 97.0, appleHealth),
    )
    private val spo2Format: (Double) -> String = { String.format(Locale.US, "%.0f", it) }

    @Test fun rowCountEqualsReadingsCount() {
        val rows = vitalReadingRows(spo2Readings, "%", strap, spo2Format)
        assertEquals(spo2Readings.size, rows.size)
    }

    @Test fun rowsAreNewestFirst() {
        val rows = vitalReadingRows(spo2Readings, "%", strap, spo2Format)
        // Ascending input (01 → 03) must render descending (03 → 01).
        assertEquals(listOf("3 Jan", "2 Jan", "1 Jan"), rows.map { it.time })
        assertEquals("97 %", rows.first().value)   // the newest reading leads
    }

    @Test fun sourceLabelsResolvePerSample() {
        val rows = vitalReadingRows(spo2Readings, "%", strap, spo2Format)
        // Newest-first, so: Apple Health (03), Health Connect (02), Whoop strap (01).
        assertEquals(
            listOf(
                DisplayText.Resource(R.string.today_source_apple_health),
                DisplayText.Resource(R.string.today_source_health_connect),
                DisplayText.Resource(R.string.today_source_whoop),
            ),
            rows.map { it.source },
        )
    }

    @Test fun computedStrapSiblingReadsOnDevice() {
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-01-04", 55.0, "$strap-noop")),
            "yrs",
            strap,
            { it.roundToInt().toString() },
        )
        assertEquals(DisplayText.Resource(R.string.today_source_on_device), rows.single().source)
    }

    /**
     * #103/queue-11a follow-up: a spo2 candidate-fallback row (see [SPO2_CANDIDATE_ATTRIBUTION_SOURCE])
     * must resolve to "strap estimate (unverified)" — the SAME caption every other candidate-fallback
     * surface uses — never a device name, which would misrepresent an unvalidated estimate as a
     * calibrated reading.
     */
    @Test fun spo2CandidateSourceReadsStrapEstimateUnverified() {
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-08-24", 97.0, SPO2_CANDIDATE_ATTRIBUTION_SOURCE)),
            "%",
            strap,
            spo2Format,
        )
        assertEquals(DisplayText.Resource(R.string.spo2_strap_estimate_caption), rows.single().source)
    }

    @Test fun valueReusesModelFormatAndUnit() {
        // The row value is the model's own formatter applied to the reading, with the unit appended —
        // 41.7 ms rounds to "42 ms".
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-01-01", 41.7, strap)),
            "ms",
            strap,
            { it.roundToInt().toString() },
        )
        assertEquals("42 ms", rows.single().value)
    }

    @Test fun unitlessMetricLeavesNoTrailingSpace() {
        // Vitality has an empty unit; the value must not carry a dangling space.
        val rows = vitalReadingRows(
            listOf(VitalReading("2026-01-01", 72.0, "$strap-noop")),
            "",
            strap,
            { it.roundToInt().toString() },
        )
        assertEquals("72", rows.single().value)
    }

    @Test fun readingFilterMatchesPointFilterWindowInEveryRange() {
        // The header counts filterVitalReadings; the chart consumes filterVitalPoints. They must window
        // the SAME days in every range, or the "N readings" header and the table could disagree.
        val readings = (0 until 30).map {
            VitalReading(LocalDate.parse("2026-01-01").plusDays(it.toLong()).toString(), 60.0 + it, strap)
        }
        val points = readings.map { it.day to it.value }
        VitalDetailRange.entries.forEach { range ->
            assertEquals(
                filterVitalPoints(points, range).map { it.first },
                filterVitalReadings(readings, range).map { it.day },
            )
        }
    }
}
