import Foundation
import WhoopStore

// The session state machine: the heart of the Lift Log.
//
// A GYM IS NOT A QUEUE. The first version walked the plan strictly in order, one set at a time, and
// the first real session killed that: when a machine is occupied you move on and come back. So the
// plan is a SHEET of slots — every set of every exercise, all visible — and any pending slot can be
// started at any time. Order is a suggestion the session follows by default, not a rail.
//
// PURE (no timers, no store, no SwiftUI): it is the piece most likely to be wrong in a way that
// costs someone a logged set, and the only part testable with no strap, no database, no simulator.
//
// TIME ENTERS ONLY AS A PARAMETER, so a test can drive a whole session through a known timeline.
// Rest is an ABSOLUTE end instant, never a decrementing counter — a phone that sleeps through a rest
// must wake up telling the truth.
//
// THERE IS NO COOL-DOWN STAGE. Warm-up is the time before the first set and cool-down the time after
// the last; both fall out of the timestamps, so neither needs a stage of its own. The session ends
// when the user says it does.

/// One set of one exercise — a position on the sheet. `setIndex` is 1-based within its exercise.
struct LiftSlot: Hashable {
    var exerciseIndex: Int
    var setIndex: Int
}

/// One planned exercise line, flattened from a program for the session to run.
struct LiftPlanItem: Equatable {
    var exercise: String
    var primaryMuscle: LiftMuscle?
    var secondaryMuscles: [LiftMuscle]
    /// Planned working sets. Always >= 1 — a line scheduling zero sets could not be tapped through.
    var targetSets: Int
    /// Intended rest after each set, in seconds.
    var restSec: Int
    var targetRepsLow: Int?
    var targetRepsHigh: Int?
    var targetRpe: Double?
    /// The weight the program plans, in kilograms.
    var targetWeightKg: Double?
    var note: String?

    /// Rest used when a program line does not specify one. Two minutes sits in the middle of the
    /// range the hypertrophy literature uses for compound work, and is only a starting value: what
    /// is actually rested is measured from the taps.
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

/// One set as actually performed.
struct LiftRecordedSet: Equatable {
    var exerciseIndex: Int
    var setIndex: Int
    var weightKg: Double?
    var reps: Int?
    var rpe: Double?
    var isWarmup: Bool
    var startTs: Int
    var endTs: Int
    /// Rest actually taken after this set. Nil while the rest is still running, or when the user
    /// moved on without resting.
    var restSec: Int?

    var slot: LiftSlot { LiftSlot(exerciseIndex: exerciseIndex, setIndex: setIndex) }
}

/// What a set records when it is completed without anything typed into it.
///
/// Only weight and reps. RPE is deliberately absent — see `carry(for:lastSession:)`.
struct LiftSetCarry: Equatable {
    var weightKg: Double?
    var reps: Int?

    static let none = LiftSetCarry(weightKg: nil, reps: nil)
}

struct LiftSessionEngine: Equatable {

    enum Stage: Equatable {
        /// Before the first set — the warm-up.
        case warmup
        /// Performing a set.
        case working(LiftSlot)
        /// Resting after a set. `endsAt` is an absolute unix second.
        case resting(LiftSlot, endsAt: Int)
        /// Ended; ready to save.
        case finished
    }

    let plan: [LiftPlanItem]
    /// When the session began (unix seconds).
    let startTs: Int
    private(set) var stage: Stage
    /// Completed sets in COMPLETION order — which is the order they happened, not the plan's order,
    /// and is what `ord` is written from.
    private(set) var sets: [LiftRecordedSet]
    /// When the current stage began, so a set's duration is measurable.
    private(set) var stageStartedAt: Int

    /// Undo stack: whole-state snapshots rather than inverse operations. A gym is a bad place to be
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
        self.stage = .warmup
        self.sets = []
        self.stageStartedAt = startTs
    }

    /// Rebuild an interrupted session — see `LiftSessionPersistence`.
    ///
    /// The undo history is deliberately NOT restored: it is a within-sitting convenience, and a
    /// stack that survives a relaunch invites reaching back past a save boundary.
    init(restoring plan: [LiftPlanItem], startTs: Int, stage: Stage,
         sets: [LiftRecordedSet], stageStartedAt: Int) {
        self.plan = plan
        self.startTs = startTs
        self.stage = stage
        self.sets = sets
        self.stageStartedAt = stageStartedAt
    }

    // MARK: - The sheet

    /// Every slot of one exercise, in order — the rows the sheet draws.
    func slots(forExercise index: Int) -> [LiftSlot] {
        guard plan.indices.contains(index) else { return [] }
        return (1...plan[index].targetSets).map { LiftSlot(exerciseIndex: index, setIndex: $0) }
    }

