import Foundation
import WhoopStore

// The session state machine: the heart of the Lift Log.
//
// One action advances everything — warm-up → set → rest → set → … → cool-down → save. It is kept
// PURE (no timers, no store, no SwiftUI) for two reasons: it is the piece most likely to be wrong in
// a way that costs someone a logged set, and it is the only part of the feature that can be tested
// without a strap, a database or a simulator.
//
// TIME ENTERS ONLY AS A PARAMETER. `advance(now:)` is told what time it is rather than reading the
// clock, so a test can drive a whole session through a known timeline. The rest period is stored as
// an ABSOLUTE end instant, never a decrementing counter: `IntervalTimerView` decrements and loses
// time whenever the phone suspends, and a rest timer that quietly runs long is worse than none.
//
// REST NEVER AUTO-ADVANCES. When the countdown reaches zero the stage stays `.resting` and waits for
// the user. That is a deliberate product decision: a timer that starts logging a set while you are
// still racking the bar attributes time to work that was not work.

/// One planned exercise line, flattened from a program (or built freehand) for the session to run.
struct LiftPlanItem: Equatable {
    var exercise: String
    var primaryMuscle: LiftMuscle?
    var secondaryMuscles: [LiftMuscle]
    /// How many working sets are planned. Always ≥ 1 — a line with no target still gets one set,
    /// because a plan that schedules zero sets of an exercise cannot be tapped through at all.
    var targetSets: Int
    /// Intended rest after each set, in seconds.
    var restSec: Int
    var targetRepsLow: Int?
    var targetRepsHigh: Int?
    var targetRpe: Double?
    /// The weight the program plans for this line, in kilograms. Seeds the entry box so the common
    /// case is a glance and a tap rather than typing.
    var targetWeightKg: Double?
    var note: String?

    /// The rest period used when a program line does not specify one. Two minutes is the middle of
    /// the range the hypertrophy literature uses for compound work, and it is only a starting value:
    /// what is actually rested is measured from the taps, not assumed from this.
    static let defaultRestSec = 120

    init(exercise: String,
         primaryMuscle: LiftMuscle? = nil,
         secondaryMuscles: [LiftMuscle] = [],
         targetSets: Int? = nil,
         restSec: Int? = nil,
         targetRepsLow: Int? = nil,
         targetRepsHigh: Int? = nil,
         targetRpe: Double? = nil,
         targetWeightKg: Double? = nil,
         note: String? = nil) {
        self.exercise = exercise
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = secondaryMuscles
        self.targetSets = max(1, targetSets ?? 1)
        self.restSec = max(0, restSec ?? LiftPlanItem.defaultRestSec)
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetRpe = targetRpe
        self.targetWeightKg = targetWeightKg
        self.note = note
    }
}

/// One set as actually performed. Becomes a `LiftSetRow` on save; kept separate so the engine has no
/// opinion about ids or device scoping.
struct LiftRecordedSet: Equatable {
    var exerciseIndex: Int
    /// 1-based within its exercise, so "set 3 of 4" survives into the stored row.
    var setIndex: Int
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    var isWarmup: Bool
    var startTs: Int
    var endTs: Int
    /// Rest actually taken after this set, filled in when the rest ends. Nil for the final set (no
    /// rest follows it) or a set whose rest is still running.
    var restSec: Int?
}

struct LiftSessionEngine: Equatable {

    enum Stage: Equatable {
        /// Before the first set — the warm-up, derived from timestamps rather than stored as a flag.
        case warmup
        /// Performing a set. `set` is 1-based within the exercise.
        case working(item: Int, set: Int)
        /// Resting after (item, set). `endsAt` is an absolute unix second.
        case resting(item: Int, set: Int, endsAt: Int)
        /// After the last set — the cool-down.
        case cooldown
        /// Tapped through the cool-down; ready to save.
        case finished
    }

    let plan: [LiftPlanItem]
    /// When the session began (unix seconds) — the start of the warm-up.
    let startTs: Int
    private(set) var stage: Stage
    private(set) var sets: [LiftRecordedSet]
    /// When the CURRENT stage began, so a set's duration is measurable.
    private(set) var stageStartedAt: Int

    /// Undo stack. Whole-state snapshots rather than inverse operations: a gym is a bad place to be
    /// one tap ahead of yourself, and restoring a snapshot cannot get the arithmetic wrong the way a
    /// hand-written inverse can.
    private var history: [Snapshot] = []

    private struct Snapshot: Equatable {
        var stage: Stage
        var sets: [LiftRecordedSet]
        var stageStartedAt: Int
    }

    init(plan: [LiftPlanItem], startTs: Int) {
        self.plan = plan
        self.startTs = startTs
        self.stage = plan.isEmpty ? .cooldown : .warmup
        self.sets = []
        self.stageStartedAt = startTs
    }

