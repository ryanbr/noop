import Foundation
import Combine

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    // NOTE: do NOT auto-clear `pairingHint` when `bonded` flips true. On a 5/MG, `bonded` is also set by
    // the live-HR shortcut (BLEManager — HR over the unbonded standard profile), so clearing the hint
    // there hides the still-accurate "free the strap" guidance from users who are streaming HR but never
    // got the real encrypted bond (issue #69). The genuine bond path clears the hint itself (the
    // CLIENT_HELLO ack), and a fresh connect attempt resets it.
    @Published public var bonded: Bool = false
    @Published public var heartRate: Int? = nil
    @Published public var rr: [Int] = []
    @Published public var batteryPct: Double? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil
    /// Wrist-wear state from WRIST_ON/WRIST_OFF events. Defaults true so wear-gated features work
    /// before the first event arrives; flipped by FrameRouter on a real event.
    @Published public var worn: Bool = true
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    /// Fired (live only) when the strap reports a DOUBLE_TAP gesture. Wired by AppModel to the
    /// user's chosen action. Debounced in AppModel.
    public var onDoubleTap: (() -> Void)?
    /// Fired (live only) when wrist-wear changes (true = put on, false = taken off).
    public var onWristChange: ((Bool) -> Void)?

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    /// Number of WHOOP 5/MG ("puffin") frames captured this session (when frame capture is enabled in
    /// Settings → Experimental). Drives the capture status line + export button.
    @Published public var puffinCaptureCount: Int = 0
    /// On-disk location of the current puffin capture file, once anything has been flushed. The
    /// Settings "Export" / "Reveal" actions target this URL.
    @Published public var puffinCaptureURL: URL?

    /// Set when a WHOOP 5/MG strap refuses the encrypted bond on first connect ("Encryption/Authentication
    /// is insufficient") — CoreBluetooth won't start a fresh just-works bond against a strap still bonded to
    /// the official WHOOP app. Surfaced as actionable pairing-mode guidance; cleared once the link bonds.
    @Published public var pairingHint: String? = nil

    public init() {}

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
