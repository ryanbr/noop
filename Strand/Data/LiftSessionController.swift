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
// controller owns the engine, the rest's timers, the buzz gating and the persistence. The sheet is a
// rendering of it; the bottom bar is another. Dismissing either changes nothing about the session.
//
// The strap gesture is claimed for the LIFETIME OF THE SESSION rather than the lifetime of a view,
// and handed back untouched when the session ends.

@MainActor
final class LiftSessionController: ObservableObject {

    /// The running session, or nil when none is in flight. Every change re-arms the rest's timers
    /// (`scheduleRestTimers`), which only act when the rest itself changed.
    @Published private(set) var engine: LiftSessionEngine? { didSet { scheduleRestTimers() } }
    @Published private(set) var programId: String?
    @Published private(set) var programName: String?
    /// True while the full sheet is presented; false when minimised to the bottom bar.
    @Published var isPresented = false

    /// Bumped each time a finished session is written. The session sheet is presented above every
    /// screen, so its save cannot call back into the one listing sessions; that screen reloads on this.
    @Published private(set) var savedSessions = 0

    /// Sends the moment a strap double-tap has moved the session on, with the new stage in place — unlike
    /// `$engine`, which publishes before the change lands. The Lock Screen banner uses it to light the
    /// screen on the step just taken, and because it comes before anything else about the step reaches
    /// the banner, that one lit update is usually the only update the step causes.
    let strapStepTaken = PassthroughSubject<Void, Never>()

