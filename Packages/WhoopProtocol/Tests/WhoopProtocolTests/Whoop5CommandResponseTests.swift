import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") COMMAND_RESPONSE (type 36) decode, verified against real captured frames.
///
/// WHOOP 5 reuses the 4.0 command NUMBERS on the puffin transport (response command at frame[10], the
/// 4.0 frame[6] + 4), but the response PAYLOADS diverge from 4.0 — so each field is mapped from a real
/// capture (firmware 50.38.1.0), not ported on faith:
///   • battery: direct percent at pay[2] (the 4.0 deci-percent ÷10 is gone; 47% confirmed vs the app);
///   • data-range: real-unix timestamps as 4-byte-aligned u32s → history window;
///   • firmware version + device name: from the GET_HELLO info block.
///
/// The battery and data-range fixtures are real frames (verified token-free). The GET_HELLO fixture is
/// **synthetic** — a hand-built frame with a fake device name and the version bytes at their real
/// offsets — so the real device name and session token never enter a committed fixture.
final class Whoop5CommandResponseTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// Real GET_BATTERY_LEVEL(26) response: payload `02 01 2f …` → 0x2f = 47%.
    private let batteryHex = "aa0110000100208124931a02012f000000000000f1c132cb"

    func testBatteryIsDirectPercent() {
        let f = parseFrame(bytes(batteryHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["battery_pct"]?.doubleValue, 47)   // NOT 4.7 — the ÷10 is dropped
    }

    /// Real GET_DATA_RANGE(34) long response: aligned u32 timestamps spanning 2026-05-10 … 2026-06-08.
    private let dataRangeHex =
        "aa014c00010032d124982207010180b901005ab7010048b901005ab701001000000000000200da1b00000ee31d00b0e1ff69d7430000a3ab266a3d4a0000a3ab266a3d4a00007cc7266a5c4f00000000623977f5"

    func testDataRangeHistoryWindow() {
        let f = parseFrame(bytes(dataRangeHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["history_oldest"]?.intValue, 1778377136)   // 2026-05-10
        XCTAssertEqual(f.parsed["history_newest"]?.intValue, 1780926332)   // 2026-06-08
    }

    /// SYNTHETIC GET_HELLO(145): fake device name "WHOOP-FAKE01" at pay[16], fw 50.38.1.0 at pay[93];
    /// everything else zeroed — no real name, no session token.
    private let helloHex =
        "aa0174000001ffe12401910000000000000000000000000000000057484f4f502d46414b453031000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000032260100000000000000000000000000a30d90ed"

    func testHelloDeviceNameAndFirmware() {
        let f = parseFrame(bytes(helloHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["device_name"]?.stringValue, "WHOOP-FAKE01")
        XCTAssertEqual(f.parsed["fw_version"]?.stringValue, "50.38.1.0")
    }

    /// SYNTHETIC all-zero GET_HELLO: the guards must fail closed — no device name, no firmware.
    private let helloZeroHex =
        "aa0174000001ffe12402910000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000063ef7ada"

    func testHelloGuardsFailClosed() {
        let f = parseFrame(bytes(helloZeroHex), family: .whoop5)
        XCTAssertEqual(f.crcOK, true)
        XCTAssertNil(f.parsed["device_name"])   // pay[16] == 0 → no printable name
        XCTAssertNil(f.parsed["fw_version"])     // pay[93] != 50 → fails the generation guard
    }

    /// Real WHOOP 5 MG (`WS50_r03`) replies to the three ECG/Labrador toggles, posted in #891.
    ///
    /// Committed because they are the only real 5/MG COMMAND_RESPONSE frames in the tree whose payload is
    /// inert — `01 01 00 00` carries no device name, serial or session token — and because they exercise
    /// the generic response path for commands NOOP does not send, which the battery / data-range / hello
    /// fixtures above do not. The Kotlin twin asserts the identical values in `CommandCatalogueTest`; that
    /// pairing is the point, since Android labelled these from its sender enum and rendered them as bare
    /// hex until #891.
    ///
    /// Decode only. No claim is made here about what the strap did with the commands — all three answered
    /// SUCCESS and produced no ECG data, which is the open question in #891, not something a test settles.
    ///
    /// Now asserts `resp_seq` and `result` alongside `resp_cmd`, matching the Kotlin twin field for field.
    /// When these fixtures landed this decoder published neither, which is how that divergence was found;
    /// #894 closed it, so the two suites finally agree on every field of the same bytes.
    private let mgToggleReplies: [(hex: String, cmd: String, seq: Int)] = [
        ("aa010c000100271124148b2f01010000845a1705", "TOGGLE_LABRADOR_FILTERED(139)", 47),
        ("aa010c000100271124157d300101000067ab1b82", "TOGGLE_LABRADOR_RAW_SAVE(125)", 48),
        ("aa010c000100271124167c3101010000ef4bcf45", "TOGGLE_LABRADOR_DATA_GENERATION(124)", 49),
    ]

    func testMgToggleRepliesDecode() {
        for reply in mgToggleReplies {
            let f = parseFrame(bytes(reply.hex), family: .whoop5)
            XCTAssertEqual(f.typeName, "COMMAND_RESPONSE", reply.cmd)
            XCTAssertEqual(f.crcOK, true, reply.cmd)
            XCTAssertEqual(f.parsed["resp_cmd"]?.stringValue, reply.cmd)
            XCTAssertEqual(f.parsed["resp_seq"]?.intValue, reply.seq)
            XCTAssertEqual(f.parsed["result"]?.stringValue, "SUCCESS(1)")
        }
    }

    /// The battery reply already in this file, now also asserting the two new fields — it is the one real
    /// 5/MG fixture whose value byte is independently known (47%), so it pins that publishing `resp_seq`
    /// and `result` did not shift the payload offsets the value decode reads from.
    func testBatteryReplyAlsoReportsSeqAndResult() {
        let f = parseFrame(bytes(batteryHex), family: .whoop5)
        XCTAssertEqual(f.parsed["resp_seq"]?.intValue, 2)
        XCTAssertEqual(f.parsed["result"]?.stringValue, "SUCCESS(1)")
        XCTAssertEqual(f.parsed["battery_pct"]?.doubleValue, 47)
    }

    /// A real `SELECT_WRIST(123)` pair from the same MG, one accepted and one refused (#891).
    ///
    /// These are the first REAL 5/MG frames in the tree carrying `result = FAILURE(0)` — every other
    /// non-SUCCESS fixture here is a synthetic `GET_HELLO`. So until now the FAILURE branch of this
    /// decoder had never been exercised by bytes a strap actually sent, on this family. They are also a
    /// success/failure pair on ONE opcode, which is the shape that made the 4.0 result mapping credible
    /// (`GET_EXTENDED_BATTERY_INFO` answering both ways) — 5/MG now has its own.
    ///
    /// Provenance: WHOOP 5 MG `WS50_r03`, build 215, posted with the raw frames in #891. Payload is inert —
    /// `01 01 00 00` and `00 01 00 00`, no name, serial or token. Both re-verified here: CRC16-Modbus
    /// header, CRC32 tail, declared length.
    ///
    /// The strap accepted `arg=1` and refused `arg=0` minutes apart in one session, so the refusal is not
    /// "the opcode is unknown". Whether that is a strap refusing a real mutation or `0` simply not being a
    /// valid argument is open — `docs/PROTOCOL.md` flags the right=0/left=1 mapping as inferred from the
    /// vendor client's enum order, never attested. Nothing here decides it; the frames are pinned so the
    /// decode of both outcomes is fixed while the meaning is argued elsewhere.
    func testRealMgSelectWristAcceptedAndRefused() {
        let accepted = parseFrame(bytes("aa010c000100271124d77b81010100007ce76722"), family: .whoop5)
        XCTAssertEqual(accepted.crcOK, true)
        XCTAssertEqual(accepted.parsed["resp_cmd"]?.stringValue, "SELECT_WRIST(123)")
        XCTAssertEqual(accepted.parsed["resp_seq"]?.intValue, 129)
        XCTAssertEqual(accepted.parsed["result"]?.stringValue, "SUCCESS(1)")

        let refused = parseFrame(bytes("aa010c000100271124217bcc000100000213163d"), family: .whoop5)
        XCTAssertEqual(refused.crcOK, true)
        XCTAssertEqual(refused.parsed["resp_cmd"]?.stringValue, "SELECT_WRIST(123)")
        XCTAssertEqual(refused.parsed["resp_seq"]?.intValue, 204)
        XCTAssertEqual(refused.parsed["result"]?.stringValue, "FAILURE(0)")
    }

    /// Byte 13 — the first response-payload byte, where `GET_BATTERY_LEVEL` returns its percent — is `0x01`
    /// in every one of these replies, and is deliberately NOT decoded into a field.
    ///
    /// #891 has since narrowed what it is without settling it. A `SELECT_WRIST` sent with `arg=0` came back
    /// with byte 13 = 1, which refutes the echo reading outright — an echo would have returned 0. It does
    /// not establish the read-back reading, though: across all eight MG command responses on record, over
    /// four opcodes and both result codes, byte 13 has taken exactly one value. A constant fits every
    /// observation as well as stored state does, and is simpler. Separating them needs a reply whose stored
    /// value is 0 — a strap set to the other wrist.
    ///
    /// So the slot stays undecoded, for a sharper reason than before: naming it would encode the unproven
    /// half of a result that only refuted the alternative. Fail closed (#194).
    func testNoValueIsInventedFromAToggleReply() {
        let f = parseFrame(bytes(mgToggleReplies[0].hex), family: .whoop5)
        XCTAssertNil(f.parsed["battery_pct"])
    }
}
