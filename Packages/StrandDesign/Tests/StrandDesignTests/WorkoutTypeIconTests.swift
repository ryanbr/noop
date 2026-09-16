import XCTest
@testable import StrandDesign

final class WorkoutTypeIconTests: XCTestCase {

    /// The WHOOP-parity sports (#2260). Resolution is token-based, so a new catalogue name silently
    /// falls to the generic icon unless a token already covers it; these are the ones that should not.
    func testWhoopParitySportsResolveToARealIcon() {
        XCTAssertEqual(KnownWorkoutType.resolving("Nordic walking"), .walking)
        XCTAssertEqual(KnownWorkoutType.resolving("Jiu jitsu"), .martialArts)
        XCTAssertEqual(KnownWorkoutType.resolving("Judo"), .martialArts)
        // "muay" was missing from a bucket that already listed karate and mma.
        XCTAssertEqual(KnownWorkoutType.resolving("Muay Thai"), .martialArts)
        XCTAssertEqual(KnownWorkoutType.resolving("Ballet"), .dancing)
        XCTAssertEqual(KnownWorkoutType.resolving("Breakdancing"), .dancing)
        XCTAssertEqual(KnownWorkoutType.resolving("Disc golf"), .golf)
    }

    /// The token was "dance", which the common inflection "dancing" does not contain, so only the exact
    /// catalogue name matched and any free-typed variant fell through. Pinned so it cannot regress.
    func testFreeTypedDancingResolves() {
        XCTAssertEqual(KnownWorkoutType.resolving("dancing"), .dancing)
        XCTAssertEqual(KnownWorkoutType.resolving("Salsa dancing"), .dancing)
    }

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
