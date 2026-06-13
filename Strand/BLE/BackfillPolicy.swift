import Foundation

/// What prompted a sync attempt. Mirrors WHOOP (15-min periodic floor + event-triggered "process now"
/// syncs + the strap's own prompt events + manual), adapted to iOS.
enum BackfillTrigger {
    case periodic    // the repeating timer while connected+bonded
    case connect     // a (re)connect / bond confirmation
    case foreground  // the app became active (scenePhase .active)
    case manual      // the user tapped "Sync now"
    case strap       // an incoming strap EVENT packet (WHOOP's HighFreqSyncPrompt analog)
}

/// Pure rate-limiter for historical-offload kicks. No BLE/store deps. Floors match WHOOP
/// (observed: ~15-min periodic + expedited event syncs).
enum BackfillPolicy {
    static let periodicFloorSeconds: TimeInterval = 900   // 15 min
    static let eventFloorSeconds: TimeInterval = 90       // absorbs reconnect-flaps / event bursts
    static let emptyBackoffThreshold = 3                  // empties before the floor starts stretching
    static let maxEmptyBackoff: Double = 4                // cap → ~6-min event / 1-hr periodic floor

    /// `emptyStreak` = consecutive COMPLETED offloads that banked no sensor records (EmptySyncTracker).
    /// Past the threshold the AUTOMATIC triggers (.periodic/.strap) stretch their floor — each further
    /// empty doubles it, capped — so we stop hammering an off-wrist / not-banking strap (#77/#120).
    /// `.manual`/`.connect`/`.foreground` never back off, and the first real record resets the streak,
    /// so baseline cadence resumes instantly — a user/connection-driven sync is never delayed.
    static func shouldRun(trigger: BackfillTrigger, now: TimeInterval,
                          lastBackfillAt: TimeInterval?, emptyStreak: Int = 0) -> Bool {
        guard let last = lastBackfillAt else { return true }
        let elapsed = now - last
        let backoff: Double = emptyStreak >= emptyBackoffThreshold
            ? min(pow(2.0, Double(emptyStreak - emptyBackoffThreshold + 1)), maxEmptyBackoff)
            : 1.0
        switch trigger {
        case .manual:                return true
        case .connect, .foreground:  return elapsed >= eventFloorSeconds
        case .strap:                 return elapsed >= eventFloorSeconds * backoff
        case .periodic:              return elapsed >= periodicFloorSeconds * backoff
        }
    }
}
