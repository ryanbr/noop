import XCTest
@testable import StrandDesign

final class WorkoutTypeIconTests: XCTestCase {

    /// The WHOOP-parity sports (#2260). Resolution is token-based, so a new catalogue name silently
    /// falls to the generic icon unless a token already covers it; these are the ones that should not.
    func testWhoopParitySportsResolveToARealIcon() {
        XCTAssertEqual(KnownWorkoutType.resolving("Nordic walking"), .nordicWalking)
        XCTAssertEqual(KnownWorkoutType.resolving("Jiu jitsu"), .jiuJitsu)
        XCTAssertEqual(KnownWorkoutType.resolving("Judo"), .judo)
        // "muay" was missing from a bucket that already listed karate and mma.
        XCTAssertEqual(KnownWorkoutType.resolving("Muay Thai"), .muayThai)
        XCTAssertEqual(KnownWorkoutType.resolving("Ballet"), .ballet)
        XCTAssertEqual(KnownWorkoutType.resolving("Breakdancing"), .breakdancing)
        XCTAssertEqual(KnownWorkoutType.resolving("Disc golf"), .discGolf)
    }

    /// The token was "dance", which the common inflection "dancing" does not contain, so only the exact
    /// catalogue name matched and any free-typed variant fell through. Pinned so it cannot regress.
    func testFreeTypedDancingResolves() {
        // NOT "dancing" on its own: exact(matching:) is case-insensitive, so that hits the catalogue's
        // own "Dancing" and never reaches the token chain. It passed before the fix too, which makes it
        // useless as a regression test. These have no exact match and must go through the token.
        XCTAssertEqual(KnownWorkoutType.resolving("Salsa dancing"), .dancing)
        XCTAssertEqual(KnownWorkoutType.resolving("evening dancing class"), .dancing)
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
