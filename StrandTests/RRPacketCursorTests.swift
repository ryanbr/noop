import XCTest
import Combine
@testable import Strand

/// A handler reached from `LiveState`'s heart-rate AND R-R sinks — as `AppModel.ingestHR`, and through it the stress
/// check-in, is — takes each R-R packet once when it asks `RRPacketCursor`.
@MainActor
final class RRPacketCursorTests: XCTestCase {

    func testASequenceIsNewOnlyTheFirstTime() {
        var cursor = RRPacketCursor()
        XCTAssertFalse(cursor.isNew(0))   // nothing has arrived yet
        XCTAssertTrue(cursor.isNew(1))
        XCTAssertFalse(cursor.isNew(1))
        XCTAssertTrue(cursor.isNew(2))
    }

    /// Writes a real `LiveState` the way BLEManager's standard-HR path does — the packet's intervals first, then the
    /// heart rate only when it changed — and collects `live.rr` from both sinks, as AppModel wires them.
    private func feedStrap(_ packets: [(bpm: Int, rr: Int)], throughCursor: Bool) -> [Int] {
        let live = LiveState()
        var cursor = RRPacketCursor()
        var taken: [Int] = []
        let handler = {
            if throughCursor, !cursor.isNew(live.rrSeq) { return }
            taken.append(contentsOf: live.rr)
        }
        var subscriptions = Set<AnyCancellable>()
        live.$heartRate.sink { _ in handler() }.store(in: &subscriptions)
        live.$rr.sink { _ in handler() }.store(in: &subscriptions)
        for packet in packets {
            live.setRRIntervals([packet.rr])
            if live.heartRate != packet.bpm { live.heartRate = packet.bpm }
        }
        return taken
    }

    /// 21 packets, the heart rate moving every second one (and on the last, so it too is handed over).
    private let packets = (0...20).map { (bpm: 70 + $0 / 2, rr: 800 + $0) }

    func testEachPacketIsTakenOnceAndInOrder() {
        XCTAssertEqual(feedStrap(packets, throughCursor: true), packets.map(\.rr))
    }

    /// What the stress check-in did before: the same packets, read from both sinks with no cursor.
    func testWithoutTheCursorPacketsAreTakenMoreThanOnce() {
        let taken = feedStrap(packets, throughCursor: false)
        XCTAssertGreaterThan(taken.count, packets.count)
        XCTAssertEqual(Array(Set(taken)).sorted(), packets.map(\.rr))
    }
}
