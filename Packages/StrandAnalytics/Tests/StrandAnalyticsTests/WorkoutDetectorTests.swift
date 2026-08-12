import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class WorkoutDetectorTests: XCTestCase {

    // MARK: - Activity series

    func testActivitySeriesFirstIsZero() {
        let grav = [
            GravitySample(ts: 0, x: 0, y: 0, z: 1),
            GravitySample(ts: 1, x: 0.3, y: 0, z: 1),  // Δ = 0.3
            GravitySample(ts: 2, x: 0.3, y: 0, z: 1),  // Δ = 0
        ]
        let series = WorkoutDetector.activitySeries(grav)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series[0].intensity, 0.0, accuracy: 1e-9)
        XCTAssertEqual(series[1].intensity, 0.3, accuracy: 1e-9)
        XCTAssertEqual(series[2].intensity, 0.0, accuracy: 1e-9)
    }

    func testActivitySeriesEmpty() {
        XCTAssertTrue(WorkoutDetector.activitySeries([]).isEmpty)
    }

    // MARK: - Calories

    func testCaloriesActiveAndRestingMale() {
        // 600 active samples at 150 bpm, male 80 kg 30 y, hrmax 190, RHR 60. With a resting HR known,
        // the Keytel FITNESS-adjusted model runs (Uth VO2max = 15.3·190/60 = 48.45): 58.5503 kJ/min ×
        // 600 s / 251.04 = 139.9386 kcal. (The base fitness-blind model gave 146.972.) MUST match the
        // Kotlin twin Vo2maxCaloriesTest.caloriesActiveAndRestingMale_matchesSwiftGolden.
        let hr = (0..<600).map { HRSample(ts: $0, bpm: 150) }
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let (kcal, kj) = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 190, restingHR: 60)
        XCTAssertEqual(kcal, 139.9386, accuracy: 0.1)
        XCTAssertEqual(kj, kcal * 4.184, accuracy: 1e-6)
    }

    func testCaloriesRestingBelowThreshold() {
        // HR below the 30% HRR active threshold → BMR rate (small per-sample).
        // Threshold = 60 + 0.30*(190-60) = 99. bpm 80 < 99 → resting.
        let hr = (0..<86400).map { HRSample(ts: $0, bpm: 80) }  // a full "day" of resting
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let (kcal, _) = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 190, restingHR: 60)
        // 86400 s at BMR rate ≈ full BMR ≈ 1853.6 kcal/day.
        XCTAssertEqual(kcal, 1853.632, accuracy: 1.0)
    }

    func testCaloriesSexCoefficientsDiffer() {
        let hr = (0..<600).map { HRSample(ts: $0, bpm: 150) }
        let male = Calories.estimateBoutCalories(
            hr, profile: UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "male"),
            hrmax: 190, restingHR: 60).0
        let female = Calories.estimateBoutCalories(
            hr, profile: UserProfile(weightKg: 70, heightCm: 175, age: 30, sex: "female"),
            hrmax: 190, restingHR: 60).0
        XCTAssertNotEqual(male, female, accuracy: 0.0)
    }

    // MARK: - Detection

    /// A workout: high HR + sustained motion for `durationS`, embedded in a rest day.
    private func workoutDay(workoutStart: Int, workoutDur: Int) -> (hr: [HRSample], grav: [GravitySample]) {
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = workoutStart - 30 * 60
        let dayEnd = workoutStart + workoutDur + 30 * 60
        for t in dayStart..<dayEnd {
            let inWorkout = t >= workoutStart && t < workoutStart + workoutDur
            // Resting periods: HR 55, still gravity. Workout: HR 165, moving gravity.
            hr.append(HRSample(ts: t, bpm: inWorkout ? 165 : 55))
            if inWorkout {
                let phase = Double((t - workoutStart) % 2) * 0.5  // 0.5 g oscillation → moving
                grav.append(GravitySample(ts: t, x: phase, y: 0, z: 1))
            } else {
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))  // still
            }
        }
        return (hr, grav)
    }

    func testDetectFindsWorkout() {
        let start = 5_000_000
        let dur = 20 * 60  // 20 min
        let (hr, grav) = workoutDay(workoutStart: start, workoutDur: dur)
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, age: 30)
        XCTAssertEqual(sessions.count, 1)
        let w = sessions[0]
        XCTAssertEqual(w.avgHR, 165, accuracy: 1.0)
        XCTAssertEqual(w.peakHR, 165)
        XCTAssertGreaterThan(w.durationS, Double(15 * 60))
        // Zone breakdown sums to ~100.
        let total = w.zoneTimePct.values.reduce(0, +)
        XCTAssertEqual(total, 100.0, accuracy: 0.5)
        XCTAssertEqual(w.hrmaxSource, "tanaka")  // age supplied, thin observed history
    }

    func testDetectWithProfileEstimatesCalories() {
        let start = 6_000_000
        let dur = 20 * 60
        let (hr, grav) = workoutDay(workoutStart: start, workoutDur: dur)
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, age: 30, profile: profile)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNotNil(sessions[0].caloriesKcal)
        XCTAssertGreaterThan(sessions[0].caloriesKcal!, 0)
    }

    func testDetectRejectsShortBout() {
        let start = 7_000_000
        let (hr, grav) = workoutDay(workoutStart: start, workoutDur: 3 * 60)  // 3 min < 5
        XCTAssertTrue(WorkoutDetector.detect(hr: hr, gravity: grav, age: 30).isEmpty)
    }

    func testDetectEmptyStreams() {
        XCTAssertTrue(WorkoutDetector.detect(hr: [], gravity: [], age: 30).isEmpty)
        let grav = [GravitySample(ts: 0, x: 0, y: 0, z: 1)]
        XCTAssertTrue(WorkoutDetector.detect(hr: [], gravity: grav, age: 30).isEmpty)
    }

    func testDetectRejectsLowIntensityBlip() {
        // Moving + slightly elevated HR but dominated by zone 0/1 (HR just over floor).
        // resting derived ~55, floor = 70. HR 75 is above floor but at ~15% HRR (zone 0).
        let start = 8_000_000
        let dur = 20 * 60
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = start - 30 * 60
        let dayEnd = start + dur + 30 * 60
        for t in dayStart..<dayEnd {
            let inBout = t >= start && t < start + dur
            hr.append(HRSample(ts: t, bpm: inBout ? 75 : 55))
            if inBout {
                let phase = Double((t - start) % 2) * 0.5
                grav.append(GravitySample(ts: t, x: phase, y: 0, z: 1))
            } else {
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            }
        }
        // age 30 → hrmax 187, zone math available → z2+ fraction ≈ 0 < 0.50 → rejected.
        XCTAssertTrue(WorkoutDetector.detect(hr: hr, gravity: grav, age: 30).isEmpty)
    }

    // MARK: - Sustained-effort fragmentation (#303)

    /// A long endurance bout (e.g. a road bike ride) that dips momentarily every few
    /// minutes — coasting downhill, a junction, a brief sensor gap — so that motion
    /// falls below threshold for a `dipS`-long stretch on a `cadenceS` cadence. HR
    /// stays elevated throughout (you don't actually rest). Helper returns a full day
    /// with the ride embedded in rest, plus the true ride span for assertions.
    private func longRideWithDips(
        rideStart: Int, rideDur: Int, cadenceS: Int, dipS: Int
    ) -> (hr: [HRSample], grav: [GravitySample]) {
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = rideStart - 30 * 60
        let dayEnd = rideStart + rideDur + 30 * 60
        for t in dayStart..<dayEnd {
            let inRide = t >= rideStart && t < rideStart + rideDur
            // Coasting dip: the last `dipS` seconds of every `cadenceS`-second cycle.
            let phaseInCycle = (t - rideStart) % cadenceS
            let coasting = inRide && phaseInCycle >= cadenceS - dipS
            // HR stays high the whole ride (a real dip in cadence ≠ a dip in HR).
            hr.append(HRSample(ts: t, bpm: inRide ? 150 : 52))
            if inRide && !coasting {
                let osc = Double((t - rideStart) % 2) * 0.5  // pedalling → moving
                grav.append(GravitySample(ts: t, x: osc, y: 0, z: 1))
            } else {
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))  // still / coasting
            }
        }
        return (hr, grav)
    }

    func testLongRideWithBriefDipsIsOneWorkout() {
        // ~4 h ride (matches the issue: 13:00–16:52) with a ~2-min coasting dip every
        // ~8 min. Each dip exceeds the OLD 150 s merge gap, so it used to shatter the
        // ride into ~30 sub-5-min slivers, most of which were then dropped by the
        // minimum-duration filter — surfacing as a handful of tiny "workouts".
        let start = 9_000_000
        let rideDur = 232 * 60      // 3 h 52 m
        let (hr, grav) = longRideWithDips(
            rideStart: start, rideDur: rideDur, cadenceS: 8 * 60, dipS: 180)
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, age: 30)

        // One ride → one workout, spanning ~the whole ride (not a pile of fragments).
        XCTAssertEqual(sessions.count, 1, "sustained ride fragmented into \(sessions.count) workouts")
        let w = sessions[0]
        XCTAssertGreaterThan(w.durationS, Double(rideDur) * 0.9,
                             "merged ride too short: \(Int(w.durationS))s of \(rideDur)s")
        XCTAssertEqual(w.avgHR, 150, accuracy: 2.0)
    }

    func testGenuinelySeparateWorkoutsStaySeparate() {
        // Two real workouts separated by a long genuine rest (HR drops to resting and
        // motion stops for ~25 min) must NOT be merged by the bridge. Guards against
        // the fix over-merging unrelated sessions.
        let startA = 10_000_000
        let durA = 20 * 60
        let restGap = 25 * 60               // 25 min true rest, well beyond the bridge
        let startB = startA + durA + restGap
        let durB = 20 * 60
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = startA - 30 * 60
        let dayEnd = startB + durB + 30 * 60
        for t in dayStart..<dayEnd {
            let inA = t >= startA && t < startA + durA
            let inB = t >= startB && t < startB + durB
            let active = inA || inB
            hr.append(HRSample(ts: t, bpm: active ? 160 : 52))
            if active {
                let osc = Double(t % 2) * 0.5
                grav.append(GravitySample(ts: t, x: osc, y: 0, z: 1))
            } else {
                grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            }
        }
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, age: 30)
        XCTAssertEqual(sessions.count, 2, "separate workouts were over-merged")
    }

    func testWarmupBeforeHrRisesBackdatesStartToMotionOnset() {
        // #148: motion (walking / cycling) starts, but HR lags ~10 min behind during cardiac
        // warm-up. The HR-AND-motion gate used to clip that warm-up, dropping the first ~10 min
        // (the reporter's "way there not tracked, way back tracked"). Motion is continuous from
        // onset, so a confirmed run's start must back-date to the motion onset, not the HR crossing.
        let motionStart = 12_000_000
        let warmupS = 10 * 60   // moving, HR still ~resting (below the floor) → used to be clipped
        let coreS = 20 * 60     // moving, HR elevated → the HR-gated core
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = motionStart - 30 * 60
        let dayEnd = motionStart + warmupS + coreS + 30 * 60
        for t in dayStart..<dayEnd {
            let inWarm = t >= motionStart && t < motionStart + warmupS
            let inCore = t >= motionStart + warmupS && t < motionStart + warmupS + coreS
            let moving = inWarm || inCore
            hr.append(HRSample(ts: t, bpm: inCore ? 150 : (inWarm ? 60 : 52)))
            let phase = moving ? Double(t % 2) * 0.5 : 0.0
            grav.append(GravitySample(ts: t, x: phase, y: 0, z: 1))
        }
        // resting 52 → floor 67: warm-up 60 is below it (clipped without the fix), core 150 clears it.
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 52, age: 30)
        XCTAssertEqual(sessions.count, 1)
        let w = sessions[0]
        XCTAssertLessThanOrEqual(w.start, motionStart + 120,
            "start \(w.start) not back-dated to motion onset \(motionStart) (HR crossed ~\(motionStart + warmupS))")
        XCTAssertGreaterThanOrEqual(w.durationS, Double(warmupS + coreS) * 0.9,
            "duration \(Int(w.durationS))s still excludes the warm-up")
    }

    func testBackdateDoesNotCrossPreviousWorkoutContinuousMotion() {
        // #148 guard: you keep walking the whole time (motion never stops), but HR spikes, dips to
        // resting for a few minutes, then spikes again → two separate efforts (bridgeRuns won't merge
        // across an HR-to-resting lull). Back-dating the second effort must NOT walk its start across
        // the still-moving lull into the first one — the two sessions must stay non-overlapping.
        let startA = 13_000_000
        let durA = 15 * 60
        let lull = 6 * 60          // HR at resting, but STILL WALKING
        let durB = 15 * 60
        let moveEnd = startA + durA + lull + durB
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        let dayStart = startA - 30 * 60
        let dayEnd = moveEnd + 30 * 60
        for t in dayStart..<dayEnd {
            let inA = t >= startA && t < startA + durA
            let inB = t >= startA + durA + lull && t < moveEnd
            let moving = t >= startA && t < moveEnd   // continuous through the lull
            hr.append(HRSample(ts: t, bpm: (inA || inB) ? 155 : 52))
            grav.append(GravitySample(ts: t, x: moving ? Double(t % 2) * 0.5 : 0.0, y: 0, z: 1))
        }
        let sessions = WorkoutDetector.detect(hr: hr, gravity: grav, restingHR: 52, age: 30)
        XCTAssertEqual(sessions.count, 2, "continuous-motion lull did not split into two efforts")
        XCTAssertGreaterThan(sessions[1].start, sessions[0].end,
            "second workout (\(sessions[1].start)) overlaps the first (ends \(sessions[0].end))")
    }
}
