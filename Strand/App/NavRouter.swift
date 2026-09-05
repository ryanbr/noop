import SwiftUI
import Combine

// MARK: - NavRouter
//
// A tiny shared navigation hook so a screen can ask the app shell to switch to another top-level
// destination without knowing how that shell is built. The two shells navigate very differently —
// macOS drives a `NavigationSplitView` sidebar selection (`RootView`), iOS uses a `TabView` whose
// "everything else" screens live behind the More tab (`RootTabView`) — so neither exposes a shared
// `selection` binding LiveView could reach. This object is the small, shared bridge between them.
//
// Usage: a screen calls `router.openDevices()`; the shell observes `requestedDestination` and routes
// itself (macOS sets the sidebar selection to `.devices`; iOS presents `DevicesView`). Each consumer
// clears the request once it's handled so the same tap can fire again later. Injected at both app
// roots (`StrandApp`, `StrandiOSApp`) as an `@EnvironmentObject`.
@MainActor
final class NavRouter: ObservableObject {
    /// A top-level destination a screen can ask the shell to open. Deliberately minimal — the Devices
    /// manager, the v5 pillar screens the new in-hub rows deep-link to (Insights hub, Lab Book, the
    /// fused record, the experimental Rhythm visualization), Trends, and the active-workout return route
    /// the Today indicator card raises.
    enum Destination: String, Equatable, Identifiable {
        case devices
        case insightsHub
        case labBook
        case fusedRecord
        case rhythm
        case trends
        case activeWorkout
        case liveSession
        case journal
        /// #1862: the Coach screen, opened from the Today Coach launcher sheet once the user picks a
        /// suggestion or submits the composer. The launcher deliberately owns no send/stream/consent
        /// surface of its own — it hands the question to the one screen that already has them.
        case coach

        var id: String { rawValue }

        /// Map a stored `UpdateItem.deepLink` route key to a Destination, if it names one. Lets the
        /// Updates inbox route a tapped item generically (e.g. a `.reading` item's "trends") without the
        /// inbox knowing every shell. Unknown keys return nil → the inbox just dismisses.
        init?(deepLinkKey: String) {
            self.init(rawValue: deepLinkKey)
        }
    }

    /// The destination a screen has asked the shell to open, or nil once handled. Published so the
    /// active shell (macOS sidebar / iOS tab) reacts and routes itself, then resets this to nil.
    @Published var requestedDestination: Destination?

    /// Set when a screen's top-bar "+" asks the shell to open the quick-action sheet (the sheet lives
    /// in the iOS shell). The shell presents it, then resets this to false.
    @Published var quickActionsRequested = false

    /// One-shot: `LiveView` reads this on appear to present the in-exercise screen for an already-running
    /// workout (routing alone only reaches the Live root), then clears it. A normal Live visit is
    /// unaffected, since the flag is only raised by `openActiveWorkout()` from the Today indicator card.
    /// The #238 "a workout just started" transition trigger never fires for a session that is already in
    /// flight, so this is the one path that re-opens the live workout for an existing session.
    @Published var presentActiveWorkout = false

    /// Ask the shell to open the quick-action sheet (Live HR · workout · journal · breathe).
    func requestQuickActions() { quickActionsRequested = true }

    /// Ask the shell to open the Devices manager (pair / switch bands). The shell decides how.
    func openDevices() { requestedDestination = .devices }
    /// #1862: open Coach, optionally with a question the launcher already collected.
    func openCoach() { requestedDestination = .coach }
    /// Open the v5 Insights hub (the n-of-1 "what moves your Charge" surface).
    func openInsightsHub() { requestedDestination = .insightsHub }
    /// Open the Lab Book (private health-records logbook).
    func openLabBook() { requestedDestination = .labBook }
    /// Open the "Your Data, Fused" multi-device record.
    func openFusedRecord() { requestedDestination = .fusedRecord }
    /// Open the experimental Rhythm visualization (self-gates on its own consent).
    func openRhythm() { requestedDestination = .rhythm }
    /// Open the Trends screen (where a "new data" reading deep-links).
    func openTrends() { requestedDestination = .trends }
    /// Open the active workout: route to the Live surface AND raise the one-shot flag so `LiveView`
    /// presents the in-exercise screen even when the workout is already running, in one tap from the Today
    /// indicator card. The flag is consumed (and cleared) by `LiveView.consumeActiveWorkoutRequest()`.
    func openActiveWorkout() { presentActiveWorkout = true; requestedDestination = .activeWorkout }
    /// Open a Live Session (silent guardian, beta). The Liquid Today entry presents the session screen
    /// directly today; this route exists for deep-link parity so a future shell/inbox item can raise it
    /// the same way as every other destination.
    func openLiveSession() { requestedDestination = .liveSession }
    /// A journal day-offset (daysBack; -1 = Tomorrow) the Today journal widget deep-linked to, so tapping
    /// a SPECIFIC day's bar opens the journal at THAT day instead of always today (#656). InsightsView
    /// consumes it on appear and clears it back to nil. nil = open at today (the default).
    @Published var pendingJournalDayOffset: Int?

    /// Open the journal (hosted in the classic Insights screen). The #627 Today journal widget taps here;
    /// iOS presents InsightsView (the journal quick-action sheet), macOS selects the Insights sidebar row.
    /// `day` (#656): a specific day-offset to open at (nil = today) — a tapped strip bar passes its day.
    func openJournal(day offset: Int? = nil) {
        pendingJournalDayOffset = offset
        requestedDestination = .journal
    }
}
