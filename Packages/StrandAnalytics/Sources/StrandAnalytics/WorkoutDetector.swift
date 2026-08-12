import Foundation
import WhoopProtocol
import WhoopStore

// WorkoutDetector.swift — retroactive workout detection from the 1 Hz store.
//
// Ported from server/ingest/app/analysis/exercise.py (+ activity.py, calories.py).
//
// A workout is a SUSTAINED window (≥ MIN_EXERCISE_MIN) of elevated HR (above
// resting + HR_MARGIN_BPM) AND sustained motion (gravity-derived intensity above
// MOTION_THRESHOLD). Both gates must hold for a sample to count as active.
//
// Per detected bout: avg/peak HR, duration, Edwards zone time-%, mean %HRR,
// strain (StrainScorer), and estimated calories (Keytel 2005 active + revised
// Harris–Benedict BMR resting, age/sex/weight/height adjusted).
//
// All intensity/energy outputs are APPROXIMATE and not medical advice.

// MARK: - Profile + result

/// User profile for calorie estimation.
public struct UserProfile: Equatable, Sendable {
    public var weightKg: Double
    public var heightCm: Double
    public var age: Double
    public var sex: String   // "male" | "female" | "nonbinary"
    /// Counter ticks per real step for the @57 motion counter (#139). The WHOOP 5/MG
    /// counter overcounts and its true tick rate is unknown, so the daily-steps total
    /// divides by this. 1.0 = raw pass-through (default); the engine clamps ≥ 0.5.
    public var stepTicksPerStep: Double
    public init(weightKg: Double = 70.0, heightCm: Double = 170.0,
                age: Double = 30.0, sex: String = "nonbinary",
                stepTicksPerStep: Double = 1.0) {
        self.weightKg = weightKg; self.heightCm = heightCm
        self.age = age; self.sex = sex
        self.stepTicksPerStep = stepTicksPerStep
    }
}

/// A detected workout window. All intensity fields are APPROXIMATE.
public struct ExerciseSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let avgHR: Double
    public let peakHR: Int
    public let strain: Double?
    public let durationS: Double
    /// Edwards zone (0–5) time breakdown as % of HR samples; sums to 100.
    public let zoneTimePct: [Int: Double]
    /// Mean Karvonen %HRR over the bout, clamped [0, 100], or nil.
    public let avgHRRPct: Double?
    /// Effective HRmax used for zone math (bpm), or nil.
    public let hrmax: Double?
    /// "caller" | "observed" | "tanaka" | "unknown".
    public let hrmaxSource: String
    public let caloriesKcal: Double?
    public let caloriesKJ: Double?

    public init(start: Int, end: Int, avgHR: Double, peakHR: Int, strain: Double?,
                durationS: Double, zoneTimePct: [Int: Double], avgHRRPct: Double?,
                hrmax: Double?, hrmaxSource: String,
                caloriesKcal: Double?, caloriesKJ: Double?) {
        self.start = start; self.end = end; self.avgHR = avgHR; self.peakHR = peakHR
        self.strain = strain; self.durationS = durationS; self.zoneTimePct = zoneTimePct
        self.avgHRRPct = avgHRRPct; self.hrmax = hrmax; self.hrmaxSource = hrmaxSource
        self.caloriesKcal = caloriesKcal; self.caloriesKJ = caloriesKJ
    }
}

public enum WorkoutDetector {

    // MARK: - Constants (exercise.py)