    /// Rebuild a session that was interrupted — see `LiftSessionPersistence`.
    ///
    /// The undo history is deliberately NOT restored: it is a within-sitting convenience, and an undo
    /// stack that survives a relaunch invites someone to reach back past a save boundary into state
    /// the store has already been told about.
    init(restoring plan: [LiftPlanItem], startTs: Int, stage: Stage,
         sets: [LiftRecordedSet], stageStartedAt: Int) {
        self.plan = plan
        self.startTs = startTs
        self.stage = stage
        self.sets = sets
        self.stageStartedAt = stageStartedAt
    }

    // MARK: - Queries the UI needs

    var isFinished: Bool { stage == .finished }
    var canUndo: Bool { !history.isEmpty }

    /// The exercise currently being worked or rested from, if any.
    var currentItem: LiftPlanItem? {
        switch stage {
        case .working(let i, _), .resting(let i, _, _): return plan.indices.contains(i) ? plan[i] : nil
        case .warmup, .cooldown, .finished: return nil
        }
    }

    /// Seconds left in the current rest, floored at zero. Nil when not resting.
    ///
    /// Floored rather than allowed to go negative so the UI shows "0:00" and waits, which is what a
    /// rest that has run over actually means — the user has not tapped yet.
    func restRemaining(now: Int) -> Int? {
        guard case .resting(_, _, let endsAt) = stage else { return nil }
        return max(0, endsAt - now)
    }

    /// Total working sets planned across the session, for a progress read-out.
    var plannedWorkingSets: Int { plan.reduce(0) { $0 + $1.targetSets } }

    /// Working sets recorded so far (warm-ups excluded, matching how volume and set counts treat them).
    var completedWorkingSets: Int { sets.filter { !$0.isWarmup }.count }

    // MARK: - The one action

    /// Advance the machine.
    ///
    /// Deliberately takes NO set values. What was lifted is entered AFTERWARDS, during the rest that
    /// follows (see `updateLastSet`) — you cannot type a weight while the bar is still in your hands,
    /// and asking for it mid-set means either stopping to type or guessing later. The set is recorded
    /// the instant you finish it, with its timing; the numbers are filled in while you recover.
    mutating func advance(now: Int) {
        history.append(Snapshot(stage: stage, sets: sets, stageStartedAt: stageStartedAt))

        switch stage {
        case .warmup:
            // The warm-up ends and the first set begins.
            stage = plan.isEmpty ? .cooldown : .working(item: 0, set: 1)

        case .working(let i, let s):
            // Close out the set that was being performed — timing now, numbers during the rest.
            sets.append(LiftRecordedSet(
                exerciseIndex: i, setIndex: s,
                weightKg: nil, reps: nil, rpe: nil, isWarmup: false,
                startTs: stageStartedAt, endTs: now, restSec: nil))
            // No rest after the very last set of the very last exercise — that is the cool-down.
            if isLastSetOfSession(item: i, set: s) {
                stage = .cooldown
            } else {
                let rest = plan.indices.contains(i) ? plan[i].restSec : LiftPlanItem.defaultRestSec
                stage = .resting(item: i, set: s, endsAt: now + rest)
            }

        case .resting(let i, let s, _):
            // Record what was ACTUALLY rested, not what was planned — this is the figure the
            // work-vs-rest split is built from, and it is the one thing only the taps can know.
            if let last = sets.indices.last {
                sets[last].restSec = max(0, now - stageStartedAt)
            }
            if s < setsPlanned(for: i) {
                stage = .working(item: i, set: s + 1)
            } else {
                stage = .working(item: i + 1, set: 1)
            }

        case .cooldown:
            stage = .finished

        case .finished:
            // Terminal. Drop the snapshot we just pushed so a stray tap cannot fill the undo stack
            // with no-ops.
            history.removeLast()
            return
        }
        stageStartedAt = now
    }

    /// Fill in what the set just finished actually was. Called while resting (or during the
    /// cool-down, for the final set, which no rest follows).
    ///
    /// Editing rather than appending, so typing a weight can never create a phantom set — and so the
    /// user can keep correcting it for the whole rest period without anything being double-counted.
    /// No-op when no set has been recorded yet.
    mutating func updateLastSet(weightKg: Double?, reps: Int?, rpe: Double?, isWarmup: Bool) {
        guard let last = sets.indices.last else { return }
        sets[last].weightKg = weightKg
        sets[last].reps = reps
        sets[last].rpe = rpe
        sets[last].isWarmup = isWarmup
    }

    /// The set awaiting its numbers — the one just performed, while resting or cooling down. Nil in
    /// any stage where there is nothing to fill in.
    var setAwaitingEntry: LiftRecordedSet? {
        switch stage {
        case .resting, .cooldown: return sets.last
        case .warmup, .working, .finished: return nil
        }
    }

    /// Undo the last advance. Restores the whole prior state, including a set that was recorded.
    mutating func undo() {
        guard let previous = history.popLast() else { return }
        stage = previous.stage
        sets = previous.sets
        stageStartedAt = previous.stageStartedAt
    }

    // MARK: - Plan arithmetic

    private func setsPlanned(for item: Int) -> Int {
        plan.indices.contains(item) ? plan[item].targetSets : 0
    }

    private func isLastSetOfSession(item: Int, set: Int) -> Bool {
        item >= plan.count - 1 && set >= setsPlanned(for: item)
    }
}