    /// Anything about the session changed, once the change has landed and settled — what the Lock Screen
    /// banner follows. `objectWillChange` fires BEFORE a change lands, so a banner pushed from it showed the
    /// step before; the debounce also folds a burst (typing a number, the several changes of one tap) into one
    /// push. Built once, so its subscribers keep one pipeline.
    private(set) lazy var changesSettled: AnyPublisher<Void, Never> = objectWillChange
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .map { _ in () }
        .eraseToAnyPublisher()

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
    /// The running rest's warning and end, and the end they were set for — see `scheduleRestTimers`.
    private var restTimers: [Task<Void, Never>] = []
    private var scheduledRestEnd: Int?

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
    static let strapKnockWindowSec = 5

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
        isPresented = true
        claimStrap()
        persist()
    }

    /// Pick up the session a previous run of NOOP left going, as the app process starts.
    ///
    /// iOS closes NOOP in the background and relaunches it when the strap next sends something — four
    /// times in 28 minutes of one gym session (strap log, 21 Sep 2026). The session used to come back only
    /// when the first screen appeared, and the Lock Screen banner is driven by the same screen: its first
    /// push found no session, ended the banner, and iOS allows a new one only while NOOP is open. Every
    /// strap step after a restart then lit nothing ("no Lift Log banner is running") until NOOP was opened.
    /// Resumed here, before any screen exists, the session is back before anything asks about it, and
    /// the banner iOS kept on the Lock Screen is picked up again instead. The line it logs is how a later
    /// strap log shows a restart in the middle of a session.
    func resumeSaved(from defaults: UserDefaults = .standard) {
        guard !isActive, let snapshot = LiftSessionPersistence.load(from: defaults) else { return }
        resume(from: snapshot)
        log("Lift Log: session picked up again after NOOP restarted")
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
        // Suppress the warning for a rest that is ALREADY inside its final seconds. Without this,
        // reopening a session mid-rest greets the user with three buzzes for a rest they have been
        // watching count down all along.
        if case .resting(_, let endsAt) = engine?.stage,
           endsAt - Self.unixNow <= LiftSessionController.restWarningLeadSec {
            warnedFor = endsAt
        } else {
            warnedFor = nil
        }
        isPresented = present
        claimStrap()
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
        setStrapHandler(nil)
    }

    /// The handler runs SYNCHRONOUSLY, inside the frame handling that delivered the tap. It used to hop
    /// through a `Task`, which let the sync request the same strap event triggers reach the strap
    /// first; the strap then started a history transfer before playing the confirming buzz, and those
    /// buzzes came 1–2.8 s after the tap, where most others came in under one (strap log, 16 Sep 2026).
    private func claimStrap() {
        setStrapHandler({ [weak self] in self?.advance(fromStrap: true) })
    }

    /// The current unix second. Read when needed; nothing about a session is stored per second.
    static var unixNow: Int { Int(Date().timeIntervalSince1970) }

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
        // Straight after the stage moves, so the screen lights with no wait behind the bookkeeping below.
        // What follows cannot change what the banner shows: numbers typed into a set are already shown
        // before they are applied (`setNumbers`).
        if fromStrap { strapStepTaken.send() }
        applyPendingInput()
        warnedFor = nil
        persist()
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
    /// rest a lifter means to end, is that short. It was 8 s at first; after the next session Utku found
    /// that too long to wait for a deliberate second tap (21 Sep 2026), and 5 s still covers the knocks
    /// measured at +2.9 s and +4.1 s. The exception is a rest that is already over — a
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
            let ready = endsAt <= Self.unixNow
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

    /// Add an exercise the program does not have (Utku, 21 Sep 2026), at the end of the sheet: one set,
    /// planned as 0 kg × 0 reps with no max RPE and the default rest, so its row shows zeros until
    /// numbers are typed — or last session's numbers, when the exercise has been done before. It
    /// carries the id its program line will have if finishing adds it. Returns whether it was added.
    @discardableResult
    func addExercise(_ name: String, primaryMuscle: LiftMuscle?, secondaryMuscles: [LiftMuscle]) -> Bool {
        let line = LiftPlanItem(exercise: name, primaryMuscle: primaryMuscle,
                                secondaryMuscles: secondaryMuscles.filter { $0 != primaryMuscle },
                                targetSets: 1, targetRepsLow: 0, targetWeightKg: 0,
                                programItemId: UUID().uuidString, addedInSession: true)
        guard engine?.addExercise(line) == true else { return false }
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

    /// Sets never started. Finishing asks once whether to complete them with their grey numbers or
    /// discard them; a set that WAS done is never in question (`setsToSave`).
    var unfinishedSlots: [LiftSlot] { engine?.unperformedSlots ?? [] }

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
    /// A set that was DONE — ticked by Set done or a strap double-tap — is complete, with no question at
    /// finish (Utku, 21 Sep 2026): it saves what was typed into it, and a number left blank takes the grey
    /// value the sheet showed. That includes RPE: a set left unrated saves the program line's max RPE
    /// (16 Sep 2026). A rating typed for the set always wins, and a previous set's rating is never copied
    /// onto another — only the plan's own number fills a blank. Sets never started are the only
    /// unfinished ones: they save with their grey numbers (and anything typed in advance) when
    /// `completingUnfinished`; otherwise as 0 kg × 0 reps, which every figure leaves out
    /// (`LiftMetrics.isPerformed`) and Edit sets still shows, so a discard made by mistake can be filled
    /// back in. Done sets keep the order they happened in and their timing; sets never started follow in
    /// plan order, with no timing.
    func setsToSave(completingUnfinished: Bool) -> [FinishedSet] {
        guard let engine else { return [] }
        // The plan's max RPE, which the session shows grey in the RPE field.
        func planned(_ slot: LiftSlot) -> Double? { engine.planItem(for: slot)?.targetRpe }
        var out = engine.sets.map { set -> FinishedSet in
            let shown = values(of: set.slot)
            return FinishedSet(slot: set.slot, weightKg: shown.weightKg, reps: shown.reps,
                               rpe: set.rpe ?? planned(set.slot), isWarmup: set.isWarmup,
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

    /// Whether any of `sets` was performed. When none was (no set done, and the rest discarded), there
    /// is nothing to file: `LiftSessionView.save` writes no session, no sets and no workout, and the
    /// finish sheet says so before Save.
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
    /// since is skipped rather than resurrected — as is a line added during the session, which the
    /// program does not have yet (`programAfterSession`).
    static func setCountChanges(plan: [LiftPlanItem], program items: [LiftProgramItemRow]) -> [SetCountChange] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.compactMap { line in
            guard let id = line.programItemId, let row = byId[id] else { return nil }
            let saved = max(1, row.targetSets ?? 1)
            guard saved != line.targetSets else { return nil }
            return SetCountChange(itemId: id, exercise: line.exercise, from: saved, to: line.targetSets)
        }
    }

    /// The program's lines with each one's HEAVIEST done set this session as its new weight and reps.
    ///
    /// Utku, 21 Sep 2026: numbers typed during a session update the program, without asking. A line holds
    /// one weight and one rep count for all its sets, so it takes the heaviest set — the working weight,
    /// which a lighter back-off set must not pull down; between sets of equal weight, the one with more
    /// reps. Only sets actually done count: a warm-up, a set discarded to zeros and a set completed at
    /// finish without being started (it carries grey numbers, not new ones) move nothing. A number the
    /// heaviest set does not have (a bodyweight line's weight) is left as it was; a leftover rep range
    /// top below the new count is dropped, since the editor keeps one rep count. Lines without a program
    /// line behind them, or deleted since, are skipped.
    static func applyingHeaviestSets(_ sets: [FinishedSet], plan: [LiftPlanItem],
                                     to items: [LiftProgramItemRow]) -> [LiftProgramItemRow] {
        var heaviest: [String: FinishedSet] = [:]
        for set in sets where set.startTs != nil && !set.isWarmup && LiftMetrics.isPerformed(reps: set.reps) {
            guard plan.indices.contains(set.slot.exerciseIndex),
                  let id = plan[set.slot.exerciseIndex].programItemId else { continue }
            if let best = heaviest[id], !isHeavier(set, than: best) { continue }
            heaviest[id] = set
        }
        return items.map { row in
            guard let top = heaviest[row.id] else { return row }
            var edited = row
            if let weight = top.weightKg { edited.targetWeightKg = weight }
            if let reps = top.reps {
                edited.targetRepsLow = reps
                if let high = edited.targetRepsHigh, high < reps { edited.targetRepsHigh = nil }
            }
            return edited
        }
    }

    /// More weight wins; at equal weight, more reps. A missing number ranks below any number.
    private static func isHeavier(_ a: FinishedSet, than b: FinishedSet) -> Bool {
        let (weightA, weightB) = (a.weightKg ?? -1, b.weightKg ?? -1)
        if weightA != weightB { return weightA > weightB }
        return (a.reps ?? -1) > (b.reps ?? -1)
    }

    /// The program's lines after this session — what `LiftSessionView.save` writes.
    ///
    /// Every line already in the program takes its heaviest done set (`applyingHeaviestSets`, always).
    /// With `keepingChanges` — the answer to the finish sheet's program question — changed set counts
    /// move too (`applying`), and each exercise added during the session becomes a new line at the end,
    /// in the order added: the session's set count for it, its heaviest done set's weight and reps, else
    /// 0 kg × 0 reps, and nothing else (Utku, 21 Sep 2026: the rest is set later in the program editor).
    static func programAfterSession(_ sets: [FinishedSet], plan: [LiftPlanItem],
                                    program items: [LiftProgramItemRow], keepingChanges: Bool,
                                    programId: String, deviceId: String) -> [LiftProgramItemRow] {
        var lines = items
        if keepingChanges {
            lines = applying(setCountChanges(plan: plan, program: items), to: lines)
            let next = (items.map(\.ord).max() ?? -1) + 1
            for (offset, line) in plan.filter(\.addedInSession).enumerated() {
                guard let id = line.programItemId, !lines.contains(where: { $0.id == id }) else { continue }
                lines.append(LiftProgramItemRow(
                    id: id, deviceId: deviceId, programId: programId, ord: next + offset,
                    exercise: line.exercise, targetSets: line.targetSets,
                    targetRepsLow: 0, targetRepsHigh: nil, targetRpe: nil, targetWeightKg: 0,
                    restSec: nil, note: nil))
            }
        }
        return applyingHeaviestSets(sets, plan: plan, to: lines)
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

    // MARK: - The rest's two moments
    //
    // A running session changes with time alone at two moments of each rest: the warning buzz
    // `restWarningLeadSec` before it ends, and its end. Each gets a one-shot timer, set when the rest starts
    // and replaced whenever the rest does; between taps a session does no work at all.
    //
    // It used to tick once a second, and publish the tick to every screen watching the session — the whole
    // tab shell, the session sheet, the bar, the Lift Log hub — so all of them were redrawn every second, on
    // screen or not. iOS killed NOOP four times in one gym session for background CPU (Utku's crash reports,
    // 21 Sep 2026: over 80% for 60 s, busy redrawing SwiftUI views), and every kill cost a Lock Screen banner
    // and the log before it. The clocks on screen tick by themselves, and only while shown (`LiftRunningClock`).

    /// Re-arm the rest's timers when the rest changed — a new rest, a rest undone or cut short, no rest.
    private func scheduleRestTimers() {
        let endsAt: Int? = { if case .resting(_, let end) = engine?.stage { return end }; return nil }()
        guard endsAt != scheduledRestEnd else { return }
        scheduledRestEnd = endsAt
        restTimers.forEach { $0.cancel() }
        restTimers = []
        guard let endsAt else { return }
        let times = Self.restEventTimes(endsAt: endsAt, now: Self.unixNow)
        restTimers.append(after(times.warning) { $0.fireRestWarningIfDue() })
        if let end = times.end {
            restTimers.append(after(end) { $0.restDidEnd() })
        }
    }

    /// When a rest's warning and end fire, in unix seconds. The warning comes `restWarningLeadSec` before the
    /// end, or one second from now when the rest is already inside that window (a short rest, none at all,
    /// or the rest left once every set is done) — when the once-a-second tick used to fire it, and clear of
    /// the confirming buzz the same tap just sent. The end fires only for a rest still to run.
    static func restEventTimes(endsAt: Int, now: Int) -> (warning: Int, end: Int?) {
        (warning: max(now + 1, endsAt - restWarningLeadSec), end: endsAt > now ? endsAt : nil)
    }

    /// Run `action` on the main actor at unix second `unix`, unless cancelled first.
    private func after(_ unix: Int,
                       _ action: @escaping @MainActor (LiftSessionController) -> Void) -> Task<Void, Never> {
        let delay = Date(timeIntervalSince1970: TimeInterval(unix)).timeIntervalSinceNow
        return Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            action(self)
        }
    }

    private func fireRestWarningIfDue() {
        guard let engine, case .resting(_, let endsAt) = engine.stage else { return }
        guard warnedFor != endsAt else { return }
        guard endsAt - Self.unixNow <= LiftSessionController.restWarningLeadSec else { return }
        warnedFor = endsAt
        buzz(LiftSessionController.restWarningBuzzes)
    }

    /// The rest is over: the one moment a session's words change with time alone — on screen and, through
    /// `changesSettled`, on the Lock Screen, "Resting after set 2" becomes "Ready for the next set".
    private func restDidEnd() {
        objectWillChange.send()
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
