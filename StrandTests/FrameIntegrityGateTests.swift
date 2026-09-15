import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// End-to-end, parser → consumer, for the state-driving gates this app owns (frame-integrity, E3):
/// the frame router, the history-metadata classifier, the clock correlation and the data-range reply.
///
/// Every frame below is a real or protocol-correct frame broken in exactly ONE way — a corrupted
/// header checksum, a declared length under the family minimum, a cut-off CRC32 trailer — so what the
/// consumer refuses is attributable to a single cause. Each test asserts the PRECONDITION that the
/// frame still decodes, because a gate that only ever sees unreadable bytes proves nothing.
///
/// `@MainActor`: `FrameRouter` and `LiveState` are main-actor types.
@MainActor
final class FrameIntegrityGateTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    /// The WHOOP 4.0 REALTIME_DATA frame the protocol package's own framing fixtures use (28 bytes,
    /// HR 60) — header checksum and payload CRC32 both verify. Reused rather than invented so the gate
    /// is exercised on the same bytes the decoder tests already pin.
    private let realtimeHex = "aa1800ff28020f3de10128663c0000000000000000000000da855212"

    /// The same frame with ONLY its CRC-8 header checksum broken. Its payload CRC32 still verifies —
    /// this is precisely the class that reached live state before the integrity gate.
    private func headerBroken() -> [UInt8] {
        var f = bytes(realtimeHex); f[3] ^= 0xFF; return f
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "testcentre.active.connection")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "testcentre.active.connection")
        UserDefaults.standard.removeObject(forKey: "testcentre.active.master")
        super.tearDown()
    }

    // MARK: - the router drives no state from a frame that is not intact

    func testRouterRejectsABrokenHeaderChecksum() {
        let frame = headerBroken()
        let parsed = parseFrame(frame, family: .whoop4)
        XCTAssertEqual(parsed.crcOK, true, "precondition: the payload CRC32 verifies")
        XCTAssertEqual(parsed.parsed["heart_rate"]?.intValue, 60, "precondition: the HR still decodes")

        let live = LiveState()
        let router = FrameRouter(state: live)
        router.handle(frame: frame)
        XCTAssertNil(live.heartRate, "a frame that is not intact must not reach live state")
        XCTAssertNil(live.lastFrameType, "…and must not be forwarded to any downstream consumer")
    }

    func testRouterAcceptsTheSameFrameIntact() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.handle(frame: bytes(realtimeHex))
        XCTAssertEqual(live.heartRate, 60, "control: the untouched frame still drives live state")
        XCTAssertEqual(live.lastFrameType, "REALTIME_DATA")
    }

    func testRouterRejectsADeclaredLengthBelowTheFamilyMinimum() {
        var frame = bytes(realtimeHex)
        frame[1] = 6; frame[2] = 0                       // declared 6 → total 10, under the 11-byte floor
        frame[3] = crc8(frame, 1, 3)                     // with a CORRECT checksum for that length word
        XCTAssertEqual(parseFrame(frame, family: .whoop4).rejectReason, .belowMinimumLength)

        let live = LiveState()
        FrameRouter(state: live).handle(frame: frame)
        XCTAssertNil(live.heartRate)
        XCTAssertNil(live.lastFrameType)
    }

    func testRouterRejectsATruncatedTrailer() {
        let frame = Array(bytes(realtimeHex).dropLast(2))
        let parsed = parseFrame(frame, family: .whoop4)
        XCTAssertEqual(parsed.rejectReason, .lengthMismatch)
        XCTAssertEqual(parsed.typeName, "REALTIME_DATA", "precondition: it still reads as a frame")

        let live = LiveState()
        FrameRouter(state: live).handle(frame: frame)
        XCTAssertNil(live.heartRate)
        XCTAssertNil(live.lastFrameType)
    }

    func testRouterRejectsTrailingBytes() {
        let frame = bytes(realtimeHex) + [0x00]
        XCTAssertEqual(parseFrame(frame, family: .whoop4).rejectReason, .lengthMismatch)
        let live = LiveState()
        FrameRouter(state: live).handle(frame: frame)
        XCTAssertNil(live.heartRate)
    }

    // MARK: - what the router SAYS about a rejection (D3)

    /// Rare-event evidence stays visible with every test mode OFF: the class that used to pass is the
    /// one the hardware run's abort criterion reads, and it costs nothing on a link where it never
    /// happens.
    func testTheClassThatUsedToPassIsAnnouncedWithoutAnyTestMode() {
        XCTAssertFalse(TestCentre.active(.connection))
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.handle(frame: headerBroken())
        XCTAssertEqual(router.rejectTally.payloadCRCOKButEnvelopeRejected, 1)
        XCTAssertEqual(router.rejectTally.count(.headerChecksumMismatch), 1)
        XCTAssertTrue(live.log.contains { $0.contains("payload CRC32 verified") },
                      "the always-on line must name the class: \(live.log)")
        // Announced ONCE, at the first sighting — a noisy link must not repeat it per frame.
        router.handle(frame: headerBroken())
        XCTAssertEqual(live.log.filter { $0.contains("payload CRC32 verified") }.count, 1)
        XCTAssertEqual(router.rejectTally.payloadCRCOKButEnvelopeRejected, 2, "…while the count keeps rising")
    }

    /// The ordinary per-connection detail is Test-Centre gated, and silent when the mode is off.
    func testPerConnectionRejectDetailIsGatedBehindTheConnectionDomain() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.handle(frame: Array(bytes(realtimeHex).dropLast(2)))   // lengthMismatch, CRC32 unknown
        XCTAssertTrue(live.taggedTail(domain: .connection).isEmpty,
                      "mode off must emit zero tagged lines: \(live.taggedTail(domain: .connection))")

        TestCentre.activate(.connection)
        defer { TestCentre.deactivate(.connection) }
        let live2 = LiveState()
        let router2 = FrameRouter(state: live2)
        router2.handle(frame: Array(bytes(realtimeHex).dropLast(2)))
        let tagged = live2.taggedTail(domain: .connection)
        XCTAssertEqual(tagged.count, 1, "one line per reason, got \(tagged)")
        XCTAssertTrue(tagged[0].contains("frameReject reason=lengthMismatch"), tagged[0])
        XCTAssertTrue(tagged[0].contains("type=REALTIME_DATA"),
                      "a rejected frame keeps its packet type in the diagnosis: \(tagged[0])")
        // One line per REASON, not per frame.
        router2.handle(frame: Array(bytes(realtimeHex).dropLast(2)))
        XCTAssertEqual(live2.taggedTail(domain: .connection).count, 1)
    }

    /// A byte run the reassembler drops never reaches the router at all; folding its monotonic counter
    /// in is what keeps its disappearance visible.
    func testReassemblerDropsAreFoldedIntoTheConnectionTally() {
        let live = LiveState()
        let router = FrameRouter(state: live)
        let r = Reassembler(family: .whoop4)
        let runt: [UInt8] = [0xAA, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]   // declares 8 total
        let completed = r.feed(runt + bytes(realtimeHex))
        router.noteReassemblerDrops(r.belowMinimumLengthDrops)
        XCTAssertEqual(completed.count, 1, "the stream resyncs onto the real frame")
        XCTAssertEqual(router.rejectTally.count(.belowMinimumLength), r.belowMinimumLengthDrops)
        XCTAssertGreaterThan(r.belowMinimumLengthDrops, 0)
    }

    // MARK: - the clock correlation takes no anchor from a frame that is not intact (2.14)

    /// A WHOOP 4.0 GET_CLOCK COMMAND_RESPONSE carrying a device clock value.
    ///
    /// The command byte must be the REAL `GET_CLOCK` opcode: the decoder only publishes `clock` when
    /// the schema resolves `frame[6]` to `GET_CLOCK`, so a made-up opcode yields a frame that verifies
    /// and parses but carries no anchor at all — a gate test written on one would pass while proving
    /// nothing about the gate.
    private func clockResponse() -> [UInt8] {
        // [type 36][seq][cmd = GET_CLOCK][resp_seq][result][clock u32 LE]
        frameFromPayload([0x0A, 0x01, 0x8F, 0x64, 0xE1, 0x01],
                         type: 36, seq: 1, cmd: WhoopCommand.getClock.rawValue)
    }

    /// The helper is only meaningful if it really carries an anchor — pinned separately so a future
    /// opcode change fails HERE, with the cause named, instead of quietly hollowing out the two gate
    /// tests below into assertions that nil equals nil.
    func testTheClockResponseHelperActuallyCarriesAClock() {
        let parsed = parseFrame(clockResponse(), family: .whoop4)
        XCTAssertEqual(parsed.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(parsed.parsed["clock"]?.intValue, 31_548_559,
                       "the helper must decode a clock, or the gate tests prove nothing")
    }

    func testClockRefIsTakenFromAnIntactResponse() {
        let parsed = parseFrame(clockResponse(), family: .whoop4)
        XCTAssertTrue(parsed.ok, "precondition: the response is intact")
        XCTAssertNotNil(parsed.parsed["clock"]?.intValue, "precondition: it carries a clock")
        XCTAssertNotNil(ClockCorrelation.clockRef(from: parsed, wall: 1_736_365_593),
                        "control: the useful path still anchors")
    }

    func testClockRefIsNotTakenFromABrokenHeaderChecksum() {
        var frame = clockResponse()
        frame[3] ^= 0xFF
        let parsed = parseFrame(frame, family: .whoop4)
        XCTAssertEqual(parsed.crcOK, true, "precondition: only the header checksum is broken")
        XCTAssertNotNil(parsed.parsed["clock"]?.intValue, "precondition: the clock value still decodes")
        XCTAssertNil(ClockCorrelation.clockRef(from: parsed, wall: 1_736_365_593),
                     "an anchor from a damaged frame mis-stamps every row that follows")
    }

    func testClockRefIsNotTakenFromADeclaredLengthBelowTheMinimum() {
        var frame = clockResponse()
        frame[1] = 6; frame[2] = 0
        frame[3] = crc8(frame, 1, 3)
        let parsed = parseFrame(frame, family: .whoop4)
        XCTAssertEqual(parsed.rejectReason, .belowMinimumLength)
        XCTAssertNil(ClockCorrelation.clockRef(from: parsed, wall: 1_736_365_593))
    }

    // MARK: - the data-range reply (2.15)

    /// A protocol-correct WHOOP 4.0 GET_DATA_RANGE COMMAND_RESPONSE (built here, not captured): its
    /// plausible-unix words are the window the offload judges every drained record against (#547).
    private func dataRangeResponse() -> [UInt8] {
        // The two-byte response header, a filler word, then the oldest and newest markers on the
        // 4-byte grid the oldest-scan reads (frame[11] and frame[15]).
        let payload: [UInt8] = [0x0A, 0x01, 0x00, 0x00,
                                0x00, 0xF1, 0x53, 0x65,      // 1_700_000_000 LE
                                0x70, 0xE1, 0x4C, 0x68]      // 1_749_868_912 LE
        return frameFromPayload(payload, type: 36, seq: 1, cmd: WhoopCommand.getDataRange.rawValue)
    }

    func testTheDataRangeWindowIsReadFromAnIntactReply() {
        let frame = dataRangeResponse()
        XCTAssertTrue(parseFrame(frame, family: .whoop4).ok, "precondition: intact")
        XCTAssertEqual(BLEManager.dataRangeOldestUnix(from: frame), 1_700_000_000)
        XCTAssertEqual(BLEManager.dataRangeNewestUnix(from: frame, wallNowUnix: 1_760_000_000),
                       1_749_868_912)
    }

    /// The gate the BLE seam applies before it hands this reply to `handleDataRangeResponse`: the
    /// bytes still scan to a window, and that is exactly why the verdict has to be consulted. A reply
    /// with a broken header checksum narrows the plausibility window, the sync's real records fall
    /// through it, the section persists nothing — and is acknowledged anyway.
    func testABrokenDataRangeReplyIsRefusedByTheVerdictTheSeamChecks() {
        var frame = dataRangeResponse()
        frame[3] ^= 0xFF
        let parsed = parseFrame(frame, family: .whoop4)
        XCTAssertFalse(parsed.ok, "the seam's condition is `parsed.ok`, and it must be false here")
        XCTAssertEqual(parsed.rejectReason, .headerChecksumMismatch)
        XCTAssertEqual(parsed.crcOK, true, "…even though the payload CRC32 verifies")
        // The scan itself is byte-level and would happily answer — which is the point of the gate.
        XCTAssertNotNil(BLEManager.dataRangeNewestUnix(from: frame, wallNowUnix: 1_760_000_000))
    }

    func testATruncatedDataRangeReplyIsRefusedByTheSameVerdict() {
        let frame = Array(dataRangeResponse().dropLast(2))
        XCTAssertFalse(parseFrame(frame, family: .whoop4).ok)
        XCTAssertEqual(parseFrame(frame, family: .whoop4).rejectReason, .lengthMismatch)
    }

    // MARK: - the app's own direct call into the verifier (2.5, the fifth caller)

    /// A 5/MG COMMAND_RESPONSE for one of the four ECG opcodes, in the puffin envelope the ECG probe's
    /// frame triage reads: type @8, cmd @10, result code @12.
    private func ecgProbeReply(result: UInt8 = 0x01) -> [UInt8] {
        puffinCommandFrame(cmd: WhoopCommand.toggleLabradorFiltered.rawValue, seq: 1,
                           payload: [0x42, result, 0x00, 0x00], type: 0x24)
    }

    /// `BLEManager.noteEcgProbeFrame` is the ONE place the app calls `verifyFrame` itself rather than
    /// going through a parser, and D2 requires each of the five direct callers to have its useful path
    /// shown intact under the tightened verifier. Here that path is: a well-formed reply verifies, and
    /// the probe's own decoder reads the outcome the report will state.
    func testTheEcgProbeGateStillAdmitsAWellFormedReply() {
        let frame = ecgProbeReply()
        XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok,
                      "the probe's gate is exactly this call; the useful path must stay open")
        XCTAssertEqual(frame[8], 0x24, "precondition: the triage's COMMAND_RESPONSE type byte")
        XCTAssertEqual(frame[10], WhoopCommand.toggleLabradorFiltered.rawValue,
                       "precondition: the triage's opcode byte")
        XCTAssertEqual(Whoop5EcgProbe.outcome(frame: frame), .success,
                       "control: the outcome the probe would report from this reply")
    }

    /// And the other half of why that gate is there. The result byte of a damaged reply still decodes,
    /// so without the verdict the probe would print the strongest claim it can make — a refusal or a
    /// success — about a frame the strap may never have sent that way. Silence is the correct output.
    func testTheEcgProbeGateRefusesADamagedReplyWhoseResultByteWouldStillDecode() {
        var frame = ecgProbeReply(result: 0x00)          // 0 = FAILURE, the loudest verdict
        frame[6] ^= 0xFF                                  // break only the CRC16 header checksum
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertFalse(check.ok, "the probe must read no byte of this frame")
        XCTAssertEqual(check.reason, .headerChecksumMismatch)
        XCTAssertEqual(check.crc32OK, true, "…while the payload CRC32 still verifies")
        XCTAssertEqual(Whoop5EcgProbe.outcome(frame: frame), .failure,
                       "the byte-level decode would happily answer — that is what the gate stops")
    }

    func testTheEcgProbeGateRefusesTrailingBytesAndTruncation() {
        XCTAssertEqual(verifyFrame(ecgProbeReply() + [0x00], family: .whoop5).reason, .lengthMismatch)
        XCTAssertEqual(verifyFrame(Array(ecgProbeReply().dropLast(2)), family: .whoop5).reason,
                       .lengthMismatch)
    }
}
