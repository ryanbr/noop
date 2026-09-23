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
/// Now a banner that exists is kept and shows what is true — the dash when the link is down or the strap is not
/// measuring — so it comes back by itself; it ends only when its switch is off or another banner actually on screen
/// takes its place (a Lift Log session, a sync started in the foreground). A new one is asked for only in the
/// foreground, with a heart rate to show.
///
/// Pure and platform-free so `StrandTests` covers it; the controller it serves is in the iOS app target.
enum LiveHRBannerLifecycle {

    enum Step: Equatable { case nothing, start, push, end }

    /// `showing`: a banner exists. `standsAside`: another NOOP banner is on screen. `linkUp`: the strap is connected.
    static func step(switchOn: Bool, standsAside: Bool, linkUp: Bool, bpm: Int?,
                     showing: Bool, appActive: Bool) -> Step {
        guard switchOn, !standsAside else { return showing ? .end : .nothing }
        if showing { return .push }
        return linkUp && bpm != nil && appActive ? .start : .nothing
    }
}
