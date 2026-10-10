import Foundation

/// Freshness of accepted live samples, independent of the displayed heart-rate value.
struct TrainingPulseGuard: Codable, Equatable {
    static let timeoutSeconds = 600
    static let checkpointSeconds = 30
    var lastSampleSec: Int?
    var recoveryAllowance = 0
    var disconnected: Bool? = nil
    var reconnectedAtSec: Int? = nil

    var deadline: Int? {
        let allowance = min(Self.checkpointSeconds, max(0, recoveryAllowance))
        guard disconnected != true, let lastSampleSec, lastSampleSec > 0 else { return nil }
        let reference = max(lastSampleSec, reconnectedAtSec ?? lastSampleSec)
        guard reference > 0,
              reference <= Int.max - Self.timeoutSeconds - allowance - Self.checkpointSeconds else { return nil }
        return reference + Self.timeoutSeconds + allowance
    }
    func isDue(at now: Int) -> Bool { deadline.map { now >= $0 } ?? false }
    mutating func receive(at now: Int) { lastSampleSec = now; recoveryAllowance = 0; reconnectedAtSec = nil }
    mutating func resume(at now: Int) { if lastSampleSec != nil { receive(at: now) } }
    mutating func setConnected(_ connected: Bool, at now: Int) {
        if !connected { disconnected = true; reconnectedAtSec = nil }
        else if disconnected == true {
            disconnected = false
            // A connection is not a sample; allow a new window without claiming a fresh pulse.
            reconnectedAtSec = now
            recoveryAllowance = 0
        }
    }
    // A checkpoint can lag receipt by 30 seconds. Never pause early after a process restart.
    var checkpoint: Self { var copy = self; copy.recoveryAllowance = Self.checkpointSeconds; return copy }
}
