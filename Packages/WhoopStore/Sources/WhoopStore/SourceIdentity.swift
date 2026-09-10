import Foundation

/// Which registry device a live BLE link's samples belong to (#1881).
///
/// Split out of `BLEManager` because it is the whole of the decision and none of the CoreBluetooth: BLE
/// behaviour cannot be tested in CI, but *this* can, and it is the part that silently files rows under the
/// wrong device when it is wrong. The Kotlin twin is `com.noop.ble.SourceIdentity`.
///
/// The bug it exists to prevent: `BLEManager` held one `deviceId` meaning "the active device" and reused it
/// as "the device these bytes came from". Those were the same thing only while every registered device was
/// a WHOOP. Once a ring could be active, a WHOOP connection filed its samples — including `stepSample` and
/// `gravitySample`, which only a strap can produce — under the ring's id.
public enum SourceIdentity {

    /// The device id this connection's samples should be stored under, or nil to leave the current id alone.
    ///
    /// Conservative by construction. It returns an id ONLY when a registry row is both matched by peripheral
    /// and a WHOOP, so every uncertain case keeps today's behaviour rather than guessing:
    ///   • `address` nil, or no row carries it → nil. This is the legacy single-WHOOP row before it has
    ///     adopted a `peripheralId`; the coordinator adopts one on this same connect, so the next resolves.
    ///   • the matched row is not a WHOOP → nil. Nothing else should be arriving on the WHOOP delegate, and
    ///     if it does, re-pointing the strap's id at it would be the very bug this prevents.
    ///   • the matched row is already the current id → nil, so there is no write on the common path.
    ///
    /// Matching is case-insensitive because the two platforms disagree about case: Apple stores an uppercase
    /// `CBPeripheral.identifier.uuidString`, Android an uppercase MAC — but neither is guaranteed by the OS,
    /// and a row written by an older build may carry either.
    public static func resolve(address: String?, rows: [PairedDevice], currentId: String) -> String? {
        // BLANK, not merely empty, so the two platforms agree: Kotlin's `isNullOrBlank` refuses a
        // whitespace-only address, and a bare `isEmpty` here would let one match a stored blank.
        guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let row = rows.first(where: {
            guard let pid = $0.peripheralId else { return false }
            return pid.caseInsensitiveCompare(address) == .orderedSame
        }) else { return nil }
        guard isWhoop(row), row.id != currentId else { return nil }
        return row.id
    }

    /// A device is a WHOOP when it is the seeded legacy row or its brand says so. Kept here beside the
    /// resolver rather than reaching into the app target, so this file has no dependency to test around.
    /// Byte-identical to `SourceCoordinator.isWhoop` on both platforms.
    public static func isWhoop(_ device: PairedDevice) -> Bool {
        device.id == "my-whoop" || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }
}
