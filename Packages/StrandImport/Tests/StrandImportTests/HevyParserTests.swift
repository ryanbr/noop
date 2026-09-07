import XCTest
@testable import StrandImport

/// Hevy workout parsing (DRAFT).
///
/// The cases that carry weight are the REFUSALS. A Hevy workout is imported to be attached to a
/// stretch of the strap's own heart rate, so a session with an invented window would label the wrong
/// part of someone's day — worse than not importing it. Every test below that asserts a skip is
/// asserting that.
final class HevyParserTests: XCTestCase {

    private func page(_ workouts: String) -> Data {
        Data("{\"page\":1,\"page_count\":1,\"workouts\":[\(workouts)]}".utf8)
    }

    private let full = """
    {"id":"abc","title":"Push Day","description":"felt strong",
     "start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T11:02:00Z",
     "exercises":[{"title":"Bench Press","sets":[{"reps":8},{"reps":8},{"reps":6}]},
                  {"title":"Overhead Press","sets":[{"reps":10},{"reps":10}]}]}
    """

    func testParsesAWorkoutWithItsWindowAndLabel() {
        let out = HevyParser.parse(page(full))
        XCTAssertEqual(out.count, 1)
        let w = out[0]
        XCTAssertEqual(w.id, "abc")
        XCTAssertEqual(w.title, "Push Day")
        XCTAssertEqual(w.notes, "felt strong")
        XCTAssertEqual(w.exerciseTitles, ["Bench Press", "Overhead Press"])
        XCTAssertEqual(w.setCount, 5)
        XCTAssertEqual(w.durationS, 62 * 60)
    }

    /// A bare array is what a saved response pasted out of a browser looks like.
    func testAcceptsABareArrayAsWellAsTheEnvelope() {
        XCTAssertEqual(HevyParser.parse(Data("[\(full)]".utf8)).count, 1)
    }

    /// Both stamp forms have been seen. A formatter handling only one silently drops half a page,
    /// which reads as "Hevy had no workouts" rather than as a parse failure.
    func testAcceptsFractionalAndPlainTimestamps() {
        let frac = full.replacingOccurrences(of: "10:00:00Z", with: "10:00:00.500Z")
        XCTAssertEqual(HevyParser.parse(page(frac)).count, 1)
    }

    func testSkipsAWorkoutWithNoWindow() {
        let noEnd = """
        {"id":"a","title":"x","start_time":"2026-09-07T10:00:00Z","exercises":[]}
        """
        XCTAssertTrue(HevyParser.parse(page(noEnd)).isEmpty, "a window with no end cannot be attached")
        let noStart = """
        {"id":"a","title":"x","end_time":"2026-09-07T11:00:00Z","exercises":[]}
        """
        XCTAssertTrue(HevyParser.parse(page(noStart)).isEmpty)
    }

    /// Without an id a re-import cannot recognise the same session, so it would duplicate every time.
    func testSkipsAWorkoutWithNoId() {
        let noId = """
        {"title":"x","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T11:00:00Z"}
        """
        XCTAssertTrue(HevyParser.parse(page(noId)).isEmpty)
    }

    /// This runs over data from someone else's server. Malformed input must yield nothing, not throw.
    func testMalformedInputYieldsNothingRatherThanThrowing() {
        XCTAssertTrue(HevyParser.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(HevyParser.parse(Data()).isEmpty)
        XCTAssertTrue(HevyParser.parse(Data("{\"workouts\":\"nope\"}".utf8)).isEmpty)
        XCTAssertTrue(HevyParser.parse(Data("{\"workouts\":[1,2,3]}".utf8)).isEmpty)
    }

    /// An untitled session is still a real window worth attaching; only the LABEL is missing.
    func testAnUntitledWorkoutStillParses() {
        let untitled = """
        {"id":"a","start_time":"2026-09-07T10:00:00Z","end_time":"2026-09-07T10:30:00Z","exercises":[]}
        """
        let out = HevyParser.parse(page(untitled))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].title, "")
        XCTAssertNil(out[0].notes)
    }

    /// The note is the only place the exercise titles land, so it has to carry them — and it must
    /// stay nil rather than empty when there is nothing to say.
    func testNoteLineCarriesTheLiftsAndIsNilWhenEmpty() {
        let w = HevyParser.parse(page(full))[0]
        let note = HevyParser.noteLine(w)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("Bench Press"), note!)
        XCTAssertTrue(note!.contains("felt strong"), note!)

        let bare = HevyWorkout(id: "b", title: "", notes: nil, start: Date(), end: Date(),
                               exerciseTitles: [], setCount: 0)
        XCTAssertNil(HevyParser.noteLine(bare))
    }

    /// Hevy carries no physiology, and the parser must not invent any. The model has no HR, calorie
    /// or distance field at all — this pins that as a decision rather than an oversight.
    func testTheModelCarriesNoPhysiology() {
        let w = HevyParser.parse(page(full))[0]
        let mirror = Mirror(reflecting: w)
        let names = mirror.children.compactMap(\.label)
        for invented in ["avgHr", "maxHr", "strain", "energyKcal", "distanceM", "calories"] {
            XCTAssertFalse(names.contains(invented),
                           "Hevy has no \(invented); the strap supplies physiology, not this parser")
        }
    }
}
