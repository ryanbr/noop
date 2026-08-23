import Foundation
import WhoopProtocol

/// Re-score a manual workout's HR-derived metrics (avg/peak HR, strain, calories) from the HR samples
/// now available for its time window.
///
/// Why: a manually-started workout is scored at *save* time from the live HR captured during the
/// session. On a WHOOP 5.0/MG the live stream is sparse and intermittent, so only a handful of samples
/// land in the window — calories collapse toward ~1 kcal, the average is off, and strain is empty
/// (#137). The strap *does* bank its own HR to flash and offloads it on the next sync; once that denser
/// HR covers the workout's window, this recomputes the workout from it.
///
/// Pure + deterministic (no store, no I/O) so it's unit-tested directly. The caller (the post-sync
/// scoring pass) decides which workouts to feed it — under-scored `manual` ones — reads the window's
/// HR, and only persists when the result is a genuine improvement. The scoring formulas mirror the
/// app's `endWorkout` exactly (same `StrainScorer` + `Calories.estimateBoutCalories`).
public enum ManualWorkoutRescore {

    public struct Scored: Equatable {
        public let avgHr: Int
        public let maxHr: Int
        public let strain: Double?
        public let kcal: Double?
        public init(avgHr: Int, maxHr: Int, strain: Double?, kcal: Double?) {
            self.avgHr = avgHr; self.maxHr = maxHr; self.strain = strain; self.kcal = kcal
        }
    }

    /// At/under this many kcal a manual workout looks like the #137 symptom (no/negligible energy).
    public static let underScoredKcalThreshold = 5.0
    /// A rescore must beat the stored calories by at least this much to be worth persisting — so a
    /// still-sparse window (recompute ≈ current) is a no-op and the pass is idempotent.
    public static let improvementMarginKcal = 1.0

    /// Does this manual workout currently look under-scored (missing/negligible calories)? The gate the
    /// post-sync pass uses to decide whether to attempt a rescore at all — so well-scored workouts
    /// (a 4.0's dense live HR) are never touched.
    public static func looksUnderScored(currentKcal: Double?) -> Bool {
        (currentKcal ?? 0) <= underScoredKcalThreshold
    }

    /// Recompute avg/peak HR, strain and calories from `windowSamples` (the HR now stored for the
    /// workout's [start, end]). Returns nil when there are too few samples to score meaningfully — i.e.
    /// nothing better than what we already had.
    /// `restingHR` is the wearer's MEASURED resting HR (#950): the strain %HRR denominator needs it, and the
    /// calories model's active-vs-resting threshold sits at resting + 30% HRR, and both used to silently fall back to a hardcoded 60 here while the
    /// DAY total was scored against the measured value — so a fit wearer's workout was systematically
    /// under-scored relative to the very day it sat in. nil keeps the old default (a cold start with no
    /// measured resting yet), so existing callers are byte-identical until they thread one.
    public static func scored(windowSamples: [HRSample], profile: UserProfile, hrMax: Double,
                              restingHR: Double? = nil,
                              // #1545: see WorkoutDetector.detect — Edwards by default, threaded by the app.
                              effortMethod: StrainScorer.Method = .edwards) -> Scored? {
        guard windowSamples.count >= 2 else { return nil }
        let bpms = windowSamples.map(\.bpm)
        let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        let peak = bpms.max() ?? 0
        let strain = StrainScorer.strain(windowSamples, maxHR: hrMax,
                                         restingHR: restingHR ?? StrainScorer.defaultRestingHR,
                                         method: effortMethod, sex: profile.sex)
        let kcalRaw = Calories.estimateBoutCalories(windowSamples, profile: profile,
                                                    hrmax: hrMax, restingHR: restingHR).0
        return Scored(avgHr: avg, maxHr: peak, strain: strain, kcal: kcalRaw > 0 ? kcalRaw : nil)
    }

    /// Is `scored` a worthwhile improvement over the stored row? Two ways to qualify:
    ///  - Strictly more energy (denser HR ⇒ higher), so a sparse-window recompute that lands ≈ the
    ///    current value is rejected, keeping the pass idempotent and incapable of *lowering* a workout's
    ///    numbers. This is the default and the ONLY path for a plain 2-arg call.
    ///  - A strain-only fill (opt-in via `allowStrainOnlyFill`): the row has NO strain (`currentStrain ==
    ///    nil`) yet the recompute produced one. This is the merged-row case (#137/merge), a merged
    ///    workout's kcal is the SUM of its inputs, so it never looks under-scored, yet its strain is nil
    ///    forever. When strain is the only gain we still persist so Effort renders, without lowering the
    ///    summed kcal (the caller keeps the existing kcal). Gated so a normal rescore's contract is
    ///    unchanged: without the flag, only a strict kcal improvement counts.
    public static func improves(_ scored: Scored, over currentKcal: Double?,
                                currentStrain: Double? = nil, allowStrainOnlyFill: Bool = false) -> Bool {
        if let newK = scored.kcal, newK > (currentKcal ?? 0) + improvementMarginKcal { return true }
        // Strain-only improvement: fill a missing strain even when kcal doesn't beat the stored sum.
        return allowStrainOnlyFill && currentStrain == nil && scored.strain != nil
    }
}
