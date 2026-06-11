import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") HISTORICAL_DATA (type 47) decode, verified against a real captured frame.
///
/// These DSP biometric records are the historical equivalent of REALTIME_DATA. They only arrive once
/// the offload is acknowledged: each HISTORY_END must be echoed back with HISTORICAL_DATA_RESULT(23)
/// to advance the strap's trim cursor — without that handshake the cursor stays frozen and zero
/// type-47 frames are served (see docs/BLE_REVERSE_ENGINEERING.md §5).
///
/// The record carries its layout version in frame[9]. Real WHOOP 5 hardware on the latest firmware
/// emits **version 18**, which is NOT the repo's 4.0 v24 layout shifted by +4 — that firmware
/// revision is not what this device emits, and a naive +4 decodes to garbage. Every offset is read
/// off real frames at its absolute 5.0 position and cross-checked physiologically (rr_count == #valid
/// R-R; 60000/mean(R-R) ≈ heart_rate; |gravity| ≈ 1 g). Offsets are taken from real captures, never
/// invented.
final class Whoop5HistoricalTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// A real type-47 HISTORICAL_DATA v18 frame (worn WHOOP 5, captured 2026-06-08):
    /// unix=1780916150, hr=102, rr=[602,613] ms, |gravity| ≈ 1.0 g.
    private let historicalHex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    func testHistoricalV18HeartRateRRAndGravity() {
        let f = parseFrame(bytes(historicalHex), family: .whoop5)

        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)

        // v18 absolute 5.0 offsets: hist_version@9, unix@15, heart_rate@22, rr_count@23, rr@24+
        XCTAssertEqual(f.parsed["hist_version"]?.intValue, 18)
        XCTAssertEqual(f.parsed["unix"]?.intValue, 1780916150)
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 102)
        XCTAssertEqual(f.parsed["rr_count"]?.intValue, 2)
        XCTAssertEqual(f.parsed["rr_intervals"]?.intArrayValue, [602, 613])

        // Gravity triplet (f32) at 45/49/53 — magnitude ≈ 1 g.
        let gx = f.parsed["gravity_x"]?.doubleValue ?? 0
        let gy = f.parsed["gravity_y"]?.doubleValue ?? 0
        let gz = f.parsed["gravity_z"]?.doubleValue ?? 0
        XCTAssertEqual((gx * gx + gy * gy + gz * gz).squareRoot(), 1.0, accuracy: 0.05)

        // R-R is internally consistent with the heart rate (60000 / mean(R-R) ≈ bpm).
        let meanRR = Double(602 + 613) / 2.0
        XCTAssertEqual(60000.0 / meanRR, 102, accuracy: 8)
    }

    func testHistoricalV18BiometricFields() {
        // The cross-validated per-second fields beyond HR/gravity, each gated to a physical range and
        // verified against this real worn frame. (Fields that did NOT decode consistently on this
        // firmware — cardiac_flags@33, state@81, perfusion@69/71 — are deliberately not decoded.)
        let p = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        // skin temperature: the raw AS6221 u16 register (scale-agnostic). °C = raw / 128 — the AS6221's
        // native 7.8125 m°C/LSB. Raw kept in the record so the absolute scale (/128 vs /100) isn't baked in.
        XCTAssertEqual(p["skin_temp_raw"]?.intValue, 3057)
        // dynamic (gravity-removed) acceleration — small for a still wrist, gated to [0, 8] g.
        let dyn = p["dynamic_acceleration"]?.doubleValue ?? -1
        XCTAssertTrue((0.0...8.0).contains(dyn))
        XCTAssertEqual(dyn, 0.0092, accuracy: 0.001)
        // cumulative motion counter + wear/contact quality enum.
        XCTAssertEqual(p["step_motion_counter"]?.intValue, 50)
        XCTAssertEqual(p["motion_wear_quality"]?.intValue, 0)
    }

    func testHistoricalV18SkinTempTracksWristContact() {
        // Proof @73 is the real skin-temp sensor: worn it reads skin; off-wrist the same thermistor
        // reads a cooler ambient value — both pass the guard, so a valid-but-cooler off-wrist reading is
        // still captured rather than dropped. Asserted on the raw register (worn 3057 > off-wrist 2247;
        // °C = raw/128 → ~23.9 worn / ~17.6 ambient — the absolute scale awaits a contact-thermometer).
        let worn = parseFrame(bytes(historicalHex), family: .whoop5).parsed
        let off = parseFrame(bytes(historicalOffWristHex), family: .whoop5).parsed
        XCTAssertEqual(worn["skin_temp_raw"]?.intValue, 3057)
        XCTAssertEqual(off["skin_temp_raw"]?.intValue, 2247)
        XCTAssertLessThan(off["skin_temp_raw"]?.intValue ?? .max, worn["skin_temp_raw"]?.intValue ?? 0)
    }

    func testHeartRateOffsetIsNotTheNaivePlusFour() {
        // Guard the firmware caveat: v18 HR is at offset 22, NOT v24's 21+4=25. If a future change
        // wrongly reuses the 4.0 v24 layout at +4, this fails instead of silently shipping HR=0.
        let f = parseFrame(bytes(historicalHex), family: .whoop5)
        XCTAssertEqual(f.fields.first { $0.name == "heart_rate" }?.off, 22)
        XCTAssertNotEqual(f.fields.first { $0.name == "heart_rate" }?.off, 25)
    }

    func testHistoricalFeedsStreamExtraction() {
        // The decoded v18 record flows into the datastore path (extractHistoricalStreams keys off
        // unix/heart_rate/rr_intervals/gravity_*), producing real HR, R-R and gravity samples.
        let f = parseFrame(bytes(historicalHex), family: .whoop5)
        let s = extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertEqual(s.hr.map { $0.bpm }, [102])
        XCTAssertEqual(s.hr.first?.ts, 1780916150)          // real unix, no wall-clock offset
        XCTAssertEqual(s.rr.map { $0.rrMs }, [602, 613])
        XCTAssertEqual(s.gravity.count, 1)
    }

    /// A real single-R-R v18 frame (same strap): unix=1780916152, hr=101, rr=[595] ms.
    private let historicalOneRRHex =
        "aa01740001003fb12f1280753d8401b89f266a664600650153020000000000000000f8018d656365ff80702f3c7b7039bf71f5fd3e142a003f3200aa000000000000000000f7000901f30b0007010c020c0000000000000000000000000000000000000000000000010066701f1e0000005e77a8c00000001194fc6a"

    func testHistoricalSingleRR() {
        // Breadth: rr_count=1 must yield exactly one interval (not a fixed-width over-read).
        let f = parseFrame(bytes(historicalOneRRHex), family: .whoop5)
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 101)
        XCTAssertEqual(f.parsed["rr_count"]?.intValue, 1)
        XCTAssertEqual(f.parsed["rr_intervals"]?.intArrayValue, [595])
    }

    /// A real off-wrist v18 frame (HR=0): the strap still emits a record with no biometric reading.
    private let historicalOffWristHex =
        "aa01740001003fb12f12803a3d84018889266a3d0a00000000000000000000000000000000000000000064c33b52b47d3fe1ba1dbda470ecbd000064000000000000000000e500e200c708000c010c020c0000000000000000000000000000000000000000000000010000008080000000000000000000009ffafe6c"

    func testHistoricalOffWristEmitsNoHeartRate() {
        // HR=0 is the off-wrist / no-reading sentinel; extractHistoricalStreams must skip it so a
        // 0-bpm sample never lands in the datastore.
        let f = parseFrame(bytes(historicalOffWristHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 0)
        let s = extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertTrue(s.hr.isEmpty)
    }

    /// A real type-47 record of a DIFFERENT version (26, 88-byte) — a high-rate waveform buffer the
    /// same WHOOP 5 also emits. We do not map it; the decoder must describe it safely, not crash or
    /// misapply the v18 offsets.
    private let historicalV26Hex =
        "aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4cfebafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff405fb33c50080101006cb67c17"

    func testHistoricalUnknownVersionFallsBackSafely() {
        let f = parseFrame(bytes(historicalV26Hex), family: .whoop5)
        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["hist_version"]?.intValue, 26)
        // No v18 fields are invented for an unknown version.
        XCTAssertNil(f.parsed["heart_rate"])
        XCTAssertNil(f.parsed["rr_intervals"])
        XCTAssertNil(f.parsed["gravity_x"])
    }

    // MARK: Offload handshake (the WHOOP 5 metadata + ack the app drives during a backfill)

    /// Real WHOOP 5 METADATA frames: a HISTORY_END (meta_type 2, trim=112193) and a HISTORY_START.
    private let historyEndHex =
        "aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"
    private let historyStartHex =
        "aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"

    func testWhoop5MetadataClassifiesHistoryEnd() {
        // The +4 metadata decode must expose unix + trim_cursor so classifyHistoricalMeta can drive
        // the ack — without this the WHOOP 5 offload can't advance.
        let f = parseFrame(bytes(historyEndHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "METADATA")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(classifyHistoricalMeta(f), .end(unix: 1780917124, trim: 112193))
    }

    func testWhoop5MetadataClassifiesHistoryStart() {
        let f = parseFrame(bytes(historyStartHex), family: .whoop5)
        XCTAssertEqual(classifyHistoricalMeta(f), .start)
    }

    func testWhoop5HistoricalAckFrameMatchesHardwareProvenBytes() {
        // end_data = HISTORY_END frame[21..29] (trim 112193 + next 16). The ack must be byte-identical
        // to the Python build_history_ack that walked the cursor on real hardware.
        let endData: [UInt8] = [0x41, 0xb6, 0x01, 0x00, 0x10, 0x00, 0x00, 0x00]
        let ack = whoop5HistoricalAckFrame(endData: endData, seq: 0)
        let hex = ack.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "aa0110000001e0d12300170141b6010010000000667da4fb")
        // And it round-trips as a valid puffin COMMAND carrying cmd 23.
        let parsed = parseFrame(ack, family: .whoop5)
        XCTAssertEqual(parsed.crcOK, true)
        XCTAssertEqual(parsed.cmdName?.hasPrefix("HISTORICAL_DATA_RESULT"), true)
    }

    // Real v18 frames from a SECOND device (Galaxy S24 Ultra capture, 2026-06-11) — a different
    // strap/firmware than the 2026-06-08 device the offsets were first read from. The decisive part:
    // each frame's heart rate was cross-checked against THAT SAME device's own live REALTIME_DATA at
    // the identical unix second (57 and 63 bpm matched exactly, 53/53 over the overlap), so these are
    // ground-truth, not self-referential. This pins that the v18 layout GENERALISES, not overfits.
    private let secondDeviceHR57 =
        "aa01740001003fb12f128093c47c006dbc296a00600039000000000000000000006137020b610000e1e04c063d8fce36bf7b08233f8fea993e38a50000000000000000000019012101920b5002010c020c0100000000000000000000000000000000000000000005010085808080000000a5538ec000000016d0680d"
    private let secondDeviceHR63 =
        "aa01740001003fb12f128034d67c000ece296a0a77003f01fc0300000000000000203a0302e30000ff00f8093c1f8534bcc3a5473f4819243f85a6000000000000000000001b012601e80b5003010c020c00000000000000000000000000000000000000000000050100ced7241c0000006ead8cc00000008775b70c"

    func testHistoricalV18GeneralisesToSecondDevice() {
        for (hex, expectHR, expectUnix) in [(secondDeviceHR57, 57, 1781120109), (secondDeviceHR63, 63, 1781124622)] {
            let p = parseFrame(bytes(hex), family: .whoop5).parsed
            XCTAssertEqual(p["hist_version"]?.intValue, 18)
            XCTAssertEqual(p["unix"]?.intValue, expectUnix)
            XCTAssertEqual(p["heart_rate"]?.intValue, expectHR, "HR must match the device's own live HR at this second")
            // Gravity vector reads ~1 g on a worn strap regardless of firmware revision.
            if let gx = p["gravity_x"]?.doubleValue, let gy = p["gravity_y"]?.doubleValue, let gz = p["gravity_z"]?.doubleValue {
                let mag = (gx * gx + gy * gy + gz * gz).squareRoot()
                XCTAssert((0.8...1.2).contains(mag), "|gravity| \(mag) out of range")
            } else {
                XCTFail("gravity did not decode")
            }
        }
    }
}
