import Foundation

/// When NOOP's Live HR banner (the Lock Screen / Dynamic Island Live Activity) is worth a push.
///
/// WHY THIS EXISTS. The banner is driven off the live heart-rate stream, which ticks about once a second for as
/// long as a strap stays connected, and it used to be pushed on the first tick more than 2 s after the last
/// push — every ~3 s, 1,200 times an hour — whether or not anything on it had changed. Each push wakes the
/// widget extension to re-render the Lock Screen and the Dynamic Island, and ActivityKit budgets how often an
/// app may update an activity. The banner shows three numbers — the smoothed
/// heart rate, recovery and effort — and the smoothed heart rate is a 10-second median that holds still across
/// most ticks, so most of those pushes re-drew exactly what was already on screen.
///
/// So the banner is pushed when what it shows has changed (still no more often than `minimumSpacing`), and an
/// unchanged banner is re-pushed only often enough to keep its stale date ahead of it. What the banner shows,
/// and how soon a new number reaches it, is unchanged. This is the rule Android's connection notification has
/// followed since #216: re-post only when a rendered field changes.
///
/// Pure and platform-free so `StrandTests` covers it: the controller it serves lives in the iOS app target,
/// which no CI job compiles (`AGENTS.md`).
enum LiveHRBannerPushPolicy {

    /// The shortest time between two pushes, as before: well under ActivityKit's update budget.
    static let minimumSpacing: TimeInterval = 2

    /// `shown` is what the banner was last pushed with (nil when this controller has pushed nothing yet, so the
    /// first update always goes out), `next` what it would show now. `sinceLastPush` is how long ago the last
    /// push was; `staleAfter` is the stale date each push carries. An unchanged banner is re-pushed once half of
    /// that has passed, so it never reaches its stale date while the strap is connected.
    static func due<Content: Equatable>(shown: Content?, next: Content, sinceLastPush: TimeInterval,
                                        staleAfter: TimeInterval) -> Bool {
        guard sinceLastPush > minimumSpacing else { return false }
        return shown != next || sinceLastPush >= staleAfter / 2
    }
}