    public static let minExerciseMin: Double = 5.0
    public static let hrMarginBPM: Double = 15.0
    public static let motionThreshold: Double = 0.20
    public static let motionSmoothS: Double = 10.0
    public static let mergeGapS: Double = 150.0
    public static let minIntensityZ2Plus: Double = 0.50
    public static let alignToleranceS: Double = 5.0
    public static let restingPercentile: Double = 10.0
    /// Second-pass bridge window (#303). Two adjacent active runs separated by a
    /// below-motion-threshold gap no longer than this are stitched into one workout
    /// — BUT ONLY while HR stays elevated across the gap (see `bridgeRuns`). A
    /// sustained endurance effort (e.g. a long bike ride) routinely dips below the
    /// motion gate for a few minutes — coasting a descent, a junction, a brief sensor
    /// dropout — without the athlete actually resting; `mergeGapS` (150 s) is too
    /// tight to ride through those, so the bout used to shatter into many sub-bouts,
    /// most of which then fell under `minExerciseMin` and vanished. A genuine rest
    /// between two separate workouts is gated out by the HR check, not by this window.
    public static let bridgeGapS: Double = 300.0

    // MARK: - Activity series (activity.py)

    public struct ActivityPoint: Equatable, Sendable {
        public let ts: Int
        public let intensity: Double
    }

    /// Per-record motion-intensity series: L2 magnitude of the gravity change vs
    /// the previous record. First row → 0. Empty input → []. (GravitySample always
    /// carries finite x/y/z, so no dropout sentinel is required here.)
    public static func activitySeries(_ gravity: [GravitySample]) -> [ActivityPoint] {
        if gravity.isEmpty { return [] }
        let rows = gravity.sorted { $0.ts < $1.ts }
        var series: [ActivityPoint] = []
        series.reserveCapacity(rows.count)
        var prev: GravitySample? = nil
        for (i, row) in rows.enumerated() {
            let intensity: Double
            if i == 0 { intensity = 0.0 }
            else if let p = prev {
                let dx = row.x - p.x, dy = row.y - p.y, dz = row.z - p.z
                intensity = (dx * dx + dy * dy + dz * dz).squareRoot()
            } else { intensity = 0.0 }
            series.append(ActivityPoint(ts: row.ts, intensity: intensity))
            prev = row
        }
        return series
    }

    // MARK: - Helpers

    /// Sorted (ts, bpm) pairs.
    static func cleanHR(_ hr: [HRSample]) -> [(ts: Int, bpm: Double)] {
        hr.map { (ts: $0.ts, bpm: Double($0.bpm)) }.sorted { $0.ts < $1.ts }
    }

    /// Day resting-HR baseline = nearest-rank RESTING_PERCENTILE of bpm values.
    static func deriveRestingHR(_ hrSeg: [(ts: Int, bpm: Double)]) -> Double {
        let bpms = hrSeg.map { $0.bpm }.sorted()
        precondition(!bpms.isEmpty, "deriveRestingHR called with empty segment")
        let rank = max(1, Int(ceil(restingPercentile / 100.0 * Double(bpms.count))))
        return bpms[rank - 1]
    }

    /// Value whose ts is nearest to `ts` within `tol` seconds, else nil. Ties go
    /// to the later timestamp (matches the Python <= behaviour).
    static func nearest(_ sortedTs: [Int], _ values: [Double], _ ts: Int, _ tol: Double) -> Double? {
        if sortedTs.isEmpty { return nil }
        // bisect_left
        var lo = 0, hi = sortedTs.count
        while lo < hi { let mid = (lo + hi) / 2; if sortedTs[mid] < ts { lo = mid + 1 } else { hi = mid } }
        let i = lo
        var bestV: Double? = nil
        var bestD = tol
        for j in [i - 1, i] where j >= 0 && j < sortedTs.count {
            let d = abs(Double(sortedTs[j] - ts))
            if d <= bestD { bestD = d; bestV = values[j] }
        }
        return bestV
    }

    /// Trailing rolling mean (over window_s) of intensities (all finite here).
    static func smoothedIntensity(_ motion: [ActivityPoint], windowS: Double) -> [Double] {
        let ts = motion.map { $0.ts }
        let raw = motion.map { $0.intensity.isFinite ? $0.intensity : 0.0 }
        var out: [Double] = []
        out.reserveCapacity(motion.count)
        var lo = 0
        var running = 0.0
        for i in 0..<motion.count {
            running += raw[i]
            while Double(ts[i] - ts[lo]) > windowS { running -= raw[lo]; lo += 1 }
            out.append(running / Double(i - lo + 1))
        }
        return out
    }

