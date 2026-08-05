import XCTest
@testable import Strand
import StrandDesign

/// Pins the suggestion catalogue (#714): the two new indoor presets exist, are spelled byte-for-byte
/// the way Android persists them (the stored sport label round-trips cross-platform via CSV / export),
/// and default GPS off (no route on a treadmill or a lifting session). Mirrors the Android
/// WorkoutSportTest intent for the same two sports.
final class WorkoutCatalogTests: XCTestCase {

    func testTreadmillWalkPresetExistsWithGpsOff() {
        let s = WorkoutCatalog.sport(named: "Treadmill walk")
        XCTAssertNotNil(s, "Treadmill walk must be in the suggestion catalogue (#714)")
        XCTAssertEqual(s?.name, "Treadmill walk", "Name is persisted data, must match Android byte-for-byte")
        XCTAssertEqual(s?.isDistanceSport, false, "Indoor walk has no route, so GPS defaults off")
    }

    func testBodybuildingPresetExistsWithGpsOff() {
        let s = WorkoutCatalog.sport(named: "Bodybuilding")
        XCTAssertNotNil(s, "Bodybuilding must be in the suggestion catalogue (#714)")
        XCTAssertEqual(s?.name, "Bodybuilding", "Name is persisted data, must match Android byte-for-byte")
        XCTAssertEqual(s?.isDistanceSport, false, "A lifting session has no route, so GPS defaults off")
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(WorkoutCatalog.sport(named: "treadmill WALK")?.name, "Treadmill walk")
        XCTAssertEqual(WorkoutCatalog.sport(named: "  bodybuilding  ")?.name, "Bodybuilding")
    }

    /// #768: the newly requested presets exist and are spelled byte-for-byte the way Android persists
    /// them (the stored sport label round-trips cross-platform via CSV / export). Racket + court sports
    /// have no route so GPS defaults off; snow sports cover ground so GPS defaults on.
    func testNewPresetsExistWithCorrectGpsDefaults() {
        let gpsOff = ["Racquetball", "Volleyball", "Martial arts", "Dancing", "Golf",
                      "Climbing", "Stretching", "Pickleball"]
        for name in gpsOff {
            let s = WorkoutCatalog.sport(named: name)
            XCTAssertNotNil(s, "\(name) must be in the suggestion catalogue (#768)")
            XCTAssertEqual(s?.name, name, "Name is persisted data, must match Android byte-for-byte")
            XCTAssertEqual(s?.isDistanceSport, false, "\(name) has no route, GPS defaults off")
        }
        for name in ["Skiing", "Snowboarding"] {
            let s = WorkoutCatalog.sport(named: name)
            XCTAssertNotNil(s, "\(name) must be in the suggestion catalogue (#768)")
            XCTAssertEqual(s?.isDistanceSport, true, "\(name) covers ground, GPS defaults on")
        }
    }

    /// Padel (#152) stays the canonical racket extra, and the new Pickleball extra rides last, just
    /// before the generic "Other" catch-all , parity with Android's WorkoutSport build order.
    func testExtrasPrecedeOther() {
        let names = WorkoutCatalog.all.map(\.name)
        guard let pickle = names.firstIndex(of: "Pickleball"),
              let other = names.firstIndex(of: "Other") else {
            return XCTFail("Pickleball and Other must both be present")
        }
        XCTAssertLessThan(pickle, other, "Pickleball extra must sit before the generic Other")
        XCTAssertEqual(names.last, "Other", "Other stays the final catch-all")
    }

    /// Bowling (D#850): exists, is spelled byte-for-byte the way Android persists it, defaults GPS off
    /// (a lane has no route), and rides with the extras before the generic "Other" catch-all.
    func testBowlingPresetExistsWithGpsOff() {
        let s = WorkoutCatalog.sport(named: "bowling")
        XCTAssertNotNil(s, "Bowling must be in the suggestion catalogue (D#850)")
        XCTAssertEqual(s?.name, "Bowling", "Name is persisted data, must match Android byte-for-byte")
        XCTAssertEqual(s?.isDistanceSport, false, "Bowling has no route, GPS defaults off")
        let names = WorkoutCatalog.all.map(\.name)
        guard let bowling = names.firstIndex(of: "Bowling"),
              let other = names.firstIndex(of: "Other") else {
            return XCTFail("Bowling and Other must both be present")
        }
        XCTAssertLessThan(bowling, other, "Bowling extra must sit before the generic Other")
    }

    /// Iconography lockstep: every catalogue sport must resolve to a `KnownWorkoutType` with a unique
    /// preferred glyph so the live-workout Liquid Glass control never shares icons across types.
    func testCatalogueSportsHaveUniqueWorkoutTypeIcons() {
        let catalogNames = WorkoutCatalog.all.map(\.name)
        let knownNames = KnownWorkoutType.allCases.map(\.rawValue)
        XCTAssertEqual(Set(catalogNames), Set(knownNames),
                       "KnownWorkoutType raw values must match WorkoutCatalog.all names exactly")

        var identities = Set<String>()
        for sport in WorkoutCatalog.all {
            guard let type = KnownWorkoutType.exact(matching: sport.name) else {
                return XCTFail("No KnownWorkoutType for catalogue sport \(sport.name)")
            }
            let id = WorkoutTypeIconography.preferredIdentity(for: type)
            XCTAssertFalse(identities.contains(id), "Duplicate icon \(id) for \(sport.name)")
            identities.insert(id)
        }
        XCTAssertEqual(identities.count, WorkoutCatalog.all.count)
    }
}
