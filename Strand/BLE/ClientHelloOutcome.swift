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
}
