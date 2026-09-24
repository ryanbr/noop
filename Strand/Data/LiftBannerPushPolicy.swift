import Foundation

/// When a new heart rate is worth pushing the gym session's Lock Screen banner.
///
/// WHY THIS EXISTS. Live heart rate arrives once a second while a strap streams, and the banner shows it.
/// Pushing the banner for each one spends the phone twice over: every push wakes the widget extension to
/// re-render the Lock Screen and the Dynamic Island, and ActivityKit budgets how often an app may update an
/// activity — an app that spends that budget on a number nobody is reading has none left for the update that
/// matters, the one carrying the light-up alert on a strap double-tap. On 22 Sep 2026 a 75-minute session sent
/// about 450 heart-rate pushes (one per 10 s) and 30 alerts, and the light-ups ran 5–10 seconds late for the
/// middle of the session while the buzz stayed immediate.
///
/// So a heart rate alone moves the banner rarely: only when it has changed enough to read differently, and not
/// more often than `interval`. Everything else a person would notice — the stage, the set, the numbers — still
/// pushes at once, carrying whatever the heart rate is at that moment, and the clocks tick client-side without
/// any push at all. Appearing or disappearing (the strap dropping, or coming back) is a visible change rather
/// than a moving number, so it is allowed sooner.
///
/// Pure and platform-free so `StrandTests` covers it: `StrandTests` runs on macOS and cannot exercise
/// ActivityKit, so the rule has to live outside the controller to be unit tested at all. (The controller
/// itself IS compiled in CI, by `app-build.yml`'s `NOOPiOS` leg.)
enum LiftBannerPushPolicy {

    /// The shortest time between two pushes caused by the heart rate alone. A glance at the Lock Screen
    /// between sets wants a number that is current to the set, not to the second.
    static let interval: TimeInterval = 30

    /// How far the heart rate must have moved to be worth a push of its own. Under this it is the same
    /// reading with noise on it.
    static let step = 2

    /// The floor for the strap appearing or disappearing (a number becoming "—", or the reverse): rare, and
    /// a visible change of state rather than a moving number.
    static let presenceInterval: TimeInterval = 5

    /// `shown` is the heart rate the banner is currently showing, `latest` what the app has now; nil is the
    /// dash the banner shows with no live strap. `sinceLastPush` is how long ago the banner was last pushed
    /// for any reason.
    static func heartRateDue(shown: Int?, latest: Int?, sinceLastPush: TimeInterval) -> Bool {
        switch (shown, latest) {
        case let (shown?, latest?):
            return abs(latest - shown) >= step && sinceLastPush >= interval
        case (nil, nil):
            return false
        default:
            return sinceLastPush >= presenceInterval
        }
    }
}
