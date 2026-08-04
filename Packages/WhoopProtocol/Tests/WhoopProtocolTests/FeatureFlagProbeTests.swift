import XCTest
@testable import WhoopProtocol

/// #761: the read-only feature-flag enumeration probe's parse + report contract.
///
/// Fixtures are SYNTHETIC and built with real CRCs by the two helpers below (the WHOOP 4.0 harvard
/// envelope and the 5/MG puffin envelope), because the layout is reverse-engineered and not yet
/// answered by a strap in this project's hands. They pin the decode/report contract — including every
/// failure path the BLE handler must survive — so `swift test` covers the whole probe without hardware.
final class FeatureFlagProbeTests: XCTestCase {

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

    /// WHOOP 5/MG COMMAND_RESPONSE in the puffin envelope (same shape `puffinCommandFrame` builds, with
    /// the COMMAND_RESPONSE type byte): type @8, seq @9, cmd @10, record from @11.
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

    /// The 2-byte response header every COMMAND_RESPONSE carries ahead of its record (`pay[1]` is the
    /// 5/MG result code), then the record itself.
    private func payload(result: UInt8, record: [UInt8]) -> [UInt8] { [0x0A, result] + record }

    /// A NUL-terminated key name, padded like the SET side pads its 32-byte name field.
    private func keyBytes(_ s: String, pad: Int = 8) -> [UInt8] {
        Array(s.utf8) + [0x00] + [UInt8](repeating: 0, count: pad)
    }

    // MARK: - Wire constants

    func testOpcodesAreTheEnumeratePairOnly() {
        XCTAssertEqual(FeatureFlagProbe.startKeyExchangeCmd, 117)   // 0x75
        XCTAssertEqual(FeatureFlagProbe.sendNextFlagCmd, 118)       // 0x76
        XCTAssertEqual(FeatureFlagProbe.requestBody, [0x01])
        // The SET verbs must not appear anywhere in this file's surface — the probe is read-only.
        XCTAssertNotEqual(FeatureFlagProbe.startKeyExchangeCmd, 120)
        XCTAssertNotEqual(FeatureFlagProbe.sendNextFlagCmd, 119)
    }

    // MARK: - START_FF_KEY_EXCHANGE (117)

