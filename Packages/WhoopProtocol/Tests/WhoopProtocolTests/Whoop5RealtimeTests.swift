import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") REALTIME_DATA decode, verified against a real captured frame.
///
/// The 5.0 inner record starts at byte 8 (vs byte 4 on 4.0), so every field sits at its 4.0 offset
/// + 4. This frame was captured from a real WHOOP 5 strap while worn; the heart rate matched the
/// standard `2A37` Heart Rate profile reading at the same instant (98 bpm), and the two R-R intervals
/// are consistent with that rate. Offsets are taken from real captures, never invented.
final class Whoop5RealtimeTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// A real type-40 REALTIME_DATA frame: hr=98, rr=[603,587] ms, unix ts=1780916382.
    private let realtimeHex =
        "aa011800010022e128029ea0266aae4762025b024b020000000001005ed515dc"

    func testRealtimeHeartRateAndRR() {
        let f = parseFrame(bytes(realtimeHex), family: .whoop5)

        XCTAssertTrue(f.ok)
        XCTAssertEqual(f.typeName, "REALTIME_DATA")
        XCTAssertEqual(f.crcOK, true)

        // +4 layout: timestamp@10, subseconds@14, heart_rate@16, rr_count@17, rr@18+
        XCTAssertEqual(f.parsed["timestamp"]?.intValue, 1780916382)
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 98)
        XCTAssertEqual(f.parsed["rr_count"]?.intValue, 2)
        XCTAssertEqual(f.parsed["rr_intervals"]?.intArrayValue, [603, 587])
    }

    func testRealtimeRRTimestampsSpreadAcrossTheBatch() {
        // A WHOOP 5 realtime frame carries TWO intervals, so it batches like the 4.0 does and the spread
        // applies to it: the 587 ms beat ends at the frame, the 603 ms one before it back-dates by the
        // 587 ms that follow. 5.0 is NOT untouched by the spread, and nothing pinned that before: the
        // tests either read the parsed dict or asserted rrMs values, which the spread leaves alone.
        // Coverage on a 5.0 night moves from about 1.0028 to about 1.0000, so it stays plausible.
        let f = parseFrame(bytes(realtimeHex), family: .whoop5)
        let streams = extractStreams([f], deviceClockRef: 1780916382, wallClockRef: 1780916382)
        XCTAssertEqual(streams.rr.map(\.rrMs), [603, 587])
        XCTAssertEqual(streams.rr.map(\.ts), [1780916381, 1780916382])
    }

    func testHeartRateFieldIsAtOffset16() {
        // Guard the exact offset the +4 rule predicts (4.0 heart_rate@12 → 5.0 @16).
        // collectFields: the annotated fields array is opt-in diagnostics (D#742).
        let f = parseFrame(bytes(realtimeHex), family: .whoop5, collectFields: true)
        let hr = f.fields.first { $0.name == "heart_rate" }
        XCTAssertEqual(hr?.off, 16)
    }

    func testWhoop4RealtimeIsUnaffected() {
        // The 4.0 path must still decode at its original offsets (heart_rate@12) — no +4 there.
        // A real 4.0 REALTIME_DATA frame from the parity fixtures: hr=60, rr=[1000].
        let f = parseFrame(bytes("aa1800ff28000f3de10100003c01e8030000000000000000c64efbea"),
                           family: .whoop4, collectFields: true)
        XCTAssertEqual(f.typeName, "REALTIME_DATA")
        XCTAssertEqual(f.parsed["heart_rate"]?.intValue, 60)
        XCTAssertEqual(f.fields.first { $0.name == "heart_rate" }?.off, 12)
    }
}
