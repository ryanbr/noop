import XCTest
@testable import StrandDesign

final class WorkoutTypeIconTests: XCTestCase {

    func testPreferredIdentitiesAreUnique() {
        var seen = Set<String>()
        for type in KnownWorkoutType.allCases {
            let id = WorkoutTypeIconography.preferredIdentity(for: type)
            XCTAssertFalse(seen.contains(id), "Duplicate preferred icon identity \(id) for \(type.rawValue)")
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, KnownWorkoutType.allCases.count)
    }

    func testRuntimeIdentitiesAreUnique() {
        var seen = Set<String>()
        for type in KnownWorkoutType.allCases {
            let id = WorkoutTypeIconography.identity(for: type)
            XCTAssertFalse(seen.contains(id), "Duplicate runtime icon identity \(id) for \(type.rawValue)")
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, KnownWorkoutType.allCases.count)
    }

    func testExactResolveMatchesRawValues() {
        for type in KnownWorkoutType.allCases {
            XCTAssertEqual(KnownWorkoutType.exact(matching: type.rawValue), type)
            XCTAssertEqual(KnownWorkoutType.exact(matching: type.rawValue.lowercased()), type)
        }
    }

    func testFuzzyResolveCoversCommonAliases() {
        XCTAssertEqual(KnownWorkoutType.resolving("Morning Run"), .running)
        XCTAssertEqual(KnownWorkoutType.resolving("trail hike"), .hiking)
        XCTAssertEqual(KnownWorkoutType.resolving("indoor bike"), .indoorCycle)
        XCTAssertEqual(KnownWorkoutType.resolving("open water swimming"), .openWaterSwim)
        XCTAssertEqual(KnownWorkoutType.resolving("detected"), .other)
        XCTAssertNil(KnownWorkoutType.resolving(""))
    }

    func testPadelUsesCustomGlyph() {
        XCTAssertEqual(WorkoutTypeIconography.glyph(for: .padel),
                       .custom(.padelRacket))
    }

    func testSportSymbolBridgeNonEmpty() {
        for type in KnownWorkoutType.allCases {
            XCTAssertFalse(sportSymbol(type.rawValue).isEmpty)
        }
    }
}
