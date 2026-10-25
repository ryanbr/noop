import XCTest
import HealthKit
@testable import Strand

/// Every sport NOOP offers reaches Apple Health as its own activity type. Health, and Strava and Bevel with it,
/// name and icon a workout from that type alone, so a sport with no entry shows up as "Other Exercise".
final class HealthWorkoutTypeTests: XCTestCase {

    /// Sports Health has no activity type for stay "Other"; every other catalogue sport must not.
    private let hasNoHealthType: Set<String> = [
        "padel", "netball", "gaelic football", "spikeball", "horseback riding", "wheelchair", "gaming",
        "motor racing", "nordic walking", "ballet", "billiards", "breakdancing", "cheerleading", "darts",
        "disc golf", "other", "motocross", "paintball", "parkour", "polo", "skydiving",
    ]

    func testEveryCatalogueSportWithAHealthTypeKeepsIt() {
        for sport in WorkoutCatalog.all where !hasNoHealthType.contains(sport.name.lowercased()) {
            XCTAssertNotEqual(HealthWorkoutType.activityType(forSport: sport.name), .other, sport.name)
        }
    }

    func testTheSportsThatShowedUpAsOtherExercise() {
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: "Weightlifting"), .traditionalStrengthTraining)
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: "Strength"), .traditionalStrengthTraining)
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: "HIIT"), .highIntensityIntervalTraining)
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: "Judo"), .martialArts)
    }

    func testNamesThatMappedBeforeStillMapTheSame() {
        let before: [String: HKWorkoutActivityType] = [
            "running": .running, "walking": .walking, "hiking": .hiking, "cycling": .cycling,
            "hiit": .highIntensityIntervalTraining, "core training": .coreTraining, "yoga": .yoga,
            "pilates": .pilates, "rowing": .rowing, "elliptical": .elliptical, "stairs": .stairClimbing,
            "jump rope": .jumpRope, "boxing": .boxing, "basketball": .basketball, "soccer": .soccer,
            "football": .americanFootball, "baseball": .baseball, "badminton": .badminton, "tennis": .tennis,
            "table tennis": .tableTennis, "volleyball": .volleyball, "squash": .squash,
            "martial arts": .martialArts, "dancing": .dance, "golf": .golf, "climbing": .climbing,
            "skiing": .downhillSkiing, "snowboarding": .snowboarding, "swimming": .swimming,
            "surfing": .surfingSports, "paddling": .paddleSports,
        ]
        for (name, type) in before { XCTAssertEqual(HealthWorkoutType.activityType(forSport: name), type, name) }
    }

    func testUnknownAndGenericSportsStayOther() {
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: "Workout"), .other)
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: "Activity"), .other)
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: ""), .other)
    }

    func testMatchingIgnoresCaseAndEdgeSpaces() {
        XCTAssertEqual(HealthWorkoutType.activityType(forSport: "  WEIGHTLIFTING "), .traditionalStrengthTraining)
    }
}
