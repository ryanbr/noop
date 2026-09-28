import XCTest
@testable import Strand

/// What the Live card renders, and why it is a SLICE of absolute indices.
///
/// #2521: the card rendered the whole 5,000-line buffer in a non-lazy `VStack`, so every appended line built
/// and diffed every row while the viewport shows about fifteen. A history drain plus a re-score burst emits
/// hundreds of lines a minute, and iOS killed the app with `cpu_resource_fatal` for 85% of a core over 57s
/// while it was not frontmost. Reported by @pipiche38 with a symbolicated microstackshot whose heaviest
/// stack was the main run loop inside SwiftUI.
final class LiveLogTailTests: XCTestCase {

    private let tail = 200
    private func log(_ n: Int) -> [String] { (0..<n).map { "line \($0)" } }

    func testAnEmptyLogRendersNothing() {
        XCTAssertTrue(LiveState.renderedTail(log(0), tailLines: tail).isEmpty)
    }

    func testALogShorterThanTheTailRendersAllOfIt() {
        let t = LiveState.renderedTail(log(7), tailLines: tail)
        XCTAssertEqual(t.indices, 0..<7)
        XCTAssertEqual(Array(t), log(7))
    }

    func testALogLongerThanTheTailRendersExactlyTheLastLines() {
        let t = LiveState.renderedTail(log(5_000), tailLines: tail)
        XCTAssertEqual(t.indices, 4_800..<5_000)
        XCTAssertEqual(t.count, tail)
        XCTAssertEqual(t.first, "line 4800")
        XCTAssertEqual(t.last, "line 4999")
    }

    /// The load-bearing invariant: `onChangeCompat` scrolls to `log.indices.last`, so that index MUST be one
    /// the card actually rendered. A LEADING window would satisfy every count assertion above and still
    /// scroll to a row that was never built.
    func testTheScrollTargetIsAlwaysInsideTheRenderedTail() {
        for count in [1, 2, 199, 200, 201, 5_000, 5_256] {
            let t = LiveState.renderedTail(log(count), tailLines: tail)
            XCTAssertTrue(t.indices.contains(count - 1),
                          "scrollTo(\(count - 1)) must be rendered, indices were \(t.indices) for \(count)")
        }
    }

    /// Absolute indices mean an append shifts only the window edges, so every shared row keeps its identity.
    /// That is what turns a full re-identification into one row in and one out.
    func testAnAppendKeepsEverySharedRowsIdentity() {
        let before = LiveState.renderedTail(log(1_000), tailLines: tail).indices
        let after = LiveState.renderedTail(log(1_001), tailLines: tail).indices
        XCTAssertEqual(before, 800..<1_000)
        XCTAssertEqual(after, 801..<1_001)
        XCTAssertEqual(Set(before).intersection(Set(after)).count, tail - 1,
                       "only one row should leave and one arrive")
    }

    /// The reason this returns a slice rather than a range.
    ///
    /// The card draws the tail in a `LazyVStack`, whose row closures can run after the body that produced
    /// them. If the tail were a range indexed back into the live buffer, a trim landing in between would make
    /// a realized row read out of bounds. A slice is a value snapshot, so it survives the buffer moving.
    func testTheTailIsASnapshotAndSurvivesTheBufferBeingTrimmed() {
        var buffer = log(5_256)
        let t = LiveState.renderedTail(buffer, tailLines: tail)
        let expectedFirst = t.first
        let expectedLast = t.last

        buffer.removeFirst(256)          // exactly what append(log:) does at the trim slack
        buffer = log(3)                  // and something far more violent

        XCTAssertEqual(t.count, tail, "the snapshot must not shrink with the buffer")
        XCTAssertEqual(t.first, expectedFirst)
        XCTAssertEqual(t.last, expectedLast)
        // Every index the card would hand to SwiftUI is still readable.
        for idx in t.indices { XCTAssertFalse(t[idx].isEmpty) }
    }

    /// Defensive: a non-positive tail renders nothing rather than trapping on a negative count.
    func testANonPositiveTailRendersNothing() {
        XCTAssertTrue(LiveState.renderedTail(log(500), tailLines: 0).isEmpty)
        XCTAssertTrue(LiveState.renderedTail(log(500), tailLines: -5).isEmpty)
    }
}
