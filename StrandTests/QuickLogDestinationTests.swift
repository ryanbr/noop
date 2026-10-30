import XCTest

final class QuickLogDestinationTests: XCTestCase {
    func testEveryWidgetDestinationRoundTrips() {
        for destination in QuickLogDestination.allCases {
            XCTAssertEqual(QuickLogDestination(url: destination.url), destination)
        }
    }

    func testUnrelatedAndMalformedLinksAreRejected() {
        let invalid = [
            "https://quick-log/hydration", "noop://coach", "noop://import-health/hydration",
            "noop://quick-log", "noop://quick-log/unknown", "noop://quick-log/hydration/extra",
            "noop://quick-log/hydration?amount=500", "noop://quick-log/hydration#fragment",
            "noop://user@quick-log/hydration", "noop://quick-log:80/hydration"
        ]
        for link in invalid {
            XCTAssertNil(QuickLogDestination(url: URL(string: link)!), link)
        }
    }

    func testColdLaunchWaitsForGatesAndConsumesOnlyOnce() {
        var request = QuickLogRequest()
        request.receive(QuickLogDestination.hydration.url)
        XCTAssertNil(request.take(ifAllowed: false))
        XCTAssertEqual(request.pending, .hydration)
        XCTAssertEqual(request.take(ifAllowed: true), .hydration)
        XCTAssertNil(request.take(ifAllowed: true))
    }

    func testWarmLaunchCanOpenTheSameDestinationAgain() {
        var request = QuickLogRequest()
        for _ in 0..<2 {
            XCTAssertTrue(request.receive(QuickLogDestination.caffeine.url))
            XCTAssertEqual(request.take(ifAllowed: true), .caffeine)
        }
    }

    func testLatestSelectionWinsWhileUnrelatedURLPreservesPendingSelection() {
        var request = QuickLogRequest()
        request.receive(QuickLogDestination.hydration.url)
        request.receive(QuickLogDestination.journal.url)
        XCTAssertFalse(request.receive(URL(string: "noop://import-health")!))
        XCTAssertEqual(request.take(ifAllowed: true), .journal)
    }
}
