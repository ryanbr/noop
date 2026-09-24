import Combine
import XCTest
@testable import Strand

/// The Live HR banner reads what it shows once the changes have landed, never from inside one of them: a reader called
/// from a `@Published` sink runs in willSet and still sees the old value. On a tester's phone that left the last number
/// on the banner for minutes after the strap sent WRIST_OFF (24 Sep 2026).
final class LiveHRBannerInputsTests: XCTestCase {

    private func bannerSignal<P: Publisher>(_ publisher: P) -> AnyPublisher<Void, Never> where P.Failure == Never {
        publisher.map { _ in () }.eraseToAnyPublisher()
    }

    /// WRIST_OFF clears the heart rate. The banner is refreshed after that has landed, and reads nothing inside it.
    @MainActor
    func testTheBannerReadsAClearedHeartRateOnlyOnceTheClearHasLanded() {
        let live = LiveState()
        live.heartRate = 91
        var seen: [Int?] = []
        let refreshed = expectation(description: "refreshed")
        refreshed.assertForOverFulfill = false
        let subscription = LiveHRBannerInputs.settled([bannerSignal(live.$heartRate)])
            .sink { seen.append(live.heartRate); refreshed.fulfill() }
        live.clearLiveHeartRate()
        XCTAssertEqual(seen, [], "read inside the change, it would still say 91")
        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(seen, [nil])
        subscription.cancel()
    }

    /// A clear moves the R-R and the heart rate, and a drop the link, in one turn: one refresh, after all of them.
    @MainActor
    func testSeveralChangesInOneTurnMakeOneRefresh() {
        let live = LiveState()
        live.heartRate = 91
        live.rr = [650]
        live.connected = true
        var refreshes = 0
        let refreshed = expectation(description: "refreshed")
        refreshed.assertForOverFulfill = false
        let subscription = LiveHRBannerInputs.settled([bannerSignal(live.$heartRate), bannerSignal(live.$rr),
                                                       bannerSignal(live.$connected)])
            .sink { refreshes += 1; refreshed.fulfill() }
        live.clearLiveHeartRate()
        live.connected = false
        wait(for: [refreshed], timeout: 1)
        let laterTurn = expectation(description: "a later turn")
        DispatchQueue.main.async { laterTurn.fulfill() }
        wait(for: [laterTurn], timeout: 1)
        XCTAssertEqual(refreshes, 1)
        subscription.cancel()
    }
}
