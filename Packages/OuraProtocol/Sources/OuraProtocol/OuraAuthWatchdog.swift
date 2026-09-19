import Foundation

/// Escalation policy for an auth handshake the ring does not answer (#2304).
///
/// The connect sequence is link up → discover → enable notifications → `get_nonce`, and from there the
/// app waits for the nonce. Nothing else is armed until `auth OK` reaches `.streaming` (the re-engage tick,
/// the history-fetch timer), so a ring that accepts the link and the subscription but never answers the
/// nonce left the session parked as "connected" until the OS dropped the link for its own reasons — on
/// the #2303 capture that was 52 and 55 minutes across five consecutive links. Healthy sessions never
/// wait: every answered `get_nonce` on file gets its nonce within the same second (one 5 s outlier over
/// ~270 handshakes), and the only `get_nonce` without a nonce are the ones where the link itself dropped
/// 1–3 s later — which takes the disconnect path and cancels the watchdog before it can fire.
///
/// Pure so it is testable without a `CBCentralManager` / `BluetoothGatt`; the transport owns the timer
/// and the writes, and asks this table what to do when the timer fires. Every step is one the transport
/// already makes on every connection (a `get_nonce` write, a CCCD toggle, a disconnect) — nothing new
/// is sent to the ring, and silence is never turned into a pairing verdict.
public enum OuraAuthWatchdog {
    /// How long a `get_nonce` may go unanswered before the first escalation. The healthy figure is
    /// ≤ 1 s with a single 5 s outlier; 10 s leaves room for a slow first connection and is still
    /// hundreds of times shorter than what happened on #2303. Re-armed after each escalation.
    public static let nonceTimeout: TimeInterval = 10

    /// What the transport should do when the nonce timer fires. Ordered: the sequence is
    /// `.resendNonce` → `.toggleNotify` → `.dropLink`, at most once each per session, then the link is
    /// dropped and the ordinary reconnect backoff takes over. No loop.
    public enum Step: Equatable, Sendable {
        /// Still inside the timeout (a timer fired early or was re-armed): keep waiting.
        case wait
        /// Re-send `get_nonce` once (1/3) — the write may simply not have reached the ring.
        case resendNonce
        /// Toggle the notify subscription off and back on, then re-send `get_nonce` (2/3) — a stale
        /// subscription delivers nothing, and the CCCD round-trip re-establishes it.
        case toggleNotify
        /// Cancel the connection and let the normal reconnect path bring the ring back (3/3).
        case dropLink
    }

    /// The escalation table. Kotlin twin of `OuraAuthWatchdog.step` (the Kotlin side takes milliseconds
    /// against `NONCE_TIMEOUT_MS`; same thresholds, same order, same attempt semantics).
    ///
    /// The claim is on the FUNCTION deliberately. `parity_ledger.resolved_file_pairs` derives file
    /// authority from resolved FUNCTION pairs, so a twin reference in the type or file header pairs
    /// nothing: this file and its Kotlin counterpart sat in `unpaired_files` with identical stems and a
    /// claim already on the Kotlin object, because neither side named a twin where the ledger reads one.
    ///
    /// - Parameters:
    ///   - secondsSinceNonceRequest: age of the most recent `get_nonce` write of this session.
    ///   - attempt: how many escalations have already been taken this session (0 = none yet).
    public static func step(secondsSinceNonceRequest: TimeInterval, attempt: Int) -> Step {
        guard secondsSinceNonceRequest >= nonceTimeout else { return .wait }
        switch attempt {
        case ..<1: return .resendNonce
        case 1:    return .toggleNotify
        default:   return .dropLink
        }
    }
}
