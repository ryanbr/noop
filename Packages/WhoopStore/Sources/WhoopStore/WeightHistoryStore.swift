import Foundation

public enum WeightHistoryError: Error { case invalidEntry }

extension WhoopStore {
    /// Save one manual reading per local date. Imports and the profile scalar are never changed.
    /// Kotlin twin: `WeightHistoryStore.save`.
    public func saveWeight(day: String, kilograms: Double) async throws {
        guard WeightHistory.validDay(day), WeightHistory.validKilograms(kilograms) else {
            throw WeightHistoryError.invalidEntry
        }
        try await upsertMetricSeries([MetricPoint(day: day, key: WeightHistory.key, value: kilograms)],
                                     deviceId: WeightHistory.manualSource)
    }

    /// Kotlin twin: `WeightHistoryStore.delete`.
    public func deleteWeight(day: String) async throws {
        guard WeightHistory.validDay(day) else { throw WeightHistoryError.invalidEntry }
        try await deleteMetricSeriesPoint(deviceId: WeightHistory.manualSource, day: day, key: WeightHistory.key)
    }

    /// Kotlin twin: `WeightHistoryStore.history`.
    public func weightHistory(through day: String) async throws -> [WeightEntry] {
        var entries: [WeightEntry] = []
        for source in WeightHistory.sources {
            // Older imports only populated appleDaily. Valid series rows appended below win a
            // same-source conflict; invalid rows cannot hide the daily fallback.
            if source != WeightHistory.manualSource {
                let daily = try await appleDaily(deviceId: source, from: "0001-01-01", to: day)
                entries += daily.compactMap { row in
                    row.weightKg.map { WeightEntry(day: row.day, kilograms: $0, source: source) }
                }
            }
            let points = try await metricSeries(deviceId: source, key: WeightHistory.key, from: "0001-01-01", to: day)
            entries += points.map { WeightEntry(day: $0.day, kilograms: $0.value, source: source) }
        }
        return WeightHistory.resolve(entries, through: day)
    }
}