    /// Every slot in the whole session, in plan order.
    var allSlots: [LiftSlot] { plan.indices.flatMap { slots(forExercise: $0) } }

    func recordedSet(for slot: LiftSlot) -> LiftRecordedSet? {
        sets.first { $0.slot == slot }
    }

    func isCompleted(_ slot: LiftSlot) -> Bool { recordedSet(for: slot) != nil }

    /// The slot being worked or rested from.
    var currentSlot: LiftSlot? {
        switch stage {
        case .working(let s): return s
        case .resting(let s, _): return s
        case .warmup, .finished: return nil
        }
    }

    /// The next slot the plan would suggest — the first uncompleted one in plan order. Nil when the
    /// whole sheet is done.
    ///
    /// This is the SHEET's answer, used to open a session and to know when everything is done. It is
    /// deliberately NOT what `advance` follows after a set — see `slotAfter(_:)`.
    var nextPendingSlot: LiftSlot? {
        allSlots.first { !isCompleted($0) }
    }

    /// Where the session goes after finishing `slot`: the next uncompleted set of the SAME exercise,
    /// and only once that exercise is finished, the first uncompleted slot in plan order.
    ///
    /// Plan order alone is wrong, and wrong in a way that costs sets. A gym is not a queue — the
    /// whole point of being able to start any pending set is that machines get occupied — so a user
    /// who skips exercise 1 and starts exercise 3 has an EARLIER slot still uncompleted. Following
    /// plan order then throws them back to the machine they just walked away from, mid-exercise,
    /// after every single set. Reported from a real session: "when I double-tap for the next set, it
    /// reverts to the first set of the exercise I couldn't do earlier."
    ///
    /// Staying on the current exercise until it is finished is also simply what lifting is: you do
    /// your sets on the machine you are standing at. The skipped exercise is not forgotten — it is
    /// still pending, and it is what you get once the current one is done.
    func slotAfter(_ slot: LiftSlot) -> LiftSlot? {
        slots(forExercise: slot.exerciseIndex).first { !isCompleted($0) } ?? nextPendingSlot
    }

    var allCompleted: Bool { nextPendingSlot == nil }
    var isFinished: Bool { stage == .finished }
    var canUndo: Bool { !history.isEmpty }

    var plannedWorkingSets: Int { plan.reduce(0) { $0 + $1.targetSets } }
    var completedWorkingSets: Int { sets.filter { !$0.isWarmup }.count }

    func planItem(for slot: LiftSlot) -> LiftPlanItem? {
        plan.indices.contains(slot.exerciseIndex) ? plan[slot.exerciseIndex] : nil
    }

    /// Seconds left in the current rest, floored at zero. Nil when not resting.
    ///
    /// Floored rather than negative so an overrun rest reads "0:00" and waits, which is what it
    /// actually means: the user has not moved on yet.
    func restRemaining(now: Int) -> Int? {
        guard case .resting(_, let endsAt) = stage else { return nil }
        return max(0, endsAt - now)
    }

    /// What was lifted for the PREVIOUS set of this exercise in THIS session — the ghost values a
    /// set row shows before anything is typed. Falls back to nil, and the UI then falls back to the
    /// plan's target or to what was lifted last session.
    func previousSetInSession(for slot: LiftSlot) -> LiftRecordedSet? {
        (1..<max(1, slot.setIndex)).reversed()
            .compactMap { recordedSet(for: LiftSlot(exerciseIndex: slot.exerciseIndex, setIndex: $0)) }
            .first
    }

