import XCTest
@testable import WhoopProtocol

/// WHOOP MG ECG ("Labrador") decode + command construction.
///
/// Every fixture here is SYNTHETIC and hand-built in the test: no WHOOP MG ECG capture exists in this
/// repo, and inventing one would be worse than having none. What these tests DO pin is the thing a
/// capture cannot change — the structural contract: field order and widths, the length agreement between
/// `numberOfECGSamples` and the sample array, fail-closed behaviour on truncation and on a bad CRC, the
/// exact command bytes that go on the wire, and the run-scoped verdict logic.
final class Whoop5EcgTests: XCTestCase {

    // MARK: - Fixture builders

    /// The 17-byte status header, in wire order. Defaults are a mid-run, leads-on, medium-quality packet.
    private func header(signalQuality: UInt8 = 2,
                        statusFlags: UInt8 = 0x05,
                        started: UInt8 = 1,
                        running: UInt8 = 1,
                        stoppedAndComplete: UInt8 = 0,
                        leadsOn: UInt8 = 1,
                        arrhythmiaResult: UInt8 = 0,
                        arrhythmiaStatus: UInt8 = 1,
                        progress: UInt8 = 42,
                        unreadableReason: UInt8 = 0,
                        averageHR: UInt8 = 61,
                        hr: UInt8 = 63,
                        hrv: UInt16 = 812,
                        stress: UInt8 = 17,
                        samples: UInt16) -> [UInt8] {
        [signalQuality, statusFlags, started, running, stoppedAndComplete, leadsOn,
         arrhythmiaResult, arrhythmiaStatus, progress, unreadableReason, averageHR, hr,
         UInt8(hrv & 0xFF), UInt8(hrv >> 8), stress,
         UInt8(samples & 0xFF), UInt8(samples >> 8)]
    }

    private func i16le(_ values: [Int16]) -> [UInt8] {
        values.flatMap { v -> [UInt8] in
            let u = UInt16(bitPattern: v)
            return [UInt8(u & 0xFF), UInt8(u >> 8)]
        }
    }

    private func u16le(_ values: [UInt16]) -> [UInt8] {
        values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    /// Wrap a payload in a real, CRC-correct puffin frame using the shipped builder, so the frame-level
    /// tests exercise the same envelope the strap speaks.
    private func puffinFrame(type: UInt8, payload: [UInt8]) -> [UInt8] {
        puffinCommandFrame(cmd: 0x00, seq: 0x01, payload: payload, type: type)
    }

    // MARK: - Filtered packet

    func testFilteredDecodesEveryFieldInWireOrder() {
        let samples: [Int16] = [0, 1, -1, 32_767, -32_768, 250, -250]
        let payload = header(samples: UInt16(samples.count)) + i16le(samples)
        let packet = Whoop5Ecg.decodeFiltered(payload: payload)
        XCTAssertNotNil(packet)
        guard let packet else { return }

        XCTAssertEqual(packet.header.signalQuality, .medium)
        XCTAssertEqual(packet.header.statusFlags, 0x05)
        XCTAssertTrue(packet.header.heartKeyStarted)
        XCTAssertTrue(packet.header.heartKeyIsRunning)
        XCTAssertFalse(packet.header.heartKeyIsStoppedAndComplete)
        XCTAssertTrue(packet.header.heartKeyLeadsAreOn)
        XCTAssertEqual(packet.header.heartKeyArrhythmiaCheckResult, .notComplete)
        XCTAssertEqual(packet.header.heartKeyArrhythmiaCheckStatus, .inProgress)
        XCTAssertEqual(packet.header.heartKeyProgress, .percent(42))
        XCTAssertEqual(packet.header.heartKeyProgress.percentValue, 42)
        XCTAssertEqual(packet.header.heartKeyUnreadableReason, 0)
        XCTAssertEqual(packet.header.heartKeyAverageHR, 61)
        XCTAssertEqual(packet.header.heartKeyHR, 63)
        XCTAssertEqual(packet.header.heartKeyHRV, 812)          // u16 LE, not two u8s
        XCTAssertEqual(packet.header.heartKeyStressScore, 17)
        XCTAssertEqual(packet.header.numberOfECGSamples, 7)
        XCTAssertEqual(packet.filteredECGDataRaw, samples)      // signed, LE
        XCTAssertTrue(packet.padding.isEmpty)
    }

    func testFilteredCarriesTrailingPadding() {
        let payload = header(samples: 2) + i16le([5, -5]) + [0x00, 0x00, 0x00]
        let packet = Whoop5Ecg.decodeFiltered(payload: payload)
        XCTAssertEqual(packet?.filteredECGDataRaw, [5, -5])
        XCTAssertEqual(packet?.padding, [0x00, 0x00, 0x00])
    }

    func testFilteredZeroSamplesIsValid() {
        // A status-only packet (leads off, nothing captured yet) is legitimate, not an error.
        let payload = header(leadsOn: 0, samples: 0)
        let packet = Whoop5Ecg.decodeFiltered(payload: payload)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.filteredECGDataRaw, [])
        XCTAssertEqual(packet?.header.heartKeyLeadsAreOn, false)
    }

    func testFilteredRejectsShortHeader() {
        for count in 0..<Whoop5Ecg.headerLength {
            let payload = [UInt8](repeating: 0, count: count)
            XCTAssertNil(Whoop5Ecg.decodeFiltered(payload: payload), "\(count)-byte payload must not decode")
        }
    }

    func testFilteredRejectsSampleCountLongerThanBuffer() {
        // numberOfECGSamples says 10; only 3 samples are present. Fail closed — never a partial decode.
        let payload = header(samples: 10) + i16le([1, 2, 3])
        XCTAssertNil(Whoop5Ecg.decodeFiltered(payload: payload))
    }