    /// Per-bout Edwards zone breakdown (%) + mean %HRR. APPROXIMATE.
    static func boutIntensity(_ hrSeries: [(ts: Int, bpm: Double)],
                              restingHR: Double, maxHR: Double) -> ([Int: Double], Double?) {
        if hrSeries.isEmpty || maxHR <= restingHR { return ([:], nil) }
        let hrReserve = maxHR - restingHR
        var zoneCounts = [Int: Int]()
        for z in 0...5 { zoneCounts[z] = 0 }
        var hrrVals: [Double] = []
        for r in hrSeries {
            let z = StrainScorer.zoneWeight(r.bpm, restingHR: restingHR, hrReserve: hrReserve)
            zoneCounts[z, default: 0] += 1
            hrrVals.append(StrainScorer.pctHRR(r.bpm, restingHR: restingHR, hrReserve: hrReserve))
        }
        let n = Double(hrSeries.count)
        var zonePct = [Int: Double]()
        for (z, c) in zoneCounts { zonePct[z] = ((Double(c) / n * 100.0) * 10).rounded() / 10 }
        let avgHRR = ((hrrVals.reduce(0, +) / n) * 10).rounded() / 10
        return (zonePct, avgHRR)
    }

    /// Second-pass merge over raw active runs (#303).
    ///
    /// Stitch run `i+1` onto the current span when the inter-run gap (start of the
    /// next minus end of the current) is ≤ `bridgeGapS` AND HR stays elevated across
    /// that gap — i.e. the athlete kept working through a brief motion lull rather
    /// than resting. "Elevated" = the mean of the HR samples strictly inside the gap
    /// is still above `hrFloor` (resting + HR_MARGIN_BPM). If the gap carries NO HR
    /// samples it is treated as a same-effort sensor dropout and bridged; a real rest
    /// always lands HR samples in the gap (the strap streams 1 Hz), so it fails the
    /// elevation test and the two workouts stay separate. Runs must arrive sorted by
    /// start (they do — built from a sorted timeline).
    static func bridgeRuns(_ runs: [(Int, Int)],
                           hrSeg: [(ts: Int, bpm: Double)],
                           hrFloor: Double) -> [(Int, Int)] {
        guard runs.count > 1 else { return runs }
        var merged: [(Int, Int)] = []
        var curStart = runs[0].0
        var curEnd = runs[0].1
        for next in runs.dropFirst() {
            let gap = Double(next.0 - curEnd)
            var bridge = false
            if gap <= bridgeGapS {
                // HR samples strictly between the two runs (the lull itself).
                let gapHR = hrSeg.filter { $0.ts > curEnd && $0.ts < next.0 }.map { $0.bpm }
                if gapHR.isEmpty {
                    bridge = true   // sensor dropout mid-effort → same workout
                } else {
                    let meanGapHR = gapHR.reduce(0, +) / Double(gapHR.count)
                    bridge = meanGapHR > hrFloor   // still working → same workout
                }
            }
            if bridge {
                curEnd = max(curEnd, next.1)
            } else {
                merged.append((curStart, curEnd))
                curStart = next.0
                curEnd = next.1
            }
        }
        merged.append((curStart, curEnd))
        return merged
    }

