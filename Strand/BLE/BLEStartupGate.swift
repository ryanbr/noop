import Foundation

/// Serializes store initialization before automatic BLE startup can consult the device registry.
@MainActor
final class BLEStartupGate {
    enum Refusal: Equatable {
        case storeNotReady
        case radioNotPoweredOn
    }

    private var preparation: Task<Bool, Never>?

    func prepare(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if let preparation { return await preparation.value }
        let task = Task { @MainActor in await operation() }
        preparation = task
        let ready = await task.value
        preparation = nil
        return ready
    }

    func resume(prepare operation: @escaping @MainActor () async -> Bool,
                radioIsPoweredOn: @MainActor () -> Bool,
                onRefusal: @MainActor (Refusal) -> Void,
                isAllowed: @MainActor () -> Bool,
                action: @MainActor () -> Void) async {
        guard await prepare(operation) else {
            onRefusal(.storeNotReady)
            return
        }
        guard radioIsPoweredOn() else {
            onRefusal(.radioNotPoweredOn)
            return
        }
        // The active-device policy logs its own refusal; do not duplicate that evidence here.
        guard isAllowed() else { return }
        action()
    }
}
