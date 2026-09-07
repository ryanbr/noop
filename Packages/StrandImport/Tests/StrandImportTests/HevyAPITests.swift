import XCTest
@testable import StrandImport

/// Pins the Hevy Web API parsers beyond the workouts page: exercise templates (the authoritative
/// muscle attribution), body measurements, workout events (the only endpoint that reports deletions),
/// and the two trivial ones. Kotlin twin: HevyApiTest.
final class HevyAPITests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Exercise templates

    func testExerciseTemplatesParseMuscleGroupsAndPaging() {
        let page = HevyAPI.parseExerciseTemplates(data: data("""
        {"page":2,"page_count":7,"exercise_templates":[
          {"id":"t1","title":"Bench Press (Barbell)","type":"weight_reps",
           "primary_muscle_group":"chest","secondary_muscle_groups":["triceps","shoulders"],
           "equipment":"barbell","is_custom":false}]}
        """))
        XCTAssertEqual(page.page, 2)
        XCTAssertEqual(page.pageCount, 7)
        XCTAssertTrue(page.hasMore, "page 2 of 7 has more")
        XCTAssertEqual(page.items.count, 1)
        let t = page.items[0]
        XCTAssertEqual(t.id, "t1")
        XCTAssertEqual(t.primaryMuscleGroup, .chest)
        XCTAssertEqual(t.secondaryMuscleGroups, [.triceps, .shoulders])
        XCTAssertEqual(t.equipment, "barbell")
        XCTAssertFalse(t.isCustom)
    }

    /// The underscored wire values are the ones a hand-written mapping is most likely to get wrong.
    func testMuscleGroupWireValuesRoundTrip() {
        XCTAssertEqual(HevyAPI.MuscleGroup(rawValue: "upper_back"), .upperBack)
        XCTAssertEqual(HevyAPI.MuscleGroup(rawValue: "lower_back"), .lowerBack)
        XCTAssertEqual(HevyAPI.MuscleGroup(rawValue: "full_body"), .fullBody)
        XCTAssertEqual(HevyAPI.MuscleGroup.allCases.count, 20)
    }

    /// A group Hevy adds later must NOT collapse into `.other`, which is a real category of its own:
    /// silently filing an unknown group as "other" would look like data rather than like a gap.
    func testUnknownMuscleGroupIsNilRatherThanOther() {
        let page = HevyAPI.parseExerciseTemplates(data: data("""
        {"exercise_templates":[{"id":"t2","title":"X","primary_muscle_group":"rotator_cuff",
                                "secondary_muscle_groups":["chest","hypothetical"]}]}
        """))
        XCTAssertNil(page.items[0].primaryMuscleGroup)
        XCTAssertEqual(page.items[0].secondaryMuscleGroups, [.chest], "unknown dropped, known kept")
    }

    func testExerciseTemplateWithoutIdOrTitleIsSkipped() {
        let page = HevyAPI.parseExerciseTemplates(data: data("""
        {"exercise_templates":[{"title":"No id"},{"id":"t3"},{"id":"t4","title":"Good"}]}
        """))
        XCTAssertEqual(page.items.map(\.id), ["t4"])
        XCTAssertEqual(page.skipped, 2)
    }

    // MARK: - Body measurements

    func testBodyMeasurementsKeepTheDateStringAndDropEmptyEntries() {
        let page = HevyAPI.parseBodyMeasurements(data: data("""
        {"page":1,"page_count":1,"body_measurements":[
          {"date":"2024-08-14","weight_kg":82.5,"fat_percent":16.2,"lean_mass_kg":69.1},
          {"date":"2024-08-15","waist":80,"left_calf":38}]}
        """))
        XCTAssertEqual(page.items.count, 1, "an entry with only circumferences has nothing to store")
        XCTAssertEqual(page.skipped, 1)
        XCTAssertEqual(page.items[0].date, "2024-08-14", "the bare calendar date is kept verbatim")
        XCTAssertEqual(page.items[0].weightKg, 82.5)
        XCTAssertEqual(page.items[0].leanMassKg, 69.1)
        XCTAssertFalse(page.hasMore)
    }

    /// A zero weight is a cleared field, not a reading of zero kilograms.
    func testBodyMeasurementZeroWeightIsNotAReading() {
        let page = HevyAPI.parseBodyMeasurements(data: data("""
        {"body_measurements":[{"date":"2024-08-16","weight_kg":0,"fat_percent":15}]}
        """))
        XCTAssertNil(page.items[0].weightKg)
        XCTAssertEqual(page.items[0].fatPercent, 15)
    }

    // MARK: - Workout events

    func testWorkoutEventsFoldUpdatesThroughTheSameArithmeticAsAPage() {
        let page = HevyAPI.parseWorkoutEvents(data: data("""
        {"page":1,"page_count":3,"events":[
          {"type":"updated","workout":{"id":"w1","title":"Push","start_time":"2026-09-07T10:00:00Z",
            "end_time":"2026-09-07T11:00:00Z","exercises":[{"title":"Bench Press","sets":[
              {"type":"warmup","weight_kg":40,"reps":10},{"type":"normal","weight_kg":60,"reps":8}]}]}},
          {"type":"deleted","id":"w2","deleted_at":"2026-09-07T12:00:00Z"}]}
        """))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.pageCount, 3)
        guard case let .updated(id, session) = page.items[0] else { return XCTFail("expected updated") }
        XCTAssertEqual(id, "w1")
        XCTAssertEqual(session.volumeLoadKg, 480, accuracy: 0.001)  // 60×8; the warm-up excluded
        XCTAssertEqual(session.setCount, 1)
        guard case let .deleted(deletedID, at) = page.items[1] else { return XCTFail("expected deleted") }
        XCTAssertEqual(deletedID, "w2")
        XCTAssertNotNil(at)
        XCTAssertEqual(page.items[1].workoutID, "w2")
    }

    /// An update whose sets all fold away is NOT a deletion. Reporting it as one would drop a workout
    /// the user still has, which is the worst thing a sync can do.
    func testAnUpdateThatFoldsToNothingIsSkippedNotDeleted() {
        let page = HevyAPI.parseWorkoutEvents(data: data("""
        {"events":[{"type":"updated","workout":{"id":"w3","start_time":"2026-09-07T10:00:00Z",
          "exercises":[{"title":"Bench","sets":[{"type":"warmup","weight_kg":40,"reps":10}]}]}}]}
        """))
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.skipped, 1)
    }

    func testUnknownEventTypeIsSkipped() {
        let page = HevyAPI.parseWorkoutEvents(data: data("""
        {"events":[{"type":"archived","id":"w4"},{"type":"deleted","id":"w5"}]}
        """))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.skipped, 1)
        guard case let .deleted(_, at) = page.items[0] else { return XCTFail("expected deleted") }
        XCTAssertNil(at, "deleted_at is optional in the spec")
    }

    // MARK: - Count, user info, pagination

    func testWorkoutCountAndUserInfo() {
        XCTAssertEqual(HevyAPI.parseWorkoutCount(data: data("{\"workout_count\":42}")), 42)
        XCTAssertNil(HevyAPI.parseWorkoutCount(data: data("{}")))
        let user = HevyAPI.parseUserInfo(data: data("{\"data\":{\"id\":\"u1\",\"name\":\"Sam\"}}"))
        XCTAssertEqual(user?.id, "u1")
        XCTAssertEqual(user?.name, "Sam")
        XCTAssertNil(user?.url)
        XCTAssertEqual(HevyAPI.parseUserInfo(data: data("{\"id\":\"u2\"}"))?.id, "u2", "bare object tolerated")
    }

    /// A missing or nonsense page number falls back to 1 rather than to zero: this value ends up in a
    /// `page < pageCount` loop condition, and a zero there would read as "nothing to fetch".
    func testPaginationFallsBackRatherThanReturningZero() {
        XCTAssertEqual(HevyAPI.parsePagination(data: data("{\"page\":3,\"page_count\":9}"))?.page, 3)
        let odd = HevyAPI.parsePagination(data: data("{\"page\":0,\"page_count\":\"nope\"}"))
        XCTAssertEqual(odd?.page, 1)
        XCTAssertEqual(odd?.pageCount, 1)
        XCTAssertNil(HevyAPI.parsePagination(data: data("not json")))
    }

    // MARK: - Hostile input

    /// Every one of these runs over another server's data, so nothing here may throw.
    func testMalformedInputYieldsEmptyPagesRatherThanThrowing() {
        for bad in ["", "not json", "[]", "{}", "{\"events\":\"nope\"}", "null"] {
            XCTAssertTrue(HevyAPI.parseWorkoutEvents(data: data(bad)).items.isEmpty)
            XCTAssertTrue(HevyAPI.parseExerciseTemplates(data: data(bad)).items.isEmpty)
            XCTAssertTrue(HevyAPI.parseBodyMeasurements(data: data(bad)).items.isEmpty)
        }
    }

    /// A bare array is what a saved response pasted out of a browser looks like.
    func testBareArrayIsAcceptedForEachPagedEndpoint() {
        let templates = HevyAPI.parseExerciseTemplates(data: data("""
        [{"id":"t9","title":"Squat","primary_muscle_group":"quadriceps"}]
        """))
        XCTAssertEqual(templates.items.count, 1)
        XCTAssertEqual(templates.page, 1)
        XCTAssertFalse(templates.hasMore, "an unwrapped page cannot claim more")
    }
}