    func testFilteredRejectsSampleCountOffByOneByte() {
        // One byte short of the declared 4 samples: the array must not be silently truncated to 3.
        let payload = header(samples: 4) + i16le([1, 2, 3]) + [0x07]
        XCTAssertNil(Whoop5Ecg.decodeFiltered(payload: payload))
    }

    func testFilteredExtraSamplesBeyondTheCountBecomePadding() {
        // The count is authoritative: bytes past it are padding, never extra samples.
        let payload = header(samples: 2) + i16le([9, 9, 9, 9])
        let packet = Whoop5Ecg.decodeFiltered(payload: payload)
        XCTAssertEqual(packet?.filteredECGDataRaw.count, 2)
        XCTAssertEqual(packet?.padding.count, 4)
    }

    // MARK: - Enum coverage

    func testEveryArrhythmiaCheckResultCaseDecodes() {
        let expected: [(UInt8, EcgArrhythmiaCheckResult, String)] = [
            (0, .notComplete, "notComplete"),
            (1, .normalSinusRhythm, "normalSinusRhythm"),
            (2, .signalUnreadable, "signalUnreadable"),
            (3, .bradycardia, "bradycardia"),
            (4, .afibDetected, "afibDetected"),
            (5, .tachycardia, "tachycardia"),
            (6, .inconclusive, "inconclusive"),
        ]
        XCTAssertEqual(expected.count, EcgArrhythmiaCheckResult.allCases.count)
        for (raw, expectedCase, token) in expected {
            let payload = header(arrhythmiaResult: raw, samples: 1) + i16le([0])
            let packet = Whoop5Ecg.decodeFiltered(payload: payload)
            XCTAssertEqual(packet?.header.heartKeyArrhythmiaCheckResult, expectedCase, "raw \(raw)")
            XCTAssertEqual(packet?.header.heartKeyArrhythmiaCheckResultRaw, raw)
            XCTAssertEqual(expectedCase.token, token)
        }
    }

    func testUnknownArrhythmiaResultIsCarriedRawNotCoerced() {
        // A firmware value outside the table must NOT be folded onto a known case.
        let payload = header(arrhythmiaResult: 200, samples: 1) + i16le([0])
        let packet = Whoop5Ecg.decodeFiltered(payload: payload)
        XCTAssertNil(packet?.header.heartKeyArrhythmiaCheckResult)
        XCTAssertEqual(packet?.header.heartKeyArrhythmiaCheckResultRaw, 200)
    }

    func testEveryArrhythmiaCheckStatusCaseDecodes() {
        let expected: [(UInt8, EcgArrhythmiaCheckStatus)] = [
            (0, .notRunning), (1, .inProgress), (2, .checkComplete),
        ]
        XCTAssertEqual(expected.count, EcgArrhythmiaCheckStatus.allCases.count)
        for (raw, expectedCase) in expected {
            let payload = header(arrhythmiaStatus: raw, samples: 0)
            XCTAssertEqual(Whoop5Ecg.decodeFiltered(payload: payload)?.header.heartKeyArrhythmiaCheckStatus,
                           expectedCase)
        }
        let bad = header(arrhythmiaStatus: 9, samples: 0)
        XCTAssertNil(Whoop5Ecg.decodeFiltered(payload: bad)?.header.heartKeyArrhythmiaCheckStatus)
        XCTAssertEqual(Whoop5Ecg.decodeFiltered(payload: bad)?.header.heartKeyArrhythmiaCheckStatusRaw, 9)
    }

    func testEverySignalQualityCaseDecodes() {
        for quality in EcgSignalQuality.allCases {
            let payload = header(signalQuality: quality.rawValue, samples: 0)
            XCTAssertEqual(Whoop5Ecg.decodeFiltered(payload: payload)?.header.signalQuality, quality)
        }
        // Out of range falls back to .unknown but keeps the raw byte.
        let payload = header(signalQuality: 77, samples: 0)
        XCTAssertEqual(Whoop5Ecg.decodeFiltered(payload: payload)?.header.signalQuality, .unknown)
        XCTAssertEqual(Whoop5Ecg.decodeFiltered(payload: payload)?.header.signalQualityRaw, 77)
    }

    func testProgressPercentInRangeAndRawOutside() {
        for value: UInt8 in [0, 1, 50, 99, 100] {
            let payload = header(progress: value, samples: 0)
            XCTAssertEqual(Whoop5Ecg.decodeFiltered(payload: payload)?.header.heartKeyProgress, .percent(value))
        }
        // 101...255 is out of percentage range. The source type has a "timed out" case, but its sentinel
        // value is not attested, so the byte is carried raw rather than renamed into a state we can't prove.
        for value: UInt8 in [101, 200, 255] {
            let payload = header(progress: value, samples: 0)
            let progress = Whoop5Ecg.decodeFiltered(payload: payload)?.header.heartKeyProgress
            XCTAssertEqual(progress, .unmapped(value))
            XCTAssertNil(progress?.percentValue)
            XCTAssertEqual(progress?.raw, value)
        }
    }

    // MARK: - Raw packet

