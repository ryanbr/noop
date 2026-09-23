import XCTest
import Combine
import WhoopProtocol
@testable import Strand

/// The live heart rate NOOP shows is cleared when the strap stops measuring, instead of the last reading standing on
/// every surface for as long as the link lasts.
@MainActor
final class LiveHeartRateReadabilityTests: XCTestCase {

    func testWhatCountsAsReadable() {
        XCTAssertTrue(LiveHeartRateReadability.isReadable(bpm: 62, contact: .supportedDetected))
        XCTAssertTrue(LiveHeartRateReadability.isReadable(bpm: 62, contact: .unsupported))   // no contact flag at all
        XCTAssertFalse(LiveHeartRateReadability.isReadable(bpm: 62, contact: .supportedNotDetected))
        XCTAssertFalse(LiveHeartRateReadability.isReadable(bpm: 0, contact: .unsupported))
        XCTAssertFalse(LiveHeartRateReadability.isReadable(bpm: 29, contact: .supportedDetected))
        XCTAssertFalse(LiveHeartRateReadability.isReadable(bpm: 221, contact: .supportedDetected))
    }

    /// One or two unreadable samples while worn clear nothing; a third in a row does, once.
    func testOnlyARunOfUnreadableSamplesClears() {
        var gate = LiveHeartRateReadability()
        XCTAssertFalse(gate.clearsShownHeartRate(bpm: 0, contact: .unsupported))
        XCTAssertFalse(gate.clearsShownHeartRate(bpm: 0, contact: .unsupported))
        XCTAssertFalse(gate.clearsShownHeartRate(bpm: 64, contact: .supportedDetected))   // a glitch, then back
        XCTAssertFalse(gate.clearsShownHeartRate(bpm: 0, contact: .unsupported))
        XCTAssertFalse(gate.clearsShownHeartRate(bpm: 60, contact: .supportedNotDetected))
        XCTAssertTrue(gate.clearsShownHeartRate(bpm: 0, contact: .unsupported))
        XCTAssertFalse(gate.clearsShownHeartRate(bpm: 0, contact: .unsupported))   // still off: cleared already
    }

    /// Surfaces listen to the heart rate; by the time it is cleared, the R-R packet must be gone too, or the median
    /// rebuilt from it and the banner, handed the old values, went on showing a number.
    func testClearingLeavesNothingForAHeartRateListener() {
        let live = LiveState()
        live.setRRIntervals([800])
        live.heartRate = 70
        let seqBefore = live.rrSeq
        var seen: [(hr: Int?, rr: [Int])] = []
        var subscriptions = Set<AnyCancellable>()
        live.$heartRate.dropFirst().sink { hr in seen.append((hr, live.rr)) }.store(in: &subscriptions)

        live.clearLiveHeartRate()

        XCTAssertEqual(seen.count, 1)
        XCTAssertNil(seen.first?.hr)
        XCTAssertEqual(seen.first?.rr, [])
        XCTAssertNil(live.heartRate)
        XCTAssertEqual(live.rrSeq, seqBefore)   // no new packet: packet consumers are not woken
    }
}
