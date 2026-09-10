package com.noop.ai

import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ui.UnitSystem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * #2033: the coach could say a wearer did two workouts on a day and how hard the day was, but not what
 * they did, for how long, how far, or how hard their heart worked. Apple has emitted per-session detail
 * since `recentWorkoutsBlock` was written; this pins the Kotlin twin's text.
 *
 * The FORMAT is the contract, because both platforms feed the same model: a wearer comparing an iPhone
 * and an Android phone on identical data should not get differently-shaped advice. Field order,
 * separators and rounding are asserted literally rather than by shape.
 */
class AiCoachWorkoutBlockTest {

    private fun coach(): AiCoach {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, _ ->
            throw UnsupportedOperationException("the formatter must not touch storage (${method.name})")
        } as WhoopDao
        return AiCoach(WhoopRepository(dao))
    }

    /** Local midnight on the given day, so the emitted date is that day in any zone the CI runs in. */
    private fun tsOn(day: String): Long =
        LocalDate.parse(day).atStartOfDay(ZoneId.systemDefault()).toEpochSecond()

    private fun row(
        day: String,
        sport: String,
        durationS: Double? = null,
        strain: Double? = null,
        avgHr: Int? = null,
        kcal: Double? = null,
        distanceM: Double? = null,
    ) = WorkoutRow(
        deviceId = "my-whoop", startTs = tsOn(day), endTs = tsOn(day) + 3600L, sport = sport,
        source = "strap",
        durationS = durationS, energyKcal = kcal, avgHr = avgHr, strain = strain, distanceM = distanceM,
    )

    @Test fun everyFieldPresentEmitsSwiftsOrderAndSeparators() {
        val out = coach().formatWorkoutsBlock(
            listOf(row("2026-09-08", "Running", 2_520.0, 12.43, 148, 511.6, 8_200.0)),
            UnitSystem.METRIC,
        )
        assertEquals(
            "Recent workouts (newest first):\n" +
                "  2026-09-08 Running, 42 min, effort 12.4, avg HR 148, 512 kcal, 8.2 km",
            out,
        )
    }

    @Test fun aMissingFieldIsOmittedRatherThanDashed() {
        // A prompt, not a table: a dash invites the model to reason about a gap that is only a sensor
        // the session never had.
        val out = coach().formatWorkoutsBlock(
            listOf(row("2026-09-08", "Strength Training", durationS = 3_600.0)),
            UnitSystem.METRIC,
        )
        assertEquals(
            "Recent workouts (newest first):\n  2026-09-08 Strength Training, 60 min",
            out,
        )
        assertFalse("a gap must not be spelled", out.contains("-,") || out.contains("null"))
    }

    @Test fun distanceFollowsTheWearersChosenUnits() {
        val metric = coach().formatWorkoutsBlock(
            listOf(row("2026-09-08", "Running", distanceM = 5_000.0)), UnitSystem.METRIC)
        val imperial = coach().formatWorkoutsBlock(
            listOf(row("2026-09-08", "Running", distanceM = 5_000.0)), UnitSystem.IMPERIAL)
        assertTrue(metric, metric.contains("5 km") || metric.contains("5.0 km"))
        assertTrue(imperial, imperial.contains("mi"))
        assertFalse("imperial must not leak kilometres", imperial.contains(" km"))
    }

    @Test fun theLimitCapsWhatRidesInThePrompt() {
        val rows = (1..10).map { row("2026-09-0${(it % 9) + 1}", "Running", durationS = 600.0) }
        val out = coach().formatWorkoutsBlock(rows, UnitSystem.METRIC, limit = 6)
        assertEquals("header plus six sessions", 7, out.lines().size)
    }

    @Test fun noWorkoutsSaysSoRatherThanEmittingAnEmptyHeader() {
        // An empty header would read to the model as "there is a workouts section and it is blank",
        // which is a different claim from "none recorded".
        assertEquals(
            "Recent workouts: none recorded in the last 30 days.",
            coach().formatWorkoutsBlock(emptyList(), UnitSystem.METRIC),
        )
    }

    @Test fun theDecimalSeparatorDoesNotFollowTheDeviceLocale() {
        // A prompt is read by a model, not a person. On a German device the default locale renders
        // "12,4", which Swift never emits, and which invites parsing as two numbers. CI runs in an
        // English locale, so this would pass by luck without forcing the default.
        val original = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY)
            val out = coach().formatWorkoutsBlock(
                listOf(row("2026-09-08", "Running", strain = 12.43, distanceM = 8_200.0)),
                UnitSystem.METRIC,
            )
            assertTrue(out, out.contains("effort 12.4"))
            assertTrue(out, out.contains("8.2 km"))
            assertFalse("a comma decimal must never reach the model", out.contains(","+"4") )
        } finally {
            java.util.Locale.setDefault(original)
        }
    }

    @Test fun roundingMatchesSwiftsHalfUpOnTheMinuteAndCalorie() {
        val out = coach().formatWorkoutsBlock(
            listOf(row("2026-09-08", "Cycling", durationS = 2_550.0, kcal = 511.5)),
            UnitSystem.METRIC,
        )
        assertTrue(out, out.contains("43 min"))
        assertTrue(out, out.contains("512 kcal"))
    }
}
