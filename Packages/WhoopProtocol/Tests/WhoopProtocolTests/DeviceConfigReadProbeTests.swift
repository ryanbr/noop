import XCTest
@testable import WhoopProtocol

/// #103: the read-only device-config read probe's allowlist, request shape, parse and plan contract.
///
/// Fixtures are SYNTHETIC and built with real CRCs by the two helpers below (the WHOOP 4.0 harvard
/// envelope and the 5/MG puffin envelope). No strap has ever answered opcode 121 or 128 in this
/// project's hands — establishing whether one does is what the probe is for — so these tests pin the
/// decode, the plan and the report, including every "the verb is not implemented" path the BLE handler
/// must survive.
final class DeviceConfigReadProbeTests: XCTestCase {

    // MARK: - Frame builders (mirror the two envelopes verifyFrame(_:family:) validates)

    /// WHOOP 4.0 COMMAND_RESPONSE: [0xAA][len u16 LE][crc8(len)][type=36][seq][cmd][payload…][crc32 LE].
    private func whoop4Response(cmd: UInt8, payload: [UInt8], seq: UInt8 = 1) -> [UInt8] {
        let inner: [UInt8] = [36, seq, cmd] + payload
        let length = UInt16(inner.count + 4)
        let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
        var frame: [UInt8] = [0xAA] + lenBytes + [crc8(lenBytes)] + inner
        let c = crc32(inner)
        frame += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 24) & 0xFF)]
        return frame
    }

    /// WHOOP 5/MG COMMAND_RESPONSE in the puffin envelope: type @8, seq @9, cmd @10, record from @11.
    private func whoop5Response(cmd: UInt8, payload: [UInt8], seq: UInt8 = 1) -> [UInt8] {
        var inner: [UInt8] = [36, seq, cmd] + payload
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

    /// The 2-byte response header every COMMAND_RESPONSE carries ahead of its record, then the record.
    private func payload(result: UInt8, record: [UInt8]) -> [UInt8] { [0x0A, result] + record }

    /// A record shaped like the SET side's body: the key NUL-padded to 32 bytes, then the value byte.
    private func echoRecord(_ key: String, value: UInt8, lead: [UInt8] = []) -> [UInt8] {
        var field = [UInt8](repeating: 0, count: DeviceConfigReadProbe.nameFieldBytes)
        let bytes = Array(key.utf8)
        for i in 0..<min(field.count, bytes.count) { field[i] = bytes[i] }
        return lead + field + [value]
    }

    private var flagKeys: [String] { Whoop5Config.enableR22Sequence.map(\.name) }

    // MARK: - The read-only allowlist (the hard safety constraint)

    func testAllowlistAdmitsOnlyTheTwoReadVerbs() {
        XCTAssertEqual(DeviceConfigReadProbe.getDeviceConfigValueCmd, 121)   // 0x79
        XCTAssertEqual(DeviceConfigReadProbe.getFeatureFlagValueCmd, 128)    // 0x80
        XCTAssertEqual(DeviceConfigReadProbe.readOnlyOpcodes, [121, 128])
        XCTAssertTrue(DeviceConfigReadProbe.isReadOnlyOpcode(121))
        XCTAssertTrue(DeviceConfigReadProbe.isReadOnlyOpcode(128))
    }

    /// The load-bearing safety test: the two config WRITE verbs must be rejected by the same predicate
    /// the BLE send path consults while a probe is in flight.
    func testAllowlistRejectsBothConfigWriteVerbs() {
        XCTAssertEqual(DeviceConfigReadProbe.setDeviceConfigValueCmd, 119)   // 0x77
        XCTAssertEqual(DeviceConfigReadProbe.setFeatureFlagValueCmd, 120)    // 0x78
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(119), "SET_DEVICE_CONFIG_VALUE must never pass")
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(120), "SET_FF_VALUE must never pass")
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(Whoop5Config.setConfigCmd))       // 0x78
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(Whoop5Config.setDeviceConfigCmd)) // 0x77
        for op in DeviceConfigReadProbe.writeOpcodes {
            XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(op))
        }
        XCTAssertTrue(DeviceConfigReadProbe.readOnlyOpcodes.isDisjoint(with: DeviceConfigReadProbe.writeOpcodes))
    }

    /// Nothing outside the pair passes either — including the enumerate verbs #761 owns and the
    /// destructive opcodes that must never come near this path.
    func testAllowlistRejectsEveryOtherOpcode() {
        for op in UInt8.min...UInt8.max where !DeviceConfigReadProbe.readOnlyOpcodes.contains(op) {
            XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(op), "opcode \(op) must not pass")
        }
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(FeatureFlagProbe.startKeyExchangeCmd))
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(FeatureFlagProbe.sendNextFlagCmd))
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(25))   // FORCE_TRIM
        XCTAssertFalse(DeviceConfigReadProbe.isReadOnlyOpcode(29))   // REBOOT_STRAP
    }

    // MARK: - Request body

    func testRequestBodyIsTheB3ByteThenA32ByteNulPaddedName() {
        let body = DeviceConfigReadProbe.requestBody(key: "enable_spo2")
        XCTAssertEqual(body.count, 33, "b3 byte + a 32-byte name field, and no value byte")
        XCTAssertEqual(body[0], 0x01)
        XCTAssertEqual(Array(body[1..<12]), Array("enable_spo2".utf8))
        XCTAssertTrue(body[12...].allSatisfy { $0 == 0 }, "the rest of the name field is NUL padding")
        // It carries no value byte — that is exactly what separates it from the SET bodies.
        XCTAssertEqual(Whoop5Config.deviceConfigBody(name: "enable_spo2", value: 0x31).count, 33)
        XCTAssertNotEqual(Array(body.dropFirst()),
                          Whoop5Config.deviceConfigBody(name: "enable_spo2", value: 0x31))
    }

    func testRequestBodyTruncatesAnOverlongNameLikeTheSetSide() {
        let long = String(repeating: "z", count: 40)
        let body = DeviceConfigReadProbe.requestBody(key: long)
        XCTAssertEqual(body.count, 33)
        XCTAssertEqual(Array(body[1...]), [UInt8](repeating: 0x7A, count: 32))
    }

    // MARK: - Parsing

    func testParseDecodesTheRecordAndResultCodeOnWhoop5() {
        let record = echoRecord("enable_r22_packets", value: 0x32, lead: [0x01])
        let frame = whoop5Response(cmd: 128, payload: payload(result: 1, record: record))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5, expecting: 128) else {
            return XCTFail("expected a decoded reply")
        }
        XCTAssertEqual(r.resultCode, 1)
        XCTAssertFalse(r.isUnsupported)
        XCTAssertEqual(r.value(for: "enable_r22_packets"), 0x32)
        XCTAssertEqual(r.echoOffset(of: "enable_r22_packets"), 1)
    }

    func testParseOnWhoop4LeavesTheResultCodeUnlabelled() {
        let frame = whoop4Response(cmd: 121, payload: payload(result: 1, record: echoRecord("k", value: 0x31)))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop4, expecting: 121) else {
            return XCTFail("expected a decoded reply")
        }
        XCTAssertNil(r.resultCode, "the result byte's meaning is only established on 5/MG")
        XCTAssertEqual(r.value(for: "k"), 0x31)
    }

    func testUnsupportedResultIsRecognised() {
        let frame = whoop5Response(cmd: 121, payload: payload(result: 3, record: [0x00, 0x00, 0x00]))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5, expecting: 121) else {
            return XCTFail("expected a decoded reply")
        }
        XCTAssertTrue(r.isUnsupported)
        XCTAssertNil(r.value(for: "whatever"), "an UNSUPPORTED reply must never yield a value")
    }

    func testNoValueIsClaimedWhenTheReplyDoesNotEchoTheKey() {
        // A plausible-looking record that simply isn't the key we asked for.
        let frame = whoop5Response(cmd: 128, payload: payload(result: 1, record: echoRecord("some_other_key", value: 0x32)))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5, expecting: 128) else {
            return XCTFail("expected a decoded reply")
        }
        XCTAssertNil(r.value(for: "enable_spo2"))
        XCTAssertNil(r.echoOffset(of: "enable_spo2"))
    }

    func testKeyMustSitInARealNulPaddedFieldNotJustAppearInTheBytes() {
        // "enable_spo2" appears, but immediately followed by more text — so it is not the 32-byte field.
        var record = Array("enable_spo2_extra_suffix_bytes__".utf8)   // exactly 32 bytes, no NUL padding
        record += [0x31]
        let frame = whoop5Response(cmd: 121, payload: payload(result: 1, record: record))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5, expecting: 121) else {
            return XCTFail("expected a decoded reply")
        }
        XCTAssertNil(r.value(for: "enable_spo2"), "a substring match is not a name field")
    }

    /// On WHOOP 4.0, where the envelope adds no padding, a record that ends at the name field yields no
    /// value at all. (On 5/MG the puffin envelope pads the inner payload to a 4-byte boundary, so the
    /// same record would carry up to three trailing NULs that are envelope padding, not data — which is
    /// why `value(for:)` is only ever read as "the byte after the echoed field", never as "the last byte".)
    func testValueIsNotClaimedWhenTheRecordStopsAtTheNameField() {
        var field = [UInt8](repeating: 0, count: 32)
        for (i, b) in Array("enable_spo2".utf8).enumerated() { field[i] = b }
        let frame = whoop4Response(cmd: 121, payload: payload(result: 1, record: field))
        guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop4, expecting: 121) else {
            return XCTFail("expected a decoded reply")
        }
        XCTAssertEqual(r.echoOffset(of: "enable_spo2"), 0)
        XCTAssertNil(r.value(for: "enable_spo2"), "nil is 'no value claimed', never 'value is zero'")
    }

    // MARK: - Failure paths (the handler must survive every one)

    func testBadCRCIsRejected() {
        var frame = whoop4Response(cmd: 121, payload: payload(result: 1, record: echoRecord("k", value: 0x31)))
        frame[frame.count - 1] ^= 0xFF          // corrupt the CRC32 trailer
        XCTAssertEqual(DeviceConfigReadProbe.parse(frame: frame, family: .whoop4, expecting: 121), .failure(.crc))

        var five = whoop5Response(cmd: 128, payload: payload(result: 1, record: echoRecord("k", value: 0x31)))
        five[7] ^= 0xFF                          // corrupt the CRC16 header
        XCTAssertEqual(DeviceConfigReadProbe.parse(frame: five, family: .whoop5, expecting: 128), .failure(.crc))

        XCTAssertEqual(DeviceConfigReadProbe.parse(frame: [], family: .whoop4, expecting: 121), .failure(.crc))
    }

    func testWrongCommandAndWrongTypeAreRejected() {
        let frame = whoop4Response(cmd: 128, payload: payload(result: 1, record: echoRecord("k", value: 0x31)))
        XCTAssertEqual(DeviceConfigReadProbe.parse(frame: frame, family: .whoop4, expecting: 121),
                       .failure(.wrongCommand))

        // Same bytes, but the packet type is COMMAND (35) rather than COMMAND_RESPONSE (36).
        let inner: [UInt8] = [35, 1, 121] + payload(result: 1, record: [0x01, 0x02])
        let length = UInt16(inner.count + 4)
        let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
        var wrong: [UInt8] = [0xAA] + lenBytes + [crc8(lenBytes)] + inner
        let c = crc32(inner)
        wrong += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 24) & 0xFF)]
        XCTAssertEqual(DeviceConfigReadProbe.parse(frame: wrong, family: .whoop4, expecting: 121),
                       .failure(.envelope))
    }

    func testTruncatedRecordIsRejected() {
        let header = whoop4Response(cmd: 121, payload: [0x0A, 0x01])
        XCTAssertEqual(DeviceConfigReadProbe.parse(frame: header, family: .whoop4, expecting: 121),
                       .failure(.truncated))
    }

    // MARK: - The plan

    func testDiscoveryTriesEachVerbOnceBeforeAnythingElse() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys,
                                                 candidateKeys: DeviceConfigReadProbe.oxygenCandidateKeys)
        guard let first = report.nextStep() else { return XCTFail("expected a first step") }
        XCTAssertEqual(first.opcode, 128)
        XCTAssertEqual(first.key, "enable_r22_packets", "128 is discovered against a flag NOOP writes")
        XCTAssertEqual(first.group, .discovery)

        // Nothing is known yet, so the second step is the other verb, not a value read.
        guard let second = report.nextStep() else { return XCTFail("expected a second step") }
        XCTAssertEqual(second.opcode, 121)
        XCTAssertEqual(second.key, DeviceConfigReadProbe.deviceConfigDiscoveryKey)
        XCTAssertEqual(second.group, .discovery)
    }

    func testBothVerbsUnsupportedEndsTheProbeAfterTwoRoundTrips() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys,
                                                 candidateKeys: DeviceConfigReadProbe.oxygenCandidateKeys)
        for _ in 0..<2 {
            guard let step = report.nextStep() else { return XCTFail("expected a discovery step") }
            let frame = whoop5Response(cmd: step.opcode, payload: payload(result: 3, record: [0x00, 0x00, 0x00]))
            guard case .success(let r) = DeviceConfigReadProbe.parse(frame: frame, family: .whoop5,
                                                                     expecting: step.opcode) else {
                return XCTFail("parse")
            }
            report.noteReply(r, for: step)
        }
        XCTAssertNil(report.nextStep(), "a refused verb must not drive sixteen more round-trips")
        XCTAssertEqual(report.steps, 2)
        XCTAssertEqual(report.featureFlagVerb, .unsupported)
        XCTAssertEqual(report.deviceConfigVerb, .unsupported)
        // The one run that supports the strong sentence: the firmware itself refused both verbs.
        XCTAssertEqual(report.verdict,
                       "neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121) is served by this "
                       + "firmware — rejected as UNSUPPORTED")
        XCTAssertTrue(report.render().contains("neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121)"))
    }

    /// Two timeouts are two timeouts. `BLEManager.send` returns without transmitting when there is no
    /// `cmdCharacteristic` and again when the 5/MG allowlist does not carry the opcode, so a run in which
    /// nothing reached the strap must not print a claim about what the firmware serves.
    func testSilentVerbsEndTheProbeAndAreSaidPlainly() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys,
                                                 candidateKeys: DeviceConfigReadProbe.oxygenCandidateKeys)
        for _ in 0..<2 {
            guard let step = report.nextStep() else { return XCTFail("expected a discovery step") }
            report.noteTimeout(for: step, seconds: 8)
        }
        XCTAssertNil(report.nextStep())
        XCTAssertEqual(report.featureFlagVerb, .silent)
        XCTAssertEqual(report.deviceConfigVerb, .silent)
        XCTAssertEqual(report.verdict,
                       "no read verb answered — GET_FF_VALUE(128) served no reply in 8s — unconfirmed; "
                       + "GET_DEVICE_CONFIG_VALUE(121) served no reply in 8s — unconfirmed")
        let text = report.render()
        XCTAssertFalse(text.contains("served by this firmware"),
                       "silence is not the firmware answering — it is not even proof a frame was sent")
        XCTAssertFalse(text.contains("UNSUPPORTED"), "nothing was refused; nothing replied at all")
        XCTAssertTrue(text.contains("no COMMAND_RESPONSE within 8s"))
        XCTAssertTrue(text.contains("(none — the verb that would carry them did not answer)"))
    }

    /// One verb refused and the other timed out: the refusal belongs to the verb that was refused. The
    /// old `||` printed "neither … is served by this firmware — rejected as UNSUPPORTED" over a 121 that
    /// was never refused, only never heard from.
    func testOneRefusalIsNotGeneralisedToTheVerbThatWasNeverHeardFrom() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys,
                                                 candidateKeys: DeviceConfigReadProbe.oxygenCandidateKeys)
        guard let s128 = report.nextStep() else { return XCTFail("128") }
        XCTAssertEqual(s128.opcode, 128)
        report.noteReply(.init(resultCode: 3, record: [0x00]), for: s128)
        guard let s121 = report.nextStep() else { return XCTFail("121") }
        XCTAssertEqual(s121.opcode, 121)
        report.noteTimeout(for: s121, seconds: 8)

        XCTAssertNil(report.nextStep())
        XCTAssertEqual(report.featureFlagVerb, .unsupported)
        XCTAssertEqual(report.deviceConfigVerb, .silent)
        XCTAssertEqual(report.verdict,
                       "no read verb answered — GET_FF_VALUE(128) refused by firmware (UNSUPPORTED); "
                       + "GET_DEVICE_CONFIG_VALUE(121) served no reply in 8s — unconfirmed")
        XCTAssertFalse(report.render().contains("neither GET_FF_VALUE(128) nor GET_DEVICE_CONFIG_VALUE(121)"),
                       "one refusal does not speak for the other verb")
    }

    /// An undecodable reply is affirmative evidence the strap DID transmit, so "not served by this
    /// firmware" states the opposite of what the run observed.
    func testAnUndecodableReplyIsNotReportedAsUnserved() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys, candidateKeys: [])
        guard let s128 = report.nextStep() else { return XCTFail("128") }
        report.noteFailure(.crc, for: s128)
        guard let s121 = report.nextStep() else { return XCTFail("121") }
        report.noteFailure(.envelope, for: s121)

        XCTAssertEqual(report.featureFlagVerb, .undecodable)
        XCTAssertEqual(report.deviceConfigVerb, .undecodable)
        XCTAssertEqual(report.verdict,
                       "no read verb answered — "
                       + "GET_FF_VALUE(128) replied but the frame did not decode — unconfirmed; "
                       + "GET_DEVICE_CONFIG_VALUE(121) replied but the frame did not decode — unconfirmed")
        XCTAssertFalse(report.render().contains("served by this firmware"))
    }

    /// A probe that ended before either verb went out says so, rather than reporting an empty run as a
    /// finding about the firmware.
    func testAProbeThatAskedNothingClaimsNothing() {
        let report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys, candidateKeys: [])
        XCTAssertEqual(report.featureFlagVerb, .untried)
        XCTAssertEqual(report.deviceConfigVerb, .untried)
        XCTAssertEqual(report.verdict,
                       "no read verb answered — GET_FF_VALUE(128) not asked; "
                       + "GET_DEVICE_CONFIG_VALUE(121) not asked")
    }

    func testAnAnsweringFeatureFlagVerbWalksTheFifteenRemainingKnownFlags() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys,
                                                 candidateKeys: DeviceConfigReadProbe.oxygenCandidateKeys)
        // 128 answers; 121 is refused.
        guard let s128 = report.nextStep() else { return XCTFail("128") }
        report.noteReply(.init(resultCode: 1, record: echoRecord(s128.key, value: 0x32, lead: [0x01])), for: s128)
        guard let s121 = report.nextStep() else { return XCTFail("121") }
        report.noteReply(.init(resultCode: 3, record: [0x00]), for: s121)

        var flagSteps: [String] = []
        var candidateSteps: [String] = []
        while let step = report.nextStep() {
            XCTAssertEqual(step.opcode, 128, "the refused verb must never be sent again")
            switch step.group {
            case .knownFlag: flagSteps.append(step.key)
            case .candidate: candidateSteps.append(step.key)
            case .discovery: XCTFail("discovery is over")
            }
            report.noteReply(.init(resultCode: 1, record: echoRecord(step.key, value: 0x31, lead: [0x01])), for: step)
        }
        XCTAssertEqual(flagSteps, Array(flagKeys.dropFirst()),
                       "the discovery key is not read twice; every other flag is")
        XCTAssertEqual(candidateSteps, DeviceConfigReadProbe.oxygenCandidateKeys,
                       "candidates fall back to the surviving verb")
        XCTAssertEqual(report.steps, 2 + 15 + DeviceConfigReadProbe.oxygenCandidateKeys.count)
    }

    func testCandidatesPreferTheDeviceConfigVerbWhenBothAnswer() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: ["only_flag"],
                                                 candidateKeys: ["enable_spo2"])
        guard let a = report.nextStep() else { return XCTFail("128") }
        report.noteReply(.init(resultCode: 1, record: echoRecord(a.key, value: 0x32)), for: a)
        guard let b = report.nextStep() else { return XCTFail("121") }
        report.noteReply(.init(resultCode: 1, record: echoRecord(b.key, value: 0x31)), for: b)

        // The only known flag was already read during discovery, so the next step is the candidate.
        guard let c = report.nextStep() else { return XCTFail("candidate") }
        XCTAssertEqual(c.group, .candidate)
        XCTAssertEqual(c.opcode, 121, "the device-config namespace is the one this probe exists to reach")
        XCTAssertEqual(c.key, "enable_spo2")
    }

    func testThePlanIsCappedEvenWithAnAbsurdKeyList() {
        let many = (0..<500).map { "key_\($0)" }
        var report = DeviceConfigReadProbeReport(family: .whoop4, knownFlagKeys: many, candidateKeys: many)
        var seen = 0
        while let step = report.nextStep() {
            seen += 1
            XCTAssertLessThanOrEqual(seen, DeviceConfigReadProbe.maxSteps + 1, "the plan must terminate")
            report.noteReply(.init(resultCode: nil, record: echoRecord(step.key, value: 0x31)), for: step)
        }
        XCTAssertEqual(seen, DeviceConfigReadProbe.maxSteps)
        XCTAssertEqual(report.stopReason, "safety cap of 64 round-trips reached")
    }

    func testAnUndecodableReplyRetiresTheVerb() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: flagKeys, candidateKeys: [])
        guard let step = report.nextStep() else { return XCTFail("first") }
        report.noteFailure(.crc, for: step)
        XCTAssertEqual(report.featureFlagVerb, .undecodable)
        guard let next = report.nextStep() else { return XCTFail("second") }
        XCTAssertEqual(next.opcode, 121, "the undecodable verb is not retried")
        report.noteTimeout(for: next, seconds: 8)
        XCTAssertNil(report.nextStep())
        XCTAssertEqual(report.stopReason, "CRC failed — frame rejected (never decoded)")
    }

    func testAVerdictAlreadyReachedIsNotRewrittenByALaterReply() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: ["a", "b"], candidateKeys: [])
        guard let first = report.nextStep() else { return XCTFail("first") }
        report.noteReply(.init(resultCode: 1, record: echoRecord("a", value: 0x31)), for: first)
        XCTAssertEqual(report.featureFlagVerb, .answered)
        // A later UNSUPPORTED on the same verb sticks; a later SUCCESS after that does not undo it.
        guard let second = report.nextStep() else { return XCTFail("second") }
        report.noteReply(.init(resultCode: 3, record: [0x00]), for: second)
        XCTAssertEqual(report.deviceConfigVerb, .unsupported)
        report.noteReply(.init(resultCode: 1, record: [0x00]), for: second)
        XCTAssertEqual(report.deviceConfigVerb, .unsupported, "a refusal is not upgraded away")
    }

    // MARK: - Report

    func testCandidateKeysAreLabelledAsGuesses() {
        var report = DeviceConfigReadProbeReport(family: .whoop5, knownFlagKeys: ["f"],
                                                 candidateKeys: ["enable_spo2"])
        guard let a = report.nextStep() else { return XCTFail("a") }
        report.noteReply(.init(resultCode: 1, record: echoRecord("f", value: 0x32)), for: a)
        guard let b = report.nextStep() else { return XCTFail("b") }
        report.noteReply(.init(resultCode: 1, record: echoRecord(b.key, value: 0x31)), for: b)
        guard let c = report.nextStep() else { return XCTFail("c") }
        report.noteReply(.init(resultCode: 0, record: [0x00]), for: c)
        let text = report.render()
        XCTAssertTrue(text.contains("Candidate oxygen keys — GUESSES, never observed on a wire or in any table"))
        XCTAssertTrue(text.contains("enable_spo2"))
        XCTAssertTrue(text.contains("no value (result=FAILURE(0))"))
    }

    func testOxygenCandidateListIsShortAndOxygenNamed() {
        let keys = DeviceConfigReadProbe.oxygenCandidateKeys
        XCTAssertFalse(keys.isEmpty)
        XCTAssertLessThanOrEqual(keys.count, 12, "keep the guess list short — it is a guess list")
        XCTAssertEqual(Set(keys).count, keys.count, "no duplicates")
        for k in keys {
            XCTAssertTrue(k.contains("spo2") || k.contains("oxygen") || k.contains("pulse_ox"),
                          "\(k) does not read as oxygen-related")
            XCTAssertLessThanOrEqual(k.utf8.count, DeviceConfigReadProbe.nameFieldBytes,
                                     "\(k) would be truncated by the 32-byte name field")
        }
    }

    /// GOLDEN: the exact rendered report, byte-for-byte. Its Kotlin twin
    /// (`DeviceConfigReadProbeTest.goldenReportIsByteIdenticalAcrossPlatforms`) asserts the SAME literal,
    /// so a strap log reads identically on either platform — a whitespace or wording drift on one side
    /// fails there rather than in a user's log.
    ///
    /// The first record's trailing `00`, and the seven-byte UNSUPPORTED record, are the puffin envelope's
    /// 4-byte inner padding showing through — which is exactly why the value is read as "the byte after
    /// the echoed name field" and not "the last byte of the record".
    func testGoldenReportIsByteIdenticalAcrossPlatforms() {
        var report = DeviceConfigReadProbeReport(family: .whoop5,
                                                 knownFlagKeys: ["enable_r22_packets", "hr_ch_switching"],
                                                 candidateKeys: ["enable_spo2"])
        // 128 answers with a value; 121 is refused; the remaining flag reads through 128; the guessed
        // candidate falls back to 128 and comes back FAILURE.
        guard let s1 = report.nextStep() else { return XCTFail("s1") }
        let f1 = whoop5Response(cmd: 128, payload: payload(result: 1,
                                                           record: echoRecord("enable_r22_packets", value: 0x32, lead: [0x01])))
        guard case .success(let r1) = DeviceConfigReadProbe.parse(frame: f1, family: .whoop5, expecting: 128) else {
            return XCTFail("parse s1")
        }
        report.noteReply(r1, for: s1)

        guard let s2 = report.nextStep() else { return XCTFail("s2") }
        let f2 = whoop5Response(cmd: 121, payload: payload(result: 3, record: [0x00, 0x00, 0x00, 0x00]))
        guard case .success(let r2) = DeviceConfigReadProbe.parse(frame: f2, family: .whoop5, expecting: 121) else {
            return XCTFail("parse s2")
        }
        report.noteReply(r2, for: s2)

        guard let s3 = report.nextStep() else { return XCTFail("s3") }
        report.noteReply(.init(resultCode: 1, record: echoRecord("hr_ch_switching", value: 0x32, lead: [0x01])), for: s3)

        guard let s4 = report.nextStep() else { return XCTFail("s4") }
        report.noteReply(.init(resultCode: 0, record: [0x01, 0x00]), for: s4)
        XCTAssertNil(report.nextStep())

        let golden = """
        #103 DEVICE-CONFIG READ PROBE — WHOOP 5/MG
        Read-only: GET_DEVICE_CONFIG_VALUE(121) + GET_FF_VALUE(128). No value is written; SET_DEVICE_CONFIG_VALUE(119) and SET_FF_VALUE(120) are never sent from this path.
        Follow-up to the #761 enumeration probe: that one asked for key NAMES, this asks for VALUES.

        Verdict: 1 of 2 read verbs answered; read 2 config value(s)

        Read verbs:
          GET_FF_VALUE(128)             answered
          GET_DEVICE_CONFIG_VALUE(121)  unsupported

        Discovery — one round-trip per verb against a key it should know (2):
           1. enable_r22_packets              = '2' (0x32)
           2. whoop_live_hr_in_adv_ind_pkt    — no value (result=UNSUPPORTED(3))

        Known feature-flag values (names NOOP already writes; values never read before) (1):
           1. hr_ch_switching                 = '2' (0x32)

        Candidate oxygen keys — GUESSES, never observed on a wire or in any table (1):
           1. enable_spo2                     — no value (result=FAILURE(0))

        Exchange:
          GET_FF_VALUE(128) key="enable_r22_packets" → result=SUCCESS(1) value='2' (0x32) record=[01 65 6e 61 62 6c 65 5f 72 32 32 5f 70 61 63 6b 65 74 73 00 00 00 00 00 00 00 00 00 00 00 00 00 00 32 00]
          GET_DEVICE_CONFIG_VALUE(121) key="whoop_live_hr_in_adv_ind_pkt" → result=UNSUPPORTED(3) record=[00 00 00 00 00 00 00]
          GET_FF_VALUE(128) key="hr_ch_switching" → result=SUCCESS(1) value='2' (0x32) record=[01 68 72 5f 63 68 5f 73 77 69 74 63 68 69 6e 67 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 32]
          GET_FF_VALUE(128) key="enable_spo2" → result=FAILURE(0) record=[01 00]

        """
        XCTAssertEqual(report.render(), golden)
    }
}