    func testRawDecodesWithExplicitSampleWidth() {
        let rawBlob: [UInt8] = Array(0..<12)                 // 4 samples × 3 bytes
        let leadsOffI: [UInt16] = [1, 2]
        let leadsOffQ: [UInt16] = [3, 4]
        let payload = header(samples: 4) + rawBlob + [2] + u16le(leadsOffI) + u16le(leadsOffQ)

        let packet = Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 3)
        XCTAssertNotNil(packet)
        XCTAssertEqual(packet?.rawECGDataRaw, rawBlob)
        XCTAssertEqual(packet?.numberOfLeadsOffSamples, 2)
        XCTAssertEqual(packet?.leadsOffIRaw, leadsOffI)
        XCTAssertEqual(packet?.leadsOffQRaw, leadsOffQ)
        XCTAssertEqual(packet?.padding, [])
        XCTAssertEqual(packet?.bytesPerSample, 3)             // count ÷ numberOfECGSamples
        XCTAssertEqual(packet?.header.numberOfECGSamples, 4)
    }

    func testRawWithNoLeadsOffSamples() {
        let payload = header(samples: 2) + [0xAA, 0xBB, 0xCC, 0xDD] + [0]
        let packet = Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 2)
        XCTAssertEqual(packet?.numberOfLeadsOffSamples, 0)
        XCTAssertEqual(packet?.leadsOffIRaw, [])
        XCTAssertEqual(packet?.leadsOffQRaw, [])
        XCTAssertEqual(packet?.rawECGDataRaw, [0xAA, 0xBB, 0xCC, 0xDD])
    }

    func testRawRejectsTruncatedLeadsOffArrays() {
        // Declares 3 leads-off samples but only carries I (and only partly).
        let payload = header(samples: 2) + [0, 0, 0, 0] + [3] + u16le([1, 2, 3])
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 2))
    }

    func testRawRejectsMissingLeadsOffCountByte() {
        // The raw blob consumes the whole buffer, leaving no room for the count byte.
        let payload = header(samples: 2) + [0, 0, 0, 0]
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 2))
    }

    func testRawRejectsAWidthThatWouldOverflowTheOffsetMath() {
        // `bytesPerSample` is caller-supplied on a public API and the sample count comes off the wire.
        // Their product must be checked: unguarded it traps in Swift and wraps NEGATIVE in Kotlin.
        let payload = header(samples: 65_535) + [UInt8](repeating: 0, count: 8)
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: Int.max))
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: Int.max / 2))
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 1_000_000))
        // And the same through the public frame entry point.
        let frame = puffinFrame(type: 0x2F, payload: payload)
        XCTAssertNil(Whoop5Ecg.decodeRawFrame(frame, bytesPerSample: Int.max))

        // The n-SMALL / width-HUGE case: `1 * Int.max` does NOT overflow the multiply, so a guard that
        // only checks the product still traps on `headerLength + blobLength`. Both must be checked.
        let onePayload = header(samples: 1) + [UInt8](repeating: 0, count: 8)
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: onePayload, bytesPerSample: Int.max))
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: onePayload, bytesPerSample: Int.max - 16))
        // Two samples: the multiply overflows only above .max/2, so the add is again the live guard.
        let twoPayload = header(samples: 2) + [UInt8](repeating: 0, count: 8)
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: twoPayload, bytesPerSample: Int.max / 2))
    }

    func testRawRejectsShortHeaderAndZeroWidth() {
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: [1, 2, 3], bytesPerSample: 2))
        let payload = header(samples: 2) + [0, 0, 0, 0] + [0]
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 0))
    }

    func testRawSampleWidthCandidatesAreEnumeratedNotGuessed() {
        // 4 samples × 2 bytes, then a 1-sample leads-off tail. Width 2 must be admitted.
        let payload = header(samples: 4) + [UInt8](repeating: 0x11, count: 8) + [1] + u16le([7]) + u16le([8])
        let candidates = Whoop5Ecg.rawBytesPerSampleCandidates(payload: payload)
        XCTAssertTrue(candidates.contains(2), "width 2 must be structurally admissible")
        // Whatever the full candidate set is, the single-candidate decoder must agree with it: it either
        // resolves uniquely, or refuses. It must never silently pick one of several.
        if candidates.count == 1 {
            XCTAssertEqual(Whoop5Ecg.decodeRaw(payload: payload)?.bytesPerSample, candidates[0])
        } else {
            XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload),
                         "ambiguous buffer (\(candidates)) must refuse to decode, not guess")
        }
    }

    func testRawAmbiguousBufferRefusesToDecode() {
        // Hand-built so several widths parse: a long all-zero tail lets many split points look valid.
        let payload = header(samples: 1) + [UInt8](repeating: 0, count: 6)
        let candidates = Whoop5Ecg.rawBytesPerSampleCandidates(payload: payload, maxPadding: 8)
        XCTAssertGreaterThan(candidates.count, 1, "fixture is meant to be ambiguous")
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload, maxPadding: 8))
    }

    // MARK: - Frame level (CRC gating)

    func testFilteredFrameDecodesThroughAValidPuffinEnvelope() {
        let samples: [Int16] = [10, -10, 300]
        let payload = header(samples: UInt16(samples.count)) + i16le(samples)
        let frame = puffinFrame(type: 0x28, payload: payload)
        XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok)

        let packet = Whoop5Ecg.decodeFilteredFrame(frame)
        XCTAssertEqual(packet?.filteredECGDataRaw, samples)
        XCTAssertEqual(packet?.header.heartKeyHR, 63)
    }

    func testFilteredFrameRejectsBadCRC32() {
        let payload = header(samples: 2) + i16le([1, 2])
        var frame = puffinFrame(type: 0x28, payload: payload)
        frame[frame.count - 1] ^= 0xFF                        // corrupt the CRC32 trailer
        XCTAssertFalse(verifyFrame(frame, family: .whoop5).ok)
        XCTAssertNil(Whoop5Ecg.decodeFilteredFrame(frame), "a bad CRC must never reach a field read")
    }

    func testFilteredFrameRejectsBadHeaderCRC16() {
        let payload = header(samples: 2) + i16le([1, 2])
        var frame = puffinFrame(type: 0x28, payload: payload)
        frame[6] ^= 0xFF                                      // corrupt the CRC16 header check
        XCTAssertFalse(verifyFrame(frame, family: .whoop5).ok)
        XCTAssertNil(Whoop5Ecg.decodeFilteredFrame(frame))
    }

    func testFilteredFrameRejectsCorruptedBodyThatBreaksCRC() {
        let payload = header(samples: 2) + i16le([1, 2])
        var frame = puffinFrame(type: 0x28, payload: payload)
        frame[12] ^= 0x01                                     // flip a status bit; CRC32 no longer matches
        XCTAssertFalse(verifyFrame(frame, family: .whoop5).ok)
        XCTAssertNil(Whoop5Ecg.decodeFilteredFrame(frame))
    }

    func testFrameRejectsGarbageAndShortInput() {
        XCTAssertNil(Whoop5Ecg.decodeFilteredFrame([]))
        XCTAssertNil(Whoop5Ecg.decodeFilteredFrame([0xAA, 0x01, 0x00]))
        XCTAssertNil(Whoop5Ecg.decodeFilteredFrame([UInt8](repeating: 0xFF, count: 64)))
    }

    func testRawFrameDecodesThroughAValidPuffinEnvelope() {
        let payload = header(samples: 2) + [1, 2, 3, 4] + [1] + u16le([5]) + u16le([6])
        let frame = puffinFrame(type: 0x2F, payload: payload)
        let packet = Whoop5Ecg.decodeRawFrame(frame, bytesPerSample: 2)
        XCTAssertEqual(packet?.rawECGDataRaw, [1, 2, 3, 4])
        XCTAssertEqual(packet?.leadsOffIRaw, [5])
        XCTAssertEqual(packet?.leadsOffQRaw, [6])
    }

    func testRawFrameRejectsBadCRC() {
        let payload = header(samples: 2) + [1, 2, 3, 4] + [0]
        var frame = puffinFrame(type: 0x2F, payload: payload)
        frame[frame.count - 2] ^= 0xFF
        XCTAssertNil(Whoop5Ecg.decodeRawFrame(frame, bytesPerSample: 2))
    }

    // MARK: - Structural triage (packet-type discovery)

    func testPlausibleFilteredPayloadAcceptsAWellFormedPacket() {
        let payload = header(samples: 3) + i16le([1, 2, 3])
        XCTAssertTrue(Whoop5Ecg.plausibleFilteredPayload(payload))
    }

    func testPlausibleFilteredPayloadRejectsNonBooleanFlagBytes() {
        let payload = header(started: 7, samples: 3) + i16le([1, 2, 3])
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload(payload))
    }

    func testPlausibleFilteredPayloadRejectsOutOfRangeEnums() {
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload(header(signalQuality: 9, samples: 2) + i16le([1, 2])))
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload(header(arrhythmiaResult: 9, samples: 2) + i16le([1, 2])))
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload(header(arrhythmiaStatus: 9, samples: 2) + i16le([1, 2])))
    }

    func testPlausibleFilteredPayloadRejectsLengthDisagreement() {
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload(header(samples: 40) + i16le([1, 2])))
        // Far more trailing bytes than the pad4 budget → not this layout.
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload(header(samples: 1) + i16le([1]) + [UInt8](repeating: 0, count: 40)))
    }

    func testPlausibleFilteredPayloadRejectsEmptyAndZeroSampleBuffers() {
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload([]))
        // Zero samples is a VALID packet but a useless triage signal (an all-zero buffer would match), so
        // the sniffer deliberately requires at least one sample.
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload(header(samples: 0)))
        XCTAssertFalse(Whoop5Ecg.plausibleFilteredPayload([UInt8](repeating: 0, count: 64)))
    }

    // MARK: - Commands

    func testCommandOpcodesMatchTheRepoProtocolTable() {
        // These four numbers are already in Resources/whoop_protocol.json (CommandNumber) from the
        // upstream whoomp/goose work — this file must not drift from the shipped table.
        let schema = loadSchema()
        XCTAssertTrue(schema.enumName("CommandNumber", Int(Whoop5Ecg.selectWristCmd)).hasPrefix("SELECT_WRIST"))
        XCTAssertTrue(schema.enumName("CommandNumber", Int(Whoop5Ecg.mainControlEcgDataGenerationCmd))
            .hasPrefix("TOGGLE_LABRADOR_DATA_GENERATION"))
        XCTAssertTrue(schema.enumName("CommandNumber", Int(Whoop5Ecg.toggleSaveRawEcgCmd))
            .hasPrefix("TOGGLE_LABRADOR_RAW_SAVE"))
        XCTAssertTrue(schema.enumName("CommandNumber", Int(Whoop5Ecg.toggleRealtimeFilteredEcgCmd))
            .hasPrefix("TOGGLE_LABRADOR_FILTERED"))
        XCTAssertEqual(Whoop5Ecg.selectWristCmd, 0x7B)
        XCTAssertEqual(Whoop5Ecg.mainControlEcgDataGenerationCmd, 0x7C)
        XCTAssertEqual(Whoop5Ecg.toggleSaveRawEcgCmd, 0x7D)
        XCTAssertEqual(Whoop5Ecg.toggleRealtimeFilteredEcgCmd, 0x8B)
    }

    func testCommandPayloadIsRevisionThenArg() {
        XCTAssertEqual(Whoop5Ecg.selectWristPayload(.right), [0x01, 0x00])
        XCTAssertEqual(Whoop5Ecg.selectWristPayload(.left), [0x01, 0x01])
        XCTAssertEqual(Whoop5Ecg.togglePayload(on: true), [0x01, 0x01])
        XCTAssertEqual(Whoop5Ecg.togglePayload(on: false), [0x01, 0x00])
        XCTAssertEqual(Whoop5Ecg.controlPayload(.stop), [0x01, 0x00])
        XCTAssertEqual(Whoop5Ecg.controlPayload(.start), [0x01, 0x01])
        XCTAssertEqual(Whoop5Ecg.controlPayload(.restart), [0x01, 0x02])
    }

    func testCommandFramesAreExactlyWhatTheSendPathBuilds() {
        // BLEManager.send() frames a 5/MG command as puffinCommandFrame(cmd:seq:payload:). These builders
        // must produce byte-identical output, so a test pins the wire form without a strap.
        let seq: UInt8 = 9
        XCTAssertEqual(Whoop5Ecg.selectWristFrame(.left, seq: seq),
                       puffinCommandFrame(cmd: 0x7B, seq: seq, payload: [0x01, 0x01]))
        XCTAssertEqual(Whoop5Ecg.toggleRealtimeFilteredEcgFrame(on: true, seq: seq),
                       puffinCommandFrame(cmd: 0x8B, seq: seq, payload: [0x01, 0x01]))
        XCTAssertEqual(Whoop5Ecg.toggleSaveRawEcgFrame(on: false, seq: seq),
                       puffinCommandFrame(cmd: 0x7D, seq: seq, payload: [0x01, 0x00]))
        XCTAssertEqual(Whoop5Ecg.mainControlEcgDataGenerationFrame(.start, seq: seq),
                       puffinCommandFrame(cmd: 0x7C, seq: seq, payload: [0x01, 0x01]))
    }

    func testCommandFramesRoundTripThroughTheWhoop5Validator() {
        let frames = [
            Whoop5Ecg.selectWristFrame(.right, seq: 1),
            Whoop5Ecg.toggleRealtimeFilteredEcgFrame(on: true, seq: 2),
            Whoop5Ecg.toggleSaveRawEcgFrame(on: true, seq: 3),
            Whoop5Ecg.mainControlEcgDataGenerationFrame(.stop, seq: 4),
        ]
        for frame in frames {
            XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok)
            // Inner record = [type=35][seq][cmd][revision][arg] = 5 bytes, pad4 → 8. Frame = 8 header
            // + 8 inner + 4 CRC32 = 20. The 3 pad bytes ARE the command struct's trailing `padding`.
            XCTAssertEqual(frame.count, 20)
            XCTAssertEqual(Array(frame[13...15]), [0, 0, 0])   // pad4-supplied padding field
            XCTAssertEqual(frame[8], 35)                       // COMMAND
            XCTAssertEqual(frame[11], Whoop5Ecg.commandRevision)
        }
        XCTAssertEqual(frames[0][10], 0x7B)
        XCTAssertEqual(frames[1][10], 0x8B)
        XCTAssertEqual(frames[2][10], 0x7D)
        XCTAssertEqual(frames[3][10], 0x7C)
    }

    func testOffPathIsTheExactInverseOfTheOnPath() {
        // The UI promises an explicit OFF path; these are the bytes it sends.
        XCTAssertEqual(Whoop5Ecg.mainControlEcgDataGenerationFrame(.stop, seq: 1)[12], 0)
        XCTAssertEqual(Whoop5Ecg.toggleRealtimeFilteredEcgFrame(on: false, seq: 1)[12], 0)
        XCTAssertEqual(Whoop5Ecg.toggleSaveRawEcgFrame(on: false, seq: 1)[12], 0)
    }

    // MARK: - Verdict classification

    private func responseFrame(cmd: UInt8, result: UInt8) -> [UInt8] {
        // COMMAND_RESPONSE (type 36) with the result code at frame[12] = payload byte 1.
        puffinCommandFrame(cmd: cmd, seq: 1, payload: [0x01, result], type: 36)
    }

    func testOutcomeReadsTheResultCodeAtFrame12() {
        XCTAssertEqual(Whoop5EcgProbe.outcome(frame: responseFrame(cmd: 0x7C, result: 0)), .failure)
        XCTAssertEqual(Whoop5EcgProbe.outcome(frame: responseFrame(cmd: 0x7C, result: 1)), .success)
        XCTAssertEqual(Whoop5EcgProbe.outcome(frame: responseFrame(cmd: 0x7C, result: 2)), .pending)
        XCTAssertEqual(Whoop5EcgProbe.outcome(frame: responseFrame(cmd: 0x7C, result: 3)), .unsupported)
        XCTAssertEqual(Whoop5EcgProbe.outcome(frame: responseFrame(cmd: 0x7C, result: 42)), .unmapped(42))
        XCTAssertNil(Whoop5EcgProbe.outcome(frame: [0xAA, 0x01]))
    }

    /// Build a step the way `BLEManager.sendEcgCommand` does — the label from the opcode, and the role
    /// flag DERIVED from opcode + argument rather than hand-set. Every verdict test below therefore
    /// exercises the same predicate the app does, so a wrong `requestsRealtimeData` cannot be papered
    /// over by a test that simply asserts the flag it wants.
    private func sent(_ cmd: UInt8,
                      arg: UInt8,
                      _ outcome: Whoop5EcgProbe.CommandOutcome,
                      replyHex: String? = nil) -> Whoop5EcgProbe.Step {
        let name: String
        switch cmd {
        case Whoop5Ecg.selectWristCmd: name = "SELECT_WRIST"
        case Whoop5Ecg.mainControlEcgDataGenerationCmd: name = "TOGGLE_LABRADOR_DATA_GENERATION"
        case Whoop5Ecg.toggleSaveRawEcgCmd: name = "TOGGLE_LABRADOR_RAW_SAVE"
        case Whoop5Ecg.toggleRealtimeFilteredEcgCmd: name = "TOGGLE_LABRADOR_FILTERED"
        default: name = "CMD"
        }
        return Whoop5EcgProbe.Step(
            label: "\(name)(\(cmd))",
            outcome: outcome,
            requestsRealtimeData: Whoop5Ecg.requestsRealtimeData(cmd: cmd, arg: arg),
            replyHex: replyHex)
    }

    // MARK: - Which commands can produce data at all

    func testOnlyTheStreamAndGenerationVerbsCanProduceRealtimeData() {
        // The ARGUMENT is half the answer: the same opcode asks for data ON and asks for silence OFF.
        XCTAssertTrue(Whoop5Ecg.requestsRealtimeData(cmd: Whoop5Ecg.toggleRealtimeFilteredEcgCmd, arg: 1))
        XCTAssertFalse(Whoop5Ecg.requestsRealtimeData(cmd: Whoop5Ecg.toggleRealtimeFilteredEcgCmd, arg: 0))
        XCTAssertTrue(Whoop5Ecg.requestsRealtimeData(cmd: Whoop5Ecg.mainControlEcgDataGenerationCmd,
                                                     arg: Whoop5Ecg.ControlSignal.start.rawValue))
        XCTAssertTrue(Whoop5Ecg.requestsRealtimeData(cmd: Whoop5Ecg.mainControlEcgDataGenerationCmd,
                                                     arg: Whoop5Ecg.ControlSignal.restart.rawValue))
        XCTAssertFalse(Whoop5Ecg.requestsRealtimeData(cmd: Whoop5Ecg.mainControlEcgDataGenerationCmd,
                                                      arg: Whoop5Ecg.ControlSignal.stop.rawValue))
        // SELECT_WRIST configures which wrist; it starts nothing, on EITHER argument. This is the
        // opcode whose silence was being reported as a firmware block.
        for wrist in Whoop5Ecg.WristSelection.allCases {
            XCTAssertFalse(Whoop5Ecg.requestsRealtimeData(cmd: Whoop5Ecg.selectWristCmd, arg: wrist.rawValue))
        }
        // RAW_SAVE names flash, not a live channel — a realtime window cannot observe it either way, so
        // it must not unlock a verdict that reads realtime silence as evidence (#891 hypothesis (b)).
        XCTAssertFalse(Whoop5Ecg.requestsRealtimeData(cmd: Whoop5Ecg.toggleSaveRawEcgCmd, arg: 1))
        // An opcode outside the family (an unsolicited reply's, say) is never a data request.
        XCTAssertFalse(Whoop5Ecg.requestsRealtimeData(cmd: 26, arg: 1))
    }

    func testAttestedResultCodesOutrankTheShapeHeuristic() {
        // The packet count comes from a HEURISTIC that ordinary traffic can trip; the result codes are
        // attested wire semantics. So a firmware FAILURE must not be overridden by candidate frames —
        // the old precedence turned one loose match into an unhedged "not blocked".
        let failed = [sent(124, arg: 1, .failure)]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: failed, ecgPacketsSeen: 12, windowSeconds: 30),
                       .dataRequestRefused(commands: ["TOGGLE_LABRADOR_DATA_GENERATION(124)"]))
        let unsupported = [sent(139, arg: 1, .unsupported)]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: unsupported, ecgPacketsSeen: 12, windowSeconds: 30),
                       .opcodeUnsupported(commands: ["TOGGLE_LABRADOR_FILTERED(139)"]))
        // With no contrary result code, candidates are the verdict — as candidates, not as proof.
        let ok = [sent(124, arg: 1, .success)]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: ok, ecgPacketsSeen: 12, windowSeconds: 30),
                       .ecgCandidatesArrived(packets: 12))
    }

    func testCandidateVerdictIsHedgedNotAssertedAsProof() {
        let text = Whoop5EcgProbe.report(
            steps: [sent(124, arg: 1, .success)],
            ecgPacketsSeen: 3, candidateFrames: ["type=0x28 len=220"], windowSeconds: 30)
        XCTAssertTrue(text.contains("CANDIDATE, not proof"))
        // The old wording asserted the conclusion outright; it must not come back.
        XCTAssertFalse(text.contains("Not blocked"))
        XCTAssertFalse(text.contains("is ACTIVE"))
    }

    func testVerdictFailureOnADataRequestIsReportedAsARefusal() {
        let steps = [
            sent(139, arg: 1, .success),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .failure),
        ]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .dataRequestRefused(commands: ["TOGGLE_LABRADOR_DATA_GENERATION(124)"]))
    }

    func testVerdictAllSuccessButSilentIsTheSilentNoOpCase() {
        // The turn-on run: data WAS requested and the strap said SUCCESS. This is the only shape from
        // which "accepted, then not honoured" can be read.
        let steps = [
            sent(139, arg: 1, .success),
            sent(125, arg: 1, .success),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .success),
        ]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .acceptedButSilent(windowSeconds: 30))
    }

    func testTogglesSentAndPacketsArrivedIsTheCandidateVerdictNotABlock() {
        let steps = [
            sent(139, arg: 1, .success),
            sent(125, arg: 1, .success),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .success),
        ]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 4, windowSeconds: 30),
                       .ecgCandidatesArrived(packets: 4))
    }

    // MARK: - A run that asked for nothing is not a test of anything

    func testWristOnlyRunIsNotReportedAsADeviceFlagBlock() {
        // REGRESSION (#891). A SELECT_WRIST-only run sends NO data-generation command, so zero packets is
        // the expected outcome. The old logic classified it `acceptedButSilent` and printed "Consistent
        // with a device-flag block applied as a silent no-op" — manufacturing evidence for hypothesis (e)
        // out of a run that could not speak to it.
        let steps = [sent(123, arg: Whoop5Ecg.WristSelection.left.rawValue, .success,
                          replyHex: "aa010c000100271124d77b81010100007ce76722")]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .noDataRequested(commands: ["SELECT_WRIST(123)"]))
        let text = Whoop5EcgProbe.report(steps: steps, ecgPacketsSeen: 0,
                                         candidateFrames: [], windowSeconds: 30)
        XCTAssertTrue(text.contains("NOT A TEST"))
        XCTAssertFalse(text.contains("device-flag block"))
        XCTAssertFalse(text.contains("Accepted but SILENT"))
        // The report must say WHY, not just withhold the claim.
        XCTAssertTrue(text.contains("cannot produce ECG data"))
        XCTAssertTrue(text.contains("Zero is the EXPECTED result here"))
    }

    func testWristOnlyRunThatFailsIsARefusalNotADeviceFlagBlock() {
        // REGRESSION (#891). The same run with the OTHER wrist came back FAILURE(0) on hardware, and the
        // old logic promoted that to "LIKELY blockedByDeviceFlags". The firmware refused ONE config
        // write; nothing about ECG generation follows from it.
        let steps = [sent(123, arg: Whoop5Ecg.WristSelection.right.rawValue, .failure,
                          replyHex: "aa010c000100271124217bcc000100000213163d")]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .commandRefused(commands: ["SELECT_WRIST(123)"]))
        let text = Whoop5EcgProbe.report(steps: steps, ecgPacketsSeen: 0,
                                         candidateFrames: [], windowSeconds: 30)
        XCTAssertTrue(text.contains("REFUSED"))
        XCTAssertFalse(text.contains("blockedByDeviceFlags"))
    }

    func testOffSequenceAsksForSilenceSoItsSilenceIsNotEvidence() {
        // The OFF path sends the same three opcodes with the OFF arguments. It asks for exactly the
        // silence it gets, so it must never render as a block either.
        let steps = [
            sent(124, arg: Whoop5Ecg.ControlSignal.stop.rawValue, .success),
            sent(125, arg: 0, .success),
            sent(139, arg: 0, .success),
        ]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .noDataRequested(commands: ["TOGGLE_LABRADOR_DATA_GENERATION(124)",
                                                   "TOGGLE_LABRADOR_RAW_SAVE(125)",
                                                   "TOGGLE_LABRADOR_FILTERED(139)"]))
    }

    func testRawSaveAloneCannotUnlockTheSilentVerdict() {
        // RAW_SAVE names flash. A realtime listen window observes nothing from it even on total success,
        // so a raw-save-only run cannot be read as "accepted and then silent" (#891 hypothesis (b)).
        let steps = [sent(125, arg: 1, .success)]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .noDataRequested(commands: ["TOGGLE_LABRADOR_RAW_SAVE(125)"]))
    }

    func testAnUnacknowledgedDataRequestIsNotAcceptedButSilent() {
        // "Accepted" needs an ack. The wrist write landed; the request that matters never came back.
        let steps = [
            sent(123, arg: Whoop5Ecg.WristSelection.left.rawValue, .success),
            sent(139, arg: 1, .noReply),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .noReply),
        ]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .dataRequestNotAccepted(commands: ["TOGGLE_LABRADOR_FILTERED(139)",
                                                          "TOGGLE_LABRADOR_DATA_GENERATION(124)"]))
    }

    func testNoVerdictClaimsAFlagBlockWithoutADataRequest() {
        // The invariant, stated once over every reachable outcome: a run that asked for no realtime data
        // can never produce a headline that reads as evidence about the block question.
        let outcomes: [Whoop5EcgProbe.CommandOutcome] =
            [.success, .failure, .pending, .unsupported, .unmapped(42), .noReply]
        let noDataArgs: [(UInt8, UInt8)] = [(123, 0), (123, 1), (125, 1), (125, 0),
                                            (139, 0), (124, Whoop5Ecg.ControlSignal.stop.rawValue)]
        let asserts = ["LIKELY blockedByDeviceFlags", "Consistent with a device-flag block"]
        for (cmd, arg) in noDataArgs {
            for outcome in outcomes {
                let verdict = Whoop5EcgProbe.verdict(steps: [sent(cmd, arg: arg, outcome)],
                                                     ecgPacketsSeen: 0, windowSeconds: 30)
                for claim in asserts {
                    XCTAssertFalse(verdict.headline.contains(claim),
                                   "cmd \(cmd) arg \(arg) outcome \(outcome.token) claimed: \(claim)")
                }
            }
        }
    }

    /// REGRESSION (#891). No verdict may name `blockedByDeviceFlags` or a "device-flag block" AT ALL —
    /// not to assert it, and not to deny it.
    ///
    /// The scoping fix made the two offending verdicts unreachable without a data request; it left the
    /// WORDING in place, and the wording is independently wrong. `blockedByDeviceFlags` is a client-side
    /// construct: no command in the `CommandNumber` table reads or writes such a flag, nothing in this
    /// repo implements one, and it is never transmitted to a strap. A probe that sees only result codes
    /// and packet counts cannot attribute anything to it. #891 then wrote the leading named firmware-side
    /// candidate (`enable_raw_data_w_ecg`) to `'1'`, confirmed the read-back, and still saw zero packets.
    ///
    /// Enumerated over EVERY verdict case rather than every input, so a new case cannot be added with the
    /// old vocabulary and slip through on the grounds that no input reaches it.
    func testNoVerdictMentionsDeviceFlagsAtAll() {
        let cmds = ["TOGGLE_LABRADOR_DATA_GENERATION(124)"]
        let every: [Whoop5EcgProbe.Verdict] = [
            .ecgCandidatesArrived(packets: 3),
            .dataRequestRefused(commands: cmds),
            .commandRefused(commands: cmds),
            .acceptedButSilent(windowSeconds: 30),
            .noDataRequested(commands: cmds),
            .dataRequestNotAccepted(commands: cmds),
            .opcodeUnsupported(commands: cmds),
            .noReplies,
            .inconclusive,
        ]
        for verdict in every {
            let headline = verdict.headline.lowercased()
            XCTAssertFalse(headline.contains("deviceflag"), "leaked the identifier: \(verdict.headline)")
            XCTAssertFalse(headline.contains("device-flag"), "leaked the phrase: \(verdict.headline)")
        }
    }

    /// The silent verdict must still say something useful — removing the false cause must not leave the
    /// report mute about what else explains the silence.
    func testAcceptedButSilentNamesTheAlternativesInsteadOfACause() {
        let headline = Whoop5EcgProbe.Verdict.acceptedButSilent(windowSeconds: 30).headline
        XCTAssertTrue(headline.contains("does not identify a cause"))
        XCTAssertTrue(headline.contains("flash"))
        XCTAssertTrue(headline.contains("entitlement gate"))
    }

    func testVerdictUnsupportedIsReportedAsItselfNotAsABlock() {
        let steps = [sent(139, arg: 1, .unsupported)]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30),
                       .opcodeUnsupported(commands: ["TOGGLE_LABRADOR_FILTERED(139)"]))
    }

    func testVerdictSilenceIsNeverCalledABlock() {
        let steps = [
            sent(139, arg: 1, .noReply),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .noReply),
        ]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30), .noReplies)
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: [], ecgPacketsSeen: 0, windowSeconds: 30), .noReplies)
    }

    func testVerdictMixedCodesAreInconclusive() {
        let steps = [
            sent(139, arg: 1, .success),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .pending),
        ]
        XCTAssertEqual(Whoop5EcgProbe.verdict(steps: steps, ecgPacketsSeen: 0, windowSeconds: 30), .inconclusive)
    }

    func testReportCarriesTheVerdictTheOutcomesAndTheNonMedicalFraming() {
        let steps = [
            sent(123, arg: Whoop5Ecg.WristSelection.left.rawValue, .success, replyHex: "aabb"),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .failure, replyHex: "ccdd"),
        ]
        let text = Whoop5EcgProbe.report(steps: steps, ecgPacketsSeen: 0,
                                         candidateFrames: ["type=0x28 len=220"], windowSeconds: 30)
        XCTAssertTrue(text.contains("DATA REQUEST REFUSED"))
        XCTAssertTrue(text.contains("SELECT_WRIST(123): SUCCESS(1)"))
        XCTAssertTrue(text.contains("TOGGLE_LABRADOR_DATA_GENERATION(124): FAILURE(0)"))
        XCTAssertTrue(text.contains("type=0x28 len=220"))
        XCTAssertTrue(text.contains("aabb"))
        XCTAssertTrue(text.contains("not a medical measurement or a diagnosis"))
    }

    /// #896 review: nobody is told to hold the clasp. An MG measures across the wrist electrode AND the
    /// two clasp indents, and lead state is not on the wire — so a run where the clasp was never touched
    /// returns zero packets for a reason that has nothing to do with the firmware. #891 asks other MG
    /// owners to run this; without the line they report "nothing happened" and the thread reads it as
    /// evidence about the gate.
    func testAZeroPacketRunThatAskedForDataQuestionsTheElectrodeCircuit() {
        let steps = [
            sent(123, arg: Whoop5Ecg.WristSelection.left.rawValue, .success, replyHex: "aabb"),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .success, replyHex: "ccdd"),
        ]
        let text = Whoop5EcgProbe.report(steps: steps, ecgPacketsSeen: 0,
                                         candidateFrames: [], windowSeconds: 30)
        XCTAssertTrue(text.contains("Were the leads closed?"))
        XCTAssertTrue(text.contains("two indents on the clasp"))
        XCTAssertTrue(text.contains("OTHER hand"))
        // It must stay a QUESTION about the run. Claiming the leads WERE open would be the same
        // manufactured-cause error as the retired device-flag wording.
        XCTAssertTrue(text.contains("cannot tell an open circuit from a strap that ignored the command"))
    }

    /// The line is about a zero that MIGHT have a mundane cause, so it is silent when there is no zero
    /// to explain and when the run never asked for data (that case has its own, different sentence).
    func testTheElectrodeQuestionIsAbsentWhenPacketsArrivedOrNoDataWasAsked() {
        let asked = [
            sent(123, arg: Whoop5Ecg.WristSelection.left.rawValue, .success, replyHex: "aabb"),
            sent(124, arg: Whoop5Ecg.ControlSignal.start.rawValue, .success, replyHex: "ccdd"),
        ]
        let withPackets = Whoop5EcgProbe.report(steps: asked, ecgPacketsSeen: 4,
                                                candidateFrames: [], windowSeconds: 30)
        XCTAssertFalse(withPackets.contains("Were the leads closed?"))

        let wristOnly = [sent(123, arg: Whoop5Ecg.WristSelection.left.rawValue, .success, replyHex: "aabb")]
        let noRequest = Whoop5EcgProbe.report(steps: wristOnly, ecgPacketsSeen: 0,
                                              candidateFrames: [], windowSeconds: 30)
        XCTAssertFalse(noRequest.contains("Were the leads closed?"))
        XCTAssertTrue(noRequest.contains("Zero is the EXPECTED result here"))
    }

    func testReportNeverPresentsAnArrhythmiaResultAsAFinding() {
        // The report is the only text the probe surfaces; it must not name a classifier verdict at all.
        let text = Whoop5EcgProbe.report(steps: [], ecgPacketsSeen: 0, candidateFrames: [], windowSeconds: 30)
        for token in EcgArrhythmiaCheckResult.allCases.map(\.token) {
            XCTAssertFalse(text.lowercased().contains(token.lowercased()), "report must not name \(token)")
        }
    }
}
