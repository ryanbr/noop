import XCTest
@testable import WhoopProtocol

/// #891: the ECG raw-data gate — the write allowlist, the body it builds, and the mandatory read-back.
///
/// The allowlist tests are the point of this file. `DeviceConfigWriteGate.admitsSend` is the SAME
/// predicate the 5/MG send path consults, so proving here that it refuses an opcode or a key is proving
/// it about the real wire path rather than about a copy of the rule.
final class DeviceConfigWriteGateTests: XCTestCase {

    // MARK: - Helpers

    /// The payload the send path would hold for a device-config write of `key`.
    private func payload(key: String, value: UInt8 = 0x31) -> [UInt8] {
        [0x01] + Whoop5Config.deviceConfigBody(name: key, value: value)
    }

    /// A real 5/MG COMMAND_RESPONSE frame carrying `record` for command 121, CRC16 header + CRC32 body,
    /// so `DeviceConfigReadProbe.parse` runs its CRC gate on these fixtures rather than being bypassed.
    /// Same construction as the #103 read-probe tests.
    private func readBackFrame(record: [UInt8], cmd: UInt8 = 121, result: UInt8 = 1) -> [UInt8] {
        var inner: [UInt8] = [36, 1, cmd, 0x0A, result] + record       // type, seq, cmd, 2-byte hdr, record
        let pad = (4 - inner.count % 4) % 4
        if pad > 0 { inner += [UInt8](repeating: 0, count: pad) }
        let declLen = inner.count + 4
        var frame: [UInt8] = [0xAA, 0x01, UInt8(declLen & 0xFF), UInt8((declLen >> 8) & 0xFF), 0x00, 0x01]
        let c16 = crc16Modbus(Array(frame[0..<6]))
        frame += [UInt8(c16 & 0xFF), UInt8((c16 >> 8) & 0xFF)]
        frame += inner
        let c32 = crc32(inner)
        frame += [UInt8(c32 & 0xFF), UInt8((c32 >> 8) & 0xFF), UInt8((c32 >> 16) & 0xFF), UInt8((c32 >> 24) & 0xFF)]
        return frame
    }

    /// A 121 reply record echoing `key` in a 32-byte NUL-padded field, then `value` as ASCII.
    private func echoRecord(key: String, value: String) -> [UInt8] {
        var rec = [UInt8](repeating: 0, count: DeviceConfigWriteGate.nameFieldBytes)
        for (i, b) in Array(key.utf8).enumerated() where i < rec.count { rec[i] = b }
        return rec + Array(value.utf8)
    }

    // MARK: - The allowlist: what it admits

