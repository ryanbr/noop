import XCTest
@testable import StrandDesign

final class WorkoutTypeIconTests: XCTestCase {

    /// Free-text resolution for sports WHOOP names and NOOP does not carry as catalogue entries.
    /// These arrive as typed or imported labels, so the token chain is what they have.
    func testWhoopParitySportsResolveToARealIcon() {
        // Now an exact catalogue case of its own, so it resolves to itself rather than to Walking.
        XCTAssertEqual(KnownWorkoutType.resolving("Nordic walking"), .nordicWalking)
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
