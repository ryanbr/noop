package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #510: `fillWorkoutHrFromStrap` used to read every workout's HR window under a hardcoded "my-whoop",
 * so a workout recorded on a SECOND WHOOP (id "whoop-<mac>", its HR banked under that id) read an empty
 * window and lost its Avg HR / calories / Effort. [WhoopRepository.workoutHrDeviceIds] now resolves the
 * correct read key per row; this pins that resolution and the strap-native classification it rides on.
 */
class WorkoutHrDeviceKeyTest {

    // #856: the resolver returns a LIST now — one id for a detected bout (the strap that recorded it),
    // the active ∪ canonical union for manual/imported. These cases all assert the id that wins, which
    // is `.first()` in both branches, so the original expectations are unchanged.


    @Test fun `strap-native sources are classified as strap-native`() {
        assertTrue(WhoopRepository.isStrapNativeWorkout("manual"))
        assertTrue(WhoopRepository.isStrapNativeWorkout("MANUAL"))          // case-insensitive
        assertTrue(WhoopRepository.isStrapNativeWorkout("my-whoop-noop"))   // detected (canonical)
        assertTrue(WhoopRepository.isStrapNativeWorkout("whoop-aabbcc-noop")) // detected (2nd WHOOP)
    }

    @Test fun `imported sources are NOT strap-native`() {
        assertFalse(WhoopRepository.isStrapNativeWorkout("apple-health"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("Apple Health"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("Health Connect"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("activity-file"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("lifting"))
        assertFalse(WhoopRepository.isStrapNativeWorkout("my-whoop"))       // WHOOP CSV import (ends -whoop, not -noop)
    }

    @Test fun `detected row reads HR under its own base strap, not the active strap`() {
        // A detected bout on a SECOND WHOOP lives under "whoop-aabbcc-noop"; its HR is banked under
        // "whoop-aabbcc". The active strap being something else must NOT redirect the read.
        assertEquals(
            "whoop-aabbcc",
            WhoopRepository.workoutHrDeviceIds("whoop-aabbcc-noop", "whoop-aabbcc-noop", activeStrapId = "my-whoop").first(),
        )
        // Canonical single-WHOOP detected row is unchanged from the old "my-whoop" behaviour.
        assertEquals(
            "my-whoop",
            WhoopRepository.workoutHrDeviceIds("my-whoop-noop", "my-whoop-noop", activeStrapId = "my-whoop").first(),
        )
    }

    @Test fun `manual row reads HR under the active union, not its stored placeholder id`() {
        // #836: a manual row reads the #814 union (active strap first, canonical "my-whoop" second) rather
        // than its own stored id, because that id is not reliably the recording strap. Byte-parity with the
        // Swift twin, which has always kept manual rows off the single-id path.
        assertEquals(
            listOf("whoop-aabbcc", "my-whoop"),
            WhoopRepository.workoutHrDeviceIds("manual", "whoop-aabbcc", activeStrapId = "whoop-aabbcc"),
        )
    }

    @Test fun `manual row ignores its stored strap id when a DIFFERENT strap is active`() {
        // The divergent case, pinned explicitly: before #1039 a manual row keyed on its stored deviceId, so
        // this returned ["whoop-aabbcc"]. It now returns the active union instead, which is the deliberate
        // trade — see workoutHrDeviceIds' doc. Asserting it here rather than at rowDeviceId == activeStrapId
        // (where the old and new rules happen to agree) is the whole point: that is the only shape that can
        // tell the two rules apart, so without it a regression to per-row keying passes the suite silently.
        //
        // It matters because both buildManualRow callers write source "manual" with DIFFERENT ids — the
        // Workouts screen passes "my-whoop", AutoWorkoutNudge passes the active strap id — so a nudge-created
        // row genuinely does carry a real recording strap that this rule declines to use.
        assertEquals(
            listOf("whoop-ddeeff", "my-whoop"),
            WhoopRepository.workoutHrDeviceIds("manual", "whoop-aabbcc", activeStrapId = "whoop-ddeeff"),
        )
    }

    @Test fun `the read key never exceeds the two ids hrWindowStats consumes`() {
        // fillWorkoutHrFromStrap calls hrWindowStats(hrIds[0], hrIds.getOrElse(1) { hrIds[0] }, ...) — exactly
        // two. A third id would be silently dropped, so any future widening of this key has to fail here
        // first rather than lose a read at the call site.
        for (source in listOf("manual", "apple-health", "activity-file", "whoop-aabbcc-noop", "my-whoop-noop")) {
            for (active in listOf("my-whoop", "whoop-aabbcc")) {
                val ids = WhoopRepository.workoutHrDeviceIds(source, "whoop-ddeeff", activeStrapId = active)
                assertTrue("$source/$active produced ${ids.size} ids", ids.isNotEmpty() && ids.size <= 2)
            }
        }
    }

    @Test fun `imported row reads HR under the active strap (the worn strap), preserving the #77 fill`() {
        // An Apple/HC/activity-file row carries no strap HR; #77 fills it from the worn strap = active strap.
        assertEquals(
            "whoop-aabbcc",
            WhoopRepository.workoutHrDeviceIds("apple-health", "apple-health", activeStrapId = "whoop-aabbcc").first(),
        )
        assertEquals(
            "my-whoop",
            WhoopRepository.workoutHrDeviceIds("activity-file", "activity-file", activeStrapId = "my-whoop").first(),
        )
    }

    @Test fun `a bare strap id with no -noop suffix is returned unchanged`() {
        // removeSuffix is a no-op when the suffix is absent — a detected row's base id must not be
        // truncated. (Only detected rows carry rowDeviceId into the read key at all; see the manual/
        // imported cases above for the union path.)
        assertEquals(
            "whoop-aabbcc",
            WhoopRepository.workoutHrDeviceIds("whoop-aabbcc-noop", "whoop-aabbcc", activeStrapId = "ignored").first(),
        )
    }

    @Test fun `manual workout on a re-added strap reads the active union, not the stale my-whoop`() {
        // #836/#928 (bartmuskala): a manual workout is always stored under deviceId "my-whoop"
        // (WorkoutEditing.buildManualRow), regardless of which strap actually recorded the live HR. On a
        // re-added or second strap, the live trace banks under the strap's fresh id ("whoop-aabbcc"), not
        // under "my-whoop" — so reading only "my-whoop" (the pre-fix behaviour) hit an empty window and
        // left Avg HR / Effort blank. The union reads the active strap first, so it finds the trace.
        assertEquals(
            listOf("whoop-aabbcc", "my-whoop"),
            WhoopRepository.workoutHrDeviceIds("manual", rowDeviceId = "my-whoop", activeStrapId = "whoop-aabbcc"),
        )
    }
}
