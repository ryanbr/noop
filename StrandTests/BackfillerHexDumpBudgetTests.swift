import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// #1992: the reject hex dump spends ONE budget for the connection, not a fresh per-chunk allowance.
///
/// The dump is the only channel that carries an unmapped layout's raw bytes to someone who can map it.
/// Bounded per chunk with no session cap, it defeated itself on exactly the straps it exists for: ~25
/// rejects per chunk, many chunks, many sessions per connection, 8 long hex lines each time, flooding a
/// 2000-line rolling log and evicting its own earlier dumps.
///
/// Kotlin twin: `RejectHexDumpBudgetTest`, which mirrors the six arithmetic cases. The scope test at
/// the end has NO Kotlin counterpart on purpose: constructing an Android `Backfiller` in a plain JVM
/// test needs a repository over a 152-method DAO with no fake in the tree, whereas Swift's store is a
/// protocol with existing test fakes. The invariant is identical on both sides; only one platform can
/// currently assert it.
final class BackfillerHexDumpBudgetTests: XCTestCase {

    private let cap = 8

    @MainActor func testAChunkNeverDumpsMoreThanThePerChunkCap() {
        XCTAssertEqual(Backfiller.hexDumpAllowance(50, 24), cap)
    }

    @MainActor func testAChunkNeverDumpsMoreThanItRejected() {
        XCTAssertEqual(Backfiller.hexDumpAllowance(3, 24), 3)
    }

    /// The point of the change: successive chunks drain one budget rather than each getting a fresh 8.
    @MainActor func testSuccessiveChunksDrainTheOneBudget() {
        var budget = Backfiller.rejectHexDumpBudget
        var dumped = 0
        for _ in 0 ..< 10 {
            let n = Backfiller.hexDumpAllowance(25, budget)
            dumped += n
            budget -= n
        }
        XCTAssertEqual(dumped, Backfiller.rejectHexDumpBudget,
                       "ten chunks must not exceed the one budget")
        XCTAssertEqual(budget, 0)
    }

    /// Once spent, later chunks dump nothing, which is what stops the flood.
    @MainActor func testAnExhaustedBudgetDumpsNothing() {
        XCTAssertEqual(Backfiller.hexDumpAllowance(25, 0), 0)
    }

    /// Never negative, however the counters are driven.
    @MainActor func testTheAllowanceIsNeverNegative() {
        XCTAssertEqual(Backfiller.hexDumpAllowance(0, 24), 0)
        XCTAssertEqual(Backfiller.hexDumpAllowance(25, -5), 0)
    }

    /// The budget must clear more than one chunk, or the sample cannot span an offload.
    @MainActor func testTheBudgetIsWorthMoreThanOneChunk() {
        XCTAssertGreaterThan(Backfiller.rejectHexDumpBudget, cap)
    }

    // MARK: - The budget's SCOPE, which the arithmetic above cannot pin

    /// A minimal store, mirroring the fakes the other Backfiller suites use. The protocol has no default
    /// implementations, so every requirement is stubbed here.
    private final class NoopStore: BackfillStoreWriting {
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    /// The budget must NOT reset when a session begins.
    ///
    /// This is the half of the change the pure arithmetic cannot see: `hexDumpAllowance` behaves
    /// identically whether the budget is per session or per connection, so a test of it alone passes
    /// either way. The auto-continue re-kicks up to 24 sessions per connection, so a per-session budget
    /// would permit 24 x 24 frames and flood the rolling log exactly as before, which is the shape the
    /// reporter hit. Same reasoning as `lastAckedTrim`, which is likewise not reset in `begin()`.
    @MainActor func testBeginDoesNotRefillTheBudget() {
        let backfiller = Backfiller(store: NoopStore(), deviceId: "test", ackTrim: { _, _ in }, log: { _ in })
        XCTAssertEqual(backfiller.rejectHexBudget, Backfiller.rejectHexDumpBudget)

        backfiller.begin(family: .whoop4)
        XCTAssertEqual(backfiller.rejectHexBudget, Backfiller.rejectHexDumpBudget,
                       "a fresh Backfiller starts full, so this only shows begin() did not zero it")

        // A second session must inherit whatever the first spent, not start over.
        backfiller.begin(family: .whoop4)
        XCTAssertEqual(backfiller.rejectHexBudget, Backfiller.rejectHexDumpBudget,
                       "begin() must never refill the budget: the rolling log it protects belongs to "
                        + "the process, not to one offload session")
    }

    // MARK: - #891: the unmapped-type dump line

    /// The census names a type; this has to find the bytes that earned the name, and the byte count is
    /// derived from those bytes so the number and the payload beside it cannot disagree.
    @MainActor func testUnmappedTypeDumpLineSelectsTheMatchingFrame() {
        let frames: [[UInt8]] = [[0x01, 0x02], [0xaa, 0xbb, 0xcc, 0xdd]]
        let names = ["HISTORICAL_DATA", "type53"]
        let line = Backfiller.unmappedTypeDumpLine(typeName: "type53", frames: frames, typeNames: names)
        XCTAssertEqual(line, "Backfill: unmapped type type53 first frame 4B: aabbccdd")
    }

    /// The FIRST frame of that type, not the last: a long offload of one unmapped type costs one dump.
    @MainActor func testUnmappedTypeDumpLineTakesTheFirstMatch() {
        let frames: [[UInt8]] = [[0x11], [0x22]]
        let names = ["type53", "type53"]
        let line = Backfiller.unmappedTypeDumpLine(typeName: "type53", frames: frames, typeNames: names)
        XCTAssertEqual(line, "Backfill: unmapped type type53 first frame 1B: 11")
    }

    /// No frame of that type in this chunk means no line, rather than an empty dump that reads like the
    /// strap sent nothing. This is the case that would have shipped silently: reading `ParsedFrame.rawHex`
    /// here returns "" on the ingest fast path (`collectFields: false`), so every real offload would have
    /// logged a dump with no bytes in it while any test building its own ParsedFrame passed.
    @MainActor func testUnmappedTypeDumpLineIsNilWhenNoFrameMatches() {
        let frames: [[UInt8]] = [[0x01, 0x02]]
        XCTAssertNil(Backfiller.unmappedTypeDumpLine(typeName: "type53", frames: frames,
                                                    typeNames: ["HISTORICAL_DATA"]))
    }

    /// The full frame rides the line - no prefix cap, for the reason the reject dump has none: an unmapped
    /// layout's fields are as likely to sit in the tail as the head.
    @MainActor func testUnmappedTypeDumpLineDoesNotTruncate() {
        let raw = [UInt8](repeating: 0xab, count: 600)
        let line = Backfiller.unmappedTypeDumpLine(typeName: "type53", frames: [raw], typeNames: ["type53"])
        XCTAssertTrue(line?.hasSuffix(String(repeating: "ab", count: 600)) == true)
        XCTAssertTrue(line?.contains("600B") == true)
    }
}