    /// #148: back-date a confirmed run's start over the warm-up. Motion leads HR at the onset of the
    /// first effort — cardiac warm-up climbs over minutes, so the HR-AND-motion gate clips the leading
    /// "moving but HR not yet elevated" stretch. Once a run has ALREADY QUALIFIED on its HR-elevated
    /// core, extend the start backward across contiguous above-`motionThreshold` samples, stopping at
    /// the first motion gap > `mergeGapS` (a real pause) or the series start. Same motion gate as
    /// detection — recovers the warm-up without inventing activity, and can't bridge a genuine rest.
    /// `coreStart` is an active-sample ts (so it exists in `motionTs`); `smooth` is index-aligned.
    static func backdatedStart(_ coreStart: Int, _ motionTs: [Int], _ smooth: [Double]) -> Int {
        var i = motionTs.firstIndex(where: { $0 >= coreStart }) ?? motionTs.count
        guard i < motionTs.count else { return coreStart }
        var start = coreStart
        var prevTs = motionTs[i]
        while i > 0 {
            i -= 1
            if smooth[i] <= motionThreshold { break }                    // motion dropped → warm-up start
            if Double(prevTs - motionTs[i]) > mergeGapS { break }        // real pause → stop
            start = motionTs[i]
            prevTs = motionTs[i]
        }
        return start
    }

    // MARK: - Public API

    /// Detect workouts from the 1 Hz HR + gravity store.
    ///
    /// - Parameters:
    ///   - hr: heart-rate stream (required; empty → []).
    ///   - gravity: gravity stream (required; empty → []).
    ///   - restingHR: day resting-HR baseline (bpm). nil → derived as the 10th
    ///     percentile of the day's HR.
    ///   - maxHR: HRmax (bpm). nil → estimated via StrainScorer.estimateHRmax.
    ///   - age: used only for the Tanaka fallback when maxHR is nil.
    ///   - profile: when provided, per-bout calories are estimated.
    public static func detect(hr: [HRSample],
                              gravity: [GravitySample],
                              restingHR: Double? = nil,
                              maxHR: Double? = nil,
                              age: Double? = nil,
                              profile: UserProfile? = nil) -> [ExerciseSession] {
        let hrSeg = cleanHR(hr)
        let motion = activitySeries(gravity)
        if hrSeg.isEmpty || motion.isEmpty { return [] }

        let restHR = restingHR ?? deriveRestingHR(hrSeg)
        let hrFloor = restHR + hrMarginBPM

        let effMaxHR: Double?
        let hrmaxSource: String
        if let m = maxHR {
            effMaxHR = m; hrmaxSource = "caller"
        } else {
            let (est, src) = StrainScorer.estimateHRmax(hrSeg.map { $0.bpm }, age: age)
            effMaxHR = est == 0.0 ? nil : est
            hrmaxSource = src
        }

        let hrTs = hrSeg.map { $0.ts }
        let hrBpm = hrSeg.map { $0.bpm }
        let smooth = smoothedIntensity(motion, windowS: motionSmoothS)
        let motionTs = motion.map { $0.ts }

        // Walk the gravity timeline; flag samples where BOTH gates hold.
        var activeTs: [Int] = []
        for (p, inten) in zip(motion, smooth) {
            if inten <= motionThreshold { continue }
            guard let bpm = nearest(hrTs, hrBpm, p.ts, alignToleranceS), bpm > hrFloor else { continue }
            activeTs.append(p.ts)
        }
        if activeTs.isEmpty { return [] }

        // Group contiguous active samples into runs, merging gaps < MERGE_GAP_S.
        var runs: [(Int, Int)] = []
        var runStart = activeTs[0]
        var prev = activeTs[0]
        for ts in activeTs.dropFirst() {
            if Double(ts - prev) > mergeGapS { runs.append((runStart, prev)); runStart = ts }
            prev = ts
        }
        runs.append((runStart, prev))

        // Second pass (#303): bridge adjacent runs across a brief, still-elevated-HR
        // lull so a sustained effort isn't shattered by coasting / junctions / sensor
        // gaps. Runs over a genuine rest (HR falls to resting) are NOT bridged.
        runs = bridgeRuns(runs, hrSeg: hrSeg, hrFloor: hrFloor)

        let minDurS = minExerciseMin * 60.0
        var sessions: [ExerciseSession] = []
        for (idx, run) in runs.enumerated() {
            let (start, end) = run
            // Onset latency tolerance equal to the smoothing window.
            if Double(end - start) < minDurS - motionSmoothS { continue }
            // Qualify on the HR-elevated CORE (unchanged gates) so the warm-up's low intensity
            // can't dilute a real workout below the zone-2 bar and drop it (#148).
            let core = hrSeg.filter { $0.ts >= start && $0.ts <= end }
            if core.isEmpty { continue }

            var zonePct: [Int: Double] = [:]
            var avgHRR: Double? = nil
            if let m = effMaxHR, m > restHR {
                (zonePct, avgHRR) = boutIntensity(core, restingHR: restHR, maxHR: m)
            }

            // Intensity qualification: require ≥ MIN_INTENSITY_Z2PLUS in zone 2+.
            if !zonePct.isEmpty {
                let z2plus = (2...5).reduce(0.0) { $0 + (zonePct[$1] ?? 0.0) } / 100.0
                if z2plus < minIntensityZ2Plus { continue }
            }

            // Qualified → back-date the start over the warm-up and report stats on the full window (#148).
            // Never back-date past the previous run's end: a continuous-motion stretch whose HR dipped to
            // resting BETWEEN two efforts (so bridgeRuns kept them separate) must not overlap the earlier one.
            let floor = idx > 0 ? runs[idx - 1].1 + 1 : Int.min
            let effStart = max(Self.backdatedStart(start, motionTs, smooth), floor)
            let window = hrSeg.filter { $0.ts >= effStart && $0.ts <= end }
            if window.isEmpty { continue }
            let bpms = window.map { $0.bpm }
            let hrSamples = window.map { HRSample(ts: $0.ts, bpm: Int($0.bpm.rounded())) }

            var kcal: Double? = nil
            var kj: Double? = nil
            if let profile = profile {
                let (k, j) = Calories.estimateBoutCalories(hrSamples, profile: profile,
                                                           hrmax: effMaxHR, restingHR: restHR)
                kcal = k; kj = j
            }

            guard !bpms.isEmpty else { continue }   // skip a degenerate bout with no HR samples
            let avg = bpms.reduce(0, +) / Double(bpms.count)
            let peak = Int(bpms.max()!.rounded())
            let strain = StrainScorer.strain(hrSamples, maxHR: effMaxHR, restingHR: restHR)

            sessions.append(ExerciseSession(
                start: effStart, end: end, avgHR: avg, peakHR: peak, strain: strain,
                durationS: Double(end - effStart), zoneTimePct: zonePct, avgHRRPct: avgHRR,
                hrmax: effMaxHR, hrmaxSource: hrmaxSource, caloriesKcal: kcal, caloriesKJ: kj))
        }
        return sessions
    }

