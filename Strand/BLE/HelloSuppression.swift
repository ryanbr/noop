import Foundation
import WhoopProtocol

/// Whether to send the WHOOP 5/MG CLIENT_HELLO at all on this connect.
///
/// The #1635 field captures show the hello is what ends the link. Across two sessions and sixteen writes it
/// was never once acknowledged, and the drop is locked to the HELLO rather than to the connect: 3.158s,
/// 3.159s, 3.155s after the write, cycle after cycle, while live HR streams happily over the standard
/// profile the whole time.
///
/// An HCI capture later established the cause: the phone transmits an SMP Pairing Request and the strap
/// answers `Pairing Not Supported` (0x05). The refusal is categorical — the encrypted bond this hello waits
/// behind can never arrive on a 5/MG — so the write is a handshake that has never once succeeded knocking a
/// strap that CAN deliver live HR off every few seconds.
///
/// Suppressing it after the give-up latches trades an unreachable capability (puffin commands, history
/// offload) for one that demonstrably works (continuous live HR) — the "Live HR, not fully paired" state
/// the app already models (#69), reached deliberately instead of never at all.
///
/// [userInitiated] always re-attempts: suppression is a fallback for automatic reconnects, never a
/// permanent verdict. Someone who puts the strap in pairing mode and presses Connect must get a fresh try,
/// and that is also how the suppression is cleared.
///
/// Kotlin twin: `com.noop.ble.shouldSendClientHello`.
func shouldSendClientHello(suppressedForDevice: Bool, userInitiated: Bool) -> Bool {
    !suppressedForDevice || userInitiated
}

/// Should the give-up latch suppress the hello, rather than pause auto-reconnect?
///
/// The two give-up causes want opposite treatment, which is why they are split here rather than sharing
/// one branch:
///
///  - An AUTH REFUSAL means the strap actively declined the encrypted bond — typically because it is still
///    held by the official WHOOP app. Reconnecting cannot help until the user acts, so pausing is right.
///  - An UNANSWERED HANDSHAKE means the write vanished. The link itself is healthy and streaming, so
///    pausing throws away working live HR to punish a handshake nobody is waiting on. Suppress the hello
///    and stay connected instead.
///
/// Splitting them is the whole point: before this, both ended in the same pause, so the strap that could
/// still deliver HR was treated exactly like the one that could not.
///
/// Kotlin twin: `com.noop.ble.giveUpSuppressesHello`.
func giveUpSuppressesHello(authRefusal: Bool) -> Bool { !authRefusal }

/// Does this disconnect count as the strap refusing to bond?
///
/// Two observations mean the same thing for the purpose of giving up: the strap answered the bond write
/// with INSUFFICIENT_AUTHENTICATION / INSUFFICIENT_ENCRYPTION, or it never answered the CLIENT_HELLO at
/// all. The second was invisible to the give-up on this platform, because the gate tested only the write
/// error — and an unanswered handshake produces no write error at all, just a link that drops a few
/// seconds later. The consequence is the loop #1635 describes, with nothing able to end it.
///
/// Deliberately does NOT widen what counts as an AUTH refusal — [helloUnacked] is a separate signal carried
/// separately, so the user-facing guidance can stay honest about which was observed. An auth refusal
/// supports naming a cause; an unanswered handshake does not.
///
/// Pure so the rule is unit-tested without a radio. Kotlin twin: `com.noop.ble.countsAsBondRefusal`.
func countsAsBondRefusal(
    isAuthRefusalStatus: Bool,
    helloUnacked: Bool,
    alreadyBonded: Bool,
    family: DeviceFamily
) -> Bool {
    if alreadyBonded { return false }        // bonded already — not a pairing problem
    if family != .whoop5 { return false }    // the 4.0 bonds cleanly; this is the 5/MG handshake
    return isAuthRefusalStatus || helloUnacked
}

/// UserDefaults key holding the hello-suppression latch for one strap.
///
/// Per device, and lowercased for the same reason the firmware key is: the same strap can present its
/// identifier in different cases across sessions, and a case-sensitive key would silently latch a second
/// time under a second key instead of reading the first.
///
/// DIVERGENCE FROM ANDROID (deliberate, PII): the identifier here is the CoreBluetooth-local peripheral
/// UUID, which is per-install rather than the hardware address. The key SHAPE is shared with the Kotlin
/// twin so the two are recognisably the same latch; the value that goes into it is not the same kind of
/// identifier, and deliberately so.
///
/// Kotlin twin: `com.noop.ble.helloSuppressionPrefKey`.
func helloSuppressionPrefKey(_ peripheralId: String?) -> String? {
    guard let raw = peripheralId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    return "noop.helloUnanswered.\(raw.lowercased())"
}

/// Read/write the per-strap hello-suppression latch. Kept beside the key helper so no caller hand-rolls
/// the key, which is how the Android side ended up with a case-sensitivity bug worth a comment.
enum HelloSuppressionStore {
    static func suppressed(_ peripheralId: String?) -> Bool {
        guard let key = helloSuppressionPrefKey(peripheralId) else { return false }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setSuppressed(_ peripheralId: String?, _ suppressed: Bool) {
        guard let key = helloSuppressionPrefKey(peripheralId) else { return }
        if suppressed {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            // Remove rather than store false: an absent key and a false one mean the same thing, and this
            // keeps a strap that never latched from leaving a permanent entry behind.
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// May the keep-alive timer do its work on this link?
///
/// #1635: the timer used to gate on the genuine encrypted bond alone. A SUPPRESSED 5/MG never reaches
/// one, so that gate switched the whole timer off for exactly the link the suppression keeps up for
/// hours — taking the liveness watchdog with it and leaving a stalled stream with nothing to bounce it.
/// The stable-live-HR promise would have quietly depended on a stream nothing was watching.
///
/// So a 5/MG that is STREAMING (`bonded` is the live-HR shortcut of #8/#69, set when HR actually arrives
/// over the standard profile) is admitted too. Deliberately narrower than the Android twin, which admits
/// any `bonded` link: here it is 5/MG only, and only as far as the watchdog — the caller re-guards on the
/// real bond before anything puffin-framed, which an unbonded link cannot land anyway.
///
/// Pure so the rule is pinned without a radio.
func keepAliveMayRun(connected: Bool, didBond: Bool, bonded: Bool, family: DeviceFamily) -> Bool {
    guard connected else { return false }
    if didBond { return true }
    return bonded && family == .whoop5
}
