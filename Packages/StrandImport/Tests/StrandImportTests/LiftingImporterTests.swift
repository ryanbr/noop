import XCTest
@testable import StrandImport

/// Pins LiftingImporter: a Hevy CSV export and a Liftosaur JSON export both parse into one Strength
/// session per workout, with a TRANSPARENT volume-load = Σ(weight × reps). Warm-up sets are excluded
/// from the working volume, lb columns convert to kg, and the note never claims a strain.
final class LiftingImporterTests: XCTestCase {

    // MARK: - Hevy CSV

    func testHevyGroupsSetsIntoOneSessionWithVolumeLoad() {
        // Two exercises, four working sets across one workout. Volume = Σ(kg × reps):
        //   100×5 + 100×5 + 100×5 = 1500 (bench) ; 60×8 = 480 (curl) → 1980 kg.
        let csv = """
        title,start_time,end_time,exercise_title,set_index,set_type,weight_kg,reps
        Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,0,warmup,40,10
        Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,1,normal,100,5
        Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,2,normal,100,5
        Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,3,normal,100,5
        Push Day,2026-06-01 18:00:00,2026-06-01 19:00:00,Bicep Curl,0,normal,60,8
        """
        let r = LiftingImporter.parseHevy(text: csv)

        XCTAssertEqual(r.sessionCount, 1)
        XCTAssertEqual(r.skipped, 0)
        let s = r.sessions[0]
        XCTAssertEqual(s.volumeLoadKg, 1980, accuracy: 1e-6)   // warm-up 40×10 excluded
        XCTAssertEqual(s.setCount, 4)                          // 4 working sets, warm-up not counted
        XCTAssertEqual(s.exerciseCount, 2)
        XCTAssertEqual(s.totalReps, 23)
        XCTAssertEqual(s.topSetKg, 100)
        XCTAssertEqual(s.durationS, 3600)
        XCTAssertEqual(s.title, "Push Day")
    }

    func testHevySplitsDistinctWorkoutsAndConvertsPounds() {
        // A lb column converts to kg (135 lb ≈ 61.235 kg). Two start_times → two sessions.
        let csv = """
        title,start_time,exercise_title,set_type,weight_lb,reps
        A,2026-06-01 10:00:00,Squat,normal,135,5
        B,2026-06-02 10:00:00,Deadlift,normal,225,3
        """
        let r = LiftingImporter.parseHevy(text: csv)
        XCTAssertEqual(r.sessionCount, 2)
        XCTAssertEqual(r.sessions[0].volumeLoadKg, 135 * 0.45359237 * 5, accuracy: 1e-4)
        XCTAssertEqual(r.sessions[1].volumeLoadKg, 225 * 0.45359237 * 3, accuracy: 1e-4)
        // Oldest-first ordering.
        XCTAssertLessThan(r.sessions[0].start, r.sessions[1].start)
    }

    func testHevySkipsRowsWithNoUsableDate() {
        let csv = """
        title,start_time,exercise_title,set_type,weight_kg,reps
        Good,2026-06-01 10:00:00,Squat,normal,100,5
        Bad,,Squat,normal,100,5
        """
        let r = LiftingImporter.parseHevy(text: csv)
        XCTAssertEqual(r.sessionCount, 1)
        XCTAssertEqual(r.skipped, 1)
    }

    func testHevyBodyweightSetCountsButAddsNoVolume() {
        // No weight column at all → reps still count the set, volume stays 0.
        let csv = """
        title,start_time,exercise_title,set_type,reps
        Pull,2026-06-01 10:00:00,Pull Up,normal,12
        """
        let r = LiftingImporter.parseHevy(text: csv)
        XCTAssertEqual(r.sessions[0].setCount, 1)
        XCTAssertEqual(r.sessions[0].volumeLoadKg, 0)
        XCTAssertEqual(r.sessions[0].totalReps, 12)
        XCTAssertNil(r.sessions[0].topSetKg)
    }

