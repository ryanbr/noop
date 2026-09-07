package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/**
 * Pins LiftingImporter.parse: a Hevy CSV export and a Liftosaur JSON export both fold into one
 * Strength session per workout, with a TRANSPARENT volume load = Σ(weight × reps). Warm-up sets are
 * excluded from the working volume, lb columns / units convert to kg, and the note never claims a
 * strain. Kotlin twin of the macOS LiftingImporterTests — same arithmetic, same labels.
 */
class LiftingImporterTest {

    private fun hevy(csv: String) =
        LiftingImporter.parseHevy(CsvTable.fromData(csv.trimIndent().toByteArray()))

    private fun liftosaur(json: String) = LiftingImporter.parseLiftosaur(json.trimIndent())

    private fun apiPage(workouts: String, zone: ZoneId = ZoneId.systemDefault()) =
        LiftingImporter.parseHevyAPI(
            """{"page":1,"page_count":1,"workouts":[$workouts]}""".toByteArray(),
            zone,
        )

    private val apiWorkout = """
        {"id":"w1","title":"Push Day","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T11:02:00Z",
         "exercises":[{"title":"Bench Press","sets":[{"type":"warmup","weight_kg":40,"reps":10},
                                                     {"type":"normal","weight_kg":60,"reps":8},
                                                     {"type":"normal","weight_kg":60,"reps":8}]},
                      {"title":"Overhead Press","sets":[{"type":"normal","weight_kg":40,"reps":10}]}]}
    """.trimIndent()

    // MARK: - Hevy CSV

    @Test
    fun hevyGroupsSetsIntoOneSessionWithVolumeLoad() {
        // Volume = 100×5 + 100×5 + 100×5 (bench) + 60×8 (curl) = 1980 kg; warm-up 40×10 excluded.
        val r = hevy(
            """
            title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,0,warmup,40,10
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,1,normal,100,5
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,2,normal,100,5
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,3,normal,100,5
            Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bicep Curl,0,normal,60,8
            """
        )
        assertEquals(1, r.sessions.size)
        assertEquals(0, r.skipped)
        val s = r.sessions[0]
        assertEquals(1980.0, s.volumeLoadKg, 1e-6)
        assertEquals(4, s.setCount)        // warm-up not counted
        assertEquals(2, s.exerciseCount)
        assertEquals(23, s.totalReps)
        assertEquals(100.0, s.topSetKg!!, 1e-9)
        assertEquals(3600.0, s.durationS!!, 1e-9)
        assertEquals("Push Day", s.title)
    }

    @Test
    fun hevySplitsDistinctWorkoutsAndConvertsPounds() {
        val r = hevy(
            """
            title,start_time,exercise_title,set_type,weight_lb,reps
            A,2026-06-01 10:00:00,Squat,normal,135,5
            B,2026-06-02 10:00:00,Deadlift,normal,225,3
            """
        )
        assertEquals(2, r.sessions.size)
        assertEquals(135 * 0.45359237 * 5, r.sessions[0].volumeLoadKg, 1e-4)
        assertEquals(225 * 0.45359237 * 3, r.sessions[1].volumeLoadKg, 1e-4)
        assertTrue(r.sessions[0].startTs < r.sessions[1].startTs) // oldest first
    }

