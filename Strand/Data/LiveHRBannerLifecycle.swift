import Foundation

/// What NOOP's Live HR banner does with the latest live values: start, push, end, or nothing.
///
/// WHY THIS EXISTS. iOS lets an app START a Live Activity only while it is on screen; one already running can be
/// updated from the background. The banner used to be ENDED whenever the strap's link dropped and whenever a history
/// sync ran — including the automatic one every 15 minutes, which in the background shows no sync banner at all —
/// so within minutes of leaving NOOP it was gone, and it stayed gone until NOOP was opened again. A tester's log
/// held three link timeouts in one afternoon, each recovered within seconds (23 Sep 2026). Meanwhile, with no banner
/// and the app in the background, every heart-rate tick asked iOS for a new one and was refused.
///
/// So NOOP never ends the banner for something that passes: not for a dropped link however long, not for a strap off
/// the wrist, not for a sync, not for having nothing to show while NOOP is on screen. It shows the dash then (iOS
/// draws it at the banner's stale date even while NOOP is suspended) and the number again by itself; a banner NOOP
/// ended could come back only once NOOP was opened, which the tester found illogical (24 Sep 2026). It ends only when
/// its switch is turned off — the one way to be rid of it — or while the Lift Log banner, which carries the heart
/// rate itself, is on screen. A new one is asked for only in the foreground, with the strap connected, whether or not
/// a heart rate has arrived yet.
///
/// iOS itself ends a Live Activity about eight hours after it was started. So when NOOP is on screen with a banner
/// more than `renewAfter` old, it starts a fresh one and then lets the old one go (`renew`): each time NOOP is opened
/// the banner has most of those hours ahead of it again. The swap happens while NOOP is in front, with the Lock Screen
/// out of sight, and the new banner exists before the old one ends, so there is no moment without one.
///
/// Pure and platform-free so `StrandTests` covers it; the controller it serves is in the iOS app target.
enum LiveHRBannerLifecycle {

    enum Step: Equatable { case nothing, start, push, renew, end }

    /// A banner older than this is replaced by a fresh one while NOOP is on screen.
    static let renewAfter: TimeInterval = 60 * 60

    /// `showing`: a banner exists, started `age` ago (nil when NOOP does not know, which counts as old).
    /// `standsAside`: the Lift Log banner is on screen. `linkUp`: the strap is connected. `appActive`: NOOP is on
    /// screen, the only time iOS lets it start a banner.
    static func step(switchOn: Bool, standsAside: Bool, linkUp: Bool, showing: Bool, age: TimeInterval?,
                     appActive: Bool) -> Step {
        guard switchOn, !standsAside else { return showing ? .end : .nothing }
        if showing { return appActive && (age ?? .infinity) >= renewAfter ? .renew : .push }
        return linkUp && appActive ? .start : .nothing
    }
}
