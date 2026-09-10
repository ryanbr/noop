package com.noop.ai

import com.noop.data.DismissedWorkout
import com.noop.data.PairedDeviceRow
import com.noop.data.WhoopDao
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/**
 * #2033: WHICH sessions reach the coach, as opposed to how they are printed.
 *
 * This is the half that was wrong twice. A first pass dropped auto-detected sessions wholesale, hiding a
 * strap-only wearer's training entirely, and never applied the dismissal filter, so a session the wearer
 * had hidden from their own list was still sent to a third party. The formatter had seven tests and
 * neither bug was in the formatter, which is why this exists.
 *
 * The contract is the Workouts screen: what it lists, the coach sees; what it hides, the coach does not.
 */
class AiCoachVisibleWorkoutsTest {

    private val strap = "my-whoop"

    /**
     * `source` is the field `WorkoutEditing.classify` keys on, and a detected row's source is the
     * COMPUTED device id, "my-whoop-noop", not the word "detected". A looser fixture passed the
     * dismissal test while proving nothing, because a row that does not classify as detected is never
     * dismissible in the first place.
     */
    private fun row(source: String, day: Int, sport: String = "Running", deviceId: String = source) =
        WorkoutRow(
            deviceId = deviceId, startTs = day * 86_400L, endTs = day * 86_400L + 3_600L,
            sport = sport, source = source, durationS = 3_600.0,
        )

    /**
     * A DAO answering only what the selection reads. Anything else throws, so a source added to the
     * production union without being considered here fails loudly instead of being silently skipped.
     */
    private fun coach(
        byDevice: Map<String, List<WorkoutRow>>,
        dismissed: List<DismissedWorkout> = emptyList(),
    ): AiCoach {
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "workouts" -> byDevice[args[0] as String].orEmpty()
                "dismissedWorkouts" -> dismissed
                "pairedDevices" -> listOf(
                    PairedDeviceRow(strap, "WHOOP", "5.0 MG", null, sourceKind = "liveBLE",
                        capabilities = "hr,hrv", status = "active", addedAt = 1, lastSeenAt = 1),
                )
                else -> throw UnsupportedOperationException("unexpected DAO call: ${method.name}")
            }
        } as WhoopDao
        return AiCoach(WhoopRepository(dao)) { strap }
    }

    @Test fun everySourceTheScreenListsReachesTheCoach() = runBlocking {
        val rows = coach(
            mapOf(
                strap to listOf(row("strap", 10, "Running", deviceId = strap)),
                "apple-health" to listOf(row("apple-health", 11, "Yoga")),
                "health-connect" to listOf(row("health-connect", 12, "Walking")),
                "$strap-noop" to listOf(row("$strap-noop", 13, "Cycling", deviceId = "$strap-noop")),
                "activity-file" to listOf(row("activity-file", 14, "Hiking")),
                "lifting" to listOf(row("lifting", 15, "Strength Training")),
            ),
        ).visibleWorkoutRows(0L, 9_000_000L)
        val sports = rows.map { it.sport }.toSet()
        for (expected in listOf("Running", "Yoga", "Walking", "Cycling", "Hiking", "Strength Training")) {
            assertTrue("$expected missing; the coach sees less than the screen", expected in sports)
        }
    }

    @Test fun anAutoDetectedSessionIsNotDroppedForBeingDetectable() {
        // The first pass confused the category with the act: detected sessions CAN be dismissed, so it
        // dropped them all. A strap-only wearer's training is largely what the engine detects.
        val rows = runBlocking {
            coach(mapOf("$strap-noop" to listOf(row("$strap-noop", 13, "Cycling", deviceId = "$strap-noop"))))
                .visibleWorkoutRows(0L, 9_000_000L)
        }
        assertEquals(listOf("Cycling"), rows.map { it.sport })
    }

    @Test fun aDismissedSessionNeverLeavesTheDevice() {
        val hidden = row("$strap-noop", 13, "Cycling", deviceId = "$strap-noop")
        val rows = runBlocking {
            coach(
                mapOf("$strap-noop" to listOf(hidden)),
                dismissed = listOf(
                    DismissedWorkout(
                        deviceId = "$strap-noop", startTs = hidden.startTs, endTs = hidden.endTs,
                    ),
                ),
            ).visibleWorkoutRows(0L, 9_000_000L)
        }
        assertTrue("a session the wearer hid was sent anyway", rows.isEmpty())
    }

    @Test fun newestFirst() {
        val rows = runBlocking {
            coach(
                mapOf(
                    strap to listOf(row("strap", 10, "Running", deviceId = strap)),
                    "lifting" to listOf(row("lifting", 20, "Strength Training")),
                ),
            ).visibleWorkoutRows(0L, 9_000_000L)
        }
        assertEquals(listOf("Strength Training", "Running"), rows.map { it.sport })
    }

    @Test fun theWindowIsPassedThroughRatherThanIgnored() {
        // Both bounds reach the DAO: a stub that returned rows regardless would hide a window bug.
        var seenFrom = -1L
        var seenTo = -1L
        val dao = Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader, arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "workouts" -> { seenFrom = args[1] as Long; seenTo = args[2] as Long; emptyList<WorkoutRow>() }
                "dismissedWorkouts" -> emptyList<DismissedWorkout>()
                "pairedDevices" -> emptyList<PairedDeviceRow>()
                else -> throw UnsupportedOperationException(method.name)
            }
        } as WhoopDao
        runBlocking { AiCoach(WhoopRepository(dao)) { strap }.visibleWorkoutRows(1_000L, 2_000L) }
        assertEquals(1_000L, seenFrom)
        assertEquals(2_000L, seenTo)
    }
}
