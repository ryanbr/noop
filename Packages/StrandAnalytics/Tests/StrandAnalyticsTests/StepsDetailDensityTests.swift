import Foundation
import XCTest
@testable import StrandAnalytics

final class StepsDetailDensityTests: XCTestCase {
    private let projector: ([StepsDetailReading], StepsDetailRange, String?) -> [StepsDetailBucket] =
        StepsDetailDensity.project

    private func loadOracle() throws -> [[String: Any]] {
        let relative = "android/app/src/test/resources/steps_detail_density_oracle.json"
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

    func testSwiftProjectorAssertsTheSharedAndroidFixture() throws {
        let cases = try loadOracle()
        XCTAssertEqual(cases.count, 11)
        XCTAssertEqual(Set(cases.compactMap { $0["range"] as? String }),
                       Set(["W", "2W", "3W", "M", "3M", "6M", "1Y", "ALL"]))

        for fixture in cases {
            let id = try XCTUnwrap(fixture["id"] as? String)
            let range = try XCTUnwrap(StepsDetailRange(rawValue: try XCTUnwrap(fixture["range"] as? String)))
            let readings = try XCTUnwrap(fixture["readings"] as? [[String: Any]]).map {
                StepsDetailReading(day: try XCTUnwrap($0["day"] as? String),
                                   value: try XCTUnwrap($0["value"] as? NSNumber).doubleValue)
            }
            let expected = try XCTUnwrap(fixture["expected"] as? [[String: Any]])
            let actual = projector(readings, range, try XCTUnwrap(fixture["anchorDay"] as? String))

            XCTAssertEqual(actual.count, expected.count, id)
            for (bucket, want) in zip(actual, expected) {
                XCTAssertEqual(bucket.key, want["key"] as? String, id)
                XCTAssertEqual(bucket.displayDay, want["displayDay"] as? String, id)
                XCTAssertEqual(bucket.sum, try XCTUnwrap(want["sum"] as? NSNumber).doubleValue,
                               accuracy: 0.000_000_1, id)
                XCTAssertEqual(bucket.observedDayCount, want["observedDayCount"] as? Int, id)
                XCTAssertEqual(bucket.mean, want["mean"] as? Int, id)
            }
        }
    }

    func testInvalidExplicitAnchorProducesNoBuckets() {
        let readings = [StepsDetailReading(day: "2024-02-29", value: 100)]
        XCTAssertEqual(projector(readings, .week, "2023-02-29"), [])
    }

    func testLatestValidReadingIsTheDefaultAnchor() {
        let readings = [
            StepsDetailReading(day: "2024-01-01", value: 1),
            StepsDetailReading(day: "2024-01-20", value: 2),
            StepsDetailReading(day: "invalid", value: 999),
        ]
        XCTAssertEqual(projector(readings, .week, nil), [
            StepsDetailBucket(key: "2024-01-20", displayDay: "2024-01-20",
                              sum: 2, observedDayCount: 1, mean: 2),
        ])
    }
}
