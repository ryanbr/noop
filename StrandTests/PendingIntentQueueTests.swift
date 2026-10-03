import Foundation
import XCTest
@testable import Strand

final class PendingIntentQueueTests: XCTestCase {
    private func withQueue(_ body: (PendingIntentQueue, UserDefaults) throws -> Void) rethrows {
        let suite = "PendingIntentQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(PendingIntentQueue(defaults: defaults), defaults)
    }

    func testTypedMarksSurviveReloadWithTheirInvocationTimes() {
        withQueue { queue, defaults in
            let bedtime = Date(timeIntervalSince1970: 1_700_000_000.125)
            let wake = bedtime.addingTimeInterval(8 * 3_600)
            XCTAssertTrue(queue.append(.markBedtime, at: bedtime))
            XCTAssertTrue(queue.append(.markWake, at: wake))

            // A new queue instance drains after capture; its clock must never replace either instant.
            let requests = PendingIntentQueue(defaults: defaults).drain()
            XCTAssertEqual(requests.map(\.action), [.markBedtime, .markWake])
            XCTAssertEqual(requests.map(\.date), [bedtime, wake])
            XCTAssertEqual(requests.compactMap(\.sleepMark).map(\.tsMs),
                           [1_700_000_000_125, 1_700_028_800_125])
            XCTAssertEqual(requests.compactMap(\.sleepMark).map(\.metricPoint.value), [0, 1])
            XCTAssertTrue(queue.drain().isEmpty)
        }
    }

    func testLegacyActionsAndTimestampFormatRemainCompatible() {
        withQueue { queue, defaults in
            defaults.set(["markMoment", "buzz", "askCoach", "markMoment:1700000000.5"],
                         forKey: "noop.pendingIntents")
            let requests = queue.drain()
            XCTAssertEqual(requests.map(\.action), [.markMoment, .buzz, .askCoach, .markMoment])
            XCTAssertEqual(requests.map(\.date), [nil, nil, nil, Date(timeIntervalSince1970: 1_700_000_000.5)])
            XCTAssertTrue(requests.allSatisfy { $0.sleepMark == nil })
            XCTAssertNil(defaults.object(forKey: "noop.pendingIntents"))
        }
    }

    func testNewAndExistingRequestsShareTheSameOrderedQueue() {
        withQueue { queue, defaults in
            defaults.set(["buzz"], forKey: "noop.pendingIntents")
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            queue.append(.markWake, at: date)
            queue.append(.markMoment, at: date)
            XCTAssertEqual(defaults.stringArray(forKey: "noop.pendingIntents"),
                           ["buzz", "markWake:1700000000.0", "markMoment:1700000000.0"])
            XCTAssertEqual(queue.drain().map(\.action), [.buzz, .markWake, .markMoment])
        }
    }

    func testCoachQuestionWithColonsStillDrainsSeparately() {
        withQueue { queue, _ in
            queue.appendAskCoach(question: "Today: how was my sleep?", at: Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(queue.drain().map(\.action), [.askCoach])
            XCTAssertEqual(queue.consumeCoachQuestion(), "Today: how was my sleep?")
            XCTAssertNil(queue.consumeCoachQuestion())
        }
    }

    func testMalformedEntriesCannotBecomeMarksAtDrainTime() {
        withQueue { queue, defaults in
            defaults.set(["", ":", ":markWake", "unknown", "markWake", "markBedtime",
                          "markWake:", "markWake:not-a-time", "markWake:nan", "markBedtime:inf",
                          "markWake:1e300", "markMoment:1700000000:extra", "markWake:1700000000"],
                         forKey: "noop.pendingIntents")
            let requests = queue.drain()
            XCTAssertEqual(requests, [.init(action: .markWake, date: Date(timeIntervalSince1970: 1_700_000_000))])
            XCTAssertEqual(requests.first?.sleepMark?.type, .wake)
        }
    }

    func testUnavailableQueueOrMissingInvalidTimestampRejectsAppend() {
        XCTAssertFalse(PendingIntentQueue(defaults: nil).append(.markWake, at: Date()))
        withQueue { queue, defaults in
            XCTAssertFalse(queue.append(.markBedtime))
            XCTAssertFalse(queue.append(.markWake, at: Date(timeIntervalSince1970: .nan)))
            XCTAssertFalse(queue.append(.markWake, at: Date(timeIntervalSince1970: 1e300)))
            XCTAssertNil(defaults.object(forKey: "noop.pendingIntents"))
        }
    }
}