    func testHevyTimestampUsesDeviceTimezoneNotUTC() {
        // #649: Hevy writes zoneless local wall-clock times. A set logged at "12 Jun 2026, 18:30"
        // must land at 18:30 *in the device timezone*, not 18:30 UTC. With a fixed UTC+2 zone the
        // wall-clock 18:30 is 16:30 UTC.
        let zone = TimeZone(secondsFromGMT: 2 * 3600)!
        // The "d MMM yyyy, HH:mm" form contains a comma, so it is a quoted CSV field (as Hevy exports).
        let csv = """
        title,start_time,exercise_title,set_type,weight_kg,reps
        Evening,"12 Jun 2026, 18:30",Squat,normal,100,5
        """
        let r = LiftingImporter.parseHevy(text: csv, zone: zone)
        XCTAssertEqual(r.sessionCount, 1)
        // 18:30 local (UTC+2) == 16:30 UTC.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 12; comps.hour = 18; comps.minute = 30
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        XCTAssertEqual(r.sessions[0].start, cal.date(from: comps)!)
        // Same wall-clock parsed at UTC would be two hours later — confirm we are NOT doing that.
        XCTAssertNotEqual(r.sessions[0].start,
                          ISO8601DateFormatter().date(from: "2026-06-12T18:30:00Z"))
    }

    func testHevyPlainTimestampHonoursDeviceTimezone() {
        // The "yyyy-MM-dd HH:mm:ss" Hevy form is equally zoneless → also device-zone, not UTC.
        let zone = TimeZone(secondsFromGMT: -5 * 3600)!   // UTC-5
        let csv = """
        title,start_time,exercise_title,set_type,weight_kg,reps
        Morning,2026-06-01 09:00:00,Bench,normal,80,5
        """
        let r = LiftingImporter.parseHevy(text: csv, zone: zone)
        // 09:00 at UTC-5 == 14:00 UTC.
        XCTAssertEqual(r.sessions[0].start,
                       ISO8601DateFormatter().date(from: "2026-06-01T14:00:00Z"))
    }

    func testHevyTimestampWithExplicitOffsetIgnoresDeviceTimezone() {
        // A timestamp that already carries an offset is authoritative — the device zone must NOT shift
        // it. "...+01:00" at 12:00 is 11:00 UTC regardless of the passed zone.
        let csv = """
        title,start_time,exercise_title,set_type,weight_kg,reps
        Zoned,2026-06-01T12:00:00+01:00,Row,normal,70,5
        """
        let r = LiftingImporter.parseHevy(text: csv, zone: TimeZone(secondsFromGMT: 9 * 3600)!)
        XCTAssertEqual(r.sessions[0].start,
                       ISO8601DateFormatter().date(from: "2026-06-01T11:00:00Z"))
    }

    // MARK: - Liftosaur JSON

    func testLiftosaurParsesHistoryRecords() {
        // startTime is epoch ms. Two entries; volume = 80×5 + 80×5 + 100×3 = 1100 kg.
        let json = """
        { "history": [
          { "startTime": 1748772000000, "endTime": 1748775600000, "dayName": "Day 1",
            "entries": [
              { "sets": [ { "weight": 80, "completedReps": 5 }, { "weight": 80, "completedReps": 5 } ] },
              { "sets": [ { "weight": { "value": 100, "unit": "kg" }, "completedReps": 3 } ] }
            ] }
        ] }
        """
        let r = LiftingImporter.parseLiftosaur(data: Data(json.utf8))
        XCTAssertEqual(r.sessionCount, 1)
        let s = r.sessions[0]
        XCTAssertEqual(s.volumeLoadKg, 1100, accuracy: 1e-6)
        XCTAssertEqual(s.setCount, 3)
        XCTAssertEqual(s.exerciseCount, 2)
        XCTAssertEqual(s.totalReps, 13)
        XCTAssertEqual(s.start, Date(timeIntervalSince1970: 1748772000))
        XCTAssertEqual(s.durationS, 3600)
    }