    /// #510: backfill ONLY the avgHr/maxHr/energyKcal/strain fields `real` doesn't already have, from a
    /// detected bout's own computed values — never touching a field that's already present, whether
    /// typed by the user, imported, or filled by an earlier pass. `real` unchanged (`==`) means it
    /// already had everything, so the caller can tell whether a write is actually needed. Kotlin twin
    /// IntelligenceEngine.backfillWorkoutFromDetectedBout.
    public static func backfillWorkout(_ real: WorkoutRow, avgBpm: Int, peakHR: Int, caloriesKcal: Double?, strain: Double?) -> WorkoutRow {
        WorkoutRow(
            startTs: real.startTs, endTs: real.endTs, sport: real.sport, source: real.source,
            durationS: real.durationS,
            energyKcal: real.energyKcal ?? caloriesKcal,
            avgHr: real.avgHr ?? avgBpm,
            maxHr: real.maxHr ?? peakHR,
            strain: real.strain ?? strain,
            distanceM: real.distanceM, zonesJSON: real.zonesJSON, notes: real.notes)
    }
}

// MARK: - Calories (calories.py)

/// HR-based calorie estimation (Keytel 2005 active + revised Harris–Benedict BMR).
/// APPROXIMATE — not laboratory calorimetry, not medical advice.
public enum Calories {

