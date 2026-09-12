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

    /// `validKey = 0` alone is NOT classified as the strap's end marker any more — it is an empty slot,
    /// and the walk steps over it. The entry itself is still never collected as a key.
    func testValidKeyFalseIsAnEmptySlotNotTheEndMarker() {
        // validKey=0 with a plausible-looking name after it: still not a key, still not the end.
        let record: [UInt8] = [0x01, 0x04, 0x00] + keyBytes("stale_buffer_leftover")
        let frame = whoop4Response(cmd: 118, payload: payload(result: 1, record: record))
        guard case .success(let r) = FeatureFlagProbe.parseNext(frame: frame, family: .whoop4) else {
            return XCTFail("expected a decoded NEXT response")
        }
        XCTAssertFalse(r.validKey)
        XCTAssertFalse(r.isExhausted, "only index=0xFF is the strap's unambiguous end marker")
        XCTAssertTrue(r.isEmptySlot)
        var report = FeatureFlagProbeReport(family: .whoop4)
        XCTAssertTrue(report.noteNext(r), "validKey=0 without 0xFF must not end the walk")
        XCTAssertNil(report.stopReason)
        XCTAssertEqual(report.emptySlots, 1)
        XCTAssertTrue(report.keys.isEmpty, "an invalid entry must never be collected as a flag")
    }

    /// The whole experiment, in one walk: the strap serves `validKey = 0` mid-list, the walk keeps asking,
    /// and the strap names MORE keys before ending on 0xFF. That sequence is decisive — under the old rule
    /// this list would have been reported as one key long.
    func testWalkContinuesPastValidKeyZeroAndCollectsTheKeysAfterIt() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 5,
                                                        record: [0x01, 0x05, 0x00]))
        func next(_ index: Int, valid: Bool, _ key: String?) -> FeatureFlagProbe.NextResponse {
            FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: index, validKey: valid,
                                          key: key, record: [0x01, UInt8(index), valid ? 1 : 0])
        }
        XCTAssertTrue(report.noteNext(next(1, valid: true, "enable_r22_packets")))
        XCTAssertTrue(report.noteNext(next(2, valid: false, nil)), "an empty slot must not end the walk")
        XCTAssertTrue(report.noteNext(next(3, valid: false, nil)), "nor must a second one")
        XCTAssertTrue(report.noteNext(next(4, valid: true, "enable_sig12")))
        XCTAssertFalse(report.noteNext(next(0xFF, valid: false, nil)))

        XCTAssertEqual(report.keys, ["enable_r22_packets", "enable_sig12"])
        XCTAssertEqual(report.emptySlots, 2)
        XCTAssertEqual(report.keysAfterFirstEmptySlot, 1)
        XCTAssertEqual(report.stopCode, .endMarker)
        let finding = report.terminatorFinding
        XCTAssertTrue(finding.hasPrefix("DECISIVE — validKey=0 is an EMPTY/RETIRED SLOT"), finding)
        XCTAssertTrue(finding.contains("naming 1 more key(s)"), finding)
        XCTAssertTrue(report.render().contains("2 validKey=0 slot(s) stepped over"))
    }

    /// #874's rule reaches the CONCLUSION too. The strap flagged an entry past the hole as real; our ASCII
    /// filter declined its name. The list still continued, so the finding must still be decisive — reading
    /// "inconclusive" here would be our parser deciding a question about the firmware.
    func testAnUndecodableEntryAfterAnEmptySlotIsStillDecisive() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 30,
                                                        record: [0x01, 0x1E, 0x00]))
        XCTAssertTrue(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 1, validKey: false, key: nil, record: [0x01, 0x01, 0x00])))
        XCTAssertTrue(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 2, validKey: true, key: nil,
            record: [0x01, 0x02, 0x01, 0xDE, 0xAD])))
        XCTAssertEqual(report.keys, [], "no name decoded, so no key is invented")
        XCTAssertEqual(report.keysAfterFirstEmptySlot, 0)
        XCTAssertEqual(report.validEntriesAfterFirstEmptySlot, 1)
        let finding = report.terminatorFinding
        XCTAssertTrue(finding.hasPrefix("DECISIVE — validKey=0 is an EMPTY/RETIRED SLOT"), finding)
        XCTAssertTrue(finding.contains("1 of them flagged validKey=1"), finding)
        XCTAssertFalse(finding.contains("naming"), finding)
    }

    /// The other decisive outcome, and the one that costs two round-trips: the strap repeats the same
    /// index with `validKey = 0`. What that decides is that the cursor does not advance, so this walk
    /// cannot see past the point — NOT that the list ends there. A firmware whose cursor parks on an
    /// empty slot emits the identical frame, and that is the reading this whole probe exists to make
    /// testable, so the verdict must not print it as settled. Both halves are pinned below: the DECISIVE
    /// label stays, and the over-claim must not come back.
    func testRepeatedEmptySlotAtTheSameIndexIsReportedAsATerminator() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 9,
                                                        record: [0x01, 0x09, 0x00]))
        let empty = FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: 7, validKey: false,
                                                  key: nil, record: [0x01, 0x07, 0x00])
        XCTAssertTrue(report.noteNext(empty), "the first empty slot is stepped over")
        XCTAssertFalse(report.noteNext(empty), "a parked cursor ends the walk")
        XCTAssertEqual(report.stopCode, .emptySlotCursorParked)
        XCTAssertTrue(report.terminatorFinding.hasPrefix("DECISIVE — validKey=0 is a TERMINATOR"),
                      report.terminatorFinding)
        // The narrowing, pinned so it cannot be quietly widened back. "There is nothing past it" is the
        // conclusion a reader would paste into an issue as settled, and it is the one this probe exists
        // to question — two firmwares emit this identical frame.
        XCTAssertTrue(report.terminatorFinding.contains("the cursor does not advance past it"),
                      report.terminatorFinding)
        XCTAssertTrue(report.terminatorFinding.contains(
            "not separable from a firmware whose cursor parks on an empty slot"),
                      report.terminatorFinding)
        XCTAssertFalse(report.terminatorFinding.contains("there is nothing past it"),
                       "the walk observes a stalled cursor, not an empty tail: \(report.terminatorFinding)")
        XCTAssertEqual(report.steps, 2, "settling this must cost two round-trips, not a full cap")
    }

    /// A firmware that answers `validKey = 0` forever with an ADVANCING index cannot run the walk away:
    /// the consecutive-empty cap stops it, and names itself a CLIENT-side bound so the run is never read
    /// as a complete list.
    func testAnUnendingRunOfEmptySlotsStopsAtTheConsecutiveCap() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        var index = 0
        var sent = 0
        while report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: index, validKey: false, key: nil,
            record: [0x01, UInt8(index), 0x00])) {
            index += 1
            sent += 1
            XCTAssertLessThan(sent, FeatureFlagProbe.maxConsecutiveEmptySlots + 2, "walk must not run away")
        }
        XCTAssertEqual(report.steps, FeatureFlagProbe.maxConsecutiveEmptySlots)
        XCTAssertEqual(report.stopCode, .emptySlotRunCap)
        let why = report.stopReason ?? ""
        XCTAssertTrue(why.contains("a CLIENT-side bound, not the strap's"), why)
        XCTAssertTrue(report.terminatorFinding.hasPrefix("INCONCLUSIVE"), report.terminatorFinding)
    }

    /// A valid entry resets the run, so scattered holes cost nothing against the cap.
    func testAValidEntryResetsTheConsecutiveEmptySlotRun() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        func empty(_ i: Int) -> FeatureFlagProbe.NextResponse {
            FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: i, validKey: false, key: nil,
                                          record: [0x01, UInt8(i), 0x00])
        }
        func valid(_ i: Int, _ k: String) -> FeatureFlagProbe.NextResponse {
            FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: i, validKey: true, key: k,
                                          record: [0x01, UInt8(i), 0x01])
        }
        for i in 0..<(FeatureFlagProbe.maxConsecutiveEmptySlots - 1) {
            XCTAssertTrue(report.noteNext(empty(i)))
        }
        XCTAssertTrue(report.noteNext(valid(20, "hr_ch_switching")))
        for i in 21..<(21 + FeatureFlagProbe.maxConsecutiveEmptySlots - 1) {
            XCTAssertTrue(report.noteNext(empty(i)), "the run restarted at the valid entry")
        }
        XCTAssertNil(report.stopCode)
        XCTAssertEqual(report.keys, ["hr_ch_switching"])
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

    /// The reply a WHOOP 5 MG actually served to end its 115/116 walk: `index = 255` and `validKey = 0`
    /// on the SAME frame. Both terminator conditions fired at once, so that run cannot say which one the
    /// firmware meant — and the report must say exactly that instead of picking one.
    func testEndMarkerCarryingValidKeyZeroIsReportedAsAmbiguous() {
        var report = FeatureFlagProbeReport(family: .whoop5,
                                            namespace: FeatureFlagProbe.deviceConfigNamespace)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 7,
                                                        record: [0x01, 0x07, 0x00]))
        XCTAssertTrue(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 1, validKey: true, key: "enable_rfid",
            record: [0x01, 0x01, 0x01])))
        XCTAssertFalse(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 0xFF, validKey: false, key: nil,
            record: [0x01, 0xFF, 0x00, 0x00])))

        XCTAssertTrue(report.endMarkerAlsoCarriedInvalidFlag)
        XCTAssertEqual(report.stopCode, .endMarker)
        XCTAssertTrue(report.terminatorFinding.hasPrefix("AMBIGUOUS"), report.terminatorFinding)
        XCTAssertTrue(report.terminatorFinding.contains("both terminator conditions fired at once"),
                      report.terminatorFinding)
        XCTAssertTrue(report.render().contains("index=0xFF AND validKey=0 on the same reply"))
    }

    /// The 0xFF marker with `validKey` still true separates the two conditions the other way, and the
    /// report has to be equally careful there: 0xFF alone terminated, and validKey=0 stayed untested.
    func testEndMarkerWithValidKeyTrueSaysValidKeyZeroIsUntested() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 2,
                                                        record: [0x01, 0x02, 0x00]))
        XCTAssertTrue(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 1, validKey: true, key: "enable_r22_packets",
            record: [0x01, 0x01, 0x01])))
        XCTAssertFalse(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 0xFF, validKey: true, key: nil,
            record: [0x01, 0xFF, 0x01])))
        XCTAssertFalse(report.endMarkerAlsoCarriedInvalidFlag)
        XCTAssertTrue(report.terminatorFinding.contains("validKey=0 was never served, so it is untested"),
                      report.terminatorFinding)
    }

    /// What the 117/118 walk on a 5/MG actually did: sixteen valid, named entries and NO terminator of
    /// either kind. The walk used to stop dead at the announced count and read as a complete list. It now
    /// asks a bounded number of further times, and — whatever comes back — reports in the verdict itself
    /// that a client-side bound ended the run.
    func testWalkOvershootsTheAnnouncedCountSoTheStrapCanEndItsOwnList() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 3,
                                                        record: [0x01, 0x03, 0x00]))
        var sent = 0
        var keepGoing = true
        while keepGoing {
            sent += 1
            keepGoing = report.noteNext(FeatureFlagProbe.NextResponse(
                resultCode: 1, revision: 1, index: sent, validKey: true, key: "key_\(sent)",
                record: [0x01, UInt8(sent), 0x01]))
        }
        XCTAssertEqual(sent, 3 + FeatureFlagProbe.countOvershootAllowance,
                       "the strap gets \(FeatureFlagProbe.countOvershootAllowance) replies past its own count")
        XCTAssertEqual(report.stopCode, .announcedCountOvershoot)
        XCTAssertEqual(report.repliesPastAnnouncedCount, FeatureFlagProbe.countOvershootAllowance)
        XCTAssertTrue(report.verdict.contains("INCOMPLETE: the walk ended on a client-side bound"),
                      report.verdict)
        XCTAssertTrue(report.terminatorFinding.hasPrefix("NO TERMINATOR OBSERVED"),
                      report.terminatorFinding)
        // …and the count line reports the arithmetic that makes it a finding.
        let count = try! XCTUnwrap(report.countFinding)
        XCTAssertTrue(count.contains("Keys yielded: 7"), count)
        XCTAssertTrue(count.contains("MISMATCH against the announced 3"), count)
        XCTAssertTrue(count.contains("kept answering 4 repl(ies) past its own announced count"), count)
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
            XCTAssertTrue(report.noteNext(n), "the announced count no longer ends the walk by itself")
        }
        // The strap's own end marker — the only thing that ends a walk cleanly.
        let end = whoop5Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0xFF, 0x00, 0x00]))
        guard case .success(let last) = FeatureFlagProbe.parseNext(frame: end, family: .whoop5) else {
            return XCTFail("end marker")
        }
        XCTAssertFalse(report.noteNext(last))
        XCTAssertEqual(report.keys, names)
        XCTAssertEqual(report.stopCode, .endMarker)
        let text = report.render()
        XCTAssertTrue(text.contains("#761 FEATURE-FLAG ENUMERATION PROBE — WHOOP 5/MG"))
        XCTAssertTrue(text.contains("Read-only"))
        XCTAssertTrue(text.contains("enumerated 3 feature-flag key name(s)"))
        XCTAssertTrue(text.contains("Flags reported by the strap (3 of 3 announced)"))
        XCTAssertTrue(text.contains("   1. enable_r22_packets"))
        XCTAssertTrue(text.contains("   3. wear_detect_bias"))
        XCTAssertTrue(text.contains("Stop code: endMarker"))
        XCTAssertTrue(text.contains("START_FF_KEY_EXCHANGE(117) → revision=1 count=3 result=SUCCESS(1)"))
        XCTAssertTrue(text.contains("SEND_NEXT_FF(118) → index=0 validKey=true key=\"enable_r22_packets\""))
    }

    // MARK: - Raw bytes

    /// Requirement of the whole exercise: the RAW record bytes of every reply are in the report, not only
    /// the fields parsed out of them. Earlier findings here had to be re-run because only parsed output
    /// survived, and a parsed field cannot contradict the layout that produced it.
    func testEveryReplyLogsItsRawRecordBytes() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        let start = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x02, 0x00]))
        guard case .success(let s) = FeatureFlagProbe.parseStart(frame: start, family: .whoop5) else {
            return XCTFail("start")
        }
        report.noteStart(s)
        XCTAssertEqual(s.record, [0x01, 0x02, 0x00], "the parse keeps the bytes it decoded from")
        let next = whoop5Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0x00, 0x01, 0x78, 0x00]))
        guard case .success(let n) = FeatureFlagProbe.parseNext(frame: next, family: .whoop5) else {
            return XCTFail("next")
        }
        XCTAssertTrue(report.noteNext(n))
        let text = report.render()
        XCTAssertTrue(text.contains("raw=01 02 00"), text)
        XCTAssertTrue(text.contains("raw=01 00 01 78 00"), text)
    }

    /// A reply that failed to decode is the one whose raw bytes matter most, so the whole frame goes in.
    func testUndecodedReplyLogsTheWholeRawFrame() {
        var report = FeatureFlagProbeReport(family: .whoop4)
        report.noteFailure(.crc, command: 118, frame: [0xAA, 0x05, 0x00, 0x2B, 0x24])
        XCTAssertTrue(report.render().contains("raw frame=aa 05 00 2b 24"), report.render())
        XCTAssertEqual(report.stopCode, .parseFailure)
    }

    /// The hex is bounded so one absurd record cannot flood the log — but the true LENGTH is always
    /// printed, because an over-long record is itself evidence that the layout is wrong.
    func testOverLongRawRecordIsElidedButItsLengthIsKept() {
        let long = [UInt8](repeating: 0xAB, count: FeatureFlagProbe.maxRawHexBytes + 10)
        let rendered = FeatureFlagProbe.hex(long)
        XCTAssertTrue(rendered.hasSuffix("… (\(FeatureFlagProbe.maxRawHexBytes + 10) bytes total)"), rendered)
        XCTAssertEqual(FeatureFlagProbe.hex([]), "(empty)")
    }

    // MARK: - The announced count

    /// The count is read as u16 LE, and every count seen so far has had a zero high byte — where a
    /// single-byte read returns the SAME number. So no capture distinguishes the two readings, and the
    /// report says that rather than asserting a field width nothing has established.
    func testCountCarriesBothReadingsAndSaysWhenTheyAgree() {
        let frame = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x10, 0x00]))
        guard case .success(let r) = FeatureFlagProbe.parseStart(frame: frame, family: .whoop5) else {
            return XCTFail("start")
        }
        XCTAssertEqual(r.count, 16)
        XCTAssertEqual(r.singleByteCount, 16)
        XCTAssertEqual(r.countHighByte, 0)
        XCTAssertTrue(r.countReadingsAgree)
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(r)
        let finding = try! XCTUnwrap(report.countFinding)
        XCTAssertTrue(finding.contains("u16 LE read = 16; single-byte read = 16 (high byte 0x00)"), finding)
        XCTAssertTrue(finding.contains("the two readings AGREE"), finding)
    }

    /// A nonzero high byte is the only thing that separates them, and it is a finding either way: on the
    /// u16 reading the list is enormous, on the single-byte reading `record[2]` is padding.
    func testNonZeroHighByteIsReportedAsADisagreement() {
        let frame = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x07, 0x02]))
        guard case .success(let r) = FeatureFlagProbe.parseStart(frame: frame, family: .whoop5) else {
            return XCTFail("start")
        }
        XCTAssertEqual(r.count, 0x0207)
        XCTAssertEqual(r.singleByteCount, 7)
        XCTAssertFalse(r.countReadingsAgree)
        XCTAssertFalse(r.countIsPlausible, "an implausible u16 must not become a loop bound")
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(r)
        let finding = try! XCTUnwrap(report.countFinding)
        XCTAssertTrue(finding.contains("single-byte read = 7 (high byte 0x02)"), finding)
        XCTAssertTrue(finding.contains("the two readings DISAGREE"), finding)
    }

    /// Announced-count-versus-yielded is itself a result. A strap that announces sixteen and names
    /// fourteen has two entries nobody has accounted for, and the report has to raise it rather than
    /// print a tidy short list.
    func testAnnouncedCountVersusKeysYieldedMismatchIsReported() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 16,
                                                        record: [0x01, 0x10, 0x00]))
        XCTAssertTrue(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 1, validKey: true, key: "enable_r22_packets",
            record: [0x01, 0x01, 0x01])))
        XCTAssertFalse(report.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 0xFF, validKey: true, key: nil,
            record: [0x01, 0xFF, 0x01])))
        let finding = try! XCTUnwrap(report.countFinding)
        XCTAssertTrue(finding.contains("Keys yielded: 1"), finding)
        XCTAssertTrue(finding.contains("MISMATCH against the announced 16"), finding)
    }

    /// …and when everything is accounted for — keys plus skipped plus empty slots — there is no alarm.
    func testFullyAccountedCountIsNotFlaggedAsAMismatch() {
        var report = FeatureFlagProbeReport(family: .whoop5)
        report.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 3,
                                                        record: [0x01, 0x03, 0x00]))
        _ = report.noteNext(FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: 1,
                                                          validKey: true, key: "a", record: [0x01, 0x01, 0x01]))
        _ = report.noteNext(FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: 2,
                                                          validKey: true, key: nil, record: [0x01, 0x02, 0x01]))
        _ = report.noteNext(FeatureFlagProbe.NextResponse(resultCode: 1, revision: 1, index: 3,
                                                          validKey: false, key: nil, record: [0x01, 0x03, 0x00]))
        let finding = try! XCTUnwrap(report.countFinding)
        XCTAssertFalse(finding.contains("MISMATCH"), finding)
        XCTAssertTrue(finding.contains("Keys yielded: 1 (+1 undecodable) (+1 empty slot(s))"), finding)
    }

    // MARK: - The device-config namespace (115/116)

    /// The SAME walk drives the device-config pair, so the terminator rules cannot be corrected in one
    /// namespace and left wrong in the other. Decoded end-to-end from 115/116 frames.
    func testDeviceConfigNamespaceWalksThroughTheSameCorrectedRules() {
        var report = FeatureFlagProbeReport(family: .whoop5,
                                            namespace: FeatureFlagProbe.deviceConfigNamespace)
        let start = whoop5Response(cmd: 115, payload: payload(result: 1, record: [0x01, 0x02, 0x00]))
        guard case .success(let s) = FeatureFlagProbe.parseStart(frame: start, family: .whoop5,
                                                                 expecting: 115) else {
            return XCTFail("115 start")
        }
        report.noteStart(s)
        // An empty slot first — under the old rule the walk would have ended here with zero keys.
        let hole = whoop5Response(cmd: 116, payload: payload(result: 1, record: [0x01, 0x02, 0x00, 0x00]))
        guard case .success(let h) = FeatureFlagProbe.parseNext(frame: hole, family: .whoop5,
                                                                expecting: 116) else {
            return XCTFail("116 hole")
        }
        XCTAssertTrue(report.noteNext(h))
        let named = whoop5Response(cmd: 116, payload: payload(
            result: 1, record: [0x01, 0x03, 0x01] + keyBytes("enable_raw_data_w_ecg")))
        guard case .success(let n) = FeatureFlagProbe.parseNext(frame: named, family: .whoop5,
                                                                expecting: 116) else {
            return XCTFail("116 named")
        }
        XCTAssertTrue(report.noteNext(n))
        XCTAssertEqual(report.keys, ["enable_raw_data_w_ecg"],
                       "the key AFTER the empty slot is exactly what the old rule discarded")

        let text = report.render()
        XCTAssertTrue(text.contains("#761 DEVICE-CONFIG ENUMERATION PROBE — WHOOP 5/MG"), text)
        XCTAssertTrue(text.contains("START_DEVICE_CONFIG_KEY_EXCHANGE(115) + SEND_NEXT_DEVICE_CONFIG(116)"), text)
        XCTAssertTrue(text.contains("Keys reported by the strap (1 of 2 announced"), text)
        XCTAssertTrue(text.contains("SEND_NEXT_DEVICE_CONFIG(116) → index=3"), text)
    }

    /// An explicit refusal is the strap's answer, not one of our bounds, and it must end the walk with its
    /// own name — on the START reply (where the driver reads `hasStopped` instead of stepping to 118) and
    /// on a NEXT reply alike.
    func testUnsupportedRefusalEndsTheWalkWithItsOwnStopCode() {
        var start = FeatureFlagProbeReport(family: .whoop5)
        XCTAssertFalse(start.hasStopped)
        start.noteStart(FeatureFlagProbe.StartResponse(resultCode: 3, revision: 0, count: 0,
                                                       record: [0x00, 0x00, 0x00]))
        XCTAssertTrue(start.hasStopped, "a refused START must not step on to the next verb")
        XCTAssertEqual(start.stopCode, .unsupported)
        XCTAssertTrue(start.render().contains("Stop code: unsupported"))

        var mid = FeatureFlagProbeReport(family: .whoop5)
        mid.noteStart(FeatureFlagProbe.StartResponse(resultCode: 1, revision: 1, count: 4,
                                                     record: [0x01, 0x04, 0x00]))
        XCTAssertTrue(mid.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 1, revision: 1, index: 1, validKey: true, key: "enable_r22_packets",
            record: [0x01, 0x01, 0x01])))
        XCTAssertFalse(mid.noteNext(FeatureFlagProbe.NextResponse(
            resultCode: 3, revision: 0, index: 0, validKey: false, key: nil, record: [0x00, 0x00, 0x00])))
        XCTAssertEqual(mid.stopCode, .unsupported)
        XCTAssertEqual(mid.emptySlots, 0, "a refusal is never counted as an empty slot")
        XCTAssertTrue(mid.stopReason?.contains("UNSUPPORTED(3)") == true, mid.stopReason ?? "")
    }

    /// The two platforms must classify the same reply the same way, or a strap log means different things
    /// on either side. These are the exact constants the walk is bounded by; the Kotlin twin
    /// (`walkBoundsMatchTheSwiftTwin`) asserts the same numbers and the same stop-code spellings.
    func testWalkBoundsMatchTheKotlinTwin() {
        XCTAssertEqual(FeatureFlagProbe.maxConsecutiveEmptySlots, 8)
        XCTAssertEqual(FeatureFlagProbe.countOvershootAllowance, 4)
        XCTAssertEqual(FeatureFlagProbe.maxRawHexBytes, 64)
        XCTAssertEqual(FeatureFlagProbe.maxFlags, 128)
        XCTAssertEqual(FeatureFlagProbe.StopCode.endMarker.rawValue, "endMarker")
        XCTAssertEqual(FeatureFlagProbe.StopCode.emptySlotCursorParked.rawValue, "emptySlotCursorParked")
        XCTAssertEqual(FeatureFlagProbe.StopCode.emptySlotRunCap.rawValue, "emptySlotRunCap")
        XCTAssertEqual(FeatureFlagProbe.StopCode.stepCap.rawValue, "stepCap")
        XCTAssertEqual(FeatureFlagProbe.StopCode.announcedCountOvershoot.rawValue, "announcedCountOvershoot")
        XCTAssertEqual(FeatureFlagProbe.StopCode.timeout.rawValue, "timeout")
        XCTAssertEqual(FeatureFlagProbe.StopCode.unsupported.rawValue, "unsupported")
        XCTAssertEqual(FeatureFlagProbe.StopCode.parseFailure.rawValue, "parseFailure")
    }

    /// The 115/116 frames must not decode as 117/118 by accident — the opcode is checked, both ways.
    func testTheTwoNamespacesDoNotDecodeEachOthersFrames() {
        let cfg = whoop5Response(cmd: 116, payload: payload(result: 1, record: [0x01, 0x00, 0x01]))
        XCTAssertEqual(FeatureFlagProbe.parseNext(frame: cfg, family: .whoop5), .failure(.wrongCommand))
        let ff = whoop5Response(cmd: 118, payload: payload(result: 1, record: [0x01, 0x00, 0x01]))
        XCTAssertEqual(FeatureFlagProbe.parseNext(frame: ff, family: .whoop5, expecting: 116),
                       .failure(.wrongCommand))
        XCTAssertEqual(FeatureFlagProbe.deviceConfigNamespace.startCmd, 115)
        XCTAssertEqual(FeatureFlagProbe.deviceConfigNamespace.nextCmd, 116)
        // Still read-only: the SET verbs appear in neither namespace.
        for ns in [FeatureFlagProbe.featureFlagNamespace, FeatureFlagProbe.deviceConfigNamespace] {
            XCTAssertFalse([119, 120].contains(Int(ns.startCmd)))
            XCTAssertFalse([119, 120].contains(Int(ns.nextCmd)))
        }
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
        Stop code: endMarker
        Terminator: AMBIGUOUS — the walk ended on a reply carrying index=0xFF AND validKey=0 together, so both terminator conditions fired at once and this run cannot say which one the firmware meant.
        Announced count: u16 LE read = 2; single-byte read = 2 (high byte 0x00) — the two readings AGREE, so this reply does not establish the field's width. Keys yielded: 1 — MISMATCH against the announced 2

        Flags reported by the strap (1 of 2 announced):
           1. enable_r22_packets

        Exchange:
          START_FF_KEY_EXCHANGE(117) → revision=1 count=2 result=SUCCESS(1) raw=01 02 00
          SEND_NEXT_FF(118) → index=0 validKey=true key="enable_r22_packets" result=SUCCESS(1) raw=01 00 01 65 6e 61 62 6c 65 5f 72 32 32 5f 70 61 63 6b 65 74 73 00 00 00 00 00 00 00 00 00 00
          SEND_NEXT_FF(118) → index=255 validKey=false result=SUCCESS(1) raw=01 ff 00 00 00 00 00  (index=0xFF AND validKey=0 on the same reply — both terminator conditions at once)

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

    // MARK: - direct caller of the verifier (2.5): the useful path is unchanged

    /// `FeatureFlagProbe.record` calls `verifyFrame` itself rather than going through `parseFrame`, so a
    /// stricter verifier could have silently broken this probe. These pin that it did not — the ordinary
    /// well-formed replies of BOTH families still decode — and that the classes the verifier newly
    /// rejects come back as `.crc`, its own refusal, rather than being read as data.
    func testTheOrdinaryReplyStillDecodesUnderTheTightenedVerifier() {
        let four = whoop4Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x0B, 0x00]))
        XCTAssertTrue(verifyFrame(four, family: .whoop4).ok, "precondition: an ordinary 4.0 reply is intact")
        XCTAssertEqual(verifyFrame(four, family: .whoop4).reason, .none)
        guard case .success = FeatureFlagProbe.parseStart(frame: four, family: .whoop4) else {
            return XCTFail("the 4.0 useful path must still decode")
        }
        let five = whoop5Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x10, 0x00]))
        XCTAssertTrue(verifyFrame(five, family: .whoop5).ok)
        guard case .success = FeatureFlagProbe.parseStart(frame: five, family: .whoop5) else {
            return XCTFail("the 5/MG useful path must still decode")
        }
    }

    func testAReplyWithTrailingBytesIsRefusedNotRead() {
        let frame = whoop4Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x0B, 0x00])) + [0x00]
        XCTAssertEqual(verifyFrame(frame, family: .whoop4).reason, .lengthMismatch)
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: frame, family: .whoop4), .failure(.crc))
    }

    func testAReplyWithABrokenHeaderChecksumIsRefusedNotRead() {
        var frame = whoop4Response(cmd: 117, payload: payload(result: 1, record: [0x01, 0x0B, 0x00]))
        frame[3] ^= 0xFF
        XCTAssertEqual(verifyFrame(frame, family: .whoop4).crc32OK, true, "the payload CRC32 still verifies")
        XCTAssertEqual(FeatureFlagProbe.parseStart(frame: frame, family: .whoop4), .failure(.crc))
    }
}
