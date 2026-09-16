import Foundation
import Combine
import WhoopStore
import StrandAnalytics

// The live session, owned ABOVE any screen.
//
// WHY THIS EXISTS. The session used to live inside the sheet that displayed it. Swiping that sheet
// down dismissed it, which tore down the view — and with it the strap's double-tap handler and the
// rest-timer tick. The session looked alive (it was still on disk, and "Resume" brought it back) but
// was deaf: taps did nothing, no buzz arrived, in the app or out of it. Re-entering also re-fired
// the five-second warning, because the "already buzzed" flag was view state that reset on every
// present.
//
// A workout outlives the screen you happen to be looking at, so the session has to as well. This
// controller owns the engine, the tick, the buzz gating and the persistence. The sheet is a
// rendering of it; the bottom bar is another. Dismissing either changes nothing about the session.
//
// The strap gesture is claimed for the LIFETIME OF THE SESSION rather than the lifetime of a view,
// and handed back untouched when the session ends.

@MainActor
final class LiftSessionController: ObservableObject {

    /// The running session, or nil when none is in flight.
    @Published private(set) var engine: LiftSessionEngine?
    @Published private(set) var programId: String?
    @Published private(set) var programName: String?
    /// Ticks every second while a session runs, so views can redraw clocks off one shared timer
    /// rather than each starting their own.
    @Published private(set) var now = Int(Date().timeIntervalSince1970)
    /// True while the full sheet is presented; false when minimised to the bottom bar.
    @Published var isPresented = false

    /// Bumped each time a finished session is written. The session sheet is presented above every
    /// screen, so its save cannot call back into the one listing sessions; that screen reloads on this.
    @Published private(set) var savedSessions = 0

    /// Sends after a strap double-tap has moved the session on, once the new state is in place — unlike
    /// `$engine`, which publishes before the change lands. The Lock Screen banner uses it to light the
    /// screen for the step the lifter just took.
    let strapStepTaken = PassthroughSubject<Void, Never>()

    var isActive: Bool { engine != nil && engine?.isFinished == false }

    /// Rest period the five-second warning has already fired for. Lives HERE, not in a view, so
    /// re-opening the sheet mid-rest cannot re-fire it.
    private var warnedFor: Int?

    /// Slots the user marked as a warm-up BEFORE performing them. You know a set is a warm-up on the
    /// way in, not afterwards, but an unperformed set has no record to carry the flag — and inventing
    /// one would create a set nobody did. So the mark is held here and applied the instant the set is
    /// recorded. Owned by the controller rather than a view so it survives the sheet being minimised.
    @Published private(set) var pendingWarmups: Set<LiftSlot> = []

    /// Numbers typed into a set BEFORE it was performed, held exactly the way a warm-up mark is.
    ///
    /// Reported from a real session: "when I type something during an active set to other sets it
    /// refreshes to the empty". It did — `LiftSessionView.write` could only edit a set that already
    /// had a record, so every keystroke into a pending row was silently discarded, and the field only
    /// LOOKED like it had taken until focus left and the draft was dropped.
    ///
    /// The engine invariant it ran into is real and stays: typing must never append a set, or a set
    /// nobody performed becomes data. So the value is held here instead, shown back on the row, and
    /// applied the instant the set is recorded — at which point it BEATS the carried plan, because a
    /// number the user typed for this set is better evidence than the one the sheet guessed for it.
    @Published private(set) var pendingValues: [LiftSlot: PendingSetValues] = [:]

    /// What a user typed into a set that has not happened yet. All optional: a row where only the
    /// weight was typed keeps carrying its reps.
    struct PendingSetValues: Equatable {
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?

        var isEmpty: Bool { weightKg == nil && reps == nil && rpe == nil }
    }

    /// What the store holds for each exercise LAST session, keyed by exercise name then set number —
    /// the middle layer of `LiftSessionEngine.carry(for:lastSession:)`.
    ///
    /// It lives here rather than in the sheet because the minimised bar and the Lock Screen show a
    /// set's numbers too, and they must be the grey numbers the sheet shows. `LiftSessionView` loads it
    /// and hands it over; until it does (a session resumed straight into the bar after a relaunch, say)
    /// the grey numbers fall through to the program's target, which is the layer below.
    @Published private var lastSession: [String: [Int: LiftSetCarry]] = [:]
    private var ticker: AnyCancellable?

