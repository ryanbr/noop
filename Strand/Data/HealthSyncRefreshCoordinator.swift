import Foundation

/// Mantiene el orden necesario entre la importación de Salud y la caché que alimenta «Hoy».
/// HealthKit escribe primero en el almacén local; solo después se refresca el repositorio visible.
@MainActor
enum HealthSyncRefreshCoordinator {
    static func run(sync: () async -> Void, refresh: () async -> Void) async {
        await sync()
        await refresh()
    }
}
