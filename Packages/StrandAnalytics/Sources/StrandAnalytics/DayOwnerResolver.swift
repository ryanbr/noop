import Foundation

/// Decides which single device owns a given day's displayed/scored metrics, so scores are never
/// computed from a mix of sources (invariant I2). Pure — the caller supplies candidates (each device
/// that has any data near the day, with a priority) and any locked override from the dayOwnership table.
public enum DayOwnerResolver {
    public struct Candidate: Equatable {
        public let deviceId: String
        public let priority: Int     // 0 = active strap, 1 = other live straps, 2 = imports (lower wins)
        public let hasData: Bool
        public init(deviceId: String, priority: Int, hasData: Bool) {
            self.deviceId = deviceId; self.priority = priority; self.hasData = hasData
        }
    }
    /// Returns the owning deviceId, or nil if no candidate has data for the day.
    public static func resolve(day: String, lockedOwner: String?, candidates: [Candidate]) -> String? {
        if let locked = lockedOwner { return locked }
        return candidates.filter { $0.hasData }.sorted { $0.priority < $1.priority }.first?.deviceId
    }

    /// #2880: the active strap won the day, but archived rows for the SAME physical strap (same
    /// peripheralId, left behind by Remove + re-add) may hold the night. The one with the most HR rows
    /// owns the day; a tie keeps the active id, then the earlier sibling. `siblings` are (id, hrRows).
    public static func sameStrapOwner(activeId: String, activeHrRows: Int,
                                      siblings: [(id: String, hrRows: Int)]) -> String {
        var best = (id: activeId, hrRows: activeHrRows)
        for s in siblings where s.hrRows > best.hrRows { best = s }
        return best.id
    }
}
