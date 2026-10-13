import Foundation

/// What became of a WHOOP 5/MG CLIENT_HELLO write.
///
/// A capture could not previously distinguish the three ways the 5/MG bond fails, because two of them
/// produce no line at all. In one field capture 14 of 16 CLIENT_HELLO writes went out and were never
/// acked, 1 was rejected by the stack, and 1 produced an "ack" — from a completion the code never checked
/// the characteristic of (#1635). From the log those look the same: silence, then a link drop.
///
/// The three outcomes, and why each matters:
///  - acked by the hello characteristic: the only one that is genuinely an ack.
///  - a completion from a DIFFERENT characteristic while the bond is pending: the ack branch matches on
///    family alone, so this is what silently sets `encryptedBond` on a strap that never bonded — and the
///    line names the characteristic that did it.
///  - no callback at all before the link dropped: the dominant case in the field capture, and the one
///    with no evidence today.
///
/// Reports only what it observed; it does not attribute blame between the strap and the local stack,
/// because a write callback that never arrives cannot distinguish "the strap declined to respond" from
/// "the frame never reached the air". Naming the gap is what makes that answerable next.
///
/// `status` is passed pre-rendered so each platform supplies its own, leaving the line shape identical.
/// Pure. Kotlin twin: `com.noop.ble.clientHelloOutcomeLine`.
enum ClientHelloOutcome {
    static func line(isHelloChar: Bool, charUuid: String?, elapsedMs: Int, status: String?) -> String {
        guard let charUuid else {
            return "CLIENT_HELLO outcome: NO write callback after \(elapsedMs)ms — the link dropped before"
                + " the stack reported, so the strap may never have seen it"
        }
        let where_ = charUuid.trimmingCharacters(in: .whitespaces).isEmpty ? "unknown" : charUuid
        let st = (status?.trimmingCharacters(in: .whitespaces).isEmpty == false) ? " \(status!)" : ""
        if isHelloChar {
            return "CLIENT_HELLO outcome: acked by \(where_) after \(elapsedMs)ms\(st)"
        }
        return "CLIENT_HELLO outcome: bond declared from a DIFFERENT characteristic \(where_) after"
            + " \(elapsedMs)ms\(st) — this is NOT a CLIENT_HELLO ack (#1635)"
    }

    /// What a CLIENT_HELLO write completion records on the current 5/MG link.
    ///
    /// The twin of `Whoop4BondAck`, for the same defect on the other family. `didConnect` clears
    /// `encryptedBond` so each link earns it again at the ack site, and that clear has to precede the
    /// `connectedPeripheralUUID` publish (SourceCoordinator's #52 re-adoption gate reads the flag at that
    /// instant). `didBond` is cleared only by the disconnect callback, and CoreBluetooth sends no
    /// disconnect when the Mac's Bluetooth radio powers off. So a `didConnect` that re-enters a live link
    /// arrives with `didBond` still true and `encryptedBond` false.
    ///
    /// A fresh CLIENT_HELLO IS written on that re-entry: the write sits in `didDiscoverCharacteristics`,
    /// not behind the once-per-connection handshake guard, so re-discovery sends it again. Its completion
    /// then reached `isAck`, which declines on `alreadyBonded` and left the strap reading "Live HR (not
    /// fully paired)" for the rest of the link, with buzz refused, while history sync kept working.
    ///
    /// Re-proving demands the SAME evidence a first bond does, the hello's own completion inside its own
    /// outstanding window, so an offload ack on fd4b0002 can no more restore the flag than it could set
    /// it. Only the `alreadyBonded` disqualification is lifted, and only when the flag was cleared.
    ///
    /// `alreadyBonded` is process-global while the ack is evidence about ONE peripheral, so re-proving also
    /// asks whether this is the strap the recorded bond came from. See `Whoop4BondAck` for why that window
    /// exists and why a different strap's own ack is routed to `firstBond` rather than refused.
    ///
    /// Pure, so the rule is tested without a radio. Android tears this link down at the radio-off edge
    /// (#314) and so has no state to re-prove from; there is no Kotlin counterpart to pair with.
    enum HelloAck: Equatable {
        /// The hello's own completion on an unbonded link: record the bond and run the post-bond work.
        case firstBond
        /// Already bonded, but a re-entered `didConnect` cleared the encrypted flag: restore it.
        case reprove
        /// Already bonded and still proven on this link: nothing to record.
        case alreadyProven
        /// Not the hello's ack at all (a foreign completion, a queued command, or a WHOOP 4.0 link).
        case notAnAck
    }

    /// Classify one write completion on a 5/MG link. See `HelloAck`.
    static func classify(
        isHelloChar: Bool,
        helloOutstanding: Bool,
        alreadyBonded: Bool,
        encryptedBond: Bool,
        samePeripheralAsBond: Bool,
        isWhoop5: Bool
    ) -> HelloAck {
        guard isWhoop5, isHelloChar, helloOutstanding else { return .notAnAck }
        if !alreadyBonded { return .firstBond }
        if !samePeripheralAsBond { return .firstBond }
        return encryptedBond ? .alreadyProven : .reprove
    }

