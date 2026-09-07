package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Hevy Web API parsers beyond the workouts page: exercise templates (the authoritative
 * muscle attribution), body measurements, workout events (the only endpoint that reports deletions),
 * and the two trivial ones. Kotlin twin of the macOS HevyAPITests - same cases, same assertions.
 */
class HevyApiTest {

    private fun bytes(s: String) = s.trimIndent().toByteArray()

    // MARK: - Exercise templates

    @Test
    fun exerciseTemplatesParseMuscleGroupsAndPaging() {
        val page = HevyApi.parseExerciseTemplates(
            bytes(
                """
                {"page":2,"page_count":7,"exercise_templates":[
                  {"id":"t1","title":"Bench Press (Barbell)","type":"weight_reps",
                   "primary_muscle_group":"chest","secondary_muscle_groups":["triceps","shoulders"],
                   "equipment":"barbell","is_custom":false}]}
                """
            )
        )
        assertEquals(2, page.page)
        assertEquals(7, page.pageCount)
        assertTrue(page.hasMore)
        assertEquals(1, page.items.size)
        val t = page.items[0]
        assertEquals("t1", t.id)
        assertEquals(HevyApi.MuscleGroup.CHEST, t.primaryMuscleGroup)
        assertEquals(listOf(HevyApi.MuscleGroup.TRICEPS, HevyApi.MuscleGroup.SHOULDERS), t.secondaryMuscleGroups)
        assertEquals("barbell", t.equipment)
        assertFalse(t.isCustom)
    }

    /** The underscored wire values are the ones a hand-written mapping is most likely to get wrong. */
    @Test
    fun muscleGroupWireValuesRoundTrip() {
        assertEquals(HevyApi.MuscleGroup.UPPER_BACK, HevyApi.MuscleGroup.from("upper_back"))
        assertEquals(HevyApi.MuscleGroup.LOWER_BACK, HevyApi.MuscleGroup.from("lower_back"))
        assertEquals(HevyApi.MuscleGroup.FULL_BODY, HevyApi.MuscleGroup.from("full_body"))
        assertEquals(20, HevyApi.MuscleGroup.entries.size)
    }

    /**
     * A group Hevy adds later must NOT collapse into OTHER, which is a real category of its own:
     * silently filing an unknown group as "other" would look like data rather than like a gap.
     */
    @Test
    fun unknownMuscleGroupIsNullRatherThanOther() {
        val page = HevyApi.parseExerciseTemplates(
            bytes(
                """
                {"exercise_templates":[{"id":"t2","title":"X","primary_muscle_group":"rotator_cuff",
                                        "secondary_muscle_groups":["chest","hypothetical"]}]}
                """
            )
        )
        assertNull(page.items[0].primaryMuscleGroup)
        assertEquals(listOf(HevyApi.MuscleGroup.CHEST), page.items[0].secondaryMuscleGroups)
    }

    @Test
    fun exerciseTemplateWithoutIdOrTitleIsSkipped() {
        val page = HevyApi.parseExerciseTemplates(
            bytes("""{"exercise_templates":[{"title":"No id"},{"id":"t3"},{"id":"t4","title":"Good"}]}""")
        )
        assertEquals(listOf("t4"), page.items.map { it.id })
        assertEquals(2, page.skipped)
    }

    // MARK: - Body measurements

    @Test
    fun bodyMeasurementsKeepTheDateStringAndDropEmptyEntries() {
        val page = HevyApi.parseBodyMeasurements(
            bytes(
                """
                {"page":1,"page_count":1,"body_measurements":[
                  {"date":"2024-08-14","weight_kg":82.5,"fat_percent":16.2,"lean_mass_kg":69.1},
                  {"date":"2024-08-15","waist":80,"left_calf":38}]}
                """
            )
        )
        assertEquals(1, page.items.size)
        assertEquals(1, page.skipped)
        assertEquals("2024-08-14", page.items[0].date)
        assertEquals(82.5, page.items[0].weightKg!!, 1e-9)
        assertEquals(69.1, page.items[0].leanMassKg!!, 1e-9)
        assertFalse(page.hasMore)
    }

    /** A zero weight is a cleared field, not a reading of zero kilograms. */
    @Test
    fun bodyMeasurementZeroWeightIsNotAReading() {
        val page = HevyApi.parseBodyMeasurements(
            bytes("""{"body_measurements":[{"date":"2024-08-16","weight_kg":0,"fat_percent":15}]}""")
        )
        assertNull(page.items[0].weightKg)
        assertEquals(15.0, page.items[0].fatPercent!!, 1e-9)
    }

    // MARK: - Workout events

