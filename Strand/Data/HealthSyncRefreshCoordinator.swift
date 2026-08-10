import Foundation

/// Keeps the ordering between the Health import and the cache that feeds Today.
/// HealthKit writes to the local store first; only then is the visible repository refreshed.
@MainActor
enum HealthSyncRefreshCoordinator {
    static func run(sync: () async -> Void, refresh: () async -> Void) async {
        await sync()
        await refresh()
    }
}
