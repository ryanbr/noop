import XCTest
@testable import OuraProtocol

/// 0x6A `sleep_period_info` (OURA_PROTOCOL.md s6.12) — the tag that carries the ring's own average HR
/// and a CANDIDATE breath rate, and that NOOP used to drop as unknown.
///
/// Every vector here is a REAL captured record from a Gen 3 overnight (`Night 08-06_08_07`,
/// `oura-raw.jsonl`), full `type len rt(4 LE) body(10)` bytes, not a synthetic body — the point of the
/// tag is what the ring actually sends. The expected values are the ones the corpus survey produced,
/// so a decoder regression that changes a scale or slips an offset fails here rather than quietly
/// re-labelling a night's breathing.
final class SleepPeriodInfoTests: XCTestCase {

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

    private func record(_ hex: String) -> OuraRecord {
        guard let rec = OuraFraming.parseRecord(bytes(hex)) else {
            XCTFail("record failed to parse: \(hex)"); return OuraRecord(type: 0, ringTimestamp: 0, payload: [])
        }
        XCTAssertEqual(rec.type, OuraEventTag.sleepPeriodInfo.rawValue)
        XCTAssertEqual(rec.payload.count, 10, "0x6A bodies are a fixed 10 bytes in every record we hold")
        return rec
    }

    // MARK: - The layout, on real records

    /// A typical mid-sleep record. Pins all nine fields at once, which is what catches an off-by-one in
    /// the offsets: with the fields adjacent and differently scaled, a one-byte slip cannot leave all
    /// nine right.
    func testTypicalRecordDecodesEveryField() {
        let info = OuraDecoders.decodeSleepPeriodInfo(record("6a0e9dcca60068f13a1f831f0001d257"))
        XCTAssertEqual(info?.averageHrBpm, 52.0)          // wire 0x68 = 104, x 0.5
        XCTAssertEqual(info?.hrTrend, -0.9375)            // wire 0xf1 = -15 SIGNED, x 0.0625
        XCTAssertEqual(info?.mzci, 3.625)                 // wire 0x3a = 58, x 0.0625
        XCTAssertEqual(info?.dzci, 1.9375)                // wire 0x1f = 31, x 0.0625
        XCTAssertEqual(info?.breathsPerMin, 16.375)       // wire 0x83 = 131, / 8
        XCTAssertEqual(info?.breathVariability, 3.875)    // wire 0x1f = 31, / 8
        XCTAssertEqual(info?.motionCount, 0)
        XCTAssertEqual(info?.sleepState, 1)
        XCTAssertEqual(info?.cv ?? 0, 0.343048, accuracy: 1e-6)   // 0x57d2 LE / 65536
    }

    /// `average_hr` is `u8 × 0.5`, not a bare bpm byte: an ODD wire byte decodes to a half-bpm. About
    /// half of all real records carry one (0.506 / 0.530 / 0.507 / 0.467 across four nights), so the
    /// half-steps are the channel's real resolution and rounding them away would be a decode loss.
    func testAverageHrHasHalfBpmResolution() {
        let info = OuraDecoders.decodeSleepPeriodInfo(record("6a0eb6cda60067e92e14862200013f58"))
        XCTAssertEqual(info?.averageHrBpm, 51.5)          // wire 0x67 = 103 — ODD
        XCTAssertEqual(info?.breathsPerMin, 16.75)
    }

    /// `hr_trend` is the body's ONE signed field. Read as unsigned this record's -4.625 becomes
    /// +11.375, which is a plausible-looking number — hence a test rather than a comment.
    func testHrTrendIsSigned() {
        let info = OuraDecoders.decodeSleepPeriodInfo(record("6a0e99efa60062b638176f1f01004055"))
        XCTAssertEqual(info?.hrTrend, -4.625)             // wire 0xb6 = -74 SIGNED, x 0.0625
        XCTAssertEqual(info?.averageHrBpm, 49.0)
        XCTAssertEqual(info?.motionCount, 1)
        XCTAssertEqual(info?.sleepState, 0)
    }

