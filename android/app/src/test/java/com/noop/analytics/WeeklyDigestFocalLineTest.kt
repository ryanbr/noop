package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the weekly-digest focal sentences byte for byte, so moving them behind [DigestFocalLine] (for the
 * card's localized rendering) cannot change the English text. The expected strings are the Swift
 * `WeeklyDigestFocalLineTests` oracle, captured from the digest before the split, for the same inputs.
 */
class WeeklyDigestFocalLineTest {

    private fun days(range: IntRange, value: (Int) -> Double): Map<String, Double> =
        range.associate { "2026-06-%02d".format(it) to value(it) }

    private fun build(name: String): WeeklyDigest = when (name) {
        "chargeUp" -> WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.CHARGE to days(8..14) { 80.0 } + days(1..7) { 55.0 }), "2026-06-13")
        "rhrUp" -> WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.RHR to days(8..14) { 60.0 } + days(1..7) { 52.0 }), "2026-06-13")
        "steadyRest" -> WeeklyDigestEngine.build(
            mapOf(
                WeeklyMetric.CHARGE to days(1..14) { 65.0 },
                WeeklyMetric.EFFORT to days(1..14) { 63.0 },
                WeeklyMetric.REST to days(1..14) { if (it % 2 == 0) 84.0 else 81.0 },
            ),
            "2026-06-13",
        )
        "steady" -> WeeklyDigestEngine.build(
            mapOf(
                WeeklyMetric.CHARGE to days(1..14) { 65.0 },
                WeeklyMetric.EFFORT to days(1..14) { 63.0 },
                WeeklyMetric.REST to days(1..14) { if (it % 2 == 0) 95.0 else 70.0 },
            ),
            "2026-06-13",
        )
        "currentSparse" -> WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.CHARGE to days(8..9) { 40.0 } + days(1..7) { 70.0 }), "2026-06-09")
        "previousSparse" -> WeeklyDigestEngine.build(
            mapOf(WeeklyMetric.CHARGE to days(8..14) { 60.0 } + days(6..7) { 70.0 }), "2026-06-13")
        "overreaching" -> WeeklyDigestEngine.build(
            mapOf(
                WeeklyMetric.CHARGE to days(1..14) { if (it > 7) 40.0 else 70.0 },
                WeeklyMetric.EFFORT to days(1..14) { if (it > 7) 80.0 else 50.0 },
            ),
            "2026-06-13",
        )
        else -> error(name)
    }

    private val expected = listOf(
        "chargeUp" to listOf("Charge is up 45% week over week (avg 80 vs 55), a good sign."),
        "rhrUp" to listOf("Resting HR is up 15% week over week (avg 60 vs 52), worth a look."),
        "steadyRest" to listOf("A steady week: Rest held even (±1.6 pts) and nothing moved much."),
        "steady" to listOf("A steady week: no metric moved meaningfully from last week."),
        "currentSparse" to listOf(
            "Only 2 days into this week so far, too early to call a week-over-week trend yet."),
        "previousSparse" to listOf(
            "Last week only had 2 days of data, so week-over-week changes are rough, not a trend."),
        "overreaching" to listOf(
            "Charge is down 43% week over week (avg 40 vs 70), worth a look.",
            "Your Effort outpaced your Charge this week: you leaned into the red. Watch for a recovery dip.",
        ),
    )

    @Test fun focalPointsMatchTheSwiftOracleAndTheirLines() {
        for ((name, sentences) in expected) {
            val d = build(name)
            assertEquals(name, sentences, d.focalPoints)
            assertEquals(name, d.focalPoints, d.focalLines.map { it.englishText })
        }
    }

    @Test fun linesCarryTheValuesTheCardRenders() {
        assertEquals(
            listOf(DigestFocalLine.Mover(WeeklyMetric.CHARGE, 1, DigestFocalLine.Magnitude.Percent(45), 1, 80, 55)),
            build("chargeUp").focalLines,
        )
        assertEquals(DigestFocalLine.Balance(BalanceRead.OVERREACHING), build("overreaching").focalLines.last())
        assertEquals(listOf(DigestFocalLine.SteadyRest(1.6)), build("steadyRest").focalLines)
        assertEquals(listOf(DigestFocalLine.CurrentWeekSparse(2)), build("currentSparse").focalLines)
        assertEquals(listOf(DigestFocalLine.PreviousWeekSparse(2)), build("previousSparse").focalLines)
        assertEquals(listOf(DigestFocalLine.Steady), build("steady").focalLines)
    }

    @Test fun amountMagnitudeKeepsTheOldWording() {
        assertEquals(
            "HRV is up 4.5 ms week over week (avg 64 vs 60), a good sign.",
            DigestFocalLine.Mover(WeeklyMetric.HRV, 1, DigestFocalLine.Magnitude.Amount(4.5, "ms"), 1, 64, 60).englishText,
        )
        assertEquals(
            "Rest is down 0.5 pts week over week (avg 80 vs 81), worth a look.",
            DigestFocalLine.Mover(WeeklyMetric.REST, -1, DigestFocalLine.Magnitude.Amount(0.5, ""), -1, 80, 81).englishText,
        )
    }

    @Test fun unparseableAnchorGivesNoLines() {
        val d = WeeklyDigestEngine.build(emptyMap(), "not-a-date")
        assertTrue(d.focalLines.isEmpty())
        assertTrue(d.focalPoints.isEmpty())
    }
}
