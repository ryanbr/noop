import Foundation
import Combine
import WhoopStore

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

    var isActive: Bool { engine != nil && engine?.isFinished == false }

    /// Rest period the five-second warning has already fired for. Lives HERE, not in a view, so
    /// re-opening the sheet mid-rest cannot re-fire it.
    private var warnedFor: Int?

    /// Slots the user marked as a warm-up BEFORE performing them. You know a set is a warm-up on the
    /// way in, not afterwards, but an unperformed set has no record to carry the flag — and inventing
    /// one would create a set nobody did. So the mark is held here and applied the instant the set is
    /// recorded. Owned by the controller rather than a view so it survives the sheet being minimised.
    @Published private(set) var pendingWarmups: Set<LiftSlot> = []
    private var ticker: AnyCancellable?

    /// Fires the strap buzz. Injected so the controller has no opinion about BLE and stays testable.
    private let buzz: (UInt8) -> Void
    /// Claims/releases the strap's double-tap for the session's lifetime.
    private let setStrapHandler: ((() -> Void)?) -> Void

    /// One pulse confirms a strap double-tap registered — with the phone face-down there is
    /// otherwise no way to know. Three means the rest is nearly up. Two patterns that cannot be
    /// mistaken for each other on a wrist that has been knocked about all session.
    static let advanceConfirmBuzzes: UInt8 = 1
    static let restWarningBuzzes: UInt8 = 3
    /// How long before the rest ends the warning fires.
    static let restWarningLeadSec = 5

    init(buzz: @escaping (UInt8) -> Void,
         setStrapHandler: @escaping ((() -> Void)?) -> Void) {
        self.buzz = buzz
        self.setStrapHandler = setStrapHandler
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
    }

    private func teardown() {
        engine = nil
        programId = nil
        programName = nil
        warnedFor = nil
        pendingWarmups = []
        isPresented = false
        ticker?.cancel()
        ticker = nil
        setStrapHandler(nil)
    }

    private func claimStrap() {
        setStrapHandler({ [weak self] in
            Task { @MainActor in self?.advance(fromStrap: true) }
        })
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

    /// The one action. `fromStrap` earns a single confirming buzz.
    func advance(fromStrap: Bool = false) {
        guard engine != nil else { return }
        // BUZZ FIRST, before any state work. The confirmation is a latency signal — its whole job is
        // to say "that registered" — so it must not queue behind a JSON encode and a defaults write.
        if fromStrap { buzz(LiftSessionController.advanceConfirmBuzzes) }

        let stamp = Int(Date().timeIntervalSince1970)
        engine?.advance(now: stamp)
        applyPendingWarmup()
        now = stamp
        warnedFor = nil
        persist()
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

    /// Carry a pre-marked warm-up onto the set that was just recorded.
    private func applyPendingWarmup() {
        guard let engine, let last = engine.sets.last, pendingWarmups.contains(last.slot),
              !last.isWarmup else { return }
        self.engine?.updateSet(last.slot, weightKg: last.weightKg, reps: last.reps,
                               rpe: last.rpe, isWarmup: true)
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

    func updateSet(_ slot: LiftSlot, weightKg: Double?, reps: Int?, rpe: Double?, isWarmup: Bool) {
        engine?.updateSet(slot, weightKg: weightKg, reps: reps, rpe: rpe, isWarmup: isWarmup)
        persist()
    }

    func undo() {
        engine?.undo()
        persist()
    }

    func finish() {
        engine?.finish(now: Int(Date().timeIntervalSince1970))
        persist()
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
                                            programName: programName))
    }
}
