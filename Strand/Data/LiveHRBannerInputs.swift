import Combine
import Foundation

/// When NOOP's Live HR banner reads the values it shows.
///
/// WHY THIS EXISTS. The banner shows AppModel's smoothed rate (`bpm`), which AppModel keeps with sinks of its own on
/// the live heart rate and R-R. A `@Published` sink runs in willSet, before the value lands, and several sinks on one
/// publisher run in no promised order. The banner used to refresh from a sink of its own on the heart rate, so when a
/// strap's WRIST_OFF cleared the heart rate it could run before AppModel had reset its median, read the old one and
/// send no dash. A tester's banner kept the last number for two to three minutes, until iOS's stale date drew the dash:
/// the strap log shows "Strap: WRIST_OFF; live heart rate cleared" and no banner line after it (24 Sep 2026, 10:48).
///
/// So the banner is refreshed once the changes have landed: the signals are merged and debounced to the end of the
/// main queue's current turn, where the heart rate, the link and the median all read as they now are. A clear moves
/// several of them in one turn, and makes one refresh instead of one per value.
///
/// Platform-free so `StrandTests` covers it; the controller it serves is in the iOS app target.
enum LiveHRBannerInputs {

    /// One signal per turn of the main queue in which any of `changes` fired, delivered after that turn.
    static func settled(_ changes: [AnyPublisher<Void, Never>]) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(changes)
            .debounce(for: .zero, scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
