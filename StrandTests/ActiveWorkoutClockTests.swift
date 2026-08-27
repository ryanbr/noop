import XCTest
@testable import Strand

/// Pins the pause-aware workout clock every live surface now shares.
///
/// #1533 added Pause/Resume but only the full-screen live view's timer subtracted the paused time; the
/// Today indicator and the Live card kept reading `now - start`, so pausing froze one clock and left two
/// counting. These cases are the twin of Kotlin `ActiveWorkoutClockTest` — same scenarios, same expected
/// seconds — so the two platforms cannot drift on what "elapsed" means for a paused session.
final class ActiveWorkoutClockTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000)

    private func elapsed(pausedAt: TimeInterval? = nil, pausedDuration: TimeInterval = 0,
                         now: TimeInterval) -> Int {
        Int(ActiveWorkoutClock.activeElapsed(
            start: start,
            pausedAt: pausedAt.map { start.addingTimeInterval($0) },
            pausedDuration: pausedDuration,
            now: start.addingTimeInterval(now)))
    }

    func testActiveElapsedSubtractsCompletedAndOpenPauses() {
        XCTAssertEqual(elapsed(now: 65), 65)                                     // never paused
        XCTAssertEqual(elapsed(pausedDuration: 20, now: 65), 45)                 // one finished pause
        XCTAssertEqual(elapsed(pausedAt: 30, now: 65), 30)                       // paused at 30s, still paused
        XCTAssertEqual(elapsed(pausedAt: 50, pausedDuration: 10, now: 65), 40)   // both
    }

    /// The whole point of the fix: while paused the number must not move, however much wall time passes.
    /// This is what the two card surfaces got wrong, and a clock that merely subtracts a CONSTANT would
    /// still tick — so the open pause has to grow with `now`.
    func testClockIsFrozenWhilePaused() {
        XCTAssertEqual(elapsed(pausedAt: 30, now: 65), 30)
        XCTAssertEqual(elapsed(pausedAt: 30, now: 99), 30)
        XCTAssertEqual(elapsed(pausedAt: 30, now: 4_000), 30)
    }

    func testNeverCountsBackwards() {
        XCTAssertEqual(elapsed(now: -5), 0)                        // clock skew
        XCTAssertEqual(elapsed(pausedDuration: 70, now: 65), 0)    // paused longer than the session
    }

    /// The Live card carried its own `%d:%02d` formatter with no hour roll-over, so a 90-minute session
    /// read "90:00" there and "1:30:00" on the Today indicator beside it. One formatter now.
    func testClockFormatRollsOverAtAnHour() {
        XCTAssertEqual(ActiveWorkoutClock.clock(0), "0:00")
        XCTAssertEqual(ActiveWorkoutClock.clock(65), "1:05")
        XCTAssertEqual(ActiveWorkoutClock.clock(3_600), "1:00:00")
        XCTAssertEqual(ActiveWorkoutClock.clock(5_400), "1:30:00")
        XCTAssertEqual(ActiveWorkoutClock.clock(2 * 3_600 + 5 * 60 + 9), "2:05:09")
        XCTAssertEqual(ActiveWorkoutClock.clock(-5), "0:00")
    }

    /// The Today indicator renders from a value type, so the pause state has to reach IT — being correct
    /// on `AppModel` is not enough, and that is exactly how the card kept counting.
    func testIndicatorModelCarriesPauseStateAndFreezes() {
        var workout = AppModel.ActiveWorkout(start: start)
        workout.pausedAt = start.addingTimeInterval(30)
        let model = ActiveWorkoutIndicatorModel.make(from: workout)
        XCTAssertEqual(model?.isPaused, true)
        XCTAssertEqual(model?.pausedAt, workout.pausedAt)
        XCTAssertEqual(
            ActiveWorkoutIndicatorModel.elapsed(since: start, pausedAt: model?.pausedAt,
                                                pausedDuration: model?.pausedDuration ?? 0,
                                                now: start.addingTimeInterval(600)),
            "0:30")
    }
}
