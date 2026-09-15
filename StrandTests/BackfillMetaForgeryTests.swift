import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// Scenario "Zustandstreibende Tore fordern das volle Urteil / Verlaufs-Metadaten können nicht
/// gefälscht werden", end to end through the offload state machine (E3): parser → history-metadata
/// classifier → trim acknowledgement.
///
/// This is the P0 path of the whole change. A HISTORY_END the app acts on advances the trim cursor and
/// acknowledges the strap, which frees the records it just sent. A frame that only LOOKS like one —
/// a wrong header checksum, a declared length under the family minimum, a cut-off CRC32 trailer —
/// must therefore reach neither the acknowledgement nor the chunk boundary.
///
/// Each frame is a protocol-correct HISTORY_END — built here, at the 25-byte size a real one has —
/// broken in exactly ONE way, and every test asserts up front that the frame still decodes as a
/// HISTORY_END. Without that precondition a passing test would only prove that unreadable bytes are
/// unreadable.
final class BackfillMetaForgeryTests: XCTestCase {

    private final class NoopStore: BackfillStoreWriting {
        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (streams.hr.count, streams.rr.count, 0, 0,
             streams.spo2.count, streams.skinTemp.count, streams.resp.count, streams.gravity.count)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// A protocol-correct WHOOP 4.0 HISTORY_END (METADATA, meta_type 2) carrying unix + trim cursor.
    private func historyEndFrame(unix: UInt32 = 1_700_000_000, trim: UInt32 = 70_476) -> [UInt8] {
        frameFromPayload(le32(unix) + [0, 0] + le32(0) + le32(trim), type: 49, seq: 0, cmd: 2)
    }

    /// Collects every trim acknowledgement the Backfiller issues. `@MainActor` because `Backfiller` is.
    @MainActor private func makeBackfiller(_ acks: @escaping (UInt32) -> Void) -> Backfiller {
        Backfiller(store: NoopStore(), deviceId: "test", ackTrim: { trim, _ in acks(trim) })
    }

    // MARK: - control: the intact frame does acknowledge

    @MainActor func testAnIntactHistoryEndAcknowledgesTheTrim() async {
        var acked: [UInt32] = []
        let backfiller = makeBackfiller { acked.append($0) }
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(historyEndFrame())
        XCTAssertEqual(acked, [70_476], "control: a real HISTORY_END must still advance the offload")
    }

    // MARK: - a forged or damaged HISTORY_END acknowledges nothing

    @MainActor func testAHistoryEndWithABrokenHeaderChecksumAcknowledgesNothing() async {
        var frame = historyEndFrame()
        frame[3] ^= 0xFF                                   // CRC-8 over the length field only
        let parsed = parseFrame(frame, family: .whoop4)
        XCTAssertEqual(parsed.crcOK, true, "precondition: the payload CRC32 still verifies")
        XCTAssertEqual(parsed.parsed["meta_type"], .string("HISTORY_END(2)"),
                       "precondition: it still decodes as a history end")
        XCTAssertEqual(parsed.parsed["trim_cursor"]?.intValue, 70_476,
                       "precondition: the trim cursor it carries is readable")

        var acked: [UInt32] = []
        let backfiller = makeBackfiller { acked.append($0) }
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(frame)
        XCTAssertTrue(acked.isEmpty,
                      "acking on this frame frees records the strap would then delete, got \(acked)")
    }

    @MainActor func testAHistoryEndWithADeclaredLengthBelowTheMinimumAcknowledgesNothing() async {
        var frame = historyEndFrame()
        frame[1] = 6; frame[2] = 0                         // declared 6 → total 10, under the 11-byte floor
        frame[3] = crc8(frame, 1, 3)                       // with a CORRECT checksum for that word
        XCTAssertEqual(parseFrame(frame, family: .whoop4).rejectReason, .belowMinimumLength)

        var acked: [UInt32] = []
        let backfiller = makeBackfiller { acked.append($0) }
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(frame)
        XCTAssertTrue(acked.isEmpty, "got \(acked)")
    }

    @MainActor func testAHistoryEndWithATruncatedTrailerAcknowledgesNothing() async {
        let frame = Array(historyEndFrame().dropLast(2))
        let parsed = parseFrame(frame, family: .whoop4)
        XCTAssertEqual(parsed.rejectReason, .lengthMismatch)
        XCTAssertEqual(parsed.parsed["meta_type"], .string("HISTORY_END(2)"),
                       "precondition: without the gate this frame WOULD read as a history end")

        var acked: [UInt32] = []
        let backfiller = makeBackfiller { acked.append($0) }
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(frame)
        XCTAssertTrue(acked.isEmpty, "got \(acked)")
    }