    @Test
    fun workoutEventsFoldUpdatesThroughTheSameArithmeticAsAPage() {
        val page = HevyApi.parseWorkoutEvents(
            bytes(
                """
                {"page":1,"page_count":3,"events":[
                  {"type":"updated","workout":{"id":"w1","title":"Push","start_time":"2026-09-07T10:00:00Z",
                    "end_time":"2026-09-07T11:00:00Z","exercises":[{"title":"Bench Press","sets":[
                      {"type":"warmup","weight_kg":40,"reps":10},{"type":"normal","weight_kg":60,"reps":8}]}]}},
                  {"type":"deleted","id":"w2","deleted_at":"2026-09-07T12:00:00Z"}]}
                """
            )
        )
        assertEquals(2, page.items.size)
        assertEquals(3, page.pageCount)
        val updated = page.items[0] as HevyApi.WorkoutEvent.Updated
        assertEquals("w1", updated.workoutId)
        assertEquals(480.0, updated.session.volumeLoadKg, 1e-6)   // 60×8; the warm-up excluded
        assertEquals(1, updated.session.setCount)
        val deleted = page.items[1] as HevyApi.WorkoutEvent.Deleted
        assertEquals("w2", deleted.workoutId)
        assertTrue(deleted.deletedAtTs != null)
    }

    /**
     * An update whose sets all fold away is NOT a deletion. Reporting it as one would drop a workout
     * the user still has, which is the worst thing a sync can do.
     */
    @Test
    fun anUpdateThatFoldsToNothingIsSkippedNotDeleted() {
        val page = HevyApi.parseWorkoutEvents(
            bytes(
                """
                {"events":[{"type":"updated","workout":{"id":"w3","start_time":"2026-09-07T10:00:00Z",
                  "exercises":[{"title":"Bench","sets":[{"type":"warmup","weight_kg":40,"reps":10}]}]}}]}
                """
            )
        )
        assertTrue(page.items.isEmpty())
        assertEquals(1, page.skipped)
    }

    @Test
    fun unknownEventTypeIsSkipped() {
        val page = HevyApi.parseWorkoutEvents(
            bytes("""{"events":[{"type":"archived","id":"w4"},{"type":"deleted","id":"w5"}]}""")
        )
        assertEquals(1, page.items.size)
        assertEquals(1, page.skipped)
        assertNull((page.items[0] as HevyApi.WorkoutEvent.Deleted).deletedAtTs)
    }

    // MARK: - Count, user info, pagination

    @Test
    fun workoutCountAndUserInfo() {
        assertEquals(42, HevyApi.parseWorkoutCount(bytes("""{"workout_count":42}""")))
        assertNull(HevyApi.parseWorkoutCount(bytes("{}")))
        val user = HevyApi.parseUserInfo(bytes("""{"data":{"id":"u1","name":"Sam"}}"""))
        assertEquals("u1", user?.id)
        assertEquals("Sam", user?.name)
        assertNull(user?.url)
        assertEquals("u2", HevyApi.parseUserInfo(bytes("""{"id":"u2"}"""))?.id)
    }

    /**
     * A missing or nonsense page number falls back to 1 rather than to zero: this value ends up in a
     * `page < pageCount` loop condition, and a zero there would read as "nothing to fetch".
     */
    @Test
    fun paginationFallsBackRatherThanReturningZero() {
        assertEquals(3, HevyApi.parsePagination(bytes("""{"page":3,"page_count":9}"""))?.first)
        val odd = HevyApi.parsePagination(bytes("""{"page":0,"page_count":"nope"}"""))
        assertEquals(1, odd?.first)
        assertEquals(1, odd?.second)
        assertNull(HevyApi.parsePagination(bytes("not json")))
    }

    // MARK: - Hostile input

    /** Every one of these runs over another server's data, so nothing here may throw. */
    @Test
    fun malformedInputYieldsEmptyPagesRatherThanThrowing() {
        for (bad in listOf("", "not json", "[]", "{}", """{"events":"nope"}""", "null")) {
            assertTrue(HevyApi.parseWorkoutEvents(bytes(bad)).items.isEmpty())
            assertTrue(HevyApi.parseExerciseTemplates(bytes(bad)).items.isEmpty())
            assertTrue(HevyApi.parseBodyMeasurements(bytes(bad)).items.isEmpty())
        }
    }

    /** A bare array is what a saved response pasted out of a browser looks like. */
    @Test
    fun bareArrayIsAcceptedForEachPagedEndpoint() {
        val templates = HevyApi.parseExerciseTemplates(
            bytes("""[{"id":"t9","title":"Squat","primary_muscle_group":"quadriceps"}]""")
        )
        assertEquals(1, templates.items.size)
        assertEquals(1, templates.page)
        assertFalse(templates.hasMore)
    }
}
