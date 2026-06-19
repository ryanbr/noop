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
    /// manager plus the v5 pillar screens the new in-hub rows deep-link to (Insights hub, Lab Book,
    /// the fused record, the experimental Rhythm visualization).
    enum Destination: String, Equatable, Identifiable {
        case devices
        case insightsHub
        case labBook
        case fusedRecord
        case rhythm

        var id: String { rawValue }
    }

    /// The destination a screen has asked the shell to open, or nil once handled. Published so the
    /// active shell (macOS sidebar / iOS tab) reacts and routes itself, then resets this to nil.
    @Published var requestedDestination: Destination?

    /// Ask the shell to open the Devices manager (pair / switch bands). The shell decides how.
    func openDevices() { requestedDestination = .devices }
    /// Open the v5 Insights hub (the n-of-1 "what moves your Charge" surface).
    func openInsightsHub() { requestedDestination = .insightsHub }
    /// Open the Lab Book (private health-records logbook).
    func openLabBook() { requestedDestination = .labBook }
    /// Open the "Your Data, Fused" multi-device record.
    func openFusedRecord() { requestedDestination = .fusedRecord }
    /// Open the experimental Rhythm visualization (self-gates on its own consent).
    func openRhythm() { requestedDestination = .rhythm }
}
