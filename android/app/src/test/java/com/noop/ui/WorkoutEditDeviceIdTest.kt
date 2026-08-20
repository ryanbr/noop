package com.noop.ui

import com.noop.data.WhoopRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1488: editing a workout appeared to save and changed nothing, across restarts.
 *
 * `workout`'s primary key is (deviceId, startTs, sport), and the edit sheet builds every manual row on the
 * "my-whoop" seed. On a strap whose ACTIVE id is something else — re-paired, or identified by serial — the
 * original row sits under that active id, so the edit did not overwrite it, it inserted a second row beside
 * it. `saveManualWorkout` then only deleted the original when startTs or sport had moved, which on a plain
 * "change the duration" edit they had not. Both rows survived, and the read path keeps the FIRST row per
 * (startTs, sport) across [activeDeviceId, "my-whoop"] — so the stale one shadowed the edit for good.
 *
 * The fix compares the whole primary key rather than two thirds of it, which also migrates the row onto the
 * seed. That matters beyond this bug: "my-whoop" is in the read union unconditionally, while a strap's
 * active id is only there while it is active.
 */
class WorkoutEditDeviceIdTest {

    private val start = 1_780_000_000L

    private fun row(deviceId: String, durationMin: Int, sport: String = "Run") =
        WorkoutEditing.buildManualRow(
            deviceId = deviceId, startSeconds = start, durationMin = durationMin, sport = sport,
            avgHr = null, energyKcal = null, nowSeconds = start + 86_400L,
        )!!

    /**
     * The regression, stated as the predicate that missed it: same start, same sport, and the original
     * living under an active strap id. Two thirds of the key match, so the old comparison saw "nothing
     * moved" and skipped the delete — while the upsert wrote to a different key anyway.
     */
    @Test fun aRowUnderAnActiveStrapIdIsSupersededEvenWhenStartAndSportAreUntouched() {
        assertTrue(
            WhoopRepository.supersedesStoredRow(row("whoop-ABC123", 30), row("my-whoop", 45)),
        )
    }

    /** The ordinary in-place edit still must NOT delete: same key, so the upsert overwrites it. */
    @Test fun anEditThatMovesNothingIsNotSuperseded() {
        assertFalse(WhoopRepository.supersedesStoredRow(row("my-whoop", 30), row("my-whoop", 45)))
    }

    /** And the case that always worked keeps working — a re-keyed sport still retires the old row. */
    @Test fun aSportChangeIsStillSuperseded() {
        assertTrue(
            WhoopRepository.supersedesStoredRow(
                row("my-whoop", 30, sport = "Run"), row("my-whoop", 30, sport = "Ride"),
            ),
        )
    }

    /**
     * The shadowing half, kept because it is what made the bug SILENT rather than a visible duplicate: the
     * read union dedupes on (startTs, sport) only, so two rows differing just by deviceId collapse to one
     * and the first — the active-strap row — wins. Without the delete above, this is what the user saw.
     */
    @Test fun unionDedupeDiscardsASecondRowDifferingOnlyByDeviceId() {
        // Union order is [activeDeviceId, "my-whoop"], so the active-strap row is seen first.
        val shown = WhoopRepository.dedupWorkoutsByKey(listOf(row("whoop-ABC123", 30), row("my-whoop", 45)))
        assertEquals(1, shown.size)
        assertEquals(start + 30 * 60, shown[0].endTs)   // the STALE duration survives — the reported bug
        assertEquals("whoop-ABC123", shown[0].deviceId)
    }

    /**
     * A DETECTED bout never reaches the delete branch above — it is dismissed durably instead, because the
     * re-detector would otherwise recreate it. Pins the classification that routes it there, and that a
     * computed "<id>-noop" source is read as detected rather than as an import.
     */
    @Test fun detectedBoutsRouteToDismissalNotDeletion() {
        assertEquals(WorkoutSource.MANUAL, WorkoutEditing.classify("manual"))
        assertEquals(WorkoutSource.DETECTED, WorkoutEditing.classify("my-whoop-noop"))
        assertEquals(WorkoutSource.DETECTED, WorkoutEditing.classify("whoop-ABC123-noop"))
        assertEquals(WorkoutSource.APPLE, WorkoutEditing.classify("apple-health"))
        assertEquals(WorkoutSource.APPLE, WorkoutEditing.classify("health-connect"))
    }

    /**
     * The delete this fix added must never be able to reach a read-only source.
     *
     * "Duplicate as manual" pre-fills the sheet from a strap / Apple / lifting row and passes that pre-fill
     * on as `replacing`. It claims source "manual" while carrying the ORIGINAL's natural key, so if it also
     * kept the original's deviceId, [WhoopRepository.supersedesStoredRow] would fire against the strap's own
     * namespace and the save would delete the session it was copied from — on a menu item whose whole
     * promise is that it does not touch the original.
     */
    @Test fun aDuplicateOfAReadOnlyRowCannotDeleteTheOriginal() {
        val strapSession = row("whoop-ABC123", 60, sport = "Run").copy(source = "whoop")
        val copy = WorkoutEditing.asManualCopy(strapSession)
        assertEquals("my-whoop", copy.deviceId)          // re-seeded out of the strap namespace
        assertEquals(strapSession.startTs, copy.startTs) // ...while still pre-filling from the original
        // Whatever the user then edits, the key the save could delete stays inside "my-whoop".
        val edited = row("my-whoop", 75, sport = "Ride")
        assertTrue(WhoopRepository.supersedesStoredRow(copy, edited))
        assertEquals("my-whoop", copy.deviceId)
        // The strap's own row is a different key entirely, so no delete this save issues can name it.
        assertTrue(copy.deviceId != strapSession.deviceId)
    }
}
