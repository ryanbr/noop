import Foundation
import Combine
import WhoopStore

// MARK: - DeviceRegistry
//
// Observable @MainActor cache over the synchronous `DeviceRegistryStore` (device-foundation
// Task 5). The UI observes this for the paired-device list + the currently active device; the
// app's `deviceId` is sourced from `activeDeviceId` so it's "the active device's id" rather than
// the hardcoded "my-whoop" literal. Behaviour is unchanged today — migration v15 seeds a single
// 'my-whoop' row as `.active`, so the active id is still "my-whoop".
//
// `DeviceRegistryStore` is synchronous (its own GRDB queue, internally serialized), so the reads
// here are plain synchronous calls; we keep failures non-fatal and fall back to the seeded defaults.
@MainActor
final class DeviceRegistry: ObservableObject {
    /// All paired devices (any status), oldest-added first — the store's `all()` ordering.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id. Defaults to "my-whoop" so callers have a safe value before the
    /// first `reload()` and if the registry can't be read.
    @Published private(set) var activeDeviceId: String = "my-whoop"

    private let store: DeviceRegistryStore

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Load the device list and active id from the store. Best-effort: on any error the published
    /// values are left untouched (keeping the safe "my-whoop" fallback), never crashing.
    func reload() {
        guard let rows = try? store.all() else { return }
        devices = rows
        if let active = rows.first(where: { $0.status == .active })?.id {
            activeDeviceId = active
        }
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op delegates to the synchronous store, then `reload()`s so the published `devices` /
    // `activeDeviceId` reflect the change and the UI updates. Best-effort: a store failure leaves the
    // published state untouched (we never crash the UI on a write error).

    /// Add or upsert a paired device (the Add wizard's chosen strap). Refreshes the published list.
    func add(_ device: PairedDevice) {
        try? store.add(device)
        reload()
    }

    /// Make `id` the single active device. The store demotes whatever was active in the same
    /// transaction (invariant I1); changing `activeDeviceId` drives the `SourceCoordinator` to run the
    /// right live source.
    func setActive(_ id: String) {
        try? store.setActive(id)
        reload()
    }

    /// #771: re-point the active Oura device off its transient CoreBluetooth-UUID id onto its stable
    /// `oura-<serial>` id (read from the ring on connect), folding ONLY the active row's data + registry into
    /// the serial id — other past `oura-*` pairings are left untouched. Best-effort; returns true when a
    /// re-point happened so the caller can `setActive(serialId)` to move the spine onto it.
    @discardableResult
    func adoptSerialIdentity(from activeId: String, to serialId: String) -> Bool {
        let moved = (try? store.adoptSerialIdentity(from: activeId, to: serialId)) ?? false
        if moved { reload() }
        return moved
    }

    /// Archive (remove) a device: NOOP stops connecting to it, but its recorded data is kept. If the
    /// archived device was the active one, `activeDeviceId` is left as-is here — the caller decides the
    /// next active device (or leaves none active) and calls `setActive` explicitly.
    func archive(_ id: String) {
        try? store.archive(id)
        reload()
    }

    /// Rename a device. `name` nil/empty clears the nickname so it falls back to brand+model.
    func rename(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.rename(id, nickname: (trimmed?.isEmpty == false) ? trimmed : nil)
        reload()
    }

    /// Permanently delete every recorded sample/derived row for a device across all `deviceId`-keyed
    /// tables. Does NOT remove the registry row (that's `archive`); this only empties its recordings.
    ///
    /// Routed through the `WhoopStore` actor's `deleteAllData(deviceId:)`, so the heavy 16+-table delete
    /// runs on the actor's OWN (off-main) executor instead of blocking the main thread (this is a
    /// `@MainActor` cache). Calling the synchronous `DeviceRegistryStore` write directly here would run
    /// the whole transaction on the main actor and freeze the UI on a large device/Apple-Health dataset.
    /// Best-effort: a store failure leaves the recordings and published state untouched. Awaits the delete
    /// BEFORE `reload()` so the refreshed device list reflects the emptied recordings.
    func deleteDeviceData(_ id: String, store: WhoopStore) async {
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return
        }
        reload()
    }

    /// Permanently FORGET a device: wipe all of its recorded data AND remove its registry entry, so a
    /// duplicate/stale strap disappears from the Devices list entirely. Today an archived ("Removed")
    /// row can only be re-activated or have its data wiped — never purged — so a duplicate strap lingers
    /// forever (issue #1193). Routes the heavy multi-table sample wipe through the `WhoopStore` actor
    /// (off-main, like `deleteDeviceData`), then removes the small `pairedDevice`/`device` registry rows
    /// and refreshes the published list. Best-effort: if the data wipe fails the registry row is left in
    /// place (we never leave orphaned recordings behind a removed row).
    func forget(_ id: String, store: WhoopStore) async {
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return
        }
        try? self.store.remove(id)
        reload()
    }

    /// Adopt (or clear, when nil) the stable BLE identity for a device — the
    /// CBPeripheral.identifier.uuidString on iOS/Mac. Lets NOOP tell physical straps apart and map a
    /// connected peripheral back to its registry row. Refreshes the published list. Best-effort.
    func setPeripheralId(_ id: String, peripheralId: String?) {
        try? store.setPeripheralId(id, peripheralId: peripheralId)
        reload()
    }

    /// Find the paired device that has adopted a given BLE peripheral, if any. A plain read of the
    /// store (no reload) — returns nil on any error or when no row has adopted that peripheral yet.
    func device(forPeripheralId peripheralId: String) -> PairedDevice? {
        (try? store.device(forPeripheralId: peripheralId)) ?? nil
    }

    /// Update the model label for a device and refresh the published list. Best-effort.
    func setModel(_ id: String, model: String) {
        try? store.setModel(id, model: model)
        reload()
    }
}
