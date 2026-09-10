import XCTest
@testable import WhoopProtocol

final class Whoop5RRTests: XCTestCase {
    private struct Oracle: Decodable {
        struct Case: Decodable { let ticks: UInt16; let milliseconds: Int }
        struct Policy: Decodable { let model: String?; let brand: String?; let tagged: Bool; let strict: Bool }
        struct Wire: Decodable { let name: String; let hex: String; let raw: [Int]; let ms: [Int]; let channel: Int }
        let cases: [Case]
        let policy_cases: [Policy]
        let wire_cases: [Wire]
        let milliseconds_u16le_fnv1a64: String
    }
    private func oracle() throws -> Oracle {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "whoop5_rr_oracle", withExtension: "json"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    func testAllUnsignedWordsMatchExecutedSwiftOracle() throws {
        let expected = try oracle()
        var hash: UInt64 = 14695981039346656037
        for ticks in UInt16.min...UInt16.max {
            let ms = Whoop5RR.milliseconds(ticks: ticks)
            for byte in [ms & 255, ms >> 8] { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        }
        XCTAssertEqual(String(format: "%016llx", hash), expected.milliseconds_u16le_fnv1a64)
        for c in expected.cases { XCTAssertEqual(Whoop5RR.milliseconds(ticks: c.ticks), c.milliseconds) }
        for c in expected.policy_cases {
            XCTAssertEqual(Whoop5RR.usesCanonicalSource(model: c.model, brand: c.brand,
                                                       hasTaggedIntervals: c.tagged), c.strict)
        }
    }

    func testWireBoundsRawUnitsAndExtractedProvenance() throws {
        for c in try oracle().wire_cases {
            let chars = Array(c.hex)
            let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
            let f = parseFrame(bytes, family: .whoop5)
            XCTAssertTrue(f.ok, c.name)
            XCTAssertEqual(f.crcOK, true, c.name)
            XCTAssertEqual(f.parsed["rr_raw_ticks"]?.intArrayValue, c.raw, c.name)
            XCTAssertEqual(f.parsed["rr_intervals"]?.intArrayValue, c.ms, c.name)
            XCTAssertEqual(f.parsed["rr_source_channel"]?.intValue, c.channel, c.name)
            let streams = c.channel == 5
                ? extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
                : extractStreams([f], deviceClockRef: 0, wallClockRef: 0)
            XCTAssertEqual(streams.rr.map(\.rrMs), c.ms, c.name)
            XCTAssertEqual(streams.rr.compactMap { $0.srcChannel?.rawValue }, c.ms.map { _ in c.channel }, c.name)
        }
    }

    func testTransportCodes() {
        XCTAssertEqual(RRSourceChannel.allCases.map(\.rawValue), Array(1...7))
    }

    /// The table below is the parity contract for the "this night cannot be scored" explanation. The
    /// Kotlin `legacyUnscorableNight` test carries the SAME rows, so the two platforms cannot start
    /// explaining a different set of nights to the wearer.
    func testLegacyUnscorableNight() {
        let cases: [(String, Bool, String, String?, String?, Double?, Double?, Bool)] = [
            // (strictWhoop5, day, firstRecordedDay, firstScorableDay, avgHrv, totalSleepMin) -> claimed
            // A confirmed WHOOP 5 recording since the 1st, labelled era starting on the 10th: the 9th is the
            // case this explains.
            ("W5, staged night inside the unlabelled era", true, "2026-08-09", "2026-08-01", "2026-08-10", nil, 431.0, true),
            // The same night once it scored: there is nothing to explain.
            ("W5, that night scored", true, "2026-08-09", "2026-08-01", "2026-08-10", 48.0, 431.0, false),
            // Nothing staged, so an empty HRV is far more likely an unworn strap. Never blame the units.
            ("W5, no night staged", true, "2026-08-09", "2026-08-01", "2026-08-10", nil, 0.0, false),
            ("W5, sleep unknown", true, "2026-08-09", "2026-08-01", "2026-08-10", nil, nil, false),
            // On and after the first scorable day the general statement stops being true.
            ("W5, the labelled day itself", true, "2026-08-10", "2026-08-01", "2026-08-10", nil, 431.0, false),
            ("W5, inside the labelled era", true, "2026-08-11", "2026-08-01", "2026-08-10", nil, 431.0, false),
            // BEFORE the strap ever recorded: imported history, which never had beats to lose.
            ("W5, imported night predating the strap", true, "2026-07-30", "2026-08-01", "2026-08-10", nil, 431.0, false),
            ("W5, the first recorded day itself", true, "2026-08-01", "2026-08-01", "2026-08-10", nil, 431.0, true),
            // A device that has banked no beats at all can never have lost any to the units.
            ("W5, nothing recorded", true, "2026-08-09", nil, nil, nil, 431.0, false),
            ("W5, nothing recorded, empty key", true, "2026-08-09", "", nil, nil, 431.0, false),
            // Recording, but never synced since the units were corrected: every staged night in the era.
            ("W5, nothing labelled banked", true, "2026-08-09", "2026-08-01", nil, nil, 431.0, true),
            ("W5, nothing labelled, empty key", true, "2026-08-09", "2026-08-01", "", nil, 431.0, true),
            // The policy is not applied to this device, so the explanation would be a lie.
            ("WHOOP 4 night", false, "2026-08-09", "2026-08-01", "2026-08-10", nil, 431.0, false),
            // Day keys are yyyy-MM-dd, so string order is date order across a month and a year boundary.
            ("W5, previous month", true, "2026-07-31", "2026-07-01", "2026-08-01", nil, 400.0, true),
            ("W5, next year", true, "2027-01-01", "2026-01-01", "2026-12-31", nil, 400.0, false),
        ]
        for (name, strict, day, recorded, scorable, hrv, sleep, want) in cases {
            XCTAssertEqual(
                Whoop5RR.legacyUnscorableNight(strictWhoop5: strict, day: day, firstRecordedDay: recorded,
                                               firstScorableDay: scorable,
                                               avgHrv: hrv, totalSleepMin: sleep),
                want, name)
        }
    }
}
