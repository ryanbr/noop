import XCTest
@testable import WhoopProtocol

/// Synthetic, protocol-valid frames (built by scripts/gen_synthetic_fixtures.py's frame
/// builders), decoded then stream-extracted. No real biometric capture is embedded.
/// Refs chosen so the first REALTIME_DATA timestamp (31538447) maps onto a known wall instant.
final class StreamsTests: XCTestCase {
    private let deviceClockRef = 31_538_447
    private let wallClockRef = 1_736_365_593

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // REALTIME_DATA: ts=31538447 hr=60 ; ts=31538448 hr=59 (synthetic)
    private let rt0 = "aa1800ff28020f3de10100003c0000000000000000000000b7e67942"
    private let rt1 = "aa1800ff2802103de10100003b000000000000000000000048f73dee"
    // EVENT RAW_DATA_COLLECTION_ON(46), event_timestamp=1736365593 (synthetic)
    private let ev = "aa0c00fc30012e0019d67e67f21241bd"
    // COMMAND_RESPONSE GET_BATTERY_LEVEL(26), battery_pct=25.5 (synthetic)
    private let battery = "aa0f00c324141a0000ff0000000000080fadae"
    // REALTIME_RAW_DATA (type 43): carries a heart_rate byte but MUST NOT feed the HR stream
    private let raw43 = "aa8407f72b0500bebafeca183de10100000000000046000000000000d275e1c1"

    private func parsedFrames(_ hexes: [String]) -> [ParsedFrame] {
        hexes.map { parseFrame(bytes($0)) }
    }

    func testRealtimeHRMapsDeviceToWallClock() {
        let s = extractStreams(parsedFrames([rt0, rt1]),
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.hr, [HRSample(ts: 1_736_365_593, bpm: 60),
                              HRSample(ts: 1_736_365_594, bpm: 59)])
        XCTAssertTrue(s.rr.isEmpty)
    }

    func testEventTimestampIsNotOffset() {
        let s = extractStreams(parsedFrames([ev]),
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.events.count, 1)
        XCTAssertEqual(s.events[0].ts, 1_736_365_593)          // raw event_timestamp, not offset
        XCTAssertEqual(s.events[0].kind, "RAW_DATA_COLLECTION_ON(46)")
        XCTAssertEqual(s.events[0].payload, [:])                // event/event_timestamp stripped
    }

    func testBatteryStampedAtWallClockRef() {
        let s = extractStreams(parsedFrames([battery]),
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.battery, [BatterySample(ts: 1_736_365_593, soc: 25.5, mv: nil)])
    }

    func testHRNotTakenFromType43RawData() {
        // raw43 decodes with a heart_rate in parsed, but it is REALTIME_RAW_DATA → no HR row.
        let p = parseFrame(bytes(raw43))
        XCTAssertEqual(p.typeName, "REALTIME_RAW_DATA")
        XCTAssertNotNil(p.parsed["heart_rate"])
        let s = extractStreams([p], deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertTrue(s.hr.isEmpty)
        XCTAssertTrue(s.rr.isEmpty)
    }

    func testCrcFailedAndNotOkFramesSkipped() {
        let good = parseFrame(bytes(rt0))                       // ok, crc ok
        let truncated = parseFrame([0xAA, 0x00])                // ok==false (INVALID/FRAGMENT)
        let s = extractStreams([good, truncated],
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.hr.count, 1)
    }

    // MARK: - the extraction gate reads the FULL verdict
    //
    // Scenario "Zustandstreibende Tore fordern das volle Urteil / Strom- und Verlaufs-Extraktion
    // überspringt ungültige Rahmen". Each frame is a real REALTIME_DATA broken in exactly one way and
    // still fully decodable, so what is missing from the result is attributable to the gate.

    func testFrameWithABrokenHeaderChecksumYieldsNoRow() {
        var broken = bytes(rt0)
        broken[3] ^= 0xFF                                       // header checksum only
        let p = parseFrame(broken)
        XCTAssertEqual(p.crcOK, true, "precondition: the payload CRC32 still verifies")
        XCTAssertNotNil(p.parsed["heart_rate"], "precondition: the frame still decodes an HR")
        let s = extractStreams([p], deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertTrue(s.hr.isEmpty, "no row may be derived from a frame that is not intact")
        XCTAssertTrue(s.rr.isEmpty)
    }

    func testFrameWithTrailingBytesYieldsNoRow() {
        let p = parseFrame(bytes(rt0) + [0x00])
        XCTAssertEqual(p.rejectReason, .lengthMismatch)
        let s = extractStreams([p], deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertTrue(s.hr.isEmpty)
    }

    func testOneBrokenFrameInASequenceLosesOnlyItsOwnRow() {
        var broken = bytes(rt1)
        broken[3] ^= 0xFF
        let s = extractStreams([parseFrame(bytes(rt0)), parseFrame(broken)],
                               deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(s.hr, [HRSample(ts: 1_736_365_593, bpm: 60)],
                       "the intact frame still produces its row; only the broken one is skipped")
    }

    // MARK: - D7: a named field is never read out of the CRC32 trailer (post-hook half, 2.18)

    /// This 17-byte WHOOP 4.0 REALTIME_DATA frame is INTACT — correct header checksum, correct CRC32,
    /// exact declared length of 13 — but its inner record ends at byte 13, so the R-R count the
    /// realtime post-hook reads at offset 13 is the first byte of the frame's own CRC32 trailer. That
    /// byte is 0x01, and the two trailer bytes behind it read as a 33403 ms interval: a physiologically
    /// impossible R-R that the strap never sent and that nothing downstream could tell from a real one.
    ///
    /// The gate cannot catch this — the frame passes every checksum. Only the payload bound does.
    func testRealtimeRRCountIsNotReadOutOfTheTrailer() {
        let frame = bytes("aa0d00e9280100000009000000017b826e")
        let p = parseFrame(frame)
        XCTAssertTrue(p.ok, "precondition: this frame is intact by every checksum")
        XCTAssertEqual(p.typeName, "REALTIME_DATA")
        XCTAssertEqual(frame[13], 0x01, "precondition: the trailer's first byte reads as rr_count = 1")
        XCTAssertEqual(p.parsed["rr_intervals"], .intArray([]),
                       "an R-R interval must never be decoded out of the CRC32 trailer")
        let s = extractStreams([p], deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertTrue(s.rr.isEmpty, "…and no such row may reach the datastore")
    }
}
