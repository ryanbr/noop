import XCTest
@testable import WhoopProtocol

/// type-47 HISTORICAL_DATA V24 — the 14-day biometric store record. Mirrors the Python
/// test at tests/test_historical_v24.py: a SYNTHETIC record (HR=63, one R-R, on-wrist) built
/// by scripts/gen_synthetic_fixtures.historical_v24(). No real on-device capture is embedded.
final class HistoricalV24Tests: XCTestCase {
    // A synthetic V24 record (unix anchored to 1700000000, gravity a synthetic ~1g unit vector).
    private let v24Hex =
        "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
        "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
        "200364006400b80bb80b000000000000c25c1a88"

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    func testV24DecodesAsHistoricalData() {
        let out = parseFrame(bytes(v24Hex))
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.typeName, "HISTORICAL_DATA")
        XCTAssertEqual(out.crcOK, true)
        XCTAssertEqual(out.seq, 24)  // version byte
    }

    func testV24BiometricFields() {
        let p = parseFrame(bytes(v24Hex)).parsed
        XCTAssertEqual(p["hist_version"]?.intValue, 24)
        XCTAssertEqual(p["unix"]?.intValue, 1700000000)  // synthetic anchor epoch
        XCTAssertEqual(p["heart_rate"]?.intValue, 63)
        XCTAssertEqual(p["rr_count"]?.intValue, 1)
        XCTAssertEqual(p["rr_intervals"]?.intArrayValue, [850])
        XCTAssertEqual(p["ppg_green"]?.intValue, 1500)
        XCTAssertEqual(p["ppg_red_ir"]?.intValue, 30000)
        XCTAssertEqual(p["skin_contact"]?.intValue, 64)
        XCTAssertEqual(p["spo2_red"]?.intValue, 18000)
        XCTAssertEqual(p["spo2_ir"]?.intValue, 17000)
        XCTAssertEqual(p["skin_temp_raw"]?.intValue, 900)
        XCTAssertEqual(p["resp_rate_raw"]?.intValue, 3000)
        XCTAssertEqual(p["signal_quality"]?.intValue, 3000)
    }

    func testV24GravityIsF32UnitVector() {
        let p = parseFrame(bytes(v24Hex)).parsed
        // gravity is a 3xf32 vector stored unrounded as .double; magnitude must be ~1g.
        guard case .double(let gx)? = p["gravity_x"],
              case .double(let gy)? = p["gravity_y"],
              case .double(let gz)? = p["gravity_z"] else {
            return XCTFail("gravity components must decode as unrounded .double")
        }
        let mag = (gx * gx + gy * gy + gz * gz).squareRoot()
        XCTAssertGreaterThan(mag, 0.9)
        XCTAssertLessThan(mag, 1.1)
    }

    func testV24ExtractHistoricalStreams() {
        let out = parseFrame(bytes(v24Hex))
        let st = extractHistoricalStreams([out], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertEqual(st.hr, [HRSample(ts: 1700000000, bpm: 63)])
        XCTAssertEqual(st.rr, [RRInterval(ts: 1700000000, rrMs: 850)])
        XCTAssertEqual(st.spo2.first, SpO2Sample(ts: 1700000000, red: 18000, ir: 17000))
        XCTAssertEqual(st.skinTemp.first, SkinTempSample(ts: 1700000000, raw: 900))
        XCTAssertEqual(st.resp.first?.raw, 3000)
        let g = try! XCTUnwrap(st.gravity.first)
        XCTAssertEqual(g.ts, 1700000000)
        XCTAssertEqual(g.unit, "g")
    }

    func testUnmappedVersionFallsBackGracefully() {
        var bad = bytes(v24Hex)
        bad[5] = 99  // flip version byte to an unmapped value
        let out = parseFrame(bad)
        // The flipped byte is inside the CRC32-covered inner record, so the frame is NOT intact and
        // `ok` says so — it used to report a positive verdict for exactly this deliberately corrupted
        // frame. Decoding stays defensive: the fields are still readable for an inspector.
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.rejectReason, .payloadCRCMismatch)
        XCTAssertEqual(out.crcOK, false)
        XCTAssertEqual(out.parsed["hist_version"]?.intValue, 99)
    }
}
