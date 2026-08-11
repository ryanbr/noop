import XCTest
@testable import Strand

/// The durable strap-log tail used to be a SINGLE slot: a fresh process began logging and, 32 lines in,
/// `persistTail` overwrote it — so the lines that would explain an unexplained restart were destroyed by
/// the restart itself. Three consecutive overnight Oura captures were lost exactly that way. These pin the
/// generation ring that rescues the tail at first append.
@MainActor
final class LiveStateLogGenerationsTests: XCTestCase {
    private let tailKey = "strapLog.tail"
    private let gensKey = "strapLog.generations"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: tailKey)
        UserDefaults.standard.removeObject(forKey: gensKey)
        LiveState.resetGenerationRollLatchForTesting()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: tailKey)
        UserDefaults.standard.removeObject(forKey: gensKey)
        LiveState.resetGenerationRollLatchForTesting()
        super.tearDown()
    }

    /// THE ONE THAT MATTERS: a surviving tail is moved into a generation, and the live slot is cleared so
    /// the next `persistTail` cannot destroy it.
    func testRollMovesTheSurvivingTailIntoAGeneration() {
        UserDefaults.standard.set(["22:01 connected", "22:02 drain done"], forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        let gens = LiveState.persistedLogGenerations()
        XCTAssertEqual(gens.count, 1)
        XCTAssertEqual(gens[0].dropFirst(), ["22:01 connected", "22:02 drain done"])
        XCTAssertTrue(gens[0][0].contains("previous app session"), "generation must carry its own header")
        XCTAssertEqual(LiveState.persistedLogTail(), [], "the live slot must be cleared, not left to duplicate")
    }

    /// Idempotent per process: a second call must NOT push this process's own partial tail in as a
    /// "previous" session (which would evict a real one and mislabel the current lines).
    func testRollIsOncePerProcess() {
        UserDefaults.standard.set(["old line"], forKey: tailKey)
        LiveState.rollLogGenerationsIfNeeded()
        UserDefaults.standard.set(["a line this process just wrote"], forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        XCTAssertEqual(LiveState.persistedLogGenerations().count, 1)
        XCTAssertEqual(LiveState.persistedLogTail(), ["a line this process just wrote"])
    }

    /// A launch that logs nothing (or one right after a roll) must not push an empty generation — that
    /// would evict a real one, which is the opposite of the point.
    func testEmptyTailRollsNothing() {
        LiveState.rollLogGenerationsIfNeeded()
        XCTAssertEqual(LiveState.persistedLogGenerations().count, 0)
    }

    /// The ring is bounded and drops the OLDEST, keeping the most recent restarts.
    func testRingKeepsTheMostRecentGenerations() {
        for i in 1...(LiveState.maxLogGenerations + 2) {
            UserDefaults.standard.set(["session \(i)"], forKey: tailKey)
            LiveState.resetGenerationRollLatchForTesting()   // stands in for a fresh process
            LiveState.rollLogGenerationsIfNeeded()
        }
        let gens = LiveState.persistedLogGenerations()
        XCTAssertEqual(gens.count, LiveState.maxLogGenerations)
        XCTAssertEqual(gens.first?.dropFirst().first, "session 3", "oldest generations are evicted first")
        XCTAssertEqual(gens.last?.dropFirst().first, "session \(LiveState.maxLogGenerations + 2)")
    }

    /// Each generation is clipped to its own cap so the ring cannot grow UserDefaults without bound, and
    /// the clip keeps the TAIL — what explains a stop is the end of the previous session, not its start.
    func testGenerationIsClippedToItsTail() {
        let many = (0..<(LiveState.generationTailLimit + 50)).map { "line \($0)" }
        UserDefaults.standard.set(many, forKey: tailKey)

        LiveState.rollLogGenerationsIfNeeded()

        let body = Array(LiveState.persistedLogGenerations()[0].dropFirst())
        XCTAssertEqual(body.count, LiveState.generationTailLimit)
        XCTAssertEqual(body.last, "line \(LiveState.generationTailLimit + 49)", "the newest line must survive")
    }

    /// The export puts previous sessions AHEAD of the current one, so `report.txt` stays chronological and
    /// the log-parsing tools keep working on it unchanged.
    func testPreviousSessionsTextPrecedesTheCurrentMarker() {
        UserDefaults.standard.set(["last night 03:00 disconnected"], forKey: tailKey)
        LiveState.rollLogGenerationsIfNeeded()

        let text = LiveState.previousSessionsText()
        let prevIdx = try? XCTUnwrap(text.range(of: "last night 03:00 disconnected")?.lowerBound)
        let curIdx = try? XCTUnwrap(text.range(of: "current app session")?.lowerBound)
        XCTAssertNotNil(prevIdx)
        XCTAssertNotNil(curIdx)
        if let p = prevIdx, let c = curIdx { XCTAssertTrue(p < c) }
    }

    func testNoGenerationsRendersNothing() {
        XCTAssertEqual(LiveState.previousSessionsText(), "")
    }
}
