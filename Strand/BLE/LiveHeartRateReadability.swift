import Foundation
import WhoopProtocol

/// Whether a standard heart-rate sample (0x2A37) is one NOOP may show as the live heart rate, and when a run of
/// samples that are not clears what is shown.
///
/// A sample with a heart rate outside 30–220 bpm (0 included), or whose skin-contact flag says contact is not
/// detected, used to be refused without touching what was shown, so the last readable heart rate stayed on Today,
/// the Live screen, the Lock Screen and the Dynamic Island for as long as the link lasted. A run of `clearAfter`
/// such samples now clears it; a single one does not, so a glitch while the strap is worn cannot blank the number.
/// A WRIST_OFF event clears it at once (`FrameRouter`). If the strap stops notifying altogether, this sees nothing
/// and the link's own watchdog is what ends it.
///
/// What is stored is unchanged: every sample still reaches the collector as it arrived.
struct LiveHeartRateReadability {
    /// Unreadable samples in a row before the shown heart rate is cleared; about three seconds at 1 Hz.
    static let clearAfter = 3

    private(set) var unreadableRun = 0

    static func isReadable(bpm: Int, contact: StandardHRContact) -> Bool {
        (30...220).contains(bpm) && contact != .supportedNotDetected
    }

    /// Feed one sample. True exactly once per run of unreadable samples: on the one that makes it `clearAfter` long.
    mutating func clearsShownHeartRate(bpm: Int, contact: StandardHRContact) -> Bool {
        guard !Self.isReadable(bpm: bpm, contact: contact) else {
            unreadableRun = 0
            return false
        }
        unreadableRun += 1
        return unreadableRun == Self.clearAfter
    }
}