    /// Fires the strap buzz. Injected so the controller has no opinion about BLE and stays testable.
    private let buzz: (UInt8) -> Void
    /// Claims/releases the strap's double-tap for the session's lifetime.
    private let setStrapHandler: ((@MainActor () -> Void)?) -> Void
    /// Writes a line to the strap log — how a double-tap the session holds back is accounted for.
    private let log: (String) -> Void

    /// When the session last acted on a strap double-tap (unix seconds). Nil until it has, and after a
    /// relaunch: a knock is judged against a tap in the same sitting, never one from before it.
    private var lastStrapStepAt: Int?

    /// One pulse confirms a strap double-tap registered — with the phone face-down there is
    /// otherwise no way to know. Three means the rest is nearly up. Two patterns that cannot be
    /// mistaken for each other on a wrist that has been knocked about all session.
    static let advanceConfirmBuzzes: UInt8 = 1
    static let restWarningBuzzes: UInt8 = 3
    /// How long before the rest ends the warning fires.
    static let restWarningLeadSec = 5
    /// A strap double-tap this soon after the last one the session acted on is taken as a knock. See
    /// `isKnock(secondsSinceLastStep:stage:now:)`.
    static let strapKnockWindowSec = 8

    init(buzz: @escaping (UInt8) -> Void,
         setStrapHandler: @escaping ((@MainActor () -> Void)?) -> Void,
         log: @escaping (String) -> Void = { _ in }) {
        self.buzz = buzz
        self.setStrapHandler = setStrapHandler
        self.log = log
    }

    // MARK: - Lifecycle

    func start(plan: [LiftPlanItem], programId: String?, programName: String?) {
        let stamp = Int(Date().timeIntervalSince1970)
        engine = LiftSessionEngine(plan: plan, startTs: stamp)
        self.programId = programId
        self.programName = programName
        warnedFor = nil
        now = stamp
        isPresented = true
        claimStrap()
        startTicking()
        persist()
    }

    /// Rehydrate an interrupted session found on disk. Does NOT present the sheet: the session comes
    /// back as the bottom bar, and the user opens it if they want to.
    func resume(from snapshot: LiftSessionPersistence.Snapshot, present: Bool = false) {
        engine = LiftSessionPersistence.engine(from: snapshot)
        programId = snapshot.programId
        programName = snapshot.programName
        // Numbers typed for sets not yet performed, and warm-ups marked in advance, come back too:
        // they are intent the user already expressed, and losing them is the bug this pair exists
        // to prevent, whether it is lost to a blur or to a relaunch.
        pendingValues = LiftSessionPersistence.pendingValues(from: snapshot)
        pendingWarmups = LiftSessionPersistence.pendingWarmups(from: snapshot)
        now = Int(Date().timeIntervalSince1970)
        // Suppress the warning for a rest that is ALREADY inside its final seconds. Without this,
        // reopening a session mid-rest greets the user with three buzzes for a rest they have been
        // watching count down all along.
        if case .resting(_, let endsAt) = engine?.stage,
           endsAt - now <= LiftSessionController.restWarningLeadSec {
            warnedFor = endsAt
        } else {
            warnedFor = nil
        }
        isPresented = present
        claimStrap()
        startTicking()
    }

    /// Give up the session without saving.
    func discard() {
        teardown()
        LiftSessionPersistence.clear()
    }

    /// Called once the session has been written to the store.
    func finishedSaving() {
        teardown()
        LiftSessionPersistence.clear()
        savedSessions += 1
    }

    private func teardown() {
        engine = nil
        programId = nil
        programName = nil
        warnedFor = nil
        lastStrapStepAt = nil
        pendingWarmups = []
        pendingValues = [:]
        isPresented = false
        ticker?.cancel()
        ticker = nil
        setStrapHandler(nil)
    }

