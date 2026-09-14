package com.noop.ui

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Test

/** Pure source-union parity tests for the auto-workout candidate path. */
class AutoWorkoutNudgeSourceTest {

    private fun row(
        source: String,
        start: Long,
        end: Long = start + 100L,
        sport: String = "Running",
        avgHr: Int? = null,
        maxHr: Int? = null,
    ) = WorkoutRow(
        deviceId = source,
        startTs = start,
        endTs = end,
        sport = sport,
        source = source,
        avgHr = avgHr,
        maxHr = maxHr,
    )

    @Test fun shadowPoliciesIncludePublishedBaselineAndAlternatives() {
        assertEquals(listOf(10.0, 12.0, 15.0), autoDetectShadowPolicies())
    }

    @Test fun savedRowsIncludeEveryPlatformSourceFamily() {
        val rows = mergeAutoDetectSavedRows(
            whoopRows = listOf(row("whoop-active", 100L)),
            computedRows = listOf(row("whoop-archived-noop", 300L, sport = "detected")),
            appleRows = listOf(row("apple-health", 500L)),
            healthConnectRows = listOf(row("health-connect", 700L)),
            liftingRows = listOf(row("lifting", 900L)),
            activityFileRows = listOf(row("activity-file", 1_100L)),
        )

        assertEquals(listOf(100L, 300L, 500L, 700L, 900L, 1_100L), rows.map { it.startTs })
    }

    @Test fun shadowLabelsComeFromTheCrossSourceDeduplicatedRealSet() {
        val strap = row("manual", 100L, 200L, avgHr = 145, maxHr = 170)
        val mirroredApple = row("apple-health", 105L, 195L)
        val legacyDetected = row("whoop-archived-noop", 300L, 400L, sport = "detected")
        val activityFile = row("activity-file", 500L, 600L, sport = "Cycling")
        val saved = mergeAutoDetectSavedRows(
            whoopRows = listOf(strap),
            computedRows = listOf(legacyDetected),
            appleRows = listOf(mirroredApple),
            healthConnectRows = emptyList(),
            liftingRows = emptyList(),
            activityFileRows = listOf(activityFile),
        )

        assertEquals(listOf(strap, legacyDetected, activityFile), saved)
        assertEquals(
            listOf(100L to 200L, 500L to 600L),
            autoDetectLabelledSpans(saved),
        )
    }
}