    struct Coeffs {
        let restingAlpha: Double
        let restingWeight: Double
        let restingHeight: Double  // applied to height in METRES
        let restingAge: Double
        // Keytel 2005 base (fitness-blind) active model: EE(kJ/min) = alpha + hr·HR + wt·W + age·A.
        let workoutHR: Double
        let workoutWeight: Double
        let workoutAge: Double
        let workoutAlpha: Double
        // Keytel 2005 fitness-ADJUSTED active model, which reads VO2max and is the more accurate
        // form the authors published: EE(kJ/min) = fitAlpha + fitHR·HR + fitVO2·VO2max + fitWeight·W
        // + fitAge·A. Used only when a resting HR is known (so a Uth VO2max can be derived); otherwise
        // the base workout* model above is used, unchanged. (Keytel et al. 2005, J. Sports Sci. 23(3).)
        let fitHR: Double
        let fitVO2: Double
        let fitWeight: Double
        let fitAge: Double
        let fitAlpha: Double
    }

    static let male = Coeffs(restingAlpha: 88.362, restingWeight: 13.397, restingHeight: 479.9,
                             restingAge: 5.677, workoutHR: 0.6309, workoutWeight: 0.1988,
                             workoutAge: 0.2017, workoutAlpha: -55.0969,
                             fitHR: 0.634, fitVO2: 0.404, fitWeight: 0.394, fitAge: 0.271,
                             fitAlpha: -95.7735)
    static let female = Coeffs(restingAlpha: 447.593, restingWeight: 9.247, restingHeight: 309.8,
                               restingAge: 4.33, workoutHR: 0.4472, workoutWeight: -0.1263,
                               workoutAge: 0.0740, workoutAlpha: -20.4022,
                               fitHR: 0.450, fitVO2: 0.380, fitWeight: 0.103, fitAge: 0.274,
                               fitAlpha: -59.3954)
    // Nonbinary = the male/female midpoint, the same convention the base workout* coeffs use.
    static let nonbinary = Coeffs(restingAlpha: 267.9775, restingWeight: 11.322, restingHeight: 394.85,
                                  restingAge: 5.0035, workoutHR: 0.53905, workoutWeight: 0.03625,
                                  workoutAge: 0.13785, workoutAlpha: -37.74955,
                                  fitHR: 0.542, fitVO2: 0.392, fitWeight: 0.2485, fitAge: 0.2725,
                                  fitAlpha: -77.58445)

    static let activeHRRFraction = 0.30
    /// Whole-day active gate (`estimateDayCalories` only). The Keytel 2005 equation is
    /// validated for genuine EXERCISE HR; applying it to ordinary low-intensity daytime
    /// HR (walking, stairs, standing — typically ~95–110 bpm) across the WHOLE day credits
    /// the full gross-exercise rate to every elevated second and over-counts by ~1000+ kcal
    /// (community "Calories too high"). The bout path keeps the 0.30 detector fraction —
    /// Keytel is appropriate for a real detected/manual workout — but the day path raises
    /// the gate to 50% HRR so the gross rate only applies at genuine exercise-level HR.
    static let dayActiveHRRFraction = 0.50
    static let workoutDivisor = 251.04  // 60 s/min × 4.184 kJ/kcal

    static func resolveCoeffs(_ sex: String) -> Coeffs {
        switch sex.lowercased() {
        case "male": return male
        case "female": return female
        case "nonbinary": return nonbinary
        default: return nonbinary
        }
    }

    static func restingKcalPerS(_ c: Coeffs, weightKg: Double, heightCm: Double, age: Double) -> Double {
        let heightM = heightCm / 100.0
        let bmr = c.restingAlpha + c.restingWeight * weightKg + c.restingHeight * heightM - c.restingAge * age
        return max(0.0, bmr) / 86_400.0
    }

