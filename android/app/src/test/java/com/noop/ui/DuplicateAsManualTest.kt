package com.noop.ui

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * "Duplicate as manual" must not touch the session it copied.
 *
 * The action is offered only on READ-ONLY rows — strap, Apple, lifting, activity file — and the menu
 * describes it as a copy path that leaves the original alone. The copy is built with source "manual" so the
 * form treats it as editable, which meant the dialog's own guard ("pass `replacing` only for a MANUAL or
 * DETECTED row") classified it as MANUAL and passed it straight through, carrying the ORIGINAL's startTs.
 *
 * The database survived that on Android because its delete is keyed by deviceId. The Health Connect
 * write-back did not: `deleteExercise` deletes `noop-workout-<startTs>` with no deviceId in the key at all,
 * so duplicating a strap session removed the original's records — and a duplicate saved at a NEW start left
 * them deleted with nothing to restore them.
 */
class DuplicateAsManualTest {

    private val start = 1_780_000_000L

    private fun row(source: String, deviceId: String = "my-whoop") = WorkoutRow(
        deviceId = deviceId, startTs = start, endTs = start + 3_600, sport = "Run",
        source = source, durationS = 3_600.0,
    )

    /**
     * The regression: a duplicate replaces nothing, even though its source says "manual". Passing it on is
     * what let the write-back delete by the original's start.
     */
    @Test fun aDuplicateReplacesNothing() {
        val copyOfStrapSession = row("manual", deviceId = "whoop-ABC123")
        assertNull(WorkoutEditing.replacingRowFor(copyOfStrapSession, isCopy = true))
    }

    /** A real edit of a stored manual row still replaces it — the delete-before-write must keep working. */
    @Test fun editingAManualRowStillReplacesIt() {
        val stored = row("manual")
        assertEquals(stored, WorkoutEditing.replacingRowFor(stored, isCopy = false))
    }

    /** A detected bout also replaces: the repository dismisses the original durably so it can't re-detect. */
    @Test fun editingADetectedBoutStillReplacesIt() {
        val detected = row("my-whoop-noop")
        assertEquals(detected, WorkoutEditing.replacingRowFor(detected, isCopy = false))
    }

    /**
     * And the case the source test DID catch stays caught: an imported row that somehow arrives without the
     * copy flag is still never replaced, so this is a second lock rather than a swap.
     */
    @Test fun anImportedRowIsNeverReplacedEvenWithoutTheFlag() {
        assertNull(WorkoutEditing.replacingRowFor(row("apple-health"), isCopy = false))
        assertNull(WorkoutEditing.replacingRowFor(row("health-connect"), isCopy = false))
        assertNull(WorkoutEditing.replacingRowFor(row("whoop"), isCopy = false))
    }

    /** A fresh add has nothing to replace either way. */
    @Test fun aFreshAddReplacesNothing() {
        assertNull(WorkoutEditing.replacingRowFor(null, isCopy = false))
        assertNull(WorkoutEditing.replacingRowFor(null, isCopy = true))
    }
}