    /// A restless record: motion present, HR up, trend strongly positive. Confirms the fields move
    /// together the way a real summary should rather than being a fixed pattern.
    func testRestlessRecord() {
        let info = OuraDecoders.decodeSleepPeriodInfo(record("6a0e0929a7008c7f54346f261b007340"))
        XCTAssertEqual(info?.averageHrBpm, 70.0)
        XCTAssertEqual(info?.hrTrend, 7.9375)             // wire 0x7f = +127, the positive extreme
        XCTAssertEqual(info?.motionCount, 27)
        XCTAssertEqual(info?.breathsPerMin, 13.875)
    }

    // MARK: - The honest-data boundaries

    /// The source's own parser THROWS when `motion_count >= 121` or `sleep_state > 2`, so a body that
    /// breaks either is not this layout. Return nil rather than a number assembled from bytes that mean
    /// something else — and note this costs nothing on real data: all 3 493 records across four
    /// consecutive overnights satisfy both.
    func testDeclaredInvariantsRejectABody() {
        let badMotion = OuraRecord(type: 0x6A, ringTimestamp: 1,
                                   payload: [104, 0, 58, 31, 131, 31, 121, 1, 0xd2, 0x57])
        XCTAssertNil(OuraDecoders.decodeSleepPeriodInfo(badMotion), "motion_count == 121 is out of range")
        let badState = OuraRecord(type: 0x6A, ringTimestamp: 1,
                                  payload: [104, 0, 58, 31, 131, 31, 0, 3, 0xd2, 0x57])
        XCTAssertNil(OuraDecoders.decodeSleepPeriodInfo(badState), "sleep_state == 3 is out of range")
        // …and the boundary values that ARE legal still decode, so the guard is not off by one.
        let edge = OuraRecord(type: 0x6A, ringTimestamp: 1,
                              payload: [104, 0, 58, 31, 131, 31, 120, 2, 0xff, 0xff])
        XCTAssertEqual(OuraDecoders.decodeSleepPeriodInfo(edge)?.motionCount, 120)
        XCTAssertEqual(OuraDecoders.decodeSleepPeriodInfo(edge)?.sleepState, 2)
        XCTAssertEqual(OuraDecoders.decodeSleepPeriodInfo(edge)?.cv ?? 0, 0.999985, accuracy: 1e-6)
    }

    func testShortBodyDecodesToNil() {
        let short = OuraRecord(type: 0x6A, ringTimestamp: 1, payload: [104, 0, 58, 31, 131, 31, 0, 1, 0xd2])
        XCTAssertNil(OuraDecoders.decodeSleepPeriodInfo(short), "9 bytes cannot hold the u16 cv tail")
    }

    // MARK: - Tier discipline

    /// 0x6A is Tier B: the field NAMES rest on one decompiled-binary source, and nothing has shown
    /// `breath` tracks a real respiratory rate (#194). So the driver must drop it by default and only
    /// emit it when a caller explicitly asks for Tier B.
    func testTagIsTierBAndGatedInTheDriver() {
        XCTAssertEqual(OuraEventTag.sleepPeriodInfo.tier, .tierB)
        let rec = record("6a0e9dcca60068f13a1f831f0001d257")

        let gated = OuraDriver(ringGen: .gen3, authKey: nil)
        XCTAssertTrue(gated.ingest(record: rec).isEmpty, "Tier-B 0x6A must not be emitted by default")

        let allowed = OuraDriver(ringGen: .gen3, authKey: nil, allowTierB: true)
        let events = allowed.ingest(record: rec)
        XCTAssertEqual(events.count, 1)
        guard case .sleepPeriodInfo(let info)? = events.first else {
            return XCTFail("expected a .sleepPeriodInfo event, got \(events)")
        }
        XCTAssertEqual(info.breathsPerMin, 16.375)
        XCTAssertTrue(events[0].isTierB, "a consumer asserting a Tier-A-only sink must see this as Tier B")
        XCTAssertEqual(events[0].envelopeRingTimestamp, rec.ringTimestamp)
    }
}