    /// Uth–Sørensen VO2max estimate (ml·kg⁻¹·min⁻¹) ≈ 15.3 · HRmax / HRrest. Returns nil when no
    /// usable resting HR — the caller then keeps the base (fitness-blind) Keytel model, so a strap
    /// with no resting baseline is scored exactly as before. A function of HRmax + resting HR ONLY,
    /// so every call site resolves it locally and day derivation stays deterministic (no cross-day
    /// dependency). (Uth et al. 2004, Eur. J. Appl. Physiol. 91.)
    static func vo2maxFor(hrmax: Double, restingHR: Double?) -> Double? {
        guard let rhr = restingHR, rhr > 0, hrmax > 0 else { return nil }
        return 15.3 * hrmax / rhr
    }

    /// Active energy rate (kcal/s). With `vo2max` present, uses the Keytel 2005 fitness-ADJUSTED
    /// equation (personalizes beyond age/weight/sex); with nil, the base fitness-blind Keytel model,
    /// byte-identical to before. HR is capped at HRmax in both, as the base model always did.
    static func activeKcalPerS(_ c: Coeffs, hr: Double, hrmax: Double, weightKg: Double, age: Double,
                               vo2max: Double? = nil) -> Double {
        let eeKjMin: Double
        if let vo2 = vo2max {
            eeKjMin = c.fitHR * min(hr, hrmax) + c.fitVO2 * vo2 + c.fitWeight * weightKg
                + c.fitAge * age + c.fitAlpha
        } else {
            eeKjMin = c.workoutHR * min(hr, hrmax) + c.workoutWeight * weightKg
                + c.workoutAge * age + c.workoutAlpha
        }
        return max(0.0, eeKjMin) / workoutDivisor
    }

    /// Estimate (kcal, kJ) for a workout bout. Each sample is weighted by the ELAPSED time
    /// to the next sample (capped at `WorkoutDetector.mergeGapS`), so a sparse, non-1 Hz
    /// stream is counted over real seconds rather than undercounted as one second per sample.
    ///
    /// This elapsed-time weighting is justified ONLY for the bout path: a bout's intra-sample
    /// gaps are motion-gated and ≤ mergeGapS (150 s) by construction, so each gap really is
    /// continuous active/resting time. The whole-day estimator deliberately does NOT use it
    /// (see `estimateDayCalories`) — its raw, non-gap-filled day HR union would otherwise
    /// credit up to 150 s of active burn to a single isolated elevated sample.
    public static func estimateBoutCalories(_ hrSamples: [HRSample],
                                            profile: UserProfile,
                                            hrmax: Double?,
                                            restingHR: Double?) -> (Double, Double) {
        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let coeffs = resolveCoeffs(profile.sex)

        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        let activeThreshold = effResting + activeHRRFraction * (effHRmax - effResting)

        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)
        // Fitness anchor (Uth VO2max) when a resting HR is known → the Keytel fitness-adjusted rate;
        // nil restingHR → base model, unchanged. Computed once (constant across the bout).
        let vo2max = vo2maxFor(hrmax: effHRmax, restingHR: restingHR)