    @Test
    fun hevySkipsRowsWithNoUsableDate() {
        val r = hevy(
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Good,2026-06-01 10:00:00,Squat,normal,100,5
            Bad,,Squat,normal,100,5
            """
        )
        assertEquals(1, r.sessions.size)
        assertEquals(1, r.skipped)
    }

    @Test
    fun hevyBodyweightSetCountsButAddsNoVolume() {
        val r = hevy(
            """
            title,start_time,exercise_title,set_type,reps
            Pull,2026-06-01 10:00:00,Pull Up,normal,12
            """
        )
        assertEquals(1, r.sessions[0].setCount)
        assertEquals(0.0, r.sessions[0].volumeLoadKg, 1e-9)
        assertEquals(12, r.sessions[0].totalReps)
        assertNull(r.sessions[0].topSetKg)
    }

    @Test
    fun hevyTimestampUsesDeviceTimezoneNotUtc() {
        // #649: Hevy writes zoneless local wall-clock times. "12 Jun 2026, 18:30" must land at 18:30
        // in the device zone, not 18:30 UTC. The "d MMM yyyy, HH:mm" form contains a comma, so it is a
        // quoted CSV field (as Hevy exports). At UTC+2, 18:30 local == 16:30 UTC.
        val zone = java.time.ZoneId.of("UTC+02:00")
        val csv =
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Evening,"12 Jun 2026, 18:30",Squat,normal,100,5
            """.trimIndent()
        val r = LiftingImporter.parseHevy(CsvTable.fromData(csv.toByteArray()), zone)
        assertEquals(1, r.sessions.size)
        val expected = java.time.LocalDateTime.of(2026, 6, 12, 18, 30)
            .atZone(zone).toEpochSecond()
        assertEquals(expected, r.sessions[0].startTs)
        // Same wall-clock parsed at UTC would be 7200 s later — confirm we are NOT doing that.
        val asUtc = java.time.LocalDateTime.of(2026, 6, 12, 18, 30)
            .toEpochSecond(java.time.ZoneOffset.UTC)
        assertEquals(7200L, asUtc - r.sessions[0].startTs)
    }

    @Test
    fun hevyPlainTimestampHonoursDeviceTimezone() {
        // The "yyyy-MM-dd HH:mm:ss" Hevy form is equally zoneless → device-zone, not UTC.
        val zone = java.time.ZoneId.of("UTC-05:00")
        val csv =
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Morning,2026-06-01 09:00:00,Bench,normal,80,5
            """.trimIndent()
        val r = LiftingImporter.parseHevy(CsvTable.fromData(csv.toByteArray()), zone)
        // 09:00 at UTC-5 == 14:00 UTC.
        val expected = java.time.OffsetDateTime.parse("2026-06-01T14:00:00Z").toEpochSecond()
        assertEquals(expected, r.sessions[0].startTs)
    }

    @Test
    fun hevyTimestampWithExplicitOffsetIgnoresDeviceTimezone() {
        // A timestamp that already carries an offset is authoritative — the device zone must NOT shift
        // it. "...+01:00" at 12:00 is 11:00 UTC regardless of the passed zone.
        val csv =
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            Zoned,2026-06-01T12:00:00+01:00,Row,normal,70,5
            """.trimIndent()
        val r = LiftingImporter.parseHevy(CsvTable.fromData(csv.toByteArray()), java.time.ZoneId.of("UTC+09:00"))
        val expected = java.time.OffsetDateTime.parse("2026-06-01T11:00:00Z").toEpochSecond()
        assertEquals(expected, r.sessions[0].startTs)
    }

    // MARK: - Liftosaur JSON

    @Test
    fun liftosaurParsesHistoryRecords() {
        // startTime is epoch ms. Volume = 80×5 + 80×5 + 100×3 = 1100 kg.
        val r = liftosaur(
            """
            { "history": [
              { "startTime": 1748772000000, "endTime": 1748775600000, "dayName": "Day 1",
                "entries": [
                  { "sets": [ { "weight": 80, "completedReps": 5 }, { "weight": 80, "completedReps": 5 } ] },
                  { "sets": [ { "weight": { "value": 100, "unit": "kg" }, "completedReps": 3 } ] }
                ] }
            ] }
            """
        )
        assertEquals(1, r.sessions.size)
        val s = r.sessions[0]
        assertEquals(1100.0, s.volumeLoadKg, 1e-6)
        assertEquals(3, s.setCount)
        assertEquals(2, s.exerciseCount)
        assertEquals(13, s.totalReps)
        assertEquals(1748772000L, s.startTs)
        assertEquals(3600.0, s.durationS!!, 1e-9)
    }

    @Test
    fun liftosaurConvertsPoundUnitAndSkipsUncompletedSets() {
        val r = liftosaur(
            """
            { "history": [
              { "startTime": 1748772000000, "entries": [
                  { "unit": "lb", "sets": [ { "weight": 100, "completedReps": 5 }, { "weight": 100, "reps": 5 } ] }
              ] }
            ] }
            """
        )
        val s = r.sessions[0]
        assertEquals(1, s.setCount) // template set without completedReps skipped
        assertEquals(100 * 0.45359237 * 5, s.volumeLoadKg, 1e-4)
    }

    @Test
    fun liftosaurAcceptsBareArrayAndStorageWrapper() {
        val bare =
            """[ { "startTime": 1748772000000, "entries": [ { "sets": [ { "weight": 50, "completedReps": 10 } ] } ] } ]"""
        assertEquals(1, LiftingImporter.parseLiftosaur(bare).sessions.size)
        val wrapped =
            """{ "storage": { "history": [ { "startTime": 1748772000000, "entries": [ { "sets": [ { "weight": 50, "completedReps": 10 } ] } ] } ] } }"""
        assertEquals(1, LiftingImporter.parseLiftosaur(wrapped).sessions.size)
    }

    @Test
    fun liftosaurHeterogeneousHistoryCountsEveryRejectedRecord() {
        val json =
            """
            { "history": [
              { "startTime": 1748772000000, "endTime": 1748775600000, "dayName": "Day 1",
                "entries": [ { "sets": [ { "weight": 80, "completedReps": 5 } ] } ] },
              7,
              { "dayName": "Missing timestamp",
                "entries": [ { "sets": [ { "weight": 60, "completedReps": 8 } ] } ] },
              "not a record"
            ] }
            """.trimIndent()

        val r = LiftingImporter.parse(json.toByteArray())

        assertEquals(listOf(1748772000L), r.sessions.map { it.startTs })
        assertEquals(1, r.sessions.size)
        val s = r.sessions[0]
        assertEquals(1748775600L, s.endTs)
        assertEquals(3600.0, s.durationS!!, 1e-9)
        assertEquals(400.0, s.volumeLoadKg, 1e-6)
        assertEquals(1, s.setCount)
        assertEquals(1, s.exerciseCount)
        assertEquals(5, s.totalReps)
        assertEquals(80.0, s.topSetKg!!, 1e-9)
        assertEquals("Day 1", s.title)
        assertEquals("2025-06-01", r.firstDay)
        assertEquals("2025-06-01", r.lastDay)
        assertEquals(3, r.skipped)
    }

    // MARK: - Auto-detection + note

    @Test
    fun detectFormatRoutesByLeadingByte() {
        assertEquals(
            LiftingImporter.Format.LIFTOSAUR_JSON,
            LiftingImporter.detectFormat("  { \"history\": [] }".toByteArray()),
        )
        assertEquals(LiftingImporter.Format.LIFTOSAUR_JSON, LiftingImporter.detectFormat("[]".toByteArray()))
        assertEquals(LiftingImporter.Format.HEVY_CSV, LiftingImporter.detectFormat("title,start_time\n".toByteArray()))
    }

    @Test
    fun volumeLoadNoteMatchesSwiftForTitledAndUntitledSessions() {
        fun session(title: String?) = LiftingImporter.Session(
            startTs = 0, endTs = 0, volumeLoadKg = 12400.0, setCount = 18,
            exerciseCount = 5, totalReps = 120, topSetKg = 140.0, title = title,
        )

        val body = "Strength · volume load 12,400 kg · 18 sets · 5 exercises"
        assertEquals(body, session(null).volumeLoadNote())
        assertEquals(body, session("").volumeLoadNote())
        assertEquals("Leg Day: $body", session("Leg Day").volumeLoadNote())
    }

    /**
     * "1e9999" parses to infinity, and an infinite top set would ride out to the session note while
     * poisoning the volume total. Dropped at the parse on both platforms, so the same hostile CSV
     * imports the same way whatever the phone. The set still counts as work done, it just carries no
     * weight.
     */
    @Test
    fun hevyCsvRejectsANonFiniteWeight() {
        val s = hevy(
            """
            title,start_time,exercise_title,set_type,weight_kg,reps
            H,2026-06-01 18:00:00,Bench Press,normal,1e9999,5
            """
        ).sessions[0]
        assertEquals(1, s.setCount)
        assertNull(s.topSetKg)
        assertEquals(0.0, s.volumeLoadKg, 1e-6)
    }

    // MARK: - Hevy Web API

    /**
     * The API must land on the SAME arithmetic as the CSV lane: warm-ups excluded from volume, sets
     * counted, top set tracked. 60×8 + 60×8 + 40×10 = 1360 kg, and the 40 kg warm-up adds nothing.
     */
    @Test
    fun hevyApiUsesTheSameVolumeArithmeticAsTheCsvLane() {
        val r = apiPage(apiWorkout)
        assertEquals(1, r.sessions.size)
        val s = r.sessions[0]
        assertEquals(1360.0, s.volumeLoadKg, 1e-6)
        assertEquals(3, s.setCount)      // the warm-up is not a working set
        assertEquals(2, s.exerciseCount)
        assertEquals(26, s.totalReps)
        assertEquals(60.0, s.topSetKg!!, 1e-6)
        assertEquals("Push Day", s.title)
        assertEquals(62.0 * 60, s.durationS!!, 1.0)
    }

    /**
     * Hevy's set `type` is one of normal, warmup, dropset, failure (published spec). Only warmup is
     * excluded from volume: a dropset and a set taken to failure are work, and counting them as
     * warm-ups would under-report a hard session, the opposite of the error the exclusion prevents.
     */
    @Test
    fun hevyApiCountsDropsetAndFailureSetsAsWork() {
        val s = apiPage(
            """
            {"id":"w5","title":"Arms","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:40:00Z",
             "exercises":[{"title":"Bicep Curl (Dumbbell)",
                           "sets":[{"type":"warmup","weight_kg":10,"reps":10},
                                   {"type":"normal","weight_kg":20,"reps":10},
                                   {"type":"dropset","weight_kg":15,"reps":8},
                                   {"type":"failure","weight_kg":12,"reps":6}]}]}
            """.trimIndent()
        ).sessions[0]
        assertEquals(3, s.setCount)
        assertEquals(20.0 * 10 + 15.0 * 8 + 12.0 * 6, s.volumeLoadKg, 1e-6)
        assertEquals(24, s.totalReps)
    }

    /**
     * A workout with no countable set is skipped, not stored as an empty session. The count comes
     * from the shared Hevy tail, so the CSV lane reports it the same way and so does Swift.
     */
    @Test
    fun hevyApiSkipsAWorkoutWithNoCountableSet() {
        val r = apiPage(
            """
            {"id":"w2","title":"Rest","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:05:00Z",
             "exercises":[{"title":"Bench Press","sets":[{"type":"warmup","weight_kg":40,"reps":10}]}]}
            """.trimIndent()
        )
        assertTrue(r.sessions.isEmpty())
        assertEquals(1, r.skipped)
    }

    /** No start means no window to attach the session to, so it is skipped rather than defaulted. */
    @Test
    fun hevyApiSkipsAWorkoutWithNoStart() {
        val r = apiPage("""{"id":"w3","title":"x","end_time":"2026-09-07T11:00:00Z","exercises":[]}""")
        assertTrue(r.sessions.isEmpty())
        assertEquals(1, r.skipped)
    }

    /** This runs over another server's data: malformed input yields nothing rather than throwing. */
    @Test
    fun hevyApiMalformedInputYieldsNothing() {
        assertTrue(LiftingImporter.parseHevyAPI("not json".toByteArray()).sessions.isEmpty())
        assertTrue(LiftingImporter.parseHevyAPI(ByteArray(0)).sessions.isEmpty())
        assertTrue(LiftingImporter.parseHevyAPI("""{"workouts":"nope"}""".toByteArray()).sessions.isEmpty())
    }

    /** A bare array is what a saved response pasted out of a browser looks like. */
    @Test
    fun hevyApiAcceptsABareArray() {
        assertEquals(1, LiftingImporter.parseHevyAPI("[$apiWorkout]".toByteArray()).sessions.size)
    }

    /**
     * Weights and reps may arrive quoted depending on the encoder. A nulled weight must not become
     * zero volume silently: the set still counts as work done, it just adds nothing.
     */
    @Test
    fun hevyApiAcceptsQuotedNumbersAndToleratesANullWeight() {
        val s = apiPage(
            """
            {"id":"w4","title":"Q","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:30:00Z",
             "exercises":[{"title":"Row","sets":[{"type":"normal","weight_kg":"50","reps":"5"},
                                                 {"type":"normal","reps":12}]}]}
            """.trimIndent()
        ).sessions[0]
        assertEquals(250.0, s.volumeLoadKg, 1e-6)
        assertEquals(2, s.setCount)
        assertEquals(17, s.totalReps)
    }

    /**
     * The rep count is narrowed to Int, and Kotlin's `Double.toInt()` SATURATES a non-finite value
     * (+inf to Int.MAX_VALUE) where Swift's `Int(_:)` traps. "1e9999" parses to infinity, so both
     * platforms have to reject it here: the set still counts as work done, contributing no reps and
     * no volume, rather than storing two billion of them.
     */
    @Test
    fun hevyApiSurvivesAHostileRepCount() {
        val s = apiPage(
            """
            {"id":"w6","title":"H","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:30:00Z",
             "exercises":[{"title":"Row","sets":[{"type":"normal","weight_kg":50,"reps":"1e9999"}]}]}
            """.trimIndent()
        ).sessions[0]
        assertEquals(1, s.setCount)
        assertEquals(0, s.totalReps)
        assertEquals(0.0, s.volumeLoadKg, 1e-6)
    }

    /**
     * The API stamps an offset, which parseEpochSeconds honours over the device zone, so the same
     * payload parses identically whatever zone the phone is in. That is the API's advantage over the
     * CSV lane, where a zoneless wall clock has to be interpreted (#649).
     */
    @Test
    fun hevyApiHonoursTheStampedOffsetRatherThanTheDeviceZone() {
        assertEquals(
            apiPage(apiWorkout, ZoneId.of("UTC")).sessions[0].startTs,
            apiPage(apiWorkout, ZoneId.of("Asia/Tokyo")).sessions[0].startTs,
        )
    }
}