    @MainActor func testAHistoryEndWithTrailingBytesAcknowledgesNothing() async {
        let frame = historyEndFrame() + [0x00, 0x00]
        XCTAssertEqual(parseFrame(frame, family: .whoop4).rejectReason, .lengthMismatch)

        var acked: [UInt32] = []
        let backfiller = makeBackfiller { acked.append($0) }
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(frame)
        XCTAssertTrue(acked.isEmpty, "got \(acked)")
    }

    /// The other half of the forgery: HISTORY_COMPLETE ends the whole offload. A damaged one must not
    /// close a session that is still mid-flight.
    @MainActor func testADamagedHistoryCompleteDoesNotEndTheOffload() async {
        var complete = frameFromPayload([], type: 49, seq: 0, cmd: 3)
        complete[3] ^= 0xFF
        XCTAssertEqual(parseFrame(complete, family: .whoop4).parsed["meta_type"],
                       .string("HISTORY_COMPLETE(3)"), "precondition: it still decodes as complete")

        let backfiller = makeBackfiller { _ in }
        backfiller.begin(family: .whoop4)
        XCTAssertTrue(backfiller.isBackfilling, "precondition: the session is open")
        await backfiller.ingest(complete)
        XCTAssertTrue(backfiller.isBackfilling, "a damaged HISTORY_COMPLETE must not close the session")

        // Control: the same frame INTACT does close it, so the gate is what made the difference.
        let control = makeBackfiller { _ in }
        control.begin(family: .whoop4)
        await control.ingest(frameFromPayload([], type: 49, seq: 0, cmd: 3))
        XCTAssertFalse(control.isBackfilling)
    }

    // MARK: - the acknowledgement block is EXEMPT from the payload bound (D7, decision 4)

    /// The eight bytes the trim acknowledgement mirrors back to the strap reach INTO the CRC32 trailer
    /// by design: on the real 25-byte HISTORY_END the trailer starts at 21 and the block runs 17…25.
    /// It is an opaque echo, not a decoded field, so the payload bound that now clamps every named
    /// field must not touch it.
    ///
    /// This is the CALLER-side half of that exemption. The protocol package pins the slice itself; what
    /// is pinned here is that the app's own reader still hands eight bytes to the ack. Clamped to the
    /// trailer it would yield four, and the strap would be acknowledged with a block it never sent —
    /// either it refuses the acknowledgement and the offload stops, or it trims on an altered block.
    /// Both outcomes are the permanent data loss this whole change exists to prevent, arriving through
    /// the fix rather than the bug.
    @MainActor func testTheWhoop4AcknowledgementBlockIsEightBytesAndReachesIntoTheTrailer() {
        let frame = historyEndFrame()
        XCTAssertEqual(frame.count, 25, "precondition: the real HISTORY_END size the exemption is about")
        let declared = Int(frame[1]) | (Int(frame[2]) << 8)
        XCTAssertEqual(declared, 21, "precondition: the CRC32 trailer starts at 21")

        let endData = Backfiller.endData(from: frame, family: .whoop4)
        XCTAssertEqual(endData?.count, 8, "eight bytes, not the four a trailer clamp would leave")
        XCTAssertEqual(endData, Array(frame[17..<25]), "…and exactly the bytes at 17…25, unaltered")
        XCTAssertNotEqual(endData, Array(frame[17..<21]) + [0, 0, 0, 0],
                          "a clamped-then-padded block is not the same echo")
    }

    /// The 5/MG twin of the same slice (frame[21…29]), so a later tidy-up cannot narrow one family
    /// while the other keeps working.
    @MainActor func testTheWhoop5AcknowledgementBlockIsAlsoEightBytes() {
        let frame = puffinCommandFrame(cmd: 2, seq: 0,
                                       payload: [UInt8](repeating: 7, count: 20), type: 49)
        XCTAssertGreaterThanOrEqual(frame.count, 29, "precondition: long enough to hold the block")
        let endData = Backfiller.endData(from: frame, family: .whoop5)
        XCTAssertEqual(endData?.count, 8)
        XCTAssertEqual(endData, Array(frame[21..<29]))
    }

    /// The guard the exemption does keep: a frame too short to hold the block yields nil rather than a
    /// short read. Not-enough-bytes is a different answer from four-bytes-because-we-clamped.
    @MainActor func testAFrameTooShortForTheBlockYieldsNilRatherThanAShortRead() {
        XCTAssertNil(Backfiller.endData(from: frameFromPayload([], type: 49, seq: 0, cmd: 2),
                                        family: .whoop4))
    }
}
