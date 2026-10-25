import Foundation
import HealthKit

/// Which Apple Health activity type a NOOP sport is written as. Health, and so Strava and Bevel, take the
/// activity's name and icon from this alone: a sport with no entry lands as "Other Exercise". The map covers
/// every name in `WorkoutCatalog`, so a sport you pick in NOOP keeps its own name downstream.
enum HealthWorkoutType {

    static func activityType(forSport sport: String) -> HKWorkoutActivityType {
        table[sport.lowercased().trimmingCharacters(in: .whitespaces)] ?? .other
    }

    private static let table: [String: HKWorkoutActivityType] = {
        var t: [String: HKWorkoutActivityType] = [:]
        func add(_ type: HKWorkoutActivityType, _ names: String...) { names.forEach { t[$0] = type } }
        add(.running, "running", "treadmill run")
        add(.walking, "walking", "treadmill walk", "rucking")
        add(.hiking, "hiking", "snowshoeing")
        add(.cycling, "cycling", "indoor cycle", "mountain biking", "spinning")
        add(.swimming, "open-water swim", "pool swim", "swimming")
        add(.rowing, "rowing", "row machine")
        add(.elliptical, "elliptical")
        add(.traditionalStrengthTraining, "strength", "bodybuilding", "weightlifting", "powerlifting", "strength trainer")
        add(.functionalStrengthTraining, "calisthenics")
        add(.highIntensityIntervalTraining, "hiit")
        add(.crossTraining, "crossfit", "boot camp")
        add(.coreTraining, "core training")
        add(.yoga, "yoga")
        add(.pilates, "pilates")
        add(.flexibility, "stretching")
        add(.mindAndBody, "meditation")
        add(.boxing, "boxing")
        add(.kickboxing, "kickboxing")
        add(.martialArts, "martial arts", "judo", "jiu jitsu", "muay thai")
        add(.basketball, "basketball")
        add(.soccer, "soccer")
        add(.baseball, "baseball")
        add(.softball, "softball")
        add(.badminton, "badminton")
        add(.tennis, "tennis")
        add(.pickleball, "pickleball")
        add(.squash, "squash")
        add(.racquetball, "racquetball")
        add(.tableTennis, "table tennis")
        add(.volleyball, "volleyball", "sand volleyball")
        add(.dance, "dancing")
        add(.golf, "golf")
        add(.climbing, "climbing")
        add(.downhillSkiing, "skiing")
        add(.snowboarding, "snowboarding")
        add(.bowling, "bowling")
        add(.hockey, "ice hockey", "field hockey", "hurling/camogie")
        add(.americanFootball, "american football", "football")
        add(.australianFootball, "australian football")
        add(.rugby, "rugby")
        add(.cricket, "cricket")
        add(.handball, "handball")
        add(.waterPolo, "water polo")
        add(.discSports, "frisbee")
        add(.surfingSports, "surfing")
        add(.paddleSports, "kayaking", "stand-up paddleboard", "paddling")
        add(.sailing, "sailing", "kiteboarding")
        if #available(iOS 17.0, macOS 14.0, *) { add(.underwaterDiving, "scuba diving") }
        add(.skatingSports, "ice skating", "inline skating", "skateboarding")
        add(.gymnastics, "gymnastics")
        add(.fencing, "fencing")
        add(.stairClimbing, "stair climber", "stairs")
        add(.lacrosse, "lacrosse")
        add(.jumpRope, "jump rope")
        add(.archery, "archery")
        add(.fishing, "fishing")
        add(.hunting, "hunting")
        add(.curling, "curling")
        return t
    }()
}
