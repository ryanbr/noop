import Foundation

/// What a WHOOP 4.0 confirmed-write acknowledgement records on the current link.
///
/// The ack is the per-connection proof of the encrypted bond (#69): `didConnect` clears `encryptedBond` so
/// each link earns it again at this site. `didBond` is cleared only by the disconnect callback, and
/// CoreBluetooth sends no disconnect when the Mac's Bluetooth radio powers off. On the next `poweredOn` the
/// app re-attaches to the strap macOS still holds, so `didConnect` arrives with `didBond` still true.
/// Recording the bond only when `didBond` was false then never re-proved it: the strap read "Live HR (not
/// fully paired)" for the rest of the link while history sync, which `didBond` gates, kept working, and
/// buzz, which `encryptedBond` gates, was refused.
///
/// Pure so the rule is unit-tested without a radio.
enum Whoop4BondAck: Equatable {
    /// The first bond on this link: record it and run the post-bond bookkeeping.
    case firstBond
    /// Already bonded, but a re-entered `didConnect` cleared the encrypted flag: this ack restores it.
    case reprove
    /// Already bonded and already proven on this link: nothing to record.
    case alreadyProven

    static func classify(didBond: Bool, encryptedBond: Bool) -> Whoop4BondAck {
        if !didBond { return .firstBond }
        return encryptedBond ? .alreadyProven : .reprove
    }
}
