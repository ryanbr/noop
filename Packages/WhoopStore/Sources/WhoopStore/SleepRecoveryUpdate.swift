import Foundation

/// A bounded derived-score update; sleep records and other stored day fields remain unchanged.
public struct SleepRecoveryUpdate: Equatable, Sendable {
    public let day: String
    public let recovery: Double?
    public let skinTempDevC: Double?
    public let sourceId: String?

    public init(day: String, recovery: Double?, skinTempDevC: Double?, sourceId: String? = nil) {
        self.day = day
        self.recovery = recovery
        self.skinTempDevC = skinTempDevC
        self.sourceId = sourceId
    }
    public func changes(_ row: DailyMetric) -> Bool {
        day == row.day && (recovery != row.recovery || skinTempDevC != row.skinTempDevC)
    }
}