    /// Is this write completion genuinely the CLIENT_HELLO's ack, and therefore proof of an encrypted bond?
    ///
    /// The bond branch used to match on family alone: on a 5/MG link, ANY completion that arrived while
    /// `didBond` was false was taken as the ack and set `encryptedBond`. A characteristic check on its own
    /// does not fix that, because the puffin command characteristic (fd4b0002) carries BOTH the
    /// CLIENT_HELLO and every ordinary command — DISABLE_ALARM is written there on the same connect — so
    /// the hello and an unrelated command are indistinguishable by uuid.
    ///
    /// What separates them is whether a hello is actually OUTSTANDING, which is why both conditions are
    /// required and neither is redundant:
    ///  - `isHelloChar` alone admits DISABLE_ALARM and every other puffin command.
    ///  - `helloOutstanding` alone admits a completion from a different characteristic that happens to
    ///    land inside the hello's window.
    ///
    /// Declining does not claim the strap refused anything — it says only that THIS completion is not
    /// evidence of a bond. A real ack still arrives on its own callback and still bonds.
    ///
    /// Pure, so the rule is tested without a radio. Kotlin twin: `completionIsClientHelloAck`.
    static func isAck(
        isHelloChar: Bool,
        helloOutstanding: Bool,
        alreadyBonded: Bool,
        isWhoop5: Bool
    ) -> Bool {
        classify(isHelloChar: isHelloChar,
                 helloOutstanding: helloOutstanding,
                 alreadyBonded: alreadyBonded,
                 encryptedBond: false,
                 samePeripheralAsBond: true,
                 isWhoop5: isWhoop5) == .firstBond
    }

    /// A pre-bond write completion on a 5/MG link that arrived with NO CLIENT_HELLO outstanding.
    ///
    /// `isAck` declines these, and without a line it declines in SILENCE — which is worse for a capture
    /// than the wrong answer it replaces. The field log for #1635 said "CLIENT_HELLO acked — link
    /// established" here; the honest replacement is not nothing, it is "a completion arrived and it was
    /// not the hello's". Without it the reader cannot tell a completion arrived at all.
    ///
    /// Names the characteristic because the whole point is that fd4b0002 carries traffic other than the
    /// hello, and the reader needs to see WHICH command completed.
    ///
    /// Pure. Kotlin twin: `clientHelloDeclinedLine`.
    static func declinedLine(charUuid: String?, status: String?) -> String {
        let uuid = charUuid?.trimmingCharacters(in: .whitespaces) ?? ""
        let whereFrom = uuid.isEmpty ? "unknown" : uuid
        let trimmedStatus = status?.trimmingCharacters(in: .whitespaces) ?? ""
        let st = trimmedStatus.isEmpty ? "" : " \(trimmedStatus)"
        return "CLIENT_HELLO outcome: completion from \(whereFrom)\(st) with NO hello outstanding — not a bond,"
            + " so the link stays unbonded (#1635)"
    }

    /// The shortest an ATT round trip can plausibly take, in milliseconds.
    ///
    /// BLE's minimum connection interval is 7.5ms. A peripheral may answer inside the same connection
    /// event, so this is not a hard floor and is NOT used to reject anything — it decides only whether
    /// the log points the reader at the timing. It earns its place from the field distribution, which is
    /// starkly bimodal: across 41 captures every hello either "completed" in 0, 4, 5 or 7ms, or produced
    /// no callback at all about 3150ms later. Nothing in between, and 0ms cannot be a round trip at all.
    ///
    /// Byte-identical to the Android twin `MIN_PLAUSIBLE_ATT_ROUND_TRIP_MS`.
    static let minPlausibleAttRoundTripMs = 8

    /// #1883: a timing tell for Apple, where CoreBluetooth exposes no link-encryption state.
    ///
    /// On Android, `helloCompletionProvesEncryptedBond(osBonded) = osBonded` — only the OS bond state
    /// attests encryption. CoreBluetooth exposes no bond state at all, so Apple has nothing to supply
    /// for that check. The gap is real: a completion that is faster than one connection interval did
    /// NOT come from the strap, and that is exactly the signature of #1635's false bond — a
    /// `DISABLE_ALARM` completion misread as a hello ack because it arrived in 5ms.
    ///
    /// This line does NOT change any behavior. The bond still proceeds, the handshake still runs, and
    /// `encryptedBond` is still set — because on Apple there is no alternative source of truth, and
    /// refusing to bond would break every strap that genuinely bonds. The line only says what is
    /// UNKNOWN: that the completion was suspiciously fast and the link's encryption state cannot be
    /// verified on this platform. It is the diagnostic the issue's direction 2 asks for, and it is the
    /// one that would have made #1635 visible on Apple instead of only on Android.
    ///
    /// Pure. No Kotlin twin — this is Apple-only by design (Android has `helloAckedWithoutEncryptionLine`
    /// for the case where the OS bond state IS available and disagrees).
    static func unverifiedBondTimingLine(elapsedMs: Int) -> String? {
        guard elapsedMs < minPlausibleAttRoundTripMs else { return nil }
        return "CLIENT_HELLO outcome: acked after \(elapsedMs)ms — under one BLE connection interval,"
            + " so the callback most likely came from the local stack rather than the strap. CoreBluetooth"
            + " exposes no link-encryption state, so the bond is UNVERIFIED on this platform (#1883, #1635)."
            + " The handshake proceeds because there is no alternative source of truth on Apple."
    }
}