    func testLiftosaurConvertsPoundUnitAndSkipsUncompletedSets() {
        // Entry-level lb unit applies; a set with no completedReps is a template entry → skipped.
        let json = """
        { "history": [
          { "startTime": 1748772000000, "entries": [
              { "unit": "lb", "sets": [ { "weight": 100, "completedReps": 5 }, { "weight": 100, "reps": 5 } ] }
          ] }
        ] }
        """
        let r = LiftingImporter.parseLiftosaur(data: Data(json.utf8))
        let s = r.sessions[0]
        XCTAssertEqual(s.setCount, 1)                                   // template set without completedReps skipped
        XCTAssertEqual(s.volumeLoadKg, 100 * 0.45359237 * 5, accuracy: 1e-4)
    }

    func testLiftosaurBareArrayAndStorageWrappers() {
        // Bare array form.
        let bare = """
        [ { "startTime": 1748772000000, "entries": [ { "sets": [ { "weight": 50, "completedReps": 10 } ] } ] } ]
        """
        XCTAssertEqual(LiftingImporter.parseLiftosaur(data: Data(bare.utf8)).sessionCount, 1)
        // { storage: { history: [...] } } wrapper form.
        let wrapped = """
        { "storage": { "history": [
          { "startTime": 1748772000000, "entries": [ { "sets": [ { "weight": 50, "completedReps": 10 } ] } ] }
        ] } }
        """
        XCTAssertEqual(LiftingImporter.parseLiftosaur(data: Data(wrapped.utf8)).sessionCount, 1)
    }

    func testLiftosaurHeterogeneousHistoryCountsEveryRejectedRecord() {
        let json = """
        { "history": [
          { "startTime": 1748772000000, "endTime": 1748775600000, "dayName": "Day 1",
            "entries": [ { "sets": [ { "weight": 80, "completedReps": 5 } ] } ] },
          7,
          { "dayName": "Missing timestamp",
            "entries": [ { "sets": [ { "weight": 60, "completedReps": 8 } ] } ] },
          "not a record"
        ] }
        """

        let r = LiftingImporter.parse(data: Data(json.utf8))

        XCTAssertEqual(r.sessions.map(\.start), [Date(timeIntervalSince1970: 1748772000)])
        XCTAssertEqual(r.sessionCount, 1)
        let s = r.sessions[0]
        XCTAssertEqual(s.end, Date(timeIntervalSince1970: 1748775600))
        XCTAssertEqual(s.durationS, 3600)
        XCTAssertEqual(s.volumeLoadKg, 400, accuracy: 1e-6)
        XCTAssertEqual(s.setCount, 1)
        XCTAssertEqual(s.exerciseCount, 1)
        XCTAssertEqual(s.totalReps, 5)
        XCTAssertEqual(s.topSetKg, 80)
        XCTAssertEqual(s.title, "Day 1")
        XCTAssertEqual(r.earliest, Date(timeIntervalSince1970: 1748772000))
        XCTAssertEqual(r.latest, Date(timeIntervalSince1970: 1748772000))
        XCTAssertEqual(r.skipped, 3)
    }

    // MARK: - Auto-detection + note

    func testDetectFormatRoutesByLeadingByte() {
        XCTAssertEqual(LiftingImporter.detectFormat(data: Data("  { \"history\": [] }".utf8)), .liftosaurJson)
        XCTAssertEqual(LiftingImporter.detectFormat(data: Data("[]".utf8)), .liftosaurJson)
        XCTAssertEqual(LiftingImporter.detectFormat(data: Data("title,start_time\n".utf8)), .hevyCsv)
    }

    func testVolumeLoadNoteMatchesKotlinForTitledAndUntitledSessions() {
        func session(title: String?) -> LiftingSession {
            LiftingSession(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 0),
                           volumeLoadKg: 12400, setCount: 18, exerciseCount: 5, totalReps: 120,
                           topSetKg: 140, title: title)
        }