    func testStartDecodesRevisionAndCountOnWhoop4() {
        // record = [revision=1][count=11 u16 LE] — the published 4.0 dump's shape (`0a 01 | 01 0b 00`).
        let frame = whoop4Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x0B, 0x00]))
        guard case .success(let r) = FeatureFlagProbe.parseStart(frame: frame, family: .whoop4) else {
            return XCTFail("expected a decoded START response")
        }
        XCTAssertEqual(r.revision, 1)
        XCTAssertEqual(r.count, 11)
        XCTAssertNil(r.resultCode, "the result byte's meaning is only established on 5/MG")
        XCTAssertTrue(r.countIsPlausible)
    }

    func testStartDecodesOnWhoop5AndSurfacesTheResultCode() {
        let frame = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x10, 0x00]))
        guard case .success(let r) = FeatureFlagProbe.parseStart(frame: frame, family: .whoop5) else {
            return XCTFail("expected a decoded START response")
        }
        XCTAssertEqual(r.count, 16)
        XCTAssertEqual(r.resultCode, 1)
    }

    func testStartWithUnsupportedResultIsStillDecodedAndVerdictSaysRejected() {
        // result=3 UNSUPPORTED: the firmware refusing opcode 117 is the single most informative outcome.
        let frame = whoop5Response(cmd: 117, payload: payload(result: 3, record: [0x00, 0x00, 0x00]))
        guard case .success(let r) = FeatureFlagProbe.parseStart(frame: frame, family: .whoop5) else {
            return XCTFail("expected a decoded START response")
        }
        XCTAssertEqual(r.resultCode, 3)
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(r)
        XCTAssertTrue(report.verdict.contains("REJECTED by firmware (UNSUPPORTED)"))
        XCTAssertTrue(report.render().contains("opcode 117 REJECTED"))
    }

    func testImplausibleCountIsFlaggedNotTrusted() {
        let frame = whoop4Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0xFF, 0xFF]))
        guard case .success(let r) = FeatureFlagProbe.parseStart(frame: frame, family: .whoop4) else {
            return XCTFail("expected a decoded START response")
        }
        XCTAssertEqual(r.count, 65535)
        XCTAssertFalse(r.countIsPlausible)
        var report = FeatureFlagProbeReport(family: .whoop4)
        report.noteStart(r)
        XCTAssertTrue(report.render().contains("count outside 1…128"))
    }

    // MARK: - SEND_NEXT_FF (118)

    func testNextDecodesTheKeyName() {
        // record = [revision=1][index=0][validKey=1]["enable_r22_packets"\0…]
        let record: [UInt8] = [0x01, 0x00, 0x01] + keyBytes("enable_r22_packets")
        let frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: record))
        guard case .success(let r) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop4) else {
            return XCTFail("expected a decoded NEXT response")
        }
        XCTAssertEqual(r.index, 0)
        XCTAssertTrue(r.validKey)
        XCTAssertEqual(r.key, "enable_r22_packets")
        XCTAssertFalse(r.isExhausted)
    }

    func testNextDecodesOnWhoop5Too() {
        let record: [UInt8] = [0x01, 0x03, 0x01] + keyBytes("sigproc_wear_detect")
        let frame = whoop5Response(cmd: 118, payload: payload(result: 1, record: record))
        guard case .success(let r) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop5) else {
            return XCTFail("expected a decoded NEXT response")
        }
        XCTAssertEqual(r.index, 3)
        XCTAssertEqual(r.key, "sigproc_wear_detect")
        XCTAssertEqual(r.resultCode, 1)
    }

    func testExhaustedCursorIsTheEndMarker() {
        // The published 4.0 dump's end marker: `0a 01 | 01 ff …`.
        let frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0xFF, 0x00, 0x00]))
        guard case .success(let r) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop4) else {
            return XCTFail("expected a decoded NEXT response")
        }
        XCTAssertEqual(r.index, 0xFF)
        XCTAssertTrue(r.isExhausted)
        var report = FeatureFlagProbeReport(family: .whoop4)
        XCTAssertFalse(report.noteNext(r), "an exhausted cursor must stop the walk")
        XCTAssertEqual(report.stopReason, "cursor exhausted (index 0xFF)")
    }

    func testValidKeyFalseStopsTheWalkEvenWithBytesAfterIt() {
        // validKey=0 with a plausible-looking name after it: the firmware's own flag wins.
        let record: [UInt8] = [0x01, 0x04, 0x00] + keyBytes("stale_buffer_leftover")
        let frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: record))
        guard case .success(let r) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop4) else {
            return XCTFail("expected a decoded NEXT response")
        }
        XCTAssertFalse(r.validKey)
        XCTAssertTrue(r.isExhausted)
        var report = FeatureFlagProbeReport(family: .whoop4)
        XCTAssertFalse(report.noteNext(r))
        XCTAssertEqual(report.stopReason, "firmware reported validKey=false")
        XCTAssertTrue(report.keys.isEmpty, "an invalid entry must never be collected as a flag")
    }

    func testNonPrintableNameIsNotReportedAsAKey() {
        let record: [UInt8] = [0x01, 0x02, 0x01, 0xDE, 0xAD, 0xBE, 0xEF]
        let frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: record))
        guard case .success(let r) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop4) else {
            return XCTFail("expected a decoded NEXT response")
        }
        XCTAssertNil(r.key, "a non-printable run is never invented into a name")
        // Our decode declining a name is NOT the strap saying stop: the firmware still flagged this entry
        // valid, so the walk steps over it instead of throwing away everything after it.
        XCTAssertFalse(r.isExhausted)
        XCTAssertTrue(r.isSkippable)
    }

    /// The regression this split exists for: one undecodable entry used to end the enumeration, so a list
    /// with a bad byte in the middle reported only the keys BEFORE it. The first real capture is the
    /// expensive one to obtain, and it is exactly the run that must not be truncated by our own strictness.
    func testAnUndecodableEntryDoesNotHideTheKeysAfterIt() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 4))

        func next(_ index: Int, _ key: String?) -> FeatureFlagProbe.NextResponse {
            FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: index, validKey: true, key: key)
        }
        XCTAssertTrue(report.noteNext(next(0, "enable_r22_packets")))
        XCTAssertTrue(report.noteNext(next(1, nil)), "a bad name must not stop the walk")
        XCTAssertTrue(report.noteNext(next(2, "sigproc_wear_detect")))
        XCTAssertFalse(report.noteNext(
            FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: 0xFF,
                                          validKey: false, key: nil)))

        XCTAssertEqual(report.keys, ["enable_r22_packets", "sigproc_wear_detect"],
                       "the key after the undecodable entry is collected, not lost")
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.stopReason, "cursor exhausted (index 0xFF)")
        XCTAssertTrue(report.render().contains("1 name(s) did not decode and were skipped"),
                      "a dump with holes must describe itself rather than look complete")
    }

    /// `validKey = 0` is trusted as an end marker, but the other reading — an EMPTY SLOT with the list
    /// continuing past it — is not ruled out by anything observed so far. Stopping well short of the
    /// announced count is the evidence that would settle it, so the report has to say so loudly rather
    /// than reporting a confident short list.
    func testStoppingOnValidKeyFalseShortOfTheAnnouncedCountIsFlagged() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 40))
        XCTAssertTrue(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 0, validKey: true, key: "enable_r22_packets")))
        XCTAssertFalse(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 1, validKey: false, key: nil)))

        let why = try! XCTUnwrap(report.stopReason)
        XCTAssertTrue(why.contains("2 of 40 announced entries"), why)
        XCTAssertTrue(why.contains("the remainder was NOT walked"), why)
    }

    /// …and when the count was fully walked, the plain reason stands — no false alarm.
    func testValidKeyFalseAtTheAnnouncedEndIsNotFlagged() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 1))
        XCTAssertFalse(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 0, validKey: false, key: nil)))
        XCTAssertEqual(report.stopReason, "firmware reported validKey=false")
    }

    /// The verdict must never blame the strap for our own decode. A firmware whose names all fail our
    /// printable-ASCII/length filter DID name them; reporting "named none" points at the strap and is the
    /// sentence someone would paste into #103.
    func testVerdictBlamesOurParserNotTheStrapWhenEveryNameFails() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 3))
        for i in 0..<3 {
            _ = report.noteNext(FeatureFlagProbe.NextResponse(
                resultCode: 1, revision: 1, index: i, validKey: true, key: nil))
        }
        XCTAssertTrue(report.keys.isEmpty)
        XCTAssertEqual(report.skipped, 3)
        let v = report.verdict
        XCTAssertTrue(v.contains("strap named 3 flag(s)"), v)
        XCTAssertTrue(v.contains("our parser rejecting them"), v)
        XCTAssertFalse(v.contains("named none"), "must not report our limitation as the strap's behaviour")
    }

    /// A partial success says so in the headline too, not only in the flag-count line.
    func testVerdictReportsSkippedAlongsideTheKeysItDidGet() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 3))
        _ = report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 0, validKey: true, key: "enable_r22_packets"))
        _ = report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 1, validKey: true, key: nil))
        XCTAssertEqual(report.verdict,
                       "enumerated 1 feature-flag key name(s); 1 further name(s) did not decode")
    }

    /// The skip cannot become an unbounded walk: `maxFlags` still terminates a firmware that answers
    /// forever with entries whose names never decode.
    func testEveryReplyUndecodableStillStopsAtTheSafetyCap() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        var sent = 0
        while report.noteNext(FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: 0,
                                                            validKey: true, key: nil)) {
            sent += 1
            XCTAssertLessThan(sent, FeatureFlagProbe.maxFlags + 2, "walk must not run away")
        }
        XCTAssertEqual(report.steps, FeatureFlagProbe.maxFlags)
        XCTAssertEqual(report.skipped, FeatureFlagProbe.maxFlags)
        XCTAssertEqual(report.stopReason, "safety cap of \(FeatureFlagProbe.maxFlags) replies reached")
        XCTAssertTrue(report.keys.isEmpty)
    }

    func testKeyLongerThanTheSetSideFieldIsRejected() {
        let long = String(repeating: "a", count: FeatureFlagProbe.maxKeyLength + 1)
        XCTAssertNil(FeatureFlagProbe.asciiKey(Array(long.utf8) + [0x00]))
        XCTAssertEqual(FeatureFlagProbe.asciiKey(Array("ok_key".utf8) + [0x00, 0x41]), "ok_key")
    }

    // MARK: - Failure paths (the handler must survive every one)

    func testBadCRCIsRejected() {
        var frame = whoop4Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x0B, 0x00]))
        frame[frame.count - 1] ^= 0xFF          // corrupt the CRC32 trailer
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: frame, family: .whoop4), .failure(.crc))

        var five = whoop5Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0x00, 0x01] + keyBytes("x")))
        five[7] ^= 0xFF                          // corrupt the CRC16 header
        XCTAssertEqual(FeatureFlagProbe.parseNext(frame: five, family: .whoop5), .failure(.crc))
    }

    func testCorruptPayloadBytesFailCRCBeforeAnyFieldIsRead() {
        // A single flipped bit inside the record must be rejected, not decoded into a bogus key.
        var frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0x00, 0x01] + keyBytes("enable_r22_packets")))
        frame[10] ^= 0x01
        XCTAssertEqual(FeatureFlagProbe.parseNext(frame: frame, family: .whoop4), .failure(.crc))
    }

    func testWrongCommandIsRejected() {
        let frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0x00, 0x01] + keyBytes("x")))
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: frame, family: .whoop4), .failure(.wrongCommand))
    }

    func testNonCommandResponseTypeIsRejected() {
        // Same bytes, but the packet type is COMMAND (35) rather than COMMAND_RESPONSE (36).
        var inner: [UInt8] = [35, 1, 117] + payload(result: 1, record: [0x01, 0x0B, 0x00])
        let length = UInt16(inner.count + 4)
        let lenBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
        var frame: [UInt8] = [0xAA] + lenBytes + [crc8(lenBytes)] + inner
        let c = crc32(inner)
        frame += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 24) & 0xFF)]
        inner = []
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: frame, family: .whoop4), .failure(.envelope))
    }

    func testTruncatedRecordsAreRejected() {
        // START with only the revision byte (no u16 count).
        let short = whoop4Response(cmd: 117, payload: payload(result: 1, record: [0x01]))
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: short, family: .whoop4), .failure(.truncated))
        // NEXT with a header but no record at all.
        let header = whoop4Response(cmd: 118, payload: [0x0A, 0x01])
        XCTAssertEqual(FeatureFlagProbe.parseNext(frame: header, family: .whoop4), .failure(.truncated))
        // A frame chopped mid-envelope can't even be verified.
        let full = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x02, 0x00]))
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: Array(full.prefix(9)), family: .whoop5), .failure(.crc))
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: [], family: .whoop4), .failure(.crc))
    }

    // MARK: - Report

    func testFullWalkRendersEveryKeyAndStopsOnTheEndMarker() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        let start = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x03, 0x00]))
        guard case .success(let s) = FeatureFlagProbe.parseStart(frame: start, family: .whoop5) else {
            return XCTFail("start")
        }
        report.noteStart(s)
        let names = ["enable_r22_packets", "hr_ch_switching", "wear_detect_bias"]
        for (i, name) in names.enumerated() {
            let record: [UInt8] = [0x01, UInt8(i), 0x01] + keyBytes(name)
            let frame = whoop5Response(cmd: 118, payload: payload(result: 1, record: record))
            guard case .success(let n) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop5) else {
                return XCTFail("next \(i)")
            }
            let keepGoing = report.noteNext(n)
            XCTAssertEqual(keepGoing, i < names.count - 1, "the announced count bounds the walk")
        }
        XCTAssertEqual(report.keys, names)
        let text = report.render()
        XCTAssertTrue(text.contains("#761 FEATURE-FLAG ENUMERATION PROBE — WHOOP 5/MG"))
        XCTAssertTrue(text.contains("Read-only"))
        XCTAssertTrue(text.contains("enumerated 3 feature-flag key name(s)"))
        XCTAssertTrue(text.contains("Flags reported by the strap (3 of 3 announced)"))
        XCTAssertTrue(text.contains("   1. enable_r22_packets"))
        XCTAssertTrue(text.contains("   3. wear_detect_bias"))
        XCTAssertTrue(text.contains("walked the 3 entries the strap announced"))
        XCTAssertTrue(text.contains("START_FF_KEY_EXCHANGE(117) → revision=1 count=3 result=SUCCESS(1)"))
        XCTAssertTrue(text.contains("SEND_NEXT_FF(118) → index=0 validKey=true key=\"enable_r22_packets\""))
    }

    func testRepeatedKeysCannotDriveAnUnboundedWalk() {
        // A firmware whose cursor never advances repeats one entry: the reply-count cap must stop it.
        var report = FeatureFlagProbeReport(family: .whoop4)
        let record: [UInt8] = [0x01, 0x00, 0x01] + keyBytes("stuck_cursor")
        let frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: record))
        guard case .success(let n) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop4) else {
            return XCTFail("next")
        }
        var steps = 0
        while report.noteNext(n) {
            steps += 1
            XCTAssertLessThan(steps, FeatureFlagProbe.maxFlags + 2, "the walk must terminate")
        }
        XCTAssertEqual(report.keys, ["stuck_cursor"], "a repeated name is collected once")
        XCTAssertEqual(report.steps, FeatureFlagProbe.maxFlags)
        XCTAssertEqual(report.stopReason, "safety cap of 128 replies reached")
    }

    func testTimeoutAndFailureAreReportedNotSwallowed() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteTimeout(command: 117, seconds: 8)
        let text = report.render()
        XCTAssertTrue(text.contains("no COMMAND_RESPONSE for opcode 117 within 8s"))
        XCTAssertTrue(text.contains("no usable reply — the enumerate path is unconfirmed"))
        XCTAssertTrue(text.contains("(none)"))

        var other = FeatureFlagProbeReport(family: .whoop4)
        other.noteFailure(.crc, command: 118)
        XCTAssertTrue(other.render().contains("CRC failed — frame rejected (never decoded)"))
    }

    /// GOLDEN: the exact rendered report, byte-for-byte. Its Kotlin twin
    /// (`FeatureFlagProbeTest.goldenReportIsByteIdenticalAcrossPlatforms`) asserts the SAME literal, so a
    /// strap log reads identically on either platform — that is the parity contract, and a whitespace or
    /// wording drift on one side fails there rather than in a user's log.
    func testGoldenReportIsByteIdenticalAcrossPlatforms() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        let start = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x02, 0x00]))
        guard case .success(let s) = FeatureFlagProbe.parseStart(frame: start, family: .whoop5) else {
            return XCTFail("start")
        }
        report.noteStart(s)
        let first = whoop5Response(cmd: 118, payload: payload(
            result: 1, record: [0x01, 0x00, 0x01] + keyBytes("enable_r22_packets")))
        guard case .success(let n1) = FeatureFlagProbe.parseNext(frame: first, family: .whoop5) else {
            return XCTFail("next 1")
        }
        XCTAssertTrue(report.noteNext(n1))
        let end = whoop5Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0xFF, 0x00, 0x00]))
        guard case .success(let n2) = FeatureFlagProbe.parseNext(frame: end, family: .whoop5) else {
            return XCTFail("next 2")
        }
        XCTAssertFalse(report.noteNext(n2))

        let golden = """
        #761 FEATURE-FLAG ENUMERATION PROBE — WHOOP 5/MG
        Read-only: START_FF_KEY_EXCHANGE(117) + SEND_NEXT_FF(118). No value is written; SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119) are never sent from this path.

        Verdict: enumerated 1 feature-flag key name(s)
        Stopped: cursor exhausted (index 0xFF)

        Flags reported by the strap (1 of 2 announced):
           1. enable_r22_packets

        Exchange:
          START_FF_KEY_EXCHANGE(117) → revision=1 count=2 result=SUCCESS(1)
          SEND_NEXT_FF(118) → index=0 validKey=true key="enable_r22_packets" result=SUCCESS(1)
          SEND_NEXT_FF(118) → index=255 validKey=false result=SUCCESS(1)

        """
        XCTAssertEqual(report.render(), golden)
    }

    /// The 117 answer landed and then nothing did: `BLEManager.probeFeatureFlags()` sends 118, the 8s
    /// timer fires, and the report renders with zero SEND_NEXT replies. "Named none" would be a claim
    /// about the strap's key list that this run's own inputs cannot support — the list was never read.
    /// Same class as the `skipped > 0` branch beside it: never report our limitation as the strap's
    /// behaviour.
    func testAnnouncedCountWithNo118ReplyIsInconclusiveNotBlamedOnTheStrap() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        let start = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x05, 0x00]))
        guard case .success(let s) = FeatureFlagProbe.parseStart(frame: start, family: .whoop5) else {
            return XCTFail("start")
        }
        report.noteStart(s)
        report.noteTimeout(command: 118, seconds: 8)

        XCTAssertEqual(report.steps, 0, "no SEND_NEXT reply was decoded")
        let v = report.verdict
        XCTAssertEqual(v, "strap announced 5 flag(s); no SEND_NEXT_FF(118) reply was decoded — "
                       + "the key list was never read (inconclusive)")
        XCTAssertFalse(v.contains("named none"),
                       "must not report our own timeout as the strap serving no names")
    }

    /// A 118 reply that DID land and carried no name is the opposite case: the strap walked its own
    /// cursor straight to the end marker, so "named none" is a fact about the strap and is said plainly.
    func testAnnouncedCountWithARealEmptyWalkIsSaidPlainly() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        let start = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x05, 0x00]))
        guard case .success(let s) = FeatureFlagProbe.parseStart(frame: start, family: .whoop5) else {
            return XCTFail("start")
        }
        report.noteStart(s)
        XCTAssertFalse(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 0xFF, validKey: false, key: nil)))

        XCTAssertEqual(report.steps, 1)
        XCTAssertEqual(report.keys, [])
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.verdict, "strap announced 5 flag(s) but named none")
    }

    /// The count itself is the strap's claim, not a measurement. `noteStart` already marks an implausible
    /// one in the trace; the verdict is the line that gets pasted into an issue, so it carries the doubt
    /// too rather than restating the number as bare fact.
    func testImplausibleAnnouncedCountIsNotRestatedAsFactInTheVerdict() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 9999))
        report.noteTimeout(command: 118, seconds: 8)

        let v = report.verdict
        XCTAssertTrue(v.contains("an implausible 9999 flag(s)"), v)
        XCTAssertTrue(v.contains("(inconclusive)"), v)
    }
}