    /// What this slot records if the user completes it without typing: the same numbers the sheet
    /// was already showing them in grey, in the same order of preference — this exercise earlier in
    /// THIS session, then the same set number LAST session, then the program's target.
    ///
    /// The original rule was that a placeholder is never recorded, on the principle that "a number
    /// nobody entered must never become data". A real session killed it: 19 sets were completed
    /// against visible 50 kg x 10 placeholders and every one saved with weight and reps NIL, so the
    /// session's volume was zero and the numbers the whole feature exists to keep were simply gone.
    /// Silence is not the conservative choice when the alternative is losing the measurement.
    ///
    /// The principle survives in a stricter form: this is not an inference about what the user did,
    /// it is the plan they were working to, committed only because they pressed "set done" against
    /// it. The UI must therefore render a carried value as a REAL entry rather than a placeholder —
    /// what was recorded has to be visible and correctable during the rest, which is when set entry
    /// happens by design. A set the user did not actually do is corrected to 0, not left blank.
    ///
    /// RPE is NOT carried. Weight and reps are a plan, knowable in advance; RPE is how hard a set
    /// FELT, knowable only afterwards, and carrying one forward would invent the one figure nobody
    /// can guess for you. It would also silently corrupt the coverage the RPE card reports — every
    /// set would read as rated, and "14 of 19 sets unrated" could never be shown again.
    ///
    /// `lastSession` is the one layer the engine cannot know: it comes from the store, and the
    /// caller supplies it. Nil there simply falls through to the target.
    func carry(for slot: LiftSlot, lastSession: LiftSetCarry) -> LiftSetCarry {
        let previous = previousSetInSession(for: slot)
        let item = planItem(for: slot)
        return LiftSetCarry(
            weightKg: previous?.weightKg ?? lastSession.weightKg ?? item?.targetWeightKg,
            reps: previous?.reps ?? lastSession.reps ?? item?.targetRepsLow)
    }

    // MARK: - Actions

    /// Begin a specific set. Works from any stage, which is the whole point: a machine being busy
    /// must not block the session.
    ///
    /// Starting a set while ANOTHER set is in progress abandons that one — nothing is recorded,
    /// because nothing was finished. Starting an already-completed slot re-opens it for a redo,
    /// dropping its previous record so the set is not counted twice.
    mutating func start(_ slot: LiftSlot, now: Int) {
        guard planItem(for: slot) != nil else { return }
        pushHistory()
        sets.removeAll { $0.slot == slot }
        stage = .working(slot)
        stageStartedAt = now
    }

    /// The big button. Context decides what it means.
    ///
    /// `lastSession` is what the store holds for the slot being completed, used only as the middle
    /// layer of `carry(for:lastSession:)`. Callers without it pass `.none`.
    mutating func advance(now: Int, lastSession: LiftSetCarry = .none) {
        switch stage {
        case .warmup:
            guard let next = nextPendingSlot else { return }
            start(next, now: now)

        case .working(let slot):
            pushHistory()
            let carried = carry(for: slot, lastSession: lastSession)
            sets.append(LiftRecordedSet(
                exerciseIndex: slot.exerciseIndex, setIndex: slot.setIndex,
                weightKg: carried.weightKg, reps: carried.reps, rpe: nil, isWarmup: false,
                startTs: stageStartedAt, endTs: now, restSec: nil))
            let rest = planItem(for: slot)?.restSec ?? LiftPlanItem.defaultRestSec
            stage = .resting(slot, endsAt: now + rest)
            stageStartedAt = now

        case .resting(let slot, _):
            pushHistory()
            // Record what was ACTUALLY rested — the figure the work-vs-rest split is built from, and
            // the one thing only the taps can know.
            if let i = sets.firstIndex(where: { $0.slot == slot }) {
                sets[i].restSec = max(0, now - stageStartedAt)
            }
            if let next = slotAfter(slot) {
                stage = .working(next)
                stageStartedAt = now
            } else {
                // Sheet complete: stay put rather than inventing a stage. The user finishes when
                // they are ready, and the time until then is the cool-down.
                stage = .resting(slot, endsAt: now)
                stageStartedAt = now
            }

        case .finished:
            break
        }
    }

    /// Fill in (or correct) what a set actually was. Editing, never appending — the set already
    /// exists, so typing can never create a phantom. No-op for a slot that has not been completed.
    mutating func updateSet(_ slot: LiftSlot,
                            weightKg: Double?, reps: Int?, rpe: Double?, isWarmup: Bool) {
        guard let i = sets.firstIndex(where: { $0.slot == slot }) else { return }
        sets[i].weightKg = weightKg
        sets[i].reps = reps
        sets[i].rpe = rpe
        sets[i].isWarmup = isWarmup
    }

    /// End the session. The rest that was running is closed out first, so its measured duration is
    /// not silently lost.
    mutating func finish(now: Int) {
        guard stage != .finished else { return }
        pushHistory()
        if case .resting(let slot, _) = stage,
           let i = sets.firstIndex(where: { $0.slot == slot }), sets[i].restSec == nil {
            sets[i].restSec = max(0, now - stageStartedAt)
        }
        stage = .finished
        stageStartedAt = now
    }

    mutating func undo() {
        guard let previous = history.popLast() else { return }
        stage = previous.stage
        sets = previous.sets
        stageStartedAt = previous.stageStartedAt
    }

    private mutating func pushHistory() {
        history.append(Snapshot(stage: stage, sets: sets, stageStartedAt: stageStartedAt))
    }
}