    func testAdmitsEcgKeyOnlyWhenOptedInOnAnAttestedMG() {
        let p = payload(key: DeviceConfigWriteGate.ecgRawDataKey)
        // The one combination that is allowed.
        XCTAssertTrue(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: true, isMG: true, broadcastHrOptIn: false))
        // Opt-in off — a default install can never form these bytes.
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: false, isMG: true, broadcastHrOptIn: false))
        // Opted in but the strap is not an attested MG (a plain 5.0, or DIS not read yet).
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: true, isMG: false, broadcastHrOptIn: false))
        // The Broadcast-HR opt-in must NOT carry the ECG key — that cross-authorisation is the exact
        // hole the key-aware gate closes.
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: false, isMG: true, broadcastHrOptIn: true))
    }

    func testAdmitsBroadcastHrKeyOnlyUnderItsOwnOptIn() {
        let p = payload(key: DeviceConfigWriteGate.broadcastHrKey)
        XCTAssertTrue(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: false, isMG: false, broadcastHrOptIn: true))
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: false, isMG: false, broadcastHrOptIn: false))
        // The ECG opt-in must not carry the Broadcast-HR key either — the rule runs both ways.
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: true, isMG: true, broadcastHrOptIn: false))
        // Broadcast HR is not MG-gated: it works on a plain 5.0, and must keep doing so.
        XCTAssertTrue(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: p, ecgGateOptIn: true, isMG: false, broadcastHrOptIn: true))
    }

    func testAdmitsBroadcastHrDisableWriteRegardlessOfOptIn() {
        // #1061: turning the Broadcast-HR flag OFF is the safe UNDO and must NOT be gated on the opt-in —
        // it is already false by the time the user disables, which made the toggle-off path dead (the
        // disable refused here, strap left advertising). The OFF write must be admitted with NO opt-in.
        let off = payload(key: DeviceConfigWriteGate.broadcastHrKey, value: DeviceConfigWriteGate.disabledValue)
        XCTAssertTrue(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: off, ecgGateOptIn: false, isMG: false, broadcastHrOptIn: false))
        XCTAssertTrue(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: off, ecgGateOptIn: false, isMG: false, broadcastHrOptIn: true))
        // The ON write stays gated on the opt-in — the exemption is for OFF only.
        let on = payload(key: DeviceConfigWriteGate.broadcastHrKey, value: DeviceConfigWriteGate.enabledValue)
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: on, ecgGateOptIn: false, isMG: false, broadcastHrOptIn: false))
        // The OFF exemption is Broadcast-HR ONLY: the ECG key's OFF write is still gated on its own opt-in
        // (a mandatory read-back gate, #891) — the exemption must not leak to it.
        let ecgOff = payload(key: DeviceConfigWriteGate.ecgRawDataKey, value: DeviceConfigWriteGate.disabledValue)
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: ecgOff, ecgGateOptIn: false, isMG: true, broadcastHrOptIn: false))
    }

    // MARK: - The allowlist: what it refuses

    func testRefusesEveryOtherEnumeratedKeyEvenWithBothOptInsOn() {
        // The five keys the strap listed that this app has no business writing. Every one refused, with
        // both opt-ins on and an attested MG — the most permissive state that exists.
        for key in DeviceConfigWriteGate.outOfScopeKeys {
            XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
                opcode: 119, payload: payload(key: key),
                ecgGateOptIn: true, isMG: true, broadcastHrOptIn: true),
                "\(key) must never be writable from this path")
        }
        XCTAssertEqual(DeviceConfigWriteGate.outOfScopeKeys.count, 5)
        // The five out-of-scope keys plus the two writable ones are exactly what the strap enumerated.
        XCTAssertEqual(Set(DeviceConfigWriteGate.outOfScopeKeys)
                        .union([DeviceConfigWriteGate.ecgRawDataKey, DeviceConfigWriteGate.broadcastHrKey]),
                       Set(DeviceConfigWriteGate.enumeratedKeys))
        XCTAssertEqual(DeviceConfigWriteGate.enumeratedKeys.count, 7)
    }

    func testRefusesSetFeatureFlagValue120ForEveryKeyAndEveryOptIn() {
        // 120 is the OTHER namespace's write verb (the R22 sequence). It must be unreachable from here
        // no matter what the body says or which opt-ins are on.
        for key in DeviceConfigWriteGate.enumeratedKeys + Whoop5Config.enableR22Sequence.map(\.name) {
            for ecg in [true, false] {
                for hr in [true, false] {
                    XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
                        opcode: DeviceConfigWriteGate.setFeatureFlagValueCmd, payload: payload(key: key),
                        ecgGateOptIn: ecg, isMG: true, broadcastHrOptIn: hr),
                        "SET_FF_VALUE(120) must never be admitted (key=\(key))")
                }
            }
        }
    }

    func testRefusesEveryOtherOpcodeInTheWholeByteRange() {
        // Exhaustive: with both opt-ins on, an attested MG, and a body carrying the one writable key,
        // 119 is the ONLY opcode this gate admits. All 255 others are refused.
        let p = payload(key: DeviceConfigWriteGate.ecgRawDataKey)
        var admitted: [UInt8] = []
        for opcode in UInt8.min...UInt8.max {
            if DeviceConfigWriteGate.admitsSend(opcode: opcode, payload: p,
                                                ecgGateOptIn: true, isMG: true, broadcastHrOptIn: true) {
                admitted.append(opcode)
            }
        }
        XCTAssertEqual(admitted, [DeviceConfigWriteGate.setDeviceConfigValueCmd])
    }

    func testRefusesUnknownAndMalformedKeys() {
        let states = [(true, true), (true, false), (false, true), (false, false)]
        for (ecg, hr) in states {
            // A key nobody has ever seen.
            XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
                opcode: 119, payload: payload(key: "enable_something_invented"),
                ecgGateOptIn: ecg, isMG: true, broadcastHrOptIn: hr))
            // A near-miss on the real key: prefix, suffix, and case all matter.
            for near in ["enable_raw_data_w_ec", "enable_raw_data_w_ecg2", "ENABLE_RAW_DATA_W_ECG"] {
                XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
                    opcode: 119, payload: payload(key: near),
                    ecgGateOptIn: ecg, isMG: true, broadcastHrOptIn: hr), "\(near) must not pass")
            }
        }
        // Bodies that are not shaped like a device-config write are refused rather than guessed at.
        let good = payload(key: DeviceConfigWriteGate.ecgRawDataKey)
        for bad: [UInt8] in [
            [],                                           // empty
            [0x01],                                       // b3 byte only
            Array(good.dropFirst()),                      // missing the b3 byte
            [0x02] + Array(good.dropFirst()),             // wrong b3 byte
            Array(good.prefix(20)),                       // truncated inside the name field
        ] {
            XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
                opcode: 119, payload: bad, ecgGateOptIn: true, isMG: true, broadcastHrOptIn: true))
        }
    }

    func testKeyNameParsingRejectsNonNulPaddingAndNonAscii() {
        // A name field with junk AFTER the NUL terminator is not a NUL-padded name field, so nothing is
        // claimed — a body cannot smuggle a second string past the terminator.
        var body = payload(key: DeviceConfigWriteGate.ecgRawDataKey)
        body[1 + DeviceConfigWriteGate.ecgRawDataKey.count + 2] = 0x41   // 'A' amongst the padding
        XCTAssertNil(DeviceConfigWriteGate.keyName(inSendPayload: body))
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: body, ecgGateOptIn: true, isMG: true, broadcastHrOptIn: true))
        // Extending the name itself yields a DIFFERENT name, which the key allowlist then refuses.
        var extended = payload(key: DeviceConfigWriteGate.ecgRawDataKey)
        extended[1 + DeviceConfigWriteGate.ecgRawDataKey.count] = 0x41
        XCTAssertEqual(DeviceConfigWriteGate.keyName(inSendPayload: extended), "enable_raw_data_w_ecgA")
        XCTAssertFalse(DeviceConfigWriteGate.admitsSend(
            opcode: 119, payload: extended, ecgGateOptIn: true, isMG: true, broadcastHrOptIn: true))
        // Binary in the name field is refused, not transliterated.
        var binary = payload(key: DeviceConfigWriteGate.ecgRawDataKey)
        binary[3] = 0xFF
        XCTAssertNil(DeviceConfigWriteGate.keyName(inSendPayload: binary))
        // The happy path still round-trips.
        XCTAssertEqual(DeviceConfigWriteGate.keyName(inSendPayload: payload(key: "enable_rfid")),
                       "enable_rfid")
    }

    func testReadBackOpcodeIsOnly121() {
        var admitted: [UInt8] = []
        for opcode in UInt8.min...UInt8.max where DeviceConfigWriteGate.isReadBackOpcode(opcode) {
            admitted.append(opcode)
        }
        XCTAssertEqual(admitted, [121])
        // Notably NOT the write verbs, and not the other namespace's read verb.
        XCTAssertFalse(DeviceConfigWriteGate.isReadBackOpcode(119))
        XCTAssertFalse(DeviceConfigWriteGate.isReadBackOpcode(120))
        XCTAssertFalse(DeviceConfigWriteGate.isReadBackOpcode(128))
    }

    // MARK: - The bytes on the wire

    func testWritePayloadIsTheHardwareValidatedBroadcastHrShape() {
        let on = DeviceConfigWriteGate.writePayload(on: true)
        // [b3] + [32-byte NUL-padded name] + [value] — 34 bytes, the same shape #181 has written since.
        XCTAssertEqual(on.count, 1 + 32 + 1)
        XCTAssertEqual(on[0], 0x01)
        XCTAssertEqual(DeviceConfigWriteGate.keyName(inSendPayload: on), "enable_raw_data_w_ecg")
        XCTAssertEqual(on.last, 0x31)                       // ASCII '1'
        let off = DeviceConfigWriteGate.writePayload(on: false)
        XCTAssertEqual(off.last, 0x30)                      // ASCII '0'
        // Both directions differ ONLY in the value byte — reversibility is one byte, not a second path.
        XCTAssertEqual(Array(on.dropLast()), Array(off.dropLast()))
    }

    func testReadBackPayloadMatchesTheReadProbesRequestShape() {
        XCTAssertEqual(DeviceConfigWriteGate.readBackPayload(),
                       DeviceConfigReadProbe.requestBody(key: "enable_raw_data_w_ecg"))
    }

    // MARK: - The single-digit value the read-back reads

    func testValueReadsTheSingleDigitGateValue() {
        // The gate stores one ASCII digit, so the report reads exactly the byte after the echoed name
        // field (main's single-byte `value(for:)`). Multi-character values belong to the read probe.
        let one = DeviceConfigReadProbe.ValueResponse(
            resultCode: 1, record: echoRecord(key: "enable_raw_data_w_ecg", value: "1"))
        XCTAssertEqual(one.value(for: "enable_raw_data_w_ecg"), 0x31)
        // Trailing envelope NUL padding after the value byte is not part of it.
        let padded = DeviceConfigReadProbe.ValueResponse(
            resultCode: 1, record: echoRecord(key: "enable_raw_data_w_ecg", value: "0") + [0, 0, 0])
        XCTAssertEqual(padded.value(for: "enable_raw_data_w_ecg"), 0x30)
        // A record that stops at the name field claims no value.
        let bare = DeviceConfigReadProbe.ValueResponse(
            resultCode: 1, record: [UInt8](repeating: 0, count: 32))
        XCTAssertNil(bare.value(for: "enable_raw_data_w_ecg"))
        // The key not being echoed at all claims nothing either.
        let other = DeviceConfigReadProbe.ValueResponse(
            resultCode: 1, record: echoRecord(key: "enable_rfid", value: "0"))
        XCTAssertNil(other.value(for: "enable_raw_data_w_ecg"))
    }

    // MARK: - The verdict table: the ack never decides, the read-back does

    func testConfirmedOnlyWhenTheReadBackReturnsWhatWasAsked() {
        var report = EcgRawDataGateReport(on: true)
        XCTAssertEqual(report.verdict, .pending)
        report.noteWriteAck(resultCode: 1)
        // A SUCCESS ack alone must NOT reach a verdict — #891's whole lesson.
        XCTAssertEqual(report.verdict, .pending)
        let frame = readBackFrame(record: echoRecord(key: "enable_raw_data_w_ecg", value: "1"))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5,
                                                                 expecting: 121) else {
            return XCTFail("read-back frame should parse")
        }
        report.noteReadBack(r)
        XCTAssertEqual(report.verdict, .confirmed)
        XCTAssertEqual(report.storedValue, "1")
        XCTAssertTrue(report.render().contains("enable_raw_data_w_ecg"))
    }

    func testSuccessAckWithAnUnmovedValueIsUnchangedNotSuccess() {
        // The exact failure mode this design exists for: the strap acks SUCCESS, and the value did not
        // move. Reporting that as success is what the read-back is here to prevent.
        var report = EcgRawDataGateReport(on: true)
        report.noteWriteAck(resultCode: 1)
        let frame = readBackFrame(record: echoRecord(key: "enable_raw_data_w_ecg", value: "0"))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5,
                                                                 expecting: 121) else {
            return XCTFail("read-back frame should parse")
        }
        report.noteReadBack(r)
        XCTAssertEqual(report.verdict, .unchanged)
        XCTAssertEqual(report.storedValue, "0")
        XCTAssertTrue(report.summary.contains("did NOT take"))
    }

    func testTurningTheGateBackOffConfirmsOnZero() {
        var report = EcgRawDataGateReport(on: false)
        XCTAssertEqual(report.requested, "0")
        let frame = readBackFrame(record: echoRecord(key: "enable_raw_data_w_ecg", value: "0"))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5,
                                                                 expecting: 121) else {
            return XCTFail("read-back frame should parse")
        }
        report.noteReadBack(r)
        XCTAssertEqual(report.verdict, .confirmed)
    }

    func testRefusedSilentNotClaimedAndUndecodableAreNeverSuccess() {
        // FAILURE for the key.
        var refused = EcgRawDataGateReport(on: true)
        refused.noteReadBack(DeviceConfigReadProbe.ValueResponse(resultCode: 0, record: []))
        XCTAssertEqual(refused.verdict, .refused)
        // UNSUPPORTED verb.
        var unsupported = EcgRawDataGateReport(on: true)
        unsupported.noteReadBack(DeviceConfigReadProbe.ValueResponse(resultCode: 3, record: []))
        XCTAssertEqual(unsupported.verdict, .refused)
        // Answered, but the key was not echoed — no value can be claimed.
        var notClaimed = EcgRawDataGateReport(on: true)
        notClaimed.noteReadBack(DeviceConfigReadProbe.ValueResponse(
            resultCode: 1, record: echoRecord(key: "enable_rfid", value: "1")))
        XCTAssertEqual(notClaimed.verdict, .notClaimed)
        // No reply at all.
        var silent = EcgRawDataGateReport(on: true)
        silent.noteReadBackTimeout(seconds: 8)
        XCTAssertEqual(silent.verdict, .silent)
        // A reply that failed the CRC gate.
        var undecodable = EcgRawDataGateReport(on: true)
        undecodable.noteReadBackFailure(.crc)
        XCTAssertEqual(undecodable.verdict, .undecodable)
        for r in [refused, unsupported, notClaimed, silent, undecodable] {
            XCTAssertNotEqual(r.verdict, .confirmed)
            XCTAssertFalse(r.summary.isEmpty)
        }
    }

    func testReadBackIsCrcGatedLikeEveryOtherDecode() {
        var frame = readBackFrame(record: echoRecord(key: "enable_raw_data_w_ecg", value: "1"))
        frame[frame.count - 1] ^= 0xFF          // corrupt the CRC32 trailer
        guard case .failure(let f) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5,
                                                                 expecting: 121) else {
            return XCTFail("a corrupt frame must not decode")
        }
        XCTAssertEqual(f, .crc)
    }

    func testRenderNamesTheKeyTheVerbsAndTheOpenQuestion() {
        var report = EcgRawDataGateReport(on: true)
        report.noteWriteAck(resultCode: 1)
        report.noteReadBackTimeout(seconds: 8)
        let text = report.render()
        XCTAssertTrue(text.contains("SET_DEVICE_CONFIG_VALUE(119)"))
        XCTAssertTrue(text.contains("GET_DEVICE_CONFIG_VALUE(121)"))
        XCTAssertTrue(text.contains("SET_FF_VALUE(120) is never sent"))
        // The honest framing has to survive into the copyable report a user pastes into an issue.
        XCTAssertTrue(text.contains("UNKNOWN"))
        XCTAssertTrue(text.contains("#891"))
    }
}