        let body = "Strength · volume load 12,400 kg · 18 sets · 5 exercises"
        XCTAssertEqual(session(title: nil).volumeLoadNote(), body)
        XCTAssertEqual(session(title: "").volumeLoadNote(), body)
        XCTAssertEqual(session(title: "Leg Day").volumeLoadNote(), "Leg Day: \(body)")
    }


    // MARK: - Hevy API (draft)

    /// A weight is narrowed nowhere, so nothing traps — but `Double("1e9999")` is infinity, and an
    /// infinite top set rides out to the session note while poisoning the volume total. Kotlin always
    /// dropped it at the parse; Swift did not, which meant the same hostile CSV imported differently
    /// depending on the phone. The set still counts as work done, it just carries no weight.
    func testHevyCSVRejectsANonFiniteWeight() {
        let csv = """
        title,start_time,exercise_title,set_type,weight_kg,reps
        H,2026-06-01 18:00:00,Bench Press,normal,1e9999,5
        """
        let s = LiftingImporter.parseHevy(text: csv).sessions[0]
        XCTAssertEqual(s.setCount, 1)
        XCTAssertNil(s.topSetKg, "an infinite top set must not survive the parse")
        XCTAssertEqual(s.volumeLoadKg, 0, accuracy: 0.001)
    }

    private func apiPage(_ workouts: String) -> Data {
        Data("{\"page\":1,\"page_count\":1,\"workouts\":[\(workouts)]}".utf8)
    }

    private let apiWorkout = """
    {"id":"w1","title":"Push Day","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T11:02:00Z",
     "exercises":[{"title":"Bench Press","sets":[{"type":"warmup","weight_kg":40,"reps":10},
                                                 {"type":"normal","weight_kg":60,"reps":8},
                                                 {"type":"normal","weight_kg":60,"reps":8}]},
                  {"title":"Overhead Press","sets":[{"type":"normal","weight_kg":40,"reps":10}]}]}
    """

    /// The API must land on the SAME arithmetic as the CSV lane: warm-ups excluded from volume, sets
    /// counted, top set tracked. 60x8 + 60x8 + 40x10 = 1360 kg, and the 40 kg warm-up adds nothing.
    func testHevyAPIUsesTheSameVolumeArithmeticAsTheCSVLane() {
        let out = LiftingImporter.parseHevyAPI(data: apiPage(apiWorkout))
        XCTAssertEqual(out.sessions.count, 1)
        let s = out.sessions[0]
        XCTAssertEqual(s.volumeLoadKg, 1360, accuracy: 0.001)
        XCTAssertEqual(s.setCount, 3, "the warm-up must not be counted as a working set")
        XCTAssertEqual(s.exerciseCount, 2)
        XCTAssertEqual(s.totalReps, 26)
        XCTAssertEqual(s.topSetKg, 60)
        XCTAssertEqual(s.title, "Push Day")
        XCTAssertEqual(s.end.timeIntervalSince(s.start), 62 * 60, accuracy: 1)
    }

    /// A workout with no countable set is skipped, not stored as an empty session — the same rule the
    /// CSV lane applies, and the reason `skipped` exists.
    func testHevyAPISkipsAWorkoutWithNoCountableSet() {
        let empty = """
        {"id":"w2","title":"Rest","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:05:00Z",
         "exercises":[{"title":"Bench Press","sets":[{"type":"warmup","weight_kg":40,"reps":10}]}]}
        """
        let out = LiftingImporter.parseHevyAPI(data: apiPage(empty))
        XCTAssertTrue(out.sessions.isEmpty)
        XCTAssertEqual(out.skipped, 1)
    }

    /// No start means no window to attach the session to, so it is skipped rather than defaulted.
    func testHevyAPISkipsAWorkoutWithNoStart() {
        let noStart = """
        {"id":"w3","title":"x","end_time":"2026-09-07T11:00:00Z","exercises":[]}
        """
        let out = LiftingImporter.parseHevyAPI(data: apiPage(noStart))
        XCTAssertTrue(out.sessions.isEmpty)
        XCTAssertEqual(out.skipped, 1)
    }

    /// This runs over another server's data: malformed input yields nothing rather than throwing.
    func testHevyAPIMalformedInputYieldsNothing() {
        XCTAssertTrue(LiftingImporter.parseHevyAPI(data: Data("not json".utf8)).sessions.isEmpty)
        XCTAssertTrue(LiftingImporter.parseHevyAPI(data: Data()).sessions.isEmpty)
        XCTAssertTrue(LiftingImporter.parseHevyAPI(data: Data("{\"workouts\":\"nope\"}".utf8)).sessions.isEmpty)
    }

    /// A bare array is what a saved response pasted out of a browser looks like.
    func testHevyAPIAcceptsABareArray() {
        XCTAssertEqual(LiftingImporter.parseHevyAPI(data: Data("[\(apiWorkout)]".utf8)).sessions.count, 1)
    }

    /// Weights and reps may arrive quoted depending on the encoder. A nulled weight must not become
    /// zero volume silently — the set still counts, it just adds nothing.
    func testHevyAPIAcceptsQuotedNumbersAndToleratesANullWeight() {
        let quoted = """
        {"id":"w4","title":"Q","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:30:00Z",
         "exercises":[{"title":"Row","sets":[{"type":"normal","weight_kg":"50","reps":"5"},
                                             {"type":"normal","reps":12}]}]}
        """
        let s = LiftingImporter.parseHevyAPI(data: apiPage(quoted)).sessions[0]
        XCTAssertEqual(s.volumeLoadKg, 250, accuracy: 0.001)
        XCTAssertEqual(s.setCount, 2, "a weightless set still counts as work done")
        XCTAssertEqual(s.totalReps, 17)
    }

    /// The API stamps an offset, which `parseDate` honours over the device zone — so the same payload
    /// parses identically whatever zone the phone is in. That is the API's advantage over the CSV
    /// lane, where a zoneless wall clock has to be interpreted (#649).
    func testHevyAPIHonoursTheStampedOffsetRatherThanTheDeviceZone() {
        let utc = LiftingImporter.parseHevyAPI(data: apiPage(apiWorkout),
                                               zone: TimeZone(identifier: "UTC")!)
        let tokyo = LiftingImporter.parseHevyAPI(data: apiPage(apiWorkout),
                                                 zone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(utc.sessions[0].start, tokyo.sessions[0].start)
    }

    /// The rep count is narrowed to Int, and `Int(_:)` TRAPS on a non-finite Double rather than
    /// saturating — `Double("1e9999")` is infinity. A response body is less trustworthy than a file
    /// the user picked, so the bound has to hold here: the set still counts as work done, it just
    /// contributes no reps and no volume.
    func testHevyAPISurvivesAHostileRepCount() {
        let hostile = """
        {"id":"w6","title":"H","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:30:00Z",
         "exercises":[{"title":"Row","sets":[{"type":"normal","weight_kg":50,"reps":"1e9999"}]}]}
        """
        let s = LiftingImporter.parseHevyAPI(data: apiPage(hostile)).sessions[0]
        XCTAssertEqual(s.setCount, 1)
        XCTAssertEqual(s.totalReps, 0)
        XCTAssertEqual(s.volumeLoadKg, 0, accuracy: 0.001)
    }

    /// Hevy's set `type` is one of normal, warmup, dropset, failure (published spec). Only warmup is
    /// excluded from volume: a dropset and a set taken to failure are work, and counting them as
    /// warm-ups would under-report a hard session — the opposite of the error the exclusion prevents.
    func testHevyAPICountsDropsetAndFailureSetsAsWork() {
        let mixed = """
        {"id":"w5","title":"Arms","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:40:00Z",
         "exercises":[{"title":"Bicep Curl (Dumbbell)",
                       "sets":[{"type":"warmup","weight_kg":10,"reps":10},
                               {"type":"normal","weight_kg":20,"reps":10},
                               {"type":"dropset","weight_kg":15,"reps":8},
                               {"type":"failure","weight_kg":12,"reps":6}]}]}
        """
        let s = LiftingImporter.parseHevyAPI(data: apiPage(mixed)).sessions[0]
        XCTAssertEqual(s.setCount, 3, "warmup excluded; dropset and failure are working sets")
        // 20×10 + 15×8 + 12×6 = 200 + 120 + 72; pre-summed because the literal arithmetic blows the
        // Swift type-check budget. Kotlin's twin computes it inline, which is what caught this sum.
        XCTAssertEqual(s.volumeLoadKg, 392, accuracy: 0.001)
        XCTAssertEqual(s.totalReps, 24)
    }
}