        // Weight each sample by the ACTUAL elapsed time to the next sample, not a flat 1 s.
        // restingRate / activeKcalPerS are per-SECOND rates, so summing one per sample only
        // equals real energy when the stream is exactly 1 Hz. A sparse WHOOP 5/MG bout can
        // run far below 1 sample/s, which previously undercounted energy roughly in proportion
        // to the coverage gap (calories collapsing toward ~1 kcal, #137). Each interval is
        // capped at mergeGapS (150 s) — the detector's own "still continuous, not resting"
        // threshold — so a brief dropout is fully counted but a wear gap can't inflate one
        // reading. At a steady 1 Hz every interval is ~1 s: behaviour is unchanged.
        let ordered = hrSamples.sorted { $0.ts < $1.ts }
        var totalKcal = 0.0
        for i in ordered.indices {
            let bpm = Double(ordered[i].bpm)
            let dur: Double
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - ordered[i].ts)
                dur = gap > 0 ? min(gap, WorkoutDetector.mergeGapS) : 1.0
            } else {
                dur = 1.0   // last sample carries one representative second
            }
            if bpm < activeThreshold {
                totalKcal += restingRate * dur
            } else {
                totalKcal += activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax, weightKg: weightKg, age: age, vo2max: vo2max) * dur
            }
        }
        return (totalKcal, totalKcal * 4.184)
    }

    /// APPROXIMATE whole-day total energy estimate (kcal) from the full day's HR samples.
    /// Per-second model: below the day activeThreshold (resting + `dayActiveHRRFraction`
    /// HRR) a sample burns the resting BMR rate, above it the Keytel active rate — FLOORED
    /// at the resting rate so a day-second can never be credited LESS than resting metabolism.
    ///
    /// The day path uses `dayActiveHRRFraction` (50% HRR), NOT the 30% the bout detector uses
    /// (`activeHRRFraction`). The Keytel 2005 equation is validated for genuine EXERCISE HR;
    /// at 30% the gate falls to ~94 bpm for a typical user, so ordinary low-intensity daytime
    /// HR (walking, stairs, standing) credited the full gross-exercise rate across the whole
    /// day and over-counted by ~1000+ kcal (community "Calories too high"). The 50% gate keeps
    /// the gross rate for genuine exercise-level HR only; the bout path is UNCHANGED — Keytel
    /// is appropriate there, on a real detected/manual workout.
    ///
    /// Each HR sample = ONE second of data (1 Hz strap), counted flat — this path deliberately
    /// does NOT use the bout estimator's elapsed-time-per-sample weighting. The day feed is a
    /// raw, non-gap-filled union of the day's HR (it is NOT motion-gated the way a bout is), so
    /// capping each gap at mergeGapS (150 s) would credit up to ~150 s of active burn to a
    /// single isolated elevated sample — over-counting by ~150x on gappy days. Flat
    /// one-second-per-sample is the conservative, stable choice for the day total.
    /// This is an on-device estimate from heart rate alone — NOT laboratory calorimetry, NOT
    /// Apple/WHOOP cloud parity, NOT medical advice. Returns total estimated kcal (>= 0).
    public static func estimateDayCalories(_ hrSamples: [HRSample],
                                           profile: UserProfile,
                                           hrmax: Double?,
                                           restingHR: Double?) -> Double {
        if hrSamples.isEmpty { return 0.0 }

        let weightKg = profile.weightKg > 0 ? profile.weightKg : 70.0
        let heightCm = profile.heightCm > 0 ? profile.heightCm : 170.0
        let age = profile.age > 0 ? profile.age : 30.0
        let coeffs = resolveCoeffs(profile.sex)

        let effHRmax = hrmax ?? 220.0
        let effResting = restingHR ?? 60.0
        // Day-path gate is HIGHER than the bout detector's: only genuine exercise-level HR
        // gets the Keytel gross rate (see `dayActiveHRRFraction`).
        let activeThreshold = effResting + dayActiveHRRFraction * (effHRmax - effResting)

        let restingRate = restingKcalPerS(coeffs, weightKg: weightKg, heightCm: heightCm, age: age)
        // Fitness anchor (Uth VO2max) when a resting HR is known → Keytel fitness-adjusted rate; nil
        // restingHR → base model, unchanged. Constant across the day.
        let vo2max = vo2maxFor(hrmax: effHRmax, restingHR: restingHR)

        var totalKcal = 0.0
        for s in hrSamples {
            let bpm = Double(s.bpm)
            if bpm < activeThreshold {
                totalKcal += restingRate
            } else {
                // Floor the active rate at the resting BMR rate: a worn day-second never burns
                // LESS than resting metabolism, even where the Keytel value dips low for some
                // profiles just above the gate.
                let active = activeKcalPerS(coeffs, hr: bpm, hrmax: effHRmax, weightKg: weightKg, age: age, vo2max: vo2max)
                totalKcal += max(restingRate, active)
            }
        }
        return totalKcal
    }
}
