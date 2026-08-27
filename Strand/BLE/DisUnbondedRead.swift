import Foundation

/// Should NOOP try reading the Device Information Service on a 5/MG that has NOT bonded?
///
/// `readDisIdentity` is issued only inside the post-bond handshake, so a strap that never bonds never
/// reads DIS at all — and since #1635 the suppression makes that state PERMANENT rather than transient.
/// The Devices screen shows a WHOOP 4.0 with its firmware beside a 5/MG with none. The firmware, the
/// serial and the MG-vs-5.0 hardware revision all sit behind the same bond that never happens.
///
/// Whether they NEED that bond is unproven, and the evidence is one-sided in an uncomfortable way.
/// Standard NOTIFICATIONS demonstrably work unbonded — live HR and battery both arrive that way on
/// exactly these straps — but nothing shows a standard READ working unbonded, and this file's own
/// platform carries the #490 note that a 5/MG refuses standard reads on an unencrypted link. A read is
/// also the same class of operation as the write that has been provoking the teardown, so this can
/// plausibly cost the stable link the suppression just bought.
///
/// Hence: once per device, and never again after a refusal. [previouslyRefused] is persisted, so a strap
/// that says no says it once rather than on every reconnect forever. That makes the experiment
/// self-limiting in the same way the hello suppression is — "keeps trying something that will never
/// work" is the failure mode this whole area keeps producing.
///
/// A refusal is a RESULT, not a defeat: it settles #490, which no capture has ever done.
///
/// Kotlin twin: `com.noop.ble.shouldReadDisUnbonded`.
func shouldReadDisUnbonded(
    isWhoop5: Bool,
    bonded: Bool,
    alreadyReadThisLink: Bool,
    previouslyRefused: Bool
) -> Bool {
    if !isWhoop5 { return false }
    if bonded { return false }            // the post-bond path already covers this
    if alreadyReadThisLink { return false }
    return !previouslyRefused
}

/// Persisted key for "this strap refused an unbonded DIS read". Per device and lowercased, for the same
/// reason the hello-suppression key is.
///
/// DIVERGENCE FROM ANDROID (deliberate, PII): the identifier here is the CoreBluetooth-local peripheral
/// UUID, per-install rather than the hardware address. Same key SHAPE, different kind of identifier.
///
/// Kotlin twin: `com.noop.ble.disRefusedPrefKey`.
func disRefusedPrefKey(_ peripheralId: String?) -> String? {
    guard let raw = peripheralId?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    return "noop.disRefused.\(raw.lowercased())"
}

/// The line for a DIS read that came back with a failure status.
///
/// Without it the read fails into the generic notify-failure line, so a capture cannot tell a refusal
/// from a read that was never issued. That is the same ambiguity that made the CLIENT_HELLO failure
/// unreadable for eleven weeks, and it is not worth reproducing.
///
/// Insufficient authentication / encryption are the interesting answers: they say the strap requires an
/// encrypted link for this read, which settles #490 and means the firmware simply cannot be had without
/// a bond.
///
/// Pure. Byte-identical to the Kotlin `disReadFailureLine`.
func disReadFailureLine(uuid: String, status: String) -> String {
    "DIS: read of \(uuid) failed \(status) — the strap declined it on this link. If this is an insufficient-authentication or -encryption status, DIS needs an encrypted bond and the firmware cannot be read without one (#490)"
}

/// Should the standard Device Information Service firmware string be published for this strap?
///
/// A 5/MG that never completes the puffin handshake has no firmware to show, because the only source
/// NOOP reads it from is a framed command that needs the bond. DIS `0x2A26` sits in the same service the
/// serial and hardware revision come from; it was simply never asked for on this platform.
///
/// DIS is a FALLBACK, never an override. The puffin value is the strap's own report of the firmware it
/// is running and is what the 4.0 has always shown; DIS is whatever the device chose to publish in its
/// standard profile, and the two are not guaranteed to agree. So this yields to anything already decoded
/// rather than racing it — the decode lands later in the connect, and a value that appeared and then
/// changed would be worse than one that arrived once.
///
/// Kotlin twin: `com.noop.ble.shouldPublishDisFirmware`.
func shouldPublishDisFirmware(disFirmware: String?, alreadyDecoded: String?) -> Bool {
    guard let dis = disFirmware, !dis.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    guard let decoded = alreadyDecoded else { return true }
    return decoded.trimmingCharacters(in: .whitespaces).isEmpty
}
