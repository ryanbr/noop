import XCTest
@testable import OuraProtocol

/// Pins `OuraActivityRecordTiming` against the SHARED fixture the Kotlin twin also asserts
/// (`android/app/src/test/resources/oura_met_record_timing_oracle.json`, #2242).
///
/// One committed file, read by both suites, so neither platform can move the rule without the other
/// going red. The fixture is generated from this Swift enum compiled standalone; regenerate it from
/// Swift and never hand-edit a number in it.
final class ActivityRecordTimingTests: XCTestCase {

    private func loadOracle() throws -> [[String: Any]] {
        let relative = "android/app/src/test/resources/oura_met_record_timing_oracle.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                let root = try XCTUnwrap(object as? [String: Any])
                XCTAssertEqual(root["schemaVersion"] as? Int, 1)
                XCTAssertFalse(try XCTUnwrap(root["note"] as? String).isEmpty)
                return try XCTUnwrap(root["cases"] as? [[String: Any]])
            }
            directory = directory.deletingLastPathComponent()
        }
        XCTFail("committed oracle \(relative) not found above \(#filePath)")
        throw CocoaError(.fileNoSuchFile)
    }

    func testSwiftTimingAssertsTheSharedAndroidFixture() throws {
        let cases = try loadOracle()
        XCTAssertEqual(cases.count, 11)
        // The shapes that must be in the contract: if one is dropped the fixture stops covering it.
        XCTAssertTrue(Set(cases.compactMap { $0["id"] as? String })
            .isSuperset(of: ["single_sample_record", "typical_26_sample_record",
                             "straddles_local_midnight", "ends_exactly_on_local_midnight",
                             "two_minute_cadence", "empty_record", "zero_epoch"]))

        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let endUtc = try XCTUnwrap(fixture["endUtc"] as? Int)
            let sampleCount = try XCTUnwrap(fixture["sampleCount"] as? Int)
            let epochSeconds = try XCTUnwrap(fixture["epochSeconds"] as? Int)
            let expected = try XCTUnwrap(fixture["expectedStarts"] as? [Int])

            let actual = OuraActivityRecordTiming.sampleStarts(
                endUtc: endUtc, sampleCount: sampleCount, epochSeconds: epochSeconds)
            XCTAssertEqual(actual, expected, "\(id): sample starts")

            // Per-sample accessor must agree with the bulk one, index for index.
            for (index, start) in expected.enumerated() {
                XCTAssertEqual(
                    OuraActivityRecordTiming.sampleStart(
                        endUtc: endUtc, sampleCount: sampleCount, index: index,
                        epochSeconds: epochSeconds),
                    start, "\(id): sampleStart(index: \(index))")
            }
        }
    }

    /// The property the fan-out exists for: the record timestamp is the EXCLUSIVE end of the span, the
    /// samples are contiguous and ascending, and the last one ends exactly on the timestamp.
    func testSamplesAreContiguousAndEndOnTheRecordTimestamp() {
        for sampleCount in 1...40 {
            for epoch in [30, 60, 120, 300] {
                let endUtc = 1_755_208_800
                let starts = OuraActivityRecordTiming.sampleStarts(
                    endUtc: endUtc, sampleCount: sampleCount, epochSeconds: epoch)
                XCTAssertEqual(starts.count, sampleCount)
                XCTAssertEqual(starts.first, endUtc - sampleCount * epoch)
                XCTAssertEqual(starts.last! + epoch, endUtc,
                               "the last sample must end ON the record timestamp")
                XCTAssertFalse(starts.contains(endUtc),
                               "the timestamp itself is never a sample start")
                for (a, b) in zip(starts, starts.dropFirst()) {
                    XCTAssertEqual(b - a, epoch, "samples must be exactly one epoch apart")
                }
            }
        }
    }

    /// Reading FORWARD from the timestamp is the rule this helper exists to replace (23 % exact minute
    /// matches against Oura's export, vs 85 % reading back). Pin the direction so a "simplification"
    /// that flips it fails here rather than on a wearer's day boundary.
    func testDirectionIsBackwardFromTheTimestampNotForward() {
        let starts = OuraActivityRecordTiming.sampleStarts(
            endUtc: 1_000_000, sampleCount: 3, epochSeconds: 60)
        XCTAssertEqual(starts, [999_820, 999_880, 999_940])
        XCTAssertNotEqual(starts, [1_000_000, 1_000_060, 1_000_120], "this is the forward reading")
    }

    func testDegenerateShapesPlaceNothing() {
        XCTAssertEqual(OuraActivityRecordTiming.sampleStarts(endUtc: 100, sampleCount: 0, epochSeconds: 60), [])
        XCTAssertEqual(OuraActivityRecordTiming.sampleStarts(endUtc: 100, sampleCount: -3, epochSeconds: 60), [])
        XCTAssertEqual(OuraActivityRecordTiming.sampleStarts(endUtc: 100, sampleCount: 5, epochSeconds: 0), [])
        XCTAssertEqual(OuraActivityRecordTiming.sampleStarts(endUtc: 100, sampleCount: 5, epochSeconds: -60), [])
    }
}
