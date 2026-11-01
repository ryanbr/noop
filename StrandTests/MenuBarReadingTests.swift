import Combine
import XCTest
@testable import Strand

/// The menu-bar label draws one `MenuBarReading`, and a new one only when what it shows changes, at most once a
/// second: every render repaints the status item in every menu bar, and NOOP sat at a quarter of a core when the
/// label rendered on each published change of the app's objects (`MenuBarReading`).
final class MenuBarReadingTests: XCTestCase {

    private func reading(bpm: Int?, heartRate: Int? = nil, lastRR: Int? = nil, connected: Bool = true) -> MenuBarReading {
        MenuBarReading(bpm: bpm, heartRate: heartRate, lastRR: lastRR, connected: connected)
    }

    /// The label shows the median first, then the strap's reported rate, then the rate of the last R-R.
    func testTheMedianWinsThenTheReportedRateThenTheLastRR() {
        XCTAssertEqual(reading(bpm: 72, heartRate: 80, lastRR: 500).displayHR, 72)
        XCTAssertEqual(reading(bpm: nil, heartRate: 80, lastRR: 500).displayHR, 80)
        XCTAssertEqual(reading(bpm: 0, heartRate: 0, lastRR: 800).displayHR, 75)
        XCTAssertNil(reading(bpm: nil, heartRate: nil, lastRR: 0, connected: false).displayHR)
    }

    /// Zones split at 60/70/80/90% of an assumed 190 bpm maximum.
    func testTheZoneIsTheShareOfAnAssumedMaximum() {
        XCTAssertEqual(reading(bpm: 113).zone, 1)
        XCTAssertEqual(reading(bpm: 114).zone, 2)
        XCTAssertEqual(reading(bpm: 132).zone, 2)
        XCTAssertEqual(reading(bpm: 133).zone, 3)
        XCTAssertEqual(reading(bpm: 152).zone, 4)
        XCTAssertEqual(reading(bpm: 171).zone, 5)
        XCTAssertNil(reading(bpm: nil).zone)
    }

    /// A change the label does not show draws nothing: here the same reading arrives again an interval later.
    func testAnUnchangedReadingIsNotDrawnAgain() {
        let readings = PassthroughSubject<MenuBarReading, Never>()
        var drawn: [MenuBarReading] = []
        let subscription = MenuBarReading.drawn(readings.eraseToAnyPublisher(), atMostEvery: .milliseconds(50))
            .sink { drawn.append($0) }
        readings.send(reading(bpm: 60))
        waitIntervals()
        readings.send(reading(bpm: 60))
        waitIntervals()
        XCTAssertEqual(drawn, [reading(bpm: 60)])
        subscription.cancel()
    }

    /// A burst inside one interval is drawn at most twice, at the interval's two edges, and ends on the latest reading.
    func testABurstInsideOneIntervalDrawsAtMostTwiceAndEndsOnTheLatest() {
        let readings = PassthroughSubject<MenuBarReading, Never>()
        let burst = (60..<70).map { reading(bpm: $0) }
        var drawn: [MenuBarReading] = []
        let latestDrawn = expectation(description: "latest drawn")
        let subscription = MenuBarReading.drawn(readings.eraseToAnyPublisher(), atMostEvery: .milliseconds(200))
            .sink {
                drawn.append($0)
                if $0 == burst.last { latestDrawn.fulfill() }
            }
        burst.forEach(readings.send)
        wait(for: [latestDrawn], timeout: 5)
        XCTAssertLessThanOrEqual(drawn.count, 2, "drawn: \(drawn.map { $0.displayHR ?? 0 })")
        subscription.cancel()
    }

    /// A reading that moves and comes back inside one interval leaves the label as it is: not drawn again.
    func testAReadingThatComesBackWithinAnIntervalIsNotRedrawn() {
        let readings = PassthroughSubject<MenuBarReading, Never>()
        var drawn: [MenuBarReading] = []
        let subscription = MenuBarReading.drawn(readings.eraseToAnyPublisher(), atMostEvery: .milliseconds(50))
            .sink { drawn.append($0) }
        readings.send(reading(bpm: 60))
        waitIntervals()
        readings.send(reading(bpm: 61))
        readings.send(reading(bpm: 60))
        waitIntervals()
        XCTAssertEqual(drawn, [reading(bpm: 60)])
        subscription.cancel()
    }

    /// A heart rate that moves more often than the interval, and never pauses for a whole one, is still drawn about
    /// once per interval while it moves: the label follows a live strap, not only a strap that has gone quiet.
    func testASteadyStreamIsDrawnWhileItRuns() {
        let readings = PassthroughSubject<MenuBarReading, Never>()
        var drawn: [MenuBarReading] = []
        let subscription = MenuBarReading.drawn(readings.eraseToAnyPublisher(), atMostEvery: .milliseconds(50))
            .sink { drawn.append($0) }
        let start = Date()
        for bpm in 60..<90 {
            readings.send(reading(bpm: bpm))
            pump(0.01)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(drawn.count, 3, "drawn: \(drawn.map { $0.displayHR ?? 0 })")
        XCTAssertLessThanOrEqual(drawn.count, Int(elapsed / 0.05) + 2, "drawn: \(drawn.map { $0.displayHR ?? 0 })")
        waitIntervals()
        XCTAssertEqual(drawn.last, reading(bpm: 89))
        subscription.cancel()
    }

    /// The link alone changes what the label draws (the filled or hollow heart, and the dot's tint).
    func testALinkChangeAloneIsDrawn() {
        let readings = PassthroughSubject<MenuBarReading, Never>()
        var drawn: [MenuBarReading] = []
        let subscription = MenuBarReading.drawn(readings.eraseToAnyPublisher(), atMostEvery: .milliseconds(50))
            .sink { drawn.append($0) }
        readings.send(reading(bpm: nil, connected: true))
        waitIntervals()
        readings.send(reading(bpm: nil, connected: false))
        waitIntervals()
        XCTAssertEqual(drawn, [reading(bpm: nil, connected: true), reading(bpm: nil, connected: false)])
        subscription.cancel()
    }

    /// Lets several 50 ms intervals pass on the main queue, where the readings are drawn.
    private func waitIntervals() {
        pump(0.25)
    }

    /// Runs the main queue for `seconds`.
    private func pump(_ seconds: TimeInterval) {
        let later = expectation(description: "\(seconds) s later")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { later.fulfill() }
        wait(for: [later], timeout: 5 + seconds)
    }
}
