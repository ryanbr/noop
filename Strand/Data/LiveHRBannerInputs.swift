import Combine
import Foundation

/// When NOOP's Live HR banner reads the values it shows.
///
/// WHY THIS EXISTS. The banner shows AppModel's smoothed rate (`bpm`), a ten-second rolling median `AppModel.ingestHR`
/// keeps from the live heart rate and R-R. The banner used to observe the heart rate and the link but never `bpm`
/// itself, so every move of the median that came from an R-R update, or from samples ageing out of the window, changed
/// what the banner shows and refreshed nothing. `LiveState.clearBiometrics()` is the deterministic case: it clears the
/// heart rate while the R-R is still there, so `ingestHR` reads the rate from `rr.last` and the median survives the one
/// refresh the banner does get; `rr.removeAll()` then takes `ingestHR` through `resetSmoothing()`, `bpm` goes nil, and
/// nothing the banner watches has moved. A tester's banner kept the last number for two to three minutes after a
/// WRIST_OFF, until iOS's stale date drew the dash: the strap log shows "Strap: WRIST_OFF; live heart rate cleared" and
/// no banner line after it (24 Sep 2026, 10:48).
///
/// So the median is an input in its own right, and the banner is refreshed once the changes have landed: a `@Published`
/// sink runs in willSet, before the value lands, so a refresh driven from inside one reads the others as they were. The
/// signals are merged and debounced to the end of the main queue's current turn, where the heart rate, the link and the
/// median all read as they now are. A clear moves several of them in one turn, and makes one refresh instead of one per
/// value.
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
