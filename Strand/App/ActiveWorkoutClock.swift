import Foundation

/// The ONE pause-aware elapsed calculation for an in-flight workout, shared by every surface that shows
/// its clock.
///
/// #1533 added Pause/Resume to the full-screen live workout view and taught THAT view's timer to subtract
/// the paused time. The Today "workout in progress" indicator and the Live tab's active-workout card were
/// not part of it: both still read `now - start`. So pausing froze one clock and left two others counting
/// up, and a wearer who paused and backed out saw the session apparently still running. The saved duration
/// was correct the whole time, which is what made it confusing rather than merely wrong — the only
/// evidence on screen contradicted the button that had just been pressed.
///
/// Kept pure and in one place so a new surface cannot reintroduce the divergence by open-coding the
/// subtraction again. Twin of Kotlin `ActiveWorkoutClock`.
enum ActiveWorkoutClock {

    /// Seconds of ACTIVE time: wall time since `start`, minus every completed pause, minus the one still
    /// open if the session is paused right now.
    ///
    /// Clamped at zero so a clock-skew negative reads 0:00 rather than counting backwards. The open-pause
    /// term is deliberately NOT clamped on its own: the single clamp on the result is what the Kotlin twin
    /// does, and two clamps would disagree with it for a `pausedAt` in the future.
    ///
    /// Twin of Kotlin `ActiveWorkoutClock.activeElapsedSeconds` — the NAMES differ (this one takes
    /// `Date`/`TimeInterval`, that one Long milliseconds), so neither turns up in a grep for the other.
    /// Same arithmetic and the same single clamp; the platforms truncate to whole seconds at different
    /// points and agree because both truncate toward zero.
    static func activeElapsed(start: Date, pausedAt: Date?, pausedDuration: TimeInterval,
                              now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(start) - pausedDuration
            - (pausedAt.map { now.timeIntervalSince($0) } ?? 0))
    }

    /// `M:SS` up to an hour, `H:MM:SS` once an hour has passed, so a 90-minute session reads "1:30:00"
    /// rather than "90:00". Negative input clamps to "0:00".
    ///
    /// The Live card used to carry its own `%d:%02d` formatter with no hour roll-over at all, so a long
    /// session read "90:00" there while the Today indicator beside it read "1:30:00" — and Android's
    /// shared `elapsedClock` documents itself as mirroring the iOS one, which by then it no longer did.
    /// Twin of Kotlin `elapsedClock`.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
