import XCTest
@testable import WhoopProtocol

final class DeviceFamilyFramingTests: XCTestCase {

    static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    // MARK: - CRC16-Modbus known vectors

    func testCrc16ModbusKnownVectors() {
        // The canonical CRC16/MODBUS check value for the ASCII string "123456789".
        XCTAssertEqual(crc16Modbus(Array("123456789".utf8)), 0x4B37)
        // Empty input returns the init value unchanged.
        XCTAssertEqual(crc16Modbus([]), 0xFFFF)
        // Classic Modbus RTU frame 01 04 02 FF FF -> CRC bytes B8 80 (LE) = value 0x80B8.
        XCTAssertEqual(crc16Modbus([0x01, 0x04, 0x02, 0xFF, 0xFF]), 0x80B8)
        // Single-byte vectors.
        XCTAssertEqual(crc16Modbus([0xAA]), 0x3F3F)
        XCTAssertEqual(crc16Modbus(Array("A".utf8)), 0x707F)
    }

    // MARK: - Whoop 5.0 frame verification

    // Synthetic, hand-computed VALID whoop5 frame:
    //   header  = [aa 01 0c 00 00 01]            (SOF, format, len=12 LE, two header bytes)
    //   crc16   = e741  (CRC16-Modbus over the 6 header bytes, LE)
    //   payload = [36 07 02 11 22 33 44 55]      (type=COMMAND_RESPONSE, seq=7, cmd=2, data)
    //   crc32   = 7481f36e  (zlib CRC32 over payload, LE) -> value 0x6ef38174
    static let validWhoop5 = "aa010c000001e74124070211223344557481f36e"