    /// The handler runs SYNCHRONOUSLY, inside the frame handling that delivered the tap. It used to hop
    /// through a `Task`, which let the sync request the same strap event triggers reach the strap
    /// first; the strap then started a history transfer before playing the confirming buzz, and those
    /// buzzes came 1–2.8 s after the tap, where most others came in under one (strap log, 16 Sep 2026).
    private func claimStrap() {
        setStrapHandler({ [weak self] in self?.advance(fromStrap: true) })
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] instant in
                guard let self else { return }
                self.now = Int(instant.timeIntervalSince1970)
                self.fireRestWarningIfDue()
            }
    }

    // MARK: - Actions

    /// The one action. `fromStrap` earns a single confirming buzz, unless the tap reads as a knock.
    func advance(fromStrap: Bool = false) {
        guard let current = engine else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        if fromStrap {
            if let last = lastStrapStepAt,
               Self.isKnock(secondsSinceLastStep: stamp - last, stage: current.stage, now: stamp) {
                // No buzz: the missing confirmation is the lifter's cue to tap again.
                log("Lift Log: that double-tap was not acted on — \(stamp - last) s after the last one it "
                    + "acted on (under \(Self.strapKnockWindowSec) s is taken as a knock)")
                return
            }
            lastStrapStepAt = stamp
            // BUZZ FIRST, before any state work. The confirmation is a latency signal — its whole job
            // is to say "that registered" — so it must not queue behind a JSON encode and a defaults write.
            buzz(LiftSessionController.advanceConfirmBuzzes)
        }

        engine?.advance(now: stamp)
        applyPendingInput()
        now = stamp
        warnedFor = nil
        persist()
        if fromStrap { strapStepTaken.send() }
    }

    /// Whether a strap double-tap `secondsSinceLastStep` after the last one the session acted on is a
    /// knock rather than a tap.
    ///
    /// The strap's own sensor log for the 16 Sep 2026 session shows two double-taps it detected 3 s
    /// and 4 s after one that had just started a set — the arm going onto the bar, not a second tap.
    /// Each was a genuine detection with its own timestamp, so the de-duplication in `FrameRouter`
    /// rightly let it through, and each finished a set seconds old and started its rest: "it skipped
    /// two things when it should have done only one". Only the timing tells such a knock from a tap.
    ///
    /// Under `strapKnockWindowSec` counts as a knock, because no set a lifter means to finish, and no
    /// rest a lifter means to end, is that short. The exception is a rest that is already over — a
    /// line planned with no rest, or the one left once every set is done — where going straight on is
    /// the plan. The on-screen button is never held back: a knock does not press it. A tap held back
    /// gets no buzz, which tells the lifter to tap again.
    static func isKnock(secondsSinceLastStep: Int, stage: LiftSessionEngine.Stage, now: Int) -> Bool {
        guard (0..<strapKnockWindowSec).contains(secondsSinceLastStep) else { return false }
        if case .resting(_, let endsAt) = stage, endsAt <= now { return false }
        return true
    }

    // MARK: - Presentation
    //
    // What a running session looks like, resolved ONCE here rather than in each surface that shows
    // it. The minimised bar and the Lock Screen Live Activity display the same four things — state,
    // exercise, numbers, clock — and they must agree, including the wording. Two copies of this
    // drifted the moment one of them was edited.

    struct Presentation: Equatable {
        var isResting: Bool
        /// The exercise being worked or rested from; the program's name during the warm-up.
        var exercise: String
        /// "Set 2", "Resting after set 2", "Ready for the next set", "Warm-up".
        var status: String
        /// "8 x 30 kg", already unit-converted. Nil when neither reps nor weight is known.
        var detail: String?
        /// "Next: Set 3 · Bench press" — see `nextLine(_:)`.
        var next: String
        var stageStartedAt: Date
        /// When the running rest is due to end. Nil while working.
        var restEndsAt: Date?
    }

    func presentation(system: UnitSystem) -> Presentation? {
        guard let engine, !engine.isFinished else { return nil }
        let started = Date(timeIntervalSince1970: TimeInterval(engine.stageStartedAt))
        let next = Self.nextLine(engine)

        guard let slot = engine.currentSlot, let item = engine.planItem(for: slot) else {
            return Presentation(isResting: false,
                                exercise: programName ?? String(localized: "Session"),
                                status: String(localized: "Warm-up"), detail: nil, next: next,
                                stageStartedAt: started, restEndsAt: nil)
        }

        let detail = setNumbers(for: slot, system: system)
        switch engine.stage {
        case .resting(_, let endsAt):
            let ready = endsAt <= now
            return Presentation(
                isResting: true, exercise: item.exercise,
                status: ready ? String(localized: "Ready for the next set")
                              : String(localized: "Resting after set \(slot.setIndex)"),
                detail: detail, next: next,
                stageStartedAt: started,
                restEndsAt: Date(timeIntervalSince1970: TimeInterval(endsAt)))
        default:
            return Presentation(
                isResting: false, exercise: item.exercise,
                status: String(localized: "Set \(slot.setIndex)"),
                detail: detail, next: next,
                stageStartedAt: started, restEndsAt: nil)
        }
    }

    /// The set after this one, as the bar and the Lock Screen show it on one line.
    ///
    /// It replaced "3 of 19 sets done", which answered nothing a lifter acts on mid-session, while the
    /// set coming up says where to walk (Utku, 16 Sep 2026). It is always a SET, never the rest before
    /// it. The set number comes before the exercise so that a narrow line cuts the name, not the
    /// number. "Last set" while the final set is worked; "All sets done" once it is.
    static func nextLine(_ engine: LiftSessionEngine) -> String {
        if let upcoming = engine.upcomingSlot, let item = engine.planItem(for: upcoming) {
            return String(localized: "Next: Set \(upcoming.setIndex) · \(item.exercise)")
        }
        return engine.allCompleted ? String(localized: "All sets done") : String(localized: "Last set")
    }

    /// Reps x weight for a slot, as "8 x 30 kg": what the set's row on the sheet shows — typed numbers,
    /// else the grey ones.
    ///
    /// That includes numbers typed into a set BEFORE it is recorded (`pendingValues`), which the row shows
    /// black. Without them the bar and the Lock Screen showed the grey plan for the set being lifted while
    /// its row showed what was typed (simulator, 16 Sep 2026: 70 kg × 9 typed, "8 x 60 kg" on the bar).
    func setNumbers(for slot: LiftSlot, system: UnitSystem) -> String? {
        guard engine != nil else { return nil }
        let grey = values(of: slot)
        let typed = pendingValues[slot]
        let shown = LiftSetCarry(weightKg: typed?.weightKg ?? grey.weightKg, reps: typed?.reps ?? grey.reps)

        let weight = shown.weightKg.map {
            LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system))
            + " " + LiftFormat.weightUnit(system)
        }
        switch (shown.reps, weight) {
        case (let r?, let w?): return "\(r) x \(w)"
        case (let r?, nil):    return String(localized: "\(r) reps")
        case (nil, let w?):    return w
        case (nil, nil):       return nil
        }
    }

    /// Hand over what the store knows about previous sessions. Called by the sheet once it has read
    /// it; safe to call again if it reloads.
    func setLastSession(_ values: [String: [Int: LiftSetCarry]]) {
        lastSession = values
    }

    /// The grey numbers a slot shows — the one chain every surface reads, so the sheet, the minimised
    /// bar and the Lock Screen cannot disagree about them.
    func carry(for slot: LiftSlot) -> LiftSetCarry {
        engine?.carry(for: slot, lastSession: lastSessionSets(for: slot)) ?? .none
    }

    /// What a slot counts as: typed numbers, else its grey ones.
    func values(of slot: LiftSlot) -> LiftSetCarry {
        engine?.values(of: slot, lastSession: lastSessionSets(for: slot)) ?? .none
    }

    private func lastSessionSets(for slot: LiftSlot) -> [Int: LiftSetCarry] {
        engine?.planItem(for: slot).flatMap { lastSession[$0.exercise] } ?? [:]
    }

    /// Mark a slot as a warm-up (or not). Applies immediately when the set already exists, and is
    /// remembered for when it does not yet.
    func setWarmup(_ slot: LiftSlot, _ isWarmup: Bool) {
        if isWarmup { pendingWarmups.insert(slot) } else { pendingWarmups.remove(slot) }
        if let row = engine?.recordedSet(for: slot) {
            engine?.updateSet(slot, weightKg: row.weightKg, reps: row.reps,
                              rpe: row.rpe, isWarmup: isWarmup)
        }
        persist()
    }

    func isWarmup(_ slot: LiftSlot) -> Bool {
        if let row = engine?.recordedSet(for: slot) { return row.isWarmup }
        return pendingWarmups.contains(slot)
    }

    /// Carry a pre-marked warm-up, and any numbers typed in advance, onto the set just recorded.
    ///
    /// The set is recorded with its timing only, so typed numbers become its own and a field left
    /// untouched stays grey — typing only the weight does not blank the reps.
    ///
    /// The entry is CONSUMED. A redo (`start` on a completed slot) drops the record and should show
    /// the ghosts again, exactly as it did before; leaving the entry behind would resurrect numbers
    /// the user is in the middle of redoing.
    private func applyPendingInput() {
        guard let engine, let last = engine.sets.last else { return }
        let typed = pendingValues.removeValue(forKey: last.slot)
        let warmup = last.isWarmup || pendingWarmups.contains(last.slot)
        guard typed != nil || warmup != last.isWarmup else { return }
        self.engine?.updateSet(last.slot,
                               weightKg: typed?.weightKg ?? last.weightKg,
                               reps: typed?.reps ?? last.reps,
                               rpe: typed?.rpe ?? last.rpe,
                               isWarmup: warmup)
    }

    /// Begin a specific set — the out-of-order path, for when a machine is occupied.
    func start(_ slot: LiftSlot, fromStrap: Bool = false) {
        guard engine != nil else { return }
        if fromStrap { buzz(LiftSessionController.advanceConfirmBuzzes) }
        let stamp = Int(Date().timeIntervalSince1970)
        engine?.start(slot, now: stamp)
        // Starting a slot drops any record it had, so its warm-up mark reverts to pending — which is
        // where it already lives.
        now = stamp
        warnedFor = nil
        persist()
    }

    /// Add one set to an exercise — the unplanned fifth set. Returns whether anything changed, which
    /// is what tells the caller whether the program behind the session needs rewriting.
    @discardableResult
    func addSet(toExercise index: Int) -> Bool {
        guard engine?.addSet(toExercise: index) == true else { return false }
        persist()
        return true
    }

    /// Drop the last pending set of an exercise. See `LiftSessionEngine.canRemoveSet(fromExercise:)`
    /// for what "can" means — a completed set is never removed this way.
    @discardableResult
    func removeSet(fromExercise index: Int) -> Bool {
        guard let engine, engine.canRemoveSet(fromExercise: index) else { return false }
        let dropped = LiftSlot(exerciseIndex: index, setIndex: engine.plan[index].targetSets)
        self.engine?.removeSet(fromExercise: index)
        // A slot that no longer exists must not keep a warm-up mark or typed numbers: adding the set
        // back would return them silently, from input the user gave a set they then removed.
        pendingWarmups.remove(dropped)
        pendingValues.removeValue(forKey: dropped)
        persist()
        return true
    }

    /// Fill in or correct a set's numbers — **any** set, at any time.
    ///
    /// A set that has been performed is edited in the engine. A set that has NOT been performed
    /// cannot be (that would invent it), so its numbers are held in `pendingValues` until it is.
    /// From the screen the two are indistinguishable, which is the point: the user asked to be able
    /// to type into whichever row they are looking at, and being mid-set somewhere else is not a
    /// reason to refuse.
    func updateSet(_ slot: LiftSlot, weightKg: Double?, reps: Int?, rpe: Double?, isWarmup: Bool) {
        if engine?.recordedSet(for: slot) != nil {
            engine?.updateSet(slot, weightKg: weightKg, reps: reps, rpe: rpe, isWarmup: isWarmup)
        } else if engine?.planItem(for: slot) != nil {
            let values = PendingSetValues(weightKg: weightKg, reps: reps, rpe: rpe)
            // Clearing the last field clears the entry rather than leaving an empty one behind, so
            // the row goes back to showing the plan's grey ghost instead of a blank it has to keep.
            if values.isEmpty { pendingValues.removeValue(forKey: slot) }
            else { pendingValues[slot] = values }
        }
        persist()
    }

    /// What a slot is currently showing: what it recorded, or what was typed into it in advance.
    func enteredValues(for slot: LiftSlot) -> PendingSetValues {
        if let row = engine?.recordedSet(for: slot) {
            return PendingSetValues(weightKg: row.weightKg, reps: row.reps, rpe: row.rpe)
        }
        return pendingValues[slot] ?? PendingSetValues(weightKg: nil, reps: nil, rpe: nil)
    }

    func undo() {
        engine?.undo()
        persist()
    }

    func finish() {
        engine?.finish(now: Int(Date().timeIntervalSince1970))
        persist()
    }

    // MARK: - Finishing

    /// Slots with no number typed in — never started, or finished without typing. Finishing asks once
    /// whether to complete all of them with their grey numbers or discard them.
    var unfinishedSlots: [LiftSlot] { engine?.unenteredSlots ?? [] }

    /// One set as the finished session saves it. Timing is nil for a set completed at finish without
    /// ever being started: there is no moment to record, and inventing one would give it a rest and a
    /// heart-rate window it never had.
    struct FinishedSet: Equatable {
        var slot: LiftSlot
        var weightKg: Double?
        var reps: Int?
        var rpe: Double?
        var isWarmup: Bool
        var startTs: Int?
        var endTs: Int?
        var restSec: Int?
    }

    /// The sets the session saves — every slot on the sheet.
    ///
    /// A set with anything typed saves its numbers, and a number left blank takes its grey value, so a
    /// set that was rated but never weighed does not save empty. That includes RPE: a set left unrated
    /// saves the program line's max RPE (Utku, 16 Sep 2026), which is the number the session showed grey.
    /// A rating typed for the set always wins, and a previous set's rating is never copied onto another —
    /// only the plan's own number fills a blank. Unfinished sets save with their grey
    /// numbers (and anything typed in advance) when `completingUnfinished`; otherwise they save as
    /// 0 kg × 0 reps, which every figure leaves out (`LiftMetrics.isPerformed`) and Edit sets still
    /// shows, so a discard made by mistake can be filled back in. Performed sets keep the order they
    /// happened in and their timing; sets never started follow in plan order, with no timing.
    func setsToSave(completingUnfinished: Bool) -> [FinishedSet] {
        guard let engine else { return [] }
        let unfinished = Set(engine.unenteredSlots)
        // The plan's max RPE, which the session shows grey in the RPE field.
        func planned(_ slot: LiftSlot) -> Double? { engine.planItem(for: slot)?.targetRpe }
        var out = engine.sets.map { set -> FinishedSet in
            let discarded = unfinished.contains(set.slot) && !completingUnfinished
            let shown = values(of: set.slot)
            return FinishedSet(slot: set.slot,
                               weightKg: discarded ? 0 : shown.weightKg, reps: discarded ? 0 : shown.reps,
                               rpe: discarded ? nil : (set.rpe ?? planned(set.slot)), isWarmup: set.isWarmup,
                               startTs: set.startTs, endTs: set.endTs, restSec: set.restSec)
        }
        for slot in engine.allSlots where !engine.isCompleted(slot) {
            let typed = pendingValues[slot]
            let grey = carry(for: slot)
            out.append(FinishedSet(slot: slot,
                                   weightKg: completingUnfinished ? typed?.weightKg ?? grey.weightKg : 0,
                                   reps: completingUnfinished ? typed?.reps ?? grey.reps : 0,
                                   rpe: completingUnfinished ? typed?.rpe ?? planned(slot) : nil,
                                   isWarmup: pendingWarmups.contains(slot),
                                   startTs: nil, endTs: nil, restSec: nil))
        }
        return out
    }

    /// Whether any of `sets` was performed. When none was (a session run face-down with nothing typed,
    /// then discarded), there is nothing to file: `LiftSessionView.save` writes no session, no sets and
    /// no workout, and the finish sheet says so before Save.
    static func anyPerformed(_ sets: [FinishedSet]) -> Bool {
        sets.contains { LiftMetrics.isPerformed(reps: $0.reps) }
    }

    /// A program line whose set count this session changed.
    struct SetCountChange: Equatable {
        var itemId: String
        var exercise: String
        var from: Int
        var to: Int
    }

    /// Lines whose set count in this session differs from the program's current one. A line with no
    /// count counts as one set, as it does when a session starts, and a line deleted from the program
    /// since is skipped rather than resurrected.
    static func setCountChanges(plan: [LiftPlanItem], program items: [LiftProgramItemRow]) -> [SetCountChange] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.compactMap { line in
            guard let id = line.programItemId, let row = byId[id] else { return nil }
            let saved = max(1, row.targetSets ?? 1)
            guard saved != line.targetSets else { return nil }
            return SetCountChange(itemId: id, exercise: line.exercise, from: saved, to: line.targetSets)
        }
    }

    /// The program's lines with `changes` applied. Only `targetSets` moves.
    static func applying(_ changes: [SetCountChange], to items: [LiftProgramItemRow]) -> [LiftProgramItemRow] {
        let counts = Dictionary(changes.map { ($0.itemId, $0.to) }, uniquingKeysWith: { first, _ in first })
        return items.map { row in
            guard let sets = counts[row.id] else { return row }
            var edited = row
            edited.targetSets = sets
            return edited
        }
    }

    // MARK: - The rest warning

    private func fireRestWarningIfDue() {
        guard let engine, case .resting(_, let endsAt) = engine.stage else { return }
        guard warnedFor != endsAt else { return }
        guard endsAt - now <= LiftSessionController.restWarningLeadSec else { return }
        warnedFor = endsAt
        buzz(LiftSessionController.restWarningBuzzes)
    }

    // MARK: - Persistence

    private func persist() {
        guard let engine, !engine.isFinished else { return }
        LiftSessionPersistence.store(
            LiftSessionPersistence.snapshot(engine: engine,
                                            programId: programId,
                                            programName: programName,
                                            pendingValues: pendingValues,
                                            pendingWarmups: pendingWarmups))
    }
}