    func testVerifyValidWhoop5Frame() {
        let frame = Self.hex(Self.validWhoop5)
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.length, 12)        // declaredLength = payload(8) + crc32(4)
        XCTAssertEqual(check.crc8OK, true)      // header CRC16 outcome surfaced via crc8OK
        XCTAssertEqual(check.crc32OK, true)
    }

    func testWhoop4OnWhoop5FrameFailsHeaderCRC() {
        // Same bytes, parsed as whoop4: the CRC8 path reads length/crc8 from the wrong offsets,
        // so the header CRC must fail — proving the family switch genuinely changes behaviour.
        let frame = Self.hex(Self.validWhoop5)
        let check = verifyFrame(frame, family: .whoop4)
        XCTAssertEqual(check.crc8OK, false)
        XCTAssertFalse(check.ok)
    }

    func testWhoop5HeaderCorruptionDetected() {
        var frame = Self.hex(Self.validWhoop5)
        frame[4] ^= 0xFF   // corrupt a header byte covered by the CRC16
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertEqual(check.crc8OK, false)
        XCTAssertFalse(check.ok)
    }

    func testWhoop5PayloadCorruptionDetected() {
        var frame = Self.hex(Self.validWhoop5)
        frame[10] ^= 0xFF  // corrupt a payload byte -> crc32 fails, header crc16 still OK
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertEqual(check.crc8OK, true)
        XCTAssertEqual(check.crc32OK, false)
        XCTAssertFalse(check.ok)
    }

    func testWhoop5ShortFrameRejected() {
        XCTAssertFalse(verifyFrame([0xAA, 0x01, 0x0c, 0x00], family: .whoop5).ok)
    }

    func testWhoop5NonSOFRejected() {
        var frame = Self.hex(Self.validWhoop5)
        frame[0] = 0x00
        XCTAssertFalse(verifyFrame(frame, family: .whoop5).ok)
    }

    // MARK: - whoop4 family overload is byte-for-byte back-compatible

    func testWhoop4FamilyOverloadMatchesLegacy() {
        // The existing realtime-data fixture from FramingTests must verify identically through the
        // family-aware overload.
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        XCTAssertEqual(verifyFrame(frame, family: .whoop4), verifyFrame(frame))
        XCTAssertTrue(verifyFrame(frame, family: .whoop4).ok)
    }

    // MARK: - CLIENT_HELLO constant

    func testWhoop5ClientHelloBytesAndVerify() {
        let hello = DeviceFamily.whoop5ClientHello
        XCTAssertEqual(hello, Self.hex("aa0108000001e67123019101363e5c8d"))
        XCTAssertEqual(DeviceFamily.whoop5.clientHello, hello)
        XCTAssertNil(DeviceFamily.whoop4.clientHello)
        // The real CLIENT_HELLO must pass whoop5 verification end-to-end.
        let check = verifyFrame(hello, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.length, 8)   // payload(4) + crc32(4)
    }

    // MARK: - Per-family metadata (no CoreBluetooth)

    func testFamilyMetadata() {
        XCTAssertEqual(DeviceFamily.whoop4.headerCRCKind, .crc8)
        XCTAssertEqual(DeviceFamily.whoop5.headerCRCKind, .crc16Modbus)

        XCTAssertEqual(DeviceFamily.whoop4.serviceUUIDString,
                       "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        XCTAssertEqual(DeviceFamily.whoop5.serviceUUIDString,
                       "fd4b0001-cce1-4033-93ce-002d5875f58a")

        XCTAssertEqual(DeviceFamily.whoop4.characteristicUUIDStrings.count, 4)
        XCTAssertEqual(DeviceFamily.whoop5.characteristicUUIDStrings.count, 5)
        XCTAssertTrue(DeviceFamily.whoop5.characteristicUUIDStrings
            .contains("fd4b0007-cce1-4033-93ce-002d5875f58a"))

        XCTAssertEqual(DeviceFamily.whoop4.commandCharacteristicUUIDString,
                       "61080002-8d6d-82b8-614a-1c8cb0f8dcc6")
        XCTAssertEqual(DeviceFamily.whoop5.commandCharacteristicUUIDString,
                       "fd4b0002-cce1-4033-93ce-002d5875f58a")

        XCTAssertEqual(DeviceFamily.allCases, [.whoop4, .whoop5])
    }

    func testDiagnosticGattFamiliesAreMetadataOnly() {
        XCTAssertEqual(WhoopGattServiceFamily.unsupportedServiceUUIDStrings, [
            "11500001-6215-11ee-8c99-0242ac120002",
            "8a580001-2fe8-4796-9267-b87a2b0c8234",
            "59830001-5955-419b-bb8d-c8262926af23",
        ])

        for family in WhoopGattServiceFamily.unsupportedFamilies {
            XCTAssertFalse(family.isConnectable)
            XCTAssertNil(family.connectableDeviceFamily)
            XCTAssertTrue(family.diagnosticUnsupportedMessage.contains("will not connect or send commands"))
            XCTAssertEqual(family.characteristicUUIDStrings.count, 5)
        }
    }

    func testSupportedGattFamiliesRemainTheOnlyConnectableFamilies() {
        XCTAssertEqual(WhoopGattServiceFamily.whoop4.connectableDeviceFamily, .whoop4)
        XCTAssertEqual(WhoopGattServiceFamily.maverickGooseFD4B.connectableDeviceFamily, .whoop5)
        XCTAssertEqual(
            WhoopGattServiceFamily.maverickGooseFD4B.serviceUUIDString,
            "fd4b0001-cce1-4033-93ce-002d5875f58a"
        )
    }

    func testUnsupportedAdvertisementsDoNotConnect() {
        let decision = whoopGattScanDecision(
            selectedServiceUUIDString: DeviceFamily.whoop5.serviceUUIDString,
            advertisedServiceUUIDStrings: ["8A580001-2FE8-4796-9267-B87A2B0C8234"]
        )

        XCTAssertFalse(decision.shouldConnect)
        XCTAssertEqual(decision.unsupportedFamily, .monument)
    }

    func testSelectedServiceAdvertisementsStillConnect() {
        let decision = whoopGattScanDecision(
            selectedServiceUUIDString: DeviceFamily.whoop4.serviceUUIDString,
            advertisedServiceUUIDStrings: [DeviceFamily.whoop4.serviceUUIDString]
        )

        XCTAssertTrue(decision.shouldConnect)
        XCTAssertNil(decision.unsupportedFamily)
    }

    func testEmptyAdvertisementServiceListPreservesLegacyConnectPath() {
        let decision = whoopGattScanDecision(
            selectedServiceUUIDString: DeviceFamily.whoop4.serviceUUIDString,
            advertisedServiceUUIDStrings: []
        )

        XCTAssertTrue(decision.shouldConnect)
        XCTAssertNil(decision.unsupportedFamily)
    }

    // MARK: - Puffin packet type names

    func testPuffinTypeNamesAliased() {
        let schema = loadSchema()
        // 38 -> COMMAND_RESPONSE, 56 -> METADATA (not "unknown"/"typeN").
        XCTAssertEqual(canonicalTypeName(38, schema: schema), "COMMAND_RESPONSE")
        XCTAssertEqual(canonicalTypeName(56, schema: schema), "METADATA")
        // Non-puffin types defer to the schema unchanged.
        XCTAssertEqual(canonicalTypeName(40, schema: schema), schema.typeName(40))
        XCTAssertEqual(canonicalTypeName(36, schema: schema), "COMMAND_RESPONSE")
        XCTAssertEqual(PuffinPacketType.puffinCommandResponse, 38)
        XCTAssertEqual(PuffinPacketType.puffinMetadata, 56)
    }

    // MARK: - Family-aware parseFrame

    func testParseWhoop5FrameAliasesPuffinAndParsesEnvelope() {
        // A puffin-metadata (type 56) frame must parse with typeName "METADATA".
        // payload=[56 03 00 ab cd 00 00 00] (padded), crc32 over it.
        let frame = Self.hex("aa010c000001e741380300abcd00000060153281")
        // collectFields: the annotated fields array is opt-in diagnostics (D#742).
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.typeName, "METADATA")
        XCTAssertEqual(parsed.seq, 3)
        XCTAssertEqual(parsed.crcOK, true)
        // SOF/length/crc16/packet_type envelope fields are present.
        XCTAssertTrue(parsed.fields.contains { $0.name == "crc16" })
        XCTAssertTrue(parsed.fields.contains { $0.name == "packet_type" })
    }

    func testParseWhoop5CommandResponseFrame() {
        let frame = Self.hex(Self.validWhoop5)
        let parsed = parseFrame(frame, family: .whoop5)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(parsed.seq, 7)
        XCTAssertEqual(parsed.crcOK, true)
    }

    func testParseWhoop4FamilyOverloadMatchesLegacy() {
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        XCTAssertEqual(parseFrame(frame, family: .whoop4), parseFrame(frame))
    }

    // MARK: - Family-aware Reassembler

    func testReassemblerWhoop5SingleFrame() {
        // validWhoop5 is a complete 20-byte frame: declLength=12 @ [2..4] -> total = 12 + 8 = 20.
        let frame = Self.hex(Self.validWhoop5)
        let r = Reassembler(family: .whoop5)
        let out = r.feed(frame)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, frame)
    }

    func testReassemblerWhoop5SplitAcrossFragments() {
        // A whoop5 frame split mid-way must only emit once both halves have arrived.
        let frame = Self.hex(Self.validWhoop5)
        let r = Reassembler(family: .whoop5)
        XCTAssertEqual(r.feed(Array(frame[0..<9])).count, 0)   // incomplete so far
        let out = r.feed(Array(frame[9...]))                   // rest arrives
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, frame)
    }

    func testReassemblerWhoop5BackToBackFrames() {
        // Two whoop5 frames in one buffer (the 16-byte CLIENT_HELLO then the 20-byte fixture).
        let hello = DeviceFamily.whoop5ClientHello     // declLength=8 -> total 16
        let frame = Self.hex(Self.validWhoop5)          // total 20
        let r = Reassembler(family: .whoop5)
        let out = r.feed(hello + frame)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], hello)
        XCTAssertEqual(out[1], frame)
    }

    func testReassemblerWhoop5DiscardsLeadingGarbage() {
        let frame = Self.hex(Self.validWhoop5)
        let r = Reassembler(family: .whoop5)
        let out = r.feed([0x00, 0xFF, 0x12] + frame)   // junk before the 0xAA SOF
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, frame)
    }

    // MARK: - Puffin command frame builder (experimental 5/MG outbound)

    func testPuffinCommandFrameVerifies() {
        // A puffin TOGGLE_REALTIME_HR (cmd 3, payload [0x01]) must be a well-formed whoop5 frame.
        let f = puffinCommandFrame(cmd: 3, seq: 7, payload: [0x01])
        let check = verifyFrame(f, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.crc8OK, true)    // CRC16 header outcome surfaced via crc8OK
        XCTAssertEqual(check.crc32OK, true)
        // And it parses back as a whoop5 frame with the seq we set.
        let parsed = parseFrame(f, family: .whoop5)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.seq, 7)
        // It also reassembles cleanly through the whoop5 reassembler.
        XCTAssertEqual(Reassembler(family: .whoop5).feed(f), [f])
    }

    func testReassemblerWhoop4DefaultUnchanged() {
        // Default family stays WHOOP 4.0: a 28-byte whoop4 frame (length=0x18=24 -> total 28).
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        XCTAssertEqual(Reassembler().feed(frame), [frame])
        XCTAssertEqual(Reassembler(family: .whoop4).feed(frame), [frame])
    }

    func testPuffinHapticsFrameMatchesMaverickGolden() {
        // WHOOP 5/MG buzz (#48): the haptic inner is 15 bytes ([35, seq, 0x13] + 12-byte payload), which
        // pad4 must extend to 16 before length/CRC — exactly as the strap's maverick framing does. The
        // golden frame is computed from the working app's buildMaverickFrame (notify preset, effects
        // 47,152) at seq=1; byte-for-byte equality proves our opcode (0x13), payload, AND pad4 are correct.
        let payload: [UInt8] = [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0]   // 0x01 + effects(8) + loopCtl(2) + overallLoop
        XCTAssertEqual(payload.count, 12)
        let frame = puffinCommandFrame(cmd: 0x13, seq: 1, payload: payload)
        XCTAssertEqual(frame, Self.hex("aa0114000001e1e1230113012f980000000000000000000098cb83a5"))
        XCTAssertEqual(frame.count, 28)            // 8 header + 16 padded inner + 4 crc32
        XCTAssertTrue(verifyFrame(frame, family: .whoop5).ok)
        XCTAssertEqual(Reassembler(family: .whoop5).feed(frame), [frame])
        // pad4 is a NO-OP for already-4-aligned commands: HR toggle inner ([35, seq, 3, 1]) stays 16 bytes.
        XCTAssertEqual(puffinCommandFrame(cmd: 3, seq: 7, payload: [0x01]).count, 16)
    }

    // MARK: - 5/MG firmware-alarm payloads (REVISION_4 / REVISION_2) — Swift twin of AlarmPayloadTest.kt

    func testMaverickAlarmPayloadBytes() {
        // wakeEpochMs 1_700_000_000_123 → seconds 1700000000 (LE 00 f1 53 65),
        // subseconds (123*32768)/1000 = 4030 = 0x0FBE (LE be 0f); tail = effects 47/152,
        // loopControl 0, overallLoop 7, duration 30 s. Byte-for-byte the Android vectors.
        let body = AlarmPayload.setAlarmRev4(wakeEpochMs: 1_700_000_000_123)
        XCTAssertEqual(body.count, 20)
        XCTAssertEqual(body, Self.hex("040100f15365be0f2f980000000000000000071e"))
        XCTAssertEqual(AlarmPayload.disableRev2(), [0x02, 0xFF])
        XCTAssertEqual(AlarmPayload.runAlarmRev2(), [0x02, 0x01])
        // #926: overallLoop counts the repeats AFTER the first pulse (hardware-confirmed on a 5/MG by
        // @dwehrmann), so ONE buzz is 0 — and that is byte-for-byte the literal both send() paths shipped
        // for years, which is why the old single buzz was the observed behaviour.
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 1),
                       [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        // The SAME vectors the Kotlin twin pins (MaverickHapticBodyTest), so the two reimplementations
        // cannot drift on what this byte means.
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 2).last, 1)       // 2 buzzes = 1 repeat
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 3).last, 2)       // 3 buzzes
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 5).last, 4)       // BuzzPattern.Long
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 999).last, 7)     // clamped to the alarm's 7
        XCTAssertEqual(MaverickHaptics.notificationBuzz(loops: 0).last, 0)       // never underflows
        // Everything except byte 11 is the shipped constant, at every loop count.
        for n in 1...8 {
            let body = MaverickHaptics.notificationBuzz(loops: n)
            XCTAssertEqual(body.count, 12)
            XCTAssertEqual(Array(body[0..<11]), [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    func testPuffinAlarmFramesMatchKotlinParityGoldens() {
        // Cross-platform parity pins: the Android FramingTest asserts these SAME three full-frame
        // hexes, so both platforms are locked to identical alarm bytes (the same pipeline whose
        // buzz output is capture-verified above). SET_ALARM_TIME inner is 23 bytes → pad4 → 24,
        // declLen 28; the rev-2 bodies pad 5 → 8.
        let alarm = puffinCommandFrame(cmd: 66, seq: 1,
                                       payload: AlarmPayload.setAlarmRev4(wakeEpochMs: 1_700_000_000_123))
        XCTAssertEqual(alarm, Self.hex("aa011c000001e381230142040100f15365be0f2f980000000000000000071e00392f2ac9"))
        XCTAssertEqual(alarm.count, 36)
        XCTAssertTrue(verifyFrame(alarm, family: .whoop5).ok)
        XCTAssertEqual(Reassembler(family: .whoop5).feed(alarm), [alarm])
        XCTAssertEqual(puffinCommandFrame(cmd: 69, seq: 1, payload: AlarmPayload.disableRev2()),
                       Self.hex("aa010c000001e74123014502ff000000267ffc4f"))
        XCTAssertEqual(puffinCommandFrame(cmd: 68, seq: 1, payload: AlarmPayload.runAlarmRev2()),
                       Self.hex("aa010c000001e741230144020100000017cd19e2"))
    }

    func testPuffinOneShotBuzzSequenceGoldens() {
        // #921 one-shot buzz (BLEManager.buzzStrapOnce): on a 5/MG the confirmed sequence is the
        // maverick 0x13 notify buzz followed by RUN_ALARM(68) REVISION_2, on consecutive seq bytes.
        // Golden hexes generated independently (Python: zlib CRC-32, CRC16-Modbus) and cross-checked
        // against the Android FramingTest vectors, so a drift in either frame fails here. (Android
        // stops at the maverick buzz on a 5/MG: its allow-list excludes RUN_ALARM for that family.)
        let buzz = puffinCommandFrame(cmd: 0x13, seq: 1,
                                      payload: [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(buzz, Self.hex("aa0114000001e1e1230113012f980000000000000000000098cb83a5"))
        let runAlarm = puffinCommandFrame(cmd: 68, seq: 2, payload: AlarmPayload.runAlarmRev2())
        XCTAssertEqual(runAlarm, Self.hex("aa010c000001e74123024402010000008ad7f1d3"))
        XCTAssertTrue(verifyFrame(buzz, family: .whoop5).ok)
        XCTAssertTrue(verifyFrame(runAlarm, family: .whoop5).ok)
    }
}
